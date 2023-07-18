// Copyright © 2023 Roope Palmroos, Cory Petkovsek, and Contributors. All rights reserved. See LICENSE.
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
#include <godot_cpp/classes/visual_instance3d.hpp>
#include <godot_cpp/classes/geometry_instance3d.hpp>
#include <godot_cpp/classes/v_box_container.hpp> // needed for get_editor_main_screen()
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/templates/vector.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include "geoclipmap.h"
#include "terrain_3d_storage.h"

using namespace godot;

class Terrain3D : public Node3D {
private:
	GDCLASS(Terrain3D, Node3D);

	bool _is_inside_world = false;

	// Terrain settings
	static int _debug_level;
	bool _valid = false;
	int _clipmap_size = 48;
	int _clipmap_levels = 7;

	Ref<Terrain3DStorage> _storage;

	// Editor components
	EditorPlugin *_plugin = nullptr;
	// Current editor or gameplay camera we are centering the terrain on.
	Camera3D *_camera = nullptr;
	// X,Z Position of the camera during the previous snapping. Set to max float value to force a snap update.
	Vector2 _camera_last_position = Vector2(FLT_MAX, FLT_MAX);

	// Meshes and Mesh instances
	Vector<RID> _meshes;
	struct Instances {
		RID cross;
		Vector<RID> tiles;
		Vector<RID> fillers;
		Vector<RID> trims;
		Vector<RID> seams;
	} _data;

	// Physics body and settings
	RID _static_body;
	StaticBody3D *_debug_static_body = nullptr;
	bool _collision_enabled = true;
	bool _show_debug_collision = false;
	uint32_t _collision_layer = 1;
	uint32_t _collision_mask = 1;
	real_t _collision_priority = 1.0;

	// Visual Instance
	uint32_t _visual_layers = 1;

	// Geometry Instance
	GeometryInstance3D::ShadowCastingSetting _shadow_casting_setting = GeometryInstance3D::SHADOW_CASTING_SETTING_ON;

	void __process(double delta);

	void _grab_camera();
	void _find_cameras(TypedArray<Node> from_nodes, Node *excluded_node, TypedArray<Camera3D> &cam_array);

	void _build_collision();
	void _update_collision();
	void _destroy_collision();

	void _update_instances();

public:
	Terrain3D();
	~Terrain3D();

	// Terrain settings
	void set_debug_level(int p_level);
	int get_debug_level() const { return _debug_level; }
	void set_clipmap_levels(int p_count);
	int get_clipmap_levels() const { return _clipmap_levels; }
	void set_clipmap_size(int p_size);
	int get_clipmap_size() const { return _clipmap_size; }

	void set_storage(const Ref<Terrain3DStorage> &p_storage);
	Ref<Terrain3DStorage> get_storage() const { return _storage; }

	// Editor components
	void set_plugin(EditorPlugin *p_plugin);
	EditorPlugin *get_plugin() const { return _plugin; }
	void set_camera(Camera3D *p_plugin);
	Camera3D *get_camera() const { return _camera; }

	// Physics body settings
	void set_collision_enabled(bool p_enabled);
	int get_collision_enabled() const { return _collision_enabled; }
	void set_show_debug_collision(bool p_enabled);
	int get_show_debug_collision() const { return _show_debug_collision; }
	void set_collision_layer(uint32_t p_layer) { _collision_layer = p_layer; }
	uint32_t get_collision_layer() const { return _collision_layer; };
	void set_collision_mask(uint32_t p_mask) { _collision_mask = p_mask; }
	uint32_t get_collision_mask() const { return _collision_mask; };
	void set_collision_priority(real_t p_priority) { _collision_priority = p_priority; }
	real_t get_collision_priority() const { return _collision_priority; }

	// Visual instance settings
	void set_layer_mask(uint32_t p_mask);
	uint32_t get_layer_mask() const { return _visual_layers; };

	// Geometry instance settings
	void set_cast_shadows_setting(GeometryInstance3D::ShadowCastingSetting p_shadow_casting_setting);
	GeometryInstance3D::ShadowCastingSetting get_cast_shadows_setting() const { return _shadow_casting_setting; };

	// Terrain methods
	void clear(bool p_clear_meshes = true, bool p_clear_collision = true);
	void build(int p_clipmap_levels, int p_clipmap_size);
	void snap(Vector3 p_cam_pos);
	void update_aabbs();
	Vector3 get_intersection(Vector3 p_position, Vector3 p_direction);

protected:
	void _notification(int p_what);
	static void _bind_methods();
};

#endif // TERRAIN3D_CLASS_H