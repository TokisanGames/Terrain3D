// Native spline-brush rasterisers (Round 2 perf). A faithful C++ port of the per-cell rasterisation in
// Pasture3DTerrainBrush (GDScript), which dominated large-edit bake time (~730 ms interpreted). These run
// the same SDF/chamfer + per-cell profile math natively and write into the layer via the existing
// (deferred) layer-write API, so they slot under the unchanged Round 1 orchestration. The GDScript loops
// are kept as a fallback / A-B reference. See PASTURE3D_BRUSH_PERF_ROUND2_SPEC.md.

#include "pasture_3d_data.h"
#include "pasture_3d_gpu_raster.h"
#include "pasture_3d_relief_ops.h"
#include "pasture_3d_util.h"

#include <godot_cpp/classes/fast_noise_lite.hpp>

#include <algorithm>
#include <cmath>
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


} // namespace

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
	const double noise_strength = p_params.get("noise_strength", 0.0);
	Object *noise_obj = p_params.get("noise", Variant());
	Ref<FastNoiseLite> noise = Object::cast_to<FastNoiseLite>(noise_obj);

	const double sign = invert ? -1.0 : 1.0;
	// Denominator that normalises signed_d -> 0..1 ramp. dome_denom is the natural interior run (also the
	// noise mask for the cone); ramp_denom is falloff_width, or |height|/slope_tan in CAPPED slope mode.
	const bool use_angle = (flank_mode == 1);
	const bool cone = use_angle && !capped; // uncapped slope = free-rising cone (height from geometry)
	const double dome_denom = MAX(max_inside + edge_offset, 0.001);
	const double ramp_denom = (use_angle && capped) ? MAX(std::fabs(height) / slope_tan, 0.001) : MAX(falloff_width, 0.001);
	const bool add = (blend == 1); // BLEND_ADD

	Pasture3DLayer *wlayer = _layer_stack.is_null() ? nullptr : _layer_stack->get_layer_ptr(p_layer_id);
	Vector2i wloc(0x7fffffff, 0x7fffffff);
	Pasture3DRegion *wregion = nullptr;
	// Below-layer base: the composite of layers beneath this brush's, so it samples the ground under its
	// own layer (not the full terrain) and features stop climbing each other. NaN/empty => fall back.
	const PackedFloat32Array base_below = p_params.get("base_below", PackedFloat32Array());
	const bool has_below = base_below.size() == gw * gh;

	// Always buffer per-cell values into a box (NaN = no write) so the optional smoothing pass can run
	// before any write. Batched raw-tile apply path (Phase 1b) then commits the buffer one tile at a time
	// (no per-cell dict lookup / set_pixelv) for the common deferred non-base overlay; otherwise a per-cell
	// _stamp_write loop handles full-refresh composite, no layer, or a dense Base target.
	const bool batched = wlayer && !composite && !wlayer->is_base();
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
			double amp;
			double profile;
			if (cone) {
				// Free-rising cone: tan × distance, capped by the region safety height. profile (0..1
				// interior mask) only gates the noise so the rim stays clean.
				profile = CLAMP(signed_d / dome_denom, 0.0, 1.0);
				amp = sign * MIN(slope_tan * signed_d, slope_safety);
			} else {
				profile = (double)raster_ramp(p_lut, (float)(signed_d / (capped ? ramp_denom : dome_denom)));
				if (profile <= 0.0) {
					continue;
				}
				amp = sign * height * profile;
			}
			const double x = min_x + ix * vs;
			if (has_clip && (x < cx0 || x >= cx1)) {
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
			if (noise.is_valid()) {
				amp += noise_strength * noise->get_noise_2d(x, z) * profile;
			}
			vals[row + ix] = (float)(add ? amp : (base_y + amp));
		}
	}

	// Optional NaN-aware post-smoothing (default 0 = no-op, no allocation).
	nan_blur(vals, gw, gh, (int)p_params.get("smooth_passes", 0));

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
