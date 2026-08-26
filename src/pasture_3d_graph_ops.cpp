// Terrain-graph cell-run evaluator — see pasture_3d_graph_ops.h. The A/B oracle is the GDScript folded
// evaluator (Pasture3DTerrainGraph.evaluate / _cell_value); every op here must agree with it to 1e-4 m,
// which GraphCppParityGate holds them to.

#include "pasture_3d_graph_ops.h"

#include <algorithm>

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
	r_out.in_a = p_prog["in_a"];
	r_out.in_b = p_prog["in_b"];
	r_out.output = (int)p_prog["output"];
	const int n = r_out.ops.size();
	// The five parallel arrays must line up; a program whose columns disagree is malformed, not merely
	// short, so refuse it rather than index off the end of the shortest.
	const Array noise_in = p_prog["noise"];
	if (r_out.params.size() != n || r_out.in_a.size() != n || r_out.in_b.size() != n ||
			noise_in.size() != n) {
		r_out = GraphCellProgram();
		return false;
	}
	r_out.noise.resize(n);
	for (int i = 0; i < n; i++) {
		// A null entry stays an empty Ref; only NOISE slots carry one, and the evaluator reads it only there.
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

} // namespace godot
