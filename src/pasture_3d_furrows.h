// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#pragma once

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

enum FurrowsProfile {
	FURROWS_PROFILE_V = 0,
	FURROWS_PROFILE_U = 1,
	FURROWS_PROFILE_SQUARE = 2,
};

PackedFloat32Array furrows_grid(int p_gw, int p_gh, const Rect2 &p_rect,
		double p_amplitude, double p_spacing, double p_direction_deg,
		int p_profile, double p_wobble_amount, double p_wobble_size, int p_seed);

} // namespace godot
