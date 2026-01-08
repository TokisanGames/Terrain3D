// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

// These special inserts are injected into the shader code at the end of fragment().

R"(
//INSERT: EDITOR_NAVIGATION
	// Show navigation
	{
		if(bool(floatBitsToUint(texelFetch(_control_maps, get_index_coord(floor(uv + 0.5)), 0)).r >>1u & 0x1u)) {
			ALBEDO *= vec3(.5, .0, .85);
		}
	}

//INSERT: EDITOR_REGION_GRID
	// Show region grid
	{
		vec3 __pixel_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz * _vertex_density;
		float __line = 0.1 * sqrt(-VERTEX.z);
		vec2 __p = __pixel_pos.xz;
		// Region Grid
		vec2 __g = abs(fract((__p + _region_size * 0.5) / _region_size) - 0.5) * _region_size;
		float __grid_d = min(__g.x, __g.y);
		float __grid_mask = 1.0 - smoothstep(__line - fwidth(__grid_d), __line + fwidth(__grid_d), __grid_d);
		// Region Map Boundry
		float __hmap = _region_size * 16.0;
		vec2 __bp = abs(__p) - __hmap;
		float __box_d = abs(max(__bp.x, __bp.y));
		float __box_mask = 1.0 - smoothstep( __line - fwidth(__box_d), __line + fwidth(__box_d), __box_d);
		// Clip Grid at Boundary
		float __b_line = __hmap - __line - fwidth(__box_d);
		__grid_mask *= step(abs(__p.x), __b_line) * step(abs(__p.y), __b_line);
		vec3 __grid_color = mix(vec3(1.0, 0.1, 0.1), vec3(1.0), float(clamp(get_index_coord(__pixel_pos.xz - 0.5).z + 1, 0, 1)));
		ALBEDO = mix(ALBEDO, __grid_mask * __grid_color + __box_mask * vec3(0.0, 0.0, 1.0), max(__grid_mask, __box_mask));
	}

//INSERT: EDITOR_DECAL_SETUP
uniform highp sampler2D _editor_brush_texture : source_color, filter_linear, repeat_disable;
uniform vec2 _editor_decal_position[3];
uniform float _editor_decal_size[3];
uniform float _editor_decal_rotation[3];
uniform vec4 _editor_decal_color[3] : source_color;
uniform bool _editor_decal_visible[3]; // show decal: brush, slope point1, point2
uniform bool _editor_decal_part[2]; // show decal[0] component: texture, reticle

float get_reticle(vec2 uv, int index) {
	float cam_dist = clamp(length(v_camera_pos - v_vertex), 0., 4000.);
	float sq_cam_dist = sqrt(cam_dist);
	float view_scale = 16.0 / sq_cam_dist;
	vec2 cross_uv = (uv * _vertex_spacing - _editor_decal_position[index]) * view_scale;
	float brush_radius = max((_editor_decal_size[index] * 0.5) * view_scale, 1.);
	float line_start = brush_radius + log2(cam_dist);
	float line_end = 2.5 * line_start;
	float line_thickness = .03 * length(cross_uv) + .03 * sq_cam_dist; // flanged lines + distant thickness

	float cursor = 0.;
	float h, v;

	// Crosshair
	vec2 d = abs(cross_uv);
	h = smoothstep(line_thickness, 0.0, d.y) * step(d.x, line_end) * step(line_start, d.x);
	v = smoothstep(line_thickness, 0.0, d.x) * step(d.y, line_end) * step(line_start, d.y);
	cursor = h + v;

	// Circle
	float dist = length(cross_uv);
	h = smoothstep(brush_radius + line_thickness, brush_radius, dist);
	v = 1.0 - smoothstep(brush_radius, brush_radius - line_thickness, dist);
	cursor += h * v;

	return clamp(cursor, 0.0, 1.0);
}

// Expects uv (Texture/world space 0 to +/- inf 1m units).
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

		float decal = 0.0;
        if (i == 0 && abs(decal_uv.x) <= 0.499 && abs(decal_uv.y) <= 0.499 && _editor_decal_part[0]) {
            decal = texture(_editor_brush_texture, decal_uv + 0.5).r;
        }
		if (_editor_decal_part[1]) {
			decal += get_reticle(uv, i);
		}
		// Blend in decal; square for better visual blend
        albedo = mix(albedo, _editor_decal_color[i].rgb, decal * decal * _editor_decal_color[i].a);
	}
	return albedo;
}

//INSERT: EDITOR_DECAL_RENDER
	// Render decal
	{
		ALBEDO = get_decal(ALBEDO, uv);
	}
)"