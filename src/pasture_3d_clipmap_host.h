// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
// What Pasture3DMesher needs from whatever owns it.
// Spec: PASTURE3D_WATER_BODIES_SPEC.md §6.2

#ifndef PASTURE3D_CLIPMAP_HOST_CLASS_H
#define PASTURE3D_CLIPMAP_HOST_CLASS_H

#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

using namespace godot;

/**
 * The six things a clipmap mesher asks of its owner.
 *
 * Pasture3DMesher held a `Pasture3D *` and reached through it in exactly six
 * places. Five of them are Node3D-shaped questions that have nothing to do with
 * terrain; the sixth is a default height range that only the terrain can answer.
 * Pasture3DOcean can answer all six, so this is the entire coupling and it is small.
 *
 * The one that mattered was NOT any of the six. update_aabbs() opened with
 * IS_DATA_INIT, which early-returns unless `_terrain->get_data()` exists -- so an
 * ocean in a scene with no terrain would silently never update its cull volume,
 * which is water spec §4.5's bug arriving through a different door. That guard is
 * now is_clipmap_host_ready(), which asks whether the HOST is ready to draw and
 * says nothing about terrain data.
 */
class Pasture3DClipmapHost {
public:
	virtual ~Pasture3DClipmapHost() {}

	// Where the clipmap centres itself: the camera, or whatever the host follows.
	virtual Vector3 get_clipmap_target_position() const = 0;
	// In a tree, in a world, and holding whatever else the host needs before its
	// geometry means anything. Replaces both is_inside_world() and IS_DATA_INIT.
	virtual bool is_clipmap_host_ready() const = 0;
	virtual Ref<World3D> get_clipmap_world() const = 0;
	virtual bool is_clipmap_visible() const = 0;
	// Used only when update_aabbs() is called with the sentinel defaults, which is
	// the terrain's own path. The ocean always passes explicit values.
	virtual real_t get_default_cull_margin() const = 0;
	virtual Vector2 get_default_height_range() const = 0;
};

#endif // PASTURE3D_CLIPMAP_HOST_CLASS_H
