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

#include <cmath>
#include <cstring>
#include <vector>

using namespace godot;

// One compute shader, dispatched once per GRID node with a `mode` selecting the op. Reads up to two input
// buffers (A, B) and writes one output buffer (OUT), all std430 float arrays over the gw*gh grid.
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

static const char *GRAPH_HYDRAULIC_GLSL =
#include "shaders/graph_solver_hydraulic.glsl"
;

Pasture3DGraphGPU::~Pasture3DGraphGPU() {
	if (_rd) {
		if (_pipeline.is_valid()) {
			_rd->free_rid(_pipeline);
		}
		if (_shader.is_valid()) {
			_rd->free_rid(_shader);
		}
		if (_pipeline_hydraulic.is_valid()) {
			_rd->free_rid(_pipeline_hydraulic);
		}
		if (_shader_hydraulic.is_valid()) {
			_rd->free_rid(_shader_hydraulic);
		}
		memdelete(_rd);
		_rd = nullptr;
	}
}

bool Pasture3DGraphGPU::_ensure_init() {
	if (_rd && _pipeline.is_valid()) {
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
	if (!_rd) {
		_rd = rs->create_local_rendering_device();
		if (!_rd) {
			UtilityFunctions::push_warning("Graph GPU: no local RenderingDevice; falling back to the CPU evaluator.");
			_init_failed = true;
			return false;
		}
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

bool Pasture3DGraphGPU::_ensure_init_hydraulic() {
	if (_rd && _pipeline_hydraulic.is_valid()) {
		return true;
	}
	if (_init_hydraulic_failed) {
		return false;
	}
	if (!_ensure_init()) {
		_init_hydraulic_failed = true;
		return false;
	}

	Ref<RDShaderSource> src;
	src.instantiate();
	src->set_stage_source(RenderingDevice::SHADER_STAGE_COMPUTE, String(GRAPH_HYDRAULIC_GLSL));
	Ref<RDShaderSPIRV> spirv = _rd->shader_compile_spirv_from_source(src);
	if (spirv.is_null() || !spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_COMPUTE).is_empty()) {
		UtilityFunctions::push_warning("Graph GPU: hydraulic compute shader compile failed; falling back to the CPU evaluator.");
		_init_hydraulic_failed = true;
		return false;
	}
	_shader_hydraulic = _rd->shader_create_from_spirv(spirv);
	if (!_shader_hydraulic.is_valid()) {
		_init_hydraulic_failed = true;
		return false;
	}
	_pipeline_hydraulic = _rd->compute_pipeline_create(_shader_hydraulic);
	if (!_pipeline_hydraulic.is_valid()) {
		_rd->free_rid(_shader_hydraulic);
		_init_hydraulic_failed = true;
		return false;
	}
	return true;
}

bool Pasture3DGraphGPU::available() {
	return _ensure_init();
}

namespace {
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

	std::vector<RID> to_free;
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
		pb.resize(bytes);
		RID b = _rd->storage_buffer_create(bytes, pb);
		if (b.is_valid()) {
			to_free.push_back(b);
		}
		return b;
	};

	const RID zero_buf = empty_buf();
	if (!zero_buf.is_valid()) {
		return fail();
	}

	const int32_t *ops = p_prog.ops.ptr();
	const float *params = p_prog.params.ptr();
	const int32_t *in0 = p_prog.in0.ptr();
	const int32_t *in1 = p_prog.in1.ptr();

	std::vector<RID> slot_buf(p_prog.count);
	std::vector<GraphDispatch> plan;

	std::vector<float> host((size_t)n);
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
					plan.push_back({ out, src, zero_buf, 0, 0 });
					slot_buf[s] = out;
				} else {
					const RID ta = empty_buf();
					const RID tb = empty_buf();
					RID cur = src;
					for (int pass = 0; pass < passes; pass++) {
						plan.push_back({ tb, cur, zero_buf, 2, 0 });
						plan.push_back({ ta, tb, zero_buf, 3, 0 });
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
				return fail();
		}
		if (!slot_buf[s].is_valid()) {
			return fail();
		}
	}
	if (!slot_buf[p_prog.output].is_valid()) {
		return fail();
	}

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

bool Pasture3DGraphGPU::eval_hydraulic(const PackedFloat32Array &p_surface, int p_gw, int p_gh, const Rect2 &p_rect,
		const ErosionHydraulicParams &p_params, ErosionHydraulicResult &r_out) {
	if (!_ensure_init_hydraulic()) {
		return false;
	}
	if (p_gw < 1 || p_gh < 1) {
		return false;
	}
	const int n = p_gw * p_gh;
	if (p_surface.size() != n) {
		return false;
	}

	const int bytes = n * (int)sizeof(float);
	const int vec4_bytes = n * (int)sizeof(float) * 4;

	std::vector<RID> to_free;
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

	// 1. Storage buffers
	PackedByteArray pb_height;
	pb_height.resize(bytes);
	std::memcpy(pb_height.ptrw(), p_surface.ptr(), bytes);
	const RID height_buf = _rd->storage_buffer_create(bytes, pb_height);
	if (!height_buf.is_valid()) return fail();
	to_free.push_back(height_buf);

	PackedByteArray pb_zero;
	pb_zero.resize(bytes);
	const RID water_buf = _rd->storage_buffer_create(bytes, pb_zero);
	if (!water_buf.is_valid()) return fail();
	to_free.push_back(water_buf);

	const RID sediment_buf = _rd->storage_buffer_create(bytes, pb_zero);
	if (!sediment_buf.is_valid()) return fail();
	to_free.push_back(sediment_buf);

	const RID flow_buf = _rd->storage_buffer_create(bytes, pb_zero);
	if (!flow_buf.is_valid()) return fail();
	to_free.push_back(flow_buf);

	PackedByteArray pb_vec4_zero;
	pb_vec4_zero.resize(vec4_bytes);
	const RID flux_w_buf = _rd->storage_buffer_create(vec4_bytes, pb_vec4_zero);
	if (!flux_w_buf.is_valid()) return fail();
	to_free.push_back(flux_w_buf);

	const RID flux_s_buf = _rd->storage_buffer_create(vec4_bytes, pb_vec4_zero);
	if (!flux_s_buf.is_valid()) return fail();
	to_free.push_back(flux_s_buf);

	// Uniform set
	TypedArray<RDUniform> uniforms;
	const RID bufs[6] = { height_buf, water_buf, sediment_buf, flow_buf, flux_w_buf, flux_s_buf };
	for (int i = 0; i < 6; i++) {
		Ref<RDUniform> u;
		u.instantiate();
		u->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
		u->set_binding(i);
		u->add_id(bufs[i]);
		uniforms.push_back(u);
	}
	const RID uniform_set = _rd->uniform_set_create(uniforms, _shader_hydraulic, 0);
	if (!uniform_set.is_valid()) {
		return fail();
	}

	const float dx = p_rect.size.x / (float)std::max(p_gw, 1);
	const float dz = p_rect.size.y / (float)std::max(p_gh, 1);
	const float cell_dist = std::sqrt(std::max(dx * dz, 1e-6f));
	const int gx = (p_gw + 7) / 8;
	const int gy = (p_gh + 7) / 8;

	PackedByteArray push;
	push.resize(64);
	push.encode_s32(4, p_gw);
	push.encode_s32(8, p_gh);
	push.encode_s32(12, 0); // pad0
	push.encode_float(16, dx);
	push.encode_float(20, dz);
	push.encode_float(24, cell_dist);
	push.encode_float(28, p_params.rain_rate);
	push.encode_float(32, p_params.evaporation_rate);
	push.encode_float(36, p_params.sediment_capacity);
	push.encode_float(40, p_params.erosion_speed);
	push.encode_float(44, p_params.deposition_speed);
	push.encode_float(48, p_params.min_slope);
	push.encode_float(52, 1.0f); // max_flow (temp)
	push.encode_float(56, 1.0f); // max_sed (temp)
	push.encode_float(60, 0.0f); // pad1

	// Simulation passes
	int64_t cl = _rd->compute_list_begin();
	_rd->compute_list_bind_compute_pipeline(cl, _pipeline_hydraulic);
	_rd->compute_list_bind_uniform_set(cl, uniform_set, 0);

	for (int pass = 0; pass < p_params.iterations; pass++) {
		// Phase 0: Rain, Stream Power Incision & Outbound Flux
		push.encode_s32(0, 0);
		_rd->compute_list_set_push_constant(cl, push, push.size());
		_rd->compute_list_dispatch(cl, gx, gy, 1);
		_rd->compute_list_add_barrier(cl);

		// Phase 1: Gather Inbound Flux & Evaporate
		push.encode_s32(0, 1);
		_rd->compute_list_set_push_constant(cl, push, push.size());
		_rd->compute_list_dispatch(cl, gx, gy, 1);
		_rd->compute_list_add_barrier(cl);
	}
	_rd->compute_list_end();
	_rd->submit();
	_rd->sync();

	// Calculate max_flow and max_sed for normalization
	PackedByteArray flow_bytes = _rd->buffer_get_data(flow_buf);
	PackedByteArray sed_bytes = _rd->buffer_get_data(sediment_buf);
	PackedByteArray height_bytes = _rd->buffer_get_data(height_buf);

	const float *h_ptr = (const float *)height_bytes.ptr();
	const float *f_ptr = (const float *)flow_bytes.ptr();
	const float *s_ptr = (const float *)sed_bytes.ptr();
	float max_flow = 1e-6f;
	float max_sed = 1e-6f;
	for (int i = 0; i < n; i++) {
		if (std::isfinite(h_ptr[i])) {
			max_flow = std::max(max_flow, f_ptr[i]);
			max_sed = std::max(max_sed, s_ptr[i]);
		}
	}

	// Phase 2: Final Normalization
	push.encode_s32(0, 2);
	push.encode_float(52, max_flow);
	push.encode_float(56, max_sed);

	cl = _rd->compute_list_begin();
	_rd->compute_list_bind_compute_pipeline(cl, _pipeline_hydraulic);
	_rd->compute_list_bind_uniform_set(cl, uniform_set, 0);
	_rd->compute_list_set_push_constant(cl, push, push.size());
	_rd->compute_list_dispatch(cl, gx, gy, 1);
	_rd->compute_list_end();
	_rd->submit();
	_rd->sync();

	// Readback output channels
	height_bytes = _rd->buffer_get_data(height_buf);
	sed_bytes = _rd->buffer_get_data(sediment_buf);
	flow_bytes = _rd->buffer_get_data(flow_buf);

	_rd->free_rid(uniform_set);
	free_bufs();

	if (height_bytes.size() != bytes || sed_bytes.size() != bytes || flow_bytes.size() != bytes) {
		return false;
	}

	r_out.height.resize(n);
	r_out.sediment.resize(n);
	r_out.flow.resize(n);
	std::memcpy(r_out.height.ptrw(), height_bytes.ptr(), bytes);
	std::memcpy(r_out.sediment.ptrw(), sed_bytes.ptr(), bytes);
	std::memcpy(r_out.flow.ptrw(), flow_bytes.ptr(), bytes);
	r_out.ok = true;
	return true;
}

namespace godot {

int graph_gpu_threshold() {
	const int dflt = 65536; // 256x256
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
		static Pasture3DGraphGPU s_gpu;
		PackedFloat32Array out;
		if (s_gpu.eval_grid(p_prog, p_gw, p_gh, p_rect, p_input, out)) {
			return out;
		}
	}
	return graph_eval_grid(p_prog, p_gw, p_gh, p_rect, p_input);
}

ErosionHydraulicResult erosion_hydraulic_solve_best(const PackedFloat32Array &p_surface,
		int p_gw, int p_gh, const Rect2 &p_rect, const ErosionHydraulicParams &p_params) {
	const int threshold = graph_gpu_threshold();
	if (threshold > 0 && (int64_t)p_gw * p_gh >= (int64_t)threshold) {
		static Pasture3DGraphGPU s_gpu;
		ErosionHydraulicResult res;
		if (s_gpu.eval_hydraulic(p_surface, p_gw, p_gh, p_rect, p_params, res)) {
			return res;
		}
	}
	return erosion_hydraulic_solve(p_surface, p_gw, p_gh, p_rect, p_params);
}

} // namespace godot
