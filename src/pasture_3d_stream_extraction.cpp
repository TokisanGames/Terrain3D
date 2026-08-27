// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_stream_extraction.h"
#include "pasture_3d_depression_filling.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <numeric>
#include <vector>

using namespace godot;

namespace {

struct OffsetEntry {
	int dx;
	int dy;
	double dist;
};

} // namespace

Dictionary StreamExtractionResult::to_dict() const {
	Dictionary d;
	d["ok"] = ok;
	d["height"] = height;
	d["channel_mask"] = channel_mask;
	d["flow_rate"] = flow_rate;
	d["stream_points"] = stream_points;
	return d;
}

StreamExtractionResult godot::stream_extraction_solve(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_min_catchment_cells, double p_carve_depth,
		double p_channel_width, double p_bank_falloff) {
	StreamExtractionResult res;
	if (p_gw < 1 || p_gh < 1) {
		return res;
	}
	const int n = p_gw * p_gh;
	if (p_surface.size() != n) {
		return res;
	}

	const double dx = (p_rect.size.x > 0.0 && p_gw > 1) ? ((double)p_rect.size.x / std::max((double)(p_gw - 1), 1.0)) : 2.0;
	const double dz = (p_rect.size.y > 0.0 && p_gh > 1) ? ((double)p_rect.size.y / std::max((double)(p_gh - 1), 1.0)) : 2.0;

	// 1. Fill depressions for monotonic flow routing
	PackedFloat32Array filled = priority_flood_fill(p_surface, p_gw, p_gh, dx, dz, 0.0001, 0.0);
	const float *fld_ptr = filled.ptr();
	const float *src_ptr = p_surface.ptr();

	// 2. Sort indices descending by elevation
	std::vector<int32_t> order(n);
	std::iota(order.begin(), order.end(), 0);
	std::stable_sort(order.begin(), order.end(), [&](int32_t a, int32_t b) {
		const float za = fld_ptr[a];
		const float zb = fld_ptr[b];
		if (!std::isfinite(za) && !std::isfinite(zb)) return false;
		if (!std::isfinite(za)) return false;
		if (!std::isfinite(zb)) return true;
		return za > zb;
	});

	// 3. D8 flow receiver map
	std::vector<int32_t> receiver(n, -1);
	const double diag_d = std::sqrt(dx * dx + dz * dz);
	const OffsetEntry offsets[8] = {
		{ -1, 0, dx }, { 1, 0, dx },
		{ 0, -1, dz }, { 0, 1, dz },
		{ -1, -1, diag_d }, { 1, -1, diag_d },
		{ -1, 1, diag_d }, { 1, 1, diag_d }
	};

	for (int iz = 0; iz < p_gh; iz++) {
		for (int ix = 0; ix < p_gw; ix++) {
			const int idx = iz * p_gw + ix;
			const float zh = fld_ptr[idx];
			if (!std::isfinite(zh)) {
				continue;
			}

			double max_slope = 0.0;
			int best_rec = -1;

			for (int k = 0; k < 8; k++) {
				const int nx = ix + offsets[k].dx;
				const int nz = iz + offsets[k].dy;
				if (nx < 0 || nx >= p_gw || nz < 0 || nz >= p_gh) {
					continue;
				}
				const int n_idx = nz * p_gw + nx;
				const float n_zh = fld_ptr[n_idx];
				if (!std::isfinite(n_zh)) {
					continue;
				}
				const double slope = ((double)zh - (double)n_zh) / offsets[k].dist;
				if (slope > max_slope) {
					max_slope = slope;
					best_rec = n_idx;
				}
			}

			receiver[idx] = best_rec;
		}
	}

	// 4. Downhill flow accumulation
	std::vector<double> accum(n, 1.0);
	double max_accum = 1.0;

	for (int32_t idx : order) {
		const int32_t rec = receiver[idx];
		if (rec >= 0 && rec < n) {
			accum[rec] += accum[idx];
			if (accum[rec] > max_accum) {
				max_accum = accum[rec];
			}
		}
	}

	res.height = p_surface.duplicate();
	res.channel_mask.resize(n);
	res.flow_rate.resize(n);

	float *out_h = res.height.ptrw();
	float *out_channel = res.channel_mask.ptrw();
	float *out_flow = res.flow_rate.ptrw();

	const double min_cells = std::max(p_min_catchment_cells, 1.0);
	const double divisor_channel = std::max(min_cells * 2.0, 1.0);
	const double divisor_flow = std::max(max_accum, 1.0);

	// 5. Channel incision along high catchment
	for (int i = 0; i < n; i++) {
		const double flow = accum[i];
		out_flow[i] = (float)std::clamp(flow / divisor_flow, 0.0, 1.0);

		if (flow >= min_cells && std::isfinite(out_h[i])) {
			const double intensity = std::clamp((flow - min_cells) / divisor_channel, 0.0, 1.0);
			out_channel[i] = (float)intensity;
			const double carve = p_carve_depth * intensity;
			out_h[i] = (float)((double)out_h[i] - carve);
		} else {
			out_channel[i] = 0.0f;
		}
	}

	// 6. Vectorized thalweg streamline tracing
	int max_idx = -1;
	double max_val = min_cells;
	for (int i = 0; i < n; i++) {
		if (accum[i] > max_val) {
			max_val = accum[i];
			max_idx = i;
		}
	}

	if (max_idx >= 0) {
		std::vector<uint8_t> visited_trace(n, 0);
		int curr = max_idx;

		while (curr >= 0 && curr < n && !visited_trace[curr]) {
			visited_trace[curr] = 1;
			const int ix = curr % p_gw;
			const int iz = curr / p_gw;
			const double wx = (double)p_rect.position.x + (double)ix * dx;
			const double wz = (double)p_rect.position.y + (double)iz * dz;
			const double wy = std::isfinite(src_ptr[curr]) ? (double)src_ptr[curr] : 0.0;
			res.stream_points.append(Vector3((real_t)wx, (real_t)wy, (real_t)wz));
			curr = receiver[curr];
		}
	}

	res.ok = true;
	return res;
}
