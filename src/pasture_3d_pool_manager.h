// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
// The scene's water authority: wave profiles, the clock, the sun, the material cache.
// Spec: PASTURE3D_WATER_BODIES_SPEC.md §5

#ifndef PASTURE3D_POOL_MANAGER_CLASS_H
#define PASTURE3D_POOL_MANAGER_CLASS_H

#include <godot_cpp/classes/directional_light3d.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/templates/vector.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include "constants.h"
#include "pasture_3d_wave_profile.h"
#include "target_node_3d.h"

using namespace godot;

/**
 * One node per scene owns everything every water body shares.
 *
 * Before this existed the ocean owned all of it, and a lake had no way to reach any
 * of it: the wave table was uploaded into the ocean's material by Pasture3D, and a
 * MeshInstance3D with a lake material got whatever compile-time default its variant
 * happened to carry. That is why the water guide's advice for a pond is "edit 32
 * floats, or run a script" -- there was nothing to ask.
 *
 * Four responsibilities, and they are together because they are the same
 * information seen four ways:
 *
 *   1. PROFILES. Named sets of wave knobs. Bodies select one by name.
 *   2. THE CLOCK. water_time / water_time_period, written once per physics frame.
 *      Project-wide shader globals, so one write drives every body in the scene.
 *   3. THE SUN. water_sun_direction / water_sun_color, from a DirectionalLight3D.
 *   4. THE MATERIAL CACHE. One material per distinct (base material, profile) pair,
 *      with the profile's table uploaded into it once. Ten ponds on one profile cost
 *      one material and one upload -- which is only possible because
 *      _water_domain_origin became an instance uniform (§5.4).
 *
 * Coexistence with Pasture3D's ocean, for the life of Phase 1: Pasture3D still owns
 * an ocean and still wants to drive the clock. Two writers of one global is one
 * writer too many, so Pasture3D yields whenever a manager is in the tree -- see
 * has_active_manager(). Phase 2 deletes the losing side.
 */
class Pasture3DPoolManager : public Node3D {
	GDCLASS(Pasture3DPoolManager, Node3D);
	CLASS_NAME();

public: // Constants
	// Bodies find their manager by group. Matches WATER_MANAGER_GROUP in the spec.
	//
	// A `const char *` and not a `static inline StringName`. A StringName built at
	// static-initialisation time runs before godot-cpp has brought up its string
	// interner, and the DLL then fails to load at all -- Windows reports it as
	// "Error 1114: a dynamic link library initialization routine failed", with no
	// indication of which line. add_to_group() takes a StringName and converts.
	static constexpr const char *MANAGER_GROUP = "pasture3d_water_manager";

private:
	// Process-global count of managers currently in a tree. Pasture3D reads it to
	// decide whether to drive the clock, and the answer has to be about the whole
	// process rather than about one scene: the RenderingServer global table is
	// process-wide, so a manager in ANY open scene is a second writer.
	// Every manager currently in a tree, in the order they entered. A LIST and not a
	// single pointer: managers overlap. A queue_free()d manager stays in the tree
	// until the frame ends, so a replacement entering before it leaves would decline
	// to take over (the slot looked occupied) and then be orphaned when the outgoing
	// one cleared the slot -- leaving no active manager while one was plainly in the
	// scene. Scene switching does exactly that, and the Phase 1 gate caught it.
	static inline Vector<Pasture3DPoolManager *> _managers;

	// Water bodies registered with this manager, in registration order. Deferred
	// from Phase 1 because nothing implemented a body yet and a registry that
	// cannot be gated is a registry that only compiles.
	Vector<Node *> _bodies;
	// The first manager to enter a tree, and the one Pasture3D adopts its clock
	// from. A raw pointer is safe only because EXIT_TREE clears it; nothing else
	// may hold it across a frame.

	TypedArray<Pasture3DWaveProfile> _profiles;
	real_t _loop_period = 120.f;
	TargetNode3D _sun_light;
	bool _paused = false;

	double _water_time = 0.0;
	// Last value pushed to water_time_period; -1 forces the first write.
	float _period_sent = -1.f;
	// Last sun values pushed, so a static sun costs no RenderingServer traffic.
	Vector3 _sun_dir_sent = V3_MAX;
	Vector3 _sun_color_sent = V3_MAX;

	// (base material instance id, profile name) -> the shared duplicate handed out.
	HashMap<String, Ref<Material>> _material_cache;
	// Cumulative count of _waves uploads. The Phase 1 gate asserts ten pools on one
	// profile produce exactly one; it is kept afterwards because "how many uploads
	// did that inspector drag cost" is the question this class exists to answer.
	int _upload_count = 0;

	String _cache_key(const Ref<Material> &p_base, const StringName &p_profile) const;
	void _upload_into(const Ref<Material> &p_material, const Ref<Pasture3DWaveProfile> &p_profile);
	void _on_profile_changed();
	void _connect_profiles();
	void _update_clock(const double p_delta);
	void _update_sun();

protected:
	static void _bind_methods();
	void _notification(int p_what);

public:
	Pasture3DPoolManager();
	~Pasture3DPoolManager();

	// True when any Pasture3DPoolManager is in a tree. Pasture3D consults this before
	// writing the clock globals; see the class comment.
	static bool has_active_manager() { return !_managers.is_empty(); }
	// The manager driving the clock, or null. Pasture3D reads its water_time so the
	// ocean's CPU query stays on the same instant as the drawn surface.
	static Pasture3DPoolManager *get_active_manager() {
		return _managers.is_empty() ? nullptr : _managers[0];
	}
	static int get_active_manager_count() { return _managers.size(); }

	// Declares water_time / water_time_period / water_sun_* on the RenderingServer
	// if the project settings did not already. Process-global and idempotent.
	//
	// Static, and called by Pasture3DOcean as well as by this node, because an ocean or a
	// bare MeshInstance3D with a water material can exist in a scene with no
	// manager at all -- and a water material loaded before these exist makes Godot
	// warn that a global "was removed at some point" and render it black until it
	// recompiles. Moved here from Pasture3D in Phase 2.
	static void register_water_globals();

	void set_profiles(const TypedArray<Pasture3DWaveProfile> &p_profiles);
	TypedArray<Pasture3DWaveProfile> get_profiles() const { return _profiles; }
	void set_loop_period(const real_t p_seconds);
	real_t get_loop_period() const { return _loop_period; }
	void set_sun_light(Node3D *p_light);
	Node3D *get_sun_light() const { return _sun_light.ptr(); }
	void set_paused(const bool p_paused);
	bool is_paused() const { return _paused; }

	// The wrapped clock both the CPU queries and the shaders run on. Not
	// Time.get_ticks_msec(), and not Godot's TIME.
	real_t get_water_time() const { return (real_t)_water_time; }

	Ref<Pasture3DWaveProfile> get_profile(const StringName &p_name) const;
	PackedStringArray get_profile_names() const;
	bool has_profile(const StringName &p_name) const { return get_profile(p_name).is_valid(); }

	// The shared duplicate for this (base, profile) pair, built and uploaded on
	// first ask. Returns the base itself if the profile does not resolve, so a
	// mistyped name renders water rather than nothing.
	Ref<Material> get_material_for(const Ref<Material> &p_base, const StringName &p_profile);
	// Writes a profile's table into a material the caller owns. For bodies that
	// cannot use the shared cache because they write their own uniforms into their
	// material -- Pasture3DOcean and its clipmap parameters are the case this exists for.
	void upload_profile_into(const Ref<Material> &p_material, const StringName &p_profile);
	int get_cached_material_count() const { return _material_cache.size(); }
	int get_upload_count() const { return _upload_count; }
	void clear_material_cache();

	// Rebuilds every profile's table and re-uploads it into every cached material.
	void rebuild_tables();

	// --- Body registry (spec §5.5) ------------------------------------------
	// Bodies register on entering the tree. The contract a body must satisfy is one
	// duck-typed method, `contains_point(global_pos) -> bool`, so a GDScript
	// Pasture3DPool and a C++ Pasture3DOcean can both be bodies without a shared
	// base class.
	void register_body(Node *p_body);
	void unregister_body(Node *p_body);
	TypedArray<Node> get_bodies() const;
	// The innermost body containing a world point, or null. Finite bodies are asked
	// first and the ocean is the fallback -- an ocean is infinite, so asking it first
	// would mean no pool was ever found.
	Node *body_at(const Vector3 &p_global_pos) const;

	// --- Evaluation, in DOMAIN space (spec §5.5) ----------------------------
	// World-space queries belong to the bodies, which apply their own surface
	// height and domain origin. These are the primitives underneath, taken at the
	// current water_time unless one is given.
	real_t evaluate_height(const StringName &p_profile, const Vector2 &p_domain_xz) const;
	Vector3 evaluate_normal(const StringName &p_profile, const Vector2 &p_domain_xz) const;
	Vector3 evaluate_surface_point(const StringName &p_profile, const Vector2 &p_domain_xz) const;
	// Inverse: the domain parameter whose displaced point lands on p_target_xz.
	Vector2 solve_domain(const StringName &p_profile, const Vector2 &p_target_xz) const;

	PackedStringArray _get_configuration_warnings() const;
};

#endif // PASTURE3D_POOL_MANAGER_CLASS_H
