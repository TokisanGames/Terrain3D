// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_noise_jordan.h"
#include "pasture_3d_graph_ops.h"
#include "pasture_3d_thread_pool.h"

#include <algorithm>
#include <cmath>

using namespace godot;

PackedFloat32Array godot::noise_jordan_grid(int p_gw, int p_gh, const Rect2 &p_rect,
		double p_amplitude, double p_frequency, int p_octaves,
		double p_gain, double p_lacunarity, double p_warp_strength,
		double p_damp_strength, int p_seed) {
	const int n = p_gw * p_gh;
	PackedFloat32Array out;
	out.resize(n);
	if (n <= 0) {
		return out;
	}

	if (std::abs(p_amplitude) <= 1e-7 || p_octaves <= 0) {
		out.fill(0.f);
		return out;
	}

	Ref<FastNoiseLite> nz;
	nz.instantiate();
	nz->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
	nz->set_fractal_type(FastNoiseLite::FRACTAL_NONE);
	nz->set_frequency(1.0f);
	nz->set_seed(p_seed);

	const double eps = 0.2;
	float *w = out.ptrw();

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			for (int ix = 0; ix < p_gw; ix++) {
				double wx, wz;
				graph_cell_to_world(ix, iz, p_gw, p_gh, p_rect, wx, wz);

				double total_h = 0.0;
				double cur_amp = 1.0;
				double cur_freq = p_frequency;
				double sum_grad_x = 0.0;
				double sum_grad_z = 0.0;
				double max_amp = 0.0;

				for (int i = 0; i < p_octaves; i++) {
					const double sample_x = wx * cur_freq + sum_grad_x * p_warp_strength;
					const double sample_z = wz * cur_freq + sum_grad_z * p_warp_strength;

					const double n_val = (double)nz->get_noise_2d((real_t)sample_x, (real_t)sample_z);

					const double n_dx = ((double)nz->get_noise_2d((real_t)(sample_x + eps), (real_t)sample_z) -
							(double)nz->get_noise_2d((real_t)(sample_x - eps), (real_t)sample_z)) / (2.0 * eps);
					const double n_dz = ((double)nz->get_noise_2d((real_t)sample_x, (real_t)(sample_z + eps)) -
							(double)nz->get_noise_2d((real_t)sample_x, (real_t)(sample_z - eps))) / (2.0 * eps);

					const double grad_len_sq = sum_grad_x * sum_grad_x + sum_grad_z * sum_grad_z;
					const double damp = 1.0 / (1.0 + p_damp_strength * grad_len_sq);

					total_h += cur_amp * n_val * damp;
					sum_grad_x += n_dx * cur_amp * damp;
					sum_grad_z += n_dz * cur_amp * damp;
					max_amp += cur_amp;

					cur_amp *= p_gain;
					cur_freq *= p_lacunarity;
				}

				const double normalized = total_h / std::max(max_amp, 0.0001);
				w[row + ix] = (float)(normalized * p_amplitude);
			}
		}
	});

	return out;
}
