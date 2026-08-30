// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Transform — affine resample of a height grid in world XZ.
// PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md §4.1.
//
// Grid, not cell: eval_cell hands a node its inputs already evaluated at (wx, wz), so a node cannot ask
// its upstream for a value elsewhere (spec §3.1). This resamples the materialised grid instead.

#ifndef PASTURE_3D_TRANSFORM_H
#define PASTURE_3D_TRANSFORM_H

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/vector2.hpp>

namespace godot {

// Sync with Pasture3DGraphNodeTransform.EdgeMode.
enum TransformEdgeMode {
	TRANSFORM_EDGE_CLAMP = 0,
	TRANSFORM_EDGE_ZERO = 1,
	TRANSFORM_EDGE_WRAP = 2,
};

// Resample p_surface at inverse-transformed cell centres. Returns a grid of p_gw * p_gh, or an
// empty-sized grid when the input size disagrees with the requested grid.
PackedFloat32Array transform_solve(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, const Vector2 &p_offset, double p_rotation_deg, double p_scale,
		const Vector2 &p_pivot, int p_edge_mode, double p_amount);

} // namespace godot

#endif // PASTURE_3D_TRANSFORM_H
