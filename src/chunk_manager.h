// Copyright © 2024 Lorenz Wildberg

#ifndef CHUNKMANAGER_CLASS_H
#define CHUNKMANAGER_CLASS_H

#include "base_chunk.h"
#include <godot_cpp/classes/node3d.hpp>

using namespace godot;

class BaseChunk;

class ChunkManager : public Node3D {
	GDCLASS(ChunkManager, Node3D);

public:
	// Constants
	static inline const char *__class__ = "Terrain3DChunkManager";

protected:
	uint _chunk_size = 16;

private:
	float _distance = 64.0;
	uint _chunks_width = 0;
	uint _chunk_count = 0;
	Array _active_chunks = Array();
	Array _old_chunks = Array();
	Array _inactive_chunks = Array();
	Vector2i _old_snapped_pos = Vector2i(0, 0);

	Vector2i _snap_position(Vector3 p_position);
	void _destroy();
	void _build();

public:
	ChunkManager() {}

	void set_chunk_size(uint p_size);
	uint get_chunk_size() { return _chunk_size; }
	void set_distance(float p_distance);
	float get_distance() { return _distance; }
	void move(Vector3 p_camera_position);

protected:
	virtual BaseChunk *create_chunk() { return nullptr; }
	static void _bind_methods() {}
};

#endif
