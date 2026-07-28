// Pasture3D Water — fragment stage.
// Spec: PASTURE3D_WATER_SHADER_SPEC.md §3.3-§3.7
//
// Budget (§5): zero sin/cos, zero integer multiplies, zero mat4 products, one
// normalize, four texture fetches. Everything expensive happens per vertex.
//
// The normal is assembled in the SLOPE domain, not by blending normal vectors:
// dh/dx and dh/dz add, so the Gerstner slope and two scrolled detail layers
// combine with two adds and one normalize at the end. That is the entire reason
// the detail texture is a derivative map and not a normal map.

#ifndef WATER_SHADING_INC
#define WATER_SHADING_INC

void fragment() {
#ifdef WATER_DEBUG_GLOBALS
	// Diagnostic: writes the three plugin-driven globals straight to ALBEDO so
	// the global-uniform plumbing can be verified in isolation, at any phase,
	// without needing waves or textures to be implemented. Used by the Phase 1
	// gate (bench/WaterPhase1Gate.gd) and worth keeping for future regressions.
	//
	// This is an #else and not an early `return` because Godot's shader language
	// rejects `return` inside fragment()/vertex() outright.
	ALBEDO = vec3(
		clamp(water_time, 0.0, 1.0),
		clamp(water_sun_color.g, 0.0, 1.0),
		clamp(water_sun_direction.y * 0.5 + 0.5, 0.0, 1.0));
	ALPHA = 1.0;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
#elif defined(WATER_DEBUG_SURFACE)
	// Diagnostic: the wave function itself, with the shading taken out of the
	// way. EMISSION passes through the light loop untouched, and a black ALBEDO
	// with zero SPECULAR contributes nothing, so this is unshaded without
	// needing a render_mode the wrappers would have to opt into.
	//
	// This exists because a shaded diff is the wrong instrument for comparing
	// two tessellations of the same surface: water is near-mirror, so a normal
	// difference far too small to see becomes a saturated specular pixel, and
	// the metric ends up measuring highlight placement rather than geometry.
	ALBEDO = vec3(0.0);
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
	ALPHA = 1.0;
	vec3 dbg_n = normalize(v_wave_normal);
	EMISSION = vec3(
		dbg_n.x * 0.5 + 0.5,
		dbg_n.z * 0.5 + 0.5,
		clamp(v_world_pos.y * (1.0 / 8.0) + 0.5, 0.0, 1.0));
#else

	vec2 domain = v_world_pos.xz - _water_domain_origin.xz;

	// Gerstner normal back into the slope domain. v_wave_normal always points up
	// -- the flip for the underwater view happens after detail is added, because
	// an inverted normal would put the divide below on the wrong side of zero.
	vec3 wave_normal = normalize(v_wave_normal);
	vec2 slope = -wave_normal.xz / max(wave_normal.y, 1e-3);

	// Detail amplitude the distance fade removed. Fed to roughness below so the
	// energy is redistributed rather than thrown away (§3.4).
	float detail_lost = 0.0;

#ifdef WATER_DETAIL
	float detail_fade = 1.0 - clamp(
		(v_view_dist - detail_fade_start) / max(detail_fade_end - detail_fade_start, 1e-3),
		0.0, 1.0);

	// Two fetches from ONE texture: same mip chain, same cache lines, and the
	// second layer costs little more than the first. Mip filtering is the
	// anti-aliasing here -- hardware trilinear is a correct prefilter, which is
	// what the legacy shader's widened finite-difference stencil never was.
	vec2 uv0 = domain * detail_scale0 - water_scroll(detail_flow0 * detail_scale0);
	vec2 detail = texture(detail_deriv, uv0).rg * 2.0 - 1.0;
#if WATER_DETAIL_LAYERS > 1
	vec2 uv1 = domain * detail_scale1 - water_scroll(detail_flow1 * detail_scale1);
	detail += texture(detail_deriv, uv1).rg * 2.0 - 1.0;
#endif

	slope += detail * (detail_strength * detail_fade);
	detail_lost = detail_strength * (1.0 - detail_fade);
#endif

	vec3 world_normal = normalize(vec3(-slope.x, 1.0, -slope.y));
	// Water is a two-sided sheet (render_mode cull_disabled): flip for the
	// underwater view. The legacy shader was cull_back and simply vanished from
	// below, while still testing for a submerged camera.
	//
	// Keyed on the CAMERA, not on FRONT_FACING, and the difference is visible.
	// depth_draw_never means the water does not occlude itself, so cull_disabled
	// rasterises the back side of every wave crest -- fragments that a solid
	// surface would have hidden behind the crest in front of them. Those are
	// !FRONT_FACING while the viewer is plainly above the water, and flipping them
	// pointed their normal at the ground: they shaded as dark dashes scattered
	// across the mid-distance at grazing pitches, which is what the Phase 5 A/B
	// captures showed (§8.6).
	//
	// Which side the viewer is on is a property of the camera and cannot be read
	// off one triangle. v_base_y is the undisplaced sheet -- sea_level, or the
	// mesh's own height -- so this stays correct for a plain MeshInstance3D that
	// has no sea_level uniform at all.
	if (CAMERA_POSITION_WORLD.y < v_base_y) {
		world_normal = -world_normal;
	}

	NORMAL = normalize(mat3(VIEW_MATRIX) * world_normal);

	float n_dot_v = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fresnel = water_fresnel(n_dot_v);

	vec3 albedo = deep_color;
	// Opacity from absorption alone, before fresnel. Opaque unless the depth
	// path says otherwise, which is the right default: with no way to know what
	// is behind, showing it would be a guess.
	float absorb_alpha = 1.0;
	float thickness = 0.0;

#ifdef WATER_DEPTH_FADE
	float raw_depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	// Scalar linear-depth reconstruction (§3.5). Only view-space z is wanted, and
	// four scalars of the inverse projection give it: 2 mul, 2 add, 1 divide
	// against the legacy shader's two full mat4 chains. Phase 2 gate G measured
	// this exactly equal to the mat4 path over 186k pixels under reversed-Z.
	float scene_vz = (INV_PROJECTION_MATRIX[2][2] * raw_depth + INV_PROJECTION_MATRIX[3][2])
		/ (INV_PROJECTION_MATRIX[2][3] * raw_depth + INV_PROJECTION_MATRIX[3][3]);
	// View space looks down -Z, so both are negative and the farther one is more
	// so. VERTEX is the water surface. No world-space reconstruction, and no
	// sea_level in sight -- the legacy shader added it twice (§9.1).
	thickness = max(0.0, VERTEX.z - scene_vz);

	// Beer-Lambert, per channel. This is the ocean/lake/pond knob (§3.5): the
	// three presets differ mainly in how fast and how selectively they absorb.
	vec3 transmit = exp(-absorption * thickness);

	// Fixed-function alpha blending has ONE scalar destination factor, so the
	// per-channel filtering of the background cannot be done without a backbuffer
	// copy -- and avoiding that copy is the whole point of WATER_REFRACTION being
	// off by default. What is done instead: pick the scalar alpha from luminance,
	// then solve for the albedo that makes the water's OWN contribution exact per
	// channel. Deep water lands on deep_color exactly, shallow water lands on the
	// background almost untinted, and the approximation is confined to mid
	// depths, where it shows as a colour blended toward the water rather than a
	// background filtered by it. Visually close; physically not the same thing,
	// so it is written down rather than glossed.
	absorb_alpha = 1.0 - dot(transmit, WATER_LUMA);
	albedo = min(deep_color * (vec3(1.0) - transmit) / max(absorb_alpha, 1e-3), vec3(1.0));
#endif

	// Reflection replaces transmission: light bounced off the surface did not
	// come from behind it, so opacity has to rise with fresnel. This is the other
	// half of the Phase 1 horizon artefact -- alpha already rose at grazing
	// incidence, but with no reflection term to put in the sky's place the
	// brightest pixels on the surface went opaque and dark (§8.3).
	float alpha = absorb_alpha + (1.0 - absorb_alpha) * fresnel;

	float roughness = clamp(base_roughness + detail_lost * variance_to_roughness, 0.02, 0.35);

#if defined(WATER_FOAM_CREST) || defined(WATER_FOAM_SHORE)
	float foam = 0.0;
#ifdef WATER_FOAM_CREST
	// Free: the Jacobian was already summed inside the wave loop, and it is
	// literally "how close is this crest to breaking" rather than the legacy
	// shader's height threshold, which foamed the tops of calm swells too.
	//
	// The ramp ends at threshold + softness, not at 1.0: v_jacobian is bounded by
	// wave_steepness (~0.35), so a ramp to 1.0 would keep foam permanently in its
	// first few percent and no whitecap would ever reach full opacity.
	foam += smoothstep(foam_crest_threshold,
		foam_crest_threshold + foam_crest_softness, v_jacobian) * foam_crest_amount;
#endif
#if defined(WATER_FOAM_SHORE) && defined(WATER_DEPTH_FADE)
	// Also free: thickness came out of the depth fetch above.
	foam += (1.0 - smoothstep(0.0, foam_shore_depth, thickness)) * foam_shore_amount;
#endif
	foam = clamp(foam, 0.0, 1.0) * texture(foam_tex,
		domain * foam_scale - water_scroll(detail_flow0 * foam_scale)).r;

	albedo = mix(albedo, foam_color, foam);
	roughness = mix(roughness, foam_roughness, foam);
	alpha = mix(alpha, 1.0, foam);
#endif

	ALBEDO = albedo;
	SPECULAR = specular_amount;
	ROUGHNESS = roughness;
	ALPHA = alpha;

#ifdef WATER_SCATTER
	// One backlight term, against the legacy shader's three pow() calls and a
	// three-term accumulation for an effect the specular largely swamps.
	//
	// water_sun_direction points toward the sun, so light travelling into the
	// camera -- the sun on the far side of the wave -- is a negative dot. Squared
	// to tighten it to the near-into-the-sun view where the effect actually
	// exists. Gated on the crest signal because that is where the water is thin
	// enough to transmit, and because that signal carries the sea state: raw
	// v_jacobian peaks at wave_steepness, so calm water scatters less on its own.
	vec3 to_camera = normalize(CAMERA_POSITION_WORLD - v_world_pos);
	float backlit = clamp(-dot(water_sun_direction, to_camera), 0.0, 1.0);
	BACKLIGHT = scatter_color *
		(scatter_strength * clamp(v_jacobian, 0.0, 1.0) * backlit * backlit);
#endif

#endif // WATER_DEBUG_GLOBALS
}

#endif // WATER_SHADING_INC
