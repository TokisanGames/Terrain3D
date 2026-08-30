// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_morphology.h"
#include "pasture_3d_thread_pool.h"

#include <algorithm>
#include <cmath>
#include <vector>

using namespace godot;

namespace {

// 1D running extremum over a window of half-width w, along a strided sequence.
//
// A monotonic deque rather than van Herk-Gil-Werman. vHGW is the textbook O(1)-per-cell answer and it is
// what the spec named, but its prefix/suffix block scan assumes every sample participates — and NaN must
// be SKIPPED here, not folded in as an identity element. A NaN treated as -inf under a max is invisible;
// treated as +inf it swallows the window. The deque skips cleanly because it only ever holds indices of
// finite samples, and it is still O(1) amortised per cell, so nothing was traded away but the constant.
//
// A window containing no finite sample at all yields NaN, which is the honest answer: there was nothing
// there to take an extremum of.
void line_extremum(const double *src, double *dst, int count, int stride, int w, bool is_max,
		std::vector<int> &deque_buf) {
	if (count <= 0) {
		return;
	}
	deque_buf.clear();
	deque_buf.reserve((size_t)count);
	int head = 0;

	// The deque holds indices in decreasing (max) or increasing (min) order of value, so its front is
	// always the extremum of the live window.
	auto push = [&](int idx) {
		const double v = src[(size_t)idx * stride];
		if (!std::isfinite(v)) {
			return; // skipped, never folded in as an identity
		}
		while ((int)deque_buf.size() > head) {
			const double back = src[(size_t)deque_buf.back() * stride];
			const bool dominated = is_max ? (back <= v) : (back >= v);
			if (!dominated) {
				break;
			}
			deque_buf.pop_back();
		}
		deque_buf.push_back(idx);
	};

	for (int i = 0; i < std::min(w, count); i++) {
		push(i);
	}

	for (int i = 0; i < count; i++) {
		const int add = i + w;
		if (add < count) {
			push(add);
		}
		const int drop = i - w - 1;
		while ((int)deque_buf.size() > head && deque_buf[(size_t)head] <= drop) {
			head++;
		}
		dst[(size_t)i * stride] = ((int)deque_buf.size() > head)
				? src[(size_t)deque_buf[(size_t)head] * stride]
				: std::nan("");
	}
}

void horizontal_pass(const std::vector<double> &src, std::vector<double> &dst, int gw, int gh, int w,
		bool is_max) {
	Pasture3DThreadPool::parallel_for_rows(gh, 8, [&](int z0, int z1) {
		std::vector<int> deque_buf;
		for (int iz = z0; iz < z1; iz++) {
			line_extremum(&src[(size_t)iz * gw], &dst[(size_t)iz * gw], gw, 1, w, is_max, deque_buf);
		}
	});
}

void vertical_pass(const std::vector<double> &src, std::vector<double> &dst, int gw, int gh, int w,
		bool is_max) {
	Pasture3DThreadPool::parallel_for_elements(gw, 8, [&](int x0, int x1) {
		std::vector<int> deque_buf;
		for (int ix = x0; ix < x1; ix++) {
			line_extremum(&src[(size_t)ix], &dst[(size_t)ix], gh, gw, w, is_max, deque_buf);
		}
	});
}

// One morphological pass: dilation (is_max) or erosion over the structuring element.
void morph_pass(const std::vector<double> &src, std::vector<double> &dst, int gw, int gh, int wx, int wz,
		int kernel, bool is_max) {
	if (wx <= 0 && wz <= 0) {
		dst = src;
		return;
	}

	if (kernel == MORPHOLOGY_KERNEL_SQUARE) {
		// A box is separable: rows then columns, exactly.
		std::vector<double> tmp(src.size());
		horizontal_pass(src, tmp, gw, gh, wx, is_max);
		vertical_pass(tmp, dst, gw, gh, wz, is_max);
		return;
	}

	// A disc is NOT separable, but it decomposes into a stack of horizontal line segments — one per row
	// offset, each with the half-width the circle has at that offset. That is `2*wz + 1` horizontal
	// passes instead of the O(r^2) per-cell gather, and it keeps the exact disc shape rather than
	// approximating it with a box.
	dst.assign(src.size(), std::nan(""));
	std::vector<double> row_dilated(src.size());
	const double rz = std::max(wz, 1);

	for (int dz = -wz; dz <= wz; dz++) {
		// FLOOR, not round. The disc is defined once, as the offsets satisfying
		// (ox/wx)^2 + (oz/wz)^2 <= 1, and floor is what makes this row's half-width contain exactly
		// those offsets. Rounding would admit a ring of cells just outside the ellipse and quietly give
		// this kernel a different structuring element from the oracle's.
		const double t = (wz > 0) ? ((double)dz / rz) : 0.0;
		const double frac = std::sqrt(std::max(0.0, 1.0 - t * t));
		const int w = (int)std::floor((double)wx * frac + 1e-9);

		horizontal_pass(src, row_dilated, gw, gh, w, is_max);

		Pasture3DThreadPool::parallel_for_rows(gh, 8, [&](int z0, int z1) {
			for (int iz = z0; iz < z1; iz++) {
				const int sz = iz + dz;
				if (sz < 0 || sz >= gh) {
					continue;
				}
				for (int ix = 0; ix < gw; ix++) {
					const double v = row_dilated[(size_t)sz * gw + ix];
					if (!std::isfinite(v)) {
						continue;
					}
					double &d = dst[(size_t)iz * gw + ix];
					if (!std::isfinite(d)) {
						d = v;
					} else if (is_max ? (v > d) : (v < d)) {
						d = v;
					}
				}
			}
		});
	}
}

void apply_mode(const std::vector<double> &src, std::vector<double> &dst, int gw, int gh, int wx, int wz,
		int kernel, int mode) {
	switch (mode) {
		case MORPHOLOGY_SHRINK:
			morph_pass(src, dst, gw, gh, wx, wz, kernel, false);
			break;
		case MORPHOLOGY_OPEN: {
			std::vector<double> mid(src.size());
			morph_pass(src, mid, gw, gh, wx, wz, kernel, false);
			morph_pass(mid, dst, gw, gh, wx, wz, kernel, true);
		} break;
		case MORPHOLOGY_CLOSE: {
			std::vector<double> mid(src.size());
			morph_pass(src, mid, gw, gh, wx, wz, kernel, true);
			morph_pass(mid, dst, gw, gh, wx, wz, kernel, false);
		} break;
		case MORPHOLOGY_GRADIENT: {
			std::vector<double> hi(src.size());
			std::vector<double> lo(src.size());
			morph_pass(src, hi, gw, gh, wx, wz, kernel, true);
			morph_pass(src, lo, gw, gh, wx, wz, kernel, false);
			dst.resize(src.size());
			for (size_t i = 0; i < src.size(); i++) {
				dst[i] = hi[i] - lo[i];
			}
		} break;
		case MORPHOLOGY_EXPAND:
		default:
			morph_pass(src, dst, gw, gh, wx, wz, kernel, true);
			break;
	}
}

} // namespace

PackedFloat32Array godot::expand_shrink_solve(const PackedFloat32Array &p_surface,
		const PackedFloat32Array &p_mask, int p_gw, int p_gh, const Rect2 &p_rect, int p_mode,
		double p_radius_m, int p_kernel, int p_iterations, double p_amount) {
	const int n = p_gw * p_gh;
	PackedFloat32Array result;
	if (n <= 0 || p_surface.size() != n) {
		return result;
	}
	result.resize(n);

	const float *src_f = p_surface.ptr();
	float *dst_f = result.ptrw();

	const double amount = std::clamp(p_amount, 0.0, 1.0);
	const int iterations = std::clamp(p_iterations, 0, 64);

	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);

	// Metres to cells. Rounding to NEAREST rather than truncating keeps the grown distance within half a
	// cell of the requested world radius at any resolution; truncation biases every radius downward and
	// makes the metric-invariance criterion fail by a systematic cell, not by rounding.
	const int wx = (dx > 0.0) ? (int)std::lround(p_radius_m / dx) : 0;
	const int wz = (dz > 0.0) ? (int)std::lround(p_radius_m / dz) : 0;

	if (amount <= 0.0 || iterations <= 0 || (wx <= 0 && wz <= 0)) {
		std::copy(src_f, src_f + n, dst_f);
		return result;
	}

	std::vector<double> a((size_t)n);
	for (int i = 0; i < n; i++) {
		a[(size_t)i] = (double)src_f[i];
	}
	std::vector<double> b((size_t)n);

	for (int it = 0; it < iterations; it++) {
		apply_mode(a, b, p_gw, p_gh, wx, wz, p_kernel, p_mode);
		a.swap(b);
	}

	const bool has_mask = (p_mask.size() == n);
	const float *msk = has_mask ? p_mask.ptr() : nullptr;

	for (int i = 0; i < n; i++) {
		const double v_in = (double)src_f[i];
		if (!std::isfinite(v_in)) {
			dst_f[i] = src_f[i]; // NaN in, NaN out — the brush loop mask survives.
			continue;
		}
		const double v_out = a[(size_t)i];
		if (!std::isfinite(v_out)) {
			// Every sample in the structuring element was masked out; leave the input alone rather than
			// writing a NaN the input never had.
			dst_f[i] = src_f[i];
			continue;
		}
		double w = amount;
		if (has_mask && std::isfinite(msk[i])) {
			w *= std::clamp((double)msk[i], 0.0, 1.0);
		}
		dst_f[i] = (float)(v_in + (v_out - v_in) * w);
	}

	return result;
}
