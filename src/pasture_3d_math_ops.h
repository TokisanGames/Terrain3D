// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#pragma once

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

enum GraphMaskProperty {
	GRAPH_MASK_SLOPE = 0,
	GRAPH_MASK_ALTITUDE = 1,
	GRAPH_MASK_CURVATURE = 2,
};

PackedFloat32Array curve_grid(const PackedFloat32Array &p_surface, const PackedFloat32Array &p_lut,
		double p_in_min, double p_in_max, double p_out_min, double p_out_max, double p_amount);

PackedFloat32Array remap_grid(const PackedFloat32Array &p_surface,
		double p_in_min, double p_in_max, double p_out_min, double p_out_max,
		bool p_clamp_output, double p_soft_knee, bool p_invert);

PackedFloat32Array mask_grid(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, int p_property, double p_band_min, double p_band_max,
		double p_falloff_lo, double p_falloff_hi, bool p_invert, double p_strength);

} // namespace godot
