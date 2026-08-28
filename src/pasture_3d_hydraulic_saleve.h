// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

struct HydraulicSaleveParams {
	int iterations = 20;
	float incision_rate = 0.2f;
	float joint_azimuth = 45.0f;
	float joint_strength = 0.4f;
	float ridge_preservation = 0.8f;
	float deposition_rate = 0.3f;
	float bank_smoothing = 0.1f;
	PackedFloat32Array mask;

	static HydraulicSaleveParams from_dict(const Dictionary &p_dict);
};

struct HydraulicSaleveResult {
	bool ok = false;
	PackedFloat32Array height;
	PackedFloat32Array eroded_rock;
	PackedFloat32Array sediment;

	Dictionary to_dict() const;
};

HydraulicSaleveResult hydraulic_saleve_solve(const PackedFloat32Array &p_surface,
		int p_gw, int p_gh, const Rect2 &p_rect, const HydraulicSaleveParams &p_params);

} // namespace godot
