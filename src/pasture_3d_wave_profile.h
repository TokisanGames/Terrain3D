// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
// A named set of Gerstner wave knobs, shared by every water body that selects it.
// Spec: PASTURE3D_WATER_BODIES_SPEC.md §5.3

#ifndef PASTURE3D_WAVE_PROFILE_CLASS_H
#define PASTURE3D_WAVE_PROFILE_CLASS_H

#include <godot_cpp/classes/resource.hpp>

#include "constants.h"
#include "water_waves.h"

using namespace godot;

/**
 * The art knobs for one sea state, plus the table they generate.
 *
 * This is a thin Resource around WaterWaves, and thin on purpose: WaterWaves is a
 * transcription of water_waves.gdshaderinc and the only reason this class exists is
 * so that a scene can hold several of them and hand them out by name. Every piece of
 * wave arithmetic stays in WaterWaves, so the rule that the wave model has exactly
 * two implementations -- the shader include and the C++ file -- survives the
 * addition of lakes, ponds, rivers and buoyancy (spec W3).
 *
 * `loop_period` is deliberately NOT a property here. water_time and
 * water_time_period are project-wide shader globals and the frequency quantisation
 * that makes the clock wrap seamless (water spec §3.2) is computed against a single
 * period, so the period belongs to whatever owns the clock. Pool3DManager owns it
 * and pushes it in with set_loop_period() before building the table.
 */
class Pasture3DWaveProfile : public Resource {
	GDCLASS(Pasture3DWaveProfile, Resource);
	CLASS_NAME();

private:
	// Resource already has name/set_name (the resource's own name), so the
	// selection key is spelled out rather than overloading that.
	StringName _profile_name = "profile";
	WaterWaves _waves;

	// WaterWaves::update() is lazy behind a dirty flag and every read below needs
	// the table built, so this is the one place that forces it.
	void _ensure_built() { _waves.update(); }

protected:
	static void _bind_methods();

public:
	Pasture3DWaveProfile() {}
	~Pasture3DWaveProfile() {}

	void set_profile_name(const StringName &p_name);
	StringName get_profile_name() const { return _profile_name; }

	void set_wave_count(const int p_count);
	int get_wave_count() const { return _waves.get_count(); }
	void set_direction_deg(const real_t p_deg);
	real_t get_direction_deg() const { return _waves.get_direction_deg(); }
	void set_spread_deg(const real_t p_deg);
	real_t get_spread_deg() const { return _waves.get_spread_deg(); }
	void set_amplitude(const real_t p_metres);
	real_t get_amplitude() const { return _waves.get_amplitude(); }
	void set_length_max(const real_t p_metres);
	real_t get_length_max() const { return _waves.get_length_max(); }
	void set_steepness(const real_t p_steepness);
	real_t get_steepness() const { return _waves.get_steepness(); }

	// Manager-driven, not exported. See the class comment.
	void set_loop_period(const real_t p_seconds);
	real_t get_loop_period() const { return _waves.get_loop_period(); }

	// --- Derived, read-only -------------------------------------------------
	PackedVector4Array get_shader_table();
	// What the surface ACTUALLY reaches, which is the sum over the table and not
	// the amplitude knob. Cull margins and clearance checks want this one.
	real_t get_amplitude_sum();
	// Shortest wavelength in the built table. Pool3D sizes its mesh from this
	// (spec §7.3: vertex spacing is a wavelength/8 rule, not a taste).
	real_t get_min_wavelength();

	// --- Evaluation, in DOMAIN space ----------------------------------------
	// World-space queries live on the bodies, which add their own surface height
	// and subtract their own domain origin. These are the primitives underneath.
	Vector3 get_surface_point(const Vector2 &p_domain_xz, const real_t p_time);
	real_t get_height_at(const Vector2 &p_domain_xz, const real_t p_time);
	Vector3 get_normal_at(const Vector2 &p_domain_xz, const real_t p_time);
	Vector2 solve_domain(const Vector2 &p_target_xz, const real_t p_time);

	// For C++ callers that want the evaluator directly (Pool3DManager, Buoy3D).
	WaterWaves &get_waves() {
		_ensure_built();
		return _waves;
	}
};

#endif // PASTURE3D_WAVE_PROFILE_CLASS_H
