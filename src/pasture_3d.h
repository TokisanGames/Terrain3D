// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef PASTURE3D_CLASS_H
#define PASTURE3D_CLASS_H

#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/color_rect.hpp>
#include <godot_cpp/classes/geometry_instance3d.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/sub_viewport.hpp>
#include <godot_cpp/templates/vector.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include "constants.h"
#include "target_node_3d.h"
#include "pasture_3d_assets.h"
#include "pasture_3d_collision.h"
#include "pasture_3d_data.h"
#include "pasture_3d_editor.h"
#include "pasture_3d_instancer.h"
#include "pasture_3d_material.h"
#include "pasture_3d_clipmap_host.h"
#include "pasture_3d_mesher.h"

class Pasture3D : public Node3D, public Pasture3DClipmapHost {
	GDCLASS(Pasture3D, Node3D);
	CLASS_NAME();

public: // Constants
	enum DebugLevel {
		MESG = -2, // Always print except in release builds
		WARN = -1, // Always print except in release builds
		ERROR = 0, // Always print except in release builds
		INFO = 1, // Print every function call and important entries
		DEBUG = 2, // Print details within functions
		EXTREME = 3, // Continuous operations like snapping
	};

	enum RegionSize {
		SIZE_64 = 64,
		SIZE_128 = 128,
		SIZE_256 = 256,
		SIZE_512 = 512,
		SIZE_1024 = 1024,
		SIZE_2048 = 2048,
	};

	// Pasture3D: per-camera clipmaps use a reserved top range of render layers, one bit per player,
	// descending: camera i -> bit (TERRAIN_TOP_BIT - i). Default 19 => layers 20,19,18,17 for
	// cameras 0..3. Keep gameplay (karts, props) on layers 1-16 so every camera sees it.
	static const int TERRAIN_TOP_BIT = 19;

private:
	String _version = "1.1.0-dev";
	String _data_directory;
	bool _is_inside_world = false;
	bool _initialized = false;
	uint8_t _warnings = 0u;

	// Object references
	Pasture3DData *_data = nullptr;
	Ref<Pasture3DAssets> _assets;
	Pasture3DCollision *_collision = nullptr;
	Pasture3DInstancer *_instancer = nullptr;
	Pasture3DEditor *_editor = nullptr;
	Object *_editor_plugin = nullptr;

	// Regions
	RegionSize _region_size = SIZE_256;
	bool _save_16_bit = false;
	real_t _label_distance = 0.f;
	int _label_size = 48;

	// Tracked Targets
	TargetNode3D _clipmap_target;
	TargetNode3D _collision_target;
	TargetNode3D _light_target;
	Vector3 _light_dir_sent = V3_MAX; // Sentinel: never equal to a real direction, so the first
	Color _light_color_sent = Color(-1.f, -1.f, -1.f); // frame always pushes.
	TargetNode3D _camera; // Fallback target for clipmap and collision
	// Pasture3D: explicit per-camera list for local split-screen (>=2 cameras). When set, the
	// mesher renders one clipmap per camera; empty/single collapses to the single-view path above.
	Vector<uint64_t> _cameras; // Camera3D ObjectIDs

	// Terrain Mesh
	Pasture3DMesher *_terrain_mesher = nullptr;
	Ref<Pasture3DMaterial> _material;
	int _mesh_lods = 7;
	int _tessellation_level = 0;
	int _mesh_size = 48;
	real_t _vertex_spacing = 1.0f;
	real_t _cull_margin = 0.0f;
	RenderingServer::ShadowCastingSetting _cast_shadows = RenderingServer::SHADOW_CASTING_SETTING_ON;
	GeometryInstance3D::GIMode _gi_mode = GeometryInstance3D::GI_MODE_STATIC;
	uint32_t _render_layers = 1u | (1u << 31u); // Bit 1 and 32 for the cursor

	// Displacement Buffer
	SubViewport *_d_buffer_vp = nullptr;
	ColorRect *_d_buffer_rect = nullptr;
	Vector2 _last_buffer_position = V2_MAX;

	// Ocean Mesh
	// Ocean state left this node in Phase 2 of the water-bodies work; it lives on
	// Pasture3DOcean now (WATER_BODIES_SPEC §6). What remains is the holding pen for
	// ocean_* values found in scenes saved before that, so opening and re-saving an
	// old scene cannot silently erase somebody's ocean before they are told.
	Dictionary _legacy_ocean;

	// Rendering
	bool _free_editor_textures = true;
	// Mouse cursor
	SubViewport *_mouse_vp = nullptr;
	Camera3D *_mouse_cam = nullptr;
	MeshInstance3D *_mouse_quad = nullptr;
	uint32_t _mouse_layer = 32u;
	// Parent containers for child nodes
	Node3D *_label_parent;

	void _initialize();
	void __physics_process(const double p_delta);
	void _grab_camera();

	void _destroy_collision(const bool p_final = false);

	void _setup_terrain_mesher();
	void _apply_cameras_to_mesher();
	void _update_mesher_aabbs() { _terrain_mesher ? _terrain_mesher->update_aabbs() : void(); }
	void _destroy_terrain_mesher(const bool p_final = false);

	void _upload_wave_table();

	void _setup_displacement_buffer();
	void _update_displacement_buffer();
	void _destroy_displacement_buffer();

	void _build_containers();
	void _destroy_containers();
	void _destroy_labels();

	void _setup_mouse_picking();
	void _destroy_mouse_picking();
	void _destroy_instancer();

	void _generate_triangles(PackedVector3Array &p_vertices, PackedVector2Array *p_uvs, const int32_t p_lod,
			const Pasture3DData::HeightFilter p_filter, const bool require_nav, const AABB &p_global_aabb) const;
	void _generate_triangle_pair(PackedVector3Array &p_vertices, PackedVector2Array *p_uvs, const int32_t p_lod,
			const Pasture3DData::HeightFilter p_filter, const bool require_nav, const int32_t x, const int32_t z) const;

public:
	static DebugLevel debug_level; // Initialized in pasture_3d.cpp

	Pasture3D();
	~Pasture3D() {}
	bool is_inside_world() const { return _is_inside_world; }

	// Terrain
	String get_version() const { return _version; }
	void set_debug_level(const DebugLevel p_level);
	DebugLevel get_debug_level() const { return debug_level; }
	void set_data_directory(String p_dir);
	String get_data_directory() const { return _data ? _data_directory : ""; }

	// Object references
	Pasture3DData *get_data() const { return _data; }
	void set_assets(const Ref<Pasture3DAssets> &p_assets);
	Ref<Pasture3DAssets> get_assets() const { return _assets; }
	Pasture3DCollision *get_collision() const { return _collision; }
	Pasture3DInstancer *get_instancer() const { return _instancer; }
	void set_editor(Pasture3DEditor *p_editor);
	Pasture3DEditor *get_editor() const { return _editor; }
	void set_plugin(Object *p_plugin);
	Object *get_plugin() const { return _editor_plugin; }

	// Regions
	void set_region_size(const RegionSize p_size);
	RegionSize get_region_size() const { return _region_size; }
	void change_region_size(const RegionSize p_size) { _data ? _data->change_region_size(p_size) : void(); }
	void set_save_16_bit(const bool p_enabled);
	bool get_save_16_bit() const { return _save_16_bit; }
	void set_label_distance(const real_t p_distance);
	real_t get_label_distance() const { return _label_distance; }
	void set_label_size(const int p_size);
	int get_label_size() const { return _label_size; }
	void update_region_labels();

	// Target Tracking
	void set_camera(Camera3D *p_camera);
	Camera3D *get_camera() const { return cast_to<Camera3D>(_camera.ptr()); }
	// Pasture3D: local split-screen. Renders one clipmap per camera (each on its own render layer,
	// snapped to its own camera), all sharing the single Pasture3DData. set_cameras([one]) behaves
	// exactly like set_camera(one); >=2 cameras enables true per-camera LOD. Collision is unchanged.
	void set_cameras(const TypedArray<Camera3D> &p_cameras);
	TypedArray<Camera3D> get_cameras() const;
	void set_clipmap_target(Node3D *p_node);
	Node3D *get_clipmap_target() const { return _clipmap_target.ptr(); }
	virtual Vector3 get_clipmap_target_position() const override;

	// --- Pasture3DClipmapHost (WATER_BODIES_SPEC §6.2) ----------------------
	// Was a direct Pasture3D* dependency inside Pasture3DMesher. Narrowed to this
	// so Pasture3DOcean can own a clipmap too.
	virtual bool is_clipmap_host_ready() const override { return _is_inside_world; }
	virtual Ref<World3D> get_clipmap_world() const override { return get_world_3d(); }
	virtual bool is_clipmap_visible() const override { return is_visible_in_tree(); }
	virtual real_t get_default_cull_margin() const override { return _cull_margin; }
	virtual Vector2 get_default_height_range() const override;

	// --- Legacy ocean migration (§6.4) --------------------------------------
	// Builds a Pasture3DPoolManager + Pasture3DOcean from ocean_* properties captured out of a
	// scene saved before Phase 2, then clears them. Returns the new Pasture3DOcean, or
	// null if there was nothing to migrate.
	Node *migrate_ocean();
	void discard_legacy_ocean();
	bool has_legacy_ocean() const { return !_legacy_ocean.is_empty(); }
	Dictionary get_legacy_ocean() const { return _legacy_ocean; }
	// Inspector buttons for the two above. Godot's tool-button hint wants a property
	// whose getter returns a Callable; these are those getters, and they are the
	// GDExtension equivalent of GDScript's @export_tool_button.
	Callable get_migrate_ocean_button() const;
	Callable get_discard_legacy_ocean_button() const;

	void set_collision_target(Node3D *p_node);
	Node3D *get_collision_target() const { return _collision_target.ptr(); }
	Vector3 get_collision_target_position() const;
	void set_light_target(Node3D *p_node);
	Node3D *get_light_target() const { return _light_target.ptr(); }
	void snap();

	// Collision Aliases
	void set_collision_mode(const CollisionMode p_mode) { _collision ? _collision->set_mode(p_mode) : void(); }
	CollisionMode get_collision_mode() const { return _collision ? _collision->get_mode() : CollisionMode::DYNAMIC_GAME; }
	void set_collision_shape_size(const uint16_t p_size) { _collision ? _collision->set_shape_size(p_size) : void(); }
	uint16_t get_collision_shape_size() const { return _collision ? _collision->get_shape_size() : 16; }
	void set_collision_radius(const uint16_t p_radius) { _collision ? _collision->set_radius(p_radius) : void(); }
	uint16_t get_collision_radius() const { return _collision ? _collision->get_radius() : 64; }
	void set_collision_layer(const uint32_t p_layers) { _collision ? _collision->set_layer(p_layers) : void(); }
	uint32_t get_collision_layer() const { return _collision ? _collision->get_layer() : 1; }
	void set_collision_mask(const uint32_t p_mask) { _collision ? _collision->set_mask(p_mask) : void(); }
	uint32_t get_collision_mask() const { return _collision ? _collision->get_mask() : 1; }
	void set_collision_priority(const real_t p_priority) { _collision ? _collision->set_priority(p_priority) : void(); }
	real_t get_collision_priority() const { return _collision ? _collision->get_priority() : 1.f; }
	void set_physics_material(const Ref<PhysicsMaterial> &p_mat) { _collision ? _collision->set_physics_material(p_mat) : void(); }
	Ref<PhysicsMaterial> get_physics_material() const { return _collision ? _collision->get_physics_material() : Ref<PhysicsMaterial>(); }

	// Terrain Mesh
	Pasture3DMesher *get_mesher() const { return _terrain_mesher; }
	void set_material(const Ref<Pasture3DMaterial> &p_material);
	Ref<Pasture3DMaterial> get_material() const { return _material; }
	void set_mesh_lods(const int p_count);
	int get_mesh_lods() const { return _mesh_lods; }
	void set_tessellation_level(const int p_level);
	int get_tessellation_level() const { return _tessellation_level; }
	void set_mesh_size(const int p_size);
	int get_mesh_size() const { return _mesh_size; }
	void set_vertex_spacing(const real_t p_spacing);
	real_t get_vertex_spacing() const { return _vertex_spacing; }
	void set_cull_margin(const real_t p_margin);
	real_t get_cull_margin() const { return _cull_margin; }
	void set_cast_shadows(const RenderingServer::ShadowCastingSetting p_cast_shadows);
	RenderingServer::ShadowCastingSetting get_cast_shadows() const { return _cast_shadows; }
	void set_gi_mode(const GeometryInstance3D::GIMode p_gi_mode);
	GeometryInstance3D::GIMode get_gi_mode() const { return _gi_mode; }
	void set_render_layers(const uint32_t p_layers);
	uint32_t get_render_layers() const { return _render_layers; }

	// Material Displacement Aliases
	void set_displacement_scale(const real_t p_displacement_scale) { _material.is_valid() ? _material->set_displacement_scale(p_displacement_scale) : void(); }
	real_t get_displacement_scale() const { return _material.is_valid() ? _material->get_displacement_scale() : 1.f; }
	void set_displacement_sharpness(const real_t p_displacement_sharpness) { _material.is_valid() ? _material->set_displacement_sharpness(p_displacement_sharpness) : void(); }
	real_t get_displacement_sharpness() const { return _material.is_valid() ? _material->get_displacement_sharpness() : 0.25f; }
	void set_buffer_shader_override_enabled(const bool p_enabled) { _material.is_valid() ? _material->set_buffer_shader_override_enabled(p_enabled) : void(); }
	bool is_buffer_shader_override_enabled() const { return _material.is_valid() ? _material->is_buffer_shader_override_enabled() : false; }
	void set_buffer_shader_override(const Ref<Shader> &p_shader) { return _material.is_valid() ? _material->set_buffer_shader_override(p_shader) : void(); }
	Ref<Shader> get_buffer_shader_override() const { return _material.is_valid() ? _material->get_buffer_shader_override() : Ref<Shader>(); }

	// Ocean Mesh

	// Ocean waves. These are art knobs; C++ turns them into the wave table the
	// shader and the CPU height query both read (spec §4.2).


	// The wave function itself: where the surface point for a DOMAIN parameter
	// lands, which is what the vertex shader computes for the same input and
	// therefore what the Phase 4 gate compares against. No inverse solve, so this
	// is also the cheap call for anything that does not need a specific XZ --
	// spray, wakes, a debug gizmo drawing the surface.

	// Rendering
	void set_mouse_layer(const uint32_t p_layer);
	uint32_t get_mouse_layer() const { return _mouse_layer; }
	void set_free_editor_textures(const bool p_free_textures) { _free_editor_textures = p_free_textures; }
	bool get_free_editor_textures() const { return _free_editor_textures; }
	void set_instancer_mode(const InstancerMode p_mode) { _instancer ? _instancer->set_mode(p_mode) : void(); }
	InstancerMode get_instancer_mode() const { return _instancer ? _instancer->get_mode() : InstancerMode::NORMAL; }

	// Utility
	Vector3 get_intersection(const Vector3 &p_src_pos, const Vector3 &p_direction, const bool p_gpu_mode = false);
	Dictionary get_raycast_result(const Vector3 &p_src_pos, const Vector3 &p_direction, const uint32_t p_col_mask = 0xFFFFFFFF, const bool p_exclude_self = false) const;
	Ref<Mesh> bake_mesh(const int p_lod, const Pasture3DData::HeightFilter p_filter = Pasture3DData::HEIGHT_FILTER_NEAREST) const;
	PackedVector3Array generate_nav_mesh_source_geometry(const AABB &p_global_aabb, const bool p_require_nav = true) const;

	// Warnings
	void set_warning(const uint8_t p_warning, const bool p_enabled);
	uint8_t get_warnings() const { return _warnings; }
	PackedStringArray _get_configuration_warnings() const override;

	// Overlay Aliases
	void set_show_region_grid(const bool p_enabled) { _material.is_valid() ? _material->set_show_region_grid(p_enabled) : void(); }
	bool get_show_region_grid() const { return _material.is_valid() ? _material->get_show_region_grid() : false; }
	void set_show_instancer_grid(const bool p_enabled) { _material.is_valid() ? _material->set_show_instancer_grid(p_enabled) : void(); }
	bool get_show_instancer_grid() const { return _material.is_valid() ? _material->get_show_instancer_grid() : false; }
	void set_show_vertex_grid(const bool p_enabled) { _material.is_valid() ? _material->set_show_vertex_grid(p_enabled) : void(); }
	bool get_show_vertex_grid() const { return _material.is_valid() ? _material->get_show_vertex_grid() : false; }
	void set_show_contours(const bool p_enabled) { _material.is_valid() ? _material->set_show_contours(p_enabled) : void(); }
	bool get_show_contours() const { return _material.is_valid() ? _material->get_show_contours() : false; }
	void set_show_navigation(const bool p_enabled) { _material.is_valid() ? _material->set_show_navigation(p_enabled) : void(); }
	bool get_show_navigation() const { return _material.is_valid() ? _material->get_show_navigation() : false; }

	// Debug View Aliases
	void set_show_checkered(const bool p_enabled) { _material.is_valid() ? _material->set_show_checkered(p_enabled) : void(); }
	bool get_show_checkered() const { return _material.is_valid() ? _material->get_show_checkered() : false; }
	void set_show_grey(const bool p_enabled) { _material.is_valid() ? _material->set_show_grey(p_enabled) : void(); }
	bool get_show_grey() const { return _material.is_valid() ? _material->get_show_grey() : false; }
	void set_show_heightmap(const bool p_enabled) { _material.is_valid() ? _material->set_show_heightmap(p_enabled) : void(); }
	bool get_show_heightmap() const { return _material.is_valid() ? _material->get_show_heightmap() : false; }
	void set_show_jaggedness(const bool p_enabled) { _material.is_valid() ? _material->set_show_jaggedness(p_enabled) : void(); }
	bool get_show_jaggedness() const { return _material.is_valid() ? _material->get_show_jaggedness() : false; }
	void set_show_autoshader(const bool p_enabled) { _material.is_valid() ? _material->set_show_autoshader(p_enabled) : void(); }
	bool get_show_autoshader() const { return _material.is_valid() ? _material->get_show_autoshader() : false; }
	void set_show_control_texture(const bool p_enabled) { _material.is_valid() ? _material->set_show_control_texture(p_enabled) : void(); }
	bool get_show_control_texture() const { return _material.is_valid() ? _material->get_show_control_texture() : false; }
	void set_show_control_blend(const bool p_enabled) { _material.is_valid() ? _material->set_show_control_blend(p_enabled) : void(); }
	bool get_show_control_blend() const { return _material.is_valid() ? _material->get_show_control_blend() : false; }
	void set_show_control_angle(const bool p_enabled) { _material.is_valid() ? _material->set_show_control_angle(p_enabled) : void(); }
	bool get_show_control_angle() const { return _material.is_valid() ? _material->get_show_control_angle() : false; }
	void set_show_control_scale(const bool p_enabled) { _material.is_valid() ? _material->set_show_control_scale(p_enabled) : void(); }
	bool get_show_control_scale() const { return _material.is_valid() ? _material->get_show_control_scale() : false; }
	void set_show_colormap(const bool p_enabled) { _material.is_valid() ? _material->set_show_colormap(p_enabled) : void(); }
	bool get_show_colormap() const { return _material.is_valid() ? _material->get_show_colormap() : false; }
	void set_show_roughmap(const bool p_enabled) { _material.is_valid() ? _material->set_show_roughmap(p_enabled) : void(); }
	bool get_show_roughmap() const { return _material.is_valid() ? _material->get_show_roughmap() : false; }
	void set_show_displacement_buffer(const bool p_enabled) { _material.is_valid() ? _material->set_show_displacement_buffer(p_enabled) : void(); }
	bool get_show_displacement_buffer() const { return _material.is_valid() ? _material->get_show_displacement_buffer() : false; }

	// PBR View Aliases
	void set_show_texture_albedo(const bool p_enabled) { _material.is_valid() ? _material->set_show_texture_albedo(p_enabled) : void(); }
	bool get_show_texture_albedo() const { return _material.is_valid() ? _material->get_show_texture_albedo() : false; }
	void set_show_texture_height(const bool p_enabled) { _material.is_valid() ? _material->set_show_texture_height(p_enabled) : void(); }
	bool get_show_texture_height() const { return _material.is_valid() ? _material->get_show_texture_height() : false; }
	void set_show_texture_normal(const bool p_enabled) { _material.is_valid() ? _material->set_show_texture_normal(p_enabled) : void(); }
	bool get_show_texture_normal() const { return _material.is_valid() ? _material->get_show_texture_normal() : false; }
	void set_show_texture_rough(const bool p_enabled) { _material.is_valid() ? _material->set_show_texture_rough(p_enabled) : void(); }
	bool get_show_texture_rough() const { return _material.is_valid() ? _material->get_show_texture_rough() : false; }
	void set_show_texture_ao(const bool p_enabled) { _material.is_valid() ? _material->set_show_texture_ao(p_enabled) : void(); }
	bool get_show_texture_ao() const { return _material.is_valid() ? _material->get_show_texture_ao() : false; }

protected:
	void _notification(const int p_what);
	void _validate_property(PropertyInfo &p_property) const;
	// Captures ocean_* from scenes saved before Phase 2 instead of discarding them.
	bool _set(const StringName &p_name, const Variant &p_value);
	bool _get(const StringName &p_name, Variant &r_ret) const;
	static void _bind_methods();
};

VARIANT_ENUM_CAST(Pasture3D::RegionSize);
VARIANT_ENUM_CAST(Pasture3D::DebugLevel);

constexpr Pasture3D::DebugLevel MESG = Pasture3D::DebugLevel::MESG;
constexpr Pasture3D::DebugLevel WARN = Pasture3D::DebugLevel::WARN;
constexpr Pasture3D::DebugLevel ERROR = Pasture3D::DebugLevel::ERROR;
constexpr Pasture3D::DebugLevel INFO = Pasture3D::DebugLevel::INFO;
constexpr Pasture3D::DebugLevel DEBUG = Pasture3D::DebugLevel::DEBUG;
constexpr Pasture3D::DebugLevel EXTREME = Pasture3D::DebugLevel::EXTREME;

#endif // PASTURE3D_CLASS_H
