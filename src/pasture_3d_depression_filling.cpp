// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_depression_filling.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

using namespace godot;

namespace {

struct SpillNode {
	double z;
	int32_t idx;
};

struct OffsetEntry {
	int dx;
	int dy;
	double dist;
};

struct NativeMinHeap {
	std::vector<SpillNode> items;

	bool empty() const {
		return items.empty();
	}

	void push(double val, int32_t idx) {
		items.push_back({ val, idx });
		int i = (int)items.size() - 1;
		while (i > 0) {
			int parent = (i - 1) / 2;
			if (items[i].z < items[parent].z) {
				std::swap(items[i], items[parent]);
				i = parent;
			} else {
				break;
			}
		}
	}

	SpillNode pop() {
		SpillNode top = items[0];
		SpillNode last = items.back();
		items.pop_back();
		if (!items.empty()) {
			items[0] = last;
			int i = 0;
			const int size = (int)items.size();
			while (true) {
				int smallest = i;
				int left = 2 * i + 1;
				int right = 2 * i + 2;
				if (left < size && items[left].z < items[smallest].z) {
					smallest = left;
				}
				if (right < size && items[right].z < items[smallest].z) {
					smallest = right;
				}
				if (smallest != i) {
					std::swap(items[i], items[smallest]);
					i = smallest;
				} else {
					break;
				}
			}
		}
		return top;
	}
};

} // namespace

PackedFloat32Array godot::priority_flood_fill(const PackedFloat32Array &p_h, int p_gw, int p_gh,
		double p_dx, double p_dz, double p_eps, double p_depth_limit) {
	PackedFloat32Array filled;
	if (p_gw < 1 || p_gh < 1) {
		return filled;
	}
	const int n = p_gw * p_gh;
	if (p_h.size() != n) {
		return filled;
	}

	filled.resize(n);
	float *out_ptr = filled.ptrw();
	const float *src_ptr = p_h.ptr();

	std::vector<uint8_t> visited(n, 0);
	NativeMinHeap heap;

	for (int iz = 0; iz < p_gh; iz++) {
		for (int ix = 0; ix < p_gw; ix++) {
			const int idx = iz * p_gw + ix;
			const bool is_edge = (ix == 0 || ix == p_gw - 1 || iz == 0 || iz == p_gh - 1);
			const float val = src_ptr[idx];

			if (!std::isfinite(val)) {
				visited[idx] = 1;
				out_ptr[idx] = std::numeric_limits<float>::quiet_NaN();
			} else if (is_edge) {
				visited[idx] = 1;
				out_ptr[idx] = val;
				heap.push((double)val, idx);
			} else {
				out_ptr[idx] = std::numeric_limits<float>::infinity();
			}
		}
	}

	const double diag_d = std::sqrt(p_dx * p_dx + p_dz * p_dz);
	const OffsetEntry offsets[8] = {
		{ -1, 0, p_dx }, { 1, 0, p_dx },
		{ 0, -1, p_dz }, { 0, 1, p_dz },
		{ -1, -1, diag_d }, { 1, -1, diag_d },
		{ -1, 1, diag_d }, { 1, 1, diag_d }
	};

	while (!heap.empty()) {
		const SpillNode top = heap.pop();
		const double spill_z = top.z;
		const int cur_idx = top.idx;
		const int c_ix = cur_idx % p_gw;
		const int c_iz = cur_idx / p_gw;

		for (int k = 0; k < 8; k++) {
			const int nx = c_ix + offsets[k].dx;
			const int nz = c_iz + offsets[k].dy;
			if (nx < 0 || nx >= p_gw || nz < 0 || nz >= p_gh) {
				continue;
			}

			const int n_idx = nz * p_gw + nx;
			if (visited[n_idx]) {
				continue;
			}

			visited[n_idx] = 1;
			const float raw_z_f = src_ptr[n_idx];

			if (!std::isfinite(raw_z_f)) {
				out_ptr[n_idx] = std::numeric_limits<float>::quiet_NaN();
				continue;
			}

			const double raw_z = (double)raw_z_f;
			const double min_spill = spill_z + p_eps * offsets[k].dist;
			const double spill_elev = std::max(raw_z, min_spill);
			heap.push(spill_elev, n_idx);

			double filled_z = spill_elev;
			if (p_depth_limit > 0.0 && (filled_z - raw_z) > p_depth_limit) {
				filled_z = raw_z + p_depth_limit;
			}

			out_ptr[n_idx] = (float)filled_z;
		}
	}

	return filled;
}

PackedFloat32Array godot::depression_filling_solve(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_epsilon_slope, double p_fill_depth_limit, double p_amount) {
	const int n = p_gw * p_gh;
	if (p_surface.size() != n || n <= 0) {
		PackedFloat32Array empty;
		empty.resize(n);
		return empty;
	}

	if (p_amount <= 1e-6) {
		return p_surface.duplicate();
	}

	const double dx = (p_rect.size.x > 0.0 && p_gw > 1) ? ((double)p_rect.size.x / std::max((double)(p_gw - 1), 1.0)) : 2.0;
	const double dz = (p_rect.size.y > 0.0 && p_gh > 1) ? ((double)p_rect.size.y / std::max((double)(p_gh - 1), 1.0)) : 2.0;

	PackedFloat32Array filled = priority_flood_fill(p_surface, p_gw, p_gh, dx, dz, p_epsilon_slope, p_fill_depth_limit);

	if (std::abs(p_amount - 1.0) <= 1e-6) {
		return filled;
	}

	PackedFloat32Array out;
	out.resize(n);
	const float *src = p_surface.ptr();
	const float *fld = filled.ptr();
	float *dst = out.ptrw();

	for (int i = 0; i < n; i++) {
		if (std::isfinite(src[i]) && std::isfinite(fld[i])) {
			dst[i] = (float)((double)src[i] + ((double)fld[i] - (double)src[i]) * p_amount);
		} else {
			dst[i] = src[i];
		}
	}

	return out;
}
