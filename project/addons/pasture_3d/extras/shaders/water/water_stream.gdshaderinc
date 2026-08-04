// Pasture3D Water — stream wave evaluation. Spec §10.2, §10.3, §10.4.
//
// *** THIS FILE IS A PARITY CONTRACT. ***
// Pasture3DStream._ripple() is a transcription of water_eval_stream_waves().
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
// THE SAME ARGUMENT, TWICE MORE. The two terms added on top of the ripples are
// each a phase coordinate integrated on the CPU, for the identical reason:
//
//   CHOP (§10.3) varies ACROSS the channel, which the ripples cannot: they are a
//   function of travel time alone, so every point on a cross-section sits at the
//   same height and the river reads as a rolling carpet. Chop is two oblique
//   octaves in (tau, lateral), interfering into the diamond lattice moving water
//   shows. Its coordinate is signed lateral offset in METRES (CUSTOM0.x), not a
//   fraction of the width, so the pattern does not stretch where the channel opens
//   out. It is the one term whose crests are not athwart the current, and so the
//   only one that contributes a cross-channel component to the normal.
//
//   STANDING WAVES (§10.4) are the undulations below a ford or a chute, and they
//   DO NOT MOVE: their phase is a function of position and of nothing else, so
//   they sit still in the world while the water runs through them. A wave holds
//   station when its phase speed matches the flow, c = v, which in deep water
//   means k = g/v^2 -- so the stationary phase is
//
//       psi(s) = integral of g / v(s)^2 ds
//
//   and, exactly as with tau, it must be INTEGRATED and carried (CUSTOM0.y) rather
//   than evaluated pointwise as g*s/v^2. Pointwise is not merely approximate: on a
//   reach slowing from 3 to 2 m/s two hundred metres down a river, g*s/v^2 swings
//   by 270 radians over a few rows -- forty crests packed between two vertices --
//   and the surface aliases into noise. The integral moves smoothly because it
//   accumulates the local wavenumber instead of re-deriving a global one.
//
// WHAT IS NOT MODELLED. No horizontal (Gerstner) shear: river ripples at this
// scale are close enough to vertical, and the shear term is what makes crests
// sharp on an ocean, which a creek does not want. No obstacle wakes -- a rock in
// the stream is not in the mesh, so there is nothing to wake from. No breaking:
// the standing waves stay sinusoidal however supercritical the reach gets, and
// whitewater is the foam layer's job.

#ifndef WATER_STREAM_INC
#define WATER_STREAM_INC

// Metres per second below which the flow speed stops being taken at face value.
// Only reached on water every amplitude gate here has already faded to nothing,
// so it decides the shape of something invisible; it exists to keep the divisions
// finite. Mirrored by Pasture3DStream.TAU_SPEED_FLOOR.
const float WATER_STREAM_SPEED_FLOOR = 0.25;

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

// Chop octaves. The lateral multipliers have OPPOSITE SIGNS on purpose: two
// oblique wave trains crossing is what makes a lattice rather than corduroy.
// They are not exact mirrors (1.0 against -0.79, and different frequencies)
// because a mirrored pair at one frequency collapses by the sum-to-product
// identity into a train with STATIONARY nodes at fixed lateral positions --
// stripes down the river that never move, which is worse than the corduroy.
//
// The frequency multipliers are bounded ABOVE by what the mesh can carry: a
// stream sizes its rows against the base ripple octave, so anything much past
// the second ripple octave at 2.317 would alias along the flow. Chop buys its
// detail across the channel, where the columns are, and not along it.
#define WATER_STREAM_CHOP_OCTAVES 2
const float WATER_STREAM_CHOP_FREQ_MUL[2] = {1.63, 1.19};
const float WATER_STREAM_CHOP_AMP_MUL[2] = {1.0, 0.7};
const float WATER_STREAM_CHOP_LAT_MUL[2] = {1.0, -0.79};
const float WATER_STREAM_CHOP_PHASE[2] = {0.0, 2.4};

// Froude interval the standing waves fade in over, above standing_froude_onset.
// A hard switch at the critical point would pop a whole reach into existence on
// a millimetre of bed edit.
const float WATER_STREAM_FROUDE_WIDTH = 0.35;

// Snap a frequency so a whole number of its cycles fits in water_time_period.
//
// The same constraint water_scroll() and flow_period document, and for the same
// reason: water_time WRAPS. A wave whose frequency does not divide the period is
// mid-cycle at the wrap and the whole river jumps. Floored at one cycle per
// period, since zero would stop the water dead.
//
// The standing waves need no equivalent: they do not read the clock at all, which
// is the one practical dividend of a wave that holds station.
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
// p_chan   : CUSTOM0 -- the channel data the two newer terms need.
//              .x signed lateral offset from the centreline, metres, measured along
//                 the LEFT of the flow direction (so it flips with flow_reverse and
//                 the shader never has to know the spline's own handedness);
//              .y stationary phase psi, radians, integrated from the head;
//              .z depth of water at this row, metres;
//              .w 1 where the mesh resolves this row's stationary wavelength, 0
//                 where it cannot. Baked, because it is a fact about the vertex
//                 spacing rather than a look setting -- see _standing_resolved().
WaveSample water_eval_stream_waves(vec3 p_pos, float p_tau, vec3 p_flow, float p_shore, vec4 p_chan) {
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
	// as a wave. Faded to nothing before it gets there. Applied to every term,
	// including the standing waves, for which it is the same argument.
	float shore_amp = 1.0 - smoothstep(ripple_bank_fade, 1.0, p_shore);

	float height = 0.0;
	// The two gradients accumulated alongside the height, so the normal costs no
	// second pass over the octaves. One per channel coordinate that has any: travel
	// time down the flow, and metres across it.
	float dh_dtau = 0.0;
	float dh_dlat = 0.0;

	// --- ripples: athwart the current, moving downstream (§10.2) ---------------
	float amp = ripple_amplitude * speed_amp * shore_amp;
	for (int i = 0; i < WATER_STREAM_OCTAVES; i++) {
		float f = water_stream_quantise(ripple_frequency * WATER_STREAM_FREQ_MUL[i]);
		float a = amp * WATER_STREAM_AMP_MUL[i];
		float w = WATER_TAU * f;
		float theta = w * (water_time - p_tau) + WATER_STREAM_PHASE[i];
		height += a * sin(theta);
		// d/dtau of a*sin(w*(t - tau)) = -a*w*cos(...)
		dh_dtau -= a * w * cos(theta);
	}

	// --- chop: oblique, moving downstream (§10.3) ------------------------------
	float chop_amp = chop_amplitude * speed_amp * shore_amp;
	float k_lat = WATER_TAU / max(chop_wavelength, 0.05);
	for (int i = 0; i < WATER_STREAM_CHOP_OCTAVES; i++) {
		float f = water_stream_quantise(ripple_frequency * WATER_STREAM_CHOP_FREQ_MUL[i]);
		float a = chop_amp * WATER_STREAM_CHOP_AMP_MUL[i];
		float w = WATER_TAU * f;
		float k = k_lat * WATER_STREAM_CHOP_LAT_MUL[i];
		float theta = w * (water_time - p_tau) + k * p_chan.x + WATER_STREAM_CHOP_PHASE[i];
		height += a * sin(theta);
		dh_dtau -= a * w * cos(theta);
		dh_dlat += a * k * cos(theta);
	}

	// --- standing waves: stationary, at shallows (§10.4) -----------------------
	//
	// Froude number, the ratio of the flow speed to the speed a disturbance can
	// travel in water that deep. Above 1 nothing can propagate back upstream, so a
	// wave pattern can hold station against the current; below it the pattern
	// washes away, which is why this and not an authored flag decides where rapids
	// are. The epsilon is for a bone-dry row, where the answer is "infinitely
	// supercritical" and the depth gate below is what actually rules.
	float depth = p_chan.z;
	float froude = speed / sqrt(max(WATER_GRAVITY * depth, 1e-4));
	float froude_gate = smoothstep(standing_froude_onset,
			standing_froude_onset + WATER_STREAM_FROUDE_WIDTH, froude);
	// Depth gate. A standing wave taller than the water it stands in would dip
	// through the bed, and at a ford that is centimetres deep it should be a
	// ripple over the gravel rather than a metre of swell.
	float depth_gate = clamp(depth / max(standing_depth_ref, 1e-3), 0.0, 1.0);
	float standing_amp = standing_amplitude * froude_gate * depth_gate * p_chan.w * shore_amp;
	height += standing_amp * sin(p_chan.y);
	// d(psi)/d(distance) is the local stationary wavenumber g/v^2 by construction,
	// so the slope needs no second coordinate -- it is the one place the pointwise
	// form IS correct, because it is a derivative and not an accumulation.
	float dpsi_ds = WATER_GRAVITY / max(speed * speed,
			WATER_STREAM_SPEED_FLOOR * WATER_STREAM_SPEED_FLOOR);
	float dh_ds_standing = standing_amp * cos(p_chan.y) * dpsi_ds;

	o.position.y += height;

	// Chain rule into world space. tau is travel time, so d(tau)/d(distance along
	// the channel) is 1/speed, and that gradient points along the flow direction.
	// The lateral gradient is already per metre and points across it.
	//
	// The floor on speed is doing real work: as the water slows, the wavelength
	// packs down toward zero and the true gradient diverges. The AMPLITUDE has
	// already gone to zero there by the speed gate above, so the surface is
	// correct; without the floor the NORMAL would still be computed from a
	// vanishing denominator and flicker on flat water.
	float dh_ds = dh_dtau / max(speed, WATER_STREAM_SPEED_FLOOR) + dh_ds_standing;
	vec2 side = vec2(-p_flow.y, p_flow.x);
	vec2 grad = dh_ds * p_flow.xy + dh_dlat * side;
	o.normal = normalize(vec3(-grad.x, 1.0, -grad.y));

	// Surface slope as the crest-steepness signal, in the same spirit as the
	// Gerstner jacobian: ~1 where the surface is as steep as it gets. The LENGTH of
	// the gradient and not the along-flow part alone, so that chop -- whose whole
	// contribution is across the channel -- is visible to it. The river variant
	// compiles no crest foam, so nothing reads this today; it is filled in rather
	// than left at zero so that enabling WATER_FOAM_CREST on a stream gets a
	// meaningful signal instead of a silently dead one.
	o.jacobian = clamp(length(grad), 0.0, 1.0);
	return o;
}

#endif // WATER_STREAM_INC
