// Copyright © 2024 Lorenz Wildberg

#include "editor_collision_chunk.h"
#include "logger.h"
#include <godot_cpp/classes/height_map_shape3d.hpp>
#include <godot_cpp/classes/project_settings.hpp>

EditorCollisionChunk::EditorCollisionChunk(EditorCollisionChunkManager *p_manager, uint p_size) :
		BaseChunk(p_manager, p_size) {
	_col_shape = memnew(CollisionShape3D);
	_col_shape->set_name("CollisionShape3D");
	_col_shape->set_visible(false);
	Ref<HeightMapShape3D> hshape;
	hshape.instantiate();
	hshape->set_map_width(p_size + 1);
	hshape->set_map_depth(p_size + 1);
	_col_shape->set_shape(hshape);
	((EditorCollisionChunkManager *)_manager)->_body->add_child(_col_shape);
	_col_shape->set_owner(((EditorCollisionChunkManager *)_manager)->_body);
	LOG(DEBUG, "new chunk");
}

EditorCollisionChunk::~EditorCollisionChunk() {
	((EditorCollisionChunkManager *)_manager)->_body->remove_child(_col_shape);
	memdelete(_col_shape);
}

void EditorCollisionChunk::refill() {
	Transform3D xform;
	PackedFloat32Array map_data = fill_map(&xform);

	Ref<HeightMapShape3D> hshape = _col_shape->get_shape();
	hshape->set_map_data(map_data);
	_col_shape->set_global_transform(xform);
}

inline PackedFloat32Array EditorCollisionChunk::fill_map(Transform3D *xform) {
	Ref<Terrain3DStorage> storage = ((CollisionChunkManager *)_manager)->_terrain->get_storage();
	float hole_const = NAN;
	if (ProjectSettings::get_singleton()->get_setting("physics/3d/physics_engine") == "JoltPhysics3D") {
		hole_const = __FLT_MAX__;
	}

	int region = storage->get_region_index(Vector3(_position.x, 0, _position.y));
	int region_size = storage->get_region_size();

	PackedFloat32Array map_data = PackedFloat32Array();
	map_data.resize(_size * _size);

	Ref<Image> map, map_x, map_z, map_xz;
	Ref<Image> cmap, cmap_x, cmap_z, cmap_xz;
	map = storage->get_map_region(Terrain3DStorage::TYPE_HEIGHT, region);
	cmap = storage->get_map_region(Terrain3DStorage::TYPE_CONTROL, region);
	if (region >= 0) {
		map = storage->get_map_region(Terrain3DStorage::TYPE_HEIGHT, region);
		cmap = storage->get_map_region(Terrain3DStorage::TYPE_CONTROL, region);
	}
	region = storage->get_region_index(Vector3(_position.x + _size, 0, _position.y));
	if (region >= 0) {
		map_x = storage->get_map_region(Terrain3DStorage::TYPE_HEIGHT, region);
		cmap_x = storage->get_map_region(Terrain3DStorage::TYPE_CONTROL, region);
	}
	region = storage->get_region_index(Vector3(_position.x, 0, _position.y + _size));
	if (region >= 0) {
		map_z = storage->get_map_region(Terrain3DStorage::TYPE_HEIGHT, region);
		cmap_z = storage->get_map_region(Terrain3DStorage::TYPE_CONTROL, region);
	}
	region = storage->get_region_index(Vector3(_position.x + _size, 0, _position.y + _size));
	if (region >= 0) {
		map_xz = storage->get_map_region(Terrain3DStorage::TYPE_HEIGHT, region);
		cmap_xz = storage->get_map_region(Terrain3DStorage::TYPE_CONTROL, region);
	}

	for (int z = 0; z < _size; z++) {
		for (int x = 0; x < _size; x++) {
			// Choose array indexing to match triangulation of heightmapshape with the mesh
			// https://stackoverflow.com/questions/16684856/rotating-a-2d-pixel-array-by-90-degrees
			// Normal array index rotated Y=0 - shape rotation Y=0 (xform below)
			// int index = z * shape_size + x;
			// Array Index Rotated Y=-90 - must rotate shape Y=+90 (xform below)
			int index = _size - 1 - z + x * _size;

			int shape_global_x = x + (_position.x % region_size);
			if (shape_global_x < 0) {
				shape_global_x = region_size + shape_global_x;
			}
			LOG(INFO, shape_global_x, " ", _position.x, " ", region_size, " ", x);
			int shape_global_z = z + (_position.y % region_size);
			if (shape_global_z < 0) {
				shape_global_z = region_size + shape_global_z;
			}
			// Set heights on local map, or adjacent maps if on the last row/col
			if (shape_global_x < region_size && shape_global_z < region_size) {
				if (map.is_valid()) {
					map_data[index] = (Util::is_hole(cmap->get_pixel(shape_global_x, shape_global_z).r)) ? hole_const : map->get_pixel(shape_global_x, shape_global_z).r;
				} else {
					map_data[index] = 0.0;
				}
			} else if (shape_global_x == region_size && shape_global_z < region_size) {
				if (map_x.is_valid()) {
					map_data[index] = (Util::is_hole(cmap_x->get_pixel(0, shape_global_z).r)) ? hole_const : map_x->get_pixel(0, shape_global_z).r;
				} else {
					map_data[index] = 0.0f;
				}
			} else if (shape_global_z == region_size && shape_global_x < region_size) {
				if (map_z.is_valid()) {
					map_data[index] = (Util::is_hole(cmap_z->get_pixel(shape_global_x, 0).r)) ? hole_const : map_z->get_pixel(shape_global_x, 0).r;
				} else {
					map_data[index] = 0.0f;
				}
			} else if (shape_global_x == region_size && shape_global_z == region_size) {
				if (map_xz.is_valid()) {
					map_data[index] = (Util::is_hole(cmap_xz->get_pixel(0, 0).r)) ? hole_const : map_xz->get_pixel(0, 0).r;
				} else {
					map_data[index] = 0.0f;
				}
			}
		}
	}

	// Non rotated shape for normal array index above
	//Transform3D xform = Transform3D(Basis(), global_pos);
	// Rotated shape Y=90 for -90 rotated array index
	*xform = Transform3D(Basis(Vector3(0, 1.0, 0), Math_PI * .5), Vector3(_position.x, 0.0, _position.y));

	return map_data;
}

void EditorCollisionChunk::set_position(Vector2i p_position) {
	BaseChunk::set_position(p_position);
	_col_shape->set_position(Vector3(p_position.x, 0.0, p_position.y));
}

void EditorCollisionChunk::set_enabled(bool enabled) {
	_col_shape->set_visible(enabled);
}
