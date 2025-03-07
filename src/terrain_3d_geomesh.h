// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_GEOMESH_CLASS_H
#define TERRAIN3D_GEOMESH_CLASS_H

#include <godot_cpp/templates/vector.hpp>

#include "constants.h"

using namespace godot;

class Terrain3D;

class Terrain3DGeoMesh : public Object {
	GDCLASS(Terrain3DGeoMesh, Object);
	CLASS_NAME();
	friend Terrain3D;

private:
	Terrain3D *_terrain = nullptr;

	RID _generate_mesh(const Vector2i &p_size, const bool p_standard_grid = false);
	RID _instantiate_mesh(const PackedVector3Array &p_vertices, const PackedInt32Array &p_indices, const AABB &p_aabb);
	void _generate_offset_data(const int p_mesh_size);
	void _generate_mesh_types(const int p_mesh_size);
	void _clear_mesh_types();
	void _generate_clipmap(const int p_size, const int p_lods, const RID &scenario);
	void _clear_clipmap();

	Array _mesh_rids;
	// lods -> MeshTypes -> instances
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
	real_t _offset_a;
	real_t _offset_b;
	real_t _offset_c;
	PackedVector3Array _edge_pos;

public:
	Terrain3DGeoMesh() {}
	~Terrain3DGeoMesh() { destroy(); }

	void initialize(Terrain3D *p_terrain);
	void destroy();

	void snap(const Vector3 &p_tracked_pos, const real_t p_mesh_density);
	void update();
	void update_aabbs();

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

protected:
	static void _bind_methods();
};
// Inline Functions

#endif // TERRAIN3D_GEOMESH_CLASS_H