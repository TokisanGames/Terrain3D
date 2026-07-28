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
uniform vec3 _water_domain_origin = vec3(0.0, 0.0, 0.0);
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
// Slope multiplier. 1.0 = the texture as authored (see tools/gen_water_textures.py:
// ~1.2 cm RMS ripples over a 10 m tile).
uniform float detail_strength : hint_range(0.0, 4.0, 0.01) = 1.0;
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

#endif // WATER_COMMON_INC
