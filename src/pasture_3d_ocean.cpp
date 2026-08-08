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

/**
 * Joins the manager's registry and its profiles_changed signal, if there is a manager yet.
 *
 * RETRIED, not done once. Siblings enter the tree in child order and Pasture3DPoolManager only
 * appends itself to _managers in its own ENTER_TREE, so an ocean placed above the manager in
 * the scene ran this with _managers empty. Nothing looked again: the PHYSICS_PROCESS
 * recovery path below only fires while _runtime_material is null, and the first tick fills
 * that in with or without a manager. The ocean then stayed invisible to body_at() for the
 * life of the scene -- buoys in open water got no body and never floated -- and missed every
 * profile change, all decided by the order of two nodes in the inspector.
 *
 * Idempotent and cheap once it has landed: the flag short-circuits it, and the two calls
 * underneath are themselves guarded (register_body() de-dupes, is_connected() gates).
 */
void Pasture3DOcean::_try_register_with_manager() {
	if (_manager_registered) {
		return;
	}
	Pasture3DPoolManager *manager = _find_manager();
	if (!manager) {
		return;
	}
	Callable cb = callable_mp(this, &Pasture3DOcean::_on_profiles_changed);
	if (!manager->is_connected("profiles_changed", cb)) {
		manager->connect("profiles_changed", cb);
	}
	// So body_at() can hand out the ocean as the fallback for a point no pool claims --
	// which is what makes a buoy work in open water.
	manager->register_body(this);
	_manager_registered = true;
	// The table and the cull AABB were built against "no manager"; now there is one.
	_rebuild_runtime_material();
	_update_aabbs(true);
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
	// TRUE since the split-screen work reached the water: _target_pos is an instance uniform now
	// (water_common.gdshaderinc), so writing it material-wide would write to a uniform that is no
	// longer there and every view would morph toward the origin. The ocean was single-view purely
	// because this said false.
	_mesher->initialize(this, _mesh_size, _mesh_lods, _tessellation_level, _vertex_spacing,
			_runtime_material.is_valid() ? _runtime_material->get_rid() : RID(),
			_render_layers, true, _cast_shadows, _gi_mode);
	_apply_views();
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
 *
 * A duplicate is a SNAPSHOT, and keeping it in step with the base it was taken from is
 * _poll_base_material()'s job, not this one's.
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

/**
 * Carries inspector edits of the base material into the private duplicate.
 *
 * Polled rather than pushed, and for a harder reason than the AABB below: there is no
 * signal. ShaderMaterial emits nothing when a parameter changes -- not `changed`, not
 * `property_list_changed`, through either set_shader_parameter() or
 * set("shader_parameter/.."). A directly-assigned material needs no announcement because
 * the RID is the same object; only a duplicate does, and the engine makes none. So the
 * poll IS the technique here, not a shortcut around one.
 *
 * EDITOR ONLY, because tuning a preset is an editor act. The comparison inside
 * sync_material_params() means an untouched material costs reads and no RenderingServer
 * traffic, and the uniforms this node writes are skipped there -- so this does not fight
 * the sea level and clipmap writes happening two lines away in _notification().
 */
void Pasture3DOcean::_poll_base_material() {
	if (_material.is_null() || _runtime_material.is_null()) {
		return;
	}
	Pasture3DPoolManager::sync_material_params(_material, _runtime_material);
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

// EVERY SETTER HERE LOGS. Each one silently clamps, and a knob that stops responding
// with nothing in the log is what sent someone hunting through the mesher for a bug that
// was a ceiling. The log line fires only on an actual change: SET_IF_DIFF returns first
// when the value is unchanged.

// Rings, and therefore REACH, not detail. The mesher builds `_lods + _tessellation_level`
// of them (pasture_3d_mesher.cpp), each twice the span of the last.
void Pasture3DOcean::set_mesh_lods(const int p_count) {
	int lods = CLAMP(p_count, 1, 10);
	SET_IF_DIFF(_mesh_lods, lods);
	LOG(INFO, "Setting ocean mesh levels: ", _mesh_lods);
	_setup_mesher();
}

/**
 * Extra clipmap rings BELOW LOD0, halving vertex spacing each time: the density dial.
 * Effective spacing at the camera is vertex_spacing / 2^tessellation_level, and _subdiv
 * (2^level) goes to the shader for the LOD0 geomorph.
 *
 * Ceiling restored to 6. Phase 2 extracted this from Pasture3D::set_ocean_tessellation_level
 * and narrowed it to 3 with no comment, while carrying the defaults over verbatim -- a
 * transcription slip rather than a decision, and one that reads from the inspector as
 * "the slider stopped working". Same story in set_mesh_size().
 */
void Pasture3DOcean::set_tessellation_level(const int p_level) {
	int level = CLAMP(p_level, 0, 6);
	SET_IF_DIFF(_tessellation_level, level);
	LOG(INFO, "Setting ocean tessellation level: ", _tessellation_level);
	_setup_mesher();
}

/**
 * Quads per clipmap tile -- the RADIUS of each resolution band, not its density.
 *
 * This is the knob for "the water goes coarse too close to the camera". Tiles are laid
 * out at multiples of _mesh_size (Pasture3DMesher::_generate_offset_data), so doubling it
 * doubles how far the finest ring reaches before the LOD halves. Density comes from
 * vertex_spacing and tessellation_level instead.
 *
 * COST SCALES WITH THE SQUARE, on every ring. 256 is the terrain's ceiling and it is
 * reachable here again, but an ocean fills the screen in a way ground does not; treat
 * 48-64 as the working range and the rest as headroom you measure before keeping.
 *
 * `& ~1` restored with the ceiling. The size must be even: the LOD0 geomorph in
 * water_surface.gdshaderinc is a vertex-parity test (`fract(VERTEX.xz * 0.5) * 2.0`), so
 * an odd tile flips the parity of the next one and the seam stops aligning. The step-2
 * inspector hint hides this; a value set from code does not go through the hint.
 */
void Pasture3DOcean::set_mesh_size(const int p_size) {
	int size = CLAMP(p_size & ~1, 8, 256); // Ensure even
	SET_IF_DIFF(_mesh_size, size);
	LOG(INFO, "Setting ocean mesh size: ", _mesh_size);
	_setup_mesher();
}

// Metres between vertices at LOD0 before tessellation divides it. Moves WITH mesh_lods:
// halving the spacing halves the reach, and one more LOD buys it back (see the header).
void Pasture3DOcean::set_vertex_spacing(const real_t p_spacing) {
	real_t spacing = CLAMP(p_spacing, 0.25f, 100.f);
	SET_IF_DIFF(_vertex_spacing, spacing);
	LOG(INFO, "Setting ocean vertex spacing: ", _vertex_spacing);
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
	_drop_height_memo(); // a different table is a different surface
	_rebuild_runtime_material();
	_update_aabbs(true);
	update_configuration_warnings();
}

void Pasture3DOcean::set_domain_origin(const Vector3 &p_origin) {
	SET_IF_DIFF(_domain_origin, p_origin);
	_drop_height_memo(); // subtracted before the solve, so it moves the answer
	_push_clipmap_uniforms();
}

/**
 * CAMERA_USER_GROUP's method: one clipmap view per camera, on the layer that camera reads.
 *
 * The ocean subscribes directly rather than through Pasture3DPoolManager, because it works in a
 * scene with no manager at all (water spec W4) and a camera list routed through one would be lost
 * in exactly that case.
 */
void Pasture3DOcean::set_cameras(const TypedArray<Camera3D> &p_cameras,
		const PackedInt32Array &p_layers) {
	_view_cameras = p_cameras;
	_view_layers = p_layers;
	_apply_views();
}

void Pasture3DOcean::_apply_views() {
	if (!_mesher) {
		return;
	}
	Vector<uint64_t> ids;
	Vector<uint32_t> layers;
	for (int i = 0; i < _view_cameras.size(); i++) {
		Camera3D *cam = Object::cast_to<Camera3D>(_view_cameras[i]);
		if (!cam) {
			continue;
		}
		ids.push_back(cam->get_instance_id());
		layers.push_back(i < _view_layers.size() ? (uint32_t)_view_layers[i] : _render_layers);
	}
	_mesher->set_views(ids, layers);
	_push_clipmap_uniforms();
	_height_range_sent = V2_MAX; // re-created instances need the cull volume again
	_update_aabbs(true);
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

/**
 * Surface height at a world XZ, including waves. Memoised per (world XZ, physics frame);
 * see _height_memo_xz for why that pair and why one entry.
 *
 * Keyed on the physics FRAME rather than on water_time, exactly as Pasture3DWaterBody does:
 * the manager advances the clock in its own physics tick, so water_time is constant across a
 * frame by construction, and an integer compare beats a float one.
 *
 * That does make the whole frame agree on whichever value was captured first. Node order
 * decides whether that is the pre- or post-advance clock, so a query can lag the drawn
 * surface by one frame -- but the alternative is what was there before, where callers on
 * either side of the manager's tick disagreed with each other. Internally consistent and
 * possibly one frame old beats inconsistent. Phase 1 criterion H pins the parity.
 */
real_t Pasture3DOcean::get_water_height(const Vector2 &p_xz) const {
	const uint64_t frame = Engine::get_singleton()->get_physics_frames();
	if (_height_memo_valid && _height_memo_frame == frame && _height_memo_xz == p_xz) {
		return _height_memo_y;
	}
	Pasture3DPoolManager *manager = _find_manager();
	if (!manager) {
		// Not memoised: there is no solve to save, and a manager appearing mid-frame should
		// not have to invalidate anything.
		return get_sea_level();
	}
	Vector2 target(p_xz.x - _domain_origin.x, p_xz.y - _domain_origin.z);
	Vector2 domain = manager->solve_domain(_wave_profile, target);
	_height_memo_y = get_sea_level() + manager->evaluate_height(_wave_profile, domain);
	_height_memo_xz = p_xz;
	_height_memo_frame = frame;
	_height_memo_valid = true;
	return _height_memo_y;
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

/**
 * Is this world point in the water?
 *
 * An ocean is unbounded horizontally, so the only question is vertical, and it is
 * asked against the WAVE surface rather than the flat sea level -- at the shoreline
 * in a 1 m swell those differ by the entire effect, and a camera or a buoy that used
 * the flat plane would pop through the surface visibly.
 */
bool Pasture3DOcean::contains_point(const Vector3 &p_global_pos) const {
	return p_global_pos.y <= get_water_height(Vector2(p_global_pos.x, p_global_pos.z));
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
		//
		// The count is READ OFF THE SHADER, via the _wave_variant_count uniform
		// water_common.gdshaderinc declares for exactly this. It used to be inferred
		// from substrings of the shader's file path, which got water_river.gdshader
		// wrong (reported 8; it evaluates none) and got any renamed shader wrong in
		// whichever direction the name happened to fall -- inventing this warning or
		// hiding it, both silently.
		Ref<Pasture3DWaveProfile> profile = manager->get_profile(_wave_profile);
		ShaderMaterial *mat = Object::cast_to<ShaderMaterial>(_material.ptr());
		if (profile.is_valid() && mat) {
			Ref<Shader> shader = mat->get_shader();
			if (shader.is_valid()) {
				Variant declared = RS->shader_get_parameter_default(shader->get_rid(),
						StringName("_wave_variant_count"));
				String file = shader->get_path().get_file();
				// A shader that does not declare it is not a water shader this node
				// can reason about -- a custom one, or one that includes none of the
				// water headers. Say nothing rather than guess, which is the whole
				// point of the change: silence is a correct answer here and a wrong
				// number is not.
				//
				// The same branch also covers HEADLESS, where the dummy renderer
				// returns nil for every parameter default however the shader was
				// written. Harmless for the thing this drives -- configuration
				// warnings are read in the editor, which always has a real renderer --
				// but it does mean a --headless gate cannot assert on this warning,
				// and would see it silently absent rather than failing. See
				// bench/WaterShaderCompileCheck.gd, which prints the count and has to
				// be run windowed for the same reason.
				if (declared.get_type() == Variant::INT) {
					int variant_waves = (int)declared;
					if (variant_waves <= 0) {
						// A stream variant. The table is inert, so wave_count says
						// nothing about what is drawn -- but get_water_height() on THIS
						// node still reads it, which is the disagreement worth naming.
						warnings.push_back(String(file) +
								" evaluates no Gerstner waves at all -- it is a stream variant, "
								"which replaces the wave table with its own channel model. Profile '" +
								String(_wave_profile) +
								"' therefore describes a surface this material will not draw. Use an "
								"ocean or body variant here, or put this material on a Pasture3DStream.");
					} else if (profile->get_wave_count() > variant_waves) {
						warnings.push_back("Profile '" + String(_wave_profile) + "' has " +
								String::num_int64(profile->get_wave_count()) + " waves but " + file +
								" compiles " + String::num_int64(variant_waves) +
								", so the extra waves are invisible on screen while get_water_height() "
								"still counts them. Lower the profile's wave_count or use a higher tier.");
					}
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
			add_to_group(Pasture3D::CAMERA_USER_GROUP);
			_try_register_with_manager();
			break;
		}

		case NOTIFICATION_EXIT_TREE: {
			remove_from_group(OCEAN_GROUP);
			remove_from_group(Pasture3D::CAMERA_USER_GROUP);
			Pasture3DPoolManager *exiting_manager = _find_manager();
			if (exiting_manager) {
				exiting_manager->unregister_body(this);
			}
			// Re-attempted on the next enter: this ocean may come back under a different
			// manager, or under one that does not exist yet.
			_manager_registered = false;
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
			// get_water_height()'s memo is keyed on world XZ and the frame, but the answer
			// also carries sea level -- moving the ocean inside a frame would otherwise hand
			// back the pre-move height for the rest of it.
			_drop_height_memo();
			_update_aabbs();
			break;
		}

		case NOTIFICATION_PHYSICS_PROCESS: {
			// Before the enabled/mesher guard: a disabled ocean still has to be findable
			// by body_at(), and registration is about the registry, not about drawing.
			_try_register_with_manager();
			if (!_enabled || !_mesher) {
				break;
			}
			// The material may only now exist (it needs a manager for its table,
			// and node order does not guarantee one at ENTER_WORLD).
			if (_runtime_material.is_null() && _material.is_valid()) {
				_setup_mesher();
			}
			if (Engine::get_singleton()->is_editor_hint()) {
				_poll_base_material();
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
	ClassDB::bind_method(D_METHOD("contains_point", "global_pos"), &Pasture3DOcean::contains_point);
	ClassDB::bind_method(D_METHOD("set_cameras", "cameras", "layers"), &Pasture3DOcean::set_cameras);
	ClassDB::bind_method(D_METHOD("get_ocean_warnings"), &Pasture3DOcean::get_ocean_warnings);

	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enabled"), "set_enabled", "is_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "material", PROPERTY_HINT_RESOURCE_TYPE, "ShaderMaterial,BaseMaterial3D"), "set_material", "get_material");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "wave_profile"), "set_wave_profile", "get_wave_profile");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "domain_origin"), "set_domain_origin", "get_domain_origin");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "clipmap_target", PROPERTY_HINT_NODE_TYPE, "Node3D"), "set_clipmap_target", "get_clipmap_target");

	ADD_GROUP("Geometry", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mesh_lods", PROPERTY_HINT_RANGE, "1,10,1"), "set_mesh_lods", "get_mesh_lods");
	// Ranges match the clamps in the setters, and both match what these were before the
	// Phase 2 extraction. A hint narrower than the clamp is a slider that stops short of
	// a value the node would accept, which is indistinguishable from a broken knob.
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mesh_size", PROPERTY_HINT_RANGE, "8,256,2"), "set_mesh_size", "get_mesh_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "tessellation_level", PROPERTY_HINT_RANGE, "0,6,1"), "set_tessellation_level", "get_tessellation_level");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "vertex_spacing", PROPERTY_HINT_RANGE, "0.25,10.0,0.05,or_greater"), "set_vertex_spacing", "get_vertex_spacing");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "cull_margin", PROPERTY_HINT_RANGE, "0.0,10000.0,0.5,or_greater"), "set_cull_margin", "get_cull_margin");

	ADD_GROUP("Rendering", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "cast_shadows", PROPERTY_HINT_ENUM, "Off,On,Double-Sided,Shadows Only"), "set_cast_shadows", "get_cast_shadows");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "gi_mode", PROPERTY_HINT_ENUM, "Disabled,Static,Dynamic"), "set_gi_mode", "get_gi_mode");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "render_layers", PROPERTY_HINT_LAYERS_3D_RENDER), "set_render_layers", "get_render_layers");
}
