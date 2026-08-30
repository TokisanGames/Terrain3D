// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_math_ops.h"
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

} // namespace

PackedFloat32Array godot::curve_grid(const PackedFloat32Array &p_surface, const PackedFloat32Array &p_lut,
		double p_in_min, double p_in_max, double p_out_min, double p_out_max, double p_amount) {
	const int n = p_surface.size();
	PackedFloat32Array out;
	out.resize(n);
	if (n <= 0) {
		return out;
	}

	const int lut_size = p_lut.size();
	if (lut_size < 2 || std::abs(p_amount) <= 1e-7) {
		return p_surface.duplicate();
	}

	const float *s_ptr = p_surface.ptr();
	const float *lut_ptr = p_lut.ptr();
	float *w = out.ptrw();

	const double span_in = p_in_max - p_in_min;
	const double span_out = p_out_max - p_out_min;
	const double lut_max_idx = (double)(lut_size - 1);

	Pasture3DThreadPool::parallel_for_elements(n, 1024, [&](int i0, int i1) {
		for (int i = i0; i < i1; i++) {
			const float x = s_ptr[i];
			if (std::isnan(x)) {
				w[i] = NAN;
				continue;
			}

			double u = 0.0;
			if (std::abs(span_in) > 1.0e-9) {
				u = std::clamp(((double)x - p_in_min) / span_in, 0.0, 1.0);
			}

			const double f_idx = u * lut_max_idx;
			const int idx0 = std::min((int)f_idx, lut_size - 2);
			const double frac = f_idx - (double)idx0;
			const double y = (double)lut_ptr[idx0] * (1.0 - frac) + (double)lut_ptr[idx0 + 1] * frac;

			const double remapped = p_out_min + y * span_out;
			w[i] = (float)((double)x + ((remapped - (double)x) * p_amount));
		}
	});

	return out;
}

PackedFloat32Array godot::remap_grid(const PackedFloat32Array &p_surface,
		double p_in_min, double p_in_max, double p_out_min, double p_out_max,
		bool p_clamp_output, double p_soft_knee, bool p_invert) {
	const int n = p_surface.size();
	PackedFloat32Array out;
	out.resize(n);
	if (n <= 0) {
		return out;
	}

	const float *s_ptr = p_surface.ptr();
	float *w = out.ptrw();

	const double span_in = p_in_max - p_in_min;
	const double span_out = p_out_max - p_out_min;
	const double k = p_soft_knee * 0.5;

	Pasture3DThreadPool::parallel_for_elements(n, 1024, [&](int i0, int i1) {
		for (int i = i0; i < i1; i++) {
			const float x = s_ptr[i];
			if (std::isnan(x)) {
				w[i] = NAN;
				continue;
			}

			double t = (std::abs(span_in) > 1.0e-9) ? (((double)x - p_in_min) / span_in) : 0.0;
			if (p_invert) {
				t = 1.0 - t;
			}

			if (p_clamp_output) {
				if (p_soft_knee > 0.0) {
					if (t < k) {
						const double st = t / k;
						t = 0.5 * k * st * st;
					} else if (t > (1.0 - k)) {
						const double st = (1.0 - t) / k;
						t = 1.0 - 0.5 * k * st * st;
					}
				}
				t = std::clamp(t, 0.0, 1.0);
			}

			w[i] = (float)(p_out_min + t * span_out);
		}
	});

	return out;
}

PackedFloat32Array godot::mask_grid(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, int p_property, double p_band_min, double p_band_max,
		double p_falloff_lo, double p_falloff_hi, bool p_invert, double p_strength) {
	const int n = p_gw * p_gh;
	PackedFloat32Array out;
	out.resize(n);
	if (n <= 0 || p_surface.size() != n) {
		return out;
	}

	const float *h = p_surface.ptr();
	float *w = out.ptrw();

	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
	const double inv2x = 1.0 / (2.0 * std::max(dx, 1.0e-9));
	const double inv2z = 1.0 / (2.0 * std::max(dz, 1.0e-9));
	const double rad_to_deg_c = 180.0 / Math_PI;

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			const int zm = std::max(iz - 1, 0) * p_gw;
			const int zp = std::min(iz + 1, p_gh - 1) * p_gw;

			for (int ix = 0; ix < p_gw; ix++) {
				const int xm = std::max(ix - 1, 0);
				const int xp = std::min(ix + 1, p_gw - 1);
				const float c = h[row + ix];

				if (std::isnan(c)) {
					w[row + ix] = 0.0f;
					continue;
				}

				double x = 0.0;
				if (p_property == GRAPH_MASK_ALTITUDE) {
					x = (double)c;
				} else if (p_property == GRAPH_MASK_SLOPE) {
					const double gx = ((double)h[row + xp] - (double)h[row + xm]) * inv2x;
					const double gz = ((double)h[zp + ix] - (double)h[zm + ix]) * inv2z;
					x = std::atan(std::sqrt(gx * gx + gz * gz)) * rad_to_deg_c;
				} else {
					// CURVATURE
					const double hxm = std::isnan(h[row + xm]) ? (double)c : (double)h[row + xm];
					const double hxp = std::isnan(h[row + xp]) ? (double)c : (double)h[row + xp];
					const double hzm = std::isnan(h[zm + ix]) ? (double)c : (double)h[zm + ix];
					const double hzp = std::isnan(h[zp + ix]) ? (double)c : (double)h[zp + ix];
					x = (hxm + hxp + hzm + hzp) * 0.25 - (double)c;
				}

				const double lo = p_band_min;
				const double hi = p_band_max;
				const double f_lo = std::max(p_falloff_lo, 0.0);
				const double f_hi = std::max(p_falloff_hi, 0.0);

				const double rise = (x >= lo) ? 1.0 : ((f_lo > 0.0) ? smoothstep(lo - f_lo, lo, x) : 0.0);
				const double fall = (x <= hi) ? 1.0 : ((f_hi > 0.0) ? 1.0 - smoothstep(hi, hi + f_hi, x) : 0.0);

				double weight = std::clamp(std::min(rise, fall), 0.0, 1.0);
				if (p_invert) {
					weight = 1.0 - weight;
				}

				w[row + ix] = (float)(1.0 + (weight - 1.0) * p_strength);
			}
		}
	});

	return out;
}

// --- Falloff (PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md §4.2) ---------------------------------------
//
// Mirrors Pasture3DGraphNodeFalloff.attenuation / eval_cell. Distances are WORLD METRES taken from the
// cell centre via the same mapping as Pasture3DTerrainGraph.cell_to_world (dx divides by gw, sample at
// +0.5), so the falloff reads identically at any bake resolution and under any modifier margin.
PackedFloat32Array godot::falloff_grid(const PackedFloat32Array &p_surface, const PackedFloat32Array &p_noise,
		int p_gw, int p_gh, const Rect2 &p_rect, int p_shape, double p_centre_x, double p_centre_z,
		double p_radius, double p_feather, double p_strength, bool p_invert, double p_distance_noise) {
	const int n = p_gw * p_gh;
	PackedFloat32Array result;
	result.resize(n);
	if (p_surface.size() != n || n <= 0) {
		return result;
	}

	const float *src = p_surface.ptr();
	const float *nz = (p_noise.size() == n) ? p_noise.ptr() : nullptr;
	float *dst = result.ptrw();

	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
	const double ox = (double)p_rect.position.x;
	const double oz = (double)p_rect.position.y;
	const double strength = std::clamp(p_strength, 0.0, 1.0);

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			const double wz = oz + ((double)iz + 0.5) * dz;
			for (int ix = 0; ix < p_gw; ix++) {
				const int i = row + ix;
				const double v = (double)src[i];
				if (!std::isfinite(v)) {
					dst[i] = src[i]; // NaN is the loop mask; it survives untouched.
					continue;
				}

				const double wx = ox + ((double)ix + 0.5) * dx;
				const double ddx = wx - p_centre_x;
				const double ddz = wz - p_centre_z;

				double d = 0.0;
				switch (p_shape) {
					case GRAPH_FALLOFF_SQUARE: d = std::max(std::abs(ddx), std::abs(ddz)); break;
					case GRAPH_FALLOFF_AXIS_X: d = std::abs(ddx); break;
					case GRAPH_FALLOFF_AXIS_Z: d = std::abs(ddz); break;
					case GRAPH_FALLOFF_RADIAL:
					default: d = std::sqrt(ddx * ddx + ddz * ddz); break;
				}
				if (nz != nullptr && std::isfinite(nz[i])) {
					d += p_distance_noise * (double)nz[i];
				}

				// A zero feather is a hard edge, not a divide by zero.
				double t;
				if (p_feather <= 0.0) {
					t = (d <= p_radius) ? 0.0 : 1.0;
				} else {
					const double u = std::clamp((d - p_radius) / p_feather, 0.0, 1.0);
					t = u * u * (3.0 - 2.0 * u);
				}

				double a = 1.0 - t;
				if (p_invert) {
					a = 1.0 - a;
				}

				dst[i] = (float)(v * (1.0 + (a - 1.0) * strength));
			}
		}
	});

	return result;
}

// --- Contrast (PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md §4.3) --------------------------------------
//
// Mirrors Pasture3DGraphNodeContrast.eval_cell. Heights OUTSIDE the window pass through untouched rather
// than being clamped into it — clamping would flatten every peak above the window into a plateau.
PackedFloat32Array godot::contrast_grid(const PackedFloat32Array &p_surface, const PackedFloat32Array &p_mask,
		int p_mode, double p_amount, double p_range_min, double p_range_max, double p_mask_amount) {
	const int n = p_surface.size();
	PackedFloat32Array result;
	result.resize(n);
	if (n <= 0) {
		return result;
	}

	const float *src = p_surface.ptr();
	const float *msk = (p_mask.size() == n) ? p_mask.ptr() : nullptr;
	float *dst = result.ptrw();

	const double span = p_range_max - p_range_min;
	if (span <= 0.0) {
		// A degenerate window has no defined normalisation; pass through rather than invent one.
		std::copy(src, src + n, dst);
		return result;
	}

	const double amount = std::max(p_amount, 0.001);
	const double mask_amount = std::clamp(p_mask_amount, 0.0, 1.0);

	Pasture3DThreadPool::parallel_for_elements(n, 1024, [&](int i0, int i1) {
		for (int i = i0; i < i1; i++) {
			const double v = (double)src[i];
			if (!std::isfinite(v)) {
				dst[i] = src[i];
				continue;
			}
			if (v <= p_range_min || v >= p_range_max) {
				dst[i] = src[i];
				continue;
			}

			const double t = (v - p_range_min) / span;
			double c;
			if (p_mode == GRAPH_CONTRAST_GAMMA) {
				c = std::pow(t, amount);
			} else if (t < 0.5) {
				c = 0.5 * std::pow(2.0 * t, amount);
			} else {
				c = 1.0 - 0.5 * std::pow(2.0 - 2.0 * t, amount);
			}

			const double shaped = p_range_min + c * span;
			double w = mask_amount;
			if (msk != nullptr && std::isfinite(msk[i])) {
				w *= (double)msk[i];
			}
			w = std::clamp(w, 0.0, 1.0);
			dst[i] = (float)(v + (shaped - v) * w);
		}
	});

	return result;
}
