// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// WarpDownslope — displace the surface ALONG its own gradient.
// PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md §7.1.
//
// The distinction from the noise Warp node is the whole point. Noise warp pushes terrain in directions
// that have nothing to do with the terrain; this pushes it downhill, which is the direction material
// actually travels. It is the cheap middle rung between "no erosion" and "freeze an erosion solve".

#ifndef PASTURE_3D_WARP_DOWNSLOPE_H
#define PASTURE_3D_WARP_DOWNSLOPE_H

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

// Resample p_surface at each cell displaced p_displacement_m metres along the local downslope direction,
// where "local" means the gradient of the surface smoothed over p_radius_m. Cells whose gradient is below
// an epsilon do not move at all, so a flat plane is returned bit-identical.
//
// p_mask may be empty; when supplied it scales the displacement per cell.
PackedFloat32Array warp_downslope_solve(const PackedFloat32Array &p_surface,
		const PackedFloat32Array &p_mask, int p_gw, int p_gh, const Rect2 &p_rect,
		double p_displacement_m, double p_radius_m, bool p_reverse, double p_amount);

} // namespace godot

#endif // PASTURE_3D_WARP_DOWNSLOPE_H
