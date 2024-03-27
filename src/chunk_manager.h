// Copyright © 2024 Lorenz Wildberg

#ifndef CHUNKMANAGER_CLASS_H
#define CHUNKMANAGER_CLASS_H

#include "base_chunk.h"

using namespace godot;

class ChunkManager {
public:
	// Constants
	static inline const char *__class__ = "Terrain3DChunkManager";

private:
  float _chunk_size;
  float _distance;
  float _chunks_width;
  int _chunk_count;
  Array _active_chunks;
  Array _old_chunks;
  Array _inactive_chunks;
  Vector2i _old_snapped_pos;

  Vector2i _snap_position(Vector3 p_position);
  void _destroy();
  void _build();

public:
  void set_chunk_size(float p_size);
  float get_chunk_size() { return _chunk_size; }
  void set_distance(float p_distance);
  float get_distance() { return _distance; }
  void move(Vector3 p_camera_position);
  virtual BaseChunk* create_chunk() = 0;
};

#endif
