// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_MESHER_CLASS_H
#define TERRAIN3D_MESHER_CLASS_H

#include "constants.h"

using namespace godot;

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

	void _generate_mesh_types(const int p_mesh_size);
	RID _generate_mesh(const Vector2i &p_size, const bool p_standard_grid = false);
	RID _instantiate_mesh(const PackedVector3Array &p_vertices, const PackedInt32Array &p_indices, const AABB &p_aabb);
	void _generate_clipmap(const int p_size, const int p_lods, const RID &scenario);
	void _generate_offset_data(const int p_mesh_size);

	void _clear_clipmap();
	void _clear_mesh_types();

public:
	Terrain3DMesher() {}
	~Terrain3DMesher() { destroy(); }

	void initialize(Terrain3D *p_terrain);
	void destroy();

	void snap();
	void reset_target_position() { _last_target_position = V2_MAX; }
	void update();
	void update_aabbs();
};
// Inline Functions

#endif // TERRAIN3D_MESHER_CLASS_H
