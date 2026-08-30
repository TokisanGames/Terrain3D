// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Water nodes — FloodingUniformLevel (§8.1) and WaterMask (§8.2).
// PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md.
//
// Neither of these spawns a Pasture3DPond. LakeFlooding owns that relationship, and two nodes racing to
// create water bodies is a bug factory. These produce FIELDS — a height, a depth, a couple of masks — and
// what a host does with them is the host's business.

#ifndef PASTURE_3D_WATER_NODES_H
#define PASTURE_3D_WATER_NODES_H

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

// Sync with Pasture3DGraphNodeWaterMask.ShoreFalloff.
enum WaterShoreFalloff {
	WATER_SHORE_LINEAR = 0,
	WATER_SHORE_SMOOTH = 1,
};

// Clamp the surface up to a uniform world-Y water level. Pointwise: this is deliberately NOT a solver.
// LakeFlooding finds basins and spillways; this is the cheap path for an author who just wants a sea.
//
// Writes `r_depth` (max(level - z, 0), metres) and `r_mask` (1 where flooded) when those pointers are
// non-null. When p_clamp_terrain is false the returned height is a bit-exact copy of the input and only
// the two derived channels are produced.
PackedFloat32Array flooding_uniform_level_solve(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		double p_level, bool p_clamp_terrain, PackedFloat32Array *r_depth, PackedFloat32Array *r_mask);

// The submerged mask, plus the shore band within p_shore_width_m of the waterline ON EITHER SIDE.
//
// The band comes from running the SIGNED distance transform (§5.1) against the water mask and windowing
// |d| < width. It calls the native distance routine; there is deliberately no second distance
// implementation here, because two of them would be two chances to disagree about what a metre is.
PackedFloat32Array water_mask_solve(const PackedFloat32Array &p_depth, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_depth_threshold, double p_shore_width_m, int p_shore_falloff,
		PackedFloat32Array *r_shore);

} // namespace godot

#endif // PASTURE_3D_WATER_NODES_H
