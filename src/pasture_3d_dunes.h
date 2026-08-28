// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#pragma once

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

PackedFloat32Array dunes_grid(int p_gw, int p_gh, const Rect2 &p_rect,
		double p_amplitude, double p_wavelength, double p_direction_deg,
		double p_asymmetry, double p_crest_sharpness, double p_wander_amount,
		double p_wander_size, int p_seed);

} // namespace godot
