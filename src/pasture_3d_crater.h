// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#pragma once

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

PackedFloat32Array crater_grid(int p_gw, int p_gh, const Rect2 &p_rect,
		double p_amplitude, double p_floor_depth, double p_rim_height,
		double p_rim_width, double p_ejecta_falloff, double p_floor_flatness,
		int p_terrace_steps);

} // namespace godot
