// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.
// This shader snippet draws a hex grid

// To use it, add this line to the top of your shader:
// #include "res://addons/terrain_3d/extras/shaders/hex_grid.gdshaderinc"

// And this line at the bottom of your shader:
// 	draw_hex_grid(uv2, _region_texel_size, w_normal, ALBEDO);

mat2 rotate2d(float _angle) {
	return mat2(vec2(cos(_angle),-sin(_angle)), vec2(sin(_angle), cos(_angle)));
}

void draw_hex_grid(vec2 uv, float texel_size, vec3 normal, inout vec3 albedo) {
	float hex_size = 0.02;
	float line_thickness = 0.04;

	vec2 guv = (uv - vec2(0.5 * texel_size)) / hex_size;

	// Convert UV to axial hex coordinates
	float q = (sqrt(3.0) / 3.0 * guv.x - 1.0 / 3.0 * guv.y);
	float r = (2.0 / 3.0 * guv.y);

	// Cube coordinates for the hex (q, r, -q-r)
	float x = q;
	float z = r;
	float y = -x - z;

	// Round to the nearest hex center
	vec3 rounded = round(vec3(x, y, z));
	vec3 diff = abs(vec3(x, y, z) - rounded);

	// Fix rounding errors
	if (diff.x > diff.y && diff.x > diff.z) {
		rounded.x = -rounded.y - rounded.z;
	} else if (diff.y > diff.z) {
		rounded.y = -rounded.x - rounded.z;
	} else {
		rounded.z = -rounded.x - rounded.y;
	}

	// Find the hex center in UV space
	vec2 hex_center = vec2(
	    sqrt(3.0) * rounded.x + sqrt(3.0) / 2.0 * rounded.z,
	    3.0 / 2.0 * rounded.z
    );

	// Relative position within the hex
	vec2 local_pos = guv - hex_center;
	vec2 lines_uv = local_pos;
	float line = 1.0;

	for (int i = 0; i < 6; i++) {
		vec2 luv = lines_uv * rotate2d(radians(60.0 * float(i) + 30.0));
		float dist = abs(dot(luv + vec2(0.90), vec2(0.0, 1.0)));
		line = min(line, dist);
	}

	// Filter lines by slope
	float slope = 4.; // Can also assign to (auto_slope * 4.) to match grass placement
	float slope_factor = clamp(dot(vec3(0., 1., 0.), slope * (normal - 1.) + 1.), 0., 1.);

	// Draw hex grid
	albedo = mix(albedo, vec3(1.0), smoothstep(line_thickness + 0.02, line_thickness, line) * slope_factor);
	// Draw Hex center dot
	albedo = mix(albedo, vec3(0.0, 0.5, 0.5), smoothstep(0.11, 0.10, length(local_pos)) * slope_factor);
}