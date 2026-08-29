// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_hydraulic_stream_log.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <numeric>
#include <vector>

using namespace godot;

HydraulicStreamLogParams HydraulicStreamLogParams::from_dict(const Dictionary &p_dict) {
	HydraulicStreamLogParams p;
	if (p_dict.has("iterations")) {
		p.iterations = std::max(1, (int)p_dict["iterations"]);
	}
	if (p_dict.has("incision_rate")) {
		p.incision_rate = std::max(0.0f, (float)p_dict["incision_rate"]);
	}
	if (p_dict.has("area_exponent")) {
		p.area_exponent = std::clamp((float)p_dict["area_exponent"], 0.01f, 2.0f);
	}
	if (p_dict.has("slope_exponent")) {
		p.slope_exponent = std::clamp((float)p_dict["slope_exponent"], 0.01f, 2.0f);
	}
	if (p_dict.has("min_catchment")) {
		p.min_catchment = std::max(0.0f, (float)p_dict["min_catchment"]);
	}
	if (p_dict.has("bank_smoothing")) {
		p.bank_smoothing = std::clamp((float)p_dict["bank_smoothing"], 0.0f, 0.5f);
	}
	if (p_dict.has("peak_preservation")) {
		p.peak_preservation = std::clamp((float)p_dict["peak_preservation"], 0.0f, 1.0f);
	}
	if (p_dict.has("gradient_power")) {
		p.gradient_power = std::clamp((float)p_dict["gradient_power"], 0.1f, 2.0f);
	}
	if (p_dict.has("mask")) {
		p.mask = p_dict["mask"];
	}
	return p;
}

Dictionary HydraulicStreamLogResult::to_dict() const {
	Dictionary d;
	d["ok"] = ok;
	d["height"] = height;
	d["channel_mask"] = channel_mask;
	d["flow_accumulation"] = flow_accumulation;
	return d;
}

HydraulicStreamLogResult godot::hydraulic_stream_log_solve(const PackedFloat32Array &p_surface,
		int p_gw, int p_gh, const Rect2 &p_rect, const HydraulicStreamLogParams &p_params) {
	HydraulicStreamLogResult res;
	if (p_gw < 2 || p_gh < 2) {
		return res;
	}
	const int n = p_gw * p_gh;
	if (p_surface.size() != n) {
		return res;
	}

	const float *src_height = p_surface.ptr();
	std::vector<float> height(src_height, src_height + n);
	std::vector<float> channel_mask(n, 0.0f);
	std::vector<float> flow_accum(n, 0.0f);

	const bool has_mask = (p_params.mask.size() == n);
	const float *mask_ptr = has_mask ? p_params.mask.ptr() : nullptr;

	const int iterations = std::max(1, p_params.iterations);
	const double incision_rate = (double)p_params.incision_rate;
	const double area_exponent = (double)p_params.area_exponent;
	const double slope_exponent = (double)p_params.slope_exponent;
	const double min_catchment = (double)p_params.min_catchment;
	const double bank_smoothing = (double)p_params.bank_smoothing;
	const double peak_preservation = (double)p_params.peak_preservation;
	const double gradient_power = (double)p_params.gradient_power;

	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
	const double diag_dist = std::sqrt(dx * dx + dz * dz);

	const int n_dx[8] = { -1, 1, 0, 0, -1, 1, -1, 1 };
	const int n_dz[8] = { 0, 0, -1, 1, -1, -1, 1, 1 };
	const double n_dist[8] = { dx, dx, dz, dz, diag_dist, diag_dist, diag_dist, diag_dist };

	std::vector<int> order(n);

	for (int pass = 0; pass < iterations; pass++) {
		// 1. Sort indices descending by elevation
		for (int i = 0; i < n; i++) {
			order[i] = i;
		}

		std::sort(order.begin(), order.end(), [&height](int a, int b) {
			float ha = height[a];
			float hb = height[b];
			if (!std::isfinite(ha)) return false;
			if (!std::isfinite(hb)) return true;
			return ha > hb;
		});

		// 2. Accumulate drainage flow using MD8 multi-direction routing
		std::vector<float> current_flow(n, 1.0f);

		for (int idx : order) {
			float h_c = height[idx];
			if (!std::isfinite(h_c)) {
				continue;
			}
			int cx = idx % p_gw;
			int cz = idx / p_gw;

			double sum_drop = 0.0;
			double drops[8] = { 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };

			for (int k = 0; k < 8; k++) {
				int nx = cx + n_dx[k];
				int nz = cz + n_dz[k];
				if (nx >= 0 && nx < p_gw && nz >= 0 && nz < p_gh) {
					int n_idx = nz * p_gw + nx;
					float h_n = height[n_idx];
					if (std::isfinite(h_n) && h_n < h_c) {
						double drop = (double)(h_c - h_n) / n_dist[k];
						double weighted_drop = std::pow(drop, 1.3);
						drops[k] = weighted_drop;
						sum_drop += weighted_drop;
					}
				}
			}

			if (sum_drop > 1.0e-6) {
				double my_flow = (double)current_flow[idx];
				for (int k = 0; k < 8; k++) {
					if (drops[k] > 0.0) {
						int nx = cx + n_dx[k];
						int nz = cz + n_dz[k];
						int n_idx = nz * p_gw + nx;
						double frac = drops[k] / sum_drop;
						current_flow[n_idx] = (float)((double)current_flow[n_idx] + my_flow * frac);
					}
				}
			}
		}

		// 3. Compute Logarithmic Stream-Power Incision with lateral bank spreading & Hesiod peak preservation
		std::vector<double> incision_map(n, 0.0);

		for (int iz = 0; iz < p_gh; iz++) {
			int row = iz * p_gw;
			for (int ix = 0; ix < p_gw; ix++) {
				int idx = row + ix;
				float h_c = height[idx];
				if (!std::isfinite(h_c)) {
					continue;
				}

				double m_val = has_mask ? (double)mask_ptr[idx] : 1.0;
				if (m_val <= 0.001) {
					continue;
				}

				float h_l = (ix > 0 && std::isfinite(height[row + ix - 1])) ? height[row + ix - 1] : h_c;
				float h_r = (ix < p_gw - 1 && std::isfinite(height[row + ix + 1])) ? height[row + ix + 1] : h_c;
				float h_u = (iz > 0 && std::isfinite(height[(iz - 1) * p_gw + ix])) ? height[(iz - 1) * p_gw + ix] : h_c;
				float h_d = (iz < p_gh - 1 && std::isfinite(height[(iz + 1) * p_gw + ix])) ? height[(iz + 1) * p_gw + ix] : h_c;

				double gx = (double)(h_r - h_l) / (2.0 * dx);
				double gz = (double)(h_d - h_u) / (2.0 * dz);
				double slope = std::sqrt(gx * gx + gz * gz);

				// Hesiod gradient power shaping
				double shaped_slope = (gradient_power != 1.0) ? std::pow(slope, gradient_power) : slope;

				// Hesiod relative elevation peak preservation kernel (radius 2)
				double peak_weight = 1.0;
				if (peak_preservation > 0.0) {
					float min_local = h_c;
					float max_local = h_c;
					for (int rz = std::max(0, iz - 2); rz <= std::min(p_gh - 1, iz + 2); rz++) {
						for (int rx = std::max(0, ix - 2); rx <= std::min(p_gw - 1, ix + 2); rx++) {
							float val = height[rz * p_gw + rx];
							if (std::isfinite(val)) {
								if (val < min_local) min_local = val;
								if (val > max_local) max_local = val;
							}
						}
					}
					double range = (double)(max_local - min_local);
					if (range > 1.0e-4) {
						double re = ((double)h_c - (double)min_local) / range;
						double s_re = re * re * (3.0 - 2.0 * re); // smoothstep3
						peak_weight = (1.0 - peak_preservation) + peak_preservation * (1.0 - s_re);
					}
				}

				// Smooth softplus transition for catchment activation
				double diff = (double)current_flow[idx] - min_catchment;
				double a_accum = (diff > 15.0) ? diff : ((diff > -15.0) ? std::log(1.0 + std::exp(diff)) : 0.0);

				if (a_accum > 0.01 && slope > 1.0e-5) {
					double power = std::pow(a_accum, area_exponent) * std::pow(shaped_slope, slope_exponent);
					double incision = incision_rate * std::log(1.0 + power) * peak_weight * m_val;

					// Lateral bank spreading to create smooth V/U shaped channels
					double center_weight = 1.0 - bank_smoothing * 0.6;
					double neighbor_weight = (bank_smoothing * 0.6) * 0.25;

					incision_map[idx] += incision * center_weight;
					if (ix > 0) incision_map[row + ix - 1] += incision * neighbor_weight;
					if (ix < p_gw - 1) incision_map[row + ix + 1] += incision * neighbor_weight;
					if (iz > 0) incision_map[(iz - 1) * p_gw + ix] += incision * neighbor_weight;
					if (iz < p_gh - 1) incision_map[(iz + 1) * p_gw + ix] += incision * neighbor_weight;
				}

				flow_accum[idx] = current_flow[idx];
			}
		}

		// 4. Apply incision with base-level descent clamping
		std::vector<float> next_height = height;
		for (int iz = 0; iz < p_gh; iz++) {
			int row = iz * p_gw;
			for (int ix = 0; ix < p_gw; ix++) {
				int idx = row + ix;
				float h_c = height[idx];
				if (!std::isfinite(h_c)) {
					continue;
				}

				double cut = incision_map[idx];
				if (cut > 0.0) {
					int cx = ix;
					int cz = iz;
					float min_downhill = h_c;
					for (int k = 0; k < 8; k++) {
						int nx = cx + n_dx[k];
						int nz = cz + n_dz[k];
						if (nx >= 0 && nx < p_gw && nz >= 0 && nz < p_gh) {
							float h_n = height[nz * p_gw + nx];
							if (std::isfinite(h_n) && h_n < min_downhill) {
								min_downhill = h_n;
							}
						}
					}

					double max_cut = std::max(0.0, (double)(h_c - min_downhill) + 0.05 * cut);
					cut = std::min(cut, max_cut);
					next_height[idx] = (float)((double)h_c - cut);
					float normalized_cut = std::clamp((float)(cut / (incision_rate * 2.0 + 1.0e-5)), 0.0f, 1.0f);
					channel_mask[idx] = std::max(channel_mask[idx], normalized_cut);
				}
			}
		}

		height = next_height;
	}

	res.ok = true;
	res.height.resize(n);
	std::memcpy(res.height.ptrw(), height.data(), n * sizeof(float));

	res.channel_mask.resize(n);
	std::memcpy(res.channel_mask.ptrw(), channel_mask.data(), n * sizeof(float));

	res.flow_accumulation.resize(n);
	std::memcpy(res.flow_accumulation.ptrw(), flow_accum.data(), n * sizeof(float));

	return res;
}
