// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_gavoronoise.h"
#include "pasture_3d_graph_ops.h"
#include "pasture_3d_thread_pool.h"

#include <algorithm>
#include <cmath>
#include <cstdint>

using namespace godot;

namespace {

// A uint32 multiply-xor-shift hash. Integer, deliberately: see the header. Every constant here is a
// well-known avalanche constant, and the exact values matter only in that all three implementations use
// the same ones.
inline uint32_t hash_u32(uint32_t x) {
	x ^= x >> 16;
	x *= 0x7feb352du;
	x ^= x >> 15;
	x *= 0x846ca68bu;
	x ^= x >> 16;
	return x;
}

inline uint32_t hash_cell(int32_t p_cx, int32_t p_cz, int32_t p_seed, uint32_t p_salt) {
	uint32_t h = hash_u32((uint32_t)p_cx * 0x9e3779b1u);
	h = hash_u32(h ^ ((uint32_t)p_cz * 0x85ebca6bu));
	h = hash_u32(h ^ (uint32_t)p_seed);
	return hash_u32(h ^ p_salt);
}

// 24 bits into [0,1). 24 is the float mantissa, so this conversion is exact on the GPU too.
inline double rnd01(uint32_t p_h) {
	return (double)(p_h & 0x00ffffffu) / 16777216.0;
}

} // namespace

PackedFloat32Array godot::gavoronoise_grid(int p_gw, int p_gh, const Rect2 &p_rect, double p_amplitude,
		double p_frequency, int p_octaves, int p_seed, double p_angle_deg, double p_angle_spread,
		double p_slope_strength, double p_branch_strength, double p_z_cut_min, double p_z_cut_max) {
	const int n = p_gw * p_gh;
	PackedFloat32Array out;
	if (p_gw <= 0 || p_gh <= 0) {
		return out;
	}
	out.resize(n);
	if (std::abs(p_amplitude) <= 1e-7 || p_octaves <= 0 || p_frequency <= 0.0) {
		out.fill(0.f);
		return out;
	}

	const double kPi = 3.14159265358979323846;
	const double theta = p_angle_deg * kPi / 180.0;
	const double cs = std::cos(theta);
	const double sn = std::sin(theta);
	// Never exactly 0: at 0 the along-strike coordinate would collapse to a single Voronoi column for any
	// rect, and the ridge SPACING would stop being a function of `frequency` at all.
	const double aniso = std::max(std::clamp(p_angle_spread, 0.0, 1.0), 0.02);
	// A fixed lacunarity and gain. They are not exposed: this node's character comes from the derivative
	// feedback, and two more octave knobs would let a user dial that character away without noticing.
	const double lacunarity = 2.0;
	const double gain = 0.5;

	float *w = out.ptrw();

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			for (int ix = 0; ix < p_gw; ix++) {
				double wx, wz;
				graph_cell_to_world(ix, iz, p_gw, p_gh, p_rect, wx, wz);

				// Into the STRIKE frame: rotate world metres so +x runs along the tectonic strike. Doing
				// it once, outside the octave loop, is what keeps every octave's ridges parallel to the
				// same direction instead of each finding its own.
				const double sx = wx * cs + wz * sn;
				const double sz = -wx * sn + wz * cs;

				double total = 0.0;
				double max_amp = 0.0;
				double amp = 1.0;
				double freq = p_frequency;
				double grad_x = 0.0;
				double grad_z = 0.0;

				for (int o = 0; o < p_octaves; o++) {
					// The feedback: previous octaves' accumulated slope displaces where this octave is
					// sampled. That displacement along the slope is what bends cell walls into branches.
					// The along-strike axis is COMPRESSED by `aniso`, which is what elongates the cells
					// into strike-parallel ribbons. See the header.
					const double qx = (sx * freq + grad_x * p_branch_strength) * aniso;
					const double qz = sz * freq + grad_z * p_branch_strength;

					const int32_t bx = (int32_t)std::floor(qx);
					const int32_t bz = (int32_t)std::floor(qz);

					double best = 1.0e30;
					double best_dx = 0.0;
					double best_dz = 0.0;
					for (int oz = -1; oz <= 1; oz++) {
						for (int ox = -1; ox <= 1; ox++) {
							const int32_t cx = bx + ox;
							const int32_t cz = bz + oz;
							const uint32_t h0 = hash_cell(cx, cz, p_seed + o * 7919, 0x1u);
							const uint32_t h1 = hash_cell(cx, cz, p_seed + o * 7919, 0x2u);
							// Both coordinates are free. The strike alignment comes from the compressed
							// `qx` above, not from where the feature point sits inside its cell.
							const double fx = (double)cx + rnd01(h0);
							const double fz = (double)cz + rnd01(h1);
							const double dx = qx - fx;
							const double dz = qz - fz;
							const double d2 = dx * dx + dz * dz;
							if (d2 < best) {
								best = d2;
								best_dx = dx;
								best_dz = dz;
							}
						}
					}

					const double dist = std::sqrt(best);
					// Ridged: 1 at a cell wall is wrong, 1 AT the feature point is what gives peaks with
					// valleys between them, so the field is 1 - distance clamped into [0,1].
					const double v = std::clamp(1.0 - dist, 0.0, 1.0);

					// The analytic derivative of `dist` is the unit vector from the winning feature point
					// to the sample; v = 1 - dist negates it. Zero distance has no direction, so it
					// contributes no gradient rather than a NaN.
					double gx = 0.0;
					double gz = 0.0;
					if (dist > 1e-12 && v > 0.0) {
						gx = -best_dx / dist;
						gz = -best_dz / dist;
					}

					// Damping: once the accumulated slope is steep, further octaves are attenuated. This
					// is what stops the feedback running away and turning the field into noise.
					const double gl2 = grad_x * grad_x + grad_z * grad_z;
					const double damp = 1.0 / (1.0 + p_slope_strength * gl2);

					total += amp * v * damp;
					grad_x += gx * amp * damp;
					grad_z += gz * amp * damp;
					max_amp += amp;

					amp *= gain;
					freq *= lacunarity;
				}

				double t = total / std::max(max_amp, 1e-4); // normalised to roughly [0,1]

				// The z-cut window, applied BEFORE the amplitude scale so the two knobs stay independent:
				// widening the window must not also change how tall the result is.
				const double lo = p_z_cut_min;
				const double hi = p_z_cut_max;
				t = (hi - lo > 1e-9) ? std::clamp((t - lo) / (hi - lo), 0.0, 1.0)
									 : ((t >= hi) ? 1.0 : 0.0);

				w[row + ix] = (float)(t * p_amplitude);
			}
		}
	});

	return out;
}
