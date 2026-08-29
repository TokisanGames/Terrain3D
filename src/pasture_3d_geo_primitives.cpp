// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_geo_primitives.h"
#include "pasture_3d_thread_pool.h"

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

MountainRangeRadialParams MountainRangeRadialParams::from_dict(const Dictionary &p_dict) {
	MountainRangeRadialParams p;
	if (p_dict.has("seed")) p.seed = (int)p_dict["seed"];
	if (p_dict.has("elevation")) p.elevation = (float)p_dict["elevation"];
	if (p_dict.has("kw_x")) p.kw_x = std::max(0.01f, (float)p_dict["kw_x"]);
	if (p_dict.has("kw_y")) p.kw_y = std::max(0.01f, (float)p_dict["kw_y"]);
	if (p_dict.has("half_width")) p.half_width = std::max(0.01f, (float)p_dict["half_width"]);
	if (p_dict.has("angle_spread_ratio")) p.angle_spread_ratio = std::clamp((float)p_dict["angle_spread_ratio"], 0.0f, 1.0f);
	if (p_dict.has("core_size_ratio")) p.core_size_ratio = std::max(0.01f, (float)p_dict["core_size_ratio"]);
	if (p_dict.has("center")) p.center = (Vector2)p_dict["center"];
	if (p_dict.has("octaves")) p.octaves = std::clamp((int)p_dict["octaves"], 1, 16);
	if (p_dict.has("weight")) p.weight = std::clamp((float)p_dict["weight"], 0.0f, 1.0f);
	if (p_dict.has("persistence")) p.persistence = std::clamp((float)p_dict["persistence"], 0.0f, 1.0f);
	if (p_dict.has("lacunarity")) p.lacunarity = std::max(0.01f, (float)p_dict["lacunarity"]);
	if (p_dict.has("ctrl_param")) p.ctrl_param = p_dict["ctrl_param"];
	if (p_dict.has("dx")) p.dx = p_dict["dx"];
	if (p_dict.has("dy")) p.dy = p_dict["dy"];
	if (p_dict.has("envelope")) p.envelope = p_dict["envelope"];
	return p;
}

MountainTibestiParams MountainTibestiParams::from_dict(const Dictionary &p_dict) {
	MountainTibestiParams p;
	if (p_dict.has("seed")) p.seed = (int)p_dict["seed"];
	if (p_dict.has("elevation")) p.elevation = (float)p_dict["elevation"];
	if (p_dict.has("scale")) p.scale = std::max(0.01f, (float)p_dict["scale"]);
	if (p_dict.has("octaves")) p.octaves = std::clamp((int)p_dict["octaves"], 1, 16);
	if (p_dict.has("peak_kw")) p.peak_kw = std::max(0.01f, (float)p_dict["peak_kw"]);
	if (p_dict.has("rugosity")) p.rugosity = (float)p_dict["rugosity"];
	if (p_dict.has("angle")) p.angle = (float)p_dict["angle"];
	if (p_dict.has("angle_spread_ratio")) p.angle_spread_ratio = std::clamp((float)p_dict["angle_spread_ratio"], 0.0f, 1.0f);
	if (p_dict.has("gamma")) p.gamma = std::max(0.01f, (float)p_dict["gamma"]);
	if (p_dict.has("bulk_amp")) p.bulk_amp = std::max(0.0f, (float)p_dict["bulk_amp"]);
	if (p_dict.has("base_noise_amp")) p.base_noise_amp = (float)p_dict["base_noise_amp"];
	if (p_dict.has("center")) p.center = (Vector2)p_dict["center"];
	if (p_dict.has("dx")) p.dx = p_dict["dx"];
	if (p_dict.has("dy")) p.dy = p_dict["dy"];
	return p;
}

MountainStumpParams MountainStumpParams::from_dict(const Dictionary &p_dict) {
	MountainStumpParams p;
	if (p_dict.has("seed")) p.seed = (int)p_dict["seed"];
	if (p_dict.has("elevation")) p.elevation = (float)p_dict["elevation"];
	if (p_dict.has("scale")) p.scale = std::max(0.01f, (float)p_dict["scale"]);
	if (p_dict.has("octaves")) p.octaves = std::clamp((int)p_dict["octaves"], 1, 16);
	if (p_dict.has("peak_kw")) p.peak_kw = std::max(0.01f, (float)p_dict["peak_kw"]);
	if (p_dict.has("rugosity")) p.rugosity = (float)p_dict["rugosity"];
	if (p_dict.has("angle")) p.angle = (float)p_dict["angle"];
	if (p_dict.has("k_smoothing")) p.k_smoothing = std::max(0.001f, (float)p_dict["k_smoothing"]);
	if (p_dict.has("gamma")) p.gamma = std::max(0.01f, (float)p_dict["gamma"]);
	if (p_dict.has("ridge_amp")) p.ridge_amp = std::max(0.0f, (float)p_dict["ridge_amp"]);
	if (p_dict.has("base_noise_amp")) p.base_noise_amp = (float)p_dict["base_noise_amp"];
	if (p_dict.has("center")) p.center = (Vector2)p_dict["center"];
	if (p_dict.has("dx")) p.dx = p_dict["dx"];
	if (p_dict.has("dy")) p.dy = p_dict["dy"];
	return p;
}

ShatteredPeakParams ShatteredPeakParams::from_dict(const Dictionary &p_dict) {
	ShatteredPeakParams p;
	if (p_dict.has("seed")) p.seed = (int)p_dict["seed"];
	if (p_dict.has("elevation")) p.elevation = (float)p_dict["elevation"];
	if (p_dict.has("scale")) p.scale = std::max(0.01f, (float)p_dict["scale"]);
	if (p_dict.has("octaves")) p.octaves = std::clamp((int)p_dict["octaves"], 1, 16);
	if (p_dict.has("peak_kw")) p.peak_kw = std::max(0.01f, (float)p_dict["peak_kw"]);
	if (p_dict.has("rugosity")) p.rugosity = (float)p_dict["rugosity"];
	if (p_dict.has("angle")) p.angle = (float)p_dict["angle"];
	if (p_dict.has("gamma")) p.gamma = std::max(0.01f, (float)p_dict["gamma"]);
	if (p_dict.has("bulk_amp")) p.bulk_amp = std::max(0.0f, (float)p_dict["bulk_amp"]);
	if (p_dict.has("base_noise_amp")) p.base_noise_amp = (float)p_dict["base_noise_amp"];
	if (p_dict.has("k_smoothing")) p.k_smoothing = std::max(0.001f, (float)p_dict["k_smoothing"]);
	if (p_dict.has("center")) p.center = (Vector2)p_dict["center"];
	if (p_dict.has("dx")) p.dx = p_dict["dx"];
	if (p_dict.has("dy")) p.dy = p_dict["dy"];
	return p;
}

CalderaParams CalderaParams::from_dict(const Dictionary &p_dict) {
	CalderaParams p;
	if (p_dict.has("elevation")) p.elevation = (float)p_dict["elevation"];
	if (p_dict.has("radius")) p.radius = (float)p_dict["radius"];
	if (p_dict.has("sigma_inner")) p.sigma_inner = std::max(0.001f, (float)p_dict["sigma_inner"]);
	if (p_dict.has("sigma_outer")) p.sigma_outer = std::max(0.001f, (float)p_dict["sigma_outer"]);
	if (p_dict.has("z_bottom")) p.z_bottom = (float)p_dict["z_bottom"];
	if (p_dict.has("noise_r_amp")) p.noise_r_amp = (float)p_dict["noise_r_amp"];
	if (p_dict.has("noise_z_ratio")) p.noise_z_ratio = (float)p_dict["noise_z_ratio"];
	if (p_dict.has("center")) p.center = (Vector2)p_dict["center"];
	if (p_dict.has("noise")) p.noise = p_dict["noise"];
	return p;
}

// wang_hash() lives in pasture_3d_geo_primitives.h so the GPU router can pre-hash the seed identically.

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

	int i1 = x0 > y0 ? 1 : 0;
	int j1 = x0 > y0 ? 0 : 1;

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
	for (int o = 0; o < octaves; ++o) {
		total += amp * simplex2_raw(x * freq, y * freq, seed + (uint32_t)o * 7919u);
		max_amp += amp;
		amp *= persistence;
		freq *= lacunarity;
	}
	return max_amp > 0.0f ? (total / max_amp) : 0.0f;
}

// Analytical Inigo Quilez Voronoi Knife-Edge Ridge Kernel
static inline float voronoi_edge_distance_raw(float x, float y, uint32_t seed) {
	float px = std::floor(x);
	float py = std::floor(y);
	float fx = x - px;
	float fy = y - py;

	int32_t ipx = (int32_t)px;
	int32_t ipy = (int32_t)py;

	int32_t mbx = 0;
	int32_t mby = 0;
	float mr_x = 0.0f;
	float mr_y = 0.0f;
	float md = 8.0f;

	for (int j = -1; j <= 1; ++j) {
		for (int i = -1; i <= 1; ++i) {
			float bx = (float)i;
			float by = (float)j;
			float hx, hy;
			hash22(ipx + i, ipy + j, seed, hx, hy);
			float rx = bx - fx + hx;
			float ry = by - fy + hy;
			float d = rx * rx + ry * ry;
			if (d < md) {
				md = d;
				mr_x = rx;
				mr_y = ry;
				mbx = i;
				mby = j;
			}
		}
	}

	float res = 8.0f;
	for (int j = -2; j <= 2; ++j) {
		for (int i = -2; i <= 2; ++i) {
			float bx = (float)(mbx + i);
			float by = (float)(mby + j);
			float hx, hy;
			hash22(ipx + mbx + i, ipy + mby + j, seed, hx, hy);
			float rx = bx - fx + hx;
			float ry = by - fy + hy;

			float diff_x = rx - mr_x;
			float diff_y = ry - mr_y;
			if (diff_x * diff_x + diff_y * diff_y > 1e-6f) {
				float mid_x = 0.5f * (mr_x + rx);
				float mid_y = 0.5f * (mr_y + ry);
				float norm = std::sqrt(diff_x * diff_x + diff_y * diff_y);
				float dir_x = (rx - mr_x) / norm;
				float dir_y = (ry - mr_y) / norm;
				float d = mid_x * dir_x + mid_y * dir_y;
				res = std::min(res, d);
			}
		}
	}

	return std::max(0.0f, res);
}

static inline float voronoi_edge_fbm(float x, float y, int octaves, float persistence, float lacunarity, uint32_t seed) {
	float total = 0.0f;
	float amp = 1.0f;
	float freq = 1.0f;
	float max_amp = 0.0f;
	for (int o = 0; o < octaves; ++o) {
		total += amp * voronoi_edge_distance_raw(x * freq, y * freq, seed + (uint32_t)o * 6271u);
		max_amp += amp;
		amp *= persistence;
		freq *= lacunarity;
	}
	return max_amp > 0.0f ? (total / max_amp) : 0.0f;
}

// Voronoi F2 - F1 Bedrock Fracture Kernel
static inline float voronoi_f2mf1_raw(float x, float y, uint32_t seed) {
	float px = std::floor(x);
	float py = std::floor(y);
	float fx = x - px;
	float fy = y - py;

	int32_t ipx = (int32_t)px;
	int32_t ipy = (int32_t)py;

	float d1 = 8.0f;
	float d2 = 8.0f;

	for (int j = -1; j <= 1; ++j) {
		for (int i = -1; i <= 1; ++i) {
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

static inline float voronoi_f2mf1_fbm(float x, float y, int octaves, float persistence, float lacunarity, uint32_t seed) {
	float total = 0.0f;
	float amp = 1.0f;
	float freq = 1.0f;
	float max_amp = 0.0f;
	for (int o = 0; o < octaves; ++o) {
		total += amp * voronoi_f2mf1_raw(x * freq, y * freq, seed + (uint32_t)o * 6271u);
		max_amp += amp;
		amp *= persistence;
		freq *= lacunarity;
	}
	return max_amp > 0.0f ? (total / max_amp) : 0.0f;
}

// Inigo Quilez Gabor Wave Directional Noise Kernel
static inline float gabor_wave_scalar(float x, float y, float dir_x, float dir_y, float angle_spread_ratio, uint32_t seed) {
	float ip_x = std::floor(x);
	float ip_y = std::floor(y);
	float fp_x = x - ip_x;
	float fp_y = y - ip_y;

	int32_t i_ipx = (int32_t)ip_x;
	int32_t i_ipy = (int32_t)ip_y;

	const float fr = 6.2831853f;
	const float fa = 4.0f;

	float av = 0.0f;
	float at = 0.0f;

	for (int j = -2; j <= 2; ++j) {
		for (int i = -2; i <= 2; ++i) {
			float hx, hy;
			hash22(i_ipx + i, i_ipy + j, seed, hx, hy);
			float rx = fp_x - ((float)i + hx);
			float ry = fp_y - ((float)j + hy);

			float kx_r, ky_r;
			hash22(i_ipx + i + 11, i_ipy + j + 31, seed, kx_r, ky_r);
			float kx = dir_x + angle_spread_ratio * (2.0f * kx_r - 1.0f);
			float ky = dir_y + angle_spread_ratio * (2.0f * ky_r - 1.0f);
			float kn = std::sqrt(kx * kx + ky * ky);
			if (kn > 1e-6f) {
				kx /= kn;
				ky /= kn;
			}

			float d = rx * rx + ry * ry;
			float l = rx * kx + ry * ky;
			float w = std::exp(-fa * d);
			float cs = std::cos(fr * l);

			av += w * cs;
			at += w;
		}
	}

	return at > 1e-6f ? (av / at) : 0.0f;
}

static inline float gabor_wave_scalar_fbm(float x, float y, float dir_x, float dir_y, float angle_spread_ratio,
		int octaves, float weight, float persistence, float lacunarity, uint32_t seed) {
	float n = 0.0f;
	float nf = 1.0f;
	float na = 0.6f;
	for (int o = 0; o < octaves; ++o) {
		float v = gabor_wave_scalar(x * nf, y * nf, dir_x, dir_y, angle_spread_ratio, seed + (uint32_t)o * 5437u);
		n += v * na;
		na *= (1.0f - weight) + weight * std::min(v + 1.0f, 2.0f) * 0.5f;
		na *= persistence;
		nf *= lacunarity;
	}
	return n;
}

static inline float lerp_f(float a, float b, float t) {
	return a + t * (b - a);
}

static inline float minimum_smooth(float a, float b, float k) {
	float h = std::clamp(0.5f + 0.5f * (b - a) / std::max(1e-5f, k), 0.0f, 1.0f);
	return lerp_f(b, a, h) - k * h * (1.0f - h);
}

// nyquist_octave_cap() lives in pasture_3d_geo_primitives.h so the GPU router computes the identical cap.

// ----------------------------------------------------------------------------------------------------
// 1. MountainCone Solve
// ----------------------------------------------------------------------------------------------------
PackedFloat32Array godot::mountain_cone_solve(int p_gw, int p_gh, const Rect2 &p_rect, const MountainConeParams &p_params) {
	int n = p_gw * p_gh;
	PackedFloat32Array out;
	out.resize(n);
	float *out_ptr = out.ptrw();

	float half_radius = 0.5f * p_params.scale;
	float kw = p_params.peak_kw / p_params.scale;
	float persistence = 0.5f;
	float lacunarity = 2.0f;
	float alpha = p_params.angle * 0.0174532925f;
	float cos_alpha = std::cos(alpha);
	float sin_alpha = std::sin(alpha);
	int octaves = nyquist_octave_cap(p_params.octaves, kw, lacunarity, std::min(p_gw, p_gh));
	uint32_t seed_u = wang_hash((uint32_t)p_params.seed);

	const float *dx_ptr = (p_params.dx.size() == n) ? p_params.dx.ptr() : nullptr;
	const float *dy_ptr = (p_params.dy.size() == n) ? p_params.dy.ptr() : nullptr;
	const float *env_ptr = (p_params.envelope.size() == n) ? p_params.envelope.ptr() : nullptr;

	Pasture3DThreadPool::parallel_for_rows(p_gh, 8, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; ++iz) {
			float ny = (p_gh > 1) ? ((float)iz / (float)(p_gh - 1)) : 0.5f;
			const int row = iz * p_gw;
			for (int ix = 0; ix < p_gw; ++ix) {
				float nx = (p_gw > 1) ? ((float)ix / (float)(p_gw - 1)) : 0.5f;
				int idx = row + ix;

				float base_n = p_params.scale * p_params.base_noise_amp * simplex2_fbm(nx * kw, ny * kw, octaves, persistence, lacunarity, seed_u);
				float disp_x = base_n * cos_alpha + (dx_ptr ? dx_ptr[idx] : 0.0f);
				float disp_y = base_n * sin_alpha + (dy_ptr ? dy_ptr[idx] : 0.0f);

				float cx = nx + disp_x * 0.2f - p_params.center.x;
				float cy = ny + disp_y * 0.2f - p_params.center.y;
				float dist = std::sqrt(cx * cx + cy * cy) / std::max(1.0e-5f, half_radius);

				float cone = 0.0f;
				if (dist < 1.0f) {
					float r_pow = std::pow(dist, p_params.cone_alpha);
					float raw_cone = (1.0f - r_pow) / (1.0f + r_pow);
					float t = std::clamp(raw_cone, 0.0f, 1.0f);
					cone = t * t * (3.0f - 2.0f * t);
				}

				if (env_ptr) {
					cone *= env_ptr[idx];
				}

				float vx = (nx + disp_x) * kw;
				float vy = (ny + disp_y) * kw;
				float vor = 2.0f * voronoi_edge_fbm(vx, vy, octaves, persistence, lacunarity, seed_u);
				vor = std::max(0.0f, vor);

				if (p_params.gamma > 0.0f) {
					vor = std::pow(vor, p_params.gamma);
				}

				float val = cone * (p_params.ridge_amp * vor + 1.0f) / (p_params.ridge_amp + 1.0f);
				out_ptr[idx] = val * p_params.elevation;
			}
		}
	});

	return out;
}

// ----------------------------------------------------------------------------------------------------
// 2. MountainInselberg Solve
// ----------------------------------------------------------------------------------------------------
PackedFloat32Array godot::mountain_inselberg_solve(int p_gw, int p_gh, const Rect2 &p_rect, const MountainInselbergParams &p_params) {
	int n = p_gw * p_gh;
	PackedFloat32Array out;
	out.resize(n);
	float *out_ptr = out.ptrw();

	float half_width = 0.2f * p_params.scale;
	float kw = 2.6f / p_params.scale;
	float persistence = 0.5f;
	float lacunarity = 2.0f;
	float alpha = p_params.angle * 0.0174532925f;
	float cos_alpha = std::cos(alpha);
	float sin_alpha = std::sin(alpha);
	int octaves = nyquist_octave_cap(p_params.octaves, kw, lacunarity, std::min(p_gw, p_gh));
	uint32_t seed_u = wang_hash((uint32_t)p_params.seed);

	const float *dx_ptr = (p_params.dx.size() == n) ? p_params.dx.ptr() : nullptr;
	const float *dy_ptr = (p_params.dy.size() == n) ? p_params.dy.ptr() : nullptr;

	Pasture3DThreadPool::parallel_for_rows(p_gh, 8, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; ++iz) {
			float ny = (p_gh > 1) ? ((float)iz / (float)(p_gh - 1)) : 0.5f;
			const int row = iz * p_gw;
			for (int ix = 0; ix < p_gw; ++ix) {
				float nx = (p_gw > 1) ? ((float)ix / (float)(p_gw - 1)) : 0.5f;
				int idx = row + ix;

				float base_n = p_params.scale * p_params.base_noise_amp * simplex2_fbm(nx * kw, ny * kw, octaves, persistence, lacunarity, seed_u);
				float disp_x = base_n * cos_alpha + (dx_ptr ? dx_ptr[idx] : 0.0f);
				float disp_y = base_n * sin_alpha + (dy_ptr ? dy_ptr[idx] : 0.0f);

				float cx = nx + disp_x * 0.15f - p_params.center.x;
				float cy = ny + disp_y * 0.15f - p_params.center.y;
				float dist_sq = (cx * cx + cy * cy) / std::max(1.0e-5f, half_width * half_width);
				float pulse = std::exp(-dist_sq);

				float vx = (nx + disp_x) * kw;
				float vy = (ny + disp_y) * kw;
				float vor = 0.72f + voronoi_f2mf1_fbm(vx, vy, octaves, persistence, lacunarity, seed_u);
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
	});

	return out;
}

// ----------------------------------------------------------------------------------------------------
// 3. MountainRangeRadial Solve
// ----------------------------------------------------------------------------------------------------
Array godot::mountain_range_radial_solve(int p_gw, int p_gh, const Rect2 &p_rect, const MountainRangeRadialParams &p_params) {
	int n = p_gw * p_gh;
	PackedFloat32Array out_height;
	out_height.resize(n);
	float *out_h = out_height.ptrw();

	PackedFloat32Array out_angle;
	out_angle.resize(n);
	float *out_a = out_angle.ptrw();

	uint32_t seed_u = wang_hash((uint32_t)p_params.seed);
	const float *ctrl_ptr = (p_params.ctrl_param.size() == n) ? p_params.ctrl_param.ptr() : nullptr;
	const float *dx_ptr = (p_params.dx.size() == n) ? p_params.dx.ptr() : nullptr;
	const float *dy_ptr = (p_params.dy.size() == n) ? p_params.dy.ptr() : nullptr;
	const float *env_ptr = (p_params.envelope.size() == n) ? p_params.envelope.ptr() : nullptr;

	float r2_max = p_params.core_size_ratio / std::max(0.01f, std::max(p_params.kw_x, p_params.kw_y));
	float hw2 = std::max(1e-5f, p_params.half_width * p_params.half_width);
	int octaves = nyquist_octave_cap(p_params.octaves, std::max(p_params.kw_x, p_params.kw_y), p_params.lacunarity, std::min(p_gw, p_gh));

	Pasture3DThreadPool::parallel_for_rows(p_gh, 8, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; ++iz) {
			float ny = (p_gh > 1) ? ((float)iz / (float)(p_gh - 1)) : 0.5f;
			const int row = iz * p_gw;
			for (int ix = 0; ix < p_gw; ++ix) {
				float nx = (p_gw > 1) ? ((float)ix / (float)(p_gw - 1)) : 0.5f;
				int idx = row + ix;

				float ct = ctrl_ptr ? ctrl_ptr[idx] : 1.0f;
				float dx = dx_ptr ? dx_ptr[idx] : 0.0f;
				float dy = dy_ptr ? dy_ptr[idx] : 0.0f;

				float px = (nx + dx) * p_params.kw_x;
				float py = (ny + dy) * p_params.kw_y;

				float cx = nx - p_params.center.x;
				float cy = ny - p_params.center.y;
				float r2 = cx * cx + cy * cy;
				float amp = env_ptr ? env_ptr[idx] : std::exp(-0.5f * r2 / hw2);

				float theta = std::atan2(cy, cx) + 1.5707963268f;
				float dir_x = std::cos(theta);
				float dir_y = std::sin(theta);

				ct *= amp;
				float eff_weight = (1.0f - ct) + ct * p_params.weight;
				float noise = gabor_wave_scalar_fbm(px, py, dir_x, dir_y, p_params.angle_spread_ratio,
						octaves, eff_weight, p_params.persistence, p_params.lacunarity, seed_u);

				float t = std::min(1.0f, r2 / std::max(1e-5f, r2_max));
				t = std::sqrt(t) * (1.0f - std::exp(-500.0f * t));
				t = std::clamp(t, 0.0f, 1.0f);
				t = t * t * (3.0f - 2.0f * t);

				out_h[idx] = amp * lerp_f(1.0f, 0.5f * noise + 0.5f, t) * p_params.elevation;
				out_a[idx] = theta;
			}
		}
	});

	Array res;
	res.append(out_height);
	res.append(out_angle);
	return res;
}

// ----------------------------------------------------------------------------------------------------
// 4. MountainTibesti Solve
// ----------------------------------------------------------------------------------------------------
PackedFloat32Array godot::mountain_tibesti_solve(int p_gw, int p_gh, const Rect2 &p_rect, const MountainTibestiParams &p_params) {
	int n = p_gw * p_gh;
	PackedFloat32Array out;
	out.resize(n);
	float *out_ptr = out.ptrw();

	float persistence = 0.5f;
	float lacunarity = 2.0f;
	float alpha = p_params.angle * 0.0174532925f;
	float half_width = 0.3f * p_params.scale;
	float kw_base = p_params.peak_kw / p_params.scale;
	float kw_noise4 = 4.0f / p_params.scale;
	float kw_noise2 = 2.0f / p_params.scale;
	int shape_min = std::min(p_gw, p_gh);
	int oct_base = nyquist_octave_cap(p_params.octaves, kw_base, lacunarity, shape_min);
	int oct4 = nyquist_octave_cap(p_params.octaves, kw_noise4, lacunarity, shape_min);
	int oct2 = nyquist_octave_cap(p_params.octaves, kw_noise2, lacunarity, shape_min);
	uint32_t seed_u = wang_hash((uint32_t)p_params.seed);

	const float *dx_ptr = (p_params.dx.size() == n) ? p_params.dx.ptr() : nullptr;
	const float *dy_ptr = (p_params.dy.size() == n) ? p_params.dy.ptr() : nullptr;

	float dir_x = std::cos(alpha);
	float dir_y = std::sin(alpha);

	Pasture3DThreadPool::parallel_for_rows(p_gh, 8, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; ++iz) {
			float ny = (p_gh > 1) ? ((float)iz / (float)(p_gh - 1)) : 0.5f;
			const int row = iz * p_gw;
			for (int ix = 0; ix < p_gw; ++ix) {
				float nx = (p_gw > 1) ? ((float)ix / (float)(p_gw - 1)) : 0.5f;
				int idx = row + ix;

				float n4 = simplex2_fbm(nx * kw_noise4, ny * kw_noise4, oct4, persistence, lacunarity, seed_u + 101u);
				n4 = 0.5f * n4 + 0.5f;
				n4 = std::max(0.0f, n4);
				if (p_params.gamma > 0.0f) {
					n4 = std::pow(n4, p_params.gamma);
				}

				float n2 = p_params.scale * p_params.base_noise_amp * simplex2_fbm(nx * kw_noise2, ny * kw_noise2, oct2, persistence, lacunarity, seed_u + 203u);
				float disp_x = n2 * dir_x + (dx_ptr ? dx_ptr[idx] : 0.0f);
				float disp_y = n2 * dir_y + (dy_ptr ? dy_ptr[idx] : 0.0f);

				float gabor = gabor_wave_scalar_fbm((nx + disp_x) * kw_base, (ny + disp_y) * kw_base, dir_x, dir_y,
						p_params.angle_spread_ratio, oct_base, 0.7f, persistence, lacunarity, seed_u + 307u);
				gabor = (0.5f * gabor + 0.5f) * n4;
				gabor = n4 * (p_params.bulk_amp + gabor) / (p_params.bulk_amp + 1.0f);

				float cx = nx - p_params.center.x;
				float cy = ny - p_params.center.y;
				float r2 = (cx * cx + cy * cy) / std::max(1e-5f, half_width * half_width);
				float pulse = std::exp(-0.5f * r2);

				out_ptr[idx] = gabor * pulse * p_params.elevation;
			}
		}
	});

	return out;
}

// ----------------------------------------------------------------------------------------------------
// 5. MountainStump Solve
// ----------------------------------------------------------------------------------------------------
PackedFloat32Array godot::mountain_stump_solve(int p_gw, int p_gh, const Rect2 &p_rect, const MountainStumpParams &p_params) {
	int n = p_gw * p_gh;
	PackedFloat32Array out;
	out.resize(n);
	float *out_ptr = out.ptrw();

	float half_width = 0.1f * p_params.scale;
	float kw = p_params.peak_kw / p_params.scale;
	float persistence = 0.5f;
	float lacunarity = 2.0f;
	float alpha = p_params.angle * 0.0174532925f;
	float cos_alpha = std::cos(alpha);
	float sin_alpha = std::sin(alpha);
	int octaves = nyquist_octave_cap(p_params.octaves, kw, lacunarity, std::min(p_gw, p_gh));
	uint32_t seed_u = wang_hash((uint32_t)p_params.seed);

	const float *dx_ptr = (p_params.dx.size() == n) ? p_params.dx.ptr() : nullptr;
	const float *dy_ptr = (p_params.dy.size() == n) ? p_params.dy.ptr() : nullptr;

	Pasture3DThreadPool::parallel_for_rows(p_gh, 8, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; ++iz) {
			float ny = (p_gh > 1) ? ((float)iz / (float)(p_gh - 1)) : 0.5f;
			const int row = iz * p_gw;
			for (int ix = 0; ix < p_gw; ++ix) {
				float nx = (p_gw > 1) ? ((float)ix / (float)(p_gw - 1)) : 0.5f;
				int idx = row + ix;

				float n_disp = p_params.scale * p_params.base_noise_amp * simplex2_fbm(nx * kw, ny * kw, octaves, persistence, lacunarity, seed_u);
				float disp_x = n_disp * cos_alpha + (dx_ptr ? dx_ptr[idx] : 0.0f);
				float disp_y = n_disp * sin_alpha + (dy_ptr ? dy_ptr[idx] : 0.0f);

				float cx = nx + disp_x * 0.1f - p_params.center.x;
				float cy = ny + disp_y * 0.1f - p_params.center.y;
				float r2 = (cx * cx + cy * cy) / std::max(1e-5f, half_width * half_width);
				float pulse = std::min(1.0f, 2.0f * std::exp(-0.5f * r2));

				float stump_n = 0.25f * simplex2_fbm((nx + disp_x) * kw, (ny + disp_y) * kw, octaves, persistence, lacunarity, seed_u + 71u) + 0.75f;
				float stump = minimum_smooth(stump_n, pulse, p_params.k_smoothing);

				float vx = (nx + disp_x) * kw;
				float vy = (ny + disp_y) * kw;
				float vor = 2.0f * voronoi_edge_fbm(vx, vy, octaves, persistence, lacunarity, seed_u + 149u);
				vor = std::min(1.0f, vor) * pulse;

				float val = stump + p_params.ridge_amp * vor;
				if (p_params.gamma > 0.0f) {
					val = std::pow(std::max(0.0f, val), p_params.gamma);
				}

				out_ptr[idx] = val * p_params.elevation;
			}
		}
	});

	return out;
}

// ----------------------------------------------------------------------------------------------------
// 6. ShatteredPeak Solve
// ----------------------------------------------------------------------------------------------------
PackedFloat32Array godot::shattered_peak_solve(int p_gw, int p_gh, const Rect2 &p_rect, const ShatteredPeakParams &p_params) {
	int n = p_gw * p_gh;
	PackedFloat32Array out;
	out.resize(n);
	float *out_ptr = out.ptrw();

	float half_width = 0.2f * p_params.scale;
	float kw = p_params.peak_kw / p_params.scale;
	float persistence = 0.5f;
	float lacunarity = 2.0f;
	float alpha = p_params.angle * 0.0174532925f;
	float cos_alpha = std::cos(alpha);
	float sin_alpha = std::sin(alpha);
	int octaves = nyquist_octave_cap(p_params.octaves, kw, lacunarity, std::min(p_gw, p_gh));
	uint32_t seed_u = wang_hash((uint32_t)p_params.seed);

	const float *dx_ptr = (p_params.dx.size() == n) ? p_params.dx.ptr() : nullptr;
	const float *dy_ptr = (p_params.dy.size() == n) ? p_params.dy.ptr() : nullptr;

	Pasture3DThreadPool::parallel_for_rows(p_gh, 8, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; ++iz) {
			float ny = (p_gh > 1) ? ((float)iz / (float)(p_gh - 1)) : 0.5f;
			const int row = iz * p_gw;
			for (int ix = 0; ix < p_gw; ++ix) {
				float nx = (p_gw > 1) ? ((float)ix / (float)(p_gw - 1)) : 0.5f;
				int idx = row + ix;

				float base_n = p_params.scale * p_params.base_noise_amp * simplex2_fbm(nx * kw, ny * kw, octaves, persistence, lacunarity, seed_u);
				float disp_x = base_n * cos_alpha + (dx_ptr ? dx_ptr[idx] : 0.0f);
				float disp_y = base_n * sin_alpha + (dy_ptr ? dy_ptr[idx] : 0.0f);

				float cx = nx + disp_x * 0.1f - p_params.center.x;
				float cy = ny + disp_y * 0.1f - p_params.center.y;
				float r2 = (cx * cx + cy * cy) / std::max(1e-5f, half_width * half_width);
				float pulse = std::exp(-0.5f * r2);

				float vx = (nx + disp_x) * kw;
				float vy = (ny + disp_y) * kw;
				float vor = voronoi_edge_fbm(vx, vy, octaves, persistence, lacunarity, seed_u + 89u);
				vor = (vor * pulse + p_params.bulk_amp * pulse) / (0.5f + p_params.bulk_amp);

				if (p_params.gamma > 0.0f) {
					vor = std::pow(std::max(0.0f, vor), p_params.gamma);
				}

				out_ptr[idx] = vor * p_params.elevation;
			}
		}
	});

	return out;
}

// ----------------------------------------------------------------------------------------------------
// 7. Caldera Solve
// ----------------------------------------------------------------------------------------------------
PackedFloat32Array godot::caldera_solve(int p_gw, int p_gh, const Rect2 &p_rect, const CalderaParams &p_params) {
	int n = p_gw * p_gh;
	PackedFloat32Array out;
	out.resize(n);
	float *out_ptr = out.ptrw();

	float si2 = p_params.sigma_inner * p_params.sigma_inner;
	float so2 = p_params.sigma_outer * p_params.sigma_outer;
	const float *noise_ptr = (p_params.noise.size() == n) ? p_params.noise.ptr() : nullptr;

	Pasture3DThreadPool::parallel_for_rows(p_gh, 8, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; ++iz) {
			float ny = (p_gh > 1) ? ((float)iz / (float)(p_gh - 1)) : 0.5f;
			const int row = iz * p_gw;
			for (int ix = 0; ix < p_gw; ++ix) {
				float nx = (p_gw > 1) ? ((float)ix / (float)(p_gw - 1)) : 0.5f;
				int idx = row + ix;

				float cx = nx - p_params.center.x;
				float cy = ny - p_params.center.y;
				float r = std::sqrt(cx * cx + cy * cy) - p_params.radius;

				if (noise_ptr) {
					r += p_params.noise_r_amp * (2.0f * noise_ptr[idx] - 1.0f);
				}

				float z = 0.0f;
				if (r < 0.0f) {
					z = p_params.z_bottom + std::exp(-0.5f * r * r / std::max(1e-6f, si2)) * (1.0f - p_params.z_bottom);
				} else {
					z = 1.0f / (1.0f + r * r / std::max(1e-6f, so2));
				}

				if (noise_ptr) {
					z *= 1.0f + p_params.noise_z_ratio * (2.0f * noise_ptr[idx] - 1.0f);
				}

				out_ptr[idx] = z * p_params.elevation;
			}
		}
	});

	return out;
}
