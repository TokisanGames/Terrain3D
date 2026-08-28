// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_hydraulic_particle.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

using namespace godot;

HydraulicParticleParams HydraulicParticleParams::from_dict(const Dictionary &p_dict) {
	HydraulicParticleParams p;
	if (p_dict.has("droplet_count")) {
		p.droplet_count = std::max(1, (int)p_dict["droplet_count"]);
	}
	if (p_dict.has("max_lifetime")) {
		p.max_lifetime = std::max(1, (int)p_dict["max_lifetime"]);
	}
	if (p_dict.has("inertia")) {
		p.inertia = std::clamp((float)p_dict["inertia"], 0.0f, 1.0f);
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
	if (p_dict.has("evaporation_rate")) {
		p.evaporation_rate = std::clamp((float)p_dict["evaporation_rate"], 0.0f, 1.0f);
	}
	if (p_dict.has("min_slope")) {
		p.min_slope = std::max(0.0001f, (float)p_dict["min_slope"]);
	}
	if (p_dict.has("gravity")) {
		p.gravity = std::max(0.1f, (float)p_dict["gravity"]);
	}
	if (p_dict.has("seed")) {
		p.seed = (int64_t)p_dict["seed"];
	}
	if (p_dict.has("mask")) {
		p.mask = p_dict["mask"];
	}
	return p;
}

Dictionary HydraulicParticleResult::to_dict() const {
	Dictionary d;
	d["ok"] = ok;
	d["height"] = height;
	d["sediment"] = sediment;
	d["flow"] = flow;
	d["water_depth"] = water_depth;
	return d;
}

static inline double next_rand(uint32_t &p_state) {
	p_state = p_state * 1664525u + 1013904223u;
	return (double)p_state / 4294967296.0;
}

HydraulicParticleResult godot::hydraulic_particle_solve(const PackedFloat32Array &p_surface,
		int p_gw, int p_gh, const Rect2 &p_rect, const HydraulicParticleParams &p_params) {
	HydraulicParticleResult res;
	if (p_gw < 2 || p_gh < 2) {
		return res;
	}
	const int n = p_gw * p_gh;
	if (p_surface.size() != n) {
		return res;
	}

	const float *src_height = p_surface.ptr();
	std::vector<float> height(src_height, src_height + n);
	std::vector<float> sediment(n, 0.0f);
	std::vector<float> flow(n, 0.0f);
	std::vector<float> water_depth(n, 0.0f);

	const bool has_mask = (p_params.mask.size() == n);
	const float *mask_ptr = has_mask ? p_params.mask.ptr() : nullptr;

	const int droplet_count = std::max(1, p_params.droplet_count);
	const int max_lifetime = std::max(1, p_params.max_lifetime);
	const double inertia = (double)p_params.inertia;
	const double sediment_capacity = (double)p_params.sediment_capacity;
	const double erosion_speed = (double)p_params.erosion_speed;
	const double deposition_speed = (double)p_params.deposition_speed;
	const double evaporation_rate = (double)p_params.evaporation_rate;
	const double min_slope = (double)p_params.min_slope;
	const double gravity = (double)p_params.gravity;
	uint32_t rng_state = (uint32_t)p_params.seed;

	const double tau = 6.28318530717958647692;

	for (int d = 0; d < droplet_count; d++) {
		double rx = next_rand(rng_state) * (double)(p_gw - 1);
		double rz = next_rand(rng_state) * (double)(p_gh - 1);

		double px = rx;
		double pz = rz;
		double dir_x = 0.0;
		double dir_z = 0.0;
		double speed = 1.0;
		double water = 1.0;
		double sed = 0.0;

		int init_ix = std::clamp((int)px, 0, p_gw - 1);
		int init_iz = std::clamp((int)pz, 0, p_gh - 1);
		int init_idx = init_iz * p_gw + init_ix;
		if (!std::isfinite(height[init_idx])) {
			continue;
		}
		if (has_mask && mask_ptr[init_idx] <= 0.001f) {
			continue;
		}

		for (int step = 0; step < max_lifetime; step++) {
			int ix = (int)std::floor(px);
			int iz = (int)std::floor(pz);
			if (ix < 0 || ix >= p_gw - 1 || iz < 0 || iz >= p_gh - 1) {
				break;
			}

			double u = px - (double)ix;
			double v = pz - (double)iz;

			int i00 = iz * p_gw + ix;
			int i10 = i00 + 1;
			int i01 = (iz + 1) * p_gw + ix;
			int i11 = i01 + 1;

			float h00 = height[i00];
			float h10 = height[i10];
			float h01 = height[i01];
			float h11 = height[i11];

			if (!std::isfinite(h00) || !std::isfinite(h10) || !std::isfinite(h01) || !std::isfinite(h11)) {
				break;
			}

			double h_curr = (1.0 - u) * (1.0 - v) * (double)h00 + u * (1.0 - v) * (double)h10 +
					(1.0 - u) * v * (double)h01 + u * v * (double)h11;

			// Surface gradient
			double gx = (1.0 - v) * (double)(h10 - h00) + v * (double)(h11 - h01);
			double gz = (1.0 - u) * (double)(h01 - h00) + u * (double)(h11 - h10);

			// Direction with momentum
			dir_x = dir_x * inertia - gx * (1.0 - inertia);
			dir_z = dir_z * inertia - gz * (1.0 - inertia);

			double dir_len = std::sqrt(dir_x * dir_x + dir_z * dir_z);
			if (dir_len > 1.0e-6) {
				dir_x /= dir_len;
				dir_z /= dir_len;
			} else {
				double ang = next_rand(rng_state) * tau;
				dir_x = std::cos(ang);
				dir_z = std::sin(ang);
			}

			double next_px = px + dir_x;
			double next_pz = pz + dir_z;

			int next_ix = (int)std::floor(next_px);
			int next_iz = (int)std::floor(next_pz);
			if (next_ix < 0 || next_ix >= p_gw - 1 || next_iz < 0 || next_iz >= p_gh - 1) {
				break;
			}

			double next_u = next_px - (double)next_ix;
			double next_v = next_pz - (double)next_iz;

			int ni00 = next_iz * p_gw + next_ix;
			int ni10 = ni00 + 1;
			int ni01 = (next_iz + 1) * p_gw + next_ix;
			int ni11 = ni01 + 1;

			float nh00 = height[ni00];
			float nh10 = height[ni10];
			float nh01 = height[ni01];
			float nh11 = height[ni11];

			if (!std::isfinite(nh00) || !std::isfinite(nh10) || !std::isfinite(nh01) || !std::isfinite(nh11)) {
				break;
			}

			double h_next = (1.0 - next_u) * (1.0 - next_v) * (double)nh00 + next_u * (1.0 - next_v) * (double)nh10 +
					(1.0 - next_u) * next_v * (double)nh01 + next_u * next_v * (double)nh11;
			double delta_h = h_next - h_curr;

			double w00 = (1.0 - u) * (1.0 - v);
			double w10 = u * (1.0 - v);
			double w01 = (1.0 - u) * v;
			double w11 = u * v;

			double mask_val = 1.0;
			if (has_mask) {
				mask_val = w00 * (double)mask_ptr[i00] + w10 * (double)mask_ptr[i10] +
						w01 * (double)mask_ptr[i01] + w11 * (double)mask_ptr[i11];
			}

			if (delta_h > 0.0) {
				// Moving uphill into pit — deposit sediment
				double deposit_amt = std::min(sed, delta_h) * mask_val;
				sed -= deposit_amt;
				height[i00] += (float)(deposit_amt * w00);
				height[i10] += (float)(deposit_amt * w10);
				height[i01] += (float)(deposit_amt * w01);
				height[i11] += (float)(deposit_amt * w11);
				sediment[i00] += (float)(deposit_amt * w00);
				sediment[i10] += (float)(deposit_amt * w10);
				sediment[i01] += (float)(deposit_amt * w01);
				sediment[i11] += (float)(deposit_amt * w11);
				break;
			} else {
				// Moving downhill
				double slope = std::max(-delta_h, min_slope);
				double cap = slope * speed * water * sediment_capacity;

				if (sed > cap) {
					double dep = (sed - cap) * deposition_speed * mask_val;
					sed -= dep;
					height[i00] += (float)(dep * w00);
					height[i10] += (float)(dep * w10);
					height[i01] += (float)(dep * w01);
					height[i11] += (float)(dep * w11);
					sediment[i00] += (float)(dep * w00);
					sediment[i10] += (float)(dep * w10);
					sediment[i01] += (float)(dep * w01);
					sediment[i11] += (float)(dep * w11);
				} else {
					double ero = std::min((cap - sed) * erosion_speed, -delta_h) * mask_val;
					sed += ero;
					height[i00] -= (float)(ero * w00);
					height[i10] -= (float)(ero * w10);
					height[i01] -= (float)(ero * w01);
					height[i11] -= (float)(ero * w11);
				}

				speed = std::sqrt(std::max(0.0, speed * speed - delta_h * gravity));
				water *= (1.0 - evaporation_rate);

				// Flow accumulation
				flow[i00] += (float)(water * w00);
				flow[i10] += (float)(water * w10);
				flow[i01] += (float)(water * w01);
				flow[i11] += (float)(water * w11);

				water_depth[i00] = std::max(water_depth[i00], (float)(water * 0.05 * w00));
				water_depth[i10] = std::max(water_depth[i10], (float)(water * 0.05 * w10));
				water_depth[i01] = std::max(water_depth[i01], (float)(water * 0.05 * w01));
				water_depth[i11] = std::max(water_depth[i11], (float)(water * 0.05 * w11));

				px = next_px;
				pz = next_pz;
			}
		}
	}

	res.ok = true;
	res.height.resize(n);
	std::memcpy(res.height.ptrw(), height.data(), n * sizeof(float));

	res.sediment.resize(n);
	std::memcpy(res.sediment.ptrw(), sediment.data(), n * sizeof(float));

	res.flow.resize(n);
	std::memcpy(res.flow.ptrw(), flow.data(), n * sizeof(float));

	res.water_depth.resize(n);
	std::memcpy(res.water_depth.ptrw(), water_depth.data(), n * sizeof(float));

	return res;
}
