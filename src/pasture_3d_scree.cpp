// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_scree.h"
#include "pasture_3d_graph_ops.h"
#include "pasture_3d_thread_pool.h"

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <algorithm>
#include <cmath>

using namespace godot;

namespace {

constexpr double SCREE_TOE_FULL_M = 0.25;

inline double smoothstep(double p_from, double p_to, double p_weight) {
	if (std::abs(p_from - p_to) <= 1e-7) {
		return p_from;
	}
	const double x = std::clamp((p_weight - p_from) / (p_to - p_from), 0.0, 1.0);
	return x * x * (3.0 - 2.0 * x);
}

inline double finite_or(float val, float fallback) {
	return std::isnan(val) ? fallback : val;
}

inline double slope_gate(double p_slope_deg, double p_min_slope, double p_falloff) {
	if (p_slope_deg >= p_min_slope) {
		return 1.0;
	}
	if (p_falloff <= 0.0 || p_slope_deg <= p_min_slope - p_falloff) {
		return 0.0;
	}
	return smoothstep(p_min_slope - p_falloff, p_min_slope, p_slope_deg);
}

} // namespace

Array godot::scree_solve_grid(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_amplitude, double p_grain_size,
		double p_downslope_streak, double p_toe_deposition, double p_min_slope_deg,
		double p_slope_falloff_deg, int p_seed) {
	const int n = p_gw * p_gh;
	PackedFloat32Array height;
	height.resize(n);
	PackedFloat32Array shed;
	shed.resize(n);

	Array res;
	if (n <= 0 || p_surface.size() != n) {
		res.append(height);
		res.append(shed);
		return res;
	}

	Ref<FastNoiseLite> nz;
	nz.instantiate();
	nz->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
	nz->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
	nz->set_fractal_octaves(3);
	nz->set_fractal_gain(0.5f);
	nz->set_fractal_lacunarity(2.0f);
	nz->set_frequency((real_t)(1.0 / std::max(p_grain_size, 0.01)));
	nz->set_seed(p_seed);

	const float *s_ptr = p_surface.ptr();
	float *h_ptr = height.ptrw();
	float *m_ptr = shed.ptrw();

	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
	const double rad_to_deg_c = 180.0 / Math_PI;

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			const int zm = std::max(iz - 1, 0) * p_gw;
			const int zp = std::min(iz + 1, p_gh - 1) * p_gw;

			for (int ix = 0; ix < p_gw; ix++) {
				const int i = row + ix;
				const float c = s_ptr[i];
				if (std::isnan(c)) {
					h_ptr[i] = NAN;
					m_ptr[i] = 0.0f;
					continue;
				}

				const int xm = std::max(ix - 1, 0);
				const int xp = std::min(ix + 1, p_gw - 1);

				const double hxm = finite_or(s_ptr[row + xm], c);
				const double hxp = finite_or(s_ptr[row + xp], c);
				const double hzm = finite_or(s_ptr[zm + ix], c);
				const double hzp = finite_or(s_ptr[zp + ix], c);

				const double gx = (hxp - hxm) / (2.0 * dx);
				const double gz = (hzp - hzm) / (2.0 * dz);
				const double glen = std::sqrt(gx * gx + gz * gz);
				const double slope_deg = std::atan(glen) * rad_to_deg_c;
				const double curv = (hxm + hxp + hzm + hzp) * 0.25 - (double)c;
				const double gate = slope_gate(slope_deg, p_min_slope_deg, p_slope_falloff_deg);

				const double wx = (double)p_rect.position.x + ((double)ix + 0.5) * dx;
				const double wz = (double)p_rect.position.y + ((double)iz + 0.5) * dz;

				double su = wx;
				double sv = wz;
				if (glen > 1.0e-6) {
					su = wx - (gx / glen) * p_downslope_streak;
					sv = wz - (gz / glen) * p_downslope_streak;
				}

				double val = (double)nz->get_noise_2d((real_t)su, (real_t)sv) * p_amplitude;
				if (p_toe_deposition != 0.0) {
					val += p_toe_deposition * std::clamp(curv / SCREE_TOE_FULL_M, 0.0, 1.0);
				}

				h_ptr[i] = (float)(gate * val);
				m_ptr[i] = (float)gate;
			}
		}
	});

	res.append(height);
	res.append(shed);
	return res;
}
