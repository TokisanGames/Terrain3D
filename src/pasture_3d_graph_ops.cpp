#include "pasture_3d_graph_ops.h"
#include "pasture_3d_thread_pool.h"

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
	if (p_prog.has("params_b")) {
		r_out.params_b = p_prog["params_b"];
	}
	if (p_prog.has("params_c")) {
		r_out.params_c = p_prog["params_c"];
	}
	if (p_prog.has("params_d")) {
		r_out.params_d = p_prog["params_d"];
	}
	r_out.in0 = p_prog["in0"];
	r_out.in1 = p_prog["in1"];
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
	r_out.count = n;
	if (r_out.is_empty()) {
		r_out = GraphProgram();
		return false;
	}
	return true;
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
	const bool have_input = p_input.size() == n;
	const int32_t *ops = p_prog.ops.ptr();
	const float *params = p_prog.params.ptr();
	const float *params_b = p_prog.params_b.ptr();
	const float *params_c = p_prog.params_c.ptr();
	const float *params_d = p_prog.params_d.ptr();
	const int32_t *in0 = p_prog.in0.ptr();
	const int32_t *in1 = p_prog.in1.ptr();

	// One materialised grid per slot; a slot's inputs are always earlier slots (topological order).
	std::vector<std::vector<float>> grids(p_prog.count);
	for (int s = 0; s < p_prog.count; s++) {
		std::vector<float> g((size_t)n, 0.f);
		switch (ops[s]) {
			case GRAPH_OP_INPUT: {
				if (have_input) {
					const float *src = p_input.ptr();
					for (int i = 0; i < n; i++) {
						g[i] = src[i];
					}
				}
				// else: a flat 0, matching _surface_grid handing back zeros when no surface was passed.
			} break;
			case GRAPH_OP_NOISE: {
				const Ref<FastNoiseLite> &nz = p_prog.noise[s];
				if (nz.is_valid()) {
					const double amp = (double)params[s];
					float *g_ptr = g.data();
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
				}
			} break;
			case GRAPH_OP_CONST: {
				const float v = params[s];
				std::fill(g.begin(), g.end(), v);
			} break;
			case GRAPH_OP_BLEND: {
				const std::vector<float> *ga = in0[s] >= 0 ? &grids[in0[s]] : nullptr;
				const std::vector<float> *gb = in1[s] >= 0 ? &grids[in1[s]] : nullptr;
				const int mode = (int)params[s];
				float *g_ptr = g.data();
				Pasture3DThreadPool::parallel_for_elements(n, 1024, [&](int i0, int i1) {
					for (int i = i0; i < i1; i++) {
						const double a = ga ? (double)(*ga)[i] : 0.0;
						const double b = gb ? (double)(*gb)[i] : 0.0;
						double val;
						switch (mode) {
							case GRAPH_BLEND_ADD: val = a + b; break;
							case GRAPH_BLEND_SUB: val = a - b; break;
							case GRAPH_BLEND_MUL: val = a * b; break;
							case GRAPH_BLEND_MAX: val = a > b ? a : b; break;
							case GRAPH_BLEND_MIN: val = a < b ? a : b; break;
							default: val = a; break;
						}
						g_ptr[i] = (float)val;
					}
				});
			} break;
			case GRAPH_OP_TERRACE: {
				const std::vector<float> *src = in0[s] >= 0 ? &grids[in0[s]] : nullptr;
				const float band_height = params[s] > 0.001f ? params[s] : 0.001f;
				const float hardness = params_b ? params_b[s] : 0.8f;
				const float amount = params_c ? params_c[s] : 1.0f;
				const float jitter = params_d ? params_d[s] : 0.0f;
				const Ref<FastNoiseLite> &j_nz = p_prog.noise[s];
				const double hard_exp = 1.0 + (double)hardness * 15.0;
				float *g_ptr = g.data();

				Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
					for (int iz = z0; iz < z1; iz++) {
						const int row = iz * p_gw;
						for (int ix = 0; ix < p_gw; ix++) {
							const int idx = row + ix;
							const float x = src ? (*src)[idx] : 0.f;
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
				if (in0[s] >= 0) {
					g = grids[in0[s]]; // duplicate the upstream grid; blur mutates in place
				}
				graph_nan_blur(g, p_gw, p_gh, (int)params[s]);
			} break;
			case GRAPH_OP_OUTPUT: {
				if (in0[s] >= 0) {
					g = grids[in0[s]];
				}
			} break;
			default:
				break; // an unknown op stays a flat 0 (the GDScript compiler refuses to emit one)
		}
		grids[s] = std::move(g);
	}

	const std::vector<float> &res = grids[p_prog.output];
	float *w = out.ptrw();
	for (int i = 0; i < n; i++) {
		w[i] = res[i];
	}
	return out;
}

} // namespace godot
