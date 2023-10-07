// Copyright © 2023 Roope Palmroos, Cory Petkovsek, and Contributors. All rights reserved. See LICENSE.
#ifndef TERRAIN3D_CLASS_H
#define TERRAIN3D_CLASS_H

#ifndef __FLT_MAX__
#define __FLT_MAX__ FLT_MAX
#endif

#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/editor_plugin.hpp>
#include <godot_cpp/classes/geometry_instance3d.hpp>
#include <godot_cpp/classes/static_body3d.hpp>

#include "terrain_3d_material.h"
#include "terrain_3d_storage.h"
#include "terrain_3d_texture_list.h"

using namespace godot;

class Terrain3D : public Node3D {
private:
	GDCLASS(Terrain3D, Node3D);
	static inline const char *__class__ = "Terrain3D";

	// Terrain state
	bool _is_inside_world = false;
	bool _initialized = false;

	// Terrain settings
	static int _debug_level;
	int _clipmap_size = 48;
	int _clipmap_levels = 7;

	Ref<Terrain3DStorage> _storage;
	Ref<Terrain3DMaterial> _material;
	Ref<Terrain3DTextureList> _texture_list;

	// Editor components
	EditorPlugin *_plugin = nullptr;
	// Current editor or gameplay camera we are centering the terrain on.
	Camera3D *_camera = nullptr;
	// X,Z Position of the camera during the previous snapping. Set to max float value to force a snap update.
	Vector2 _camera_last_position = Vector2(__FLT_MAX__, __FLT_MAX__);

	// Meshes and Mesh instances
	Vector<RID> _meshes;
	struct Instances {
		RID cross;
		Vector<RID> tiles;
		Vector<RID> fillers;
		Vector<RID> trims;
		Vector<RID> seams;
	} _data;

	// Renderer settings
	uint32_t _render_layers = 1;
	GeometryInstance3D::ShadowCastingSetting _shadow_casting = GeometryInstance3D::SHADOW_CASTING_SETTING_ON;
	float _cull_margin = 0.0;

	// Physics body and settings
	RID _static_body;
	StaticBody3D *_debug_static_body = nullptr;
	bool _collision_enabled = true;
	bool _show_debug_collision = false;
	uint32_t _collision_layer = 1;
	uint32_t _collision_mask = 1;
	real_t _collision_priority = 1.0;

	void _initialize();
	void __ready();
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
	void set_material(const Ref<Terrain3DMaterial> &p_material);
	Ref<Terrain3DMaterial> get_material() const { return _material; }
	void set_texture_list(const Ref<Terrain3DTextureList> &p_texture_list);
	Ref<Terrain3DTextureList> get_texture_list() const { return _texture_list; }

	// Editor components
	void set_plugin(EditorPlugin *p_plugin);
	EditorPlugin *get_plugin() const { return _plugin; }
	void set_camera(Camera3D *p_plugin);
	Camera3D *get_camera() const { return _camera; }

	// Renderer settings
	void set_render_layers(uint32_t p_layers);
	uint32_t get_render_layers() const { return _render_layers; };
	void set_cast_shadows(GeometryInstance3D::ShadowCastingSetting p_shadow_casting);
	GeometryInstance3D::ShadowCastingSetting get_cast_shadows() const { return _shadow_casting; };
	void set_cull_margin(float p_margin);
	float get_cull_margin() const { return _cull_margin; };

	// Physics body settings
	void set_collision_enabled(bool p_enabled);
	bool get_collision_enabled() const { return _collision_enabled; }
	void set_show_debug_collision(bool p_enabled);
	bool get_show_debug_collision() const { return _show_debug_collision; }
	void set_collision_layer(uint32_t p_layers) { _collision_layer = p_layers; }
	uint32_t get_collision_layer() const { return _collision_layer; };
	void set_collision_mask(uint32_t p_mask) { _collision_mask = p_mask; }
	uint32_t get_collision_mask() const { return _collision_mask; };
	void set_collision_priority(real_t p_priority) { _collision_priority = p_priority; }
	real_t get_collision_priority() const { return _collision_priority; }

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