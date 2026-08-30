#include "pasture_3d_graph_ops.h"
#include "pasture_3d_distance_transform.h"
#include "pasture_3d_morphology.h"
#include "pasture_3d_terrain_metrics.h"
#include "pasture_3d_transform.h"
#include "pasture_3d_thread_pool.h"
#include "pasture_3d_crater.h"
#include "pasture_3d_curvature.h"
#include "pasture_3d_depression_filling.h"
#include "pasture_3d_dunes.h"
#include "pasture_3d_erosion.h"
#include "pasture_3d_erosion_hydraulic.h"
#include "pasture_3d_erosion_thermal.h"
#include "pasture_3d_furrows.h"
#include "pasture_3d_geo_primitives.h"
#include "pasture_3d_geological_primitive.h"
#include "pasture_3d_graph_gpu.h"
#include "pasture_3d_hydraulic_particle.h"
#include "pasture_3d_hydraulic_saleve.h"
#include "pasture_3d_hydraulic_stream_log.h"
#include "pasture_3d_lake_flooding.h"
#include "pasture_3d_math_ops.h"
#include "pasture_3d_noise_jordan.h"
#include "pasture_3d_noise_swiss.h"
#include "pasture_3d_scree.h"
#include "pasture_3d_spectral_equalizer.h"
#include "pasture_3d_strata.h"
#include "pasture_3d_stream_extraction.h"
#include "pasture_3d_warp.h"

#include <algorithm>
#include <cmath>
#include <utility>

using namespace godot;

namespace godot {

bool graph_cell_build(const Dictionary &p_prog, GraphCellProgram &r_out) {
	r_out = GraphCellProgram();
	if (!p_prog.has("ops") || !p_prog.has("params") || !p_prog.has("in_a") ||
			!p_prog.has("in_b") || !p_prog.has("noise") || !p_prog.has("output")) {
		return false;
	}
	r_out.ops = p_prog["ops"];
	r_out.params = p_prog["params"];
	if (p_prog.has("params_b")) {
		r_out.params_b = p_prog["params_b"];
	}
	if (p_prog.has("params_c")) {
		r_out.params_c = p_prog["params_c"];
	}
	if (p_prog.has("params_d")) {
		r_out.params_d = p_prog["params_d"];
	}
	r_out.in_a = p_prog["in_a"];
	r_out.in_b = p_prog["in_b"];
	r_out.output = (int)p_prog["output"];
	const int n = r_out.ops.size();
	// The parallel arrays must line up; a program whose columns disagree is malformed, not merely
	// short, so refuse it rather than index off the end of the shortest.
	const Array noise_in = p_prog["noise"];
	if (r_out.params.size() != n || r_out.in_a.size() != n || r_out.in_b.size() != n ||
			noise_in.size() != n) {
		r_out = GraphCellProgram();
		return false;
	}
	r_out.noise.resize(n);
	for (int i = 0; i < n; i++) {
		// A null entry stays an empty Ref; only NOISE/JITTER slots carry one, and the evaluator reads it only there.
		r_out.noise[i] = Ref<FastNoiseLite>(noise_in[i]);
	}
	r_out.count = n;
	if (r_out.is_empty()) {
		r_out = GraphCellProgram();
		return false;
	}
	return true;
}

double graph_cell_eval(const GraphCellProgram &p_prog, double p_wx, double p_wz,
		std::vector<double> &r_scratch) {
	if ((int)r_scratch.size() < p_prog.count) {
		r_scratch.resize(p_prog.count);
	}
	const int32_t *ops = p_prog.ops.ptr();
	const float *params = p_prog.params.ptr();
	const float *params_b = p_prog.params_b.ptr();
	const float *params_c = p_prog.params_c.ptr();
	const float *params_d = p_prog.params_d.ptr();
	const int32_t *in_a = p_prog.in_a.ptr();
	const int32_t *in_b = p_prog.in_b.ptr();
	for (int i = 0; i < p_prog.count; i++) {
		double val = 0.0;
		switch (ops[i]) {
			case GRAPH_OP_NOISE: {
				// amplitude * noise, or a defined 0 when no FastNoiseLite is assigned — mirrors
				// Pasture3DGraphNodeNoise.eval_cell, which returns 0 for a null noise rather than inventing.
				const Ref<FastNoiseLite> &nz = p_prog.noise[i];
				val = nz.is_valid() ? (double)params[i] * (double)nz->get_noise_2d(p_wx, p_wz) : 0.0;
			} break;
			case GRAPH_OP_CONST:
				val = (double)params[i];
				break;
			case GRAPH_OP_BLEND: {
				// An unwired port reads 0, exactly as _cell_value passes 0 for a -1 source.
				const double a = in_a[i] >= 0 ? r_scratch[in_a[i]] : 0.0;
				const double b = in_b[i] >= 0 ? r_scratch[in_b[i]] : 0.0;
				switch ((int)params[i]) {
					case GRAPH_BLEND_ADD: val = a + b; break;
					case GRAPH_BLEND_SUB: val = a - b; break;
					case GRAPH_BLEND_MUL: val = a * b; break;
					case GRAPH_BLEND_MAX: val = a > b ? a : b; break;
					case GRAPH_BLEND_MIN: val = a < b ? a : b; break;
					default: val = a; break; // matches the GDScript fallthrough `return a`
				}
			} break;
			case GRAPH_OP_TERRACE: {
				const double x = in_a[i] >= 0 ? r_scratch[in_a[i]] : 0.0;
				if (std::isnan(x)) {
					val = x;
				} else {
					const double band_height = params[i] > 0.001f ? (double)params[i] : 0.001;
					const double hardness = params_b ? (double)params_b[i] : 0.8;
					const double amount = params_c ? (double)params_c[i] : 1.0;
					const double jitter = params_d ? (double)params_d[i] : 0.0;
					const Ref<FastNoiseLite> &j_nz = p_prog.noise[i];
					double xj = x;
					if (jitter > 0.0 && j_nz.is_valid()) {
						xj += (double)j_nz->get_noise_2d(p_wx, p_wz) * jitter;
					}
					const double t = xj / band_height;
					const double q = std::floor(t);
					const double f = t - q;
					const double stepped = (q + std::pow(f, 1.0 + hardness * 15.0)) * band_height;
					val = x + (stepped - x) * amount;
				}
			} break;
			default:
				val = 0.0;
				break;
		}
		r_scratch[i] = val;
	}
	return r_scratch[p_prog.output];
}

void graph_cell_to_world(int p_ix, int p_iz, int p_gw, int p_gh, const Rect2 &p_rect,
		double &r_wx, double &r_wz) {
	// maxi(gw, 1): a zero-width grid still divides by 1 rather than by 0, matching cell_to_world.
	const double dx = (double)p_rect.size.x / (double)(p_gw < 1 ? 1 : p_gw);
	const double dz = (double)p_rect.size.y / (double)(p_gh < 1 ? 1 : p_gh);
	r_wx = (double)p_rect.position.x + ((double)p_ix + 0.5) * dx;
	r_wz = (double)p_rect.position.y + ((double)p_iz + 0.5) * dz;
}

void graph_nan_blur(std::vector<float> &r_vals, int p_gw, int p_gh, int p_passes) {
	if (p_passes <= 0) {
		return;
	}
	std::vector<float> tmp((size_t)p_gw * p_gh);
	for (int pass = 0; pass < p_passes; pass++) {
		// Horizontal: vals -> tmp
		Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
			for (int iz = z0; iz < z1; iz++) {
				const int row = iz * p_gw;
				for (int ix = 0; ix < p_gw; ix++) {
					const float v = r_vals[row + ix];
					if (std::isnan(v)) { tmp[row + ix] = (float)NAN; continue; }
					float sum = 0.5f * v, weight = 0.5f;
					if (ix > 0 && !std::isnan(r_vals[row + ix - 1])) { sum += 0.25f * r_vals[row + ix - 1]; weight += 0.25f; }
					if (ix < p_gw - 1 && !std::isnan(r_vals[row + ix + 1])) { sum += 0.25f * r_vals[row + ix + 1]; weight += 0.25f; }
					tmp[row + ix] = sum / weight;
				}
			}
		});
		// Vertical: tmp -> vals
		Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
			for (int iz = z0; iz < z1; iz++) {
				const int row = iz * p_gw;
				for (int ix = 0; ix < p_gw; ix++) {
					const float v = tmp[row + ix];
					if (std::isnan(v)) { r_vals[row + ix] = (float)NAN; continue; }
					float sum = 0.5f * v, weight = 0.5f;
					if (iz > 0 && !std::isnan(tmp[(iz - 1) * p_gw + ix])) { sum += 0.25f * tmp[(iz - 1) * p_gw + ix]; weight += 0.25f; }
					if (iz < p_gh - 1 && !std::isnan(tmp[(iz + 1) * p_gw + ix])) { sum += 0.25f * tmp[(iz + 1) * p_gw + ix]; weight += 0.25f; }
					r_vals[row + ix] = sum / weight;
				}
			}
		});
	}
}

bool graph_build(const Dictionary &p_prog, GraphProgram &r_out) {
	r_out = GraphProgram();
	if (!p_prog.has("ops") || !p_prog.has("params") || !p_prog.has("in0") ||
			!p_prog.has("in1") || !p_prog.has("noise") || !p_prog.has("output")) {
		return false;
	}
	r_out.ops = p_prog["ops"];
	r_out.params = p_prog["params"];
	if (p_prog.has("params_b")) r_out.params_b = p_prog["params_b"];
	if (p_prog.has("params_c")) r_out.params_c = p_prog["params_c"];
	if (p_prog.has("params_d")) r_out.params_d = p_prog["params_d"];
	if (p_prog.has("params_e")) r_out.params_e = p_prog["params_e"];
	if (p_prog.has("params_f")) r_out.params_f = p_prog["params_f"];
	if (p_prog.has("params_g")) r_out.params_g = p_prog["params_g"];
	if (p_prog.has("params_h")) r_out.params_h = p_prog["params_h"];
	if (p_prog.has("params_i")) r_out.params_i = p_prog["params_i"];
	if (p_prog.has("params_j")) r_out.params_j = p_prog["params_j"];
	if (p_prog.has("params_k")) r_out.params_k = p_prog["params_k"];
	if (p_prog.has("params_m")) r_out.params_m = p_prog["params_m"];
	if (p_prog.has("params_n")) r_out.params_n = p_prog["params_n"];
	if (p_prog.has("params_o")) r_out.params_o = p_prog["params_o"];
	if (p_prog.has("params_p")) r_out.params_p = p_prog["params_p"];
	if (p_prog.has("params_l")) r_out.params_l = p_prog["params_l"];
	r_out.in0 = p_prog["in0"];
	r_out.in1 = p_prog["in1"];
	if (p_prog.has("in2")) r_out.in2 = p_prog["in2"];
	if (p_prog.has("in3")) r_out.in3 = p_prog["in3"];
	r_out.output = (int)p_prog["output"];
	const int n = r_out.ops.size();
	const Array noise_in = p_prog["noise"];
	if (r_out.params.size() != n || r_out.in0.size() != n || r_out.in1.size() != n || noise_in.size() != n) {
		r_out = GraphProgram();
		return false;
	}
	r_out.noise.resize(n);
	for (int i = 0; i < n; i++) {
		r_out.noise[i] = Ref<FastNoiseLite>(noise_in[i]);
	}
	if (p_prog.has("luts")) {
		const Array luts_in = p_prog["luts"];
		r_out.luts.resize(n);
		for (int i = 0; i < std::min((int)luts_in.size(), n); i++) {
			r_out.luts[i] = luts_in[i];
		}
	}
	r_out.count = n;
	if (r_out.is_empty()) {
		r_out = GraphProgram();
		return false;
	}
	return true;
}

// Core whole-graph evaluation: runs the SSA program into a scratch-buffer arena and leaves the live
// buffers in r_pool / r_slot_buffer so the caller can copy out any protected slot. Slots in
// p_extra_protect get the same recycle-protection the output slot gets (an extra ref count that never
// reaches zero), so a multi-tap caller can read several intermediate buffers from one pass. File-local;
// the public graph_eval_grid / graph_eval_grid_taps wrappers own the copy-out.
static void graph_eval_grid_core(const GraphProgram &p_prog, int p_gw, int p_gh, const Rect2 &p_rect,
		const PackedFloat32Array &p_input, const std::vector<int> &p_extra_protect,
		std::vector<std::vector<float>> &r_pool, std::vector<int> &r_slot_buffer) {
	const int n = (p_gw > 0 ? p_gw : 0) * (p_gh > 0 ? p_gh : 0);
	r_pool.clear();
	r_slot_buffer.clear();
	if (n == 0 || p_prog.is_empty()) {
		return;
	}
	const bool have_input = p_input.size() == n;
	const int32_t *ops = p_prog.ops.ptr();
	const float *params = p_prog.params.ptr();
	const float *params_b = p_prog.params_b.ptr();
	const float *params_c = p_prog.params_c.ptr();
	const float *params_d = p_prog.params_d.ptr();
	const float *params_e = p_prog.params_e.ptr();
	const float *params_f = p_prog.params_f.ptr();
	const float *params_g = p_prog.params_g.ptr();
	const float *params_h = p_prog.params_h.ptr();
	const float *params_i = p_prog.params_i.ptr();
	const float *params_j = p_prog.params_j.ptr();
	const float *params_k = p_prog.params_k.ptr();
	const float *params_l = p_prog.params_l.ptr();
	const float *params_m = p_prog.params_m.size() == p_prog.count ? p_prog.params_m.ptr() : nullptr;
	const float *params_n = p_prog.params_n.size() == p_prog.count ? p_prog.params_n.ptr() : nullptr;
	const float *params_o = p_prog.params_o.size() == p_prog.count ? p_prog.params_o.ptr() : nullptr;
	const float *params_p = p_prog.params_p.size() == p_prog.count ? p_prog.params_p.ptr() : nullptr;
	const int32_t *in0 = p_prog.in0.ptr();
	const int32_t *in1 = p_prog.in1.ptr();
	const int32_t *in2 = p_prog.in2.size() == p_prog.count ? p_prog.in2.ptr() : nullptr;
	const int32_t *in3 = p_prog.in3.size() == p_prog.count ? p_prog.in3.ptr() : nullptr;

	// 1. Reference count consumers for each slot (Scratch Arena Liveness analysis)
	std::vector<int> ref_counts(p_prog.count, 0);
	for (int s = 0; s < p_prog.count; s++) {
		if (in0[s] >= 0 && in0[s] < p_prog.count) ref_counts[in0[s]]++;
		if (in1[s] >= 0 && in1[s] < p_prog.count) ref_counts[in1[s]]++;
		if (in2 && in2[s] >= 0 && in2[s] < p_prog.count) ref_counts[in2[s]]++;
		if (in3 && in3[s] >= 0 && in3[s] < p_prog.count) ref_counts[in3[s]]++;
	}
	if (p_prog.output >= 0 && p_prog.output < p_prog.count) {
		ref_counts[p_prog.output]++; // protect final output buffer
	}
	for (size_t pi = 0; pi < p_extra_protect.size(); pi++) {
		const int slot = p_extra_protect[pi];
		if (slot >= 0 && slot < p_prog.count) {
			ref_counts[slot]++; // protect a tapped preview buffer from recycling
		}
	}

	// 2. Scratch Buffer Pool (owned by the caller so tapped buffers survive the return)
	std::vector<std::vector<float>> &pool = r_pool;
	std::vector<int> free_buffers;
	r_slot_buffer.assign(p_prog.count, -1);
	std::vector<int> &slot_buffer = r_slot_buffer;

	auto acquire_buffer = [&]() -> int {
		if (!free_buffers.empty()) {
			int idx = free_buffers.back();
			free_buffers.pop_back();
			return idx;
		}
		int idx = (int)pool.size();
		pool.emplace_back((size_t)n, 0.f);
		return idx;
	};

	auto release_consumer = [&](int src_slot) {
		if (src_slot >= 0 && src_slot < p_prog.count) {
			ref_counts[src_slot]--;
			if (ref_counts[src_slot] == 0 && src_slot != p_prog.output) {
				int b_idx = slot_buffer[src_slot];
				if (b_idx >= 0) {
					free_buffers.push_back(b_idx);
				}
			}
		}
	};

	auto get_grid_packed = [&](int src_slot) -> PackedFloat32Array {
		PackedFloat32Array arr;
		arr.resize(n);
		float *w = arr.ptrw();
		if (src_slot >= 0 && src_slot < p_prog.count && slot_buffer[src_slot] >= 0) {
			const float *src = pool[slot_buffer[src_slot]].data();
			for (int i = 0; i < n; i++) w[i] = src[i];
		} else {
			for (int i = 0; i < n; i++) w[i] = 0.f;
		}
		return arr;
	};

	// 3. Sequential evaluation of nodes in topological order
	for (int s = 0; s < p_prog.count; s++) {
		int out_b = acquire_buffer();
		slot_buffer[s] = out_b;
		float *g_ptr = pool[out_b].data();

		switch (ops[s]) {
			case GRAPH_OP_INPUT: {
				if (have_input) {
					const float *src = p_input.ptr();
					for (int i = 0; i < n; i++) g_ptr[i] = src[i];
				} else {
					std::fill_n(g_ptr, n, 0.f);
				}
			} break;

			case GRAPH_OP_NOISE: {
				const Ref<FastNoiseLite> &nz = p_prog.noise[s];
				if (nz.is_valid()) {
					const double amp = (double)params[s];
					Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
						for (int iz = z0; iz < z1; iz++) {
							const int row = iz * p_gw;
							for (int ix = 0; ix < p_gw; ix++) {
								double wx, wz;
								graph_cell_to_world(ix, iz, p_gw, p_gh, p_rect, wx, wz);
								g_ptr[row + ix] = (float)(amp * (double)nz->get_noise_2d(wx, wz));
							}
						}
					});
				} else {
					std::fill_n(g_ptr, n, 0.f);
				}
			} break;

			case GRAPH_OP_CONST: {
				std::fill_n(g_ptr, n, params[s]);
			} break;

			case GRAPH_OP_BLEND: {
				const float *ga = (in0[s] >= 0 && slot_buffer[in0[s]] >= 0) ? pool[slot_buffer[in0[s]]].data() : nullptr;
				const float *gb = (in1[s] >= 0 && slot_buffer[in1[s]] >= 0) ? pool[slot_buffer[in1[s]]].data() : nullptr;
				const float *gc = (in2 && in2[s] >= 0 && slot_buffer[in2[s]] >= 0) ? pool[slot_buffer[in2[s]]].data() : nullptr;
				const int mode = (int)params[s];
				Pasture3DThreadPool::parallel_for_elements(n, 1024, [&](int i0, int i1) {
					for (int i = i0; i < i1; i++) {
						const double a = ga ? (double)ga[i] : 0.0;
						const double b = gb ? (double)gb[i] : 0.0;
						double val;
						switch (mode) {
							case GRAPH_BLEND_ADD: val = a + b; break;
							case GRAPH_BLEND_SUB: val = a - b; break;
							case GRAPH_BLEND_MUL: val = a * b; break;
							case GRAPH_BLEND_MAX: val = a > b ? a : b; break;
							case GRAPH_BLEND_MIN: val = a < b ? a : b; break;
							default: val = a; break;
						}
						if (gc) {
							const double mask_val = std::clamp((double)gc[i], 0.0, 1.0);
							val = a + (val - a) * mask_val;
						}
						g_ptr[i] = (float)val;
					}
				});
			} break;

			case GRAPH_OP_TERRACE: {
				const float *src = (in0[s] >= 0 && slot_buffer[in0[s]] >= 0) ? pool[slot_buffer[in0[s]]].data() : nullptr;
				const float band_height = params[s] > 0.001f ? params[s] : 0.001f;
				const float hardness = params_b ? params_b[s] : 0.8f;
				const float amount = params_c ? params_c[s] : 1.0f;
				const float jitter = params_d ? params_d[s] : 0.0f;
				const Ref<FastNoiseLite> &j_nz = p_prog.noise[s];
				const double hard_exp = 1.0 + (double)hardness * 15.0;

				Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
					for (int iz = z0; iz < z1; iz++) {
						const int row = iz * p_gw;
						for (int ix = 0; ix < p_gw; ix++) {
							const int idx = row + ix;
							const float x = src ? src[idx] : 0.f;
							if (std::isnan(x)) {
								g_ptr[idx] = x;
								continue;
							}
							double xj = (double)x;
							if (jitter > 0.0f && j_nz.is_valid()) {
								double wx, wz;
								graph_cell_to_world(ix, iz, p_gw, p_gh, p_rect, wx, wz);
								xj += (double)j_nz->get_noise_2d(wx, wz) * (double)jitter;
							}
							const double t = xj / (double)band_height;
							const double q = std::floor(t);
							const double f = t - q;
							const double stepped = (q + std::pow(f, hard_exp)) * (double)band_height;
							g_ptr[idx] = (float)((double)x + (stepped - (double)x) * (double)amount);
						}
					}
				});
			} break;

			case GRAPH_OP_SMOOTH: {
				if (in0[s] >= 0 && slot_buffer[in0[s]] >= 0) {
					const float *src = pool[slot_buffer[in0[s]]].data();
					std::copy_n(src, n, g_ptr);
				} else {
					std::fill_n(g_ptr, n, 0.f);
				}
				std::vector<float> tmp_v(g_ptr, g_ptr + n);
				graph_nan_blur(tmp_v, p_gw, p_gh, (int)params[s]);
				std::copy(tmp_v.begin(), tmp_v.end(), g_ptr);
			} break;

			case GRAPH_OP_OUTPUT: {
				if (in0[s] >= 0 && slot_buffer[in0[s]] >= 0) {
					const float *src = pool[slot_buffer[in0[s]]].data();
					std::copy_n(src, n, g_ptr);
				} else {
					std::fill_n(g_ptr, n, 0.f);
				}
			} break;

			case GRAPH_OP_NOISE_JORDAN: {
				PackedFloat32Array res = noise_jordan_grid(p_gw, p_gh, p_rect, params[s], params_b[s], (int)params_c[s], params_d[s], params_e[s], params_f[s], params_g[s], (int)params_h[s]);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_NOISE_SWISS: {
				PackedFloat32Array res = noise_swiss_grid(p_gw, p_gh, p_rect, params[s], params_b[s], (int)params_c[s], params_d[s], params_e[s], params_f[s], params_g[s], (int)params_h[s]);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_GEOLOGICAL_PRIMITIVE: {
				Vector2 offset(params_j ? params_j[s] : 0.f, params_k ? params_k[s] : 0.f);
				PackedFloat32Array res = geological_primitive_grid(p_gw, p_gh, p_rect, (int)params[s], (int)params_b[s], params_c[s], params_d[s], params_e[s], params_f[s], params_g[s], offset);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_FURROWS: {
				PackedFloat32Array res = furrows_grid(p_gw, p_gh, p_rect, params[s], params_b[s], params_c[s], (int)params_d[s], params_e[s], params_f[s], (int)params_g[s]);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_DUNES: {
				PackedFloat32Array res = dunes_grid(p_gw, p_gh, p_rect, params[s], params_b[s], params_c[s], params_d[s], params_e[s], params_f[s], params_g[s], (int)params_h[s]);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_CRATER: {
				PackedFloat32Array res = crater_grid(p_gw, p_gh, p_rect, params[s], params_b[s], params_c[s], params_d[s], params_e[s], params_f[s], (int)params_g[s]);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_STRATA: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				PackedFloat32Array res = strata_grid(in_arr, p_gw, p_gh, p_rect, params[s], params_b[s], params_c[s], params_d[s], params_e[s], params_f[s], params_g[s], (int)params_h[s]);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_CURVE: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				const PackedFloat32Array &lut = p_prog.luts[s];
				PackedFloat32Array res = curve_grid(in_arr, lut, params[s], params_b[s], params_c[s], params_d[s], params_e[s]);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_REMAP: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				PackedFloat32Array res = remap_grid(in_arr, params[s], params_b[s], params_c[s], params_d[s], params_e[s] > 0.5f, params_f[s], params_g[s] > 0.5f);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_FALLOFF: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				// in1 is the optional distance-perturbation grid; an unwired port passes an empty array,
				// which falloff_grid reads as "no perturbation" rather than as zeros.
				PackedFloat32Array nz_arr = (in1[s] >= 0) ? get_grid_packed(in1[s]) : PackedFloat32Array();
				PackedFloat32Array res = falloff_grid(in_arr, nz_arr, p_gw, p_gh, p_rect, (int)params[s],
						params_b[s], params_c[s], params_d[s], params_e[s], params_f[s],
						params_g[s] > 0.5f, params_h[s]);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_CONTRAST: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				PackedFloat32Array msk_arr = (in1[s] >= 0) ? get_grid_packed(in1[s]) : PackedFloat32Array();
				PackedFloat32Array res = contrast_grid(in_arr, msk_arr, (int)params[s], params_b[s],
						params_c[s], params_d[s], params_e[s]);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_TRANSFORM: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				PackedFloat32Array res = transform_solve(in_arr, p_gw, p_gh, p_rect,
						Vector2((float)params[s], (float)params_b[s]), params_c[s], params_d[s],
						Vector2((float)params_e[s], (float)params_f[s]), (int)params_g[s], params_h[s]);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_DISTANCE_TRANSFORM: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				// The divisor is discarded on this path. The node computes it again on the GDScript side
				// so it can be stored and shown; recomputing is cheap next to the JFA itself, and the
				// alternative is threading an out-parameter through the whole program struct.
				double divisor = 1.0;
				PackedFloat32Array res = distance_transform_solve(in_arr, p_gw, p_gh, p_rect,
						params[s], (int)params_b[s], (int)params_c[s], (int)params_d[s], params_e[s],
						&divisor);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_EXPAND_SHRINK: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				PackedFloat32Array msk_arr = (in1[s] >= 0) ? get_grid_packed(in1[s]) : PackedFloat32Array();
				PackedFloat32Array res = expand_shrink_solve(in_arr, msk_arr, p_gw, p_gh, p_rect,
						(int)params[s], params_b[s], (int)params_c[s], (int)params_d[s], params_e[s]);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_RELATIVE_ELEVATION: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				PackedFloat32Array res = relative_elevation_solve(in_arr, p_gw, p_gh, p_rect,
						params[s], (int)params_b[s]);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_SMOOTH_FILL: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				PackedFloat32Array msk_arr = (in1[s] >= 0) ? get_grid_packed(in1[s]) : PackedFloat32Array();
				// The deposition channel is dropped here. This evaluator produces ONE grid per slot; a
				// graph that wires the deposition port is routed to the multi-channel path instead, so
				// nothing is lost by not computing it.
				PackedFloat32Array res = smooth_fill_solve(in_arr, msk_arr, p_gw, p_gh, p_rect,
						(int)params[s], params_b[s], params_c[s], params_d[s], nullptr, nullptr);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_RECAST_CLIFF: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				PackedFloat32Array msk_arr = (in1[s] >= 0) ? get_grid_packed(in1[s]) : PackedFloat32Array();
				PackedFloat32Array res = recast_cliff_solve(in_arr, msk_arr, p_gw, p_gh, p_rect,
						params[s], params_b[s], params_c[s], params_d[s], params_e[s], params_f[s],
						params_g[s]);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_MASK: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				PackedFloat32Array res = mask_grid(in_arr, p_gw, p_gh, p_rect, (int)params[s], params_b[s], params_c[s], params_d[s], params_e[s], params_f[s] > 0.5f, params_g[s]);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_WARP: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				PackedFloat32Array res = warp_solve_grid(in_arr, p_gw, p_gh, p_rect, (WarpNoiseType)(int)params[s], params_b[s], params_c[s], (int)params_d[s], params_e[s], params_f[s], (int)params_g[s]);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_CURVATURE: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				PackedFloat32Array res = curvature_solve(in_arr, p_gw, p_gh, (CurvatureMode)(int)params[s], (int)params_b[s], params_c[s]);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_TALUS_PROJECTION: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				PackedFloat32Array in_mask = get_grid_packed(in1[s]);
				PackedFloat32Array res = talus_projection_solve(in_arr, in_mask, p_gw, p_gh, p_rect, params[s], (int)params_b[s], params_c[s], params_d[s]);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_SPECTRAL_EQUALIZER: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				PackedFloat32Array in_mask = get_grid_packed(in1[s]);
				PackedFloat32Array res = spectral_equalizer_solve(in_arr, in_mask, p_gw, p_gh, params[s], params_b[s], params_c[s], (int)params_d[s], (int)params_e[s], params_f[s]);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_DEPRESSION_FILLING: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				PackedFloat32Array res = depression_filling_solve(in_arr, p_gw, p_gh, p_rect, params[s], params_b[s], params_c[s]);
				if (res.size() == n) std::copy_n(res.ptr(), n, g_ptr);
			} break;

			case GRAPH_OP_LAKE_FLOODING: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				LakeFloodingResult res = lake_flooding_solve(in_arr, p_gw, p_gh, p_rect, (LakeFloodMode)(int)params[s], params_b[s], params_c[s], params_d[s]);
				if (res.ok && res.height.size() == n) {
					std::copy_n(res.height.ptr(), n, g_ptr);
				}
			} break;

			case GRAPH_OP_STREAM_EXTRACTION: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				StreamExtractionResult res = stream_extraction_solve(in_arr, p_gw, p_gh, p_rect, params[s], params_b[s], params_c[s], params_d[s]);
				if (res.ok && res.height.size() == n) {
					std::copy_n(res.height.ptr(), n, g_ptr);
				}
			} break;

			case GRAPH_OP_EROSION_HYDRAULIC: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				ErosionHydraulicParams p;
				p.iterations = (int)params[s];
				p.rain_rate = params_b[s];
				p.evaporation_rate = params_c[s];
				p.sediment_capacity = params_d[s];
				p.erosion_speed = params_e[s];
				p.deposition_speed = params_f[s];
				p.min_slope = params_g ? params_g[s] : 0.01f;
				ErosionHydraulicResult res = erosion_hydraulic_solve_best(in_arr, p_gw, p_gh, p_rect, p);
				if (res.ok && res.height.size() == n) {
					std::copy_n(res.height.ptr(), n, g_ptr);
				}
			} break;

			case GRAPH_OP_EROSION_THERMAL: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				PackedFloat32Array in_hard = get_grid_packed(in1[s]);
				ErosionThermalResult res = erosion_thermal_solve(in_arr, in_hard, p_gw, p_gh, p_rect, params[s], (int)params_b[s], params_c[s]);
				if (res.ok && res.height.size() == n) {
					std::copy_n(res.height.ptr(), n, g_ptr);
				}
			} break;

			case GRAPH_OP_SCREE: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				Array res = scree_solve_grid(in_arr, p_gw, p_gh, p_rect, params[s], params_b[s], params_c[s], params_d[s], params_e[s], params_f[s], (int)params_g[s]);
				if (res.size() > 0) {
					PackedFloat32Array h = res[0];
					if (h.size() == n) std::copy_n(h.ptr(), n, g_ptr);
				}
			} break;

			case GRAPH_OP_EROSION: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				PackedFloat32Array in_erod = get_grid_packed(in1[s]);
				ErosionParams p;
				p.gw = p_gw;
				p.gh = p_gh;
				p.cell_size = (double)p_rect.size.x / (double)std::max(p_gw, 1);
				p.iterations = (int)params[s];
				p.erosion_rate = params_b[s];
				p.area_exponent = params_c[s];
				p.diffusion = params_d[s];
				p.deposition = params_e[s];
				std::vector<float> z_in(in_arr.ptr(), in_arr.ptr() + n);
				ErosionResult res = erosion_solve(z_in, p, in_erod);
				if (res.ok && (int)res.z.size() == n) {
					std::copy(res.z.begin(), res.z.end(), g_ptr);
				}
			} break;

			case GRAPH_OP_HYDRAULIC_PARTICLE: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				HydraulicParticleParams p;
				p.droplet_count = (int)params[s];
				p.max_lifetime = (int)params_b[s];
				p.inertia = params_c[s];
				p.sediment_capacity = params_d[s];
				p.erosion_speed = params_e[s];
				p.deposition_speed = params_f[s];
				p.evaporation_rate = params_g ? params_g[s] : 0.01f;
				p.min_slope = params_h ? params_h[s] : 0.01f;
				p.gravity = params_i ? params_i[s] : 4.0f;
				p.seed = params_j ? (int64_t)params_j[s] : 1337;
				p.bedrock_gap = params_k ? params_k[s] : 2.0f;
				p.ridge_forcing = params_l ? params_l[s] : 0.0f;
				if (in1 && in1[s] >= 0) {
					p.mask = get_grid_packed(in1[s]);
				}
				HydraulicParticleResult res = hydraulic_particle_solve(in_arr, p_gw, p_gh, p_rect, p);
				if (res.ok && res.height.size() == n) {
					std::copy_n(res.height.ptr(), n, g_ptr);
				}
			} break;

			case GRAPH_OP_HYDRAULIC_STREAM_LOG: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				HydraulicStreamLogParams p;
				p.iterations = (int)params[s];
				p.incision_rate = params_b[s];
				p.area_exponent = params_c[s];
				p.slope_exponent = params_d[s];
				p.min_catchment = params_e[s];
				p.bank_smoothing = params_f[s];
				p.peak_preservation = params_g ? params_g[s] : 0.5f;
				p.gradient_power = params_h ? params_h[s] : 0.8f;
				if (in1 && in1[s] >= 0) {
					p.mask = get_grid_packed(in1[s]);
				}
				HydraulicStreamLogResult res = hydraulic_stream_log_solve(in_arr, p_gw, p_gh, p_rect, p);
				if (res.ok && res.height.size() == n) {
					std::copy_n(res.height.ptr(), n, g_ptr);
				}
			} break;

			case GRAPH_OP_HYDRAULIC_SALEVE: {
				PackedFloat32Array in_arr = get_grid_packed(in0[s]);
				HydraulicSaleveParams p;
				p.iterations = (int)params[s];
				p.erosion_strength = params_b[s];
				p.drainage_exponent = params_c[s];
				p.drainage_noise = params_d[s];
				p.shape_preservation = params_e[s];
				p.bank_smoothing = params_f[s];
				p.deposition_radius = params_g ? params_g[s] : 25.0f;
				p.reference_relief = params_p ? std::max(0.0f, params_p[s]) : 0.0f;
				p.deposition_strength = params_h ? params_h[s] : 0.5f;
				p.stream_strength = params_i ? params_i[s] : 0.02f;
				p.stream_exp = params_j ? params_j[s] : 0.8f;
				p.gain = params_k ? params_k[s] : 1.0f;
				p.gamma = params_l ? params_l[s] : 1.0f;
				p.mix_factor = params_m ? params_m[s] : 1.0f;
				p.seed = params_n ? (int)params_n[s] : 0;
				p.enable_post_smoothing = params_o ? (params_o[s] > 0.5f) : false;
				if (in1 && in1[s] >= 0) {
					p.dx = get_grid_packed(in1[s]);
				}
				if (in2 && in2[s] >= 0) {
					p.dy = get_grid_packed(in2[s]);
				}
				if (in3 && in3[s] >= 0) {
					p.mask = get_grid_packed(in3[s]);
				}
				HydraulicSaleveResult res = hydraulic_saleve_solve(in_arr, p_gw, p_gh, p_rect, p);
				if (res.ok && res.height.size() == n) {
					std::copy_n(res.height.ptr(), n, g_ptr);
				}
			} break;

			case GRAPH_OP_MOUNTAIN_CONE: {
				MountainConeParams p;
				p.seed = (int)params[s];
				p.elevation = params_b[s];
				p.scale = params_c[s];
				p.octaves = (int)params_d[s];
				p.peak_kw = params_e[s];
				p.rugosity = params_f[s];
				p.angle = params_g ? params_g[s] : 45.0f;
				p.gamma = params_h ? params_h[s] : 0.5f;
				p.cone_alpha = params_i ? params_i[s] : 1.2f;
				p.ridge_amp = params_j ? params_j[s] : 0.4f;
				p.base_noise_amp = params_k ? params_k[s] : 0.05f;
				if (in0[s] >= 0) p.dx = get_grid_packed(in0[s]);
				if (in1 && in1[s] >= 0) p.dy = get_grid_packed(in1[s]);
				if (in2 && in2[s] >= 0) p.envelope = get_grid_packed(in2[s]);
				PackedFloat32Array res = mountain_cone_solve_best(p_gw, p_gh, p_rect, p);
				if (res.size() == n) {
					std::copy_n(res.ptr(), n, g_ptr);
				}
			} break;

			case GRAPH_OP_MOUNTAIN_INSELBERG: {
				MountainInselbergParams p;
				p.seed = (int)params[s];
				p.elevation = params_b[s];
				p.scale = params_c[s];
				p.octaves = (int)params_d[s];
				p.rugosity = params_e[s];
				p.angle = params_f[s];
				p.gamma = params_g ? params_g[s] : 0.5f;
				p.bulk_amp = params_h ? params_h[s] : 0.5f;
				p.base_noise_amp = params_i ? params_i[s] : 0.05f;
				if (in0[s] >= 0) p.dx = get_grid_packed(in0[s]);
				if (in1 && in1[s] >= 0) p.dy = get_grid_packed(in1[s]);
				PackedFloat32Array res = mountain_inselberg_solve_best(p_gw, p_gh, p_rect, p);
				if (res.size() == n) {
					std::copy_n(res.ptr(), n, g_ptr);
				}
			} break;

			case GRAPH_OP_MOUNTAIN_RANGE_RADIAL: {
				MountainRangeRadialParams p;
				p.seed = (int)params[s];
				p.elevation = params_b[s];
				p.kw_x = params_c[s];
				p.kw_y = params_d[s];
				p.half_width = params_e[s];
				p.angle_spread_ratio = params_f[s];
				p.core_size_ratio = params_g ? params_g[s] : 0.2f;
				p.octaves = params_h ? (int)params_h[s] : 8;
				p.weight = params_i ? params_i[s] : 0.7f;
				p.persistence = params_j ? params_j[s] : 0.5f;
				p.lacunarity = params_k ? params_k[s] : 2.0f;
				if (in0[s] >= 0) p.ctrl_param = get_grid_packed(in0[s]);
				if (in1 && in1[s] >= 0) p.dx = get_grid_packed(in1[s]);
				if (in2 && in2[s] >= 0) p.dy = get_grid_packed(in2[s]);
				Array res = mountain_range_radial_solve_best(p_gw, p_gh, p_rect, p);
				if (res.size() > 0) {
					PackedFloat32Array h = res[0];
					if (h.size() == n) {
						std::copy_n(h.ptr(), n, g_ptr);
					}
				}
			} break;

			case GRAPH_OP_MOUNTAIN_TIBESTI: {
				MountainTibestiParams p;
				p.seed = (int)params[s];
				p.elevation = params_b[s];
				p.scale = params_c[s];
				p.octaves = (int)params_d[s];
				p.peak_kw = params_e[s];
				p.rugosity = params_f[s];
				p.angle = params_g ? params_g[s] : 45.0f;
				p.angle_spread_ratio = params_h ? params_h[s] : 0.5f;
				p.gamma = params_i ? params_i[s] : 0.5f;
				p.bulk_amp = params_j ? params_j[s] : 0.5f;
				p.base_noise_amp = params_k ? params_k[s] : 0.05f;
				if (in0[s] >= 0) p.dx = get_grid_packed(in0[s]);
				if (in1 && in1[s] >= 0) p.dy = get_grid_packed(in1[s]);
				PackedFloat32Array res = mountain_tibesti_solve_best(p_gw, p_gh, p_rect, p);
				if (res.size() == n) {
					std::copy_n(res.ptr(), n, g_ptr);
				}
			} break;

			case GRAPH_OP_MOUNTAIN_STUMP: {
				MountainStumpParams p;
				p.seed = (int)params[s];
				p.elevation = params_b[s];
				p.scale = params_c[s];
				p.octaves = (int)params_d[s];
				p.peak_kw = params_e[s];
				p.rugosity = params_f[s];
				p.angle = params_g ? params_g[s] : 45.0f;
				p.k_smoothing = params_h ? params_h[s] : 0.05f;
				p.gamma = params_i ? params_i[s] : 0.5f;
				p.ridge_amp = params_j ? params_j[s] : 0.4f;
				p.base_noise_amp = params_k ? params_k[s] : 0.05f;
				if (in0[s] >= 0) p.dx = get_grid_packed(in0[s]);
				if (in1 && in1[s] >= 0) p.dy = get_grid_packed(in1[s]);
				PackedFloat32Array res = mountain_stump_solve_best(p_gw, p_gh, p_rect, p);
				if (res.size() == n) {
					std::copy_n(res.ptr(), n, g_ptr);
				}
			} break;

			case GRAPH_OP_SHATTERED_PEAK: {
				ShatteredPeakParams p;
				p.seed = (int)params[s];
				p.elevation = params_b[s];
				p.scale = params_c[s];
				p.octaves = (int)params_d[s];
				p.peak_kw = params_e[s];
				p.rugosity = params_f[s];
				p.angle = params_g ? params_g[s] : 45.0f;
				p.gamma = params_h ? params_h[s] : 0.5f;
				p.bulk_amp = params_i ? params_i[s] : 0.5f;
				p.base_noise_amp = params_j ? params_j[s] : 0.05f;
				p.k_smoothing = params_k ? params_k[s] : 0.05f;
				if (in0[s] >= 0) p.dx = get_grid_packed(in0[s]);
				if (in1 && in1[s] >= 0) p.dy = get_grid_packed(in1[s]);
				PackedFloat32Array res = shattered_peak_solve_best(p_gw, p_gh, p_rect, p);
				if (res.size() == n) {
					std::copy_n(res.ptr(), n, g_ptr);
				}
			} break;

			case GRAPH_OP_CALDERA: {
				CalderaParams p;
				p.elevation = params[s];
				p.radius = params_b[s];
				p.sigma_inner = params_c[s];
				p.sigma_outer = params_d[s];
				p.z_bottom = params_e[s];
				p.noise_r_amp = params_f[s];
				p.noise_z_ratio = params_g ? params_g[s] : 0.05f;
				if (in0[s] >= 0) p.noise = get_grid_packed(in0[s]);
				PackedFloat32Array res = caldera_solve_best(p_gw, p_gh, p_rect, p);
				if (res.size() == n) {
					std::copy_n(res.ptr(), n, g_ptr);
				}
			} break;

			default:
				std::fill_n(g_ptr, n, 0.f);
				break;
		}

		// 4. Release consumer references and recycle dead buffers
		release_consumer(in0[s]);
		release_consumer(in1[s]);
		if (in2) release_consumer(in2[s]);
	}

}

PackedFloat32Array graph_eval_grid(const GraphProgram &p_prog, int p_gw, int p_gh, const Rect2 &p_rect,
		const PackedFloat32Array &p_input) {
	const int n = (p_gw > 0 ? p_gw : 0) * (p_gh > 0 ? p_gh : 0);
	PackedFloat32Array out;
	out.resize(n);
	{
		float *w = out.ptrw();
		for (int i = 0; i < n; i++) {
			w[i] = 0.f;
		}
	}
	if (n == 0 || p_prog.is_empty()) {
		return out;
	}
	std::vector<std::vector<float>> pool;
	std::vector<int> slot_buffer;
	graph_eval_grid_core(p_prog, p_gw, p_gh, p_rect, p_input, std::vector<int>(), pool, slot_buffer);
	const int out_slot = p_prog.output;
	if (out_slot >= 0 && out_slot < (int)slot_buffer.size() && slot_buffer[out_slot] >= 0) {
		const float *res = pool[slot_buffer[out_slot]].data();
		float *w = out.ptrw();
		for (int i = 0; i < n; i++) {
			w[i] = res[i];
		}
	}
	return out;
}

// Multi-tap: evaluate once and copy out every slot in p_tap_slots. Returns a Dictionary {slot(int) ->
// PackedFloat32Array}; a slot out of range or with no live buffer yields a zero field of size gw*gh so
// the caller always gets one field per requested tap. Empty when the program is empty or no taps given.
Dictionary graph_eval_grid_taps(const GraphProgram &p_prog, int p_gw, int p_gh, const Rect2 &p_rect,
		const PackedFloat32Array &p_input, const PackedInt32Array &p_tap_slots) {
	Dictionary result;
	const int n = (p_gw > 0 ? p_gw : 0) * (p_gh > 0 ? p_gh : 0);
	const int tap_n = p_tap_slots.size();
	if (n == 0 || p_prog.is_empty() || tap_n == 0) {
		return result;
	}
	std::vector<int> protect;
	protect.reserve(tap_n);
	for (int i = 0; i < tap_n; i++) {
		const int slot = p_tap_slots[i];
		if (slot >= 0 && slot < p_prog.count) {
			protect.push_back(slot);
		}
	}
	std::vector<std::vector<float>> pool;
	std::vector<int> slot_buffer;
	graph_eval_grid_core(p_prog, p_gw, p_gh, p_rect, p_input, protect, pool, slot_buffer);
	for (int i = 0; i < tap_n; i++) {
		const int slot = p_tap_slots[i];
		PackedFloat32Array field;
		field.resize(n);
		float *w = field.ptrw();
		if (slot >= 0 && slot < (int)slot_buffer.size() && slot_buffer[slot] >= 0) {
			const float *src = pool[slot_buffer[slot]].data();
			for (int j = 0; j < n; j++) {
				w[j] = src[j];
			}
		} else {
			for (int j = 0; j < n; j++) {
				w[j] = 0.f;
			}
		}
		result[slot] = field;
	}
	return result;
}

} // namespace godot
