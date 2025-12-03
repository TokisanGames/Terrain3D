// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_MESHER_CLASS_H
#define TERRAIN3D_MESHER_CLASS_H

#include "constants.h"

class Terrain3D;

class Terrain3DMesher {
	CLASS_NAME_STATIC("Terrain3DMesher");

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

private:
	Terrain3D *_terrain = nullptr;
	RID _scenario = RID();
	Vector2 _last_target_position = V2_MAX;

	Array _mesh_rids;
	// LODs -> MeshTypes -> Instances
	Array _clipmap_rids;

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
	int _mesh_size = 0;
	int _lods = 0;
	real_t _vertex_spacing = 1.f;

	void _generate_mesh_types();
	RID _generate_mesh(const Vector2i &p_size, const bool p_standard_grid = false);
	RID _instantiate_mesh(const PackedVector3Array &p_vertices, const PackedInt32Array &p_indices, const AABB &p_aabb);
	void _generate_clipmap();
	void _generate_offset_data();

	void _clear_clipmap();
	void _clear_mesh_types();

public:
	Terrain3DMesher() {}
	~Terrain3DMesher() { destroy(); }

	void initialize(Terrain3D *p_terrain, const int p_mesh_size, const int p_lods, const int p_tessellation_level, const real_t p_vertex_spacing, const RID &p_material);
	void destroy();

	void snap();
	void reset_target_position() { _last_target_position = V2_MAX; }
	void update();
	void update_aabbs();

	void set_material(const RID &p_material) { _material = p_material; }
	RID get_material() const { return _material; }
	void set_mesh_size(const int p_size) { _mesh_size = p_size; }
	int get_mesh_size() const { return _mesh_size; }
	void set_lods(const int p_lods) { _lods = p_lods; }
	int get_lods() const { return _lods; }
	void set_vertex_spacing(const real_t p_spacing) { _vertex_spacing = p_spacing; }
	real_t get_vertex_spacing() const { return _vertex_spacing; }
	void set_tessellation_level(const int p_level) { _tessellation_level = p_level; }
	int get_tessellation_level() const { return _tessellation_level; }
};
// Inline Functions

#endif // TERRAIN3D_MESHER_CLASS_H
