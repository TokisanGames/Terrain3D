// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#pragma once

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

PackedFloat32Array noise_jordan_grid(int p_gw, int p_gh, const Rect2 &p_rect,
		double p_amplitude, double p_frequency, int p_octaves,
		double p_gain, double p_lacunarity, double p_warp_strength,
		double p_damp_strength, int p_seed);

} // namespace godot
