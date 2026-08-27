// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_warp.h"
#include "pasture_3d_graph_ops.h"

#include <cmath>
#include <limits>
#include <vector>

using namespace godot;

PackedFloat32Array godot::warp_solve_grid(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, WarpNoiseType p_type, double p_frequency, double p_strength,
		int p_octaves, double p_amplitude, double p_roughness, int p_seed) {
	const int n = p_gw * p_gh;
	PackedFloat32Array result;
	result.resize(n);
	if (n <= 0) {
		return result;
	}

	const float *src = (p_surface.size() == n) ? p_surface.ptr() : nullptr;

	Ref<FastNoiseLite> noise_x;
	noise_x.instantiate();
	noise_x->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
	noise_x->set_fractal_type(p_type == WarpNoiseType::FRACTAL ? FastNoiseLite::FRACTAL_FBM : FastNoiseLite::FRACTAL_NONE);
	noise_x->set_fractal_octaves(p_octaves);
	noise_x->set_fractal_gain((real_t)p_roughness);
	noise_x->set_frequency((real_t)p_frequency);
	noise_x->set_seed(p_seed);

	Ref<FastNoiseLite> noise_z;
	noise_z.instantiate();
	noise_z->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
	noise_z->set_fractal_type(p_type == WarpNoiseType::FRACTAL ? FastNoiseLite::FRACTAL_FBM : FastNoiseLite::FRACTAL_NONE);
	noise_z->set_fractal_octaves(p_octaves);
	noise_z->set_fractal_gain((real_t)p_roughness);
	noise_z->set_frequency((real_t)p_frequency);
	noise_z->set_seed(p_seed + 1013904223);

	Ref<FastNoiseLite> noise_out;
	noise_out.instantiate();
	noise_out->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
	noise_out->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
	noise_out->set_fractal_octaves(p_octaves);
	noise_out->set_fractal_gain((real_t)p_roughness);
	noise_out->set_frequency((real_t)p_frequency);
	noise_out->set_seed(p_seed + 2147483647);

	float *dst = result.ptrw();

	for (int iz = 0; iz < p_gh; iz++) {
		const int row = iz * p_gw;
		for (int ix = 0; ix < p_gw; ix++) {
			const int i = row + ix;
			const float base_in = src ? src[i] : 0.0f;
			if (std::isnan(base_in)) {
				dst[i] = std::numeric_limits<float>::quiet_NaN();
				continue;
			}

			double wx = 0.0;
			double wz = 0.0;
			graph_cell_to_world(ix, iz, p_gw, p_gh, p_rect, wx, wz);

			double dx = 0.0;
			double dz = 0.0;
			if (p_strength > 0.0) {
				dx = (double)noise_x->get_noise_2d((real_t)wx, (real_t)wz) * p_strength;
				dz = (double)noise_z->get_noise_2d((real_t)wx, (real_t)wz) * p_strength;
			}

			const double warped_x = wx + dx;
			const double warped_z = wz + dz;

			const double sample = (double)noise_out->get_noise_2d((real_t)warped_x, (real_t)warped_z);
			const double generated_h = sample * p_amplitude;

			dst[i] = (float)((double)base_in + generated_h);
		}
	}

	return result;
}
