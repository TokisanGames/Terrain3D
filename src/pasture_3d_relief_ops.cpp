// Relief op-program evaluator. See pasture_3d_relief_ops.h and PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md.
//
// Everything here is a faithful port of connectors/pasture3d_relief_material.gd. Where the two could plausibly
// diverge — noise settings, the crater profile, accumulation order, the exact clamp bounds — the C++ is
// written to match the GDScript line for line rather than to be idiomatic, because the A/B gate compares
// them numerically. If you change one, change the other in the same commit.

#include "pasture_3d_relief_ops.h"

#include <godot_cpp/core/math.hpp>

#include <cmath>

using namespace godot;

namespace {

// Mirrors GDScript smoothstep(from, to, x).
// Bilinear read of a row-major grid at fractional sample coords, clamped to the edges. Used only by
// relief_fields_add_sim, whose caller has already range-checked the coords. A non-finite corner yields
// 0 rather than propagating NaN into a selector band, where it would compare false against everything
// and read as "gated out" with no way to tell that from a correct gate.
inline double relief_bilinear(const float *p_src, int p_w, int p_h, double p_fu, double p_fv) {
	const int x0 = CLAMP((int)std::floor(p_fu), 0, p_w - 1);
	const int y0 = CLAMP((int)std::floor(p_fv), 0, p_h - 1);
	const int x1 = MIN(x0 + 1, p_w - 1);
	const int y1 = MIN(y0 + 1, p_h - 1);
	const double tx = CLAMP(p_fu - (double)x0, 0.0, 1.0);
	const double ty = CLAMP(p_fv - (double)y0, 0.0, 1.0);
	const float v00 = p_src[y0 * p_w + x0], v10 = p_src[y0 * p_w + x1];
	const float v01 = p_src[y1 * p_w + x0], v11 = p_src[y1 * p_w + x1];
	if (!std::isfinite(v00) || !std::isfinite(v10) || !std::isfinite(v01) || !std::isfinite(v11)) {
		return 0.0;
	}
	const double a = (double)v00 * (1.0 - tx) + (double)v10 * tx;
	const double b = (double)v01 * (1.0 - tx) + (double)v11 * tx;
	return a * (1.0 - ty) + b * ty;
}

inline double relief_smoothstep(double p_from, double p_to, double p_x) {
	if (Math::is_equal_approx(p_from, p_to)) {
		return p_x < p_from ? 0.0 : 1.0;
	}
	const double t = CLAMP((p_x - p_from) / (p_to - p_from), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

// Mirrors GDScript lerpf. Written out rather than using Math::lerp so the operation order — and so the
// last bit of the result — matches the oracle exactly.
inline double relief_lerp(double p_from, double p_to, double p_weight) {
	return p_from + (p_to - p_from) * p_weight;
}

// Mirrors GDScript signf: 0 stays 0 (copysign would return +1).
inline double relief_sign(double p_x) {
	return p_x > 0.0 ? 1.0 : (p_x < 0.0 ? -1.0 : 0.0);
}

// The one place noise settings are decided — mirrors Pasture3DReliefMaterial._configure_noise.
Ref<FastNoiseLite> configure_noise(float p_freq, int p_octaves, float p_lacunarity, float p_gain,
		int p_seed, bool p_ridged) {
	Ref<FastNoiseLite> n;
	n.instantiate();
	n->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
	n->set_seed(p_seed);
	n->set_frequency(MAX(p_freq, 0.000001f));
	n->set_fractal_type(p_ridged ? FastNoiseLite::FRACTAL_RIDGED : FastNoiseLite::FRACTAL_FBM);
	n->set_fractal_octaves(CLAMP(p_octaves, 1, 8));
	n->set_fractal_lacunarity(p_lacunarity);
	n->set_fractal_gain(p_gain);
	n->set_fractal_weighted_strength(0.0f);
	return n;
}

// Quantise x in [0,1] into `steps` bands — mirrors Pasture3DReliefMaterial._band. Shared by TERRACE and
// STRATIFY, which differ only in the coordinate they band.
inline double relief_band(double p_x, double p_steps, double p_hardness) {
	const double s = MAX(p_steps, 1.0);
	const double xs = p_x * s;
	const double q = std::floor(xs);
	const double f = xs - q;
	return (q + std::pow(f, 1.0 + CLAMP(p_hardness, 0.0, 1.0) * 15.0)) / s;
}

// The 0..1 coordinate a PROFILE band op quantises — mirrors Pasture3DReliefMaterial._band_coord.
//
// ACCUMULATOR is the historical path and is deliberately spelled as the exact expression it always was,
// not as a special case of a more general one: it is the default on every material authored so far, and
// gate BP compares it to the byte.
inline double relief_band_coord(int p_band_source, double p_acc, const ReliefSample &p_ground,
		const PackedFloat32Array &p_params, int p) {
	if (p_band_source == RELIEF_BAND_HOST_PROFILE) {
		// Already divided by the host's stored height in ReliefFields::sample_host, so 0 is the rim and
		// 1 the crest. Reads a flat 0 when no host fields were built, which is what makes a `Host Profile`
		// band on a Plow do visibly nothing rather than something arbitrary.
		return CLAMP(p_ground.host_norm, 0.0, 1.0);
	}
	if (p_band_source == RELIEF_BAND_GROUND_ALTITUDE) {
		const double lo = (double)p_params[p + RELIEF_BAND_RANGE_LO];
		const double hi = (double)p_params[p + RELIEF_BAND_RANGE_HI];
		const double d = hi - lo;
		return std::fabs(d) > 1.0e-9 ? CLAMP((p_ground.altitude - lo) / d, 0.0, 1.0) : 0.0;
	}
	return CLAMP(p_acc * 0.5 + 0.5, 0.0, 1.0);
}

// Linear read out of a baked Curve LUT block — mirrors Pasture3DReliefMaterial._sample_lut.
inline double relief_sample_lut(const PackedFloat32Array &p_luts, int p_slot, double p_x) {
	const int base = p_slot * RELIEF_CURVE_LUT_N;
	if (base < 0 || base + RELIEF_CURVE_LUT_N > p_luts.size()) {
		return p_x;
	}
	const double f = p_x * (double)(RELIEF_CURVE_LUT_N - 1);
	const int i0 = (int)f;
	if (i0 >= RELIEF_CURVE_LUT_N - 1) {
		return (double)p_luts[base + RELIEF_CURVE_LUT_N - 1];
	}
	const double frac = f - (double)i0;
	return (double)p_luts[base + i0] * (1.0 - frac) + (double)p_luts[base + i0 + 1] * frac;
}

// Bilinear read out of a baked 2D field block, in LOOP-NORMALISED coordinates: nu,nv are +/-1 at the
// fitted rect's edge, so they map onto the field's [0,1]x[0,1] extent. Outside that, and for a slot that
// does not exist, the field reads 0 -- a defined nothing, so a mis-spliced slot shows up as the op
// contributing nothing rather than as garbage.
// Mirrors Pasture3DReliefMaterial._sample_field, which is the ONLY producer of these bytes.
inline double relief_sample_field(const PackedFloat32Array &p_fields, const PackedInt32Array &p_meta,
		int p_slot, double p_nu, double p_nv) {
	const int m = p_slot * RELIEF_FIELD_META_STRIDE;
	if (p_slot < 0 || m + RELIEF_FIELD_META_STRIDE > p_meta.size()) {
		return 0.0;
	}
	const int base = p_meta[m];
	const int w = p_meta[m + 1];
	const int h = p_meta[m + 2];
	if (w < 2 || h < 2 || base < 0 || base + w * h > p_fields.size()) {
		return 0.0;
	}
	const double fx = (p_nu * 0.5 + 0.5) * (double)(w - 1);
	const double fy = (p_nv * 0.5 + 0.5) * (double)(h - 1);
	if (fx < 0.0 || fy < 0.0 || fx > (double)(w - 1) || fy > (double)(h - 1)) {
		return 0.0;
	}
	const int x0 = (int)fx;
	const int y0 = (int)fy;
	const int x1 = MIN(x0 + 1, w - 1);
	const int y1 = MIN(y0 + 1, h - 1);
	const double tx = fx - (double)x0;
	const double ty = fy - (double)y0;
	const double a = (double)p_fields[base + y0 * w + x0];
	const double b = (double)p_fields[base + y0 * w + x1];
	const double c = (double)p_fields[base + y1 * w + x0];
	const double d = (double)p_fields[base + y1 * w + x1];
	return (a * (1.0 - tx) + b * tx) * (1.0 - ty) + (c * (1.0 - tx) + d * tx) * ty;
}

// Asymmetric dune ridges — mirrors Pasture3DReliefMaterial._dunes.
// p: [0]=amplitude [1]=wavelength [2]=direction [3]=asymmetry [4]=crest sharpness [5]=wander frequency
//    [6]=wander amount [7]=seed
inline double relief_dunes(double u, double v, const PackedFloat32Array &p_params, int p,
		const Ref<FastNoiseLite> &p_noise) {
	const double dir = (double)p_params[p + 2];
	double d = u * std::cos(dir) + v * std::sin(dir);
	d += (double)p_noise->get_noise_2d(u, v) * (double)p_params[p + 6];
	const double wl = MAX((double)p_params[p + 1], 0.001);
	const double phase = (d / wl) - std::floor(d / wl);
	const double a = CLAMP((double)p_params[p + 3], 0.01, 0.99);
	const double t = phase < a ? (phase / a) : (1.0 - (phase - a) / (1.0 - a));
	return (std::pow(CLAMP(t, 0.0, 1.0), MAX((double)p_params[p + 4], 0.01)) * 2.0 - 1.0) *
			(double)p_params[p];
}

// Parallel corrugation — mirrors Pasture3DReliefMaterial._furrows.
// p: [0]=amplitude [1]=spacing [2]=direction [3]=profile(0=V,1=U,2=square) [4]=wobble frequency
//    [5]=wobble amount [6]=seed
inline double relief_furrows(double u, double v, const PackedFloat32Array &p_params, int p,
		const Ref<FastNoiseLite> &p_noise) {
	const double dir = (double)p_params[p + 2];
	double d = u * std::cos(dir) + v * std::sin(dir);
	d += (double)p_noise->get_noise_2d(u, v) * (double)p_params[p + 5];
	const double sp = MAX((double)p_params[p + 1], 0.001);
	const double phase = (d / sp) - std::floor(d / sp);
	const double a = std::fabs(phase * 2.0 - 1.0); // 0 at the furrow floor, 1 at the ridge
	const int profile = (int)p_params[p + 3];
	double f = a;
	if (profile == 1) {
		f = relief_smoothstep(0.0, 1.0, a);
	} else if (profile == 2) {
		f = relief_smoothstep(0.42, 0.58, a);
	}
	return (f * 2.0 - 1.0) * (double)p_params[p];
}

// One selector against one cell — mirrors Pasture3DReliefMaterial._selector_value.
inline double relief_selector_value(const PackedFloat32Array &p_sel, int p_sid,
		const ReliefSample &p_ground) {
	const int b = p_sid * RELIEF_SELECTOR_STRIDE;
	if (b < 0 || b + RELIEF_SELECTOR_STRIDE > p_sel.size()) {
		return 1.0;
	}
	const int filter_type = (int)p_sel[b];
	// Which surface the three SHAPE filter types read: the layers below this brush, or the brush's own
	// generated profile. Chosen before anything is measured, because it decides which of two parallel
	// field sets every read below comes out of. The four sim filter types ignore it entirely.
	const bool host = (int)p_sel[b + RELIEF_SELECTOR_FIELD_SOURCE] == RELIEF_FIELD_HOST;
	const ReliefFields *fl = host ? p_ground.host_fields : p_ground.fields;
	// SLOPE and CURVATURE are the two filter types a `measure_radius` applies to (§21.6): the same
	// measurement over a wider stencil. The radius lives on the fields, not the sample, because it is a whole
	// extra grid; the sample only carries where it came from.
	const bool measured = (double)p_sel[b + RELIEF_SELECTOR_RADIUS] > 0.0 && fl != nullptr &&
			p_ground.index >= 0;
	double x = measured ? fl->slope_for(p_sid, p_ground.index)
						: (host ? p_ground.host_slope_deg : p_ground.slope_deg);
	if (filter_type == RELIEF_SELECT_ALTITUDE) {
		x = host ? p_ground.host_altitude : p_ground.altitude;
	} else if (filter_type == RELIEF_SELECT_CURVATURE) {
		x = measured ? fl->curvature_for(p_sid, p_ground.index)
					 : (host ? p_ground.host_curvature : p_ground.curvature);
	} else if (filter_type == RELIEF_SELECT_FLOW) {
		x = p_ground.sim_flow; // already m², un-logged in relief_fields_add_sim
	} else if (filter_type == RELIEF_SELECT_EROSION) {
		x = p_ground.sim_erosion; // already positive metres
	} else if (filter_type == RELIEF_SELECT_DEPOSITION) {
		x = p_ground.sim_deposition;
	} else if (filter_type == RELIEF_SELECT_WETNESS) {
		x = p_ground.sim_wetness;
	}
	const double lo = (double)p_sel[b + 1];
	const double hi = (double)p_sel[b + 2];
	const double f_lo = MAX((double)p_sel[b + 3], 0.0);
	const double f_hi = MAX((double)p_sel[b + 4], 0.0);
	const double rise = x >= lo ? 1.0 : (f_lo > 0.0 ? relief_smoothstep(lo - f_lo, lo, x) : 0.0);
	const double fall = x <= hi ? 1.0 : (f_hi > 0.0 ? 1.0 - relief_smoothstep(hi, hi + f_hi, x) : 0.0);
	double s = CLAMP(MIN(rise, fall), 0.0, 1.0);
	if (p_sel[b + 5] != 0.0) { // invert
		s = 1.0 - s;
	}
	const double strength = CLAMP((double)p_sel[b + 6], 0.0, 1.0);
	return 1.0 + (s - 1.0) * strength; // lerp(1, s, strength)
}

// Loose rock shed downhill — mirrors Pasture3DReliefMaterial._scree.
// p: [0]=amplitude [1]=grain frequency [2]=downslope streak (m) [3]=toe deposition [4]=seed
//
// §21.6 retune: curvature is now metres of deviation over one cell instead of the raw 1/m Laplacian, so
// the old `clamp(curvature, 0, 1)` would have been a hundredfold different ramp. 0.25 m is the SAME ramp
// as before at 1 m vertex spacing — the two definitions differ by exactly vs²/4 there — and unlike the old
// one it now means the same depth of hollow at every spacing. Pinned by SimPhase65SelectorGate's BF.
inline double relief_scree(double u, double v, const ReliefSample &p_ground,
		const PackedFloat32Array &p_params, int p, const Ref<FastNoiseLite> &p_noise) {
	double su = u;
	double sv = v;
	const double glen = std::sqrt(p_ground.grad_x * p_ground.grad_x + p_ground.grad_z * p_ground.grad_z);
	if (glen > 0.000001) {
		// Offset the sample downhill so the grain reads as material that has travelled.
		const double streak = (double)p_params[p + 2];
		su = u - (p_ground.grad_x / glen) * streak;
		sv = v - (p_ground.grad_z / glen) * streak;
	}
	double val = (double)p_noise->get_noise_2d(su, sv) * (double)p_params[p];
	const double toe = (double)p_params[p + 3];
	if (toe != 0.0) {
		val += toe * CLAMP(p_ground.curvature / RELIEF_SCREE_TOE_FULL_M, 0.0, 1.0);
	}
	return val;
}

// Radial crater profile — mirrors Pasture3DReliefMaterial._crater.
// p: [0]=amplitude [1]=floor_depth [2]=rim_height [3]=rim_width [4]=ejecta_falloff [5]=floor_flatness
//    [6]=terrace_steps  ([7] reserved for rim wobble in phase 2)
inline double relief_crater(double p_nu, double p_nv, const PackedFloat32Array &p_params, int p) {
	const double r = std::sqrt(p_nu * p_nu + p_nv * p_nv);
	if (r >= 1.0) {
		return 0.0;
	}
	const double floor_depth = (double)p_params[p + 1];
	const double rim_height = (double)p_params[p + 2];
	const double rim_pos = CLAMP(1.0 - (double)p_params[p + 3], 0.05, 0.98);
	double val;
	if (r <= rim_pos) {
		const double t = r / rim_pos;
		// Higher exponent = flatter floor and steeper walls; 0 at the rim, -floor_depth at the centre.
		val = -floor_depth * (1.0 - std::pow(t, 2.0 + 6.0 * (double)p_params[p + 5]));
		const int steps = (int)p_params[p + 6];
		if (steps >= 1) {
			val = std::floor(val * steps) / (double)steps;
		}
		val += rim_height * relief_smoothstep(0.7, 1.0, t);
	} else {
		const double s = (r - rim_pos) / (1.0 - rim_pos);
		val = rim_height * std::pow(1.0 - s, MAX((double)p_params[p + 4], 0.01));
	}
	return val * (double)p_params[p];
}

} // namespace

bool godot::relief_build(const Dictionary &p_params, ReliefProgram &r_prog) {
	r_prog.ops = p_params.get("ops", PackedInt32Array());
	r_prog.params = p_params.get("op_params", PackedFloat32Array());
	r_prog.luts = p_params.get("op_luts", PackedFloat32Array());
	r_prog.fields = p_params.get("op_fields", PackedFloat32Array());
	r_prog.field_meta = p_params.get("op_field_meta", PackedInt32Array());
	r_prog.selectors = p_params.get("op_selectors", PackedFloat32Array());
	r_prog.count = r_prog.ops.size() / RELIEF_OP_STRIDE;
	if (r_prog.count < 1 || r_prog.params.size() < r_prog.count * RELIEF_PARAM_STRIDE) {
		r_prog.count = 0;
		return false;
	}

	r_prog.noise_a.assign(r_prog.count, Ref<FastNoiseLite>());
	r_prog.noise_b.assign(r_prog.count, Ref<FastNoiseLite>());
	for (int i = 0; i < r_prog.count; i++) {
		const int op = r_prog.ops[i * RELIEF_OP_STRIDE];
		const int p = i * RELIEF_PARAM_STRIDE;
		switch (op) {
			case RELIEF_OP_FBM:
			case RELIEF_OP_RIDGED:
			case RELIEF_OP_BILLOW:
				r_prog.noise_a[i] = configure_noise(r_prog.params[p + 1], (int)r_prog.params[p + 2],
						r_prog.params[p + 3], r_prog.params[p + 4], (int)r_prog.params[p + 5],
						op == RELIEF_OP_RIDGED);
				break;
			case RELIEF_OP_DUNES: // wander field
				r_prog.noise_a[i] = configure_noise(r_prog.params[p + 5], 2, 2.0f, 0.5f,
						(int)r_prog.params[p + 7], false);
				break;
			case RELIEF_OP_FURROWS: // wobble field
				r_prog.noise_a[i] = configure_noise(r_prog.params[p + 4], 2, 2.0f, 0.5f,
						(int)r_prog.params[p + 6], false);
				break;
			case RELIEF_OP_TERRACE: // step jitter field
				r_prog.noise_a[i] = configure_noise(r_prog.params[p + 4], 2, 2.0f, 0.5f,
						(int)r_prog.params[p + 3], false);
				break;
			case RELIEF_OP_STRATIFY: // lateral break-up field
				r_prog.noise_a[i] = configure_noise(r_prog.params[p + 4], 3, 2.0f, 0.5f,
						(int)r_prog.params[p + 6], false);
				break;
			case RELIEF_OP_SCREE: // grain field
				r_prog.noise_a[i] = configure_noise(r_prog.params[p + 1], 3, 2.0f, 0.5f,
						(int)r_prog.params[p + 4], false);
				break;
			case RELIEF_OP_WARP: {
				// Two decorrelated fields offset the domain. Godot's FastNoiseLite applies its own
				// domain_warp_* settings internally and exposes no standalone warp call, so the offset is
				// computed explicitly — which is also what lets subsequent ops see it.
				const float amp_freq = r_prog.params[p + 1];
				const int oct = (int)r_prog.params[p + 2];
				const int sd = (int)r_prog.params[p + 3];
				r_prog.noise_a[i] = configure_noise(amp_freq, oct, 2.0f, 0.5f, sd, false);
				r_prog.noise_b[i] = configure_noise(amp_freq, oct, 2.0f, 0.5f, sd + 1013, false);
			} break;
			default:
				break;
		}
	}
	return true;
}

void godot::ReliefFields::sample(int p_index, ReliefSample &r_out) const {
	if (!ready || p_index < 0 || p_index >= (int)altitude.size()) {
		r_out = ReliefSample();
		return;
	}
	r_out.fields = this;
	r_out.index = p_index;
	r_out.altitude = (double)altitude[p_index];
	r_out.slope_deg = (double)slope_deg[p_index];
	r_out.curvature = (double)curvature[p_index];
	r_out.grad_x = (double)grad_x[p_index];
	r_out.grad_z = (double)grad_z[p_index];
	if (has_sim) {
		r_out.sim_flow = (double)sim_flow[p_index];
		r_out.sim_erosion = (double)sim_erosion[p_index];
		r_out.sim_deposition = (double)sim_deposition[p_index];
		r_out.sim_wetness = (double)sim_wetness[p_index];
	} else {
		r_out.sim_flow = 0.0;
		r_out.sim_erosion = 0.0;
		r_out.sim_deposition = 0.0;
		r_out.sim_wetness = 0.0;
	}
}

void godot::ReliefFields::sample_host(int p_index, ReliefSample &r_out) const {
	if (!ready || p_index < 0 || p_index >= (int)altitude.size()) {
		return; // leaves has_host false: a host-source selector then reads a defined zero, not the below set
	}
	r_out.host_fields = this;
	r_out.index = p_index;
	r_out.host_altitude = (double)altitude[p_index];
	r_out.host_slope_deg = (double)slope_deg[p_index];
	r_out.host_curvature = (double)curvature[p_index];
	// The stored divisor, applied once. Guarded because a zero-height Mound is a legal (if pointless)
	// brush and a band op dividing by it would put NaN into the height map.
	r_out.host_norm = std::fabs(norm_divisor) > 1.0e-9 ? r_out.host_altitude / norm_divisor : 0.0;
	r_out.has_host = true;
}

double godot::ReliefFields::slope_for(int p_sid, int p_index) const {
	if (p_sid < 0 || p_sid >= (int)sel_slot.size() || p_index < 0) {
		return p_index >= 0 && p_index < (int)slope_deg.size() ? (double)slope_deg[p_index] : 0.0;
	}
	const int slot = sel_slot[p_sid];
	if (slot < 0 || slot >= (int)measured_slope.size() || p_index >= (int)measured_slope[slot].size()) {
		return p_index < (int)slope_deg.size() ? (double)slope_deg[p_index] : 0.0;
	}
	return (double)measured_slope[slot][p_index];
}

double godot::ReliefFields::curvature_for(int p_sid, int p_index) const {
	if (p_sid < 0 || p_sid >= (int)sel_slot.size() || p_index < 0) {
		return p_index >= 0 && p_index < (int)curvature.size() ? (double)curvature[p_index] : 0.0;
	}
	const int slot = sel_slot[p_sid];
	if (slot < 0 || slot >= (int)measured_curvature.size() ||
			p_index >= (int)measured_curvature[slot].size()) {
		return p_index < (int)curvature.size() ? (double)curvature[p_index] : 0.0;
	}
	return (double)measured_curvature[slot][p_index];
}

double godot::relief_selector_weight(const PackedFloat32Array &p_selectors, int p_sid,
		const ReliefSample &p_ground) {
	return relief_selector_value(p_selectors, p_sid, p_ground);
}

void godot::relief_fields_build(const PackedFloat32Array &p_below, double p_min_x, double p_min_z,
		double p_vs, int p_gw, int p_gh, const std::function<float(double, double)> &p_fallback,
		ReliefFields &r_out) {
	const int n = p_gw * p_gh;
	if (n < 1) {
		return;
	}
	r_out.gw = p_gw;
	r_out.gh = p_gh;
	r_out.vs = p_vs;
	r_out.altitude.assign((size_t)n, 0.f);
	const bool has_below = p_below.size() == n;
	for (int iz = 0; iz < p_gh; iz++) {
		const int row = iz * p_gw;
		for (int ix = 0; ix < p_gw; ix++) {
			float h = has_below ? p_below[row + ix] : (float)NAN;
			if (!std::isfinite(h)) {
				h = p_fallback(p_min_x + ix * p_vs, p_min_z + iz * p_vs);
			}
			r_out.altitude[row + ix] = std::isfinite(h) ? h : 0.f;
		}
	}

	r_out.slope_deg.assign((size_t)n, 0.f);
	r_out.curvature.assign((size_t)n, 0.f);
	r_out.grad_x.assign((size_t)n, 0.f);
	r_out.grad_z.assign((size_t)n, 0.f);
	const double inv2 = 1.0 / (2.0 * p_vs);
	for (int iz = 0; iz < p_gh; iz++) {
		const int row = iz * p_gw;
		const int zm = MAX(iz - 1, 0) * p_gw;
		const int zp = MIN(iz + 1, p_gh - 1) * p_gw;
		for (int ix = 0; ix < p_gw; ix++) {
			const int xm = MAX(ix - 1, 0);
			const int xp = MIN(ix + 1, p_gw - 1);
			const double c = (double)r_out.altitude[row + ix];
			const double gx = ((double)r_out.altitude[row + xp] - (double)r_out.altitude[row + xm]) * inv2;
			const double gz = ((double)r_out.altitude[zp + ix] - (double)r_out.altitude[zm + ix]) * inv2;
			r_out.grad_x[row + ix] = (float)gx;
			r_out.grad_z[row + ix] = (float)gz;
			r_out.slope_deg[row + ix] = (float)Math::rad_to_deg(std::atan(std::sqrt(gx * gx + gz * gz)));
			// §21.6: METRES of deviation — the mean of the ring at one cell, minus the centre. The old
			// form divided by vs² instead of 4, which made the same hollow read 16x smaller on a 4x
			// coarser grid. Positive is still a hollow.
			r_out.curvature[row + ix] = (float)(((double)r_out.altitude[row + xp] +
														(double)r_out.altitude[row + xm] +
														(double)r_out.altitude[zp + ix] +
														(double)r_out.altitude[zm + ix] - 4.0 * c) *
					0.25);
		}
	}
	r_out.ready = true;
}

void godot::relief_fields_add_measured(const PackedFloat32Array &p_selectors, ReliefFields &r_fields,
		int p_field_source) {
	const int n_sel = p_selectors.size() / RELIEF_SELECTOR_STRIDE;
	if (!r_fields.ready || n_sel < 1) {
		return;
	}
	const int gw = r_fields.gw;
	const int gh = r_fields.gh;
	const double vs = r_fields.vs > 0.0 ? r_fields.vs : 1.0;
	const int n = gw * gh;

	// One slot per DISTINCT radius. Exact float equality is the right test: both sides are the same
	// `measure_radius` float off the same wire block, not two numbers that happen to be close.
	std::vector<double> radii;
	r_fields.sel_slot.assign((size_t)n_sel, -1);
	for (int s = 0; s < n_sel; s++) {
		const int base = s * RELIEF_SELECTOR_STRIDE;
		const double r = (double)p_selectors[base + RELIEF_SELECTOR_RADIUS];
		if (!(r > 0.0)) {
			continue; // 0 = one cell = the base fields, and NaN lands here too
		}
		if ((int)p_selectors[base + RELIEF_SELECTOR_FIELD_SOURCE] != p_field_source) {
			continue; // this radius belongs to the other field set; slot stays -1 here
		}
		int slot = -1;
		for (int i = 0; i < (int)radii.size(); i++) {
			if (radii[i] == r) {
				slot = i;
				break;
			}
		}
		if (slot < 0) {
			slot = (int)radii.size();
			radii.push_back(r);
		}
		r_fields.sel_slot[s] = slot;
	}
	if (radii.empty()) {
		return;
	}

	r_fields.measured_slope.assign(radii.size(), std::vector<float>());
	r_fields.measured_curvature.assign(radii.size(), std::vector<float>());
	for (size_t k = 0; k < radii.size(); k++) {
		const double r = radii[k];
		std::vector<float> &slope = r_fields.measured_slope[k];
		std::vector<float> &curv = r_fields.measured_curvature[k];
		slope.assign((size_t)n, 0.f);
		curv.assign((size_t)n, 0.f);

		// SLOPE: the same central difference the one-cell field takes, over +/-R cells instead of +/-1.
		// Round rather than truncate, and never below 1, so a radius under half a cell is the one-cell
		// measurement rather than a division by zero.
		const int rc = MAX(1, (int)std::lround(r / vs));
		const double inv2 = 1.0 / (2.0 * (double)rc * vs);

		// CURVATURE: the ring of cells one cell wide at radius r, mean height minus the centre (§21.6).
		// Built once here rather than per cell. At r = vs the ring is the 4 axial and 4 diagonal
		// neighbours, which is close to but deliberately not identical to the one-cell field's 4 axial
		// ones — `measure_radius = 0` is the bitwise-preserved path, not "r = one cell".
		const int rr = MAX(1, (int)std::ceil(r / vs));
		std::vector<int> ring_dx, ring_dz;
		for (int dz = -rr; dz <= rr; dz++) {
			for (int dx = -rr; dx <= rr; dx++) {
				const double d = std::sqrt((double)(dx * dx + dz * dz)) * vs;
				if (std::fabs(d - r) <= vs * 0.5) {
					ring_dx.push_back(dx);
					ring_dz.push_back(dz);
				}
			}
		}
		const double inv_ring = ring_dx.empty() ? 0.0 : 1.0 / (double)ring_dx.size();

		for (int iz = 0; iz < gh; iz++) {
			const int row = iz * gw;
			const int zm = MAX(iz - rc, 0) * gw;
			const int zp = MIN(iz + rc, gh - 1) * gw;
			for (int ix = 0; ix < gw; ix++) {
				const int xm = MAX(ix - rc, 0);
				const int xp = MIN(ix + rc, gw - 1);
				const double gx = ((double)r_fields.altitude[row + xp] -
										  (double)r_fields.altitude[row + xm]) *
						inv2;
				const double gz = ((double)r_fields.altitude[zp + ix] -
										  (double)r_fields.altitude[zm + ix]) *
						inv2;
				slope[row + ix] = (float)Math::rad_to_deg(std::atan(std::sqrt(gx * gx + gz * gz)));
				if (ring_dx.empty()) {
					curv[row + ix] = r_fields.curvature[row + ix];
					continue;
				}
				double acc = 0.0;
				for (size_t i = 0; i < ring_dx.size(); i++) {
					const int sx = CLAMP(ix + ring_dx[i], 0, gw - 1);
					const int sz = CLAMP(iz + ring_dz[i], 0, gh - 1);
					acc += (double)r_fields.altitude[sz * gw + sx];
				}
				curv[row + ix] = (float)(acc * inv_ring - (double)r_fields.altitude[row + ix]);
			}
		}
	}
}

void godot::relief_fields_add_sim(const Dictionary &p_sim, double p_min_x, double p_min_z, double p_vs,
		int p_gw, int p_gh, ReliefFields &r_fields) {
	const int sw = (int)p_sim.get("width", 0);
	const int sh = (int)p_sim.get("height", 0);
	const double cell = (double)p_sim.get("cell_size", 0.0);
	const double smin_x = (double)p_sim.get("min_x", 0.0);
	const double smin_z = (double)p_sim.get("min_z", 0.0);
	const PackedFloat32Array flow = p_sim.get("flow", PackedFloat32Array());
	const PackedFloat32Array ero = p_sim.get("erosion", PackedFloat32Array());
	const PackedFloat32Array dep = p_sim.get("deposition", PackedFloat32Array());
	const PackedFloat32Array wet = p_sim.get("wetness", PackedFloat32Array());
	const int64_t sn = (int64_t)sw * (int64_t)sh;
	const int64_t n = (int64_t)p_gw * (int64_t)p_gh;
	if (sw < 2 || sh < 2 || cell <= 0.0 || n < 1 || flow.size() < sn || ero.size() < sn ||
			dep.size() < sn || wet.size() < sn) {
		return; // has_sim stays false; every sim Kind then reads its defined zero
	}
	// The defined-zero fill (spec §9). Done first and unconditionally, so a bake grid that only PARTLY
	// overlaps the result still has honest values everywhere — the "outside" cells are not left
	// uninitialised and are not the nearest edge sample smeared outwards.
	r_fields.sim_flow.assign((size_t)n, 0.0f);
	r_fields.sim_erosion.assign((size_t)n, 0.0f);
	r_fields.sim_deposition.assign((size_t)n, 0.0f);
	r_fields.sim_wetness.assign((size_t)n, 0.0f);
	r_fields.has_sim = true;

	const float *fp = flow.ptr();
	const float *ep = ero.ptr();
	const float *dp = dep.ptr();
	const float *wp = wet.ptr();
	for (int iz = 0; iz < p_gh; iz++) {
		const double fv = ((p_min_z + (double)iz * p_vs) - smin_z) / cell;
		if (fv < 0.0 || fv > (double)(sh - 1)) {
			continue;
		}
		const int row = iz * p_gw;
		for (int ix = 0; ix < p_gw; ix++) {
			const double fu = ((p_min_x + (double)ix * p_vs) - smin_x) / cell;
			if (fu < 0.0 || fu > (double)(sw - 1)) {
				continue;
			}
			const double f = relief_bilinear(fp, sw, sh, fu, fv);
			const double e = relief_bilinear(ep, sw, sh, fu, fv);
			const double d = relief_bilinear(dp, sw, sh, fu, fv);
			const double w = relief_bilinear(wp, sw, sh, fu, fv);
			// The two unit conversions the ReliefSample docs promise. exp() once per cell here rather
			// than once per gated op in the evaluator, and the sign flip so an erosion band reads in the
			// direction an artist thinks in.
			r_fields.sim_flow[(size_t)(row + ix)] = (float)std::exp(f);
			r_fields.sim_erosion[(size_t)(row + ix)] = (float)(e < 0.0 ? -e : 0.0);
			r_fields.sim_deposition[(size_t)(row + ix)] = (float)(d > 0.0 ? d : 0.0);
			r_fields.sim_wetness[(size_t)(row + ix)] = (float)(w > 0.0 ? w : 0.0);
		}
	}
}

bool godot::relief_scatter_build(const Dictionary &p_params, double p_min_x, double p_min_z, double p_vs,
		int p_gw, int p_gh, ReliefScatter &r_out) {
	r_out.instances = p_params.get("instances", PackedFloat32Array());
	r_out.count = r_out.instances.size() / RELIEF_INSTANCE_STRIDE;
	if (r_out.count < 1) {
		return false;
	}
	r_out.blend = (int)p_params.get("scatter_blend", (int)RELIEF_SCATTER_STRONGEST);
	r_out.min_x = p_min_x;
	r_out.min_z = p_min_z;

	// One grid cell per largest instance: a query then only has to look at its own bucket, because an
	// instance is inserted into every bucket its bounding box touches.
	double max_r = p_vs;
	for (int i = 0; i < r_out.count; i++) {
		max_r = MAX(max_r, (double)r_out.instances[i * RELIEF_INSTANCE_STRIDE + 2]);
	}
	r_out.cell = MAX(max_r, 0.001);
	r_out.gw = MAX((int)std::ceil((p_gw * p_vs) / r_out.cell) + 1, 1);
	r_out.gh = MAX((int)std::ceil((p_gh * p_vs) / r_out.cell) + 1, 1);
	r_out.buckets.assign((size_t)r_out.gw * r_out.gh, {});

	for (int i = 0; i < r_out.count; i++) {
		const int b = i * RELIEF_INSTANCE_STRIDE;
		const double cx = (double)r_out.instances[b];
		const double cz = (double)r_out.instances[b + 1];
		const double r = (double)r_out.instances[b + 2];
		int x0 = (int)std::floor((cx - r - p_min_x) / r_out.cell);
		int x1 = (int)std::floor((cx + r - p_min_x) / r_out.cell);
		int z0 = (int)std::floor((cz - r - p_min_z) / r_out.cell);
		int z1 = (int)std::floor((cz + r - p_min_z) / r_out.cell);
		x0 = CLAMP(x0, 0, r_out.gw - 1);
		x1 = CLAMP(x1, 0, r_out.gw - 1);
		z0 = CLAMP(z0, 0, r_out.gh - 1);
		z1 = CLAMP(z1, 0, r_out.gh - 1);
		for (int gz = z0; gz <= z1; gz++) {
			for (int gx = x0; gx <= x1; gx++) {
				r_out.buckets[(size_t)gz * r_out.gw + gx].push_back(i); // ascending i, by construction
			}
		}
	}
	return true;
}

double godot::relief_scatter_eval(const ReliefProgram &p_prog, const ReliefScatter &p_sc, double p_x,
		double p_z, const ReliefSample &p_ground) {
	const int bx = CLAMP((int)std::floor((p_x - p_sc.min_x) / p_sc.cell), 0, p_sc.gw - 1);
	const int bz = CLAMP((int)std::floor((p_z - p_sc.min_z) / p_sc.cell), 0, p_sc.gh - 1);
	const std::vector<int> &bucket = p_sc.buckets[(size_t)bz * p_sc.gw + bx];

	bool has = false;
	double acc = 0.0;
	for (int idx : bucket) {
		const int b = idx * RELIEF_INSTANCE_STRIDE;
		const double r = MAX((double)p_sc.instances[b + 2], 0.001);
		const double dx = p_x - (double)p_sc.instances[b];
		const double dz = p_z - (double)p_sc.instances[b + 1];
		const double c = (double)p_sc.instances[b + 3];
		const double s = (double)p_sc.instances[b + 4];
		const double lx = dx * c + dz * s;
		const double lz = -dx * s + dz * c;
		const double inv = 1.0 / r;
		const double nu = lx * inv;
		const double nv = lz * inv;
		const double rad = std::sqrt(nu * nu + nv * nv);
		if (rad >= 1.0) {
			continue;
		}
		// Window the outer 10% to zero so a non-radial material (a fractal, say) fades out instead of
		// stamping a hard disc. Radial ops are already ~0 out here, so this barely touches them.
		const double val = relief_eval(p_prog, lx, lz, nu, nv, inv, inv, p_ground) *
				(double)p_sc.instances[b + 5] * relief_smoothstep(1.0, 0.9, rad);
		if (!has) {
			acc = val;
			has = true;
			continue;
		}
		switch (p_sc.blend) {
			case RELIEF_SCATTER_ADD: acc += val; break;
			case RELIEF_SCATTER_MAX: acc = MAX(acc, val); break;
			case RELIEF_SCATTER_MIN: acc = MIN(acc, val); break;
			default: // STRONGEST
				if (std::fabs(val) > std::fabs(acc)) {
					acc = val;
				}
				break;
		}
	}
	return has ? acc : 0.0;
}

double godot::relief_eval(const ReliefProgram &p_prog, double u, double v, double nu, double nv,
		double inv_ex, double inv_ez, const ReliefSample &p_ground) {
	double acc = 0.0;
	for (int i = 0; i < p_prog.count; i++) {
		const int o = i * RELIEF_OP_STRIDE;
		const int op = p_prog.ops[o];
		const int blend = p_prog.ops[o + 1];
		const int flags = p_prog.ops[o + 3];
		const int p = i * RELIEF_PARAM_STRIDE;

		// Terrain-aware gate for this op, if any. A GENERATOR scales its contribution by it, a DOMAIN op
		// scales its displacement, and a PROFILE op lerps between the un-remapped and remapped
		// accumulator — so `sel == 0` always means "this op did nothing", smoothly, whatever its category.
		const int sid = p_prog.ops[o + 2];
		const double sel = sid >= 0 ? relief_selector_value(p_prog.selectors, sid, p_ground) : 1.0;

		// --- DOMAIN: rewrites the sample point for every op that follows; never touches acc.
		if (op == RELIEF_OP_WARP) {
			if (p_prog.noise_a[i].is_null() || p_prog.noise_b[i].is_null()) {
				continue;
			}
			const double amp = (double)p_prog.params[p] * sel;
			const double du = (double)p_prog.noise_a[i]->get_noise_2d(u, v) * amp;
			const double dv = (double)p_prog.noise_b[i]->get_noise_2d(u, v) * amp;
			u += du;
			v += dv;
			nu += du * inv_ex;
			nv += dv * inv_ez;
			continue;
		}

		// --- PROFILE: remaps acc in place; ignores blend.
		const int band_source = (flags & RELIEF_FLAG_BAND_MASK) >> RELIEF_FLAG_BAND_SHIFT;

		if (op == RELIEF_OP_TERRACE) {
			if (p_prog.noise_a[i].is_null()) {
				continue;
			}
			double tx = relief_band_coord(band_source, acc, p_ground, p_prog.params, p);
			const double jit = (double)p_prog.params[p + 2];
			if (jit != 0.0) {
				tx = CLAMP(tx + (double)p_prog.noise_a[i]->get_noise_2d(u, v) * jit, 0.0, 1.0);
			}
			acc = relief_lerp(acc,
					relief_band(tx, (double)p_prog.params[p], (double)p_prog.params[p + 1]) * 2.0 - 1.0,
					sel);
			continue;
		}
		if (op == RELIEF_OP_STRATIFY) {
			if (p_prog.noise_a[i].is_null()) {
				continue;
			}
			// Bands are horizontal in the banded coordinate, then tilted by a linear ramp across the
			// ground (dip, in normalised units per 100 m) and broken up laterally so they are not dead
			// straight.
			const double dipdir = (double)p_prog.params[p + 3];
			const double tilt = (double)p_prog.params[p + 2] *
							(u * std::cos(dipdir) + v * std::sin(dipdir)) * 0.01 +
					(double)p_prog.noise_a[i]->get_noise_2d(u, v) * (double)p_prog.params[p + 5];
			// The ACCUMULATOR path folds dip and break-up in BEFORE the -1..1 -> 0..1 remap, exactly as it
			// always did — that expression is what gate BP holds to the byte. The other band sources are
			// already in 0..1, so the same tilt is halved to land at the same visual magnitude rather
			// than twice it.
			double w;
			if (band_source == RELIEF_BAND_ACCUMULATOR) {
				w = CLAMP((acc + tilt) * 0.5 + 0.5, 0.0, 1.0);
			} else {
				w = CLAMP(relief_band_coord(band_source, acc, p_ground, p_prog.params, p) + tilt * 0.5,
						0.0, 1.0);
			}
			acc = relief_lerp(acc,
					relief_band(w, (double)p_prog.params[p], (double)p_prog.params[p + 1]) * 2.0 - 1.0,
					sel);
			continue;
		}
		if (op == RELIEF_OP_CLAMP) {
			acc = relief_lerp(acc, CLAMP(acc, (double)p_prog.params[p], (double)p_prog.params[p + 1]), sel);
			continue;
		}
		if (op == RELIEF_OP_CURVE) {
			acc = relief_lerp(acc,
					relief_sample_lut(p_prog.luts, (int)p_prog.params[p],
							CLAMP(acc * 0.5 + 0.5, 0.0, 1.0)) *
									2.0 -
							1.0,
					sel);
			continue;
		}

		// --- GENERATOR: computes a value and blends it in.
		double val = 0.0;
		switch (op) {
			case RELIEF_OP_CONST:
				val = (double)p_prog.params[p];
				break;
			case RELIEF_OP_FBM:
			case RELIEF_OP_RIDGED:
			case RELIEF_OP_BILLOW: {
				if (p_prog.noise_a[i].is_null()) {
					continue;
				}
				double raw = (double)p_prog.noise_a[i]->get_noise_2d(u, v);
				if (op == RELIEF_OP_BILLOW) {
					raw = std::fabs(raw) * 2.0 - 1.0;
				} else if (op == RELIEF_OP_RIDGED) {
					const double sharp = (double)p_prog.params[p + 6];
					if (sharp != 1.0 && sharp > 0.0) {
						raw = relief_sign(raw) * std::pow(std::fabs(raw), sharp);
					}
				}
				val = raw * (double)p_prog.params[p];
			} break;
			case RELIEF_OP_DUNES:
				if (p_prog.noise_a[i].is_null()) {
					continue;
				}
				val = relief_dunes(u, v, p_prog.params, p, p_prog.noise_a[i]);
				break;
			case RELIEF_OP_FURROWS:
				if (p_prog.noise_a[i].is_null()) {
					continue;
				}
				val = relief_furrows(u, v, p_prog.params, p, p_prog.noise_a[i]);
				break;
			case RELIEF_OP_CRATER:
				val = relief_crater(nu, nv, p_prog.params, p);
				break;
			case RELIEF_OP_DLA:
				// Loop-normalised, exactly like CRATER: the cluster maps once onto the oriented rectangle.
				val = relief_sample_field(p_prog.fields, p_prog.field_meta,
							   (int)p_prog.params[p + RELIEF_DLA_FIELD_SLOT], nu, nv) *
						(double)p_prog.params[p];
				break;
			case RELIEF_OP_SCREE:
				if (p_prog.noise_a[i].is_null()) {
					continue;
				}
				val = relief_scree(u, v, p_ground, p_prog.params, p, p_prog.noise_a[i]);
				break;
			default:
				continue;
		}

		val *= sel;

		if (flags & RELIEF_FLAG_NEGATE) {
			val = -val;
		}
		switch (blend) {
			case RELIEF_BLEND_ADD: acc += val; break;
			case RELIEF_BLEND_SUB: acc -= val; break;
			case RELIEF_BLEND_MUL: acc *= val; break;
			case RELIEF_BLEND_MAX: acc = MAX(acc, val); break;
			case RELIEF_BLEND_MIN: acc = MIN(acc, val); break;
			case RELIEF_BLEND_REPLACE: acc = val; break;
			default: break;
		}
		if (flags & RELIEF_FLAG_CLAMP) {
			acc = CLAMP(acc, -1.0, 1.0);
		}
	}
	return acc;
}
