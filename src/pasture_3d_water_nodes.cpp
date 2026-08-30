// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_water_nodes.h"
#include "pasture_3d_distance_transform.h"

#include <algorithm>
#include <cmath>

using namespace godot;

PackedFloat32Array godot::flooding_uniform_level_solve(const PackedFloat32Array &p_surface, int p_gw,
		int p_gh, double p_level, bool p_clamp_terrain, PackedFloat32Array *r_depth,
		PackedFloat32Array *r_mask) {
	const int n = p_gw * p_gh;
	PackedFloat32Array out;
	if (p_gw <= 0 || p_gh <= 0 || p_surface.size() != n) {
		return out;
	}
	out.resize(n);
	if (r_depth) {
		r_depth->resize(n);
	}
	if (r_mask) {
		r_mask->resize(n);
	}

	const float *src = p_surface.ptr();
	float *dst = out.ptrw();
	float *dep = r_depth ? r_depth->ptrw() : nullptr;
	float *msk = r_mask ? r_mask->ptrw() : nullptr;

	for (int i = 0; i < n; i++) {
		const float z = src[i];
		if (!std::isfinite(z)) {
			// NaN is the brush-loop mask (spec §3.4). A masked-out cell is not "dry land at 0 m", it is
			// absent, so it stays absent in every channel.
			dst[i] = z;
			if (dep) {
				dep[i] = z;
			}
			if (msk) {
				msk[i] = z;
			}
			continue;
		}
		const double d = std::max((double)p_level - (double)z, 0.0);
		dst[i] = p_clamp_terrain ? (float)std::max((double)z, (double)p_level) : z;
		if (dep) {
			dep[i] = (float)d;
		}
		if (msk) {
			msk[i] = (d > 0.0) ? 1.f : 0.f;
		}
	}
	return out;
}

PackedFloat32Array godot::water_mask_solve(const PackedFloat32Array &p_depth, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_depth_threshold, double p_shore_width_m, int p_shore_falloff,
		PackedFloat32Array *r_shore) {
	const int n = p_gw * p_gh;
	PackedFloat32Array water;
	if (p_gw <= 0 || p_gh <= 0 || p_depth.size() != n) {
		return water;
	}
	water.resize(n);
	if (r_shore) {
		r_shore->resize(n);
		r_shore->fill(0.f);
	}

	const float *dep = p_depth.ptr();
	float *wat = water.ptrw();
	for (int i = 0; i < n; i++) {
		const float d = dep[i];
		if (!std::isfinite(d)) {
			wat[i] = d;
			continue;
		}
		wat[i] = ((double)d > p_depth_threshold) ? 1.f : 0.f;
	}

	if (!r_shore || p_shore_width_m <= 0.0) {
		return water;
	}

	// SIGNED distance to the waterline, in metres: negative inside the water, positive on land. The
	// threshold is 0.5 because `water` is already a hard 0/1 field — the distance transform's own
	// threshold is not a second chance to redefine where the water is.
	double divisor = 1.0;
	const PackedFloat32Array signed_d = distance_transform_solve(water, p_gw, p_gh, p_rect, 0.5,
			DISTANCE_TRANSFORM_SIGNED, DISTANCE_TRANSFORM_EUCLIDEAN, DISTANCE_TRANSFORM_METRES, 0.0,
			&divisor);
	if (signed_d.size() != n) {
		return water;
	}

	const float *sd = signed_d.ptr();
	float *shore = r_shore->ptrw();
	for (int i = 0; i < n; i++) {
		const double s = (double)sd[i];
		if (!std::isfinite(s)) {
			shore[i] = (float)s;
			continue;
		}
		// The band straddles the waterline: |d| is what matters, so a beach is as wide on the wet side as
		// on the dry one. A one-sided band would have been the easier thing to write and would make the
		// wet-sand material stop dead at the water's edge.
		const double t = std::clamp(1.0 - std::abs(s) / p_shore_width_m, 0.0, 1.0);
		shore[i] = (float)((p_shore_falloff == WATER_SHORE_SMOOTH) ? (t * t * (3.0 - 2.0 * t)) : t);
	}
	return water;
}
