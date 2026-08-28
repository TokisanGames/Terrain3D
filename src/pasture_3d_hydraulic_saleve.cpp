// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_hydraulic_saleve.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <numeric>
#include <vector>

using namespace godot;

HydraulicSaleveParams HydraulicSaleveParams::from_dict(const Dictionary &p_dict) {
	HydraulicSaleveParams p;
	if (p_dict.has("iterations")) {
		p.iterations = std::max(1, (int)p_dict["iterations"]);
	}
	if (p_dict.has("incision_rate")) {
		p.incision_rate = std::max(0.0f, (float)p_dict["incision_rate"]);
	}
	if (p_dict.has("joint_azimuth")) {
		p.joint_azimuth = (float)p_dict["joint_azimuth"];
	}
	if (p_dict.has("joint_strength")) {
		p.joint_strength = std::clamp((float)p_dict["joint_strength"], 0.0f, 1.0f);
	}
	if (p_dict.has("ridge_preservation")) {
		p.ridge_preservation = std::clamp((float)p_dict["ridge_preservation"], 0.0f, 1.0f);
	}
	if (p_dict.has("deposition_rate")) {
		p.deposition_rate = std::clamp((float)p_dict["deposition_rate"], 0.0f, 1.0f);
	}
	if (p_dict.has("bank_smoothing")) {
		p.bank_smoothing = std::clamp((float)p_dict["bank_smoothing"], 0.0f, 0.5f);
	}
	if (p_dict.has("mask")) {
		p.mask = p_dict["mask"];
	}
	return p;
}

Dictionary HydraulicSaleveResult::to_dict() const {
	Dictionary d;
	d["ok"] = ok;
	d["height"] = height;
	d["eroded_rock"] = eroded_rock;
	d["sediment"] = sediment;
	return d;
}

HydraulicSaleveResult godot::hydraulic_saleve_solve(const PackedFloat32Array &p_surface,
		int p_gw, int p_gh, const Rect2 &p_rect, const HydraulicSaleveParams &p_params) {
	HydraulicSaleveResult res;
	if (p_gw < 2 || p_gh < 2) {
		return res;
	}
	const int n = p_gw * p_gh;
	if (p_surface.size() != n) {
		return res;
	}

	const float *src_height = p_surface.ptr();
	std::vector<float> height(src_height, src_height + n);
	std::vector<float> eroded_rock(n, 0.0f);
	std::vector<float> sediment(n, 0.0f);

	const bool has_mask = (p_params.mask.size() == n);
	const float *mask_ptr = has_mask ? p_params.mask.ptr() : nullptr;

	const int iterations = std::max(1, p_params.iterations);
	const double incision_rate = (double)p_params.incision_rate;
	const double joint_azimuth = (double)p_params.joint_azimuth;
	const double joint_strength = (double)p_params.joint_strength;
	const double ridge_preservation = (double)p_params.ridge_preservation;
	const double deposition_rate = (double)p_params.deposition_rate;
	const double bank_smoothing = (double)p_params.bank_smoothing;

	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
	const double diag_dist = std::sqrt(dx * dx + dz * dz);

	const int n_dx[8] = { -1, 1, 0, 0, -1, 1, -1, 1 };
	const int n_dz[8] = { 0, 0, -1, 1, -1, -1, 1, 1 };
	const double n_dist[8] = { dx, dx, dz, dz, diag_dist, diag_dist, diag_dist, diag_dist };

	// Precompute joint vector and neighbor alignments
	const double pi = 3.14159265358979323846;
	const double joint_rad = joint_azimuth * (pi / 180.0);
	const double joint_ux = std::sin(joint_rad);
	const double joint_uz = -std::cos(joint_rad);
	double joint_weights[8];
	for (int k = 0; k < 8; k++) {
		double nx_dir = (double)n_dx[k] * dx / n_dist[k];
		double nz_dir = (double)n_dz[k] * dz / n_dist[k];
		double dot = std::fabs(nx_dir * joint_ux + nz_dir * joint_uz);
		joint_weights[k] = (1.0 - joint_strength) + joint_strength * dot;
	}

	std::vector<int> order(n);

	for (int pass_idx = 0; pass_idx < iterations; pass_idx++) {
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

		// 2. Accumulate drainage flow with joint-biased weighting
		std::vector<float> current_flow(n, 1.0f);
		std::vector<float> current_sediment(n, 0.0f);

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
						double weighted_drop = std::pow(drop, 1.2) * joint_weights[k];
						drops[k] = weighted_drop;
						sum_drop += weighted_drop;
					}
				}
			}

			if (sum_drop > 1.0e-6) {
				double my_flow = (double)current_flow[idx];
				double my_sed = (double)current_sediment[idx];
				for (int k = 0; k < 8; k++) {
					if (drops[k] > 0.0) {
						int nx = cx + n_dx[k];
						int nz = cz + n_dz[k];
						int n_idx = nz * p_gw + nx;
						double frac = drops[k] / sum_drop;
						current_flow[n_idx] = (float)((double)current_flow[n_idx] + my_flow * frac);
						current_sediment[n_idx] = (float)((double)current_sediment[n_idx] + my_sed * frac);
					}
				}
			}
		}

		// 3. Compute Salève Incision with Ridge Curvature Shielding & Lateral Bank Spreading
		std::vector<double> incision_map(n, 0.0);
		std::vector<double> dep_map(n, 0.0);

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

				// 2D discrete Laplacian curvature
				double lap = ((double)h_l + (double)h_r - 2.0 * (double)h_c) / (dx * dx) +
						((double)h_u + (double)h_d - 2.0 * (double)h_c) / (dz * dz);
				double ridge_shield = 1.0;
				if (lap < 0.0) {
					ridge_shield = std::max(0.0, 1.0 - ridge_preservation * std::clamp(-lap * dx * 0.5, 0.0, 1.0));
				}

				double flow_val = (double)current_flow[idx];
				double a_accum = std::log(1.0 + std::max(0.0, flow_val - 1.0));

				if (a_accum > 0.01 && slope > 1.0e-5) {
					double power = std::sqrt(a_accum) * slope;
					double incision = incision_rate * std::log(1.0 + power) * ridge_shield * m_val;

					double center_w = 1.0 - bank_smoothing * 0.6;
					double neigh_w = (bank_smoothing * 0.6) * 0.25;

					incision_map[idx] += incision * center_w;
					if (ix > 0) incision_map[row + ix - 1] += incision * neigh_w;
					if (ix < p_gw - 1) incision_map[row + ix + 1] += incision * neigh_w;
					if (iz > 0) incision_map[(iz - 1) * p_gw + ix] += incision * neigh_w;
					if (iz < p_gh - 1) incision_map[(iz + 1) * p_gw + ix] += incision * neigh_w;

					current_sediment[idx] = (float)((double)current_sediment[idx] + incision);
				}

				// Deposition in flat / low-slope basins
				if (slope < 0.2 && current_sediment[idx] > 0.0f) {
					double dep = deposition_rate * (double)current_sediment[idx] * (1.0 - slope / 0.2) * m_val;
					dep_map[idx] += dep;
					current_sediment[idx] = (float)std::max(0.0, (double)current_sediment[idx] - dep);
				}
			}
		}

		// 4. Apply incision & deposition
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
				double dep = dep_map[idx];

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
					eroded_rock[idx] = (float)((double)eroded_rock[idx] + cut);
				}

				double h_next = (double)h_c - cut + dep;
				next_height[idx] = (float)h_next;
				sediment[idx] = (float)((double)sediment[idx] + dep);
			}
		}

		height = next_height;
	}

	res.ok = true;
	res.height.resize(n);
	std::memcpy(res.height.ptrw(), height.data(), n * sizeof(float));

	res.eroded_rock.resize(n);
	std::memcpy(res.eroded_rock.ptrw(), eroded_rock.data(), n * sizeof(float));

	res.sediment.resize(n);
	std::memcpy(res.sediment.ptrw(), sediment.data(), n * sizeof(float));

	return res;
}
