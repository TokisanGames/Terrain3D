// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Native Thermal Erosion & Talus Projection Solvers (PASTURE3D_SOLVER_NATIVE_ACCELERATION_SPEC.md §4 Phase 3).

#ifndef PASTURE_3D_EROSION_THERMAL_H
#define PASTURE_3D_EROSION_THERMAL_H

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace godot {

struct ErosionThermalResult {
	bool ok = false;
	PackedFloat32Array height;
	PackedFloat32Array talus;

	Dictionary to_dict() const;
};

// Thermal erosion solver with slope slippage and hardness modulation.
ErosionThermalResult erosion_thermal_solve(const PackedFloat32Array &p_surface,
		const PackedFloat32Array &p_hardness, int p_gw, int p_gh, const Rect2 &p_rect,
		double p_talus_angle_deg, int p_iterations, double p_settling_rate);

// Angle-of-repose talus projection filter with volume conservation.
PackedFloat32Array talus_projection_solve(const PackedFloat32Array &p_surface,
		const PackedFloat32Array &p_mask, int p_gw, int p_gh, const Rect2 &p_rect,
		double p_talus_angle_deg, int p_iterations, double p_transfer_rate, double p_amount);

} // namespace godot

#endif // PASTURE_3D_EROSION_THERMAL_H
