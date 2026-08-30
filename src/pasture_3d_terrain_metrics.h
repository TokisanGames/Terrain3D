// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Phase 3 — terrain metrics and structural shaping.
// PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md §6.
//
// Three kernels that all measure the terrain against a LOCAL reference rather than an absolute one:
//   RelativeElevation — where a cell sits between its local basin floor and its local crest
//   SmoothFill        — raise concave ground toward a blurred reference, leaving ridges alone
//   RecastCliff       — push already-steep ground toward a stepped face, leaving gentle ground alone
//
// All radii are WORLD METRES. All slopes are metric gradients (metres per metre), never per-cell rises.

#ifndef PASTURE_3D_TERRAIN_METRICS_H
#define PASTURE_3D_TERRAIN_METRICS_H

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

// Sync with Pasture3DGraphNodeRelativeElevation.OutputUnits.
enum RelativeElevationUnits {
	RELATIVE_ELEVATION_NORMALISED = 0, // 0 on the local basin floor, 1 on the local crest
	RELATIVE_ELEVATION_METRES = 1, // metres above the local basin floor
};

// Sync with Pasture3DGraphNodeSmoothFill.Mode.
enum SmoothFillMode {
	SMOOTH_FILL_VALLEYS = 0,
	SMOOTH_FILL_HOLES = 1,
	SMOOTH_FILL_SMEAR_PEAKS = 2,
};

// Separable box mean over a metric radius, shared by SmoothFill and RecastCliff.
//
// Deliberately two 1D passes of DIRECT gathers rather than an incremental running sum. A running sum is
// O(1) per cell instead of O(w), but it accumulates and cancels in a different order than a GPU gather
// can, and the two would then disagree by more than float32 rounding on large radii. Matching the GPU
// exactly is worth more here than the constant factor.
PackedFloat32Array box_mean_solve(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_radius_m);

PackedFloat32Array relative_elevation_solve(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_radius_m, int p_units);

// Writes the deposition channel (metres added, before normalisation) into r_deposition when non-null,
// and the divisor used to normalise it into r_deposition_divisor. The divisor is part of the interface
// for the same reason it is on DistanceTransform: a normalised channel without it is not reproducible.
PackedFloat32Array smooth_fill_solve(const PackedFloat32Array &p_surface, const PackedFloat32Array &p_mask,
		int p_gw, int p_gh, const Rect2 &p_rect, int p_mode, double p_radius_m, double p_k,
		double p_amount, PackedFloat32Array *r_deposition, double *r_deposition_divisor);

PackedFloat32Array recast_cliff_solve(const PackedFloat32Array &p_surface, const PackedFloat32Array &p_mask,
		int p_gw, int p_gh, const Rect2 &p_rect, double p_talus_angle_deg, double p_radius_m,
		double p_amplitude, double p_gain, double p_direction_deg, double p_direction_spread_deg,
		double p_amount);

} // namespace godot

#endif // PASTURE_3D_TERRAIN_METRICS_H
