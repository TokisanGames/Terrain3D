// Copyright © 2024 Lorenz Wildberg

#ifndef COLLISIONCHUNKMANAGER_CLASS_H
#define COLLISIONCHUNKMANAGER_CLASS_H

#include "chunk_manager.h"
#include "terrain_3d.h"
#include <godot_cpp/classes/static_body3d.hpp>

class Terrain3D;

using namespace godot;

class CollisionChunkManager : public ChunkManager {
	GDCLASS(CollisionChunkManager, ChunkManager);

public:
	// Constants
	static inline const char *__class__ = "Terrain3DCollisionChunkManager";

	Terrain3D *_terrain = nullptr;

public:
	CollisionChunkManager() {}

	void set_terrain(Terrain3D *p_terrain) { _terrain = p_terrain; }

protected:
	static void _bind_methods() {}
};

#endif
