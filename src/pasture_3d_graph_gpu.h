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
#include "pasture_3d_graph_ops.h"

using namespace godot;

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

private:
	RenderingDevice *_rd = nullptr;
	RID _shader;
	RID _pipeline;
	RID _shader_hydraulic;
	RID _pipeline_hydraulic;
	bool _init_failed = false;
	bool _init_hydraulic_failed = false;

	bool _ensure_init();
	bool _ensure_init_hydraulic();
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

} // namespace godot

#endif // PASTURE_3D_GRAPH_GPU_H
