// Native spline-brush rasterisers (Round 2 perf). A faithful C++ port of the per-cell rasterisation in
// Pasture3DTerrainBrush (GDScript), which dominated large-edit bake time (~730 ms interpreted). These run
// the same SDF/chamfer + per-cell profile math natively and write into the layer via the existing
// (deferred) layer-write API, so they slot under the unchanged Round 1 orchestration. The GDScript loops
// are kept as a fallback / A-B reference. See PASTURE3D_BRUSH_PERF_ROUND2_SPEC.md.

#include "pasture_3d_data.h"
#include "pasture_3d_erosion.h"
#include "pasture_3d_gpu_raster.h"
#include "pasture_3d_graph_ops.h"
#include "pasture_3d_raster_util.h"
#include "pasture_3d_relief_ops.h"
#include "pasture_3d_util.h"

#include <godot_cpp/classes/fast_noise_lite.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

using namespace godot;

namespace {

constexpr float RBIG = 1.0e9f;

// Linear lookup into a 0..1 ramp LUT. The brush always bakes a full LUT (curve or analytic default), so
// n>=2 in practice; the n==0/1 guards are just safety.
inline float raster_ramp(const PackedFloat32Array &lut, float x) {
	if (x < 0.f) {
		x = 0.f;
	} else if (x > 1.f) {
		x = 1.f;
	}
	const int n = lut.size();
	if (n == 0) {
		return x * x * (3.f - 2.f * x); // smoothstep(0,1,x) fallback
	}
	if (n == 1) {
		return lut[0];
	}
	const float f = x * (n - 1);
	int i0 = (int)f;
	if (i0 >= n - 1) {
		return lut[n - 1];
	}
	const float frac = f - (float)i0;
	return lut[i0] * (1.f - frac) + lut[i0 + 1] * frac;
}

// NaN-aware separable 3-tap Gaussian blur of a packed grid, in place. NaN cells are skipped (treated as
// "no contribution") so the blur never bleeds a feature outward past its footprint. No-op and NO
// allocation when passes <= 0, so an unused smoother costs nothing. Shared by the spline height brushes
// (mirrors Pasture3DTerrainBrush._blur_grid for A/B parity).
static void nan_blur(std::vector<float> &vals, int gw, int gh, int passes) {
	if (passes <= 0) {
		return;
	}
	std::vector<float> tmp((size_t)gw * gh);
	for (int pass = 0; pass < passes; pass++) {
		// Horizontal: vals -> tmp
		for (int iz = 0; iz < gh; iz++) {
			const int row = iz * gw;
			for (int ix = 0; ix < gw; ix++) {
				const float v = vals[row + ix];
				if (std::isnan(v)) { tmp[row + ix] = (float)NAN; continue; }
				float sum = 0.5f * v, weight = 0.5f;
				if (ix > 0 && !std::isnan(vals[row + ix - 1])) { sum += 0.25f * vals[row + ix - 1]; weight += 0.25f; }
				if (ix < gw - 1 && !std::isnan(vals[row + ix + 1])) { sum += 0.25f * vals[row + ix + 1]; weight += 0.25f; }
				tmp[row + ix] = sum / weight;
			}
		}
		// Vertical: tmp -> vals
		for (int iz = 0; iz < gh; iz++) {
			const int row = iz * gw;
			for (int ix = 0; ix < gw; ix++) {
				const float v = tmp[row + ix];
				if (std::isnan(v)) { vals[row + ix] = (float)NAN; continue; }
				float sum = 0.5f * v, weight = 0.5f;
				if (iz > 0 && !std::isnan(tmp[(iz - 1) * gw + ix])) { sum += 0.25f * tmp[(iz - 1) * gw + ix]; weight += 0.25f; }
				if (iz < gh - 1 && !std::isnan(tmp[(iz + 1) * gw + ix])) { sum += 0.25f * tmp[(iz + 1) * gw + ix]; weight += 0.25f; }
				vals[row + ix] = sum / weight;
			}
		}
	}
}

// Two-pass chamfer distance transform, in place (port of Pasture3DTerrainBrush._chamfer).
void raster_chamfer(std::vector<float> &arr, int gw, int gh, float a, float b) {
	for (int iz = 0; iz < gh; iz++) {
		const int row = iz * gw;
		for (int ix = 0; ix < gw; ix++) {
			const int i = row + ix;
			float d = arr[i];
			if (iz > 0) {
				const int up = i - gw;
				if (arr[up] + a < d) {
					d = arr[up] + a;
				}
				if (ix > 0 && arr[up - 1] + b < d) {
					d = arr[up - 1] + b;
				}
				if (ix < gw - 1 && arr[up + 1] + b < d) {
					d = arr[up + 1] + b;
				}
			}
			if (ix > 0 && arr[i - 1] + a < d) {
				d = arr[i - 1] + a;
			}
			arr[i] = d;
		}
	}
	for (int iz = gh - 1; iz >= 0; iz--) {
		const int row = iz * gw;
		for (int ix = gw - 1; ix >= 0; ix--) {
			const int i = row + ix;
			float d = arr[i];
			if (iz < gh - 1) {
				const int dn = i + gw;
				if (arr[dn] + a < d) {
					d = arr[dn] + a;
				}
				if (ix < gw - 1 && arr[dn + 1] + b < d) {
					d = arr[dn + 1] + b;
				}
				if (ix > 0 && arr[dn - 1] + b < d) {
					d = arr[dn - 1] + b;
				}
			}
			if (ix < gw - 1 && arr[i + 1] + a < d) {
				d = arr[i + 1] + a;
			}
			arr[i] = d;
		}
	}
}

// Signed distance field of a closed world polygon over the grid (port of _signed_distance_field).
// Fills `field` (gw*gh, positive inside / negative outside, metres); returns max interior distance.
float raster_sdf(const PackedVector2Array &poly, double min_x, double min_z, double vs, int gw, int gh, std::vector<float> &field) {
	const int n = gw * gh;
	const int pc = poly.size();
	std::vector<uint8_t> inside(n, 0);
	std::vector<float> xs;
	for (int iz = 0; iz < gh; iz++) {
		const double zc = min_z + iz * vs;
		xs.clear();
		for (int e = 0; e < pc; e++) {
			const Vector2 pa = poly[e];
			const Vector2 pb = poly[(e + 1) % pc];
			if ((pa.y <= zc && pb.y > zc) || (pb.y <= zc && pa.y > zc)) {
				const double tt = (zc - pa.y) / (pb.y - pa.y);
				xs.push_back((float)(pa.x + tt * (pb.x - pa.x)));
			}
		}
		std::sort(xs.begin(), xs.end());
		const int row = iz * gw;
		size_t k = 0;
		while (k + 1 < xs.size()) {
			int ix0 = (int)std::ceil((xs[k] - min_x) / vs);
			int ix1 = (int)std::floor((xs[k + 1] - min_x) / vs);
			if (ix0 < 0) {
				ix0 = 0;
			}
			if (ix1 > gw - 1) {
				ix1 = gw - 1;
			}
			for (int ix = ix0; ix <= ix1; ix++) {
				inside[row + ix] = 1;
			}
			k += 2;
		}
	}
	std::vector<float> din(n), dout(n);
	for (int i = 0; i < n; i++) {
		if (inside[i]) {
			din[i] = RBIG;
			dout[i] = 0.f;
		} else {
			din[i] = 0.f;
			dout[i] = RBIG;
		}
	}
	const float diag = (float)(vs * 1.4142135624);
	raster_chamfer(din, gw, gh, (float)vs, diag);
	raster_chamfer(dout, gw, gh, (float)vs, diag);
	field.assign(n, 0.f);
	float max_inside = 0.f;
	for (int i = 0; i < n; i++) {
		if (inside[i]) {
			field[i] = din[i];
			if (din[i] < RBIG && din[i] > max_inside) {
				max_inside = din[i];
			}
		} else {
			field[i] = -dout[i];
		}
	}
	return max_inside;
}

// Chamfer that carries two payloads with the nearest-feature distance (port of _chamfer_payload).
void raster_chamfer_payload(std::vector<float> &dist, std::vector<float> &p1, std::vector<float> &p2, int gw, int gh, float a, float b) {
	for (int iz = 0; iz < gh; iz++) {
		const int row = iz * gw;
		for (int ix = 0; ix < gw; ix++) {
			const int i = row + ix;
			float bd = dist[i];
			int bj = -1;
			if (iz > 0) {
				const int up = i - gw;
				if (dist[up] + a < bd) { bd = dist[up] + a; bj = up; }
				if (ix > 0 && dist[up - 1] + b < bd) { bd = dist[up - 1] + b; bj = up - 1; }
				if (ix < gw - 1 && dist[up + 1] + b < bd) { bd = dist[up + 1] + b; bj = up + 1; }
			}
			if (ix > 0 && dist[i - 1] + a < bd) { bd = dist[i - 1] + a; bj = i - 1; }
			if (bj >= 0) { dist[i] = bd; p1[i] = p1[bj]; p2[i] = p2[bj]; }
		}
	}
	for (int iz = gh - 1; iz >= 0; iz--) {
		const int row = iz * gw;
		for (int ix = gw - 1; ix >= 0; ix--) {
			const int i = row + ix;
			float bd = dist[i];
			int bj = -1;
			if (iz < gh - 1) {
				const int dn = i + gw;
				if (dist[dn] + a < bd) { bd = dist[dn] + a; bj = dn; }
				if (ix < gw - 1 && dist[dn + 1] + b < bd) { bd = dist[dn + 1] + b; bj = dn + 1; }
				if (ix > 0 && dist[dn - 1] + b < bd) { bd = dist[dn - 1] + b; bj = dn - 1; }
			}
			if (ix < gw - 1 && dist[i + 1] + a < bd) { bd = dist[i + 1] + a; bj = i + 1; }
			if (bj >= 0) { dist[i] = bd; p1[i] = p1[bj]; p2[i] = p2[bj]; }
		}
	}
}

// Three-payload chamfer: same nearest-feature propagation as raster_chamfer_payload but carries p3 too.
void raster_chamfer_payload3(std::vector<float> &dist, std::vector<float> &p1, std::vector<float> &p2, std::vector<float> &p3, int gw, int gh, float a, float b) {
	for (int iz = 0; iz < gh; iz++) {
		const int row = iz * gw;
		for (int ix = 0; ix < gw; ix++) {
			const int i = row + ix;
			float bd = dist[i];
			int bj = -1;
			if (iz > 0) {
				const int up = i - gw;
				if (dist[up] + a < bd) { bd = dist[up] + a; bj = up; }
				if (ix > 0 && dist[up - 1] + b < bd) { bd = dist[up - 1] + b; bj = up - 1; }
				if (ix < gw - 1 && dist[up + 1] + b < bd) { bd = dist[up + 1] + b; bj = up + 1; }
			}
			if (ix > 0 && dist[i - 1] + a < bd) { bd = dist[i - 1] + a; bj = i - 1; }
			if (bj >= 0) { dist[i] = bd; p1[i] = p1[bj]; p2[i] = p2[bj]; p3[i] = p3[bj]; }
		}
	}
	for (int iz = gh - 1; iz >= 0; iz--) {
		const int row = iz * gw;
		for (int ix = gw - 1; ix >= 0; ix--) {
			const int i = row + ix;
			float bd = dist[i];
			int bj = -1;
			if (iz < gh - 1) {
				const int dn = i + gw;
				if (dist[dn] + a < bd) { bd = dist[dn] + a; bj = dn; }
				if (ix < gw - 1 && dist[dn + 1] + b < bd) { bd = dist[dn + 1] + b; bj = dn + 1; }
				if (ix > 0 && dist[dn - 1] + b < bd) { bd = dist[dn - 1] + b; bj = dn - 1; }
			}
			if (ix < gw - 1 && dist[i + 1] + a < bd) { bd = dist[i + 1] + a; bj = i + 1; }
			if (bj >= 0) { dist[i] = bd; p1[i] = p1[bj]; p2[i] = p2[bj]; p3[i] = p3[bj]; }
		}
	}
}

// Feature field of a world-space polyline over the grid (port of _polyline_field). Fills lat / base_y /
// along (size gw*gh); returns the polyline's total arc length.
float raster_polyline_field(const PackedVector3Array &pts, double min_x, double min_z, double vs, int gw, int gh,
		std::vector<float> &lat, std::vector<float> &base_y, std::vector<float> &along) {
	const int n = gw * gh;
	lat.assign(n, RBIG);
	base_y.assign(n, 0.f);
	along.assign(n, 0.f);
	const double sample = vs * 0.5;
	double run = 0.0;
	const int np = pts.size();
	for (int k = 0; k < np - 1; k++) {
		const Vector3 a = pts[k];
		const Vector3 b = pts[k + 1];
		const double ax = a.x;
		const double az = a.z;
		const double seg = std::sqrt((b.x - ax) * (b.x - ax) + (b.z - az) * (b.z - az));
		const double along_a = run;
		run += seg;
		int steps = (int)std::ceil(seg / sample);
		if (steps < 1) {
			steps = 1;
		}
		for (int s = 0; s <= steps; s++) {
			const double tt = (double)s / (double)steps;
			const int ix = (int)std::lround((ax + (b.x - ax) * tt - min_x) / vs);
			const int iz = (int)std::lround((az + (b.z - az) * tt - min_z) / vs);
			if (ix >= 0 && ix < gw && iz >= 0 && iz < gh) {
				const int idx = iz * gw + ix;
				lat[idx] = 0.f;
				base_y[idx] = (float)(a.y + (b.y - a.y) * tt);
				along[idx] = (float)(along_a + seg * tt);
			}
		}
	}
	raster_chamfer_payload(lat, base_y, along, gw, gh, (float)vs, (float)(vs * 1.4142135624));
	return (float)run;
}


// ---- The brush modifier stack (PASTURE3D_BRUSH_EROSION_SPEC.md §6) ----
//
// One compiled step of a brush's modifier list. Built ONCE per bake from the array of dictionaries
// `Pasture3DTerrainBrush._compile_modifiers` hands over, never per cell.
//
// POINT steps (noise, relief) contribute metres at one cell and are folded into the rasteriser's own
// loop in double precision, exactly where the hard-coded `+ noise` / `+ relief` used to sit. FIELD steps
// (smoothing, erosion) need the whole grid and force the working values to be materialised at their
// position in the list. See the header of connectors/pasture3d_brush_modifier.gd for why that split is
// structural rather than an optimisation.
struct BrushModStep {
	enum Kind { NOISE = 0, RELIEF = 1, SMOOTH = 2, EROSION = 3, GRAPH = 4 };
	int kind = NOISE;
	bool field = false;
	Ref<FastNoiseLite> noise; // NOISE
	double strength = 0.0; // NOISE / RELIEF: metres at full output
	ReliefProgram prog; // RELIEF
	double mat_strength = 1.0; // RELIEF: the material's own Strength multiplier
	int passes = 0; // SMOOTH
	// GRAPH (the terrain-graph grid-pass interleave). `graph_prog` is the whole-graph program; `graph_amount`
	// the 0..1 composite amount; `graph_reads_input`/`graph_content_key` drive the frozen key the same way
	// _apply_graph_step does — key on the input surface only for a FILTER graph, else on the revision alone.
	GraphProgram graph_prog;
	double graph_amount = 1.0;
	bool graph_reads_input = false;
	int64_t graph_content_key = 0;
	ErosionParams erosion; // EROSION
	PackedFloat32Array erodability; // EROSION: the hardness LUT, empty for uniform rock
	bool publish_fields = false; // EROSION: write the four channels into the stack's field context
	// EROSION freezing (§6.3). `frozen` caches the solve; `cache` is what the modifier had stored for
	// THIS grid extent, and `cache_key` the surface it was solved for. `out` is the modifier's own
	// Dictionary — a reference type, so writing into it here is how the result gets back to GDScript.
	bool frozen = false;
	// EROSION, PASTURE3D_BRUSH_EROSION_SPEC.md sec14: pass 1 of the deferred solve. Hand the surface this
	// step WOULD have solved back through `out` and leave the grid alone, so the main thread can solve it
	// on a worker and bake again. Only ever set on a FROZEN step: the cache is how the answer returns.
	bool defer = false;
	// RELIEF: hand the working surface back BEFORE this step runs, so a material that has to be built
	// from the stack above it (a ridge-seeded DLA) can see what that stack produced. Deliberately the
	// surface at THIS step's position and not the finished one -- a material seeded on its own output
	// would drift, and here it structurally cannot.
	bool capture = false;
	// Whether GDScript handed over an `out` slot at all. NOT `out.is_empty()`: the slot arrives EMPTY —
	// it is what this function fills — so emptiness says nothing about whether anyone is listening.
	bool has_out = false;
	int64_t cache_key = 0;
	PackedFloat32Array cache, cache_flow, cache_ero, cache_dep, cache_wet;
	Dictionary out;
};

constexpr uint64_t BRUSH_FNV_OFFSET = 1469598103934665603ULL;
constexpr uint64_t BRUSH_FNV_PRIME = 1099511628211ULL;

inline uint64_t brush_fnv(uint64_t p_h, uint64_t p_v) {
	return (p_h ^ p_v) * BRUSH_FNV_PRIME;
}

// A key for one frozen solve: the EXACT surface handed to the solver, plus the settings that surface
// does not capture. Hashing the input grid rather than enumerating what fed it is what makes staleness
// detection complete — the spline, the shape properties and every modifier above this one are all in
// there, and none of them can move without moving this.
//
// NaN is canonicalised, because "no data" must hash the same however it was produced.
//
// This does NOT have to agree with the GDScript oracle's key, and deliberately is not made to: each path
// only ever compares keys it wrote itself, and a build that switches rasterisers pays one extra solve.
int64_t brush_mod_erosion_key(const BrushModStep &p_step, const std::vector<float> &p_z) {
	uint64_t h = BRUSH_FNV_OFFSET;
	for (size_t i = 0; i < p_z.size(); i++) {
		uint32_t b;
		const float f = p_z[i];
		std::memcpy(&b, &f, sizeof(b));
		if (std::isnan(f)) {
			b = 0x7fc00000u;
		}
		h = brush_fnv(h, (uint64_t)b);
	}
	// The grid does not change when `iterations` does, so the settings have to be folded in separately.
	const double settings[] = {
		(double)p_step.erosion.iterations, p_step.erosion.erosion_rate, p_step.erosion.area_exponent,
		p_step.erosion.diffusion, p_step.erosion.deposition, p_step.erosion.erodability_min,
		p_step.erosion.erodability_max, (double)p_step.erosion.erodability_w,
		(double)p_step.erosion.erodability_h, p_step.publish_fields ? 1.0 : 0.0
	};
	for (double v : settings) {
		uint64_t b;
		std::memcpy(&b, &v, sizeof(b));
		h = brush_fnv(h, b);
	}
	for (int i = 0; i < p_step.erodability.size(); i++) {
		uint32_t b;
		const float f = p_step.erodability[i];
		std::memcpy(&b, &f, sizeof(b));
		h = brush_fnv(h, (uint64_t)b);
	}
	return (int64_t)h;
}

// Read the "modifiers" array out of the brush's params. Steps that would contribute nothing are dropped
// here rather than tested per cell — an unassigned noise field, a material that compiled to no ops, a
// zero strength, zero blur passes. GDScript already drops the obvious ones (`is_active`); this repeats
// the test because the wire format is a plain dictionary and the rasteriser must not trust it.
//
// Every RELIEF step is built against the ONE stack-wide selector block in `op_selectors`: each material's
// ops had their selector ids rebased into it at compile time, so `ReliefFields::sel_slot` — which is
// keyed by selector id — stays a single flat array however many materials the stack carries.
//
// False when nothing survived, which puts the caller back on the legacy path.
bool brush_mod_build(const Dictionary &p_params, std::vector<BrushModStep> &r_steps) {
	const Array mods = p_params.get("modifiers", Array());
	if (mods.is_empty()) {
		return false;
	}
	const PackedFloat32Array selectors = p_params.get("op_selectors", PackedFloat32Array());
	for (int i = 0; i < mods.size(); i++) {
		const Dictionary d = mods[i];
		const String op = d.get("op", String());
		BrushModStep st;
		if (op == "noise") {
			st.kind = BrushModStep::NOISE;
			Object *obj = d.get("noise", Variant());
			st.noise = Object::cast_to<FastNoiseLite>(obj);
			st.strength = d.get("strength", 0.0);
			if (st.noise.is_null() || st.strength == 0.0) {
				continue;
			}
		} else if (op == "relief") {
			st.kind = BrushModStep::RELIEF;
			st.strength = d.get("strength", 0.0);
			st.mat_strength = d.get("mat_strength", 1.0);
			if (st.strength == 0.0) {
				continue;
			}
			// relief_build reads its program keys off a dictionary; hand it this modifier's own
			// program paired with the stack-wide selector block. The FIELD table stays per-modifier
			// (unlike the selectors): a field op's slot is an index into the material's own compiled
			// table, and a stack already rebased its children's slots into that.
			Dictionary sub;
			sub["ops"] = d.get("ops", PackedInt32Array());
			sub["op_params"] = d.get("op_params", PackedFloat32Array());
			sub["op_luts"] = d.get("op_luts", PackedFloat32Array());
			sub["op_fields"] = d.get("op_fields", PackedFloat32Array());
			sub["op_field_meta"] = d.get("op_field_meta", PackedInt32Array());
			sub["op_selectors"] = selectors;
			st.capture = d.get("capture", false);
			if (st.capture) {
				st.out = d.get("out", Dictionary());
			}
			// An empty program is normally not a step at all. It IS one when the step is also a capture:
			// a material waiting for the surface this capture will hand it compiles to nothing until it
			// has one, so dropping it here is what would make it wait forever. Evaluating a zero-op
			// program costs nothing and contributes nothing, which is the correct behaviour meanwhile.
			if (!relief_build(sub, st.prog) && !st.capture) {
				continue;
			}
		} else if (op == "smooth") {
			st.kind = BrushModStep::SMOOTH;
			st.field = true;
			st.passes = (int)d.get("passes", 0);
			if (st.passes <= 0) {
				continue;
			}
		} else if (op == "erosion") {
			st.kind = BrushModStep::EROSION;
			st.field = true;
			// Same reader the Pasture3DSim node's params go through, so a value tuned on a standalone
			// Sim means the same thing here — which is the whole reason the property names match.
			st.erosion = erosion_params_from_dict(d);
			st.publish_fields = d.get("publish_fields", false);
			st.erosion.want_diagnostics = st.publish_fields;
			st.erodability = d.get("erodability_lut", PackedFloat32Array());
			st.frozen = d.get("frozen", false);
			st.defer = d.get("defer", false);
			st.cache_key = d.get("cache_key", (int64_t)0);
			st.cache = d.get("cache", PackedFloat32Array());
			st.cache_flow = d.get("cache_flow", PackedFloat32Array());
			st.cache_ero = d.get("cache_ero", PackedFloat32Array());
			st.cache_dep = d.get("cache_dep", PackedFloat32Array());
			st.cache_wet = d.get("cache_wet", PackedFloat32Array());
			st.has_out = d.has("out");
			st.out = d.get("out", Dictionary());
			if (st.erosion.iterations < 1 || (st.erosion.erosion_rate == 0.0 && st.erosion.diffusion == 0.0)) {
				continue; // would route water and subtract nothing
			}
		} else if (op == "graph") {
			st.kind = BrushModStep::GRAPH;
			st.field = true;
			st.graph_amount = CLAMP((double)d.get("strength", 1.0), 0.0, 1.0);
			// An empty or unsupported program (a node op the native evaluator does not implement) is not a
			// step. GDScript only takes the native path when native_supported(), so this is a belt-and-braces
			// guard, not the common case.
			const Dictionary prog = d.get("graph_program", Dictionary());
			if (!graph_build(prog, st.graph_prog)) {
				continue;
			}
			st.graph_reads_input = d.get("reads_input", false);
			st.graph_content_key = d.get("content_key", (int64_t)0);
			st.frozen = d.get("frozen", false);
			st.cache_key = d.get("cache_key", (int64_t)0);
			st.cache = d.get("cache", PackedFloat32Array());
			st.has_out = d.has("out");
			st.out = d.get("out", Dictionary());
		} else {
			continue; // an unknown op is a newer plugin's node; skipping beats guessing
		}
		r_steps.push_back(st);
	}
	return !r_steps.empty();
}

// Run one EROSION step over the working grid, in place.
//
// Two mechanical facts, both from §6.8 and both checked against the solver rather than assumed:
//
//  1. THE SOLVER NEEDS AN ABSOLUTE SURFACE, and `vals` under an ADD blend holds a delta. The input is
//     `basey + vals`, and what goes back is `eroded - basey`.
//  2. NaN OUTSIDE THE LOOP IS THE RIGHT BOUNDARY CONDITION, for free. `erosion_solve` turns non-finite
//     input into a fixed outlet at the field minimum, which for a mound is exactly right: the ground off
//     the loop is where the mountain's water goes. It comes back as a real number, so only the cells the
//     brush actually writes are copied out — otherwise the outlet level would be painted across the
//     whole bounding box.
//
// A mountain IS the drainage divide, so nothing upstream feeds it and the Sim's `catchment_margin` —
// quadratic, and much of why a standalone Sim is expensive over a big area — does not apply here.
void brush_mod_erode(BrushModStep &p_step, std::vector<float> &r_vals,
		const std::vector<float> &p_basey, bool p_add, int p_gw, int p_gh, double p_vs,
		ReliefFields &r_fields) {
	const size_t n = (size_t)p_gw * p_gh;
	std::vector<float> z(n);
	for (size_t i = 0; i < n; i++) {
		z[i] = p_add ? (float)((double)p_basey[i] + (double)r_vals[i]) : r_vals[i];
	}
	// ---- FROZEN (§6.3) ----
	//
	// A frozen modifier re-solves only when it has nothing usable cached. Note the three-way split:
	// a MISSING cache solves (reopening a scene must not lose the erosion), a MATCHING cache is served,
	// and a cache for a DIFFERENT surface is served AND reported stale. That last case is the design
	// decision: clearing on edit — which the first draft of the spec called for — throws away a
	// multi-second solve at the exact moment you were mid-comparison. Stale data plus a warning is
	// recoverable; deleted data is not.
	//
	// A cache of the wrong SIZE is not stale, it is unusable: the loop moved and the grid is a different
	// shape, so there is nothing to serve.
	const bool want_key = p_step.frozen && p_step.has_out;
	const int64_t key = want_key ? brush_mod_erosion_key(p_step, z) : 0;
	// A cached surface is not enough on its own. If a modifier BELOW this one now reads the published
	// channels and the entry does not carry them, the cache is unusable however well its key matches —
	// adding a flow-gated modifier does not change the surface handed to the solver, so the key WOULD
	// still match and the new modifier would quietly read zeros.
	const bool want_channels = p_step.publish_fields && r_fields.ready;
	const bool have_cache = p_step.frozen && p_step.cache.size() == (int)n
			&& !(want_channels && p_step.cache_flow.size() != (int)n);
	if (have_cache) {
		const bool stale = p_step.cache_key != key;
		if (p_step.publish_fields && r_fields.ready
				&& p_step.cache_flow.size() == (int)n && p_step.cache_wet.size() == (int)n) {
			r_fields.sim_flow.assign(p_step.cache_flow.ptr(), p_step.cache_flow.ptr() + n);
			r_fields.sim_erosion.assign(p_step.cache_ero.ptr(), p_step.cache_ero.ptr() + n);
			r_fields.sim_deposition.assign(p_step.cache_dep.ptr(), p_step.cache_dep.ptr() + n);
			r_fields.sim_wetness.assign(p_step.cache_wet.ptr(), p_step.cache_wet.ptr() + n);
			r_fields.has_sim = true;
		}
		for (size_t i = 0; i < n; i++) {
			if (std::isnan(r_vals[i])) {
				continue;
			}
			r_vals[i] = p_add ? (float)((double)p_step.cache[i] - (double)p_basey[i]) : p_step.cache[i];
		}
		p_step.out["stale"] = stale;
		p_step.out["served"] = true;
		return;
	}

	// ---- The deferred solve, pass 1 (sec10) ----
	//
	// Nothing is solved and nothing is written: the surface goes out through `out` and the grid keeps the
	// un-eroded shape. The main thread solves this on a WorkerThreadPool task and bakes again, and on
	// that bake the cache above HITS -- the key is a hash of exactly this grid, and the grid does not
	// depend on whether the erosion ran, so pass 3 hands the solver the same bytes pass 1 did.
	//
	// The key is already computed: `want_key` is `frozen && has_out`, and `defer` is only ever set on a
	// step that is both.
	if (p_step.defer && p_step.has_out) {
		PackedFloat32Array pending;
		pending.resize((int)n);
		std::memcpy(pending.ptrw(), z.data(), n * sizeof(float));
		p_step.out["pending"] = pending;
		p_step.out["pending_key"] = key;
		p_step.out["pending_gw"] = p_gw;
		p_step.out["pending_gh"] = p_gh;
		return;
	}

	ErosionParams ep = p_step.erosion;
	ep.gw = p_gw;
	ep.gh = p_gh;
	ep.cell_size = p_vs;
	const ErosionResult res = erosion_solve(z, ep, p_step.erodability);
	if (!res.ok) {
		return; // the surface is left exactly as it was; nothing is silently half-eroded
	}
	if (p_step.publish_fields && r_fields.ready && res.flow.size() == n && res.lake_depth.size() == n) {
		// The four channels a later modifier's selectors read, in the units and signs a
		// Pasture3DTerrainMask expects — the same conversions relief_fields_add_sim makes on the way
		// out of a Pasture3DSimResult, so a FLOW band means here exactly what it means there.
		//
		// POSITIONAL BY CONSTRUCTION (§6.4): this happens at the erosion step's own place in the list, so
		// a modifier above it has already run against the defined zero and one below it reads the real
		// numbers. Nothing has to enforce the invariant because nothing can violate it.
		r_fields.sim_flow.assign(res.flow.begin(), res.flow.end());
		r_fields.sim_wetness.assign(res.lake_depth.begin(), res.lake_depth.end());
		r_fields.sim_erosion.resize(n);
		r_fields.sim_deposition.resize(n);
		for (size_t i = 0; i < n; i++) {
			const double d = (double)res.z[i] - (double)z[i];
			const double fd = std::isfinite(d) ? d : 0.0;
			r_fields.sim_erosion[i] = (float)MAX(-fd, 0.0); // POSITIVE metres removed
			r_fields.sim_deposition[i] = (float)MAX(fd, 0.0);
		}
		r_fields.has_sim = true;
	}
	for (size_t i = 0; i < n; i++) {
		if (std::isnan(r_vals[i])) {
			continue;
		}
		r_vals[i] = p_add ? (float)((double)res.z[i] - (double)p_basey[i]) : res.z[i];
	}

	// Hand the solve back so the modifier can cache it. `out` is a Dictionary the GDScript side owns —
	// a reference type, so this is visible the moment stamp_mound_loop returns.
	if (want_key) {
		PackedFloat32Array grid;
		grid.resize((int)n);
		std::memcpy(grid.ptrw(), res.z.data(), n * sizeof(float));
		p_step.out["key"] = key;
		p_step.out["grid"] = grid;
		p_step.out["stale"] = false;
		p_step.out["served"] = false;
		if (r_fields.has_sim && p_step.publish_fields) {
			PackedFloat32Array f, e, dp, w;
			f.resize((int)n);
			e.resize((int)n);
			dp.resize((int)n);
			w.resize((int)n);
			std::memcpy(f.ptrw(), r_fields.sim_flow.data(), n * sizeof(float));
			std::memcpy(e.ptrw(), r_fields.sim_erosion.data(), n * sizeof(float));
			std::memcpy(dp.ptrw(), r_fields.sim_deposition.data(), n * sizeof(float));
			std::memcpy(w.ptrw(), r_fields.sim_wetness.data(), n * sizeof(float));
			p_step.out["flow"] = f;
			p_step.out["ero"] = e;
			p_step.out["dep"] = dp;
			p_step.out["wet"] = w;
		}
	}
}

// A key for one frozen GRAPH evaluation. Like brush_mod_erosion_key: the revision (any node param or wiring
// change bumps content_key), plus the input surface ONLY for a FILTER graph (graph_reads_input), which is
// what makes a drag re-key a filter but leave a world-fixed generator alone. The amount is NOT folded in —
// it scales the composite, not the cached output, so a strength edit reuses the cache. This need not agree
// with the GDScript key; each path compares only keys it wrote.
int64_t brush_mod_graph_key(const BrushModStep &p_step, const std::vector<float> &p_z) {
	uint64_t h = BRUSH_FNV_OFFSET;
	h = brush_fnv(h, (uint64_t)p_step.graph_content_key);
	if (p_step.graph_reads_input) {
		for (size_t i = 0; i < p_z.size(); i++) {
			uint32_t b;
			const float f = p_z[i];
			std::memcpy(&b, &f, sizeof(b));
			if (std::isnan(f)) {
				b = 0x7fc00000u;
			}
			h = brush_fnv(h, (uint64_t)b);
		}
	}
	return (int64_t)h;
}

// Composite the graph's absolute output `p_zo` over the absolute input surface `p_z`, feathered by the
// interior profile and scaled by `p_amount`, then write back into `r_vals` in that grid's units (a delta
// under ADD). A byte-for-byte port of Pasture3DTerrainBrush._composite_graph. NaN cells pass through.
static void brush_mod_graph_composite(std::vector<float> &r_vals, const std::vector<float> &p_z,
		const float *p_zo, const std::vector<float> &p_profile, double p_amount,
		const std::vector<float> &p_basey, bool p_add, size_t p_n) {
	for (size_t k = 0; k < p_n; k++) {
		if (std::isnan(r_vals[k])) {
			continue;
		}
		const double t = p_amount * (double)p_profile[k];
		const double abs_out = (double)p_z[k] + ((double)p_zo[k] - (double)p_z[k]) * t;
		r_vals[k] = p_add ? (float)(abs_out - (double)p_basey[k]) : (float)abs_out;
	}
}

// Run one GRAPH step over the working grid, in place. Mirrors Pasture3DTerrainBrush._apply_graph_step:
// lift the working delta to an absolute surface, hand it to the native whole-graph evaluator (an Input node
// reads it), composite the output back feathered by the profile, and cache the ABSOLUTE output per extent
// with the three-way frozen split brush_mod_erode uses.
void brush_mod_graph(BrushModStep &p_step, std::vector<float> &r_vals, const std::vector<float> &p_basey,
		const std::vector<float> &p_profile, bool p_add, int p_gw, int p_gh, double p_vs,
		double p_min_x, double p_min_z) {
	const size_t n = (size_t)p_gw * p_gh;
	std::vector<float> z(n);
	for (size_t i = 0; i < n; i++) {
		z[i] = p_add ? (float)((double)p_basey[i] + (double)r_vals[i]) : r_vals[i];
	}
	const double amount = p_step.graph_amount;

	// FROZEN (§6.3): a missing cache evaluates, a matching one is served, a stale one is served AND flagged.
	const bool want_key = p_step.frozen && p_step.has_out;
	const int64_t key = want_key ? brush_mod_graph_key(p_step, z) : 0;
	const bool have_cache = p_step.frozen && p_step.cache.size() == (int)n;
	if (have_cache) {
		brush_mod_graph_composite(r_vals, z, p_step.cache.ptr(), p_profile, amount, p_basey, p_add, n);
		p_step.out["stale"] = p_step.cache_key != key;
		p_step.out["served"] = true;
		return;
	}

	// MISS: evaluate at the brush's own per-cell world coords (a half-cell-shifted rect makes
	// graph_cell_to_world reproduce min + i*vs), handing the graph the absolute surface for its Input node.
	const Rect2 rect((real_t)(p_min_x - 0.5 * p_vs), (real_t)(p_min_z - 0.5 * p_vs),
			(real_t)((double)p_gw * p_vs), (real_t)((double)p_gh * p_vs));
	PackedFloat32Array zin;
	zin.resize((int)n);
	std::memcpy(zin.ptrw(), z.data(), n * sizeof(float));
	const PackedFloat32Array zo = graph_eval_grid(p_step.graph_prog, p_gw, p_gh, rect, zin);
	brush_mod_graph_composite(r_vals, z, zo.ptr(), p_profile, amount, p_basey, p_add, n);
	if (want_key) {
		p_step.out["key"] = key;
		p_step.out["grid"] = zo;
		p_step.out["stale"] = false;
		p_step.out["served"] = false;
	}
}


} // namespace

// Re-export the two primitives Pasture3DSim's loop mask needs (pasture_3d_raster_util.h). Thin
// forwarders rather than moving the definitions, so the brush call sites above are untouched.
float godot::pasture3d_raster_sdf(const PackedVector2Array &p_poly, double p_min_x, double p_min_z, double p_vs,
		int p_gw, int p_gh, std::vector<float> &r_field) {
	return raster_sdf(p_poly, p_min_x, p_min_z, p_vs, p_gw, p_gh, r_field);
}

float godot::pasture3d_raster_ramp(const PackedFloat32Array &p_lut, float p_x) {
	return raster_ramp(p_lut, p_x);
}

void Pasture3DData::_stamp_write(Pasture3DLayer *p_layer, const int p_layer_id, const bool p_composite,
		Vector2i &r_loc, Pasture3DRegion *&r_region, const Vector3 &p_pos, const real_t p_value, const int p_blend) {
	// p_blend matches Pasture3DLayer::BlendMode / the GDScript BLEND_* consts: 0=REPLACE,1=ADD,2=MAX,3=MIN.
	if (!p_layer) {
		// No stack / invalid layer: destructive fallback (the deferred partial path normally has a layer).
		if (p_blend == 1) {
			set_height(p_pos, get_height(p_pos) + p_value);
		} else {
			set_height(p_pos, p_value);
		}
		return;
	}
	Vector2i region_loc;
	const Vector2i img_pos = _global_to_region_pixel(p_pos, region_loc);
	if (region_loc != r_loc) { // cache the region across a run of same-region cells
		r_loc = region_loc;
		r_region = get_region_ptr(region_loc);
	}
	if (!r_region || r_region->is_deleted()) {
		return;
	}
	// Combine with any same-layer value already written THIS bake, by the brush's blend mode, so two
	// overlapping tools on one layer stack correctly (MAX keeps the taller, MIN the deeper, ADD sums)
	// instead of the later tool overwriting the earlier one — the "cut" two mounds carved in each other.
	// The bake clears the layer in the box first, so the first tool finds it uncovered and just writes.
	real_t v = p_value;
	if (p_layer->get_weight(region_loc, img_pos) > 0.f) {
		const real_t cur = p_layer->get_value(region_loc, img_pos);
		switch (p_blend) {
			case 1: v = cur + p_value; break;   // ADD
			case 2: v = MAX(cur, p_value); break; // MAX
			case 3: v = MIN(cur, p_value); break; // MIN
			default: break;                       // REPLACE: last write wins
		}
	}
	p_layer->set_sample(region_loc, img_pos, v, 1.0);
	r_region->set_modified(true);
	if (p_composite) {
		// Full-refresh path: keep the public API's per-pixel composite (layer-vs-below) up to date.
		composite_region(region_loc, Rect2i(img_pos, V2I(1)), false);
	}
}

// Floor division (toward -inf), for region coords that can be negative.
static inline int _floordiv(const int a, const int b) {
	int q = a / b;
	if ((a % b != 0) && ((a < 0) != (b < 0))) {
		q--;
	}
	return q;
}

void Pasture3DData::_apply_stamp_block(Pasture3DLayer *p_layer, const int p_min_px, const int p_min_pz,
		const int p_gw, const int p_gh, const float *p_vals, const int p_blend) {
	if (!p_layer) {
		return;
	}
	const int rs = _region_size;
	const int ts = p_layer->get_tile_size();
	if (rs < 1 || ts < 1) {
		return;
	}
	const int px_lo = p_min_px, px_hi = p_min_px + p_gw; // box world-pixel range [lo, hi)
	const int pz_lo = p_min_pz, pz_hi = p_min_pz + p_gh;
	const int rx0 = _floordiv(px_lo, rs), rx1 = _floordiv(px_hi - 1, rs);
	const int rz0 = _floordiv(pz_lo, rs), rz1 = _floordiv(pz_hi - 1, rs);

	for (int rz = rz0; rz <= rz1; rz++) {
		for (int rx = rx0; rx <= rx1; rx++) {
			const Vector2i region_loc(rx, rz);
			Pasture3DRegion *region = get_region_ptr(region_loc);
			if (!region || region->is_deleted()) {
				continue; // only write where a region exists (matches _stamp_write)
			}
			const int gx = rx * rs, gz = rz * rs; // region's global pixel origin
			// Region-local pixel rect covered by the box.
			const int lpx0 = MAX(0, px_lo - gx), lpx1 = MIN(rs, px_hi - gx);
			const int lpz0 = MAX(0, pz_lo - gz), lpz1 = MIN(rs, pz_hi - gz);
			if (lpx0 >= lpx1 || lpz0 >= lpz1) {
				continue;
			}
			const int tx0 = lpx0 / ts, tx1 = (lpx1 - 1) / ts;
			const int tz0 = lpz0 / ts, tz1 = (lpz1 - 1) / ts;
			bool region_touched = false;
			for (int tz = tz0; tz <= tz1; tz++) {
				for (int tx = tx0; tx <= tx1; tx++) {
					const int bx = tx * ts, bz = tz * ts;
					const int x0 = MAX(lpx0, bx), x1 = MIN(lpx1, bx + ts);
					const int z0 = MAX(lpz0, bz), z1 = MIN(lpz1, bz + ts);
					if (x0 >= x1 || z0 >= z1) {
						continue;
					}
					// Pre-scan: skip tiles the feature doesn't touch (e.g. corner tiles of a circular dome)
					// so we don't allocate/dirty empty tiles the per-cell path never created.
					bool any = false;
					for (int py = z0; py < z1 && !any; py++) {
						const float *vrow = &p_vals[(size_t)(gz + py - p_min_pz) * p_gw];
						const int ix0 = gx + x0 - p_min_px, ix1 = gx + x1 - p_min_px;
						for (int ix = ix0; ix < ix1; ix++) {
							if (!std::isnan(vrow[ix])) {
								any = true;
								break;
							}
						}
					}
					if (!any) {
						continue;
					}
					Ref<Image> tile = p_layer->get_or_create_tile(region_loc, Vector2i(tx, tz));
					if (tile.is_null() || tile->get_format() != Image::FORMAT_RGF) {
						continue; // batched path is RGF-only; non-RGF shouldn't occur on a non-base overlay
					}
					PackedByteArray data = tile->get_data();
					float *f = reinterpret_cast<float *>(data.ptrw()); // RGF: [r,g] per pixel, stride 2
					bool tile_touched = false;
					for (int py = z0; py < z1; py++) {
						const int iz = gz + py - p_min_pz; // box-grid row
						const float *vrow = &p_vals[(size_t)iz * p_gw];
						const int ly = py - bz;
						for (int px = x0; px < x1; px++) {
							const int ix = gx + px - p_min_px;
							const float v = vrow[ix];
							if (std::isnan(v)) {
								continue;
							}
							const int li = (ly * ts + (px - bx)) * 2;
							float out = v;
							if (f[li + 1] > 0.f) { // already written THIS bake (same-layer blend)
								const float cur = f[li];
								switch (p_blend) {
									case 1: out = cur + v; break; // ADD
									case 2: out = MAX(cur, v); break; // MAX
									case 3: out = MIN(cur, v); break; // MIN
									default: break; // REPLACE
								}
							}
							f[li] = out;
							f[li + 1] = 1.f;
							tile_touched = true;
						}
					}
					if (tile_touched) {
						tile->set_data(ts, ts, false, Image::FORMAT_RGF, data);
						region_touched = true;
					}
				}
			}
			if (region_touched) {
				region->set_modified(true);
			}
		}
	}
}

void Pasture3DData::_apply_control_block(Pasture3DLayer *p_layer, const int p_min_px, const int p_min_pz,
		const int p_gw, const int p_gh, const uint32_t *p_ctrl, const uint8_t *p_mask) {
	if (!p_layer) {
		return;
	}
	const int rs = _region_size;
	const int ts = p_layer->get_tile_size();
	if (rs < 1 || ts < 1) {
		return;
	}
	const int px_lo = p_min_px, px_hi = p_min_px + p_gw;
	const int pz_lo = p_min_pz, pz_hi = p_min_pz + p_gh;
	const int rx0 = _floordiv(px_lo, rs), rx1 = _floordiv(px_hi - 1, rs);
	const int rz0 = _floordiv(pz_lo, rs), rz1 = _floordiv(pz_hi - 1, rs);

	for (int rz = rz0; rz <= rz1; rz++) {
		for (int rx = rx0; rx <= rx1; rx++) {
			const Vector2i region_loc(rx, rz);
			Pasture3DRegion *region = get_region_ptr(region_loc);
			if (!region || region->is_deleted()) {
				continue;
			}
			const int gx = rx * rs, gz = rz * rs;
			const int lpx0 = MAX(0, px_lo - gx), lpx1 = MIN(rs, px_hi - gx);
			const int lpz0 = MAX(0, pz_lo - gz), lpz1 = MIN(rs, pz_hi - gz);
			if (lpx0 >= lpx1 || lpz0 >= lpz1) {
				continue;
			}
			const int tx0 = lpx0 / ts, tx1 = (lpx1 - 1) / ts;
			const int tz0 = lpz0 / ts, tz1 = (lpz1 - 1) / ts;
			bool region_touched = false;
			for (int tz = tz0; tz <= tz1; tz++) {
				for (int tx = tx0; tx <= tx1; tx++) {
					const int bx = tx * ts, bz = tz * ts;
					const int x0 = MAX(lpx0, bx), x1 = MIN(lpx1, bx + ts);
					const int z0 = MAX(lpz0, bz), z1 = MIN(lpz1, bz + ts);
					if (x0 >= x1 || z0 >= z1) {
						continue;
					}
					bool any = false;
					for (int py = z0; py < z1 && !any; py++) {
						const uint8_t *mrow = &p_mask[(size_t)(gz + py - p_min_pz) * p_gw];
						for (int ix = gx + x0 - p_min_px, ixe = gx + x1 - p_min_px; ix < ixe; ix++) {
							if (mrow[ix]) {
								any = true;
								break;
							}
						}
					}
					if (!any) {
						continue;
					}
					Ref<Image> tile = p_layer->get_or_create_tile(region_loc, Vector2i(tx, tz));
					if (tile.is_null() || tile->get_format() != Image::FORMAT_RGF) {
						continue;
					}
					PackedByteArray data = tile->get_data();
					float *f = reinterpret_cast<float *>(data.ptrw());
					bool tile_touched = false;
					for (int py = z0; py < z1; py++) {
						const int idx_row = (gz + py - p_min_pz) * p_gw;
						const int ly = py - bz;
						for (int px = x0; px < x1; px++) {
							const int idx = idx_row + (gx + px - p_min_px);
							if (!p_mask[idx]) {
								continue;
							}
							const int li = (ly * ts + (px - bx)) * 2;
							f[li] = as_float(p_ctrl[idx]); // control bits as float (REPLACE; no numeric blend)
							f[li + 1] = 1.f;
							tile_touched = true;
						}
					}
					if (tile_touched) {
						tile->set_data(ts, ts, false, Image::FORMAT_RGF, data);
						region_touched = true;
					}
				}
			}
			if (region_touched) {
				region->set_modified(true);
			}
		}
	}
}

// ---- Closed-loop dome/plateau (Pasture3DMound) ----
void Pasture3DData::stamp_mound_loop(const int p_layer_id, const PackedVector2Array &p_poly, const AABB &p_clip, const Dictionary &p_params, const PackedFloat32Array &p_lut) {
	if (p_poly.size() < 3) {
		return;
	}
	const double min_x = p_params.get("min_x", 0.0);
	const double min_z = p_params.get("min_z", 0.0);
	const double vs = p_params.get("vs", 1.0);
	const int gw = (int)p_params.get("gw", 0);
	const int gh = (int)p_params.get("gh", 0);
	if (gw < 1 || gh < 1) {
		return;
	}

	// Signed-distance field: GPU analytic when the box is large enough and a local RenderingDevice exists,
	// else the C++ serial chamfer. Three-tier fallback GPU -> C++ -> GDScript (spec §4). The GPU path is a
	// drop-in: it fills `field` + `max_inside` identically in shape, so the per-cell loop below is unchanged
	// and the only behavioural change is analytic-exact vs chamfer-approximate distance (A/B-validated §7).
	std::vector<float> field;
	float max_inside = 0.f;
	bool got_field = false;
	const int threshold = _gpu_raster_threshold();
	if (threshold > 0 && (gw * gh) >= threshold) {
		Pasture3DGPURaster *gpu = _ensure_gpu_raster();
		if (gpu) {
			got_field = gpu->closed_loop_field(p_poly, min_x, min_z, vs, gw, gh, field, max_inside);
		}
	}
	if (!got_field) {
		max_inside = raster_sdf(p_poly, min_x, min_z, vs, gw, gh, field);
	}

	const double height = p_params.get("height", 0.0);
	const bool capped = p_params.get("capped", false);
	const bool invert = p_params.get("invert", false);
	const double falloff_width = p_params.get("falloff_width", 0.0);
	const double edge_offset = p_params.get("edge_offset", 0.0);
	// Flank mode: 0 = fixed width (ramp over falloff_width / dome over max_inside), 1 = slope angle.
	// CAPPED slope: ramp run = |height| / slope_tan (rises to height, then flat). UNCAPPED slope ("cone"):
	// height = slope_tan * distance-from-edge, capped by slope_safety (region-sized). slope_tan = tan(angle).
	const int flank_mode = (int)p_params.get("flank_mode", 0);
	const double slope_tan = MAX((double)p_params.get("slope_tan", 1.0), 0.0001);
	const double slope_safety = MAX((double)p_params.get("slope_safety", 1000.0), 0.001);
	const bool relative = p_params.get("relative_to_terrain", true);
	const double plane_y = p_params.get("plane_y", 0.0);
	const int blend = (int)p_params.get("blend", 0);
	const bool composite = p_params.get("composite", true);
	// The MODIFIER STACK (PASTURE3D_BRUSH_EROSION_SPEC.md §6), which is the whole of what this brush
	// applies to its own output. It replaced a hard-coded `+ noise -> + relief -> blur` in phase 3a;
	// gate BW compared the two over every shipped preset and found them bitwise identical before the
	// old path was deleted.
	//
	// Mapping is always TILE here: a relief modifier's ops read world XZ, and only the normalised nu,nv
	// that radial ops use come from the loop's oriented frame.
	// An EMPTY stack is not a special case: the loop below simply runs no steps and the brush stamps its
	// bare profile, which is exactly what a Mound with nothing configured should do.
	std::vector<BrushModStep> steps;
	brush_mod_build(p_params, steps);
	// The ONE selector block every relief modifier indexes into: each material's own block concatenated,
	// with its ops' selector ids rebased. `ReliefFields::sel_slot` is keyed by id, so it has to be flat.
	const PackedFloat32Array all_selectors = p_params.get("op_selectors", PackedFloat32Array());

	const double fit_cx = p_params.get("fit_cx", 0.0);
	const double fit_cz = p_params.get("fit_cz", 0.0);
	const double fit_cos = p_params.get("fit_cos", 1.0);
	const double fit_sin = p_params.get("fit_sin", 0.0);
	const double inv_ex = 1.0 / MAX((double)p_params.get("fit_ex", 1.0), 0.001);
	const double inv_ez = 1.0 / MAX((double)p_params.get("fit_ez", 1.0), 0.001);

	const double sign = invert ? -1.0 : 1.0;
	// Denominator that normalises signed_d -> 0..1 ramp. dome_denom is the natural interior run (also the
	// noise mask for the cone); ramp_denom is falloff_width, or |height|/slope_tan in CAPPED slope mode.
	const bool use_angle = (flank_mode == 1);
	const bool cone = use_angle && !capped; // uncapped slope = free-rising cone (height from geometry)
	const double dome_denom = MAX(max_inside + edge_offset, 0.001);
	const double ramp_denom = (use_angle && capped) ? MAX(std::fabs(height) / slope_tan, 0.001) : MAX(falloff_width, 0.001);
	const bool add = (blend == 1); // BLEND_ADD

	// The brush's OWN generated shape at one cell, before noise and before relief: `r_amp` in metres and
	// `r_profile` as the 0..1 interior mask. Returns false where the brush contributes nothing.
	//
	// Extracted into one expression because TWO things now evaluate it — the host-profile pre-pass below
	// and the main cell loop — and a second copy of this arithmetic is exactly how the field a selector
	// reads would quietly stop being the shape the brush stamps.
	const auto host_profile_at = [&](const double p_signed_d, double &r_amp, double &r_profile) -> bool {
		if (p_signed_d <= 0.0) {
			return false;
		}
		if (cone) {
			// Free-rising cone: tan × distance, capped by the region safety height. profile (0..1
			// interior mask) only gates the noise so the rim stays clean.
			r_profile = CLAMP(p_signed_d / dome_denom, 0.0, 1.0);
			r_amp = sign * MIN(slope_tan * p_signed_d, slope_safety);
			return true;
		}
		r_profile = (double)raster_ramp(p_lut, (float)(p_signed_d / (capped ? ramp_denom : dome_denom)));
		if (r_profile <= 0.0) {
			return false;
		}
		r_amp = sign * height * r_profile;
		return true;
	};

	Pasture3DLayer *wlayer = _layer_stack.is_null() ? nullptr : _layer_stack->get_layer_ptr(p_layer_id);
	Vector2i wloc(0x7fffffff, 0x7fffffff);
	Pasture3DRegion *wregion = nullptr;
	// Below-layer base: the composite of layers beneath this brush's, so it samples the ground under its
	// own layer (not the full terrain) and features stop climbing each other. NaN/empty => fall back.
	const PackedFloat32Array base_below = p_params.get("base_below", PackedFloat32Array());
	const bool has_below = base_below.size() == gw * gh;

	// Terrain fields for relief selectors / SCREE, derived from the SAME below-layer heights the brush
	// already stamps against, so a mound never gates itself on its own output and the bake does not creep
	// on every refresh. Built only when the compiled program asks for them.
	ReliefFields fields;
	if ((bool)p_params.get("need_fields", false)) {
		relief_fields_build(base_below, min_x, min_z, vs, gw, gh,
				[this](double x, double z) { return (float)get_height(Vector3(x, 0.0, z)); }, fields);
		const Dictionary sim = p_params.get("sim_result", Dictionary());
		if (!sim.is_empty()) {
			relief_fields_add_sim(sim, min_x, min_z, vs, gw, gh, fields);
		}
		// The wider slope / curvature grids a selector's `measure_radius` asks for (§21.6). A no-op when
		// every selector leaves it at 0, which is the default.
		relief_fields_add_measured(all_selectors, fields, RELIEF_FIELD_BELOW);
	}

	// HOST PROFILE fields: the same five measurements over the brush's OWN generated shape, for selectors
	// with `field_source = Host Profile` and for TERRACE / STRATIFY banding it. Built by a pre-pass over
	// the whole grid, because slope and curvature need neighbours and so cannot be derived inside the
	// cell loop that is producing the values.
	//
	// The pre-pass deliberately ignores the clip box. Clipping decides which cells get WRITTEN; the field
	// must be continuous across a clip edge, or a selector reads a cliff that is an artefact of tiling.
	ReliefFields host_fields;
	if ((bool)p_params.get("need_host_fields", false)) {
		PackedFloat32Array host_grid;
		host_grid.resize(gw * gh);
		float *hp = host_grid.ptrw();
		double peak = 0.0;
		for (int iz = 0; iz < gh; iz++) {
			const int row = iz * gw;
			for (int ix = 0; ix < gw; ix++) {
				double a = 0.0;
				double pr = 0.0;
				// Outside the loop the brush contributes nothing, and 0 is the honest value there — it is
				// what makes the rim read as the foot of the slope rather than as a hole.
				hp[row + ix] = host_profile_at((double)field[row + ix] + edge_offset, a, pr) ? (float)a : 0.f;
				peak = MAX(peak, std::fabs((double)hp[row + ix]));
			}
		}
		// No NaN can reach the fallback — the grid above is fully written — so it is never called.
		relief_fields_build(host_grid, min_x, min_z, vs, gw, gh,
				[](double, double) { return 0.f; }, host_fields);

		// THE DIVISOR, and why it is the measured peak rather than the brush's `height` property.
		// `height` is not the crest in two shipped configurations: an uncapped slope ("cone") derives its
		// height from the geometry and never reads `height` at all, and a capped mound whose
		// falloff_width exceeds its half-width never reaches full profile — the case the authoring guide
		// already warns about. Using `height` there would put every band a user authored somewhere other
		// than where they put it.
		//
		// The peak is a deterministic function of the loop and the shape properties — the same property
		// that makes this whole field non-drifting — so it is reproducible, not merely measured.
		host_fields.norm_divisor = peak > 0.0 ? peak : 1.0;
		relief_fields_add_measured(all_selectors, host_fields, RELIEF_FIELD_HOST);
	}
	ReliefSample ground;

	// Always buffer per-cell values into a box (NaN = no write) so a field modifier can run before any
	// write. Batched raw-tile apply path (Phase 1b) then commits the buffer one tile at a time
	// (no per-cell dict lookup / set_pixelv) for the common deferred non-base overlay; otherwise a per-cell
	// _stamp_write loop handles full-refresh composite, no layer, or a dense Base target.
	const bool batched = wlayer && !composite && !wlayer->is_base();
	std::vector<float> vals((size_t)gw * gh, (float)NAN);

	const bool has_clip = p_clip.size != Vector3();
	const double cx0 = p_clip.position.x;
	const double cx1 = p_clip.position.x + p_clip.size.x;
	const double cz0 = p_clip.position.z;
	const double cz1 = p_clip.position.z + p_clip.size.z;

	// Rasterise the brush's own profile into its own grids first, then run the modifier list over them.
	// The split is not a tidier spelling of one fused loop: a FIELD modifier reads the whole grid, so the
	// profile has to be finished before any modifier can look at it.
	//
	// `amp` is the contribution in METRES (NaN where the brush writes nothing) and `basey` the
	// surface it is measured from. `profile`, the 0..1 interior mask, is NOT stored: it is a pure
	// function of the signed distance, so recomputing it inside the point run costs one LUT lookup
	// and keeps it a double — storing it as float would round every product it appears in, and cost
	// gate BW its "bitwise" claim.
	std::vector<double> amp((size_t)gw * gh, NAN);
	std::vector<float> basey((size_t)gw * gh, 0.f);
	for (int iz = 0; iz < gh; iz++) {
		const double z = min_z + iz * vs;
		if (has_clip && (z < cz0 || z >= cz1)) {
			continue;
		}
		const int row = iz * gw;
		for (int ix = 0; ix < gw; ix++) {
			const double signed_d = (double)field[row + ix] + edge_offset;
			if (signed_d <= 0.0) {
				continue;
			}
			double a = 0.0;
			double pr = 0.0;
			if (!host_profile_at(signed_d, a, pr)) {
				continue;
			}
			const double x = min_x + ix * vs;
			if (has_clip && (x < cx0 || x >= cx1)) {
				continue;
			}
			if (relative) {
				const float bb = has_below ? base_below[row + ix] : (float)NAN;
				basey[row + ix] = std::isnan(bb) ? (float)get_height(Vector3(x, 0.0, z)) : bb;
			} else {
				basey[row + ix] = (float)plane_y;
			}
			amp[row + ix] = a;
		}
	}

	// WHY THERE ARE TWO REPRESENTATIONS. A point modifier adds metres to `amp`; a field modifier
	// transforms the grid that will be written. Under a non-ADD blend those are different quantities
	// (`vals = basey + amp`), so the runner tracks which one currently holds the truth and converts
	// only when the next step needs the other. A stack of Noise -> Relief -> Smooth converts exactly
	// once, at the same point the hard-coded pipeline did — which is what makes gate BW's bitwise
	// comparison a fair question rather than a tolerance dressed up as one.
	const size_t n = (size_t)gw * gh;
	bool in_vals = false;
	size_t si = 0;
	while (si < steps.size()) {
		if (steps[si].capture) {
			// The brush's own contribution in metres, which is what a seeded material wants: it is the
			// SHAPE, independent of whatever ground the brush was dropped on, so the ridges it finds are
			// the ones this brush built. Taken from `amp` rather than `vals` for exactly that reason.
			if (in_vals) {
				for (size_t k = 0; k < n; k++) {
					amp[k] = std::isnan(vals[k]) ? NAN
												 : (add ? (double)vals[k] : (double)vals[k] - (double)basey[k]);
				}
				in_vals = false;
			}
			PackedFloat32Array surf;
			surf.resize((int)n);
			float *sw = surf.ptrw();
			for (size_t k = 0; k < n; k++) {
				sw[k] = (float)amp[k];
			}
			steps[si].out["surface"] = surf;
			steps[si].out["gw"] = gw;
			steps[si].out["gh"] = gh;
			steps[si].capture = false; // consumed; fall through and run the step normally
			continue;
		}
		if (!steps[si].field) {
			// Fold the maximal RUN of point modifiers into one pass over the grid.
			// The run stops in front of a CAPTURE as well as in front of a field step: a capture on a
			// step in the MIDDLE of a run would otherwise never be examined, because the fold jumps the
			// whole run in one go and only the first step is ever tested.
			size_t sj = si + 1;
			while (sj < steps.size() && !steps[sj].field && !steps[sj].capture) {
				sj++;
			}
			if (in_vals) {
				for (size_t k = 0; k < n; k++) {
					amp[k] = std::isnan(vals[k]) ? NAN : (add ? (double)vals[k] : (double)vals[k] - (double)basey[k]);
				}
				in_vals = false;
			}
			for (int iz = 0; iz < gh; iz++) {
				const double z = min_z + iz * vs;
				const int row = iz * gw;
				for (int ix = 0; ix < gw; ix++) {
					const int i = row + ix;
					if (std::isnan(amp[i])) {
						continue;
					}
					const double x = min_x + ix * vs;
					double pr = 0.0;
					double unused = 0.0;
					host_profile_at((double)field[i] + edge_offset, unused, pr);
					double a = amp[i];
					for (size_t k = si; k < sj; k++) {
						const BrushModStep &st = steps[k];
						if (st.kind == BrushModStep::NOISE) {
							a += st.strength * st.noise->get_noise_2d(x, z) * pr;
						} else {
							// Loop-local metres, then the same point normalised to the frame's
							// half-extents — TILE evaluates the ops in world XZ, so only nu,nv come
							// from the frame.
							const double dx = x - fit_cx;
							const double dz = z - fit_cz;
							const double lx = dx * fit_cos + dz * fit_sin;
							const double lz = -dx * fit_sin + dz * fit_cos;
							// Below-layer first, host second: `sample` blank-slates the whole struct,
							// so filling the host half before it would silently discard it.
							fields.sample(i, ground);
							host_fields.sample_host(i, ground);
							const double rv = relief_eval(st.prog, x, z, lx * inv_ex, lz * inv_ez,
									inv_ex, inv_ez, ground);
							a += st.strength * rv * pr * st.mat_strength;
						}
					}
					amp[i] = a;
				}
			}
			si = sj;
			continue;
		}
		if (!in_vals) {
			for (size_t k = 0; k < n; k++) {
				vals[k] = std::isnan(amp[k]) ? (float)NAN : (float)(add ? amp[k] : (double)basey[k] + amp[k]);
			}
			in_vals = true;
		}
		if (steps[si].kind == BrushModStep::SMOOTH) {
			nan_blur(vals, gw, gh, steps[si].passes);
		} else if (steps[si].kind == BrushModStep::EROSION) {
			brush_mod_erode(steps[si], vals, basey, add, gw, gh, vs, fields);
		} else if (steps[si].kind == BrushModStep::GRAPH) {
			// The graph composites its output feathered by the interior profile. That 0..1 mask is not
			// stored (see the note above `amp`), so materialise it once here from the same host_profile_at
			// the point run uses — only for a graph step, which is already an O(cells) evaluation.
			std::vector<float> gprofile((size_t)gw * gh, 0.f);
			for (int iz = 0; iz < gh; iz++) {
				const int row = iz * gw;
				for (int ix = 0; ix < gw; ix++) {
					const int i = row + ix;
					double a = 0.0;
					double pr = 0.0;
					if (host_profile_at((double)field[i] + edge_offset, a, pr)) {
						gprofile[i] = (float)pr;
					}
				}
			}
			brush_mod_graph(steps[si], vals, basey, gprofile, add, gw, gh, vs, min_x, min_z);
		}
		si++;
	}
	if (!in_vals) {
		for (size_t k = 0; k < n; k++) {
			vals[k] = std::isnan(amp[k]) ? (float)NAN : (float)(add ? amp[k] : (double)basey[k] + amp[k]);
		}
	}

	if (batched) {
		const int min_px = (int)std::lround(min_x / vs);
		const int min_pz = (int)std::lround(min_z / vs);
		_apply_stamp_block(wlayer, min_px, min_pz, gw, gh, vals.data(), blend);
	} else {
		for (int iz = 0; iz < gh; iz++) {
			const double z = min_z + iz * vs;
			if (has_clip && (z < cz0 || z >= cz1)) { continue; }
			const int row = iz * gw;
			for (int ix = 0; ix < gw; ix++) {
				const float v = vals[row + ix];
				if (std::isnan(v)) { continue; }
				const double x = min_x + ix * vs;
				if (has_clip && (x < cx0 || x >= cx1)) { continue; }
				_stamp_write(wlayer, p_layer_id, composite, wloc, wregion, Vector3(x, 0.0, z), (double)v, blend);
			}
		}
	}
}

// ---- Open-polyline crest (Pasture3DRidge) ----
void Pasture3DData::stamp_ridge_line(const int p_layer_id, const PackedVector3Array &p_pts, const AABB &p_clip, const Dictionary &p_params, const PackedFloat32Array &p_lut) {
	if (p_pts.size() < 2) {
		return;
	}
	const double min_x = p_params.get("min_x", 0.0);
	const double min_z = p_params.get("min_z", 0.0);
	const double vs = p_params.get("vs", 1.0);
	const int gw = (int)p_params.get("gw", 0);
	const int gh = (int)p_params.get("gh", 0);
	if (gw < 1 || gh < 1) {
		return;
	}

	// Per-spline-point terrain heights for ground_ref interpolation — O(npts) vs O(cells) composite.
	const PackedFloat32Array base_below_pts = p_params.get("base_below_pts", PackedFloat32Array());
	const bool has_below_pts = base_below_pts.size() == p_pts.size();

	const double crest_height = p_params.get("crest_height", 0.0);
	const double width = p_params.get("width", 0.0);
	const double falloff = p_params.get("falloff", 0.0);
	const bool invert = p_params.get("invert", false);
	const bool follow = p_params.get("follow_spline_height", true);
	// Flank mode: 0 = fixed width (spread over `width`), 1 = slope angle (descend at slope_tan to ground,
	// reach capped by `width`). slope_tan = tan(slope_angle).
	const int flank_mode = (int)p_params.get("flank_mode", 0);
	const double slope_tan = MAX((double)p_params.get("slope_tan", 1.0), 0.0001);
	const int blend = (int)p_params.get("blend", 0);
	const bool composite = p_params.get("composite", true);
	const double noise_strength = p_params.get("noise_strength", 0.0);
	Object *noise_obj = p_params.get("noise", Variant());
	Ref<FastNoiseLite> noise = Object::cast_to<FastNoiseLite>(noise_obj);
	// Optional along-spline width taper LUT (t = along/total -> width multiplier). Empty => constant width.
	const PackedFloat32Array width_lut = p_params.get("width_lut", PackedFloat32Array());
	const bool has_wlut = width_lut.size() > 0;

	const double signed_crest = invert ? -crest_height : crest_height;
	const bool use_angle = (flank_mode == 1);
	const double reach = width + falloff;
	const double falloff_d = MAX(falloff, 0.001);
	const float edge_val = raster_ramp(p_lut, 1.0f); // _cross at t=1
	const bool add = (blend == 1);

	// Exact segment-driven field with adaptive downsampling: when reach/vs is large (fine vertex_spacing),
	// compute at a coarser grid (capped at ~70 cells reach) then bilinearly upsample. This keeps inner
	// iterations bounded at ~npts × 141×141 regardless of vs, with ≤vs_c/2 upsampling error in lat.
	const int reach_cells = (int)(reach / vs + 0.5);
	const int ds = MAX(1, (reach_cells + 69) / 70); // downsample factor: ceil(reach_cells/70)
	const int gw_c = (gw + ds - 1) / ds;
	const int gh_c = (gh + ds - 1) / ds;
	const double vs_c = vs * ds;
	const int nc = gw_c * gh_c;
	std::vector<float> lat_c(nc, RBIG), base_yf_c(nc, 0.f), along_c(nc, 0.f), gr_c(nc, (float)NAN);
	double arc = 0.0;
	const int npts = (int)p_pts.size();
	for (int k = 0; k < npts - 1; k++) {
		const Vector3 a = p_pts[k], b = p_pts[k + 1];
		const double dx = b.x - a.x, dz = b.z - a.z;
		const double seg_len_sq = dx * dx + dz * dz;
		const double seg_len = std::sqrt(seg_len_sq);
		const double ag = has_below_pts ? (double)base_below_pts[k] : (double)NAN;
		const double bg = has_below_pts ? (double)base_below_pts[k + 1] : (double)NAN;
		const int six0 = MAX(0, (int)std::floor((MIN(a.x, b.x) - reach - min_x) / vs_c));
		const int six1 = MIN(gw_c - 1, (int)std::ceil((MAX(a.x, b.x) + reach - min_x) / vs_c));
		const int siz0 = MAX(0, (int)std::floor((MIN(a.z, b.z) - reach - min_z) / vs_c));
		const int siz1 = MIN(gh_c - 1, (int)std::ceil((MAX(a.z, b.z) + reach - min_z) / vs_c));
		for (int iz = siz0; iz <= siz1; iz++) {
			const double cz = min_z + iz * vs_c;
			const int row = iz * gw_c;
			for (int ix = six0; ix <= six1; ix++) {
				const double cx = min_x + ix * vs_c;
				const double qx = cx - a.x, qz = cz - a.z;
				const double t = seg_len_sq > 1e-18 ? CLAMP((qx * dx + qz * dz) / seg_len_sq, 0.0, 1.0) : 0.0;
				const double d = std::sqrt((cx - (a.x + t * dx)) * (cx - (a.x + t * dx)) + (cz - (a.z + t * dz)) * (cz - (a.z + t * dz)));
				const int i = row + ix;
				if (d < (double)lat_c[i]) {
					lat_c[i] = (float)d;
					base_yf_c[i] = (float)(a.y + t * (b.y - a.y));
					along_c[i] = (float)(arc + t * seg_len);
					gr_c[i] = has_below_pts ? (float)(ag + t * (bg - ag)) : (float)NAN;
				}
			}
		}
		arc += seg_len;
	}
	const double total = MAX(arc, 0.001);
	// Upsample coarse field to full resolution (no-op when ds==1: just move the arrays).
	const int n = gw * gh;
	std::vector<float> lat(n), base_yf(n), along(n), ground_ref_arr(n);
	if (ds == 1) {
		lat = std::move(lat_c);
		base_yf = std::move(base_yf_c);
		along = std::move(along_c);
		ground_ref_arr = std::move(gr_c);
	} else {
		for (int iz = 0; iz < gh; iz++) {
			const float fz = (float)iz / ds;
			const int iz0 = (int)fz, iz1 = MIN(gh_c - 1, iz0 + 1);
			const float wz1 = fz - iz0, wz0 = 1.f - wz1;
			const int row = iz * gw;
			for (int ix = 0; ix < gw; ix++) {
				const float fx = (float)ix / ds;
				const int ix0 = (int)fx, ix1 = MIN(gw_c - 1, ix0 + 1);
				const float wx1 = fx - ix0, wx0 = 1.f - wx1;
				const int c00 = iz0 * gw_c + ix0, c01 = iz0 * gw_c + ix1;
				const int c10 = iz1 * gw_c + ix0, c11 = iz1 * gw_c + ix1;
				const int i = row + ix;
				auto bl = [&](const std::vector<float> &arr) {
					return arr[c00] * wz0 * wx0 + arr[c01] * wz0 * wx1
					     + arr[c10] * wz1 * wx0 + arr[c11] * wz1 * wx1;
				};
				lat[i] = bl(lat_c);
				base_yf[i] = bl(base_yf_c);
				along[i] = bl(along_c);
				// NaN-aware bilinear for ground_ref.
				float gsum = 0.f, gwt = 0.f;
				auto addg = [&](int ci, float w) { float v = gr_c[ci]; if (!std::isnan(v)) { gsum += v * w; gwt += w; } };
				addg(c00, wz0 * wx0); addg(c01, wz0 * wx1);
				addg(c10, wz1 * wx0); addg(c11, wz1 * wx1);
				ground_ref_arr[i] = gwt > 0.f ? gsum / gwt : (float)NAN;
			}
		}
	}

	Pasture3DLayer *wlayer = _layer_stack.is_null() ? nullptr : _layer_stack->get_layer_ptr(p_layer_id);

	const bool batched = wlayer && !composite && !wlayer->is_base(); // Phase 1b batched raw-tile apply
	// Always buffer into vals so the smoothing pass can run before any write.
	std::vector<float> vals((size_t)gw * gh, (float)NAN);

	const bool has_clip = p_clip.size != Vector3();
	const double cx0 = p_clip.position.x;
	const double cx1 = p_clip.position.x + p_clip.size.x;
	const double cz0 = p_clip.position.z;
	const double cz1 = p_clip.position.z + p_clip.size.z;

	for (int iz = 0; iz < gh; iz++) {
		const double z = min_z + iz * vs;
		if (has_clip && (z < cz0 || z >= cz1)) {
			continue;
		}
		const int row = iz * gw;
		for (int ix = 0; ix < gw; ix++) {
			const int i = row + ix;
			const double latd = (double)lat[i];
			if (latd > reach) {
				continue;
			}
			const double x = min_x + ix * vs;
			if (has_clip && (x < cx0 || x >= cx1)) {
				continue;
			}
			const Vector3 pos(x, 0.0, z);
			// Per-cell terrain height for the drape base. Own layer is cleared before paint so
			// get_height == get_height_below here. ground_ref uses per-segment interpolated height
			// (Option B: geometry-driven cross-section); falls back to ground when unavailable.
			const double ground = (double)get_height(pos);
			const double gs = (double)ground_ref_arr[i];
			const double ground_ref = std::isnan(gs) ? ground : gs;
			const double crest_top = (follow ? (double)base_yf[i] : ground_ref) + signed_crest;
			double w = width;
			if (has_wlut) {
				w *= MAX((double)raster_ramp(width_lut, (float)((double)along[i] / total)), 0.0);
			}
			const double diff = crest_top - ground_ref;
			double w_eff = w;
			if (use_angle) {
				w_eff = CLAMP(std::fabs(diff) / slope_tan, 0.0, w);
			}
			if (w_eff <= 0.0) {
				continue;
			}
			if (latd > w_eff + falloff) {
				continue;
			}
			double p;
			if (latd <= w_eff) {
				p = raster_ramp(p_lut, (float)(latd / w_eff));
			} else {
				p = edge_val * (1.0 - CLAMP((latd - w_eff) / falloff_d, 0.0, 1.0));
			}
			if (p > 0.0) {
				// Drape on actual per-cell ground — the skirt meets the terrain; only the shape
				// (diff, w_eff) is anchored to the spline-point reference so it stays smooth.
				double painted = ground + diff * p;
				if (noise.is_valid()) {
					painted += noise_strength * noise->get_noise_2d(x, z) * p;
				}
				vals[i] = (float)(add ? (painted - ground) : painted);
			}
		}
	}

	// NaN-aware separable 3-tap Gaussian blur. Smooths the chamfer DT's octagonal isocontour
	// artifacts in `lat` that appear as angular surface faceting when diff is large.
	nan_blur(vals, gw, gh, (int)p_params.get("smooth_passes", 0));

	// Write back.
	if (batched) {
		_apply_stamp_block(wlayer, (int)std::lround(min_x / vs), (int)std::lround(min_z / vs), gw, gh, vals.data(), blend);
	} else {
		Vector2i wloc(0x7fffffff, 0x7fffffff);
		Pasture3DRegion *wregion = nullptr;
		for (int iz = 0; iz < gh; iz++) {
			const double z = min_z + iz * vs;
			if (has_clip && (z < cz0 || z >= cz1)) { continue; }
			const int row = iz * gw;
			for (int ix = 0; ix < gw; ix++) {
				const float v = vals[row + ix];
				if (std::isnan(v)) { continue; }
				const double x = min_x + ix * vs;
				if (has_clip && (x < cx0 || x >= cx1)) { continue; }
				_stamp_write(wlayer, p_layer_id, composite, wloc, wregion, Vector3(x, 0.0, z), (double)v, blend);
			}
		}
	}
}

// ---- Open-polyline channel (Pasture3DTrough) ----
void Pasture3DData::stamp_trough_line(const int p_layer_id, const PackedVector3Array &p_pts, const AABB &p_clip, const Dictionary &p_params, const PackedFloat32Array &p_lut) {
	if (p_pts.size() < 2) {
		return;
	}
	const double min_x = p_params.get("min_x", 0.0);
	const double min_z = p_params.get("min_z", 0.0);
	const double vs = p_params.get("vs", 1.0);
	const int gw = (int)p_params.get("gw", 0);
	const int gh = (int)p_params.get("gh", 0);
	if (gw < 1 || gh < 1) {
		return;
	}

	const double bed_half_width = p_params.get("bed_half_width", 0.0);
	const double bank_width = p_params.get("bank_width", 0.0);
	const double falloff = p_params.get("falloff", 0.0);
	const double depth = p_params.get("depth", 0.0);
	const bool flat_bed = p_params.get("flat_bed", true);
	const bool follow = p_params.get("follow_spline_height", true);
	// Flank mode: 0 = fixed width (banks spread over bank_width), 1 = slope angle (banks rise at slope_tan
	// to ground, reach capped by bank_width). slope_tan = tan(slope_angle).
	const int flank_mode = (int)p_params.get("flank_mode", 0);
	const double slope_tan = MAX((double)p_params.get("slope_tan", 1.0), 0.0001);
	const int blend = (int)p_params.get("blend", 0);
	const bool composite = p_params.get("composite", true);
	const double noise_strength = p_params.get("noise_strength", 0.0);
	Object *noise_obj = p_params.get("noise", Variant());
	Ref<FastNoiseLite> noise = Object::cast_to<FastNoiseLite>(noise_obj);
	// Optional along-spline width taper LUT (t = along/total -> half-width multiplier). Empty => constant.
	const PackedFloat32Array width_lut = p_params.get("width_lut", PackedFloat32Array());
	const bool has_wlut = width_lut.size() > 0;

	const double reach = bed_half_width + bank_width + falloff;
	const bool use_angle = (flank_mode == 1);
	const bool add = (blend == 1);

	// Per-point terrain heights (O(npts)); C++ interpolates ground per cell by arc-length t.
	const PackedFloat32Array base_below_pts = p_params.get("base_below_pts", PackedFloat32Array());
	const bool has_below_pts = base_below_pts.size() == p_pts.size();

	// Adaptive coarse-grid field: when reach/vs is large (fine vertex_spacing) the per-segment bounding
	// box has (2*reach/vs)^2 cells which blows up. Compute at coarser resolution vs_c = vs*ds, then
	// bilinearly upsample. ds chosen so reach_cells_c <= 70 (error <= vs_c/2, imperceptible in practice).
	const int reach_cells = (int)(reach / vs + 0.5);
	const int ds = MAX(1, (reach_cells + 69) / 70);
	const int gw_c = (gw + ds - 1) / ds;
	const int gh_c = (gh + ds - 1) / ds;
	const double vs_c = vs * ds;
	const int nc = gw_c * gh_c;
	std::vector<float> lat_c(nc, RBIG), base_yf_c(nc, 0.f), along_c(nc, 0.f), gr_c(nc, (float)NAN);
	double arc = 0.0;
	const int npts = (int)p_pts.size();
	for (int k = 0; k < npts - 1; k++) {
		const Vector3 a = p_pts[k], b = p_pts[k + 1];
		const double dx = b.x - a.x, dz = b.z - a.z;
		const double seg_len_sq = dx * dx + dz * dz;
		const double seg_len = std::sqrt(seg_len_sq);
		const int six0 = MAX(0, (int)std::floor((MIN(a.x, b.x) - reach - min_x) / vs_c));
		const int six1 = MIN(gw_c - 1, (int)std::ceil((MAX(a.x, b.x) + reach - min_x) / vs_c));
		const int siz0 = MAX(0, (int)std::floor((MIN(a.z, b.z) - reach - min_z) / vs_c));
		const int siz1 = MIN(gh_c - 1, (int)std::ceil((MAX(a.z, b.z) + reach - min_z) / vs_c));
		for (int iz = siz0; iz <= siz1; iz++) {
			const double cz = min_z + iz * vs_c;
			const int row = iz * gw_c;
			for (int ix = six0; ix <= six1; ix++) {
				const double cx = min_x + ix * vs_c;
				const double qx = cx - a.x, qz = cz - a.z;
				const double t = seg_len_sq > 1e-18 ? CLAMP((qx * dx + qz * dz) / seg_len_sq, 0.0, 1.0) : 0.0;
				const double px = a.x + t * dx, pz = a.z + t * dz;
				const double d = std::sqrt((cx - px) * (cx - px) + (cz - pz) * (cz - pz));
				const int i = row + ix;
				if (d < (double)lat_c[i]) {
					lat_c[i] = (float)d;
					base_yf_c[i] = (float)(a.y + t * (b.y - a.y));
					along_c[i] = (float)(arc + t * seg_len);
					if (has_below_pts) {
						gr_c[i] = (float)((double)base_below_pts[k] * (1.0 - t) + (double)base_below_pts[k + 1] * t);
					}
				}
			}
		}
		arc += seg_len;
	}
	const double total = MAX(arc, 0.001);

	// Upsample coarse field to full resolution (no-op when ds==1: just move arrays).
	const int n = gw * gh;
	std::vector<float> lat(n), base_yf(n), along(n), ground_ref_arr(n, (float)NAN);
	if (ds == 1) {
		lat = std::move(lat_c); base_yf = std::move(base_yf_c);
		along = std::move(along_c); ground_ref_arr = std::move(gr_c);
	} else {
		for (int iz = 0; iz < gh; iz++) {
			const float fz = (float)iz / ds;
			const int iz0 = (int)fz, iz1 = MIN(gh_c - 1, iz0 + 1);
			const float wz1 = fz - iz0, wz0 = 1.f - wz1;
			const int row = iz * gw;
			for (int ix = 0; ix < gw; ix++) {
				const float fx = (float)ix / ds;
				const int ix0 = (int)fx, ix1 = MIN(gw_c - 1, ix0 + 1);
				const float wx1 = fx - ix0, wx0 = 1.f - wx1;
				const int c00 = iz0*gw_c+ix0, c01 = iz0*gw_c+ix1;
				const int c10 = iz1*gw_c+ix0, c11 = iz1*gw_c+ix1;
				const int i = row + ix;
				auto bl = [&](const std::vector<float> &arr) {
					return arr[c00]*wz0*wx0 + arr[c01]*wz0*wx1
					     + arr[c10]*wz1*wx0 + arr[c11]*wz1*wx1;
				};
				lat[i] = bl(lat_c); base_yf[i] = bl(base_yf_c); along[i] = bl(along_c);
				float gsum = 0.f, gwt = 0.f;
				auto addg = [&](int ci, float w) { float v = gr_c[ci]; if (!std::isnan(v)) { gsum += v*w; gwt += w; } };
				addg(c00, wz0*wx0); addg(c01, wz0*wx1);
				addg(c10, wz1*wx0); addg(c11, wz1*wx1);
				ground_ref_arr[i] = gwt > 0.f ? gsum/gwt : (float)NAN;
			}
		}
	}

	Pasture3DLayer *wlayer = _layer_stack.is_null() ? nullptr : _layer_stack->get_layer_ptr(p_layer_id);

	const bool batched = wlayer && !composite && !wlayer->is_base(); // Phase 1b batched raw-tile apply
	std::vector<float> vals((size_t)gw * gh, (float)NAN);

	const bool has_clip = p_clip.size != Vector3();
	const double cx0 = p_clip.position.x;
	const double cx1 = p_clip.position.x + p_clip.size.x;
	const double cz0 = p_clip.position.z;
	const double cz1 = p_clip.position.z + p_clip.size.z;

	for (int iz = 0; iz < gh; iz++) {
		const double z = min_z + iz * vs;
		if (has_clip && (z < cz0 || z >= cz1)) {
			continue;
		}
		const int row = iz * gw;
		for (int ix = 0; ix < gw; ix++) {
			const int i = row + ix;
			const double latd = (double)lat[i];
			if (latd > reach) {
				continue;
			}
			const double x = min_x + ix * vs;
			if (has_clip && (x < cx0 || x >= cx1)) {
				continue;
			}
			const Vector3 pos(x, 0.0, z);
			// Two references: the ground beneath (the rim the banks rise to) and the bed floor.
			const float bb = ground_ref_arr[i];
			const double ground = std::isnan(bb) ? (double)get_height(pos) : (double)bb;
			const double bed_y = (follow ? (double)base_yf[i] : ground) - depth;
			double wscale = 1.0;
			if (has_wlut) {
				wscale = MAX((double)raster_ramp(width_lut, (float)((double)along[i] / total)), 0.0);
			}
			const double bed_hw = bed_half_width * wscale;
			const double span = (bed_half_width + bank_width) * wscale;
			if (latd > span + falloff) {
				continue;
			}
			// Flat bed keeps a level floor of bed_hw then ramps; basin ramps from the centreline.
			const double bank_floor = flat_bed ? bed_hw : 0.0;
			double w_eff = span;
			if (use_angle) {
				w_eff = CLAMP(bank_floor + std::fabs(ground - bed_y) / slope_tan, bank_floor, span);
			}
			double h;
			if (flat_bed && latd <= bed_hw) {
				h = bed_y;
			} else if (latd <= w_eff) {
				const double t = (latd - bank_floor) / MAX(w_eff - bank_floor, 0.001);
				h = bed_y + (ground - bed_y) * (double)raster_ramp(p_lut, (float)t);
			} else {
				h = ground;
			}
			if (noise.is_valid() && h < ground) {
				const double mask = CLAMP((ground - h) / MAX(ground - bed_y, 0.001), 0.0, 1.0);
				h = MIN(h + noise_strength * noise->get_noise_2d(x, z) * mask, ground);
			}
			vals[i] = (float)(add ? (h - ground) : h);
		}
	}

	// Optional NaN-aware post-smoothing (default 0 = no-op, no allocation).
	nan_blur(vals, gw, gh, (int)p_params.get("smooth_passes", 0));

	if (batched) {
		_apply_stamp_block(wlayer, (int)std::lround(min_x / vs), (int)std::lround(min_z / vs), gw, gh, vals.data(), blend);
	} else {
		Vector2i wloc(0x7fffffff, 0x7fffffff);
		Pasture3DRegion *wregion = nullptr;
		for (int iz = 0; iz < gh; iz++) {
			const double z = min_z + iz * vs;
			if (has_clip && (z < cz0 || z >= cz1)) { continue; }
			const int row = iz * gw;
			for (int ix = 0; ix < gw; ix++) {
				const float v = vals[row + ix];
				if (std::isnan(v)) { continue; }
				const double x = min_x + ix * vs;
				if (has_clip && (x < cx0 || x >= cx1)) { continue; }
				_stamp_write(wlayer, p_layer_id, composite, wloc, wregion, Vector3(x, 0.0, z), (double)v, blend);
			}
		}
	}
}

// ---- Closed-loop source relief (Pasture3DPlow) ----
void Pasture3DData::stamp_plow_loop(const int p_layer_id, const PackedVector2Array &p_poly, const AABB &p_clip, const Dictionary &p_params, const PackedFloat32Array &p_lut, const PackedFloat32Array &p_src_data) {
	if (p_poly.size() < 3) {
		return;
	}
	const double min_x = p_params.get("min_x", 0.0);
	const double min_z = p_params.get("min_z", 0.0);
	const double vs = p_params.get("vs", 1.0);
	const int gw = (int)p_params.get("gw", 0);
	const int gh = (int)p_params.get("gh", 0);
	if (gw < 1 || gh < 1) {
		return;
	}

	// Field: GPU analytic when the box is large enough + a local RD exists, else the C++ chamfer (Plow/Splat
	// ignore max_inside; they normalise on falloff_width). Same 3-tier fallback as Mound (spec §4).
	std::vector<float> field;
	{
		bool got_field = false;
		const int threshold = _gpu_raster_threshold();
		if (threshold > 0 && (gw * gh) >= threshold) {
			Pasture3DGPURaster *gpu = _ensure_gpu_raster();
			if (gpu) {
				float mi_unused = 0.f;
				got_field = gpu->closed_loop_field(p_poly, min_x, min_z, vs, gw, gh, field, mi_unused);
			}
		}
		if (!got_field) {
			raster_sdf(p_poly, min_x, min_z, vs, gw, gh, field);
		}
	}

	const double height_scale = p_params.get("height_scale", 0.0);
	const double height_offset = p_params.get("height_offset", 0.5);
	const double edge_offset = p_params.get("edge_offset", 0.0);
	const double falloff_width = p_params.get("falloff_width", 0.0);
	const bool relative = p_params.get("relative_to_terrain", true);
	const double plane_y = p_params.get("plane_y", 0.0);
	const int blend = (int)p_params.get("blend", 1);
	const bool composite = p_params.get("composite", true);
	const double src_strength = p_params.get("src_strength", 1.0);
	const double tile_size = MAX((double)p_params.get("tile_size", 16.0), 0.0001);
	const int source = (int)p_params.get("source", 0); // 0=NOISE 1=TEXTURE 2=MATERIAL 3=RELIEF
	const int data_w = (int)p_params.get("data_w", 0);
	const int data_h = (int)p_params.get("data_h", 0);
	Object *noise_obj = p_params.get("noise", Variant());
	Ref<FastNoiseLite> noise = Object::cast_to<FastNoiseLite>(noise_obj);

	// Source = RELIEF: compile-once op program plus the loop's oriented frame. FIT evaluates the ops in
	// loop-local metres so the relief rotates with the loop; TILE keeps world XZ so it stays continuous
	// across the area. Both derive nu/nv from the same frame, which is what sizes radial ops (craters).
	ReliefProgram prog;
	if (source == 3 && !relief_build(p_params, prog)) {
		return; // nothing to stamp
	}
	const int mapping = (int)p_params.get("mapping", 0); // 0=TILE 1=FIT 2=SCATTER
	const bool fit = mapping == 1;
	ReliefScatter scatter;
	const bool scattered = source == 3 && mapping == 2 &&
			relief_scatter_build(p_params, min_x, min_z, vs, gw, gh, scatter);
	if (source == 3 && mapping == 2 && !scattered) {
		return; // scatter placed nothing (impossible count in a tight loop) — stamping would be a no-op
	}
	const double fit_cx = p_params.get("fit_cx", 0.0);
	const double fit_cz = p_params.get("fit_cz", 0.0);
	const double fit_cos = p_params.get("fit_cos", 1.0);
	const double fit_sin = p_params.get("fit_sin", 0.0);
	const double inv_ex = 1.0 / MAX((double)p_params.get("fit_ex", 1.0), 0.001);
	const double inv_ez = 1.0 / MAX((double)p_params.get("fit_ez", 1.0), 0.001);

	const double ramp_denom = MAX(falloff_width, 0.001);
	const bool add = (blend == 1); // BLEND_ADD

	Pasture3DLayer *wlayer = _layer_stack.is_null() ? nullptr : _layer_stack->get_layer_ptr(p_layer_id);
	Vector2i wloc(0x7fffffff, 0x7fffffff);
	Pasture3DRegion *wregion = nullptr;
	// Below-layer base: the composite of layers beneath this brush's, so it samples the ground under its
	// own layer (not the full terrain) and features stop climbing each other. NaN/empty => fall back.
	const PackedFloat32Array base_below = p_params.get("base_below", PackedFloat32Array());
	const bool has_below = base_below.size() == gw * gh;

	// Terrain fields for selectors / SCREE, derived from the SAME below-layer heights so a brush never
	// gates itself on its own output. Built only when the compiled program asks for them.
	ReliefFields fields;
	if (source == 3 && (bool)p_params.get("need_fields", false)) {
		relief_fields_build(base_below, min_x, min_z, vs, gw, gh,
				[this](double x, double z) { return (float)get_height(Vector3(x, 0.0, z)); }, fields);
		// The sim channels for the FLOW / EROSION / DEPOSITION / WETNESS Kinds, resampled from the
		// Pasture3DSimResult's own extent onto this bake grid (spec §9). Absent unless the program has a
		// selector of one of those Kinds, and absent is not an error — every such Kind then reads its
		// defined zero, which is what the brush's configuration warning is about.
		const Dictionary sim = p_params.get("sim_result", Dictionary());
		if (!sim.is_empty()) {
			relief_fields_add_sim(sim, min_x, min_z, vs, gw, gh, fields);
		}
		// The wider slope / curvature grids a selector's `measure_radius` asks for (§21.6). A no-op when
		// every selector leaves it at 0, which is the default.
		//
		// BELOW only: a Plow has no host profile to offer — its "own generated shape" IS its stamp, i.e.
		// its output — so a `Host Profile` selector here reads a defined zero and the brush warns. See
		// Pasture3DPlow._get_configuration_warnings.
		relief_fields_add_measured(prog.selectors, fields, RELIEF_FIELD_BELOW);
	}
	ReliefSample ground;

	// Always buffer (NaN = no write) so the optional smoothing pass can run before any write; batched
	// commit for the common deferred overlay, per-cell write-back otherwise.
	const bool batched = wlayer && !composite && !wlayer->is_base(); // Phase 1b batched raw-tile apply
	std::vector<float> vals((size_t)gw * gh, (float)NAN);

	const bool has_clip = p_clip.size != Vector3();
	const double cx0 = p_clip.position.x;
	const double cx1 = p_clip.position.x + p_clip.size.x;
	const double cz0 = p_clip.position.z;
	const double cz1 = p_clip.position.z + p_clip.size.z;

	for (int iz = 0; iz < gh; iz++) {
		const double z = min_z + iz * vs;
		if (has_clip && (z < cz0 || z >= cz1)) {
			continue;
		}
		const int row = iz * gw;
		for (int ix = 0; ix < gw; ix++) {
			const double signed_d = (double)field[row + ix] + edge_offset;
			if (signed_d <= 0.0) {
				continue;
			}
			const double mask = raster_ramp(p_lut, (float)(signed_d / ramp_denom));
			if (mask <= 0.0) {
				continue;
			}
			const double x = min_x + ix * vs;
			if (has_clip && (x < cx0 || x >= cx1)) {
				continue;
			}
			// Loop-local metres, then the same point normalised to the frame's half-extents.
			const double dx = x - fit_cx;
			const double dz = z - fit_cz;
			const double lx = dx * fit_cos + dz * fit_sin;
			const double lz = -dx * fit_sin + dz * fit_cos;

			double amp;
			if (source == 3) {
				fields.sample(row + ix, ground);
				const double rv = scattered
						? relief_scatter_eval(prog, scatter, x, z, ground)
						: relief_eval(prog, fit ? lx : x, fit ? lz : z, lx * inv_ex, lz * inv_ez,
								  inv_ex, inv_ez, ground);
				amp = height_scale * rv * mask * src_strength;
			} else {
				// Source value in [0,1] (mirrors Pasture3DPlow._sample01).
				double sv;
				if (source == 0) {
					sv = noise.is_valid() ? CLAMP(noise->get_noise_2d(x, z) * 0.5 + 0.5, 0.0, 1.0) : height_offset;
				} else if (p_src_data.is_empty() || data_w <= 0 || data_h <= 0) {
					sv = height_offset;
				} else {
					double u, t;
					if (fit) {
						// Map the image once onto the loop's oriented rect instead of tiling it.
						u = CLAMP(lx * inv_ex * 0.5 + 0.5, 0.0, 1.0);
						t = CLAMP(lz * inv_ez * 0.5 + 0.5, 0.0, 1.0);
					} else {
						u = (x / tile_size) - std::floor(x / tile_size);
						t = (z / tile_size) - std::floor(z / tile_size);
					}
					int px = (int)(u * data_w);
					int py = (int)(t * data_h);
					px = CLAMP(px, 0, data_w - 1);
					py = CLAMP(py, 0, data_h - 1);
					sv = p_src_data[py * data_w + px];
				}
				amp = height_scale * (sv - height_offset) * mask * src_strength;
			}
			if (std::fabs(amp) < 0.0001) {
				continue;
			}
			const Vector3 pos(x, 0.0, z);
			double base_y;
			if (relative) {
				const float bb = has_below ? base_below[row + ix] : (float)NAN;
				base_y = std::isnan(bb) ? (double)get_height(pos) : (double)bb;
			} else {
				base_y = plane_y;
			}
			vals[row + ix] = (float)(add ? amp : (base_y + amp));
		}
	}

	// Optional NaN-aware post-smoothing (default 0 = no-op, no allocation).
	nan_blur(vals, gw, gh, (int)p_params.get("smooth_passes", 0));

	if (batched) {
		_apply_stamp_block(wlayer, (int)std::lround(min_x / vs), (int)std::lround(min_z / vs), gw, gh, vals.data(), blend);
	} else {
		for (int iz = 0; iz < gh; iz++) {
			const double z = min_z + iz * vs;
			if (has_clip && (z < cz0 || z >= cz1)) { continue; }
			const int row = iz * gw;
			for (int ix = 0; ix < gw; ix++) {
				const float v = vals[row + ix];
				if (std::isnan(v)) { continue; }
				const double x = min_x + ix * vs;
				if (has_clip && (x < cx0 || x >= cx1)) { continue; }
				_stamp_write(wlayer, p_layer_id, composite, wloc, wregion, Vector3(x, 0.0, z), (double)v, blend);
			}
		}
	}
}

// ---- Closed-loop control/texture paint (Pasture3DSplat) ----
void Pasture3DData::stamp_splat_loop(const int p_layer_id, const PackedVector2Array &p_poly, const AABB &p_clip, const Dictionary &p_params, const PackedFloat32Array &p_lut) {
	if (p_poly.size() < 3) {
		return;
	}
	const double min_x = p_params.get("min_x", 0.0);
	const double min_z = p_params.get("min_z", 0.0);
	const double vs = p_params.get("vs", 1.0);
	const int gw = (int)p_params.get("gw", 0);
	const int gh = (int)p_params.get("gh", 0);
	if (gw < 1 || gh < 1) {
		return;
	}

	// Field: GPU analytic when the box is large enough + a local RD exists, else the C++ chamfer (Plow/Splat
	// ignore max_inside; they normalise on falloff_width). Same 3-tier fallback as Mound (spec §4).
	std::vector<float> field;
	{
		bool got_field = false;
		const int threshold = _gpu_raster_threshold();
		if (threshold > 0 && (gw * gh) >= threshold) {
			Pasture3DGPURaster *gpu = _ensure_gpu_raster();
			if (gpu) {
				float mi_unused = 0.f;
				got_field = gpu->closed_loop_field(p_poly, min_x, min_z, vs, gw, gh, field, mi_unused);
			}
		}
		if (!got_field) {
			raster_sdf(p_poly, min_x, min_z, vs, gw, gh, field);
		}
	}

	const double strength = p_params.get("strength", 1.0);
	const double edge_offset = p_params.get("edge_offset", 0.0);
	const double falloff_width = p_params.get("falloff_width", 0.0);
	const int material = (int)p_params.get("material", 0);
	const bool preserve_base = p_params.get("preserve_base", true);
	const uint32_t uv_bits = (uint32_t)(int64_t)p_params.get("uv_bits", 0);
	const bool composite = p_params.get("composite", true);
	const double noise_strength = p_params.get("noise_strength", 0.0);
	Object *noise_obj = p_params.get("noise", Variant());
	Ref<FastNoiseLite> noise = Object::cast_to<FastNoiseLite>(noise_obj);

	const double ramp_denom = MAX(falloff_width, 0.001);

	// Phase 1d batched control apply: accumulate per-cell control words into a box buffer (+ skip mask),
	// then commit one tile at a time. Used for the deferred non-base TYPE_CONTROL overlay; otherwise the
	// per-cell set_control_on_layer path (full-refresh, region-map fallback, or base target).
	Pasture3DLayer *wlayer = _layer_stack.is_null() ? nullptr : _layer_stack->get_layer_ptr(p_layer_id);
	const bool batched = wlayer && wlayer->get_map_type() == TYPE_CONTROL && !composite && !wlayer->is_base();
	std::vector<uint32_t> cvals;
	std::vector<uint8_t> cmask;
	if (batched) {
		cvals.assign((size_t)gw * gh, 0u);
		cmask.assign((size_t)gw * gh, 0);
	}

	const bool has_clip = p_clip.size != Vector3();
	const double cx0 = p_clip.position.x;
	const double cx1 = p_clip.position.x + p_clip.size.x;
	const double cz0 = p_clip.position.z;
	const double cz1 = p_clip.position.z + p_clip.size.z;

	for (int iz = 0; iz < gh; iz++) {
		const double z = min_z + iz * vs;
		if (has_clip && (z < cz0 || z >= cz1)) {
			continue;
		}
		const int row = iz * gw;
		for (int ix = 0; ix < gw; ix++) {
			const double signed_d = (double)field[row + ix] + edge_offset;
			if (signed_d <= 0.0) {
				continue;
			}
			const double x = min_x + ix * vs;
			if (has_clip && (x < cx0 || x >= cx1)) {
				continue;
			}
			double t = (double)raster_ramp(p_lut, (float)(signed_d / ramp_denom)) * strength;
			if (noise.is_valid()) {
				t += noise_strength * noise->get_noise_2d(x, z);
			}
			t = CLAMP(t, 0.0, 1.0);
			const int blend_int = (int)std::lround(t * 255.0);
			if (blend_int <= 0) {
				continue;
			}
			const Vector3 pos(x, 0.0, z);
			const uint32_t cur = get_control(pos);
			const uint8_t base_id = preserve_base ? get_base(cur) : (uint8_t)material;
			const uint32_t ctrl = enc_base(base_id) | enc_overlay((uint8_t)material) | enc_blend((uint8_t)blend_int) | uv_bits | (cur & 0x6);
			if (batched) {
				cvals[row + ix] = ctrl;
				cmask[row + ix] = 1;
			} else {
				set_control_on_layer(p_layer_id, pos, (int)ctrl, 1.0, composite);
			}
		}
	}

	if (batched) {
		_apply_control_block(wlayer, (int)std::lround(min_x / vs), (int)std::lround(min_z / vs), gw, gh, cvals.data(), cmask.data());
	}
}
