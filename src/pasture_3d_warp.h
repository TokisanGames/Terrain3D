// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Native Warp Coordinate Distortion Evaluator (PASTURE3D_SOLVER_NATIVE_ACCELERATION_SPEC.md §4 Phase 3).

#ifndef PASTURE_3D_WARP_H
#define PASTURE_3D_WARP_H

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace godot {

enum class WarpNoiseType {
	SIMPLEX = 0,
	FRACTAL = 1,
};

PackedFloat32Array warp_solve_grid(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, WarpNoiseType p_type, double p_frequency, double p_strength,
		int p_octaves, double p_amplitude, double p_roughness, int p_seed);

} // namespace godot

#endif // PASTURE_3D_WARP_H
