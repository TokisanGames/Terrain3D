#ifndef PASTURE_3D_GRAPH_GPU_H
#define PASTURE_3D_GRAPH_GPU_H

// GPU backend for the terrain graph (PASTURE3D_TERRAIN_GRAPH_SPEC.md §6, the RenderingDevice path).
//
// Owns a *local* RenderingDevice and one compute shader that runs the graph's GRID passes — Blend, Smooth
// (the NaN-aware separable blur), and Output — over resident storage buffers, one buffer per node, with a
// single readback of the output at the end. The GENERATORS (Input, Noise, Const) are evaluated on the CPU
// and uploaded: FastNoiseLite cannot be reproduced in GLSL to the parity tolerance, so the noise is the
// exact same bytes graph_eval_grid computes, and only the grid arithmetic moves to the GPU. That is where
// the win is anyway — Smooth is multi-pass, and future grid nodes (erosion) are the expensive ones.
//
// The CPU whole-graph evaluator (graph_eval_grid, pasture_3d_graph_ops) is the A/B oracle: this must match
// it within a documented epsilon (GraphGpuParityGate, run NON-headless — the dummy headless driver has no
// local RenderingDevice). Self-contained and side-effect-free; the caller falls back to the CPU path when
// `available()` is false or `eval_grid` returns false (three-tier GPU -> C++ -> GDScript, as the SDF raster).

#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

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

private:
	RenderingDevice *_rd = nullptr;
	RID _shader;
	RID _pipeline;
	bool _init_failed = false;

	bool _ensure_init();
};

#endif // PASTURE_3D_GRAPH_GPU_H
