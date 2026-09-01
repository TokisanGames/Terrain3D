// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Native PATH geometry and the analytic nearest-point query
// (PASTURE3D_GRAPH_GEOMETRY_PORTS_SPEC.md §5.1-5.2, P2a).
//
// ---- WHAT THIS IS THE NATIVE HALF OF ----
//
// Pasture3DGraphPath (project/addons/pasture_3d/graph/pasture3d_graph_path.gd) is the GDScript reference
// implementation and the oracle: a world-space polyline with a half-width at every vertex, answering
// `distance` / `s` / `t` for any point. This is the same query in C++.
//
// It is a port of an ALGORITHM, not of a file. Three details are copied exactly because the two must
// agree cell for cell, and each one changes the answer rather than only the speed:
//
//   * INDEX_MIN_SEGMENTS = 5. Below it the GDScript builds no index and tests every segment. Kept so a
//     small fixture exercises the same path in both, and because building buckets for four segments costs
//     more than checking four segments.
//   * cell = max(total_length / segment_count, 0.5) and origin = the min corner of the point bounds. The
//     bucket geometry decides which segments a query LOOKS at, and the ring stopping rule is only correct
//     against the cell size that built the buckets.
//   * The ring stop is `best <= ring * cell`, one ring later than the strict bound. Getting this wrong
//     returns a wrong NEAREST SEGMENT on a path that doubles back, which is silent: the distance stays
//     plausible and only `s` is absurd. The GDScript says the same thing at more length; do not tighten it
//     here without tightening it there, and vice versa.
//
// ---- WHY A DENSE CSR INDEX RATHER THAN A HASH ----
//
// The GDScript uses a Dictionary keyed by Vector2i because that is what GDScript has. Here the bucket grid
// is a dense CSR (bucket_start + bucket_items) over the path's bounding box. Same buckets, same contents,
// same candidate sets — only the lookup differs, and a lookup cannot change an answer. Dense costs one int
// per empty bucket, and the grid is sized by the path's own extent rather than the terrain's, so a road
// crossing a 4 km terrain does not allocate 4 km of buckets.
//
// Read-only after `build`, and every query is independent, so one Pasture3DPathGeom is shared across every
// worker thread and every slot naming it — the fanout property §4.2 of the spec is about.

#ifndef PASTURE_3D_PATH_QUERY_H
#define PASTURE_3D_PATH_QUERY_H

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

#include <vector>

namespace godot {

// Below this many segments, no index is built and every query is brute force. MUST match
// Pasture3DGraphPath.INDEX_MIN_SEGMENTS.
constexpr int PATH_INDEX_MIN_SEGMENTS = 5;

// One nearest-point answer. `segment` is -1 for an empty path, which is the caller's cue that `distance`
// is meaningless rather than merely large.
struct Pasture3DPathHit {
	double distance = 0.0;
	double s = 0.0;
	double t = 0.0;
	int segment = -1;
};

// A polyline with a per-vertex half-width, plus the segment index the query walks.
struct Pasture3DPathGeom {
	std::vector<float> px, pz; // vertices, world metres
	std::vector<float> width; // half-width per vertex; empty means 1.0 everywhere
	std::vector<double> cum; // cumulative arc length, prefix-summed once in build()
	bool closed = false;

	// Uniform bucket index over the path's own bounds. Empty when segment_count() < the minimum.
	double cell = 0.0;
	double ox = 0.0, oz = 0.0;
	int bw = 0, bh = 0; // bucket grid dimensions
	int max_ring = 0;
	std::vector<int> bucket_start; // size bw*bh + 1, CSR offsets
	std::vector<int> bucket_items; // segment ids

	int segment_count() const { return px.size() >= 2 ? (int)px.size() - 1 : 0; }
	bool is_empty() const { return segment_count() == 0; }
	double length() const { return cum.empty() ? 0.0 : cum.back(); }

	// Flatten a PATH into this struct and build the index. False (and the struct left empty) for fewer
	// than two points, which is a normal state — an unresolved Road Source — and never an error.
	bool build(const PackedVector2Array &p_points, const PackedFloat32Array &p_widths);

	// Half-width at arc length `p_s`, interpolated between the vertices either side. 1.0 when the path
	// carries no widths, which makes `t` read as signed METRES — the useful degenerate case.
	double half_width_at(double p_s) const;

	// The nearest point on the polyline. `r_scratch` is a per-thread candidate buffer reused across cells
	// so a grid query allocates nothing in its inner loop.
	Pasture3DPathHit nearest(double p_x, double p_z, std::vector<int> &r_scratch) const;

	// The same query with NO index: every segment, every time. The DEFINITION the indexed query has to
	// match, kept in production for the same reason the GDScript keeps `nearest_brute` — a definition that
	// lives only in a gate drifts from the thing it defines.
	Pasture3DPathHit nearest_brute(double p_x, double p_z) const;

private:
	Pasture3DPathHit resolve(double p_x, double p_z, const int *p_cand, int p_count) const;
	double segment_distance(int p_seg, double p_x, double p_z) const;
	int vertex_before(double p_s) const;
};

// Rasterise distance / s / t over a grid. Cell CENTRES over p_rect, matching graph_cell_to_world and the
// GDScript node; sampling corners would offset the whole field half a cell against every other node.
//
// `p_max_distance > 0` clamps `distance` (not s or t), as the node's `max_distance` does. An EMPTY path
// fills distance with `p_unreachable` and s/t with 0 — never 0 distance, which would mean every cell is on
// the road and would make a downstream Road Grade flatten the terrain (spec §4.3).
//
// Returns { ok: bool, distance, s, t }; ok is false only for a degenerate grid.
Dictionary path_query_grid(const PackedVector2Array &p_points, const PackedFloat32Array &p_widths,
		int p_gw, int p_gh, const Rect2 &p_rect, double p_unreachable, double p_max_distance);

} // namespace godot

#endif // PASTURE_3D_PATH_QUERY_H
