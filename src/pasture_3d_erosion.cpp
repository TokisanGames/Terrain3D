// Stream-power fluvial erosion solver. See pasture_3d_erosion.h and PASTURE3D_SIM_NODE_SPEC.md §4.

#include "pasture_3d_erosion.h"

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <queue>

using namespace godot;

namespace {

// D8 neighbourhood, in a FIXED order. Not cosmetic: the order decides which of two equally steep
// neighbours becomes the receiver, so it is part of what makes a run bit-reproducible (gate I).
constexpr int NB_DX[8] = { -1, 0, 1, -1, 1, -1, 0, 1 };
constexpr int NB_DZ[8] = { -1, -1, -1, 0, 0, 1, 1, 1 };

// Priority-flood's flat-resolution increment (Barnes et al. 2014, "+epsilon" variant): each cell lifted
// by the fill sits this much above the one it drained from, so a filled lake surface slopes gently to
// its outlet and every cell in it has a strictly lower neighbour to route to. Applied to the ROUTING
// surface only — the lake-depth surface is filled without it, so `lake_depth` stays physically exact.
constexpr double FILL_EPSILON = 1.0e-6;

// Explicit hillslope diffusion is the one conditionally stable part of the scheme (§4.4). The 2D FTCS
// limit is D·Δt/Δx² ≤ 0.25; we sub-step to stay at this fraction of it rather than silently clamping D.
constexpr double DIFFUSION_COURANT = 0.2;
// Ceiling on those sub-steps, so an absurd diffusion setting costs a bounded amount of time instead of
// hanging the editor. Reported back in ErosionResult::diffusion_substeps.
constexpr int DIFFUSION_SUBSTEPS_MAX = 64;

// A cell whose priority-flood fill depth exceeds this is treated as submerged and does not incise:
// standing water traps sediment, it does not cut bedrock. Also the guard that keeps a cell routed
// "uphill" across a filled basin from being raised by the implicit update.
constexpr double SUBMERGED_TOLERANCE = 1.0e-6;

struct FloodEntry {
	double z;
	int64_t seq; // insertion counter — breaks elevation ties deterministically
	int index;
};

struct FloodGreater {
	bool operator()(const FloodEntry &a, const FloodEntry &b) const {
		if (a.z != b.z) {
			return a.z > b.z;
		}
		return a.seq > b.seq;
	}
};

// Bilinear read of a row-major 0..1 LUT at normalised (u,v). Clamped at the edges.
inline double lut_sample(const PackedFloat32Array &p_lut, int p_w, int p_h, double p_u, double p_v) {
	const double fx = std::min(std::max(p_u, 0.0), 1.0) * (double)(p_w - 1);
	const double fy = std::min(std::max(p_v, 0.0), 1.0) * (double)(p_h - 1);
	const int x0 = (int)fx;
	const int y0 = (int)fy;
	const int x1 = std::min(x0 + 1, p_w - 1);
	const int y1 = std::min(y0 + 1, p_h - 1);
	const double tx = fx - (double)x0;
	const double ty = fy - (double)y0;
	const double a = (double)p_lut[y0 * p_w + x0] * (1.0 - tx) + (double)p_lut[y0 * p_w + x1] * tx;
	const double b = (double)p_lut[y1 * p_w + x0] * (1.0 - tx) + (double)p_lut[y1 * p_w + x1] * tx;
	return a * (1.0 - ty) + b * ty;
}

} // namespace

ErosionParams godot::erosion_params_from_dict(const Dictionary &p_params) {
	ErosionParams p;
	p.gw = (int)p_params.get("gw", p.gw);
	p.gh = (int)p_params.get("gh", p.gh);
	p.cell_size = (double)p_params.get("cell_size", p.cell_size);
	p.iterations = (int)p_params.get("iterations", p.iterations);
	p.time_step = (double)p_params.get("time_step", p.time_step);
	p.erosion_rate = (double)p_params.get("erosion_rate", p.erosion_rate);
	p.area_exponent = (double)p_params.get("area_exponent", p.area_exponent);
	p.diffusion = (double)p_params.get("diffusion", p.diffusion);
	p.erodability_min = (double)p_params.get("erodability_min", p.erodability_min);
	p.erodability_max = (double)p_params.get("erodability_max", p.erodability_max);
	p.erodability_w = (int)p_params.get("erodability_w", p.erodability_w);
	p.erodability_h = (int)p_params.get("erodability_h", p.erodability_h);
	p.fill_every = (int)p_params.get("fill_every", p.fill_every);
	p.fill_depressions = (bool)p_params.get("fill_depressions", p.fill_depressions);
	p.break_stack_order = (bool)p_params.get("break_stack_order", p.break_stack_order);
	p.want_diagnostics = (bool)p_params.get("want_diagnostics", p.want_diagnostics);
	return p;
}

ErosionResult godot::erosion_solve(const std::vector<float> &p_z, const ErosionParams &p_params,
		const PackedFloat32Array &p_erodability_lut) {
	ErosionResult out;
	const int gw = p_params.gw;
	const int gh = p_params.gh;
	const int64_t n = (int64_t)gw * (int64_t)gh;
	if (gw < 3 || gh < 3 || (int64_t)p_z.size() != n) {
		return out; // ok stays false — a caller that ignores this writes nothing, which is the right no-op
	}
	const double cell = p_params.cell_size > 0.0 ? p_params.cell_size : 1.0;
	const double cell_area = cell * cell;
	const double diag = cell * 1.4142135623730951;

	// ---- Boundary + no-data ---------------------------------------------------------------------
	// The margin's outer edge is the drainage outlet (§5), and so is any cell with no region under it:
	// water that reaches the edge of the authored world leaves rather than ponding against nothing.
	std::vector<uint8_t> boundary((size_t)n, 0);
	std::vector<double> zz((size_t)n, 0.0);
	double zmin = 0.0;
	bool have_finite = false;
	for (int64_t i = 0; i < n; i++) {
		const float v = p_z[(size_t)i];
		if (std::isfinite(v)) {
			if (!have_finite || (double)v < zmin) {
				zmin = (double)v;
			}
			have_finite = true;
		}
	}
	if (!have_finite) {
		return out; // every cell is no-data: nothing to erode, and NOT a silent success
	}
	const double nodata_z = zmin - 1.0;
	for (int iz = 0; iz < gh; iz++) {
		for (int ix = 0; ix < gw; ix++) {
			const int64_t i = (int64_t)iz * gw + ix;
			const float v = p_z[(size_t)i];
			if (!std::isfinite(v)) {
				zz[(size_t)i] = nodata_z;
				boundary[(size_t)i] = 1;
			} else {
				zz[(size_t)i] = (double)v;
				if (ix == 0 || iz == 0 || ix == gw - 1 || iz == gh - 1) {
					boundary[(size_t)i] = 1;
				}
			}
		}
	}

	// ---- Per-cell erodability (§7) --------------------------------------------------------------
	// Built once: the map does not change between iterations, and re-sampling it 30 times would be
	// 30x the LUT reads for an identical answer.
	std::vector<float> erod((size_t)n, 1.0f);
	const bool has_map = p_params.erodability_w > 1 && p_params.erodability_h > 1 &&
			p_erodability_lut.size() >= p_params.erodability_w * p_params.erodability_h;
	if (has_map) {
		const double lo = p_params.erodability_min;
		const double hi = p_params.erodability_max;
		for (int iz = 0; iz < gh; iz++) {
			const double v = (double)iz / (double)(gh - 1);
			for (int ix = 0; ix < gw; ix++) {
				const double u = (double)ix / (double)(gw - 1);
				const double s = lut_sample(p_erodability_lut, p_params.erodability_w, p_params.erodability_h, u, v);
				erod[(size_t)(iz * gw + ix)] = (float)(lo + (hi - lo) * s);
			}
		}
	}

	// ---- Working arrays, allocated once and reused across iterations ----------------------------
	std::vector<double> zf_route((size_t)n, 0.0); // filled + epsilon: what D8 routes on
	std::vector<double> zf_true((size_t)n, 0.0); // filled without epsilon: what lake_depth measures
	std::vector<uint8_t> visited((size_t)n, 0);
	std::vector<int> receiver((size_t)n, 0);
	std::vector<double> area((size_t)n, 0.0);
	std::vector<int> ndon((size_t)n, 0);
	std::vector<int> delta((size_t)n + 1, 0);
	std::vector<int> donors((size_t)n, 0);
	std::vector<int> stack;
	stack.reserve((size_t)n);
	std::vector<int> work; // explicit DFS frontier — recursion would blow the stack on a big grid
	work.reserve((size_t)n);
	std::vector<double> lake((size_t)n, 0.0);
	std::vector<double> lap;

	const int iterations = std::max(p_params.iterations, 0);
	const int fill_every = std::max(p_params.fill_every, 1);
	const double dt = p_params.time_step;
	const double kdt = dt * p_params.erosion_rate;
	const double m = p_params.area_exponent;
	const double ddt = dt * p_params.diffusion;

	int diffusion_substeps = 1;
	double diff_step = 0.0;
	if (ddt > 0.0) {
		const double limit = DIFFUSION_COURANT * cell_area;
		diffusion_substeps = (int)std::ceil(ddt / std::max(limit, 1.0e-12));
		diffusion_substeps = std::min(std::max(diffusion_substeps, 1), DIFFUSION_SUBSTEPS_MAX);
		diff_step = ddt / (double)diffusion_substeps;
		lap.assign((size_t)n, 0.0);
	}
	out.diffusion_substeps = ddt > 0.0 ? diffusion_substeps : 0;

	// ---- 4.1 + 4.2, as one unit ---------------------------------------------------------------------
	// Fill, route and accumulate together. `fill_every` > 1 freezes the WHOLE network for k iterations
	// (the §11 escape hatch) rather than just the fill: reusing a filled surface under a z that incision
	// has since lowered would leave cells routing to neighbours that are no longer downhill.
	auto rebuild_network = [&]() {
		if (p_params.fill_depressions) {
			std::fill(visited.begin(), visited.end(), (uint8_t)0);
			std::priority_queue<FloodEntry, std::vector<FloodEntry>, FloodGreater> pq;
			int64_t seq = 0;
			for (int64_t i = 0; i < n; i++) {
				if (boundary[(size_t)i]) {
					zf_route[(size_t)i] = zz[(size_t)i];
					zf_true[(size_t)i] = zz[(size_t)i];
					visited[(size_t)i] = 1;
					pq.push({ zz[(size_t)i], seq++, (int)i });
				}
			}
			while (!pq.empty()) {
				const FloodEntry e = pq.top();
				pq.pop();
				const int ci = e.index;
				const int cx = ci % gw;
				const int cz = ci / gw;
				for (int k = 0; k < 8; k++) {
					const int nx = cx + NB_DX[k];
					const int nz = cz + NB_DZ[k];
					if (nx < 0 || nz < 0 || nx >= gw || nz >= gh) {
						continue;
					}
					const int ni = nz * gw + nx;
					if (visited[(size_t)ni]) {
						continue;
					}
					visited[(size_t)ni] = 1;
					zf_route[(size_t)ni] = std::max(zz[(size_t)ni], zf_route[(size_t)ci] + FILL_EPSILON);
					zf_true[(size_t)ni] = std::max(zz[(size_t)ni], zf_true[(size_t)ci]);
					pq.push({ zf_route[(size_t)ni], seq++, ni });
				}
			}
			for (int64_t i = 0; i < n; i++) {
				lake[(size_t)i] = zf_true[(size_t)i] - zz[(size_t)i];
			}
		} else {
			// GATE A CONTROL: route on the raw surface. Pits then have no downhill neighbour at all,
			// which is exactly the broken forest the gate has to be able to see.
			zf_route = zz;
			std::fill(lake.begin(), lake.end(), 0.0);
		}

		// ---- 4.1b D8 receivers -------------------------------------------------------------------
		for (int iz = 0; iz < gh; iz++) {
			for (int ix = 0; ix < gw; ix++) {
				const int i = iz * gw + ix;
				if (boundary[(size_t)i]) {
					receiver[(size_t)i] = i; // a root of the forest: fixed base level
					continue;
				}
				double best = 0.0;
				int best_i = i;
				for (int k = 0; k < 8; k++) {
					const int nx = ix + NB_DX[k];
					const int nz = iz + NB_DZ[k];
					if (nx < 0 || nz < 0 || nx >= gw || nz >= gh) {
						continue;
					}
					const int ni = nz * gw + nx;
					const double drop = zf_route[(size_t)i] - zf_route[(size_t)ni];
					if (drop <= 0.0) {
						continue;
					}
					const bool is_diag = (NB_DX[k] != 0 && NB_DZ[k] != 0);
					const double slope = drop / (is_diag ? diag : cell);
					if (slope > best) {
						best = slope;
						best_i = ni;
					}
				}
				receiver[(size_t)i] = best_i;
			}
		}

		// ---- 4.2 Topological order + drainage area (Braun & Willett's stack) ---------------------
		std::fill(ndon.begin(), ndon.end(), 0);
		for (int64_t i = 0; i < n; i++) {
			const int r = receiver[(size_t)i];
			if (r != (int)i) {
				ndon[(size_t)r]++;
			}
		}
		delta[0] = 0;
		for (int64_t i = 0; i < n; i++) {
			delta[(size_t)i + 1] = delta[(size_t)i] + ndon[(size_t)i];
		}
		{
			std::vector<int> cursor(delta.begin(), delta.end() - 1);
			for (int64_t i = 0; i < n; i++) {
				const int r = receiver[(size_t)i];
				if (r != (int)i) {
					donors[(size_t)cursor[(size_t)r]++] = (int)i;
				}
			}
		}
		stack.clear();
		for (int64_t i = 0; i < n; i++) {
			if (receiver[(size_t)i] != (int)i) {
				continue;
			}
			work.clear();
			work.push_back((int)i);
			while (!work.empty()) {
				const int c = work.back();
				work.pop_back();
				stack.push_back(c);
				// Pushed in reverse so the donors come off the frontier in ascending index order —
				// the stack is then a pure function of the receiver array, not of traversal luck.
				for (int d = delta[(size_t)c + 1] - 1; d >= delta[(size_t)c]; d--) {
					work.push_back(donors[(size_t)d]);
				}
			}
		}

		for (int64_t i = 0; i < n; i++) {
			area[(size_t)i] = cell_area;
		}
		if (p_params.break_stack_order) {
			// GATE C CONTROL: accumulate roots-first, so a cell hands its area upward before its own
			// donors have contributed and the outlet totals no longer add up to the domain area.
			for (size_t k = 0; k < stack.size(); k++) {
				const int i = stack[k];
				const int r = receiver[(size_t)i];
				if (r != i) {
					area[(size_t)r] += area[(size_t)i];
				}
			}
		} else {
			for (size_t k = stack.size(); k-- > 0;) {
				const int i = stack[k];
				const int r = receiver[(size_t)i];
				if (r != i) {
					area[(size_t)r] += area[(size_t)i];
				}
			}
		}
	};

	// One pass minimum. A zero-iteration solve is then still a valid ROUTING solve: the gates that test
	// flow routing, depression fill and drainage area on an UNTOUCHED surface get their diagnostics
	// instead of empty arrays, and z comes back exactly as it went in.
	const int passes = std::max(iterations, 1);
	for (int iter = 0; iter < passes; iter++) {
		if (iter % fill_every == 0) {
			rebuild_network();
		}
		if (iter >= iterations) {
			break; // routing-only pass (iterations == 0)
		}

		// ---- 4.3 Implicit stream-power incision --------------------------------------------------
		// Downstream-first: z[r] is already this iteration's value when i is visited, which is what
		// makes the scheme implicit (and unconditionally stable) rather than merely explicit.
		if (kdt > 0.0) {
			for (size_t k = 0; k < stack.size(); k++) {
				const int i = stack[k];
				const int r = receiver[(size_t)i];
				if (r == i || boundary[(size_t)i]) {
					continue;
				}
				if (lake[(size_t)i] > SUBMERGED_TOLERANCE) {
					continue; // under standing water: deposits, does not incise
				}
				const double zr = zz[(size_t)r];
				const double zi = zz[(size_t)i];
				if (zr >= zi) {
					continue; // routed across a filled basin; incising here would RAISE the cell
				}
				const int dx = (i % gw) - (r % gw);
				const int dz = (i / gw) - (r / gw);
				const double len = (dx != 0 && dz != 0) ? diag : cell;
				const double kp = kdt * (double)erod[(size_t)i] * std::pow(area[(size_t)i], m) / len;
				const double zn = (zi + kp * zr) / (1.0 + kp);
				zz[(size_t)i] = std::max(zn, zr); // §4.3: never incise below the receiver
			}
		}

		// ---- 4.4 Hillslope diffusion -------------------------------------------------------------
		if (ddt > 0.0) {
			for (int s = 0; s < diffusion_substeps; s++) {
				for (int iz = 0; iz < gh; iz++) {
					const int zm = std::max(iz - 1, 0) * gw;
					const int zp = std::min(iz + 1, gh - 1) * gw;
					const int row = iz * gw;
					for (int ix = 0; ix < gw; ix++) {
						const int i = row + ix;
						if (boundary[(size_t)i]) {
							lap[(size_t)i] = 0.0;
							continue;
						}
						const int xm = std::max(ix - 1, 0);
						const int xp = std::min(ix + 1, gw - 1);
						lap[(size_t)i] = (zz[(size_t)(row + xm)] + zz[(size_t)(row + xp)] +
												 zz[(size_t)(zm + ix)] + zz[(size_t)(zp + ix)] - 4.0 * zz[(size_t)i]) /
								cell_area;
					}
				}
				for (int64_t i = 0; i < n; i++) {
					if (!boundary[(size_t)i]) {
						zz[(size_t)i] += diff_step * lap[(size_t)i];
					}
				}
			}
		}
	}

	// ---- Results ---------------------------------------------------------------------------------
	out.z.resize((size_t)n);
	for (int64_t i = 0; i < n; i++) {
		// A no-data cell never had an elevation to begin with; hand back NaN rather than the synthetic
		// outlet level, so the caller cannot mistake it for measured ground.
		out.z[(size_t)i] = std::isfinite(p_z[(size_t)i]) ? (float)zz[(size_t)i] : (float)NAN;
	}
	if (p_params.want_diagnostics) {
		out.flow.resize((size_t)n);
		out.lake_depth.resize((size_t)n);
		for (int64_t i = 0; i < n; i++) {
			out.flow[(size_t)i] = (float)area[(size_t)i];
			out.lake_depth[(size_t)i] = (float)lake[(size_t)i];
		}
		out.receiver = receiver;
		out.stack = stack;
		out.boundary = boundary;
	}
	out.ok = true;
	return out;
}
