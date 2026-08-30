// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// DistanceTransform — distance from each cell to the nearest "inside" cell of a thresholded mask.
// PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md §5.1.
//
// Jump flooding, NOT the exact Meijster transform. Meijster is exact but its scan is sequential, so a GPU
// port would have to be a different algorithm and CPU and GPU would then disagree by more than rounding —
// and because the GPU route is threshold-gated, the same terrain would come out differently at 128² and
// 256². JFA parallelises, so the CPU kernel, the compute shader and the GDScript oracle all run the same
// algorithm and agree by construction. The gate keeps a Meijster implementation as ground truth (DF).
//
// DISTANCES ARE METRES. Each candidate is measured with the world cell size from p_rect, never in grid
// cells — see spec §3.5 and the Salève bug this project already paid for once.

#ifndef PASTURE_3D_DISTANCE_TRANSFORM_H
#define PASTURE_3D_DISTANCE_TRANSFORM_H

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

// Sync with Pasture3DGraphNodeDistanceTransform.Direction.
enum DistanceTransformDirection {
	DISTANCE_TRANSFORM_OUTSIDE = 0,
	DISTANCE_TRANSFORM_INSIDE = 1,
	DISTANCE_TRANSFORM_SIGNED = 2,
};

// Sync with Pasture3DGraphNodeDistanceTransform.Metric.
enum DistanceTransformMetric {
	DISTANCE_TRANSFORM_EUCLIDEAN = 0,
	DISTANCE_TRANSFORM_MANHATTAN = 1,
	DISTANCE_TRANSFORM_CHEBYSHEV = 2,
};

// Sync with Pasture3DGraphNodeDistanceTransform.OutputUnits.
enum DistanceTransformUnits {
	DISTANCE_TRANSFORM_METRES = 0,
	DISTANCE_TRANSFORM_NORMALISED = 1,
};

// Returns a grid of p_gw * p_gh distances. p_max_distance <= 0 means unbounded; in NORMALISED mode it is
// the divisor, and when it is 0 the divisor is the field's own maximum.
//
// r_divisor_used receives the divisor actually applied (1.0 in METRES mode). A normalised field whose
// divisor is only printed is not an interface — the node stores this and surfaces it in node_warnings().
PackedFloat32Array distance_transform_solve(const PackedFloat32Array &p_mask, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_threshold, int p_direction, int p_metric, int p_units,
		double p_max_distance, double *r_divisor_used);

} // namespace godot

#endif // PASTURE_3D_DISTANCE_TRANSFORM_H
