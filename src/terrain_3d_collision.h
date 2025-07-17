// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_COLLISION_CLASS_H
#define TERRAIN3D_COLLISION_CLASS_H

#include <godot_cpp/classes/collision_shape3d.hpp>
#include <godot_cpp/classes/physics_material.hpp>
#include <godot_cpp/classes/static_body3d.hpp>
#include <vector>

#include "constants.h"
#include "terrain_3d_util.h"

using namespace godot;

class Terrain3D;

class Terrain3DCollision : public Object {
	GDCLASS(Terrain3DCollision, Object);
	CLASS_NAME();

public: // Constants
	enum CollisionMode {
		DISABLED,
		DYNAMIC_GAME,
		DYNAMIC_EDITOR,
		FULL_GAME,
		FULL_EDITOR,
	};

private:
	Terrain3D *_terrain = nullptr;

	// Public settings
	CollisionMode _mode = DYNAMIC_GAME;
	uint16_t _shape_size = 16;
	uint16_t _radius = 64;
	uint32_t _layer = 1;
	uint32_t _mask = 1;
	real_t _priority = 1.f;
	Ref<PhysicsMaterial> _physics_material;

	// Work data
	RID _static_body_rid; // Physics Server Static Body
	StaticBody3D *_static_body = nullptr; // Editor mode StaticBody3D
	std::vector<CollisionShape3D *> _shapes; // All CollisionShape3Ds

	bool _initialized = false;
	Vector2i _last_snapped_pos = V2I_MAX;

	// Instance collision data
	RID _instance_static_body_rid;

	// Stored as {PS_rid:RID} -> RS_rid:RID
	Dictionary _instance_shape_visual_pairs = {};

	// Stored as {cell_loc:v3} -> {mesh_asset_id:int} -> [instances [shapes [RID]]]
	Dictionary _active_instance_cells = {};

	Dictionary _RID_index_map = {};

	Vector2i _snap_to_grid(const Vector2i &p_pos) const;
	Vector2i _snap_to_grid(const Vector3 &p_pos) const;
	Dictionary _get_shape_data(const Vector2i &p_position, const int p_size);

	void _shape_set_disabled(const int p_shape_id, const bool p_disabled);
	void _shape_set_transform(const int p_shape_id, const Transform3D &p_xform);
	Vector3 _shape_get_position(const int p_shape_id) const;
	void _shape_set_data(const int p_shape_id, const Dictionary &p_dict);

	void _reload_physics_material();

	Vector2i _get_cell(const Vector3 &p_global_position, const int &p_region_size);

	TypedArray<Vector3> get_instance_cells_to_build(const Vector2i &p_snapped_pos, const int &p_region_size, const int &p_cell_size, const real_t &p_vertex_spacing);

	Dictionary _get_recyclable_instances(const Vector2i &p_snapped_pos, const real_t &p_radius);

	Dictionary _get_instance_build_data(const TypedArray<Vector3> &p_instance_p_instance_cells_to_buildcells_to_build, const int &p_region_size, const real_t &p_vertex_spacing);

	Dictionary _get_unused_instance_shapes(const Dictionary &p_mesh_instance_build_data, Dictionary &p_recyclable_mesh_instance_shapes);

	void _destroy_remaining_instance_shapes(Dictionary &p_unused_instance_shapes);

	void _generate_instances(const Dictionary &p_instance_build_data, Dictionary &p_recyclable_instances, Dictionary &p_unused_instance_shapes);

	void _update_instance_collision();
	void _destroy_instance_collision();
	void _create_visual_instance(const RID &p_shape_rid, const Transform3D &p_xform, Ref<ArrayMesh> p_debug_mesh);
	void _update_visual_instance(const RID &p_shape_rid, const Transform3D &p_xform, Ref<ArrayMesh> p_debug_mesh = NULL);
	void _destroy_visual_instance(const RID &p_shape_rid);
	void _destroy_visual_instances();

public:
	Terrain3DCollision() {}
	~Terrain3DCollision() { destroy(); }

	void initialize(Terrain3D *p_terrain);

	void build();
	void reset_target_position() { _last_snapped_pos = V2I_MAX; }
	void update(const bool p_rebuild = false);
	void destroy();

	void set_mode(const CollisionMode p_mode);
	CollisionMode get_mode() const { return _mode; }
	bool is_enabled() const { return _mode > DISABLED; }
	bool is_editor_mode() const { return _mode == DYNAMIC_EDITOR || _mode == FULL_EDITOR; }
	bool is_dynamic_mode() const { return _mode == DYNAMIC_GAME || _mode == DYNAMIC_EDITOR; }

	void set_shape_size(const uint16_t p_size);
	uint16_t get_shape_size() const { return _shape_size; }
	void set_radius(const uint16_t p_radius);
	uint16_t get_radius() const { return _radius; }
	void set_layer(const uint32_t p_layers);
	uint32_t get_layer() const { return _layer; };
	void set_mask(const uint32_t p_mask);
	uint32_t get_mask() const { return _mask; };
	void set_priority(const real_t p_priority);
	real_t get_priority() const { return _priority; }
	void set_physics_material(const Ref<PhysicsMaterial> &p_mat);
	Ref<PhysicsMaterial> get_physics_material() { return _physics_material; }
	RID get_rid() const;

protected:
	static void _bind_methods();
};

typedef Terrain3DCollision::CollisionMode CollisionMode;
VARIANT_ENUM_CAST(Terrain3DCollision::CollisionMode);

inline Vector2i Terrain3DCollision::_snap_to_grid(const Vector2i &p_pos) const {
	return Vector2i(int_round_mult(p_pos.x, int32_t(_shape_size)),
			int_round_mult(p_pos.y, int32_t(_shape_size)));
}

inline Vector2i Terrain3DCollision::_snap_to_grid(const Vector3 &p_pos) const {
	return Vector2i(Math::floor(p_pos.x / real_t(_shape_size) + 0.5f),
				   Math::floor(p_pos.z / real_t(_shape_size) + 0.5f)) *
			_shape_size;
}

#endif // TERRAIN3D_COLLISION_CLASS_H