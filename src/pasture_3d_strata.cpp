// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_strata.h"
#include "pasture_3d_graph_ops.h"
#include "pasture_3d_thread_pool.h"

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <algorithm>
#include <cmath>

using namespace godot;

PackedFloat32Array godot::strata_grid(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_band_height, double p_hardness,
		double p_amount, double p_dip, double p_dip_direction_deg,
		double p_break_amount, double p_break_size, int p_seed) {
	const int n = p_gw * p_gh;
	PackedFloat32Array out;
	out.resize(n);
	if (n <= 0 || p_surface.size() != n) {
		return out;
	}

	if (std::abs(p_amount) <= 1e-7) {
		return p_surface.duplicate();
	}

	Ref<FastNoiseLite> nz;
	if (p_break_amount > 0.0) {
		nz.instantiate();
		nz->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
		nz->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
		nz->set_fractal_octaves(3);
		nz->set_frequency((real_t)(1.0 / std::max(p_break_size, 0.01)));
		nz->set_seed(p_seed);
	}

	const float *s_ptr = p_surface.ptr();
	float *w = out.ptrw();

	const double dipdir = p_dip_direction_deg * (Math_PI / 180.0);
	const double cos_dip = std::cos(dipdir);
	const double sin_dip = std::sin(dipdir);
	const double bh = std::max(p_band_height, 0.001);
	const double exponent = 1.0 + std::clamp(p_hardness, 0.0, 1.0) * 15.0;

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			for (int ix = 0; ix < p_gw; ix++) {
				const int i = row + ix;
				const float x = s_ptr[i];
				if (std::isnan(x)) {
					w[i] = NAN;
					continue;
				}

				double wx, wz;
				graph_cell_to_world(ix, iz, p_gw, p_gh, p_rect, wx, wz);

				double tilt = p_dip * (wx * cos_dip + wz * sin_dip) * 0.01;
				if (p_break_amount > 0.0 && nz.is_valid()) {
					tilt += (double)nz->get_noise_2d((real_t)wx, (real_t)wz) * p_break_amount;
				}

				const double xj = (double)x + tilt;
				const double t = xj / bh;
				const double q = std::floor(t);
				const double f = t - q;

				const double profile_val = std::pow(std::clamp(f, 0.0, 1.0), exponent);
				const double stepped = (q + profile_val) * bh;

				w[i] = (float)((double)x + ((stepped - (double)x) * p_amount));
			}
		}
	});

	return out;
}
