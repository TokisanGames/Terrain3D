// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Native Priority-Flood hydrological depression/pit filling (PASTURE3D_SOLVER_NATIVE_ACCELERATION_SPEC.md §4 Phase 2).

#ifndef PASTURE_3D_DEPRESSION_FILLING_H
#define PASTURE_3D_DEPRESSION_FILLING_H

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

// Core Priority-Flood algorithm: raises enclosed topological depressions to their minimum spillway elevation.
PackedFloat32Array priority_flood_fill(const PackedFloat32Array &p_h, int p_gw, int p_gh,
		double p_dx, double p_dz, double p_eps, double p_depth_limit);

// Evaluates the full depression filling filter including amount cross-fade.
PackedFloat32Array depression_filling_solve(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_epsilon_slope, double p_fill_depth_limit, double p_amount);

} // namespace godot

#endif // PASTURE_3D_DEPRESSION_FILLING_H
