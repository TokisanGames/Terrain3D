// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// GLSL Compute Shader for Hydrodynamic Hydraulic Erosion.
// Ping-pong SSBO execution with 2-phase disperse-gather shallow water simulation.

R"(#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer HeightBuf { float height[]; };
layout(set = 0, binding = 1, std430) restrict buffer WaterBuf { float water[]; };
layout(set = 0, binding = 2, std430) restrict buffer SedimentBuf { float sediment[]; };
layout(set = 0, binding = 3, std430) restrict buffer FlowBuf { float flow_accum[]; };
layout(set = 0, binding = 4, std430) restrict buffer FluxWBuf { vec4 flux_w[]; };
layout(set = 0, binding = 5, std430) restrict buffer FluxSBuf { vec4 flux_s[]; };

layout(push_constant, std430) uniform Params {
	int mode; // 0: RAIN_AND_DISPERSE, 1: GATHER_AND_EVAPORATE, 2: NORMALIZE
	int gw;
	int gh;
	int pad0;
	float dx;
	float dz;
	float cell_dist;
	float rain_rate;
	float evaporation_rate;
	float sediment_capacity;
	float erosion_speed;
	float deposition_speed;
	float min_slope;
	float max_flow;
	float max_sed;
	float pad1;
} p;

void main() {
	int ix = int(gl_GlobalInvocationID.x);
	int iz = int(gl_GlobalInvocationID.y);
	if (ix >= p.gw || iz >= p.gh) {
		return;
	}
	int i = iz * p.gw + ix;

	if (p.mode == 0) {
		// Phase 0: Rain, Stream Power Incision & Outbound Flux calculation
		float h_c = height[i];
		if (isnan(h_c) || isinf(h_c)) {
			flux_w[i] = vec4(0.0);
			flux_s[i] = vec4(0.0);
			return;
		}

		water[i] += p.rain_rate;
		flow_accum[i] += p.rain_rate;
		float w_c = water[i];

		if (w_c <= 1e-7) {
			flux_w[i] = vec4(0.0);
			flux_s[i] = vec4(0.0);
			return;
		}

		float total_alt = h_c + w_c;
		float diffs[4] = float[4](0.0, 0.0, 0.0, 0.0);
		float total_diff = 0.0;
		float max_slope = 0.0;
		float min_downhill_diff = 1.0 / 0.0; // +INF

		// 0: -X (left), 1: +X (right), 2: -Z (up), 3: +Z (down)
		if (ix > 0) {
			int ni = i - 1;
			float nh = height[ni];
			if (!isnan(nh) && !isinf(nh)) {
				float diff = total_alt - (nh + water[ni]);
				if (diff > 0.0) {
					diffs[0] = diff;
					total_diff += diff;
					min_downhill_diff = min(min_downhill_diff, diff);
					max_slope = max(max_slope, diff / p.dx);
				}
			}
		}
		if (ix < p.gw - 1) {
			int ni = i + 1;
			float nh = height[ni];
			if (!isnan(nh) && !isinf(nh)) {
				float diff = total_alt - (nh + water[ni]);
				if (diff > 0.0) {
					diffs[1] = diff;
					total_diff += diff;
					min_downhill_diff = min(min_downhill_diff, diff);
					max_slope = max(max_slope, diff / p.dx);
				}
			}
		}
		if (iz > 0) {
			int ni = i - p.gw;
			float nh = height[ni];
			if (!isnan(nh) && !isinf(nh)) {
				float diff = total_alt - (nh + water[ni]);
				if (diff > 0.0) {
					diffs[2] = diff;
					total_diff += diff;
					min_downhill_diff = min(min_downhill_diff, diff);
					max_slope = max(max_slope, diff / p.dz);
				}
			}
		}
		if (iz < p.gh - 1) {
			int ni = i + p.gw;
			float nh = height[ni];
			if (!isnan(nh) && !isinf(nh)) {
				float diff = total_alt - (nh + water[ni]);
				if (diff > 0.0) {
					diffs[3] = diff;
					total_diff += diff;
					min_downhill_diff = min(min_downhill_diff, diff);
					max_slope = max(max_slope, diff / p.dz);
				}
			}
		}

		if (total_diff > 0.0) {
			float eff_slope = max(max_slope, p.min_slope);
			float vel = sqrt(clamp(eff_slope * p.cell_dist, 0.05, 50.0));
			float flow_factor = log(1.0 + flow_accum[i] * 10.0) + 1.0;
			float cap = p.sediment_capacity * eff_slope * vel * w_c * flow_factor * 0.5;

			float sed_c = sediment[i];
			float max_erode = min_downhill_diff * 0.4;
			float max_dep = min_downhill_diff * 0.4;

			if (sed_c < cap) {
				float erode_amt = clamp((cap - sed_c) * p.erosion_speed * 0.4, 0.0, max_erode);
				height[i] -= erode_amt;
				sed_c += erode_amt;
			} else if (sed_c > cap) {
				float dep_amt = clamp((sed_c - cap) * p.deposition_speed * 0.4, 0.0, max_dep);
				height[i] += dep_amt;
				sed_c -= dep_amt;
			}

			float flow_out = min(w_c * 0.6, total_diff * 0.5);
			water[i] = w_c - flow_out;

			vec4 fw = vec4(0.0);
			vec4 fs = vec4(0.0);
			float inv_tot = 1.0 / total_diff;
			float s_scale = sed_c / max(w_c, 1e-6);

			if (diffs[0] > 0.0) {
				fw.x = flow_out * (diffs[0] * inv_tot);
				fs.x = fw.x * s_scale;
				sed_c = max(sed_c - fs.x, 0.0);
			}
			if (diffs[1] > 0.0) {
				fw.y = flow_out * (diffs[1] * inv_tot);
				fs.y = fw.y * s_scale;
				sed_c = max(sed_c - fs.y, 0.0);
			}
			if (diffs[2] > 0.0) {
				fw.z = flow_out * (diffs[2] * inv_tot);
				fs.z = fw.z * s_scale;
				sed_c = max(sed_c - fs.z, 0.0);
			}
			if (diffs[3] > 0.0) {
				fw.w = flow_out * (diffs[3] * inv_tot);
				fs.w = fw.w * s_scale;
				sed_c = max(sed_c - fs.w, 0.0);
			}

			sediment[i] = sed_c;
			flux_w[i] = fw;
			flux_s[i] = fs;
		} else {
			flux_w[i] = vec4(0.0);
			flux_s[i] = vec4(0.0);
		}
		return;
	}

	if (p.mode == 1) {
		// Phase 1: Gather Inbound Flux & Evaporate
		float h_c = height[i];
		if (isnan(h_c) || isinf(h_c)) {
			return;
		}

		float in_w = 0.0;
		float in_s = 0.0;

		// Inbound from West neighbor's +X flux (index 1 -> .y)
		if (ix > 0) {
			int ni = i - 1;
			in_w += flux_w[ni].y;
			in_s += flux_s[ni].y;
		}
		// Inbound from East neighbor's -X flux (index 0 -> .x)
		if (ix < p.gw - 1) {
			int ni = i + 1;
			in_w += flux_w[ni].x;
			in_s += flux_s[ni].x;
		}
		// Inbound from North neighbor's +Z flux (index 3 -> .w)
		if (iz > 0) {
			int ni = i - p.gw;
			in_w += flux_w[ni].w;
			in_s += flux_s[ni].w;
		}
		// Inbound from South neighbor's -Z flux (index 2 -> .z)
		if (iz < p.gh - 1) {
			int ni = i + p.gw;
			in_w += flux_w[ni].z;
			in_s += flux_s[ni].z;
		}

		water[i] = (water[i] + in_w) * (1.0 - p.evaporation_rate);
		sediment[i] += in_s;
		flow_accum[i] += in_w;
		return;
	}

	if (p.mode == 2) {
		// Phase 2: Final Normalization
		float h_c = height[i];
		if (isnan(h_c) || isinf(h_c)) {
			sediment[i] = 0.0;
			flow_accum[i] = 0.0;
		} else {
			sediment[i] = clamp(sediment[i] / p.max_sed, 0.0, 1.0);
			flow_accum[i] = clamp(flow_accum[i] / p.max_flow, 0.0, 1.0);
		}
		return;
	}
}
)"
