// Copyright © 2023 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_CLASS_H
#define TERRAIN3D_CLASS_H

#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/editor_plugin.hpp>
#include <godot_cpp/classes/geometry_instance3d.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/static_body3d.hpp>
#include <godot_cpp/classes/sub_viewport.hpp>

#include "constants.h"
#include "terrain_3d_material.h"
#include "terrain_3d_storage.h"
#include "terrain_3d_texture_list.h"

using namespace godot;

class Terrain3D : public Node3D {
	GDCLASS(Terrain3D, Node3D);
	CLASS_NAME();

	// Terrain state
	String _version = "0.9.2-dev";
	bool _is_inside_world = false;
	bool _initialized = false;

	// Terrain settings
	int _mesh_size = 48;
	int _mesh_lods = 7;
	real_t _mesh_vertex_spacing = 1.0f;

	Ref<Terrain3DStorage> _storage;
	Ref<Terrain3DMaterial> _material;
	Ref<Terrain3DTextureList> _texture_list;

	// Editor components
	EditorPlugin *_plugin = nullptr;
	// Current editor or gameplay camera we are centering the terrain on.
	Camera3D *_camera = nullptr;
	// X,Z Position of the camera during the previous snapping. Set to max real_t value to force a snap update.
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
	uint32_t _render_layers = 1 | (1 << 31); // Bit 1 and 32 for the cursor
	GeometryInstance3D::ShadowCastingSetting _shadow_casting = GeometryInstance3D::SHADOW_CASTING_SETTING_ON;
	real_t _cull_margin = 0.0f;

	// Mouse cursor
	SubViewport *_mouse_vp = nullptr;
	Camera3D *_mouse_cam = nullptr;
	MeshInstance3D *_mouse_quad = nullptr;
	uint32_t _mouse_layer = 32;

	// Physics body and settings
	RID _static_body;
	StaticBody3D *_debug_static_body = nullptr;
	bool _collision_enabled = true;
	bool _show_debug_collision = false;
	uint32_t _collision_layer = 1;
	uint32_t _collision_mask = 1;
	real_t _collision_priority = 1.0f;

	void _initialize();
	void __ready();
	void __process(double delta);

	void _setup_mouse_picking();
	void _destroy_mouse_picking();
	void _grab_camera();

	void _clear(bool p_clear_meshes = true, bool p_clear_collision = true);
	void _build(int p_mesh_lods, int p_mesh_size);

	void _build_collision();
	void _update_collision();
	void _destroy_collision();

	void _update_instances();

	void _generate_triangles(PackedVector3Array &p_vertices, PackedVector2Array *p_uvs, int32_t p_lod, Terrain3DStorage::HeightFilter p_filter, bool require_nav, AABB const &p_global_aabb) const;
	void _generate_triangle_pair(PackedVector3Array &p_vertices, PackedVector2Array *p_uvs, int32_t p_lod, Terrain3DStorage::HeightFilter p_filter, bool require_nav, int32_t x, int32_t z) const;

public:
	static int debug_level;

	Terrain3D();
	~Terrain3D();

	// Terrain settings
	String get_version() const { return _version; }
	void set_debug_level(int p_level);
	int get_debug_level() const { return debug_level; }
	void set_mesh_lods(int p_count);
	int get_mesh_lods() const { return _mesh_lods; }
	void set_mesh_size(int p_size);
	int get_mesh_size() const { return _mesh_size; }
	void set_mesh_vertex_spacing(real_t p_spacing);
	real_t get_mesh_vertex_spacing() const { return _mesh_vertex_spacing; }

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
	void set_mouse_layer(uint32_t p_layer);
	uint32_t get_mouse_layer() const { return _mouse_layer; };
	void set_cast_shadows(GeometryInstance3D::ShadowCastingSetting p_shadow_casting);
	GeometryInstance3D::ShadowCastingSetting get_cast_shadows() const { return _shadow_casting; };
	void set_cull_margin(real_t p_margin);
	real_t get_cull_margin() const { return _cull_margin; };

	// Physics body settings
	void set_collision_enabled(bool p_enabled);
	bool get_collision_enabled() const { return _collision_enabled; }
	void set_show_debug_collision(bool p_enabled);
	bool get_show_debug_collision() const { return _show_debug_collision; }
	void set_collision_layer(uint32_t p_layers);
	uint32_t get_collision_layer() const { return _collision_layer; };
	void set_collision_mask(uint32_t p_mask);
	uint32_t get_collision_mask() const { return _collision_mask; };
	void set_collision_priority(real_t p_priority);
	real_t get_collision_priority() const { return _collision_priority; }

	// Terrain methods
	void snap(Vector3 p_cam_pos);
	void update_aabbs();
	Vector3 get_intersection(Vector3 p_src_pos, Vector3 p_direction);

	// Baking methods
	Ref<Mesh> bake_mesh(int p_lod, Terrain3DStorage::HeightFilter p_filter = Terrain3DStorage::HEIGHT_FILTER_NEAREST) const;
	PackedVector3Array generate_nav_mesh_source_geometry(AABB const &p_global_aabb, bool p_require_nav = true) const;

	PackedStringArray _get_configuration_warnings() const override;

protected:
	void _notification(int p_what);
	static void _bind_methods();
};

#endif // TERRAIN3D_CLASS_H
