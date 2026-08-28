// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_curvature.h"
#include "pasture_3d_thread_pool.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <mutex>
#include <vector>

using namespace godot;

namespace {

inline double smoothstep(double p_from, double p_to, double p_weight) {
	if (std::abs(p_from - p_to) <= 1e-7) {
		return p_from;
	}
	const double x = std::clamp((p_weight - p_from) / (p_to - p_from), 0.0, 1.0);
	return x * x * (3.0 - 2.0 * x);
}

} // namespace

PackedFloat32Array godot::curvature_solve(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		CurvatureMode p_mode, int p_radius, double p_contrast) {
	const int n = p_gw * p_gh;
	PackedFloat32Array result;
	result.resize(n);
	if (p_surface.size() != n || n <= 0) {
		return result;
	}

	const float *src = p_surface.ptr();
	const int r = std::max(1, p_radius);

	std::vector<double> raw_curv(n, 0.0);
	double max_val = 0.0;
	std::mutex max_mutex;

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		double local_max = 0.0;
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			for (int ix = 0; ix < p_gw; ix++) {
				const int i = row + ix;
				const float c_f = src[i];
				if (!std::isfinite(c_f)) {
					continue;
				}
				const double c = (double)c_f;

				double hxm;
				if (ix - r >= 0) {
					hxm = (double)src[row + (ix - r)];
				} else {
					const float opp = src[row + std::min(ix + r, p_gw - 1)];
					hxm = std::isfinite(opp) ? (2.0 * c - (double)opp) : c;
				}

				double hxp;
				if (ix + r < p_gw) {
					hxp = (double)src[row + (ix + r)];
				} else {
					const float opp = src[row + std::max(ix - r, 0)];
					hxp = std::isfinite(opp) ? (2.0 * c - (double)opp) : c;
				}

				double hzm;
				if (iz - r >= 0) {
					hzm = (double)src[(iz - r) * p_gw + ix];
				} else {
					const float opp = src[std::min(iz + r, p_gh - 1) * p_gw + ix];
					hzm = std::isfinite(opp) ? (2.0 * c - (double)opp) : c;
				}

				double hzp;
				if (iz + r < p_gh) {
					hzp = (double)src[(iz + r) * p_gw + ix];
				} else {
					const float opp = src[std::max(iz - r, 0) * p_gw + ix];
					hzp = std::isfinite(opp) ? (2.0 * c - (double)opp) : c;
				}

				if (!std::isfinite(hxm)) hxm = c;
				if (!std::isfinite(hxp)) hxp = c;
				if (!std::isfinite(hzm)) hzm = c;
				if (!std::isfinite(hzp)) hzp = c;

				const double laplacian = (hxm + hxp + hzm + hzp) * 0.25 - c;
				double val = 0.0;

				switch (p_mode) {
					case CurvatureMode::CONVEXITY_RIDGE:
						val = std::max(-laplacian, 0.0);
						break;
					case CurvatureMode::CONCAVITY_VALLEY:
						val = std::max(laplacian, 0.0);
						break;
					case CurvatureMode::TOTAL_CURVATURE:
						val = std::abs(laplacian);
						break;
				}

				raw_curv[i] = val;
				if (val > local_max) {
					local_max = val;
				}
			}
		}
		if (local_max > 0.0) {
			std::lock_guard<std::mutex> lock(max_mutex);
			if (local_max > max_val) {
				max_val = local_max;
			}
		}
	});

	float *dst = result.ptrw();
	if (max_val < 1e-5) {
		std::fill(dst, dst + n, 0.0f);
		return result;
	}

	const double contrast = std::max(p_contrast, 0.01);

	Pasture3DThreadPool::parallel_for_elements(n, 1024, [&](int i0, int i1) {
		for (int i = i0; i < i1; i++) {
			if (std::isfinite(src[i])) {
				const double norm = std::clamp((raw_curv[i] / max_val) * contrast, 0.0, 1.0);
				dst[i] = (float)smoothstep(0.0, 1.0, norm);
			} else {
				dst[i] = 0.0f;
			}
		}
	});

	return result;
}
