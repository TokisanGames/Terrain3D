//© Copyright 2014-2022, Juan Linietsky, Ariel Manzur and the Godot community (CC-BY 3.0)
#ifndef TERRAIN3D_CLASS_H
#define TERRAIN3D_CLASS_H

#ifdef WIN32
#include <windows.h>
#endif

#ifndef FLT_MAX
#define FLT_MAX __FLT_MAX__
#endif

#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/editor_script.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/physics_server3d.hpp>
#include <godot_cpp/classes/v_box_container.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/templates/vector.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include "geoclipmap.h"
#include "terrain_storage.h"

using namespace godot;

class Terrain3D : public Node3D {
	GDCLASS(Terrain3D, Node3D);

	static int debug_level;
	bool valid = false;
	int clipmap_size = 48;
	int clipmap_levels = 7;

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
	RID static_body;
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
	void _update_visibility();
	void _update_world(RID p_space, RID p_scenario);

private:
	void get_camera();
	void find_cameras(TypedArray<Node> from_nodes, Node *excluded_node, TypedArray<Camera3D> &cam_array);

public:
	void set_debug_level(int p_level);
	int get_debug_level() const;

	void set_clipmap_levels(int p_count);
	int get_clipmap_levels() const;

	void set_clipmap_size(int p_size);
	int get_clipmap_size() const;

	void set_storage(const Ref<Terrain3DStorage> &p_storage);
	Ref<Terrain3DStorage> get_storage() const;

	void clear(bool p_clear_meshes = true, bool p_clear_collision = true);
	void build(int p_clipmap_levels, int p_clipmap_size);
	void snap(Vector3 p_cam_pos);

	void _process(double delta);

	Terrain3D();
	~Terrain3D();
};

#endif // TERRAIN3D_CLASS_H