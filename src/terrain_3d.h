//Copyright © 2023 Roope Palmroos, Cory Petkovsek, and Contributors. All rights reserved. See LICENSE.
#ifndef TERRAIN3D_CLASS_H
#define TERRAIN3D_CLASS_H

#ifdef WIN32
#include <windows.h>
#endif

#ifndef FLT_MAX
#define FLT_MAX __FLT_MAX__
#endif

#ifndef PI
#define PI 3.14159265f
#endif

#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/editor_plugin.hpp>
#include <godot_cpp/classes/editor_script.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/physics_server3d.hpp>
#include <godot_cpp/classes/resource_saver.hpp>
#include <godot_cpp/classes/static_body3d.hpp>
#include <godot_cpp/classes/v_box_container.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/templates/vector.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include "geoclipmap.h"
#include "terrain_3d_storage.h"

using namespace godot;

class Terrain3D : public Node3D {
	GDCLASS(Terrain3D, Node3D);

	static int debug_level;
	bool valid = false;
	int clipmap_size = 48;
	int clipmap_levels = 7;

	EditorPlugin *plugin = nullptr;
	Ref<Terrain3DStorage> storage;

	// Meshes and Mesh instances
	Vector<RID> meshes;
	struct Instances {
		RID cross;
		Vector<RID> tiles;
		Vector<RID> fillers;
		Vector<RID> trims;
		Vector<RID> seams;
	} data;

	// Physics body and settings
	bool _collision_enabled = true;
	bool _show_debug_collision = false;
	RID static_body;
	StaticBody3D *_debug_static_body = nullptr;
	uint32_t collision_layer = 1;
	uint32_t collision_mask = 1;
	real_t collision_priority = 1.0;

	// Current editor or gameplay camera we are centering the terrain on.
	Camera3D *camera = nullptr;
	// X,Z Position of the camera during the previous snapping. Set to max float value to force a snap update.
	Vector2 camera_last_position = Vector2(FLT_MAX, FLT_MAX);

protected:
	static void _bind_methods();
	void _notification(int p_what);
	void process(double delta);
	void _update_visibility();
	void _update_world(RID p_space, RID p_scenario);
	void _build_collision();
	void _update_collision();
	void _destroy_collision();

private:
	void _grab_camera();
	void _find_cameras(TypedArray<Node> from_nodes, Node *excluded_node, TypedArray<Camera3D> &cam_array);

public:
	void set_camera(Camera3D *p_plugin);
	Camera3D *get_camera() const { return camera; }

	void set_plugin(EditorPlugin *p_plugin);
	EditorPlugin *get_plugin() const { return plugin; }

	void set_debug_level(int p_level);
	int get_debug_level() const { return debug_level; }
	void set_collision_enabled(bool p_enabled);
	int get_collision_enabled() const { return _collision_enabled; }
	void set_show_debug_collision(bool p_enabled);
	int get_show_debug_collision() const { return _show_debug_collision; }

	void set_collision_layer(uint32_t p_layer);
	uint32_t get_collision_layer() const { return collision_layer; };
	void set_collision_mask(uint32_t p_mask);
	uint32_t get_collision_mask() const { return collision_mask; };
	void set_collision_priority(real_t p_priority);
	real_t get_collision_priority() const { return collision_priority; }

	void set_clipmap_levels(int p_count);
	int get_clipmap_levels() const { return clipmap_levels; }

	void set_clipmap_size(int p_size);
	int get_clipmap_size() const { return clipmap_size; }

	void set_storage(const Ref<Terrain3DStorage> &p_storage);
	Ref<Terrain3DStorage> get_storage() const { return storage; }

	void clear(bool p_clear_meshes = true, bool p_clear_collision = true);
	void build(int p_clipmap_levels, int p_clipmap_size);
	void snap(Vector3 p_cam_pos);
	void update_aabbs();

	Vector3 get_intersection(Vector3 p_position, Vector3 p_direction);

	Terrain3D();
	~Terrain3D();
};

#endif // TERRAIN3D_CLASS_H