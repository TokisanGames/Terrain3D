// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_road_grade.h"

#include "pasture_3d_path_query.h"
#include "pasture_3d_thread_pool.h"

#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

namespace {

// Pasture3DRoadGrader._at: an empty array means "use the default everywhere", and any other array is
// clamped rather than bounds-checked, so a profile shorter than the alignment holds its last value
// instead of falling off the end mid-road.
inline double at_or(const float *p_arr, int p_size, int p_i, double p_default) {
	if (p_size <= 0) {
		return p_default;
	}
	return p_arr[std::clamp(p_i, 0, p_size - 1)];
}

// Pasture3DRoadAlignment.index_at: NEAREST sample, rounded. The per-sample arrays are looked up with it,
// so rounding rather than flooring is what keeps a width change landing on the sample it was authored at.
inline int align_index_at(double p_s, double p_ds, double p_s0, int p_n) {
	if (p_n == 0) {
		return -1;
	}
	return std::clamp((int)std::lround((p_s - p_s0) / std::max(p_ds, 1e-6)), 0, p_n - 1);
}

// Pasture3DRoadAlignment.height_at: LINEAR between samples, not the nearest one. The road's own height is
// the one quantity a step in would be visible in, and a stepped centreline reads as a staircase cut.
inline double align_height_at(double p_s, double p_ds, double p_s0, const float *p_z, int p_n) {
	if (p_n == 0) {
		return NAN;
	}
	if (p_n == 1) {
		return p_z[0];
	}
	const double t = (p_s - p_s0) / std::max(p_ds, 1e-6);
	const int i = std::clamp((int)std::floor(t), 0, p_n - 2);
	const double f = std::clamp(t - (double)i, 0.0, 1.0);
	return (double)p_z[i] + ((double)p_z[i + 1] - (double)p_z[i]) * f;
}

PackedFloat32Array zeros(int p_n) {
	PackedFloat32Array a;
	a.resize(p_n);
	a.fill(0.0f);
	return a;
}

} // namespace

Dictionary godot::road_grade_grid(const PackedFloat32Array &p_height, int p_gw, int p_gh, double p_min_x,
		double p_min_z, double p_vs, const PackedVector2Array &p_plan, double p_align_ds,
		double p_align_s0, const PackedFloat32Array &p_align_z, const PackedFloat32Array &p_align_bank,
		const PackedFloat32Array &p_half_width, const PackedFloat32Array &p_shoulder,
		const PackedFloat32Array &p_verge, const PackedByteArray &p_suppress, const Dictionary &p_opts) {
	Pasture3DPathGeom geom;
	geom.build(p_plan, PackedFloat32Array());
	return road_grade_grid_geom(geom, p_height, p_gw, p_gh, p_min_x, p_min_z, p_vs, p_align_ds,
			p_align_s0, p_align_z, p_align_bank, p_half_width, p_shoulder, p_verge, p_suppress, p_opts);
}

Dictionary godot::road_grade_grid_geom(const Pasture3DPathGeom &p_geom, const PackedFloat32Array &p_height,
		int p_gw, int p_gh, double p_min_x, double p_min_z, double p_vs, double p_align_ds,
		double p_align_s0, const PackedFloat32Array &p_align_z, const PackedFloat32Array &p_align_bank,
		const PackedFloat32Array &p_half_width, const PackedFloat32Array &p_shoulder,
		const PackedFloat32Array &p_verge, const PackedByteArray &p_suppress, const Dictionary &p_opts) {
	Dictionary out;
	const int n = p_gw * p_gh;
	const int n_align = p_align_z.size();

	// The pass-through answer, and it is the answer for every degenerate input. A grader that returned
	// zeros for an unsolved road would flatten the terrain to sea level while a road was being renamed.
	PackedFloat32Array height = p_height.duplicate();
	out["ok"] = false;
	out["height"] = height;
	out["roadbed"] = zeros(std::max(n, 0));
	out["cut"] = zeros(std::max(n, 0));
	out["fill"] = zeros(std::max(n, 0));
	out["verge"] = zeros(std::max(n, 0));
	out["structure"] = zeros(std::max(n, 0));
	out["surface"] = zeros(std::max(n, 0));
	if (n <= 0 || n_align == 0 || p_geom.is_empty() || p_height.size() != n) {
		return out;
	}

	const double crown = p_opts.has("crown") ? (double)p_opts["crown"] : 0.05;
	const double cut_batter = std::max(p_opts.has("cut_batter") ? (double)p_opts["cut_batter"] : 1.0, 0.01);
	const double fill_batter = std::max(p_opts.has("fill_batter") ? (double)p_opts["fill_batter"] : 0.6, 0.01);
	const double fade = std::max(p_opts.has("surface_fade") ? (double)p_opts["surface_fade"] : 1.0, 0.0);
	PackedByteArray skip;
	if (p_opts.has("skip")) {
		skip = p_opts["skip"];
	}

	const float *src = p_height.ptr();
	float *graded = height.ptrw();
	PackedFloat32Array a_bed = out["roadbed"], a_cut = out["cut"], a_fill = out["fill"];
	PackedFloat32Array a_verge = out["verge"], a_struct = out["structure"], a_surface = out["surface"];
	float *m_bed = a_bed.ptrw();
	float *m_cut = a_cut.ptrw();
	float *m_fill = a_fill.ptrw();
	float *m_verge = a_verge.ptrw();
	float *m_struct = a_struct.ptrw();
	float *m_surface = a_surface.ptrw();

	const float *z_ptr = p_align_z.ptr();
	const float *bank_ptr = p_align_bank.ptr();
	const int n_bank = p_align_bank.size();
	const float *hw_ptr = p_half_width.ptr();
	const float *sh_ptr = p_shoulder.ptr();
	const float *vg_ptr = p_verge.ptr();
	const int n_hw = p_half_width.size(), n_sh = p_shoulder.size(), n_vg = p_verge.size();
	const uint8_t *sup_ptr = p_suppress.ptr();
	const int n_sup = p_suppress.size();
	const uint8_t *skip_ptr = skip.ptr();
	const int n_skip = skip.size();

	Pasture3DThreadPool::parallel_for_rows(p_gh, 8, [&](int z0, int z1) {
		std::vector<int> scratch;
		scratch.reserve(32);
		for (int iz = z0; iz < z1; iz++) {
			const double wz = p_min_z + (double)iz * p_vs;
			const int row = iz * p_gw;
			for (int ix = 0; ix < p_gw; ix++) {
				const int idx = row + ix;
				const double ground = src[idx];
				// NaN is the brush's "not my cell" marker, not a height. Writing a road through it would
				// invent ground outside the loop.
				if (!std::isfinite(ground)) {
					continue;
				}
				const double wx = p_min_x + (double)ix * p_vs;

				const Pasture3DPathHit hit = p_geom.nearest(wx, wz, scratch);
				const double d = hit.distance;
				const double s = hit.s;

				const int si = align_index_at(s, p_align_ds, p_align_s0, n_align);
				if (si < n_skip && skip_ptr[si] != 0) {
					continue;
				}
				const double half = at_or(hw_ptr, n_hw, si, 3.5);
				const double shoulder = at_or(sh_ptr, n_sh, si, 0.5);
				const double verge = at_or(vg_ptr, n_vg, si, 4.0);
				const double edge_d = half + shoulder;

				// THE CORRIDOR IS AS WIDE AS THE BATTER NEEDS, plus the verge. Capping the reach at
				// edge_d + verge silently CLIPS the batter: a 20 m cut at 1:1 needs 20 m of run, and with
				// a 4 m verge the other 16 m becomes a sheer wall down the side of the road. It looks like
				// a canyon and reports no error, because a clipped batter is still a legal height field.
				const double z_ref = align_height_at(s, p_align_ds, p_align_s0, z_ptr, n_align);
				const double rise = std::abs(z_ref - ground);
				const double slope = z_ref < ground ? cut_batter : fill_batter;
				if (d > edge_d + rise / slope + verge) {
					continue;
				}

				// A suppressed stretch still REPORTS itself — the structure mask is how a later phase
				// learns where to build a deck — it just does not touch the ground.
				if (si < n_sup && sup_ptr[si] != 0) {
					m_struct[idx] = 1.0f;
					continue;
				}

				// signf, not the query's `t` sign: the reference calls a point exactly collinear with a
				// segment side 0, and matching that exactly is one line. See the header.
				double side = 0.0;
				if (hit.segment >= 0) {
					const double ax = p_geom.px[hit.segment], az = p_geom.pz[hit.segment];
					const double abx = (double)p_geom.px[hit.segment + 1] - ax;
					const double abz = (double)p_geom.pz[hit.segment + 1] - az;
					const double cross = abx * (wz - az) - abz * (wx - ax);
					side = cross > 0.0 ? 1.0 : (cross < 0.0 ? -1.0 : 0.0);
				}

				const double u = d * side;
				const double bank = si < n_bank ? (double)bank_ptr[si] : 0.0;
				const double z_surface = road_surface_height(z_ref, bank, crown, u);

				double h = ground;
				if (d <= edge_d) {
					h = z_surface;
				} else {
					// Beyond the shoulder the batter runs from the edge of formation until it MEETS the
					// ground, and the meet is a max/min rather than a solved crossing — which is what makes
					// the join continuous with no seam to chase, at any terrain slope.
					const double z_edge = road_surface_height(z_ref, bank, crown, edge_d * side);
					const double beyond = d - edge_d;
					h = z_edge > ground ? std::max(ground, z_edge - beyond * fill_batter)
										: std::min(ground, z_edge + beyond * cut_batter);
				}
				graded[idx] = (float)h;

				// COVERAGE FOR PAINTING, as a float, computed here because this is the only place that
				// knows `d`. Smoothstep rather than linear, so the painted edge has no visible line where
				// the gradient starts — which a linear ramp does have, its derivative jumping.
				const double fade_end = edge_d + shoulder * fade;
				if (d <= edge_d) {
					m_surface[idx] = 1.0f;
				} else if (fade_end > edge_d) {
					const double uf = std::clamp((fade_end - d) / (fade_end - edge_d), 0.0, 1.0);
					m_surface[idx] = (float)(uf * uf * (3.0 - 2.0 * uf));
				}
				if (d <= half) {
					m_bed[idx] = 1.0f;
				} else if (d > edge_d) {
					m_verge[idx] = 1.0f;
				}
				if (d > edge_d && std::abs(h - ground) <= ROAD_EARTHWORK_EPSILON) {
					m_verge[idx] = 1.0f; // past the batter toe: ground the road disturbed but did not move
				}
				const double delta = h - ground;
				if (delta > ROAD_EARTHWORK_EPSILON) {
					m_fill[idx] = 1.0f;
				} else if (delta < -ROAD_EARTHWORK_EPSILON) {
					m_cut[idx] = 1.0f;
				}
			}
		}
	});

	out["ok"] = true;
	out["height"] = height;
	out["roadbed"] = a_bed;
	out["cut"] = a_cut;
	out["fill"] = a_fill;
	out["verge"] = a_verge;
	out["structure"] = a_struct;
	out["surface"] = a_surface;
	return out;
}
