// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_hydraulic_saleve.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <numeric>
#include <vector>

using namespace godot;

namespace {

// Fast 2D coherent smooth noise generator for drainage flow perturbation
inline float hash2d(int x, int y, int seed) {
	uint32_t n = (uint32_t)(x * 73856093 ^ y * 19349663 ^ seed * 83492791);
	n = (n ^ (n >> 13)) * 0x5bd1e995;
	n ^= n >> 15;
	return ((float)(n & 0x00ffffff) / 8388608.0f) - 1.0f; // [-1.0 .. 1.0]
}

inline float smooth_noise2d(float x, float z, int seed) {
	int ix = (int)std::floor(x);
	int iz = (int)std::floor(z);
	float fx = x - (float)ix;
	float fz = z - (float)iz;

	// Quintic hermite curve
	float wx = fx * fx * fx * (fx * (fx * 6.0f - 15.0f) + 10.0f);
	float wz = fz * fz * fz * (fz * (fz * 6.0f - 15.0f) + 10.0f);

	float v00 = hash2d(ix, iz, seed);
	float v10 = hash2d(ix + 1, iz, seed);
	float v01 = hash2d(ix, iz + 1, seed);
	float v11 = hash2d(ix + 1, iz + 1, seed);

	float nx0 = v00 * (1.0f - wx) + v10 * wx;
	float nx1 = v01 * (1.0f - wx) + v11 * wx;
	return nx0 * (1.0f - wz) + nx1 * wz;
}

} // namespace

HydraulicSaleveParams HydraulicSaleveParams::from_dict(const Dictionary &p_dict) {
	HydraulicSaleveParams p;
	if (p_dict.has("iterations")) {
		p.iterations = std::max(1, (int)p_dict["iterations"]);
	}
	if (p_dict.has("erosion_strength")) {
		p.erosion_strength = std::max(0.0f, (float)p_dict["erosion_strength"]);
	} else if (p_dict.has("incision_rate")) {
		p.erosion_strength = std::max(0.0f, (float)p_dict["incision_rate"]);
	}
	if (p_dict.has("drainage_exponent")) {
		p.drainage_exponent = std::clamp((float)p_dict["drainage_exponent"], 0.01f, 1.0f);
	}
	if (p_dict.has("drainage_noise")) {
		p.drainage_noise = std::max(0.0f, (float)p_dict["drainage_noise"]);
	}
	if (p_dict.has("fine_erosion_strength")) {
		p.fine_erosion_strength = std::max(0.0f, (float)p_dict["fine_erosion_strength"]);
	}
	if (p_dict.has("shape_preservation")) {
		p.shape_preservation = std::clamp((float)p_dict["shape_preservation"], 0.0f, 2.0f);
	}
	if (p_dict.has("bank_smoothing")) {
		p.bank_smoothing = std::clamp((float)p_dict["bank_smoothing"], 0.0f, 0.5f);
	}
	if (p_dict.has("sediment_strength")) {
		p.sediment_strength = std::clamp((float)p_dict["sediment_strength"], 0.0f, 1.0f);
	}
	if (p_dict.has("seed")) {
		p.seed = (int)p_dict["seed"];
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
	const std::vector<float> original_height(src_height, src_height + n);
	std::vector<float> eroded_rock(n, 0.0f);
	std::vector<float> sediment(n, 0.0f);

	const bool has_mask = (p_params.mask.size() == n);
	const float *mask_ptr = has_mask ? p_params.mask.ptr() : nullptr;

	const int iterations = std::max(1, p_params.iterations);
	const double erosion_strength = (double)p_params.erosion_strength;
	const double drainage_exponent = (double)p_params.drainage_exponent;
	const double drainage_noise = (double)p_params.drainage_noise;
	const double fine_erosion_strength = (double)p_params.fine_erosion_strength;
	const double shape_preservation = (double)p_params.shape_preservation;
	const double bank_smoothing = (double)p_params.bank_smoothing;
	const double sediment_strength = (double)p_params.sediment_strength;
	const int seed = p_params.seed;

	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
	const double diag_dist = std::sqrt(dx * dx + dz * dz);

	const int n_dx[8] = { -1, 1, 0, 0, -1, 1, -1, 1 };
	const int n_dz[8] = { 0, 0, -1, 1, -1, -1, 1, 1 };
	const double n_dist[8] = { dx, dx, dz, dz, diag_dist, diag_dist, diag_dist, diag_dist };

	std::vector<int> order(n);

	for (int pass_idx = 0; pass_idx < iterations; pass_idx++) {
		// 1. Sort cell indices descending by elevation
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

		// 2. Accumulate drainage flow with coherent noise perturbation for dendritic branching
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

						// Add noise perturbation to drainage routing to trigger natural meandering and branching
						if (drainage_noise > 0.0) {
							float noise_val = smooth_noise2d((float)nx * 0.2f, (float)nz * 0.2f, seed + pass_idx * 17);
							drop *= std::max(0.01, 1.0 + drainage_noise * (double)noise_val);
						}

						double weighted_drop = std::pow(drop, 1.3);
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

		// 3. Compute Salève Stream Power & Fine Rill Incision with Lateral Bank Spreading
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

				double flow_val = (double)current_flow[idx];
				double a_accum = std::log(1.0 + std::max(0.0, flow_val - 1.0));

				// Primary large-scale stream incision
				double inc_primary = 0.0;
				if (a_accum > 0.01 && slope > 1.0e-5) {
					double power = std::pow(a_accum, drainage_exponent) * slope;
					inc_primary = erosion_strength * 0.25 * std::log(1.0 + power) * m_val;
				}

				// Secondary micro-rill fine flow erosion along steep slopes
				double inc_fine = 0.0;
				if (fine_erosion_strength > 0.0 && slope > 0.02) {
					inc_fine = fine_erosion_strength * 0.1 * std::pow(slope, 0.8) * m_val;
				}

				double total_incision = inc_primary + inc_fine;

				if (total_incision > 0.0) {
					double center_w = 1.0 - bank_smoothing * 0.6;
					double neigh_w = (bank_smoothing * 0.6) * 0.25;

					incision_map[idx] += total_incision * center_w;
					if (ix > 0) incision_map[row + ix - 1] += total_incision * neigh_w;
					if (ix < p_gw - 1) incision_map[row + ix + 1] += total_incision * neigh_w;
					if (iz > 0) incision_map[(iz - 1) * p_gw + ix] += total_incision * neigh_w;
					if (iz < p_gh - 1) incision_map[(iz + 1) * p_gw + ix] += total_incision * neigh_w;

					current_sediment[idx] = (float)((double)current_sediment[idx] + total_incision);
				}

				// Sediment deposition mask tracking
				if (slope < 0.15 && current_sediment[idx] > 0.0f) {
					double dep = sediment_strength * (double)current_sediment[idx] * (1.0 - slope / 0.15) * m_val;
					dep_map[idx] += dep;
					current_sediment[idx] = (float)std::max(0.0, (double)current_sediment[idx] - dep);
				}
			}
		}

		// 4. Apply incision with shape preservation envelope
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
					double max_cut = std::max(0.0, (double)(h_c - min_downhill) + 0.1 * cut);
					cut = std::min(cut, max_cut);
					eroded_rock[idx] = (float)((double)eroded_rock[idx] + cut);

					// Shape preservation envelope: maintains macroscopic mountain profile
					double restore = 0.0;
					if (shape_preservation > 0.0 && original_height[idx] > h_c) {
						restore = 0.02 * shape_preservation * (double)(original_height[idx] - h_c);
					}

					next_height[idx] = (float)((double)h_c - cut + restore);
				}

				sediment[idx] = (float)((double)sediment[idx] + dep_map[idx]);
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
