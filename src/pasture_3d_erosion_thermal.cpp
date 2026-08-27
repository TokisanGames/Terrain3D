// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_erosion_thermal.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

using namespace godot;

namespace {

struct OffsetEntry {
	int dx;
	int dy;
	double dist;
};

inline double deg_to_rad(double p_deg) {
	return p_deg * (Math_PI / 180.0);
}

} // namespace

Dictionary ErosionThermalResult::to_dict() const {
	Dictionary d;
	d["ok"] = ok;
	d["height"] = height;
	d["talus"] = talus;
	return d;
}

ErosionThermalResult godot::erosion_thermal_solve(const PackedFloat32Array &p_surface,
		const PackedFloat32Array &p_hardness, int p_gw, int p_gh, const Rect2 &p_rect,
		double p_talus_angle_deg, int p_iterations, double p_settling_rate) {
	ErosionThermalResult res;
	if (p_gw < 1 || p_gh < 1) {
		return res;
	}
	const int n = p_gw * p_gh;
	if (p_surface.size() != n) {
		return res;
	}

	const float *src_h = p_surface.ptr();
	const float *src_hard = (p_hardness.size() == n) ? p_hardness.ptr() : nullptr;

	std::vector<float> height(src_h, src_h + n);
	std::vector<float> talus_accum(n, 0.0f);

	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
	const double diag_dist = std::sqrt(dx * dx + dz * dz);

	const double tan_talus = std::tan(deg_to_rad(p_talus_angle_deg));

	const int n_dx[8] = { -1, 1, 0, 0, -1, 1, -1, 1 };
	const int n_dz[8] = { 0, 0, -1, 1, -1, -1, 1, 1 };
	const double n_dist[8] = { dx, dx, dz, dz, diag_dist, diag_dist, diag_dist, diag_dist };

	for (int pass = 0; pass < p_iterations; pass++) {
		std::vector<float> next_height = height;

		for (int iz = 0; iz < p_gh; iz++) {
			const int row = iz * p_gw;
			for (int ix = 0; ix < p_gw; ix++) {
				const int i = row + ix;
				const double h_c = (double)height[i];
				if (!std::isfinite(h_c)) {
					continue;
				}

				const double hard_c = src_hard ? std::clamp((double)src_hard[i], 0.0, 1.0) : 0.0;
				const double eff_tan = tan_talus * (1.0 + hard_c * 0.75);

				double excess[8] = { 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
				double total_excess = 0.0;
				double max_ex = 0.0;

				for (int k = 0; k < 8; k++) {
					const int nx = ix + n_dx[k];
					const int nz = iz + n_dz[k];
					if (nx >= 0 && nx < p_gw && nz >= 0 && nz < p_gh) {
						const int ni = nz * p_gw + nx;
						const double n_h = (double)height[ni];
						if (std::isfinite(n_h)) {
							const double diff = h_c - n_h;
							const double max_diff = n_dist[k] * eff_tan;
							if (diff > max_diff) {
								const double ex = diff - max_diff;
								excess[k] = ex;
								total_excess += ex;
								if (ex > max_ex) {
									max_ex = ex;
								}
							}
						}
					}
				}

				if (total_excess > 0.0) {
					const double slip_amt = std::clamp(max_ex * 0.5 * p_settling_rate, 0.0, total_excess * 0.5);
					next_height[i] = (float)((double)next_height[i] - slip_amt);

					for (int k = 0; k < 8; k++) {
						if (excess[k] > 0.0) {
							const double frac = excess[k] / total_excess;
							const double moved = slip_amt * frac;
							const int ni = (iz + n_dz[k]) * p_gw + (ix + n_dx[k]);
							next_height[ni] = (float)((double)next_height[ni] + moved);
							talus_accum[ni] = (float)((double)talus_accum[ni] + moved);
						}
					}
				}
			}
		}

		height = std::move(next_height);
	}

	double max_talus = 1e-6;
	for (int i = 0; i < n; i++) {
		if (std::isfinite(height[i])) {
			max_talus = std::max(max_talus, (double)talus_accum[i]);
		}
	}

	res.height.resize(n);
	res.talus.resize(n);

	float *out_h = res.height.ptrw();
	float *out_t = res.talus.ptrw();

	for (int i = 0; i < n; i++) {
		if (std::isfinite(height[i])) {
			out_h[i] = height[i];
			out_t[i] = (float)std::clamp((double)talus_accum[i] / max_talus, 0.0, 1.0);
		} else {
			out_h[i] = height[i];
			out_t[i] = 0.0f;
		}
	}

	res.ok = true;
	return res;
}

PackedFloat32Array godot::talus_projection_solve(const PackedFloat32Array &p_surface,
		const PackedFloat32Array &p_mask, int p_gw, int p_gh, const Rect2 &p_rect,
		double p_talus_angle_deg, int p_iterations, double p_transfer_rate, double p_amount) {
	const int n = p_gw * p_gh;
	if (p_surface.size() != n || n <= 0) {
		PackedFloat32Array empty;
		empty.resize(n);
		return empty;
	}

	if (p_amount <= 1e-6 || p_iterations <= 0) {
		return p_surface.duplicate();
	}

	const float *src_h = p_surface.ptr();
	const float *src_m = (p_mask.size() == n) ? p_mask.ptr() : nullptr;

	std::vector<float> h(src_h, src_h + n);

	const double dx = (p_rect.size.x > 0.0 && p_gw > 1) ? ((double)p_rect.size.x / std::max((double)(p_gw - 1), 1.0)) : 2.0;
	const double dz = (p_rect.size.y > 0.0 && p_gh > 1) ? ((double)p_rect.size.y / std::max((double)(p_gh - 1), 1.0)) : 2.0;
	const double diag_d = std::sqrt(dx * dx + dz * dz);

	const double tan_talus = std::tan(deg_to_rad(p_talus_angle_deg));
	const double rate = p_transfer_rate * 0.25;

	const OffsetEntry offsets[8] = {
		{ -1, 0, dx }, { 1, 0, dx },
		{ 0, -1, dz }, { 0, 1, dz },
		{ -1, -1, diag_d }, { 1, -1, diag_d },
		{ -1, 1, diag_d }, { 1, 1, diag_d }
	};

	std::vector<double> delta(n, 0.0);

	for (int iter = 0; iter < p_iterations; iter++) {
		std::fill(delta.begin(), delta.end(), 0.0);

		for (int iz = 0; iz < p_gh; iz++) {
			const int row = iz * p_gw;
			for (int ix = 0; ix < p_gw; ix++) {
				const int i = row + ix;
				const double hi = (double)h[i];
				if (!std::isfinite(hi)) {
					continue;
				}

				for (int k = 0; k < 8; k++) {
					const int nx = ix + offsets[k].dx;
					const int nz = iz + offsets[k].dy;
					if (nx < 0 || nx >= p_gw || nz < 0 || nz >= p_gh) {
						continue;
					}

					const int ni = nz * p_gw + nx;
					const double hni = (double)h[ni];
					if (!std::isfinite(hni)) {
						continue;
					}

					const double diff = hi - hni;
					const double max_diff = offsets[k].dist * tan_talus;

					if (diff > max_diff) {
						const double excess = (diff - max_diff) * rate;
						delta[i] -= excess;
						delta[ni] += excess;
					}
				}
			}
		}

		for (int i = 0; i < n; i++) {
			if (std::isfinite(h[i])) {
				h[i] = (float)((double)h[i] + delta[i]);
			}
		}
	}

	PackedFloat32Array out;
	out.resize(n);
	float *dst = out.ptrw();

	for (int i = 0; i < n; i++) {
		if (std::isfinite(src_h[i]) && std::isfinite(h[i])) {
			const double m = src_m ? std::clamp((double)src_m[i], 0.0, 1.0) : 1.0;
			dst[i] = (float)((double)src_h[i] + ((double)h[i] - (double)src_h[i]) * (p_amount * m));
		} else {
			dst[i] = src_h[i];
		}
	}

	return out;
}
