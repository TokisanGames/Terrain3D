// Copyright © 2024 Lorenz Wildberg

#ifndef COLLISIONCHUNKMANAGER_CLASS_H
#define COLLISIONCHUNKMANAGER_CLASS_H

#include "chunk_manager.h"
#include <godot_cpp/classes/static_body3d.hpp>

using namespace godot;

class CollisionChunkManager : public ChunkManager {
	GDCLASS(CollisionChunkManager, ChunkManager);

public:
	// Constants
	static inline const char *__class__ = "Terrain3DCollisionChunkManager";

	StaticBody3D *_body = nullptr;

public:
	CollisionChunkManager();
	~CollisionChunkManager();

	BaseChunk *create_chunk() override;

protected:
	static void _bind_methods() {}
};

#endif
