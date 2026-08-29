// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_geo_primitives.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

using namespace godot;

MountainConeParams MountainConeParams::from_dict(const Dictionary &p_dict) {
	MountainConeParams p;
	if (p_dict.has("seed")) p.seed = (int)p_dict["seed"];
	if (p_dict.has("elevation")) p.elevation = (float)p_dict["elevation"];
	if (p_dict.has("scale")) p.scale = std::max(0.01f, (float)p_dict["scale"]);
	if (p_dict.has("octaves")) p.octaves = std::clamp((int)p_dict["octaves"], 1, 16);
	if (p_dict.has("peak_kw")) p.peak_kw = std::max(0.01f, (float)p_dict["peak_kw"]);
	if (p_dict.has("rugosity")) p.rugosity = (float)p_dict["rugosity"];
	if (p_dict.has("angle")) p.angle = (float)p_dict["angle"];
	if (p_dict.has("gamma")) p.gamma = std::max(0.01f, (float)p_dict["gamma"]);
	if (p_dict.has("cone_alpha")) p.cone_alpha = std::max(0.01f, (float)p_dict["cone_alpha"]);
	if (p_dict.has("ridge_amp")) p.ridge_amp = std::max(0.0f, (float)p_dict["ridge_amp"]);
	if (p_dict.has("base_noise_amp")) p.base_noise_amp = (float)p_dict["base_noise_amp"];
	if (p_dict.has("center")) p.center = (Vector2)p_dict["center"];
	if (p_dict.has("dx")) p.dx = p_dict["dx"];
	if (p_dict.has("dy")) p.dy = p_dict["dy"];
	if (p_dict.has("envelope")) p.envelope = p_dict["envelope"];
	return p;
}

MountainInselbergParams MountainInselbergParams::from_dict(const Dictionary &p_dict) {
	MountainInselbergParams p;
	if (p_dict.has("seed")) p.seed = (int)p_dict["seed"];
	if (p_dict.has("elevation")) p.elevation = (float)p_dict["elevation"];
	if (p_dict.has("scale")) p.scale = std::max(0.01f, (float)p_dict["scale"]);
	if (p_dict.has("octaves")) p.octaves = std::clamp((int)p_dict["octaves"], 1, 16);
	if (p_dict.has("rugosity")) p.rugosity = (float)p_dict["rugosity"];
	if (p_dict.has("angle")) p.angle = (float)p_dict["angle"];
	if (p_dict.has("gamma")) p.gamma = std::max(0.01f, (float)p_dict["gamma"]);
	if (p_dict.has("bulk_amp")) p.bulk_amp = std::max(0.0f, (float)p_dict["bulk_amp"]);
	if (p_dict.has("base_noise_amp")) p.base_noise_amp = (float)p_dict["base_noise_amp"];
	if (p_dict.has("center")) p.center = (Vector2)p_dict["center"];
	if (p_dict.has("dx")) p.dx = p_dict["dx"];
	if (p_dict.has("dy")) p.dy = p_dict["dy"];
	return p;
}

// Deterministic PRNG Hash (Wang Hash from HighMap)
static inline uint32_t wang_hash(uint32_t seed) {
	seed = (seed ^ 61) ^ (seed >> 16);
	seed *= 9;
	seed = seed ^ (seed >> 4);
	seed *= 0x27d4eb2d;
	seed = seed ^ (seed >> 15);
	return seed;
}

// Exact 2D Integer PCG Hash
static inline void hash22(int32_t ix, int32_t iy, uint32_t seed, float &out_x, float &out_y) {
	uint32_t ux = (uint32_t)ix * 0x8da6b343u;
	uint32_t uy = (uint32_t)iy * 0xd8163841u;
	uint32_t h1 = ux ^ uy ^ seed;
	h1 ^= h1 >> 13;
	h1 *= 0x85ebca6bu;
	h1 ^= h1 >> 16;
	out_x = (float)(h1 & 0xFFFFFF) / 16777216.0f;

	uint32_t h2 = (ux ^ 0x5bd1e995u) ^ uy ^ (seed + 1013904223u);
	h2 ^= h2 >> 13;
	h2 *= 0x85ebca6bu;
	h2 ^= h2 >> 16;
	out_y = (float)(h2 & 0xFFFFFF) / 16777216.0f;
}

// 2D Simplex Noise
static inline float simplex2_raw(float xin, float yin, uint32_t seed) {
	const float F2 = 0.5f * (std::sqrt(3.0f) - 1.0f);
	const float G2 = (3.0f - std::sqrt(3.0f)) / 6.0f;

	float s = (xin + yin) * F2;
	int i = (int)std::floor(xin + s);
	int j = (int)std::floor(yin + s);
	float t = (float)(i + j) * G2;
	float X0 = (float)i - t;
	float Y0 = (float)j - t;
	float x0 = xin - X0;
	float y0 = yin - Y0;

	int i1, j1;
	if (x0 > y0) { i1 = 1; j1 = 0; }
	else { i1 = 0; j1 = 1; }

	float x1 = x0 - (float)i1 + G2;
	float y1 = y0 - (float)j1 + G2;
	float x2 = x0 - 1.0f + 2.0f * G2;
	float y2 = y0 - 1.0f + 2.0f * G2;

	float n0 = 0.0f, n1 = 0.0f, n2 = 0.0f;

	float t0 = 0.5f - x0 * x0 - y0 * y0;
	if (t0 > 0.0f) {
		t0 *= t0;
		float hx, hy;
		hash22(i, j, seed, hx, hy);
		float h = hx * 6.2831853f;
		n0 = t0 * t0 * (std::cos(h) * x0 + std::sin(h) * y0);
	}

	float t1 = 0.5f - x1 * x1 - y1 * y1;
	if (t1 > 0.0f) {
		t1 *= t1;
		float hx, hy;
		hash22(i + i1, j + j1, seed, hx, hy);
		float h = hx * 6.2831853f;
		n1 = t1 * t1 * (std::cos(h) * x1 + std::sin(h) * y1);
	}

	float t2 = 0.5f - x2 * x2 - y2 * y2;
	if (t2 > 0.0f) {
		t2 *= t2;
		float hx, hy;
		hash22(i + 1, j + 1, seed, hx, hy);
		float h = hx * 6.2831853f;
		n2 = t2 * t2 * (std::cos(h) * x2 + std::sin(h) * y2);
	}

	return 70.0f * (n0 + n1 + n2);
}

static inline float simplex2_fbm(float x, float y, int octaves, float persistence, float lacunarity, uint32_t seed) {
	float total = 0.0f;
	float amp = 1.0f;
	float freq = 1.0f;
	float max_amp = 0.0f;

	for (int o = 0; o < octaves; o++) {
		total += amp * simplex2_raw(x * freq, y * freq, seed + (uint32_t)(o * 7919));
		max_amp += amp;
		amp *= persistence;
		freq *= lacunarity;
	}
	return (max_amp > 0.0f) ? (total / max_amp) : 0.0f;
}

// Inigo Quilez's exact analytical Voronoi Edge Distance (Hesiod VoronoiReturnType::EDGE_DISTANCE_SQUARED)
static inline float voronoi_edge_distance_raw(float x, float y, uint32_t seed) {
	float px = std::floor(x);
	float py = std::floor(y);
	float fx = x - px;
	float fy = y - py;

	int ipx = (int)px;
	int ipy = (int)py;

	float mr_x = 0.0f, mr_y = 0.0f;
	float mb_x = 0.0f, mb_y = 0.0f;
	float res = 8.0f;

	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			float bx = (float)i;
			float by = (float)j;
			float hx, hy;
			hash22(ipx + i, ipy + j, seed, hx, hy);
			float rx = bx - fx + hx;
			float ry = by - fy + hy;
			float d = rx * rx + ry * ry;
			if (d < res) {
				res = d;
				mr_x = rx;
				mr_y = ry;
				mb_x = bx;
				mb_y = by;
			}
		}
	}

	res = 8.0f;
	for (int j = -2; j <= 2; j++) {
		for (int i = -2; i <= 2; i++) {
			float bx = mb_x + (float)i;
			float by = mb_y + (float)j;
			float hx, hy;
			hash22(ipx + (int)mb_x + i, ipy + (int)mb_y + j, seed, hx, hy);
			float rx = bx - fx + hx;
			float ry = by - fy + hy;
			float diff_x = mr_x - rx;
			float diff_y = mr_y - ry;
			float diff_d2 = diff_x * diff_x + diff_y * diff_y;
			if (diff_d2 > 1.0e-6f) {
				float mid_x = 0.5f * (mr_x + rx);
				float mid_y = 0.5f * (mr_y + ry);
				float norm = std::sqrt(diff_d2);
				float dir_x = (rx - mr_x) / norm;
				float dir_y = (ry - mr_y) / norm;
				float d = mid_x * dir_x + mid_y * dir_y;
				res = std::min(res, d);
			}
		}
	}

	return std::max(0.0f, res);
}

// Voronoi F2 - F1 (Hesiod VoronoiReturnType::CONSTANT_F2MF1_SQUARED)
static inline float voronoi_f2mf1_raw(float x, float y, uint32_t seed) {
	float px = std::floor(x);
	float py = std::floor(y);
	float fx = x - px;
	float fy = y - py;

	int ipx = (int)px;
	int ipy = (int)py;

	float d1 = 8.0f;
	float d2 = 8.0f;

	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			float bx = (float)i;
			float by = (float)j;
			float hx, hy;
			hash22(ipx + i, ipy + j, seed, hx, hy);
			float rx = bx - fx + hx;
			float ry = by - fy + hy;
			float d = std::sqrt(rx * rx + ry * ry);
			if (d < d1) {
				d2 = d1;
				d1 = d;
			} else if (d < d2) {
				d2 = d;
			}
		}
	}

	return std::max(0.0f, d2 - d1);
}

static inline float voronoi_edge_fbm(float x, float y, int octaves, float persistence, float lacunarity, uint32_t seed) {
	float total = 0.0f;
	float amp = 1.0f;
	float freq = 1.0f;
	float max_amp = 0.0f;

	for (int o = 0; o < octaves; o++) {
		total += amp * voronoi_edge_distance_raw(x * freq, y * freq, seed + (uint32_t)(o * 6271));
		max_amp += amp;
		amp *= persistence;
		freq *= lacunarity;
	}
	return (max_amp > 0.0f) ? (total / max_amp) : 0.0f;
}

static inline float voronoi_f2mf1_fbm(float x, float y, int octaves, float persistence, float lacunarity, uint32_t seed) {
	float total = 0.0f;
	float amp = 1.0f;
	float freq = 1.0f;
	float max_amp = 0.0f;

	for (int o = 0; o < octaves; o++) {
		total += amp * voronoi_f2mf1_raw(x * freq, y * freq, seed + (uint32_t)(o * 6271));
		max_amp += amp;
		amp *= persistence;
		freq *= lacunarity;
	}
	return (max_amp > 0.0f) ? (total / max_amp) : 0.0f;
}

PackedFloat32Array godot::mountain_cone_solve(int p_gw, int p_gh, const Rect2 &p_rect, const MountainConeParams &p_params) {
	PackedFloat32Array out;
	if (p_gw < 2 || p_gh < 2) return out;
	const int n = p_gw * p_gh;
	out.resize(n);
	float *out_ptr = out.ptrw();

	const float radius = 0.5f * p_params.scale;
	const float kw = p_params.peak_kw / std::max(0.01f, p_params.scale);
	const float persistence = 0.5f;
	const float lacunarity = 2.0f;
	const float alpha = p_params.angle * 0.0174532925f; // deg to rad
	const uint32_t seed_u = wang_hash((uint32_t)p_params.seed);

	const bool has_dx = (p_params.dx.size() == n);
	const bool has_dy = (p_params.dy.size() == n);
	const bool has_env = (p_params.envelope.size() == n);
	const float *dx_ptr = has_dx ? p_params.dx.ptr() : nullptr;
	const float *dy_ptr = has_dy ? p_params.dy.ptr() : nullptr;
	const float *env_ptr = has_env ? p_params.envelope.ptr() : nullptr;

	for (int iz = 0; iz < p_gh; iz++) {
		float ny = (float)iz / (float)(p_gh - 1);
		for (int ix = 0; ix < p_gw; ix++) {
			float nx = (float)ix / (float)(p_gw - 1);
			int idx = iz * p_gw + ix;

			// Base strike displacement noise
			float base_n = p_params.scale * p_params.base_noise_amp *
					simplex2_fbm(nx * kw, ny * kw, p_params.octaves, persistence, lacunarity, seed_u);

			float disp_x = base_n * std::cos(alpha) + (has_dx ? dx_ptr[idx] : 0.0f);
			float disp_y = base_n * std::sin(alpha) + (has_dy ? dy_ptr[idx] : 0.0f);

			// Sigmoid conical envelope
			float cx = nx + disp_x * 0.2f - p_params.center.x;
			float cy = ny + disp_y * 0.2f - p_params.center.y;
			float dist = std::sqrt(cx * cx + cy * cy) / std::max(1.0e-5f, radius);

			float cone = 0.0f;
			if (dist < 1.0f) {
				float r_pow = std::pow(dist, p_params.cone_alpha);
				cone = (1.0f - r_pow) / (1.0f + r_pow);
				cone = std::clamp(cone, 0.0f, 1.0f);
				cone = cone * cone * (3.0f - 2.0f * cone); // smoothstep3_lower
			}

			if (has_env) {
				cone *= env_ptr[idx];
			}

			// Cellular Voronoi knife-edge ridges with domain warping
			float vx = (nx + disp_x) * kw;
			float vy = (ny + disp_y) * kw;
			float vor = 2.0f * voronoi_edge_fbm(vx, vy, p_params.octaves, persistence, lacunarity, seed_u);
			vor = std::max(0.0f, vor);

			// Gamma profile sharpening
			if (p_params.gamma > 0.0f) {
				vor = std::pow(vor, p_params.gamma);
			}

			// Modulate cone with ridges
			float val = cone * (p_params.ridge_amp * vor + 1.0f) / (p_params.ridge_amp + 1.0f);
			out_ptr[idx] = val * p_params.elevation;
		}
	}

	return out;
}

PackedFloat32Array godot::mountain_inselberg_solve(int p_gw, int p_gh, const Rect2 &p_rect, const MountainInselbergParams &p_params) {
	PackedFloat32Array out;
	if (p_gw < 2 || p_gh < 2) return out;
	const int n = p_gw * p_gh;
	out.resize(n);
	float *out_ptr = out.ptrw();

	const float half_width = 0.2f * p_params.scale;
	const float kw = 2.6f / std::max(0.01f, p_params.scale);
	const float persistence = 0.5f;
	const float lacunarity = 2.0f;
	const float alpha = p_params.angle * 0.0174532925f;
	const uint32_t seed_u = wang_hash((uint32_t)p_params.seed);

	const bool has_dx = (p_params.dx.size() == n);
	const bool has_dy = (p_params.dy.size() == n);
	const float *dx_ptr = has_dx ? p_params.dx.ptr() : nullptr;
	const float *dy_ptr = has_dy ? p_params.dy.ptr() : nullptr;

	for (int iz = 0; iz < p_gh; iz++) {
		float ny = (float)iz / (float)(p_gh - 1);
		for (int ix = 0; ix < p_gw; ix++) {
			float nx = (float)ix / (float)(p_gw - 1);
			int idx = iz * p_gw + ix;

			float base_n = p_params.scale * p_params.base_noise_amp *
					simplex2_fbm(nx * kw, ny * kw, p_params.octaves, persistence, lacunarity, seed_u);

			float disp_x = base_n * std::cos(alpha) + (has_dx ? dx_ptr[idx] : 0.0f);
			float disp_y = base_n * std::sin(alpha) + (has_dy ? dy_ptr[idx] : 0.0f);

			// Gaussian pulse envelope
			float cx = nx + disp_x * 0.15f - p_params.center.x;
			float cy = ny + disp_y * 0.15f - p_params.center.y;
			float dist_sq = (cx * cx + cy * cy) / std::max(1.0e-5f, half_width * half_width);
			float pulse = std::exp(-dist_sq);

			// Voronoi F2 - F1 bedrock fracture ridges
			float vx = (nx + disp_x) * kw;
			float vy = (ny + disp_y) * kw;
			float vor = 0.72f + voronoi_f2mf1_fbm(vx, vy, p_params.octaves, persistence, lacunarity, seed_u);
			vor = std::max(0.0f, vor) * pulse;

			if (p_params.bulk_amp > 0.0f) {
				vor = (vor + p_params.bulk_amp * pulse) / (1.0f + p_params.bulk_amp);
			}

			if (p_params.gamma > 0.0f) {
				vor = std::pow(vor, p_params.gamma);
			}

			out_ptr[idx] = vor * p_params.elevation;
		}
	}

	return out;
}
