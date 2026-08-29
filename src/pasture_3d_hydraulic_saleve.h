// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

struct HydraulicSaleveParams {
	int iterations = 25;
	float erosion_strength = 0.5f;
	float drainage_exponent = 0.15f;
	float drainage_noise = 0.15f;
	float fine_erosion_strength = 0.05f;
	float shape_preservation = 0.2f;
	float bank_smoothing = 0.1f;
	float sediment_strength = 0.3f;
	int seed = 0;
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
