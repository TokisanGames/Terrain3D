// Relief op-program evaluator (Pasture3DPlow Source = RELIEF). A Pasture3DReliefMaterial compiles itself
// to a flat, branch-free layer list in GDScript; this evaluates that list per cell in C++ so the brush
// keeps the native rasteriser's budget. It is deliberately a fixed op catalogue, not a scripting VM.
//
// The GDScript evaluator in connectors/relief_material.gd is the A/B oracle: every op here must agree
// with it to 1e-4 m on the final amplitude, and the noise construction in relief_build must mirror
// Pasture3DReliefMaterial._configure_noise exactly. See PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md §4-5, §10.

#pragma once

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <functional>
#include <vector>

namespace godot {

// Op ids — MUST stay in sync with Pasture3DReliefMaterial.Op (connectors/relief_material.gd).
enum ReliefOpType {
	RELIEF_OP_CONST = 0,
	RELIEF_OP_FBM = 1,
	RELIEF_OP_RIDGED = 2,
	RELIEF_OP_BILLOW = 3,
	RELIEF_OP_DUNES = 4,
	RELIEF_OP_FURROWS = 5,
	RELIEF_OP_CRATER = 6,
	RELIEF_OP_SCREE = 7,
	RELIEF_OP_WARP = 8,
	RELIEF_OP_TERRACE = 9,
	RELIEF_OP_STRATIFY = 10,
	RELIEF_OP_CLAMP = 11,
	RELIEF_OP_CURVE = 12,
};

// Blend ids — sync with Pasture3DReliefMaterial.Blend. Prefixed because MAX/MIN are godot-cpp macros.
enum ReliefBlendMode {
	RELIEF_BLEND_ADD = 0,
	RELIEF_BLEND_SUB = 1,
	RELIEF_BLEND_MUL = 2,
	RELIEF_BLEND_MAX = 3,
	RELIEF_BLEND_MIN = 4,
	RELIEF_BLEND_REPLACE = 5,
};

constexpr int RELIEF_OP_STRIDE = 4; // [op_type, blend, selector_id, flags]
constexpr int RELIEF_PARAM_STRIDE = 12;
constexpr int RELIEF_FLAG_NEGATE = 1; // bit0
constexpr int RELIEF_FLAG_CLAMP = 2; // bit1
constexpr int RELIEF_CURVE_LUT_N = 256; // samples per baked Curve, one contiguous block per CURVE op
constexpr int RELIEF_SELECTOR_STRIDE = 8; // [kind, min, max, falloff_lo, falloff_hi, invert, strength, _]

// Selector kinds — sync with Pasture3DReliefSelector.Kind.
enum ReliefSelectorKind {
	RELIEF_SELECT_SLOPE = 0, // degrees
	RELIEF_SELECT_ALTITUDE = 1, // world metres
	RELIEF_SELECT_CURVATURE = 2, // Laplacian; positive = hollow
};

// What the ground BELOW this brush's layer is doing at one cell. Selectors and SCREE read it; every
// other op ignores it. Zeroed when the program does not need it, so it costs nothing to pass.
struct ReliefSample {
	double altitude = 0.0;
	double slope_deg = 0.0;
	double curvature = 0.0;
	double grad_x = 0.0;
	double grad_z = 0.0;
};

// Built ONCE per bake, never per cell. `noise_a`/`noise_b` are parallel to the op index; entries are null
// for ops that need no noise, and `noise_b` is only populated for WARP's second (decorrelated) field.
struct ReliefProgram {
	PackedInt32Array ops;
	PackedFloat32Array params;
	PackedFloat32Array luts; // concatenated RELIEF_CURVE_LUT_N blocks, indexed by a CURVE op's slot
	PackedFloat32Array selectors; // stride-8 blocks, indexed by an op's selector_id
	std::vector<Ref<FastNoiseLite>> noise_a;
	std::vector<Ref<FastNoiseLite>> noise_b;
	int count = 0;
	bool is_empty() const { return count == 0; }
};

// Per-cell terrain fields over the bake grid, derived once from the below-layer heights. Mirrors
// Pasture3DPlow._terrain_fields — same formula, same input, so the two paths agree.
struct ReliefFields {
	std::vector<float> altitude, slope_deg, curvature, grad_x, grad_z;
	int gw = 0, gh = 0;
	bool ready = false;
	void sample(int p_index, ReliefSample &r_out) const;
};

// How overlapping SCATTER instances combine. Sync with Pasture3DPlow.ScatterBlend.
enum ReliefScatterBlend {
	RELIEF_SCATTER_STRONGEST = 0, // largest magnitude wins — the deepest crater / tallest mound
	RELIEF_SCATTER_ADD = 1,
	RELIEF_SCATTER_MAX = 2,
	RELIEF_SCATTER_MIN = 3,
};

constexpr int RELIEF_INSTANCE_STRIDE = 6; // [cx, cz, radius, cos_rot, sin_rot, amp_scale]

// SCATTER acceleration: a uniform grid over the brush footprint so each cell only tests instances that
// can actually reach it. Without it the cell loop is O(cells x instances). Buckets hold indices in
// ASCENDING order, which is what keeps the result bitwise identical to the GDScript oracle's linear scan
// (the contributing set and its order are the same; the grid only skips instances that contribute 0).
struct ReliefScatter {
	PackedFloat32Array instances;
	std::vector<std::vector<int>> buckets;
	double min_x = 0.0;
	double min_z = 0.0;
	double cell = 1.0;
	int gw = 0;
	int gh = 0;
	int blend = RELIEF_SCATTER_STRONGEST;
	int count = 0;
	bool is_empty() const { return count == 0; }
};

// Read "ops"/"op_params"/"op_luts"/"op_selectors" out of the brush's params dict and construct the per-op
// noise. False when the program is empty or malformed — the caller must then skip the cell loop entirely.
bool relief_build(const Dictionary &p_params, ReliefProgram &r_prog);

// Derive the slope/curvature/gradient grids from a below-layer height grid. `p_below` may be empty or
// hold NaN where no lower layer covers; `p_fallback` supplies the live height for those cells.
void relief_fields_build(const PackedFloat32Array &p_below, double p_min_x, double p_min_z, double p_vs,
		int p_gw, int p_gh, const std::function<float(double, double)> &p_fallback, ReliefFields &r_out);

// Read "instances"/"scatter_blend" and bucket them over the footprint. False when there are none.
bool relief_scatter_build(const Dictionary &p_params, double p_min_x, double p_min_z, double p_vs,
		int p_gw, int p_gh, ReliefScatter &r_out);

// Evaluate every instance covering world (x,z) and combine them. Each instance evaluates the program in
// its own rotated, radius-normalised frame, windowed to zero at its edge so instances do not cut discs.
double relief_scatter_eval(const ReliefProgram &p_prog, const ReliefScatter &p_sc, double p_x, double p_z,
		const ReliefSample &p_ground);

// Evaluate at one cell. `u,v` are metres in the active mapping frame; `nu,nv` the same point normalised
// to the loop's half-extents; `inv_ex,inv_ez` convert a metre offset into that normalised space so WARP
// displaces both consistently. Returns the signed accumulator, deliberately not hard-clamped (spec §4.4).
// Returns double (not float) so the accumulation order matches the GDScript oracle exactly.
double relief_eval(const ReliefProgram &p_prog, double u, double v, double nu, double nv,
		double inv_ex, double inv_ez, const ReliefSample &p_ground);

} // namespace godot
