// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Native Geological Primitives solver (MountainCone, MountainInselberg, MountainRangeRadial,
// MountainTibesti, MountainStump, ShatteredPeak, Caldera) ported from Hesiod/HighMap.

#ifndef PASTURE_3D_GEO_PRIMITIVES_H
#define PASTURE_3D_GEO_PRIMITIVES_H

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <cstdint>

namespace godot {

// Deterministic PRNG hash (Wang hash from HighMap). Shared by the CPU solvers and the GPU router so both
// seed the noise kernels identically. Inline in the header so pasture_3d_graph_gpu.cpp can pre-hash on host
// the way the CPU path and the GLSL shader expect.
inline uint32_t wang_hash(uint32_t seed) {
	seed = (seed ^ 61) ^ (seed >> 16);
	seed *= 9;
	seed = seed ^ (seed >> 4);
	seed *= 0x27d4eb2d;
	seed = seed ^ (seed >> 15);
	return seed;
}

// Nyquist octave cap. Keeps octave o while kw * lacunarity^o <= shape/2 (wavelength >= 2 px); octaves past
// that carry only aliasing and dominate cost at preview resolution. Computed in double with a small relative
// slack on the boundary so it returns the IDENTICAL integer across the C++ (float), GDScript-oracle
// (double), and GPU-router paths — the parity gates depend on this. shape is the coarser grid axis.
inline int nyquist_octave_cap(int octaves, double kw, double lacunarity, int shape_px) {
	if (octaves <= 1 || kw <= 0.0 || shape_px <= 0 || lacunarity <= 1.0) {
		return octaves;
	}
	int cap = 1; // octave 0 (the base frequency) is always kept
	double f = kw * lacunarity; // frequency at octave index 1
	const double nyq = 0.5 * (double)shape_px * 1.0001; // relative slack absorbs float/double boundary jitter
	while (cap < octaves && f <= nyq) {
		cap++;
		f *= lacunarity;
	}
	return cap;
}

struct MountainConeParams {
	int seed = 0;
	float elevation = 25.0f;
	float scale = 1.0f;
	int octaves = 8;
	float peak_kw = 4.0f;
	float rugosity = 0.0f;
	float angle = 45.0f;
	float gamma = 0.5f;
	float cone_alpha = 1.2f;
	float ridge_amp = 0.4f;
	float base_noise_amp = 0.05f;
	Vector2 center = Vector2(0.5f, 0.5f);
	PackedFloat32Array dx;
	PackedFloat32Array dy;
	PackedFloat32Array envelope;

	static MountainConeParams from_dict(const Dictionary &p_dict);
};

struct MountainInselbergParams {
	int seed = 0;
	float elevation = 25.0f;
	float scale = 1.0f;
	int octaves = 8;
	float rugosity = 0.0f;
	float angle = 45.0f;
	float gamma = 0.5f;
	float bulk_amp = 0.5f;
	float base_noise_amp = 0.05f;
	Vector2 center = Vector2(0.5f, 0.5f);
	PackedFloat32Array dx;
	PackedFloat32Array dy;

	static MountainInselbergParams from_dict(const Dictionary &p_dict);
};

struct MountainRangeRadialParams {
	int seed = 0;
	float elevation = 25.0f;
	float kw_x = 4.0f;
	float kw_y = 4.0f;
	float half_width = 0.2f;
	float angle_spread_ratio = 0.5f;
	float core_size_ratio = 0.2f;
	Vector2 center = Vector2(0.5f, 0.5f);
	int octaves = 8;
	float weight = 0.7f;
	float persistence = 0.5f;
	float lacunarity = 2.0f;
	PackedFloat32Array ctrl_param;
	PackedFloat32Array dx;
	PackedFloat32Array dy;
	PackedFloat32Array envelope;

	static MountainRangeRadialParams from_dict(const Dictionary &p_dict);
};

struct MountainTibestiParams {
	int seed = 0;
	float elevation = 25.0f;
	float scale = 1.0f;
	int octaves = 8;
	float peak_kw = 4.0f;
	float rugosity = 0.0f;
	float angle = 45.0f;
	float angle_spread_ratio = 0.5f;
	float gamma = 0.5f;
	float bulk_amp = 0.5f;
	float base_noise_amp = 0.05f;
	Vector2 center = Vector2(0.5f, 0.5f);
	PackedFloat32Array dx;
	PackedFloat32Array dy;

	static MountainTibestiParams from_dict(const Dictionary &p_dict);
};

struct MountainStumpParams {
	int seed = 0;
	float elevation = 25.0f;
	float scale = 1.0f;
	int octaves = 8;
	float peak_kw = 4.0f;
	float rugosity = 0.0f;
	float angle = 45.0f;
	float k_smoothing = 0.05f;
	float gamma = 0.5f;
	float ridge_amp = 0.4f;
	float base_noise_amp = 0.05f;
	Vector2 center = Vector2(0.5f, 0.5f);
	PackedFloat32Array dx;
	PackedFloat32Array dy;

	static MountainStumpParams from_dict(const Dictionary &p_dict);
};

struct ShatteredPeakParams {
	int seed = 0;
	float elevation = 25.0f;
	float scale = 1.0f;
	int octaves = 8;
	float peak_kw = 4.0f;
	float rugosity = 0.0f;
	float angle = 45.0f;
	float gamma = 0.5f;
	float bulk_amp = 0.5f;
	float base_noise_amp = 0.05f;
	float k_smoothing = 0.05f;
	Vector2 center = Vector2(0.5f, 0.5f);
	PackedFloat32Array dx;
	PackedFloat32Array dy;

	static ShatteredPeakParams from_dict(const Dictionary &p_dict);
};

struct CalderaParams {
	float elevation = 25.0f;
	float radius = 0.2f;
	float sigma_inner = 0.05f;
	float sigma_outer = 0.15f;
	float z_bottom = 0.2f;
	float noise_r_amp = 0.02f;
	float noise_z_ratio = 0.05f;
	Vector2 center = Vector2(0.5f, 0.5f);
	PackedFloat32Array noise;

	static CalderaParams from_dict(const Dictionary &p_dict);
};

PackedFloat32Array mountain_cone_solve(int p_gw, int p_gh, const Rect2 &p_rect, const MountainConeParams &p_params);
PackedFloat32Array mountain_inselberg_solve(int p_gw, int p_gh, const Rect2 &p_rect, const MountainInselbergParams &p_params);
Array mountain_range_radial_solve(int p_gw, int p_gh, const Rect2 &p_rect, const MountainRangeRadialParams &p_params);
PackedFloat32Array mountain_tibesti_solve(int p_gw, int p_gh, const Rect2 &p_rect, const MountainTibestiParams &p_params);
PackedFloat32Array mountain_stump_solve(int p_gw, int p_gh, const Rect2 &p_rect, const MountainStumpParams &p_params);
PackedFloat32Array shattered_peak_solve(int p_gw, int p_gh, const Rect2 &p_rect, const ShatteredPeakParams &p_params);
PackedFloat32Array caldera_solve(int p_gw, int p_gh, const Rect2 &p_rect, const CalderaParams &p_params);

} // namespace godot

#endif // PASTURE_3D_GEO_PRIMITIVES_H
