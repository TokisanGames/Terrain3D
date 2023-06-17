//Copyright © 2023 Roope Palmroos, Cory Petkovsek, and Contributors. All rights reserved. See LICENSE.
#include <godot_cpp/core/class_db.hpp>

#include "terrain.h"
#include "terrain_logger.h"

// Initialize static member variable
int Terrain3D::debug_level{ DEBUG };

Terrain3D::Terrain3D() {
	set_notify_transform(true);
}

Terrain3D::~Terrain3D() {
}

/**
 * This is a proxy for _process(delta) called by _notification() due to
 * https://github.com/godotengine/godot-cpp/issues/1022
 */
void Terrain3D::process(double delta) {
	if (!valid)
		return;

	// If the game/editor camera is not set, find it
	if (camera == nullptr) {
		LOG(DEBUG, "camera is null, getting the current one");
		get_camera();
	}

	// If camera has moved significantly, center the terrain on it.
	if (camera != nullptr) {
		Vector3 cam_pos = camera->get_global_position();
		Vector2 cam_pos_2d = Vector2(cam_pos.x, cam_pos.z);
		if (camera_last_position.distance_to(cam_pos_2d) > clipmap_size * .5) {
			snap(cam_pos);
			camera_last_position = cam_pos_2d;
		}
	}
}

/**
 * Centers the terrain and LODs on a provided position. Y height is ignored.
 */
void Terrain3D::snap(Vector3 p_cam_pos) {
	p_cam_pos.y = 0;
	LOG(DEBUG_CONT, "Snapping terrain to: ", String(p_cam_pos));

	Transform3D t = Transform3D(Basis(), p_cam_pos.floor());
	RenderingServer::get_singleton()->instance_set_transform(data.cross, t);

	int edge = 0;
	int tile = 0;

	for (int l = 0; l < clipmap_levels; l++) {
		float scale = float(1 << l);
		Vector3 snapped_pos = (p_cam_pos / scale).floor() * scale;
		Vector3 tile_size = Vector3(float(clipmap_size << l), 0, float(clipmap_size << l));
		Vector3 base = snapped_pos - Vector3(float(clipmap_size << (l + 1)), 0, float(clipmap_size << (l + 1)));

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

				RenderingServer::get_singleton()->instance_set_transform(data.tiles[tile], t);

				tile++;
			}
		}
		{
			Transform3D t = Transform3D().scaled(Vector3(scale, 1, scale));
			t.origin = snapped_pos;
			RenderingServer::get_singleton()->instance_set_transform(data.fillers[l], t);
		}

		if (l != clipmap_levels - 1) {
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
				RenderingServer::get_singleton()->instance_set_transform(data.trims[edge], t);
			}

			// Position seams
			{
				Vector3 next_base = next_snapped_pos - Vector3(float(clipmap_size << (l + 1)), 0, float(clipmap_size << (l + 1)));
				Transform3D t = Transform3D().scaled(Vector3(scale, 1, scale));
				t.origin = next_base;
				RenderingServer::get_singleton()->instance_set_transform(data.seams[edge], t);
			}
			edge++;
		}
	}
}

void Terrain3D::build(int p_clipmap_levels, int p_clipmap_size) {
	if (!is_inside_tree() || !storage.is_valid()) {
		LOG(DEBUG, "Not inside the tree or no valid storage, skipping build");
		return;
	}

	LOG(INFO, "Building the terrain");

	// Generate terrain meshes, lods, seams
	meshes = GeoClipMap::generate(p_clipmap_size, p_clipmap_levels);
	ERR_FAIL_COND(meshes.is_empty());

	// Set the current terrain material on all meshes
	RID material_rid = storage->get_material();
	for (const RID rid : meshes) {
		RenderingServer::get_singleton()->mesh_surface_set_material(rid, 0, material_rid);
	}

	// Create mesh instances from meshes
	LOG(DEBUG, "Creating mesh instances from meshes");

	// Get current visual scenario so the instances appear in the scene
	RID scenario = get_world_3d()->get_scenario();

	data.cross = RenderingServer::get_singleton()->instance_create2(meshes[GeoClipMap::CROSS], scenario);

	for (int l = 0; l < p_clipmap_levels; l++) {
		for (int x = 0; x < 4; x++) {
			for (int y = 0; y < 4; y++) {
				if (l != 0 && (x == 1 || x == 2) && (y == 1 || y == 2)) {
					continue;
				}

				RID tile = RenderingServer::get_singleton()->instance_create2(meshes[GeoClipMap::TILE], scenario);
				data.tiles.push_back(tile);
			}
		}

		RID filler = RenderingServer::get_singleton()->instance_create2(meshes[GeoClipMap::FILLER], scenario);
		data.fillers.push_back(filler);

		if (l != p_clipmap_levels - 1) {
			RID trim = RenderingServer::get_singleton()->instance_create2(meshes[GeoClipMap::TRIM], scenario);
			data.trims.push_back(trim);

			RID seam = RenderingServer::get_singleton()->instance_create2(meshes[GeoClipMap::SEAM], scenario);
			data.seams.push_back(seam);
		}
	}

	// Create collision

	/*if (!static_body.is_valid()) {
		static_body = PhysicsServer3D::get_singleton()->body_create();

		PhysicsServer3D::get_singleton()->body_set_mode(static_body, PhysicsServer3D::BODY_MODE_STATIC);
		PhysicsServer3D::get_singleton()->body_set_space(static_body, get_world_3d()->get_space());

		RID shape = PhysicsServer3D::get_singleton()->heightmap_shape_create();
		PhysicsServer3D::get_singleton()->body_add_shape(static_body, shape);

		Dictionary shape_data;
		int shape_size = p_size + 1;

		PackedFloat32Array map_data;
		map_data.resize(shape_size * shape_size);

		shape_data["width"] = shape_size;
		shape_data["depth"] = shape_size;
		shape_data["heights"] = map_data;
		shape_data["min_height"] = 0.0;
		shape_data["max_height"] = real_t(height);

		PhysicsServer3D::get_singleton()->shape_set_data(shape, shape_data);
	}*/

	valid = true;
	_update_aabbs();
	// Force a snap update
	camera_last_position = Vector2(FLT_MAX, FLT_MAX);
}

void Terrain3D::_update_aabbs() {
	LOG(INFO, "Updating AABBs");
	ERR_FAIL_COND_MSG(!valid, "Terrain meshes have not been built yet");
	ERR_FAIL_COND_MSG(!storage.is_valid(), "Terrain3DStorage is not valid");

	float height = float(Terrain3DStorage::TERRAIN_MAX_HEIGHT);

	AABB aabb = RenderingServer::get_singleton()->mesh_get_custom_aabb(meshes[GeoClipMap::CROSS]);
	aabb.size.y = height;
	RenderingServer::get_singleton()->instance_set_custom_aabb(data.cross, aabb);

	aabb = RenderingServer::get_singleton()->mesh_get_custom_aabb(meshes[GeoClipMap::TILE]);
	aabb.size.y = height;
	for (int i = 0; i < data.tiles.size(); i++) {
		RenderingServer::get_singleton()->instance_set_custom_aabb(data.tiles[i], aabb);
	}

	aabb = RenderingServer::get_singleton()->mesh_get_custom_aabb(meshes[GeoClipMap::FILLER]);
	aabb.size.y = height;
	for (int i = 0; i < data.fillers.size(); i++) {
		RenderingServer::get_singleton()->instance_set_custom_aabb(data.fillers[i], aabb);
	}

	aabb = RenderingServer::get_singleton()->mesh_get_custom_aabb(meshes[GeoClipMap::TRIM]);
	aabb.size.y = height;
	for (int i = 0; i < data.trims.size(); i++) {
		RenderingServer::get_singleton()->instance_set_custom_aabb(data.trims[i], aabb);
	}

	aabb = RenderingServer::get_singleton()->mesh_get_custom_aabb(meshes[GeoClipMap::SEAM]);
	aabb.size.y = height;
	for (int i = 0; i < data.seams.size(); i++) {
		RenderingServer::get_singleton()->instance_set_custom_aabb(data.seams[i], aabb);
	}
}

void Terrain3D::clear(bool p_clear_meshes, bool p_clear_collision) {
	LOG(INFO, "Clearing the terrain");
	if (p_clear_meshes) {
		for (const RID rid : meshes) {
			RenderingServer::get_singleton()->free_rid(rid);
		}

		RenderingServer::get_singleton()->free_rid(data.cross);

		for (const RID rid : data.tiles) {
			RenderingServer::get_singleton()->free_rid(rid);
		}

		for (const RID rid : data.fillers) {
			RenderingServer::get_singleton()->free_rid(rid);
		}

		for (const RID rid : data.trims) {
			RenderingServer::get_singleton()->free_rid(rid);
		}

		for (const RID rid : data.seams) {
			RenderingServer::get_singleton()->free_rid(rid);
		}

		meshes.clear();

		data.tiles.clear();
		data.fillers.clear();
		data.trims.clear();
		data.seams.clear();

		valid = false;
	}

	if (p_clear_collision) {
		if (static_body.is_valid()) {
			RID shape = PhysicsServer3D::get_singleton()->body_get_shape(static_body, 0);
			PhysicsServer3D::get_singleton()->free_rid(shape);
			PhysicsServer3D::get_singleton()->free_rid(static_body);
			static_body = RID();
		}
	}
}

void Terrain3D::set_debug_level(int p_level) {
	LOG(INFO, "Setting debug level: ", p_level);
	debug_level = CLAMP(p_level, 0, DEBUG_MAX);
}

void Terrain3D::set_clipmap_levels(int p_count) {
	if (clipmap_levels != p_count) {
		LOG(INFO, "Setting clipmap levels: ", p_count);
		clear();
		build(p_count, clipmap_size);
		clipmap_levels = p_count;
	}
}

void Terrain3D::set_clipmap_size(int p_size) {
	if (clipmap_size != p_size) {
		LOG(INFO, "Setting clipmap size: ", p_size);
		clear();
		build(clipmap_levels, p_size);
		clipmap_size = p_size;
	}
}

void Terrain3D::set_storage(const Ref<Terrain3DStorage> &p_storage) {
	if (storage != p_storage) {
		LOG(INFO, "Setting storage");
		storage = p_storage;
		clear();

		if (storage.is_valid()) {
			if (storage->get_region_count() == 0) {
				LOG(DEBUG, "Region count 0, adding new region");
				storage->call_deferred("add_region", Vector3(0, 0, 0));
			}
			build(clipmap_levels, clipmap_size);
		}
		emit_signal("storage_changed");
	}
}

void Terrain3D::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_READY: {
			LOG(INFO, "NOTIFICATION_READY");
			set_process(true);
			break;
		}

		case NOTIFICATION_PROCESS: {
			process(get_process_delta_time());
			break;
		}

		case NOTIFICATION_PREDELETE: {
			LOG(INFO, "NOTIFICATION_PREDELETE");
			clear();
			break;
		}

		case NOTIFICATION_ENTER_TREE: {
			LOG(INFO, "NOTIFICATION_ENTER_TREE");
			if (!valid) {
				build(clipmap_levels, clipmap_size);
			}
			break;
		}

		case NOTIFICATION_EXIT_TREE: {
			LOG(INFO, "NOTIFICATION_EXIT_TREE");
			clear();
			break;
		}

		case NOTIFICATION_ENTER_WORLD: {
			LOG(INFO, "NOTIFICATION_ENTER_WORLD");
			_update_world(get_world_3d()->get_space(), get_world_3d()->get_scenario());
			break;
		}

		case NOTIFICATION_TRANSFORM_CHANGED: {
			//LOG(INFO, "NOTIFICATION_TRANSFORM_CHANGED");
			break;
		}

		case NOTIFICATION_EXIT_WORLD: {
			LOG(INFO, "NOTIFICATION_EXIT_WORLD");
			_update_world(RID(), RID());
			break;
		}

		case NOTIFICATION_VISIBILITY_CHANGED: {
			LOG(INFO, "NOTIFICATION_VISIBILITY_CHANGED");
			_update_visibility();
			break;
		}

		case NOTIFICATION_EDITOR_PRE_SAVE: {
			LOG(INFO, "NOTIFICATION_EDITOR_PRE_SAVE");
			if (!storage.is_valid()) {
				LOG(DEBUG, "Save requested, but no valid storage. Skipping");
				return;
			}
			String path = storage->get_path();
			LOG(DEBUG, "Saving the terrain to: " + path);
			if (path.get_extension() == ".tres" || path.get_extension() == ".res") {
				Error err = ResourceSaver::get_singleton()->save(storage, path);
				ERR_FAIL_COND(err);
			}
			LOG(INFO, "Finished saving terrain data");
			break;
		}

		case NOTIFICATION_EDITOR_POST_SAVE: {
			//LOG(INFO, "NOTIFICATION_EDITOR_POST_SAVE");
			break;
		}
	}
}

/**
 * Make all mesh instances visible or not
 */
void Terrain3D::_update_visibility() {
	if (!is_inside_tree() || !valid) {
		return;
	}

	bool v = is_visible_in_tree();
	RenderingServer::get_singleton()->instance_set_visible(data.cross, v);

	for (const RID rid : data.tiles) {
		RenderingServer::get_singleton()->instance_set_visible(rid, v);
	}

	for (const RID rid : data.fillers) {
		RenderingServer::get_singleton()->instance_set_visible(rid, v);
	}

	for (const RID rid : data.trims) {
		RenderingServer::get_singleton()->instance_set_visible(rid, v);
	}

	for (const RID rid : data.seams) {
		RenderingServer::get_singleton()->instance_set_visible(rid, v);
	}
}

/**
 * Update all mesh instances with the new world scenario so they appear
 * in the scene.
 */
void Terrain3D::_update_world(RID p_space, RID p_scenario) {
	if (static_body.is_valid()) {
		PhysicsServer3D::get_singleton()->body_set_space(static_body, p_space);
	}

	if (!valid) {
		return;
	}

	RenderingServer::get_singleton()->instance_set_scenario(data.cross, p_scenario);

	for (const RID rid : data.tiles) {
		RenderingServer::get_singleton()->instance_set_scenario(rid, p_scenario);
	}

	for (const RID rid : data.fillers) {
		RenderingServer::get_singleton()->instance_set_scenario(rid, p_scenario);
	}

	for (const RID rid : data.trims) {
		RenderingServer::get_singleton()->instance_set_scenario(rid, p_scenario);
	}

	for (const RID rid : data.seams) {
		RenderingServer::get_singleton()->instance_set_scenario(rid, p_scenario);
	}
}

/**
 * If running in the editor, recurses into the editor scene tree to find the editor cameras and grabs the first one.
 * The edited_scene_root is excluded in case the user already has a Camera3D in their scene.
 */
void Terrain3D::get_camera() {
	if (Engine::get_singleton()->is_editor_hint()) {
		EditorScript temp_editor_script;
		EditorInterface *editor_interface = temp_editor_script.get_editor_interface();
		TypedArray<Camera3D> cam_array = TypedArray<Camera3D>();
		find_cameras(editor_interface->get_editor_main_screen()->get_children(), editor_interface->get_edited_scene_root(), cam_array);
		if (!cam_array.is_empty()) {
			LOG(DEBUG, "Connecting to the first editor camera");
			camera = Object::cast_to<Camera3D>(cam_array[0]);
		}
	} else {
		LOG(DEBUG, "Connecting to the in-game viewport camera");
		camera = get_viewport()->get_camera_3d();
	}
}

/**
 * Recursive helper function for get_camera().
 */
void Terrain3D::find_cameras(TypedArray<Node> from_nodes, Node *excluded_node, TypedArray<Camera3D> &cam_array) {
	for (int i = 0; i < from_nodes.size(); i++) {
		Node *node = Object::cast_to<Node>(from_nodes[i]);
		if (node != excluded_node) {
			find_cameras(node->get_children(), excluded_node, cam_array);
		}
		if (node->is_class("Camera3D")) {
			LOG(DEBUG, "Found a Camera3D at: ", node->get_path());
			cam_array.push_back(node);
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

	ClassDB::bind_method(D_METHOD("clear", "clear_meshes", "clear_collision"), &Terrain3D::clear);
	ClassDB::bind_method(D_METHOD("build", "clipmap_levels", "clipmap_size"), &Terrain3D::build);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "debug_level", PROPERTY_HINT_ENUM, "Errors,Info,Debug,Debug+Snapping"), "set_debug_level", "get_debug_level");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "storage", PROPERTY_HINT_RESOURCE_TYPE, "Terrain3DStorage"), "set_storage", "get_storage");

	ADD_GROUP("Clipmap", "clipmap_");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "clipmap_levels", PROPERTY_HINT_RANGE, "1,10,1"), "set_clipmap_levels", "get_clipmap_levels");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "clipmap_size", PROPERTY_HINT_RANGE, "8,64,1"), "set_clipmap_size", "get_clipmap_size");

	ADD_SIGNAL(MethodInfo("storage_changed"));
}
