// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_transform.h"
#include "pasture_3d_thread_pool.h"

#include <algorithm>
#include <cmath>
#include <vector>

using namespace godot;

namespace {

// Bilinear read at FRACTIONAL cell coordinates. Mirrors Pasture3DGraphNodeDevTransform._sample exactly —
// the oracle is the contract, so any change here is a change there.
//
// NaN taps are DROPPED, not averaged: NaN is the brush-loop mask (spec §3.4), and letting one bleed into
// a finite neighbour pulls a seam along every loop rim. Dropping the weight keeps the finite part of the
// tap correctly normalised. TRANSFORM_EDGE_ZERO is the one case that KEEPS its weight while contributing
// nothing, so the field fades out at the border instead of being renormalised back to full amplitude.
double sample_bilinear(const float *g, double fx, double fz, int gw, int gh, int edge_mode) {
	const int x0 = (int)std::floor(fx);
	const int z0 = (int)std::floor(fz);
	const double tx = fx - (double)x0;
	const double tz = fz - (double)z0;

	double acc = 0.0;
	double wsum = 0.0;

	for (int k = 0; k < 4; k++) {
		int sx = x0 + (k & 1);
		int sz = z0 + (k >> 1);
		const double wx = ((k & 1) == 1) ? tx : (1.0 - tx);
		const double wz = ((k >> 1) == 1) ? tz : (1.0 - tz);
		const double w = wx * wz;
		if (w <= 0.0) {
			continue;
		}

		switch (edge_mode) {
			case TRANSFORM_EDGE_CLAMP:
				sx = std::clamp(sx, 0, gw - 1);
				sz = std::clamp(sz, 0, gh - 1);
				break;
			case TRANSFORM_EDGE_WRAP:
				sx = ((sx % gw) + gw) % gw;
				sz = ((sz % gh) + gh) % gh;
				break;
			case TRANSFORM_EDGE_ZERO:
			default:
				if (sx < 0 || sx >= gw || sz < 0 || sz >= gh) {
					wsum += w;
					continue;
				}
				break;
		}

		const double v = (double)g[sz * gw + sx];
		if (!std::isfinite(v)) {
			continue;
		}
		acc += w * v;
		wsum += w;
	}

	if (wsum <= 0.0) {
		return 0.0;
	}
	return acc / wsum;
}

} // namespace

double godot::transform_sample_bilinear(const float *p_grid, double p_fx, double p_fz, int p_gw, int p_gh,
		int p_edge_mode) {
	return sample_bilinear(p_grid, p_fx, p_fz, p_gw, p_gh, p_edge_mode);
}

PackedFloat32Array godot::transform_solve(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, const Vector2 &p_offset, double p_rotation_deg, double p_scale,
		const Vector2 &p_pivot, int p_edge_mode, double p_amount) {
	const int n = p_gw * p_gh;
	PackedFloat32Array result;
	result.resize(n);
	if (p_surface.size() != n || n <= 0) {
		return result;
	}

	const float *src = p_surface.ptr();
	float *dst = result.ptrw();

	const double scale = (p_scale > 1e-6) ? p_scale : 1e-6;
	const double amount = std::clamp(p_amount, 0.0, 1.0);

	// Identity is a copy, not a resample: a bilinear tap through the identity still costs a float
	// round-trip per cell, and the gate's TA criterion would then be measuring the resampler's error
	// instead of the transform's.
	if (amount <= 0.0 || (p_offset.x == 0.0f && p_offset.y == 0.0f &&
								 std::abs(p_rotation_deg) < 1e-9 && std::abs(scale - 1.0) < 1e-9)) {
		std::copy(src, src + n, dst);
		return result;
	}

	// Cell size and origin — a byte-for-byte match of Pasture3DTerrainGraph.cell_to_world: dx divides by
	// gw (NOT gw-1) and the sample sits at the cell CENTRE (+0.5). Getting this wrong is a half-texel
	// shift that looks correct in isolation and seams where two transformed regions meet.
	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
	const double ox = (double)p_rect.position.x;
	const double oz = (double)p_rect.position.y;

	if (dx <= 0.0 || dz <= 0.0) {
		std::copy(src, src + n, dst);
		return result;
	}

	// Inverse of T(pivot) R S T(-pivot) T(offset): undo the offset, un-pivot, un-rotate, un-scale.
	const double rad = -p_rotation_deg * 3.14159265358979323846 / 180.0;
	const double cs = std::cos(rad);
	const double sn = std::sin(rad);
	const double inv_s = 1.0 / scale;

	const double px_off = (double)p_offset.x + (double)p_pivot.x;
	const double pz_off = (double)p_offset.y + (double)p_pivot.y;

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			const double wz = oz + ((double)iz + 0.5) * dz;
			for (int ix = 0; ix < p_gw; ix++) {
				const int i = row + ix;
				const double v_in = (double)src[i];
				if (!std::isfinite(v_in)) {
					dst[i] = src[i]; // NaN in, NaN out.
					continue;
				}

				const double wx = ox + ((double)ix + 0.5) * dx;

				const double qx = wx - px_off;
				const double qz = wz - pz_off;
				const double rx = (qx * cs - qz * sn) * inv_s + (double)p_pivot.x;
				const double rz = (qx * sn + qz * cs) * inv_s + (double)p_pivot.y;

				const double fx = (rx - ox) / dx - 0.5;
				const double fz = (rz - oz) / dz - 0.5;

				const double s = sample_bilinear(src, fx, fz, p_gw, p_gh, p_edge_mode);
				dst[i] = (float)(v_in + (s - v_in) * amount);
			}
		}
	});

	return result;
}
