// Copyright © 2024 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/collision_shape3d.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/environment.hpp>
#include <godot_cpp/classes/height_map_shape3d.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/quad_mesh.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/classes/surface_tool.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/classes/viewport_texture.hpp>
#include <godot_cpp/classes/world3d.hpp>

#include "geoclipmap.h"
#include "logger.h"
#include "terrain_3d.h"
#include "terrain_3d_util.h"

///////////////////////////
// Private Functions
///////////////////////////

// Initialize static member variable
int Terrain3D::debug_level{ ERROR };

void Terrain3D::_initialize() {
	LOG(INFO, "Checking instancer, material, storage, assets, signal, and mesh initialization");

	// Make blank objects if needed
	if (_material.is_null()) {
		LOG(DEBUG, "Creating blank material");
		_material.instantiate();
	}
	if (_storage.is_null()) {
		LOG(DEBUG, "Creating blank storage");
		_storage.instantiate();
		_storage->set_version(Terrain3DStorage::CURRENT_VERSION);
	}
	if (_assets.is_null()) {
		LOG(DEBUG, "Creating blank texture list");
		_assets.instantiate();
	}
	if (_instancer == nullptr) {
		LOG(DEBUG, "Creating blank instancer");
		_instancer = memnew(Terrain3DInstancer);
	}

	// Connect signals
	// Region size changed, update material
	if (!_storage->is_connected("region_size_changed", callable_mp(_material.ptr(), &Terrain3DMaterial::_update_maps))) {
		LOG(DEBUG, "Connecting region_size_changed signal to _material->_update_regions()");
		_storage->connect("region_size_changed", callable_mp(_material.ptr(), &Terrain3DMaterial::_update_maps));
	}
	// Any map was regenerated or regions changed, update material
	if (!_storage->is_connected("maps_changed", callable_mp(_material.ptr(), &Terrain3DMaterial::_update_maps))) {
		LOG(DEBUG, "Connecting _storage::maps_changed signal to _material->_update_maps()");
		_storage->connect("maps_changed", callable_mp(_material.ptr(), &Terrain3DMaterial::_update_maps));
	}
	// Height map was regenerated - update aabbs - Probably remove and just use maps_edited
	if (!_storage->is_connected("height_maps_changed", callable_mp(this, &Terrain3D::update_aabbs))) {
		LOG(DEBUG, "Connecting _storage::height_maps_changed signal to update_aabbs()");
		_storage->connect("height_maps_changed", callable_mp(this, &Terrain3D::update_aabbs));
	}
	// Texture assets changed, update material
	if (!_assets->is_connected("textures_changed", callable_mp(_material.ptr(), &Terrain3DMaterial::_update_texture_arrays))) {
		LOG(DEBUG, "Connecting _assets.textures_changed to _material->_update_texture_arrays()");
		_assets->connect("textures_changed", callable_mp(_material.ptr(), &Terrain3DMaterial::_update_texture_arrays));
	}
	// MeshAssets changed, update instancer
	if (!_assets->is_connected("meshes_changed", callable_mp(_instancer, &Terrain3DInstancer::_update_mmis).bind(Vector2i(INT32_MAX, INT32_MAX), -1))) {
		LOG(DEBUG, "Connecting _assets.meshes_changed to _instancer->_update_mmis()");
		_assets->connect("meshes_changed", callable_mp(_instancer, &Terrain3DInstancer::_update_mmis).bind(Vector2i(INT32_MAX, INT32_MAX), -1));
	}
	// New multimesh added to storage, rebuild instancer
	if (!_storage->is_connected("multimeshes_changed", callable_mp(_instancer, &Terrain3DInstancer::_rebuild_mmis))) {
		LOG(DEBUG, "Connecting _storage::multimeshes_changed signal to _rebuild_mmis()");
		_storage->connect("multimeshes_changed", callable_mp(_instancer, &Terrain3DInstancer::_rebuild_mmis));
	}
	// Connect height changes to update instances
	if (!_storage->is_connected("maps_edited", callable_mp(_instancer, &Terrain3DInstancer::update_transforms))) {
		LOG(DEBUG, "Connecting maps_edited signal to update_transforms()");
		_storage->connect("maps_edited", callable_mp(_instancer, &Terrain3DInstancer::update_transforms));
	}

	// Initialize the system
	if (!_initialized && _is_inside_world && is_inside_tree()) {
		_storage->initialize(this);
		_material->initialize(this);
		_assets->initialize(this);
		_instancer->initialize(this);
		_build_meshes(_mesh_lods, _mesh_size);
		_build_collision();
		_initialized = true;
	}
	update_configuration_warnings();
}

/**
 * This is a proxy for _process(delta) called by _notification() due to
 * https://github.com/godotengine/godot-cpp/issues/1022
 */
void Terrain3D::__process(const double p_delta) {
	if (!_initialized)
		return;

	// If the game/editor camera is not set, find it
	if (!is_instance_valid(_camera_instance_id, _camera)) {
		LOG(DEBUG, "Camera is null, getting the current one");
		_grab_camera();
	}

	// If camera has moved enough, re-center the terrain on it.
	if (is_instance_valid(_camera_instance_id) && _camera->is_inside_tree()) {
		Vector3 cam_pos = _camera->get_global_position();
		Vector2 cam_pos_2d = Vector2(cam_pos.x, cam_pos.z);
		if (_camera_last_position.distance_to(cam_pos_2d) > 0.2f) {
			snap(cam_pos);
			_camera_last_position = cam_pos_2d;
		}
	}
}

void Terrain3D::_setup_mouse_picking() {
	if (!is_inside_tree()) {
		LOG(ERROR, "Not inside the tree, skipping mouse setup");
		return;
	}
	LOG(INFO, "Setting up mouse picker and get_intersection viewport, camera & screen quad");
	_mouse_vp = memnew(SubViewport);
	_mouse_vp->set_name("MouseViewport");
	add_child(_mouse_vp, true);
	_mouse_vp->set_size(Vector2i(2, 2));
	_mouse_vp->set_update_mode(SubViewport::UPDATE_ONCE);
	_mouse_vp->set_handle_input_locally(false);
	_mouse_vp->set_canvas_cull_mask(0);
	_mouse_vp->set_use_hdr_2d(true);
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
	_mouse_cam->set_projection(Camera3D::PROJECTION_ORTHOGONAL);
	_mouse_cam->set_size(0.1f);
	_mouse_cam->set_far(100000.f);

	_mouse_quad = memnew(MeshInstance3D);
	_mouse_quad->set_name("MouseQuad");
	_mouse_cam->add_child(_mouse_quad, true);
	Ref<QuadMesh> quad;
	quad.instantiate();
	quad->set_size(Vector2(0.1f, 0.1f));
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
	set_mouse_layer(_mouse_layer);
}

void Terrain3D::_destroy_mouse_picking() {
	LOG(DEBUG, "Freeing mouse_quad");
	memdelete_safely(_mouse_quad);
	LOG(DEBUG, "Freeing mouse_cam");
	memdelete_safely(_mouse_cam);
	LOG(DEBUG, "memdelete mouse_vp");
	memdelete_safely(_mouse_vp);
}

/**
 * If running in the editor, grab the first editor viewport camera.
 * The edited_scene_root is excluded in case the user already has a Camera3D in their scene.
 */
void Terrain3D::_grab_camera() {
	if (IS_EDITOR) {
		_camera = EditorInterface::get_singleton()->get_editor_viewport_3d(0)->get_camera_3d();
		LOG(DEBUG, "Grabbing the first editor viewport camera: ", _camera);
	} else {
		_camera = get_viewport()->get_camera_3d();
		LOG(DEBUG, "Grabbing the in-game viewport camera: ", _camera);
	}
	if (_camera) {
		_camera_instance_id = _camera->get_instance_id();
	} else {
		_camera_instance_id = 0;
		set_process(false); // disable snapping
		LOG(ERROR, "Cannot find the active camera. Set it manually with Terrain3D.set_camera(). Stopping _process()");
	}
}

void Terrain3D::_build_meshes(const int p_mesh_lods, const int p_mesh_size) {
	if (!is_inside_tree() || !_storage.is_valid()) {
		LOG(DEBUG, "Not inside the tree or no valid storage, skipping build");
		return;
	}
	LOG(INFO, "Building the terrain meshes");

	// Generate terrain meshes, lods, seams
	_meshes = GeoClipMap::generate(p_mesh_size, p_mesh_lods);
	ERR_FAIL_COND(_meshes.is_empty());

	// Set the current terrain material on all meshes
	RID material_rid = _material->get_material_rid();
	for (const RID rid : _meshes) {
		RS->mesh_surface_set_material(rid, 0, material_rid);
	}

	LOG(DEBUG, "Creating mesh instances");

	// Get current visual scenario so the instances appear in the scene
	RID scenario = get_world_3d()->get_scenario();

	_data.cross = RS->instance_create2(_meshes[GeoClipMap::CROSS], scenario);
	RS->instance_geometry_set_cast_shadows_setting(_data.cross, RenderingServer::ShadowCastingSetting(_cast_shadows));
	RS->instance_set_layer_mask(_data.cross, _render_layers);

	for (int l = 0; l < p_mesh_lods; l++) {
		for (int x = 0; x < 4; x++) {
			for (int y = 0; y < 4; y++) {
				if (l != 0 && (x == 1 || x == 2) && (y == 1 || y == 2)) {
					continue;
				}

				RID tile = RS->instance_create2(_meshes[GeoClipMap::TILE], scenario);
				RS->instance_geometry_set_cast_shadows_setting(tile, RenderingServer::ShadowCastingSetting(_cast_shadows));
				RS->instance_set_layer_mask(tile, _render_layers);
				_data.tiles.push_back(tile);
			}
		}

		RID filler = RS->instance_create2(_meshes[GeoClipMap::FILLER], scenario);
		RS->instance_geometry_set_cast_shadows_setting(filler, RenderingServer::ShadowCastingSetting(_cast_shadows));
		RS->instance_set_layer_mask(filler, _render_layers);
		_data.fillers.push_back(filler);

		if (l != p_mesh_lods - 1) {
			RID trim = RS->instance_create2(_meshes[GeoClipMap::TRIM], scenario);
			RS->instance_geometry_set_cast_shadows_setting(trim, RenderingServer::ShadowCastingSetting(_cast_shadows));
			RS->instance_set_layer_mask(trim, _render_layers);
			_data.trims.push_back(trim);

			RID seam = RS->instance_create2(_meshes[GeoClipMap::SEAM], scenario);
			RS->instance_geometry_set_cast_shadows_setting(seam, RenderingServer::ShadowCastingSetting(_cast_shadows));
			RS->instance_set_layer_mask(seam, _render_layers);
			_data.seams.push_back(seam);
		}
	}

	update_aabbs();
	// Force a snap update
	_camera_last_position = Vector2(__FLT_MAX__, __FLT_MAX__);
}

/**
 * Make all mesh instances visible or not
 * Update all mesh instances with the new world scenario so they appear
 */
void Terrain3D::_update_mesh_instances() {
	if (!_initialized || !_is_inside_world || !is_inside_tree()) {
		return;
	}
	if (_static_body.is_valid()) {
		RID _space = get_world_3d()->get_space();
		PhysicsServer3D::get_singleton()->body_set_space(_static_body, _space);
	}

	RID _scenario = get_world_3d()->get_scenario();

	bool v = is_visible_in_tree();
	RS->instance_set_visible(_data.cross, v);
	RS->instance_set_scenario(_data.cross, _scenario);
	RS->instance_geometry_set_cast_shadows_setting(_data.cross, RenderingServer::ShadowCastingSetting(_cast_shadows));
	RS->instance_set_layer_mask(_data.cross, _render_layers);

	for (const RID rid : _data.tiles) {
		RS->instance_set_visible(rid, v);
		RS->instance_set_scenario(rid, _scenario);
		RS->instance_geometry_set_cast_shadows_setting(rid, RenderingServer::ShadowCastingSetting(_cast_shadows));
		RS->instance_set_layer_mask(rid, _render_layers);
	}

	for (const RID rid : _data.fillers) {
		RS->instance_set_visible(rid, v);
		RS->instance_set_scenario(rid, _scenario);
		RS->instance_geometry_set_cast_shadows_setting(rid, RenderingServer::ShadowCastingSetting(_cast_shadows));
		RS->instance_set_layer_mask(rid, _render_layers);
	}

	for (const RID rid : _data.trims) {
		RS->instance_set_visible(rid, v);
		RS->instance_set_scenario(rid, _scenario);
		RS->instance_geometry_set_cast_shadows_setting(rid, RenderingServer::ShadowCastingSetting(_cast_shadows));
		RS->instance_set_layer_mask(rid, _render_layers);
	}

	for (const RID rid : _data.seams) {
		RS->instance_set_visible(rid, v);
		RS->instance_set_scenario(rid, _scenario);
		RS->instance_geometry_set_cast_shadows_setting(rid, RenderingServer::ShadowCastingSetting(_cast_shadows));
		RS->instance_set_layer_mask(rid, _render_layers);
	}
}

void Terrain3D::_clear_meshes() {
	LOG(INFO, "Clearing the terrain meshes");
	for (const RID rid : _meshes) {
		RS->free_rid(rid);
	}
	RS->free_rid(_data.cross);
	for (const RID rid : _data.tiles) {
		RS->free_rid(rid);
	}
	for (const RID rid : _data.fillers) {
		RS->free_rid(rid);
	}
	for (const RID rid : _data.trims) {
		RS->free_rid(rid);
	}
	for (const RID rid : _data.seams) {
		RS->free_rid(rid);
	}
	_meshes.clear();
	_data.tiles.clear();
	_data.fillers.clear();
	_data.trims.clear();
	_data.seams.clear();
	_initialized = false;
}

void Terrain3D::_build_collision() {
	if (!_collision_enabled || !_is_inside_world || !is_inside_tree()) {
		return;
	}
	// Create collision only in game, unless showing debug
	if (IS_EDITOR && !_show_debug_collision) {
		return;
	}
	if (_storage.is_null()) {
		LOG(ERROR, "Storage missing, cannot create collision");
		return;
	}
	_destroy_collision();

	if (!_show_debug_collision) {
		LOG(INFO, "Building collision with physics server");
		_static_body = PhysicsServer3D::get_singleton()->body_create();
		PhysicsServer3D::get_singleton()->body_set_mode(_static_body, PhysicsServer3D::BODY_MODE_STATIC);
		PhysicsServer3D::get_singleton()->body_set_space(_static_body, get_world_3d()->get_space());
		PhysicsServer3D::get_singleton()->body_attach_object_instance_id(_static_body, get_instance_id());
	} else {
		LOG(WARN, "Building debug collision. Disable this mode for releases");
		_debug_static_body = memnew(StaticBody3D);
		_debug_static_body->set_name("StaticBody3D");
		_debug_static_body->set_as_top_level(true);
		add_child(_debug_static_body, true);
	}
	_update_collision();
}

/* Eventually this should be callable to update collision on changes,
 * and especially updating only the ones that have changed. However it's not there yet, so
 * destroy and recreate for now.
 */
void Terrain3D::_update_collision() {
	if (!_collision_enabled || !is_inside_tree()) {
		return;
	}
	// Create collision only in game, unless showing debug
	if (IS_EDITOR && !_show_debug_collision) {
		return;
	}
	if ((!_show_debug_collision && !_static_body.is_valid()) ||
			(_show_debug_collision && _debug_static_body == nullptr)) {
		_build_collision();
	}

	int time = Time::get_singleton()->get_ticks_msec();
	int region_size = _storage->get_region_size();
	int shape_size = region_size + 1;
	float hole_const = NAN;
	// DEPRECATED - Jolt v0.12 supports NAN. Remove check when it's old.
	if (ProjectSettings::get_singleton()->get_setting("physics/3d/physics_engine") == "JoltPhysics3D") {
		hole_const = __FLT_MAX__;
	}

	for (int i = 0; i < _storage->get_region_count(); i++) {
		PackedRealArray map_data = PackedRealArray();
		map_data.resize(shape_size * shape_size);

		Vector2i global_loc = Vector2i(_storage->get_region_locations()[i]) * region_size;
		Vector3 global_pos = Vector3(global_loc.x, 0.f, global_loc.y);

		Ref<Image> map, map_x, map_z, map_xz;
		Ref<Image> cmap, cmap_x, cmap_z, cmap_xz;
		map = _storage->get_map_region(TYPE_HEIGHT, i);
		cmap = _storage->get_map_region(TYPE_CONTROL, i);
		int region_id = _storage->get_region_id(Vector3(global_pos.x + region_size, 0.f, global_pos.z) * _mesh_vertex_spacing);
		if (region_id >= 0) {
			map_x = _storage->get_map_region(TYPE_HEIGHT, region_id);
			cmap_x = _storage->get_map_region(TYPE_CONTROL, region_id);
		}
		region_id = _storage->get_region_id(Vector3(global_pos.x, 0.f, global_pos.z + region_size) * _mesh_vertex_spacing);
		if (region_id >= 0) {
			map_z = _storage->get_map_region(TYPE_HEIGHT, region_id);
			cmap_z = _storage->get_map_region(TYPE_CONTROL, region_id);
		}
		region_id = _storage->get_region_id(Vector3(global_pos.x + region_size, 0.f, global_pos.z + region_size) * _mesh_vertex_spacing);
		if (region_id >= 0) {
			map_xz = _storage->get_map_region(TYPE_HEIGHT, region_id);
			cmap_xz = _storage->get_map_region(TYPE_CONTROL, region_id);
		}

		for (int z = 0; z < shape_size; z++) {
			for (int x = 0; x < shape_size; x++) {
				// Choose array indexing to match triangulation of heightmapshape with the mesh
				// https://stackoverflow.com/questions/16684856/rotating-a-2d-pixel-array-by-90-degrees
				// Normal array index rotated Y=0 - shape rotation Y=0 (xform below)
				// int index = z * shape_size + x;
				// Array Index Rotated Y=-90 - must rotate shape Y=+90 (xform below)
				int index = shape_size - 1 - z + x * shape_size;

				// Set heights on local map, or adjacent maps if on the last row/col
				if (x < region_size && z < region_size) {
					map_data[index] = (is_hole(cmap->get_pixel(x, z).r)) ? hole_const : map->get_pixel(x, z).r;
				} else if (x == region_size && z < region_size) {
					if (map_x.is_valid()) {
						map_data[index] = (is_hole(cmap_x->get_pixel(0, z).r)) ? hole_const : map_x->get_pixel(0, z).r;
					} else {
						map_data[index] = 0.0f;
					}
				} else if (z == region_size && x < region_size) {
					if (map_z.is_valid()) {
						map_data[index] = (is_hole(cmap_z->get_pixel(x, 0).r)) ? hole_const : map_z->get_pixel(x, 0).r;
					} else {
						map_data[index] = 0.0f;
					}
				} else if (x == region_size && z == region_size) {
					if (map_xz.is_valid()) {
						map_data[index] = (is_hole(cmap_xz->get_pixel(0, 0).r)) ? hole_const : map_xz->get_pixel(0, 0).r;
					} else {
						map_data[index] = 0.0f;
					}
				}
			}
		}

		// Non rotated shape for normal array index above
		//Transform3D xform = Transform3D(Basis(), global_pos);
		// Rotated shape Y=90 for -90 rotated array index
		Transform3D xform = Transform3D(Basis(Vector3(0.f, 1.f, 0.f), Math_PI * .5f),
				global_pos + Vector3(region_size, 0.f, region_size) * .5f);
		xform.scale(Vector3(_mesh_vertex_spacing, 1.f, _mesh_vertex_spacing));

		if (!_show_debug_collision) {
			RID shape = PhysicsServer3D::get_singleton()->heightmap_shape_create();
			Dictionary shape_data;
			shape_data["width"] = shape_size;
			shape_data["depth"] = shape_size;
			shape_data["heights"] = map_data;
			Vector2 min_max = _storage->get_height_range();
			shape_data["min_height"] = min_max.x;
			shape_data["max_height"] = min_max.y;
			PhysicsServer3D::get_singleton()->shape_set_data(shape, shape_data);
			PhysicsServer3D::get_singleton()->body_add_shape(_static_body, shape);
			PhysicsServer3D::get_singleton()->body_set_shape_transform(_static_body, i, xform);
			PhysicsServer3D::get_singleton()->body_set_collision_mask(_static_body, _collision_mask);
			PhysicsServer3D::get_singleton()->body_set_collision_layer(_static_body, _collision_layer);
			PhysicsServer3D::get_singleton()->body_set_collision_priority(_static_body, _collision_priority);
		} else {
			CollisionShape3D *debug_col_shape;
			debug_col_shape = memnew(CollisionShape3D);
			debug_col_shape->set_name("CollisionShape3D");
			_debug_static_body->add_child(debug_col_shape, true);
			debug_col_shape->set_owner(_debug_static_body);

			Ref<HeightMapShape3D> hshape;
			hshape.instantiate();
			hshape->set_map_width(shape_size);
			hshape->set_map_depth(shape_size);
			hshape->set_map_data(map_data);
			debug_col_shape->set_shape(hshape);
			debug_col_shape->set_global_transform(xform);
			_debug_static_body->set_collision_mask(_collision_mask);
			_debug_static_body->set_collision_layer(_collision_layer);
			_debug_static_body->set_collision_priority(_collision_priority);
		}
	}
	LOG(DEBUG, "Collision creation time: ", Time::get_singleton()->get_ticks_msec() - time, " ms");
}

void Terrain3D::_destroy_collision() {
	if (_static_body.is_valid()) {
		LOG(INFO, "Freeing physics body");
		RID shape = PhysicsServer3D::get_singleton()->body_get_shape(_static_body, 0);
		PhysicsServer3D::get_singleton()->free_rid(shape);
		PhysicsServer3D::get_singleton()->free_rid(_static_body);
		_static_body = RID();
	}

	if (_debug_static_body != nullptr) {
		LOG(INFO, "Freeing debug static body");
		for (int i = 0; i < _debug_static_body->get_child_count(); i++) {
			Node *child = _debug_static_body->get_child(i);
			LOG(DEBUG, "Freeing dsb child ", i, " ", child->get_name());
			_debug_static_body->remove_child(child);
			memdelete(child);
		}

		LOG(DEBUG, "Freeing static body");
		remove_child(_debug_static_body);
		memdelete(_debug_static_body);
		_debug_static_body = nullptr;
	}
}

void Terrain3D::_destroy_instancer() {
	memdelete_safely(_instancer);
}

void Terrain3D::_generate_triangles(PackedVector3Array &p_vertices, PackedVector2Array *p_uvs, const int32_t p_lod,
		const Terrain3DStorage::HeightFilter p_filter, const bool p_require_nav, const AABB &p_global_aabb) const {
	ERR_FAIL_COND(!_storage.is_valid());
	int32_t step = 1 << CLAMP(p_lod, 0, 8);

	if (!p_global_aabb.has_volume()) {
		int32_t region_size = (int)_storage->get_region_size();

		TypedArray<Vector2i> region_locations = _storage->get_region_locations();
		for (int r = 0; r < region_locations.size(); ++r) {
			Vector2i region_loc = (Vector2i)region_locations[r] * region_size;

			for (int32_t z = region_loc.y; z < region_loc.y + region_size; z += step) {
				for (int32_t x = region_loc.x; x < region_loc.x + region_size; x += step) {
					_generate_triangle_pair(p_vertices, p_uvs, p_lod, p_filter, p_require_nav, x, z);
				}
			}
		}
	} else {
		int32_t z_start = (int32_t)Math::ceil(p_global_aabb.position.z / _mesh_vertex_spacing);
		int32_t z_end = (int32_t)Math::floor(p_global_aabb.get_end().z / _mesh_vertex_spacing) + 1;
		int32_t x_start = (int32_t)Math::ceil(p_global_aabb.position.x / _mesh_vertex_spacing);
		int32_t x_end = (int32_t)Math::floor(p_global_aabb.get_end().x / _mesh_vertex_spacing) + 1;

		for (int32_t z = z_start; z < z_end; ++z) {
			for (int32_t x = x_start; x < x_end; ++x) {
				real_t height = _storage->get_height(Vector3(x, 0.f, z));
				if (height >= p_global_aabb.position.y && height <= p_global_aabb.get_end().y) {
					_generate_triangle_pair(p_vertices, p_uvs, p_lod, p_filter, p_require_nav, x, z);
				}
			}
		}
	}
}

// p_vertices is assumed to exist and the destination for data
// p_uvs might not exist, so a pointer is fine
void Terrain3D::_generate_triangle_pair(PackedVector3Array &p_vertices, PackedVector2Array *p_uvs,
		const int32_t p_lod, const Terrain3DStorage::HeightFilter p_filter, const bool p_require_nav,
		const int32_t x, const int32_t z) const {
	int32_t step = 1 << CLAMP(p_lod, 0, 8);

	Vector3 xz = Vector3(x, 0.0f, z) * _mesh_vertex_spacing;
	Vector3 xsz = Vector3(x + step, 0.0f, z) * _mesh_vertex_spacing;
	Vector3 xzs = Vector3(x, 0.0f, z + step) * _mesh_vertex_spacing;
	Vector3 xszs = Vector3(x + step, 0.0f, z + step) * _mesh_vertex_spacing;

	uint32_t control1 = _storage->get_control(xz);
	uint32_t control2 = _storage->get_control(xszs);
	uint32_t control3 = _storage->get_control(xzs);
	if (!p_require_nav || (is_nav(control1) && is_nav(control2) && is_nav(control3))) {
		Vector3 v1 = _storage->get_mesh_vertex(p_lod, p_filter, xz);
		Vector3 v2 = _storage->get_mesh_vertex(p_lod, p_filter, xszs);
		Vector3 v3 = _storage->get_mesh_vertex(p_lod, p_filter, xzs);
		if (!std::isnan(v1.y) && !std::isnan(v2.y) && !std::isnan(v3.y)) {
			p_vertices.push_back(v1);
			p_vertices.push_back(v2);
			p_vertices.push_back(v3);
			if (p_uvs != nullptr) {
				p_uvs->push_back(Vector2(v1.x, v1.z));
				p_uvs->push_back(Vector2(v2.x, v2.z));
				p_uvs->push_back(Vector2(v3.x, v3.z));
			}
		}
	}

	control1 = _storage->get_control(xz);
	control2 = _storage->get_control(xsz);
	control3 = _storage->get_control(xszs);
	if (!p_require_nav || (is_nav(control1) && is_nav(control2) && is_nav(control3))) {
		Vector3 v1 = _storage->get_mesh_vertex(p_lod, p_filter, xz);
		Vector3 v2 = _storage->get_mesh_vertex(p_lod, p_filter, xsz);
		Vector3 v3 = _storage->get_mesh_vertex(p_lod, p_filter, xszs);
		if (!std::isnan(v1.y) && !std::isnan(v2.y) && !std::isnan(v3.y)) {
			p_vertices.push_back(v1);
			p_vertices.push_back(v2);
			p_vertices.push_back(v3);
			if (p_uvs != nullptr) {
				p_uvs->push_back(Vector2(v1.x, v1.z));
				p_uvs->push_back(Vector2(v2.x, v2.z));
				p_uvs->push_back(Vector2(v3.x, v3.z));
			}
		}
	}
}

///////////////////////////
// Public Functions
///////////////////////////

Terrain3D::Terrain3D() {
	PackedStringArray args = OS::get_singleton()->get_cmdline_args();
	for (int i = args.size() - 1; i >= 0; i--) {
		String arg = args[i];
		if (arg.begins_with("--terrain3d-debug=")) {
			String value = arg.lstrip("--terrain3d-debug=");
			if (value == "ERROR") {
				set_debug_level(ERROR);
			} else if (value == "INFO") {
				set_debug_level(INFO);
			} else if (value == "DEBUG") {
				set_debug_level(DEBUG);
			} else if (value == "DEBUG_CONT") {
				set_debug_level(DEBUG_CONT);
			}
			break;
		}
	}
}

void Terrain3D::set_debug_level(const int p_level) {
	LOG(INFO, "Setting debug level: ", p_level);
	debug_level = CLAMP(p_level, 0, DEBUG_MAX);
}

void Terrain3D::set_mesh_lods(const int p_count) {
	if (_mesh_lods != p_count) {
		_clear_meshes();
		_destroy_collision();
		LOG(INFO, "Setting mesh levels: ", p_count);
		_mesh_lods = p_count;
		_initialize();
	}
}

void Terrain3D::set_mesh_size(const int p_size) {
	if (_mesh_size != p_size) {
		_clear_meshes();
		_destroy_collision();
		LOG(INFO, "Setting mesh size: ", p_size);
		_mesh_size = p_size;
		_initialize();
	}
}

void Terrain3D::set_mesh_vertex_spacing(const real_t p_spacing) {
	real_t spacing = CLAMP(p_spacing, 0.25f, 100.0f);
	if (_mesh_vertex_spacing != spacing) {
		LOG(INFO, "Setting mesh vertex spacing: ", spacing);
		_mesh_vertex_spacing = spacing;
		_clear_meshes();
		_destroy_collision();
		_destroy_instancer();
		_initialize();
	}
	if (IS_EDITOR && _plugin != nullptr) {
		_plugin->call("update_region_grid");
	}
}

void Terrain3D::set_material(const Ref<Terrain3DMaterial> &p_material) {
	if (_material != p_material) {
		_clear_meshes();
		LOG(INFO, "Setting material");
		_material = p_material;
		_initialize();
		emit_signal("material_changed");
	}
}

// This is run after the object has loaded and initialized
void Terrain3D::set_storage(const Ref<Terrain3DStorage> &p_storage) {
	if (_storage != p_storage) {
		_clear_meshes();
		_destroy_collision();
		_destroy_instancer();
		LOG(INFO, "Setting storage");
		_storage = p_storage;
		_initialize();
		emit_signal("storage_changed");
	}
}

void Terrain3D::set_assets(const Ref<Terrain3DAssets> &p_assets) {
	if (_assets != p_assets) {
		_clear_meshes();
		LOG(INFO, "Setting asset list");
		_assets = p_assets;
		_initialize();
		emit_signal("assets_changed");
	}
}

void Terrain3D::set_editor(Terrain3DEditor *p_editor) {
	_editor = p_editor;
	LOG(DEBUG, "Received Terrain3DEditor: ", p_editor);
}

void Terrain3D::set_plugin(EditorPlugin *p_plugin) {
	_plugin = p_plugin;
	LOG(DEBUG, "Received editor plugin: ", p_plugin);
}

void Terrain3D::set_camera(Camera3D *p_camera) {
	if (_camera != p_camera) {
		_camera = p_camera;
		if (p_camera == nullptr) {
			LOG(DEBUG, "Received null camera. Calling _grab_camera()");
			_grab_camera();
		} else {
			_camera = p_camera;
			_camera_instance_id = _camera->get_instance_id();
			LOG(DEBUG, "Setting camera: ", _camera);
			_initialize();
			set_process(true); // enable __process snapping
		}
	}
}

void Terrain3D::set_render_layers(const uint32_t p_layers) {
	LOG(INFO, "Setting terrain render layers to: ", p_layers);
	_render_layers = p_layers;
	_update_mesh_instances();
}

void Terrain3D::set_mouse_layer(const uint32_t p_layer) {
	uint32_t layer = CLAMP(p_layer, 21, 32);
	_mouse_layer = layer;
	uint32_t mouse_mask = 1 << (_mouse_layer - 1);
	LOG(INFO, "Setting mouse layer: ", layer, " (", mouse_mask, ") on terrain mesh, material, mouse camera, mouse quad");

	// Set terrain meshes to mouse layer
	// Mask off editor render layers by ORing user layers 1-20 and current mouse layer
	set_render_layers((_render_layers & 0xFFFFF) | mouse_mask);
	// Set terrain shader to exclude mouse camera from showing holes
	if (_material != nullptr) {
		_material->set_shader_param("_mouse_layer", mouse_mask);
	}
	// Set mouse camera to see only mouse layer
	if (_mouse_cam != nullptr) {
		_mouse_cam->set_cull_mask(mouse_mask);
	}
	// Set screenquad to mouse layer
	if (_mouse_quad != nullptr) {
		_mouse_quad->set_layer_mask(mouse_mask);
	}
}

void Terrain3D::set_cast_shadows(const GeometryInstance3D::ShadowCastingSetting p_cast_shadows) {
	_cast_shadows = p_cast_shadows;
	_update_mesh_instances();
}

void Terrain3D::set_cull_margin(const real_t p_margin) {
	LOG(INFO, "Setting extra cull margin: ", p_margin);
	_cull_margin = p_margin;
	update_aabbs();
}

void Terrain3D::set_collision_enabled(const bool p_enabled) {
	LOG(INFO, "Setting collision enabled: ", p_enabled);
	_collision_enabled = p_enabled;
	if (_collision_enabled) {
		_build_collision();
	} else {
		_destroy_collision();
	}
}

void Terrain3D::set_show_debug_collision(const bool p_enabled) {
	LOG(INFO, "Setting show collision: ", p_enabled);
	_show_debug_collision = p_enabled;
	_destroy_collision();
	if (_storage.is_valid() && _show_debug_collision) {
		_build_collision();
	}
}

void Terrain3D::set_collision_layer(const uint32_t p_layers) {
	LOG(INFO, "Setting collision layers: ", p_layers);
	_collision_layer = p_layers;
	if (_show_debug_collision) {
		if (_debug_static_body != nullptr) {
			_debug_static_body->set_collision_layer(_collision_layer);
		}
	} else {
		if (_static_body.is_valid()) {
			PhysicsServer3D::get_singleton()->body_set_collision_layer(_static_body, _collision_layer);
		}
	}
}

void Terrain3D::set_collision_mask(const uint32_t p_mask) {
	LOG(INFO, "Setting collision mask: ", p_mask);
	_collision_mask = p_mask;
	if (_show_debug_collision) {
		if (_debug_static_body != nullptr) {
			_debug_static_body->set_collision_mask(_collision_mask);
		}
	} else {
		if (_static_body.is_valid()) {
			PhysicsServer3D::get_singleton()->body_set_collision_mask(_static_body, _collision_mask);
		}
	}
}

void Terrain3D::set_collision_priority(const real_t p_priority) {
	LOG(INFO, "Setting collision priority: ", p_priority);
	_collision_priority = p_priority;
	if (_show_debug_collision) {
		if (_debug_static_body != nullptr) {
			_debug_static_body->set_collision_priority(_collision_priority);
		}
	} else {
		if (_static_body.is_valid()) {
			PhysicsServer3D::get_singleton()->body_set_collision_priority(_static_body, _collision_priority);
		}
	}
}

RID Terrain3D::get_collision_rid() const {
	if (!_show_debug_collision) {
		return _static_body;
	} else {
		if (_debug_static_body != nullptr) {
			return _debug_static_body->get_rid();
		}
	}
	return RID();
}

/**
 * Centers the terrain and LODs on a provided position. Y height is ignored.
 */
void Terrain3D::snap(const Vector3 &p_cam_pos) {
	Vector3 cam_pos = p_cam_pos;
	cam_pos.y = 0;
	LOG(DEBUG_CONT, "Snapping terrain to: ", String(cam_pos));
	Vector3 snapped_pos = (cam_pos / _mesh_vertex_spacing).floor() * _mesh_vertex_spacing;
	Transform3D t = Transform3D().scaled(Vector3(_mesh_vertex_spacing, 1, _mesh_vertex_spacing));
	t.origin = snapped_pos;
	RS->instance_set_transform(_data.cross, t);

	int edge = 0;
	int tile = 0;

	for (int l = 0; l < _mesh_lods; l++) {
		real_t scale = real_t(1 << l) * _mesh_vertex_spacing;
		snapped_pos = (cam_pos / scale).floor() * scale;
		Vector3 tile_size = Vector3(real_t(_mesh_size << l), 0, real_t(_mesh_size << l)) * _mesh_vertex_spacing;
		Vector3 base = snapped_pos - Vector3(real_t(_mesh_size << (l + 1)), 0.f, real_t(_mesh_size << (l + 1))) * _mesh_vertex_spacing;

		// Position tiles
		for (int x = 0; x < 4; x++) {
			for (int y = 0; y < 4; y++) {
				if (l != 0 && (x == 1 || x == 2) && (y == 1 || y == 2)) {
					continue;
				}

				Vector3 fill = Vector3(x >= 2 ? 1.f : 0.f, 0.f, y >= 2 ? 1.f : 0.f) * scale;
				Vector3 tile_tl = base + Vector3(x, 0.f, y) * tile_size + fill;
				//Vector3 tile_br = tile_tl + tile_size;

				Transform3D t = Transform3D().scaled(Vector3(scale, 1.f, scale));
				t.origin = tile_tl;

				RS->instance_set_transform(_data.tiles[tile], t);

				tile++;
			}
		}
		{
			Transform3D t = Transform3D().scaled(Vector3(scale, 1.f, scale));
			t.origin = snapped_pos;
			RS->instance_set_transform(_data.fillers[l], t);
		}

		if (l != _mesh_lods - 1) {
			real_t next_scale = scale * 2.0f;
			Vector3 next_snapped_pos = (cam_pos / next_scale).floor() * next_scale;

			// Position trims
			{
				Vector3 tile_center = snapped_pos + (Vector3(scale, 0.f, scale) * 0.5f);
				Vector3 d = cam_pos - next_snapped_pos;

				int r = 0;
				r |= d.x >= scale ? 0 : 2;
				r |= d.z >= scale ? 0 : 1;

				real_t rotations[4] = { 0.f, 270.f, 90.f, 180.f };

				real_t angle = UtilityFunctions::deg_to_rad(rotations[r]);
				Transform3D t = Transform3D().rotated(Vector3(0.f, 1.f, 0.f), -angle);
				t = t.scaled(Vector3(scale, 1.f, scale));
				t.origin = tile_center;
				RS->instance_set_transform(_data.trims[edge], t);
			}

			// Position seams
			{
				Vector3 next_base = next_snapped_pos - Vector3(real_t(_mesh_size << (l + 1)), 0.f, real_t(_mesh_size << (l + 1))) * _mesh_vertex_spacing;
				Transform3D t = Transform3D().scaled(Vector3(scale, 1.f, scale));
				t.origin = next_base;
				RS->instance_set_transform(_data.seams[edge], t);
			}
			edge++;
		}
	}
}

void Terrain3D::update_aabbs() {
	if (_meshes.is_empty() || _storage.is_null()) {
		LOG(DEBUG, "Update AABB called before terrain meshes built. Returning.");
		return;
	}

	Vector2 height_range = _storage->get_height_range();
	LOG(DEBUG_CONT, "Updating AABBs. Total height range: ", height_range, ", extra cull margin: ", _cull_margin);
	height_range.y += abs(height_range.x); // Add below zero to total size

	AABB aabb = RS->mesh_get_custom_aabb(_meshes[GeoClipMap::CROSS]);
	aabb.position.y = height_range.x;
	aabb.size.y = height_range.y;
	RS->instance_set_custom_aabb(_data.cross, aabb);
	RS->instance_set_extra_visibility_margin(_data.cross, _cull_margin);

	aabb = RS->mesh_get_custom_aabb(_meshes[GeoClipMap::TILE]);
	aabb.position.y = height_range.x;
	aabb.size.y = height_range.y;
	for (int i = 0; i < _data.tiles.size(); i++) {
		RS->instance_set_custom_aabb(_data.tiles[i], aabb);
		RS->instance_set_extra_visibility_margin(_data.tiles[i], _cull_margin);
	}

	aabb = RS->mesh_get_custom_aabb(_meshes[GeoClipMap::FILLER]);
	aabb.position.y = height_range.x;
	aabb.size.y = height_range.y;
	for (int i = 0; i < _data.fillers.size(); i++) {
		RS->instance_set_custom_aabb(_data.fillers[i], aabb);
		RS->instance_set_extra_visibility_margin(_data.fillers[i], _cull_margin);
	}

	aabb = RS->mesh_get_custom_aabb(_meshes[GeoClipMap::TRIM]);
	aabb.position.y = height_range.x;
	aabb.size.y = height_range.y;
	for (int i = 0; i < _data.trims.size(); i++) {
		RS->instance_set_custom_aabb(_data.trims[i], aabb);
		RS->instance_set_extra_visibility_margin(_data.trims[i], _cull_margin);
	}

	aabb = RS->mesh_get_custom_aabb(_meshes[GeoClipMap::SEAM]);
	aabb.position.y = height_range.x;
	aabb.size.y = height_range.y;
	for (int i = 0; i < _data.seams.size(); i++) {
		RS->instance_set_custom_aabb(_data.seams[i], aabb);
		RS->instance_set_extra_visibility_margin(_data.seams[i], _cull_margin);
	}
}

/* Iterate over ground to find intersection point between two rays:
 *	p_src_pos (camera position)
 *	p_direction (camera direction looking at the terrain)
 *	test_dir (camera direction 0 Y, traversing terrain along height
 * Returns vec3(Double max 3.402823466e+38F) on no intersection. Test w/ if (var.x < 3.4e38)
 */
Vector3 Terrain3D::get_intersection(const Vector3 &p_src_pos, const Vector3 &p_direction) {
	if (!is_instance_valid(_camera_instance_id)) {
		LOG(ERROR, "Invalid camera");
		return Vector3(NAN, NAN, NAN);
	}
	if (_mouse_cam == nullptr) {
		LOG(ERROR, "Invalid mouse camera");
		return Vector3(NAN, NAN, NAN);
	}
	Vector3 direction = p_direction.normalized();
	Vector3 point;

	// Position mouse cam one unit behind the requested position
	_mouse_cam->set_global_position(p_src_pos - direction);

	// If looking straight down (eg orthogonal camera), look_at won't work
	if ((direction - Vector3(0.f, -1.f, 0.f)).length_squared() < 0.00001f) {
		_mouse_cam->set_rotation_degrees(Vector3(-90.f, 0.f, 0.f));
		point = p_src_pos;
		point.y = _storage->get_height(p_src_pos);
		if (std::isnan(point.y)) {
			point.y = 0;
		}
	} else {
		// Get depth from perspective camera snapshot
		_mouse_cam->look_at(_mouse_cam->get_global_position() + direction, Vector3(0.f, 1.f, 0.f));
		_mouse_vp->set_update_mode(SubViewport::UPDATE_ONCE);
		Ref<ViewportTexture> vp_tex = _mouse_vp->get_texture();
		Ref<Image> vp_img = vp_tex->get_image();

		// Read the depth pixel from the camera viewport
		Color screen_depth = vp_img->get_pixel(0, 0);

		// Get position from depth packed in RG - unpack back to float.
		// Needed for Mobile renderer
		// https://gamedev.stackexchange.com/questions/201151/24bit-float-to-rgb
		Vector2 screen_rg = Vector2(screen_depth.r, screen_depth.g);
		real_t normalized_distance = screen_rg.dot(Vector2(1.f, 1.f / 255.f));
		if (normalized_distance < 0.00001f) {
			return Vector3(__FLT_MAX__, __FLT_MAX__, __FLT_MAX__);
		}
		// Necessary for a correct value depth = 1
		if (normalized_distance > 0.9999f) {
			normalized_distance = 1.0f;
		}

		// Denormalize distance to get real depth and terrain position
		real_t depth = normalized_distance * _mouse_cam->get_far();
		point = _mouse_cam->get_global_position() + direction * depth;
	}

	return point;
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
Ref<Mesh> Terrain3D::bake_mesh(const int p_lod, const Terrain3DStorage::HeightFilter p_filter) const {
	LOG(INFO, "Baking mesh at lod: ", p_lod, " with filter: ", p_filter);
	Ref<Mesh> result;
	ERR_FAIL_COND_V(!_storage.is_valid(), result);

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
PackedVector3Array Terrain3D::generate_nav_mesh_source_geometry(const AABB &p_global_aabb, const bool p_require_nav) const {
	LOG(INFO, "Generating NavMesh source geometry from terrain");
	PackedVector3Array faces;
	_generate_triangles(faces, nullptr, 0, Terrain3DStorage::HEIGHT_FILTER_NEAREST, p_require_nav, p_global_aabb);
	return faces;
}

PackedStringArray Terrain3D::_get_configuration_warnings() const {
	PackedStringArray psa;
	if (_storage.is_valid()) {
		String ext = _storage->get_path().get_extension();
		if (ext != "res") {
			psa.push_back("Storage resource is not saved as a binary resource file. Click the arrow to the right of `Storage`, then `Save As...` a `*.res` file.");
		}
	}
	if (!psa.is_empty()) {
		psa.push_back("To update this message, deselect and reselect Terrain3D in the Scene panel.");
	}
	return psa;
}

// DEPRECATED 0.9.2 - Remove 0.9.3+
void Terrain3D::set_texture_list(const Ref<Terrain3DTextureList> &p_texture_list) {
	if (p_texture_list.is_null()) {
		LOG(ERROR, "Attempted to upgrade Terrain3DTextureList, but received null (perhaps already a Terrain3DAssets). Reconnect manually and save.");
		return;
	}
	LOG(WARN, "Loaded Terrain3DTextureList. Converting to Terrain3DAssets. Save this scene to complete.");
	Ref<Terrain3DAssets> assets;
	assets.instantiate();
	assets->set_texture_list(p_texture_list->get_textures());
	assets->take_over_path(p_texture_list->get_path());
	set_assets(assets);
}

///////////////////////////
// Protected Functions
///////////////////////////

// Notifications are defined in individual classes: Object, Node, Node3D
// Listed below in order of operation
void Terrain3D::_notification(const int p_what) {
	switch (p_what) {
			/// Startup notifications

		case NOTIFICATION_POSTINITIALIZE: {
			// Object initialized, before script is attached
			LOG(INFO, "NOTIFICATION_POSTINITIALIZE");
			break;
		}

		case NOTIFICATION_ENTER_WORLD: {
			// Node3D registered to new World3D resource
			// Sent on scene changes
			LOG(INFO, "NOTIFICATION_ENTER_WORLD");
			_is_inside_world = true;
			_update_mesh_instances();
			break;
		}

		case NOTIFICATION_ENTER_TREE: {
			// Node entered a SceneTree
			// Sent on scene changes
			LOG(INFO, "NOTIFICATION_ENTER_TREE");
			set_as_top_level(true); // Don't inherit transforms from parent. Global only.
			set_notify_transform(true);
			_setup_mouse_picking();
			_initialize();
			set_process(true);
			break;
		}

		case NOTIFICATION_READY: {
			// Node is ready
			LOG(INFO, "NOTIFICATION_READY");
			break;
		}

			/// Game Loop notifications

		case NOTIFICATION_PROCESS: {
			// Node is processing one frame
			__process(get_process_delta_time());
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
			_update_mesh_instances();
			break;
		}

		case NOTIFICATION_EXTENSION_RELOADED: {
			// Object finished hot reloading
			LOG(INFO, "NOTIFICATION_EXTENSION_RELOADED");
			break;
		}

		case NOTIFICATION_EDITOR_PRE_SAVE: {
			// Editor Node is about to the current scene
			LOG(INFO, "NOTIFICATION_EDITOR_PRE_SAVE");
			if (!_storage.is_valid()) {
				LOG(DEBUG, "Save requested, but no valid storage. Skipping");
			} else {
				_storage->save();
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
			// Only on desktop if the crash handler is enabled
			LOG(WARN, "NOTIFICATION_CRASH");
			break;
		}

			/// Shut down notifications

		case NOTIFICATION_EXIT_TREE: {
			// Node is about to exit a SceneTree
			// Sent on scene changes
			LOG(INFO, "NOTIFICATION_EXIT_TREE");
			set_process(false);
			_clear_meshes();
			_destroy_collision();
			_destroy_mouse_picking();
			_destroy_instancer();
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
			break;
		}

		default:
			break;
	}
}

void Terrain3D::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_version"), &Terrain3D::get_version);
	ClassDB::bind_method(D_METHOD("set_debug_level", "level"), &Terrain3D::set_debug_level);
	ClassDB::bind_method(D_METHOD("get_debug_level"), &Terrain3D::get_debug_level);
	ClassDB::bind_method(D_METHOD("set_mesh_lods", "count"), &Terrain3D::set_mesh_lods);
	ClassDB::bind_method(D_METHOD("get_mesh_lods"), &Terrain3D::get_mesh_lods);
	ClassDB::bind_method(D_METHOD("set_mesh_size", "size"), &Terrain3D::set_mesh_size);
	ClassDB::bind_method(D_METHOD("get_mesh_size"), &Terrain3D::get_mesh_size);
	ClassDB::bind_method(D_METHOD("set_mesh_vertex_spacing", "scale"), &Terrain3D::set_mesh_vertex_spacing);
	ClassDB::bind_method(D_METHOD("get_mesh_vertex_spacing"), &Terrain3D::get_mesh_vertex_spacing);

	ClassDB::bind_method(D_METHOD("set_material", "material"), &Terrain3D::set_material);
	ClassDB::bind_method(D_METHOD("get_material"), &Terrain3D::get_material);
	ClassDB::bind_method(D_METHOD("set_storage", "storage"), &Terrain3D::set_storage);
	ClassDB::bind_method(D_METHOD("get_storage"), &Terrain3D::get_storage);
	ClassDB::bind_method(D_METHOD("set_assets", "assets"), &Terrain3D::set_assets);
	ClassDB::bind_method(D_METHOD("get_assets"), &Terrain3D::get_assets);
	ClassDB::bind_method(D_METHOD("get_instancer"), &Terrain3D::get_instancer);

	ClassDB::bind_method(D_METHOD("set_editor", "editor"), &Terrain3D::set_editor);
	ClassDB::bind_method(D_METHOD("get_editor"), &Terrain3D::get_editor);
	ClassDB::bind_method(D_METHOD("set_plugin", "plugin"), &Terrain3D::set_plugin);
	ClassDB::bind_method(D_METHOD("get_plugin"), &Terrain3D::get_plugin);
	ClassDB::bind_method(D_METHOD("set_camera", "camera"), &Terrain3D::set_camera);
	ClassDB::bind_method(D_METHOD("get_camera"), &Terrain3D::get_camera);

	ClassDB::bind_method(D_METHOD("set_render_layers", "layers"), &Terrain3D::set_render_layers);
	ClassDB::bind_method(D_METHOD("get_render_layers"), &Terrain3D::get_render_layers);
	ClassDB::bind_method(D_METHOD("set_mouse_layer", "layer"), &Terrain3D::set_mouse_layer);
	ClassDB::bind_method(D_METHOD("get_mouse_layer"), &Terrain3D::get_mouse_layer);
	ClassDB::bind_method(D_METHOD("set_cast_shadows", "shadow_casting_setting"), &Terrain3D::set_cast_shadows);
	ClassDB::bind_method(D_METHOD("get_cast_shadows"), &Terrain3D::get_cast_shadows);
	ClassDB::bind_method(D_METHOD("set_cull_margin", "margin"), &Terrain3D::set_cull_margin);
	ClassDB::bind_method(D_METHOD("get_cull_margin"), &Terrain3D::get_cull_margin);

	ClassDB::bind_method(D_METHOD("set_collision_enabled", "enabled"), &Terrain3D::set_collision_enabled);
	ClassDB::bind_method(D_METHOD("get_collision_enabled"), &Terrain3D::get_collision_enabled);
	ClassDB::bind_method(D_METHOD("set_show_debug_collision", "enabled"), &Terrain3D::set_show_debug_collision);
	ClassDB::bind_method(D_METHOD("get_show_debug_collision"), &Terrain3D::get_show_debug_collision);
	ClassDB::bind_method(D_METHOD("set_collision_layer", "layers"), &Terrain3D::set_collision_layer);
	ClassDB::bind_method(D_METHOD("get_collision_layer"), &Terrain3D::get_collision_layer);
	ClassDB::bind_method(D_METHOD("set_collision_mask", "mask"), &Terrain3D::set_collision_mask);
	ClassDB::bind_method(D_METHOD("get_collision_mask"), &Terrain3D::get_collision_mask);
	ClassDB::bind_method(D_METHOD("set_collision_priority", "priority"), &Terrain3D::set_collision_priority);
	ClassDB::bind_method(D_METHOD("get_collision_priority"), &Terrain3D::get_collision_priority);
	ClassDB::bind_method(D_METHOD("get_collision_rid"), &Terrain3D::get_collision_rid);

	ClassDB::bind_method(D_METHOD("get_intersection", "src_pos", "direction"), &Terrain3D::get_intersection);
	ClassDB::bind_method(D_METHOD("bake_mesh", "lod", "filter"), &Terrain3D::bake_mesh);
	ClassDB::bind_method(D_METHOD("generate_nav_mesh_source_geometry", "global_aabb", "require_nav"), &Terrain3D::generate_nav_mesh_source_geometry, DEFVAL(true));

	ADD_PROPERTY(PropertyInfo(Variant::STRING, "version", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_version");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "storage", PROPERTY_HINT_RESOURCE_TYPE, "Terrain3DStorage"), "set_storage", "get_storage");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "material", PROPERTY_HINT_RESOURCE_TYPE, "Terrain3DMaterial"), "set_material", "get_material");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "assets", PROPERTY_HINT_RESOURCE_TYPE, "Terrain3DAssets"), "set_assets", "get_assets");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "instancer", PROPERTY_HINT_NONE, "Terrain3DInstancer", PROPERTY_USAGE_NONE), "", "get_instancer");

	ADD_GROUP("Renderer", "render_");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "render_layers", PROPERTY_HINT_LAYERS_3D_RENDER), "set_render_layers", "get_render_layers");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "render_mouse_layer", PROPERTY_HINT_RANGE, "21, 32"), "set_mouse_layer", "get_mouse_layer");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "render_cast_shadows", PROPERTY_HINT_ENUM, "Off,On,Double-Sided,Shadows Only"), "set_cast_shadows", "get_cast_shadows");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "render_cull_margin", PROPERTY_HINT_RANGE, "0, 10000, 1, or_greater"), "set_cull_margin", "get_cull_margin");

	ADD_GROUP("Collision", "collision_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "collision_enabled"), "set_collision_enabled", "get_collision_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_layer", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_layer", "get_collision_layer");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_mask", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_mask", "get_collision_mask");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "collision_priority"), "set_collision_priority", "get_collision_priority");

	ADD_GROUP("Mesh", "mesh_");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mesh_lods", PROPERTY_HINT_RANGE, "1,10,1"), "set_mesh_lods", "get_mesh_lods");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mesh_size", PROPERTY_HINT_RANGE, "8,64,1"), "set_mesh_size", "get_mesh_size");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "mesh_vertex_spacing", PROPERTY_HINT_RANGE, "0.25,10.0,0.05,or_greater"), "set_mesh_vertex_spacing", "get_mesh_vertex_spacing");

	ADD_GROUP("Debug", "debug_");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "debug_level", PROPERTY_HINT_ENUM, "Errors,Info,Debug,Debug Continuous"), "set_debug_level", "get_debug_level");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_show_collision"), "set_show_debug_collision", "get_show_debug_collision");

	ADD_SIGNAL(MethodInfo("material_changed"));
	ADD_SIGNAL(MethodInfo("storage_changed"));
	ADD_SIGNAL(MethodInfo("assets_changed"));

	// DEPRECATED 0.9.2 - Remove 0.9.3+
	ClassDB::bind_method(D_METHOD("set_texture_list", "texture_list"), &Terrain3D::set_texture_list);
	ClassDB::bind_method(D_METHOD("get_texture_list"), &Terrain3D::get_texture_list);
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "texture_list", PROPERTY_HINT_RESOURCE_TYPE, "Terrain3DTextureList", PROPERTY_USAGE_NONE), "set_texture_list", "get_texture_list");
}
