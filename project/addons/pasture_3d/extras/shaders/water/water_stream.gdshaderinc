// Pasture3D Water — stream wave evaluation. Spec §10.2.
//
// *** THIS FILE IS A PARITY CONTRACT. ***
// Pasture3DStream._wave_offset() is a transcription of water_eval_stream_waves().
// Any change here must be mirrored there, in the same operation order. The
// stream gate's criterion E drives the two against each other.
//
// WHY A RIVER CANNOT USE THE GERSTNER TABLE. A wave in _waves[] carries one
// world-space heading. A river bends. So on any reach heading against that
// heading, the crests travel UPSTREAM -- correctly, for the model, and absurdly,
// for the thing being drawn. There is no amplitude, steepness or direction that
// fixes it, because the model has one direction and the river has many. The only
// setting that hides it is amplitude 0, which is what the demo scene shipped.
//
// THE FIX IS A COORDINATE, NOT A PARAMETER. The mesh carries, per vertex, the
// cumulative FLOW TRAVEL TIME from the head of the channel -- tau, in seconds,
// in UV2.x. Waves are then
//
//     h = A * sin(TAU * f * (water_time - tau))
//
// and everything falls out of that one substitution:
//
//   * Crests move DOWNSTREAM everywhere, unconditionally. tau increases along the
//     channel by construction, so there is no reach on which the phase can run
//     the other way. Upstream motion is not tuned away here; it is unrepresentable.
//   * Crests move at the LOCAL FLOW SPEED. Crest positions are the loci of equal
//     tau, spaced 1/f of travel time apart -- so they advance exactly as fast as
//     the water does, and the wavelength stretches in fast reaches and packs
//     together in slow ones. That is what real water does, and it is free: it is a
//     property of the coordinate, not an extra term.
//   * It is continuous. tau is a monotone function of one variable, sampled per
//     row on the CPU, so neighbouring vertices cannot disagree about phase.
//
// THE TRAP THIS AVOIDS, recorded because it is the obvious first attempt: making
// the CREST SPEED per-vertex, phase = TAU*(s/L) - TAU*(c_local/L)*t. That tears.
// The `c_local * t` term is a time-growing multiple of a quantity that varies
// along the river, so two adjacent rows drift apart in phase without bound and the
// surface shears itself to pieces within seconds. Frequency is what is conserved
// in steady flow, not wavelength -- so frequency is what must be the constant, and
// the wavelength is what is allowed to vary. tau is that statement as a coordinate.
//
// WHAT IS NOT MODELLED. No horizontal (Gerstner) shear: river ripples at this
// scale are close enough to vertical, and the shear term is what makes crests
// sharp on an ocean, which a creek does not want. No standing waves at shallows,
// no obstacle wakes -- both need per-vertex depth and a Froude test, and are
// deliberately out of this pass.

#ifndef WATER_STREAM_INC
#define WATER_STREAM_INC

// Octave layout. Two of them: one carrying the length of the channel, one at an
// irrational-ish multiple so the pair never re-phases into an obvious beat.
// Compile-time rather than uniforms -- these set the CHARACTER of moving water,
// and are the kind of number that gets nudged once and then has to be kept in
// step with a GDScript transcription forever.
#define WATER_STREAM_OCTAVES 2
const float WATER_STREAM_FREQ_MUL[2] = {1.0, 2.317};
const float WATER_STREAM_AMP_MUL[2] = {1.0, 0.42};
// Phase offsets, so the two octaves do not start every cycle aligned at a crest.
const float WATER_STREAM_PHASE[2] = {0.0, 1.7};

// Snap a frequency so a whole number of its cycles fits in water_time_period.
//
// The same constraint water_scroll() and flow_period document, and for the same
// reason: water_time WRAPS. A wave whose frequency does not divide the period is
// mid-cycle at the wrap and the whole river jumps. Floored at one cycle per
// period, since zero would stop the water dead.
float water_stream_quantise(float p_freq) {
	if (water_time_period <= 0.0) {
		return p_freq;
	}
	return max(round(p_freq * water_time_period), 1.0) / water_time_period;
}

// p_pos    : undisplaced world position.
// p_tau    : cumulative flow travel time from the head of the channel, seconds (UV2.x).
// p_flow   : xy = unit XZ flow direction, z = normalised speed (ARRAY_COLOR.rgb decoded).
// p_shore  : 0 at the centreline, 1 at the waterline (ARRAY_COLOR.a).
WaveSample water_eval_stream_waves(vec3 p_pos, float p_tau, vec3 p_flow, float p_shore) {
	WaveSample o;
	o.position = p_pos;
	o.normal = vec3(0.0, 1.0, 0.0);
	o.jacobian = 0.0;

	float speed = p_flow.z * flow_speed_scale;

	// Amplitude gate 1: still water is glass. A river slows into a pool and the
	// ripples should die there, which is the same observation that makes this
	// scale with speed rather than being a constant the author sets per reach.
	float speed_amp = clamp(speed / max(ripple_speed_ref, 1e-3), 0.0, 1.0);

	// Amplitude gate 2: the banks. The mesh edge sits ON the waterline, so a crest
	// there would stand proud of the ground the water is supposed to meet -- a rim
	// of surface hovering over dry bank, which reads as a broken mesh rather than
	// as a wave. Faded to nothing before it gets there.
	float shore_amp = 1.0 - smoothstep(ripple_bank_fade, 1.0, p_shore);

	float amp = ripple_amplitude * speed_amp * shore_amp;

	// d(height)/d(tau), accumulated alongside the height so the normal costs no
	// second pass over the octaves.
	float dh_dtau = 0.0;

	for (int i = 0; i < WATER_STREAM_OCTAVES; i++) {
		float f = water_stream_quantise(ripple_frequency * WATER_STREAM_FREQ_MUL[i]);
		float a = amp * WATER_STREAM_AMP_MUL[i];
		float w = WATER_TAU * f;
		float theta = w * (water_time - p_tau) + WATER_STREAM_PHASE[i];
		o.position.y += a * sin(theta);
		// d/dtau of a*sin(w*(t - tau)) = -a*w*cos(...)
		dh_dtau -= a * w * cos(theta);
	}

	// Chain rule into world space. tau is travel time, so d(tau)/d(distance along
	// the channel) is 1/speed, and the gradient points along the flow direction.
	//
	// The floor on speed is doing real work: as the water slows, the wavelength
	// packs down toward zero and the true gradient diverges. The AMPLITUDE has
	// already gone to zero there by the speed gate above, so the surface is
	// correct; without the floor the NORMAL would still be computed from a
	// vanishing denominator and flicker on flat water.
	float dh_ds = dh_dtau / max(speed, 0.25);
	o.normal = normalize(vec3(-dh_ds * p_flow.x, 1.0, -dh_ds * p_flow.y));

	// Surface slope as the crest-steepness signal, in the same spirit as the
	// Gerstner jacobian: ~1 where the surface is as steep as it gets. The river
	// variant compiles no crest foam, so nothing reads this today -- it is filled
	// in rather than left at zero so that enabling WATER_FOAM_CREST on a stream
	// gets a meaningful signal instead of a silently dead one.
	o.jacobian = clamp(abs(dh_ds), 0.0, 1.0);
	return o;
}

#endif // WATER_STREAM_INC
