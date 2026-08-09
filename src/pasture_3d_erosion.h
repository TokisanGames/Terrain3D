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
	double erodability_min = 1.0; // erodability LUT remap (§7); min==max==1 => uniform
	double erodability_max = 1.0;
	int erodability_w = 0; // LUT dimensions; 0 => no map, erodability is uniform 1.0
	int erodability_h = 0;
	int fill_every = 1; // re-run the depression fill every k iterations (§11 escape hatch)
	bool fill_depressions = true; // GATE A CONTROL: off leaves pits with no downhill receiver
	bool break_stack_order = false; // GATE C CONTROL: accumulate the drainage tree the wrong way
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

} // namespace godot
