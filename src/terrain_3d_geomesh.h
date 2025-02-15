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

	bool _initialized = false;

	RID _instantiate_mesh(const PackedVector3Array &p_vertices, const PackedInt32Array &p_indices, const AABB &p_aabb);
	void _generate_offset_data(const int mesh_size);
	RID _generate_mesh(const Vector2i size);
	void _generate_mesh_types(const int mesh_size);
	void _clear_mesh_types();
	void _generate_clipmap(const int size, const int lods, const RID &scenario);
	void _clear_clipmap();

	Array _mesh_rids;
	// lods -> MeshTypes -> instances
	Array _clipmap_rids;

	// Mesh offset data
	// LOD0 only
	Array _trim_a_pos;
	Array _trim_b_pos;
	Array _tile_pos_lod_0;
	// LOD1 +
	Array _fill_a_pos;
	Array _fill_b_pos;
	Array _tile_pos;
	// All LOD Levels
	real_t _offset_a;
	real_t _offset_b;
	real_t _offset_c;
	Array _edge_pos;

public:
	Terrain3DGeoMesh() {}
	~Terrain3DGeoMesh() { destroy(); }

	void initialize(Terrain3D *p_terrain);
	void destroy();

	void snap(const Vector3 tracked_pos, const real_t mesh_desnity);
	void update_aabbs();
	void update_clipmap_instances();
	void regenerate();

	enum MeshType {
		TILE,
		EDGE_A,
		EDGE_B,
		FILL_A,
		FILL_B,
		TRIM_A,
		TRIM_B,
	};

protected:
	static void _bind_methods();
};
// Inline Functions

#endif // TERRAIN3D_GEOMESH_CLASS_H