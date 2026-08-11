// Pasture3DSim's native side (PASTURE3D_SIM_NODE_SPEC.md). Five entry points, in the order the node
// uses them:
//
//   resample_grid      the §6 preview/build bridge — below-layer heights DOWN onto the sim grid
//   erode_heightfield  the §4 solver, as a pure function of a heightfield (pasture_3d_erosion.cpp)
//   sim_mask_deltas    §5 "simulate wide, write narrow" — deltas back UP, through the loop's falloff
//   sim_chain_blend    §19.2 — one manager pass folded into the chain, gated by its own loop
//   sim_chain_write    §19.2 — the whole chain's total delta, once, back UP onto the terrain grid
//   apply_sim_block    §8.1 — the batched raw-tile delta write, shared with the stamp_* rasterisers
//   sim_result_build   §8.2 — the four Pasture3DSimResult channels, merged across a node's loops
//   sim_extract_water  §10 — rivers off the drainage tree and lakes off the depression fill
//
// The solver itself is deliberately elsewhere and terrain-free: everything that touches a layer is
// here, everything that is landscape-evolution physics is in pasture_3d_erosion.cpp, and the gates
// drive the second half directly.

#include "pasture_3d_data.h"
#include "pasture_3d_erosion.h"
#include "pasture_3d_layer.h"
#include "pasture_3d_layer_stack.h"
#include "pasture_3d_raster_util.h"
#include "pasture_3d_relief_ops.h" // §17: the mask field reuses the relief selectors' evaluator and fields

#include <algorithm>
#include <cmath>
#include <unordered_map>
#include <utility>
#include <vector>

using namespace godot;

namespace {

// Source-sample span covering destination sample `i` of `dst_n`, in source-sample units, for the
// corner-aligned convention (dst 0 and dst_n-1 land exactly on src 0 and src_n-1). Half a destination
// step either side, clipped to the grid — so shrinking box-averages over everything it swallows and
// growing collapses to a sub-cell span the bilinear branch handles.
inline void resample_span(int i, int dst_n, int src_n, double &r_lo, double &r_hi) {
	const double ratio = (dst_n > 1) ? (double)(src_n - 1) / (double)(dst_n - 1) : 0.0;
	const double centre = (double)i * ratio;
	const double half = 0.5 * ratio;
	r_lo = std::max(centre - half, 0.0);
	r_hi = std::min(centre + half, (double)(src_n - 1));
}

// §8.2: `flow` is stored LOG-SCALED, because drainage area spans decades and a linear channel would be
// all trunk and no tributary once quantised. The convention, which phase 3 has to invert:
//
//     stored  = log(max(A, SIM_FLOW_FLOOR))      A in m²
//     read     = exp(stored)                     back to m²
//
// Natural log, and floored at 1 m² so the stored value is never negative and a cell that no result
// covers (stored 0) reads back as the smallest catchment there is rather than as a negative area.
constexpr double SIM_FLOW_FLOOR = 1.0;

// Slack, in destination cells, on "is this target cell inside that part's grid". A target grid derived
// from the parts' own bounds lands its edge samples exactly on the part edges, and a double-rounding of
// 1e-9 must not turn the last row into a hole.
constexpr double SIM_BLIT_EPS = 1.0e-3;

// Bilinear read of a row-major grid at fractional sample coords, clamped to the edges. Returns false
// (leaving r_out alone) if any of the four corners is non-finite: a no-data corner has no honest value
// and the caller writes its channel's defined zero instead of a smeared one.
inline bool grid_bilinear(const float *p_src, int p_w, int p_h, double p_fu, double p_fv, double &r_out) {
	const int x0 = (int)std::floor(std::min(std::max(p_fu, 0.0), (double)(p_w - 1)));
	const int y0 = (int)std::floor(std::min(std::max(p_fv, 0.0), (double)(p_h - 1)));
	const int x1 = std::min(x0 + 1, p_w - 1);
	const int y1 = std::min(y0 + 1, p_h - 1);
	const double tx = std::min(std::max(p_fu - (double)x0, 0.0), 1.0);
	const double ty = std::min(std::max(p_fv - (double)y0, 0.0), 1.0);
	const float v00 = p_src[y0 * p_w + x0], v10 = p_src[y0 * p_w + x1];
	const float v01 = p_src[y1 * p_w + x0], v11 = p_src[y1 * p_w + x1];
	if (!std::isfinite(v00) || !std::isfinite(v10) || !std::isfinite(v01) || !std::isfinite(v11)) {
		return false;
	}
	const double a = (double)v00 * (1.0 - tx) + (double)v10 * tx;
	const double b = (double)v01 * (1.0 - tx) + (double)v11 * tx;
	r_out = a * (1.0 - ty) + b * ty;
	return true;
}

// Douglas-Peucker on an XZ polyline, returning the indices KEPT, in order. Indices rather than points
// because every river polyline carries a parallel drainage-area array that has to be decimated with it.
// Iterative: a 500 m channel at 1 m cells recurses 500 deep in the degenerate case, and the editor's
// stack is not the place to find that out.
void dp_simplify(const std::vector<Vector2> &p_pts, double p_tol, std::vector<int> &r_keep) {
	const int n = (int)p_pts.size();
	r_keep.clear();
	if (n <= 2) {
		for (int i = 0; i < n; i++) {
			r_keep.push_back(i);
		}
		return;
	}
	std::vector<uint8_t> keep((size_t)n, 0);
	keep[0] = 1;
	keep[(size_t)n - 1] = 1;
	std::vector<std::pair<int, int>> work;
	work.push_back({ 0, n - 1 });
	const double tol2 = p_tol * p_tol;
	while (!work.empty()) {
		const std::pair<int, int> seg = work.back();
		work.pop_back();
		const int a = seg.first;
		const int b = seg.second;
		if (b <= a + 1) {
			continue;
		}
		const Vector2 pa = p_pts[(size_t)a];
		const Vector2 pb = p_pts[(size_t)b];
		const Vector2 ab = pb - pa;
		const double len2 = (double)ab.x * ab.x + (double)ab.y * ab.y;
		double worst = -1.0;
		int worst_i = -1;
		for (int i = a + 1; i < b; i++) {
			const Vector2 p = p_pts[(size_t)i];
			double d2;
			if (len2 <= 1.0e-12) {
				const double dx = (double)p.x - pa.x, dz = (double)p.y - pa.y;
				d2 = dx * dx + dz * dz;
			} else {
				double t = (((double)p.x - pa.x) * ab.x + ((double)p.y - pa.y) * ab.y) / len2;
				t = std::min(std::max(t, 0.0), 1.0);
				const double cx = (double)pa.x + ab.x * t, cz = (double)pa.y + ab.y * t;
				const double dx = (double)p.x - cx, dz = (double)p.y - cz;
				d2 = dx * dx + dz * dz;
			}
			if (d2 > worst) {
				worst = d2;
				worst_i = i;
			}
		}
		if (worst_i >= 0 && worst > tol2) {
			keep[(size_t)worst_i] = 1;
			work.push_back({ a, worst_i });
			work.push_back({ worst_i, b });
		}
	}
	for (int i = 0; i < n; i++) {
		if (keep[(size_t)i]) {
			r_keep.push_back(i);
		}
	}
}

} // namespace

PackedFloat32Array Pasture3DData::resample_grid(const PackedFloat32Array &p_src, const int p_sw, const int p_sh,
		const int p_dw, const int p_dh) {
	PackedFloat32Array out;
	if (p_sw < 1 || p_sh < 1 || p_dw < 1 || p_dh < 1 || p_src.size() < p_sw * p_sh) {
		return out;
	}
	out.resize(p_dw * p_dh);
	float *o = out.ptrw();
	const float *s = p_src.ptr();
	if (p_sw == p_dw && p_sh == p_dh) {
		// Build resolution is 1x by default, so this is the common case: copy, and in particular do NOT
		// round-trip through the interpolator, which would make a 1x "resample" lossy for no reason.
		for (int i = 0; i < p_dw * p_dh; i++) {
			o[i] = s[i];
		}
		return out;
	}
	for (int dz = 0; dz < p_dh; dz++) {
		double z0, z1;
		resample_span(dz, p_dh, p_sh, z0, z1);
		const int iz0 = (int)std::floor(z0);
		const int iz1 = std::min((int)std::ceil(z1), p_sh - 1);
		for (int dx = 0; dx < p_dw; dx++) {
			double x0, x1;
			resample_span(dx, p_dw, p_sw, x0, x1);
			const int ix0 = (int)std::floor(x0);
			const int ix1 = std::min((int)std::ceil(x1), p_sw - 1);
			// NaN-aware: no-data cells contribute nothing and an all-no-data span stays no-data, so the
			// hole in an unregioned corner survives the round trip instead of smearing into real ground.
			double acc = 0.0;
			double wsum = 0.0;
			for (int z = iz0; z <= iz1; z++) {
				// Overlap of this source sample's unit cell with the destination span, per axis.
				const double wz = std::min((double)z + 0.5, z1 + 0.5) - std::max((double)z - 0.5, z0 - 0.5);
				if (wz <= 0.0) {
					continue;
				}
				for (int x = ix0; x <= ix1; x++) {
					const double wx = std::min((double)x + 0.5, x1 + 0.5) - std::max((double)x - 0.5, x0 - 0.5);
					if (wx <= 0.0) {
						continue;
					}
					const float v = s[z * p_sw + x];
					if (!std::isfinite(v)) {
						continue;
					}
					acc += (double)v * wx * wz;
					wsum += wx * wz;
				}
			}
			o[dz * p_dw + dx] = wsum > 0.0 ? (float)(acc / wsum) : (float)NAN;
		}
	}
	return out;
}

Dictionary Pasture3DData::erode_heightfield(const PackedFloat32Array &p_z, const Dictionary &p_params,
		const PackedFloat32Array &p_erodability) {
	Dictionary out;
	ErosionParams params = erosion_params_from_dict(p_params);
	std::vector<float> z((size_t)p_z.size());
	for (int i = 0; i < p_z.size(); i++) {
		z[(size_t)i] = p_z[i];
	}
	const ErosionResult r = erosion_solve(z, params, p_erodability);
	out["ok"] = r.ok;
	if (!r.ok) {
		return out; // no "z" key at all: a caller that forgets to check `ok` fails loudly, not silently
	}
	PackedFloat32Array zo;
	zo.resize((int)r.z.size());
	for (size_t i = 0; i < r.z.size(); i++) {
		zo[(int)i] = r.z[i];
	}
	out["z"] = zo;
	out["diffusion_substeps"] = r.diffusion_substeps;
	if (params.want_diagnostics) {
		PackedFloat32Array flow, lake;
		PackedInt32Array recv, stack;
		PackedByteArray bnd;
		flow.resize((int)r.flow.size());
		lake.resize((int)r.lake_depth.size());
		recv.resize((int)r.receiver.size());
		stack.resize((int)r.stack.size());
		bnd.resize((int)r.boundary.size());
		for (size_t i = 0; i < r.flow.size(); i++) {
			flow[(int)i] = r.flow[i];
			lake[(int)i] = r.lake_depth[i];
			recv[(int)i] = r.receiver[i];
			bnd[(int)i] = r.boundary[i];
		}
		for (size_t i = 0; i < r.stack.size(); i++) {
			stack[(int)i] = r.stack[i];
		}
		out["flow"] = flow;
		out["lake_depth"] = lake;
		out["receiver"] = recv;
		out["stack"] = stack;
		out["boundary"] = bnd;
	}
	return out;
}

// §17: the per-cell mask field, from a stack of Pasture3DReliefSelectors evaluated over a height grid.
//
// Named `sim_` until §18 — nothing in it is sim-specific. It takes a height grid and a selector block, so
// the Plow's and Mound's relief selectors read it on exactly the same terms, and the §18 mask preview
// calls it rather than approximating it. The grid below is "the sim grid" only because Sim is the first
// caller; for a stamp brush it is the bake grid.
//
// Same evaluator the relief materials use (`relief_selector_value`) over the same fields
// (`relief_fields_build`), so a SLOPE band means under a Sim exactly what it means under a Plow. It lives
// here rather than in GDScript because phase 6 re-evaluates it once per pass and `_terrain_fields` is
// O(cells) interpreted — the same reason the erodability LUT is capped at 256².
//
// Selectors combine by PRODUCT. Each already returns `lerp(1, band, strength)`, so 1.0 means "passes
// fully" and a `strength = 0` selector drops out of the product for free; multiplying soft 0..1 weights
// yields another soft 0..1 weight and introduces no new semantics. `min` would have made the falloffs
// meaningless (the narrowest band would win outright) and last-wins would have made order significant for
// no reason.
//
// When the erodability params are present the TEXTURE is composed in as well, so the caller gets one
// field to hand straight to the solver:
//
//     field = (erodability_min + (max - min) * texture) * Π selectors
//
// and the node then passes an identity range, because the affine map has already been applied here. The
// texture is sampled by normalised uv with the same arithmetic `lut_sample` uses inside the solver, so
// composing here and letting the solver map are the same numbers in a different place.
//
// With no selectors AND no texture the array comes back EMPTY, and the caller must then pass nothing at
// all rather than a field of ones — that is what keeps an unmasked Sim bitwise identical to phase 4, and
// what makes "clear the masks" a usable control for every gate in §17.8.
PackedFloat32Array Pasture3DData::selector_mask_field(const PackedFloat32Array &p_z, const Dictionary &p_params,
		const PackedFloat32Array &p_selectors, const Dictionary &p_sim_result) {
	PackedFloat32Array out;
	const int gw = (int)p_params.get("gw", 0);
	const int gh = (int)p_params.get("gh", 0);
	const double cell = (double)p_params.get("cell_size", 1.0);
	const double min_x = (double)p_params.get("min_x", 0.0);
	const double min_z = (double)p_params.get("min_z", 0.0);
	if (gw < 1 || gh < 1 || cell <= 0.0 || p_z.size() < gw * gh) {
		return out;
	}
	const int n_sel = p_selectors.size() / RELIEF_SELECTOR_STRIDE;

	// §18: an optional per-cell multiplier, applied on the way out. The mask preview uses it to clip the
	// weight to the brush's own area, and it lives here rather than in a GDScript loop because that loop
	// is O(cells) interpreted and runs on every frame of a slider drag.
	const PackedFloat32Array area = p_params.get("area_mask", PackedFloat32Array());
	const bool has_area = area.size() == gw * gh;
	const float *ap = has_area ? area.ptr() : nullptr;

	const PackedFloat32Array erod_lut = p_params.get("erodability_lut", PackedFloat32Array());
	const int ew = (int)p_params.get("erodability_w", 0);
	const int eh = (int)p_params.get("erodability_h", 0);
	const bool has_map = ew > 1 && eh > 1 && erod_lut.size() >= ew * eh;
	const double e_lo = (double)p_params.get("erodability_min", 1.0);
	const double e_hi = (double)p_params.get("erodability_max", 1.0);
	if (n_sel < 1 && !has_map) {
		return out;
	}

	// Derivatives are taken over `cell`, the SIM cell size — not the terrain's vertex spacing. That is
	// what makes a SLOPE band read differently at preview resolution (§17.5), and it is correct: the mask
	// gates a solve that is itself running on this grid.
	ReliefFields fields;
	relief_fields_build(p_z, min_x, min_z, cell, gw, gh,
			[](double, double) { return (float)NAN; }, fields);
	if (!fields.ready) {
		return out;
	}
	// Only worth resampling four more grids when a sim Kind is actually in the stack; `relief_fields_add_sim`
	// is a no-op on an empty or malformed dictionary and leaves `has_sim` false, so the sim Kinds then read
	// their defined zeros rather than garbage.
	if (n_sel > 0 && !p_sim_result.is_empty()) {
		relief_fields_add_sim(p_sim_result, min_x, min_z, cell, gw, gh, fields);
	}
	// §21.6: the wider slope / curvature grids, for any selector that set a `measure_radius`. Over THIS
	// grid's cell size, which for a mask is the sim cell and not the terrain's vertex spacing — the same
	// choice §17.5 already records for the one-cell fields, and the reason a radius in metres is worth
	// having at all: it is the one part of a band that now means the same thing at both resolutions.
	relief_fields_add_measured(p_selectors, fields);

	out.resize(gw * gh);
	float *o = out.ptrw();
	ReliefSample ground;
	for (int iz = 0; iz < gh; iz++) {
		const double v = gh > 1 ? (double)iz / (double)(gh - 1) : 0.0;
		const int row = iz * gw;
		for (int ix = 0; ix < gw; ix++) {
			fields.sample(row + ix, ground);
			double w = 1.0;
			for (int s = 0; s < n_sel; s++) {
				w *= relief_selector_weight(p_selectors, s, ground);
			}
			double base = 1.0;
			if (has_map) {
				const double u = gw > 1 ? (double)ix / (double)(gw - 1) : 0.0;
				double t = 0.0; // a non-finite texel is a broken texture; e_lo is the defined answer
				grid_bilinear(erod_lut.ptr(), ew, eh, u * (double)(ew - 1), v * (double)(eh - 1), t);
				base = e_lo + (e_hi - e_lo) * t;
			}
			o[row + ix] = (float)(base * w) * (ap ? ap[row + ix] : 1.0f);
		}
	}
	return out;
}

PackedFloat32Array Pasture3DData::sim_mask_deltas(const PackedFloat32Array &p_deltas, const PackedVector2Array &p_poly,
		const Dictionary &p_params, const PackedFloat32Array &p_lut) {
	PackedFloat32Array out;
	// Optional: when params["baseline"] is the pre-solve surface, `p_deltas` is read as the POST-solve
	// surface and the difference is taken here. That is what lets the node run the solver in chunks (so
	// a long build stays cancellable) without an O(cells) subtraction loop in GDScript afterwards.
	const PackedFloat32Array baseline = p_params.get("baseline", PackedFloat32Array());
	const bool differencing = baseline.size() == p_deltas.size() && baseline.size() > 0;
	const int sw = (int)p_params.get("sw", 0);
	const int sh = (int)p_params.get("sh", 0);
	const int gw = (int)p_params.get("gw", 0);
	const int gh = (int)p_params.get("gh", 0);
	if (sw < 1 || sh < 1 || gw < 1 || gh < 1 || p_deltas.size() < sw * sh || p_poly.size() < 3) {
		return out;
	}
	const double sim_min_x = p_params.get("sim_min_x", 0.0);
	const double sim_min_z = p_params.get("sim_min_z", 0.0);
	const double sim_cell = p_params.get("sim_cell", 1.0);
	const double min_x = p_params.get("min_x", 0.0);
	const double min_z = p_params.get("min_z", 0.0);
	const double vs = p_params.get("vs", 1.0);
	const double edge_offset = p_params.get("edge_offset", 0.0);
	const double falloff_width = MAX((double)p_params.get("falloff_width", 1.0), 0.001);
	if (sim_cell <= 0.0 || vs <= 0.0) {
		return out;
	}
	// §17.3's WRITE mask: a sim-resolution 0..1 field multiplied into the loop falloff, so the solve is
	// untouched and only the committed delta is gated. Sampled at the same (fu,fv) as the delta below, so
	// the two are read off the same grid with the same interpolation and cannot drift apart. Absent (or
	// the wrong size) leaves this path bitwise identical to phase 4 — gate AD leans on that.
	const PackedFloat32Array write_mask = p_params.get("write_mask", PackedFloat32Array());
	const bool has_write_mask = write_mask.size() == sw * sh;
	const float *wm = has_write_mask ? write_mask.ptr() : nullptr;

	// The loop's area mask, on the WRITE grid. Identical construction to Pasture3DPlow's, so a Sim and a
	// Plow sharing a loop feather over the same band.
	std::vector<float> field;
	pasture3d_raster_sdf(p_poly, min_x, min_z, vs, gw, gh, field);

	out.resize(gw * gh);
	float *o = out.ptrw();
	const float *d = p_deltas.ptr();
	const float *base = differencing ? baseline.ptr() : nullptr;
	for (int iz = 0; iz < gh; iz++) {
		const double z = min_z + iz * vs;
		const int row = iz * gw;
		for (int ix = 0; ix < gw; ix++) {
			o[row + ix] = (float)NAN;
			const double signed_d = (double)field[row + ix] + edge_offset;
			if (signed_d <= 0.0) {
				continue; // outside the loop: never written, so the margin cannot leak (gate G)
			}
			const double mask = (double)pasture3d_raster_ramp(p_lut, (float)(signed_d / falloff_width));
			if (mask <= 0.0) {
				continue;
			}
			// Bilinear read of the sim-resolution delta at this terrain vertex (§6: "the delta is
			// bilinearly upsampled on write"). At build resolution the two grids coincide and this is
			// an exact sample, so a 1x build is not blurred by its own upsampler.
			const double x = min_x + ix * vs;
			const double fu = (x - sim_min_x) / sim_cell;
			const double fv = (z - sim_min_z) / sim_cell;
			if (fu < -0.001 || fv < -0.001 || fu > (double)(sw - 1) + 0.001 || fv > (double)(sh - 1) + 0.001) {
				continue; // outside the simulated area entirely — should not happen, but never guess
			}
			const int x0 = CLAMP((int)std::floor(fu), 0, sw - 1);
			const int y0 = CLAMP((int)std::floor(fv), 0, sh - 1);
			const int x1 = MIN(x0 + 1, sw - 1);
			const int y1 = MIN(y0 + 1, sh - 1);
			const double tx = CLAMP(fu - (double)x0, 0.0, 1.0);
			const double ty = CLAMP(fv - (double)y0, 0.0, 1.0);
			const int i00 = y0 * sw + x0, i10 = y0 * sw + x1;
			const int i01 = y1 * sw + x0, i11 = y1 * sw + x1;
			const float d00 = base ? d[i00] - base[i00] : d[i00];
			const float d10 = base ? d[i10] - base[i10] : d[i10];
			const float d01 = base ? d[i01] - base[i01] : d[i01];
			const float d11 = base ? d[i11] - base[i11] : d[i11];
			if (!std::isfinite(d00) || !std::isfinite(d10) || !std::isfinite(d01) || !std::isfinite(d11)) {
				continue; // a no-data corner: no honest delta here, so write nothing
			}
			const double a = (double)d00 * (1.0 - tx) + (double)d10 * tx;
			const double b = (double)d01 * (1.0 - tx) + (double)d11 * tx;
			double gate = mask;
			if (wm) {
				double w = 1.0;
				if (grid_bilinear(wm, sw, sh, fu, fv, w)) {
					gate *= CLAMP(w, 0.0, 1.0);
				}
				if (gate <= 0.0) {
					continue; // fully masked out: leave the cell uncovered rather than writing a zero
				}
			}
			const double delta = (a * (1.0 - ty) + b * ty) * gate;
			if (delta == 0.0) {
				continue; // an exact zero is not a write; leaving the cell uncovered keeps the layer sparse
			}
			o[row + ix] = (float)delta;
		}
	}
	return out;
}

// §19.2 step 3 — fold ONE pass's solved surface into the chain, masked to that pass's own loop:
//
//     z_out = z_before + gate * (z_after - z_before)
//
// `gate` is that pass's own loop mask at sim resolution — the very falloff `sim_mask_deltas` rasterises,
// obtained by feeding it a field of ones — already multiplied by the pass's write mask. So a pass gates
// its contribution through exactly the same masker a standalone Sim gates its write through, and the two
// cannot drift apart.
//
// A NaN gate means "outside this pass's loop", and that is a gate of ZERO, not a hole: the surface has to
// pass through untouched so the NEXT pass reads continuous ground across the whole cluster. Getting that
// wrong would punch the margin out of the chain and reintroduce, inside one solve, exactly the §5 seam the
// manager exists to delete. A non-finite `z_after` is different — the solver had no answer there — and
// leaves `z_before` standing.
PackedFloat32Array Pasture3DData::sim_chain_blend(const PackedFloat32Array &p_before,
		const PackedFloat32Array &p_after, const PackedFloat32Array &p_gate) {
	PackedFloat32Array out;
	const int n = p_before.size();
	if (n < 1 || p_after.size() != n || p_gate.size() != n) {
		return out; // size mismatch is a caller bug; an empty return fails loudly rather than half-blending
	}
	out.resize(n);
	float *o = out.ptrw();
	const float *b = p_before.ptr();
	const float *a = p_after.ptr();
	const float *g = p_gate.ptr();
	for (int i = 0; i < n; i++) {
		const float gate = std::isfinite(g[i]) ? std::min(std::max(g[i], 0.0f), 1.0f) : 0.0f;
		if (gate <= 0.0f || !std::isfinite(a[i]) || !std::isfinite(b[i])) {
			o[i] = b[i];
			continue;
		}
		o[i] = (float)((double)b[i] + (double)gate * ((double)a[i] - (double)b[i]));
	}
	return out;
}

// §21.2 — one MEMBER of a Pasture3DSimPass, added into the pass's accumulator.
//
//     acc += gate * (after - before)
//
// The difference from `sim_chain_blend` is the whole difference between a member and a pass: `before` is
// the pass's ONE input surface and is never advanced, so every member of a container solves the same
// ground and their masked deltas SUM. Overlapping members therefore cut deeper, which is what two
// overlapping stamp brushes on one ADD layer have always done here.
//
// The accumulator is double because it is summed across members and the terms partially cancel; the
// surface it is committed back to is float either way. Same NaN rules as the blend: a NaN gate is a gate
// of zero (outside this member's loop, the ground passes through), and a non-finite `after` means the
// solver had no answer and contributes nothing rather than poisoning the cell.
//
// NaN IN THE ACCUMULATOR MEANS "NO MEMBER HAS REACHED THIS CELL" — the same convention `sim_mask_deltas`
// and `sim_chain_write` already use for "uncovered", and not merely a tidy default. Zero would collide
// with a member that legitimately contributed nothing, and `sim_pass_commit` has to tell those apart to
// stay bit-identical to `sim_chain_blend`: the blend leaves an untouched cell's bytes alone, while
// `before + 0.0` turns a stored -0.0f into +0.0f. Numerically nil, bitwise a difference, and gate BD
// compares bytes.
PackedFloat64Array Pasture3DData::sim_pass_accumulate(const PackedFloat64Array &p_acc,
		const PackedFloat32Array &p_before, const PackedFloat32Array &p_after, const PackedFloat32Array &p_gate) {
	PackedFloat64Array out;
	const int n = p_before.size();
	if (n < 1 || p_after.size() != n || p_gate.size() != n) {
		return out; // size mismatch is a caller bug; an empty return fails loudly rather than half-adding
	}
	const bool seeded = p_acc.size() == n;
	out.resize(n);
	double *o = out.ptrw();
	const double *acc = seeded ? p_acc.ptr() : nullptr;
	const float *b = p_before.ptr();
	const float *a = p_after.ptr();
	const float *g = p_gate.ptr();
	for (int i = 0; i < n; i++) {
		const double prev = seeded ? acc[i] : (double)NAN;
		const float gate = std::isfinite(g[i]) ? std::min(std::max(g[i], 0.0f), 1.0f) : 0.0f;
		if (gate <= 0.0f || !std::isfinite(a[i]) || !std::isfinite(b[i])) {
			o[i] = prev; // this member did not reach here; whoever else did still stands
			continue;
		}
		o[i] = (std::isnan(prev) ? 0.0 : prev) + (double)gate * ((double)a[i] - (double)b[i]);
	}
	return out;
}

// §21.2 — the pass's finished surface: `before` plus everything its members contributed.
//
// A cell no member reached (NaN accumulator) comes back UNTOUCHED, byte for byte. Everywhere else this
// evaluates the same double expression `sim_chain_blend` does, so a pass of ONE member is bitwise that
// blend in every case — including the cell where a member's gate is positive and its delta is exactly
// zero, which is why the untouched case needed a sentinel of its own rather than a test for 0.
PackedFloat32Array Pasture3DData::sim_pass_commit(const PackedFloat32Array &p_before, const PackedFloat64Array &p_acc) {
	PackedFloat32Array out;
	const int n = p_before.size();
	if (n < 1 || p_acc.size() != n) {
		return out;
	}
	out.resize(n);
	float *o = out.ptrw();
	const float *b = p_before.ptr();
	const double *a = p_acc.ptr();
	for (int i = 0; i < n; i++) {
		o[i] = (std::isnan(a[i]) || !std::isfinite(b[i])) ? b[i] : (float)((double)b[i] + a[i]);
	}
	return out;
}

// §19.2 step 4 — the chain's TOTAL delta `z_N - z0`, upsampled from the cluster's sim grid onto the
// terrain-resolution write grid. ONE write per cluster, however many passes ran.
//
// No polygon and no falloff here, deliberately: every pass already gated its own contribution through its
// own loop in `sim_chain_blend`, so the total delta is zero everywhere no pass touched. Masking again
// would apply one pass's falloff to another pass's delta. An exact zero therefore comes back NaN — not a
// write — which is the same "leave the cell uncovered" rule `sim_mask_deltas` uses and what keeps the
// catchment margin out of the layer (gate G's claim, re-earned by the manager).
//
// Reads the sim grid through `grid_bilinear`, the same tap `sim_mask_deltas` samples its write mask with.
PackedFloat32Array Pasture3DData::sim_chain_write(const PackedFloat32Array &p_z0, const PackedFloat32Array &p_zn,
		const Dictionary &p_params) {
	PackedFloat32Array out;
	const int sw = (int)p_params.get("sw", 0);
	const int sh = (int)p_params.get("sh", 0);
	const int gw = (int)p_params.get("gw", 0);
	const int gh = (int)p_params.get("gh", 0);
	if (sw < 2 || sh < 2 || gw < 1 || gh < 1 || p_z0.size() < sw * sh || p_zn.size() < sw * sh) {
		return out;
	}
	const double sim_min_x = p_params.get("sim_min_x", 0.0);
	const double sim_min_z = p_params.get("sim_min_z", 0.0);
	const double sim_cell = p_params.get("sim_cell", 1.0);
	const double min_x = p_params.get("min_x", 0.0);
	const double min_z = p_params.get("min_z", 0.0);
	const double vs = p_params.get("vs", 1.0);
	if (sim_cell <= 0.0 || vs <= 0.0) {
		return out;
	}
	// The difference is taken on the SIM grid and interpolated afterwards. Interpolation is linear, so
	// this is the same arithmetic as differencing two interpolated surfaces — but it keeps the cancellation
	// exact at build resolution, where the tap is an identity and z_N - z0 must come out bit-for-bit.
	std::vector<float> d((size_t)sw * sh);
	const float *z0 = p_z0.ptr();
	const float *zn = p_zn.ptr();
	for (int i = 0; i < sw * sh; i++) {
		d[(size_t)i] = (std::isfinite(z0[i]) && std::isfinite(zn[i])) ? (float)((double)zn[i] - (double)z0[i]) : (float)NAN;
	}
	out.resize(gw * gh);
	float *o = out.ptrw();
	for (int iz = 0; iz < gh; iz++) {
		const double z = min_z + iz * vs;
		const double fv = (z - sim_min_z) / sim_cell;
		const int row = iz * gw;
		for (int ix = 0; ix < gw; ix++) {
			o[row + ix] = (float)NAN;
			const double x = min_x + ix * vs;
			const double fu = (x - sim_min_x) / sim_cell;
			if (fu < -0.001 || fv < -0.001 || fu > (double)(sw - 1) + 0.001 || fv > (double)(sh - 1) + 0.001) {
				continue; // outside the cluster's simulated area entirely
			}
			double delta = 0.0;
			if (!grid_bilinear(d.data(), sw, sh, fu, fv, delta)) {
				continue; // a no-data corner: no honest delta here, so write nothing
			}
			if (delta == 0.0) {
				continue; // no pass reached this cell; leaving it uncovered keeps the layer sparse
			}
			o[row + ix] = (float)delta;
		}
	}
	return out;
}

void Pasture3DData::apply_sim_block(const int p_layer_id, const double p_min_x, const double p_min_z, const double p_vs,
		const int p_gw, const int p_gh, const PackedFloat32Array &p_deltas, const int p_blend) {
	if (p_gw < 1 || p_gh < 1 || p_deltas.size() < p_gw * p_gh || p_vs <= 0.0) {
		return;
	}
	Pasture3DLayer *layer = _layer_stack.is_null() ? nullptr : _layer_stack->get_layer_ptr(p_layer_id);
	if (!layer) {
		return;
	}
	if (layer->is_base()) {
		// The batched path writes RGF overlay tiles. Sim always paints into its own reserved overlay
		// (Pasture3DTerrainBrush._ensure_layer_for), so this is a misuse, not a fallback case.
		ERR_PRINT("Pasture3DData::apply_sim_block: layer is the dense base map; Sim writes into an overlay.");
		return;
	}
	_apply_stamp_block(layer, (int)std::lround(p_min_x / p_vs), (int)std::lround(p_min_z / p_vs),
			p_gw, p_gh, p_deltas.ptr(), p_blend);
}

Dictionary Pasture3DData::sim_result_build(const Array &p_parts, const Dictionary &p_target) {
	Dictionary out;
	out["ok"] = false;
	const int tw = (int)p_target.get("width", 0);
	const int th = (int)p_target.get("height", 0);
	const double tcell = (double)p_target.get("cell_size", 0.0);
	const double tmin_x = (double)p_target.get("min_x", 0.0);
	const double tmin_z = (double)p_target.get("min_z", 0.0);
	if (tw < 2 || th < 2 || tcell <= 0.0 || p_parts.is_empty()) {
		return out; // no "flow" key at all, so a caller that ignores `ok` fails loudly
	}
	const int64_t n = (int64_t)tw * (int64_t)th;

	// The three fields that are actually blitted. `erosion` and `deposition` are NOT among them: they
	// are the two signs of ONE delta field (§8.2), split at the very end on the target grid. Splitting
	// per part and interpolating the halves separately would let a bilinear tap straddling a sign change
	// produce a cell with erosion AND deposition both non-zero, which is the invariant gate Q measures.
	std::vector<float> delta((size_t)n, 0.0f);
	std::vector<float> flow((size_t)n, 0.0f); // log-scaled; 0 == SIM_FLOW_FLOOR == "no catchment here"
	std::vector<float> wet((size_t)n, 0.0f);
	// Merge precedence (§8.2). A cell inside a loop's WRITE area beats a cell that some other loop merely
	// simulated as catchment margin; ties go to the earlier loop. 0 = nothing has claimed this cell yet.
	std::vector<uint8_t> prio((size_t)n, 0);

	int parts_used = 0;
	for (int k = 0; k < p_parts.size(); k++) {
		const Dictionary part = p_parts[k];
		const int sw = (int)part.get("sw", 0);
		const int sh = (int)part.get("sh", 0);
		const double pcell = (double)part.get("cell", 0.0);
		const double pmin_x = (double)part.get("min_x", 0.0);
		const double pmin_z = (double)part.get("min_z", 0.0);
		const PackedFloat32Array z0 = part.get("z0", PackedFloat32Array());
		const PackedFloat32Array z1 = part.get("z1", PackedFloat32Array());
		const PackedFloat32Array pflow = part.get("flow", PackedFloat32Array());
		const PackedFloat32Array plake = part.get("lake", PackedFloat32Array());
		const int64_t sn = (int64_t)sw * (int64_t)sh;
		if (sw < 2 || sh < 2 || pcell <= 0.0 || z0.size() < sn || z1.size() < sn ||
				pflow.size() < sn || plake.size() < sn) {
			continue;
		}
		// The loop's own write footprint, in world XZ, for the precedence rule above.
		const double wx0 = (double)part.get("write_min_x", pmin_x);
		const double wz0 = (double)part.get("write_min_z", pmin_z);
		const double wx1 = (double)part.get("write_max_x", pmin_x + pcell * (sw - 1));
		const double wz1 = (double)part.get("write_max_z", pmin_z + pcell * (sh - 1));

		// Derived once per part, on the part's own grid: the net delta (§8.2 — the NET positive/negative
		// parts of z_final - z_initial, not an accumulation over iterations) and the log flow.
		std::vector<float> pd((size_t)sn), pf((size_t)sn);
		{
			const float *a = z0.ptr();
			const float *b = z1.ptr();
			const float *f = pflow.ptr();
			for (int64_t i = 0; i < sn; i++) {
				pd[(size_t)i] = (std::isfinite(a[i]) && std::isfinite(b[i])) ? (b[i] - a[i]) : (float)NAN;
				const double av = std::isfinite(f[i]) ? (double)f[i] : SIM_FLOW_FLOOR;
				pf[(size_t)i] = (float)std::log(std::max(av, SIM_FLOW_FLOOR));
			}
		}
		const float *pl = plake.ptr();
		parts_used++;

		// Fast path: the single-loop case, where the target grid IS this part's grid. Worth its own
		// branch — it is the overwhelmingly common case, and it makes the shipped result bit-exact
		// rather than "the same to within a bilinear tap that should have been the identity".
		const bool exact = p_parts.size() == 1 && sw == tw && sh == th &&
				std::abs(pmin_x - tmin_x) < 1.0e-6 && std::abs(pmin_z - tmin_z) < 1.0e-6 &&
				std::abs(pcell - tcell) < 1.0e-9;
		if (exact) {
			for (int64_t i = 0; i < n; i++) {
				delta[(size_t)i] = std::isfinite(pd[(size_t)i]) ? pd[(size_t)i] : 0.0f;
				flow[(size_t)i] = pf[(size_t)i];
				wet[(size_t)i] = std::isfinite(pl[i]) ? pl[i] : 0.0f;
				prio[(size_t)i] = 2;
			}
			continue;
		}

		for (int iz = 0; iz < th; iz++) {
			const double wz = tmin_z + (double)iz * tcell;
			const double fv = (wz - pmin_z) / pcell;
			if (fv < -SIM_BLIT_EPS || fv > (double)(sh - 1) + SIM_BLIT_EPS) {
				continue;
			}
			const bool in_wz = (wz >= wz0 - SIM_BLIT_EPS && wz <= wz1 + SIM_BLIT_EPS);
			const int row = iz * tw;
			for (int ix = 0; ix < tw; ix++) {
				const double wx = tmin_x + (double)ix * tcell;
				const double fu = (wx - pmin_x) / pcell;
				if (fu < -SIM_BLIT_EPS || fu > (double)(sw - 1) + SIM_BLIT_EPS) {
					continue;
				}
				const uint8_t p = (in_wz && wx >= wx0 - SIM_BLIT_EPS && wx <= wx1 + SIM_BLIT_EPS) ? 2 : 1;
				if (p <= prio[(size_t)(row + ix)]) {
					continue; // an earlier loop already claimed this cell at the same or better standing
				}
				double dv = 0.0, fvv = 0.0, lv = 0.0;
				if (!grid_bilinear(pd.data(), sw, sh, fu, fv, dv)) {
					dv = 0.0; // a no-data corner: no honest delta, so this cell moved by nothing
				}
				grid_bilinear(pf.data(), sw, sh, fu, fv, fvv);
				grid_bilinear(pl, sw, sh, fu, fv, lv);
				delta[(size_t)(row + ix)] = (float)dv;
				flow[(size_t)(row + ix)] = (float)fvv;
				wet[(size_t)(row + ix)] = (float)lv;
				prio[(size_t)(row + ix)] = p;
			}
		}
	}
	if (parts_used == 0) {
		return out;
	}

	// §8.2 + gate Q: erosion and deposition are the negative and positive halves of the SAME field, so
	// no cell can carry both and their sum reconstructs the delta bit-for-bit.
	PackedFloat32Array o_flow, o_ero, o_dep, o_wet;
	o_flow.resize((int)n);
	o_ero.resize((int)n);
	o_dep.resize((int)n);
	o_wet.resize((int)n);
	float *fo = o_flow.ptrw();
	float *eo = o_ero.ptrw();
	float *dpo = o_dep.ptrw();
	float *wo = o_wet.ptrw();
	for (int64_t i = 0; i < n; i++) {
		const float d = delta[(size_t)i];
		fo[i] = flow[(size_t)i];
		eo[i] = d < 0.0f ? d : 0.0f;
		dpo[i] = d > 0.0f ? d : 0.0f;
		wo[i] = wet[(size_t)i] > 0.0f ? wet[(size_t)i] : 0.0f;
	}
	out["flow"] = o_flow;
	out["erosion"] = o_ero;
	out["deposition"] = o_dep;
	out["wetness"] = o_wet;
	out["parts"] = parts_used;
	out["ok"] = true;
	return out;
}

Dictionary Pasture3DData::sim_extract_water(const PackedFloat32Array &p_z, const Dictionary &p_params) {
	Dictionary out;
	out["ok"] = false;
	const int gw = (int)p_params.get("gw", 0);
	const int gh = (int)p_params.get("gh", 0);
	const int64_t n = (int64_t)gw * (int64_t)gh;
	if (gw < 3 || gh < 3 || p_z.size() < n) {
		return out;
	}
	const double cell = MAX((double)p_params.get("cell_size", 1.0), 1.0e-6);
	const double min_x = (double)p_params.get("min_x", 0.0);
	const double min_z = (double)p_params.get("min_z", 0.0);
	const double river_area = (double)p_params.get("river_area_threshold", 5000.0);
	const double min_len = (double)p_params.get("min_river_length", 40.0);
	const double tol = MAX((double)p_params.get("curve_tolerance", 2.0), 0.0);
	const double lake_min_depth = (double)p_params.get("lake_depth_threshold", 0.5);
	const double lake_min_area = (double)p_params.get("min_lake_area", 200.0);
	const double depth_pct = CLAMP((double)p_params.get("lake_depth_percentile", 0.9), 0.0, 1.0);
	const double cell_area = cell * cell;

	// ---- One routing pass, shared by both extractions ----------------------------------------------
	// §10's whole premise: the router already produced a pit-free forest with drainage areas, so this is
	// a traversal and not a reconstruction. Running the SAME solver in its zero-iteration routing mode
	// (rather than a second, private implementation of priority-flood) is what makes the extracted
	// network the network the sim actually produced, and it is why the lake fill costs nothing extra.
	std::vector<float> z((size_t)n);
	for (int64_t i = 0; i < n; i++) {
		z[(size_t)i] = p_z[(int)i];
	}
	ErosionParams ep;
	ep.gw = gw;
	ep.gh = gh;
	ep.cell_size = cell;
	ep.iterations = 0;
	ep.want_diagnostics = true;
	const ErosionResult r = erosion_solve(z, ep, PackedFloat32Array());
	if (!r.ok) {
		return out;
	}

	// ---- 10.1 Rivers ---------------------------------------------------------------------------------
	// Stream-link decomposition. A channel cell's receiver is always a channel cell too (drainage area
	// only grows downstream), so the channel set is a forest and its links are exactly the segments §10.1
	// asks for: cut at every cell with zero channel donors (a head) or two or more (a confluence).
	// Walking one polyline per source-to-outlet instead would overlap every shared trunk and carve it
	// once per tributary.
	std::vector<uint8_t> is_channel((size_t)n, 0);
	int channel_cells = 0;
	for (int64_t i = 0; i < n; i++) {
		if (!r.boundary[(size_t)i] && (double)r.flow[(size_t)i] >= river_area) {
			is_channel[(size_t)i] = 1;
			channel_cells++;
		}
	}
	std::vector<int> chan_donors((size_t)n, 0);
	for (int64_t i = 0; i < n; i++) {
		if (!is_channel[(size_t)i]) {
			continue;
		}
		const int rc = r.receiver[(size_t)i];
		if (rc != (int)i && is_channel[(size_t)rc]) {
			chan_donors[(size_t)rc]++;
		}
	}
	Array rivers;
	std::vector<Vector2> poly;
	std::vector<int> cells;
	std::vector<int> keep;
	for (int64_t s = 0; s < n; s++) {
		if (!is_channel[(size_t)s] || chan_donors[(size_t)s] == 1) {
			continue; // interior to some other link, not the start of one
		}
		poly.clear();
		cells.clear();
		int cur = (int)s;
		cells.push_back(cur);
		double length = 0.0;
		while (true) {
			const int rc = r.receiver[(size_t)cur];
			if (rc == cur) {
				break; // an outlet: the river leaves the map here
			}
			const int dx = (rc % gw) - (cur % gw);
			const int dz = (rc / gw) - (cur / gw);
			length += (dx != 0 && dz != 0) ? cell * 1.4142135623730951 : cell;
			cells.push_back(rc);
			// Stop AT the next junction (it belongs to both links, so the polylines meet rather than
			// leaving a one-cell gap at every confluence), and at the domain edge.
			if (r.boundary[(size_t)rc] || !is_channel[(size_t)rc] || chan_donors[(size_t)rc] != 1) {
				break;
			}
			cur = rc;
		}
		if (cells.size() < 2 || length < min_len) {
			continue;
		}
		poly.reserve(cells.size());
		for (size_t k = 0; k < cells.size(); k++) {
			const int i = cells[k];
			poly.push_back(Vector2((float)(min_x + (double)(i % gw) * cell),
					(float)(min_z + (double)(i / gw) * cell)));
		}
		dp_simplify(poly, tol, keep);
		PackedVector3Array pts;
		PackedFloat32Array areas;
		pts.resize((int)keep.size());
		areas.resize((int)keep.size());
		for (size_t k = 0; k < keep.size(); k++) {
			const int i = cells[(size_t)keep[k]];
			const float y = std::isfinite(p_z[i]) ? p_z[i] : 0.0f;
			pts[(int)k] = Vector3(poly[(size_t)keep[k]].x, y, poly[(size_t)keep[k]].y);
			areas[(int)k] = r.flow[(size_t)i];
		}
		Dictionary seg;
		seg["points"] = pts;
		seg["areas"] = areas;
		seg["length"] = length;
		seg["cells"] = (int)cells.size();
		rivers.push_back(seg);
	}

	// ---- 10.2 Lakes ----------------------------------------------------------------------------------
	// FOUR-connected components, not eight. Eight-connected regions can touch at a corner, and a contour
	// traced round one of those is not a simple loop — it pinches to a point and the Pond's polygon fill
	// behaves unpredictably there. Four-connectivity costs a couple of extra lakes where a channel
	// narrows to a diagonal and buys a boundary that is always a clean ring.
	std::vector<uint8_t> wet((size_t)n, 0);
	int lake_cells = 0;
	for (int64_t i = 0; i < n; i++) {
		if ((double)r.lake_depth[(size_t)i] > lake_min_depth && std::isfinite(p_z[(int)i])) {
			wet[(size_t)i] = 1;
			lake_cells++;
		}
	}
	Array lakes;
	std::vector<int> comp;
	std::vector<int> frontier;
	std::vector<double> depths;
	std::vector<uint8_t> seen((size_t)n, 0);
	constexpr int C4_DX[4] = { 0, 1, 0, -1 };
	constexpr int C4_DZ[4] = { -1, 0, 1, 0 };
	for (int64_t s = 0; s < n; s++) {
		if (!wet[(size_t)s] || seen[(size_t)s]) {
			continue;
		}
		comp.clear();
		frontier.clear();
		frontier.push_back((int)s);
		seen[(size_t)s] = 1;
		while (!frontier.empty()) {
			const int c = frontier.back();
			frontier.pop_back();
			comp.push_back(c);
			const int cx = c % gw;
			const int cz = c / gw;
			for (int k = 0; k < 4; k++) {
				const int nx = cx + C4_DX[k];
				const int nz = cz + C4_DZ[k];
				if (nx < 0 || nz < 0 || nx >= gw || nz >= gh) {
					continue;
				}
				const int ni = nz * gw + nx;
				if (wet[(size_t)ni] && !seen[(size_t)ni]) {
					seen[(size_t)ni] = 1;
					frontier.push_back(ni);
				}
			}
		}
		const double area = (double)comp.size() * cell_area;
		if (area < lake_min_area) {
			continue;
		}
		// Depth from a high percentile, not the max (§10.2): one deep sinkhole inside a shallow lake
		// must not make the whole pond that deep.
		depths.clear();
		depths.reserve(comp.size());
		double level_sum = 0.0;
		for (size_t k = 0; k < comp.size(); k++) {
			const int i = comp[k];
			depths.push_back((double)r.lake_depth[(size_t)i]);
			level_sum += (double)p_z[i] + (double)r.lake_depth[(size_t)i];
		}
		std::sort(depths.begin(), depths.end());
		const double depth = depths[(size_t)std::min((size_t)(depth_pct * (double)depths.size()), depths.size() - 1)];
		const double level = level_sum / (double)comp.size();

		// The waterline, as the chain of cell edges with dry ground on the far side. Every such edge is
		// emitted with a consistent winding, so chaining them head-to-tail closes into rings; the longest
		// ring is the shore and any others are islands, which a Pond has no way to express.
		std::unordered_map<int64_t, int64_t> edge_from;
		const int cw = gw + 1;
		for (size_t k = 0; k < comp.size(); k++) {
			const int i = comp[k];
			const int cx = i % gw;
			const int cz = i / gw;
			const int64_t c00 = (int64_t)cz * cw + cx;
			const int64_t c10 = c00 + 1;
			const int64_t c01 = c00 + cw;
			const int64_t c11 = c01 + 1;
			const bool north = cz > 0 && wet[(size_t)(i - gw)];
			const bool south = cz < gh - 1 && wet[(size_t)(i + gw)];
			const bool west = cx > 0 && wet[(size_t)(i - 1)];
			const bool east = cx < gw - 1 && wet[(size_t)(i + 1)];
			if (!north) {
				edge_from[c00] = c10;
			}
			if (!east) {
				edge_from[c10] = c11;
			}
			if (!south) {
				edge_from[c11] = c01;
			}
			if (!west) {
				edge_from[c01] = c00;
			}
		}
		std::vector<Vector2> best;
		std::vector<Vector2> ring;
		std::unordered_map<int64_t, int64_t> pending = edge_from;
		while (!pending.empty()) {
			ring.clear();
			const int64_t start = pending.begin()->first;
			int64_t at = start;
			while (true) {
				auto it = pending.find(at);
				if (it == pending.end()) {
					break;
				}
				const int64_t next = it->second;
				pending.erase(it);
				const int64_t xc = at % cw;
				const int64_t zc = at / cw;
				// Corner (xc,zc) sits half a cell before sample (xc,zc), so the ring runs along the cell
				// boundary rather than through the centres of the wet cells.
				ring.push_back(Vector2((float)(min_x + ((double)xc - 0.5) * cell),
						(float)(min_z + ((double)zc - 0.5) * cell)));
				at = next;
				if (at == start) {
					break;
				}
			}
			if (ring.size() > best.size()) {
				best = ring;
			}
		}
		if (best.size() < 4) {
			continue; // no usable shoreline; a 3-corner ring is not a polygon anything can fill
		}
		dp_simplify(best, tol, keep);
		// A closed ring's first and last points are adjacent, so DP's forced endpoints can leave a
		// near-duplicate; drop it rather than hand a Curve3D two coincident points.
		PackedVector3Array contour;
		for (size_t k = 0; k < keep.size(); k++) {
			const Vector2 p = best[(size_t)keep[k]];
			if (contour.size() > 0) {
				const Vector3 prev = contour[contour.size() - 1];
				if (std::abs(prev.x - p.x) < 1.0e-4 && std::abs(prev.z - p.y) < 1.0e-4) {
					continue;
				}
			}
			contour.push_back(Vector3(p.x, (float)level, p.y));
		}
		if (contour.size() < 3) {
			continue;
		}
		Dictionary lake;
		lake["contour"] = contour;
		lake["level"] = level;
		lake["depth"] = depth;
		lake["area"] = area;
		lake["cells"] = (int)comp.size();
		lakes.push_back(lake);
	}

	out["rivers"] = rivers;
	out["lakes"] = lakes;
	out["channel_cells"] = channel_cells;
	out["lake_cells"] = lake_cells;
	out["ok"] = true;
	return out;
}
