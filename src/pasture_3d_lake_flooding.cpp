// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_lake_flooding.h"
#include "pasture_3d_depression_filling.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

using namespace godot;

Dictionary LakeFloodingResult::to_dict() const {
	Dictionary d;
	d["ok"] = ok;
	d["height"] = height;
	d["water_depth"] = water_depth;
	d["shoreline"] = shoreline;
	d["contours"] = contours;
	return d;
}

LakeFloodingResult godot::lake_flooding_solve(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, LakeFloodMode p_mode, double p_water_elevation,
		double p_flood_percent, double p_shoreline_width) {
	LakeFloodingResult res;
	if (p_gw < 1 || p_gh < 1) {
		return res;
	}
	const int n = p_gw * p_gh;
	if (p_surface.size() != n) {
		return res;
	}

	const float *src_ptr = p_surface.ptr();

	res.height.resize(n);
	res.water_depth.resize(n);
	res.shoreline.resize(n);

	float *out_h = res.height.ptrw();
	float *out_depth = res.water_depth.ptrw();
	float *out_shore = res.shoreline.ptrw();

	const double dx = (p_rect.size.x > 0.0 && p_gw > 1) ? ((double)p_rect.size.x / std::max((double)(p_gw - 1), 1.0)) : 2.0;
	const double dz = (p_rect.size.y > 0.0 && p_gh > 1) ? ((double)p_rect.size.y / std::max((double)(p_gh - 1), 1.0)) : 2.0;

	std::vector<double> water_grid(n);

	if (p_mode == LakeFloodMode::GLOBAL_ELEVATION) {
		for (int i = 0; i < n; i++) {
			const float zh = src_ptr[i];
			water_grid[i] = std::isfinite(zh) ? std::max((double)zh, p_water_elevation) : std::numeric_limits<double>::quiet_NaN();
		}
	} else {
		// SPILLWAY_BASIN mode
		PackedFloat32Array filled = priority_flood_fill(p_surface, p_gw, p_gh, dx, dz, 0.0, 0.0);
		const float *fld_ptr = filled.ptr();

		for (int i = 0; i < n; i++) {
			const float raw_z = src_ptr[i];
			const float spill_z = fld_ptr[i];
			if (std::isfinite(raw_z) && std::isfinite(spill_z)) {
				const double max_depth = std::max((double)spill_z - (double)raw_z, 0.0);
				water_grid[i] = (double)raw_z + max_depth * p_flood_percent;
			} else {
				water_grid[i] = (double)raw_z;
			}
		}
	}

	const double width = std::max(p_shoreline_width, 0.1);

	for (int i = 0; i < n; i++) {
		const float raw_z = src_ptr[i];
		const double wz = water_grid[i];
		if (!std::isfinite(raw_z) || !std::isfinite(wz)) {
			out_h[i] = std::numeric_limits<float>::quiet_NaN();
			out_depth[i] = 0.0f;
			out_shore[i] = 0.0f;
			continue;
		}

		const double depth = std::max(wz - (double)raw_z, 0.0);
		out_h[i] = (float)wz;
		out_depth[i] = (float)depth;
		out_shore[i] = (float)std::clamp(depth / width, 0.0, 1.0);
	}

	// Boundary contour polygon extraction
	PackedVector2Array boundary_pts;
	for (int iz = 1; iz < p_gh - 1; iz++) {
		for (int ix = 1; ix < p_gw - 1; ix++) {
			const int idx = iz * p_gw + ix;
			if (out_depth[idx] > 0.05f) {
				const bool is_edge = (out_depth[idx - 1] <= 0.05f || out_depth[idx + 1] <= 0.05f ||
						out_depth[idx - p_gw] <= 0.05f || out_depth[idx + p_gw] <= 0.05f);
				if (is_edge) {
					const double wx = (double)p_rect.position.x + (double)ix * dx;
					const double wz = (double)p_rect.position.y + (double)iz * dz;
					boundary_pts.append(Vector2((real_t)wx, (real_t)wz));
				}
			}
		}
	}

	if (boundary_pts.size() >= 3) {
		res.contours.append(boundary_pts);
	}

	res.ok = true;
	return res;
}
