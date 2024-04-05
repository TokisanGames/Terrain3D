// Copyright © 2024 Lorenz Wildberg

#ifndef COLLISIONCHUNK_CLASS_H
#define COLLISIONCHUNK_CLASS_H

#include "base_chunk.h"
#include "collision_chunk_manager.h"
#include <godot_cpp/classes/collision_shape3d.hpp>

using namespace godot;

class CollisionChunk : public BaseChunk {
	GDCLASS(CollisionChunk, BaseChunk);

public:
	// Constants
	static inline const char *__class__ = "Terrain3DCollisionChunk";

private:
	CollisionShape3D *_col_shape = nullptr;

public:
	CollisionChunk() {}
	CollisionChunk(CollisionChunkManager *p_manager, uint p_size);
	~CollisionChunk();

	void refill() override;
	void set_enabled(bool enabled) override;
	void set_position(Vector2i p_position) override;

protected:
	static void _bind_methods() {}
};

#endif
