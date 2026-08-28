// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_geological_primitive.h"
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

inline double profile_at(int p_type, double d, double norm_x, double p_height, double p_steepness) {
	switch (p_type) {
		case GEO_PRIMITIVE_INSELBERG: {
			if (d >= 1.0) {
				return 0.0;
			}
			const double cliff_r = 0.55;
			const double cliff = 1.0 / (1.0 + std::pow(d / cliff_r, 2.5 * std::max(p_steepness, 0.2)));
			const double pediment = smoothstep(1.0, 0.75, d);
			return p_height * (cliff * pediment);
		}
		case GEO_PRIMITIVE_VOLCANIC_CALDERA: {
			if (d >= 1.0) {
				return 0.0;
			}
			const double rim_pos = 0.45;
			const double floor_ratio = 0.35;
			if (d <= rim_pos) {
				const double bt = d / rim_pos;
				const double bowl = floor_ratio + (1.0 - floor_ratio) * std::pow(std::sin(bt * Math_PI * 0.5), p_steepness);
				return p_height * bowl;
			} else {
				const double ft = (1.0 - d) / (1.0 - rim_pos);
				const double flank = std::pow(std::sin(ft * Math_PI * 0.5), p_steepness);
				return p_height * flank;
			}
		}
		case GEO_PRIMITIVE_CUESTA_BADLANDS: {
			if (d >= 1.0) {
				return 0.0;
			}
			const double envelope = std::pow(std::cos(d * Math_PI * 0.5), 0.75);
			const double scarp_factor = 0.25;
			double x_profile = 0.0;
			if (norm_x < 0.0) {
				const double st = std::clamp(-norm_x / scarp_factor, 0.0, 1.0);
				x_profile = std::pow(std::cos(st * Math_PI * 0.5), p_steepness);
			} else {
				const double dt = std::clamp(norm_x, 0.0, 1.0);
				x_profile = std::pow(std::cos(dt * Math_PI * 0.5), 0.6);
			}
			return p_height * x_profile * envelope;
		}
		default:
			return 0.0;
	}
}

} // namespace

PackedFloat32Array godot::geological_primitive_grid(int p_gw, int p_gh, const Rect2 &p_rect,
		int p_primitive_type, int p_mapping, double p_height, double p_radius,
		double p_eccentricity, double p_steepness, double p_azimuth_degrees,
		const Vector2 &p_center_offset) {
	const int n = p_gw * p_gh;
	PackedFloat32Array out;
	out.resize(n);
	if (n <= 0) {
		return out;
	}

	if (std::abs(p_height) <= 1e-7) {
		out.fill(0.f);
		return out;
	}

	float *w = out.ptrw();
	const double rad = p_azimuth_degrees * (Math_PI / 180.0);
	const double cos_a = std::cos(rad);
	const double sin_a = std::sin(rad);

	if (p_mapping == GEO_MAPPING_FIT_FRAME) {
		const double cx = (double)p_rect.position.x + (double)p_rect.size.x * 0.5 + (double)p_center_offset.x * ((double)p_rect.size.x * 0.5);
		const double cz = (double)p_rect.position.y + (double)p_rect.size.y * 0.5 + (double)p_center_offset.y * ((double)p_rect.size.y * 0.5);
		const double half_ex = std::max((double)p_rect.size.x * 0.5 * p_radius, 0.001);
		const double half_ez = std::max((double)p_rect.size.y * 0.5 * p_radius * p_eccentricity, 0.001);

		Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
			for (int iz = z0; iz < z1; iz++) {
				const int row = iz * p_gw;
				for (int ix = 0; ix < p_gw; ix++) {
					double wx, wz;
					graph_cell_to_world(ix, iz, p_gw, p_gh, p_rect, wx, wz);

					const double rx = wx - cx;
					const double rz = wz - cz;

					const double lx = rx * cos_a + rz * sin_a;
					const double lz = -rx * sin_a + rz * cos_a;

					const double norm_x = lx / half_ex;
					const double norm_z = lz / half_ez;
					const double d = std::sqrt(norm_x * norm_x + norm_z * norm_z);

					w[row + ix] = (float)profile_at(p_primitive_type, d, norm_x, p_height, p_steepness);
				}
			}
		});
	} else {
		// METRIC_WORLD mapping
		const double cx = (double)p_center_offset.x;
		const double cz = (double)p_center_offset.y;
		const double inv_r = 1.0 / std::max(p_radius, 0.001);
		const double ecc = std::max(p_eccentricity, 0.01);

		Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
			for (int iz = z0; iz < z1; iz++) {
				const int row = iz * p_gw;
				for (int ix = 0; ix < p_gw; ix++) {
					double wx, wz;
					graph_cell_to_world(ix, iz, p_gw, p_gh, p_rect, wx, wz);

					const double rx = wx - cx;
					const double rz = wz - cz;

					const double lx = rx * cos_a + rz * sin_a;
					const double lz = -rx * sin_a + rz * cos_a;

					const double norm_x = lx * inv_r;
					const double norm_z = (lz * inv_r) / ecc;
					const double d = std::sqrt(norm_x * norm_x + norm_z * norm_z);

					w[row + ix] = (float)profile_at(p_primitive_type, d, norm_x, p_height, p_steepness);
				}
			}
		});
	}

	return out;
}
