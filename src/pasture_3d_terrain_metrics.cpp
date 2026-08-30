// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_terrain_metrics.h"
#include "pasture_3d_morphology.h"
#include "pasture_3d_thread_pool.h"

#include <algorithm>
#include <cmath>
#include <vector>

using namespace godot;

namespace {

constexpr double PI_D = 3.14159265358979323846;

inline int radius_cells(double radius_m, double cell) {
	return (cell > 0.0) ? (int)std::lround(radius_m / cell) : 0;
}

// Quadratic smooth minimum. k -> 0 converges to a hard min, which is what the gate's SC criterion
// checks: a smooth blend that does NOT converge is a blend with the wrong normalisation.
inline double smin(double a, double b, double k) {
	if (k <= 1e-9) {
		return std::min(a, b);
	}
	const double h = std::clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
	return (b * (1.0 - h) + a * h) - k * h * (1.0 - h);
}

inline double smax(double a, double b, double k) {
	return -smin(-a, -b, k);
}

} // namespace

PackedFloat32Array godot::box_mean_solve(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_radius_m) {
	const int n = p_gw * p_gh;
	PackedFloat32Array result;
	if (n <= 0 || p_surface.size() != n) {
		return result;
	}
	result.resize(n);

	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
	const int wx = radius_cells(p_radius_m, dx);
	const int wz = radius_cells(p_radius_m, dz);

	const float *src = p_surface.ptr();
	float *dst = result.ptrw();
	if (wx <= 0 && wz <= 0) {
		std::copy(src, src + n, dst);
		return result;
	}

	std::vector<double> tmp((size_t)n);

	// Horizontal pass. NaN taps are skipped rather than counted, so a cell beside the brush-loop mask
	// averages what is actually there instead of being dragged toward an invented value.
	Pasture3DThreadPool::parallel_for_rows(p_gh, 8, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			for (int ix = 0; ix < p_gw; ix++) {
				double sum = 0.0;
				int count = 0;
				for (int ox = -wx; ox <= wx; ox++) {
					const int nx = ix + ox;
					if (nx < 0 || nx >= p_gw) {
						continue;
					}
					const double v = (double)src[(size_t)iz * p_gw + nx];
					if (!std::isfinite(v)) {
						continue;
					}
					sum += v;
					count++;
				}
				tmp[(size_t)iz * p_gw + ix] = (count > 0) ? (sum / (double)count) : std::nan("");
			}
		}
	});

	// Vertical pass.
	Pasture3DThreadPool::parallel_for_rows(p_gh, 8, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			for (int ix = 0; ix < p_gw; ix++) {
				double sum = 0.0;
				int count = 0;
				for (int oz = -wz; oz <= wz; oz++) {
					const int nz = iz + oz;
					if (nz < 0 || nz >= p_gh) {
						continue;
					}
					const double v = tmp[(size_t)nz * p_gw + ix];
					if (!std::isfinite(v)) {
						continue;
					}
					sum += v;
					count++;
				}
				const int i = iz * p_gw + ix;
				dst[i] = (count > 0) ? (float)(sum / (double)count) : src[i];
			}
		}
	});

	return result;
}

PackedFloat32Array godot::relative_elevation_solve(const PackedFloat32Array &p_surface, int p_gw,
		int p_gh, const Rect2 &p_rect, double p_radius_m, int p_units) {
	const int n = p_gw * p_gh;
	PackedFloat32Array result;
	if (n <= 0 || p_surface.size() != n) {
		return result;
	}
	result.resize(n);

	const float *src = p_surface.ptr();
	float *dst = result.ptrw();

	// The local basin floor and the local crest, over a disc of the given world radius. Reusing the
	// morphology kernel is not just economy: it is what makes this node's disc provably the SAME disc
	// the ExpandShrink gate already pins down on CPU, GPU and oracle.
	const PackedFloat32Array lo = expand_shrink_solve(p_surface, PackedFloat32Array(), p_gw, p_gh, p_rect,
			MORPHOLOGY_SHRINK, p_radius_m, MORPHOLOGY_KERNEL_DISC, 1, 1.0);
	const PackedFloat32Array hi = expand_shrink_solve(p_surface, PackedFloat32Array(), p_gw, p_gh, p_rect,
			MORPHOLOGY_EXPAND, p_radius_m, MORPHOLOGY_KERNEL_DISC, 1, 1.0);
	if (lo.size() != n || hi.size() != n) {
		std::copy(src, src + n, dst);
		return result;
	}

	const float *lo_p = lo.ptr();
	const float *hi_p = hi.ptr();

	Pasture3DThreadPool::parallel_for_elements(n, 1024, [&](int i0, int i1) {
		for (int i = i0; i < i1; i++) {
			const double z = (double)src[i];
			if (!std::isfinite(z)) {
				dst[i] = src[i];
				continue;
			}
			const double zlo = (double)lo_p[i];
			const double zhi = (double)hi_p[i];
			if (p_units == RELATIVE_ELEVATION_METRES) {
				dst[i] = (float)(z - zlo);
			} else {
				const double span = zhi - zlo;
				// A flat neighbourhood has no local relief to be relative to. 0.5 — the midpoint — is
				// the honest answer: the cell is neither in a basin nor on a crest. Returning 0 would
				// paint every plain as basin floor, which is what a snow mask would then act on.
				dst[i] = (span > 1e-9) ? (float)((z - zlo) / span) : 0.5f;
			}
		}
	});

	return result;
}

PackedFloat32Array godot::smooth_fill_solve(const PackedFloat32Array &p_surface,
		const PackedFloat32Array &p_mask, int p_gw, int p_gh, const Rect2 &p_rect, int p_mode,
		double p_radius_m, double p_k, double p_amount, PackedFloat32Array *r_deposition,
		double *r_deposition_divisor) {
	const int n = p_gw * p_gh;
	PackedFloat32Array result;
	if (r_deposition_divisor) {
		*r_deposition_divisor = 1.0;
	}
	if (n <= 0 || p_surface.size() != n) {
		return result;
	}
	result.resize(n);

	const float *src = p_surface.ptr();
	float *dst = result.ptrw();

	const double amount = std::clamp(p_amount, 0.0, 1.0);
	const double k = std::max(p_k, 0.0);

	std::vector<double> delta((size_t)n, 0.0);

	if (amount <= 0.0 || p_radius_m <= 0.0) {
		std::copy(src, src + n, dst);
		if (r_deposition) {
			r_deposition->resize(n);
			std::fill(r_deposition->ptrw(), r_deposition->ptrw() + n, 0.f);
		}
		return result;
	}

	const PackedFloat32Array blurred = box_mean_solve(p_surface, p_gw, p_gh, p_rect, p_radius_m);
	if (blurred.size() != n) {
		std::copy(src, src + n, dst);
		return result;
	}
	const float *zb = blurred.ptr();

	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);

	const bool has_mask = (p_mask.size() == n);
	const float *msk = has_mask ? p_mask.ptr() : nullptr;

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int zz0, int zz1) {
		for (int iz = zz0; iz < zz1; iz++) {
			for (int ix = 0; ix < p_gw; ix++) {
				const int i = iz * p_gw + ix;
				const double z = (double)src[i];
				if (!std::isfinite(z)) {
					dst[i] = src[i];
					continue;
				}
				const double b = (double)zb[i];
				double h = z;

				if (p_mode == SMOOTH_FILL_SMEAR_PEAKS) {
					h = smin(z, b, k);
				} else {
					bool apply = true;
					if (p_mode == SMOOTH_FILL_HOLES) {
						// A pit, not a valley: concave along BOTH axes. A valley floor is concave
						// across the valley and straight along it, so this test lets it through
						// untouched — which is the entire difference between the two modes.
						const int xm = std::max(ix - 1, 0);
						const int xp = std::min(ix + 1, p_gw - 1);
						const int zm = std::max(iz - 1, 0);
						const int zp = std::min(iz + 1, p_gh - 1);
						const double zxm = (double)src[(size_t)iz * p_gw + xm];
						const double zxp = (double)src[(size_t)iz * p_gw + xp];
						const double zzm = (double)src[(size_t)zm * p_gw + ix];
						const double zzp = (double)src[(size_t)zp * p_gw + ix];
						if (!std::isfinite(zxm) || !std::isfinite(zxp) || !std::isfinite(zzm) ||
								!std::isfinite(zzp)) {
							apply = false;
						} else {
							const double d2x = (zxp - 2.0 * z + zxm) / (dx * dx);
							const double d2z = (zzp - 2.0 * z + zzm) / (dz * dz);
							apply = (d2x > 0.0 && d2z > 0.0);
						}
					}
					h = apply ? smax(z, b, k) : z;
				}

				double w = amount;
				if (has_mask && std::isfinite(msk[i])) {
					w *= std::clamp((double)msk[i], 0.0, 1.0);
				}
				const double out = z + (h - z) * w;
				dst[i] = (float)out;
				delta[(size_t)i] = out - z;
			}
		}
	});

	if (r_deposition) {
		double hi = 0.0;
		for (int i = 0; i < n; i++) {
			hi = std::max(hi, std::abs(delta[(size_t)i]));
		}
		const double divisor = (hi > 1e-12) ? hi : 1.0;
		if (r_deposition_divisor) {
			*r_deposition_divisor = divisor;
		}
		r_deposition->resize(n);
		float *dep = r_deposition->ptrw();
		for (int i = 0; i < n; i++) {
			dep[i] = std::isfinite(src[i]) ? (float)(delta[(size_t)i] / divisor) : src[i];
		}
	}

	return result;
}

PackedFloat32Array godot::recast_cliff_solve(const PackedFloat32Array &p_surface,
		const PackedFloat32Array &p_mask, int p_gw, int p_gh, const Rect2 &p_rect,
		double p_talus_angle_deg, double p_radius_m, double p_amplitude, double p_gain,
		double p_direction_deg, double p_direction_spread_deg, double p_amount) {
	const int n = p_gw * p_gh;
	PackedFloat32Array result;
	if (n <= 0 || p_surface.size() != n) {
		return result;
	}
	result.resize(n);

	const float *src = p_surface.ptr();
	float *dst = result.ptrw();

	const double amount = std::clamp(p_amount, 0.0, 1.0);
	if (amount <= 0.0 || std::abs(p_amplitude) <= 0.0) {
		std::copy(src, src + n, dst);
		return result;
	}

	const PackedFloat32Array blurred = box_mean_solve(p_surface, p_gw, p_gh, p_rect, p_radius_m);
	if (blurred.size() != n) {
		std::copy(src, src + n, dst);
		return result;
	}
	const float *zb = blurred.ptr();

	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);

	// The talus angle becomes a METRIC gradient — rise over run in metres, not a per-cell rise. This is
	// the single line that Hesiod writes as `talus / shape.x`, and getting it wrong makes the cliff
	// threshold move every time the bake resolution changes.
	const double tan_talus = std::tan(p_talus_angle_deg * PI_D / 180.0);
	const double lo_gate = tan_talus * 0.75;
	const double hi_gate = tan_talus * 1.25;

	const bool directional = (p_direction_deg >= 0.0);
	const double dir_rad = p_direction_deg * PI_D / 180.0;
	const double spread_rad = std::max(p_direction_spread_deg, 0.0) * PI_D / 180.0;

	const bool has_mask = (p_mask.size() == n);
	const float *msk = has_mask ? p_mask.ptr() : nullptr;

	const double amplitude = p_amplitude;
	const double gain = std::max(p_gain, 1e-6);

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int zz0, int zz1) {
		for (int iz = zz0; iz < zz1; iz++) {
			for (int ix = 0; ix < p_gw; ix++) {
				const int i = iz * p_gw + ix;
				const double z = (double)src[i];
				if (!std::isfinite(z)) {
					dst[i] = src[i];
					continue;
				}

				const int xm = std::max(ix - 1, 0);
				const int xp = std::min(ix + 1, p_gw - 1);
				const int zm = std::max(iz - 1, 0);
				const int zp = std::min(iz + 1, p_gh - 1);
				const double zxm = (double)src[(size_t)iz * p_gw + xm];
				const double zxp = (double)src[(size_t)iz * p_gw + xp];
				const double zzm = (double)src[(size_t)zm * p_gw + ix];
				const double zzp = (double)src[(size_t)zp * p_gw + ix];
				if (!std::isfinite(zxm) || !std::isfinite(zxp) || !std::isfinite(zzm) ||
						!std::isfinite(zzp)) {
					dst[i] = src[i];
					continue;
				}

				const double gx = (zxp - zxm) / (double)((xp - xm) * dx);
				const double gz = (zzp - zzm) / (double)((zp - zm) * dz);
				const double slope = std::sqrt(gx * gx + gz * gz);

				// smoothstep across the talus threshold, so a cliff does not appear along a hard
				// contour line as the slope creeps past the angle.
				double gate;
				if (hi_gate <= lo_gate) {
					gate = (slope >= tan_talus) ? 1.0 : 0.0;
				} else {
					const double u = std::clamp((slope - lo_gate) / (hi_gate - lo_gate), 0.0, 1.0);
					gate = u * u * (3.0 - 2.0 * u);
				}

				if (directional && gate > 0.0) {
					if (slope <= 1e-12) {
						gate = 0.0;
					} else {
						// The bearing the ground FACES is the downhill direction, i.e. the negated
						// gradient.
						const double face = std::atan2(-gz, -gx);
						double diff = face - dir_rad;
						while (diff > PI_D) {
							diff -= 2.0 * PI_D;
						}
						while (diff < -PI_D) {
							diff += 2.0 * PI_D;
						}
						const double a = std::abs(diff);
						if (spread_rad <= 0.0) {
							gate = 0.0;
						} else if (a >= spread_rad) {
							gate = 0.0;
						} else {
							const double u = 1.0 - (a / spread_rad);
							gate *= u * u * (3.0 - 2.0 * u);
						}
					}
				}

				double w = amount * gate;
				if (has_mask && std::isfinite(msk[i])) {
					w *= std::clamp((double)msk[i], 0.0, 1.0);
				}
				if (w <= 0.0) {
					dst[i] = src[i];
					continue;
				}

				const double dev = z - (double)zb[i];
				const double s = 1.0 / (1.0 + std::exp(-gain * dev / amplitude));
				dst[i] = (float)(z + amplitude * (s - 0.5) * w);
			}
		}
	});

	return result;
}
