// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Pasture3D Water — the underwater screen effect. Spec §8.4.
//
// A canvas_item shader on a full-rect ColorRect, spawned by Pasture3DPool only while the active
// camera is below the wave surface. It does three things, and each of them reuses something the
// surface shader already has rather than introducing a second set of knobs:
//
//   1. TINT by the same Beer-Lambert term the surface uses for depth. `absorption` is fed straight
//      from the water material, so a pond whose surface reads brown-green does not turn blue the
//      moment you put your head under it.
//   2. WOBBLE by two scrolled samples of T_water_deriv.png -- the derivative map the surface shader
//      already keeps resident. Zero new VRAM (the guide's G3 budget stays at 384 KB), and the
//      ripple you see from below matches the one you saw from above.
//   3. VIGNETTE, because peripheral darkening is most of what reads as "submerged" and it costs a
//      single dot product.
//
// `amount` ramps 0..1 across the crossing rather than snapping, so surfacing is a transition and
// not a single-frame pop. Pasture3DPool drives it; nothing here is animated by water_time, because
// the overlay must behave identically whether or not a manager is in the scene.
shader_type canvas_item;
render_mode unshaded;

// Screen, as everything else has already drawn it.
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;

// The derivative map the surface shader uses for its detail normals. Only .rg is read.
uniform sampler2D detail_deriv : hint_default_black, repeat_enable, filter_linear;

// 0 = nothing, 1 = fully submerged. Ramped by Pasture3DPool across overlay_transition seconds.
uniform float amount : hint_range(0.0, 1.0) = 0.0;

// Per-metre extinction, from the water material's own `absorption`. Higher = murkier, faster.
uniform vec3 absorption = vec3(0.45, 0.22, 0.3);
// The material's `deep_color`, mixed in as the colour the view tends toward with depth.
uniform vec4 deep_color : source_color = vec4(0.03, 0.06, 0.05, 1.0);

// How many "metres" of water the full effect is worth. Not a real distance -- the overlay has no
// depth buffer to integrate -- it is the exponent's scale, and it is exported so a shallow pond and
// a deep lake can differ.
uniform float view_depth_scale : hint_range(0.0, 20.0) = 3.5;

// Screen-space amplitude of the wobble, in UV units, and how fast it scrolls.
uniform float wobble_strength : hint_range(0.0, 0.05) = 0.006;
uniform float wobble_scale : hint_range(0.1, 8.0) = 2.0;
uniform float wobble_speed : hint_range(0.0, 1.0) = 0.06;

// 0 = none, 1 = heavy edge darkening.
uniform float vignette : hint_range(0.0, 1.0) = 0.55;


void fragment() {
	// Two layers scrolling in different directions at different rates: one alone reads as the whole
	// screen sliding, which looks like a camera fault rather than like water.
	vec2 uv0 = SCREEN_UV * wobble_scale + vec2(TIME * wobble_speed, TIME * wobble_speed * 0.6);
	vec2 uv1 = SCREEN_UV * wobble_scale * 1.7 - vec2(TIME * wobble_speed * 0.8, TIME * wobble_speed * 0.35);
	vec2 wobble = (texture(detail_deriv, uv0).rg - 0.5) + (texture(detail_deriv, uv1).rg - 0.5);

	// Scaled by `amount` as well, so the distortion arrives with the tint instead of snapping on at
	// full strength the instant the ramp starts.
	vec2 uv = clamp(SCREEN_UV + wobble * wobble_strength * amount, vec2(0.0), vec2(1.0));
	vec3 scene = texture(screen_tex, uv).rgb;

	// The surface shader's depth term, applied to the whole view: what survives `view_depth_scale`
	// metres of this water. Red goes first in most water, which is why absorption is a vec3.
	vec3 transmit = exp(-absorption * view_depth_scale);
	vec3 tinted = mix(deep_color.rgb, scene * transmit, transmit);

	// Radial falloff from the screen centre. Squared so the darkening stays off the middle of the
	// frame and gathers at the corners.
	vec2 d = SCREEN_UV - vec2(0.5);
	float vig = 1.0 - vignette * clamp(dot(d, d) * 4.0, 0.0, 1.0);
	tinted *= mix(1.0, vig, amount);

	COLOR = vec4(mix(scene, tinted, amount), 1.0);
}
