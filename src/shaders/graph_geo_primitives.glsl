// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// GLSL Compute Shader for the Geological Primitives (MountainCone, MountainInselberg, MountainRangeRadial,
// MountainTibesti, MountainStump, ShatteredPeak, Caldera) — the GPU port of pasture_3d_geo_primitives.cpp.
//
// These primitives are embarrassingly parallel pure per-cell functions (no inter-cell dependency), so one
// dispatch over the gw*gh grid computes the whole field. The shared noise kernels (hash22, simplex2,
// voronoi, gabor) are 1:1 ports of the CPU/Hesiod kernels; `op` selects which primitive to assemble. The
// octave counts arrive ALREADY Nyquist-capped from the host (identical to the CPU _best path), so the GPU
// and CPU results agree to GPU-float tolerance (~1e-3, verified by GeoGpuParityGate), not the 1e-5
// bit-parity the CPU-vs-oracle gate holds.

R"(#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict writeonly buffer OutBuf { float o_out[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer Out2Buf { float o_out2[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer ABuf { float in_a[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer BBuf { float in_b[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer CBuf { float in_c[]; };

// One params block covering every primitive; each op reads the subset it needs. Kept as a readonly SSBO
// (not a push constant) so the union stays well under no size limit as more fields are added.
layout(set = 0, binding = 5, std430) restrict readonly buffer ParamBuf {
	int op;         // GEO_OP_* selector (matches the host enum)
	int gw;
	int gh;
	int octaves;    // primary, Nyquist-capped on host
	uint seed_u;    // already wang-hashed on host
	int flags;      // bit0 = has A (dx/ctrl), bit1 = has B (dy), bit2 = has C (env/noise)
	int octaves2;   // secondary cap (Tibesti kw_noise4)
	int octaves3;   // tertiary cap (Tibesti kw_noise2)

	float elevation;
	float scale;
	float kw;       // primary wavenumber (host-precomputed, e.g. peak_kw/scale)
	float kw2;      // secondary (kw_y, kw_noise4, ...)
	float kw3;      // tertiary (kw_noise2, ...)
	float cos_alpha;
	float sin_alpha;
	float gamma;

	float persistence;
	float lacunarity;
	float base_noise_amp;
	float cone_alpha;
	float ridge_amp;
	float bulk_amp;
	float half_width;
	float k_smoothing;

	float angle_spread_ratio;
	float core_size_ratio;
	float weight;
	float radius;
	float sigma_inner;
	float sigma_outer;
	float z_bottom;
	float noise_r_amp;

	float noise_z_ratio;
	float center_x;
	float center_y;
	float pad0;
} p;

const float TAU = 6.2831853;

// ---- Shared deterministic kernels (1:1 with pasture_3d_geo_primitives.cpp) ---------------------------

void hash22(int ix, int iy, uint seed, out float ox, out float oy) {
	uint ux = uint(ix) * 0x8da6b343u;
	uint uy = uint(iy) * 0xd8163841u;
	uint h1 = ux ^ uy ^ seed;
	h1 ^= h1 >> 13u;
	h1 *= 0x85ebca6bu;
	h1 ^= h1 >> 16u;
	ox = float(h1 & 0xFFFFFFu) / 16777216.0;

	uint h2 = (ux ^ 0x5bd1e995u) ^ uy ^ (seed + 1013904223u);
	h2 ^= h2 >> 13u;
	h2 *= 0x85ebca6bu;
	h2 ^= h2 >> 16u;
	oy = float(h2 & 0xFFFFFFu) / 16777216.0;
}

float simplex2_raw(float xin, float yin, uint seed) {
	float F2 = 0.5 * (sqrt(3.0) - 1.0);
	float G2 = (3.0 - sqrt(3.0)) / 6.0;

	float s = (xin + yin) * F2;
	int i = int(floor(xin + s));
	int j = int(floor(yin + s));
	float t = float(i + j) * G2;
	float X0 = float(i) - t;
	float Y0 = float(j) - t;
	float x0 = xin - X0;
	float y0 = yin - Y0;

	int i1 = x0 > y0 ? 1 : 0;
	int j1 = x0 > y0 ? 0 : 1;

	float x1 = x0 - float(i1) + G2;
	float y1 = y0 - float(j1) + G2;
	float x2 = x0 - 1.0 + 2.0 * G2;
	float y2 = y0 - 1.0 + 2.0 * G2;

	float n0 = 0.0;
	float n1 = 0.0;
	float n2 = 0.0;
	float hx;
	float hy;

	float t0 = 0.5 - x0 * x0 - y0 * y0;
	if (t0 > 0.0) {
		t0 *= t0;
		hash22(i, j, seed, hx, hy);
		float h = hx * TAU;
		n0 = t0 * t0 * (cos(h) * x0 + sin(h) * y0);
	}

	float t1 = 0.5 - x1 * x1 - y1 * y1;
	if (t1 > 0.0) {
		t1 *= t1;
		hash22(i + i1, j + j1, seed, hx, hy);
		float h = hx * TAU;
		n1 = t1 * t1 * (cos(h) * x1 + sin(h) * y1);
	}

	float t2 = 0.5 - x2 * x2 - y2 * y2;
	if (t2 > 0.0) {
		t2 *= t2;
		hash22(i + 1, j + 1, seed, hx, hy);
		float h = hx * TAU;
		n2 = t2 * t2 * (cos(h) * x2 + sin(h) * y2);
	}

	return 70.0 * (n0 + n1 + n2);
}

float simplex2_fbm(float x, float y, int octaves, float persistence, float lacunarity, uint seed) {
	float total = 0.0;
	float amp = 1.0;
	float freq = 1.0;
	float max_amp = 0.0;
	for (int o = 0; o < octaves; ++o) {
		total += amp * simplex2_raw(x * freq, y * freq, seed + uint(o) * 7919u);
		max_amp += amp;
		amp *= persistence;
		freq *= lacunarity;
	}
	return max_amp > 0.0 ? (total / max_amp) : 0.0;
}

float voronoi_edge_distance_raw(float x, float y, uint seed) {
	float px = floor(x);
	float py = floor(y);
	float fx = x - px;
	float fy = y - py;

	int ipx = int(px);
	int ipy = int(py);

	int mbx = 0;
	int mby = 0;
	float mr_x = 0.0;
	float mr_y = 0.0;
	float md = 8.0;
	float hx;
	float hy;

	for (int j = -1; j <= 1; ++j) {
		for (int i = -1; i <= 1; ++i) {
			float bx = float(i);
			float by = float(j);
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

	float res = 8.0;
	for (int j = -2; j <= 2; ++j) {
		for (int i = -2; i <= 2; ++i) {
			float bx = float(mbx + i);
			float by = float(mby + j);
			hash22(ipx + mbx + i, ipy + mby + j, seed, hx, hy);
			float rx = bx - fx + hx;
			float ry = by - fy + hy;

			float diff_x = rx - mr_x;
			float diff_y = ry - mr_y;
			if (diff_x * diff_x + diff_y * diff_y > 1e-6) {
				float mid_x = 0.5 * (mr_x + rx);
				float mid_y = 0.5 * (mr_y + ry);
				float norm = sqrt(diff_x * diff_x + diff_y * diff_y);
				float dir_x = (rx - mr_x) / norm;
				float dir_y = (ry - mr_y) / norm;
				float d = mid_x * dir_x + mid_y * dir_y;
				res = min(res, d);
			}
		}
	}

	return max(0.0, res);
}

float voronoi_edge_fbm(float x, float y, int octaves, float persistence, float lacunarity, uint seed) {
	float total = 0.0;
	float amp = 1.0;
	float freq = 1.0;
	float max_amp = 0.0;
	for (int o = 0; o < octaves; ++o) {
		total += amp * voronoi_edge_distance_raw(x * freq, y * freq, seed + uint(o) * 6271u);
		max_amp += amp;
		amp *= persistence;
		freq *= lacunarity;
	}
	return max_amp > 0.0 ? (total / max_amp) : 0.0;
}

// ---- Primitive assemblies ---------------------------------------------------------------------------

void main() {
	int ix = int(gl_GlobalInvocationID.x);
	int iz = int(gl_GlobalInvocationID.y);
	if (ix >= p.gw || iz >= p.gh) {
		return;
	}
	int idx = iz * p.gw + ix;

	float nx = (p.gw > 1) ? (float(ix) / float(p.gw - 1)) : 0.5;
	float ny = (p.gh > 1) ? (float(iz) / float(p.gh - 1)) : 0.5;

	bool has_a = (p.flags & 1) != 0;
	bool has_b = (p.flags & 2) != 0;
	bool has_c = (p.flags & 4) != 0;

	if (p.op == 0) { // MountainCone
		float half_radius = 0.5 * p.scale;

		float base_n = p.scale * p.base_noise_amp * simplex2_fbm(nx * p.kw, ny * p.kw, p.octaves, p.persistence, p.lacunarity, p.seed_u);
		float disp_x = base_n * p.cos_alpha + (has_a ? in_a[idx] : 0.0);
		float disp_y = base_n * p.sin_alpha + (has_b ? in_b[idx] : 0.0);

		float cx = nx + disp_x * 0.2 - p.center_x;
		float cy = ny + disp_y * 0.2 - p.center_y;
		float dist = sqrt(cx * cx + cy * cy) / max(1.0e-5, half_radius);

		float cone = 0.0;
		if (dist < 1.0) {
			float r_pow = pow(dist, p.cone_alpha);
			float raw_cone = (1.0 - r_pow) / (1.0 + r_pow);
			float tt = clamp(raw_cone, 0.0, 1.0);
			cone = tt * tt * (3.0 - 2.0 * tt);
		}

		// An unwired envelope reads 1.0 (fully open), matching input_unwired_default / the CPU _best path.
		float env = has_c ? in_c[idx] : 1.0;
		cone *= env;

		float vx = (nx + disp_x) * p.kw;
		float vy = (ny + disp_y) * p.kw;
		float vor = 2.0 * voronoi_edge_fbm(vx, vy, p.octaves, p.persistence, p.lacunarity, p.seed_u);
		vor = max(0.0, vor);

		if (p.gamma > 0.0) {
			vor = pow(vor, p.gamma);
		}

		float val = cone * (p.ridge_amp * vor + 1.0) / (p.ridge_amp + 1.0);
		o_out[idx] = val * p.elevation;
		o_out2[idx] = 0.0;
		return;
	}

	o_out[idx] = 0.0;
	o_out2[idx] = 0.0;
}
)"
