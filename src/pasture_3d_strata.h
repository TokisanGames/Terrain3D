// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#pragma once

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

PackedFloat32Array strata_grid(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_band_height, double p_hardness,
		double p_amount, double p_dip, double p_dip_direction_deg,
		double p_break_amount, double p_break_size, int p_seed);

} // namespace godot
