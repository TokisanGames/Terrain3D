// Copyright © 2024 Lorenz Wildberg

#ifndef BASECHUNK_CLASS_H
#define BASECHUNK_CLASS_H

#include <godot_cpp/templates/vector.hpp>

using namespace godot;

class BaseChunk : public Object {
public:
	// Constants
	static inline const char *__class__ = "Terrain3DBaseChunk";

private:
  Vector2i _position;

public:
  virtual void refill() = 0;
  virtual void set_enabled(bool enabled) = 0;
  void set_position(Vector2i p_position) { _position = p_position; };
  Vector2i get_position() { return _position; }
};

#endif
