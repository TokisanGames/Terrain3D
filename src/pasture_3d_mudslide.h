// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Mudslide — move a FINITE, MASKABLE quantity of material downhill as a discrete event.
// PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md §8.3.
//
// Not a duplicate of TalusProjection or ErosionThermal, and the difference is not a matter of degree.
// Those relax slope EVERYWHERE until the whole surface sits at its angle of repose; there is no budget and
// nothing to run out of. This starts with a specific depth of mobile material on a specific hillside,
// moves it, and stops when it is spent. It is the node for one scar, not for global weathering.
//
// DELTA-ACCUMULATED, not an in-place scatter (spec §3.7). Every sweep fills a delta buffer for all cells
// and applies it in a second pass. An in-place scatter would be order-dependent, and a GPU dispatch has no
// defined cell order — writing it that way would foreclose the GPU path before it was ever attempted.
// Volume conservation is then exact by construction: every transfer subtracts from one cell and adds the
// same amount to another, so it is a property of the code's shape rather than something to test for and
// hope.

#ifndef PASTURE_3D_MUDSLIDE_H
#define PASTURE_3D_MUDSLIDE_H

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

// p_travel_distance_m is how far down the hill the slide runs, in WORLD METRES.
//
// The spec proposed an `iterations` count here. An iteration count is a CELL-SPACE quantity — a
// nearest-neighbour sweep advances material about one cell — so twenty iterations means eighty metres on a
// 4 m grid and twenty metres on a 1 m one, and the same slide would reach different places at different
// bake resolutions. That is precisely the class of unit error §3.6 exists to catch, so the author-facing
// knob is metric and the sweep count is derived from it.
//
// p_mask may be empty; when it is, the mobile material is placed on every cell steeper than the talus
// angle instead. Writes the deposition delta (metres, signed) to r_deposition when non-null.
PackedFloat32Array mudslide_solve(const PackedFloat32Array &p_surface, const PackedFloat32Array &p_mask,
		int p_gw, int p_gh, const Rect2 &p_rect, double p_talus_angle_deg, double p_depth_m,
		double p_travel_distance_m, double p_depth_exponent, double p_viscosity_power, double p_amount,
		PackedFloat32Array *r_deposition, double *r_deposition_divisor);

} // namespace godot

#endif // PASTURE_3D_MUDSLIDE_H
