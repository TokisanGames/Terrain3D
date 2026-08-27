// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_erosion_hydraulic.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

using namespace godot;

ErosionHydraulicParams ErosionHydraulicParams::from_dict(const Dictionary &p_dict) {
	ErosionHydraulicParams p;
	if (p_dict.has("iterations")) {
		p.iterations = std::max(1, (int)p_dict["iterations"]);
	}
	if (p_dict.has("rain_rate")) {
		p.rain_rate = std::max(0.0f, (float)p_dict["rain_rate"]);
	}
	if (p_dict.has("evaporation_rate")) {
		p.evaporation_rate = std::clamp((float)p_dict["evaporation_rate"], 0.0f, 1.0f);
	}
	if (p_dict.has("sediment_capacity")) {
		p.sediment_capacity = std::max(0.0f, (float)p_dict["sediment_capacity"]);
	}
	if (p_dict.has("erosion_speed")) {
		p.erosion_speed = std::clamp((float)p_dict["erosion_speed"], 0.0f, 1.0f);
	}
	if (p_dict.has("deposition_speed")) {
		p.deposition_speed = std::clamp((float)p_dict["deposition_speed"], 0.0f, 1.0f);
	}
	if (p_dict.has("min_slope")) {
		p.min_slope = std::max(0.0f, (float)p_dict["min_slope"]);
	}
	return p;
}

Dictionary ErosionHydraulicResult::to_dict() const {
	Dictionary d;
	d["ok"] = ok;
	d["height"] = height;
	d["sediment"] = sediment;
	d["flow"] = flow;
	return d;
}

ErosionHydraulicResult godot::erosion_hydraulic_solve(const PackedFloat32Array &p_surface,
		int p_gw, int p_gh, const Rect2 &p_rect, const ErosionHydraulicParams &p_params) {
	ErosionHydraulicResult res;
	if (p_gw < 1 || p_gh < 1) {
		return res;
	}
	const int n = p_gw * p_gh;
	if (p_surface.size() != n) {
		return res;
	}

	const float *src_height = p_surface.ptr();
	std::vector<float> height(src_height, src_height + n);
	std::vector<float> sediment(n, 0.0f);
	std::vector<float> water(n, 0.0f);
	std::vector<float> flow_accum(n, 0.0f);

	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
	const double cell_dist = std::sqrt(std::max(dx * dz, 1e-6));

	const int n_dx[4] = { -1, 1, 0, 0 };
	const int n_dz[4] = { 0, 0, -1, 1 };
	const double n_dist[4] = { dx, dx, dz, dz };

	const int iterations = p_params.iterations;
	const double p_rain = (double)p_params.rain_rate;
	const double p_evap = (double)p_params.evaporation_rate;
	const double p_cap = (double)p_params.sediment_capacity;
	const double p_ero_spd = (double)p_params.erosion_speed;
	const double p_dep_spd = (double)p_params.deposition_speed;
	const double p_min_slope = (double)p_params.min_slope;

	for (int pass = 0; pass < iterations; pass++) {
		// 1. Rain
		for (int i = 0; i < n; i++) {
			if (std::isfinite(height[i])) {
				water[i] = (float)((double)water[i] + p_rain);
				flow_accum[i] = (float)((double)flow_accum[i] + p_rain);
			}
		}

		std::vector<float> next_water = water;
		std::vector<float> next_sediment = sediment;
		std::vector<float> next_height = height;

		// 2. Downhill flow routing & stream power incision
		for (int iz = 0; iz < p_gh; iz++) {
			const int row = iz * p_gw;
			for (int ix = 0; ix < p_gw; ix++) {
				const int i = row + ix;
				const double h_c = (double)height[i];
				const double w_c = (double)water[i];
				if (!std::isfinite(h_c) || w_c <= 1e-7) {
					continue;
				}

				const double total_alt = h_c + w_c;
				double diffs[4] = { 0.0, 0.0, 0.0, 0.0 };
				double total_diff = 0.0;
				double max_slope = 0.0;
				double min_downhill_diff = std::numeric_limits<double>::infinity();

				for (int k = 0; k < 4; k++) {
					const int nx = ix + n_dx[k];
					const int nz = iz + n_dz[k];
					if (nx >= 0 && nx < p_gw && nz >= 0 && nz < p_gh) {
						const int ni = nz * p_gw + nx;
						const double n_h = (double)height[ni];
						const double n_w = (double)water[ni];
						if (std::isfinite(n_h)) {
							const double n_total = n_h + n_w;
							const double diff = total_alt - n_total;
							if (diff > 0.0) {
								diffs[k] = diff;
								total_diff += diff;
								min_downhill_diff = std::min(min_downhill_diff, diff);
								const double slope = diff / n_dist[k];
								if (slope > max_slope) {
									max_slope = slope;
								}
							}
						}
					}
				}

				if (total_diff > 0.0) {
					const double eff_slope = std::max(max_slope, p_min_slope);
					const double vel = std::sqrt(std::clamp(eff_slope * cell_dist, 0.05, 50.0));
					const double flow_factor = std::log(1.0 + (double)flow_accum[i] * 10.0) + 1.0;
					const double cap = p_cap * eff_slope * vel * w_c * flow_factor * 0.5;

					double sed_c = (double)sediment[i];
					const double max_erode = min_downhill_diff * 0.4;
					const double max_dep = min_downhill_diff * 0.4;

					if (sed_c < cap) {
						const double erode_amt = std::clamp((cap - sed_c) * p_ero_spd * 0.4, 0.0, max_erode);
						next_height[i] = (float)((double)next_height[i] - erode_amt);
						sed_c += erode_amt;
					} else if (sed_c > cap) {
						const double dep_amt = std::clamp((sed_c - cap) * p_dep_spd * 0.4, 0.0, max_dep);
						next_height[i] = (float)((double)next_height[i] + dep_amt);
						sed_c -= dep_amt;
					}

					const double flow_out = std::min(w_c * 0.6, total_diff * 0.5);
					next_water[i] = (float)((double)next_water[i] - flow_out);

					for (int k = 0; k < 4; k++) {
						if (diffs[k] > 0.0) {
							const double frac = diffs[k] / total_diff;
							const double moved_w = flow_out * frac;
							const double moved_s = sed_c * (moved_w / std::max(w_c, 1e-6));
							const int ni = (iz + n_dz[k]) * p_gw + (ix + n_dx[k]);
							next_water[ni] = (float)((double)next_water[ni] + moved_w);
							next_sediment[ni] = (float)((double)next_sediment[ni] + moved_s);
							flow_accum[ni] = (float)((double)flow_accum[ni] + moved_w);
							sed_c = std::max(sed_c - moved_s, 0.0);
						}
					}
					next_sediment[i] = (float)sed_c;
				}
			}
		}

		// 3. Evaporation
		for (int i = 0; i < n; i++) {
			if (std::isfinite(next_height[i])) {
				next_water[i] = (float)((double)next_water[i] * (1.0 - p_evap));
			}
		}

		water = std::move(next_water);
		sediment = std::move(next_sediment);
		height = std::move(next_height);
	}

	// 4. Normalization for mask channels
	double max_flow = 1e-6;
	double max_sed = 1e-6;
	for (int i = 0; i < n; i++) {
		if (std::isfinite(height[i])) {
			max_flow = std::max(max_flow, (double)flow_accum[i]);
			max_sed = std::max(max_sed, (double)sediment[i]);
		}
	}

	res.height.resize(n);
	res.sediment.resize(n);
	res.flow.resize(n);

	float *out_h = res.height.ptrw();
	float *out_s = res.sediment.ptrw();
	float *out_f = res.flow.ptrw();

	for (int i = 0; i < n; i++) {
		if (std::isfinite(height[i])) {
			out_h[i] = height[i];
			out_s[i] = (float)std::clamp((double)sediment[i] / max_sed, 0.0, 1.0);
			out_f[i] = (float)std::clamp((double)flow_accum[i] / max_flow, 0.0, 1.0);
		} else {
			out_h[i] = height[i];
			out_s[i] = 0.0f;
			out_f[i] = 0.0f;
		}
	}

	res.ok = true;
	return res;
}
