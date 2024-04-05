// Copyright © 2024 Lorenz Wildberg

#include "collision_chunk_manager.h"
#include "collision_chunk.h"

CollisionChunkManager::CollisionChunkManager() {
	_body = memnew(StaticBody3D);
	add_child(_body);
	_body->set_owner(this);
}

CollisionChunkManager::~CollisionChunkManager() {
	if (_body != nullptr) {
		remove_child(_body);
		memfree(_body);
	}
}

BaseChunk *CollisionChunkManager::create_chunk() {
	CollisionChunk *chunk = memnew(CollisionChunk(this, _chunk_size));
	return chunk;
}
