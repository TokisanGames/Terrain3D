#include "pasture_3d_graph_gpu.h"

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/rd_shader_source.hpp>
#include <godot_cpp/classes/rd_shader_spirv.hpp>
#include <godot_cpp/classes/rd_uniform.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/memory.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

using namespace godot;

// One compute shader, dispatched once per GRID node with a `mode` selecting the op. Reads up to two input
// buffers (A, B) and writes one output buffer (OUT), all std430 float arrays over the gw*gh grid.
static const char *GRAPH_GRID_GLSL = R"(#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict writeonly buffer OutBuf { float o[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer ABuf { float a[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer BBuf { float b[]; };
// A THIRD input. Two was enough while every op was pointwise, but ExpandShrink needs input, result and
// mask at once to do its masked cross-fade, and splitting that across dispatches would need a scratch
// buffer per node anyway. Unused bindings get the shared zero buffer.
layout(set = 0, binding = 3, std430) restrict readonly buffer CBuf { float c[]; };

layout(push_constant, std430) uniform Params {
	int mode; // 0 COPY, 1 BLEND, 2 SMOOTH_H, 3 SMOOTH_V, 4 FALLOFF, 5 CONTRAST,
	          // 6 DT_SEED, 7 DT_JFA, 8 DT_RESOLVE, 9 DT_FINALIZE, 10 MORPH, 11 MORPH_BLEND,
	          // 12 BOXMEAN_H, 13 BOXMEAN_V, 14 REL_ELEV, 15 SMOOTH_FILL, 16 RECAST_CLIFF,
	          // 17 WARP_DOWNSLOPE
	int gw;
	int gh;
	int ip;   // BLEND: blend mode 0..4 | FALLOFF: shape 0..3 | CONTRAST: mode 0..1
	          // DT_JFA/DT_RESOLVE: metric 0..2 | MORPH: bit0 kernel, bit1 is_max
	// Op-specific scalars. FALLOFF uses f0..f6; CONTRAST uses f0..f3. The cell-centre world mapping
	// (ox, oz, dx, dz) is PASSED IN rather than recomputed here, so the shader cannot drift from
	// Pasture3DTerrainGraph.cell_to_world.
	float f0; float f1; float f2; float f3;
	float f4; float f5; float f6; float f7;
	float ox; float oz; float dx; float dz;
} p;

void main() {
	int ix = int(gl_GlobalInvocationID.x);
	int iz = int(gl_GlobalInvocationID.y);
	if (ix >= p.gw || iz >= p.gh) { return; }
	int i = iz * p.gw + ix;

	if (p.mode == 0) { // COPY (Output, or a zero-pass Smooth)
		o[i] = a[i];
		return;
	}
	if (p.mode == 1) { // BLEND
		float av = a[i];
		float bv = b[i];
		float r;
		if (p.ip == 0) { r = av + bv; }
		else if (p.ip == 1) { r = av - bv; }
		else if (p.ip == 2) { r = av * bv; }
		else if (p.ip == 3) { r = (av > bv) ? av : bv; }
		else if (p.ip == 4) { r = (av < bv) ? av : bv; }
		else { r = av; }
		o[i] = r;
		return;
	}
	if (p.mode == 2) { // SMOOTH horizontal
		float v = a[i];
		if (isnan(v)) { o[i] = v; return; }
		float s = 0.5 * v;
		float w = 0.5;
		if (ix > 0) { float l = a[i - 1]; if (!isnan(l)) { s += 0.25 * l; w += 0.25; } }
		if (ix < p.gw - 1) { float rr = a[i + 1]; if (!isnan(rr)) { s += 0.25 * rr; w += 0.25; } }
		o[i] = s / w;
		return;
	}
	if (p.mode == 3) { // SMOOTH vertical
		float v = a[i];
		if (isnan(v)) { o[i] = v; return; }
		float s = 0.5 * v;
		float w = 0.5;
		if (iz > 0) { float u = a[i - p.gw]; if (!isnan(u)) { s += 0.25 * u; w += 0.25; } }
		if (iz < p.gh - 1) { float d = a[i + p.gw]; if (!isnan(d)) { s += 0.25 * d; w += 0.25; } }
		o[i] = s / w;
		return;
	}
	if (p.mode == 4) { // FALLOFF: f0 centre_x, f1 centre_z, f2 radius, f3 feather,
	                   //          f4 strength, f5 invert, f6 distance_noise. b = the noise grid.
		float v = a[i];
		if (isnan(v)) { o[i] = v; return; }
		float wx = p.ox + (float(ix) + 0.5) * p.dx;
		float wz = p.oz + (float(iz) + 0.5) * p.dz;
		float ddx = wx - p.f0;
		float ddz = wz - p.f1;
		float d;
		if (p.ip == 1) { d = max(abs(ddx), abs(ddz)); }
		else if (p.ip == 2) { d = abs(ddx); }
		else if (p.ip == 3) { d = abs(ddz); }
		else { d = sqrt(ddx * ddx + ddz * ddz); }
		float nv = b[i];
		if (!isnan(nv)) { d += p.f6 * nv; }
		float t;
		if (p.f3 <= 0.0) { t = (d <= p.f2) ? 0.0 : 1.0; }
		else { float u = clamp((d - p.f2) / p.f3, 0.0, 1.0); t = u * u * (3.0 - 2.0 * u); }
		float at = 1.0 - t;
		if (p.f5 > 0.5) { at = 1.0 - at; }
		o[i] = v * (1.0 + (at - 1.0) * p.f4);
		return;
	}
	if (p.mode == 5) { // CONTRAST: f0 amount, f1 range_min, f2 range_max, f3 mask_amount. b = mask grid.
		float v = a[i];
		if (isnan(v)) { o[i] = v; return; }
		float span = p.f2 - p.f1;
		// A degenerate window, and heights outside the window, pass through. Clamping into the window
		// would flatten every peak above it into a plateau.
		if (span <= 0.0 || v <= p.f1 || v >= p.f2) { o[i] = v; return; }
		float t = (v - p.f1) / span;
		float c;
		if (p.ip == 1) { c = pow(t, p.f0); }
		else if (t < 0.5) { c = 0.5 * pow(2.0 * t, p.f0); }
		else { c = 1.0 - 0.5 * pow(2.0 - 2.0 * t, p.f0); }
		float shaped = p.f1 + c * span;
		float w = p.f3;
		// f7 flags whether a mask is actually wired. Without it an unwired port would bind the zero
		// buffer and multiply the shaping away entirely, which is the opposite of "no mask".
		if (p.f7 > 0.5) { float mv = b[i]; if (!isnan(mv)) { w *= mv; } }
		w = clamp(w, 0.0, 1.0);
		o[i] = v + (shaped - v) * w;
		return;
	}

	// ---- DistanceTransform (spec §5.1) ------------------------------------------------------------
	// The seed field carries the FLAT CELL INDEX of the nearest inside cell found so far, stored in a
	// float, with -1 for "nothing adopted yet". A float holds an integer exactly up to 2^24, and the
	// host refuses the GPU path above that many cells rather than silently losing sites.
	if (p.mode == 6) { // DT_SEED: f0 threshold, f1 want (1 = seed the inside, 0 = seed the outside)
		float m = a[i];
		// NaN is the brush loop mask: neither inside nor outside, so it never seeds either field.
		if (isnan(m)) { o[i] = -1.0; return; }
		bool inside = m > p.f0;
		bool want = p.f1 > 0.5;
		o[i] = (inside == want) ? float(i) : -1.0;
		return;
	}
	if (p.mode == 7 || p.mode == 8) {
		float dxm = p.dx;
		float dzm = p.dz;
		if (p.mode == 7) { // DT_JFA: one flooding sweep at step f0
			int k = int(p.f0);
			float bestSite = a[i];
			float bestD = 3.4e38;
			if (bestSite >= 0.0) {
				int bi = int(bestSite);
				float ax = abs(float(ix - (bi % p.gw))) * dxm;
				float az = abs(float(iz - (bi / p.gw))) * dzm;
				bestD = (p.ip == 1) ? (ax + az) : ((p.ip == 2) ? max(ax, az) : sqrt(ax * ax + az * az));
			}
			for (int oz = -1; oz <= 1; oz++) {
				for (int ox = -1; ox <= 1; ox++) {
					if (ox == 0 && oz == 0) { continue; }
					int nx = ix + ox * k;
					int nz = iz + oz * k;
					if (nx < 0 || nx >= p.gw || nz < 0 || nz >= p.gh) { continue; }
					float cand = a[nz * p.gw + nx];
					if (cand < 0.0) { continue; }
					int ci = int(cand);
					float ax = abs(float(ix - (ci % p.gw))) * dxm;
					float az = abs(float(iz - (ci / p.gw))) * dzm;
					float d = (p.ip == 1) ? (ax + az) : ((p.ip == 2) ? max(ax, az) : sqrt(ax * ax + az * az));
					if (d < bestD) { bestD = d; bestSite = cand; }
				}
			}
			o[i] = bestSite;
			return;
		}
		// DT_RESOLVE: turn adopted sites into metric distances.
		float site = a[i];
		if (site < 0.0) {
			// No seed anywhere in the field. The diagonal is a finite stand-in for infinity; 0 would
			// read as "every cell is on the boundary", which is the opposite of the truth.
			float fw = float(p.gw) * dxm;
			float fh = float(p.gh) * dzm;
			o[i] = sqrt(fw * fw + fh * fh);
			return;
		}
		int si = int(site);
		float ax = abs(float(ix - (si % p.gw))) * dxm;
		float az = abs(float(iz - (si / p.gw))) * dzm;
		o[i] = (p.ip == 1) ? (ax + az) : ((p.ip == 2) ? max(ax, az) : sqrt(ax * ax + az * az));
		return;
	}
	if (p.mode == 9) { // DT_FINALIZE: clamp to f0 (0 = unbounded), divide by f1. b = the ORIGINAL mask.
		float mv = b[i];
		if (isnan(mv)) { o[i] = mv; return; } // NaN in, NaN out
		float d = a[i];
		if (p.f0 > 0.0) { d = clamp(d, -p.f0, p.f0); }
		o[i] = d / p.f1;
		return;
	}

	// ---- ExpandShrink (spec §5.2) -----------------------------------------------------------------
	if (p.mode == 10) { // MORPH: f0 wx, f1 wz cells. ip bit0 = square kernel, bit1 = take the maximum.
		int wx = int(p.f0);
		int wz = int(p.f1);
		bool square = (p.ip & 1) != 0;
		bool isMax = (p.ip & 2) != 0;
		float best = 0.0;
		bool any = false;
		float rx = float(max(wx, 1));
		float rz = float(max(wz, 1));
		for (int oz = -wz; oz <= wz; oz++) {
			int nz = iz + oz;
			if (nz < 0 || nz >= p.gh) { continue; }
			for (int ox = -wx; ox <= wx; ox++) {
				int nx = ix + ox;
				if (nx < 0 || nx >= p.gw) { continue; }
				if (!square) {
					// The disc is defined ONCE, here and in the CPU kernel and in the oracle, as the
					// offsets inside the unit ellipse in cell space. Elliptical in cells is what keeps
					// it circular in metres when the cells are not square.
					float fx = float(ox) / rx;
					float fz = float(oz) / rz;
					if (fx * fx + fz * fz > 1.0) { continue; }
				}
				float v = a[nz * p.gw + nx];
				if (isnan(v)) { continue; } // skipped, never folded in as an identity
				if (!any) { best = v; any = true; }
				else if (isMax ? (v > best) : (v < best)) { best = v; }
			}
		}
		o[i] = any ? best : (0.0 / 0.0);
		return;
	}
	// ---- Phase 3 shared: the separable box mean (spec §6) -----------------------------------------
	// Two 1D passes of DIRECT gathers, matching the CPU kernel tap for tap. An incremental running sum
	// would be cheaper on the CPU and would accumulate in a different order here, and the two would then
	// disagree by more than float32 rounding at large radii.
	if (p.mode == 12 || p.mode == 13) {
		bool horiz = (p.mode == 12);
		int w = int(horiz ? p.f0 : p.f1);
		float sum = 0.0;
		int count = 0;
		for (int o = -w; o <= w; o++) {
			int nx = horiz ? (ix + o) : ix;
			int nz = horiz ? iz : (iz + o);
			if (nx < 0 || nx >= p.gw || nz < 0 || nz >= p.gh) { continue; }
			float v = a[nz * p.gw + nx];
			if (isnan(v)) { continue; } // skipped, not counted
			sum += v;
			count += 1;
		}
		// A fully masked window keeps the cell's own value rather than inventing a mean.
		o[i] = (count > 0) ? (sum / float(count)) : a[i];
		return;
	}
	if (p.mode == 14) { // REL_ELEV: a = z, b = local min, c = local max. f0 units (1 = metres).
		float z = a[i];
		if (isnan(z)) { o[i] = z; return; }
		float zlo = b[i];
		float zhi = c[i];
		if (p.f0 > 0.5) { o[i] = z - zlo; return; }
		float span = zhi - zlo;
		// A flat neighbourhood is neither basin nor crest: 0.5 is the honest midpoint. Returning 0
		// would paint every plain as basin floor.
		o[i] = (span > 1e-9) ? ((z - zlo) / span) : 0.5;
		return;
	}
	if (p.mode == 15) { // SMOOTH_FILL: a = z, b = blurred z, c = mask.
	                    // f0 k, f1 amount, f2 mask wired, ip = mode.
		float z = a[i];
		if (isnan(z)) { o[i] = z; return; }
		float zb = b[i];
		float k = max(p.f0, 0.0);
		float h = z;
		bool apply = true;
		if (p.ip == 1) { // FILL_HOLES — a pit is concave along BOTH axes; a valley is not.
			int xm = max(ix - 1, 0);
			int xp = min(ix + 1, p.gw - 1);
			int zm = max(iz - 1, 0);
			int zp = min(iz + 1, p.gh - 1);
			float zxm = a[iz * p.gw + xm];
			float zxp = a[iz * p.gw + xp];
			float zzm = a[zm * p.gw + ix];
			float zzp = a[zp * p.gw + ix];
			if (isnan(zxm) || isnan(zxp) || isnan(zzm) || isnan(zzp)) { apply = false; }
			else {
				float d2x = (zxp - 2.0 * z + zxm) / (p.dx * p.dx);
				float d2z = (zzp - 2.0 * z + zzm) / (p.dz * p.dz);
				apply = (d2x > 0.0 && d2z > 0.0);
			}
		}
		if (p.ip == 2) { // SMEAR_PEAKS — the mirror: smooth-min instead of smooth-max.
			if (k <= 1e-9) { h = min(z, zb); }
			else {
				float hh = clamp(0.5 + 0.5 * (zb - z) / k, 0.0, 1.0);
				h = (zb * (1.0 - hh) + z * hh) - k * hh * (1.0 - hh);
			}
		} else if (apply) {
			if (k <= 1e-9) { h = max(z, zb); }
			else {
				// smax(a,b,k) = -smin(-a,-b,k), written out so the arithmetic matches the CPU exactly.
				float na = -z;
				float nb = -zb;
				float hh = clamp(0.5 + 0.5 * (nb - na) / k, 0.0, 1.0);
				h = -((nb * (1.0 - hh) + na * hh) - k * hh * (1.0 - hh));
			}
		}
		float w = p.f1;
		if (p.f2 > 0.5) { float mv = c[i]; if (!isnan(mv)) { w *= clamp(mv, 0.0, 1.0); } }
		w = clamp(w, 0.0, 1.0);
		o[i] = z + (h - z) * w;
		return;
	}
	if (p.mode == 16) { // RECAST_CLIFF: a = z, b = blurred z, c = mask.
	                    // f0 tan(talus), f1 amplitude, f2 gain, f3 direction rad (<0 = omni),
	                    // f4 spread rad, f5 amount, f6 mask wired.
		float z = a[i];
		if (isnan(z)) { o[i] = z; return; }
		int xm = max(ix - 1, 0);
		int xp = min(ix + 1, p.gw - 1);
		int zm = max(iz - 1, 0);
		int zp = min(iz + 1, p.gh - 1);
		float zxm = a[iz * p.gw + xm];
		float zxp = a[iz * p.gw + xp];
		float zzm = a[zm * p.gw + ix];
		float zzp = a[zp * p.gw + ix];
		if (isnan(zxm) || isnan(zxp) || isnan(zzm) || isnan(zzp)) { o[i] = z; return; }

		// A METRIC gradient — rise over run in metres. The per-cell rise would move the cliff
		// threshold every time the bake resolution changed.
		float gx = (zxp - zxm) / (float(xp - xm) * p.dx);
		float gz = (zzp - zzm) / (float(zp - zm) * p.dz);
		float slope = sqrt(gx * gx + gz * gz);

		float loG = p.f0 * 0.75;
		float hiG = p.f0 * 1.25;
		float gate;
		if (hiG <= loG) { gate = (slope >= p.f0) ? 1.0 : 0.0; }
		else { float u = clamp((slope - loG) / (hiG - loG), 0.0, 1.0); gate = u * u * (3.0 - 2.0 * u); }

		if (p.f3 >= 0.0 && gate > 0.0) {
			if (slope <= 1e-12) { gate = 0.0; }
			else {
				float face = atan(-gz, -gx); // the bearing the ground FACES is downhill
				float diff = face - p.f3;
				const float TAU = 6.28318530717958647692;
				const float PIF = 3.14159265358979323846;
				diff = diff - TAU * floor((diff + PIF) / TAU);
				float ang = abs(diff);
				if (p.f4 <= 0.0 || ang >= p.f4) { gate = 0.0; }
				else { float u = 1.0 - (ang / p.f4); gate *= u * u * (3.0 - 2.0 * u); }
			}
		}

		float w = p.f5 * gate;
		if (p.f6 > 0.5) { float mv = c[i]; if (!isnan(mv)) { w *= clamp(mv, 0.0, 1.0); } }
		if (w <= 0.0) { o[i] = z; return; }
		float dev = z - b[i];
		float sg = 1.0 / (1.0 + exp(-p.f2 * dev / p.f1));
		o[i] = z + p.f1 * (sg - 0.5) * w;
		return;
	}
	if (p.mode == 17) { // WARP_DOWNSLOPE: a = z, b = z smoothed at radius, c = mask.
	                    // f0 displacement metres (already signed by `reverse`), f1 amount, f2 mask wired.
		float z = a[i];
		if (isnan(z)) { o[i] = z; return; } // NaN is the brush-loop mask: it stays put and stays NaN.
		int xm = max(ix - 1, 0);
		int xp = min(ix + 1, p.gw - 1);
		int zm = max(iz - 1, 0);
		int zp = min(iz + 1, p.gh - 1);
		float sxm = b[iz * p.gw + xm];
		float sxp = b[iz * p.gw + xp];
		float szm = b[zm * p.gw + ix];
		float szp = b[zp * p.gw + ix];
		if (isnan(sxm) || isnan(sxp) || isnan(szm) || isnan(szp)) { o[i] = z; return; }

		float gx = (sxp - sxm) / (float(xp - xm) * p.dx);
		float gz = (szp - szm) / (float(zp - zm) * p.dz);
		float mag = sqrt(gx * gx + gz * gz);
		// The SAME epsilon as GRADIENT_EPSILON in pasture_3d_warp_downslope.cpp. Below it the downhill
		// direction is numerical noise, and moving a cell along it is moving it at random.
		if (mag <= 1.0e-4) { o[i] = z; return; }

		float w = p.f1;
		if (p.f2 > 0.5) { float mv = c[i]; if (!isnan(mv)) { w *= clamp(mv, 0.0, 1.0); } else { w = 0.0; } }
		if (w <= 0.0) { o[i] = z; return; }

		// Displace in METRES, then convert to cells. Doing it in cells would make the warp strengthen
		// every time the bake resolution rose.
		float step = p.f0 * w;
		float fx = float(ix) + (gx / mag) * step / p.dx;
		float fz = float(iz) + (gz / mag) * step / p.dz;

		// Bilinear tap, CLAMP edges, NaN taps DROPPED rather than averaged — tap for tap the same rule as
		// transform_sample_bilinear, which is the CPU path's sampler.
		int x0 = int(floor(fx));
		int z0 = int(floor(fz));
		float tx = fx - float(x0);
		float tz = fz - float(z0);
		float acc = 0.0;
		float wsum = 0.0;
		for (int k = 0; k < 4; k++) {
			int sx = clamp(x0 + (k & 1), 0, p.gw - 1);
			int sz = clamp(z0 + (k >> 1), 0, p.gh - 1);
			float wx = ((k & 1) == 1) ? tx : (1.0 - tx);
			float wz = ((k >> 1) == 1) ? tz : (1.0 - tz);
			float ww = wx * wz;
			if (ww <= 0.0) { continue; }
			float v = a[sz * p.gw + sx];
			if (isnan(v)) { continue; }
			acc += ww * v;
			wsum += ww;
		}
		o[i] = (wsum <= 0.0) ? 0.0 : (acc / wsum);
		return;
	}
	if (p.mode == 11) { // MORPH_BLEND: a input, b morphed, c mask. f0 amount, f1 = is a mask wired.
		float vin = a[i];
		if (isnan(vin)) { o[i] = vin; return; }
		float vout = b[i];
		// Everything in the structuring element was masked out; leave the input rather than writing a
		// NaN it never had.
		if (isnan(vout)) { o[i] = vin; return; }
		float w = p.f0;
		if (p.f1 > 0.5) { float mv = c[i]; if (!isnan(mv)) { w *= clamp(mv, 0.0, 1.0); } }
		w = clamp(w, 0.0, 1.0);
		o[i] = vin + (vout - vin) * w;
		return;
	}
}
)";

static const char *GRAPH_HYDRAULIC_GLSL =
#include "shaders/graph_solver_hydraulic.glsl"
;

static const char *GRAPH_GEO_GLSL =
#include "shaders/graph_geo_primitives.glsl"
;

Pasture3DGraphGPU::~Pasture3DGraphGPU() {
	if (_rd) {
		if (_pipeline.is_valid()) {
			_rd->free_rid(_pipeline);
		}
		if (_shader.is_valid()) {
			_rd->free_rid(_shader);
		}
		if (_pipeline_hydraulic.is_valid()) {
			_rd->free_rid(_pipeline_hydraulic);
		}
		if (_shader_hydraulic.is_valid()) {
			_rd->free_rid(_shader_hydraulic);
		}
		if (_pipeline_geo.is_valid()) {
			_rd->free_rid(_pipeline_geo);
		}
		if (_shader_geo.is_valid()) {
			_rd->free_rid(_shader_geo);
		}
		memdelete(_rd);
		_rd = nullptr;
	}
}

bool Pasture3DGraphGPU::_ensure_init() {
	if (_rd && _pipeline.is_valid()) {
		return true;
	}
	if (_init_failed) {
		return false;
	}
	RenderingServer *rs = RenderingServer::get_singleton();
	if (!rs) {
		_init_failed = true;
		return false;
	}
	if (!_rd) {
		_rd = rs->create_local_rendering_device();
		if (!_rd) {
			UtilityFunctions::push_warning("Graph GPU: no local RenderingDevice; falling back to the CPU evaluator.");
			_init_failed = true;
			return false;
		}
	}
	Ref<RDShaderSource> src;
	src.instantiate();
	src->set_stage_source(RenderingDevice::SHADER_STAGE_COMPUTE, String(GRAPH_GRID_GLSL));
	Ref<RDShaderSPIRV> spirv = _rd->shader_compile_spirv_from_source(src);
	if (spirv.is_null() || !spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_COMPUTE).is_empty()) {
		UtilityFunctions::push_warning("Graph GPU: compute shader compile failed; falling back to the CPU evaluator.");
		memdelete(_rd);
		_rd = nullptr;
		_init_failed = true;
		return false;
	}
	_shader = _rd->shader_create_from_spirv(spirv);
	if (!_shader.is_valid()) {
		memdelete(_rd);
		_rd = nullptr;
		_init_failed = true;
		return false;
	}
	_pipeline = _rd->compute_pipeline_create(_shader);
	if (!_pipeline.is_valid()) {
		_rd->free_rid(_shader);
		memdelete(_rd);
		_rd = nullptr;
		_init_failed = true;
		return false;
	}
	return true;
}

bool Pasture3DGraphGPU::_ensure_init_hydraulic() {
	if (_rd && _pipeline_hydraulic.is_valid()) {
		return true;
	}
	if (_init_hydraulic_failed) {
		return false;
	}
	if (!_ensure_init()) {
		_init_hydraulic_failed = true;
		return false;
	}

	Ref<RDShaderSource> src;
	src.instantiate();
	src->set_stage_source(RenderingDevice::SHADER_STAGE_COMPUTE, String(GRAPH_HYDRAULIC_GLSL));
	Ref<RDShaderSPIRV> spirv = _rd->shader_compile_spirv_from_source(src);
	if (spirv.is_null() || !spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_COMPUTE).is_empty()) {
		UtilityFunctions::push_warning("Graph GPU: hydraulic compute shader compile failed; falling back to the CPU evaluator.");
		_init_hydraulic_failed = true;
		return false;
	}
	_shader_hydraulic = _rd->shader_create_from_spirv(spirv);
	if (!_shader_hydraulic.is_valid()) {
		_init_hydraulic_failed = true;
		return false;
	}
	_pipeline_hydraulic = _rd->compute_pipeline_create(_shader_hydraulic);
	if (!_pipeline_hydraulic.is_valid()) {
		_rd->free_rid(_shader_hydraulic);
		_init_hydraulic_failed = true;
		return false;
	}
	return true;
}

bool Pasture3DGraphGPU::_ensure_init_geo() {
	if (_rd && _pipeline_geo.is_valid()) {
		return true;
	}
	if (_init_geo_failed) {
		return false;
	}
	if (!_ensure_init()) {
		_init_geo_failed = true;
		return false;
	}

	Ref<RDShaderSource> src;
	src.instantiate();
	src->set_stage_source(RenderingDevice::SHADER_STAGE_COMPUTE, String(GRAPH_GEO_GLSL));
	Ref<RDShaderSPIRV> spirv = _rd->shader_compile_spirv_from_source(src);
	if (spirv.is_null() || !spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_COMPUTE).is_empty()) {
		UtilityFunctions::push_warning("Graph GPU: geo-primitives compute shader compile failed; falling back to the CPU solver.");
		_init_geo_failed = true;
		return false;
	}
	_shader_geo = _rd->shader_create_from_spirv(spirv);
	if (!_shader_geo.is_valid()) {
		_init_geo_failed = true;
		return false;
	}
	_pipeline_geo = _rd->compute_pipeline_create(_shader_geo);
	if (!_pipeline_geo.is_valid()) {
		_rd->free_rid(_shader_geo);
		_init_geo_failed = true;
		return false;
	}
	return true;
}

bool Pasture3DGraphGPU::available() {
	return _ensure_init();
}

namespace {
struct GraphDispatch {
	RID out;
	RID a;
	RID b;
	RID c;
	int mode = 0;
	int ip = 0;
	// Op-specific scalars, mirroring the shader's push-constant block. All zero for COPY/BLEND/SMOOTH.
	float f0 = 0, f1 = 0, f2 = 0, f3 = 0, f4 = 0, f5 = 0, f6 = 0, f7 = 0;
};
} // namespace

bool Pasture3DGraphGPU::eval_grid(const godot::GraphProgram &p_prog, int p_gw, int p_gh, const Rect2 &p_rect,
		const PackedFloat32Array &p_input, PackedFloat32Array &r_out) {
	if (!_ensure_init()) {
		return false;
	}
	if (p_prog.is_empty() || p_gw < 1 || p_gh < 1) {
		return false;
	}
	const int n = p_gw * p_gh;
	const int bytes = n * (int)sizeof(float);
	const bool have_input = p_input.size() == n;

	std::vector<RID> to_free;
	auto free_bufs = [&]() {
		for (RID rid : to_free) {
			if (rid.is_valid()) {
				_rd->free_rid(rid);
			}
		}
	};
	auto fail = [&]() -> bool {
		free_bufs();
		return false;
	};
	auto buf_from = [&](const void *p_data) -> RID {
		PackedByteArray pb;
		pb.resize(bytes);
		std::memcpy(pb.ptrw(), p_data, bytes);
		RID b = _rd->storage_buffer_create(bytes, pb);
		if (b.is_valid()) {
			to_free.push_back(b);
		}
		return b;
	};
	auto empty_buf = [&]() -> RID {
		PackedByteArray pb;
		pb.resize(bytes);
		RID b = _rd->storage_buffer_create(bytes, pb);
		if (b.is_valid()) {
			to_free.push_back(b);
		}
		return b;
	};

	const RID zero_buf = empty_buf();
	if (!zero_buf.is_valid()) {
		return fail();
	}

	const int32_t *ops = p_prog.ops.ptr();
	const float *params = p_prog.params.ptr();
	const int32_t *in0 = p_prog.in0.ptr();
	const int32_t *in1 = p_prog.in1.ptr();

	std::vector<RID> slot_buf(p_prog.count);
	std::vector<GraphDispatch> plan;

	// The separable box mean, as a two-dispatch sub-plan. Shared by SmoothFill and RecastCliff so the
	// blur they measure against is the same blur, produced the same way.
	auto blur_plan = [&](RID p_src, double p_radius_m) -> RID {
		const double bdx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
		const double bdz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
		const int bwx = (bdx > 0.0) ? (int)std::lround(p_radius_m / bdx) : 0;
		const int bwz = (bdz > 0.0) ? (int)std::lround(p_radius_m / bdz) : 0;
		if (bwx <= 0 && bwz <= 0) {
			return p_src;
		}
		const RID mid = empty_buf();
		GraphDispatch h{ mid, p_src, zero_buf, zero_buf, 12, 0 };
		h.f0 = (float)bwx;
		h.f1 = (float)bwz;
		plan.push_back(h);
		const RID out = empty_buf();
		GraphDispatch v{ out, mid, zero_buf, zero_buf, 13, 0 };
		v.f0 = (float)bwx;
		v.f1 = (float)bwz;
		plan.push_back(v);
		return out;
	};

	std::vector<float> host((size_t)n);
	for (int s = 0; s < p_prog.count; s++) {
		switch (ops[s]) {
			case GRAPH_OP_INPUT: {
				if (have_input) {
					slot_buf[s] = buf_from(p_input.ptr());
				} else {
					std::fill(host.begin(), host.end(), 0.f);
					slot_buf[s] = buf_from(host.data());
				}
			} break;
			case GRAPH_OP_NOISE: {
				const Ref<FastNoiseLite> &nz = p_prog.noise[s];
				if (nz.is_valid()) {
					const double amp = (double)params[s];
					for (int iz = 0; iz < p_gh; iz++) {
						const int row = iz * p_gw;
						for (int ix = 0; ix < p_gw; ix++) {
							double wx, wz;
							graph_cell_to_world(ix, iz, p_gw, p_gh, p_rect, wx, wz);
							host[row + ix] = (float)(amp * (double)nz->get_noise_2d(wx, wz));
						}
					}
				} else {
					std::fill(host.begin(), host.end(), 0.f);
				}
				slot_buf[s] = buf_from(host.data());
			} break;
			case GRAPH_OP_CONST: {
				std::fill(host.begin(), host.end(), params[s]);
				slot_buf[s] = buf_from(host.data());
			} break;
			case GRAPH_OP_BLEND: {
				const RID out = empty_buf();
				plan.push_back({ out, in0[s] >= 0 ? slot_buf[in0[s]] : zero_buf,
						in1[s] >= 0 ? slot_buf[in1[s]] : zero_buf, zero_buf, 1, (int)params[s] });
				slot_buf[s] = out;
			} break;
			case GRAPH_OP_SMOOTH: {
				const RID src = in0[s] >= 0 ? slot_buf[in0[s]] : zero_buf;
				const int passes = (int)params[s];
				if (passes <= 0) {
					const RID out = empty_buf();
					plan.push_back({ out, src, zero_buf, zero_buf, 0, 0 });
					slot_buf[s] = out;
				} else {
					const RID ta = empty_buf();
					const RID tb = empty_buf();
					RID cur = src;
					for (int pass = 0; pass < passes; pass++) {
						plan.push_back({ tb, cur, zero_buf, zero_buf, 2, 0 });
						plan.push_back({ ta, tb, zero_buf, zero_buf, 3, 0 });
						cur = ta;
					}
					slot_buf[s] = ta;
				}
			} break;
			case GRAPH_OP_FALLOFF: {
				// Spec §4.2. An unwired noise port binds the zero buffer, which reads as no
				// perturbation — the same defined 0 the CPU kernel uses for a missing grid.
				const RID out = empty_buf();
				GraphDispatch d{ out, in0[s] >= 0 ? slot_buf[in0[s]] : zero_buf,
					in1[s] >= 0 ? slot_buf[in1[s]] : zero_buf, zero_buf, 4, (int)p_prog.params[s] };
				d.f0 = p_prog.params_b[s]; // centre x
				d.f1 = p_prog.params_c[s]; // centre z
				d.f2 = p_prog.params_d[s]; // radius
				d.f3 = p_prog.params_e[s]; // feather
				d.f4 = std::clamp(p_prog.params_f[s], 0.0f, 1.0f); // strength
				d.f5 = p_prog.params_g[s]; // invert
				d.f6 = p_prog.params_h[s]; // distance_noise
				plan.push_back(d);
				slot_buf[s] = out;
			} break;
			case GRAPH_OP_CONTRAST: {
				// Spec §4.3. An unwired mask port binds the zero buffer; the shader reads a 0 there as
				// "no shaping", matching the CPU kernel's behaviour for a wired but empty mask.
				const RID out = empty_buf();
				GraphDispatch d{ out, in0[s] >= 0 ? slot_buf[in0[s]] : zero_buf,
					in1[s] >= 0 ? slot_buf[in1[s]] : zero_buf, zero_buf, 5, (int)p_prog.params[s] };
				d.f0 = std::max(p_prog.params_b[s], 0.001f); // amount
				d.f1 = p_prog.params_c[s]; // range_min
				d.f2 = p_prog.params_d[s]; // range_max
				d.f3 = std::clamp(p_prog.params_e[s], 0.0f, 1.0f); // mask_amount
				d.f7 = (in1[s] >= 0) ? 1.0f : 0.0f; // mask wired?
				plan.push_back(d);
				slot_buf[s] = out;
			} break;
			case GRAPH_OP_DISTANCE_TRANSFORM: {
				// Spec §5.1, run as a JFA plan: seed, log2(n) flooding sweeps plus a repair sweep,
				// resolve to metres, then clamp/normalise. Multi-dispatch is already how SMOOTH works,
				// so this needs no new machinery beyond the barriers the plan loop already inserts.
				const RID src = in0[s] >= 0 ? slot_buf[in0[s]] : zero_buf;
				const int units = (int)p_prog.params_d[s];
				const double max_d = (double)p_prog.params_e[s];

				// A site is a cell index carried in a float, which is exact only to 2^24. Refusing here
				// is the honest failure: past this size the GPU would quietly adopt the wrong seeds.
				if (n > (1 << 24)) {
					return fail();
				}
				// NORMALISED with no Max Distance divides by the field's own maximum, and a maximum is a
				// reduction this single-pass kernel cannot do. Rather than compute a DIFFERENT divisor
				// here and hand back a field that disagrees with the CPU, decline the whole graph — the
				// node already warns that this configuration is content-dependent.
				if (units == 1 && max_d <= 0.0) {
					return fail();
				}

				const int direction = (int)p_prog.params_b[s];
				const int metric = (int)p_prog.params_c[s];
				const float threshold = p_prog.params[s];

				int max_step = 1;
				while (max_step < std::max(p_gw, p_gh)) {
					max_step <<= 1;
				}

				// One distance field: seed with `want`, flood, resolve. Returns the resolved buffer.
				auto build_field = [&](float want) -> RID {
					const RID seed_a = empty_buf();
					GraphDispatch sd{ seed_a, src, zero_buf, zero_buf, 6, 0 };
					sd.f0 = threshold;
					sd.f1 = want;
					plan.push_back(sd);

					RID cur = seed_a;
					RID other = empty_buf();
					for (int k = max_step / 2; k >= 1; k >>= 1) {
						GraphDispatch jd{ other, cur, zero_buf, zero_buf, 7, metric };
						jd.f0 = (float)k;
						plan.push_back(jd);
						std::swap(cur, other);
					}
					// JFA+1: the repair sweep at step 1, matching the CPU kernel and the oracle exactly.
					GraphDispatch jd{ other, cur, zero_buf, zero_buf, 7, metric };
					jd.f0 = 1.0f;
					plan.push_back(jd);
					std::swap(cur, other);

					const RID resolved = empty_buf();
					plan.push_back({ resolved, cur, zero_buf, zero_buf, 8, metric });
					return resolved;
				};

				RID dist;
				if (direction == 2) { // SIGNED
					// d_out is already 0 inside the mask and d_in is already 0 outside it, so the signed
					// field is just their difference — no inside/outside test needed on either side.
					const RID d_out = build_field(1.0f);
					const RID d_in = build_field(0.0f);
					const RID diff = empty_buf();
					plan.push_back({ diff, d_out, d_in, zero_buf, 1, 1 }); // BLEND subtract
					dist = diff;
				} else {
					dist = build_field(direction == 1 ? 0.0f : 1.0f);
				}

				const RID out = empty_buf();
				GraphDispatch fd{ out, dist, src, zero_buf, 9, 0 };
				fd.f0 = (float)std::max(max_d, 0.0);
				fd.f1 = (units == 1 && max_d > 0.0) ? (float)max_d : 1.0f;
				plan.push_back(fd);
				slot_buf[s] = out;
			} break;
			case GRAPH_OP_EXPAND_SHRINK: {
				// Spec §5.2. A direct 2D gather per cell rather than the CPU's separable decomposition:
				// the decomposition exists to avoid O(r^2) work on a CPU, and a GPU has the lanes to just
				// do it. Both walk the SAME structuring element — the unit ellipse in cell space — so
				// they agree on shape, which is the part that has to match.
				const RID src = in0[s] >= 0 ? slot_buf[in0[s]] : zero_buf;
				const int mode = (int)p_prog.params[s];
				const double radius_m = (double)p_prog.params_b[s];
				const int kernel = (int)p_prog.params_c[s];
				const int iterations = std::clamp((int)p_prog.params_d[s], 0, 64);
				const float amount = std::clamp(p_prog.params_e[s], 0.0f, 1.0f);

				const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
				const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
				const int wx = (dx > 0.0) ? (int)std::lround(radius_m / dx) : 0;
				const int wz = (dz > 0.0) ? (int)std::lround(radius_m / dz) : 0;

				if (amount <= 0.0f || iterations <= 0 || (wx <= 0 && wz <= 0)) {
					const RID out = empty_buf();
					plan.push_back({ out, src, zero_buf, zero_buf, 0, 0 });
					slot_buf[s] = out;
					break;
				}

				const int ip_base = (kernel == 1) ? 1 : 0;
				auto morph = [&](RID in_buf, bool is_max) -> RID {
					const RID out = empty_buf();
					GraphDispatch d{ out, in_buf, zero_buf, zero_buf, 10, ip_base | (is_max ? 2 : 0) };
					d.f0 = (float)wx;
					d.f1 = (float)wz;
					plan.push_back(d);
					return out;
				};

				RID cur = src;
				for (int it = 0; it < iterations; it++) {
					switch (mode) {
						case 1: cur = morph(cur, false); break; // SHRINK
						case 2: cur = morph(morph(cur, false), true); break; // OPEN
						case 3: cur = morph(morph(cur, true), false); break; // CLOSE
						case 4: { // GRADIENT
							const RID hi = morph(cur, true);
							const RID lo = morph(cur, false);
							const RID diff = empty_buf();
							plan.push_back({ diff, hi, lo, zero_buf, 1, 1 }); // BLEND subtract
							cur = diff;
						} break;
						default: cur = morph(cur, true); break; // EXPAND
					}
				}

				const RID out = empty_buf();
				GraphDispatch bd{ out, src, cur, in1[s] >= 0 ? slot_buf[in1[s]] : zero_buf, 11, 0 };
				bd.f0 = amount;
				bd.f1 = (in1[s] >= 0) ? 1.0f : 0.0f; // is a mask actually wired?
				plan.push_back(bd);
				slot_buf[s] = out;
			} break;
			case GRAPH_OP_RELATIVE_ELEVATION: {
				// Spec §6.1. The local min and max reuse the SAME morphology mode the ExpandShrink gate
				// already pins down, so this node's disc is provably that disc.
				const RID src = in0[s] >= 0 ? slot_buf[in0[s]] : zero_buf;
				const double radius_m = (double)p_prog.params[s];
				const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
				const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
				const int wx = (dx > 0.0) ? (int)std::lround(radius_m / dx) : 0;
				const int wz = (dz > 0.0) ? (int)std::lround(radius_m / dz) : 0;

				const RID lo = empty_buf();
				GraphDispatch dlo{ lo, src, zero_buf, zero_buf, 10, 0 }; // disc, minimum
				dlo.f0 = (float)wx;
				dlo.f1 = (float)wz;
				plan.push_back(dlo);

				const RID hi = empty_buf();
				GraphDispatch dhi{ hi, src, zero_buf, zero_buf, 10, 2 }; // disc, maximum
				dhi.f0 = (float)wx;
				dhi.f1 = (float)wz;
				plan.push_back(dhi);

				const RID out = empty_buf();
				GraphDispatch d{ out, src, lo, hi, 14, 0 };
				d.f0 = (float)(int)p_prog.params_b[s]; // units
				plan.push_back(d);
				slot_buf[s] = out;
			} break;
			case GRAPH_OP_SMOOTH_FILL: {
				// Spec §6.2. The deposition channel is not produced here; a graph that wires it uses a
				// secondary port, which native_supported() already routes to the multi-channel path.
				const RID src = in0[s] >= 0 ? slot_buf[in0[s]] : zero_buf;
				const double radius_m = (double)p_prog.params_b[s];
				const float amount = std::clamp(p_prog.params_d[s], 0.0f, 1.0f);
				if (amount <= 0.0f || radius_m <= 0.0) {
					const RID out = empty_buf();
					plan.push_back({ out, src, zero_buf, zero_buf, 0, 0 });
					slot_buf[s] = out;
					break;
				}
				const RID blurred = blur_plan(src, radius_m);
				const RID out = empty_buf();
				GraphDispatch d{ out, src, blurred, in1[s] >= 0 ? slot_buf[in1[s]] : zero_buf, 15,
					(int)p_prog.params[s] };
				d.f0 = std::max(p_prog.params_c[s], 0.0f); // k
				d.f1 = amount;
				d.f2 = (in1[s] >= 0) ? 1.0f : 0.0f;
				plan.push_back(d);
				slot_buf[s] = out;
			} break;
			case GRAPH_OP_RECAST_CLIFF: {
				// Spec §6.3.
				const RID src = in0[s] >= 0 ? slot_buf[in0[s]] : zero_buf;
				const float amount = std::clamp(p_prog.params_g[s], 0.0f, 1.0f);
				const float amplitude = p_prog.params_c[s];
				if (amount <= 0.0f || amplitude == 0.0f) {
					const RID out = empty_buf();
					plan.push_back({ out, src, zero_buf, zero_buf, 0, 0 });
					slot_buf[s] = out;
					break;
				}
				const RID blurred = blur_plan(src, (double)p_prog.params_b[s]);
				const RID out = empty_buf();
				GraphDispatch d{ out, src, blurred, in1[s] >= 0 ? slot_buf[in1[s]] : zero_buf, 16, 0 };
				const double kPi = 3.14159265358979323846;
				d.f0 = (float)std::tan((double)p_prog.params[s] * kPi / 180.0); // tan(talus)
				d.f1 = amplitude;
				d.f2 = std::max(p_prog.params_d[s], 1e-6f); // gain
				d.f3 = (p_prog.params_e[s] >= 0.0f)
						? (float)((double)p_prog.params_e[s] * kPi / 180.0)
						: -1.0f; // direction, or omnidirectional
				d.f4 = (float)(std::max((double)p_prog.params_f[s], 0.0) * kPi / 180.0); // spread
				d.f5 = amount;
				d.f6 = (in1[s] >= 0) ? 1.0f : 0.0f;
				plan.push_back(d);
				slot_buf[s] = out;
			} break;
			case GRAPH_OP_WARP_DOWNSLOPE: {
				// Spec §7.1. params: 0 displacement_m, b radius_m, c reverse, d amount.
				const RID src = in0[s] >= 0 ? slot_buf[in0[s]] : zero_buf;
				const float amount = std::clamp(p_prog.params_d[s], 0.0f, 1.0f);
				const float disp = p_prog.params[s];
				if (amount <= 0.0f || disp == 0.0f) {
					const RID out = empty_buf();
					plan.push_back({ out, src, zero_buf, zero_buf, 0, 0 });
					slot_buf[s] = out;
					break;
				}
				// The gradient is read off the SMOOTHED copy, through the same blur_plan SmoothFill and
				// RecastCliff use, so "radius" means one thing across all three.
				const RID smoothed = blur_plan(src, (double)p_prog.params_b[s]);
				const RID out = empty_buf();
				GraphDispatch d{ out, src, smoothed, in1[s] >= 0 ? slot_buf[in1[s]] : zero_buf, 17, 0 };
				// Sample UPHILL so the surface moves downhill — a resample is a backward map. Matches the
				// `sign` in warp_downslope_solve; flipping one without the other is a silent CPU/GPU split.
				d.f0 = (p_prog.params_c[s] > 0.5f) ? -disp : disp;
				d.f1 = amount;
				d.f2 = (in1[s] >= 0) ? 1.0f : 0.0f;
				plan.push_back(d);
				slot_buf[s] = out;
			} break;
			case GRAPH_OP_OUTPUT: {
				const RID out = empty_buf();
				plan.push_back({ out, in0[s] >= 0 ? slot_buf[in0[s]] : zero_buf, zero_buf, zero_buf, 0, 0 });
				slot_buf[s] = out;
			} break;
			default:
				// GRAPH_OP_TRANSFORM lands here deliberately: an affine resample is a gather, not the
				// pointwise map this kernel expresses, and it needs its own shader (spec §3.7). Falling
				// back costs the WHOLE graph its GPU path, which is why every op above is handled here
				// rather than left to this branch.
				return fail();
		}
		if (!slot_buf[s].is_valid()) {
			return fail();
		}
	}
	if (!slot_buf[p_prog.output].is_valid()) {
		return fail();
	}

	std::vector<RID> sets;
	sets.reserve(plan.size());
	for (const GraphDispatch &d : plan) {
		Ref<RDUniform> uo;
		uo.instantiate();
		uo->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
		uo->set_binding(0);
		uo->add_id(d.out);
		Ref<RDUniform> ua;
		ua.instantiate();
		ua->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
		ua->set_binding(1);
		ua->add_id(d.a);
		Ref<RDUniform> ub;
		ub.instantiate();
		ub->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
		ub->set_binding(2);
		ub->add_id(d.b);
		Ref<RDUniform> uc;
		uc.instantiate();
		uc->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
		uc->set_binding(3);
		// Every dispatch binds all four buffers whether or not its mode reads them — an unbound binding
		// is a validation error, not an optional slot.
		uc->add_id(d.c.is_valid() ? d.c : d.b);
		TypedArray<RDUniform> us;
		us.push_back(uo);
		us.push_back(ua);
		us.push_back(ub);
		us.push_back(uc);
		const RID set = _rd->uniform_set_create(us, _shader, 0);
		if (!set.is_valid()) {
			for (RID s2 : sets) {
				_rd->free_rid(s2);
			}
			return fail();
		}
		sets.push_back(set);
	}

	const int gx = (p_gw + 7) / 8;
	const int gy = (p_gh + 7) / 8;
	const int64_t cl = _rd->compute_list_begin();
	_rd->compute_list_bind_compute_pipeline(cl, _pipeline);
	for (size_t k = 0; k < plan.size(); k++) {
		// 16 bytes of ints + 8 op scalars + the 4 world-mapping floats = 64 bytes. The mapping is
		// computed here, once, from the same expressions as Pasture3DTerrainGraph.cell_to_world (dx
		// divides by gw, NOT gw-1) rather than being re-derived inside the shader.
		PackedByteArray push;
		push.resize(64);
		push.encode_s32(0, plan[k].mode);
		push.encode_s32(4, p_gw);
		push.encode_s32(8, p_gh);
		push.encode_s32(12, plan[k].ip);
		push.encode_float(16, plan[k].f0);
		push.encode_float(20, plan[k].f1);
		push.encode_float(24, plan[k].f2);
		push.encode_float(28, plan[k].f3);
		push.encode_float(32, plan[k].f4);
		push.encode_float(36, plan[k].f5);
		push.encode_float(40, plan[k].f6);
		push.encode_float(44, plan[k].f7);
		push.encode_float(48, (float)p_rect.position.x);
		push.encode_float(52, (float)p_rect.position.y);
		push.encode_float(56, (float)((double)p_rect.size.x / (double)std::max(p_gw, 1)));
		push.encode_float(60, (float)((double)p_rect.size.y / (double)std::max(p_gh, 1)));
		_rd->compute_list_bind_uniform_set(cl, sets[k], 0);
		_rd->compute_list_set_push_constant(cl, push, push.size());
		_rd->compute_list_dispatch(cl, gx, gy, 1);
		if (k + 1 < plan.size()) {
			_rd->compute_list_add_barrier(cl);
		}
	}
	_rd->compute_list_end();
	_rd->submit();
	_rd->sync();

	PackedByteArray out_bytes = _rd->buffer_get_data(slot_buf[p_prog.output]);

	for (RID s2 : sets) {
		_rd->free_rid(s2);
	}
	free_bufs();

	if (out_bytes.size() != bytes) {
		UtilityFunctions::push_warning("Graph GPU: unexpected readback size; falling back to the CPU evaluator.");
		return false;
	}
	r_out.resize(n);
	std::memcpy(r_out.ptrw(), out_bytes.ptr(), bytes);
	return true;
}

bool Pasture3DGraphGPU::eval_hydraulic(const PackedFloat32Array &p_surface, int p_gw, int p_gh, const Rect2 &p_rect,
		const ErosionHydraulicParams &p_params, ErosionHydraulicResult &r_out) {
	if (!_ensure_init_hydraulic()) {
		return false;
	}
	if (p_gw < 1 || p_gh < 1) {
		return false;
	}
	const int n = p_gw * p_gh;
	if (p_surface.size() != n) {
		return false;
	}

	const int bytes = n * (int)sizeof(float);
	const int vec4_bytes = n * (int)sizeof(float) * 4;

	std::vector<RID> to_free;
	auto free_bufs = [&]() {
		for (RID rid : to_free) {
			if (rid.is_valid()) {
				_rd->free_rid(rid);
			}
		}
	};
	auto fail = [&]() -> bool {
		free_bufs();
		return false;
	};

	// 1. Storage buffers
	PackedByteArray pb_height;
	pb_height.resize(bytes);
	std::memcpy(pb_height.ptrw(), p_surface.ptr(), bytes);
	const RID height_buf = _rd->storage_buffer_create(bytes, pb_height);
	if (!height_buf.is_valid()) return fail();
	to_free.push_back(height_buf);

	PackedByteArray pb_zero;
	pb_zero.resize(bytes);
	const RID water_buf = _rd->storage_buffer_create(bytes, pb_zero);
	if (!water_buf.is_valid()) return fail();
	to_free.push_back(water_buf);

	const RID sediment_buf = _rd->storage_buffer_create(bytes, pb_zero);
	if (!sediment_buf.is_valid()) return fail();
	to_free.push_back(sediment_buf);

	const RID flow_buf = _rd->storage_buffer_create(bytes, pb_zero);
	if (!flow_buf.is_valid()) return fail();
	to_free.push_back(flow_buf);

	PackedByteArray pb_vec4_zero;
	pb_vec4_zero.resize(vec4_bytes);
	const RID flux_w_buf = _rd->storage_buffer_create(vec4_bytes, pb_vec4_zero);
	if (!flux_w_buf.is_valid()) return fail();
	to_free.push_back(flux_w_buf);

	const RID flux_s_buf = _rd->storage_buffer_create(vec4_bytes, pb_vec4_zero);
	if (!flux_s_buf.is_valid()) return fail();
	to_free.push_back(flux_s_buf);

	// Uniform set
	TypedArray<RDUniform> uniforms;
	const RID bufs[6] = { height_buf, water_buf, sediment_buf, flow_buf, flux_w_buf, flux_s_buf };
	for (int i = 0; i < 6; i++) {
		Ref<RDUniform> u;
		u.instantiate();
		u->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
		u->set_binding(i);
		u->add_id(bufs[i]);
		uniforms.push_back(u);
	}
	const RID uniform_set = _rd->uniform_set_create(uniforms, _shader_hydraulic, 0);
	if (!uniform_set.is_valid()) {
		return fail();
	}

	const float dx = p_rect.size.x / (float)std::max(p_gw, 1);
	const float dz = p_rect.size.y / (float)std::max(p_gh, 1);
	const float cell_dist = std::sqrt(std::max(dx * dz, 1e-6f));
	const int gx = (p_gw + 7) / 8;
	const int gy = (p_gh + 7) / 8;

	PackedByteArray push;
	push.resize(64);
	push.encode_s32(4, p_gw);
	push.encode_s32(8, p_gh);
	push.encode_s32(12, 0); // pad0
	push.encode_float(16, dx);
	push.encode_float(20, dz);
	push.encode_float(24, cell_dist);
	push.encode_float(28, p_params.rain_rate);
	push.encode_float(32, p_params.evaporation_rate);
	push.encode_float(36, p_params.sediment_capacity);
	push.encode_float(40, p_params.erosion_speed);
	push.encode_float(44, p_params.deposition_speed);
	push.encode_float(48, p_params.min_slope);
	push.encode_float(52, 1.0f); // max_flow (temp)
	push.encode_float(56, 1.0f); // max_sed (temp)
	push.encode_float(60, 0.0f); // pad1

	// Simulation passes
	int64_t cl = _rd->compute_list_begin();
	_rd->compute_list_bind_compute_pipeline(cl, _pipeline_hydraulic);
	_rd->compute_list_bind_uniform_set(cl, uniform_set, 0);

	for (int pass = 0; pass < p_params.iterations; pass++) {
		// Phase 0: Rain, Stream Power Incision & Outbound Flux
		push.encode_s32(0, 0);
		_rd->compute_list_set_push_constant(cl, push, push.size());
		_rd->compute_list_dispatch(cl, gx, gy, 1);
		_rd->compute_list_add_barrier(cl);

		// Phase 1: Gather Inbound Flux & Evaporate
		push.encode_s32(0, 1);
		_rd->compute_list_set_push_constant(cl, push, push.size());
		_rd->compute_list_dispatch(cl, gx, gy, 1);
		_rd->compute_list_add_barrier(cl);
	}
	_rd->compute_list_end();
	_rd->submit();
	_rd->sync();

	// Calculate max_flow and max_sed for normalization
	PackedByteArray flow_bytes = _rd->buffer_get_data(flow_buf);
	PackedByteArray sed_bytes = _rd->buffer_get_data(sediment_buf);
	PackedByteArray height_bytes = _rd->buffer_get_data(height_buf);

	const float *h_ptr = (const float *)height_bytes.ptr();
	const float *f_ptr = (const float *)flow_bytes.ptr();
	const float *s_ptr = (const float *)sed_bytes.ptr();
	float max_flow = 1e-6f;
	float max_sed = 1e-6f;
	for (int i = 0; i < n; i++) {
		if (std::isfinite(h_ptr[i])) {
			max_flow = std::max(max_flow, f_ptr[i]);
			max_sed = std::max(max_sed, s_ptr[i]);
		}
	}

	// Phase 2: Final Normalization
	push.encode_s32(0, 2);
	push.encode_float(52, max_flow);
	push.encode_float(56, max_sed);

	cl = _rd->compute_list_begin();
	_rd->compute_list_bind_compute_pipeline(cl, _pipeline_hydraulic);
	_rd->compute_list_bind_uniform_set(cl, uniform_set, 0);
	_rd->compute_list_set_push_constant(cl, push, push.size());
	_rd->compute_list_dispatch(cl, gx, gy, 1);
	_rd->compute_list_end();
	_rd->submit();
	_rd->sync();

	// Readback output channels
	height_bytes = _rd->buffer_get_data(height_buf);
	sed_bytes = _rd->buffer_get_data(sediment_buf);
	flow_bytes = _rd->buffer_get_data(flow_buf);

	_rd->free_rid(uniform_set);
	free_bufs();

	if (height_bytes.size() != bytes || sed_bytes.size() != bytes || flow_bytes.size() != bytes) {
		return false;
	}

	r_out.height.resize(n);
	r_out.sediment.resize(n);
	r_out.flow.resize(n);
	std::memcpy(r_out.height.ptrw(), height_bytes.ptr(), bytes);
	std::memcpy(r_out.sediment.ptrw(), sed_bytes.ptr(), bytes);
	std::memcpy(r_out.flow.ptrw(), flow_bytes.ptr(), bytes);
	r_out.ok = true;
	return true;
}

bool Pasture3DGraphGPU::eval_geo(const GeoGpuParams &p_gp, int p_gw, int p_gh,
		const PackedFloat32Array &p_in_a, const PackedFloat32Array &p_in_b, const PackedFloat32Array &p_in_c,
		PackedFloat32Array &r_out, PackedFloat32Array &r_out2) {
	if (!_ensure_init_geo()) {
		return false;
	}
	if (p_gw < 1 || p_gh < 1) {
		return false;
	}
	const int n = p_gw * p_gh;
	const int bytes = n * (int)sizeof(float);

	std::vector<RID> to_free;
	auto free_bufs = [&]() {
		for (RID rid : to_free) {
			if (rid.is_valid()) {
				_rd->free_rid(rid);
			}
		}
	};
	auto fail = [&]() -> bool {
		free_bufs();
		return false;
	};
	auto empty_buf = [&]() -> RID {
		PackedByteArray pb;
		pb.resize(bytes);
		RID b = _rd->storage_buffer_create(bytes, pb);
		if (b.is_valid()) {
			to_free.push_back(b);
		}
		return b;
	};
	// A wired input feeds its own buffer; an unwired one still needs SOME buffer bound (the shader gates the
	// read on p.flags), so it gets a zero buffer. The router sets p_gp.flags to match which are wired.
	auto input_buf = [&](const PackedFloat32Array &p_in) -> RID {
		PackedByteArray pb;
		pb.resize(bytes);
		if (p_in.size() == n) {
			std::memcpy(pb.ptrw(), p_in.ptr(), bytes);
		}
		RID b = _rd->storage_buffer_create(bytes, pb);
		if (b.is_valid()) {
			to_free.push_back(b);
		}
		return b;
	};

	const RID out_buf = empty_buf();
	const RID out2_buf = empty_buf();
	const RID a_buf = input_buf(p_in_a);
	const RID b_buf = input_buf(p_in_b);
	const RID c_buf = input_buf(p_in_c);
	if (!out_buf.is_valid() || !out2_buf.is_valid() || !a_buf.is_valid() || !b_buf.is_valid() || !c_buf.is_valid()) {
		return fail();
	}

	// Param SSBO: memcpy the host mirror 1:1 (std430, all 4-byte scalars). op/gw/gh are authoritative here.
	GeoGpuParams gp = p_gp;
	gp.gw = p_gw;
	gp.gh = p_gh;
	PackedByteArray pb_params;
	pb_params.resize((int)sizeof(GeoGpuParams));
	std::memcpy(pb_params.ptrw(), &gp, sizeof(GeoGpuParams));
	const RID param_buf = _rd->storage_buffer_create((int)sizeof(GeoGpuParams), pb_params);
	if (!param_buf.is_valid()) {
		return fail();
	}
	to_free.push_back(param_buf);

	TypedArray<RDUniform> uniforms;
	const RID bufs[6] = { out_buf, out2_buf, a_buf, b_buf, c_buf, param_buf };
	for (int i = 0; i < 6; i++) {
		Ref<RDUniform> u;
		u.instantiate();
		u->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
		u->set_binding(i);
		u->add_id(bufs[i]);
		uniforms.push_back(u);
	}
	const RID uniform_set = _rd->uniform_set_create(uniforms, _shader_geo, 0);
	if (!uniform_set.is_valid()) {
		return fail();
	}

	const int gx = (p_gw + 7) / 8;
	const int gy = (p_gh + 7) / 8;

	int64_t cl = _rd->compute_list_begin();
	_rd->compute_list_bind_compute_pipeline(cl, _pipeline_geo);
	_rd->compute_list_bind_uniform_set(cl, uniform_set, 0);
	_rd->compute_list_dispatch(cl, gx, gy, 1);
	_rd->compute_list_end();
	_rd->submit();
	_rd->sync();

	PackedByteArray out_bytes = _rd->buffer_get_data(out_buf);
	PackedByteArray out2_bytes = _rd->buffer_get_data(out2_buf);

	_rd->free_rid(uniform_set);
	free_bufs();

	if (out_bytes.size() != bytes || out2_bytes.size() != bytes) {
		return false;
	}

	r_out.resize(n);
	r_out2.resize(n);
	std::memcpy(r_out.ptrw(), out_bytes.ptr(), bytes);
	std::memcpy(r_out2.ptrw(), out2_bytes.ptr(), bytes);
	return true;
}

namespace godot {

int graph_gpu_threshold() {
	const int dflt = 65536; // 256x256
	ProjectSettings *ps = ProjectSettings::get_singleton();
	if (!ps) {
		return dflt;
	}
	return (int)ps->get_setting("pasture_3d/performance/graph_gpu_threshold", dflt);
}

PackedFloat32Array graph_eval_grid_best(const GraphProgram &p_prog, int p_gw, int p_gh, const Rect2 &p_rect,
		const PackedFloat32Array &p_input) {
	const int threshold = graph_gpu_threshold();
	if (threshold > 0 && (int64_t)p_gw * p_gh >= (int64_t)threshold) {
		static Pasture3DGraphGPU s_gpu;
		PackedFloat32Array out;
		if (s_gpu.eval_grid(p_prog, p_gw, p_gh, p_rect, p_input, out)) {
			return out;
		}
	}
	return graph_eval_grid(p_prog, p_gw, p_gh, p_rect, p_input);
}

ErosionHydraulicResult erosion_hydraulic_solve_best(const PackedFloat32Array &p_surface,
		int p_gw, int p_gh, const Rect2 &p_rect, const ErosionHydraulicParams &p_params) {
	const int threshold = graph_gpu_threshold();
	if (threshold > 0 && (int64_t)p_gw * p_gh >= (int64_t)threshold) {
		static Pasture3DGraphGPU s_gpu;
		ErosionHydraulicResult res;
		if (s_gpu.eval_hydraulic(p_surface, p_gw, p_gh, p_rect, p_params, res)) {
			return res;
		}
	}
	return erosion_hydraulic_solve(p_surface, p_gw, p_gh, p_rect, p_params);
}

bool mountain_cone_eval_gpu(int p_gw, int p_gh, const Rect2 &p_rect, const MountainConeParams &p_params,
		PackedFloat32Array &r_out) {
	if (p_gw < 1 || p_gh < 1) {
		return false;
	}
	static Pasture3DGraphGPU s_gpu; // persistent: the local RD + shader compile once across calls

	// Fill the GPU param block exactly as mountain_cone_solve derives its host-side constants, so the two
	// paths agree to GPU-float tolerance. octaves is Nyquist-capped identically (shared header helper).
	const float scale = p_params.scale;
	const float kw = p_params.peak_kw / scale;
	const float lacunarity = 2.0f;
	const float alpha = p_params.angle * 0.0174532925f;
	const int n = p_gw * p_gh;

	GeoGpuParams gp;
	gp.op = 0; // MountainCone
	gp.octaves = nyquist_octave_cap(p_params.octaves, kw, lacunarity, std::min(p_gw, p_gh));
	gp.seed_u = wang_hash((uint32_t)p_params.seed);
	gp.flags = (p_params.dx.size() == n ? 1 : 0) |
			(p_params.dy.size() == n ? 2 : 0) |
			(p_params.envelope.size() == n ? 4 : 0);
	gp.elevation = p_params.elevation;
	gp.scale = scale;
	gp.kw = kw;
	gp.cos_alpha = std::cos(alpha);
	gp.sin_alpha = std::sin(alpha);
	gp.gamma = p_params.gamma;
	gp.persistence = 0.5f;
	gp.lacunarity = lacunarity;
	gp.base_noise_amp = p_params.base_noise_amp;
	gp.cone_alpha = p_params.cone_alpha;
	gp.ridge_amp = p_params.ridge_amp;
	gp.center_x = p_params.center.x;
	gp.center_y = p_params.center.y;

	PackedFloat32Array out2;
	return s_gpu.eval_geo(gp, p_gw, p_gh, p_params.dx, p_params.dy, p_params.envelope, r_out, out2);
}

PackedFloat32Array mountain_cone_solve_best(int p_gw, int p_gh, const Rect2 &p_rect,
		const MountainConeParams &p_params) {
	const int threshold = graph_gpu_threshold();
	if (threshold > 0 && (int64_t)p_gw * p_gh >= (int64_t)threshold) {
		PackedFloat32Array out;
		if (mountain_cone_eval_gpu(p_gw, p_gh, p_rect, p_params, out)) {
			return out;
		}
	}
	return mountain_cone_solve(p_gw, p_gh, p_rect, p_params);
}

bool mountain_inselberg_eval_gpu(int p_gw, int p_gh, const Rect2 &p_rect, const MountainInselbergParams &p_params,
		PackedFloat32Array &r_out) {
	if (p_gw < 1 || p_gh < 1) return false;
	static Pasture3DGraphGPU s_gpu;

	const float scale = p_params.scale;
	const float kw = 2.6f / scale;
	const float lacunarity = 2.0f;
	const float alpha = p_params.angle * 0.0174532925f;
	const int n = p_gw * p_gh;

	GeoGpuParams gp;
	gp.op = 1; // MountainInselberg
	gp.octaves = nyquist_octave_cap(p_params.octaves, kw, lacunarity, std::min(p_gw, p_gh));
	gp.seed_u = wang_hash((uint32_t)p_params.seed);
	gp.flags = (p_params.dx.size() == n ? 1 : 0) |
			(p_params.dy.size() == n ? 2 : 0);
	gp.elevation = p_params.elevation;
	gp.scale = scale;
	gp.kw = kw;
	gp.cos_alpha = std::cos(alpha);
	gp.sin_alpha = std::sin(alpha);
	gp.gamma = p_params.gamma;
	gp.persistence = 0.5f;
	gp.lacunarity = lacunarity;
	gp.base_noise_amp = p_params.base_noise_amp;
	gp.bulk_amp = p_params.bulk_amp;
	gp.center_x = p_params.center.x;
	gp.center_y = p_params.center.y;

	PackedFloat32Array out2;
	return s_gpu.eval_geo(gp, p_gw, p_gh, p_params.dx, p_params.dy, PackedFloat32Array(), r_out, out2);
}

PackedFloat32Array mountain_inselberg_solve_best(int p_gw, int p_gh, const Rect2 &p_rect,
		const MountainInselbergParams &p_params) {
	const int threshold = graph_gpu_threshold();
	if (threshold > 0 && (int64_t)p_gw * p_gh >= (int64_t)threshold) {
		PackedFloat32Array out;
		if (mountain_inselberg_eval_gpu(p_gw, p_gh, p_rect, p_params, out)) {
			return out;
		}
	}
	return mountain_inselberg_solve(p_gw, p_gh, p_rect, p_params);
}

bool mountain_range_radial_eval_gpu(int p_gw, int p_gh, const Rect2 &p_rect, const MountainRangeRadialParams &p_params,
		Array &r_out) {
	if (p_gw < 1 || p_gh < 1) return false;
	static Pasture3DGraphGPU s_gpu;

	const float lacunarity = p_params.lacunarity;
	const int n = p_gw * p_gh;

	GeoGpuParams gp;
	gp.op = 2; // MountainRangeRadial
	gp.octaves = nyquist_octave_cap(p_params.octaves, std::max(p_params.kw_x, p_params.kw_y), lacunarity, std::min(p_gw, p_gh));
	gp.seed_u = wang_hash((uint32_t)p_params.seed);
	gp.flags = (p_params.ctrl_param.size() == n ? 1 : 0) |
			(p_params.dx.size() == n ? 2 : 0) |
			(p_params.dy.size() == n ? 4 : 0);
	gp.elevation = p_params.elevation;
	gp.kw = p_params.kw_x;
	gp.kw2 = p_params.kw_y;
	gp.half_width = p_params.half_width;
	gp.angle_spread_ratio = p_params.angle_spread_ratio;
	gp.core_size_ratio = p_params.core_size_ratio;
	gp.weight = p_params.weight;
	gp.persistence = p_params.persistence;
	gp.lacunarity = lacunarity;
	gp.center_x = p_params.center.x;
	gp.center_y = p_params.center.y;

	PackedFloat32Array h_out, a_out;
	if (s_gpu.eval_geo(gp, p_gw, p_gh, p_params.ctrl_param, p_params.dx, p_params.dy, h_out, a_out)) {
		r_out.clear();
		r_out.append(h_out);
		r_out.append(a_out);
		return true;
	}
	return false;
}

Array mountain_range_radial_solve_best(int p_gw, int p_gh, const Rect2 &p_rect,
		const MountainRangeRadialParams &p_params) {
	const int threshold = graph_gpu_threshold();
	if (threshold > 0 && (int64_t)p_gw * p_gh >= (int64_t)threshold) {
		Array out;
		if (mountain_range_radial_eval_gpu(p_gw, p_gh, p_rect, p_params, out)) {
			return out;
		}
	}
	return mountain_range_radial_solve(p_gw, p_gh, p_rect, p_params);
}

bool mountain_tibesti_eval_gpu(int p_gw, int p_gh, const Rect2 &p_rect, const MountainTibestiParams &p_params,
		PackedFloat32Array &r_out) {
	if (p_gw < 1 || p_gh < 1) return false;
	static Pasture3DGraphGPU s_gpu;

	const float scale = p_params.scale;
	const float kw_base = p_params.peak_kw / scale;
	const float kw_noise4 = 4.0f / scale;
	const float kw_noise2 = 2.0f / scale;
	const float lacunarity = 2.0f;
	const float alpha = p_params.angle * 0.0174532925f;
	const int n = p_gw * p_gh;
	const int shape_min = std::min(p_gw, p_gh);

	GeoGpuParams gp;
	gp.op = 3; // MountainTibesti
	gp.octaves = nyquist_octave_cap(p_params.octaves, kw_base, lacunarity, shape_min);
	gp.octaves2 = nyquist_octave_cap(p_params.octaves, kw_noise4, lacunarity, shape_min);
	gp.octaves3 = nyquist_octave_cap(p_params.octaves, kw_noise2, lacunarity, shape_min);
	gp.seed_u = wang_hash((uint32_t)p_params.seed);
	gp.flags = (p_params.dx.size() == n ? 1 : 0) |
			(p_params.dy.size() == n ? 2 : 0);
	gp.elevation = p_params.elevation;
	gp.scale = scale;
	gp.kw = kw_base;
	gp.cos_alpha = std::cos(alpha);
	gp.sin_alpha = std::sin(alpha);
	gp.angle_spread_ratio = p_params.angle_spread_ratio;
	gp.gamma = p_params.gamma;
	gp.persistence = 0.5f;
	gp.lacunarity = lacunarity;
	gp.base_noise_amp = p_params.base_noise_amp;
	gp.bulk_amp = p_params.bulk_amp;
	gp.center_x = p_params.center.x;
	gp.center_y = p_params.center.y;

	PackedFloat32Array out2;
	return s_gpu.eval_geo(gp, p_gw, p_gh, p_params.dx, p_params.dy, PackedFloat32Array(), r_out, out2);
}

PackedFloat32Array mountain_tibesti_solve_best(int p_gw, int p_gh, const Rect2 &p_rect,
		const MountainTibestiParams &p_params) {
	const int threshold = graph_gpu_threshold();
	if (threshold > 0 && (int64_t)p_gw * p_gh >= (int64_t)threshold) {
		PackedFloat32Array out;
		if (mountain_tibesti_eval_gpu(p_gw, p_gh, p_rect, p_params, out)) {
			return out;
		}
	}
	return mountain_tibesti_solve(p_gw, p_gh, p_rect, p_params);
}

bool mountain_stump_eval_gpu(int p_gw, int p_gh, const Rect2 &p_rect, const MountainStumpParams &p_params,
		PackedFloat32Array &r_out) {
	if (p_gw < 1 || p_gh < 1) return false;
	static Pasture3DGraphGPU s_gpu;

	const float scale = p_params.scale;
	const float kw = p_params.peak_kw / scale;
	const float lacunarity = 2.0f;
	const float alpha = p_params.angle * 0.0174532925f;
	const int n = p_gw * p_gh;

	GeoGpuParams gp;
	gp.op = 4; // MountainStump
	gp.octaves = nyquist_octave_cap(p_params.octaves, kw, lacunarity, std::min(p_gw, p_gh));
	gp.seed_u = wang_hash((uint32_t)p_params.seed);
	gp.flags = (p_params.dx.size() == n ? 1 : 0) |
			(p_params.dy.size() == n ? 2 : 0);
	gp.elevation = p_params.elevation;
	gp.scale = scale;
	gp.kw = kw;
	gp.cos_alpha = std::cos(alpha);
	gp.sin_alpha = std::sin(alpha);
	gp.gamma = p_params.gamma;
	gp.persistence = 0.5f;
	gp.lacunarity = lacunarity;
	gp.base_noise_amp = p_params.base_noise_amp;
	gp.ridge_amp = p_params.ridge_amp;
	gp.k_smoothing = p_params.k_smoothing;
	gp.center_x = p_params.center.x;
	gp.center_y = p_params.center.y;

	PackedFloat32Array out2;
	return s_gpu.eval_geo(gp, p_gw, p_gh, p_params.dx, p_params.dy, PackedFloat32Array(), r_out, out2);
}

PackedFloat32Array mountain_stump_solve_best(int p_gw, int p_gh, const Rect2 &p_rect,
		const MountainStumpParams &p_params) {
	const int threshold = graph_gpu_threshold();
	if (threshold > 0 && (int64_t)p_gw * p_gh >= (int64_t)threshold) {
		PackedFloat32Array out;
		if (mountain_stump_eval_gpu(p_gw, p_gh, p_rect, p_params, out)) {
			return out;
		}
	}
	return mountain_stump_solve(p_gw, p_gh, p_rect, p_params);
}

bool shattered_peak_eval_gpu(int p_gw, int p_gh, const Rect2 &p_rect, const ShatteredPeakParams &p_params,
		PackedFloat32Array &r_out) {
	if (p_gw < 1 || p_gh < 1) return false;
	static Pasture3DGraphGPU s_gpu;

	const float scale = p_params.scale;
	const float kw = p_params.peak_kw / scale;
	const float lacunarity = 2.0f;
	const float alpha = p_params.angle * 0.0174532925f;
	const int n = p_gw * p_gh;

	GeoGpuParams gp;
	gp.op = 5; // ShatteredPeak
	gp.octaves = nyquist_octave_cap(p_params.octaves, kw, lacunarity, std::min(p_gw, p_gh));
	gp.seed_u = wang_hash((uint32_t)p_params.seed);
	gp.flags = (p_params.dx.size() == n ? 1 : 0) |
			(p_params.dy.size() == n ? 2 : 0);
	gp.elevation = p_params.elevation;
	gp.scale = scale;
	gp.kw = kw;
	gp.cos_alpha = std::cos(alpha);
	gp.sin_alpha = std::sin(alpha);
	gp.gamma = p_params.gamma;
	gp.persistence = 0.5f;
	gp.lacunarity = lacunarity;
	gp.base_noise_amp = p_params.base_noise_amp;
	gp.bulk_amp = p_params.bulk_amp;
	gp.center_x = p_params.center.x;
	gp.center_y = p_params.center.y;

	PackedFloat32Array out2;
	return s_gpu.eval_geo(gp, p_gw, p_gh, p_params.dx, p_params.dy, PackedFloat32Array(), r_out, out2);
}

PackedFloat32Array shattered_peak_solve_best(int p_gw, int p_gh, const Rect2 &p_rect,
		const ShatteredPeakParams &p_params) {
	const int threshold = graph_gpu_threshold();
	if (threshold > 0 && (int64_t)p_gw * p_gh >= (int64_t)threshold) {
		PackedFloat32Array out;
		if (shattered_peak_eval_gpu(p_gw, p_gh, p_rect, p_params, out)) {
			return out;
		}
	}
	return shattered_peak_solve(p_gw, p_gh, p_rect, p_params);
}

bool caldera_eval_gpu(int p_gw, int p_gh, const Rect2 &p_rect, const CalderaParams &p_params,
		PackedFloat32Array &r_out) {
	if (p_gw < 1 || p_gh < 1) return false;
	static Pasture3DGraphGPU s_gpu;

	const int n = p_gw * p_gh;

	GeoGpuParams gp;
	gp.op = 6; // Caldera
	gp.flags = (p_params.noise.size() == n ? 1 : 0);
	gp.elevation = p_params.elevation;
	gp.radius = p_params.radius;
	gp.sigma_inner = p_params.sigma_inner;
	gp.sigma_outer = p_params.sigma_outer;
	gp.z_bottom = p_params.z_bottom;
	gp.noise_r_amp = p_params.noise_r_amp;
	gp.noise_z_ratio = p_params.noise_z_ratio;
	gp.center_x = p_params.center.x;
	gp.center_y = p_params.center.y;

	PackedFloat32Array out2;
	return s_gpu.eval_geo(gp, p_gw, p_gh, p_params.noise, PackedFloat32Array(), PackedFloat32Array(), r_out, out2);
}

PackedFloat32Array caldera_solve_best(int p_gw, int p_gh, const Rect2 &p_rect,
		const CalderaParams &p_params) {
	const int threshold = graph_gpu_threshold();
	if (threshold > 0 && (int64_t)p_gw * p_gh >= (int64_t)threshold) {
		PackedFloat32Array out;
		if (caldera_eval_gpu(p_gw, p_gh, p_rect, p_params, out)) {
			return out;
		}
	}
	return caldera_solve(p_gw, p_gh, p_rect, p_params);
}

} // namespace godot
