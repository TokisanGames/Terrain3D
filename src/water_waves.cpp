// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <cmath>

#include <godot_cpp/variant/vector4.hpp>

#include "logger.h"
#include "water_waves.h"

///////////////////////////
// Private Functions
///////////////////////////

namespace {

float wfract(const float p_x) {
	return p_x - std::floor(p_x);
}

/**
 * Deterministic directional scatter in [-1, 1], one value per wave index.
 *
 * A golden-ratio sequence rather than rand(): the table has to be reproducible
 * across runs and identical between the editor and the running game, or the CPU
 * height query and the GPU surface describe different oceans (spec §4.2).
 *
 * Index 0 returns exactly 0, so the dominant wave always runs straight down the
 * wind direction and the spread opens up around it.
 */
float scatter(const int p_index) {
	return 2.0f * wfract(0.5f + float(p_index) * 0.6180339887f) - 1.0f;
}

} // anonymous namespace

///////////////////////////
// Public Functions
///////////////////////////

void WaterWaves::set_count(const int p_count) {
	int count = CLAMP(p_count, 1, WATER_MAX_WAVES);
	if (_count != count) {
		_count = count;
		_dirty = true;
	}
}

void WaterWaves::set_direction_deg(const float p_deg) {
	if (_direction_deg != p_deg) {
		_direction_deg = p_deg;
		_dirty = true;
	}
}

void WaterWaves::set_spread_deg(const float p_deg) {
	float deg = CLAMP(p_deg, 0.0f, 90.0f);
	if (_spread_deg != deg) {
		_spread_deg = deg;
		_dirty = true;
	}
}

void WaterWaves::set_amplitude(const float p_amplitude) {
	float amp = MAX(p_amplitude, 0.0f);
	if (_amplitude != amp) {
		_amplitude = amp;
		_dirty = true;
	}
}

void WaterWaves::set_length_max(const float p_length) {
	float len = MAX(p_length, MIN_WAVELENGTH);
	if (_length_max != len) {
		_length_max = len;
		_dirty = true;
	}
}

void WaterWaves::set_steepness(const float p_steepness) {
	// The shader's normalisation guarantees sum(Q*w*A) == steepness, so the
	// non-self-intersection condition is exactly steepness <= 1. Held below that
	// because crests already look wrong well before they actually fold.
	float s = CLAMP(p_steepness, 0.0f, 1.0f);
	if (_steepness != s) {
		_steepness = s;
		_dirty = true;
	}
}

void WaterWaves::set_loop_period(const float p_seconds) {
	float t = MAX(p_seconds, 0.0f);
	if (_loop_period != t) {
		_loop_period = t;
		_dirty = true;
	}
}

/**
 * Builds the wave table from the art knobs.
 *
 * Wavelengths form a geometric series from length_max down to a floor, with
 * amplitude proportional to wavelength (which is what keeps steepness roughly
 * even across the series rather than making the short waves razor-edged).
 *
 * Each wavelength is then quantised so the wave completes a whole number of
 * cycles in loop_period, which is what lets the clock wrap seamlessly (§3.2).
 * The quantisation is applied to the WAVELENGTH, not to the phase rate, so the
 * shader can keep deriving the phase rate from the wavelength with a plain
 * sqrt and still land on the same number. Storing a pre-quantised phase rate
 * would have meant a second value per wave crossing the boundary, and a second
 * chance for the two sides to disagree.
 */
void WaterWaves::update() {
	if (!_dirty) {
		return;
	}
	_dirty = false;

	float length_max = MAX(_length_max, MIN_WAVELENGTH);
	// A pond whose longest wave is already near the floor still needs a series, so
	// this deliberately goes BELOW MIN_WAVELENGTH rather than collapsing the series
	// onto it. `length_max * 0.5` and not the floor: with length_max 12 the series
	// runs 12 -> 6 m, and a pond gets ripples instead of two copies of one wave.
	//
	// That is safe for the case it exists for and not in general. The floor is a
	// precision limit at CLIPMAP-scale coordinates (spec §3.1) -- the phase argument
	// w*dot(D, xz) loses mantissa bits out at kilometres, not near a mesh's own
	// origin. A 25 m pond sits near its origin, so 6 m waves are fine there; a pond
	// placed 5 km out is back in the regime the floor describes and needs a domain
	// origin, exactly as §3.1 says for every other body.
	//
	// Pinned by unit sub-test (e), which exercises this branch specifically. It is
	// only reachable below length_max 20; the ocean defaults cannot reach it, which
	// is why it went unnoticed until the Phase 5 presets asked for a pond.
	float length_min = MIN(MIN_WAVELENGTH, length_max * 0.5f);
	float ratio = (_count > 1) ? std::pow(length_min / length_max, 1.0f / float(_count - 1)) : 1.0f;

	_amp_sum = 0.0f;
	for (int i = 0; i < WATER_MAX_WAVES; i++) {
		if (i >= _count) {
			// Inert: the shader weights steepness by amplitude, so a zero here
			// contributes nothing to position, normal or jacobian. w and omega are
			// still filled in below rather than left at zero -- the evaluator divides
			// by w, and a slot that is merely unused must not be a slot that produces
			// a NaN if anything ever reads it.
			_waves[i] = Wave{ 1.0f, 0.0f, 0.0f, MIN_WAVELENGTH };
			_waves[i].w = TAU / MIN_WAVELENGTH;
			_waves[i].omega = std::sqrt(GRAVITY * _waves[i].w);
			continue;
		}

		float wavelength = length_max * std::pow(ratio, float(i));

		if (_loop_period > 0.0f) {
			float w = TAU / wavelength;
			float omega = std::sqrt(GRAVITY * w);
			// Whole cycles completed in one loop period.
			float cycles = std::round(omega * _loop_period / TAU);
			cycles = MAX(cycles, 1.0f);
			float omega_q = TAU * cycles / _loop_period;
			float w_q = omega_q * omega_q / GRAVITY;
			wavelength = TAU / w_q;
		}

		float angle = Math::deg_to_rad(_direction_deg + _spread_deg * scatter(i));

		Wave &wave = _waves[i];
		wave.dir_x = std::cos(angle);
		wave.dir_z = std::sin(angle);
		// "Amplitude of the longest wave", scaled down with wavelength.
		wave.amplitude = _amplitude * (wavelength / length_max);
		wave.wavelength = wavelength;
		// The same guard the evaluator used to apply per call, applied once. Deep-water
		// dispersion: speed = sqrt(g*L/TAU), phase rate = speed*w, which collapses to
		// sqrt(g*w).
		wave.w = TAU / MAX(wave.wavelength, 1e-3f);
		wave.omega = std::sqrt(GRAVITY * wave.w);
		_amp_sum += wave.amplitude;
	}
}

PackedVector4Array WaterWaves::get_shader_table() const {
	PackedVector4Array table;
	table.resize(WATER_MAX_WAVES);
	for (int i = 0; i < WATER_MAX_WAVES; i++) {
		const Wave &wave = _waves[i];
		table[i] = Vector4(wave.dir_x, wave.dir_z, wave.amplitude, wave.wavelength);
	}
	return table;
}

float WaterWaves::get_amplitude_sum() const {
	// Summed in update() rather than here. It was being re-summed inside get_position(),
	// which solve_domain() calls up to 16 times per query. Slots past _count carry
	// amplitude 0, so accumulating only the live ones gives the same float back: adding
	// 0.0f is exact.
	return _amp_sum;
}

///////////////////////////
// Evaluator
///////////////////////////
//
// Line-for-line transcription of water_eval_waves() in
// water_waves.gdshaderinc. Keep the operation order identical; see the header.
//
// The shader's compile-time fallback table is deliberately NOT mirrored here.
// It exists only for the case where nothing uploaded a table, and if this code
// is running then something did.

Vector3 WaterWaves::get_position(const Vector2 &p_domain_xz, const float p_time) const {
	float domain_x = (float)p_domain_xz.x;
	float domain_z = (float)p_domain_xz.y;

	float steepness_per_amp = _steepness / MAX(_amp_sum, 1e-6f);

	float px = domain_x;
	float py = 0.0f;
	float pz = domain_z;
	for (int i = 0; i < _count; i++) {
		const Wave &wave = _waves[i];
		float amp = wave.amplitude;

		const float w = wave.w;
		const float omega = wave.omega;

		float qwa = steepness_per_amp * amp;
		float qa = qwa / w;

		float theta = w * (wave.dir_x * domain_x + wave.dir_z * domain_z) + omega * p_time;
		float s = std::sin(theta);
		float c = std::cos(theta);

		px += (qa * c) * wave.dir_x;
		pz += (qa * c) * wave.dir_z;
		// No steepness weighting on the vertical term: Q scales the horizontal
		// displacement and the normal, but the shader's height is a plain
		// `amp * sin(theta)`.
		py += amp * s;
	}
	return Vector3(px, py, pz);
}

/**
 * u_{k+1} = target - D(u_k), written as u += (target - P(u).xz) since
 * P(u).xz == u + D(u).
 *
 * The iteration count is reported so callers can see it, and the unit test can
 * assert it stays inside the bound rather than trusting the arithmetic that says
 * it must.
 */
Vector2 WaterWaves::solve_domain(const Vector2 &p_target_xz, const float p_time,
		int *r_iterations) const {
	Vector2 u = p_target_xz;
	int k = 0;
	for (; k < MAX_SOLVE_ITERATIONS; k++) {
		Vector3 p = get_position(u, p_time);
		Vector2 step(p_target_xz.x - p.x, p_target_xz.y - p.z);
		u += step;
		if (step.length_squared() <= (real_t)SOLVE_EPSILON * (real_t)SOLVE_EPSILON) {
			k++;
			break;
		}
	}
	if (r_iterations) {
		*r_iterations = k;
	}
	return u;
}

Vector3 WaterWaves::get_normal(const Vector2 &p_domain_xz, const float p_time) const {
	float domain_x = (float)p_domain_xz.x;
	float domain_z = (float)p_domain_xz.y;

	float steepness_per_amp = _steepness / MAX(_amp_sum, 1e-6f);

	float nx = 0.0f;
	float ny = 1.0f;
	float nz = 0.0f;
	for (int i = 0; i < _count; i++) {
		const Wave &wave = _waves[i];
		float amp = wave.amplitude;

		const float w = wave.w;
		const float omega = wave.omega;

		float qwa = steepness_per_amp * amp;
		float wa = w * amp;

		float theta = w * (wave.dir_x * domain_x + wave.dir_z * domain_z) + omega * p_time;
		float s = std::sin(theta);
		float c = std::cos(theta);

		nx -= (wa * c) * wave.dir_x;
		nz -= (wa * c) * wave.dir_z;
		ny -= qwa * s;
	}
	return Vector3(nx, ny, nz).normalized();
}
