// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#pragma once

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

// Sync with Pasture3DGraphNodeFalloff.Shape.
enum GraphFalloffShape {
	GRAPH_FALLOFF_RADIAL = 0,
	GRAPH_FALLOFF_SQUARE = 1,
	GRAPH_FALLOFF_AXIS_X = 2,
	GRAPH_FALLOFF_AXIS_Z = 3,
};

// Sync with Pasture3DGraphNodeContrast.Mode.
enum GraphContrastMode {
	GRAPH_CONTRAST_GAIN = 0,
	GRAPH_CONTRAST_GAMMA = 1,
};

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

// Falloff (spec §4.2). Distance is measured in WORLD METRES from p_centre, never in grid fractions.
// p_noise is an optional per-cell distance perturbation grid; pass an empty array for none.
PackedFloat32Array falloff_grid(const PackedFloat32Array &p_surface, const PackedFloat32Array &p_noise,
		int p_gw, int p_gh, const Rect2 &p_rect, int p_shape, double p_centre_x, double p_centre_z,
		double p_radius, double p_feather, double p_strength, bool p_invert, double p_distance_noise);

// Contrast (spec §4.3). Gain / gamma on a height WINDOW, because Pasture3D heights are metres and a raw
// pow() on a metre value is meaningless (and NaN for negative terrain).
// `p_explicit_window` false = auto-window to the surface's own finite min/max for this call (the default
// authoring mode); true = use p_range_min/p_range_max verbatim, in metres.
PackedFloat32Array contrast_grid(const PackedFloat32Array &p_surface, const PackedFloat32Array &p_mask,
		int p_mode, double p_amount, double p_range_min, double p_range_max, double p_mask_amount,
		bool p_explicit_window);

PackedFloat32Array mask_grid(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, int p_property, double p_band_min, double p_band_max,
		double p_falloff_lo, double p_falloff_hi, bool p_invert, double p_strength);

} // namespace godot
