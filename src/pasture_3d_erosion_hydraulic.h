// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Native Hydraulic Erosion solver (PASTURE3D_SOLVER_NATIVE_ACCELERATION_SPEC.md §4 Phase 1).
// Simulates continuous rainfall, downhill water routing, slope-limited sediment capacity, erosion pickup,
// sediment transport, deposition, and evaporation over an elevation heightfield.

#ifndef PASTURE_3D_EROSION_HYDRAULIC_H
#define PASTURE_3D_EROSION_HYDRAULIC_H

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <vector>

namespace godot {

struct ErosionHydraulicParams {
	int iterations = 25;
	float rain_rate = 0.05f;
	float evaporation_rate = 0.02f;
	float sediment_capacity = 8.0f;
	float erosion_speed = 0.5f;
	float deposition_speed = 0.4f;
	float min_slope = 0.01f;

	static ErosionHydraulicParams from_dict(const Dictionary &p_dict);
};

struct ErosionHydraulicResult {
	bool ok = false;
	PackedFloat32Array height;
	PackedFloat32Array sediment;
	PackedFloat32Array flow;

	Dictionary to_dict() const;
};

// C++ native hydrodynamic shallow-water solver.
// Matches the GDScript Tier 1 oracle bit-for-bit (<= 2e-6 m).
ErosionHydraulicResult erosion_hydraulic_solve(const PackedFloat32Array &p_surface,
		int p_gw, int p_gh, const Rect2 &p_rect, const ErosionHydraulicParams &p_params);

} // namespace godot

#endif // PASTURE_3D_EROSION_HYDRAULIC_H
