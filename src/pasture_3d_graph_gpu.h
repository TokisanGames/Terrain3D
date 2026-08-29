#ifndef PASTURE_3D_GRAPH_GPU_H
#define PASTURE_3D_GRAPH_GPU_H

// GPU backend for the terrain graph (PASTURE3D_TERRAIN_GRAPH_SPEC.md §6, the RenderingDevice path).
//
// Owns a *local* RenderingDevice and compute shaders that run the graph's GRID passes — Blend, Smooth
// (the NaN-aware separable blur), Output, and Hydrodynamic Hydraulic Erosion — over resident storage buffers,
// with minimal host-device roundtrips.

#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

#include "pasture_3d_erosion_hydraulic.h"
#include "pasture_3d_geo_primitives.h"
#include "pasture_3d_graph_ops.h"

using namespace godot;

// Host-side mirror of the ParamBuf std430 block in shaders/graph_geo_primitives.glsl. All members are 4-byte
// scalars (int/uint/float), so std430 packs them contiguously with no padding and this struct memcpys 1:1
// into the params SSBO. Field order MUST match the shader exactly. Router code fills only the subset each op
// reads; unused fields keep their defaults (harmless — the op ignores them).
struct GeoGpuParams {
	int32_t op = 0;
	int32_t gw = 0;
	int32_t gh = 0;
	int32_t octaves = 1;
	uint32_t seed_u = 0; // already wang-hashed on host
	int32_t flags = 0; // bit0 = has A, bit1 = has B, bit2 = has C
	int32_t octaves2 = 1;
	int32_t octaves3 = 1;

	float elevation = 0.0f;
	float scale = 1.0f;
	float kw = 1.0f;
	float kw2 = 1.0f;
	float kw3 = 1.0f;
	float cos_alpha = 1.0f;
	float sin_alpha = 0.0f;
	float gamma = 0.0f;

	float persistence = 0.5f;
	float lacunarity = 2.0f;
	float base_noise_amp = 0.0f;
	float cone_alpha = 1.0f;
	float ridge_amp = 0.0f;
	float bulk_amp = 0.0f;
	float half_width = 0.2f;
	float k_smoothing = 0.05f;

	float angle_spread_ratio = 0.0f;
	float core_size_ratio = 0.2f;
	float weight = 0.7f;
	float radius = 0.2f;
	float sigma_inner = 0.05f;
	float sigma_outer = 0.15f;
	float z_bottom = 0.2f;
	float noise_r_amp = 0.0f;

	float noise_z_ratio = 0.0f;
	float center_x = 0.5f;
	float center_y = 0.5f;
	float pad0 = 0.0f;
};

static_assert(sizeof(GeoGpuParams) == 144, "GeoGpuParams must match the std430 ParamBuf layout (36 * 4 bytes)");

class Pasture3DGraphGPU {
public:
	Pasture3DGraphGPU() {}
	~Pasture3DGraphGPU();

	// True once the local RD + compute pipeline exist (lazily initialised). False => caller uses the CPU path.
	bool available();

	// Evaluate `p_prog` on the GPU to a p_gw*p_gh row-major field over p_rect, `p_input` feeding Input nodes
	// (empty => a flat 0). On success fills r_out (size p_gw*p_gh) and returns true; returns false on any RD
	// failure, r_out untouched, and the caller falls back to the CPU evaluator.
	bool eval_grid(const godot::GraphProgram &p_prog, int p_gw, int p_gh, const Rect2 &p_rect,
			const PackedFloat32Array &p_input, PackedFloat32Array &r_out);

	// Evaluate hydraulic erosion on the GPU using ping-pong SSBO buffers. Returns true on success.
	bool eval_hydraulic(const PackedFloat32Array &p_surface, int p_gw, int p_gh, const Rect2 &p_rect,
			const ErosionHydraulicParams &p_params, ErosionHydraulicResult &r_out);

	// Evaluate one geological primitive on the GPU in a single dispatch over the gw*gh grid. `p_gp` is the
	// filled param block (op selects the primitive; octaves must arrive already Nyquist-capped). The three
	// optional inputs feed the ABuf/BBuf/CBuf bindings; pass empty arrays for unwired ports (p_gp.flags must
	// agree). On success fills r_out (and r_out2 for two-output ops) sized p_gw*p_gh and returns true.
	bool eval_geo(const GeoGpuParams &p_gp, int p_gw, int p_gh,
			const PackedFloat32Array &p_in_a, const PackedFloat32Array &p_in_b, const PackedFloat32Array &p_in_c,
			PackedFloat32Array &r_out, PackedFloat32Array &r_out2);

private:
	RenderingDevice *_rd = nullptr;
	RID _shader;
	RID _pipeline;
	RID _shader_hydraulic;
	RID _pipeline_hydraulic;
	RID _shader_geo;
	RID _pipeline_geo;
	bool _init_failed = false;
	bool _init_hydraulic_failed = false;
	bool _init_geo_failed = false;

	bool _ensure_init();
	bool _ensure_init_hydraulic();
	bool _ensure_init_geo();
};

namespace godot {

// The crossover, in cells (p_gw*p_gh), at or above which the GPU beats the CPU whole-graph evaluator for a
// single MISS evaluation. Read from ProjectSettings pasture_3d/performance/graph_gpu_threshold; the default
// is the measured crossover on the reference machine (GraphGpuBenchGate). 0 disables the GPU path entirely.
int graph_gpu_threshold();

// Production whole-graph evaluator for the live bake: runs on the GPU when the grid is at least
// graph_gpu_threshold() cells AND a local RenderingDevice is available, otherwise (or on any GPU failure)
// on the CPU (graph_eval_grid). Always returns the field — the three-tier GPU -> C++ fallback the SDF
// raster uses. One persistent Pasture3DGraphGPU, so the shader compiles once across bakes.
PackedFloat32Array graph_eval_grid_best(const GraphProgram &p_prog, int p_gw, int p_gh, const Rect2 &p_rect,
		const PackedFloat32Array &p_input);

// Production hydraulic erosion solver: GPU accelerated when available and >= threshold, else native C++.
ErosionHydraulicResult erosion_hydraulic_solve_best(const PackedFloat32Array &p_surface,
		int p_gw, int p_gh, const Rect2 &p_rect, const ErosionHydraulicParams &p_params);

// Production Geological Primitive solvers: GPU accelerated when available and >= threshold, else native C++.
PackedFloat32Array mountain_cone_solve_best(int p_gw, int p_gh, const Rect2 &p_rect,
		const MountainConeParams &p_params);
bool mountain_cone_eval_gpu(int p_gw, int p_gh, const Rect2 &p_rect, const MountainConeParams &p_params,
		PackedFloat32Array &r_out);

PackedFloat32Array mountain_inselberg_solve_best(int p_gw, int p_gh, const Rect2 &p_rect,
		const MountainInselbergParams &p_params);
bool mountain_inselberg_eval_gpu(int p_gw, int p_gh, const Rect2 &p_rect, const MountainInselbergParams &p_params,
		PackedFloat32Array &r_out);

Array mountain_range_radial_solve_best(int p_gw, int p_gh, const Rect2 &p_rect,
		const MountainRangeRadialParams &p_params);
bool mountain_range_radial_eval_gpu(int p_gw, int p_gh, const Rect2 &p_rect, const MountainRangeRadialParams &p_params,
		Array &r_out);

PackedFloat32Array mountain_tibesti_solve_best(int p_gw, int p_gh, const Rect2 &p_rect,
		const MountainTibestiParams &p_params);
bool mountain_tibesti_eval_gpu(int p_gw, int p_gh, const Rect2 &p_rect, const MountainTibestiParams &p_params,
		PackedFloat32Array &r_out);

PackedFloat32Array mountain_stump_solve_best(int p_gw, int p_gh, const Rect2 &p_rect,
		const MountainStumpParams &p_params);
bool mountain_stump_eval_gpu(int p_gw, int p_gh, const Rect2 &p_rect, const MountainStumpParams &p_params,
		PackedFloat32Array &r_out);

PackedFloat32Array shattered_peak_solve_best(int p_gw, int p_gh, const Rect2 &p_rect,
		const ShatteredPeakParams &p_params);
bool shattered_peak_eval_gpu(int p_gw, int p_gh, const Rect2 &p_rect, const ShatteredPeakParams &p_params,
		PackedFloat32Array &r_out);

PackedFloat32Array caldera_solve_best(int p_gw, int p_gh, const Rect2 &p_rect,
		const CalderaParams &p_params);
bool caldera_eval_gpu(int p_gw, int p_gh, const Rect2 &p_rect, const CalderaParams &p_params,
		PackedFloat32Array &r_out);

} // namespace godot

#endif // PASTURE_3D_GRAPH_GPU_H
