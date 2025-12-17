// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_COLLISION_CLASS_H
#define TERRAIN3D_COLLISION_CLASS_H

#include <godot_cpp/classes/collision_shape3d.hpp>
#include <godot_cpp/classes/physics_material.hpp>
#include <godot_cpp/classes/static_body3d.hpp>
#include <vector>

#include "constants.h"
#include "terrain_3d_util.h"

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
	enum InstanceCollisionMode {
		INSTANCE_COLLISION_DISABLED,
		INSTANCE_COLLISION_DYNAMIC_GAME,
		INSTANCE_COLLISION_DYNAMIC_EDITOR,
	};

private:
	Terrain3D *_terrain = nullptr;

	// Public settings
	CollisionMode _mode = CollisionMode::DYNAMIC_GAME;
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
	InstanceCollisionMode _instance_collision_mode = InstanceCollisionMode::INSTANCE_COLLISION_DYNAMIC_GAME;
	Vector2i _last_snapped_pos_instance_collision = V2I_MAX;
	real_t _instance_collision_radius = 64.f;
	bool _instance_collision_is_dirty = false;

	RID _instance_static_body_rid;

	// Stored as {PS_rid:RID} -> RS_rid:RID
	Dictionary _shape_debug_mesh_pairs = {};

	// Stored as {cell_loc:v2} -> {mesh_asset_id:int} -> [instances [shapes [RID]]]
	Dictionary _active_instance_cells = {};

	// Stored as {rid:RID} -> {PS_body_to_shape_index:int}
	Dictionary _RID_index_map = {};

	// Debug visualisation queue

	struct DebugMeshInstanceData {
		enum class Action {
			CREATE,
			UPDATE,
			DESTROY,
		};
		RID shape_rid;
		Action action = Action::CREATE;
		Transform3D xform;
		Ref<ArrayMesh> debug_mesh;
	};

	std::vector<DebugMeshInstanceData> _debug_visual_instance_queue;

	Vector2i _snap_to_grid(const Vector2i &p_pos) const;
	Vector2i _snap_to_grid(const Vector3 &p_pos) const;
	Dictionary _get_shape_data(const Vector2i &p_position, const int p_size);

	void _shape_set_disabled(const int p_shape_id, const bool p_disabled);
	void _shape_set_transform(const int p_shape_id, const Transform3D &p_xform);
	Vector3 _shape_get_position(const int p_shape_id) const;
	void _shape_set_data(const int p_shape_id, const Dictionary &p_dict);

	void _reload_physics_material();

	TypedArray<Vector2i> _get_instance_cells_to_build(const Vector2i &p_snapped_pos, const real_t p_radius, const int p_region_size, const int p_cell_size, const real_t p_vertex_spacing);
	Dictionary _get_recyclable_instances(const Vector2i &p_snapped_pos, const real_t p_radius, const int p_cell_size, const real_t p_vertex_spacing);
	Dictionary _get_instance_build_data(const TypedArray<Vector2i> &p_instance_cells_to_build, const int p_region_size, const int p_cell_size, const real_t p_vertex_spacing);
	Dictionary _get_unused_instance_shapes(const Dictionary &p_mesh_instance_build_data, Dictionary &p_recyclable_mesh_instance_shapes);

	void _destroy_remaining_instance_shapes(Dictionary &p_unused_instance_shapes);
	void _generate_instances(const Dictionary &p_instance_build_data, Dictionary &p_recyclable_instances, Dictionary &p_unused_instance_shapes);
	void _create_debug_mesh_instance(const RID &p_shape_rid, const Transform3D &p_xform, const Ref<ArrayMesh> &p_debug_mesh);
	void _update_debug_mesh_instance(const RID &p_shape_rid, const Transform3D &p_xform, const Ref<ArrayMesh> &p_debug_mesh);
	void _destroy_debug_mesh_instance(const RID &p_shape_rid);
	void _destroy_debug_mesh_instances();
	void _queue_debug_mesh_update(const RID &p_shape_rid, const Transform3D &p_xform, const Ref<ArrayMesh> &p_debug_mesh, const DebugMeshInstanceData::Action &p_action);
	void _process_debug_mesh_updates();

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

	void update_instance_collision();
	void destroy_instance_collision();
	void set_instance_collision_mode(const InstanceCollisionMode p_mode);
	InstanceCollisionMode get_instance_collision_mode() const { return _instance_collision_mode; }
	bool is_instance_collision_enabled() const { return _instance_collision_mode > InstanceCollisionMode::INSTANCE_COLLISION_DISABLED; }
	bool is_instance_collision_editor_mode() const { return _instance_collision_mode == InstanceCollisionMode::INSTANCE_COLLISION_DYNAMIC_EDITOR; }
	bool is_instance_collision_dynamic_mode() const { return _instance_collision_mode == InstanceCollisionMode::INSTANCE_COLLISION_DYNAMIC_GAME || _instance_collision_mode == InstanceCollisionMode::INSTANCE_COLLISION_DYNAMIC_EDITOR; }
	void set_instance_collision_radius(const real_t p_radius);
	real_t get_instance_collision_radius() const { return _instance_collision_radius; }
	void set_instance_collision_dirty(const bool p_dirty) { _instance_collision_is_dirty = p_dirty; }

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

using CollisionMode = Terrain3DCollision::CollisionMode;
VARIANT_ENUM_CAST(Terrain3DCollision::CollisionMode);

using InstanceCollisionMode = Terrain3DCollision::InstanceCollisionMode;
VARIANT_ENUM_CAST(Terrain3DCollision::InstanceCollisionMode);

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
