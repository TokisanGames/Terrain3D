// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Native Lake Flooding & Shoreline Solver (PASTURE3D_SOLVER_NATIVE_ACCELERATION_SPEC.md §4 Phase 2).

#ifndef PASTURE_3D_LAKE_FLOODING_H
#define PASTURE_3D_LAKE_FLOODING_H

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace godot {

enum class LakeFloodMode {
	SPILLWAY_BASIN = 0,
	GLOBAL_ELEVATION = 1,
};

struct LakeFloodingResult {
	bool ok = false;
	PackedFloat32Array height;
	PackedFloat32Array water_depth;
	PackedFloat32Array shoreline;
	TypedArray<PackedVector2Array> contours;

	Dictionary to_dict() const;
};

LakeFloodingResult lake_flooding_solve(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, LakeFloodMode p_mode, double p_water_elevation,
		double p_flood_percent, double p_shoreline_width);

} // namespace godot

#endif // PASTURE_3D_LAKE_FLOODING_H
