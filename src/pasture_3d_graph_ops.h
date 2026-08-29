// Terrain-graph CELL-RUN evaluator (PASTURE3D_TERRAIN_GRAPH_SPEC.md §6, the C++ parity step). A
// Pasture3DTerrainGraph whose output ancestry is all CELL nodes (Noise / Const / Blend) compiles itself to
// a flat SSA program in GDScript (Pasture3DTerrainGraph.compile_cell_program); this evaluates that program
// per cell in C++ so the eventual bake path keeps the native rasteriser's budget. It is the same bargain
// the relief op-program makes (pasture_3d_relief_ops.h): a fixed op catalogue, not a scripting VM.
//
// The GDScript folded evaluator (Pasture3DTerrainGraph.evaluate / _cell_value) is the A/B oracle: this must
// agree with it to 1e-4 m on the output field. Unlike relief, the noise is NOT rebuilt from params here —
// the graph's FastNoiseLite resource travels into the program as-is, so there is no _configure_noise mirror
// to keep in step; both evaluators call the same FastNoiseLite instance and cannot disagree on it.
//
// SCOPE: cell runs only. A grid node (Smooth) reads neighbours and cannot fold into a per-cell loop, so a
// graph carrying one compiles to nothing here and stays on the GDScript path. Interleaving native grid
// passes — and flipping Pasture3DTerrainBrush's _stack_forces_gdscript off — is the follow-on that pairs
// with the GPU backend; this establishes the cell-run parity that both rest on.

#pragma once

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

#include <vector>

namespace godot {

// Graph op ids — MUST stay in sync with the op() tags in project/addons/pasture_3d/graph/. These are a
// WIRE FORMAT between the GDScript compilers (compile_cell_program / compile_graph_program) and the
// builders here; a new node appends an id rather than renumbering, exactly as the relief catalogue does.
// 1-3 are CELL ops (point-evaluable); 10-12 are GRID / structural ops the whole-graph evaluator handles.
enum GraphCellOpType {
	GRAPH_OP_NOISE = 1, // GENERATOR cell: params[slot] * noise[slot].get_noise_2d(wx, wz)
	GRAPH_OP_CONST = 2, // GENERATOR cell: params[slot]
	GRAPH_OP_BLEND = 3, // COMBINER cell: in_a (o) in_b (masked by in_c)
	GRAPH_OP_TERRACE = 4, // FILTER cell: terrace in_a, band_height=params, hardness=params_b, amount=params_c, jitter=params_d
	GRAPH_OP_INPUT = 10, // SOURCE grid: the surface handed to the graph (or a flat 0)
	GRAPH_OP_SMOOTH = 11, // FILTER grid: NaN-aware blur of in0, params[slot] passes
	GRAPH_OP_OUTPUT = 12, // SINK: passes in0 through (the graph's result)
	GRAPH_OP_NOISE_JORDAN = 13, // GENERATOR grid: Jordan fBm derivative noise
	GRAPH_OP_NOISE_SWISS = 14, // GENERATOR grid: Swiss ridge noise
	GRAPH_OP_GEOLOGICAL_PRIMITIVE = 15, // GENERATOR grid: inselberg, caldera, cuesta
	GRAPH_OP_FURROWS = 16, // GENERATOR grid: corrugated furrows
	GRAPH_OP_DUNES = 17, // GENERATOR grid: asymmetric dunes
	GRAPH_OP_CRATER = 18, // GENERATOR grid: impact crater
	GRAPH_OP_WARP = 19, // GENERATOR grid: domain warp
	GRAPH_OP_STRATA = 20, // FILTER grid: tilted rock strata
	GRAPH_OP_CURVE = 21, // FILTER grid: LUT transfer curve
	GRAPH_OP_REMAP = 22, // FILTER grid: soft-knee range remap
	GRAPH_OP_MASK = 23, // FILTER grid: slope/altitude/curvature band gate
	GRAPH_OP_CURVATURE = 24, // FILTER grid: discrete curvature mask
	GRAPH_OP_TALUS_PROJECTION = 25, // FILTER grid: angle of repose talus relaxation
	GRAPH_OP_SPECTRAL_EQUALIZER = 26, // FILTER grid: Laplacian pyramid equalizer
	GRAPH_OP_DEPRESSION_FILLING = 27, // FILTER grid: sink filler
	GRAPH_OP_LAKE_FLOODING = 28, // SOLVER grid: lake flooding
	GRAPH_OP_STREAM_EXTRACTION = 29, // SOLVER grid: river channel carving
	GRAPH_OP_EROSION_HYDRAULIC = 30, // SOLVER grid: hydraulic erosion
	GRAPH_OP_EROSION_THERMAL = 31, // SOLVER grid: thermal weathering erosion
	GRAPH_OP_SCREE = 32, // SOLVER grid: scree talus solver
	GRAPH_OP_EROSION = 33, // SOLVER grid: stream power erosion
	GRAPH_OP_HYDRAULIC_PARTICLE = 34, // SOLVER grid: particle droplet hydraulic erosion
	GRAPH_OP_HYDRAULIC_STREAM_LOG = 35, // SOLVER grid: logarithmic stream-power erosion
	GRAPH_OP_HYDRAULIC_SALEVE = 36, // SOLVER grid: Salève structural hydraulic erosion
	GRAPH_OP_MOUNTAIN_CONE = 37, // PRIMITIVE grid: conical mountain peak with cellular Voronoi ridges
	GRAPH_OP_MOUNTAIN_INSELBERG = 38, // PRIMITIVE grid: isolated inselberg dome with fractured bedrock ridges
};

// Blend modes — sync with Pasture3DGraphNodeBlend.Mode { ADD, SUB, MUL, MAX, MIN } (0..4). Prefixed
// because MAX/MIN are godot-cpp macros.
enum GraphBlendMode {
	GRAPH_BLEND_ADD = 0,
	GRAPH_BLEND_SUB = 1,
	GRAPH_BLEND_MUL = 2,
	GRAPH_BLEND_MAX = 3,
	GRAPH_BLEND_MIN = 4,
};

// An input source that reads a defined 0 rather than an earlier slot — an unwired port, exactly as the
// GDScript evaluator reads an unconnected input as 0 (never stale memory). Any value >= 0 is an SSA slot.
constexpr int GRAPH_CELL_SRC_ZERO = -1;

// A lowered cell-run in SSA form: instruction `slot` reads only lower-numbered slots, because the GDScript
// compiler emits nodes in topological order. `noise` is parallel to the slots; entries are null for every
// op but NOISE. Built once per bake, evaluated per cell.
struct GraphCellProgram {
	PackedInt32Array ops; // one GraphCellOpType per slot
	PackedFloat32Array params; // one scalar per slot: amplitude | value | blend-mode | band_height
	PackedFloat32Array params_b; // secondary scalar: hardness
	PackedFloat32Array params_c; // tertiary scalar: amount
	PackedFloat32Array params_d; // quaternary scalar: jitter
	PackedInt32Array in_a; // input A source slot, or GRAPH_CELL_SRC_ZERO
	PackedInt32Array in_b; // input B source slot (BLEND only), or GRAPH_CELL_SRC_ZERO
	std::vector<Ref<FastNoiseLite>> noise; // parallel to slots; null unless the op is NOISE or JITTER
	int output = -1; // the slot whose value is the graph's output
	int count = 0;
	bool is_empty() const { return count == 0 || output < 0 || output >= count; }
};

// Read a program dictionary (keys "ops"/"params"/"in_a"/"in_b"/"noise"/"output") produced by
// Pasture3DTerrainGraph.compile_cell_program. False — and r_out left empty — when the dictionary is
// missing a key, the parallel arrays disagree in length, or the output slot is out of range; the caller
// must then treat the graph as producing a flat 0, never read a malformed program.
bool graph_cell_build(const Dictionary &p_prog, GraphCellProgram &r_out);

// Evaluate the program at world (wx, wz). `r_scratch` holds one value per slot and is grown as needed by
// the caller so a grid loop reuses one allocation. Returns the output slot's value in double, so the
// accumulation matches the GDScript oracle (whose floats are doubles) rather than drifting in float.
double graph_cell_eval(const GraphCellProgram &p_prog, double p_wx, double p_wz,
		std::vector<double> &r_scratch);

// Map a cell to its WORLD XZ, cell-CENTRE over p_rect — a byte-for-byte port of
// Pasture3DTerrainGraph.cell_to_world. Shared so the native path and the GDScript oracle sample the
// identical point; a mapping disagreement would read as an evaluator bug.
void graph_cell_to_world(int p_ix, int p_iz, int p_gw, int p_gh, const Rect2 &p_rect,
		double &r_wx, double &r_wz);

// NaN-aware separable box blur — 0.5 centre / 0.25 each neighbour, renormalised at edges and across NaN
// holes, NaN preserved where the input is NaN. A byte-for-byte port of Pasture3DGraphOps.blur_nan (and the
// identical nan_blur in pasture_3d_brush_raster.cpp), so the graph's Smooth node computes the same surface
// on every path. In place; p_passes <= 0 is the identity and allocates nothing.
void graph_nan_blur(std::vector<float> &r_vals, int p_gw, int p_gh, int p_passes);

// ---- Whole-graph evaluator (the native grid-pass interleave & scratch buffer arena) -----------------
struct GraphProgram {
	PackedInt32Array ops; // one GraphCellOpType per slot, topological order
	PackedFloat32Array params; // primary scalar: amplitude | value | blend-mode | smooth-passes | band_height
	PackedFloat32Array params_b; // hardness | frequency | floor_depth | in_max | band_max
	PackedFloat32Array params_c; // amount | octaves | rim_height | out_min | falloff_lo
	PackedFloat32Array params_d; // jitter | gain | rim_width | out_max | falloff_hi
	PackedFloat32Array params_e; // lacunarity | ejecta_falloff | clamp_output | invert
	PackedFloat32Array params_f; // warp_strength | floor_flatness | soft_knee | strength
	PackedFloat32Array params_g; // damp_strength | terrace_steps
	PackedFloat32Array params_h; // dip | wavelength | spacing
	PackedFloat32Array params_i; // dip_direction_deg | asymmetry | direction_deg
	PackedFloat32Array params_j; // break_amount | crest_sharpness | profile
	PackedFloat32Array params_k; // break_size | wander_amount
	PackedFloat32Array params_l; // seed | wander_size
	PackedInt32Array in0; // first input's source slot, or -1 unwired
	PackedInt32Array in1; // second input's source slot, or -1
	PackedInt32Array in2; // third input's source slot (e.g. blend mask), or -1
	std::vector<Ref<FastNoiseLite>> noise; // parallel to slots; null unless NOISE or JITTER
	std::vector<PackedFloat32Array> luts; // parallel to slots; for CURVE
	int output = -1; // the slot whose grid is the graph output
	int count = 0;
	bool is_empty() const { return count == 0 || output < 0 || output >= count; }
};

// Read a program dictionary from Pasture3DTerrainGraph.compile_graph_program.
bool graph_build(const Dictionary &p_prog, GraphProgram &r_out);

// Evaluate the whole graph to a p_gw*p_gh row-major field over p_rect using scratch arena memory reuse.
PackedFloat32Array graph_eval_grid(const GraphProgram &p_prog, int p_gw, int p_gh, const Rect2 &p_rect,
		const PackedFloat32Array &p_input);

// Evaluate the whole graph ONCE and tap several intermediate node buffers from the single pass. Each slot
// in p_tap_slots is protected from the scratch-arena recycle (the same +1 ref count the output gets), so
// the cost is one evaluation regardless of how many taps are requested — the enabling primitive for the
// editor's inline node previews. Returns {slot(int) -> PackedFloat32Array of size p_gw*p_gh}.
Dictionary graph_eval_grid_taps(const GraphProgram &p_prog, int p_gw, int p_gh, const Rect2 &p_rect,
		const PackedFloat32Array &p_input, const PackedInt32Array &p_tap_slots);

} // namespace godot
