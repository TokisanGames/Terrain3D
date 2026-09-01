// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// The road grader in C++ (PASTURE3D_GRAPH_GEOMETRY_PORTS_SPEC.md §5.2, P2a).
//
// ---- WHAT THIS IS THE NATIVE HALF OF ----
//
// Pasture3DRoadGrader.grade_reference (project/addons/pasture_3d/roads/pasture3d_road_grader.gd) is the
// GDScript reference and the oracle. This is the same kernel in C++, and after this port there is exactly
// ONE grader in production: Pasture3DRoadGrader.grade forwards here, so the brush's own step and the graph's
// Road Grade node cut identically-shaped earth by construction rather than by agreement. RoadGate [K]'s
// 0.0000 m — brush and graph producing the same surface — was previously a claim about two
// implementations staying in step; it is now a claim about one.
//
// ---- WHY THE ALIGNMENT ARRIVES AS FOUR NUMBERS AND NOT AS A RESOURCE ----
//
// Pasture3DRoadAlignment is a GDScript Resource, and a kernel that took one would be a kernel that could
// only be called from the editor. Everything the grade actually reads out of it is uniform sampling: `ds`,
// `s0`, the solved heights and the bank ratios. `index_at` and `height_at` are arithmetic on those four,
// reproduced here rather than called across the boundary — which is also what lets this run on a thread.
//
// ---- THE ONE PLACE THE PORT IS NOT A TRANSCRIPTION ----
//
// The reference walks every segment for every cell, and says in its own comment that it does so
// deliberately, so that an A/B against this file compares two backends and not two algorithms. This file
// uses Pasture3DPathGeom's bucket index for the same query. That is the whole speed difference, and it is
// safe precisely because RoadNativeParityGate [A]-[C] already measured the indexed query against the
// brute-force one on a doubling-back fixture.
//
// The SIDE sign is the exception, and it is computed here rather than taken from the query's `t`: the
// reference uses signf, which is 0 for a point exactly collinear with a segment, while the query resolves
// the same case to the right. The two differ only on a measure-zero set, and matching the reference
// exactly costs one line.

#ifndef PASTURE_3D_ROAD_GRADE_H
#define PASTURE_3D_ROAD_GRADE_H

#include "pasture_3d_path_query.h"

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

namespace godot {

// Cells whose height moved by less than this are untouched. MUST match
// Pasture3DRoadGrader.EARTHWORK_EPSILON — it decides what the cut and fill masks call earthworks.
constexpr double ROAD_EARTHWORK_EPSILON = 0.001;

// The road surface at signed across-distance `p_u`. THE PROFILE, DEFINED ONCE: the mesher draws the ribbon
// this describes and the grader carves the ground under it, so a millimetre of disagreement would z-fight
// along the whole road. Positive `p_u` is the driver's right; `p_crown` is a function of |u| so both edges
// come out level with each other.
inline double road_surface_height(double p_centre, double p_bank, double p_crown, double p_u) {
	return p_centre + p_bank * p_u - p_crown * (p_u < 0.0 ? -p_u : p_u);
}

// Grade a heightfield around one road. `p_height` is row-major p_gw * p_gh in METRES and may contain NaN
// for cells outside the brush's own loop — those pass through untouched, which is what keeps the
// brush-loop boundary contract intact.
//
// The per-sample arrays (`p_half_width`, `p_shoulder`, `p_verge`, `p_suppress`, and `skip` in p_opts) are
// indexed by ALIGNMENT sample, so a width that changes partway along the run is just a different value at
// a different index. A true `p_suppress[i]` reports itself in the structure mask and leaves the ground
// alone: a bridge deck carries the road, and grading under it would build the earth dam across the valley
// the bridge exists to avoid. `skip` is NOT the same thing — it must leave no trace at all, because it
// means "this arc length belongs to a junction", and marking it as a deck would put a viaduct at every
// crossroads.
//
// p_opts: crown, cut_batter, fill_batter, surface_fade, skip (PackedByteArray).
// Returns { ok, height, roadbed, cut, fill, verge, structure, surface }.
Dictionary road_grade_grid(const PackedFloat32Array &p_height, int p_gw, int p_gh, double p_min_x,
		double p_min_z, double p_vs, const PackedVector2Array &p_plan, double p_align_ds,
		double p_align_s0, const PackedFloat32Array &p_align_z, const PackedFloat32Array &p_align_bank,
		const PackedFloat32Array &p_half_width, const PackedFloat32Array &p_shoulder,
		const PackedFloat32Array &p_verge, const PackedByteArray &p_suppress, const Dictionary &p_opts);

// The same grading against an ALREADY-BUILT plan geometry (P2c). The graph evaluator indexes a road once
// for the whole bake and hands the same Pasture3DPathGeom to every slot that names it; the entry point
// above is this function with a build in front of it. An empty geometry passes the surface through, which
// is the §4.3 answer and the only safe one — zeros would flatten the terrain to sea level.
Dictionary road_grade_grid_geom(const Pasture3DPathGeom &p_geom, const PackedFloat32Array &p_height,
		int p_gw, int p_gh, double p_min_x, double p_min_z, double p_vs, double p_align_ds,
		double p_align_s0, const PackedFloat32Array &p_align_z, const PackedFloat32Array &p_align_bank,
		const PackedFloat32Array &p_half_width, const PackedFloat32Array &p_shoulder,
		const PackedFloat32Array &p_verge, const PackedByteArray &p_suppress, const Dictionary &p_opts);

// ---- Pasture3DRoadAlignmentSolver in C++ ----
Dictionary road_align_solve(const PackedFloat32Array &p_ground, double p_ds, double p_max_grade,
		const Dictionary &p_opts);

PackedFloat32Array road_plan_curvature(const PackedVector2Array &p_plan);

PackedFloat32Array road_superelevation(const PackedFloat32Array &p_curvature, double p_design_speed,
		double p_max_superelevation, double p_ds, double p_transition_length = 25.0);

Dictionary road_align_solve_with_plan(const PackedVector2Array &p_plan, const PackedFloat32Array &p_ground,
		double p_ds, double p_max_grade, double p_design_speed, double p_max_superelevation,
		const Dictionary &p_opts);

} // namespace godot

#endif // PASTURE_3D_ROAD_GRADE_H
