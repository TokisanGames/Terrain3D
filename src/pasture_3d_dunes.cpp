// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_dunes.h"
#include "pasture_3d_graph_ops.h"
#include "pasture_3d_thread_pool.h"

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <algorithm>
#include <cmath>

using namespace godot;

PackedFloat32Array godot::dunes_grid(int p_gw, int p_gh, const Rect2 &p_rect,
		double p_amplitude, double p_wavelength, double p_direction_deg,
		double p_asymmetry, double p_crest_sharpness, double p_wander_amount,
		double p_wander_size, int p_seed) {
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
	nz->set_frequency((real_t)(1.0 / std::max(p_wander_size, 0.01)));
	nz->set_seed(p_seed);

	const double dir = p_direction_deg * (Math_PI / 180.0);
	const double cos_dir = std::cos(dir);
	const double sin_dir = std::sin(dir);
	const double wl = std::max(p_wavelength, 0.001);
	const double a = std::clamp(p_asymmetry, 0.01, 0.99);
	const double sharpness = std::max(p_crest_sharpness, 0.01);

	float *w = out.ptrw();

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			for (int ix = 0; ix < p_gw; ix++) {
				double u, v;
				graph_cell_to_world(ix, iz, p_gw, p_gh, p_rect, u, v);

				double d = u * cos_dir + v * sin_dir;
				d += (double)nz->get_noise_2d((real_t)u, (real_t)v) * p_wander_amount;

				const double phase = (d / wl) - std::floor(d / wl);
				const double t = (phase < a) ? (phase / a) : (1.0 - (phase - a) / (1.0 - a));
				const double clamped_t = std::clamp(t, 0.0, 1.0);
				const double val = (std::pow(clamped_t, sharpness) * 2.0 - 1.0) * p_amplitude;

				w[row + ix] = (float)val;
			}
		}
	});

	return out;
}
