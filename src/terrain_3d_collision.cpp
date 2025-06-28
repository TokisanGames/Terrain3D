// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/height_map_shape3d.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/world3d.hpp>

#include <godot_cpp/classes/scene_tree.hpp>

#include "constants.h"
#include "logger.h"
#include "terrain_3d.h"
#include "terrain_3d_collision.h"
#include "terrain_3d_data.h"
#include "terrain_3d_util.h"

///////////////////////////
// Private Functions
///////////////////////////

// Calculates shape data from top left position. Assumes descaled and snapped.
Dictionary Terrain3DCollision::_get_shape_data(const Vector2i &p_position, const int p_size) {
	IS_DATA_INIT_MESG("Terrain not initialized", Dictionary());
	Terrain3DData *data = _terrain->get_data();
	int region_size = _terrain->get_region_size();

	int hshape_size = p_size + 1; // Calculate last vertex at end
	PackedRealArray map_data = PackedRealArray();
	map_data.resize(hshape_size * hshape_size);
	real_t min_height = FLT_MAX;
	real_t max_height = FLT_MIN;

	Ref<Image> map, map_x, map_z, map_xz; // height maps
	Ref<Image> cmap, cmap_x, cmap_z, cmap_xz; // control maps w/ holes

	// Get region_loc of top left corner of descaled and grid snapped collision shape position
	Vector2i region_loc = V2I_DIVIDE_FLOOR(p_position, region_size);
	Ref<Terrain3DRegion> region = data->get_region(region_loc);
	if (region.is_null() || (region.is_valid() && region->is_deleted())) {
		LOG(EXTREME, "Region not found at: ", region_loc, ". Returning blank");
		return Dictionary();
	}
	map = region->get_map(TYPE_HEIGHT);
	cmap = region->get_map(TYPE_CONTROL);

	// Get +X, +Z adjacent regions in case we run over
	region = data->get_region(region_loc + Vector2i(1, 0));
	if (region.is_valid() && !region->is_deleted()) {
		map_x = region->get_map(TYPE_HEIGHT);
		cmap_x = region->get_map(TYPE_CONTROL);
	}
	region = data->get_region(region_loc + Vector2i(0, 1));
	if (region.is_valid() && !region->is_deleted()) {
		map_z = region->get_map(TYPE_HEIGHT);
		cmap_z = region->get_map(TYPE_CONTROL);
	}
	region = data->get_region(region_loc + Vector2i(1, 1));
	if (region.is_valid() && !region->is_deleted()) {
		map_xz = region->get_map(TYPE_HEIGHT);
		cmap_xz = region->get_map(TYPE_CONTROL);
	}

	for (int z = 0; z < hshape_size; z++) {
		for (int x = 0; x < hshape_size; x++) {
			// Choose array indexing to match triangulation of heightmapshape with the mesh
			// https://stackoverflow.com/questions/16684856/rotating-a-2d-pixel-array-by-90-degrees
			// Normal array index rotated Y=0 - shape rotation Y=0 (xform below)
			// int index = z * hshape_size + x;
			// Array Index Rotated Y=-90 - must rotate shape Y=+90 (xform below)
			int index = hshape_size - 1 - z + x * hshape_size;

			Vector2i shape_pos = p_position + Vector2i(x, z);
			Vector2i shape_region_loc = V2I_DIVIDE_FLOOR(shape_pos, region_size);
			int img_x = Math::posmod(shape_pos.x, region_size);
			bool next_x = shape_region_loc.x > region_loc.x;
			int img_y = Math::posmod(shape_pos.y, region_size);
			bool next_z = shape_region_loc.y > region_loc.y;

			// Set heights on local map, or adjacent maps if on the last row/col
			real_t height = 0.f;
			if (!next_x && !next_z && map.is_valid()) {
				height = is_hole(cmap->get_pixel(img_x, img_y).r) ? NAN : map->get_pixel(img_x, img_y).r;
			} else if (next_x && !next_z) {
				if (map_x.is_valid()) {
					height = is_hole(cmap_x->get_pixel(img_x, img_y).r) ? NAN : map_x->get_pixel(img_x, img_y).r;
				} else {
					height = is_hole(cmap->get_pixel(region_size - 1, img_y).r) ? NAN : map->get_pixel(region_size - 1, img_y).r;
				}
			} else if (!next_x && next_z) {
				if (map_z.is_valid()) {
					height = is_hole(cmap_z->get_pixel(img_x, img_y).r) ? NAN : map_z->get_pixel(img_x, img_y).r;
				} else {
					height = (is_hole(cmap->get_pixel(img_x, region_size - 1).r)) ? NAN : map->get_pixel(img_x, region_size - 1).r;
				}
			} else if (next_x && next_z) {
				if (map_xz.is_valid()) {
					height = is_hole(cmap_xz->get_pixel(img_x, img_y).r) ? NAN : map_xz->get_pixel(img_x, img_y).r;
				} else {
					height = (is_hole(cmap->get_pixel(region_size - 1, region_size - 1).r)) ? NAN : map->get_pixel(region_size - 1, region_size - 1).r;
				}
			}
			map_data[index] = height;
			if (!std::isnan(height)) {
				min_height = MIN(min_height, height);
				max_height = MAX(max_height, height);
			}
		}
	}

	// Non rotated shape for normal array index above
	//Transform3D xform = Transform3D(Basis(), global_pos);
	// Rotated shape Y=90 for -90 rotated array index
	Transform3D xform = Transform3D(Basis(Vector3(0, 1.0, 0), Math_PI * .5), v2iv3(p_position + V2I(p_size / 2)));
	Dictionary shape_data;
	shape_data["width"] = hshape_size;
	shape_data["depth"] = hshape_size;
	shape_data["heights"] = map_data;
	shape_data["xform"] = xform;
	shape_data["min_height"] = min_height;
	shape_data["max_height"] = max_height;
	return shape_data;
}

void Terrain3DCollision::_shape_set_disabled(const int p_shape_id, const bool p_disabled) {
	if (is_editor_mode()) {
		CollisionShape3D *shape = _shapes[p_shape_id];
		shape->set_disabled(p_disabled);
		shape->set_visible(!p_disabled);
	} else {
		PS->body_set_shape_disabled(_static_body_rid, p_shape_id, p_disabled);
	}
}

void Terrain3DCollision::_shape_set_transform(const int p_shape_id, const Transform3D &p_xform) {
	if (is_editor_mode()) {
		CollisionShape3D *shape = _shapes[p_shape_id];
		shape->set_transform(p_xform);
	} else {
		PS->body_set_shape_transform(_static_body_rid, p_shape_id, p_xform);
	}
}

Vector3 Terrain3DCollision::_shape_get_position(const int p_shape_id) const {
	if (is_editor_mode()) {
		CollisionShape3D *shape = _shapes[p_shape_id];
		return shape->get_global_position();
	} else {
		return PS->body_get_shape_transform(_static_body_rid, p_shape_id).origin;
	}
}

void Terrain3DCollision::_shape_set_data(const int p_shape_id, const Dictionary &p_dict) {
	if (is_editor_mode()) {
		CollisionShape3D *shape = _shapes[p_shape_id];
		Ref<HeightMapShape3D> hshape = shape->get_shape();
		hshape->set_map_data(p_dict["heights"]);
	} else {
		RID shape_rid = PS->body_get_shape(_static_body_rid, p_shape_id);
		PS->shape_set_data(shape_rid, p_dict);
	}
}

void Terrain3DCollision::_reload_physics_material() {
	if (is_editor_mode()) {
		if (_static_body) {
			_static_body->set_physics_material_override(_physics_material);
		}
	} else {
		if (_static_body_rid.is_valid()) {
			if (_physics_material.is_null()) {
				PS->body_set_param(_static_body_rid, PhysicsServer3D::BODY_PARAM_BOUNCE, 0.f);
				PS->body_set_param(_static_body_rid, PhysicsServer3D::BODY_PARAM_FRICTION, 1.f);
			} else {
				real_t computed_bounce = _physics_material->get_bounce() * (_physics_material->is_absorbent() ? -1.f : 1.f);
				real_t computed_friction = _physics_material->get_friction() * (_physics_material->is_rough() ? -1.f : 1.f);
				PS->body_set_param(_static_body_rid, PhysicsServer3D::BODY_PARAM_BOUNCE, computed_bounce);
				PS->body_set_param(_static_body_rid, PhysicsServer3D::BODY_PARAM_FRICTION, computed_friction);
			}
		}
	}
	if (_physics_material.is_valid()) {
		LOG(DEBUG, "Setting PhysicsMaterial bounce: ", _physics_material->get_bounce(), ", friction: ", _physics_material->get_friction());
	}
}

Vector2i Terrain3DCollision::_get_cell(const Vector3 &p_global_position, const int &p_region_size) {
	real_t vertex_spacing = _terrain->get_vertex_spacing();
	Vector2i cell;
	cell.x = UtilityFunctions::posmod(UtilityFunctions::floori(p_global_position.x / vertex_spacing), p_region_size) / _terrain->get_instancer()->CELL_SIZE;
	cell.y = UtilityFunctions::posmod(UtilityFunctions::floori(p_global_position.z / vertex_spacing), p_region_size) / _terrain->get_instancer()->CELL_SIZE;
	return cell;
}

TypedArray<Vector3> Terrain3DCollision::get_instance_cells_to_build(const Vector2i &p_snapped_pos, const int &p_region_size, const int &p_cell_size, const real_t &p_vertex_spacing) {
	
	LOG(INFO, "Building list of instance cells within the radius");
	TypedArray<Vector3> instance_cells_to_build;
	// If we are in dynamic mode, we only build cells within the radius

	if (is_dynamic_mode()) {
		int grid_size = _radius * 2;
		int step = 32;
		for (int x = 0; x < grid_size; x += step) {
			for (int y = 0; y < grid_size; y += step) {
				Vector3 grid_offset = Vector3(x - _radius, 0.0, y - _radius) * p_vertex_spacing;
				Vector3 grid_pos = v2v3(p_snapped_pos) + grid_offset;
				Vector3 region_loc = v2v3(_terrain->get_data()->get_region_location(grid_pos)) * p_region_size * p_vertex_spacing;
				Vector3 cell_loc = region_loc + v2v3(_get_cell(grid_pos, p_region_size)) * p_cell_size * p_vertex_spacing;

				if (!_active_instance_cells.has(cell_loc)) {
					Vector3 cell_centre = cell_loc + Vector3(p_vertex_spacing * p_cell_size * 0.5f, 0.0f, p_vertex_spacing * p_cell_size * 0.5f);
					// Check if the cell is within the radius
					if (cell_centre.distance_to(cell_centre) < real_t(_radius)) {
						if (!_terrain->get_data()->get_regionp(cell_centre).is_valid()) {
							continue;
						}
						instance_cells_to_build.push_back(cell_loc);
					}
				}
			}
		}
	} else {
		// Full collision
		TypedArray<Vector2i> region_locs = _terrain->get_data()->get_region_locations();
		for (int i = 0; i < region_locs.size(); i++) {
			Vector3 region_pos = v2v3(region_locs[i]) * p_region_size * p_vertex_spacing;
			for (int x = 0; x < p_cell_size; x++) {
				for (int y = 0; y < p_cell_size; y++) {
					Vector3 cell_pos = region_pos + Vector3(x * p_cell_size * p_vertex_spacing, 0.0, y * p_cell_size * p_vertex_spacing);
					instance_cells_to_build.push_back(cell_pos);
				}
			}
		}
	}
	return instance_cells_to_build;
}

Dictionary Terrain3DCollision::_get_recyclable_instances(const Vector2i &p_snapped_pos, const real_t &p_radius) {
	Dictionary recyclable_mesh_instance_shapes;
	if (is_dynamic_mode()) {
		LOG(INFO, "Decomposing cells beyond ", p_radius, " of ", p_snapped_pos);

		const TypedArray<Vector3> instance_cells = _active_instance_cells.keys();
		for (int i = 0; i < instance_cells.size(); i++) {
			const Vector3 cell_origin = instance_cells[i];
			const Vector3 cell_centre = cell_origin + Vector3(16.0f, 0.0f, 16.0f);
			if (v2v3(p_snapped_pos).distance_to(cell_centre) > p_radius) {
				LOG(EXTREME, "Decomposing at ", cell_origin);

				Dictionary active_instances_dict = _active_instance_cells[cell_origin];
				const TypedArray<int> mesh_asset_keys = active_instances_dict.keys();

				for (int i = 0; i < mesh_asset_keys.size(); i++) {
					const int mesh_asset_id = mesh_asset_keys[i];
					const Array active_instances_arr = active_instances_dict[mesh_asset_id];
					Array unused_assets = recyclable_mesh_instance_shapes[mesh_asset_id];

					for (int j = 0; j < active_instances_arr.size(); j++) {
						unused_assets.append(active_instances_arr[j]);
					}

					recyclable_mesh_instance_shapes[mesh_asset_id] = unused_assets;
					LOG(EXTREME, "Stashed ", active_instances_arr.size(), " * mesh asset ID ", mesh_asset_id);
				}
				_active_instance_cells.erase(cell_origin);
			}
		}
	}
	return recyclable_mesh_instance_shapes;
}

Dictionary Terrain3DCollision::_get_instance_build_data(const TypedArray<Vector3> &p_instance_cells_to_build, const int &p_region_size, const real_t &p_vertex_spacing) {
	Dictionary mesh_instance_build_data;
	LOG(INFO, "Building instance data");

	for (int i = 0; i < p_instance_cells_to_build.size(); i++) {
		const Vector3 cell_position = p_instance_cells_to_build[i];
		Vector2i region_loc = _terrain->get_data()->get_region_location(cell_position);
		Vector2i cell_loc = _get_cell(cell_position, p_region_size);

		Terrain3DRegion *region = _terrain->get_data()->get_region_ptr(region_loc);
		if (!region) {
			LOG(WARN, "Could not get region at ", cell_position);
			continue;
		}

		const Dictionary mesh_inst_dict = region->get_instances();
		const Array mesh_types = mesh_inst_dict.keys();

		for (int m = 0; m < mesh_types.size(); m++) {
			const int mesh_id = mesh_types[m];
			LOG(EXTREME, "Checking mesh id ", mesh_id, " in region ", region_loc, " cell: ", cell_loc);

			// Verify mesh id is valid and has some meshes
			const Ref<Terrain3DMeshAsset> ma = _terrain->get_assets()->get_mesh_asset(mesh_id);
			if (ma.is_valid()) {
				if (!ma->is_enabled()) {
					continue;
				}
				if (ma->get_shape_count() == 0) {
					LOG(EXTREME, "MeshAsset ", mesh_id, " valid but has no collision shapes, skipping");
					continue;
				}
			} else {
				LOG(WARN, "MeshAsset ", mesh_id, " is null, skipping");
				continue;
			}

			const Dictionary cell_inst_dict = mesh_inst_dict[mesh_id];

			if (!cell_inst_dict.has(cell_loc)) {
				// no instances in this cell
				continue;
			}

			const Array triple = cell_inst_dict[cell_loc];

			if (triple.size() < 3) {
				LOG(WARN, "Triple is empty");
				continue;
			}

			TypedArray<Transform3D> xforms = triple[0];
		
			if (xforms.size() == 0) {
				// no instances to add
				continue;
			}

			LOG(DEBUG, xforms.size(), " instances of ", mesh_id, " to build in ", cell_position);

			for (int x = 0; x < xforms.size(); x++) {
				Transform3D xform = xforms[x];
				xform.origin += v2v3(region_loc * p_region_size * p_vertex_spacing);
				xforms[x] = xform;
			}

			TypedArray<Vector3> cell_positions;
			cell_positions.resize(xforms.size());
			cell_positions.fill(cell_position);

			// 0 = xforms, 1 = cell_positions
			Array instance_data = mesh_instance_build_data[mesh_id];
			if (instance_data.size() == 0) {
				instance_data.resize(2);
			}

			TypedArray<Transform3D> xforms_arr = instance_data[0];
			TypedArray<Vector3> cell_positions_arr = instance_data[1];
			xforms_arr.append_array(xforms);
			cell_positions_arr.append_array(cell_positions);
			instance_data[0] = xforms_arr;
			instance_data[1] = cell_positions_arr;

			mesh_instance_build_data[mesh_id] = instance_data;

			// Next mesh type
		}
		// Next cell
	}
	
	return mesh_instance_build_data;
}

Dictionary Terrain3DCollision::_get_unused_instance_shapes(const Dictionary &p_instance_build_data, Dictionary &p_recyclable_instance_shapes) {

	Dictionary unused_instance_shapes;
	if (is_dynamic_mode()) {
		LOG(INFO, "Decomposing spare assets");

		TypedArray<int> spare_instance_keys = p_recyclable_instance_shapes.keys();

		LOG(DEBUG, spare_instance_keys.size(), " types of instance to decompose");

		for (int i = 0; i < spare_instance_keys.size(); i++) {
			const int mesh_id = spare_instance_keys[i];
			LOG(EXTREME, "Decomposing  spare mesh id ", mesh_id);

			TypedArray<Transform3D> mesh_instance_transforms;
			Array instance_data = p_instance_build_data[mesh_id];
			if (instance_data.size() > 0) {
				mesh_instance_transforms = instance_data[0];
			}

			LOG(DEBUG, "Decomposing all but ", mesh_instance_transforms.size(), " assets of type ", mesh_id);
			int time = Time::get_singleton()->get_ticks_usec();

			if (!p_recyclable_instance_shapes.has(mesh_id)) {
				LOG(WARN, "Tried to decompose mesh ", mesh_id, " when none exist");
				continue;
			}

			TypedArray<Array> ma_arr = p_recyclable_instance_shapes[mesh_id];

			if (ma_arr.size() == 0) {
				LOG(ERROR, "Unexpectedly found no more assets to decompose");
				continue;
			}

			const int nb_instances_to_decompose = MAX(0, ma_arr.size() - mesh_instance_transforms.size());

			for (int instance = 0; instance < nb_instances_to_decompose; instance++) {
				TypedArray<RID> ma_instance = ma_arr.pop_back();
				if (ma_arr.size() == 0) {
					p_recyclable_instance_shapes.erase(mesh_id);
				} else {
					p_recyclable_instance_shapes[mesh_id] = ma_arr;
				}

				const Ref<Terrain3DMeshAsset> ma = _terrain->get_assets()->get_mesh_asset(mesh_id);

				for (int s = 0; s < ma->get_shape_count(); s++) {
					RID rid = ma_instance[s];
					int shape_type = PS->shape_get_type(rid);

					if (!rid.is_valid()) {
						LOG(WARN, "Tried to decompose shape with invalid RID");
						continue;
					}

					TypedArray<RID> unused_shapes = unused_instance_shapes[shape_type];
					unused_shapes.push_back(rid);
					unused_instance_shapes[shape_type] = unused_shapes;
					LOG(EXTREME, "Stored shape ", rid);
				}
			}
		}
	}
	return unused_instance_shapes;
}

void Terrain3DCollision::_destroy_remaining_instance_shapes(Dictionary &p_unused_instance_shapes) {
	
	if (is_dynamic_mode()) {
		LOG(INFO, "Destroying unused shapes");

		// This tracks whether we destroyed any shapes, if so we will update our RID/index map
		bool is_dirty = false;

		TypedArray<int> shape_types = p_unused_instance_shapes.keys();

		for (int i = 0; i < shape_types.size(); i++) {
			int mesh_id = shape_types[i];
			TypedArray<RID> inactive_shapes = p_unused_instance_shapes[mesh_id];

			LOG(DEBUG, "    Shape type: ", shape_types[i], " Found ", inactive_shapes.size(), " shapes");
			for (int s = 0; s < inactive_shapes.size(); s++) {
				const RID shape_rid = inactive_shapes[s];
			
				if (!shape_rid.is_valid()) {
					LOG(WARN, "Attempted to destroy an invalid shape");
					continue;
				}
				_destroy_visual_instance(shape_rid);
				PS->free_rid(shape_rid);
				is_dirty = true;
				LOG(EXTREME, "Destroyed ", shape_rid);
			}
			p_unused_instance_shapes.erase(mesh_id);
		}

		// If we destroyed shapes the body_shape indices will need to update the RID/index map.
		//
		if (is_dirty) {
			LOG(INFO, "Rebuilding shape indices");

			for (int i = 0; i < PS->body_get_shape_count(_instance_static_body_rid); i++) {
				_RID_index_map[PS->body_get_shape(_instance_static_body_rid, i)] = i;
			}
		}
	}
}

void Terrain3DCollision::_generate_instances(const Dictionary &p_instance_build_data, Dictionary &p_recyclable_instances, Dictionary &p_unused_instance_shapes) {

	LOG(INFO, "Creating or recyling instances");
	TypedArray<int> mesh_instance_keys = p_instance_build_data.keys();

	for (int i = 0; i < mesh_instance_keys.size(); i++) {
		const int mesh_id = mesh_instance_keys[i];

		// Verify mesh id is valid and has some meshes
		const Ref<Terrain3DMeshAsset> ma = _terrain->get_assets()->get_mesh_asset(mesh_id);
		if (ma.is_valid()) {
			if (!ma->is_enabled()) {
				LOG(ERROR, mesh_id, " is not enabled. This shouldn't happen.");
				continue;
			}
			if (ma->get_shape_count() == 0) {
				LOG(ERROR, "MeshAsset ", mesh_id, " valid but has no collision shapes, skipping. This shouldn't happen.");
				continue;
			}
		} else {
			LOG(ERROR, "MeshAsset ", mesh_id, " is null, skipping. This shouldn't happen.");
			continue;
		}

		const Array instance_data = p_instance_build_data[mesh_id];
		if (instance_data.size() == 0) {
			// No new instances of this type are needed
			continue;
		}

		const TypedArray<Transform3D> xforms = instance_data[0];
		const TypedArray<Vector3> cell_positions = instance_data[1];

		if (xforms.size() == 0 || cell_positions.size() == 0) {
			LOG(ERROR, "No instances of type ", mesh_id, " to create. This shouldn't happen.");
			continue;
		}

		for (int x = 0; x < xforms.size(); x++) {
			TypedArray<RID> shapes;

			Transform3D xform = xforms[x];
			const Vector3 cell_pos = cell_positions[x];
			Dictionary active_instances_dict = _active_instance_cells[cell_pos];
			TypedArray<Array> active_instances_arr = active_instances_dict[mesh_id];

			// Reuse mesh asset instance if possible
			TypedArray<Array> reusable_assets;
			if (p_recyclable_instances.has(mesh_id)) {
				reusable_assets = p_recyclable_instances[mesh_id];
			}

			if (reusable_assets.size() > 0) {
				const TypedArray<RID> reusable_shapes = reusable_assets.pop_back();
				if (reusable_assets.size() == 0) {
					p_recyclable_instances.erase(mesh_id);
				} else {
					p_recyclable_instances[mesh_id] = reusable_assets;
				}

				for (int s = 0; s < reusable_shapes.size(); s++) {
					const Transform3D shape_transform = ma->get_shape_transforms()[s];
					const Transform3D this_transform = xform * shape_transform;

					const RID shape_rid = reusable_shapes[s];

					// Get the shape index from the map
					if (!_RID_index_map.has(shape_rid)) {
						// There is a problem with our RID/index map
						LOG(ERROR, shape_rid, " does not have an entry in RID_index_map. This shouldn't happen.");
						continue;
					}

					const int shape_id = _RID_index_map[shape_rid];

					LOG(EXTREME, "Recycling shape_rid : ", shape_rid, " id : ", shape_id);

					PS->body_set_shape_transform(_instance_static_body_rid, shape_id, this_transform);
					if (is_editor_mode()) {
						_update_visual_instance(shape_rid, this_transform);
					}
				}

				active_instances_arr.push_back(reusable_shapes);

			} else {
				// No shapes to recycle, create new ones
				LOG(DEBUG, "No instances of ", mesh_id, " to recycle");

				for (int i = 0; i < ma->get_shape_count(); i++) {
					const Ref<Shape3D> ma_shape = cast_to<Shape3D>(ma->get_shapes()[i]);
					const Transform3D shape_transforms = ma->get_shape_transforms()[i];
					const int shape_type = PS->shape_get_type(ma_shape->get_rid());
					const Transform3D this_transform = xform * shape_transforms;

					RID shape_rid = RID();

					// Check for a shape in the unused shapes pool
					if (p_unused_instance_shapes.has(shape_type)) {
						// Reuse a shape from the unused shapes pool
						TypedArray<RID> unused_shapes = p_unused_instance_shapes[shape_type];
						if (unused_shapes.size() > 0) {
							shape_rid = unused_shapes.pop_back();
						
							if (unused_shapes.size() == 0) {
								p_unused_instance_shapes.erase(shape_type);
							} else {
								p_unused_instance_shapes[shape_type] = unused_shapes;
							}
							
							const int shape_id = _RID_index_map[shape_rid];
							PS->shape_set_data(shape_rid, PS->shape_get_data(ma_shape->get_rid()));			
							
							shapes.push_back(shape_rid);

							if (is_editor_mode()) {
								PS->body_set_shape_transform(_instance_static_body_rid, shape_id, this_transform);
								_update_visual_instance(shape_rid, this_transform, ma_shape->get_debug_mesh());
							}
						}
					}

					// If we didn't find a shape to recycle, create a new one
					if (!shape_rid.is_valid()) {
						LOG(DEBUG, "No shapes to recycle. Creating new shape for ", ma_shape->get_name(), " type: ", shape_type);
						// Create shape using PS
						// Different methods are required to create different shapes
						switch (shape_type) {
							case PhysicsServer3D::ShapeType::SHAPE_SPHERE:
								shape_rid = PS->sphere_shape_create();
								break;
							case PhysicsServer3D::ShapeType::SHAPE_BOX:
								shape_rid = PS->box_shape_create();
								break;
							case PhysicsServer3D::ShapeType::SHAPE_CAPSULE:
								shape_rid = PS->capsule_shape_create();
								break;
							case PhysicsServer3D::ShapeType::SHAPE_CYLINDER:
								shape_rid = PS->cylinder_shape_create();
								break;
							case PhysicsServer3D::ShapeType::SHAPE_CONVEX_POLYGON:
								shape_rid = PS->convex_polygon_shape_create();
								break;
							case PhysicsServer3D::ShapeType::SHAPE_CONCAVE_POLYGON:
								shape_rid = PS->concave_polygon_shape_create();
								break;
							default:
								LOG(WARN, "Tried to use unsupported shape type : ", shape_type);
								break;
						}

						if (!shape_rid.is_valid()) {
							LOG(ERROR, "Failed to create shape type : ", shape_type);
							continue;
						}

						const int shape_id = PS->body_get_shape_count(_instance_static_body_rid);

						// Add the index to our map
						_RID_index_map[shape_rid] = shape_id;

						PS->body_add_shape(_instance_static_body_rid, shape_rid, this_transform);
						PS->shape_set_data(shape_rid, PS->shape_get_data(ma_shape->get_rid()));

						shapes.push_back(shape_rid);

						if (is_editor_mode()) {
							_create_visual_instance(shape_rid, this_transform, ma_shape->get_debug_mesh());
						}
					}
					// next shape++
				}
				active_instances_arr.push_back(shapes);
			}
			active_instances_dict[mesh_id] = active_instances_arr;
			_active_instance_cells[cell_pos] = active_instances_dict;
		}
	}
}

void Terrain3DCollision::_update_instance_collision() {
	const int time = Time::get_singleton()->get_ticks_usec();
	const int region_size = _terrain->get_region_size();
	const real_t vertex_spacing = _terrain->get_vertex_spacing();
	const int cell_size = _terrain->get_instancer()->CELL_SIZE;
	const Vector2i snapped_pos = _snap_to_grid(_terrain->get_snapped_position() / vertex_spacing);

	if (!_terrain->get_data()->get_regionp(v2v3(snapped_pos)).is_valid()) {
		return;
	}

	// Create a static body if none exists
	if (!_instance_static_body_rid.is_valid()) {
		_instance_static_body_rid = PS->body_create();
		PS->body_set_mode(_instance_static_body_rid, PhysicsServer3D::BODY_MODE_STATIC);
		PS->body_set_space(_instance_static_body_rid, _terrain->get_world_3d()->get_space());
		PS->body_attach_object_instance_id(_instance_static_body_rid, _terrain->get_instance_id());
		PS->body_set_collision_mask(_instance_static_body_rid, _mask);
		PS->body_set_collision_layer(_instance_static_body_rid, _layer);
		PS->body_set_collision_priority(_instance_static_body_rid, _priority);
	}

	// Determine which cells need to be built
	const TypedArray<Vector3> instance_cells_to_build = get_instance_cells_to_build(snapped_pos, region_size, cell_size, vertex_spacing);

	// Decompose cells outside of radius
	// Stored as {mesh_asset_id:int} -> [shapes [RID, Body_ID]]
	Dictionary recyclable_instances = _get_recyclable_instances(snapped_pos, real_t(_radius));

	// Build a list of instances to create
	// Stored as {mesh_id: int} [global_xform] [cell_position]
	Dictionary instance_build_data = _get_instance_build_data(instance_cells_to_build, region_size, vertex_spacing);

	// Decompose assets which will not be recycled in full
	// They are decomposed into their component shapes, which may yet be reused
	// Stored as {ShapeType:int} -> [shapes [RID, Body_ID]]
	Dictionary unused_instance_shapes = _get_unused_instance_shapes(instance_build_data, recyclable_instances);

	// Do the instancing
	//
	_generate_instances(instance_build_data, recyclable_instances, unused_instance_shapes);

	// Destroy any remaining unused shapes
	//
	_destroy_remaining_instance_shapes(unused_instance_shapes);

	LOG(EXTREME, "Active instance collision cell count : ", _active_instance_cells.size());
	LOG(EXTREME, "Instance shape count = ", PS->body_get_shape_count(_instance_static_body_rid));
	LOG(EXTREME, "Instance collision update time: ", Time::get_singleton()->get_ticks_usec() - time, " us");
}

void Terrain3DCollision::_destroy_instance_collision() {
	LOG(INFO, "Destroying instance collision");

	int time = Time::get_singleton()->get_ticks_usec();

	if (_instance_static_body_rid.is_valid()) {
		while (PS->body_get_shape_count(_instance_static_body_rid) > 0) {
			RID shape_rid = PS->body_get_shape(_instance_static_body_rid, 0);
			PS->free_rid(shape_rid);
		}

		PS->free_rid(_instance_static_body_rid);
		_instance_static_body_rid = RID();
	}
	_active_instance_cells.clear();
	_destroy_visual_instances();

	LOG(EXTREME, "Destroy instance collision update time: ", Time::get_singleton()->get_ticks_usec() - time, " us");
}

void Terrain3DCollision::_create_visual_instance(const RID &p_shape_rid, const Transform3D &p_xform, Ref<ArrayMesh> p_debug_mesh) {
	int time = Time::get_singleton()->get_ticks_usec();

	if (!p_xform.is_finite()) {
		LOG(WARN, "Transform invalid for shape ", p_shape_rid);
		LOG(WARN, "xform: ", p_xform);
		return;
	}

	if (!p_debug_mesh.is_valid()) {
		LOG(WARN, "Invalid debug mesh for shape ", p_shape_rid);
		return;
	}

	if (_instance_shape_visual_pairs.has(p_shape_rid)) {
		LOG(WARN, "Visual instance already exists for shape ", p_shape_rid);
		return;
	}

	RID visual_rid = RS->instance_create();
	RS->instance_set_scenario(visual_rid, _terrain->get_world_3d()->get_scenario());
	RS->instance_set_base(visual_rid, p_debug_mesh->get_rid());
	RS->instance_set_transform(visual_rid, p_xform);

	_instance_shape_visual_pairs[p_shape_rid] = visual_rid;

	LOG(EXTREME, "Created visual rid ", visual_rid, "to pair with ", p_shape_rid, " at ", p_xform.origin, " in ", Time::get_singleton()->get_ticks_usec() - time, " us");
}

void Terrain3DCollision::_update_visual_instance(const RID &p_shape_rid, const Transform3D &p_xform, Ref<ArrayMesh> p_debug_mesh) {
	int time = Time::get_singleton()->get_ticks_usec();

	if (!p_xform.is_finite()) {
		LOG(WARN, "Transform invalid for shape ", p_shape_rid);
		LOG(WARN, "xform: ", p_xform);
		return;
	}

	RID visual_rid = _instance_shape_visual_pairs[p_shape_rid];

	if (!visual_rid.is_valid()) {
		LOG(WARN, "Visual instance RID for shape ", p_shape_rid, " was invalid, skipping");
		return;
	}

	RS->instance_set_transform(visual_rid, p_xform);

	if (!p_debug_mesh.is_null()) {
		RS->instance_set_base(visual_rid, p_debug_mesh->get_rid());
	}

	LOG(EXTREME, "Updated visual instance in : ", Time::get_singleton()->get_ticks_usec() - time, " us");
}

void Terrain3DCollision::_destroy_visual_instance(const RID &p_shape_rid) {

	int time = Time::get_singleton()->get_ticks_usec();
	
	RID visual_rid = _instance_shape_visual_pairs[p_shape_rid];

	if (!visual_rid.is_valid()) {
		LOG(EXTREME, "Visual instance RID invalid, skipping");
		return;
	}

	LOG(EXTREME, "Destroying ", visual_rid, " which was paired with shape ", p_shape_rid);

	RS->free_rid(visual_rid);
	_instance_shape_visual_pairs.erase(p_shape_rid);

	LOG(EXTREME, "Destroyed visual instance ", visual_rid, " which was paired with shape ", p_shape_rid ,"in : ", Time::get_singleton()->get_ticks_usec() - time, " us");
}

void Terrain3DCollision::_destroy_visual_instances() {
	LOG(INFO, "Destroying visual instances");

	int time = Time::get_singleton()->get_ticks_usec();
	Array keys = _instance_shape_visual_pairs.keys();

	for (int i = 0; i < keys.size(); i++) {
		RID shape_rid = _instance_shape_visual_pairs[keys[i]];
		_destroy_visual_instance(shape_rid);
	}
	_instance_shape_visual_pairs.clear();

	LOG(EXTREME, "Destroyed all visual instances in : ", Time::get_singleton()->get_ticks_usec() - time, " us");
}

///////////////////////////
// Public Functions
///////////////////////////

void Terrain3DCollision::initialize(Terrain3D *p_terrain) {
	if (p_terrain) {
		_terrain = p_terrain;
	} else {
		return;
	}
	if (!IS_EDITOR && is_editor_mode()) {
		LOG(WARN, "Change collision mode to a non-editor mode for releases");
	}
	build();
}

void Terrain3DCollision::build() {
	IS_DATA_INIT(VOID);
	if (!_terrain->is_inside_world()) {
		LOG(ERROR, "Terrain isn't inside world. Returning.");
		return;
	}

	// Clear collision as the user might change modes in the editor
	destroy();

	// Build only in applicable modes
	if (!is_enabled() || (IS_EDITOR && !is_editor_mode())) {
		return;
	}

	// Create StaticBody3D
	if (is_editor_mode()) {
		LOG(INFO, "Building editor collision");
		_static_body = memnew(StaticBody3D);
		_static_body->set_name("StaticBody3D");
		_static_body->set_as_top_level(true);
		_terrain->add_child(_static_body, true);
		_static_body->set_owner(_terrain);
		_static_body->set_collision_mask(_mask);
		_static_body->set_collision_layer(_layer);
		_static_body->set_collision_priority(_priority);
	} else {
		LOG(INFO, "Building collision with Physics Server");
		_static_body_rid = PS->body_create();
		PS->body_set_mode(_static_body_rid, PhysicsServer3D::BODY_MODE_STATIC);
		PS->body_set_space(_static_body_rid, _terrain->get_world_3d()->get_space());
		PS->body_attach_object_instance_id(_static_body_rid, _terrain->get_instance_id());
		PS->body_set_collision_mask(_static_body_rid, _mask);
		PS->body_set_collision_layer(_static_body_rid, _layer);
		PS->body_set_collision_priority(_static_body_rid, _priority);
	}
	_reload_physics_material();

	// Create CollisionShape3Ds
	int shape_count;
	int hshape_size;
	if (is_dynamic_mode()) {
		int grid_width = _radius * 2 / _shape_size;
		grid_width = int_ceil_pow2(grid_width, 4);
		shape_count = grid_width * grid_width;
		hshape_size = _shape_size + 1;
		LOG(DEBUG, "Grid width: ", grid_width);
	} else {
		shape_count = _terrain->get_data()->get_region_count();
		hshape_size = _terrain->get_region_size() + 1;
	}
	// Preallocate memory for push_back()
	if (is_editor_mode()) {
		_shapes.reserve(shape_count);
	}
	LOG(DEBUG, "Shape count: ", shape_count);
	LOG(DEBUG, "Shape size: ", _shape_size, ", hshape_size: ", hshape_size);
	Transform3D xform(Basis(), V3_MAX);
	for (int i = 0; i < shape_count; i++) {
		if (is_editor_mode()) {
			CollisionShape3D *col_shape = memnew(CollisionShape3D);
			_shapes.push_back(col_shape);
			col_shape->set_name("CollisionShape3D");
			col_shape->set_disabled(true);
			col_shape->set_visible(true);
			Ref<HeightMapShape3D> hshape;
			hshape.instantiate();
			hshape->set_map_width(hshape_size);
			hshape->set_map_depth(hshape_size);
			col_shape->set_shape(hshape);
			_static_body->add_child(col_shape, true);
			col_shape->set_owner(_static_body);
			col_shape->set_transform(xform);
		} else {
			RID shape_rid = PS->heightmap_shape_create();
			PS->body_add_shape(_static_body_rid, shape_rid, xform, true);
			LOG(DEBUG, "Adding shape: ", i, ", rid: ", shape_rid.get_id(), " pos: ", _shape_get_position(i));
		}
	}

	_initialized = true;
	update();
}

void Terrain3DCollision::update(const bool p_rebuild) {
	if (!_initialized) {
		return;
	}
	if (p_rebuild && !is_dynamic_mode()) {
		build();
		return;
	}
	int time = Time::get_singleton()->get_ticks_usec();
	real_t spacing = _terrain->get_vertex_spacing();

	if (is_dynamic_mode()) {
		// Snap descaled position to a _shape_size grid (eg. multiples of 16)
		Vector2i snapped_pos = _snap_to_grid(_terrain->get_snapped_position() / spacing);
		LOG(EXTREME, "Updating collision at ", snapped_pos);

		// Skip if location hasn't moved to next step
		if (!p_rebuild && (_last_snapped_pos - snapped_pos).length() < _shape_size) {
			return;
		}

		LOG(EXTREME, "---- 1. Defining area as a radius on a grid ----");
		// Create a 0-N grid, center on snapped_pos
		PackedInt32Array grid;
		int grid_width = _radius * 2 / _shape_size; // 64*2/16 = 8
		grid_width = int_ceil_pow2(grid_width, 4);
		grid.resize(grid_width * grid_width);
		grid.fill(-1);
		Vector2i grid_offset = -V2I(grid_width / 2); // offset # cells to center of grid
		Vector2i shape_offset = V2I(_shape_size / 2); // offset meters to top left corner of shape
		Vector2i grid_pos = snapped_pos + grid_offset * _shape_size; // Top left of grid
		LOG(EXTREME, "New Snapped position: ", snapped_pos);
		LOG(EXTREME, "Grid_pos: ", grid_pos);
		LOG(EXTREME, "Radius: ", _radius, ", Grid_width: ", grid_width, ", Grid_offset: ", grid_offset, ", # cells: ", grid.size());
		LOG(EXTREME, "Shape_size: ", _shape_size, ", shape_offset: ", shape_offset);

		LOG(EXTREME, "---- 2. Checking existing shapes ----");
		// If shape is within area, skip
		// Else, mark unused

		// Stores index into _shapes array
		TypedArray<int> inactive_shape_ids;

		int shape_count = is_editor_mode() ? _shapes.size() : PS->body_get_shape_count(_static_body_rid);
		for (int i = 0; i < shape_count; i++) {
			// Descaled global position of shape center
			Vector3 shape_center = _shape_get_position(i) / spacing;
			// Unique key: Top left corner of shape, snapped to grid
			Vector2i shape_pos = _snap_to_grid(v3v2i(shape_center) - shape_offset);
			// Optionally could adjust radius to account for corner (sqrt(_shape_size*2))
			if (!p_rebuild && (shape_center.x < FLT_MAX && v3v2i(shape_center).distance_to(snapped_pos) <= real_t(_radius))) {
				// Get index into shape array
				Vector2i grid_loc = (shape_pos - grid_pos) / _shape_size;
				grid[grid_loc.y * grid_width + grid_loc.x] = i;
				_shape_set_disabled(i, false);
				LOG(EXTREME, "Shape ", i, ": shape_center: ", shape_center.x < FLT_MAX ? shape_center : V3(-999), ", shape_pos: ", shape_pos,
						", grid_loc: ", grid_loc, ", index: ", (grid_loc.y * grid_width + grid_loc.x), " active");
			} else {
				inactive_shape_ids.push_back(i);
				_shape_set_disabled(i, true);
				LOG(EXTREME, "Shape ", i, ": shape_center: ", shape_center.x < FLT_MAX ? shape_center : V3(-999), ", shape_pos: ", shape_pos,
						" out of bounds, marking inactive");
			}
		}
		LOG(EXTREME, "_inactive_shapes size: ", inactive_shape_ids.size());

		LOG(EXTREME, "---- 3. Review grid cells in area ----");
		// If cell is full, skip
		// Else assign shape and form it

		for (int i = 0; i < grid.size(); i++) {
			Vector2i grid_loc(i % grid_width, i / grid_width);
			// Unique key: Top left corner of shape, snapped to grid
			Vector2i shape_pos = grid_pos + grid_loc * _shape_size;

			if ((shape_pos + shape_offset).distance_to(snapped_pos) > real_t(_radius)) {
				LOG(EXTREME, "grid[", i, ":", grid_loc, "] shape_pos : ", shape_pos, " out of circle, skipping");
				continue;
			}
			if (!p_rebuild && grid[i] >= 0) {
				Vector2i center_pos = v3v2i(_shape_get_position(i));
				LOG(EXTREME, "grid[", i, ":", grid_loc, "] shape_pos : ", shape_pos, " act ", center_pos - shape_offset, " Has active shape id: ", grid[i]);
				continue;
			} else {
				if (inactive_shape_ids.size() == 0) {
					LOG(ERROR, "No more unused shapes! Aborting!");
					break;
				}
				Dictionary shape_data = _get_shape_data(shape_pos, _shape_size);
				if (shape_data.is_empty()) {
					LOG(EXTREME, "grid[", i, ":", grid_loc, "] shape_pos : ", shape_pos, " No region found");
					continue;
				}
				int shape_id = inactive_shape_ids.pop_back();
				Transform3D xform = shape_data["xform"];
				LOG(EXTREME, "grid[", i, ":", grid_loc, "] shape_pos : ", shape_pos, " act ", v3v2i(xform.origin) - shape_offset, " placing shape id ", shape_id);
				xform.scale(Vector3(spacing, 1.f, spacing));
				_shape_set_transform(shape_id, xform);
				_shape_set_disabled(shape_id, false);
				_shape_set_data(shape_id, shape_data);
			}
		}

		LOG(EXTREME, "Terrain collision update time: ", Time::get_singleton()->get_ticks_usec() - time, " us");
		_update_instance_collision();

		_last_snapped_pos = snapped_pos;
		LOG(EXTREME, "Setting _last_snapped_pos: ", _last_snapped_pos);
		LOG(EXTREME, "inactive_shape_ids size: ", inactive_shape_ids.size());

	} else {
		// Full collision
		int shape_count = _terrain->get_data()->get_region_count();
		int region_size = _terrain->get_region_size();
		TypedArray<Vector2i> region_locs = _terrain->get_data()->get_region_locations();
		for (int i = 0; i < region_locs.size(); i++) {
			Vector2i region_loc = region_locs[i];
			Vector2i shape_pos = region_loc * region_size;
			Dictionary shape_data = _get_shape_data(shape_pos, region_size);
			if (shape_data.is_empty()) {
				LOG(ERROR, "Can't get shape data for ", region_loc);
				continue;
			}
			Transform3D xform = shape_data["xform"];
			xform.scale(Vector3(spacing, 1.f, spacing));
			_shape_set_transform(i, xform);
			_shape_set_disabled(i, false);
			_shape_set_data(i, shape_data);
		}
		LOG(EXTREME, "Terrain collision update time: ", Time::get_singleton()->get_ticks_usec() - time, " us");
		_update_instance_collision();
	}
	LOG(EXTREME, "Collision update time: ", Time::get_singleton()->get_ticks_usec() - time, " us");
}

void Terrain3DCollision::destroy() {
	_initialized = false;
	_last_snapped_pos = V2I_MAX;

	// Physics Server
	if (_static_body_rid.is_valid()) {
		// Shape IDs change as they are freed, so it's not safe to iterate over them while freeing.
		while (PS->body_get_shape_count(_static_body_rid) > 0) {
			RID rid = PS->body_get_shape(_static_body_rid, 0);
			LOG(DEBUG, "Freeing CollisionShape RID ", rid);
			PS->free_rid(rid);
		}

		LOG(DEBUG, "Freeing StaticBody RID");
		PS->free_rid(_static_body_rid);
		_static_body_rid = RID();
	}

	// Scene Tree
	for (int i = 0; i < _shapes.size(); i++) {
		CollisionShape3D *shape = _shapes[i];
		LOG(DEBUG, "Freeing CollisionShape3D ", i, " ", shape->get_name());
		remove_from_tree(shape);
		memdelete_safely(shape);
	}
	_shapes.clear();
	if (_static_body) {
		LOG(DEBUG, "Freeing StaticBody3D");
		remove_from_tree(_static_body);
		memdelete_safely(_static_body);
	}
	_destroy_instance_collision();
}

void Terrain3DCollision::set_mode(const CollisionMode p_mode) {
	LOG(INFO, "Setting collision mode: ", p_mode);
	if (p_mode != _mode) {
		_mode = p_mode;
		if (is_enabled()) {
			build();
		} else {
			destroy();
		}
	}
}

void Terrain3DCollision::set_shape_size(const uint16_t p_size) {
	int size = CLAMP(p_size, 8, 64);
	size = int_round_mult(size, 8);
	LOG(INFO, "Setting collision dynamic shape size: ", size);
	_shape_size = size;
	// Ensure size:radius always results in at least one valid shape
	if (_shape_size > _radius - 8) {
		set_radius(_shape_size + 16);
	} else if (is_dynamic_mode()) {
		build();
	}
}

void Terrain3DCollision::set_radius(const uint16_t p_radius) {
	int radius = CLAMP(p_radius, 16, 256);
	radius = int_ceil_pow2(radius, 16);
	LOG(INFO, "Setting collision dynamic radius: ", radius);
	_radius = radius;
	// Ensure size:radius always results in at least one valid shape
	if (_radius < _shape_size + 8) {
		set_shape_size(_radius - 8);
	} else if (_shape_size < 16 && _radius > 128) {
		set_shape_size(16);
	} else if (is_dynamic_mode()) {
		build();
	}
}

void Terrain3DCollision::set_layer(const uint32_t p_layers) {
	LOG(INFO, "Setting collision layers: ", p_layers);
	_layer = p_layers;
	if (is_editor_mode()) {
		if (_static_body) {
			_static_body->set_collision_layer(_layer);
		}
	} else {
		if (_static_body_rid.is_valid()) {
			PS->body_set_collision_layer(_static_body_rid, _layer);
		}
	}
}

void Terrain3DCollision::set_mask(const uint32_t p_mask) {
	LOG(INFO, "Setting collision mask: ", p_mask);
	_mask = p_mask;
	if (is_editor_mode()) {
		if (_static_body) {
			_static_body->set_collision_mask(_mask);
		}
	} else {
		if (_static_body_rid.is_valid()) {
			PS->body_set_collision_mask(_static_body_rid, _mask);
		}
	}
}

void Terrain3DCollision::set_priority(const real_t p_priority) {
	LOG(INFO, "Setting collision priority: ", p_priority);
	_priority = p_priority;
	if (is_editor_mode()) {
		if (_static_body) {
			_static_body->set_collision_priority(_priority);
		}
	} else {
		if (_static_body_rid.is_valid()) {
			PS->body_set_collision_priority(_static_body_rid, _priority);
		}
	}
}

void Terrain3DCollision::set_physics_material(const Ref<PhysicsMaterial> &p_mat) {
	LOG(INFO, "Setting physics material: ", p_mat);
	if (_physics_material.is_valid()) {
		if (_physics_material->is_connected("changed", callable_mp(this, &Terrain3DCollision::_reload_physics_material))) {
			LOG(DEBUG, "Disconnecting _physics_material::changed signal to _reload_physics_material()");
			_physics_material->disconnect("changed", callable_mp(this, &Terrain3DCollision::_reload_physics_material));
		}
	}
	_physics_material = p_mat;
	if (_physics_material.is_valid()) {
		LOG(DEBUG, "Connecting _physics_material::changed signal to _reload_physics_material()");
		_physics_material->connect("changed", callable_mp(this, &Terrain3DCollision::_reload_physics_material));
	}
	_reload_physics_material();
}

RID Terrain3DCollision::get_rid() const {
	if (!is_editor_mode()) {
		return _static_body_rid;
	} else {
		if (_static_body) {
			return _static_body->get_rid();
		}
	}
	return RID();
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DCollision::_bind_methods() {
	BIND_ENUM_CONSTANT(DISABLED);
	BIND_ENUM_CONSTANT(DYNAMIC_GAME);
	BIND_ENUM_CONSTANT(DYNAMIC_EDITOR);
	BIND_ENUM_CONSTANT(FULL_GAME);
	BIND_ENUM_CONSTANT(FULL_EDITOR);

	ClassDB::bind_method(D_METHOD("build"), &Terrain3DCollision::build);
	ClassDB::bind_method(D_METHOD("update", "rebuild"), &Terrain3DCollision::update, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("destroy"), &Terrain3DCollision::destroy);
	ClassDB::bind_method(D_METHOD("set_mode", "mode"), &Terrain3DCollision::set_mode);
	ClassDB::bind_method(D_METHOD("get_mode"), &Terrain3DCollision::get_mode);
	ClassDB::bind_method(D_METHOD("is_enabled"), &Terrain3DCollision::is_enabled);
	ClassDB::bind_method(D_METHOD("is_editor_mode"), &Terrain3DCollision::is_editor_mode);
	ClassDB::bind_method(D_METHOD("is_dynamic_mode"), &Terrain3DCollision::is_dynamic_mode);

	ClassDB::bind_method(D_METHOD("set_shape_size", "size"), &Terrain3DCollision::set_shape_size);
	ClassDB::bind_method(D_METHOD("get_shape_size"), &Terrain3DCollision::get_shape_size);
	ClassDB::bind_method(D_METHOD("set_radius", "radius"), &Terrain3DCollision::set_radius);
	ClassDB::bind_method(D_METHOD("get_radius"), &Terrain3DCollision::get_radius);
	ClassDB::bind_method(D_METHOD("set_layer", "layers"), &Terrain3DCollision::set_layer);
	ClassDB::bind_method(D_METHOD("get_layer"), &Terrain3DCollision::get_layer);
	ClassDB::bind_method(D_METHOD("set_mask", "mask"), &Terrain3DCollision::set_mask);
	ClassDB::bind_method(D_METHOD("get_mask"), &Terrain3DCollision::get_mask);
	ClassDB::bind_method(D_METHOD("set_priority", "priority"), &Terrain3DCollision::set_priority);
	ClassDB::bind_method(D_METHOD("get_priority"), &Terrain3DCollision::get_priority);
	ClassDB::bind_method(D_METHOD("set_physics_material", "material"), &Terrain3DCollision::set_physics_material);
	ClassDB::bind_method(D_METHOD("get_physics_material"), &Terrain3DCollision::get_physics_material);
	ClassDB::bind_method(D_METHOD("get_rid"), &Terrain3DCollision::get_rid);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "mode", PROPERTY_HINT_ENUM, "Disabled,Dynamic / Game,Dynamic / Editor,Full / Game,Full / Editor"), "set_mode", "get_mode");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "shape_size", PROPERTY_HINT_RANGE, "8,64,8"), "set_shape_size", "get_shape_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "radius", PROPERTY_HINT_RANGE, "16,256,16"), "set_radius", "get_radius");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "layer", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_layer", "get_layer");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mask", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_mask", "get_mask");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "priority", PROPERTY_HINT_RANGE, "0.1,256,.1"), "set_priority", "get_priority");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "physics_material", PROPERTY_HINT_RESOURCE_TYPE, "PhysicsMaterial"), "set_physics_material", "get_physics_material");
}
