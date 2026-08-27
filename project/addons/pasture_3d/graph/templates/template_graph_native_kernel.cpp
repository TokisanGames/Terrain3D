// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "template_graph_native_kernel.h"

#include <algorithm>
#include <cmath>

using namespace godot;

PackedFloat32Array godot::template_filter_solve(const PackedFloat32Array &p_surface,
		const PackedFloat32Array &p_mask, int p_gw, int p_gh, double p_intensity) {
	const int n = p_gw * p_gh;
	PackedFloat32Array out;
	out.resize(n);
	if (p_surface.size() != n || n <= 0) {
		return out;
	}

	const float *src = p_surface.ptr();
	const float *msk = (p_mask.size() == n) ? p_mask.ptr() : nullptr;
	float *dst = out.ptrw();

	for (int i = 0; i < n; i++) {
		const float val = src[i];
		if (std::isfinite(val)) {
			const double m = msk ? std::clamp((double)msk[i], 0.0, 1.0) : 1.0;
			dst[i] = (float)((double)val + p_intensity * m);
		} else {
			dst[i] = val;
		}
	}

	return out;
}
