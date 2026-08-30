// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_distance_transform.h"
#include "pasture_3d_thread_pool.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

using namespace godot;

namespace {

// A seed site, stored as the grid coordinate of the nearest "inside" cell found so far. NO_SITE means
// nothing adopted yet, which is the JFA equivalent of infinite distance.
struct Site {
	int32_t x;
	int32_t z;
};

constexpr int32_t NO_SITE = -1;

// Metric distance in METRES between a cell and a site. dx/dz are the world size of one cell, so the
// conversion happens at the only place that measures anything — there is nowhere left to forget it.
inline double metric_distance(int ix, int iz, const Site &s, int metric, double dx, double dz) {
	const double ax = std::abs((double)(ix - s.x)) * dx;
	const double az = std::abs((double)(iz - s.z)) * dz;
	switch (metric) {
		case DISTANCE_TRANSFORM_MANHATTAN:
			return ax + az;
		case DISTANCE_TRANSFORM_CHEBYSHEV:
			return std::max(ax, az);
		case DISTANCE_TRANSFORM_EUCLIDEAN:
		default:
			return std::sqrt(ax * ax + az * az);
	}
}

// Consider one neighbour at (ix + ox * k, iz + oz * k) and keep it if it is closer.
inline void consider(const std::vector<Site> &grid, int gw, int gh, int ix, int iz, int nx, int nz,
		int metric, double dx, double dz, Site &best, double &best_d) {
	if (nx < 0 || nx >= gw || nz < 0 || nz >= gh) {
		return;
	}
	const Site cand = grid[(size_t)nz * gw + nx];
	if (cand.x == NO_SITE) {
		return;
	}
	const double d = metric_distance(ix, iz, cand, metric, dx, dz);
	if (d < best_d) {
		best_d = d;
		best = cand;
	}
}

// One jump-flooding sweep at step k: every cell considers the site held by its eight k-offset
// neighbours, keeping whichever is closest.
//
// The passes are sequential in k but every cell WITHIN a pass is independent, which is the whole reason
// this algorithm was chosen over Meijster — the same structure ports to a compute shader unchanged.
void jfa_sweep(std::vector<Site> &grid, std::vector<Site> &next, int gw, int gh, int k, int metric,
		double dx, double dz) {
	Pasture3DThreadPool::parallel_for_rows(gh, 16, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			for (int ix = 0; ix < gw; ix++) {
				const int i = iz * gw + ix;
				Site best = grid[(size_t)i];
				double best_d = (best.x == NO_SITE)
						? std::numeric_limits<double>::infinity()
						: metric_distance(ix, iz, best, metric, dx, dz);
				for (int oz = -1; oz <= 1; oz++) {
					for (int ox = -1; ox <= 1; ox++) {
						if (ox == 0 && oz == 0) {
							continue;
						}
						consider(grid, gw, gh, ix, iz, ix + ox * k, iz + oz * k, metric, dx, dz,
								best, best_d);
					}
				}
				next[(size_t)i] = best;
			}
		}
	});
	grid.swap(next);
}

void jfa_passes(std::vector<Site> &grid, int gw, int gh, int metric, double dx, double dz) {
	std::vector<Site> next(grid.size());
	int max_step = 1;
	while (max_step < std::max(gw, gh)) {
		max_step <<= 1;
	}
	for (int k = max_step / 2; k >= 1; k >>= 1) {
		jfa_sweep(grid, next, gw, gh, k, metric, dx, dz);
	}
	// JFA+1: one extra sweep at step 1. Plain JFA has rare errors at cells whose true nearest site was
	// never propagated along a power-of-two path; a repeated step-1 pass repairs the large majority of
	// them for one extra sweep. The gate's DF criterion is what decides whether this is enough.
	jfa_sweep(grid, next, gw, gh, 1, metric, dx, dz);
}

// Distance from every cell to the nearest cell whose `inside` flag equals `want`.
void distance_field(const std::vector<uint8_t> &inside, bool want, int gw, int gh, int metric,
		double dx, double dz, std::vector<double> &out) {
	const int n = gw * gh;
	std::vector<Site> sites((size_t)n);
	for (int i = 0; i < n; i++) {
		const bool is_seed = ((inside[(size_t)i] != 0) == want);
		sites[(size_t)i] = is_seed ? Site{ (int32_t)(i % gw), (int32_t)(i / gw) }
								   : Site{ NO_SITE, NO_SITE };
	}

	jfa_passes(sites, gw, gh, metric, dx, dz);

	// No seed anywhere in the field. Returning 0 would read as "every cell is on the boundary", which is
	// the opposite of the truth, so report the field diagonal as a finite stand-in for infinity. The
	// node's NO-SIGNAL warning is what tells the user this happened.
	const double fallback = std::sqrt((gw * dx) * (gw * dx) + (gh * dz) * (gh * dz));

	out.assign((size_t)n, 0.0);
	for (int iz = 0; iz < gh; iz++) {
		for (int ix = 0; ix < gw; ix++) {
			const int i = iz * gw + ix;
			const Site &s = sites[(size_t)i];
			out[(size_t)i] = (s.x == NO_SITE) ? fallback
											  : metric_distance(ix, iz, s, metric, dx, dz);
		}
	}
}

} // namespace

PackedFloat32Array godot::distance_transform_solve(const PackedFloat32Array &p_mask, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_threshold, int p_direction, int p_metric, int p_units,
		double p_max_distance, double *r_divisor_used) {
	const int n = p_gw * p_gh;
	PackedFloat32Array result;
	if (r_divisor_used) {
		*r_divisor_used = 1.0;
	}
	if (n <= 0 || p_mask.size() != n) {
		return result;
	}
	result.resize(n);

	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);

	// NaN is the brush-loop mask (spec §3.4). It is neither inside nor outside: seeding it — or refusing
	// to seed it — would both invent a boundary through a region the user explicitly excluded, and the
	// distance field would then pull a discontinuity along every loop rim.
	const float *m = p_mask.ptr();
	std::vector<uint8_t> inside((size_t)n, 0);
	std::vector<uint8_t> valid((size_t)n, 0);
	for (int i = 0; i < n; i++) {
		if (std::isfinite(m[i])) {
			valid[(size_t)i] = 1;
			inside[(size_t)i] = (m[i] > (float)p_threshold) ? 1 : 0;
		}
	}

	std::vector<double> d_out;
	std::vector<double> d_in;
	const bool need_out = (p_direction != DISTANCE_TRANSFORM_INSIDE);
	const bool need_in = (p_direction != DISTANCE_TRANSFORM_OUTSIDE);
	if (need_out) {
		distance_field(inside, true, p_gw, p_gh, p_metric, dx, dz, d_out); // distance TO inside
	}
	if (need_in) {
		distance_field(inside, false, p_gw, p_gh, p_metric, dx, dz, d_in); // distance TO outside
	}

	std::vector<double> dist((size_t)n, 0.0);
	for (int i = 0; i < n; i++) {
		switch (p_direction) {
			case DISTANCE_TRANSFORM_INSIDE:
				// Depth into the mask: 0 outside, growing toward the interior.
				dist[(size_t)i] = inside[(size_t)i] ? d_in[(size_t)i] : 0.0;
				break;
			case DISTANCE_TRANSFORM_SIGNED:
				// Positive outside, negative inside, crossing zero at the threshold contour.
				dist[(size_t)i] = inside[(size_t)i] ? -d_in[(size_t)i] : d_out[(size_t)i];
				break;
			case DISTANCE_TRANSFORM_OUTSIDE:
			default:
				dist[(size_t)i] = inside[(size_t)i] ? 0.0 : d_out[(size_t)i];
				break;
		}
	}

	if (p_max_distance > 0.0) {
		for (int i = 0; i < n; i++) {
			dist[(size_t)i] = std::clamp(dist[(size_t)i], -p_max_distance, p_max_distance);
		}
	}

	double divisor = 1.0;
	if (p_units == DISTANCE_TRANSFORM_NORMALISED) {
		if (p_max_distance > 0.0) {
			divisor = p_max_distance;
		} else {
			// Content- AND resolution-dependent by construction. The node stores this divisor and
			// surfaces it; see the calibration rule in spec §5.1.
			double hi = 0.0;
			for (int i = 0; i < n; i++) {
				hi = std::max(hi, std::abs(dist[(size_t)i]));
			}
			divisor = (hi > 1e-12) ? hi : 1.0;
		}
		for (int i = 0; i < n; i++) {
			dist[(size_t)i] /= divisor;
		}
	}
	if (r_divisor_used) {
		*r_divisor_used = divisor;
	}

	float *dst = result.ptrw();
	for (int i = 0; i < n; i++) {
		dst[i] = valid[(size_t)i] ? (float)dist[(size_t)i] : m[i]; // NaN in, NaN out.
	}
	return result;
}
