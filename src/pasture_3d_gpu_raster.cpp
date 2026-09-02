#include "pasture_3d_gpu_raster.h"

#include <godot_cpp/classes/rd_shader_source.hpp>
#include <godot_cpp/classes/rd_shader_spirv.hpp>
#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rd_uniform.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/thread.hpp>
#include <godot_cpp/core/memory.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cstring>

using namespace godot;

// This helper is a plain C++ class (not a GDCLASS Object), so the project's LOG macro (which expands
// __class__) is unavailable here; warn via UtilityFunctions directly. Failures are non-fatal — the caller
// falls back to the C++ rasteriser — so these are warnings, logged once per session via _init_failed.

// Analytic closed-loop signed-distance compute shader (GLSL, RDShaderSource path: no "#[compute]" header;
// the stage is set explicitly in code). Per texel: even-odd inside test + min distance to any polygon edge
// -> signed distance (positive inside); atomic-max of the interior distance -> max_inside. Polygon coords
// and the grid are uploaded BOX-LOCAL (world minus (min_x,min_z)) so all magnitudes stay small and float32
// precision is full regardless of the terrain region's world offset (distance is translation-invariant).
static const char *CLOSED_LOOP_SDF_GLSL = R"(#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r32f, set = 0, binding = 0) restrict writeonly uniform image2D field_tex;

layout(set = 0, binding = 1, std430) restrict readonly buffer PolyBuf {
	vec2 pts[];
} poly;

layout(set = 0, binding = 2, std430) restrict buffer MaxBuf {
	uint max_inside_bits;
} mx;

layout(push_constant, std430) uniform Params {
	float vs;
	int gw;
	int gh;
	int pc;
} p;

float seg_dist(vec2 q, vec2 a, vec2 b) {
	vec2 ab = b - a;
	float denom = max(dot(ab, ab), 1e-20);
	float t = clamp(dot(q - a, ab) / denom, 0.0, 1.0);
	return distance(q, a + t * ab);
}

void main() {
	int ix = int(gl_GlobalInvocationID.x);
	int iz = int(gl_GlobalInvocationID.y);
	if (ix >= p.gw || iz >= p.gh) { return; }
	vec2 q = vec2(float(ix) * p.vs, float(iz) * p.vs);

	bool inside = false;
	float mind = 1.0e30;
	int n = p.pc;
	int j = n - 1;
	for (int i = 0; i < n; i++) {
		vec2 a = poly.pts[i];
		vec2 b = poly.pts[j];
		// even-odd crossing on z (vec2.y holds world z), matching the scanline fill in raster_sdf.
		if ((a.y > q.y) != (b.y > q.y)) {
			float xint = a.x + (q.y - a.y) / (b.y - a.y) * (b.x - a.x);
			if (q.x < xint) { inside = !inside; }
		}
		mind = min(mind, seg_dist(q, a, b));
		j = i;
	}

	float signed_d = inside ? mind : -mind;
	imageStore(field_tex, ivec2(ix, iz), vec4(signed_d, 0.0, 0.0, 0.0));
	if (inside) {
		// floatBitsToUint is monotonic for finite non-negative floats, so an integer atomicMax of the
		// bit pattern computes the float max. mind >= 0 here.
		atomicMax(mx.max_inside_bits, floatBitsToUint(mind));
	}
}
)";

Pasture3DGPURaster::~Pasture3DGPURaster() {
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

bool Pasture3DGPURaster::_ensure_init() {
	if (!Thread::is_main_thread()) {
		return false;
	}
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
		UtilityFunctions::push_warning("GPU raster: no local RenderingDevice; falling back to CPU rasteriser.");
		_init_failed = true;
		return false;
	}
	Ref<RDShaderSource> src;
	src.instantiate();
	src->set_stage_source(RenderingDevice::SHADER_STAGE_COMPUTE, String(CLOSED_LOOP_SDF_GLSL));
	Ref<RDShaderSPIRV> spirv = _rd->shader_compile_spirv_from_source(src);
	if (spirv.is_null() || !spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_COMPUTE).is_empty()) {
		UtilityFunctions::push_warning("GPU raster: compute shader compile failed; falling back to CPU rasteriser.");
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

bool Pasture3DGPURaster::available() {
	return _ensure_init();
}

bool Pasture3DGPURaster::closed_loop_field(const PackedVector2Array &p_poly, double p_min_x, double p_min_z,
		double p_vs, int p_gw, int p_gh, std::vector<float> &r_field, float &r_max_inside) {
	if (!_ensure_init()) {
		return false;
	}
	const int pc = p_poly.size();
	if (pc < 3 || p_gw < 1 || p_gh < 1) {
		return false;
	}

	// --- Box-local polygon -> SSBO bytes ---
	PackedFloat32Array poly_local;
	poly_local.resize(pc * 2);
	{
		float *w = poly_local.ptrw();
		const Vector2 *r = p_poly.ptr();
		for (int i = 0; i < pc; i++) {
			w[i * 2 + 0] = (float)((double)r[i].x - p_min_x);
			w[i * 2 + 1] = (float)((double)r[i].y - p_min_z);
		}
	}
	PackedByteArray poly_bytes = poly_local.to_byte_array();

	// --- max_inside accumulator (1 uint), seeded 0 ---
	PackedByteArray max_init;
	max_init.resize(4);
	max_init.encode_u32(0, 0);

	// --- Output field texture (R32F, gw*gh) ---
	Ref<RDTextureFormat> fmt;
	fmt.instantiate();
	fmt->set_format(RenderingDevice::DATA_FORMAT_R32_SFLOAT);
	fmt->set_width(p_gw);
	fmt->set_height(p_gh);
	fmt->set_depth(1);
	fmt->set_array_layers(1);
	fmt->set_mipmaps(1);
	fmt->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D);
	fmt->set_usage_bits(RenderingDevice::TEXTURE_USAGE_STORAGE_BIT | RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT);
	Ref<RDTextureView> view;
	view.instantiate();
	RID tex = _rd->texture_create(fmt, view, TypedArray<PackedByteArray>());

	RID poly_buf = _rd->storage_buffer_create(poly_bytes.size(), poly_bytes);
	RID max_buf = _rd->storage_buffer_create(max_init.size(), max_init);

	if (!tex.is_valid() || !poly_buf.is_valid() || !max_buf.is_valid()) {
		if (tex.is_valid()) _rd->free_rid(tex);
		if (poly_buf.is_valid()) _rd->free_rid(poly_buf);
		if (max_buf.is_valid()) _rd->free_rid(max_buf);
		return false;
	}

	Ref<RDUniform> u_field;
	u_field.instantiate();
	u_field->set_uniform_type(RenderingDevice::UNIFORM_TYPE_IMAGE);
	u_field->set_binding(0);
	u_field->add_id(tex);
	Ref<RDUniform> u_poly;
	u_poly.instantiate();
	u_poly->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
	u_poly->set_binding(1);
	u_poly->add_id(poly_buf);
	Ref<RDUniform> u_max;
	u_max.instantiate();
	u_max->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
	u_max->set_binding(2);
	u_max->add_id(max_buf);
	TypedArray<RDUniform> uniforms;
	uniforms.push_back(u_field);
	uniforms.push_back(u_poly);
	uniforms.push_back(u_max);
	RID uniform_set = _rd->uniform_set_create(uniforms, _shader, 0);
	if (!uniform_set.is_valid()) {
		_rd->free_rid(tex);
		_rd->free_rid(poly_buf);
		_rd->free_rid(max_buf);
		return false;
	}

	// --- Push constant (16 bytes: float vs, int gw, int gh, int pc) ---
	PackedByteArray push;
	push.resize(16);
	push.encode_float(0, (float)p_vs);
	push.encode_s32(4, p_gw);
	push.encode_s32(8, p_gh);
	push.encode_s32(12, pc);

	const int64_t cl = _rd->compute_list_begin();
	_rd->compute_list_bind_compute_pipeline(cl, _pipeline);
	_rd->compute_list_bind_uniform_set(cl, uniform_set, 0);
	_rd->compute_list_set_push_constant(cl, push, push.size());
	_rd->compute_list_dispatch(cl, (p_gw + 7) / 8, (p_gh + 7) / 8, 1);
	_rd->compute_list_end();
	_rd->submit();
	_rd->sync();

	// --- Readback ---
	PackedByteArray field_bytes = _rd->texture_get_data(tex, 0);
	PackedByteArray max_bytes = _rd->buffer_get_data(max_buf);

	_rd->free_rid(uniform_set);
	_rd->free_rid(tex);
	_rd->free_rid(poly_buf);
	_rd->free_rid(max_buf);

	const int n = p_gw * p_gh;
	if (field_bytes.size() != n * 4 || max_bytes.size() != 4) {
		UtilityFunctions::push_warning("GPU raster: unexpected readback size; falling back to CPU rasteriser.");
		return false;
	}

	r_field.resize(n);
	{
		const float *src = (const float *)field_bytes.ptr();
		std::copy(src, src + n, r_field.data());
	}
	const uint32_t bits = max_bytes.decode_u32(0);
	float mi;
	memcpy(&mi, &bits, sizeof(float));
	r_max_inside = mi;
	return true;
}
