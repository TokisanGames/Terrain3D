// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_furrows.h"
#include "pasture_3d_graph_ops.h"
#include "pasture_3d_thread_pool.h"

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <algorithm>
#include <cmath>

using namespace godot;

namespace {

inline double smoothstep(double p_from, double p_to, double p_weight) {
	if (std::abs(p_from - p_to) <= 1e-7) {
		return p_from;
	}
	const double x = std::clamp((p_weight - p_from) / (p_to - p_from), 0.0, 1.0);
	return x * x * (3.0 - 2.0 * x);
}

} // namespace

PackedFloat32Array godot::furrows_grid(int p_gw, int p_gh, const Rect2 &p_rect,
		double p_amplitude, double p_spacing, double p_direction_deg,
		int p_profile, double p_wobble_amount, double p_wobble_size, int p_seed) {
	const int n = p_gw * p_gh;
	PackedFloat32Array out;
	out.resize(n);
	if (n <= 0) {
		return out;
	}

	if (std::abs(p_amplitude) <= 1e-7) {
		out.fill(0.f);
		return out;
	}

	Ref<FastNoiseLite> nz;
	nz.instantiate();
	nz->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
	nz->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
	nz->set_fractal_octaves(2);
	nz->set_fractal_gain(0.5f);
	nz->set_fractal_lacunarity(2.0f);
	nz->set_frequency((real_t)(1.0 / std::max(p_wobble_size, 0.01)));
	nz->set_seed(p_seed);

	const double dir = p_direction_deg * (Math_PI / 180.0);
	const double cos_dir = std::cos(dir);
	const double sin_dir = std::sin(dir);
	const double sp = std::max(p_spacing, 0.001);

	float *w = out.ptrw();

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			for (int ix = 0; ix < p_gw; ix++) {
				double u, v;
				graph_cell_to_world(ix, iz, p_gw, p_gh, p_rect, u, v);

				double d = u * cos_dir + v * sin_dir;
				d += (double)nz->get_noise_2d((real_t)u, (real_t)v) * p_wobble_amount;

				const double phase = (d / sp) - std::floor(d / sp);
				const double a = std::abs(phase * 2.0 - 1.0); // 0 at furrow floor, 1 at ridge

				double f = a;
				if (p_profile == FURROWS_PROFILE_U) {
					f = smoothstep(0.0, 1.0, a);
				} else if (p_profile == FURROWS_PROFILE_SQUARE) {
					f = smoothstep(0.42, 0.58, a);
				}

				w[row + ix] = (float)((f * 2.0 - 1.0) * p_amplitude);
			}
		}
	});

	return out;
}
