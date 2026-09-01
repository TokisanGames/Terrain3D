// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_path_query.h"

#include "pasture_3d_thread_pool.h"

#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

// ---- construction -----------------------------------------------------------------------------------

bool Pasture3DPathGeom::build(const PackedVector2Array &p_points, const PackedFloat32Array &p_widths) {
	px.clear();
	pz.clear();
	width.clear();
	cum.clear();
	bucket_start.clear();
	bucket_items.clear();
	bw = bh = 0;
	max_ring = 0;
	cell = 0.0;

	const int n_pts = p_points.size();
	if (n_pts < 2) {
		return false;
	}
	px.resize(n_pts);
	pz.resize(n_pts);
	for (int i = 0; i < n_pts; i++) {
		const Vector2 v = p_points[i];
		px[i] = (float)v.x;
		pz[i] = (float)v.y;
	}
	width.resize(p_widths.size());
	for (int i = 0; i < p_widths.size(); i++) {
		width[i] = p_widths[i];
	}

	cum.resize(n_pts);
	cum[0] = 0.0;
	for (int i = 1; i < n_pts; i++) {
		const double dx = (double)px[i] - (double)px[i - 1];
		const double dz = (double)pz[i] - (double)pz[i - 1];
		cum[i] = cum[i - 1] + std::sqrt(dx * dx + dz * dz);
	}

	const int n_seg = segment_count();
	if (n_seg < PATH_INDEX_MIN_SEGMENTS) {
		return true; // no index: every query is brute force, exactly as the GDScript does
	}

	// One cell per segment on average, floored — a path of very short segments must not explode into
	// millions of buckets, and a path of one huge segment must not put everything into one. Same formula
	// as Pasture3DGraphPath._ensure, because the ring stopping rule is only correct against the cell size
	// the buckets were built with.
	cell = std::max(cum.back() / (double)n_seg, 0.5);

	double min_x = px[0], max_x = px[0], min_z = pz[0], max_z = pz[0];
	for (int i = 1; i < n_pts; i++) {
		min_x = std::min(min_x, (double)px[i]);
		max_x = std::max(max_x, (double)px[i]);
		min_z = std::min(min_z, (double)pz[i]);
		max_z = std::max(max_z, (double)pz[i]);
	}
	ox = min_x;
	oz = min_z;
	bw = (int)std::floor((max_x - min_x) / cell) + 1;
	bh = (int)std::floor((max_z - min_z) / cell) + 1;
	bw = std::max(bw, 1);
	bh = std::max(bh, 1);
	max_ring = (int)std::ceil(std::max(max_x - min_x, max_z - min_z) / cell) + 2;

	// CSR build: count, prefix-sum, fill. Two passes over the same bucket spans so the counting and the
	// filling cannot disagree about which buckets a segment covers.
	std::vector<int> counts((size_t)bw * (size_t)bh, 0);
	auto span = [&](int p_seg, int &r_gx0, int &r_gx1, int &r_gz0, int &r_gz1) {
		const double ax = px[p_seg], bx = px[p_seg + 1];
		const double az = pz[p_seg], bz = pz[p_seg + 1];
		r_gx0 = (int)std::floor((std::min(ax, bx) - ox) / cell);
		r_gx1 = (int)std::floor((std::max(ax, bx) - ox) / cell);
		r_gz0 = (int)std::floor((std::min(az, bz) - oz) / cell);
		r_gz1 = (int)std::floor((std::max(az, bz) - oz) / cell);
		r_gx0 = std::max(r_gx0, 0);
		r_gz0 = std::max(r_gz0, 0);
		r_gx1 = std::min(r_gx1, bw - 1);
		r_gz1 = std::min(r_gz1, bh - 1);
	};
	for (int si = 0; si < n_seg; si++) {
		int gx0, gx1, gz0, gz1;
		span(si, gx0, gx1, gz0, gz1);
		for (int gz = gz0; gz <= gz1; gz++) {
			for (int gx = gx0; gx <= gx1; gx++) {
				counts[(size_t)gz * (size_t)bw + (size_t)gx]++;
			}
		}
	}
	bucket_start.resize(counts.size() + 1);
	bucket_start[0] = 0;
	for (size_t i = 0; i < counts.size(); i++) {
		bucket_start[i + 1] = bucket_start[i] + counts[i];
	}
	bucket_items.resize((size_t)bucket_start.back());
	std::vector<int> cursor(bucket_start.begin(), bucket_start.end() - 1);
	for (int si = 0; si < n_seg; si++) {
		int gx0, gx1, gz0, gz1;
		span(si, gx0, gx1, gz0, gz1);
		for (int gz = gz0; gz <= gz1; gz++) {
			for (int gx = gx0; gx <= gx1; gx++) {
				bucket_items[(size_t)cursor[(size_t)gz * (size_t)bw + (size_t)gx]++] = si;
			}
		}
	}
	return true;
}

// ---- per-vertex interpolation ------------------------------------------------------------------------

int Pasture3DPathGeom::vertex_before(double p_s) const {
	const int last = (int)px.size() - 2;
	if (last < 0) {
		return 0;
	}
	for (int i = 0; i < (int)px.size() - 1; i++) {
		if (p_s <= cum[i + 1]) {
			return i;
		}
	}
	return last;
}

double Pasture3DPathGeom::half_width_at(double p_s) const {
	if (width.empty()) {
		return 1.0;
	}
	if (width.size() == 1) {
		return width[0];
	}
	const int i = vertex_before(p_s);
	const int last = (int)width.size() - 1;
	const double a = width[std::min(i, last)];
	const double b = width[std::min(i + 1, last)];
	const double seg = cum[i + 1] - cum[i];
	const double f = seg <= 0.0 ? 0.0 : std::clamp((p_s - cum[i]) / seg, 0.0, 1.0);
	return a + (b - a) * f;
}

// ---- the query --------------------------------------------------------------------------------------

double Pasture3DPathGeom::segment_distance(int p_seg, double p_x, double p_z) const {
	const double ax = px[p_seg], az = pz[p_seg];
	const double abx = (double)px[p_seg + 1] - ax, abz = (double)pz[p_seg + 1] - az;
	const double len2 = abx * abx + abz * abz;
	const double f = len2 <= 0.0 ? 0.0 : std::clamp(((p_x - ax) * abx + (p_z - az) * abz) / len2, 0.0, 1.0);
	const double dx = p_x - (ax + abx * f);
	const double dz = p_z - (az + abz * f);
	return std::sqrt(dx * dx + dz * dz);
}

Pasture3DPathHit Pasture3DPathGeom::resolve(double p_x, double p_z, const int *p_cand, int p_count) const {
	Pasture3DPathHit hit;
	double best = INFINITY;
	int best_seg = -1;
	double best_f = 0.0;
	for (int k = 0; k < p_count; k++) {
		const int si = p_cand[k];
		const double ax = px[si], az = pz[si];
		const double abx = (double)px[si + 1] - ax, abz = (double)pz[si + 1] - az;
		const double len2 = abx * abx + abz * abz;
		const double f = len2 <= 0.0 ? 0.0
									 : std::clamp(((p_x - ax) * abx + (p_z - az) * abz) / len2, 0.0, 1.0);
		const double dx = p_x - (ax + abx * f);
		const double dz = p_z - (az + abz * f);
		const double d = std::sqrt(dx * dx + dz * dz);
		if (d < best) {
			best = d;
			best_seg = si;
			best_f = f;
		}
	}
	if (best_seg < 0) {
		return hit; // segment -1: an empty candidate set, which only an empty path can produce
	}
	hit.distance = best;
	hit.s = cum[best_seg] + (cum[best_seg + 1] - cum[best_seg]) * best_f;
	hit.segment = best_seg;

	// POSITIVE IS THE DRIVER'S RIGHT. On Godot's XZ plane with +Y up, the right of a heading (dx, dz) is
	// (-dz, dx), so the side is the sign of the 2D cross product of the heading with the offset. Spelled
	// out because this is exactly the step a fixture sharing the code's convention cannot catch being
	// inverted — see PASTURE3D_ROAD_SYSTEM_PROPOSAL.md on the sign convention.
	const double ax = px[best_seg], az = pz[best_seg];
	const double abx = (double)px[best_seg + 1] - ax, abz = (double)pz[best_seg + 1] - az;
	double signed_d = best;
	if (abx * abx + abz * abz > 0.0) {
		const double cross = abx * (p_z - az) - abz * (p_x - ax);
		signed_d = cross >= 0.0 ? best : -best;
	}
	hit.t = signed_d / std::max(half_width_at(hit.s), 0.0001);
	return hit;
}

bool Pasture3DPathGeom::inside(double p_x, double p_z) const {
	if (!closed || px.size() < 4) {
		return false;
	}
	// Half-open comparison on the y span: a vertex exactly level with the ray is counted once, not twice.
	// The classic point-in-polygon bug, and it shows up as single wrong cells in a straight line — which
	// reads as noise rather than as a rule error.
	const int n = (int)px.size() - 1;
	bool odd = false;
	for (int i = 0; i < n; i++) {
		const double ay = pz[i], by = pz[i + 1];
		if ((ay > p_z) != (by > p_z)) {
			const double dy = by - ay;
			if (dy != 0.0) {
				const double x_cross = (double)px[i] + (p_z - ay) / dy * ((double)px[i + 1] - (double)px[i]);
				if (p_x < x_cross) {
					odd = !odd;
				}
			}
		}
	}
	return odd;
}

Pasture3DPathHit Pasture3DPathGeom::nearest_brute(double p_x, double p_z) const {
	const int n = segment_count();
	if (n == 0) {
		return Pasture3DPathHit();
	}
	std::vector<int> all((size_t)n);
	for (int i = 0; i < n; i++) {
		all[(size_t)i] = i;
	}
	return resolve(p_x, p_z, all.data(), n);
}

Pasture3DPathHit Pasture3DPathGeom::nearest(double p_x, double p_z, std::vector<int> &r_scratch) const {
	const int n = segment_count();
	if (n == 0) {
		return Pasture3DPathHit();
	}
	if (bucket_items.empty()) {
		r_scratch.resize((size_t)n);
		for (int i = 0; i < n; i++) {
			r_scratch[(size_t)i] = i;
		}
		return resolve(p_x, p_z, r_scratch.data(), n);
	}

	r_scratch.clear();
	const int cx = (int)std::floor((p_x - ox) / cell);
	const int cz = (int)std::floor((p_z - oz) / cell);
	double best = INFINITY;
	// A segment sitting in a bucket `ring` rings out from the query cell is at least (ring - 1) * cell
	// away, so once best <= (ring - 1) * cell no unexamined bucket can hold anything nearer. Stopping one
	// ring later than that bound keeps the off-by-one on the safe side; see the header.
	for (int ring = 0; ring <= max_ring; ring++) {
		for (int gz = cz - ring; gz <= cz + ring; gz++) {
			if (gz < 0 || gz >= bh) {
				continue;
			}
			for (int gx = cx - ring; gx <= cx + ring; gx++) {
				if (gx < 0 || gx >= bw) {
					continue;
				}
				// Only this ring's own shell; the interior was collected on an earlier pass.
				if (ring > 0 && std::abs(gx - cx) != ring && std::abs(gz - cz) != ring) {
					continue;
				}
				const size_t b = (size_t)gz * (size_t)bw + (size_t)gx;
				for (int k = bucket_start[b]; k < bucket_start[b + 1]; k++) {
					const int si = bucket_items[(size_t)k];
					// The GDScript de-duplicates with a `seen` Dictionary. Here a linear scan of the
					// candidate list does it: the list is a handful of segments (that is what the index is
					// for), and a hash set per cell would cost more than the scan it replaces.
					bool seen = false;
					for (size_t q = 0; q < r_scratch.size(); q++) {
						if (r_scratch[q] == si) {
							seen = true;
							break;
						}
					}
					if (seen) {
						continue;
					}
					r_scratch.push_back(si);
					best = std::min(best, segment_distance(si, p_x, p_z));
				}
			}
		}
		if (best <= (double)ring * cell) {
			break;
		}
	}
	return resolve(p_x, p_z, r_scratch.data(), (int)r_scratch.size());
}

// ---- the grid kernel --------------------------------------------------------------------------------

Dictionary godot::path_query_grid(const PackedVector2Array &p_points, const PackedFloat32Array &p_widths,
		int p_gw, int p_gh, const Rect2 &p_rect, double p_unreachable, double p_max_distance) {
	Dictionary out;
	if (p_gw <= 0 || p_gh <= 0) {
		out["ok"] = false;
		return out;
	}
	const int n = p_gw * p_gh;
	PackedFloat32Array dist, s_out, t_out;
	dist.resize(n);
	s_out.resize(n);
	t_out.resize(n);

	Pasture3DPathGeom geom;
	if (!geom.build(p_points, p_widths)) {
		// One fill, not a per-cell branch. An unresolved Road Source is a normal state and the whole grid
		// has the same answer. The fill is `unreachable`, NEVER 0 — 0 would mean every cell is on the road.
		const float far_v = (float)(p_max_distance > 0.0 ? std::min(p_unreachable, p_max_distance)
														 : p_unreachable);
		dist.fill(far_v);
		s_out.fill(0.0f);
		t_out.fill(0.0f);
		out["ok"] = true;
		out["distance"] = dist;
		out["s"] = s_out;
		out["t"] = t_out;
		return out;
	}

	// Cell CENTRES over p_rect — graph_cell_to_world's convention and the GDScript node's.
	const double dx = p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = p_rect.size.y / (double)std::max(p_gh, 1);
	const double min_x = p_rect.position.x + 0.5 * dx;
	const double min_z = p_rect.position.y + 0.5 * dz;

	float *dist_w = dist.ptrw();
	float *s_w = s_out.ptrw();
	float *t_w = t_out.ptrw();

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		// One candidate buffer per chunk, reused across every cell in it: the query allocates nothing in
		// its inner loop, and the buffer is thread-local by construction rather than by a lock.
		std::vector<int> scratch;
		scratch.reserve(32);
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			const double wz = min_z + (double)iz * dz;
			for (int ix = 0; ix < p_gw; ix++) {
				const Pasture3DPathHit hit = geom.nearest(min_x + (double)ix * dx, wz, scratch);
				const int idx = row + ix;
				dist_w[idx] = (float)(p_max_distance > 0.0 ? std::min(hit.distance, p_max_distance)
														   : hit.distance);
				s_w[idx] = (float)hit.s;
				t_w[idx] = (float)hit.t;
			}
		}
	});

	out["ok"] = true;
	out["distance"] = dist;
	out["s"] = s_out;
	out["t"] = t_out;
	return out;
}

// ---- the mask kernel --------------------------------------------------------------------------------

// Close the ring HERE, once, exactly as Pasture3DGraphPath._ensure does: the closing edge is a real
// segment for distance and for the winding test alike, and adding it at the boundary means no query below
// has to remember that a path can be closed. Three points is the minimum for an area — a two-point
// "closed" path is a line doubled back on itself, and closing it would only duplicate a segment.
static PackedVector2Array path_ring(const PackedVector2Array &p_points, bool p_closed) {
	if (!p_closed || p_points.size() < 3) {
		return p_points;
	}
	PackedVector2Array ring = p_points;
	ring.push_back(p_points[0]);
	return ring;
}

PackedFloat32Array godot::path_mask_grid(const PackedVector2Array &p_points,
		const PackedFloat32Array &p_widths, bool p_closed, int p_gw, int p_gh, const Rect2 &p_rect,
		double p_width_scale, double p_feather, bool p_invert) {
	PackedFloat32Array out;
	if (p_gw <= 0 || p_gh <= 0) {
		return out;
	}
	out.resize(p_gw * p_gh);

	Pasture3DPathGeom geom;
	geom.closed = p_closed && p_points.size() >= 3;
	if (!geom.build(path_ring(p_points, p_closed), p_widths)) {
		out.fill(p_invert ? 1.0f : 0.0f);
		return out;
	}

	const double dx = p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = p_rect.size.y / (double)std::max(p_gh, 1);
	const double min_x = p_rect.position.x + 0.5 * dx;
	const double min_z = p_rect.position.y + 0.5 * dz;
	float *w = out.ptrw();

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		std::vector<int> scratch;
		scratch.reserve(32);
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			const double wz = min_z + (double)iz * dz;
			for (int ix = 0; ix < p_gw; ix++) {
				const double wx = min_x + (double)ix * dx;
				double m = 1.0;
				if (geom.closed) {
					// REGION. Inside is a flat 1; feathering inward as well would eat a small shape from
					// both sides and leave a region that never reaches full strength anywhere.
					if (!geom.inside(wx, wz)) {
						const double d = geom.nearest(wx, wz, scratch).distance;
						m = p_feather <= 0.0 ? 0.0 : std::clamp(1.0 - d / p_feather, 0.0, 1.0);
					}
				} else {
					// CORRIDOR. Back from `t` to metres via the half-width AT THIS s, so the feather is a
					// real distance wherever the road is wide and wherever it is narrow.
					const Pasture3DPathHit hit = geom.nearest(wx, wz, scratch);
					const double half = std::max(geom.half_width_at(hit.s) * p_width_scale, 1e-6);
					const double edge = hit.distance - half;
					if (edge > 0.0) {
						m = p_feather <= 0.0 ? 0.0 : std::clamp(1.0 - edge / p_feather, 0.0, 1.0);
					}
				}
				w[row + ix] = (float)(p_invert ? 1.0 - m : m);
			}
		}
	});
	return out;
}
