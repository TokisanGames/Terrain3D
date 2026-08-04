// Pasture3D Water — wave evaluation.
// Spec: PASTURE3D_WATER_SHADER_SPEC.md §3.1, §3.2
//
// *** THIS FILE IS THE PARITY CONTRACT WITH C++. ***
// Pasture3D::get_water_height() is a transcription of water_eval_waves(). Any
// change here must be mirrored in pasture_3d.cpp, in the same operation order,
// using float (not double). See spec §4.3.
//
// Everything except the wave table is derived here rather than uploaded, for
// two reasons:
//   1. G6 -- drop water_body.gdshader on a bare MeshInstance3D and it must make
//      waves with no plugin, so the shader cannot depend on C++ having run.
//   2. Parity. The fewer numbers that cross the CPU/GPU boundary, the fewer
//      places the two evaluators can silently disagree. The only derivations
//      used are `/` and `sqrt`, both correctly-rounded and therefore bit-exact
//      under IEEE-754 on either side.
//
// The mesh must be dense enough to resolve the shortest wavelength in the
// table: waves are a VERTEX-stage effect, so a 10 m wave on a 12 m grid aliases
// into noise. Rule of thumb: vertex spacing <= L_min / 8.

#ifndef WATER_WAVES_INC
#define WATER_WAVES_INC

#define WATER_TAU 6.283185307179586
#define WATER_GRAVITY 9.81

struct WaveSample {
	vec3 position; // world-space position after displacement
	vec3 normal;   // world-space normal
	float jacobian; // sum(Q * w * A * sin(theta)); ~1.0 means the crest is breaking
};

// p_pos: undisplaced world-space position. Y is carried through; the wave
// domain is XZ.
WaveSample water_eval_waves(vec3 p_pos) {
	WaveSample o;
	o.position = p_pos;
	o.normal = vec3(0.0, 1.0, 0.0);
	o.jacobian = 0.0;

	vec2 domain = p_pos.xz - _water_domain_origin.xz;

	// Steepness budget, distributed across waves in proportion to amplitude.
	//
	// GPU Gems normalises Q_i = steepness / (w_i * A_i * N), which makes the
	// product Q_i*w_i*A_i the same constant for every wave. That satisfies the
	// non-self-intersection constraint sum(Q*w*A) <= 1, but it has a defect the
	// spec missed: the horizontal term Q_i*A_i = steepness/(w_i*N) then carries
	// no amplitude dependence at all. A zero-amplitude wave -- an unused table
	// slot -- still shears the surface horizontally and still tilts the normal,
	// producing motion with no visible wave to justify it.
	//
	// Weighting by amplitude instead keeps the same bound (the weights sum to 1
	// by construction) while making empty slots genuinely inert and giving the
	// larger waves the sharper crests, which is also what the ocean does.
#ifndef WATER_NO_DEFAULT_WAVES
	// Nothing uploaded a table -- fall back to the compile-time one so a raw
	// .gdshader on a bare mesh still makes waves (see water_common.gdshaderinc).
	//
	// The sentinel is the first WAVELENGTH, not the amplitude sum. An un-set
	// uniform array reads as all zeros, and no real table has a zero wavelength,
	// so this distinguishes the two cases exactly -- whereas an amplitude test
	// would read a deliberately calm body as "nothing uploaded" and override it
	// with waves, making flat water impossible to author.
	//
	// Branch-free: `use_defaults` is uniform across the draw, so it costs a
	// select per wave and causes no divergence.
	float use_defaults = (_waves[0].w <= 0.0) ? 1.0 : 0.0;
#endif

	float sum_amp = 0.0;
	for (int i = 0; i < WATER_WAVE_COUNT; i++) {
		sum_amp += _waves[i].z;
	}
#ifndef WATER_NO_DEFAULT_WAVES
	sum_amp = mix(sum_amp, float(WATER_DEFAULT_SUM_AMP), use_defaults);
#endif

	float steepness_per_amp = wave_steepness / max(sum_amp, 1e-6);

	for (int i = 0; i < WATER_WAVE_COUNT; i++) {
#ifdef WATER_NO_DEFAULT_WAVES
		vec4 wave = _waves[i];
#else
		vec4 wave = mix(_waves[i], _wave_defaults[i], use_defaults);
#endif
		vec2 dir = wave.xy;
		float amp = wave.z;
		float wavelength = max(wave.w, 1e-3);

		float w = WATER_TAU / wavelength;
		// Deep-water dispersion. speed = sqrt(g*L/TAU), phase rate = speed*w,
		// which collapses to sqrt(g*w) -- one sqrt instead of a sqrt and two
		// multiplies, and identical to the spec's formula in exact arithmetic.
		float omega = sqrt(WATER_GRAVITY * w);

		// Q*w*A and Q*A, without ever forming Q. Dividing by amplitude to get Q
		// and multiplying it straight back out would blow up on empty slots.
		float qwa = steepness_per_amp * amp;
		float qa = qwa / w;
		float wa = w * amp;

		float theta = w * dot(dir, domain) + omega * water_time;
		float s = sin(theta);
		float c = cos(theta); // one sincos with the line above on every GPU in scope

		o.position.xz += (qa * c) * dir;
		o.position.y += amp * s;

		o.normal.xz -= (wa * c) * dir;
		float qwa_s = qwa * s;
		o.normal.y -= qwa_s;
		o.jacobian += qwa_s;
	}

	o.normal = normalize(o.normal);
	return o;
}

#endif // WATER_WAVES_INC
