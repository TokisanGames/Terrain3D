// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Native Geological Primitives solver (MountainCone, MountainInselberg) ported from Hesiod/HighMap.
// Generates multi-octave cellular Voronoi knife-edge ridges, strike-angle domain warping,
// and sigmoid / Gaussian pulse envelopes.

#ifndef PASTURE_3D_GEO_PRIMITIVES_H
#define PASTURE_3D_GEO_PRIMITIVES_H

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/vector2.hpp>

namespace godot {

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

PackedFloat32Array mountain_cone_solve(int p_gw, int p_gh, const Rect2 &p_rect, const MountainConeParams &p_params);
PackedFloat32Array mountain_inselberg_solve(int p_gw, int p_gh, const Rect2 &p_rect, const MountainInselbergParams &p_params);

} // namespace godot

#endif // PASTURE_3D_GEO_PRIMITIVES_H
