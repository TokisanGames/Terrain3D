// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Native Logarithmic Stream-Power Erosion solver (PASTURE3D_EROSION_NODES_EXPANSION_SPEC.md §3.1 Phase 1).
// Computes hydrological drainage flow accumulation and applies non-linear stream-power incision:
// E = K * log(1 + A^m * S^n).

#ifndef PASTURE_3D_HYDRAULIC_STREAM_LOG_H
#define PASTURE_3D_HYDRAULIC_STREAM_LOG_H

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <vector>

namespace godot {

struct HydraulicStreamLogParams {
	int iterations = 15;
	float incision_rate = 0.15f;
	float area_exponent = 0.5f;
	float slope_exponent = 1.0f;
	float min_catchment = 1.0f;
	float bank_smoothing = 0.1f;
	float peak_preservation = 0.5f;
	float gradient_power = 0.8f;
	PackedFloat32Array mask;

	static HydraulicStreamLogParams from_dict(const Dictionary &p_dict);
};

struct HydraulicStreamLogResult {
	bool ok = false;
	PackedFloat32Array height;
	PackedFloat32Array channel_mask;
	PackedFloat32Array flow_accumulation;

	Dictionary to_dict() const;
};

// C++ native Logarithmic Stream Power solver.
// Matches the GDScript Tier 1 oracle bit-for-bit (<= 2e-6 m).
HydraulicStreamLogResult hydraulic_stream_log_solve(const PackedFloat32Array &p_surface,
		int p_gw, int p_gh, const Rect2 &p_rect, const HydraulicStreamLogParams &p_params);

} // namespace godot

#endif // PASTURE_3D_HYDRAULIC_STREAM_LOG_H
