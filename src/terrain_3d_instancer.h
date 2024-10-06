// Copyright © 2024 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_INSTANCER_CLASS_H
#define TERRAIN3D_INSTANCER_CLASS_H

#include <godot_cpp/classes/multi_mesh.hpp>
#include <godot_cpp/classes/multi_mesh_instance3d.hpp>

#include "constants.h"

using namespace godot;

class Terrain3D;
class Terrain3DAssets;

class Terrain3DInstancer : public Object {
	GDCLASS(Terrain3DInstancer, Object);
	CLASS_NAME();
	friend Terrain3D;

	Terrain3D *_terrain = nullptr;

	// MM Resources stored in Terrain3DRegion::_multimeshes as
	// Dictionary[mesh_id:int] -> MultiMesh
	// MMI Objects attached to tree, freed in destructor, stored as
	// Dictionary[Vector3i(region_location.x, region_location.y, mesh_id)] -> MultiMeshInstance3D
	Dictionary _mmis;

	uint32_t _instance_counter = 0;
	uint32_t _get_instace_count(const real_t p_density);

	void _update_mmis(const Vector2i &p_region_loc = V2I_MAX, const int p_mesh_id = -1);
	void _destroy_mmi_by_location(const Vector2i &p_region_loc, const int p_mesh_id);
	void _backup_regionl(const Vector2i &p_region_loc);
	void _backup_region(const Ref<Terrain3DRegion> &p_region);
	Ref<MultiMesh> _create_multimesh(const int p_mesh_id, const TypedArray<Transform3D> &p_xforms = TypedArray<Transform3D>(), const TypedArray<Color> &p_colors = TypedArray<Color>()) const;

public:
	Terrain3DInstancer() {}
	~Terrain3DInstancer() { destroy(); }

	void initialize(Terrain3D *p_terrain);
	void destroy();

	void clear_by_mesh(const int p_mesh_id);
	void clear_by_location(const Vector2i &p_region_loc, const int p_mesh_id);
	void clear_by_region(const Ref<Terrain3DRegion> &p_region, const int p_mesh_id);

	void add_instances(const Vector3 &p_global_position, const Dictionary &p_params);
	void remove_instances(const Vector3 &p_global_position, const Dictionary &p_params);
	void add_multimesh(const int p_mesh_id, const Ref<MultiMesh> &p_multimesh, const Transform3D &p_xform = Transform3D());
	void add_transforms(const int p_mesh_id, const TypedArray<Transform3D> &p_xforms, const TypedArray<Color> &p_colors = TypedArray<Color>());
	void append_location(const Vector2i &p_region_loc, const int p_mesh_id, const TypedArray<Transform3D> &p_xforms,
			const TypedArray<Color> &p_colors, const bool p_clear = false, const bool p_update = true);
	void append_region(const Ref<Terrain3DRegion> &p_region, const int p_mesh_id, const TypedArray<Transform3D> &p_xforms,
			const TypedArray<Color> &p_colors, const bool p_clear = false, const bool p_update = true);
	void update_transforms(const AABB &p_aabb);
	void copy_paste_dfr(const Terrain3DRegion *p_src_region, const Rect2 &p_src_rect, const Terrain3DRegion *p_dst_region);

	void swap_ids(const int p_src_id, const int p_dst_id);
	Ref<MultiMesh> get_multimeshp(const Vector3 &p_global_position, const int p_mesh_id) const;
	Ref<MultiMesh> get_multimesh(const Vector2i &p_region_loc, const int p_mesh_id) const;
	MultiMeshInstance3D *get_multimesh_instancep(const Vector3 &p_global_position, const int p_mesh_id) const;
	MultiMeshInstance3D *get_multimesh_instance(const Vector2i &p_region_loc, const int p_mesh_id) const;
	Dictionary get_mmis() const { return _mmis; }
	void set_cast_shadows(const int p_mesh_id, const GeometryInstance3D::ShadowCastingSetting p_cast_shadows);
	void force_update_mmis();

	void reset_instance_counter() { _instance_counter = 0; }
	void print_multimesh_buffer(MultiMeshInstance3D *p_mmi) const;

protected:
	static void _bind_methods();
};

// Allows us to instance every X function calls for sparse placement
// Modifies _instance_counter, not const!
inline uint32_t Terrain3DInstancer::_get_instace_count(const real_t p_density) {
	uint32_t count = 0;
	if (p_density < 1.f && _instance_counter++ % uint32_t(1.f / p_density) == 0) {
		count = 1;
	} else if (p_density >= 1.f) {
		count = uint32_t(p_density);
	}
	return count;
}

#endif // TERRAIN3D_INSTANCER_CLASS_H