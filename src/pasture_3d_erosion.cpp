// Stream-power fluvial erosion solver. See pasture_3d_erosion.h and PASTURE3D_SIM_NODE_SPEC.md §4.

#include "pasture_3d_erosion.h"

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <queue>

#if defined(_MSC_VER)
#include <intrin.h>
#endif

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

// ---- The deposition term's Gauss-Seidel loop (Yuan et al. 2019) -----------------------------------
//
// With G > 0 a cell's new elevation depends on how much its whole upstream catchment eroded THIS step,
// and that erosion depends on the new elevations — so the step is implicit in a way one downstream sweep
// cannot resolve, and is iterated to a fixed point instead. Convergence is independent of grid size but
// degrades sharply as G approaches 1 (the transport-limited end), which is why the cap exists and is
// reported rather than hidden.
constexpr double DEPOSITION_TOL_REL = 1.0e-6; // scaled by the largest |z| in the field
constexpr double DEPOSITION_TOL_ABS = 1.0e-6; // metres, so a flat field still has a floor
constexpr int DEPOSITION_SWEEPS_MAX = 50; // ~20 is the published worst case near G = 1

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

// ---- The flood's priority queue (§11 profiling, 2026-08-19) ---------------------------------------
//
// Profiling put the priority-flood at 61% of the whole solve — the one O(n log n) step in an otherwise
// O(n) solver, run once per iteration over every cell. The binary heap was the cost: n pushes and n pops
// at ~log2(580k) = 20 comparisons each, on 24-byte entries, with the random access a heap implies.
//
// This replaces it with a MONOTONE BUCKET QUEUE (a radix heap, Barnes 2016 "Parallel Priority-Flood"),
// which is O(1) amortised because the pop key never decreases. Buckets are indexed by the highest bit
// where a key differs from the last key popped, so an element moves down at most 65 buckets in its whole
// lifetime, and the common case — a neighbour barely above the water line — moves it once.
//
// IT MUST POP IN EXACTLY THE ORDER THE BINARY HEAP DID, or the landscape changes silently. Two things
// make that true, and gate BI asserts it bitwise against the old implementation rather than trusting
// either of them:
//
//   1. ELEVATION ORDER is the bucket structure's own guarantee.
//   2. TIES are broken by insertion order, which matters because two cells can share a `zf_route` and
//      still carry different `zf_true` — so whichever is processed first decides a shared neighbour's
//      lake depth. Equal keys always land in the same bucket (the index is a function of the key alone),
//      pushes append, and redistribution preserves relative order — so equal keys stay in insertion
//      order, and bucket 0 is drained front-first. That is the `seq` tie-break of FloodGreater, without
//      storing a `seq`.
inline uint64_t flood_key(double p_z) {
	// Order-preserving double -> uint64: flip the sign bit for positives, invert everything for
	// negatives, so unsigned < matches double < across the whole finite range.
	uint64_t u = 0;
	std::memcpy(&u, &p_z, sizeof(u));
	return (u & 0x8000000000000000ULL) ? ~u : (u | 0x8000000000000000ULL);
}

inline int highest_bit(uint64_t p_x) {
#if defined(_MSC_VER)
	unsigned long i = 0;
	_BitScanReverse64(&i, p_x);
	return (int)i;
#else
	return 63 - __builtin_clzll(p_x);
#endif
}

class MonotoneFloodQueue {
public:
	void reset() {
		for (int i = 0; i < BUCKETS; i++) {
			_items[i].clear();
			_head[i] = 0;
		}
		_last = 0;
		_count = 0;
	}

	void push(uint64_t p_key, int p_index) {
		const int b = bucket_of(p_key);
		_items[b].push_back({ p_key, p_index });
		_count++;
	}

	bool empty() const { return _count == 0; }

	// Pops the smallest key, ties in insertion order. Returns false when the queue is empty.
	bool pop(int &r_index) {
		if (_count == 0) {
			return false;
		}
		if (_head[0] >= _items[0].size()) {
			refill();
		}
		r_index = _items[0][_head[0]].index;
		_head[0]++;
		_count--;
		if (_head[0] >= _items[0].size()) {
			_items[0].clear();
			_head[0] = 0;
		}
		return true;
	}

private:
	struct Item {
		uint64_t key;
		int index;
	};
	static constexpr int BUCKETS = 65; // 0 holds keys equal to `_last`; i+1 holds "differs first at bit i"

	int bucket_of(uint64_t p_key) const {
		const uint64_t x = p_key ^ _last;
		return x == 0 ? 0 : highest_bit(x) + 1;
	}

	// Bucket 0 is empty but the queue is not: take the lowest non-empty bucket, make its minimum the new
	// `_last`, and re-file every one of its entries. Entries only ever move to LOWER buckets, which is
	// what bounds the total work.
	void refill() {
		int b = 1;
		while (b < BUCKETS && _head[b] >= _items[b].size()) {
			b++;
		}
		uint64_t lo = UINT64_MAX;
		for (size_t i = _head[b]; i < _items[b].size(); i++) {
			lo = std::min(lo, _items[b][i].key);
		}
		_last = lo;
		// Relative order preserved: this walks the bucket front to back and appends, so equal keys keep
		// the insertion order the tie-break depends on.
		for (size_t i = _head[b]; i < _items[b].size(); i++) {
			const Item it = _items[b][i];
			_items[bucket_of(it.key)].push_back(it);
		}
		_items[b].clear();
		_head[b] = 0;
	}

	std::vector<Item> _items[BUCKETS];
	size_t _head[BUCKETS] = {};
	uint64_t _last = 0;
	size_t _count = 0;
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
	p.deposition = (double)p_params.get("deposition", p.deposition);
	p.erodability_min = (double)p_params.get("erodability_min", p.erodability_min);
	p.erodability_max = (double)p_params.get("erodability_max", p.erodability_max);
	p.erodability_w = (int)p_params.get("erodability_w", p.erodability_w);
	p.erodability_h = (int)p_params.get("erodability_h", p.erodability_h);
	p.fill_every = (int)p_params.get("fill_every", p.fill_every);
	p.fill_depressions = (bool)p_params.get("fill_depressions", p.fill_depressions);
	p.break_stack_order = (bool)p_params.get("break_stack_order", p.break_stack_order);
	p.legacy_flood = (bool)p_params.get("legacy_flood", p.legacy_flood);
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
	// Yuan et al. 2019's three extra fields, allocated ONLY when G > 0 so the detachment-limited path
	// costs exactly what it always did — which is what makes gate BS's bitwise control a real control.
	// `ht` is the elevation at the start of the step (fixed through the sweeps), `hp` the previous
	// sweep's iterate, `sed` the erosion accumulated down the drainage tree.
	std::vector<double> ht, hp, sed;
	// Declared out here, like every other working array: the flood runs once per iteration and its
	// buckets keep their capacity between rebuilds, so 30 iterations allocate once rather than 30 times.
	MonotoneFloodQueue flood_q;

	const int iterations = std::max(p_params.iterations, 0);
	const int fill_every = std::max(p_params.fill_every, 1);
	const double dt = p_params.time_step;
	const double kdt = dt * p_params.erosion_rate;
	const double m = p_params.area_exponent;
	const double ddt = dt * p_params.diffusion;
	const double g_dep = std::max(p_params.deposition, 0.0);
	const bool has_dep = g_dep > 0.0;
	if (has_dep) {
		ht.assign((size_t)n, 0.0);
		hp.assign((size_t)n, 0.0);
		sed.assign((size_t)n, 0.0);
	}

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
			// The body of the flood, shared by both queues so the two paths cannot drift apart in
			// anything except the order cells come out — which is the whole of what gate BI tests.
			// MEASURED AND REJECTED (§11, 2026-08-19): hoisting the four bounds tests into one
			// interior/edge branch per popped cell, the way the receiver pass below gets for free,
			// changed the solve by less than its own run-to-run spread. The flood is bound by the memory
			// it touches — three double arrays a row apart, plus `visited` — not by the arithmetic in
			// this loop, so the branch was reverted rather than kept for a saving that is not there.
			const auto spread = [&](const int ci, const auto &p_push) {
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
					p_push(ni);
				}
			};
			if (p_params.legacy_flood) {
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
					spread(e.index, [&](int ni) { pq.push({ zf_route[(size_t)ni], seq++, ni }); });
				}
			} else {
				flood_q.reset();
				for (int64_t i = 0; i < n; i++) {
					if (boundary[(size_t)i]) {
						zf_route[(size_t)i] = zz[(size_t)i];
						zf_true[(size_t)i] = zz[(size_t)i];
						visited[(size_t)i] = 1;
						flood_q.push(flood_key(zz[(size_t)i]), (int)i);
					}
				}
				int ci = 0;
				while (flood_q.pop(ci)) {
					spread(ci, [&](int ni) { flood_q.push(flood_key(zf_route[(size_t)ni]), ni); });
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
				// No bounds test: every cell on the grid edge is `boundary` and took the branch above,
				// so anything reaching here is interior and has all eight neighbours. The test that used
				// to be here could never fail — it was dead, and the flood pays for the same insight
				// with an explicit interior branch because its cells are not pre-filtered that way.
				for (int k = 0; k < 8; k++) {
					const int ni = i + NB_DZ[k] * gw + NB_DX[k];
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
		//
		// The incision of ONE cell, from a starting elevation `p_from` — which is the cell's own current
		// elevation in the detachment-limited path and its post-deposition elevation in the transporting
		// one. Shared so the three guards below cannot drift between the two.
		const auto incise = [&](const int i, const int r, const double p_from) -> double {
			if (lake[(size_t)i] > SUBMERGED_TOLERANCE) {
				return p_from; // under standing water: deposits, does not incise
			}
			const double zr = zz[(size_t)r];
			if (zr >= p_from) {
				return p_from; // routed across a filled basin; incising here would RAISE the cell
			}
			const int dx = (i % gw) - (r % gw);
			const int dz = (i / gw) - (r / gw);
			const double len = (dx != 0 && dz != 0) ? diag : cell;
			const double kp = kdt * (double)erod[(size_t)i] * std::pow(area[(size_t)i], m) / len;
			const double zn = (p_from + kp * zr) / (1.0 + kp);
			return std::max(zn, zr); // §4.3: never incise below the receiver
		};

		if (kdt > 0.0 && !has_dep) {
			for (size_t k = 0; k < stack.size(); k++) {
				const int i = stack[k];
				const int r = receiver[(size_t)i];
				if (r == i || boundary[(size_t)i]) {
					continue;
				}
				zz[(size_t)i] = incise(i, r, zz[(size_t)i]);
			}
		} else if (kdt > 0.0) {
			// ---- 4.3b Stream power WITH deposition (Yuan et al. 2019) ----------------------------
			//
			// A cell receives `G * Qs / A` metres of sediment, where Qs is everything its catchment shed
			// this step. Qs depends on the new elevations upstream, which depend on their own deposition,
			// so one downstream sweep cannot close it: the step is iterated to a fixed point.
			//
			// Deposition is applied to `elev` BEFORE incision, so a cell that gains material can then be
			// cut back into — which is what lays a fan down and then lets the channel re-cross it.
			//
			// The three guards live in `incise` and gate the INCISION only. Deposition applies whatever
			// they say, and that is deliberate: a cell under standing water is precisely where sediment
			// settles, so a lake must be allowed to fill even though it must not be allowed to cut.
			double zmax_abs = 0.0;
			for (int64_t i = 0; i < n; i++) {
				ht[(size_t)i] = zz[(size_t)i];
				hp[(size_t)i] = zz[(size_t)i];
				sed[(size_t)i] = 0.0;
				zmax_abs = std::max(zmax_abs, std::fabs(zz[(size_t)i]));
			}
			const double tol = DEPOSITION_TOL_REL * zmax_abs + DEPOSITION_TOL_ABS;
			int sweeps = 0;
			while (sweeps < DEPOSITION_SWEEPS_MAX) {
				sweeps++;
				for (size_t k = 0; k < stack.size(); k++) {
					const int i = stack[k];
					const int r = receiver[(size_t)i];
					if (r == i || boundary[(size_t)i]) {
						continue; // a boundary cell is fixed base level: sediment leaves through it
					}
					// `sed` carries this cell's own erosion as well as its catchment's, so its own share
					// comes back off — a cell does not deposit the material it just shed itself.
					const double own = ht[(size_t)i] - hp[(size_t)i];
					const double upstream = sed[(size_t)i] - own;
					const double elev = ht[(size_t)i] +
							g_dep * cell_area * upstream / area[(size_t)i];
					zz[(size_t)i] = incise(i, r, elev);
				}
				// Fixed-point test on the sweep's own movement, then re-accumulate the drainage tree's
				// sediment for the next one. Leaves first, exactly as the drainage-area pass runs.
				double err2 = 0.0;
				for (int64_t i = 0; i < n; i++) {
					const double d = zz[(size_t)i] - hp[(size_t)i];
					err2 += d * d;
					hp[(size_t)i] = zz[(size_t)i];
					sed[(size_t)i] = ht[(size_t)i] - zz[(size_t)i];
				}
				for (size_t k = stack.size(); k-- > 0;) {
					const int i = stack[k];
					const int r = receiver[(size_t)i];
					if (r != i) {
						sed[(size_t)r] += sed[(size_t)i];
					}
				}
				if (std::sqrt(err2 / (double)n) <= tol) {
					break;
				}
			}
			out.deposition_sweeps = std::max(out.deposition_sweeps, sweeps);
			if (sweeps >= DEPOSITION_SWEEPS_MAX) {
				out.deposition_capped = true;
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
