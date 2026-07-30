// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/scene_tree.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/core/class_db.hpp>

#include "logger.h"
#include "pasture_3d_ocean.h"
#include "pasture_3d_pool_manager.h"

///////////////////////////
// Private Functions
///////////////////////////

/**
 * The scene's Pasture3DPoolManager, or null.
 *
 * Group lookup rather than an exported reference, matching §5.1: the manager is
 * scene-wide infrastructure and making every body carry a NodePath to it is the kind
 * of wiring that gets forgotten once and then debugged for an hour. An explicit
 * override belongs on Pasture3DPool in Phase 3, where several managers are conceivable; the
 * ocean is content with whichever is driving the clock.
 */
Pasture3DPoolManager *Pasture3DOcean::_find_manager() const {
	return Pasture3DPoolManager::get_active_manager();
}

void Pasture3DOcean::_setup_mesher() {
	if (!_enabled || !_is_inside_world) {
		return;
	}
	if (!_mesher) {
		LOG(DEBUG, "Creating ocean mesher");
		_mesher = new Pasture3DMesher();
	}
	_rebuild_runtime_material();
	_mesher->initialize(this, _mesh_size, _mesh_lods, _tessellation_level, _vertex_spacing,
			_runtime_material.is_valid() ? _runtime_material->get_rid() : RID(),
			_render_layers, false, _cast_shadows, _gi_mode);
	_push_clipmap_uniforms();
	_update_aabbs(true);
}

void Pasture3DOcean::_destroy_mesher(const bool p_final) {
	LOG(INFO, "Destroying ocean mesher");
	if (_mesher) {
		_mesher->destroy();
		if (p_final) {
			delete _mesher;
			_mesher = nullptr;
		}
	}
}

/**
 * Builds the private material this ocean draws with.
 *
 * A duplicate, deliberately outside Pasture3DPoolManager's shared cache. The cache exists
 * so ten ponds cost one material, and it works because a pond writes nothing into
 * its material -- everything per-pond is either the transform or the instance
 * uniform. The ocean is not like that: the clipmap writes _mesh_size,
 * _vertex_spacing, _subdiv and _target_pos into the material, and this node writes
 * sea_level, all of which describe THIS ocean. Sharing that with a pool would mean
 * the pool's material carried a sea level.
 *
 * The table still comes from the manager's profile, so the ocean is on the same
 * wave data as everything else -- it just holds its own copy of the material.
 */
void Pasture3DOcean::_rebuild_runtime_material() {
	if (_material.is_null()) {
		_runtime_material = Ref<Material>();
		return;
	}
	if (_runtime_material.is_null()) {
		_runtime_material = _material->duplicate();
	}
	Pasture3DPoolManager *manager = _find_manager();
	if (manager) {
		manager->upload_profile_into(_runtime_material, _wave_profile);
	}
	_sea_level_sent = FLT_MAX; // force the sea level write below
}

void Pasture3DOcean::_push_clipmap_uniforms() {
	ShaderMaterial *mat = Object::cast_to<ShaderMaterial>(_runtime_material.ptr());
	if (mat) {
		// Read by the clipmap geomorph in water_surface.gdshaderinc.
		mat->set_shader_parameter("_mesh_size", _mesh_size);
		mat->set_shader_parameter("_vertex_spacing", _vertex_spacing);
		mat->set_shader_parameter("_subdiv", Math::pow(2.f, (real_t)_tessellation_level));
	}
	if (_mesher) {
		// An instance uniform since Phase 1, so it cannot go on the material.
		_mesher->set_instance_shader_param("_water_domain_origin", _domain_origin);
	}
}

/**
 * Sizes the cull AABB to where the water actually is (water spec §4.5).
 *
 * Polled every physics frame and change-detected, exactly as Pasture3D did it. The
 * two terms still come from outside: sea level is this node's transform (which does
 * emit a notification, but the amplitude sum does not), and the amplitude sum
 * belongs to a profile on the manager.
 */
void Pasture3DOcean::_update_aabbs(const bool p_force) {
	if (!_mesher) {
		return;
	}
	real_t sea_level = get_sea_level();
	real_t amplitude = 0.f;
	Pasture3DPoolManager *manager = _find_manager();
	if (manager) {
		Ref<Pasture3DWaveProfile> profile = manager->get_profile(_wave_profile);
		if (profile.is_valid()) {
			// The amplitude SUM, not the amplitude knob: the whole table crests
			// together somewhere. Understating it culls water that is on screen.
			amplitude = profile->get_amplitude_sum();
		}
	}
	Vector2 range(sea_level - amplitude, sea_level + amplitude);
	if (!p_force && range == _height_range_sent) {
		return;
	}
	_height_range_sent = range;
	_mesher->update_aabbs(_cull_margin, range);
}

void Pasture3DOcean::_on_profiles_changed() {
	_rebuild_runtime_material();
	_update_aabbs(true);
}

///////////////////////////
// Public Functions
///////////////////////////

Pasture3DOcean::Pasture3DOcean() {
	set_notify_transform(true);
}

Pasture3DOcean::~Pasture3DOcean() {
	_destroy_mesher(true);
}

Vector3 Pasture3DOcean::get_clipmap_target_position() const {
	Node3D *target = _clipmap_target.ptr();
	if (target && target->is_inside_tree()) {
		return target->get_global_position();
	}
	// No explicit target: follow the current camera, which is what an ocean without
	// a terrain to borrow one from has to do. In the editor there is no current
	// camera in the game sense, so this falls back to the node's own position and
	// the clipmap simply centres on itself -- visible, if not tracking.
	Viewport *vp = get_viewport();
	if (vp) {
		Camera3D *cam = vp->get_camera_3d();
		if (cam) {
			return cam->get_global_position();
		}
	}
	return get_global_position();
}

Vector2 Pasture3DOcean::get_default_height_range() const {
	real_t sea_level = get_sea_level();
	return Vector2(sea_level, sea_level);
}

void Pasture3DOcean::set_enabled(const bool p_enabled) {
	if (_enabled == p_enabled) {
		return;
	}
	_enabled = p_enabled;
	if (_enabled) {
		_setup_mesher();
	} else {
		_destroy_mesher(false);
	}
	update_configuration_warnings();
}

void Pasture3DOcean::set_mesh_lods(const int p_count) {
	int lods = CLAMP(p_count, 1, 10);
	SET_IF_DIFF(_mesh_lods, lods);
	_setup_mesher();
}

void Pasture3DOcean::set_tessellation_level(const int p_level) {
	int level = CLAMP(p_level, 0, 3);
	SET_IF_DIFF(_tessellation_level, level);
	_setup_mesher();
}

void Pasture3DOcean::set_mesh_size(const int p_size) {
	int size = CLAMP(p_size, 8, 64);
	SET_IF_DIFF(_mesh_size, size);
	_setup_mesher();
}

void Pasture3DOcean::set_vertex_spacing(const real_t p_spacing) {
	real_t spacing = CLAMP(p_spacing, 0.25f, 100.f);
	SET_IF_DIFF(_vertex_spacing, spacing);
	_setup_mesher();
}

void Pasture3DOcean::set_cull_margin(const real_t p_margin) {
	SET_IF_DIFF(_cull_margin, CLAMP(p_margin, 0.f, 100000.f));
	_update_aabbs(true);
}

void Pasture3DOcean::set_cast_shadows(const RenderingServer::ShadowCastingSetting p_cast_shadows) {
	SET_IF_DIFF(_cast_shadows, p_cast_shadows);
	_setup_mesher();
}

void Pasture3DOcean::set_gi_mode(const GeometryInstance3D::GIMode p_gi_mode) {
	SET_IF_DIFF(_gi_mode, p_gi_mode);
	_setup_mesher();
}

void Pasture3DOcean::set_render_layers(const uint32_t p_layers) {
	SET_IF_DIFF(_render_layers, p_layers);
	_setup_mesher();
}

void Pasture3DOcean::set_material(const Ref<Material> &p_material) {
	SET_IF_DIFF(_material, p_material);
	// The private duplicate is of the OLD base; drop it so the next setup rebuilds.
	_runtime_material = Ref<Material>();
	_setup_mesher();
	update_configuration_warnings();
}

void Pasture3DOcean::set_wave_profile(const StringName &p_name) {
	SET_IF_DIFF(_wave_profile, p_name);
	_rebuild_runtime_material();
	_update_aabbs(true);
	update_configuration_warnings();
}

void Pasture3DOcean::set_domain_origin(const Vector3 &p_origin) {
	SET_IF_DIFF(_domain_origin, p_origin);
	_push_clipmap_uniforms();
}

void Pasture3DOcean::set_clipmap_target(Node3D *p_node) {
	_clipmap_target.set_target(p_node);
	if (_mesher) {
		_mesher->reset_target_position();
	}
}

///////////////////////////
// CPU water query
///////////////////////////

real_t Pasture3DOcean::get_water_time() const {
	Pasture3DPoolManager *manager = _find_manager();
	return manager ? manager->get_water_time() : 0.f;
}

Vector3 Pasture3DOcean::get_water_surface_point(const Vector2 &p_domain_xz) const {
	Pasture3DPoolManager *manager = _find_manager();
	if (!manager) {
		return Vector3(p_domain_xz.x, get_sea_level(), p_domain_xz.y);
	}
	Vector3 local = manager->evaluate_surface_point(_wave_profile, p_domain_xz);
	// The shader displaces in domain space and adds nothing back: the position
	// already carried the origin and only the domain was shifted. Same here.
	return Vector3(local.x + _domain_origin.x, local.y + get_sea_level(), local.z + _domain_origin.z);
}

real_t Pasture3DOcean::get_water_height(const Vector2 &p_xz) const {
	Pasture3DPoolManager *manager = _find_manager();
	if (!manager) {
		return get_sea_level();
	}
	Vector2 target(p_xz.x - _domain_origin.x, p_xz.y - _domain_origin.z);
	Vector2 domain = manager->solve_domain(_wave_profile, target);
	return get_sea_level() + manager->evaluate_height(_wave_profile, domain);
}

Vector3 Pasture3DOcean::get_water_normal(const Vector2 &p_xz) const {
	Pasture3DPoolManager *manager = _find_manager();
	if (!manager) {
		return Vector3(0.f, 1.f, 0.f);
	}
	Vector2 target(p_xz.x - _domain_origin.x, p_xz.y - _domain_origin.z);
	Vector2 domain = manager->solve_domain(_wave_profile, target);
	return manager->evaluate_normal(_wave_profile, domain);
}

PackedStringArray Pasture3DOcean::_get_configuration_warnings() const {
	PackedStringArray warnings;
	Pasture3DPoolManager *manager = _find_manager();
	if (!manager) {
		warnings.push_back(
				"No Pasture3DPoolManager in the scene. The ocean will draw with whatever wave table its "
				"material's shader variant compiles in, and nothing will drive water_time, so it "
				"will not move.");
	} else if (!manager->has_profile(_wave_profile)) {
		warnings.push_back("No wave profile named '" + String(_wave_profile) +
				"' on the Pasture3DPoolManager. Available: " + String(", ").join(manager->get_profile_names()));
	} else {
		// The failure Pasture3D used to warn about, carried over: a profile with
		// more waves than the material's variant compiles is invisible on screen
		// but present in the CPU query, so get_water_height() describes a surface
		// nobody drew.
		Ref<Pasture3DWaveProfile> profile = manager->get_profile(_wave_profile);
		ShaderMaterial *mat = Object::cast_to<ShaderMaterial>(_material.ptr());
		if (profile.is_valid() && mat) {
			Ref<Shader> shader = mat->get_shader();
			if (shader.is_valid()) {
				String path = shader->get_path();
				int variant_waves = path.contains("_low") ? 4 : 8;
				if (path.contains("water_body")) {
					variant_waves = path.contains("_low") ? 2 : 4;
				}
				if (profile->get_wave_count() > variant_waves) {
					warnings.push_back("Profile '" + String(_wave_profile) + "' has " +
							String::num_int64(profile->get_wave_count()) + " waves but " +
							path.get_file() + " compiles " + String::num_int64(variant_waves) +
							", so the extra waves are invisible on screen while get_water_height() "
							"still counts them. Lower the profile's wave_count or use a higher tier.");
				}
			}
		}
	}
	if (_material.is_null()) {
		warnings.push_back("No material. Assign M_water_ocean.tres or M_water_ocean_low.tres.");
	}
	return warnings;
}

///////////////////////////
// Protected Functions
///////////////////////////

void Pasture3DOcean::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_ENTER_WORLD: {
			LOG(INFO, "NOTIFICATION_ENTER_WORLD");
			_is_inside_world = true;
			// Before any water material is loaded, or Godot warns about a global
			// parameter that "was removed at some point" and renders black until
			// the material recompiles. An ocean can exist with no manager, so it
			// cannot rely on the manager having done it.
			Pasture3DPoolManager::register_water_globals();
			_setup_mesher();
			set_physics_process(true);
			break;
		}

		case NOTIFICATION_EXIT_WORLD: {
			LOG(INFO, "NOTIFICATION_EXIT_WORLD");
			_is_inside_world = false;
			_destroy_mesher(false);
			set_physics_process(false);
			break;
		}

		case NOTIFICATION_ENTER_TREE: {
			// Re-joined on every enter, not only in a constructor: a reparent exits
			// and re-enters the tree, and a group left behind is an ocean nothing can
			// find.
			add_to_group(OCEAN_GROUP);
			Pasture3DPoolManager *manager = _find_manager();
			if (manager) {
				Callable cb = callable_mp(this, &Pasture3DOcean::_on_profiles_changed);
				if (!manager->is_connected("profiles_changed", cb)) {
					manager->connect("profiles_changed", cb);
				}
			}
			break;
		}

		case NOTIFICATION_EXIT_TREE: {
			remove_from_group(OCEAN_GROUP);
			break;
		}

		case NOTIFICATION_PREDELETE: {
			_destroy_mesher(true);
			break;
		}

		case NOTIFICATION_VISIBILITY_CHANGED: {
			if (_mesher) {
				_mesher->update();
			}
			break;
		}

		case NOTIFICATION_TRANSFORM_CHANGED: {
			// Sea level IS this node's Y (§6.1), so moving the node moves the water.
			_update_aabbs();
			break;
		}

		case NOTIFICATION_PHYSICS_PROCESS: {
			if (!_enabled || !_mesher) {
				break;
			}
			// The material may only now exist (it needs a manager for its table,
			// and node order does not guarantee one at ENTER_WORLD).
			if (_runtime_material.is_null() && _material.is_valid()) {
				_setup_mesher();
			}
			ShaderMaterial *mat = Object::cast_to<ShaderMaterial>(_runtime_material.ptr());
			real_t sea_level = get_sea_level();
			if (mat && _sea_level_sent != sea_level) {
				_sea_level_sent = sea_level;
				mat->set_shader_parameter("sea_level", sea_level);
			}
			_mesher->snap();
			_update_aabbs();
			break;
		}
	}
}

void Pasture3DOcean::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_enabled", "enabled"), &Pasture3DOcean::set_enabled);
	ClassDB::bind_method(D_METHOD("is_enabled"), &Pasture3DOcean::is_enabled);
	ClassDB::bind_method(D_METHOD("set_mesh_lods", "count"), &Pasture3DOcean::set_mesh_lods);
	ClassDB::bind_method(D_METHOD("get_mesh_lods"), &Pasture3DOcean::get_mesh_lods);
	ClassDB::bind_method(D_METHOD("set_tessellation_level", "level"), &Pasture3DOcean::set_tessellation_level);
	ClassDB::bind_method(D_METHOD("get_tessellation_level"), &Pasture3DOcean::get_tessellation_level);
	ClassDB::bind_method(D_METHOD("set_mesh_size", "size"), &Pasture3DOcean::set_mesh_size);
	ClassDB::bind_method(D_METHOD("get_mesh_size"), &Pasture3DOcean::get_mesh_size);
	ClassDB::bind_method(D_METHOD("set_vertex_spacing", "spacing"), &Pasture3DOcean::set_vertex_spacing);
	ClassDB::bind_method(D_METHOD("get_vertex_spacing"), &Pasture3DOcean::get_vertex_spacing);
	ClassDB::bind_method(D_METHOD("set_cull_margin", "margin"), &Pasture3DOcean::set_cull_margin);
	ClassDB::bind_method(D_METHOD("get_cull_margin"), &Pasture3DOcean::get_cull_margin);
	ClassDB::bind_method(D_METHOD("set_cast_shadows", "setting"), &Pasture3DOcean::set_cast_shadows);
	ClassDB::bind_method(D_METHOD("get_cast_shadows"), &Pasture3DOcean::get_cast_shadows);
	ClassDB::bind_method(D_METHOD("set_gi_mode", "mode"), &Pasture3DOcean::set_gi_mode);
	ClassDB::bind_method(D_METHOD("get_gi_mode"), &Pasture3DOcean::get_gi_mode);
	ClassDB::bind_method(D_METHOD("set_render_layers", "layers"), &Pasture3DOcean::set_render_layers);
	ClassDB::bind_method(D_METHOD("get_render_layers"), &Pasture3DOcean::get_render_layers);
	ClassDB::bind_method(D_METHOD("set_material", "material"), &Pasture3DOcean::set_material);
	ClassDB::bind_method(D_METHOD("get_material"), &Pasture3DOcean::get_material);
	ClassDB::bind_method(D_METHOD("set_wave_profile", "name"), &Pasture3DOcean::set_wave_profile);
	ClassDB::bind_method(D_METHOD("get_wave_profile"), &Pasture3DOcean::get_wave_profile);
	ClassDB::bind_method(D_METHOD("set_domain_origin", "origin"), &Pasture3DOcean::set_domain_origin);
	ClassDB::bind_method(D_METHOD("get_domain_origin"), &Pasture3DOcean::get_domain_origin);
	ClassDB::bind_method(D_METHOD("set_clipmap_target", "node"), &Pasture3DOcean::set_clipmap_target);
	ClassDB::bind_method(D_METHOD("get_clipmap_target"), &Pasture3DOcean::get_clipmap_target);

	ClassDB::bind_method(D_METHOD("get_sea_level"), &Pasture3DOcean::get_sea_level);
	ClassDB::bind_method(D_METHOD("get_water_height", "global_xz"), &Pasture3DOcean::get_water_height);
	ClassDB::bind_method(D_METHOD("get_water_normal", "global_xz"), &Pasture3DOcean::get_water_normal);
	ClassDB::bind_method(D_METHOD("get_water_surface_point", "domain_xz"), &Pasture3DOcean::get_water_surface_point);
	ClassDB::bind_method(D_METHOD("get_water_time"), &Pasture3DOcean::get_water_time);

	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enabled"), "set_enabled", "is_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "material", PROPERTY_HINT_RESOURCE_TYPE, "ShaderMaterial,BaseMaterial3D"), "set_material", "get_material");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "wave_profile"), "set_wave_profile", "get_wave_profile");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "domain_origin"), "set_domain_origin", "get_domain_origin");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "clipmap_target", PROPERTY_HINT_NODE_TYPE, "Node3D"), "set_clipmap_target", "get_clipmap_target");

	ADD_GROUP("Geometry", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mesh_lods", PROPERTY_HINT_RANGE, "1,10,1"), "set_mesh_lods", "get_mesh_lods");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mesh_size", PROPERTY_HINT_RANGE, "8,64,2"), "set_mesh_size", "get_mesh_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "tessellation_level", PROPERTY_HINT_RANGE, "0,3,1"), "set_tessellation_level", "get_tessellation_level");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "vertex_spacing", PROPERTY_HINT_RANGE, "0.25,10.0,0.05,or_greater"), "set_vertex_spacing", "get_vertex_spacing");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "cull_margin", PROPERTY_HINT_RANGE, "0.0,10000.0,0.5,or_greater"), "set_cull_margin", "get_cull_margin");

	ADD_GROUP("Rendering", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "cast_shadows", PROPERTY_HINT_ENUM, "Off,On,Double-Sided,Shadows Only"), "set_cast_shadows", "get_cast_shadows");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "gi_mode", PROPERTY_HINT_ENUM, "Disabled,Static,Dynamic"), "set_gi_mode", "get_gi_mode");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "render_layers", PROPERTY_HINT_LAYERS_3D_RENDER), "set_render_layers", "get_render_layers");
}
