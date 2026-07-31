// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
// One buoyancy sample point on a RigidBody3D.
// Spec: PASTURE3D_WATER_BODIES_SPEC.md §9

#ifndef PASTURE3D_BUOY_CLASS_H
#define PASTURE3D_BUOY_CLASS_H

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/rigid_body3d.hpp>
#include <godot_cpp/templates/hash_map.hpp>

#include "constants.h"

using namespace godot;

/**
 * One Pasture3DBuoy is one SAMPLE POINT, not one boat.
 *
 * Three or four on a hull give pitch and roll for free, because each computes its own submersion
 * from its own position and applies its force at its own offset. One gives a bobbing barrel. That is
 * the whole design: there is no hull model, no waterline solve, no mesh integration -- just points
 * that know how deep they are.
 *
 * The force model is the classic one (spec §9.1), and it is deliberately not a simulation of
 * displacement: `displacement` is the volume THIS buoy displaces at full submersion, so the sum
 * across a body's buoys is what floats it, and `mass / 1000` is the sum that makes it neutral. The
 * node says so in its configuration warning, because "why does my boat sink" is otherwise a numbers
 * puzzle with no way in.
 *
 * C++ rather than GDScript (§4.3) because this runs per physics tick over potentially dozens of
 * instances, and because the wave query underneath it is not cheap: Gerstner waves displace
 * sideways as well as up, so the surface is not a heightfield and get_water_height() solves that
 * inversion iteratively. §9.3 budgets 64 buoys at 0.5 ms per tick and the Phase 6 gate measures it.
 */
class Pasture3DBuoy : public Node3D {
	GDCLASS(Pasture3DBuoy, Node3D);
	CLASS_NAME();

public: // Constants
	// Fresh water. The number that turns a volume into a mass, and the reason `displacement` is in
	// cubic metres rather than in some arbitrary "strength" unit -- it means a hull whose volume you
	// know can be floated by arithmetic instead of by tuning.
	static constexpr real_t WATER_DENSITY = 1000.f;
	// Ticks between forced re-resolutions of the water body, when nothing else has invalidated it.
	// A boat crossing from a lake into the ocean must not need telling, and must not pay for a
	// registry walk sixty times a second either (§9.2).
	static constexpr int RESOLVE_INTERVAL = 30;

private:
	real_t _displacement = 0.25f;
	real_t _full_depth = 0.5f;
	real_t _linear_drag = 400.f;
	real_t _angular_drag = 2.f;
	int _sample_interval = 1;
	uint64_t _water_body_id = 0; // explicit override; 0 = resolve from the manager

	// --- Per-instance runtime state -----------------------------------------
	RigidBody3D *_parent_body = nullptr;
	uint64_t _body_id = 0; // resolved water body
	int _ticks_since_resolve = 0;
	int _ticks_since_sample = 0;
	// Water height as of the last evaluation. Held between samples when sample_interval > 1 --
	// the HEIGHT is held, not the force, so the buoy still responds to its own movement in between.
	real_t _held_height = 0.f;
	bool _held_valid = false;

	// --- Per-body, per-tick angular damping ---------------------------------
	// Angular drag is applied once per BODY per tick, not once per buoy: four buoys on a hull would
	// otherwise damp it four times as hard as one, and the same boat would spin differently for
	// having more sample points. Keyed on the body's instance id.
	struct BodyTick {
		uint64_t frame = 0; // physics frame this entry was last rotated on
		real_t frac_now = 0.f; // largest submersion fraction seen so far THIS frame
		real_t frac_prev = 0.f; // the completed value from the previous frame
	};
	static inline HashMap<uint64_t, BodyTick> _body_ticks;

	Node *_resolve_body();
	Node *_get_body() const;
	RigidBody3D *_find_parent_body() const;
	real_t _gravity() const;

protected:
	static void _bind_methods();
	void _notification(int p_what);

public:
	Pasture3DBuoy();
	~Pasture3DBuoy() {}

	void set_displacement(const real_t p_cubic_metres);
	real_t get_displacement() const { return _displacement; }
	void set_full_depth(const real_t p_metres);
	real_t get_full_depth() const { return _full_depth; }
	void set_linear_drag(const real_t p_drag);
	real_t get_linear_drag() const { return _linear_drag; }
	void set_angular_drag(const real_t p_drag);
	real_t get_angular_drag() const { return _angular_drag; }
	void set_sample_interval(const int p_ticks);
	int get_sample_interval() const { return _sample_interval; }
	void set_water_body(Node *p_body);
	Node *get_water_body() const;

	// The body this buoy is currently floating in, or null. Resolved lazily; exposed so a gate can
	// assert the handoff from a lake to the ocean happened without waiting to see a boat fall.
	Node *get_resolved_body() const { return _get_body(); }
	// Submersion of this buoy right now, 0..1. Read-only, for tooling and for the gate.
	real_t get_submersion() const;
	// Total displacement across every buoy on this buoy's body, and the displacement that body
	// needs to float. Drives the configuration warning; exposed because they are the two numbers
	// anyone debugging a sinking boat actually wants.
	real_t get_body_displacement() const;
	real_t get_required_displacement() const;

	void apply_buoyancy(const double p_delta);

	// The same text _get_configuration_warnings() shows, as a BOUND method.
	//
	// GDExtension virtuals like _get_configuration_warnings() are called by the engine but are not
	// callable from script, so a gate -- or any tool wanting to surface the buoyancy report
	// somewhere other than the inspector -- had no way to read them. Phase 2 hit the same wall from
	// the other side and worked around it; this exposes the thing instead.
	PackedStringArray get_buoyancy_warnings() const;

	PackedStringArray _get_configuration_warnings() const;
};

#endif // PASTURE3D_BUOY_CLASS_H
