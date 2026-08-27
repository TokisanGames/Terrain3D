// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Native 3-Band Spatial Spectral Equalizer (PASTURE3D_SOLVER_NATIVE_ACCELERATION_SPEC.md §4 Phase 3).

#ifndef PASTURE_3D_SPECTRAL_EQUALIZER_H
#define PASTURE_3D_SPECTRAL_EQUALIZER_H

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace godot {

PackedFloat32Array spectral_equalizer_solve(const PackedFloat32Array &p_surface,
		const PackedFloat32Array &p_mask, int p_gw, int p_gh,
		double p_macro_gain, double p_meso_gain, double p_micro_gain,
		int p_macro_passes, int p_meso_passes, double p_amount);

} // namespace godot

#endif // PASTURE_3D_SPECTRAL_EQUALIZER_H
