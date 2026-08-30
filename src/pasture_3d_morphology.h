// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// ExpandShrink — grayscale morphology (dilation / erosion and their compositions).
// PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md §5.2.
//
// Six Hesiod nodes fused into one mode enum, because Dilation, Erosion, Opening, Closing and
// MorphologicalGradient are all the same separable min/max kernel with a different composition.
//
// The mode is SHRINK, not "Erosion". The graph already has five nodes with Erosion in the name and every
// one of them is a geological simulation; a morphological erosion sharing that word in the palette is a
// usability trap, not a naming quibble.
//
// RADIUS IS METRES, converted to a cell count from p_rect. The same world radius must grow a mask by the
// same world distance at 129² and at 257² — that is the ExpandShrink form of the Salève bug.

#ifndef PASTURE_3D_MORPHOLOGY_H
#define PASTURE_3D_MORPHOLOGY_H

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

// Sync with Pasture3DGraphNodeExpandShrink.Mode.
enum MorphologyMode {
	MORPHOLOGY_EXPAND = 0, // grayscale dilation — local maximum
	MORPHOLOGY_SHRINK = 1, // grayscale erosion — local minimum
	MORPHOLOGY_OPEN = 2, // shrink then expand — removes features smaller than the radius
	MORPHOLOGY_CLOSE = 3, // expand then shrink — fills gaps smaller than the radius
	MORPHOLOGY_GRADIENT = 4, // expand minus shrink — the morphological edge
};

// Sync with Pasture3DGraphNodeExpandShrink.Kernel.
enum MorphologyKernel {
	MORPHOLOGY_KERNEL_DISC = 0,
	MORPHOLOGY_KERNEL_SQUARE = 1,
};

// p_mask is the per-cell blend weight between input and result; pass an empty array for "fully applied".
PackedFloat32Array expand_shrink_solve(const PackedFloat32Array &p_surface,
		const PackedFloat32Array &p_mask, int p_gw, int p_gh, const Rect2 &p_rect, int p_mode,
		double p_radius_m, int p_kernel, int p_iterations, double p_amount);

} // namespace godot

#endif // PASTURE_3D_MORPHOLOGY_H
