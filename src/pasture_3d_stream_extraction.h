// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Native Stream Extraction & Flow Routing Solver (PASTURE3D_SOLVER_NATIVE_ACCELERATION_SPEC.md §4 Phase 2).

#ifndef PASTURE_3D_STREAM_EXTRACTION_H
#define PASTURE_3D_STREAM_EXTRACTION_H

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace godot {

struct StreamExtractionResult {
	bool ok = false;
	PackedFloat32Array height;
	PackedFloat32Array channel_mask;
	PackedFloat32Array flow_rate;
	PackedVector3Array stream_points;

	Dictionary to_dict() const;
};

StreamExtractionResult stream_extraction_solve(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_min_catchment_cells, double p_carve_depth,
		double p_channel_width, double p_bank_falloff);

} // namespace godot

#endif // PASTURE_3D_STREAM_EXTRACTION_H
