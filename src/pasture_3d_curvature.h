// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Native Curvature / Discrete Laplacian Filter (PASTURE3D_SOLVER_NATIVE_ACCELERATION_SPEC.md §4 Phase 3).

#ifndef PASTURE_3D_CURVATURE_H
#define PASTURE_3D_CURVATURE_H

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace godot {

enum class CurvatureMode {
	CONVEXITY_RIDGE = 0,
	CONCAVITY_VALLEY = 1,
	TOTAL_CURVATURE = 2,
};

PackedFloat32Array curvature_solve(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		CurvatureMode p_mode, int p_radius, double p_contrast);

} // namespace godot

#endif // PASTURE_3D_CURVATURE_H
