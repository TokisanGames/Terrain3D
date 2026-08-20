// Relief op-program evaluator (Pasture3DPlow Source = RELIEF). A Pasture3DReliefMaterial compiles itself
// to a flat, branch-free layer list in GDScript; this evaluates that list per cell in C++ so the brush
// keeps the native rasteriser's budget. It is deliberately a fixed op catalogue, not a scripting VM.
//
// The GDScript evaluator in connectors/pasture3d_relief_material.gd is the A/B oracle: every op here must agree
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

// Op ids — MUST stay in sync with Pasture3DReliefMaterial.Op (connectors/pasture3d_relief_material.gd).
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
// bits 2-3: which coordinate a PROFILE band op quantises (BM phase §4.2). Packed into the existing flags
// word rather than spending a param slot, because TERRACE and STRATIFY do not agree on which slots are
// free and one rule that holds for both is worth more than two rules that each fit.
constexpr int RELIEF_FLAG_BAND_SHIFT = 2;
constexpr int RELIEF_FLAG_BAND_MASK = 3 << RELIEF_FLAG_BAND_SHIFT;
constexpr int RELIEF_CURVE_LUT_N = 256; // samples per baked Curve, one contiguous block per CURVE op
// Hollow depth, in metres over one cell, at which SCREE's toe deposition reaches full strength. Sync with
// Pasture3DReliefMaterial.SCREE_TOE_FULL_M — see the note on relief_scree.
constexpr double RELIEF_SCREE_TOE_FULL_M = 0.25;
// [filter_type, min, max, falloff_lo, falloff_hi, invert, strength, measure_radius, field_source].
//
// The stride was 8 until the host-profile phase added `field_source`. Widening it is safe and needs no
// migration BECAUSE THE BLOCK IS NEVER SERIALISED — it is rebuilt from the selector resources on every
// compile, so nothing on disk carries the old width. (Contrast the `kind` -> `filter_type` rename, which
// touched a stored property and therefore needed the `_set` shim in pasture3d_relief_selector.gd.)
constexpr int RELIEF_SELECTOR_STRIDE = 9;
constexpr int RELIEF_SELECTOR_RADIUS = 7; // slot of `measure_radius`, in METRES; 0 = one cell
constexpr int RELIEF_SELECTOR_FIELD_SOURCE = 8; // slot of `field_source`, a ReliefFieldSource

// Which surface a selector's SLOPE / ALTITUDE / CURVATURE reads. Sync with
// Pasture3DReliefSelector.FieldSource. The four sim filter types ignore this — a Sim Result is one field
// with one meaning, and there is no host-profile version of "how much land drains through here".
//
// BELOW is the historical behaviour and the default: the composite of the layers UNDER this brush's own,
// which is what stops a brush gating on its own output and drifting.
//
// HOST is the brush's own generated shape, before any relief is added to it — a Mound's dome, a Ridge's
// crest section. It cannot drift either, and for the same structural reason: the profile is a function of
// the loop and the shape properties ONLY, so relief keyed on it can never feed itself. It exists because
// on a Mound placed on flat ground BELOW is constant, every filter type returns one weight, and "craggy
// on the flanks, smooth on top" is not expressible at all.
enum ReliefFieldSource {
	RELIEF_FIELD_BELOW = 0,
	RELIEF_FIELD_HOST = 1,
};

// Which coordinate TERRACE / STRATIFY quantise into bands. Sync with Pasture3DReliefMaterial.BandSource.
//
// ACCUMULATOR is the historical behaviour and the default: band whatever relief is already in `acc`.
// Standalone that is the material's own built-in fractal, which is why a Terraces material on a Mound
// banded NOISE rather than the hill.
//
// HOST_PROFILE bands the host brush's own shape, normalised by the divisor the brush stores
// (ReliefFields::norm_divisor). Benches then lie on the hill's contours, which is what terracing a hill
// means. GROUND_ALTITUDE bands world height out of the below-layer composite, over the material's own
// authored range — strata that hold one geological elevation across several brushes.
enum ReliefBandSource {
	RELIEF_BAND_ACCUMULATOR = 0,
	RELIEF_BAND_HOST_PROFILE = 1,
	RELIEF_BAND_GROUND_ALTITUDE = 2,
};

// Param slots carrying a GROUND_ALTITUDE band's world-metre range. 7 and 8 are the lowest pair free in
// BOTH TERRACE (uses 0-4) and STRATIFY (uses 0-6), so one rule covers both ops.
constexpr int RELIEF_BAND_RANGE_LO = 7;
constexpr int RELIEF_BAND_RANGE_HI = 8;

// Selector filter types — sync with Pasture3DReliefSelector.FilterType. (The GDScript property was
// called `kind` until it was renamed for legibility; the ids and the wire slot are unchanged.)
//
// 0-2 read the ground's own shape. 3-6 read a Pasture3DSimResult, i.e. what the erosion sim did here
// (PASTURE3D_SIM_NODE_SPEC.md §9). Each is in the units an artist would type into the band, which for
// two of them is NOT the unit the resource stores — see ReliefSample below.
enum ReliefSelectorFilterType {
	RELIEF_SELECT_SLOPE = 0, // degrees
	RELIEF_SELECT_ALTITUDE = 1, // world metres
	RELIEF_SELECT_CURVATURE = 2, // METRES of deviation over measure_radius; positive = hollow (§21.6)
	RELIEF_SELECT_FLOW = 3, // upstream drainage area, m²
	RELIEF_SELECT_EROSION = 4, // metres of material removed, POSITIVE
	RELIEF_SELECT_DEPOSITION = 5, // metres of material gained
	RELIEF_SELECT_WETNESS = 6, // standing water depth, metres
};

// What the ground BELOW this brush's layer is doing at one cell. Selectors and SCREE read it; every
// other op ignores it. Zeroed when the program does not need it, so it costs nothing to pass.
//
// The four sim fields are converted ON THE WAY IN, in relief_fields_add_sim, so the evaluator is a plain
// comparison and the conversion happens once per cell rather than once per gated op. Two of them do not
// match how Pasture3DSimResult stores the channel, and both differences are deliberate:
//
//   sim_flow     the resource stores log(area); this is the AREA, in m², so a band reads
//                "more than 10 000 m² drains through here" instead of "more than 9.2 log-units"
//   sim_erosion  the resource stores a negative delta; this is the POSITIVE depth removed, so a band
//                reads "5 to 50 m stripped" instead of "-50 to -5"
//
// `curvature` is METRES of deviation, not the raw Laplacian: mean(the sample ring at one cell) minus the
// centre height (§21.6). SCREE reads this one-cell value; a SLOPE or CURVATURE selector with a non-zero
// `measure_radius` reads a wider one instead, which is what `fields`/`index` are for.
struct ReliefSample {
	double altitude = 0.0;
	double slope_deg = 0.0;
	double curvature = 0.0; // metres of deviation over ONE CELL
	double grad_x = 0.0;
	double grad_z = 0.0;
	double sim_flow = 0.0; // m² of upstream catchment (un-logged)
	double sim_erosion = 0.0; // metres removed, positive
	double sim_deposition = 0.0; // metres gained
	double sim_wetness = 0.0; // metres of standing water
	// --- The HOST PROFILE set: the same three measurements over the brush's OWN generated shape, in the
	// same units, for a selector whose `field_source` is RELIEF_FIELD_HOST. Zero and `has_host == false`
	// when the caller built no host fields, and a host-source selector then reads a defined zero rather
	// than silently falling back to the below-layer numbers — falling back would make a mis-set
	// `field_source` invisible, which is the one failure this split must not have.
	//
	// `host_altitude` is the brush's own contribution in METRES, i.e. the delta it adds, NOT the absolute
	// world height. That is deliberate: it answers "how far up this hill am I" independently of what the
	// hill was placed on, which is the property that makes a host-keyed selector non-drifting.
	double host_altitude = 0.0;
	double host_slope_deg = 0.0;
	double host_curvature = 0.0;
	// `host_altitude` over the divisor the host brush stored (a Mound's `height`), so a band op reads
	// 0 at the rim and 1 at the crest whatever the brush's scale. Pre-divided here rather than in the
	// evaluator so the divisor lives in exactly one place — on the fields object the brush filled.
	double host_norm = 0.0;
	bool has_host = false;
	// Where this sample came from, so a selector with a `measure_radius` can reach the wider grids its own
	// id owns (§21.6). Set by ReliefFields::sample / sample_host and only read while those ReliefFields
	// are alive — every caller fills the sample from fields objects on the same stack frame as the cell
	// loop. Null/-1 means "no wider fields available", and the selector then falls back to the one-cell
	// value, which is what an unmeasured caller wants anyway.
	const struct ReliefFields *fields = nullptr; // below-layer
	const struct ReliefFields *host_fields = nullptr; // host profile
	int index = -1;
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
	// The sim channels, resampled onto this grid from a Pasture3DSimResult's own extent. Empty unless a
	// selector of a sim Kind is in the program — four more grids is not a cost to pay for a slope gate.
	std::vector<float> sim_flow, sim_erosion, sim_deposition, sim_wetness;
	// §21.6: slope and curvature measured over a WIDER stencil, one slot per distinct non-zero
	// `measure_radius` in the selector block. `sel_slot[sid]` is the slot selector `sid` reads, or -1 for
	// the one-cell fields above — which is what every selector gets until someone asks for a radius, so a
	// program without one allocates nothing here.
	std::vector<std::vector<float>> measured_slope, measured_curvature;
	std::vector<int> sel_slot;
	double vs = 1.0; // the grid's own spacing, kept so a radius in metres can be turned into cells
	// What a HOST-PROFILE fields object divides its altitude by to reach 0..1 — the host brush's own
	// height. Set by the caller that built the grid, because the brush is the only thing that knows it.
	// Meaningless on a below-layer fields object, where it stays 1.0 and nothing reads it.
	double norm_divisor = 1.0;
	int gw = 0, gh = 0;
	bool ready = false;
	bool has_sim = false;
	void sample(int p_index, ReliefSample &r_out) const;
	// Fill the host half of a sample already filled by a below-layer `sample`. Separate call rather than
	// a second argument to `sample` so the common path — no host fields at all — costs nothing and reads
	// as costing nothing.
	void sample_host(int p_index, ReliefSample &r_out) const;
	// Slope in degrees / curvature in metres at `p_index`, over the radius selector `p_sid` asked for.
	// Both fall back to the one-cell field, so an unmeasured selector costs one bounds test.
	double slope_for(int p_sid, int p_index) const;
	double curvature_for(int p_sid, int p_index) const;
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

// Resample a Pasture3DSimResult onto an already-built ReliefFields grid (spec §9). `p_sim` is the
// resource flattened to {min_x, min_z, cell_size, width, height, flow, erosion, deposition, wetness} —
// C++ cannot see the GDScript class, and the extent travels with the data because the result is at SIM
// resolution over the SIMULATED area and does not share the bake grid.
//
// Outside the result's extent every channel reads its DEFINED zero, never garbage: 0 m removed, 0 m
// gained, 0 m of water, and 1 m² of catchment (a cell drains itself, which is what exp(0) means inside
// the grid too). No-op, leaving has_sim false, when the dictionary is missing or malformed.
void relief_fields_add_sim(const Dictionary &p_sim, double p_min_x, double p_min_z, double p_vs,
		int p_gw, int p_gh, ReliefFields &r_fields);

// §21.6: build the wider slope/curvature grids the selector block's `measure_radius` values ask for, on an
// already-built ReliefFields. A no-op when every selector leaves the radius at 0, which is the default and
// the whole of today's behaviour — so a SLOPE band authored before this phase pays nothing and, more to the
// point, reads exactly the grid it always read.
//
// MUST be called with the same selector block the evaluation will use: the slots are indexed by selector
// id. Radii are deduplicated, so N selectors sharing one radius build one pair of grids.
//
// `p_field_source` names which fields object this is, so a set only builds the radii ITS OWN selectors
// asked for: a host-source selector with a 20 m radius must not make the below-layer set build a 20 m
// pair it will never read. Selectors naming the other source get slot -1 here and fall back to that set's
// one-cell field, which they never reach anyway.
void relief_fields_add_measured(const PackedFloat32Array &p_selectors, ReliefFields &r_fields,
		int p_field_source = RELIEF_FIELD_BELOW);

// One selector's 0..1 weight at one cell, for callers outside the relief evaluator — Sim's §17 mask field
// is the only one today. A thin wrapper over the internal evaluator rather than a second copy of it: the
// gate that matters is that a SLOPE band gates a Sim exactly as it gates a Plow, and two implementations
// of that arithmetic would eventually disagree.
double relief_selector_weight(const PackedFloat32Array &p_selectors, int p_sid, const ReliefSample &p_ground);

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
