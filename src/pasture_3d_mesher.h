// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef PASTURE3D_MESHER_CLASS_H
#define PASTURE3D_MESHER_CLASS_H

#include <godot_cpp/templates/vector.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/rid.hpp>

#include "constants.h"
#include "pasture_3d_clipmap_host.h"

class Pasture3DMesher {
	CLASS_NAME_STATIC("Pasture3DMesher");

public: // Constants
	enum MeshType {
		TILE,
		EDGE_A,
		EDGE_B,
		FILL_A,
		FILL_B,
		STANDARD_TRIM_A,
		STANDARD_TRIM_B,
		STANDARD_TILE,
		STANDARD_EDGE_A,
		STANDARD_EDGE_B,
	};

	// Pasture3D: one clipmap instance-set per camera (local split-screen). Each view shares the
	// terrain's mesh resources (_mesh_rids) and material, but snaps to its own camera and renders
	// on its own layer, so a single Pasture3DData serves N viewers without duplicating VRAM.
	struct ClipmapView {
		Array clipmap_rids; // LODs -> MeshTypes -> Instances (this view only)
		Vector<RID> instance_rids; // Flat list of all instances above (fast per-frame iteration)
		Vector2 last_target_position = V2_MAX; // Snap tracking (xz)
		Vector3 last_shader_target_pos = V3_MAX; // _target_pos tracking (avoid redundant updates)
		uint32_t render_layers = 1u; // VisualInstance layer mask for this view
		uint64_t camera_id = 0; // ObjectID of camera to follow; 0 = terrain's default clipmap target
		bool cast_shadows = true; // Only the first view casts, to avoid double-shadowing (guide §4)
	};

private:
	// The owner. Was a Pasture3D *; narrowed to the six-method interface in Phase 2
	// of the water-bodies work so Ocean3D can own one too (WATER_BODIES_SPEC §6.2).
	Pasture3DClipmapHost *_host = nullptr;
	RID _scenario = RID();

	// Shared, view-independent mesh resources
	Array _mesh_rids;
	// Per-camera clipmap instance-sets
	Vector<ClipmapView> _views;
	// Terrain mesher writes _target_pos per-instance (each view geomorphs to its own snap center).
	// Ocean mesher leaves it false and writes _target_pos on the shared material (single view).
	bool _uses_instance_target_pos = false;

	// Mesh offset data
	// LOD0 only
	PackedVector3Array _trim_a_pos;
	PackedVector3Array _trim_b_pos;
	PackedVector3Array _tile_pos_lod_0;
	// LOD1 +
	PackedVector3Array _fill_a_pos;
	PackedVector3Array _fill_b_pos;
	PackedVector3Array _tile_pos;
	// All LOD Levels
	real_t _offset_a = 0.f;
	real_t _offset_b = 0.f;
	real_t _offset_c = 0.f;
	PackedVector3Array _edge_pos;

	RID _material;
	int _tessellation_level = 0;
	int _lods = 0;
	int _mesh_size = 0;
	real_t _vertex_spacing = 1.f;
	uint32_t _render_layers = 1u; // Default single-view layer mask
	// Owned here rather than read back off _terrain (spec §4.4). The ocean has its
	// own cast_shadows / gi_mode properties, bound and shown in the inspector, and
	// update() used to ignore them and apply the terrain's -- so the ocean silently
	// inherited ON/STATIC over its own OFF/DISABLED defaults. Benign only for as
	// long as the material stays transparent, which the shader header invites users
	// to change.
	RenderingServer::ShadowCastingSetting _cast_shadows = RenderingServer::SHADOW_CASTING_SETTING_ON;
	GeometryInstance3D::GIMode _gi_mode = GeometryInstance3D::GI_MODE_STATIC;

	void _generate_mesh_types();
	RID _generate_mesh(const Vector2i &p_size, const bool p_standard_grid = false);
	RID _instantiate_mesh(const PackedVector3Array &p_vertices, const PackedInt32Array &p_indices, const AABB &p_aabb);
	void _generate_view_instances(ClipmapView &p_view);
	void _generate_offset_data();

	Vector3 _resolve_view_target(const ClipmapView &p_view) const;
	void _snap_view(ClipmapView &p_view);

	void _clear_views();
	void _clear_mesh_types();

public:
	Pasture3DMesher() {}
	~Pasture3DMesher() { destroy(); }

	void initialize(Pasture3DClipmapHost *p_host, const int p_mesh_size, const int p_lods, const int p_tessellation_level,
			const real_t p_vertex_spacing, const RID &p_material, const uint32_t p_render_layers,
			const bool p_uses_instance_target_pos = false,
			const RenderingServer::ShadowCastingSetting p_cast_shadows = RenderingServer::SHADOW_CASTING_SETTING_ON,
			const GeometryInstance3D::GIMode p_gi_mode = GeometryInstance3D::GI_MODE_STATIC);
	void destroy();

	// Reconfigure the clipmap views. Empty input => one default view following the terrain's
	// clipmap target (single-view behavior). One entry per camera otherwise.
	void set_views(const Vector<uint64_t> &p_camera_ids, const Vector<uint32_t> &p_render_layers);
	int get_view_count() const { return _views.size(); }

	void snap();
	void reset_target_position();
	// Sets an `instance uniform` on every instance in every view. The ocean needs it
	// for _water_domain_origin, which became per-instance in Phase 1 of the water
	// bodies work so that a shared material can serve bodies in different places
	// (WATER_BODIES_SPEC §5.4). material_set_param() does not reach an instance
	// uniform, so this is the only route.
	void set_instance_shader_param(const StringName &p_name, const Variant &p_value);
	void update();
	void update_aabbs(const real_t p_cull_margin = -1.f, const Vector2 &p_height_range = V2_MAX);

	void set_material(const RID &p_material) { _material = p_material; }
	RID get_material() const { return _material; }
	void set_lods(const int p_lods) { _lods = p_lods; }
	int get_lods() const { return _lods; }
	void set_tessellation_level(const int p_level) { _tessellation_level = p_level; }
	int get_tessellation_level() const { return _tessellation_level; }
	void set_mesh_size(const int p_size) { _mesh_size = p_size; }
	int get_mesh_size() const { return _mesh_size; }
	void set_vertex_spacing(const real_t p_spacing) { _vertex_spacing = p_spacing; }
	real_t get_vertex_spacing() const { return _vertex_spacing; }
	void set_render_layers(const uint32_t p_layers);
	uint32_t get_render_layers() const { return _render_layers; }
	// Callers apply these with update(); they are read there, not on assignment,
	// because update() reapplies every instance property in one pass anyway.
	void set_cast_shadows(const RenderingServer::ShadowCastingSetting p_cast_shadows) { _cast_shadows = p_cast_shadows; }
	RenderingServer::ShadowCastingSetting get_cast_shadows() const { return _cast_shadows; }
	void set_gi_mode(const GeometryInstance3D::GIMode p_gi_mode) { _gi_mode = p_gi_mode; }
	GeometryInstance3D::GIMode get_gi_mode() const { return _gi_mode; }
};
// Inline Functions

#endif // PASTURE3D_MESHER_CLASS_H
