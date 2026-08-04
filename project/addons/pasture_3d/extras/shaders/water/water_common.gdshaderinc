// Pasture3D Water — shared declarations.
// Spec: PASTURE3D_WATER_SHADER_SPEC.md §2.1
//
// Included first by every water .gdshader wrapper. Owns feature defaults, the
// plugin-driven globals, all artist uniforms, and the vertex->fragment varyings.
// Contains no entry points.

#ifndef WATER_COMMON_INC
#define WATER_COMMON_INC

// ---------------------------------------------------------------------------
// Feature defaults. Wrappers override by #define-ing before the include.
// ---------------------------------------------------------------------------
#ifndef WATER_WAVE_COUNT
#define WATER_WAVE_COUNT 4
#endif

// Upper bound on WATER_WAVE_COUNT. Fixes the size of the uploaded wave table so
// every variant takes the same one. Raising it costs 16 bytes per slot in every
// water material and requires a matching change in water_waves.cpp.
#define WATER_MAX_WAVES 8

// ---------------------------------------------------------------------------
// Globals, owned by the plugin (spec §2.3).
//
// These MUST exist in the RenderingServer global table before any water
// material is loaded, or Godot warns "used global parameter ... was removed at
// some point" and the material renders black until it recompiles.
//
// Declared in project.godot [shader_globals] by the editor plugin (persisted,
// takes effect at startup), with a runtime global_shader_parameter_add()
// fallback for projects where the settings were never written. Phase 1 probes
// proved a runtime-only ProjectSettings.set_setting() does NOT register them.
// ---------------------------------------------------------------------------
global uniform float water_time;
// Points FROM the surface TOWARD the sun (the light's +Z basis column), so
// water_sun_direction.y > 0 means daytime. Matches the legacy shader's
// _light_direction convention.
global uniform vec3 water_sun_direction;
global uniform vec3 water_sun_color;
// The period water_time wraps at. The clock alone is not enough: anything that
// advances with it has to land on a whole number of its own cycles at the wrap
// or the seam the waves do not have is one the detail texture does. See
// water_scroll() below.
global uniform float water_time_period;

// ---------------------------------------------------------------------------
// Artist uniforms
// ---------------------------------------------------------------------------
group_uniforms body;
// Absorption coefficient per metre, per channel. This is the knob that turns an
// ocean into a lake into a pond (spec §3.5).
uniform vec3 absorption = vec3(0.35, 0.08, 0.05);
uniform vec3 deep_color : source_color = vec3(0.015, 0.05, 0.08);
#ifdef WATER_CLIPMAP
uniform float sea_level : hint_range(-500.0, 500.0, 0.01) = 0.0;
#endif
group_uniforms;

group_uniforms waves;
// (dir.x, dir.z, amplitude, wavelength) per wave. Generated in C++ so the CPU
// height query reads the identical table (spec §4.2, §4.3).
//
//
// Always declared at WATER_MAX_WAVES regardless of how many the variant reads.
// The C++ generator then has exactly one upload shape to produce and never has
// to discover a variant's array size to match it -- a negotiation with no good
// answer, since Godot gives no clean way to read a shader's declared array
// length back. Costs 128 bytes of uniform buffer in the worst case.
uniform vec4 _waves[WATER_MAX_WAVES];

// Compile-time fallback table, used when nothing has uploaded one (detected as
// a zero amplitude sum). G6 says the material must work dropped on a bare
// MeshInstance3D, and in that case no C++ ever runs -- without this the user
// gets a flat plane and no indication why.
//
// It has to be a `const` array and not a uniform default, because Godot rejects
// default values on uniform arrays outright ("Setting default values to uniform
// arrays is not supported"). An initialiser must name exactly WATER_WAVE_COUNT
// entries, hence one block per supported count. The amplitude sums are
// #define-d rather than summed at runtime because they are compile-time
// constants and folding them saves a loop.
//
// Directions are scattered around +X; wavelengths follow a geometric series;
// amplitudes are proportional to wavelength, which is what keeps steepness
// roughly uniform across the series.
#if WATER_WAVE_COUNT == 8
const vec4 _wave_defaults[8] = vec4[8]( // ocean
	vec4(1.000, 0.000, 1.64, 137.0),
	vec4(0.951, -0.309, 1.16, 97.0),
	vec4(0.978, 0.208, 0.82, 68.0),
	vec4(0.906, -0.423, 0.58, 48.0),
	vec4(0.927, 0.375, 0.41, 34.0),
	vec4(0.990, -0.139, 0.29, 24.0),
	vec4(0.883, 0.469, 0.20, 17.0),
	vec4(0.966, -0.259, 0.14, 12.0));
#define WATER_DEFAULT_SUM_AMP 5.24
#elif WATER_WAVE_COUNT == 4
const vec4 _wave_defaults[4] = vec4[4]( // lake
	vec4(1.000, 0.000, 0.42, 60.0),
	vec4(0.951, -0.309, 0.25, 36.0),
	vec4(0.970, 0.242, 0.15, 21.0),
	vec4(0.899, -0.438, 0.09, 13.0));
#define WATER_DEFAULT_SUM_AMP 0.91
#elif WATER_WAVE_COUNT == 2
const vec4 _wave_defaults[2] = vec4[2]( // pond
	vec4(1.000, 0.000, 0.090, 18.0),
	vec4(0.940, 0.342, 0.050, 11.0));
#define WATER_DEFAULT_SUM_AMP 0.14
#else
#define WATER_NO_DEFAULT_WAVES
#endif
uniform float wave_steepness : hint_range(0.0, 0.6, 0.01) = 0.35;

// Keeps phase arguments small and precise for bodies far from the origin (§3.1).
//
// PER INSTANCE, not per material (WATER_BODIES_SPEC §5.4). Pasture3DPoolManager hands the
// same material to every body sharing a (base material, wave profile) pair, so ten
// ponds cost one material and one _waves upload -- but each of those ponds sits
// somewhere different, and a domain origin stored on the material would force them
// all to share one. An instance uniform is the only per-body channel Godot offers
// that a shared material survives; it is also the ONLY thing here that can be one,
// since instance uniforms take scalars and vectors and not arrays, which is why
// _waves above can never be one and why the material cache is keyed on the profile
// at all.
//
// Written with MeshInstance3D.set_instance_shader_parameter(), or
// RenderingServer.instance_geometry_set_shader_parameter() for the ocean clipmap's
// instances. material.set_shader_parameter() no longer reaches it -- anything that
// used to set it that way now sets nothing and silently gets vec3(0).
//
// Instance uniforms are a spatial-shader feature. bench/water_parity_probe.gdshader
// includes this file from a canvas_item shader, where the declaration is a compile
// error, so it opts out and drives the origin as an ordinary uniform instead. That
// probe tests the wave arithmetic, which the origin only shifts the input of.
#ifdef WATER_PLAIN_DOMAIN_ORIGIN
uniform vec3 _water_domain_origin = vec3(0.0, 0.0, 0.0);
#else
instance uniform vec3 _water_domain_origin = vec3(0.0, 0.0, 0.0);
#endif
group_uniforms;

group_uniforms surface;
uniform float base_roughness : hint_range(0.0, 1.0, 0.001) = 0.06;
uniform float specular_amount : hint_range(0.0, 1.0, 0.01) = 0.5;
// Toksvig in spirit (§3.4): normal detail the distance fade removed is converted
// into roughness rather than discarded, so the specular lobe widens by exactly
// as much as the geometry it stood for was smoothed away. Lowering roughness to
// make distant water look sharper is what CAUSES the shimmer, not what fixes it.
uniform float variance_to_roughness : hint_range(0.0, 2.0, 0.01) = 0.55;
group_uniforms;

#ifdef WATER_DETAIL
group_uniforms detail;
// (dh/dx, dh/dz) in RG, NOT a normal map -- derivatives compose by addition, so
// two scrolled layers and the Gerstner slope combine with two adds and need no
// TBN, no whiteout blend and no cross products (§3.3).
//
// hint_normal is a lie about the content and deliberate: it is the only hint
// whose fallback texture is (0.5, 0.5, ...), which is the neutral value here.
// hint_default_white would tilt every pixel by a full unit of slope on a
// material that had not been given a texture, which is exactly the bare
// MeshInstance3D case G6 promises works.
// Number of scrolled detail layers. Two is what breaks up the tile; one is the
// low-end escape hatch. Priced in §8.4.
#ifndef WATER_DETAIL_LAYERS
#define WATER_DETAIL_LAYERS 2
#endif

#ifdef WATER_DETAIL_TRILINEAR
// Plain trilinear instead of anisotropic. Anisotropy is what keeps a grazing
// water plane sharp into the distance, and the footprint is at its most elongated
// exactly where the most pixels are, so this is where it should cost the most.
//
// On an RTX 3070 it measured EXACTLY the same either way (§8.4), so this is not
// the desktop win it looks like. Kept as a knob rather than deleted because
// anisotropy on an RDNA2 iGPU is not the same instruction it is here, and Phase 5
// has a Steam Deck to measure it on.
uniform sampler2D detail_deriv : hint_normal, filter_linear_mipmap, repeat_enable;
#else
uniform sampler2D detail_deriv : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
#endif
// Slope multiplier, in units of the texture's FULL SCALE -- not in m/m, and not
// "the texture as authored", which is what this comment used to claim and what
// the 1.0 default was chosen to mean.
//
// The generator computes a real derivative in m/m and then normalises it by its
// own 99.5th percentile before quantising, and that divisor is printed and thrown
// away (tools/gen_water_textures.py). So the stored value is a FRACTION of full
// scale, and reproducing the authored slope needs the divisor back:
//
//   full scale        0.422 m/m     <- authored, from the generator
//   stored rms        0.277         <- per layer, measured off the shipped PNG
//   authored rms      0.117 m/m     <- 0.277 * 0.422
//
// At the old default of 1.0 the two summed layers reached an rms slope of 0.39
// with excursions past 2.0: normals tilted far enough to point the reflection
// vector BELOW the horizon, which is why the ocean picked up the sky's brown
// ground hemisphere as rust-coloured speckle. The same number also feeds
// variance_to_roughness, so distant water was getting +0.55 roughness and going
// out as flat grey slabs. One uniform, wrong at both ends of the distance range.
//
// 0.25 gives ~0.10 rms slope over both layers, which is the right order for
// wind-ruffled water at the sub-10 m scale the Gerstner table does not cover
// (§3.1 floors it at 10 m). Pinned by Phase 5 gate E, which asserts the composed
// slope numerically and uses 1.0 as the control that must fail.
uniform float detail_strength : hint_range(0.0, 4.0, 0.01) = 0.25;
// Tiles per metre. The two are deliberately non-harmonic: at a simple ratio the
// layers re-align at a fixed period and the eye finds the tile immediately.
uniform float detail_scale0 : hint_range(0.001, 1.0, 0.001) = 0.1;
uniform float detail_scale1 : hint_range(0.001, 1.0, 0.001) = 0.0345;
// Advection in metres per second, world space.
uniform vec2 detail_flow0 = vec2(0.32, 0.11);
uniform vec2 detail_flow1 = vec2(-0.17, 0.26);
// Detail amplitude ramps to zero across this range, so distant water settles
// onto the smooth swell normal. A distance ramp rather than fwidth: cheaper, and
// unlike fwidth it does not misbehave across the clipmap's LOD seams.
uniform float detail_fade_start : hint_range(0.0, 2000.0, 1.0) = 200.0;
uniform float detail_fade_end : hint_range(0.0, 4000.0, 1.0) = 800.0;
group_uniforms;
#endif

#ifdef WATER_FLOW
// ---------------------------------------------------------------------------
// Flow (spec §10). River variant only.
// ---------------------------------------------------------------------------
//
// The detail layers advect along a PER-VERTEX direction carried in ARRAY_COLOR
// instead of the fixed detail_flow0/1 vectors, so the surface texture runs with
// the channel through every bend.
//
// A plain scroll along a direction that varies per vertex shears the texture at
// every bend and keeps shearing, without bound. The fix is the standard flow-map
// scheme: two copies of the layer, offset by half a period each and cross-faded
// on the same period, so the distortion is reset before it becomes visible. Two
// extra fetches from a texture already in cache.
group_uniforms flow;
// Seconds per advection cycle. Distortion grows for this long, then the
// cross-fade hands over to a fresh copy. Longer = more coherent motion but more
// visible smearing at the end of each cycle.
uniform float flow_period : hint_range(0.5, 20.0, 0.1) = 4.0;
// Metres per second at ARRAY_COLOR.b == 1. The mesh writes a NORMALISED speed, so
// this is the reference the normalisation was against and the two must agree --
// Pasture3DPool writes b = speed / FLOW_SPEED_REF with the same 8.0.
uniform float flow_speed_scale : hint_range(0.0, 20.0, 0.1) = 8.0;
// Quantise flow_period so a whole number of cycles fits in water_time_period.
//
// Without this the cross-fade is mid-hand-over when water_time wraps and the
// surface visibly jumps, exactly as an unquantised scroll rate does -- the same
// constraint water_scroll() documents, applied to a second clock. Exposed rather
// than hardcoded so the seam can be demonstrated: the Phase 7 gate turns it off
// as its control and requires the seam to appear.
uniform bool flow_quantise = true;
group_uniforms;
#endif

#ifdef WATER_STREAM_WAVES
// ---------------------------------------------------------------------------
// Stream ripples (spec §10.2). Replaces the Gerstner table on a river.
//
// See water_stream.gdshaderinc for why a river cannot use _waves[] at all. These
// four are the whole surface: everything that varies BETWEEN reaches -- how fast
// the water is running, how steep, how near the bank -- is already per-vertex in
// the mesh, so the material only has to say how much ripple a given speed earns.
// That is why they are material uniforms and not a per-river profile.
// ---------------------------------------------------------------------------
group_uniforms ripples;
// Crest-to-trough amplitude at full speed, in metres, before the bank fade.
// Centimetres, not metres: this is chop on a channel, not swell on a sea.
uniform float ripple_amplitude : hint_range(0.0, 1.0, 0.005) = 0.06;
// Cycles per second the surface bobs at a fixed point. NOT a wavelength -- the
// wavelength is a consequence, and varies along the river, because frequency is
// what steady flow conserves. Quantised against water_time_period at evaluation.
//
// LOW ON PURPOSE. At the shipped 1.5 m/s this is a 5 m undulation, and raising it
// is expensive in a way the number does not show: wavelength is speed/frequency,
// the mesh has to resolve it, so doubling this halves the vertex spacing a stream
// chooses and quadruples its vertex count. The first draft shipped 0.9 and turned
// a 200 m river into 33k vertices for chop nobody could see.
//
// The fine detail is NOT missing from the surface -- it is in the detail normal
// map, which already advects along the same per-vertex flow (WATER_FLOW above).
// This is the part that has to be geometry because it moves the silhouette and
// floats boats; anything smaller is the texture's job and costs nothing.
uniform float ripple_frequency : hint_range(0.05, 2.0, 0.01) = 0.3;
// Flow speed (m/s) at which ripples reach full amplitude. Below it they scale
// down linearly, so a river slowing into a pool goes glassy on its own.
uniform float ripple_speed_ref : hint_range(0.1, 10.0, 0.1) = 2.0;
// Fraction of the half-width at which the bank fade starts. 1 = no fade, and a
// rim of crests standing over the dry bank; lower pulls the calm margin inward.
uniform float ripple_bank_fade : hint_range(0.0, 1.0, 0.01) = 0.55;
group_uniforms;

// ---------------------------------------------------------------------------
// Cross-channel chop (spec §10.3).
//
// The ripples above are a function of travel time ALONE, so every point on a
// cross-section is at the same height and the river reads as a rolling carpet.
// These are the term that varies ACROSS the channel: two oblique octaves whose
// crests meet at an angle and interfere into the diamond lattice moving water
// actually shows.
//
// COSTS COLUMNS, NOT ROWS. Its along-flow structure is deliberately no finer
// than the ripples already carry, so the only thing it makes the mesher spend
// more of is samples ACROSS the strip -- which is the cheap axis, because a
// river is long and narrow. Set chop_amplitude to 0 and the stream stops asking
// for them entirely and goes back to the column count it had before.
// ---------------------------------------------------------------------------
group_uniforms chop;
// Crest-to-trough amplitude in metres, at full speed, mid-channel. Gated by the
// same speed and bank fades as the ripples, so chop dies in a pool and at the
// waterline without a second set of knobs.
//
// ZERO IS A SUPPORTED SETTING and not merely a quiet one: it is what tells
// Pasture3DStream it may drop back to square cells. See _column_spacing().
uniform float chop_amplitude : hint_range(0.0, 1.0, 0.005) = 0.03;
// Distance between chop crests measured ACROSS the channel, in metres. This is
// the number that sets the mesh's column spacing -- a stream samples it about
// six times per wavelength -- so halving it roughly doubles the vertex count.
uniform float chop_wavelength : hint_range(0.25, 20.0, 0.05) = 2.5;
group_uniforms;

// ---------------------------------------------------------------------------
// Standing waves at shallows (spec §10.4).
//
// The stationary undulations downstream of a ford or a chute. Unlike everything
// else on this surface they DO NOT MOVE: their phase is a function of position
// along the channel and of nothing else, so they sit still in the world while
// the water runs through them. That is what a standing wave is.
//
// They appear on their own, wherever the flow goes supercritical -- Froude
// number v / sqrt(g*d) above 1 -- and the mesh already carries per-row depth and
// speed, so nobody authors where. Raise the bed toward the surface and the reach
// grows rapids; deepen it and they go away.
// ---------------------------------------------------------------------------
group_uniforms standing;
// Crest-to-trough amplitude in metres at standing_depth_ref of water. Scaled
// down in shallower water, because a wave taller than the river is not a wave.
uniform float standing_amplitude : hint_range(0.0, 2.0, 0.005) = 0.12;
// Froude number the undulations start at. 1.0 is the physical critical point --
// below it a disturbance can travel back upstream and no standing pattern can
// hold. Shipped slightly under, because a river at Fr 0.95 is already ruffled
// and the transition looks abrupt if it begins exactly at the textbook value.
uniform float standing_froude_onset : hint_range(0.4, 2.5, 0.01) = 0.9;
// Depth in metres at which standing waves reach standing_amplitude. Also the
// scale over which they fade out as a reach dries: at zero depth there is no
// water to stand up, whatever the Froude number says.
uniform float standing_depth_ref : hint_range(0.05, 5.0, 0.01) = 1.0;
group_uniforms;
#endif

#ifdef WATER_DEPTH_FADE
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
#endif

#if defined(WATER_FOAM_CREST) || defined(WATER_FOAM_SHORE)
group_uniforms foam;
uniform sampler2D foam_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec3 foam_color : source_color = vec3(0.85, 0.89, 0.92);
uniform float foam_scale : hint_range(0.001, 1.0, 0.001) = 0.07;
// Foam is a scattering layer sitting on the water, so it must raise roughness.
// The legacy shader tinted albedo only, which gives you mirror-smooth foam.
uniform float foam_roughness : hint_range(0.0, 1.0, 0.01) = 0.8;
#ifdef WATER_FOAM_CREST
// Fraction of the breaking limit at which whitecaps start. v_jacobian is in
// fold-limit units and therefore never exceeds wave_steepness, so a threshold
// above that value means no foam at all -- which is the correct answer for calm
// water and the reason this is not normalised (see water_surface.gdshaderinc).
// 0.2 against the default steepness of 0.35 puts the onset near 2 sigma of the
// crest distribution: a few percent of the surface, which is what a moderate sea
// looks like.
uniform float foam_crest_threshold : hint_range(0.0, 1.0, 0.01) = 0.2;
// Width of the ramp from first foam to full foam, in the same units. Without it
// the ramp would have to end at 1.0 -- unreachable at any usable steepness, so
// foam could never reach full opacity anywhere.
uniform float foam_crest_softness : hint_range(0.01, 1.0, 0.01) = 0.1;
uniform float foam_crest_amount : hint_range(0.0, 2.0, 0.01) = 1.0;
#endif
#ifdef WATER_FOAM_SHORE
// Metres of water below which shore foam appears.
uniform float foam_shore_depth : hint_range(0.0, 20.0, 0.05) = 1.2;
uniform float foam_shore_amount : hint_range(0.0, 2.0, 0.01) = 0.8;
#endif
group_uniforms;
#endif

#ifdef WATER_SCATTER
group_uniforms scatter;
uniform vec3 scatter_color : source_color = vec3(0.06, 0.35, 0.28);
// Gated on the raw crest signal, which peaks at wave_steepness rather than 1.0,
// so this default is roughly 3x what it would be against a normalised signal.
// The upside is that scattering strengthens with the sea state on its own.
uniform float scatter_strength : hint_range(0.0, 8.0, 0.01) = 3.5;
group_uniforms;
#endif

// Clipmap plumbing, written by Pasture3DMesher. Only exists for the ocean.
#ifdef WATER_CLIPMAP
group_uniforms private_set_by_terrain;
uniform float _mesh_size = 32.0;
uniform float _subdiv = 1.0;
uniform float _vertex_spacing = 1.0;
uniform vec3 _target_pos = vec3(0.0, 0.0, 0.0);
group_uniforms;
#endif

// ---------------------------------------------------------------------------
// Varyings
// ---------------------------------------------------------------------------
varying vec3 v_world_pos;
varying vec3 v_wave_normal; // world space, from the analytic Gerstner sum
varying float v_jacobian;   // crest-steepness signal, drives whitecaps (§3.1)
varying float v_view_dist;
// The UNDISPLACED height of the sheet: sea_level for the clipmap, the mesh's own
// y for a plain MeshInstance3D. Carried so the fragment stage can ask "is the
// camera under the water" without knowing which of those two it is.
//
// Needed because the two-sided flip cannot be decided from FRONT_FACING alone.
// Water is depth_draw_never, so it does not occlude itself, and cull_disabled
// therefore rasterises the far side of every wave crest -- fragments a solid
// surface would have hidden. Flipping those gave them a downward normal and they
// shaded as dark dashes across the mid-distance (§8.6). The flip is only ever
// right when the VIEWER is underneath, which is a property of the camera, not of
// the triangle.
varying float v_base_y;

#ifdef WATER_FLOW
// Per-vertex flow, decoded from ARRAY_COLOR in the vertex stage: xy is the
// normalised XZ direction the water runs, z is speed normalised against
// flow_speed_scale. A loop pool writes a neutral colour, so its flow is a zero
// vector and the river shader degrades to a still surface rather than misbehaving.
varying vec3 v_flow;
#endif

#ifdef WATER_STREAM_WAVES
// Distance from the centreline as a fraction of this row's half-width: 0 mid
// channel, 1 on the waterline. Carried in ARRAY_COLOR.a, which the flow encoding
// left unused. Interpolated, so the bank fade is smooth across the strip rather
// than stepping per column.
varying float v_shore;
#endif

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// Rec.709 luminance. Used to collapse the per-channel transmittance into the one
// scalar alpha the blend hardware has (§3.5).
const vec3 WATER_LUMA = vec3(0.2126, 0.7152, 0.0722);

// Schlick fresnel for water (F0 = 0.02), unrolled -- never pow().
float water_fresnel(float n_dot_v) {
	float m = clamp(1.0 - n_dot_v, 0.0, 1.0);
	float m2 = m * m;
	return 0.02 + 0.98 * (m2 * m2 * m);
}

/**
 * UV offset for something scrolling at p_uv_per_second, snapped to the clock loop.
 *
 * water_time wraps at water_time_period, and §3.2 makes that seamless for the
 * waves by quantising their frequencies. A scrolling texture needs the same
 * treatment or it teleports at the wrap: the offset has to be a whole number of
 * tiles when t reaches the period. Rounding the CYCLE COUNT and dividing back out
 * is what does it -- the rate moves by at most half a tile per loop, which at the
 * default 120 s is under half a percent.
 *
 * A rate slow enough that it completes less than half a tile per loop rounds to
 * zero and stops. That is the honest outcome: such a layer cannot both scroll and
 * loop, and a frozen layer is less wrong than a jumping one.
 */
vec2 water_scroll(vec2 p_uv_per_second) {
	float period = max(water_time_period, 1e-3);
	return round(p_uv_per_second * period) * (water_time / period);
}

#ifdef WATER_FLOW
/**
 * The flow cycle length actually used, snapped so a whole number of cycles fits
 * in water_time_period.
 *
 * Same problem and same fix as water_scroll() above, one clock down: the flow
 * cross-fade has its own period, and if that period does not divide the wave
 * clock's then the hand-over is caught mid-way when water_time wraps and the
 * whole surface jumps. Rounding the CYCLE COUNT and dividing back out moves the
 * period by at most half a cycle -- at the default 4 s in 120 s, under 2%.
 *
 * Clamped to at least one cycle: a flow period longer than the whole loop cannot
 * both advect and loop, and freezing is less wrong than jumping.
 */
float water_flow_period() {
	if (!flow_quantise) {
		return max(flow_period, 1e-3);
	}
	float clock = max(water_time_period, 1e-3);
	float cycles = max(round(clock / max(flow_period, 1e-3)), 1.0);
	return clock / cycles;
}
#endif

#endif // WATER_COMMON_INC
