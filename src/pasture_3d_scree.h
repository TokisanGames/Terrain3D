// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#pragma once

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

Array scree_solve_grid(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_amplitude, double p_grain_size,
		double p_downslope_streak, double p_toe_deposition, double p_min_slope_deg,
		double p_slope_falloff_deg, int p_seed);

} // namespace godot
