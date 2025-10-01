// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_MESHER_CLASS_H
#define TERRAIN3D_MESHER_CLASS_H

#include "constants.h"

class Terrain3D;

struct MeshOffsetData {
	// LOD0 only
	PackedVector3Array trim_a_pos;
	PackedVector3Array trim_b_pos;
	PackedVector3Array tile_pos_lod_0;
	// LOD1 +
	PackedVector3Array fill_a_pos;
	PackedVector3Array fill_b_pos;
	PackedVector3Array tile_pos;
	// All LOD Levels
	real_t offset_a = 0.f;
	real_t offset_b = 0.f;
	real_t offset_c = 0.f;
	PackedVector3Array edge_pos;
};

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
	Array _ocean_mesh_rids;
	// LODs -> MeshTypes -> Instances
	Array _clipmap_rids;
	Array _ocean_clipmap_rids;

	MeshOffsetData _ocean_mesh_offset_data;
	MeshOffsetData _terrain_mesh_offset_data;

	bool _ocean_enabled = false;

	void _generate_mesh_types(Array &p_mesh_rids_array, const int p_size, const RID &p_mat);
	RID _generate_mesh(const Vector2i &p_size, const bool p_standard_grid = false, const RID &p_mat = RID());
	RID _instantiate_mesh(const PackedVector3Array &p_vertices, const PackedInt32Array &p_indices, const AABB &p_aabb, const RID &p_mat);
	void _generate_clipmap(Array &p_instance_rids, Array &p_mesh_rids, MeshOffsetData &p_offset_data, const int p_size, const int p_lods, const RID &p_scenario, const RID &p_mat);
	void _generate_instances(Array &p_instance_rids, Array &p_mesh_rids, const int p_lods, const RID &p_scenario);
	void _generate_offset_data(MeshOffsetData &data, const int p_mesh_size);
	void _update_mesh_transforms(const Array &p_instance_rids, const MeshOffsetData &p_offset_data, const real_t p_vertex_spacing, const Vector3 &p_snapped_pos);

	void _clear_clipmap(Array &p_instances);
	void _clear_mesh_types(Array &p_mesh_rids);
	void _clear_offset_data(MeshOffsetData &p_data);

public:
	Terrain3DMesher() {}
	~Terrain3DMesher() { destroy(); }

	void initialize(Terrain3D *p_terrain);
	void destroy();

	void snap();
	void reset_target_position() { _last_target_position = V2_MAX; }
	void update();
	void update_aabbs();
	void set_ocean_material(const Ref<Material> &p_mat);
	void set_ocean_enabled(const bool p_enabled);
	bool is_ocean_enabled() const { return _ocean_enabled; }
};
// Inline Functions

#endif // TERRAIN3D_MESHER_CLASS_H
