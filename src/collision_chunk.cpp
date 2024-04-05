// Copyright © 2024 Lorenz Wildberg

#include "collision_chunk.h"
#include "logger.h"
#include <godot_cpp/classes/height_map_shape3d.hpp>

CollisionChunk::CollisionChunk(CollisionChunkManager *p_manager, uint p_size) :
		BaseChunk(p_manager, p_size) {
	_col_shape = memnew(CollisionShape3D);
	_col_shape->set_name("CollisionShape3D");
	_col_shape->set_visible(true);
	Ref<HeightMapShape3D> hshape;
	hshape.instantiate();
	hshape->set_map_width(p_size);
	hshape->set_map_depth(p_size);
	_col_shape->set_shape(hshape);
	((CollisionChunkManager *)_manager)->_body->add_child(_col_shape);
	_col_shape->set_owner(((CollisionChunkManager *)_manager)->_body);
	LOG(INFO, "new chunk");
}

CollisionChunk::~CollisionChunk() {
	((CollisionChunkManager *)_manager)->_body->remove_child(_col_shape);
	memdelete(_col_shape);
}

void CollisionChunk::refill() {
	//
}

void CollisionChunk::set_position(Vector2i p_position) {
	BaseChunk::set_position(p_position);
	_col_shape->set_position(Vector3(p_position.x, 0.0, p_position.y));
}

void CollisionChunk::set_enabled(bool enabled) {
	_col_shape->set_visible(enabled);
}
