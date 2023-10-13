// Copyright © 2023 Cory Petkovsek, Roope Palmroos, and Contributors.

R"(

//INSERT: WORLD_NOISE1
// World Noise

uniform sampler2D region_blend_map : hint_default_black, filter_linear, repeat_disable;
uniform float noise_scale = 2.0;
uniform float noise_height = 300.0;
uniform float noise_blend_near = 0.5;
uniform float noise_blend_far = 1.0;

float hashv2(vec2 v) {
	return fract(1e4 * sin(17.0 * v.x + v.y * 0.1) * (0.1 + abs(sin(v.y * 13.0 + v.x))));
}

float noise2D(vec2 st) {
	vec2 i = floor(st);
	vec2 f = fract(st);

	// Four corners in 2D of a tile
	float a = hashv2(i);
	float b = hashv2(i + vec2(1.0, 0.0));
	float c = hashv2(i + vec2(0.0, 1.0));
	float d = hashv2(i + vec2(1.0, 1.0));

	// Cubic Hermine Curve.  Same as SmoothStep()
	vec2 u = f * f * (3.0 - 2.0 * f);

	// Mix 4 corners percentages
	return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

// World Noise end
//INSERT: WORLD_NOISE2
	// World Noise
	float weight = texture(region_blend_map, (uv/float(region_map_size))+0.5).r;
	float rmap_half_size = float(region_map_size)*.5;
	if(abs(uv.x) > rmap_half_size+.5 || abs(uv.y) > rmap_half_size+.5) {
		weight = 0.;
	} else {
		if(abs(uv.x) > rmap_half_size-.5) {
			weight = mix(weight, 0., abs(uv.x) - (rmap_half_size-.5));
		}
		if(abs(uv.y) > rmap_half_size-.5) {
			weight = mix(weight, 0., abs(uv.y) - (rmap_half_size-.5));
		}
	}
	height = mix(height, noise2D(uv * noise_scale) * noise_height,
		clamp(smoothstep(noise_blend_near, noise_blend_far, 1.0 - weight), 0.0, 1.0));
)"