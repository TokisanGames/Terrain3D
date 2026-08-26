#include "pasture_3d_graph_gpu.h"

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/rd_shader_source.hpp>
#include <godot_cpp/classes/rd_shader_spirv.hpp>
#include <godot_cpp/classes/rd_uniform.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/memory.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cstring>
#include <vector>

using namespace godot;

// One compute shader, dispatched once per GRID node with a `mode` selecting the op. Reads up to two input
// buffers (A, B) and writes one output buffer (OUT), all std430 float arrays over the gw*gh grid. The
// Smooth / Blend arithmetic and NaN handling are a byte-for-byte port of graph_nan_blur / the BLEND switch
// in graph_eval_grid, so the two paths agree; MAX/MIN use the ternary (not GLSL max/min) to match the CPU's
// `a > b ? a : b` under NaN. Generators (Input/Noise/Const) never reach the shader — they are uploaded.
static const char *GRAPH_GRID_GLSL = R"(#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict writeonly buffer OutBuf { float o[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer ABuf { float a[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer BBuf { float b[]; };

layout(push_constant, std430) uniform Params {
	int mode; // 0 COPY, 1 BLEND, 2 SMOOTH_H, 3 SMOOTH_V
	int gw;
	int gh;
	int ip;   // BLEND: the blend mode 0..4
} p;

void main() {
	int ix = int(gl_GlobalInvocationID.x);
	int iz = int(gl_GlobalInvocationID.y);
	if (ix >= p.gw || iz >= p.gh) { return; }
	int i = iz * p.gw + ix;

	if (p.mode == 0) { // COPY (Output, or a zero-pass Smooth)
		o[i] = a[i];
		return;
	}
	if (p.mode == 1) { // BLEND
		float av = a[i];
		float bv = b[i];
		float r;
		if (p.ip == 0) { r = av + bv; }
		else if (p.ip == 1) { r = av - bv; }
		else if (p.ip == 2) { r = av * bv; }
		else if (p.ip == 3) { r = (av > bv) ? av : bv; }
		else if (p.ip == 4) { r = (av < bv) ? av : bv; }
		else { r = av; }
		o[i] = r;
		return;
	}
	if (p.mode == 2) { // SMOOTH horizontal
		float v = a[i];
		if (isnan(v)) { o[i] = v; return; }
		float s = 0.5 * v;
		float w = 0.5;
		if (ix > 0) { float l = a[i - 1]; if (!isnan(l)) { s += 0.25 * l; w += 0.25; } }
		if (ix < p.gw - 1) { float rr = a[i + 1]; if (!isnan(rr)) { s += 0.25 * rr; w += 0.25; } }
		o[i] = s / w;
		return;
	}
	if (p.mode == 3) { // SMOOTH vertical
		float v = a[i];
		if (isnan(v)) { o[i] = v; return; }
		float s = 0.5 * v;
		float w = 0.5;
		if (iz > 0) { float u = a[i - p.gw]; if (!isnan(u)) { s += 0.25 * u; w += 0.25; } }
		if (iz < p.gh - 1) { float d = a[i + p.gw]; if (!isnan(d)) { s += 0.25 * d; w += 0.25; } }
		o[i] = s / w;
		return;
	}
}
)";

Pasture3DGraphGPU::~Pasture3DGraphGPU() {
	if (_rd) {
		if (_pipeline.is_valid()) {
			_rd->free_rid(_pipeline);
		}
		if (_shader.is_valid()) {
			_rd->free_rid(_shader);
		}
		memdelete(_rd);
		_rd = nullptr;
	}
}

bool Pasture3DGraphGPU::_ensure_init() {
	if (_rd) {
		return true;
	}
	if (_init_failed) {
		return false;
	}
	RenderingServer *rs = RenderingServer::get_singleton();
	if (!rs) {
		_init_failed = true;
		return false;
	}
	_rd = rs->create_local_rendering_device();
	if (!_rd) {
		UtilityFunctions::push_warning("Graph GPU: no local RenderingDevice; falling back to the CPU evaluator.");
		_init_failed = true;
		return false;
	}
	Ref<RDShaderSource> src;
	src.instantiate();
	src->set_stage_source(RenderingDevice::SHADER_STAGE_COMPUTE, String(GRAPH_GRID_GLSL));
	Ref<RDShaderSPIRV> spirv = _rd->shader_compile_spirv_from_source(src);
	if (spirv.is_null() || !spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_COMPUTE).is_empty()) {
		UtilityFunctions::push_warning("Graph GPU: compute shader compile failed; falling back to the CPU evaluator.");
		memdelete(_rd);
		_rd = nullptr;
		_init_failed = true;
		return false;
	}
	_shader = _rd->shader_create_from_spirv(spirv);
	if (!_shader.is_valid()) {
		memdelete(_rd);
		_rd = nullptr;
		_init_failed = true;
		return false;
	}
	_pipeline = _rd->compute_pipeline_create(_shader);
	if (!_pipeline.is_valid()) {
		_rd->free_rid(_shader);
		memdelete(_rd);
		_rd = nullptr;
		_init_failed = true;
		return false;
	}
	return true;
}

bool Pasture3DGraphGPU::available() {
	return _ensure_init();
}

namespace {
// One planned dispatch: write `out`, reading `a` (and `b` for BLEND; `b` is a bound zero buffer otherwise).
struct GraphDispatch {
	RID out;
	RID a;
	RID b;
	int mode = 0;
	int ip = 0;
};
} // namespace

bool Pasture3DGraphGPU::eval_grid(const godot::GraphProgram &p_prog, int p_gw, int p_gh, const Rect2 &p_rect,
		const PackedFloat32Array &p_input, PackedFloat32Array &r_out) {
	if (!_ensure_init()) {
		return false;
	}
	if (p_prog.is_empty() || p_gw < 1 || p_gh < 1) {
		return false;
	}
	const int n = p_gw * p_gh;
	const int bytes = n * (int)sizeof(float);
	const bool have_input = p_input.size() == n;

	std::vector<RID> to_free; // every buffer RID created here, freed on the single exit path
	auto free_bufs = [&]() {
		for (RID rid : to_free) {
			if (rid.is_valid()) {
				_rd->free_rid(rid);
			}
		}
	};
	auto fail = [&]() -> bool {
		free_bufs();
		return false;
	};
	auto buf_from = [&](const void *p_data) -> RID {
		PackedByteArray pb;
		pb.resize(bytes);
		std::memcpy(pb.ptrw(), p_data, bytes);
		RID b = _rd->storage_buffer_create(bytes, pb);
		if (b.is_valid()) {
			to_free.push_back(b);
		}
		return b;
	};
	auto empty_buf = [&]() -> RID {
		PackedByteArray pb;
		pb.resize(bytes); // PackedByteArray::resize zero-fills, so an unwired read is a defined 0
		RID b = _rd->storage_buffer_create(bytes, pb);
		if (b.is_valid()) {
			to_free.push_back(b);
		}
		return b;
	};

	const RID zero_buf = empty_buf(); // bound as B for non-BLEND dispatches, and for an unwired BLEND port
	if (!zero_buf.is_valid()) {
		return fail();
	}

	const int32_t *ops = p_prog.ops.ptr();
	const float *params = p_prog.params.ptr();
	const int32_t *in0 = p_prog.in0.ptr();
	const int32_t *in1 = p_prog.in1.ptr();

	std::vector<RID> slot_buf(p_prog.count); // materialised grid per node
	std::vector<GraphDispatch> plan;

	std::vector<float> host((size_t)n); // scratch for a generator's CPU-computed grid
	for (int s = 0; s < p_prog.count; s++) {
		switch (ops[s]) {
			case GRAPH_OP_INPUT: {
				if (have_input) {
					slot_buf[s] = buf_from(p_input.ptr());
				} else {
					std::fill(host.begin(), host.end(), 0.f);
					slot_buf[s] = buf_from(host.data());
				}
			} break;
			case GRAPH_OP_NOISE: {
				const Ref<FastNoiseLite> &nz = p_prog.noise[s];
				if (nz.is_valid()) {
					const double amp = (double)params[s];
					for (int iz = 0; iz < p_gh; iz++) {
						const int row = iz * p_gw;
						for (int ix = 0; ix < p_gw; ix++) {
							double wx, wz;
							graph_cell_to_world(ix, iz, p_gw, p_gh, p_rect, wx, wz);
							host[row + ix] = (float)(amp * (double)nz->get_noise_2d(wx, wz));
						}
					}
				} else {
					std::fill(host.begin(), host.end(), 0.f);
				}
				slot_buf[s] = buf_from(host.data());
			} break;
			case GRAPH_OP_CONST: {
				std::fill(host.begin(), host.end(), params[s]);
				slot_buf[s] = buf_from(host.data());
			} break;
			case GRAPH_OP_BLEND: {
				const RID out = empty_buf();
				plan.push_back({ out, in0[s] >= 0 ? slot_buf[in0[s]] : zero_buf,
						in1[s] >= 0 ? slot_buf[in1[s]] : zero_buf, 1, (int)params[s] });
				slot_buf[s] = out;
			} break;
			case GRAPH_OP_SMOOTH: {
				const RID src = in0[s] >= 0 ? slot_buf[in0[s]] : zero_buf;
				const int passes = (int)params[s];
				if (passes <= 0) {
					const RID out = empty_buf();
					plan.push_back({ out, src, zero_buf, 0, 0 }); // COPY = the identity blur
					slot_buf[s] = out;
				} else {
					// Ping-pong H/V into two temps; the result lands in `a` after each full pass.
					const RID ta = empty_buf();
					const RID tb = empty_buf();
					RID cur = src;
					for (int pass = 0; pass < passes; pass++) {
						plan.push_back({ tb, cur, zero_buf, 2, 0 }); // horizontal: cur -> tb
						plan.push_back({ ta, tb, zero_buf, 3, 0 }); // vertical:   tb  -> ta
						cur = ta;
					}
					slot_buf[s] = ta;
				}
			} break;
			case GRAPH_OP_OUTPUT: {
				const RID out = empty_buf();
				plan.push_back({ out, in0[s] >= 0 ? slot_buf[in0[s]] : zero_buf, zero_buf, 0, 0 });
				slot_buf[s] = out;
			} break;
			default:
				return fail(); // an op the GPU path does not implement — the caller falls back
		}
		if (!slot_buf[s].is_valid()) {
			return fail();
		}
	}
	if (!slot_buf[p_prog.output].is_valid()) {
		return fail();
	}

	// One uniform set per dispatch (each binds its own OUT/A/B trio); kept for the whole list.
	std::vector<RID> sets;
	sets.reserve(plan.size());
	for (const GraphDispatch &d : plan) {
		Ref<RDUniform> uo;
		uo.instantiate();
		uo->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
		uo->set_binding(0);
		uo->add_id(d.out);
		Ref<RDUniform> ua;
		ua.instantiate();
		ua->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
		ua->set_binding(1);
		ua->add_id(d.a);
		Ref<RDUniform> ub;
		ub.instantiate();
		ub->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
		ub->set_binding(2);
		ub->add_id(d.b);
		TypedArray<RDUniform> us;
		us.push_back(uo);
		us.push_back(ua);
		us.push_back(ub);
		const RID set = _rd->uniform_set_create(us, _shader, 0);
		if (!set.is_valid()) {
			for (RID s2 : sets) {
				_rd->free_rid(s2);
			}
			return fail();
		}
		sets.push_back(set);
	}

	const int gx = (p_gw + 7) / 8;
	const int gy = (p_gh + 7) / 8;
	const int64_t cl = _rd->compute_list_begin();
	_rd->compute_list_bind_compute_pipeline(cl, _pipeline);
	for (size_t k = 0; k < plan.size(); k++) {
		PackedByteArray push;
		push.resize(16);
		push.encode_s32(0, plan[k].mode);
		push.encode_s32(4, p_gw);
		push.encode_s32(8, p_gh);
		push.encode_s32(12, plan[k].ip);
		_rd->compute_list_bind_uniform_set(cl, sets[k], 0);
		_rd->compute_list_set_push_constant(cl, push, push.size());
		_rd->compute_list_dispatch(cl, gx, gy, 1);
		// A dependent dispatch reads what the previous wrote (Smooth ping-pong, a Blend of earlier slots),
		// so a barrier between every pair keeps the order correct. Perf-wise Smooth dominates and the
		// barriers are between its own passes anyway; independence-aware batching is a later optimisation.
		if (k + 1 < plan.size()) {
			_rd->compute_list_add_barrier(cl);
		}
	}
	_rd->compute_list_end();
	_rd->submit();
	_rd->sync();

	PackedByteArray out_bytes = _rd->buffer_get_data(slot_buf[p_prog.output]);

	for (RID s2 : sets) {
		_rd->free_rid(s2);
	}
	free_bufs();

	if (out_bytes.size() != bytes) {
		UtilityFunctions::push_warning("Graph GPU: unexpected readback size; falling back to the CPU evaluator.");
		return false;
	}
	r_out.resize(n);
	std::memcpy(r_out.ptrw(), out_bytes.ptr(), bytes);
	return true;
}

namespace godot {

int graph_gpu_threshold() {
	// Measured crossover (GraphGpuBenchGate, reference machine): at/above this many cells the GPU's
	// dispatch+readback beats the CPU whole-graph evaluator for one MISS. Below it the CPU wins (no
	// readback latency), so the GPU stays off for the common small-brush bake. 0 disables the GPU path.
	// Per-shape crossovers on the bench: smooth4 ~96^2, smooth2 ~128^2, noise+blend+smooth ("mixed")
	// ~256^2, identity never (a do-nothing graph always loses the transfer). 256^2 is the conservative
	// pick — the heaviest realistic filter (mixed) has crossed over, so no plausible graph regresses
	// above it; only the degenerate identity does, and only on a frozen miss (sub-ms).
	const int dflt = 65536; // 256x256; set from GraphGpuBenchGate
	ProjectSettings *ps = ProjectSettings::get_singleton();
	if (!ps) {
		return dflt;
	}
	return (int)ps->get_setting("pasture_3d/performance/graph_gpu_threshold", dflt);
}

PackedFloat32Array graph_eval_grid_best(const GraphProgram &p_prog, int p_gw, int p_gh, const Rect2 &p_rect,
		const PackedFloat32Array &p_input) {
	const int threshold = graph_gpu_threshold();
	if (threshold > 0 && (int64_t)p_gw * p_gh >= (int64_t)threshold) {
		static Pasture3DGraphGPU s_gpu; // persistent: the local RD + shader compile once across bakes
		PackedFloat32Array out;
		if (s_gpu.eval_grid(p_prog, p_gw, p_gh, p_rect, p_input, out)) {
			return out;
		}
		// GPU unavailable or failed — fall through to the CPU evaluator (three-tier fallback).
	}
	return graph_eval_grid(p_prog, p_gw, p_gh, p_rect, p_input);
}

} // namespace godot
