// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_spectral_equalizer.h"
#include "pasture_3d_graph_ops.h"
#include "pasture_3d_thread_pool.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

using namespace godot;

PackedFloat32Array godot::spectral_equalizer_solve(const PackedFloat32Array &p_surface,
		const PackedFloat32Array &p_mask, int p_gw, int p_gh,
		double p_macro_gain, double p_meso_gain, double p_micro_gain,
		int p_macro_passes, int p_meso_passes, double p_amount) {
	const int n = p_gw * p_gh;
	if (p_surface.size() != n || n <= 0) {
		PackedFloat32Array empty;
		empty.resize(n);
		return empty;
	}

	if (p_amount <= 1e-6) {
		return p_surface.duplicate();
	}

	// Exact mathematical identity optimization
	if (std::abs(p_macro_gain - 1.0) <= 1e-6 && std::abs(p_meso_gain - 1.0) <= 1e-6 && std::abs(p_micro_gain - 1.0) <= 1e-6) {
		return p_surface.duplicate();
	}

	const float *src_h = p_surface.ptr();
	const float *src_m = (p_mask.size() == n) ? p_mask.ptr() : nullptr;

	const int p_meso = std::min(p_meso_passes, p_macro_passes);
	const int p_macro = std::max(p_macro_passes, p_meso_passes);

	// Multi-scale separable decomposition
	std::vector<float> l_meso(src_h, src_h + n);
	graph_nan_blur(l_meso, p_gw, p_gh, p_meso);

	std::vector<float> l_macro = l_meso;
	graph_nan_blur(l_macro, p_gw, p_gh, p_macro - p_meso);

	PackedFloat32Array out;
	out.resize(n);
	float *dst = out.ptrw();

	Pasture3DThreadPool::parallel_for_elements(n, 1024, [&](int i0, int i1) {
		for (int i = i0; i < i1; i++) {
			const float h_orig = src_h[i];
			if (!std::isfinite(h_orig)) {
				dst[i] = std::numeric_limits<float>::quiet_NaN();
				continue;
			}

			const double macro_val = (double)l_macro[i];
			const double meso_band = (double)l_meso[i] - macro_val;
			const double micro_band = (double)h_orig - (double)l_meso[i];

			const double h_eq = p_macro_gain * macro_val + p_meso_gain * meso_band + p_micro_gain * micro_band;
			const double m = src_m ? std::clamp((double)src_m[i], 0.0, 1.0) : 1.0;

			dst[i] = (float)((double)h_orig + (h_eq - (double)h_orig) * (p_amount * m));
		}
	});

	return out;
}
