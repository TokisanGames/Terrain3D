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

// Cell-node op ids — MUST stay in sync with the op() tags in project/addons/pasture_3d/graph/. These are a
// WIRE FORMAT between compile_cell_program (GDScript) and graph_cell_build (here); a new cell node appends
// an id rather than renumbering, exactly as the relief catalogue does.
enum GraphCellOpType {
	GRAPH_OP_NOISE = 1, // GENERATOR: params[slot] * noise[slot].get_noise_2d(wx, wz)
	GRAPH_OP_CONST = 2, // GENERATOR: params[slot]
	GRAPH_OP_BLEND = 3, // COMBINER: in_a (o) in_b, o = params[slot] cast to GraphBlendMode
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
	PackedFloat32Array params; // one scalar per slot: amplitude | value | blend-mode
	PackedInt32Array in_a; // input A source slot, or GRAPH_CELL_SRC_ZERO
	PackedInt32Array in_b; // input B source slot (BLEND only), or GRAPH_CELL_SRC_ZERO
	std::vector<Ref<FastNoiseLite>> noise; // parallel to slots; null unless the op is NOISE
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

} // namespace godot
