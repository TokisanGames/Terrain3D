// Copyright © 2023 Roope Palmroos, Cory Petkovsek, and Contributors. All rights reserved. See LICENSE.
#include <godot_cpp/classes/collision_shape3d.hpp>
#include <godot_cpp/classes/height_map_shape3d.hpp>
#include <godot_cpp/core/class_db.hpp>

#include "terrain_3d.h"
#include "terrain_3d_logger.h"

///////////////////////////
// Private Functions
///////////////////////////

// Initialize static member variable
int Terrain3D::_debug_level{ ERROR };

/**
 * This is a proxy for _process(delta) called by _notification() due to
 * https://github.com/godotengine/godot-cpp/issues/1022
 */
void Terrain3D::__process(double delta) {
	if (!_valid)
		return;

	// If the game/editor camera is not set, find it
	if (_camera == nullptr) {
		LOG(DEBUG, "camera is null, getting the current one");
		_grab_camera();
	}

	// If camera has moved significantly, center the terrain on it.
	if (_camera != nullptr) {
		Vector3 cam_pos = _camera->get_global_position();
		Vector2 cam_pos_2d = Vector2(cam_pos.x, cam_pos.z);
		if (_camera_last_position.distance_to(cam_pos_2d) > _clipmap_size * .5) {
			snap(cam_pos);
			_camera_last_position = cam_pos_2d;
		}
	}
}

/**
 * If running in the editor, recurses into the editor scene tree to find the editor cameras and grabs the first one.
 * The edited_scene_root is excluded in case the user already has a Camera3D in their scene.
 */
void Terrain3D::_grab_camera() {
	if (Engine::get_singleton()->is_editor_hint()) {
		EditorScript temp_editor_script;
		EditorInterface *editor_interface = temp_editor_script.get_editor_interface();
		TypedArray<Camera3D> cam_array = TypedArray<Camera3D>();
		_find_cameras(editor_interface->get_editor_main_screen()->get_children(), editor_interface->get_edited_scene_root(), cam_array);
		if (!cam_array.is_empty()) {
			LOG(DEBUG, "Connecting to the first editor camera");
			_camera = Object::cast_to<Camera3D>(cam_array[0]);
		}
	} else {
		LOG(DEBUG, "Connecting to the in-game viewport camera");
		_camera = get_viewport()->get_camera_3d();
	}
}

/**
 * Recursive helper function for _grab_camera().
 */
void Terrain3D::_find_cameras(TypedArray<Node> from_nodes, Node *excluded_node, TypedArray<Camera3D> &cam_array) {
	for (int i = 0; i < from_nodes.size(); i++) {
		Node *node = Object::cast_to<Node>(from_nodes[i]);
		if (node != excluded_node) {
			_find_cameras(node->get_children(), excluded_node, cam_array);
		}
		if (node->is_class("Camera3D")) {
			LOG(DEBUG, "Found a Camera3D at: ", node->get_path());
			cam_array.push_back(node);
		}
	}
}

void Terrain3D::_build_collision() {
	if (!_collision_enabled) {
		return;
	}
	// Create collision only in game, unless showing debug
	if (Engine::get_singleton()->is_editor_hint() && !_show_debug_collision) {
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
	} else {
		LOG(WARN, "Building debug collision. Disable this mode for releases");
		_debug_static_body = memnew(StaticBody3D);
		_debug_static_body->set_name("StaticBody3D");
		add_child(_debug_static_body, true);
		_debug_static_body->set_owner(this);
	}
	_update_collision();
}

void Terrain3D::_update_collision() {
	if (!_collision_enabled) {
		return;
	}
	// Create collision only in game, unless showing debug
	if (Engine::get_singleton()->is_editor_hint() && !_show_debug_collision) {
		return;
	}
	if ((!_show_debug_collision && !_static_body.is_valid()) ||
			(_show_debug_collision && _debug_static_body == nullptr)) {
		_build_collision();
	}

	int region_size = _storage->get_region_size();
	int shape_size = region_size + 1;

	for (int i = 0; i < _storage->get_region_count(); i++) {
		Dictionary shape_data;
		PackedFloat32Array map_data = PackedFloat32Array();

		Ref<Image> hmap = _storage->get_map_region(Terrain3DStorage::TYPE_HEIGHT, i);
		Vector2i hmap_size = hmap->get_size();
		map_data.resize(shape_size * shape_size);

		for (int z = 0; z < shape_size; z++) {
			for (int x = 0; x < shape_size; x++) {
				// Choose array indexing to match triangulation of heightmapshape with the mesh
				// https://stackoverflow.com/questions/16684856/rotating-a-2d-pixel-array-by-90-degrees
				// Normal array index rotated Y=0 - shape rotation Y=0 (xform below)
				// int index = z * shape_size + x;
				// Array Index Rotated Y=-90 - must rotate shape Y=+90 (xform below)
				int index = shape_size - 1 - z + x * shape_size;
				Vector2i point = Vector2i(Vector2(hmap_size) * Vector2(x, z) / float(shape_size));
				map_data[index] = hmap->get_pixelv(point).r;
			}
		}

		Vector2i region_offset = _storage->get_region_offsets()[i];
		// Transform3D xform = Transform3D(Basis(),
		// Non rotated shape for normal array index above
		// Rotated shape Y=90 for -90 rotated array index
		Transform3D xform = Transform3D(Basis(Vector3(0, 1.0, 0), PI * .5),
				Vector3(region_offset.x, 0, region_offset.y) * region_size);

		shape_data["width"] = shape_size;
		shape_data["depth"] = shape_size;
		shape_data["heights"] = map_data;
		Vector2 min_max = _storage->get_height_range();
		shape_data["min_height"] = min_max.x;
		shape_data["max_height"] = min_max.y;

		if (!_show_debug_collision) {
			RID shape = PhysicsServer3D::get_singleton()->heightmap_shape_create();
			PhysicsServer3D::get_singleton()->body_add_shape(_static_body, shape);
			PhysicsServer3D::get_singleton()->shape_set_data(shape, shape_data);
			PhysicsServer3D::get_singleton()->body_set_shape_transform(_static_body, i, xform);
			PhysicsServer3D::get_singleton()->body_set_collision_mask(_static_body, _collision_mask);
			PhysicsServer3D::get_singleton()->body_set_collision_layer(_static_body, _collision_layer);
			PhysicsServer3D::get_singleton()->body_set_collision_priority(_static_body, _collision_priority);
		} else {
			CollisionShape3D *debug_col_shape;
			debug_col_shape = memnew(CollisionShape3D);
			debug_col_shape->set_name("CollisionShape3D");
			_debug_static_body->add_child(debug_col_shape, true);
			debug_col_shape->set_owner(this);

			Ref<HeightMapShape3D> hshape;
			hshape.instantiate();
			hshape->set_map_width(shape_size);
			hshape->set_map_depth(shape_size);
			hshape->set_map_data(map_data);
			debug_col_shape->set_shape(hshape);
			debug_col_shape->set_global_transform(xform);
		}
	}
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
			memfree(child);
		}

		LOG(DEBUG, "Freeing static body");
		remove_child(_debug_static_body);
		memfree(_debug_static_body);
		_debug_static_body = nullptr;
	}
}

/**
 * Make all mesh instances visible or not
 * Update all mesh instances with the new world scenario so they appear
 */
void Terrain3D::_update_instances() {
	if (!is_inside_tree() || !_valid || !_is_inside_world) {
		return;
	}
	if (_static_body.is_valid()) {
		RID _space = get_world_3d()->get_space();
		PhysicsServer3D::get_singleton()->body_set_space(_static_body, _space);
	}

	RID _scenario = get_world_3d()->get_scenario();

	bool v = is_visible_in_tree();
	RenderingServer::get_singleton()->instance_set_visible(_data.cross, v);
	RenderingServer::get_singleton()->instance_set_scenario(_data.cross, _scenario);
	RenderingServer::get_singleton()->instance_geometry_set_cast_shadows_setting(_data.cross, RenderingServer::ShadowCastingSetting(_shadow_casting_setting));
	RenderingServer::get_singleton()->instance_set_layer_mask(_data.cross, _visual_layers);

	for (const RID rid : _data.tiles) {
		RenderingServer::get_singleton()->instance_set_visible(rid, v);
		RenderingServer::get_singleton()->instance_set_scenario(rid, _scenario);
		RenderingServer::get_singleton()->instance_geometry_set_cast_shadows_setting(rid, RenderingServer::ShadowCastingSetting(_shadow_casting_setting));
		RenderingServer::get_singleton()->instance_set_layer_mask(rid, _visual_layers);
	}

	for (const RID rid : _data.fillers) {
		RenderingServer::get_singleton()->instance_set_visible(rid, v);
		RenderingServer::get_singleton()->instance_set_scenario(rid, _scenario);
		RenderingServer::get_singleton()->instance_geometry_set_cast_shadows_setting(rid, RenderingServer::ShadowCastingSetting(_shadow_casting_setting));
		RenderingServer::get_singleton()->instance_set_layer_mask(rid, _visual_layers);
	}

	for (const RID rid : _data.trims) {
		RenderingServer::get_singleton()->instance_set_visible(rid, v);
		RenderingServer::get_singleton()->instance_set_scenario(rid, _scenario);
		RenderingServer::get_singleton()->instance_geometry_set_cast_shadows_setting(rid, RenderingServer::ShadowCastingSetting(_shadow_casting_setting));
		RenderingServer::get_singleton()->instance_set_layer_mask(rid, _visual_layers);
	}

	for (const RID rid : _data.seams) {
		RenderingServer::get_singleton()->instance_set_visible(rid, v);
		RenderingServer::get_singleton()->instance_set_scenario(rid, _scenario);
		RenderingServer::get_singleton()->instance_geometry_set_cast_shadows_setting(rid, RenderingServer::ShadowCastingSetting(_shadow_casting_setting));
		RenderingServer::get_singleton()->instance_set_layer_mask(rid, _visual_layers);
	}
}

///////////////////////////
// Public Functions
///////////////////////////

Terrain3D::Terrain3D() {
	set_notify_transform(true);
}

Terrain3D::~Terrain3D() {
	_destroy_collision();
}

void Terrain3D::set_debug_level(int p_level) {
	LOG(INFO, "Setting debug level: ", p_level);
	_debug_level = CLAMP(p_level, 0, DEBUG_MAX);
}

void Terrain3D::set_clipmap_levels(int p_count) {
	if (_clipmap_levels != p_count) {
		LOG(INFO, "Setting clipmap levels: ", p_count);
		clear();
		build(p_count, _clipmap_size);
		_clipmap_levels = p_count;
	}
}

void Terrain3D::set_clipmap_size(int p_size) {
	if (_clipmap_size != p_size) {
		LOG(INFO, "Setting clipmap size: ", p_size);
		clear();
		build(_clipmap_levels, p_size);
		_clipmap_size = p_size;
	}
}

void Terrain3D::set_storage(const Ref<Terrain3DStorage> &p_storage) {
	if (_storage != p_storage) {
		LOG(INFO, "Setting storage");
		_storage = p_storage;
		clear();

		if (_storage.is_valid()) {
			_storage->connect("height_maps_changed", Callable(this, "update_aabbs"));
			if (_storage->get_region_count() == 0) {
				LOG(DEBUG, "Region count 0, adding new region");
				_storage->call_deferred("add_region", Vector3(0, 0, 0));
			}
			build(_clipmap_levels, _clipmap_size);
		}
		emit_signal("storage_changed");
	}
}

void Terrain3D::set_plugin(EditorPlugin *p_plugin) {
	_plugin = p_plugin;
	LOG(DEBUG, "Received editor plugin: ", p_plugin);
}

void Terrain3D::set_camera(Camera3D *p_camera) {
	_camera = p_camera;
	if (p_camera == nullptr) {
		LOG(DEBUG, "Received null camera. Calling _grab_camera");
		_grab_camera();
	} else {
		LOG(DEBUG, "Setting camera: ", p_camera);
		_camera = p_camera;
	}
}

void Terrain3D::set_collision_enabled(bool p_enabled) {
	LOG(INFO, "Setting collision enabled: ", p_enabled);
	_collision_enabled = p_enabled;
	if (_collision_enabled) {
		_build_collision();
	} else {
		_destroy_collision();
	}
}

void Terrain3D::set_show_debug_collision(bool p_enabled) {
	LOG(INFO, "Setting show collision: ", p_enabled);
	_show_debug_collision = p_enabled;
	_destroy_collision();
	if (_storage.is_valid() && _show_debug_collision) {
		_build_collision();
	}
}

void Terrain3D::set_layer_mask(uint32_t p_mask) {
	_visual_layers = p_mask;
	_update_instances();
}

void Terrain3D::set_cast_shadows_setting(GeometryInstance3D::ShadowCastingSetting p_shadow_casting_setting) {
	_shadow_casting_setting = p_shadow_casting_setting;
	_update_instances();
}

void Terrain3D::clear(bool p_clear_meshes, bool p_clear_collision) {
	LOG(INFO, "Clearing the terrain");
	if (p_clear_meshes) {
		for (const RID rid : _meshes) {
			RenderingServer::get_singleton()->free_rid(rid);
		}

		RenderingServer::get_singleton()->free_rid(_data.cross);

		for (const RID rid : _data.tiles) {
			RenderingServer::get_singleton()->free_rid(rid);
		}

		for (const RID rid : _data.fillers) {
			RenderingServer::get_singleton()->free_rid(rid);
		}

		for (const RID rid : _data.trims) {
			RenderingServer::get_singleton()->free_rid(rid);
		}

		for (const RID rid : _data.seams) {
			RenderingServer::get_singleton()->free_rid(rid);
		}

		_meshes.clear();

		_data.tiles.clear();
		_data.fillers.clear();
		_data.trims.clear();
		_data.seams.clear();

		_valid = false;
	}

	if (p_clear_collision) {
		_destroy_collision();
	}
}

void Terrain3D::build(int p_clipmap_levels, int p_clipmap_size) {
	if (!is_inside_tree() || !_storage.is_valid()) {
		LOG(DEBUG, "Not inside the tree or no valid storage, skipping build");
		return;
	}

	LOG(INFO, "Building the terrain");

	// Generate terrain meshes, lods, seams
	_meshes = GeoClipMap::generate(p_clipmap_size, p_clipmap_levels);
	ERR_FAIL_COND(_meshes.is_empty());

	// Set the current terrain material on all meshes
	RID material_rid = _storage->get_material();
	for (const RID rid : _meshes) {
		RenderingServer::get_singleton()->mesh_surface_set_material(rid, 0, material_rid);
	}

	// Create mesh instances from meshes
	LOG(DEBUG, "Creating mesh instances from meshes");

	// Get current visual scenario so the instances appear in the scene
	RID scenario = get_world_3d()->get_scenario();

	_data.cross = RenderingServer::get_singleton()->instance_create2(_meshes[GeoClipMap::CROSS], scenario);
	RenderingServer::get_singleton()->instance_geometry_set_cast_shadows_setting(_data.cross, RenderingServer::ShadowCastingSetting(_shadow_casting_setting));
	RenderingServer::get_singleton()->instance_set_layer_mask(_data.cross, _visual_layers);

	for (int l = 0; l < p_clipmap_levels; l++) {
		for (int x = 0; x < 4; x++) {
			for (int y = 0; y < 4; y++) {
				if (l != 0 && (x == 1 || x == 2) && (y == 1 || y == 2)) {
					continue;
				}

				RID tile = RenderingServer::get_singleton()->instance_create2(_meshes[GeoClipMap::TILE], scenario);
				RenderingServer::get_singleton()->instance_geometry_set_cast_shadows_setting(tile, RenderingServer::ShadowCastingSetting(_shadow_casting_setting));
				RenderingServer::get_singleton()->instance_set_layer_mask(tile, _visual_layers);
				_data.tiles.push_back(tile);
			}
		}

		RID filler = RenderingServer::get_singleton()->instance_create2(_meshes[GeoClipMap::FILLER], scenario);
		RenderingServer::get_singleton()->instance_geometry_set_cast_shadows_setting(filler, RenderingServer::ShadowCastingSetting(_shadow_casting_setting));
		RenderingServer::get_singleton()->instance_set_layer_mask(filler, _visual_layers);
		_data.fillers.push_back(filler);

		if (l != p_clipmap_levels - 1) {
			RID trim = RenderingServer::get_singleton()->instance_create2(_meshes[GeoClipMap::TRIM], scenario);
			RenderingServer::get_singleton()->instance_geometry_set_cast_shadows_setting(trim, RenderingServer::ShadowCastingSetting(_shadow_casting_setting));
			RenderingServer::get_singleton()->instance_set_layer_mask(trim, _visual_layers);
			_data.trims.push_back(trim);

			RID seam = RenderingServer::get_singleton()->instance_create2(_meshes[GeoClipMap::SEAM], scenario);
			RenderingServer::get_singleton()->instance_geometry_set_cast_shadows_setting(seam, RenderingServer::ShadowCastingSetting(_shadow_casting_setting));
			RenderingServer::get_singleton()->instance_set_layer_mask(seam, _visual_layers);
			_data.seams.push_back(seam);
		}
	}

	_valid = true;
	update_aabbs();
	// Force a snap update
	_camera_last_position = Vector2(FLT_MAX, FLT_MAX);
}

/**
 * Centers the terrain and LODs on a provided position. Y height is ignored.
 */
void Terrain3D::snap(Vector3 p_cam_pos) {
	p_cam_pos.y = 0;
	LOG(DEBUG_CONT, "Snapping terrain to: ", String(p_cam_pos));

	Transform3D t = Transform3D(Basis(), p_cam_pos.floor());
	RenderingServer::get_singleton()->instance_set_transform(_data.cross, t);

	int edge = 0;
	int tile = 0;

	for (int l = 0; l < _clipmap_levels; l++) {
		float scale = float(1 << l);
		Vector3 snapped_pos = (p_cam_pos / scale).floor() * scale;
		Vector3 tile_size = Vector3(float(_clipmap_size << l), 0, float(_clipmap_size << l));
		Vector3 base = snapped_pos - Vector3(float(_clipmap_size << (l + 1)), 0, float(_clipmap_size << (l + 1)));

		// Position tiles
		for (int x = 0; x < 4; x++) {
			for (int y = 0; y < 4; y++) {
				if (l != 0 && (x == 1 || x == 2) && (y == 1 || y == 2)) {
					continue;
				}

				Vector3 fill = Vector3(x >= 2 ? 1 : 0, 0, y >= 2 ? 1 : 0) * scale;
				Vector3 tile_tl = base + Vector3(x, 0, y) * tile_size + fill;
				//Vector3 tile_br = tile_tl + tile_size;

				Transform3D t = Transform3D().scaled(Vector3(scale, 1, scale));
				t.origin = tile_tl;

				RenderingServer::get_singleton()->instance_set_transform(_data.tiles[tile], t);

				tile++;
			}
		}
		{
			Transform3D t = Transform3D().scaled(Vector3(scale, 1, scale));
			t.origin = snapped_pos;
			RenderingServer::get_singleton()->instance_set_transform(_data.fillers[l], t);
		}

		if (l != _clipmap_levels - 1) {
			float next_scale = scale * 2.0f;
			Vector3 next_snapped_pos = (p_cam_pos / next_scale).floor() * next_scale;

			// Position trims
			{
				Vector3 tile_center = snapped_pos + (Vector3(scale, 0, scale) * 0.5f);
				Vector3 d = p_cam_pos - next_snapped_pos;

				int r = 0;
				r |= d.x >= scale ? 0 : 2;
				r |= d.z >= scale ? 0 : 1;

				float rotations[4] = { 0.0, 270.0, 90, 180.0 };

				float angle = UtilityFunctions::deg_to_rad(rotations[r]);
				Transform3D t = Transform3D().rotated(Vector3(0, 1, 0), -angle);
				t = t.scaled(Vector3(scale, 1, scale));
				t.origin = tile_center;
				RenderingServer::get_singleton()->instance_set_transform(_data.trims[edge], t);
			}

			// Position seams
			{
				Vector3 next_base = next_snapped_pos - Vector3(float(_clipmap_size << (l + 1)), 0, float(_clipmap_size << (l + 1)));
				Transform3D t = Transform3D().scaled(Vector3(scale, 1, scale));
				t.origin = next_base;
				RenderingServer::get_singleton()->instance_set_transform(_data.seams[edge], t);
			}
			edge++;
		}
	}
}

void Terrain3D::update_aabbs() {
	ERR_FAIL_COND_MSG(!_valid, "Terrain meshes have not been built yet");
	ERR_FAIL_COND_MSG(!_storage.is_valid(), "Terrain3DStorage is not valid");

	Vector2 height_range = _storage->get_height_range();
	LOG(DEBUG_CONT, "Updating AABBs with total height range: ", height_range);
	height_range.y += abs(height_range.x); // Add below zero to total size

	AABB aabb = RenderingServer::get_singleton()->mesh_get_custom_aabb(_meshes[GeoClipMap::CROSS]);
	aabb.position.y = height_range.x;
	aabb.size.y = height_range.y;
	RenderingServer::get_singleton()->instance_set_custom_aabb(_data.cross, aabb);

	aabb = RenderingServer::get_singleton()->mesh_get_custom_aabb(_meshes[GeoClipMap::TILE]);
	aabb.position.y = height_range.x;
	aabb.size.y = height_range.y;
	for (int i = 0; i < _data.tiles.size(); i++) {
		RenderingServer::get_singleton()->instance_set_custom_aabb(_data.tiles[i], aabb);
	}

	aabb = RenderingServer::get_singleton()->mesh_get_custom_aabb(_meshes[GeoClipMap::FILLER]);
	aabb.position.y = height_range.x;
	aabb.size.y = height_range.y;
	for (int i = 0; i < _data.fillers.size(); i++) {
		RenderingServer::get_singleton()->instance_set_custom_aabb(_data.fillers[i], aabb);
	}

	aabb = RenderingServer::get_singleton()->mesh_get_custom_aabb(_meshes[GeoClipMap::TRIM]);
	aabb.position.y = height_range.x;
	aabb.size.y = height_range.y;
	for (int i = 0; i < _data.trims.size(); i++) {
		RenderingServer::get_singleton()->instance_set_custom_aabb(_data.trims[i], aabb);
	}

	aabb = RenderingServer::get_singleton()->mesh_get_custom_aabb(_meshes[GeoClipMap::SEAM]);
	aabb.position.y = height_range.x;
	aabb.size.y = height_range.y;
	for (int i = 0; i < _data.seams.size(); i++) {
		RenderingServer::get_singleton()->instance_set_custom_aabb(_data.seams[i], aabb);
	}
}

/* Iterate over ground to find intersection point between two rays:
 *	p_position (camera position)
 *	p_direction (camera direction looking at the terrain)
 *	test_dir (camera direction 0 Y, traversing terrain along height
 * Returns vec3(Double max 3.402823466e+38F) on no intersection. Test w/ if (var.x < 3.4e38)
 */
Vector3 Terrain3D::get_intersection(Vector3 p_position, Vector3 p_direction) {
	Vector3 test_dir = Vector3(p_direction.x, 0., p_direction.z).normalized();
	Vector3 test_point = p_position;
	p_direction.normalize();

	float highest_dotp = 0.f;
	Vector3 highest_point;

	if (_storage.is_valid()) {
		for (int i = 0; i < 3000; i++) {
			test_point += test_dir;
			test_point.y = _storage->get_height(test_point);
			Vector3 test_vec = (test_point - p_position).normalized();

			float test_dotp = p_direction.dot(test_vec);
			if (test_dotp > highest_dotp) {
				highest_dotp = test_dotp;
				highest_point = test_point;
			}
			// Highest accuracy hits most of the time
			if (test_dotp > 0.9999) {
				return test_point;
			}
		}

		// Good enough fallback (the above test often overshoots, so this grabs the highest we did hit)
		if (highest_dotp >= 0.999) {
			return highest_point;
		}
	}
	return Vector3(FLT_MAX, FLT_MAX, FLT_MAX);
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3D::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_READY: {
			LOG(INFO, "NOTIFICATION_READY");
			set_process(true);
			if (_storage.is_valid()) {
				_storage->_clear_modified();
			}
			break;
		}

		case NOTIFICATION_PROCESS: {
			__process(get_process_delta_time());
			break;
		}

		case NOTIFICATION_PREDELETE: {
			LOG(INFO, "NOTIFICATION_PREDELETE");
			clear();
			break;
		}

		case NOTIFICATION_ENTER_TREE: {
			LOG(INFO, "NOTIFICATION_ENTER_TREE");
			if (!_valid) {
				build(_clipmap_levels, _clipmap_size);
			}
			_build_collision();
			break;
		}

		case NOTIFICATION_EXIT_TREE: {
			LOG(INFO, "NOTIFICATION_EXIT_TREE");
			_destroy_collision();
			clear();
			break;
		}

		case NOTIFICATION_ENTER_WORLD: {
			LOG(INFO, "NOTIFICATION_ENTER_WORLD");
			_is_inside_world = true;
			_update_instances();
			break;
		}

		case NOTIFICATION_TRANSFORM_CHANGED: {
			//LOG(INFO, "NOTIFICATION_TRANSFORM_CHANGED");
			break;
		}

		case NOTIFICATION_EXIT_WORLD: {
			LOG(INFO, "NOTIFICATION_EXIT_WORLD");
			_is_inside_world = false;
			_update_instances();
			break;
		}

		case NOTIFICATION_VISIBILITY_CHANGED: {
			LOG(INFO, "NOTIFICATION_VISIBILITY_CHANGED");
			_update_instances();
			break;
		}

		case NOTIFICATION_EDITOR_PRE_SAVE: {
			LOG(INFO, "NOTIFICATION_EDITOR_PRE_SAVE");
			if (!_storage.is_valid()) {
				LOG(DEBUG, "Save requested, but no valid storage. Skipping");
				return;
			}
			_storage->save();
			break;
		}

		case NOTIFICATION_EDITOR_POST_SAVE: {
			//LOG(INFO, "NOTIFICATION_EDITOR_POST_SAVE");
			break;
		}
	}
}

void Terrain3D::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_debug_level", "level"), &Terrain3D::set_debug_level);
	ClassDB::bind_method(D_METHOD("get_debug_level"), &Terrain3D::get_debug_level);
	ClassDB::bind_method(D_METHOD("set_clipmap_levels", "count"), &Terrain3D::set_clipmap_levels);
	ClassDB::bind_method(D_METHOD("get_clipmap_levels"), &Terrain3D::get_clipmap_levels);
	ClassDB::bind_method(D_METHOD("set_clipmap_size", "size"), &Terrain3D::set_clipmap_size);
	ClassDB::bind_method(D_METHOD("get_clipmap_size"), &Terrain3D::get_clipmap_size);

	ClassDB::bind_method(D_METHOD("set_storage", "storage"), &Terrain3D::set_storage);
	ClassDB::bind_method(D_METHOD("get_storage"), &Terrain3D::get_storage);

	ClassDB::bind_method(D_METHOD("set_plugin", "plugin"), &Terrain3D::set_plugin);
	ClassDB::bind_method(D_METHOD("get_plugin"), &Terrain3D::get_plugin);
	ClassDB::bind_method(D_METHOD("set_camera", "camera"), &Terrain3D::set_camera);
	ClassDB::bind_method(D_METHOD("get_camera"), &Terrain3D::get_camera);

	ClassDB::bind_method(D_METHOD("set_cast_shadows_setting", "shadow_casting_setting"), &Terrain3D::set_cast_shadows_setting);
	ClassDB::bind_method(D_METHOD("get_cast_shadows_setting"), &Terrain3D::get_cast_shadows_setting);
	ClassDB::bind_method(D_METHOD("set_layer_mask", "mask"), &Terrain3D::set_layer_mask);
	ClassDB::bind_method(D_METHOD("get_layer_mask"), &Terrain3D::get_layer_mask);

	ClassDB::bind_method(D_METHOD("set_collision_enabled", "enabled"), &Terrain3D::set_collision_enabled);
	ClassDB::bind_method(D_METHOD("get_collision_enabled"), &Terrain3D::get_collision_enabled);
	ClassDB::bind_method(D_METHOD("set_show_debug_collision", "enabled"), &Terrain3D::set_show_debug_collision);
	ClassDB::bind_method(D_METHOD("get_show_debug_collision"), &Terrain3D::get_show_debug_collision);
	ClassDB::bind_method(D_METHOD("set_collision_layer", "layer"), &Terrain3D::set_collision_layer);
	ClassDB::bind_method(D_METHOD("get_collision_layer"), &Terrain3D::get_collision_layer);
	ClassDB::bind_method(D_METHOD("set_collision_mask", "mask"), &Terrain3D::set_collision_mask);
	ClassDB::bind_method(D_METHOD("get_collision_mask"), &Terrain3D::get_collision_mask);
	ClassDB::bind_method(D_METHOD("set_collision_priority", "priority"), &Terrain3D::set_collision_priority);
	ClassDB::bind_method(D_METHOD("get_collision_priority"), &Terrain3D::get_collision_priority);

	ClassDB::bind_method(D_METHOD("clear", "clear_meshes", "clear_collision"), &Terrain3D::clear);
	ClassDB::bind_method(D_METHOD("build", "clipmap_levels", "clipmap_size"), &Terrain3D::build);

	// Expose 'update_aabbs' so it can be used in Callable. Not ideal.
	ClassDB::bind_method(D_METHOD("update_aabbs"), &Terrain3D::update_aabbs);
	ClassDB::bind_method(D_METHOD("get_intersection", "position", "direction"), &Terrain3D::get_intersection);

	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "storage", PROPERTY_HINT_RESOURCE_TYPE, "Terrain3DStorage"), "set_storage", "get_storage");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "cast_shadow", PROPERTY_HINT_ENUM, "Off,On,Double-Sided,Shadows Only"), "set_cast_shadows_setting", "get_cast_shadows_setting");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "layers", PROPERTY_HINT_LAYERS_3D_RENDER), "set_layer_mask", "get_layer_mask");

	ADD_GROUP("Collision", "collision_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "collision_enabled"), "set_collision_enabled", "get_collision_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_layer", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_layer", "get_collision_layer");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_mask", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_mask", "get_collision_mask");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "collision_priority"), "set_collision_priority", "get_collision_priority");

	ADD_GROUP("Mesh", "clipmap_");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "clipmap_levels", PROPERTY_HINT_RANGE, "1,10,1"), "set_clipmap_levels", "get_clipmap_levels");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "clipmap_size", PROPERTY_HINT_RANGE, "8,64,1"), "set_clipmap_size", "get_clipmap_size");

	ADD_GROUP("Debug", "debug_");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "debug_level", PROPERTY_HINT_ENUM, "Errors,Info,Debug,Debug Continuous"), "set_debug_level", "get_debug_level");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_show_collision"), "set_show_debug_collision", "get_show_debug_collision");

	ADD_SIGNAL(MethodInfo("storage_changed"));
}
