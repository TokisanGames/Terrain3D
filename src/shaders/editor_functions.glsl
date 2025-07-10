// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

// These special inserts are injected into the shader code at the end of fragment().

R"(
//INSERT: EDITOR_NAVIGATION
	// Show navigation
	{
		if(bool(floatBitsToUint(texelFetch(_control_maps, get_index_coord(floor(uv + 0.5), SKIP_PASS), 0)).r >>1u & 0x1u)) {
			ALBEDO *= vec3(.5, .0, .85);
		}
	}

//INSERT: EDITOR_DECAL_SETUP
uniform highp sampler2D _editor_brush_texture : source_color, filter_linear, repeat_disable;
uniform highp sampler2D _editor_ring_texture : source_color, filter_linear, repeat_disable;
uniform vec2 _editor_decal_position[3];
uniform float _editor_decal_size[3];
uniform float _editor_decal_rotation[3];
uniform vec4 _editor_decal_color[3] : source_color;
uniform bool _editor_decal_visible[3];
uniform float _editor_crosshair_threshold = 16.0;

// expects uv (Texture/world space 0 to +/- inf 1m units).
vec3 get_decal(vec3 albedo, vec2 uv) {
	for (int i = 0; i < 3; ++i) {
		if (!_editor_decal_visible[i]) {
			continue;
		}
		float size = 1.0 / _editor_decal_size[i];
		float cosa = cos(_editor_decal_rotation[i]);
		float sina = sin(_editor_decal_rotation[i]);
		vec2 decal_uv = (vec2(cosa * uv.x - sina * uv.y, sina * uv.x + cosa * uv.y) - 
			vec2(cosa * _editor_decal_position[i].x - sina * _editor_decal_position[i].y,
			sina * _editor_decal_position[i].x + cosa * _editor_decal_position[i].y) * _vertex_density) * size * _vertex_spacing;
		if (abs(decal_uv.x) > 0.499 || abs(decal_uv.y) > 0.499) {
			continue;
		}
		float decal = 0.0;
		switch (i) {
			case 0 :
				decal = texture(_editor_brush_texture, decal_uv + 0.5).r;
				break;
			case 1:
			case 2:
				decal = texture(_editor_ring_texture, decal_uv + 0.5).r;
				break;
		}
		// Blend in decal; square for better visual blend
		albedo =  mix(albedo, _editor_decal_color[i].rgb, decal * decal * _editor_decal_color[i].a);
	}

	// Crosshair
//	if (_editor_decal_visible[0] && _editor_decal_size[0] <= _editor_crosshair_threshold) {
//	}
	{

		float cam_dist = length(_camera_pos - v_vertex);
		float sq_cam_dist = sqrt(cam_dist);
		float view_scale = 16.0 / sq_cam_dist;
		vec2 cross_uv = (uv * _vertex_spacing - _editor_decal_position[0]) * view_scale;
		float brush_radius = max((_editor_decal_size[0] * 0.5) * view_scale, 1.);
		float line_start = brush_radius + log2(cam_dist);
		float line_end = 3. * line_start;
		float line_thickness = .03 * length(cross_uv) + .03 * sq_cam_dist;

		// Crosshair
		vec2 d = abs(cross_uv);
		float h = smoothstep(line_thickness, 0.0, d.y) * step(d.x, line_end) * step(line_start, d.x);
		float v = smoothstep(line_thickness, 0.0, d.x) * step(d.y, line_end) * step(line_start, d.y);
		float crosshair = h + v;

		// Circle
		float circle_thickness = 1.5; // Adjust for desired ring thickness
		float dist = length(cross_uv);
		h = smoothstep(brush_radius + line_thickness, brush_radius, dist);
		v = 1.0 - smoothstep(brush_radius, brush_radius - line_thickness, dist);
		float circle = h * v;

		float intensity = clamp(crosshair + circle, 0.0, 1.0);
		albedo = mix(albedo, _editor_decal_color[0].rgb, intensity * _editor_decal_color[0].a);
	}

	return albedo;
}

//INSERT: EDITOR_DECAL_RENDER
	// Render decal
	{
		ALBEDO = get_decal(ALBEDO, uv);
	}
)"