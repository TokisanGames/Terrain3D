// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_warp_downslope.h"
#include "pasture_3d_terrain_metrics.h"
#include "pasture_3d_transform.h"

#include <algorithm>
#include <cmath>

using namespace godot;

namespace {

// Below this the "downhill direction" is numerical noise rather than a direction, and moving a cell along
// it would be moving it at random. A metric threshold, so it means the same thing at every resolution:
// one part in ten thousand of rise over run.
constexpr double GRADIENT_EPSILON = 1.0e-4;

} // namespace

PackedFloat32Array godot::warp_downslope_solve(const PackedFloat32Array &p_surface,
		const PackedFloat32Array &p_mask, int p_gw, int p_gh, const Rect2 &p_rect,
		double p_displacement_m, double p_radius_m, bool p_reverse, double p_amount) {
	const int n = p_gw * p_gh;
	PackedFloat32Array out;
	if (p_gw <= 0 || p_gh <= 0 || p_surface.size() != n) {
		return out;
	}
	out.resize(n);

	const float *src = p_surface.ptr();
	if (p_amount <= 0.0 || std::abs(p_displacement_m) <= 0.0) {
		std::copy_n(src, n, out.ptrw());
		return out;
	}

	// The gradient is read off a SMOOTHED copy, not the raw surface. Reading it raw makes the warp chase
	// per-cell noise, which is exactly the direction-unrelated-to-terrain behaviour this node exists to
	// avoid. box_mean_solve is the same separable blur SmoothFill uses, so "radius" means one thing.
	const PackedFloat32Array smoothed = (p_radius_m > 0.0)
			? box_mean_solve(p_surface, p_gw, p_gh, p_rect, p_radius_m)
			: p_surface;
	const float *sm = smoothed.ptr();

	const bool have_mask = (p_mask.size() == n);
	const float *mk = have_mask ? p_mask.ptr() : nullptr;

	const double dx = (double)p_rect.size.x / (double)p_gw;
	const double dz = (double)p_rect.size.y / (double)p_gh;
	// SAMPLE UPHILL so the SURFACE moves downhill. A resample is a backward map: out(x) = in(x + d)
	// shifts the pattern by -d. Sampling at the downhill point would drag the terrain UPHILL, which is
	// the opposite of what this node is for, and it is an easy sign to get wrong because the offset
	// vector then "points downhill" and reads correct.
	const double sign = p_reverse ? -1.0 : 1.0;
	float *dst = out.ptrw();

	for (int iz = 0; iz < p_gh; iz++) {
		for (int ix = 0; ix < p_gw; ix++) {
			const int i = iz * p_gw + ix;
			const double z = (double)src[i];
			if (!std::isfinite(z)) {
				dst[i] = (float)z; // NaN is the brush-loop mask; it stays put and stays NaN.
				continue;
			}

			const int xm = std::max(ix - 1, 0);
			const int xp = std::min(ix + 1, p_gw - 1);
			const int zm = std::max(iz - 1, 0);
			const int zp = std::min(iz + 1, p_gh - 1);
			const double sxm = (double)sm[iz * p_gw + xm];
			const double sxp = (double)sm[iz * p_gw + xp];
			const double szm = (double)sm[zm * p_gw + ix];
			const double szp = (double)sm[zp * p_gw + ix];
			if (!std::isfinite(sxm) || !std::isfinite(sxp) || !std::isfinite(szm) || !std::isfinite(szp)) {
				dst[i] = (float)z;
				continue;
			}

			// Metric gradients: rise in metres over run in metres. Dividing by cell counts instead would
			// make the displacement direction correct but its magnitude resolution-dependent.
			const double gx = (sxp - sxm) / ((double)(xp - xm) * dx);
			const double gz = (szp - szm) / ((double)(zp - zm) * dz);
			const double mag = std::sqrt(gx * gx + gz * gz);
			if (mag <= GRADIENT_EPSILON) {
				dst[i] = (float)z;
				continue;
			}

			double w = p_amount;
			if (have_mask) {
				const double m = (double)mk[i];
				w *= std::isfinite(m) ? std::clamp(m, 0.0, 1.0) : 0.0;
			}
			if (w <= 0.0) {
				dst[i] = (float)z;
				continue;
			}

			// Displace in METRES, then convert to cells for the tap. Doing the whole thing in cells is the
			// `talus / shape.x` trap in another costume: the warp would get stronger every time the bake
			// resolution rose.
			const double step = p_displacement_m * w * sign;
			const double ox = (gx / mag) * step / dx;
			const double oz = (gz / mag) * step / dz;

			dst[i] = (float)transform_sample_bilinear(src, (double)ix + ox, (double)iz + oz, p_gw, p_gh,
					TRANSFORM_EDGE_CLAMP);
		}
	}
	return out;
}
