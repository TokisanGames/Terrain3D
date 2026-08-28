// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_crater.h"
#include "pasture_3d_graph_ops.h"
#include "pasture_3d_thread_pool.h"

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

inline double rim_scale(double nu, double nv, double r, double inv_ex, double inv_ez) {
	if (r <= 1.0e-9) {
		return 1.0;
	}
	const double ex = 2.0 / inv_ex;
	const double ez = 2.0 / inv_ez;
	const double cu = (nu / r) * ex;
	const double cv = (nv / r) * ez;
	const double l = std::sqrt(cu * cu + cv * cv);
	return std::min(ex, ez) / std::max(l, 1.0e-9);
}

} // namespace

PackedFloat32Array godot::crater_grid(int p_gw, int p_gh, const Rect2 &p_rect,
		double p_amplitude, double p_floor_depth, double p_rim_height,
		double p_rim_width, double p_ejecta_falloff, double p_floor_flatness,
		int p_terrace_steps) {
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

	const double cx = (double)p_rect.position.x + (double)p_rect.size.x * 0.5;
	const double cz = (double)p_rect.position.y + (double)p_rect.size.y * 0.5;
	const double inv_ex = 2.0 / std::max((double)p_rect.size.x, 1.0e-9);
	const double inv_ez = 2.0 / std::max((double)p_rect.size.y, 1.0e-9);
	const double falloff = std::max(p_ejecta_falloff, 0.01);

	float *w = out.ptrw();

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			for (int ix = 0; ix < p_gw; ix++) {
				double wx, wz;
				graph_cell_to_world(ix, iz, p_gw, p_gh, p_rect, wx, wz);

				const double nu = (wx - cx) * inv_ex;
				const double nv = (wz - cz) * inv_ez;
				const double r = std::sqrt(nu * nu + nv * nv);

				if (r >= 1.0) {
					w[row + ix] = 0.0f;
					continue;
				}

				const double rim_pos = std::clamp(1.0 - p_rim_width * rim_scale(nu, nv, r, inv_ex, inv_ez), 0.05, 0.98);
				double val = 0.0;

				if (r <= rim_pos) {
					const double t = r / rim_pos;
					val = -p_floor_depth * (1.0 - std::pow(t, 2.0 + 6.0 * p_floor_flatness));
					if (p_terrace_steps >= 1) {
						val = std::floor(val * p_terrace_steps) / (double)p_terrace_steps;
					}
					val += p_rim_height * smoothstep(0.7, 1.0, t);
				} else {
					const double s = (r - rim_pos) / (1.0 - rim_pos);
					val = p_rim_height * std::pow(1.0 - s, falloff);
				}

				w[row + ix] = (float)(val * p_amplitude);
			}
		}
	});

	return out;
}
