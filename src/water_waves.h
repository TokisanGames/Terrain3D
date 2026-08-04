// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
// Water wave table generation and CPU-side evaluation.
// Spec: PASTURE3D_WATER_SHADER_SPEC.md §3.1, §3.2, §4.2, §4.3

#ifndef WATER_WAVES_CLASS_H
#define WATER_WAVES_CLASS_H

#include <godot_cpp/variant/packed_vector4_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

using namespace godot;

// Must match WATER_MAX_WAVES in water_common.gdshaderinc.
#define WATER_MAX_WAVES 8

/**
 * Generates the Gerstner wave table from art knobs and evaluates it on the CPU.
 *
 * *** THE EVALUATOR IS A TRANSCRIPTION OF water_waves.gdshaderinc. ***
 * Both sides must produce the same surface, so both must do the same arithmetic
 * in the same order in float. See spec §4.3. Anything changed in one file gets
 * changed in the other, and the two are diffed by eye at review.
 *
 * Only the table crosses the CPU/GPU boundary; everything else (angular
 * wavenumber, phase rate, steepness weighting) is derived independently on each
 * side using nothing but `/` and `sqrt`, which IEEE-754 requires to be
 * correctly rounded and therefore bit-identical.
 */
class WaterWaves {
public:
	struct Wave {
		// --- Uploaded. Matches the shader's vec4 layout exactly. ---
		float dir_x = 1.0f;
		float dir_z = 0.0f;
		float amplitude = 0.0f;
		float wavelength = 10.0f;

		// --- Derived in update(). Never uploaded, never crosses the boundary. ---
		// Angular wavenumber and phase rate. Pure functions of `wavelength`, which is
		// fixed once the table is built, so the evaluator was recomputing a divide and a
		// sqrt per wave per call -- and solve_domain() calls it up to 16 times, which made
		// it up to 128 redundant divides and 128 redundant sqrts per height query, per
		// buoy, per tick.
		//
		// Hoisting them does NOT weaken the parity contract in the class comment. The
		// shader still derives its own w and omega per vertex; both sides compute
		// TAU/wavelength and sqrt(GRAVITY*w) from the same float, and IEEE-754 requires
		// `/` and `sqrt` to be correctly rounded, so the results are bit-identical
		// whether they are formed once or a thousand times.
		float w = 0.0f;
		float omega = 0.0f;
	};

	// Where the generated series bottoms out, and the floor on `length_max`.
	// Below ~10 m the phase argument w*dot(D, xz) loses too many mantissa bits at
	// clipmap-scale coordinates (spec §3.1); finer detail is the texture's job.
	// Bodies far from the origin should set a domain origin rather than lower this.
	//
	// NOT a hard floor on every wavelength in the table, and it never was -- see
	// update(). Once `length_max` is under 20 m the series would have nowhere to
	// run, so it continues to length_max/2 instead: a pond at length_max 12 gets
	// 12 m and 6 m waves. That is the small-body case, which is near its own origin
	// and not in the precision regime this constant describes.
	static constexpr float MIN_WAVELENGTH = 10.0f;
	static constexpr float GRAVITY = 9.81f;
	static constexpr float TAU = 6.283185307179586f;

private:
	Wave _waves[WATER_MAX_WAVES];
	int _count = 8;
	// Sum of the table's amplitudes, cached by update(). Invariant for the life of a
	// built table, and the evaluator re-summed it on every call from inside the solve
	// loop. Over the whole table, so it is unchanged by the loops below stopping at
	// _count: slots past the count hold amplitude 0.
	float _amp_sum = 0.0f;

	// Art knobs (spec §4.2)
	float _direction_deg = 0.0f;
	float _spread_deg = 25.0f;
	float _amplitude = 1.6f;
	float _length_max = 137.0f;
	float _steepness = 0.35f;
	float _loop_period = 120.0f;

	bool _dirty = true;

public:
	void set_count(const int p_count);
	int get_count() const { return _count; }
	void set_direction_deg(const float p_deg);
	float get_direction_deg() const { return _direction_deg; }
	void set_spread_deg(const float p_deg);
	float get_spread_deg() const { return _spread_deg; }
	void set_amplitude(const float p_amplitude);
	float get_amplitude() const { return _amplitude; }
	void set_length_max(const float p_length);
	float get_length_max() const { return _length_max; }
	void set_steepness(const float p_steepness);
	float get_steepness() const { return _steepness; }
	void set_loop_period(const float p_seconds);
	float get_loop_period() const { return _loop_period; }

	// Rebuilds the table if a knob changed. Cheap, but not free -- callers on a
	// per-frame path should rely on the dirty flag rather than forcing it.
	void update();
	bool is_dirty() const { return _dirty; }

	// WATER_MAX_WAVES entries, zero-padded past _count, for `uniform vec4
	// _waves[WATER_MAX_WAVES]`. Zero-amplitude entries are inert in the shader.
	PackedVector4Array get_shader_table() const;

	// Largest vertical displacement the surface can reach, which is the sum of
	// the table's amplitudes (every wave crests together somewhere). Read off the
	// built table, NOT off the amplitude knob: the knob is the amplitude of the
	// longest wave and the geometric series adds the rest, so for the ocean
	// defaults the knob says 1.6 m and the surface reaches 5.2 m. Used for the
	// ocean's cull AABB (spec §4.5), where under-stating it culls visible water.
	float get_amplitude_sum() const;

	// --- Evaluator: transcription of water_eval_waves() ---------------------
	// p_time is the same wrapped clock the shader gets, NOT Godot's TIME.
	//
	// Both loops stop at _count. They used to run to WATER_MAX_WAVES to mirror the
	// shader, which runs to its variant's WATER_WAVE_COUNT and has no way to learn
	// _count -- but that is a parity argument about the SUMS, and a slot past _count
	// holds amplitude 0, which makes every one of its contributions exactly 0.0f:
	// qwa = steepness_per_amp * 0, qa = 0, wa = 0, and the height term is 0 * sin.
	// Adding 0.0f is exact, so stopping early is arithmetically identical to running
	// on and the two sides still agree whenever the variant reads at least _count
	// waves. It also stops a 2-wave pond profile paying for eight sin/cos/sqrt.
	//
	// The reverse case -- _count above the variant's count -- cannot be fixed here
	// and is reported as a configuration warning on the node instead.

	// Displaced surface point for a DOMAIN-SPACE parameter, which is what the
	// vertex shader computes for the same input. This is the parity contract with
	// water_eval_waves(); everything else here is built on it.
	//
	// Note the result is NOT the height above p_domain_xz. Gerstner displaces
	// horizontally, so the point drawn for parameter u sits at u + D(u), and the
	// xz of the result differs from the input by up to 4.7 m at the ocean
	// defaults. solve_domain() goes the other way.
	Vector3 get_position(const Vector2 &p_domain_xz, const float p_time) const;
	float get_height(const Vector2 &p_domain_xz, const float p_time) const {
		return get_position(p_domain_xz, p_time).y;
	}
	Vector3 get_normal(const Vector2 &p_domain_xz, const float p_time) const;

	// Inverse of get_position()'s horizontal part: the domain parameter whose
	// displaced point lands on p_target_xz.
	//
	// Fixed-point iteration. Its contraction factor is bounded by _steepness
	// exactly -- the same quantity that bounds self-intersection -- so it
	// converges for every steepness the inspector allows, and fastest on calm
	// water.
	//
	// This is what makes the height query a height query. Skipping it, i.e.
	// reading the wave function at the world position and calling that the
	// height, is wrong by a mean of 23 cm and a worst case of 2.5 m at the ocean
	// defaults (§8.5), against G4's budget of 1 cm. The spec asserted a few
	// centimetres and made the solve the caller's problem; it was wrong on both
	// counts, so the solve lives here.
	// Iteration cap. The error contracts by ~steepness per step from an initial
	// miss of sum(q*A) -- 4.75 m at the ocean defaults -- so the count needed
	// scales with -log(steepness). Measured worst cases: 4 steps at steepness 0.05,
	// 8 at 0.35, 13 at 0.6, 16 at 0.8. Sized for 0.8, because steepness 1.0 is the
	// self-intersection limit where the surface has vertical tangents, the inverse
	// stops being unique and no iteration count is enough; a height query there is
	// ill-posed rather than slow. (Even so, 16 steps at 1.0 leaves a 4 mm
	// horizontal residual, worth 2.4 mm of height -- still inside G4.) Calm water
	// costs 4 steps: the loop exits on SOLVE_EPSILON, not on this.
	static constexpr int MAX_SOLVE_ITERATIONS = 16;
	// Stop once a step moves the parameter under a tenth of a millimetre. The
	// parameter error left is at most s/(1-s) of that and the height error at most
	// the surface slope (sum(w*A), 0.59 at the ocean defaults) times that, so well
	// under a tenth of a millimetre -- two orders inside G4.
	static constexpr float SOLVE_EPSILON = 1e-4f;
	Vector2 solve_domain(const Vector2 &p_target_xz, const float p_time,
			int *r_iterations = nullptr) const;
};

#endif // WATER_WAVES_CLASS_H
