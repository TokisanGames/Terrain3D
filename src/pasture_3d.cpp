// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/compositor.hpp>
#include <godot_cpp/classes/directional_light3d.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/environment.hpp>
#include <godot_cpp/classes/label3d.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/quad_mesh.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/classes/surface_tool.hpp>
#include <godot_cpp/classes/viewport_texture.hpp>
#include <godot_cpp/classes/world3d.hpp>

#include "logger.h"
#include "pasture_3d.h"
#include "pasture_3d_util.h"
#include "unit_testing.h"

// Initialize static member variable
Pasture3D::DebugLevel Pasture3D::debug_level{ ERROR };

///////////////////////////
// Private Functions
///////////////////////////

void Pasture3D::_initialize() {
	LOG(INFO, "Instantiating main subsystems");
	// Before any water material can be loaded, or Godot warns about a global
	// parameter that "was removed at some point" and renders black until the
	// material recompiles.
	_register_water_globals();
	// Make blank objects if needed
	if (!_data) {
		LOG(DEBUG, "Creating blank data object");
		_data = memnew(Pasture3DData);
	}
	if (_material.is_null()) {
		LOG(DEBUG, "Creating blank material");
		_material.instantiate();
	}
	if (_assets.is_null()) {
		LOG(DEBUG, "Creating blank texture list");
		_assets.instantiate();
	}
	if (!_collision) {
		LOG(DEBUG, "Creating collision manager");
		_collision = memnew(Pasture3DCollision);
	}
	if (!_instancer) {
		LOG(DEBUG, "Creating instancer");
		_instancer = memnew(Pasture3DInstancer);
	}
	// Connect signals
	// Any region was changed, update region labels
	if (!_data->is_connected("region_map_changed", callable_mp(this, &Pasture3D::update_region_labels))) {
		LOG(DEBUG, "Connecting _data::region_map_changed signal to set_show_region_locations()");
		_data->connect("region_map_changed", callable_mp(this, &Pasture3D::update_region_labels));
	}
	// Any region was changed, regenerate collision if enabled
	if (!_data->is_connected("region_map_changed", callable_mp(_collision, &Pasture3DCollision::build))) {
		LOG(DEBUG, "Connecting _data::region_map_changed signal to build()");
		_data->connect("region_map_changed", callable_mp(_collision, &Pasture3DCollision::build));
	}
	// Any map was regenerated or regions changed, update material uniforms without rebuilding shaders
	if (!_data->is_connected("maps_changed", callable_mp(_material.ptr(), &Pasture3DMaterial::update).bind(Pasture3DMaterial::REGION_ARRAYS))) {
		LOG(DEBUG, "Connecting _data::maps_changed signal to _material->_update()");
		_data->connect("maps_changed", callable_mp(_material.ptr(), &Pasture3DMaterial::update).bind(Pasture3DMaterial::REGION_ARRAYS));
	}
	// Height map was regenerated, update aabbs
	if (!_data->is_connected("height_maps_changed", callable_mp(this, &Pasture3D::_update_mesher_aabbs))) {
		LOG(DEBUG, "Connecting _data::height_maps_changed signal to update_aabbs()");
		_data->connect("height_maps_changed", callable_mp(this, &Pasture3D::_update_mesher_aabbs));
	}
	// Texture assets changed, update material uniforms without rebuilding shaders
	if (!_assets->is_connected("textures_changed", callable_mp(_material.ptr(), &Pasture3DMaterial::update).bind(Pasture3DMaterial::TEXTURE_ARRAYS))) {
		LOG(DEBUG, "Connecting _assets.textures_changed to _material->update()");
		_assets->connect("textures_changed", callable_mp(_material.ptr(), &Pasture3DMaterial::update).bind(Pasture3DMaterial::TEXTURE_ARRAYS));
	}
	// Initialize the system
	if (!_initialized && _is_inside_world && is_inside_tree()) {
		LOG(INFO, "Initializing main subsystems");
		_data->initialize(this);
		_material->initialize(this);
		_assets->initialize(this);
		_collision->initialize(this);
		_instancer->initialize(this);
		_setup_terrain_mesher();
		_setup_ocean_mesher();
		_update_displacement_buffer();
		_initialized = true;
		snap();
	}
	update_configuration_warnings();
}

/**
 * This is a proxy for _process(delta) called by _notification() due to
 * https://github.com/godotengine/godot-cpp/issues/1022
 */
void Pasture3D::__physics_process(const double p_delta) {
	if (!_initialized) {
		return;
	}
	if (!_camera.is_valid()) {
		LOG(DEBUG, "Camera is null, getting the current one");
		_grab_camera();
	}
	if (_tessellation_level > 0) {
		if (_terrain_mesher && _d_buffer_vp && _material.is_valid()) {
			// If clipmap target has moved enough, re-center buffer on the target.
			Vector2 target_pos_2d = v3v2(get_clipmap_target_position());
			real_t tessellation_density = 1.f / pow(2.f, _tessellation_level);
			real_t vertex_spacing = _vertex_spacing * tessellation_density;
			if (!(MAX(std::abs(_last_buffer_position.x - target_pos_2d.x), std::abs(_last_buffer_position.y - target_pos_2d.y)) < vertex_spacing)) {
				_last_buffer_position = target_pos_2d;
				RS->material_set_param(_material->get_buffer_material_rid(), "_target_pos", get_clipmap_target_position());
				_d_buffer_vp->set_update_mode(SubViewport::UPDATE_ONCE);
				// Only call snap on _mesher if the buffer has snapped, prevents stuttering.
				_terrain_mesher->snap();
			}
		}
	} else if (_terrain_mesher) {
		_terrain_mesher->snap();
	}
	if (_ocean_enabled && _ocean_mesher) {
		_ocean_mesher->snap();
		_update_water_clock(p_delta);
		// Change-detected; see the function header for why it is polled at all.
		_update_ocean_aabbs();
		if (_ocean_material.is_valid() && _ocean_light_target.is_valid()) {
			DirectionalLight3D *light = cast_to<DirectionalLight3D>(_ocean_light_target.ptr());
			ShaderMaterial *ocean_shader_mat = Object::cast_to<ShaderMaterial>(_ocean_material.ptr());
			if (light && ocean_shader_mat) {
				Color color = COLOR_WHITE;
				color = light->get_color() * light->get_param(DirectionalLight3D::PARAM_ENERGY);
				Vector3 direction = light->get_global_basis().get_column(2);
				// Globals: one write reaches every water body in the scene.
				RS->global_shader_parameter_set("water_sun_color", Vector3(color.r, color.g, color.b));
				RS->global_shader_parameter_set("water_sun_direction", direction);
				// Per-material equivalents, for the legacy ocean shader only.
				// Goes away with it in Phase 5; the new shaders ignore these.
				ocean_shader_mat->set_shader_parameter("_light_color", color);
				ocean_shader_mat->set_shader_parameter("_light_direction", direction);
			}
		}
	}
	if (_collision && _collision->is_dynamic_mode()) {
		_collision->update();
	}
}

/**
 * If running in the editor, grab the first editor viewport camera.
 * The edited_scene_root is excluded in case the user already has a Camera3D in their scene.
 */
void Pasture3D::_grab_camera() {
	if (IS_EDITOR) {
		_camera.set_target(EditorInterface::get_singleton()->get_editor_viewport_3d(0)->get_camera_3d());
		LOG(DEBUG, "Grabbing the first editor viewport camera: ", _camera.get_target());
	} else {
		_camera.set_target(get_viewport()->get_camera_3d());
		LOG(DEBUG, "Grabbing the in-game viewport camera: ", _camera.get_target());
	}
	if (!_camera.is_valid() && !_clipmap_target.is_valid()) {
		set_physics_process(false); // No target to follow, disable snapping until one set
		LOG(ERROR, "Cannot find clipmap target or active camera. LODs won't be updated. Set manually with set_clipmap_target() or set_camera()");
	}
}

void Pasture3D::_destroy_collision(const bool p_final) {
	LOG(INFO, "Destroying Collision");
	if (_collision) {
		_collision->destroy();
	}
	if (p_final) {
		memdelete_safely(_collision);
	}
}

void Pasture3D::_setup_terrain_mesher() {
	if (!_terrain_mesher) {
		LOG(DEBUG, "Creating mesher");
		_terrain_mesher = new Pasture3DMesher();
	}
	// Terrain uses per-instance _target_pos so each split-screen view geomorphs to its own camera.
	_terrain_mesher->initialize(this, _mesh_size, _mesh_lods, _tessellation_level, _vertex_spacing, _material->get_material_rid(), _render_layers, true, _cast_shadows, _gi_mode);
	// (Re)initialization resets the mesher to a single view; re-apply any multi-camera config.
	if (!_cameras.is_empty()) {
		_apply_cameras_to_mesher();
	}
}

// Pasture3D: pushes the current camera list to the mesher as one clipmap view per camera, each on
// its reserved render layer (camera i -> bit TERRAIN_TOP_BIT - i). Empty list => single view.
void Pasture3D::_apply_cameras_to_mesher() {
	if (!_terrain_mesher) {
		return;
	}
	if (_cameras.is_empty()) {
		_terrain_mesher->set_views(Vector<uint64_t>(), Vector<uint32_t>());
		return;
	}
	Vector<uint32_t> layers;
	for (int i = 0; i < _cameras.size(); i++) {
		int bit = TERRAIN_TOP_BIT - i;
		layers.push_back(bit >= 0 ? (1u << uint32_t(bit)) : 1u);
	}
	_terrain_mesher->set_views(_cameras, layers);
}

void Pasture3D::_destroy_terrain_mesher(const bool p_final) {
	LOG(INFO, "Destroying terrain mesher");
	if (_terrain_mesher) {
		_terrain_mesher->destroy();
		if (p_final) {
			delete _terrain_mesher;
			_terrain_mesher = nullptr;
		}
	}
}

void Pasture3D::_setup_ocean_mesher() {
	if (_ocean_enabled) {
		if (!_ocean_mesher) {
			LOG(DEBUG, "Creating mesher");
			_ocean_mesher = new Pasture3DMesher();
		}
		_ocean_mesher->initialize(this, _ocean_mesh_size, _ocean_mesh_lods, _ocean_tessellation_level, _ocean_vertex_spacing, _ocean_material.is_valid() ? _ocean_material->get_rid() : RID(), _ocean_render_layers, false, _ocean_cast_shadows, _ocean_gi_mode);
		_update_ocean_aabbs(true);
		if (_ocean_material.is_valid()) {
			ShaderMaterial *ocean_shader_mat = Object::cast_to<ShaderMaterial>(_ocean_material.ptr());
			if (ocean_shader_mat) {
				ocean_shader_mat->set_shader_parameter("_mesh_size", _ocean_mesh_size);
				ocean_shader_mat->set_shader_parameter("_vertex_spacing", _ocean_vertex_spacing);
				ocean_shader_mat->set_shader_parameter("_vertex_density", 1.0f / _ocean_vertex_spacing);
				ocean_shader_mat->set_shader_parameter("_subdiv", pow(2.f, real_t(_ocean_tessellation_level)));
			}
		}
		_upload_wave_table();
	}
}

/**
 * Water shaders read their clock and sun from global shader uniforms, so one
 * write drives every water body in the scene (spec §2.3).
 *
 * The editor plugin persists these to project.godot, which is what makes them
 * exist at engine startup and therefore resolve in exported builds. This is the
 * fallback for the first run after enabling the plugin, and for projects where
 * the settings were never written. Phase 1 probes established the rules:
 *   - ProjectSettings::has_setting() is the only runtime-safe existence check.
 *     global_shader_parameter_get_list() and _get() are editor-only and error
 *     out in a game build.
 *   - Writing ProjectSettings at runtime does NOT register with RenderingServer;
 *     its global table is built from project.godot at startup and only then.
 */
void Pasture3D::_register_water_globals() {
	// Process-global, not per-node: the RenderingServer table is shared, so a
	// second Pasture3D in the scene must not try to add what the first already
	// added. There is no runtime-safe way to ask RenderingServer whether a
	// global exists -- global_shader_parameter_get_list() is editor-only -- so
	// the bookkeeping has to live here.
	static bool s_registered = false;
	if (s_registered) {
		return;
	}
	s_registered = true;
	_water_globals_registered = true;

	struct GlobalDecl {
		const char *name;
		RenderingServer::GlobalShaderParameterType type;
		Variant initial;
	};
	const GlobalDecl decls[] = {
		{ "water_time", RenderingServer::GLOBAL_VAR_TYPE_FLOAT, 0.0f },
		{ "water_sun_direction", RenderingServer::GLOBAL_VAR_TYPE_VEC3, Vector3(0.f, -1.f, 0.f) },
		{ "water_sun_color", RenderingServer::GLOBAL_VAR_TYPE_VEC3, Vector3(1.f, 1.f, 1.f) },
		// The clock's wrap period. The shader needs it, not just the clock:
		// anything else that advances with water_time -- the scrolling detail
		// texture (§3.3) -- has to quantise its own rate to the same loop or the
		// wrap that is seamless for the waves is a visible jump for the ripples.
		// Defaulted to WaterWaves' own default so a bare MeshInstance3D with no
		// Pasture3D in the scene (G6) still loops correctly.
		{ "water_time_period", RenderingServer::GLOBAL_VAR_TYPE_FLOAT, 120.0f },
	};
	ProjectSettings *settings = ProjectSettings::get_singleton();
	for (const GlobalDecl &decl : decls) {
		if (settings && settings->has_setting(String("shader_globals/") + decl.name)) {
			continue;
		}
		LOG(DEBUG, "Registering water shader global at runtime: ", decl.name);
		RS->global_shader_parameter_add(decl.name, decl.type, decl.initial);
	}
}

/**
 * Advances the shared water clock and wraps it to the wave table's loop period.
 *
 * Wavelengths are quantised so every wave completes a whole number of cycles in
 * that period (spec §3.2), which makes the wrap seamless and keeps the phase
 * argument bounded. The legacy shader's `TIME * 8.0` reached ~28,800 before
 * Godot's 3600 s rollover, at which point its noise quantised and the waves
 * visibly stepped.
 */
void Pasture3D::_update_water_clock(const double p_delta) {
	_water_time += p_delta;
	double period = (double)_ocean_waves.get_loop_period();
	if (period > 0.0) {
		_water_time = Math::fposmod(_water_time, period);
	}
	RS->global_shader_parameter_set("water_time", (float)_water_time);
	// Change-detected: the period only moves when an art knob does, and the
	// fragment stage divides by it every pixel, so a stale value is worse than
	// a redundant write is cheap.
	if (_water_time_period_sent != (float)period) {
		_water_time_period_sent = (float)period;
		RS->global_shader_parameter_set("water_time_period", (float)period);
	}
}

void Pasture3D::_upload_wave_table() {
	_ocean_waves.update();
	ShaderMaterial *mat = Object::cast_to<ShaderMaterial>(_ocean_material.ptr());
	if (mat) {
		mat->set_shader_parameter("_waves", _ocean_waves.get_shader_table());
		mat->set_shader_parameter("wave_steepness", _ocean_waves.get_steepness());
	}
	// A taller sea is a taller cull volume (spec §4.5).
	_update_ocean_aabbs();
}

/**
 * Reads a uniform off the ocean material, falling back to the value the shader
 * itself declares.
 *
 * ShaderMaterial only stores what was explicitly assigned, so an untouched
 * uniform reads back as nil -- which is indistinguishable from zero if you take
 * the Variant at face value, and zero is the wrong answer for anything whose
 * declared default is not zero. shader_get_parameter_default() asks the shader.
 */
Variant Pasture3D::_get_ocean_shader_param(const StringName &p_name) const {
	ShaderMaterial *mat = Object::cast_to<ShaderMaterial>(_ocean_material.ptr());
	if (!mat) {
		return Variant();
	}
	Variant value = mat->get_shader_parameter(p_name);
	if (value.get_type() != Variant::NIL) {
		return value;
	}
	Ref<Shader> shader = mat->get_shader();
	if (shader.is_valid()) {
		return RS->shader_get_parameter_default(shader->get_rid(), p_name);
	}
	return Variant();
}

real_t Pasture3D::_get_ocean_sea_level() const {
	Variant value = _get_ocean_shader_param("sea_level");
	// Absent for the non-clipmap variants, which have no sea_level at all: a lake
	// mesh's own transform is its height (§4.1). The ocean clipmap sheet is built
	// at y = 0, so zero is the right answer either way.
	return value.get_type() == Variant::NIL ? 0.f : (real_t)value;
}

Vector3 Pasture3D::_get_ocean_domain_origin() const {
	Variant value = _get_ocean_shader_param("_water_domain_origin");
	return value.get_type() == Variant::NIL ? V3_ZERO : (Vector3)value;
}

///////////////////////////
// CPU water query (spec §4.3)
///////////////////////////

Vector3 Pasture3D::get_water_surface_point(const Vector2 &p_domain_xz) const {
	Vector3 origin = _get_ocean_domain_origin();
	Vector3 local = _ocean_waves.get_position(p_domain_xz, (float)_water_time);
	// The shader displaces in domain space and adds nothing back: p_pos already
	// carried the origin, and only `domain` was shifted. Same here.
	return Vector3(local.x + origin.x, local.y + _get_ocean_sea_level(), local.z + origin.z);
}

real_t Pasture3D::get_water_height(const Vector2 &p_xz) const {
	Vector3 origin = _get_ocean_domain_origin();
	Vector2 target(p_xz.x - origin.x, p_xz.y - origin.z);
	Vector2 domain = _ocean_waves.solve_domain(target, (float)_water_time);
	return _get_ocean_sea_level() + (real_t)_ocean_waves.get_height(domain, (float)_water_time);
}

Vector3 Pasture3D::get_water_normal(const Vector2 &p_xz) const {
	Vector3 origin = _get_ocean_domain_origin();
	Vector2 target(p_xz.x - origin.x, p_xz.y - origin.z);
	Vector2 domain = _ocean_waves.solve_domain(target, (float)_water_time);
	return _ocean_waves.get_normal(domain, (float)_water_time);
}

/**
 * Sizes the ocean's cull AABB to where the water actually is (spec §4.5).
 *
 * This used to pass a zero height range, which put the y-extent at +/- the cull
 * margin around the WORLD ORIGIN rather than around the water. The demo's
 * sea_level of 5 fitted inside the default margin of 20 by luck; a sea level
 * outside the margin got the whole clipmap frustum-culled whenever the camera was
 * near the water, which is exactly when it matters.
 *
 * Both terms come from outside this node and neither emits a change signal --
 * sea_level is a uniform on the material, and the amplitude sum is a property of
 * the built wave table -- so this is called every physics frame and change-detects
 * before touching the RenderingServer. update_aabbs() walks every mesh RID.
 */
void Pasture3D::_update_ocean_aabbs(const bool p_force) {
	if (!_ocean_mesher) {
		return;
	}
	real_t sea_level = _get_ocean_sea_level();
	// The whole table crests together somewhere, so the extreme is the amplitude
	// SUM, not the amplitude knob (which is only the longest wave's). Understating
	// it here culls water that is on screen.
	real_t amplitude = (real_t)_ocean_waves.get_amplitude_sum();
	Vector2 range(sea_level - amplitude, sea_level + amplitude);
	if (!p_force && range == _ocean_height_range_sent) {
		return;
	}
	_ocean_height_range_sent = range;
	_ocean_mesher->update_aabbs(_ocean_cull_margin, range);
}

void Pasture3D::_destroy_ocean_mesher(const bool p_final) {
	LOG(INFO, "Destroying ocean mesher");
	if (_ocean_mesher) {
		_ocean_mesher->destroy();
		if (p_final) {
			delete _ocean_mesher;
			_ocean_mesher = nullptr;
		}
	}
}

void Pasture3D::_setup_displacement_buffer() {
	if (!is_inside_tree()) {
		LOG(ERROR, "Not inside the tree, skipping displacement buffer setup");
		return;
	}
	_destroy_displacement_buffer();
	LOG(INFO, "Setting up displacement buffer");
	_d_buffer_vp = memnew(SubViewport);
	_d_buffer_vp->set_name("DBufferViewport");
	add_child(_d_buffer_vp, true);
	_d_buffer_vp->set_size(Vector2i(2, 2));
	_d_buffer_vp->set_disable_3d(true);
	_d_buffer_vp->set_update_mode(SubViewport::UPDATE_ONCE);
	_d_buffer_vp->set_disable_input(true);
	_d_buffer_vp->set_default_canvas_item_texture_filter(Viewport::DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST);

	_d_buffer_rect = memnew(ColorRect);
	_d_buffer_rect->set_name("DBufferRect");
	_d_buffer_vp->add_child(_d_buffer_rect, true);
	_d_buffer_rect->set_anchors_preset(Control::PRESET_FULL_RECT);
}

void Pasture3D::_update_displacement_buffer() {
	if (!_d_buffer_vp) {
		return;
	}
	if (_tessellation_level == 0) {
		_d_buffer_vp->set_size(V2I_ZERO);
		_d_buffer_rect->set_size(V2I_ZERO);
	} else {
		_d_buffer_vp->set_size(Vector2i(_mesh_size * 4 * _tessellation_level, _mesh_size * 4));
		_d_buffer_rect->set_size(Vector2i(_mesh_size * 4 * _tessellation_level, _mesh_size * 4));
		LOG(INFO, "Updating displacement buffer to Size: ", _d_buffer_vp->get_size());
		if (_material.is_valid() && _material->get_material_rid().is_valid()) {
			RS->canvas_item_set_material(_d_buffer_rect->get_canvas_item(), _material->get_buffer_material_rid());
			RS->material_set_param(_material->get_material_rid(), "_displacement_buffer", _d_buffer_vp->get_texture()->get_rid());
		}
	}
}

void Pasture3D::_build_containers() {
	_label_parent = memnew(Node3D);
	_label_parent->set_name("Labels");
	add_child(_label_parent, true);
}

void Pasture3D::_destroy_containers() {
	memdelete_safely(_label_parent);
}

void Pasture3D::_destroy_labels() {
	Array labels = _label_parent->get_children();
	LOG(DEBUG, "Destroying ", labels.size(), " region labels");
	for (const Variant &var : labels) {
		Node *label = cast_to<Node>(var);
		memdelete_safely(label);
	}
}

void Pasture3D::_destroy_displacement_buffer() {
	LOG(DEBUG, "Freeing d_buffer_rect");
	memdelete_safely(_d_buffer_rect);
	LOG(DEBUG, "Freeing d_buffer_vp");
	memdelete_safely(_d_buffer_vp);
}

void Pasture3D::_setup_mouse_picking() {
	if (!is_inside_tree()) {
		LOG(ERROR, "Not inside the tree, skipping mouse setup");
		return;
	}
	LOG(INFO, "Setting up mouse picker and get_intersection viewport, camera & screen quad");
	_mouse_vp = memnew(SubViewport);
	_mouse_vp->set_name("MouseViewport");
	add_child(_mouse_vp, true);
	_mouse_vp->set_size(V2I(2));
	_mouse_vp->set_scaling_3d_mode(Viewport::SCALING_3D_MODE_BILINEAR);
	_mouse_vp->set_update_mode(SubViewport::UPDATE_ONCE);
	_mouse_vp->set_disable_input(true);
	_mouse_vp->set_canvas_cull_mask(0);
	_mouse_vp->set_use_hdr_2d(true);
	_mouse_vp->set_anisotropic_filtering_level(Viewport::ANISOTROPY_DISABLED);
	_mouse_vp->set_default_canvas_item_texture_filter(Viewport::DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST);
	_mouse_vp->set_positional_shadow_atlas_size(0);
	_mouse_vp->set_positional_shadow_atlas_quadrant_subdiv(0, Viewport::SHADOW_ATLAS_QUADRANT_SUBDIV_DISABLED);
	_mouse_vp->set_positional_shadow_atlas_quadrant_subdiv(1, Viewport::SHADOW_ATLAS_QUADRANT_SUBDIV_DISABLED);
	_mouse_vp->set_positional_shadow_atlas_quadrant_subdiv(2, Viewport::SHADOW_ATLAS_QUADRANT_SUBDIV_DISABLED);
	_mouse_vp->set_positional_shadow_atlas_quadrant_subdiv(3, Viewport::SHADOW_ATLAS_QUADRANT_SUBDIV_DISABLED);

	_mouse_cam = memnew(Camera3D);
	_mouse_cam->set_name("MouseCamera");
	_mouse_vp->add_child(_mouse_cam, true);
	Ref<Environment> env;
	env.instantiate();
	env->set_tonemapper(Environment::TONE_MAPPER_LINEAR);
	_mouse_cam->set_environment(env);
	Ref<Compositor> comp;
	comp.instantiate();
	_mouse_cam->set_compositor(comp);
	_mouse_cam->set_projection(Camera3D::PROJECTION_ORTHOGONAL);
	_mouse_cam->set_size(0.1f);
	_mouse_cam->set_far(100000.f);

	_mouse_quad = memnew(MeshInstance3D);
	_mouse_quad->set_name("MouseQuad");
	_mouse_cam->add_child(_mouse_quad, true);
	Ref<QuadMesh> quad;
	quad.instantiate();
	quad->set_size(V2(0.1f));
	_mouse_quad->set_mesh(quad);
	String shader_code = String(
#include "shaders/gpu_depth.glsl"
	);
	Ref<Shader> shader;
	shader.instantiate();
	shader->set_code(shader_code);
	Ref<ShaderMaterial> shader_material;
	shader_material.instantiate();
	shader_material->set_shader(shader);
	_mouse_quad->set_surface_override_material(0, shader_material);
	_mouse_quad->set_position(Vector3(0.f, 0.f, -0.5f));

	// Set terrain, terrain shader, mouse camera, and screen quad to mouse layer
	uint32_t force_update_layer = _mouse_layer;
	_mouse_layer = 0u;
	set_mouse_layer(force_update_layer);
}

void Pasture3D::_destroy_mouse_picking() {
	LOG(DEBUG, "Freeing mouse_quad");
	memdelete_safely(_mouse_quad);
	LOG(DEBUG, "Freeing mouse_cam");
	memdelete_safely(_mouse_cam);
	LOG(DEBUG, "Freeing mouse_vp");
	memdelete_safely(_mouse_vp);
}

void Pasture3D::_destroy_instancer() {
	LOG(INFO, "Destroying Instancer");
	memdelete_safely(_instancer);
}

void Pasture3D::_generate_triangles(PackedVector3Array &p_vertices, PackedVector2Array *p_uvs, const int32_t p_lod,
		const Pasture3DData::HeightFilter p_filter, const bool p_require_nav, const AABB &p_global_aabb) const {
	ERR_FAIL_COND(_data == nullptr);
	int32_t step = 1 << CLAMP(p_lod, 0, 8);

	// Bake whole mesh, e.g. bake_mesh and painted navigation
	if (!p_global_aabb.has_volume()) {
		int32_t region_size = (int32_t)_region_size;

		TypedArray<Vector2i> region_locations = _data->get_region_locations();
		for (const Vector2i &region_loc : region_locations) {
			Vector2i region_pos = region_loc * region_size;
			for (int32_t z = region_pos.y; z < region_pos.y + region_size; z += step) {
				for (int32_t x = region_pos.x; x < region_pos.x + region_size; x += step) {
					_generate_triangle_pair(p_vertices, p_uvs, p_lod, p_filter, p_require_nav, x, z);
				}
			}
		}
	} else {
		// Bake within an AABB, e.g. runtime navigation baker
		int32_t z_start = (int32_t)Math::ceil(p_global_aabb.position.z / _vertex_spacing);
		int32_t z_end = (int32_t)Math::floor(p_global_aabb.get_end().z / _vertex_spacing) + 1;
		int32_t x_start = (int32_t)Math::ceil(p_global_aabb.position.x / _vertex_spacing);
		int32_t x_end = (int32_t)Math::floor(p_global_aabb.get_end().x / _vertex_spacing) + 1;

		for (int32_t z = z_start; z < z_end; ++z) {
			for (int32_t x = x_start; x < x_end; ++x) {
				real_t height = _data->get_height(Vector3(x, 0.f, z));
				if (height >= p_global_aabb.position.y && height <= p_global_aabb.get_end().y) {
					_generate_triangle_pair(p_vertices, p_uvs, p_lod, p_filter, p_require_nav, x, z);
				}
			}
		}
	}
}

// Generates two triangles: Top 124, Bottom 143
//		1  __  2
//		  |\ |
//		  | \|
//		3  --  4
// p_vertices is assumed to exist and the destination for data
// p_uvs might not exist, so a pointer is fine
// p_require_nav is false for the runtime baker, which ignores navigation
void Pasture3D::_generate_triangle_pair(PackedVector3Array &p_vertices, PackedVector2Array *p_uvs,
		const int32_t p_lod, const Pasture3DData::HeightFilter p_filter, const bool p_require_nav,
		const int32_t x, const int32_t z) const {
	int32_t step = 1 << CLAMP(p_lod, 0, 8);
	Vector3 xz = Vector3(x, 0.0f, z) * _vertex_spacing;
	Vector3 xsz = Vector3(x + step, 0.0f, z) * _vertex_spacing;
	Vector3 xzs = Vector3(x, 0.0f, z + step) * _vertex_spacing;
	Vector3 xszs = Vector3(x + step, 0.0f, z + step) * _vertex_spacing;
	Vector3 v1 = _data->get_mesh_vertex(p_lod, p_filter, xz);
	bool nan1 = std::isnan(v1.y);
	if (nan1) {
		return;
	}
	Vector3 v2 = _data->get_mesh_vertex(p_lod, p_filter, xsz);
	Vector3 v3 = _data->get_mesh_vertex(p_lod, p_filter, xzs);
	Vector3 v4 = _data->get_mesh_vertex(p_lod, p_filter, xszs);
	bool nan2 = std::isnan(v2.y);
	bool nan3 = std::isnan(v3.y);
	bool nan4 = std::isnan(v4.y);
	// If on the region edge, duplicate the edge pixels
	// Check #2 upper right
	if (nan2) {
		v2.y = v1.y;
	}
	// Check #3 lower left
	if (nan3) {
		v3.y = v1.y;
	}
	// Check #4 lower right
	if (nan4) {
		if (!nan2) {
			v4.y = v2.y;
		} else if (!nan3) {
			v4.y = v3.y;
		} else {
			v4.y = v1.y;
		}
	}
	uint32_t ctrl1 = _data->get_control(xz);
	uint32_t ctrl2 = _data->get_control(xsz);
	uint32_t ctrl3 = _data->get_control(xzs);
	uint32_t ctrl4 = _data->get_control(xszs);
	// Holes are only where the control map is valid and the bit is set
	bool hole1 = ctrl1 != UINT32_MAX && is_hole(ctrl1);
	bool hole2 = ctrl2 != UINT32_MAX && is_hole(ctrl2);
	bool hole3 = ctrl3 != UINT32_MAX && is_hole(ctrl3);
	bool hole4 = ctrl4 != UINT32_MAX && is_hole(ctrl4);
	// Navigation is where the control map is valid and the bit is set, or it's the region edge and nav1 is set
	bool nav1 = ctrl1 != UINT32_MAX && is_nav(ctrl1);
	bool nav2 = ctrl2 != UINT32_MAX && is_nav(ctrl2) || nan2 && nav1;
	bool nav3 = ctrl3 != UINT32_MAX && is_nav(ctrl3) || nan3 && nav1;
	bool nav4 = ctrl4 != UINT32_MAX && is_nav(ctrl4) || nan4 && nav1;
	//Bottom 143 triangle
	if (!(hole1 || hole4 || hole3) && (!p_require_nav || (nav1 && nav4 && nav3))) {
		p_vertices.push_back(v1);
		p_vertices.push_back(v4);
		p_vertices.push_back(v3);
		if (p_uvs) {
			p_uvs->push_back(Vector2(v1.x, v1.z));
			p_uvs->push_back(Vector2(v4.x, v4.z));
			p_uvs->push_back(Vector2(v3.x, v3.z));
		}
	}
	// Top 124 triangle
	if (!(hole1 || hole2 || hole4) && (!p_require_nav || (nav1 && nav2 && nav4))) {
		p_vertices.push_back(v1);
		p_vertices.push_back(v2);
		p_vertices.push_back(v4);
		if (p_uvs) {
			p_uvs->push_back(Vector2(v1.x, v1.z));
			p_uvs->push_back(Vector2(v2.x, v2.z));
			p_uvs->push_back(Vector2(v4.x, v4.z));
		}
	}
}

///////////////////////////
// Public Functions
///////////////////////////

Pasture3D::Pasture3D() {
	LOG(INFO, "Pasture3D v", _version, " - https://github.com/TokisanGames/Pasture3D");
	// Build the wave table once up front so it is never in the unbuilt state a
	// dirty flag implies. Every knob setter rebuilds it, but a get_water_height()
	// on a node whose knobs were all left at their defaults would otherwise read a
	// zero-amplitude table and report flat water (spec §4.3).
	_ocean_waves.update();
	// Process the command line
	PackedStringArray args = OS::get_singleton()->get_cmdline_args();
	for (int i = args.size() - 1; i >= 0; i--) {
		String arg = args[i];
		if (arg.begins_with("--pasture3d-debug=")) {
			String value = arg.rsplit("=")[1];
			if (value == "ERROR") {
				set_debug_level(ERROR);
			} else if (value == "INFO") {
				set_debug_level(INFO);
			} else if (value == "DEBUG") {
				set_debug_level(DEBUG);
			} else if (value == "EXTREME") {
				set_debug_level(EXTREME);
			}
		}
	}
}

void Pasture3D::set_debug_level(const DebugLevel p_level) {
	SET_IF_DIFF(debug_level, CLAMP(p_level, ERROR, EXTREME));
	LOG(INFO, "Setting debug level: ", debug_level);
}

void Pasture3D::set_data_directory(String p_dir) {
	String old_dir = _data_directory;
	SET_IF_DIFF(_data_directory, p_dir);
	LOG(INFO, "Setting data directory to ", _data_directory);
	// If _data_directory was empty and now specified, and has no data
	// assume we want to retain the current data.
	// Otherwise, clear data and reload dir
	if (!old_dir.is_empty() || Util::get_files(p_dir, "pasture3d*.res").size() > 0) {
		_initialized = false;
		_destroy_labels();
		_destroy_collision();
		_destroy_instancer();
		memdelete_safely(_data);
		_initialize();
	}
	update_configuration_warnings();
}

void Pasture3D::set_assets(const Ref<Pasture3DAssets> &p_assets) {
	SET_IF_DIFF(_assets, p_assets);
	LOG(INFO, "Setting asset list");
	_initialized = false;
	_initialize();
	LOG(DEBUG, "Emitting assets_changed");
	emit_signal("assets_changed");
}

void Pasture3D::set_editor(Pasture3DEditor *p_editor) {
	if (p_editor && p_editor->is_queued_for_deletion()) {
		LOG(ERROR, "Attempted to set a node queued for deletion");
		return;
	}
	SET_IF_DIFF(_editor, p_editor);
	LOG(INFO, "Setting Pasture3DEditor: ", _editor);
	if (_material.is_valid()) {
		_material->update(Pasture3DMaterial::FULL_REBUILD);
	}
}

void Pasture3D::set_plugin(Object *p_plugin) {
	if (p_plugin && p_plugin->is_queued_for_deletion()) {
		LOG(ERROR, "Attempted to set a node queued for deletion");
		return;
	}
	SET_IF_DIFF(_editor_plugin, p_plugin);
	LOG(INFO, "Setting Editor Plugin: ", _editor_plugin);
}

void Pasture3D::set_region_size(const RegionSize p_size) {
	if (!is_valid_region_size(p_size)) {
		LOG(ERROR, "Invalid region size: ", p_size, ". Must be power of 2, 64-2048");
		return;
	}
	SET_IF_DIFF(_region_size, p_size);
	LOG(INFO, "Setting region size: ", _region_size);
	if (_data) {
		_data->_region_size = _region_size;
		_data->_region_sizev = V2I(_region_size);
	}
	if (_material.is_valid()) {
		_material->update();
	}
	_update_displacement_buffer();
}

void Pasture3D::set_save_16_bit(const bool p_enabled) {
	SET_IF_DIFF(_save_16_bit, p_enabled);
	LOG(INFO, "Save heightmaps as 16-bit: ", _save_16_bit);
	TypedArray<Pasture3DRegion> regions = _data->get_regions_active();
	for (Ref<Pasture3DRegion> region : regions) {
		region->set_modified(true);
	}
}

void Pasture3D::set_label_distance(const real_t p_distance) {
	SET_IF_DIFF(_label_distance, CLAMP(p_distance, 0.f, 100000.f));
	LOG(INFO, "Setting region label distance: ", _label_distance);
	update_region_labels();
}

void Pasture3D::set_label_size(const int p_size) {
	SET_IF_DIFF(_label_size, CLAMP(p_size, 24, 128));
	LOG(INFO, "Setting region label size: ", _label_size);
	update_region_labels();
}

void Pasture3D::update_region_labels() {
	_destroy_labels();
	if (_label_distance > 0.f && _data) {
		TypedArray<Vector2i> region_locations = _data->get_region_locations();
		LOG(DEBUG, "Creating ", region_locations.size(), " region labels");
		for (const Vector2i &region_loc : region_locations) {
			Label3D *label = memnew(Label3D);
			String text = region_loc;
			label->set_name("Label3D" + text.replace(" ", ""));
			label->set_pixel_size(.001f);
			label->set_billboard_mode(BaseMaterial3D::BILLBOARD_ENABLED);
			label->set_draw_flag(Label3D::FLAG_DOUBLE_SIDED, true);
			label->set_draw_flag(Label3D::FLAG_DISABLE_DEPTH_TEST, true);
			label->set_draw_flag(Label3D::FLAG_FIXED_SIZE, true);
			label->set_render_priority(127);
			label->set_outline_render_priority(126);
			label->set_text(text);
			label->set_modulate(Color(1.f, 1.f, 1.f, .5f));
			label->set_outline_modulate(Color(0.f, 0.f, 0.f, .5f));
			label->set_font_size(_label_size);
			label->set_outline_size(_label_size / 6);
			label->set_visibility_range_end(_label_distance);
			label->set_visibility_range_end_margin(_label_distance / 10.f);
			label->set_visibility_range_fade_mode(GeometryInstance3D::VISIBILITY_RANGE_FADE_SELF);
			_label_parent->add_child(label, true);
			Vector3 pos = Vector3(real_t(region_loc.x) + .5f, 0.f, real_t(region_loc.y) + .5f) * _region_size * _vertex_spacing;
			real_t height = _data->get_height(pos);
			pos.y = (std::isnan(height)) ? 0.f : height;
			label->set_position(pos);
		}
	}
}

void Pasture3D::set_camera(Camera3D *p_camera) {
	if (_camera.ptr() != p_camera) {
		LOG(EXTREME, "Setting camera: ", p_camera);
		_camera.set_target(p_camera);
	}
	// Re-arm clipmap tracking even if we previously gave up (node loaded camera-less and
	// _grab_camera called set_physics_process(false)). Prime a re-snap so the terrain re-centers
	// on the next physics frame instead of staying flat/dark. Kept outside the "changed" guard so
	// re-setting the same camera after a give-up also recovers.
	if (_camera.is_valid() || _clipmap_target.is_valid()) {
		snap();
		set_physics_process(true);
	}
}

void Pasture3D::set_cameras(const TypedArray<Camera3D> &p_cameras) {
	// 0 or 1 cameras => single-view path: behaves exactly like set_camera(). Solo / online / editor
	// are unchanged. Only 2+ cameras enable per-camera split-screen clipmaps.
	if (p_cameras.size() <= 1) {
		_cameras.clear();
		if (p_cameras.size() == 1) {
			set_camera(cast_to<Camera3D>(p_cameras[0]));
		}
		_apply_cameras_to_mesher();
		return;
	}

	LOG(INFO, "Setting ", p_cameras.size(), " cameras for split-screen clipmap rendering");
	if (p_cameras.size() > 4) {
		LOG(WARN, "More than 4 cameras set; only the reserved top 4 layers (17-20) map to players");
	}
	_cameras.clear();
	for (int i = 0; i < p_cameras.size(); i++) {
		Camera3D *cam = cast_to<Camera3D>(p_cameras[i]);
		if (cam) {
			_cameras.push_back(cam->get_instance_id());
		}
	}
	// Keep a valid fallback camera (used by collision / clipmap-target fallback and to keep the
	// physics process alive). The first camera serves as that fallback.
	if (!_cameras.is_empty()) {
		set_camera(cast_to<Camera3D>(ObjectDB::get_instance(_cameras[0])));
	}
	_apply_cameras_to_mesher();
	set_physics_process(true);
}

TypedArray<Camera3D> Pasture3D::get_cameras() const {
	TypedArray<Camera3D> cameras;
	if (!_cameras.is_empty()) {
		for (const uint64_t &id : _cameras) {
			Camera3D *cam = cast_to<Camera3D>(ObjectDB::get_instance(id));
			if (cam) {
				cameras.push_back(cam);
			}
		}
	} else if (Camera3D *cam = get_camera()) {
		cameras.push_back(cam);
	}
	return cameras;
}

void Pasture3D::set_clipmap_target(Node3D *p_node) {
	if (_clipmap_target.ptr() != p_node) {
		LOG(INFO, "Setting clipmap target: ", p_node);
		_clipmap_target.set_target(p_node);
		if (_clipmap_target.is_valid()) {
			set_physics_process(true);
		}
	}
}

Vector3 Pasture3D::get_clipmap_target_position() const {
	// In Editor, or no clipmap target, use camera
	if (IS_EDITOR || !_clipmap_target.get_target()) {
		if (Node3D *cam = _camera.get_target()) {
			return cam->get_global_position();
		}
	}
	if (Node3D *target = _clipmap_target.get_target()) {
		return target->get_global_position();
	}
	return V3_ZERO;
}

void Pasture3D::set_collision_target(Node3D *p_node) {
	if (_collision_target.ptr() != p_node) {
		LOG(INFO, "Setting collision target: ", p_node);
		_collision_target.set_target(p_node);
		if (_collision_target.is_valid()) {
			set_physics_process(true);
		}
	}
}

Vector3 Pasture3D::get_collision_target_position() const {
	// In Editor, always prefer camera
	if (IS_EDITOR) {
		if (Node3D *cam = _camera.get_target()) {
			return cam->get_global_position();
		}
	}
	if (Node3D *target = _collision_target.get_target()) {
		return target->get_global_position();
	}
	if (Node3D *target = _clipmap_target.get_target()) {
		return target->get_global_position();
	}
	if (Node3D *cam = _camera.get_target()) {
		return cam->get_global_position();
	}
	return V3_ZERO;
}

void Pasture3D::set_ocean_light_target(Node3D *p_node) {
	if (_ocean_light_target.ptr() != p_node) {
		LOG(INFO, "Setting directional light target: ", p_node);
		_ocean_light_target.set_target(p_node);
		if (_ocean_light_target.is_valid()) {
			set_physics_process(true);
		}
	}
}

void Pasture3D::snap() {
	if (_terrain_mesher) {
		_terrain_mesher->reset_target_position();
	}
	if (_ocean_enabled && _ocean_mesher) {
		_ocean_mesher->reset_target_position();
	}
	if (_collision) {
		_collision->reset_target_position();
	}
	if (_tessellation_level > 0) {
		_last_buffer_position = V2_MAX;
	}
}

void Pasture3D::set_material(const Ref<Pasture3DMaterial> &p_material) {
	SET_IF_DIFF(_material, p_material);
	LOG(INFO, "Setting material");
	_initialized = false;
	_initialize();
	LOG(DEBUG, "Emitting material_changed");
	emit_signal("material_changed");
}

void Pasture3D::set_mesh_lods(const int p_count) {
	SET_IF_DIFF(_mesh_lods, CLAMP(p_count, 1, 10));
	LOG(INFO, "Setting mesh levels: ", _mesh_lods);
	if (_terrain_mesher && _material.is_valid()) {
		_material->update();
		_setup_terrain_mesher();
	}
}

void Pasture3D::set_tessellation_level(const int p_level) {
	SET_IF_DIFF(_tessellation_level, CLAMP(p_level, 0, 6));
	LOG(INFO, "Setting tessellation level: ", p_level);
	if (_terrain_mesher && _material.is_valid()) {
		_material->update(Pasture3DMaterial::FULL_REBUILD);
		_setup_terrain_mesher();
		_update_displacement_buffer();
	}
	notify_property_list_changed();
}

void Pasture3D::set_mesh_size(const int p_size) {
	SET_IF_DIFF(_mesh_size, CLAMP(p_size & ~1, 8, 256)); // Ensure even
	LOG(INFO, "Setting mesh size: ", _mesh_size);
	if (_terrain_mesher && _material.is_valid()) {
		_material->update();
		_setup_terrain_mesher();
		_update_displacement_buffer();
	}
}

void Pasture3D::set_vertex_spacing(const real_t p_spacing) {
	SET_IF_DIFF(_vertex_spacing, CLAMP(p_spacing, 0.25f, 100.0f));
	LOG(INFO, "Setting vertex spacing: ", _vertex_spacing);
	if (_collision && _data && _instancer && _material.is_valid()) {
		_instancer->_update_vertex_spacing(_vertex_spacing);
		_data->_vertex_spacing = _vertex_spacing;
		update_region_labels();
		_material->update();
		_setup_terrain_mesher();
		_collision->destroy();
		_collision->build();
		_update_displacement_buffer();
	}
}

void Pasture3D::set_cull_margin(const real_t p_margin) {
	SET_IF_DIFF(_cull_margin, CLAMP(p_margin, 0.f, 100000.f));
	LOG(INFO, "Setting extra cull margin: ", _cull_margin);
	if (_terrain_mesher) {
		_terrain_mesher->update_aabbs();
	}
}

void Pasture3D::set_cast_shadows(const RenderingServer::ShadowCastingSetting p_cast_shadows) {
	SET_IF_DIFF(_cast_shadows, p_cast_shadows);
	if (_terrain_mesher) {
		_terrain_mesher->set_cast_shadows(_cast_shadows);
		_terrain_mesher->update();
	}
}

void Pasture3D::set_gi_mode(const GeometryInstance3D::GIMode p_gi_mode) {
	SET_IF_DIFF(_gi_mode, p_gi_mode);
	if (_terrain_mesher) {
		_terrain_mesher->set_gi_mode(_gi_mode);
		_terrain_mesher->update();
	}
}

void Pasture3D::set_render_layers(const uint32_t p_layers) {
	SET_IF_DIFF(_render_layers, p_layers);
	LOG(INFO, "Setting terrain render layers to: ", p_layers);
	if (_terrain_mesher) {
		// Default (single) views follow this; camera-bound split-screen views keep their per-player
		// layers assigned in set_cameras().
		_terrain_mesher->set_render_layers(p_layers);
		_terrain_mesher->update();
	}
}

void Pasture3D::set_ocean_enabled(const bool p_enabled) {
	SET_IF_DIFF(_ocean_enabled, p_enabled);
	LOG(INFO, "Setting ocean enabled: ", _ocean_enabled);
	if (_ocean_enabled) {
		if (_ocean_material.is_null()) {
			String ocean_mat_path = ProjectSettings::get_singleton()->globalize_path(OCEAN_MATERIAL_PATH);
			ResourceLoader *rl = ResourceLoader::get_singleton();
			if (rl->exists(ocean_mat_path)) {
				Ref<ShaderMaterial> ocean_mat = rl->load(ocean_mat_path);
				if (ocean_mat.is_valid()) {
					_ocean_material = ocean_mat;
				}
			}
		}
		_setup_ocean_mesher();
	} else {
		_destroy_ocean_mesher(false);
	}
	notify_property_list_changed();
}

void Pasture3D::set_ocean_mesh_lods(const int p_count) {
	SET_IF_DIFF(_ocean_mesh_lods, CLAMP(p_count, 1, 10));
	LOG(INFO, "Setting ocean mesh levels: ", _ocean_mesh_lods);
	if (_ocean_enabled) {
		_setup_ocean_mesher();
	}
}

void Pasture3D::set_ocean_tessellation_level(const int p_level) {
	SET_IF_DIFF(_ocean_tessellation_level, CLAMP(p_level, 0, 6));
	LOG(INFO, "Setting ocean tessellation level: ", p_level);
	if (_ocean_enabled) {
		_setup_ocean_mesher();
	}
}

void Pasture3D::set_ocean_mesh_size(const int p_size) {
	SET_IF_DIFF(_ocean_mesh_size, CLAMP(p_size & ~1, 8, 256)); // Ensure even
	LOG(INFO, "Setting ocean mesh size: ", _ocean_mesh_size);
	if (_ocean_enabled) {
		_setup_ocean_mesher();
	}
}

void Pasture3D::set_ocean_vertex_spacing(const real_t p_spacing) {
	SET_IF_DIFF(_ocean_vertex_spacing, CLAMP(p_spacing, 0.25f, 100.0f));
	LOG(INFO, "Setting ocean vertex spacing: ", _ocean_vertex_spacing);
	if (_ocean_enabled) {
		_setup_ocean_mesher();
	}
}

void Pasture3D::set_ocean_cull_margin(const real_t p_margin) {
	SET_IF_DIFF(_ocean_cull_margin, CLAMP(p_margin, 0.f, 100000.f));
	LOG(INFO, "Setting extra cull margin: ", _ocean_cull_margin);
	_update_ocean_aabbs(true);
}

void Pasture3D::set_ocean_cast_shadows(const RenderingServer::ShadowCastingSetting p_cast_shadows) {
	SET_IF_DIFF(_ocean_cast_shadows, p_cast_shadows);
	if (_ocean_mesher) {
		_ocean_mesher->set_cast_shadows(_ocean_cast_shadows);
		_ocean_mesher->update();
	}
}

void Pasture3D::set_ocean_gi_mode(const GeometryInstance3D::GIMode p_gi_mode) {
	SET_IF_DIFF(_ocean_gi_mode, p_gi_mode);
	if (_ocean_mesher) {
		_ocean_mesher->set_gi_mode(_ocean_gi_mode);
		_ocean_mesher->update();
	}
}

void Pasture3D::set_ocean_render_layers(const uint32_t p_layers) {
	SET_IF_DIFF(_ocean_render_layers, p_layers);
	LOG(INFO, "Setting ocean render layers to: ", p_layers);
	if (_ocean_enabled) {
		_setup_ocean_mesher();
	}
}

void Pasture3D::set_ocean_material(const Ref<Material> &p_material) {
	SET_IF_DIFF(_ocean_material, p_material);
	LOG(INFO, "Setting ocean material");
	// New material, new variant wave count and new sea_level; both are read back
	// off it rather than owned here.
	update_configuration_warnings();
	if (_ocean_enabled) {
		_setup_ocean_mesher();
	}
}

// Wave knobs. Each rebuilds the table and re-uploads; WaterWaves change-detects
// internally, so setting a knob to its current value costs nothing.

void Pasture3D::set_ocean_wave_count(const int p_count) {
	_ocean_waves.set_count(p_count);
	// May have crossed the material variant's WATER_WAVE_COUNT; see
	// _get_configuration_warnings().
	update_configuration_warnings();
	_upload_wave_table();
}

void Pasture3D::set_ocean_wave_direction(const real_t p_degrees) {
	_ocean_waves.set_direction_deg((float)p_degrees);
	_upload_wave_table();
}

void Pasture3D::set_ocean_wave_spread(const real_t p_degrees) {
	_ocean_waves.set_spread_deg((float)p_degrees);
	_upload_wave_table();
}

void Pasture3D::set_ocean_wave_amplitude(const real_t p_metres) {
	_ocean_waves.set_amplitude((float)p_metres);
	_upload_wave_table();
}

void Pasture3D::set_ocean_wave_length_max(const real_t p_metres) {
	_ocean_waves.set_length_max((float)p_metres);
	_upload_wave_table();
}

void Pasture3D::set_ocean_wave_steepness(const real_t p_steepness) {
	_ocean_waves.set_steepness((float)p_steepness);
	_upload_wave_table();
}

void Pasture3D::set_ocean_wave_loop_period(const real_t p_seconds) {
	_ocean_waves.set_loop_period((float)p_seconds);
	_upload_wave_table();
}

void Pasture3D::set_mouse_layer(const uint32_t p_layer) {
	SET_IF_DIFF(_mouse_layer, CLAMP(p_layer, 21, 32));
	uint32_t mouse_mask = 1 << (_mouse_layer - 1);
	LOG(INFO, "Setting mouse layer: ", _mouse_layer, " (", mouse_mask,
			") on terrain mesh, material, mouse camera, mouse quad");

	// Set terrain meshes to mouse layer
	// Mask off editor render layers by ORing user layers 1-20 and current mouse layer
	set_render_layers((_render_layers & 0xFFFFF) | mouse_mask);
	// Set terrain shader to exclude mouse camera from showing holes
	if (_material.is_valid()) {
		_material->set_shader_param("_mouse_layer", mouse_mask);
	}
	// Set mouse camera to see only mouse layer
	if (_mouse_cam) {
		_mouse_cam->set_cull_mask(mouse_mask);
	}
	// Set screenquad to mouse layer
	if (_mouse_quad) {
		_mouse_quad->set_layer_mask(mouse_mask);
	}
}

/* Returns the point a ray intersects the ground using either raymarching or the GPU depth texture
 *	p_src_pos (camera position)
 *	p_direction (camera direction looking at the terrain)
 *  p_gpu_mode - false: use raymarching, true: use GPU mode
 * Returns Vec3(NAN) on error or vec3(3.402823466e+38F) on no intersection. Test w/ if (var.x < 3.4e38)
 */
Vector3 Pasture3D::get_intersection(const Vector3 &p_src_pos, const Vector3 &p_direction, const bool p_gpu_mode) {
	if (p_direction.is_zero_approx() || !p_direction.is_finite()) {
		LOG(ERROR, "Invalid direction vector: ", p_direction);
		return V3_NAN;
	}
	if (!p_src_pos.is_finite()) {
		LOG(ERROR, "Invalid source vector: ", p_src_pos);
		return V3_NAN;
	}

	Vector3 direction = p_direction.normalized();
	// If looking straight down in a region, use get_height
	if (direction.y < -.99999f) {
		real_t height = _data->get_height(p_src_pos);
		if (std ::isfinite(height)) {
			return Vector3(p_src_pos.x, height, p_src_pos.z);
		}
	}

	// Raymarching mode
	if (!p_gpu_mode) {
		// Must start above terrain if in a region
		real_t height = _data->get_height(p_src_pos);
		if (height > p_src_pos.y) { // False if Nan
			return V3_MAX;
		}
		// Raymarch down the ray in small increments until we find the terrain height
		Vector3 point = p_src_pos;
		for (int i = 0; i < 4000; i++) {
			height = _data->get_height(point);
			if (point.y - height <= 0.f) { // Nan comparison is false, which continues loop
				return point;
			}
			point += direction;
		}
		return V3_MAX;

	} else {
		// Get depth from perspective camera snapshot
		if (!_mouse_cam) {
			LOG(ERROR, "Invalid mouse camera");
			return V3_NAN;
		}
		// Position mouse cam one unit behind the requested position
		_mouse_cam->set_global_position(p_src_pos - direction);

		// If looking straight down, then we're not in a region, set rotation directly as look_at() doesn't work
		if (direction.y < -.99999f) {
			_mouse_cam->set_rotation_degrees(Vector3(-90.f, 0.f, 0.f));
		} else {
			_mouse_cam->look_at(_mouse_cam->get_global_position() + direction, V3_UP);
		}

		_mouse_vp->set_update_mode(SubViewport::UPDATE_ONCE);
		Ref<ViewportTexture> vp_tex = _mouse_vp->get_texture();
		Ref<Image> vp_img = vp_tex->get_image();

		// Read the depth pixel from the camera viewport
		Color screen_depth = vp_img->get_pixel(0, 0);

		// Get position from depth packed in RGB - unpack back to float.
		// Forward+ is 16bit, mobile and compatibility is 10bit.
		// Compatibility also has precision loss for values below 0.5, so
		// we use only the top half of the range, for 21bit depth encoded.
		real_t r = floor((screen_depth.r * 256.f) - 128.f);
		real_t g = floor((screen_depth.g * 256.f) - 128.f);
		real_t b = floor((screen_depth.b * 256.f) - 128.f);

		// Decode the full depth value
		real_t decoded_depth = (r + g / 127.f + b / (127.f * 127.f)) / 127.f;

		// Near-plane noise filter, or no hit (sky, underside, far clip)
		if (decoded_depth < 0.00001f || decoded_depth > 1.f) {
			// Catch editor ortho camera with src_pos.y at some random value around 500k
			if (direction.y < -.99999f && p_src_pos.y >= 100000.f) {
				return Vector3(p_src_pos.x, 0.f, p_src_pos.z);
			}
			return V3_MAX;
		}

		// Necessary for a near-far precision on hits
		if (decoded_depth > 0.99999f) {
			decoded_depth = 1.f;
		}

		// Denormalize distance to get real depth and terrain position.
		decoded_depth *= _mouse_cam->get_far();

		// Project the camera position by the depth value to get the intersection point.
		return _mouse_cam->get_global_position() + direction * decoded_depth;
	}
}

/* Returns the results of a physics raycast, optionally excluding the terrain
 *	p_src_pos (ray start position)
 *	p_direction (ray direction * magnitude), relative to src_pos
 */
Dictionary Pasture3D::get_raycast_result(const Vector3 &p_src_pos, const Vector3 &p_direction, const uint32_t p_col_mask, const bool p_exclude_self) const {
	if (!_is_inside_world) {
		return Dictionary();
	}
	PhysicsDirectSpaceState3D *space_state = get_world_3d()->get_direct_space_state();
	if (!space_state) {
		LOG(ERROR, "Invalid PhysicsDirectSpaceState3D");
		return Dictionary();
	}
	Ref<PhysicsRayQueryParameters3D> query = PhysicsRayQueryParameters3D::create(p_src_pos, p_src_pos + p_direction, p_col_mask);
	if (_collision && p_exclude_self) {
		query->set_exclude(TypedArray<RID>(_collision->get_rid()));
	}
	return space_state->intersect_ray(query);
}

/**
 * Generates a static ArrayMesh for the terrain.
 * p_lod (0-8): Determines the granularity of the generated mesh.
 * p_filter: Controls how vertices' Y coordinates are generated from the height map.
 *  HEIGHT_FILTER_NEAREST: Samples the height map in a 'nearest neighbour' fashion.
 *  HEIGHT_FILTER_MINIMUM: Samples a range of heights around each vertex and returns the lowest.
 *   This takes longer than ..._NEAREST, but can be used to create occluders, since it can guarantee the
 *   generated mesh will not extend above or outside the clipmap at any LOD.
 */
Ref<Mesh> Pasture3D::bake_mesh(const int p_lod, const Pasture3DData::HeightFilter p_filter) const {
	LOG(INFO, "Baking mesh at lod: ", p_lod, " with filter: ", p_filter);
	Ref<Mesh> result;
	ERR_FAIL_COND_V(_data == nullptr, result);

	Ref<SurfaceTool> st;
	st.instantiate();
	st->begin(Mesh::PRIMITIVE_TRIANGLES);

	PackedVector3Array vertices;
	PackedVector2Array uvs;
	_generate_triangles(vertices, &uvs, p_lod, p_filter, false, AABB());

	ERR_FAIL_COND_V(vertices.size() != uvs.size(), result);
	for (int i = 0; i < vertices.size(); ++i) {
		st->set_uv(uvs[i]);
		st->add_vertex(vertices[i]);
	}

	st->index();
	st->generate_normals();
	st->generate_tangents();
	st->optimize_indices_for_cache();
	result = st->commit();
	return result;
}

/**
 * Generates source geometry faces for input to nav mesh baking. Geometry is only generated where there
 * are no holes and the terrain has been painted as navigable.
 * p_global_aabb: If non-empty, geometry will be generated only within this AABB. If empty, geometry
 *  will be generated for the entire terrain.
 * p_require_nav: If true, this function will only generate geometry for terrain marked navigable.
 *  Otherwise, geometry is generated for the entire terrain within the AABB (which can be useful for
 *  dynamic and/or runtime nav mesh baking).
 */
PackedVector3Array Pasture3D::generate_nav_mesh_source_geometry(const AABB &p_global_aabb, const bool p_require_nav) const {
	LOG(INFO, "Generating NavMesh source geometry from terrain");
	PackedVector3Array faces;
	_generate_triangles(faces, nullptr, 0, Pasture3DData::HEIGHT_FILTER_NEAREST, p_require_nav, p_global_aabb);
	return faces;
}

void Pasture3D::set_warning(const uint8_t p_warning, const bool p_enabled) {
	if (p_enabled) {
		_warnings |= p_warning;
	} else {
		_warnings &= ~p_warning;
	}
	update_configuration_warnings();
}

PackedStringArray Pasture3D::_get_configuration_warnings() const {
	PackedStringArray psa;
	if (_data_directory.is_empty()) {
		psa.push_back("No data directory specified. Select a directory then save the scene to write data.");
	}
	if (_warnings & WARN_MISMATCHED_SIZE) {
		psa.push_back("Texture dimensions don't match. Double-click a texture in the FileSystem panel to see its size. Read Texture Prep in docs.");
	}
	if (_warnings & WARN_MISMATCHED_FORMAT) {
		psa.push_back("Texture formats don't match. Double-click a texture in the FileSystem panel to see its format. Check Import panel. Read Texture Prep in docs.");
	}
	if (_warnings & WARN_MISMATCHED_MIPMAPS) {
		psa.push_back("Texture mipmap settings don't match. Change on the Import panel.");
	}
	// Parity guard (spec §4.3). The CPU evaluator sums all WATER_MAX_WAVES slots,
	// which is exactly right while the shader variant reads at least as many as the
	// table fills -- slots past ocean_wave_count are zero on both sides. A variant
	// reading FEWER cannot be reconciled: the GPU drops waves the CPU keeps, and
	// get_water_height() reports a surface nobody drew. The wrapper's count is not
	// introspectable through the RenderingServer, so it is read off the shader
	// source, and a wrapper written without the literal #define is left alone.
	if (_ocean_enabled) {
		ShaderMaterial *mat = Object::cast_to<ShaderMaterial>(_ocean_material.ptr());
		Ref<Shader> shader = mat ? mat->get_shader() : Ref<Shader>();
		if (shader.is_valid()) {
			const String token = "#define WATER_WAVE_COUNT";
			String code = shader->get_code();
			int at = code.find(token);
			if (at >= 0) {
				int variant_count = code.substr(at + token.length()).strip_edges().to_int();
				if (variant_count > 0 && variant_count < _ocean_waves.get_count()) {
					psa.push_back("ocean_wave_count is " + String::num_int64(_ocean_waves.get_count()) +
							" but the ocean material's shader only reads " + String::num_int64(variant_count) +
							" waves, so the extra waves are invisible and get_water_height() will not match "
							"the water on screen. Lower ocean_wave_count or use a higher-tier variant.");
				}
			}
		}
	}
	return psa;
}

///////////////////////////
// Protected Functions
///////////////////////////

// Notifications are defined in individual classes: Object, Node, Node3D
// Listed below in order of operation
void Pasture3D::_notification(const int p_what) {
	switch (p_what) {
			/// Startup notifications

		case NOTIFICATION_POSTINITIALIZE: {
			// Object initialized, before script is attached
			LOG(INFO, "NOTIFICATION_POSTINITIALIZE");
			_build_containers();
			break;
		}

		case NOTIFICATION_ENTER_WORLD: {
			// Node3D registered to new World3D resource
			// Sent on scene changes
			LOG(INFO, "NOTIFICATION_ENTER_WORLD");
			_is_inside_world = true;
			if (_terrain_mesher) {
				_terrain_mesher->update();
			}
			break;
		}

		case NOTIFICATION_ENTER_TREE: {
			// Node entered a SceneTree
			// Sent on scene changes
			LOG(INFO, "NOTIFICATION_ENTER_TREE");
			set_as_top_level(true); // Don't inherit transforms from parent. Global only.
			set_notify_transform(true);
			set_meta("_edit_lock_", true);
			_setup_mouse_picking();
			_setup_displacement_buffer();
			// Reload editor textures - Also see READY
			if (_free_editor_textures && !IS_EDITOR && _assets.is_valid() && !_assets->get_path().contains("Pasture3DAssets")) {
				LOG(INFO, "free_editor_textures enabled, reloading Assets path: ", _assets->get_path());
				_assets = ResourceLoader::get_singleton()->load(_assets->get_path(), "", ResourceLoader::CACHE_MODE_IGNORE);
			}
			_initialize(); // Rebuild anything freed: meshes, collision, instancer
			set_physics_process(true);
			break;
		}

		case NOTIFICATION_READY: {
			// Node is ready
			LOG(INFO, "NOTIFICATION_READY");
			// Optional: Run the testing suite (unit_testing.h included at top of this file).
			//test_differs();
			//test_layer_compositing();
			//test_layer_persistence();
			//test_layer_idempotent_composite();
			//test_layer_undo_restore();
			//test_layer_stroke_undo_integration();
			//test_layer_base_persistence();
			//test_layer_road_connector();
			//test_layer_subtiling();
			//test_layer_control_color();
			//test_layer_region_size_change();

			// Opt-in runner, so a suite can be run without editing and rebuilding the
			// extension. `PASTURE3D_UNIT_TESTS=water` selects the water parity suite;
			// unset (the normal case) runs nothing. The water suite is a gate for
			// spec §4.3, and a gate is only worth anything if it is reproducible.
			{
				const String suites = OS::get_singleton()->get_environment("PASTURE3D_UNIT_TESTS");
				if (suites.contains("water")) {
					test_water_waves();
				}
			}

			// Clear editor textures - also see ENTER_TREE
			if (_free_editor_textures && !IS_EDITOR && _assets.is_valid()) {
				if (_assets->get_path().contains("Pasture3DAssets")) {
					LOG(WARN, "free_editor_textures requires `Assets` be saved to a file. Do so, or disable the former to turn off this warning");
				} else {
					LOG(INFO, "free_editor_textures enabled, clearing texture assets");
					_assets->clear_textures();
				}
			}
			break;
		}

			/// Game Loop notifications

		case NOTIFICATION_PHYSICS_PROCESS: {
			// Node is processing one physics frame
			__physics_process(get_physics_process_delta_time());
			break;
		}

		case NOTIFICATION_TRANSFORM_CHANGED: {
			// Node3D or parent transform changed
			if (get_transform() != Transform3D()) {
				set_transform(Transform3D());
			}
			break;
		}

		case NOTIFICATION_VISIBILITY_CHANGED: {
			// Node3D visibility changed
			LOG(INFO, "NOTIFICATION_VISIBILITY_CHANGED");
			if (_terrain_mesher) {
				_terrain_mesher->update();
			}
			if (_ocean_mesher) {
				_ocean_mesher->update();
			}
			if (_instancer) {
				if (!is_visible_in_tree()) {
					_instancer->destroy();
				} else {
					_instancer->update_mmis(-1, V2I_MAX, true);
				}
			}
			break;
		}

		case NOTIFICATION_EXTENSION_RELOADED: {
			// Object finished hot reloading
			LOG(INFO, "NOTIFICATION_EXTENSION_RELOADED");
			break;
		}

		case NOTIFICATION_EDITOR_PRE_SAVE: {
			// Editor Node is about to save the current scene
			LOG(INFO, "NOTIFICATION_EDITOR_PRE_SAVE");
			if (_data_directory.is_empty()) {
				LOG(ERROR, "Data directory is empty. Set it to save regions to disk.");
			} else if (!_data) {
				LOG(DEBUG, "Save requested, but no valid data object. Skipping");
			} else {
				_data->save_directory(_data_directory);
			}
			if (!_material.is_valid()) {
				LOG(DEBUG, "Save requested, but no valid material. Skipping");
			} else {
				_material->save();
			}
			if (!_assets.is_valid()) {
				LOG(DEBUG, "Save requested, but no valid texture list. Skipping");
			} else {
				_assets->save();
			}
			break;
		}

		case NOTIFICATION_EDITOR_POST_SAVE: {
			// Editor Node finished saving current scene
			break;
		}

		case NOTIFICATION_CRASH: {
			// Godot's crash handler reports engine is about to crash
			// Only works on desktop if the crash handler is enabled
			LOG(INFO, "NOTIFICATION_CRASH");
			break;
		}

			/// Shut down notifications

		case NOTIFICATION_EXIT_TREE: {
			// Node is about to exit a SceneTree
			// Sent on scene changes
			LOG(INFO, "NOTIFICATION_EXIT_TREE");
			set_physics_process(false);
			_destroy_terrain_mesher();
			_destroy_ocean_mesher();
			_destroy_instancer();
			_destroy_mouse_picking();
			_destroy_displacement_buffer();
			if (_assets.is_valid()) {
				_assets->uninitialize();
			}
			if (_material.is_valid()) {
				_material->uninitialize();
			}
			_initialized = false;
			break;
		}

		case NOTIFICATION_EXIT_WORLD: {
			// Node3D unregistered from current World3D
			// Sent on scene changes
			LOG(INFO, "NOTIFICATION_EXIT_WORLD");
			_is_inside_world = false;
			break;
		}

		case NOTIFICATION_PREDELETE: {
			// Object is about to be deleted
			LOG(INFO, "NOTIFICATION_PREDELETE");
			_destroy_terrain_mesher(true);
			_destroy_ocean_mesher(true);
			_destroy_instancer();
			_destroy_collision(true);
			_assets.unref();
			_material.unref();
			memdelete_safely(_data);
			_destroy_labels();
			_destroy_containers();
			break;
		}

		default:
			break;
	}
}

void Pasture3D::_validate_property(PropertyInfo &p_property) const {
	if (_tessellation_level == 0) {
		// Hide all displacement properties
		if (p_property.name == StringName("displacement_scale") ||
				p_property.name == StringName("displacement_sharpness") ||
				p_property.name == StringName("buffer_shader_override_enabled") ||
				p_property.name == StringName("buffer_shader_override")) {
			p_property.usage = PROPERTY_USAGE_NO_EDITOR;
		}
	}
	// Hide all ocean properties if not enabled
	if (!_ocean_enabled && p_property.name != StringName("ocean_enabled") &&
			p_property.name.begins_with("ocean_")) {
		p_property.usage = PROPERTY_USAGE_NO_EDITOR;
	}
}

void Pasture3D::_bind_methods() {
	BIND_ENUM_CONSTANT(ERROR);
	BIND_ENUM_CONSTANT(INFO);
	BIND_ENUM_CONSTANT(DEBUG);
	BIND_ENUM_CONSTANT(EXTREME);

	BIND_ENUM_CONSTANT(SIZE_64);
	BIND_ENUM_CONSTANT(SIZE_128);
	BIND_ENUM_CONSTANT(SIZE_256);
	BIND_ENUM_CONSTANT(SIZE_512);
	BIND_ENUM_CONSTANT(SIZE_1024);
	BIND_ENUM_CONSTANT(SIZE_2048);

	ClassDB::bind_method(D_METHOD("get_version"), &Pasture3D::get_version);
	ClassDB::bind_method(D_METHOD("set_debug_level", "level"), &Pasture3D::set_debug_level);
	ClassDB::bind_method(D_METHOD("get_debug_level"), &Pasture3D::get_debug_level);
	ClassDB::bind_method(D_METHOD("set_data_directory", "directory"), &Pasture3D::set_data_directory);
	ClassDB::bind_method(D_METHOD("get_data_directory"), &Pasture3D::get_data_directory);

	// Object references
	ClassDB::bind_method(D_METHOD("get_data"), &Pasture3D::get_data);
	ClassDB::bind_method(D_METHOD("set_material", "material"), &Pasture3D::set_material);
	ClassDB::bind_method(D_METHOD("get_material"), &Pasture3D::get_material);
	ClassDB::bind_method(D_METHOD("set_assets", "assets"), &Pasture3D::set_assets);
	ClassDB::bind_method(D_METHOD("get_assets"), &Pasture3D::get_assets);
	ClassDB::bind_method(D_METHOD("get_collision"), &Pasture3D::get_collision);
	ClassDB::bind_method(D_METHOD("get_instancer"), &Pasture3D::get_instancer);
	ClassDB::bind_method(D_METHOD("set_editor", "editor"), &Pasture3D::set_editor);
	ClassDB::bind_method(D_METHOD("get_editor"), &Pasture3D::get_editor);
	ClassDB::bind_method(D_METHOD("set_plugin", "plugin"), &Pasture3D::set_plugin);
	ClassDB::bind_method(D_METHOD("get_plugin"), &Pasture3D::get_plugin);

	// Regions
	ClassDB::bind_method(D_METHOD("change_region_size", "size"), &Pasture3D::change_region_size);
	ClassDB::bind_method(D_METHOD("get_region_size"), &Pasture3D::get_region_size);
	ClassDB::bind_method(D_METHOD("set_save_16_bit", "enabled"), &Pasture3D::set_save_16_bit);
	ClassDB::bind_method(D_METHOD("get_save_16_bit"), &Pasture3D::get_save_16_bit);
	ClassDB::bind_method(D_METHOD("set_label_distance", "distance"), &Pasture3D::set_label_distance);
	ClassDB::bind_method(D_METHOD("get_label_distance"), &Pasture3D::get_label_distance);
	ClassDB::bind_method(D_METHOD("set_label_size", "size"), &Pasture3D::set_label_size);
	ClassDB::bind_method(D_METHOD("get_label_size"), &Pasture3D::get_label_size);

	// Target Tracking
	ClassDB::bind_method(D_METHOD("set_camera", "camera"), &Pasture3D::set_camera);
	ClassDB::bind_method(D_METHOD("get_camera"), &Pasture3D::get_camera);
	ClassDB::bind_method(D_METHOD("set_cameras", "cameras"), &Pasture3D::set_cameras);
	ClassDB::bind_method(D_METHOD("get_cameras"), &Pasture3D::get_cameras);
	ClassDB::bind_method(D_METHOD("set_clipmap_target", "node"), &Pasture3D::set_clipmap_target);
	ClassDB::bind_method(D_METHOD("get_clipmap_target"), &Pasture3D::get_clipmap_target);
	ClassDB::bind_method(D_METHOD("get_clipmap_target_position"), &Pasture3D::get_clipmap_target_position);
	ClassDB::bind_method(D_METHOD("set_collision_target", "node"), &Pasture3D::set_collision_target);
	ClassDB::bind_method(D_METHOD("get_collision_target"), &Pasture3D::get_collision_target);
	ClassDB::bind_method(D_METHOD("get_collision_target_position"), &Pasture3D::get_collision_target_position);
	ClassDB::bind_method(D_METHOD("set_ocean_light_target", "node"), &Pasture3D::set_ocean_light_target);
	ClassDB::bind_method(D_METHOD("get_ocean_light_target"), &Pasture3D::get_ocean_light_target);
	ClassDB::bind_method(D_METHOD("snap"), &Pasture3D::snap);

	// Collision
	ClassDB::bind_method(D_METHOD("set_collision_mode", "mode"), &Pasture3D::set_collision_mode);
	ClassDB::bind_method(D_METHOD("get_collision_mode"), &Pasture3D::get_collision_mode);
	ClassDB::bind_method(D_METHOD("set_collision_shape_size", "size"), &Pasture3D::set_collision_shape_size);
	ClassDB::bind_method(D_METHOD("get_collision_shape_size"), &Pasture3D::get_collision_shape_size);
	ClassDB::bind_method(D_METHOD("set_collision_radius", "radius"), &Pasture3D::set_collision_radius);
	ClassDB::bind_method(D_METHOD("get_collision_radius"), &Pasture3D::get_collision_radius);
	ClassDB::bind_method(D_METHOD("set_collision_layer", "layers"), &Pasture3D::set_collision_layer);
	ClassDB::bind_method(D_METHOD("get_collision_layer"), &Pasture3D::get_collision_layer);
	ClassDB::bind_method(D_METHOD("set_collision_mask", "mask"), &Pasture3D::set_collision_mask);
	ClassDB::bind_method(D_METHOD("get_collision_mask"), &Pasture3D::get_collision_mask);
	ClassDB::bind_method(D_METHOD("set_collision_priority", "priority"), &Pasture3D::set_collision_priority);
	ClassDB::bind_method(D_METHOD("get_collision_priority"), &Pasture3D::get_collision_priority);
	ClassDB::bind_method(D_METHOD("set_physics_material", "material"), &Pasture3D::set_physics_material);
	ClassDB::bind_method(D_METHOD("get_physics_material"), &Pasture3D::get_physics_material);

	// Terrain Mesh
	ClassDB::bind_method(D_METHOD("set_mesh_lods", "count"), &Pasture3D::set_mesh_lods);
	ClassDB::bind_method(D_METHOD("get_mesh_lods"), &Pasture3D::get_mesh_lods);
	ClassDB::bind_method(D_METHOD("set_mesh_size", "size"), &Pasture3D::set_mesh_size);
	ClassDB::bind_method(D_METHOD("get_mesh_size"), &Pasture3D::get_mesh_size);
	ClassDB::bind_method(D_METHOD("set_tessellation_level", "size"), &Pasture3D::set_tessellation_level);
	ClassDB::bind_method(D_METHOD("get_tessellation_level"), &Pasture3D::get_tessellation_level);
	ClassDB::bind_method(D_METHOD("set_vertex_spacing", "scale"), &Pasture3D::set_vertex_spacing);
	ClassDB::bind_method(D_METHOD("get_vertex_spacing"), &Pasture3D::get_vertex_spacing);
	ClassDB::bind_method(D_METHOD("set_cull_margin", "margin"), &Pasture3D::set_cull_margin);
	ClassDB::bind_method(D_METHOD("get_cull_margin"), &Pasture3D::get_cull_margin);
	ClassDB::bind_method(D_METHOD("set_cast_shadows", "shadow_casting_setting"), &Pasture3D::set_cast_shadows);
	ClassDB::bind_method(D_METHOD("get_cast_shadows"), &Pasture3D::get_cast_shadows);
	ClassDB::bind_method(D_METHOD("set_gi_mode", "gi_mode"), &Pasture3D::set_gi_mode);
	ClassDB::bind_method(D_METHOD("get_gi_mode"), &Pasture3D::get_gi_mode);
	ClassDB::bind_method(D_METHOD("set_render_layers", "layers"), &Pasture3D::set_render_layers);
	ClassDB::bind_method(D_METHOD("get_render_layers"), &Pasture3D::get_render_layers);

	// Terrain Displacement
	ClassDB::bind_method(D_METHOD("set_displacement_scale", "scale"), &Pasture3D::set_displacement_scale);
	ClassDB::bind_method(D_METHOD("get_displacement_scale"), &Pasture3D::get_displacement_scale);
	ClassDB::bind_method(D_METHOD("set_displacement_sharpness", "sharpness"), &Pasture3D::set_displacement_sharpness);
	ClassDB::bind_method(D_METHOD("get_displacement_sharpness"), &Pasture3D::get_displacement_sharpness);
	ClassDB::bind_method(D_METHOD("set_buffer_shader_override_enabled", "enabled"), &Pasture3D::set_buffer_shader_override_enabled);
	ClassDB::bind_method(D_METHOD("is_buffer_shader_override_enabled"), &Pasture3D::is_buffer_shader_override_enabled);
	ClassDB::bind_method(D_METHOD("set_buffer_shader_override", "shader"), &Pasture3D::set_buffer_shader_override);
	ClassDB::bind_method(D_METHOD("get_buffer_shader_override"), &Pasture3D::get_buffer_shader_override);

	// Ocean Mesh
	ClassDB::bind_method(D_METHOD("set_ocean_enabled", "enabled"), &Pasture3D::set_ocean_enabled);
	ClassDB::bind_method(D_METHOD("is_ocean_enabled"), &Pasture3D::is_ocean_enabled);
	ClassDB::bind_method(D_METHOD("set_ocean_mesh_lods", "count"), &Pasture3D::set_ocean_mesh_lods);
	ClassDB::bind_method(D_METHOD("get_ocean_mesh_lods"), &Pasture3D::get_ocean_mesh_lods);
	ClassDB::bind_method(D_METHOD("set_ocean_tessellation_level", "size"), &Pasture3D::set_ocean_tessellation_level);
	ClassDB::bind_method(D_METHOD("get_ocean_tessellation_level"), &Pasture3D::get_ocean_tessellation_level);
	ClassDB::bind_method(D_METHOD("set_ocean_mesh_size", "size"), &Pasture3D::set_ocean_mesh_size);
	ClassDB::bind_method(D_METHOD("get_ocean_mesh_size"), &Pasture3D::get_ocean_mesh_size);
	ClassDB::bind_method(D_METHOD("set_ocean_vertex_spacing", "scale"), &Pasture3D::set_ocean_vertex_spacing);
	ClassDB::bind_method(D_METHOD("get_ocean_vertex_spacing"), &Pasture3D::get_ocean_vertex_spacing);
	ClassDB::bind_method(D_METHOD("set_ocean_cull_margin", "margin"), &Pasture3D::set_ocean_cull_margin);
	ClassDB::bind_method(D_METHOD("get_ocean_cull_margin"), &Pasture3D::get_ocean_cull_margin);
	ClassDB::bind_method(D_METHOD("set_ocean_cast_shadows", "shadow_casting_setting"), &Pasture3D::set_ocean_cast_shadows);
	ClassDB::bind_method(D_METHOD("get_ocean_cast_shadows"), &Pasture3D::get_ocean_cast_shadows);
	ClassDB::bind_method(D_METHOD("set_ocean_gi_mode", "gi_mode"), &Pasture3D::set_ocean_gi_mode);
	ClassDB::bind_method(D_METHOD("get_ocean_gi_mode"), &Pasture3D::get_ocean_gi_mode);
	ClassDB::bind_method(D_METHOD("set_ocean_render_layers", "layers"), &Pasture3D::set_ocean_render_layers);
	ClassDB::bind_method(D_METHOD("get_ocean_render_layers"), &Pasture3D::get_ocean_render_layers);
	ClassDB::bind_method(D_METHOD("set_ocean_material", "material"), &Pasture3D::set_ocean_material);
	ClassDB::bind_method(D_METHOD("get_ocean_material"), &Pasture3D::get_ocean_material);
	ClassDB::bind_method(D_METHOD("set_ocean_wave_count", "count"), &Pasture3D::set_ocean_wave_count);
	ClassDB::bind_method(D_METHOD("get_ocean_wave_count"), &Pasture3D::get_ocean_wave_count);
	ClassDB::bind_method(D_METHOD("set_ocean_wave_direction", "degrees"), &Pasture3D::set_ocean_wave_direction);
	ClassDB::bind_method(D_METHOD("get_ocean_wave_direction"), &Pasture3D::get_ocean_wave_direction);
	ClassDB::bind_method(D_METHOD("set_ocean_wave_spread", "degrees"), &Pasture3D::set_ocean_wave_spread);
	ClassDB::bind_method(D_METHOD("get_ocean_wave_spread"), &Pasture3D::get_ocean_wave_spread);
	ClassDB::bind_method(D_METHOD("set_ocean_wave_amplitude", "metres"), &Pasture3D::set_ocean_wave_amplitude);
	ClassDB::bind_method(D_METHOD("get_ocean_wave_amplitude"), &Pasture3D::get_ocean_wave_amplitude);
	ClassDB::bind_method(D_METHOD("set_ocean_wave_length_max", "metres"), &Pasture3D::set_ocean_wave_length_max);
	ClassDB::bind_method(D_METHOD("get_ocean_wave_length_max"), &Pasture3D::get_ocean_wave_length_max);
	ClassDB::bind_method(D_METHOD("set_ocean_wave_steepness", "steepness"), &Pasture3D::set_ocean_wave_steepness);
	ClassDB::bind_method(D_METHOD("get_ocean_wave_steepness"), &Pasture3D::get_ocean_wave_steepness);
	ClassDB::bind_method(D_METHOD("set_ocean_wave_loop_period", "seconds"), &Pasture3D::set_ocean_wave_loop_period);
	ClassDB::bind_method(D_METHOD("get_ocean_wave_loop_period"), &Pasture3D::get_ocean_wave_loop_period);
	ClassDB::bind_method(D_METHOD("get_water_time"), &Pasture3D::get_water_time);
	ClassDB::bind_method(D_METHOD("get_water_height", "global_xz"), &Pasture3D::get_water_height);
	ClassDB::bind_method(D_METHOD("get_water_normal", "global_xz"), &Pasture3D::get_water_normal);
	ClassDB::bind_method(D_METHOD("get_water_surface_point", "domain_xz"), &Pasture3D::get_water_surface_point);

	// Rendering
	ClassDB::bind_method(D_METHOD("set_mouse_layer", "layer"), &Pasture3D::set_mouse_layer);
	ClassDB::bind_method(D_METHOD("get_mouse_layer"), &Pasture3D::get_mouse_layer);
	ClassDB::bind_method(D_METHOD("set_free_editor_textures"), &Pasture3D::set_free_editor_textures);
	ClassDB::bind_method(D_METHOD("get_free_editor_textures"), &Pasture3D::get_free_editor_textures);
	ClassDB::bind_method(D_METHOD("set_instancer_mode", "mode"), &Pasture3D::set_instancer_mode);
	ClassDB::bind_method(D_METHOD("get_instancer_mode"), &Pasture3D::get_instancer_mode);

	// Overlays
	ClassDB::bind_method(D_METHOD("set_show_region_grid", "enabled"), &Pasture3D::set_show_region_grid);
	ClassDB::bind_method(D_METHOD("get_show_region_grid"), &Pasture3D::get_show_region_grid);
	ClassDB::bind_method(D_METHOD("set_show_instancer_grid", "enabled"), &Pasture3D::set_show_instancer_grid);
	ClassDB::bind_method(D_METHOD("get_show_instancer_grid"), &Pasture3D::get_show_instancer_grid);
	ClassDB::bind_method(D_METHOD("set_show_vertex_grid", "enabled"), &Pasture3D::set_show_vertex_grid);
	ClassDB::bind_method(D_METHOD("get_show_vertex_grid"), &Pasture3D::get_show_vertex_grid);
	ClassDB::bind_method(D_METHOD("set_show_contours", "enabled"), &Pasture3D::set_show_contours);
	ClassDB::bind_method(D_METHOD("get_show_contours"), &Pasture3D::get_show_contours);
	ClassDB::bind_method(D_METHOD("set_show_navigation", "enabled"), &Pasture3D::set_show_navigation);
	ClassDB::bind_method(D_METHOD("get_show_navigation"), &Pasture3D::get_show_navigation);

	// Debug Views
	ClassDB::bind_method(D_METHOD("set_show_checkered", "enabled"), &Pasture3D::set_show_checkered);
	ClassDB::bind_method(D_METHOD("get_show_checkered"), &Pasture3D::get_show_checkered);
	ClassDB::bind_method(D_METHOD("set_show_grey", "enabled"), &Pasture3D::set_show_grey);
	ClassDB::bind_method(D_METHOD("get_show_grey"), &Pasture3D::get_show_grey);
	ClassDB::bind_method(D_METHOD("set_show_heightmap", "enabled"), &Pasture3D::set_show_heightmap);
	ClassDB::bind_method(D_METHOD("get_show_heightmap"), &Pasture3D::get_show_heightmap);
	ClassDB::bind_method(D_METHOD("set_show_jaggedness", "enabled"), &Pasture3D::set_show_jaggedness);
	ClassDB::bind_method(D_METHOD("get_show_jaggedness"), &Pasture3D::get_show_jaggedness);
	ClassDB::bind_method(D_METHOD("set_show_autoshader", "enabled"), &Pasture3D::set_show_autoshader);
	ClassDB::bind_method(D_METHOD("get_show_autoshader"), &Pasture3D::get_show_autoshader);
	ClassDB::bind_method(D_METHOD("set_show_control_texture", "enabled"), &Pasture3D::set_show_control_texture);
	ClassDB::bind_method(D_METHOD("get_show_control_texture"), &Pasture3D::get_show_control_texture);
	ClassDB::bind_method(D_METHOD("set_show_control_blend", "enabled"), &Pasture3D::set_show_control_blend);
	ClassDB::bind_method(D_METHOD("get_show_control_blend"), &Pasture3D::get_show_control_blend);
	ClassDB::bind_method(D_METHOD("set_show_control_angle", "enabled"), &Pasture3D::set_show_control_angle);
	ClassDB::bind_method(D_METHOD("get_show_control_angle"), &Pasture3D::get_show_control_angle);
	ClassDB::bind_method(D_METHOD("set_show_control_scale", "enabled"), &Pasture3D::set_show_control_scale);
	ClassDB::bind_method(D_METHOD("get_show_control_scale"), &Pasture3D::get_show_control_scale);
	ClassDB::bind_method(D_METHOD("set_show_colormap", "enabled"), &Pasture3D::set_show_colormap);
	ClassDB::bind_method(D_METHOD("get_show_colormap"), &Pasture3D::get_show_colormap);
	ClassDB::bind_method(D_METHOD("set_show_roughmap", "enabled"), &Pasture3D::set_show_roughmap);
	ClassDB::bind_method(D_METHOD("get_show_roughmap"), &Pasture3D::get_show_roughmap);
	ClassDB::bind_method(D_METHOD("set_show_displacement_buffer", "enabled"), &Pasture3D::set_show_displacement_buffer);
	ClassDB::bind_method(D_METHOD("get_show_displacement_buffer"), &Pasture3D::get_show_displacement_buffer);

	// PBR Views
	ClassDB::bind_method(D_METHOD("set_show_texture_albedo", "enabled"), &Pasture3D::set_show_texture_albedo);
	ClassDB::bind_method(D_METHOD("get_show_texture_albedo"), &Pasture3D::get_show_texture_albedo);
	ClassDB::bind_method(D_METHOD("set_show_texture_height", "enabled"), &Pasture3D::set_show_texture_height);
	ClassDB::bind_method(D_METHOD("get_show_texture_height"), &Pasture3D::get_show_texture_height);
	ClassDB::bind_method(D_METHOD("set_show_texture_normal", "enabled"), &Pasture3D::set_show_texture_normal);
	ClassDB::bind_method(D_METHOD("get_show_texture_normal"), &Pasture3D::get_show_texture_normal);
	ClassDB::bind_method(D_METHOD("set_show_texture_rough", "enabled"), &Pasture3D::set_show_texture_rough);
	ClassDB::bind_method(D_METHOD("get_show_texture_rough"), &Pasture3D::get_show_texture_rough);
	ClassDB::bind_method(D_METHOD("set_show_texture_ao", "enabled"), &Pasture3D::set_show_texture_ao);
	ClassDB::bind_method(D_METHOD("get_show_texture_ao"), &Pasture3D::get_show_texture_ao);

	// Utility
	ClassDB::bind_method(D_METHOD("get_intersection", "src_pos", "direction", "gpu_mode"), &Pasture3D::get_intersection, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("get_raycast_result", "src_pos", "direction", "collision_mask", "exclude_terrain"),
			&Pasture3D::get_raycast_result, DEFVAL(0xFFFFFFFF), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("bake_mesh", "lod", "filter"), &Pasture3D::bake_mesh, DEFVAL(Pasture3DData::HEIGHT_FILTER_NEAREST));
	ClassDB::bind_method(D_METHOD("generate_nav_mesh_source_geometry", "global_aabb", "require_nav"), &Pasture3D::generate_nav_mesh_source_geometry, DEFVAL(true));

	ADD_PROPERTY(PropertyInfo(Variant::STRING, "version", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_version");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "debug_level", PROPERTY_HINT_ENUM, "Errors,Info,Debug,Extreme"), "set_debug_level", "get_debug_level");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "data_directory", PROPERTY_HINT_DIR), "set_data_directory", "get_data_directory");

	// Object references
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "material", PROPERTY_HINT_RESOURCE_TYPE, "Pasture3DMaterial"), "set_material", "get_material");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "assets", PROPERTY_HINT_RESOURCE_TYPE, "Pasture3DAssets"), "set_assets", "get_assets");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "data", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE, "Pasture3DData"), "", "get_data");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "collision", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE, "Pasture3DCollision"), "", "get_collision");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "instancer", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE, "Pasture3DInstancer"), "", "get_instancer");

	ADD_GROUP("Regions", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "region_size", PROPERTY_HINT_ENUM, "64:64,128:128,256:256,512:512,1024:1024,2048:2048", PROPERTY_USAGE_EDITOR), "change_region_size", "get_region_size");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "save_16_bit"), "set_save_16_bit", "get_save_16_bit");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "label_distance", PROPERTY_HINT_RANGE, "0.0,10000.0,0.5,or_greater"), "set_label_distance", "get_label_distance");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "label_size", PROPERTY_HINT_RANGE, "24,128,1"), "set_label_size", "get_label_size");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_grid"), "set_show_region_grid", "get_show_region_grid");

	ADD_GROUP("Collision", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_mode", PROPERTY_HINT_ENUM, "Disabled,Dynamic / Game,Dynamic / Editor,Full / Game,Full / Editor"), "set_collision_mode", "get_collision_mode");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_shape_size", PROPERTY_HINT_RANGE, "8,64,8"), "set_collision_shape_size", "get_collision_shape_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_radius", PROPERTY_HINT_RANGE, "16,256,16"), "set_collision_radius", "get_collision_radius");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "collision_target", PROPERTY_HINT_NODE_TYPE, "Node3D", PROPERTY_USAGE_DEFAULT, "Node3D"), "set_collision_target", "get_collision_target");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_layer", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_layer", "get_collision_layer");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_mask", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_mask", "get_collision_mask");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "collision_priority", PROPERTY_HINT_RANGE, "0.1,256,.1"), "set_collision_priority", "get_collision_priority");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "physics_material", PROPERTY_HINT_RESOURCE_TYPE, "PhysicsMaterial"), "set_physics_material", "get_physics_material");

	ADD_GROUP("Terrain Mesh", "");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "clipmap_target", PROPERTY_HINT_NODE_TYPE, "Node3D", PROPERTY_USAGE_DEFAULT, "Node3D"), "set_clipmap_target", "get_clipmap_target");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mesh_lods", PROPERTY_HINT_RANGE, "1,10,1"), "set_mesh_lods", "get_mesh_lods");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "tessellation_level", PROPERTY_HINT_RANGE, "0,6,1"), "set_tessellation_level", "get_tessellation_level");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mesh_size", PROPERTY_HINT_RANGE, "8,256,2"), "set_mesh_size", "get_mesh_size");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "vertex_spacing", PROPERTY_HINT_RANGE, "0.25,10.0,or_greater"), "set_vertex_spacing", "get_vertex_spacing");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "cull_margin", PROPERTY_HINT_RANGE, "0.0,10000.0,.5,or_greater"), "set_cull_margin", "get_cull_margin");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "cast_shadows", PROPERTY_HINT_ENUM, "Off,On,Double-Sided,Shadows Only"), "set_cast_shadows", "get_cast_shadows");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "gi_mode", PROPERTY_HINT_ENUM, "Disabled,Static,Dynamic"), "set_gi_mode", "get_gi_mode");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "render_layers", PROPERTY_HINT_LAYERS_3D_RENDER), "set_render_layers", "get_render_layers");

	ADD_SUBGROUP("Displacement", "");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "displacement_scale", PROPERTY_HINT_RANGE, "0.0, 2.0, 0.01"), "set_displacement_scale", "get_displacement_scale");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "displacement_sharpness", PROPERTY_HINT_RANGE, "0.0, 1.0, 0.01"), "set_displacement_sharpness", "get_displacement_sharpness");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "buffer_shader_override_enabled"), "set_buffer_shader_override_enabled", "is_buffer_shader_override_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "buffer_shader_override", PROPERTY_HINT_RESOURCE_TYPE, "Shader"), "set_buffer_shader_override", "get_buffer_shader_override");

	ADD_GROUP("Ocean Mesh", "ocean_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "ocean_enabled"), "set_ocean_enabled", "is_ocean_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "ocean_mesh_lods", PROPERTY_HINT_RANGE, "1,10,1"), "set_ocean_mesh_lods", "get_ocean_mesh_lods");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "ocean_tessellation_level", PROPERTY_HINT_RANGE, "0,6,1"), "set_ocean_tessellation_level", "get_ocean_tessellation_level");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "ocean_mesh_size", PROPERTY_HINT_RANGE, "8,256,2"), "set_ocean_mesh_size", "get_ocean_mesh_size");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "ocean_vertex_spacing", PROPERTY_HINT_RANGE, "0.25,10.0,0.05,or_greater"), "set_ocean_vertex_spacing", "get_ocean_vertex_spacing");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "ocean_cull_margin", PROPERTY_HINT_RANGE, "0.0,10000.0,.5,or_greater"), "set_ocean_cull_margin", "get_ocean_cull_margin");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "ocean_cast_shadows", PROPERTY_HINT_ENUM, "Off,On,Double-Sided,Shadows Only"), "set_ocean_cast_shadows", "get_ocean_cast_shadows");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "ocean_gi_mode", PROPERTY_HINT_ENUM, "Disabled,Static,Dynamic"), "set_ocean_gi_mode", "get_ocean_gi_mode");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "ocean_render_layers", PROPERTY_HINT_LAYERS_3D_RENDER), "set_ocean_render_layers", "get_ocean_render_layers");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "ocean_material", PROPERTY_HINT_RESOURCE_TYPE, "ShaderMaterial,BaseMaterial3D"), "set_ocean_material", "get_ocean_material");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "ocean_light_target", PROPERTY_HINT_NODE_TYPE, "DirectionalLight3D", PROPERTY_USAGE_DEFAULT, "Node3D"), "set_ocean_light_target", "get_ocean_light_target");
	// Wave knobs. Must match the WATER_WAVE_COUNT the ocean material's variant
	// was compiled with -- extra waves are uploaded but never read.
	ADD_PROPERTY(PropertyInfo(Variant::INT, "ocean_wave_count", PROPERTY_HINT_RANGE, "1,8,1"), "set_ocean_wave_count", "get_ocean_wave_count");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "ocean_wave_direction", PROPERTY_HINT_RANGE, "0.0,360.0,1.0"), "set_ocean_wave_direction", "get_ocean_wave_direction");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "ocean_wave_spread", PROPERTY_HINT_RANGE, "0.0,90.0,1.0"), "set_ocean_wave_spread", "get_ocean_wave_spread");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "ocean_wave_amplitude", PROPERTY_HINT_RANGE, "0.0,20.0,0.01,or_greater"), "set_ocean_wave_amplitude", "get_ocean_wave_amplitude");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "ocean_wave_length_max", PROPERTY_HINT_RANGE, "10.0,500.0,1.0,or_greater"), "set_ocean_wave_length_max", "get_ocean_wave_length_max");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "ocean_wave_steepness", PROPERTY_HINT_RANGE, "0.0,1.0,0.01"), "set_ocean_wave_steepness", "get_ocean_wave_steepness");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "ocean_wave_loop_period", PROPERTY_HINT_RANGE, "0.0,600.0,1.0"), "set_ocean_wave_loop_period", "get_ocean_wave_loop_period");

	ADD_GROUP("Rendering", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mouse_layer", PROPERTY_HINT_RANGE, "21, 32"), "set_mouse_layer", "get_mouse_layer");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "free_editor_textures"), "set_free_editor_textures", "get_free_editor_textures");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "instancer_mode", PROPERTY_HINT_ENUM, "Disabled,Normal"), "set_instancer_mode", "get_instancer_mode");

	ADD_GROUP("Overlays", "show_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_region_grid"), "set_show_region_grid", "get_show_region_grid");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_instancer_grid"), "set_show_instancer_grid", "get_show_instancer_grid");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_vertex_grid"), "set_show_vertex_grid", "get_show_vertex_grid");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_contours"), "set_show_contours", "get_show_contours");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_navigation"), "set_show_navigation", "get_show_navigation");

	ADD_GROUP("Debug Views", "show_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_checkered"), "set_show_checkered", "get_show_checkered");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_grey"), "set_show_grey", "get_show_grey");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_heightmap"), "set_show_heightmap", "get_show_heightmap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_jaggedness"), "set_show_jaggedness", "get_show_jaggedness");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_autoshader"), "set_show_autoshader", "get_show_autoshader");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_control_texture"), "set_show_control_texture", "get_show_control_texture");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_control_blend"), "set_show_control_blend", "get_show_control_blend");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_control_angle"), "set_show_control_angle", "get_show_control_angle");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_control_scale"), "set_show_control_scale", "get_show_control_scale");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_colormap"), "set_show_colormap", "get_show_colormap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_roughmap"), "set_show_roughmap", "get_show_roughmap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_displacement_buffer"), "set_show_displacement_buffer", "get_show_displacement_buffer");

	ADD_SUBGROUP("PBR Maps", "show_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_albedo"), "set_show_texture_albedo", "get_show_texture_albedo");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_height"), "set_show_texture_height", "get_show_texture_height");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_normal"), "set_show_texture_normal", "get_show_texture_normal");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_rough"), "set_show_texture_rough", "get_show_texture_rough");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_ao"), "set_show_texture_ao", "get_show_texture_ao");

	ADD_SIGNAL(MethodInfo("material_changed"));
	ADD_SIGNAL(MethodInfo("assets_changed"));
}
