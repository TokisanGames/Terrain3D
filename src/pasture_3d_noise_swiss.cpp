// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_noise_swiss.h"
#include "pasture_3d_graph_ops.h"
#include "pasture_3d_thread_pool.h"

#include <algorithm>
#include <cmath>

using namespace godot;

PackedFloat32Array godot::noise_swiss_grid(int p_gw, int p_gh, const Rect2 &p_rect,
		double p_amplitude, double p_frequency, int p_octaves,
		double p_gain, double p_lacunarity, double p_ridge_offset,
		double p_erosion_accent, int p_seed) {
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

				float total_h = 0.0f;
				float cur_amp = 1.0f;
				float cur_freq = (float)p_frequency;
				Vector2 sum_deriv = Vector2(0.0f, 0.0f);
				float max_amp = 0.0f;

				for (int i = 0; i < p_octaves; i++) {
					const Vector2 sample_pos = Vector2((float)wx, (float)wz) * cur_freq + sum_deriv * (float)p_erosion_accent;

					const float raw_n = nz->get_noise_2d(sample_pos.x, sample_pos.y);

					const float n_dx = (nz->get_noise_2d(sample_pos.x + 0.2f, sample_pos.y) -
							nz->get_noise_2d(sample_pos.x - 0.2f, sample_pos.y)) / 0.4f;
					const float n_dz = (nz->get_noise_2d(sample_pos.x, sample_pos.y + 0.2f) -
							nz->get_noise_2d(sample_pos.x, sample_pos.y - 0.2f)) / 0.4f;
					const Vector2 grad = Vector2(n_dx, n_dz);

					const float ridge_term = std::max(0.0f, (float)p_ridge_offset - std::abs(raw_n));
					const float ridge_val = ridge_term * ridge_term;

					const float modulation = std::clamp(1.0f - (float)p_erosion_accent * sum_deriv.length(), 0.05f, 1.0f);

					total_h += cur_amp * ridge_val * modulation;

					const float sign_raw = (raw_n > 0.0f) ? 1.0f : ((raw_n < 0.0f) ? -1.0f : 0.0f);
					sum_deriv += grad * cur_amp * (-2.0f * ridge_term * sign_raw) * modulation;

					max_amp += cur_amp * ((float)p_ridge_offset * (float)p_ridge_offset);

					cur_amp *= (float)p_gain;
					cur_freq *= (float)p_lacunarity;
				}

				const float normalized = (total_h / std::max(max_amp, 0.0001f)) * 2.0f - 1.0f;
				w[row + ix] = normalized * (float)p_amplitude;
			}
		}
	});

	return out;
}
