// Pasture3DSim's native side (PASTURE3D_SIM_NODE_SPEC.md). Four entry points, in the order the node
// uses them:
//
//   resample_grid      the §6 preview/build bridge — below-layer heights DOWN onto the sim grid
//   erode_heightfield  the §4 solver, as a pure function of a heightfield (pasture_3d_erosion.cpp)
//   sim_mask_deltas    §5 "simulate wide, write narrow" — deltas back UP, through the loop's falloff
//   apply_sim_block    §8.1 — the batched raw-tile delta write, shared with the stamp_* rasterisers
//
// The solver itself is deliberately elsewhere and terrain-free: everything that touches a layer is
// here, everything that is landscape-evolution physics is in pasture_3d_erosion.cpp, and the gates
// drive the second half directly.

#include "pasture_3d_data.h"
#include "pasture_3d_erosion.h"
#include "pasture_3d_layer.h"
#include "pasture_3d_layer_stack.h"
#include "pasture_3d_raster_util.h"

#include <algorithm>
#include <cmath>
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
			const double delta = (a * (1.0 - ty) + b * ty) * mask;
			if (delta == 0.0) {
				continue; // an exact zero is not a write; leaving the cell uncovered keeps the layer sparse
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
