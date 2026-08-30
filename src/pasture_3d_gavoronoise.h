// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Gavoronoise — a gradient-aware Voronoi generator.
// PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md §7.2.
//
// Clean-room, per spec §2: rederived from the published "gradient-aware Voronoi" idea, not ported from
// HighMap. The derivative-feedback scaffold is the one already used by noise_jordan, applied to a
// CELLULAR base instead of a gradient-noise one — which is the whole point, because FastNoiseLite's
// cellular mode gives the distance field but no gradient feedback, and the feedback is what turns
// isotropic cell blobs into branching ridgelines.
//
// THE ALGORITHM IS DEFINED HERE, ONCE. It has three implementations that must agree bit-for-bit within
// their float widths: this file, the mode-18 shader in pasture_3d_graph_gpu.cpp, and the GDScript oracle
// in pasture3d_graph_node_dev_gavoronoise.gd. Everything below that a reader might think is an arbitrary
// choice is load-bearing for that agreement:
//
//   * The hash is INTEGER (uint32) arithmetic, not a sin/fract trick. GLSL, C++ and GDScript all agree
//     exactly on uint32 multiply-xor-shift; they do NOT agree on the low bits of sin(). The result is
//     taken from 24 bits so the float conversion is exact in all three.
//   * The Voronoi derivative is ANALYTIC, not a central difference. For F1 distance the gradient is the
//     unit vector from the winning feature point to the sample, which is exact and one line — where a
//     central difference would need four extra cell searches per octave and would introduce an `eps`
//     that all three implementations would have to agree on.
//   * `angle_spread` COMPRESSES the along-strike axis before the cell lookup, so the Voronoi cells become
//     elongated ribbons running along strike. At 1 they are isotropic; as it falls toward 0 they stretch
//     until the field is a function of the across-strike coordinate alone — parallel ridges. Jittering the
//     feature points across strike instead (the obvious first idea) does NOT do this: a row of points at
//     a fixed z still produces a field that varies in x, so the ridges are not parallel and the gate's
//     anisotropy measure correctly refuses it.

#ifndef PASTURE_3D_GAVORONOISE_H
#define PASTURE_3D_GAVORONOISE_H

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

// p_frequency is CYCLES PER METRE, so the same world rect gives the same ridge spacing in metres at any
// grid resolution. p_amplitude is metres. p_z_cut_min / p_z_cut_max window the normalised field before
// the amplitude scale.
PackedFloat32Array gavoronoise_grid(int p_gw, int p_gh, const Rect2 &p_rect, double p_amplitude,
		double p_frequency, int p_octaves, int p_seed, double p_angle_deg, double p_angle_spread,
		double p_slope_strength, double p_branch_strength, double p_z_cut_min, double p_z_cut_max);

} // namespace godot

#endif // PASTURE_3D_GAVORONOISE_H
