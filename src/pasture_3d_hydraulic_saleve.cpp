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

inline float fast_hash_to_unit(uint32_t seed, uint32_t key) {
	uint32_t n = seed ^ (key * 0x5bd1e995);
	n = (n ^ (n >> 13)) * 0x5bd1e995;
	n ^= n >> 15;
	return ((float)(n & 0x00ffffff) / 8388608.0f) - 1.0f; // [-1.0 .. 1.0]
}

} // namespace

HydraulicSaleveParams HydraulicSaleveParams::from_dict(const Dictionary &p_dict) {
	HydraulicSaleveParams p;
	if (p_dict.has("iterations")) {
		p.iterations = std::max(1, (int)p_dict["iterations"]);
	}
	if (p_dict.has("erosion_strength")) {
		p.erosion_strength = std::clamp((float)p_dict["erosion_strength"], 0.0f, 1.0f);
	} else if (p_dict.has("incision_rate")) {
		p.erosion_strength = std::clamp((float)p_dict["incision_rate"], 0.0f, 1.0f);
	}
	if (p_dict.has("drainage_exponent")) {
		p.drainage_exponent = std::clamp((float)p_dict["drainage_exponent"], 0.01f, 0.8f);
	}
	if (p_dict.has("drainage_noise")) {
		p.drainage_noise = std::max(0.0f, (float)p_dict["drainage_noise"]);
	}
	if (p_dict.has("fine_erosion_strength")) {
		p.fine_erosion_strength = std::max(0.0f, (float)p_dict["fine_erosion_strength"]);
	}
	if (p_dict.has("shape_preservation")) {
		p.shape_preservation = std::clamp((float)p_dict["shape_preservation"], 0.1f, 4.0f);
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
	if (p_dict.has("dx")) {
		p.dx = p_dict["dx"];
	}
	if (p_dict.has("dy")) {
		p.dy = p_dict["dy"];
	}
	if (p_dict.has("deposition_radius")) {
		p.deposition_radius = std::max(0.0f, (float)p_dict["deposition_radius"]);
	}
	if (p_dict.has("deposition_strength")) {
		p.deposition_strength = std::clamp((float)p_dict["deposition_strength"], 0.0f, 1.0f);
	}
	if (p_dict.has("stream_strength")) {
		p.stream_strength = std::clamp((float)p_dict["stream_strength"], 0.0f, 1.0f);
	}
	if (p_dict.has("stream_exp")) {
		p.stream_exp = std::clamp((float)p_dict["stream_exp"], 0.01f, 1.0f);
	}
	if (p_dict.has("enable_post_smoothing")) {
		p.enable_post_smoothing = (bool)p_dict["enable_post_smoothing"];
	}
	if (p_dict.has("gain")) {
		p.gain = std::max(0.0f, (float)p_dict["gain"]);
	}
	if (p_dict.has("gamma")) {
		p.gamma = std::max(0.01f, (float)p_dict["gamma"]);
	}
	if (p_dict.has("mix_factor")) {
		p.mix_factor = std::clamp((float)p_dict["mix_factor"], 0.0f, 1.0f);
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
	const bool has_mask = (p_params.mask.size() == n);
	const float *mask_ptr = has_mask ? p_params.mask.ptr() : nullptr;
	const bool has_dx = (p_params.dx.size() == n);
	const bool has_dy = (p_params.dy.size() == n);
	const float *dx_ptr = has_dx ? p_params.dx.ptr() : nullptr;
	const float *dy_ptr = has_dy ? p_params.dy.ptr() : nullptr;

	float zmin = std::numeric_limits<float>::max();
	float zmax = -std::numeric_limits<float>::max();
	for (int i = 0; i < n; i++) {
		float h = src_height[i];
		if (std::isfinite(h)) {
			if (h < zmin) zmin = h;
			if (h > zmax) zmax = h;
		}
	}

	if (zmax - zmin < 1.0e-5f) {
		res.ok = true;
		res.height = p_surface.duplicate();
		res.eroded_rock.resize(n);
		res.eroded_rock.fill(0.0f);
		res.sediment.resize(n);
		res.sediment.fill(0.0f);
		return res;
	}

	const float zptp = zmax - zmin;

	// Normalized unit elevation [0..1]
	std::vector<float> z(n);
	std::vector<float> erodibility(n, 1.0f);
	std::vector<bool> is_outlet(n, false);

	for (int iz = 0; iz < p_gh; iz++) {
		for (int ix = 0; ix < p_gw; ix++) {
			int idx = iz * p_gw + ix;
			float h = src_height[idx];
			if (!std::isfinite(h)) {
				z[idx] = 0.0f;
				is_outlet[idx] = true;
				continue;
			}
			float zn = (h - zmin) / zptp;
			z[idx] = zn;

			// Hesiod Shape Preservation: erodibility = (1.0 - z_norm)^shape_exp
			erodibility[idx] = std::pow(std::clamp(1.0f - zn, 0.01f, 1.0f), p_params.shape_preservation);

			// Border cells are default outlets
			if (ix == 0 || ix == p_gw - 1 || iz == 0 || iz == p_gh - 1) {
				is_outlet[idx] = true;
			}
		}
	}

	const int iterations = std::max(1, p_params.iterations);
	const float m_exp = p_params.drainage_exponent;
	const float noise_strength = p_params.drainage_noise;
	const float uplift_rate = 1.0f;
	const float max_slope = 4.0f;
	const uint32_t seed = (uint32_t)p_params.seed;

	const double dx = 1.0 / (double)std::max(p_gw, 1);
	const double dz = 1.0 / (double)std::max(p_gh, 1);
	const double diag_dist = std::sqrt(dx * dx + dz * dz);

	const int n_dx[8] = { -1, 1, 0, 0, -1, 1, -1, 1 };
	const int n_dz[8] = { 0, 0, -1, 1, -1, -1, 1, 1 };
	const double n_dist[8] = { dx, dx, dz, dz, diag_dist, diag_dist, diag_dist, diag_dist };

	std::vector<int> receivers(n);
	std::vector<float> area_acc(n, 0.0f);
	std::vector<float> response_times(n, 0.0f);
	std::vector<int> order(n);

	// ================================================================================================
	// Stage 1: Steady-State Fluvial Incision (Chi-Transform LEM with dx/dy perturbation)
	// ================================================================================================
	for (int iter = 0; iter < iterations; iter++) {
		// 1. Compute steepest descent receivers with domain noise / dx/dy perturbation
		for (int iz = 0; iz < p_gh; iz++) {
			for (int ix = 0; ix < p_gw; ix++) {
				int idx = iz * p_gw + ix;
				if (is_outlet[idx]) {
					receivers[idx] = idx;
					continue;
				}

				float z_c = z[idx];
				float best_score = -1.0e9f;
				int best_k = idx;

				for (int k = 0; k < 8; k++) {
					int nx = ix + n_dx[k];
					int nz = iz + n_dz[k];
					if (nx >= 0 && nx < p_gw && nz >= 0 && nz < p_gh) {
						int n_idx = nz * p_gw + nx;
						float dz_val = z_c - z[n_idx];
						if (dz_val > 0.0f) {
							float slope = dz_val / (float)n_dist[k];
							float noise = fast_hash_to_unit(seed + (uint32_t)iter * 17, (uint32_t)(idx ^ (n_idx << 16)));
							float warp_factor = 1.0f;
							if (dx_ptr && dy_ptr) {
								warp_factor += 0.5f * (dx_ptr[idx] * (float)n_dx[k] + dy_ptr[idx] * (float)n_dz[k]);
							}
							float score = slope * (warp_factor + noise_strength * noise);
							if (score > best_score) {
								best_score = score;
								best_k = n_idx;
							}
						}
					}
				}
				receivers[idx] = best_k;
			}
		}

		// 2. Topological order from highest to lowest elevation
		for (int i = 0; i < n; i++) {
			order[i] = i;
		}
		std::sort(order.begin(), order.end(), [&z](int a, int b) {
			return z[a] > z[b];
		});

		// 3. Accumulate drainage area (upstream -> downstream)
		std::fill(area_acc.begin(), area_acc.end(), 1.0f);
		for (int idx : order) {
			int r = receivers[idx];
			if (r != idx) {
				area_acc[r] += area_acc[idx];
			}
		}

		// 4. Compute Response Times (chi-transform integral from outlets upstream)
		std::fill(response_times.begin(), response_times.end(), 0.0f);
		for (int i = n - 1; i >= 0; i--) {
			int idx = order[i];
			int r = receivers[idx];
			if (r != idx) {
				int ix = idx % p_gw;
				int iz = idx / p_gw;
				int rx = r % p_gw;
				int rz = r / p_gw;
				float d = (float)std::sqrt(std::pow((ix - rx) * dx, 2.0) + std::pow((iz - rz) * dz, 2.0));
				d = std::max(d, 1.0e-5f);

				float celerity = erodibility[idx] * std::pow(std::max(area_acc[idx], 1.0f), m_exp);
				response_times[idx] = response_times[r] + (d / std::max(celerity, 1.0e-4f));
			} else {
				response_times[idx] = 0.0f;
			}
		}

		// 5. Update Elevations (Hesiod Perron-Royden steady-state solver)
		float diff = 0.0f;
		for (int i = n - 1; i >= 0; i--) {
			int idx = order[i];
			int r = receivers[idx];
			if (r == idx) {
				continue;
			}

			float new_z = z[r] + uplift_rate * (response_times[idx] - response_times[r]) * 0.05f;

			// Slope limiter
			int ix = idx % p_gw;
			int iz = idx / p_gw;
			int rx = r % p_gw;
			int rz = r / p_gw;
			float d = (float)std::sqrt(std::pow((ix - rx) * dx, 2.0) + std::pow((iz - rz) * dz, 2.0));
			float slope = (new_z - z[r]) / std::max(d, 1.0e-5f);
			if (slope > max_slope) {
				new_z = z[r] + max_slope * d;
			}

			diff += std::abs(new_z - z[idx]);
			z[idx] = new_z;
		}

		if (diff / (float)n < 1.0e-4f) {
			break;
		}
	}

	// Remap Stage 1 back to [0..1]
	float ze_min = std::numeric_limits<float>::max();
	float ze_max = -std::numeric_limits<float>::max();
	for (int i = 0; i < n; i++) {
		if (z[i] < ze_min) ze_min = z[i];
		if (z[i] > ze_max) ze_max = z[i];
	}
	float ze_span = std::max(ze_max - ze_min, 1.0e-5f);
	for (int i = 0; i < n; i++) {
		z[i] = (z[i] - ze_min) / ze_span;
	}

	// ================================================================================================
	// Stage 2: Sediment Deposition (Deposition / Alluvial Flats)
	// ================================================================================================
	std::vector<float> sediment(n, 0.0f);
	if (p_params.deposition_strength > 0.0f && p_params.deposition_radius > 0.0f) {
		int ir = std::max(1, (int)(p_params.deposition_radius * (float)std::min(p_gw, p_gh)));
		std::vector<float> z_fill = z;

		// Morphological depression smoothing to fill valley floors
		for (int iz = 0; iz < p_gh; iz++) {
			for (int ix = 0; ix < p_gw; ix++) {
				int idx = iz * p_gw + ix;
				float max_n = z_fill[idx];
				for (int dy_i = -ir; dy_i <= ir; dy_i++) {
					int ny = iz + dy_i;
					if (ny < 0 || ny >= p_gh) continue;
					for (int dx_i = -ir; dx_i <= ir; dx_i++) {
						int nx = ix + dx_i;
						if (nx < 0 || nx >= p_gw) continue;
						if (dx_i * dx_i + dy_i * dy_i <= ir * ir) {
							max_n = std::max(max_n, z_fill[ny * p_gw + nx]);
						}
					}
				}
				z_fill[idx] = 0.5f * (z_fill[idx] + max_n);
			}
		}

		for (int i = 0; i < n; i++) {
			float diff = std::max(0.0f, z_fill[i] - z[i]);
			float dep = p_params.deposition_strength * diff;
			z[i] += dep;
			sediment[i] = dep * zptp;
		}
	}

	// ================================================================================================
	// Stage 3: Fine River Channel Incision (HydraulicStreamLog secondary pass)
	// ================================================================================================
	if (p_params.stream_strength > 0.0f) {
		for (int idx : order) {
			int r = receivers[idx];
			if (r != idx) {
				int ix = idx % p_gw;
				int iz = idx / p_gw;
				int rx = r % p_gw;
				int rz = r / p_gw;
				float d = (float)std::sqrt(std::pow((ix - rx) * dx, 2.0) + std::pow((iz - rz) * dz, 2.0));
				float slope = std::max(0.0f, (z[idx] - z[r]) / std::max(d, 1.0e-5f));
				float stream_inc = p_params.stream_strength * std::log(1.0f + std::pow(std::max(area_acc[idx], 1.0f), p_params.stream_exp) * slope) * erodibility[idx] * 0.15f;
				z[idx] = std::max(z[r], z[idx] - stream_inc);
			}
		}
	}

	// ================================================================================================
	// Stage 4: Post-Processing & Tonal Controls
	// ================================================================================================
	if (p_params.enable_post_smoothing || p_params.bank_smoothing > 0.0f) {
		std::vector<float> smoothed = z;
		float blend = p_params.enable_post_smoothing ? 0.3f : (p_params.bank_smoothing * 0.4f);
		for (int iz = 1; iz < p_gh - 1; iz++) {
			for (int ix = 1; ix < p_gw - 1; ix++) {
				int idx = iz * p_gw + ix;
				float avg = 0.25f * (z[iz * p_gw + ix - 1] + z[iz * p_gw + ix + 1] +
						z[(iz - 1) * p_gw + ix] + z[(iz + 1) * p_gw + ix]);
				smoothed[idx] = (1.0f - blend) * z[idx] + blend * avg;
			}
		}
		z = smoothed;
	}

	if (p_params.gamma != 1.0f || p_params.gain != 1.0f) {
		for (int i = 0; i < n; i++) {
			z[i] = p_params.gain * std::pow(std::clamp(z[i], 0.0f, 1.0f), p_params.gamma);
		}
	}

	// 5. Final Composite with original heightfield in world metres
	std::vector<float> final_height(n);
	std::vector<float> eroded_rock(n, 0.0f);

	for (int i = 0; i < n; i++) {
		float orig_h = src_height[i];
		if (!std::isfinite(orig_h)) {
			final_height[i] = orig_h;
			eroded_rock[i] = 0.0f;
			continue;
		}

		float eroded_h = zmin + z[i] * zptp;
		float m_val = has_mask ? mask_ptr[i] : 1.0f;
		float eff_weight = p_params.erosion_strength * p_params.mix_factor * m_val;

		float res_h = (1.0f - eff_weight) * orig_h + eff_weight * eroded_h;
		final_height[i] = res_h;
		eroded_rock[i] = std::max(0.0f, orig_h - res_h);
	}

	res.ok = true;
	res.height.resize(n);
	std::memcpy(res.height.ptrw(), final_height.data(), n * sizeof(float));

	res.eroded_rock.resize(n);
	std::memcpy(res.eroded_rock.ptrw(), eroded_rock.data(), n * sizeof(float));

	res.sediment.resize(n);
	std::memcpy(res.sediment.ptrw(), sediment.data(), n * sizeof(float));

	return res;
}
