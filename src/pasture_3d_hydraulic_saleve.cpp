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

// Fast deterministic 2D float hash in [-1.0 .. 1.0]
inline float hash2d(int x, int y, int seed) {
	uint32_t n = (uint32_t)(x * 73856093 ^ y * 19349663 ^ seed * 83492791);
	n = (n ^ (n >> 13)) * 0x5bd1e995;
	n ^= n >> 15;
	return ((float)(n & 0x00ffffff) / 8388608.0f) - 1.0f;
}

} // namespace

HydraulicSaleveParams HydraulicSaleveParams::from_dict(const Dictionary &p_dict) {
	HydraulicSaleveParams p;
	if (p_dict.has("iterations")) {
		p.iterations = std::max(1, (int)p_dict["iterations"]);
	}
	if (p_dict.has("erosion_strength")) {
		p.erosion_strength = std::max(0.0f, (float)p_dict["erosion_strength"]);
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

	const double cell_dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double cell_dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);

	// 1. Construct Jittered Control-Point Graph (Braun-Willett / FastScape Voronoi model)
	// Points are randomly jittered within each cell to break square grid axes and create
	// continuous 360° fractal branching river networks.
	struct ControlPoint {
		double x, z;
		float h;
		float orig_h;
		float mask;
	};

	std::vector<ControlPoint> points(n);
	for (int iz = 0; iz < p_gh; iz++) {
		for (int ix = 0; ix < p_gw; ix++) {
			int idx = iz * p_gw + ix;
			float jx = hash2d(ix, iz, seed) * 0.38f;
			float jz = hash2d(ix, iz, seed + 1013) * 0.38f;

			double px = ((double)ix + 0.5 + (double)jx) * cell_dx;
			double pz = ((double)iz + 0.5 + (double)jz) * cell_dz;

			points[idx].x = px;
			points[idx].z = pz;
			points[idx].h = src_height[idx];
			points[idx].orig_h = src_height[idx];
			points[idx].mask = has_mask ? mask_ptr[idx] : 1.0f;
		}
	}

	const int n_dx[8] = { -1, 1, 0, 0, -1, 1, -1, 1 };
	const int n_dz[8] = { 0, 0, -1, 1, -1, -1, 1, 1 };

	std::vector<int> order(n);
	std::vector<double> flow(n, 1.0);
	std::vector<double> sediment_accum(n, 0.0);
	std::vector<float> eroded_rock(n, 0.0f);
	std::vector<float> sediment_out(n, 0.0f);

	for (int pass = 0; pass < iterations; pass++) {
		// 2. Sort control points descending by elevation
		for (int i = 0; i < n; i++) {
			order[i] = i;
		}

		std::sort(order.begin(), order.end(), [&points](int a, int b) {
			float ha = points[a].h;
			float hb = points[b].h;
			if (!std::isfinite(ha)) return false;
			if (!std::isfinite(hb)) return true;
			return ha > hb;
		});

		// 3. Flow Routing on the Jittered Graph
		std::fill(flow.begin(), flow.end(), 1.0);
		std::fill(sediment_accum.begin(), sediment_accum.end(), 0.0);

		for (int idx : order) {
			float h_c = points[idx].h;
			if (!std::isfinite(h_c)) {
				continue;
			}
			int ix = idx % p_gw;
			int iz = idx / p_gw;
			double px = points[idx].x;
			double pz = points[idx].z;

			double best_slope = 0.0;
			int best_receiver = -1;
			double sum_drop = 0.0;
			double drops[8] = { 0.0 };
			int n_indices[8] = { -1, -1, -1, -1, -1, -1, -1, -1 };

			for (int k = 0; k < 8; k++) {
				int nx = ix + n_dx[k];
				int nz = iz + n_dz[k];
				if (nx >= 0 && nx < p_gw && nz >= 0 && nz < p_gh) {
					int n_idx = nz * p_gw + nx;
					n_indices[k] = n_idx;
					float h_n = points[n_idx].h;
					if (std::isfinite(h_n) && h_n < h_c) {
						double dist = std::sqrt(std::pow(points[n_idx].x - px, 2.0) + std::pow(points[n_idx].z - pz, 2.0));
						dist = std::max(dist, 1.0e-4);
						double slope = (double)(h_c - h_n) / dist;

						if (drainage_noise > 0.0) {
							float pnoise = hash2d(nx, nz, seed + pass * 31 + k * 7);
							slope *= std::max(0.05, 1.0 + drainage_noise * (double)pnoise);
						}

						double w_drop = std::pow(slope, 1.4);
						drops[k] = w_drop;
						sum_drop += w_drop;

						if (slope > best_slope) {
							best_slope = slope;
							best_receiver = n_idx;
						}
					}
				}
			}

			// Distribute flow and sediment to downhill receiver network
			if (sum_drop > 1.0e-6) {
				double my_flow = flow[idx];
				double my_sed = sediment_accum[idx];
				for (int k = 0; k < 8; k++) {
					if (drops[k] > 0.0 && n_indices[k] >= 0) {
						int n_idx = n_indices[k];
						double frac = drops[k] / sum_drop;
						flow[n_idx] += my_flow * frac;
						sediment_accum[n_idx] += my_sed * frac;
					}
				}
			}
		}

		// 4. Stream Power Bedrock Incision along the Dendritic Graph
		std::vector<float> next_h(n);
		for (int i = 0; i < n; i++) {
			next_h[i] = points[i].h;
		}

		for (int iz = 0; iz < p_gh; iz++) {
			for (int ix = 0; ix < p_gw; ix++) {
				int idx = iz * p_gw + ix;
				float h_c = points[idx].h;
				if (!std::isfinite(h_c)) {
					continue;
				}
				float m_val = points[idx].mask;
				if (m_val <= 0.001f) {
					continue;
				}

				// Local graph slope
				double max_s = 0.0;
				for (int k = 0; k < 8; k++) {
					int nx = ix + n_dx[k];
					int nz = iz + n_dz[k];
					if (nx >= 0 && nx < p_gw && nz >= 0 && nz < p_gh) {
						int n_idx = nz * p_gw + nx;
						float h_n = points[n_idx].h;
						if (std::isfinite(h_n) && h_n < h_c) {
							double d = std::sqrt(std::pow(points[n_idx].x - points[idx].x, 2.0) + std::pow(points[n_idx].z - points[idx].z, 2.0));
							double s = (double)(h_c - h_n) / std::max(d, 1.0e-4);
							if (s > max_s) max_s = s;
						}
					}
				}

				double a_accum = std::log(1.0 + std::max(0.0, flow[idx] - 1.0));
				double inc = 0.0;

				// Large-scale stream power incision: E = K * A^m * S^n
				if (a_accum > 0.01 && max_s > 1.0e-4) {
					double power = std::pow(a_accum, drainage_exponent) * max_s;
					inc += erosion_strength * 0.35 * std::log(1.0 + power) * (double)m_val;
				}

				// Secondary micro-rill fine flow erosion on steep flanks
				if (fine_erosion_strength > 0.0 && max_s > 0.02) {
					inc += fine_erosion_strength * 0.15 * std::pow(max_s, 0.8) * (double)m_val;
				}

				if (inc > 0.0) {
					// Shape preservation envelope: maintains peak height while carving gorges
					double max_depth = (shape_preservation > 0.0) ? (0.6 * (double)points[idx].orig_h / shape_preservation) : 1000.0;
					double current_depth = (double)(points[idx].orig_h - h_c);
					if (current_depth > max_depth) {
						inc *= std::max(0.0, 1.0 - (current_depth - max_depth) / (max_depth * 0.5 + 1.0e-3));
					}

					next_h[idx] = (float)std::max(0.0, (double)h_c - inc);
					eroded_rock[idx] += (float)inc;
					sediment_accum[idx] += inc;
				}

				if (max_s < 0.15 && sediment_accum[idx] > 0.0) {
					double dep = sediment_strength * sediment_accum[idx] * (1.0 - max_s / 0.15) * (double)m_val;
					sediment_out[idx] += (float)dep;
					sediment_accum[idx] = std::max(0.0, sediment_accum[idx] - dep);
				}
			}
		}

		// 5. Transverse Hillslope Diffusion along Riverbanks
		if (bank_smoothing > 0.0) {
			for (int iz = 1; iz < p_gh - 1; iz++) {
				for (int ix = 1; ix < p_gw - 1; ix++) {
					int idx = iz * p_gw + ix;
					if (eroded_rock[idx] > 0.01f && std::isfinite(next_h[idx])) {
						double avg = 0.25 * ((double)next_h[iz * p_gw + ix - 1] + (double)next_h[iz * p_gw + ix + 1] +
								(double)next_h[(iz - 1) * p_gw + ix] + (double)next_h[(iz + 1) * p_gw + ix]);
						double blend = bank_smoothing * 0.3;
						next_h[idx] = (float)((1.0 - blend) * (double)next_h[idx] + blend * avg);
					}
				}
			}
		}

		for (int i = 0; i < n; i++) {
			points[i].h = next_h[i];
		}
	}

	// 6. Resample Jittered Control-Point Graph back to Grid
	std::vector<float> final_height(n);
	for (int i = 0; i < n; i++) {
		final_height[i] = points[i].h;
	}

	res.ok = true;
	res.height.resize(n);
	std::memcpy(res.height.ptrw(), final_height.data(), n * sizeof(float));

	res.eroded_rock.resize(n);
	std::memcpy(res.eroded_rock.ptrw(), eroded_rock.data(), n * sizeof(float));

	res.sediment.resize(n);
	std::memcpy(res.sediment.ptrw(), sediment_out.data(), n * sizeof(float));

	return res;
}
