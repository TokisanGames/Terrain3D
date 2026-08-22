// Stream-power fluvial erosion solver (Pasture3DSim). See PASTURE3D_SIM_NODE_SPEC.md §4.
//
// Implicit, O(n), unconditionally stable incision after Braun & Willett 2013, over a D8 flow routing
// on a priority-flood-filled surface (Barnes et al. 2014), plus one explicit hillslope-diffusion pass
// per iteration. There is NO uplift term (spec §2): Pasture3D authors its big shapes with brushes and
// Sim erodes what is already there.
//
// Deliberately free of any Pasture3D terrain dependency — it takes a heightfield and returns a
// heightfield plus the derived fields. That is what lets the phase-1 gates drive it directly on
// synthetic terrain (a bowl, a plane, a Y-catchment) instead of only through a baked brush.
//
// CPU by design for phase 1, not by omission — spec §11 records why, and moving it to
// Pasture3DGPURaster is a decision that needs profiling first.

#pragma once

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <vector>

namespace godot {

// Everything the solver reads. Defaults match the Pasture3DSim node's exported defaults so a params
// dictionary that omits a key behaves the same as the node with that property untouched.
struct ErosionParams {
	int gw = 0;
	int gh = 0;
	double cell_size = 1.0; // metres between samples (the SIM grid, not necessarily vertex_spacing)
	int iterations = 30;
	double time_step = 1.0; // Δt; the node folds its own scaling into erosion_rate / diffusion instead
	double erosion_rate = 0.0; // K in §4.3
	double area_exponent = 0.45; // m in §4.3
	double diffusion = 0.0; // D in §4.4, m²/Δt
	// G, the dimensionless sediment deposition coefficient (Yuan et al. 2019). 0 = detachment-limited,
	// i.e. exactly the solver this one replaced: material is removed and never redeposited. Toward 1 the
	// model becomes transport-limited and rivers lay their load back down — alluvial fans, valley fill.
	//
	// It is NOT free: the deposition term makes each cell's update depend on how much its whole upstream
	// catchment eroded this step, which is only solvable by iterating. Convergence degrades sharply as G
	// rises (§5 of PASTURE3D_BRUSH_EROSION_SPEC.md), so the sweep count is capped and reported rather
	// than allowed to run away.
	double deposition = 0.0;
	double erodability_min = 1.0; // erodability LUT remap (§7); min==max==1 => uniform
	double erodability_max = 1.0;
	int erodability_w = 0; // LUT dimensions; 0 => no map, erodability is uniform 1.0
	int erodability_h = 0;
	int fill_every = 1; // re-run the depression fill every k iterations (§11 escape hatch)
	bool fill_depressions = true; // GATE A CONTROL: off leaves pits with no downhill receiver
	bool break_stack_order = false; // GATE C CONTROL: accumulate the drainage tree the wrong way
	// GATE BI CONTROL: flood with the original binary heap instead of the monotone bucket queue. The two
	// must agree bitwise (§11's profiling note), and the only way to assert that is to be able to run
	// both. Not exposed on the node — it is slower and identical, so there is nothing to choose.
	bool legacy_flood = false;
	bool want_diagnostics = false; // also return receiver / stack / flow / lake_depth
};

// One solve's outputs, all gw*gh unless noted.
struct ErosionResult {
	std::vector<float> z; // eroded elevation
	std::vector<float> flow; // drainage area, m²
	std::vector<float> lake_depth; // z_filled − z, metres (§4.1)
	std::vector<int> receiver; // D8 receiver index; receiver[i]==i marks an outlet/no-data root
	std::vector<int> stack; // Braun & Willett topological order, roots first
	std::vector<uint8_t> boundary; // 1 = domain edge or no-data, i.e. fixed base level
	int diffusion_substeps = 0; // explicit-diffusion sub-stepping actually used (see §4.4 note)
	// Worst Gauss-Seidel sweep count any one iteration needed for the deposition term, and whether the
	// cap was reached. 0 when `deposition` is 0, which is the whole of the detachment-limited path.
	// Reported for the same reason `diffusion_substeps` is: an artist who asked for something the solver
	// could not deliver in bounded time has to be told, not silently given something else.
	int deposition_sweeps = 0;
	bool deposition_capped = false;
	bool ok = false;
};

// Read an ErosionParams out of a GDScript dictionary. Missing keys keep their defaults.
ErosionParams erosion_params_from_dict(const Dictionary &p_params);

// Run the solve. `p_z` is the initial elevation (gw*gh, row-major); NaN marks a no-data cell, which
// becomes a fixed outlet at the field minimum so water leaves the map there rather than pooling
// against an invisible wall. `p_erodability_lut` is an optional row-major 0..1 image sampled across
// the whole grid (FIT-style, §7) and remapped into [erodability_min, erodability_max].
ErosionResult erosion_solve(const std::vector<float> &p_z, const ErosionParams &p_params,
		const PackedFloat32Array &p_erodability_lut);

// How far the solve currently running has got: `r_done` iterations of `r_total`.
//
// WHY THIS EXISTS. A long solve is one C++ call with no way to say anything until it returns, and
// PASTURE3D_BRUSH_EROSION_SPEC.md §14 runs exactly that call on a worker thread while the editor keeps
// drawing. Progress cannot come from chunking the call: measured, twelve chunks of five iterations
// disagreed with one call of sixty by 9.59 m on a fixture whose mean cut is 59 m, because every chunk
// boundary rounds the working surface through float32 and the routing amplifies it. So the counter comes
// from INSIDE the loop, and the answer is untouched.
//
// (0, 0) means nothing is in flight: before the first solve of the session, and again on the way out of
// every solve. Deliberately not left at (total, total) — the next caller's first poll happens before its
// worker has entered the function, and a stale 100% for work that has not begun is the worst reading of
// the three.
//
// ONE SOLVE AT A TIME. The counter is process-wide, so a second concurrent solve overwrites it and both
// readers see one blended number. That is the honest limit of a progress readout that costs two relaxed
// stores per iteration; the callers are a Sim button and a brush bake, and neither runs two at once.
// Nothing but a printed percentage depends on it.
void erosion_progress(int &r_done, int &r_total);

} // namespace godot
