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
	float shape_preservation = 2.0f;
	float bank_smoothing = 0.1f;
	float sediment_strength = 0.3f;
	int seed = 0;
	PackedFloat32Array mask;
	PackedFloat32Array dx;
	PackedFloat32Array dy;

	// Stage 2: Sediment Deposition (Deposition / Alluvial flats)
	float deposition_radius = 0.1f;
	float deposition_strength = 0.5f;

	// Stage 3: Fine River Channel Incision (HydraulicStreamLog secondary pass)
	float stream_strength = 0.02f;
	float stream_exp = 0.8f;

	// Stage 4: Post-Processing & Tonal Controls
	bool enable_post_smoothing = false;
	float gain = 1.0f;
	float gamma = 1.0f;
	float mix_factor = 1.0f;

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
