// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#pragma once

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/vector2.hpp>

namespace godot {

enum GeologicalPrimitiveType {
	GEO_PRIMITIVE_INSELBERG = 0,
	GEO_PRIMITIVE_VOLCANIC_CALDERA = 1,
	GEO_PRIMITIVE_CUESTA_BADLANDS = 2,
};

enum GeologicalPrimitiveMapping {
	GEO_MAPPING_FIT_FRAME = 0,
	GEO_MAPPING_METRIC_WORLD = 1,
};

PackedFloat32Array geological_primitive_grid(int p_gw, int p_gh, const Rect2 &p_rect,
		int p_primitive_type, int p_mapping, double p_height, double p_radius,
		double p_eccentricity, double p_steepness, double p_azimuth_degrees,
		const Vector2 &p_center_offset);

} // namespace godot
