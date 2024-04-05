// Copyright © 2024 Lorenz Wildberg

#ifndef BASECHUNK_CLASS_H
#define BASECHUNK_CLASS_H

#include "chunk_manager.h"
#include <godot_cpp/templates/vector.hpp>

using namespace godot;

class ChunkManager;

class BaseChunk : public Object {
	GDCLASS(BaseChunk, Object);

public:
	// Constants
	static inline const char *__class__ = "Terrain3DBaseChunk";

protected:
	Vector2i _position = Vector2i(0, 0);
	uint _size = 0;
	ChunkManager *_manager = nullptr;

public:
	virtual void refill() {}
	virtual void set_enabled(bool enabled) {}
	virtual void set_position(Vector2i p_position) { _position = p_position; };
	Vector2i get_position() { return _position; }

	BaseChunk() {}
	BaseChunk(ChunkManager *p_manager, uint p_size) {
		_manager = p_manager;
		_size = p_size;
	}

protected:
	static void _bind_methods() {}
};

#endif
