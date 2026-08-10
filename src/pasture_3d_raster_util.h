// The two rasteriser primitives Pasture3DSim shares with the spline brushes.
//
// The definitions live in pasture_3d_brush_raster.cpp, where the brushes use them. Sim's loop mask
// (PASTURE3D_SIM_NODE_SPEC.md §5) needs the SAME signed distance field and the SAME falloff-ramp LUT
// read as Pasture3DPlow, so the mask a Sim writes through and the mask a Plow writes through are the
// same shape for the same loop and falloff — a second copy of either would be a second thing to keep
// in sync, and the drift would only show up as a seam.

#pragma once

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include <vector>

namespace godot {

// Signed distance field of a closed world polygon over a grid: fills `r_field` (gw*gh, positive inside
// and negative outside, in metres) and returns the maximum interior distance.
float pasture3d_raster_sdf(const PackedVector2Array &p_poly, double p_min_x, double p_min_z, double p_vs,
		int p_gw, int p_gh, std::vector<float> &r_field);

// Linear read of a 0..1 ramp LUT (empty => analytic smoothstep).
float pasture3d_raster_ramp(const PackedFloat32Array &p_lut, float p_x);

} // namespace godot
