// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// These special inserts are injected into the shader code at the end of fragment().
// Variables should be prefaced with __ to avoid name conflicts.

R"(
//INSERT: OVERLAY_INSTANCER_GRID
	// Show instancer grid
	{
		vec3 __grid_color = vec3(.05);
		float __line_thickness = 0.01 * sqrt(-VERTEX.z) * _vertex_density;
		vec3 __pixel_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz * _vertex_density;
		vec2 __p = __pixel_pos.xz;
		// Instancer Grid
		#define CELL_SIZE 32.0
		vec2 __g = abs(fract((__p + CELL_SIZE * 0.5) / CELL_SIZE) - 0.5) * CELL_SIZE;
		float __grid_d = min(__g.x, __g.y);
		float __grid_mask = 1.0 - smoothstep(__line_thickness - fwidth(__grid_d), __line_thickness + fwidth(__grid_d), __grid_d);
		// Clip Grid outside regions
		__grid_mask *= float(clamp(get_index_coord(__pixel_pos.xz - 0.5).z + 1, 0, 1));
		ALBEDO = mix(ALBEDO, __grid_mask * __grid_color, __grid_mask);
	}

//INSERT: OVERLAY_VERTEX_GRID
	// Show vertex grid
	{
		vec3 __pixel_pos = (INV_VIEW_MATRIX * vec4(VERTEX,1.0)).xyz;
		vec3 __camera_pos = INV_VIEW_MATRIX[3].xyz;
		float __grid_line = 0.05;		// Vertex grid line thickness
		float __grid_step = 1.0;			// Vertex grid size, 1.0 == integer units
		float __vertex_size = 4.;		// Size of vertices
		float __view_distance = 300.0;	// Visible distance of grid
		vec3 __vertex_mul = vec3(0.);
		vec3 __vertex_add = vec3(0.);
		float __distance_factor = clamp(1.-length(__camera_pos - __pixel_pos)/__view_distance, 0., 1.);
		// Draw vertex grid
		if ( mod(__pixel_pos.x * _vertex_density + __grid_line*.5, __grid_step) < __grid_line || 
	  		 mod(__pixel_pos.z * _vertex_density + __grid_line*.5, __grid_step) < __grid_line ) { 
			__vertex_mul = vec3(0.5) * __distance_factor;
		}
		// Draw Vertices
		if ( mod(UV.x + __grid_line*__vertex_size*.5, __grid_step) < __grid_line*__vertex_size &&
	  		 mod(UV.y + __grid_line*__vertex_size*.5, __grid_step) < __grid_line*__vertex_size ) { 
			__vertex_add = vec3(0.15) * __distance_factor;
		}
		ALBEDO = fma(ALBEDO, 1.-__vertex_mul, __vertex_add);
	}

//INSERT: OVERLAY_SLOPE_SETUP
group_uniforms slope_colorizer;
uniform float slope_angle_low : hint_range(0.0, 90.0, 0.1) = 15.0;
uniform float slope_angle_high : hint_range(0.0, 90.0, 0.1) = 45.0;
uniform vec4 slope_color_mid : source_color = vec4(1.0, .835, 0.0, 1.0);
uniform vec4 slope_color_high : source_color = vec4(1.0, 0.0, 0.0, 1.0);
uniform float slope_softness : hint_range(0.1, 30.0, 0.1) = 12.0;
group_uniforms;

//INSERT: OVERLAY_SLOPE_RENDER
	// Show Slope Colorizer Overlay
	{
		float __slope_deg = degrees(acos(clamp(w_normal.y, -1.0, 1.0)));
		float __intensity = smoothstep(
			slope_angle_low - slope_softness * 0.5,
			slope_angle_low + slope_softness * 0.5,
			__slope_deg
		);
		float __color_ramp = smoothstep(
			slope_angle_high - slope_softness * 0.5,
			slope_angle_high + slope_softness * 0.5,
			__slope_deg
		);
		vec3 __slope_col = mix(slope_color_mid.rgb, slope_color_high.rgb, __color_ramp);
		float __slope_str = mix(slope_color_mid.a, slope_color_high.a, __color_ramp) * __intensity;
		ALBEDO *= mix(vec3(1.0), __slope_col, __slope_str);
	}

//INSERT: OVERLAY_CONTOURS_SETUP
group_uniforms contour_lines;
uniform vec4 contour_color : source_color = vec4(0., 0., 0., .8);
uniform bool contour_thermal_color = false;
uniform vec2 contour_thermal_heights = vec2(-200, 200);
uniform float contour_far_opacity : hint_range(0.0, .333, 0.001) = 0.08;
uniform float contour_index_interval : hint_range(10.0, 500.0, 1.0) = 100.0;
uniform float contour_index_dist  : hint_range(1024.0, 100000.0, 1.0) = 8192.0;
uniform float contour_index_thickness : hint_range(0.0, 8.0, 0.001) = 2.;
uniform float contour_inter_dist  : hint_range(200.0, 10000.0, 1.0) = 1536.0;
uniform float contour_inter_thickness : hint_range(0.0, 4.0, 0.001) = 1.2;
uniform float contour_half_dist  : hint_range(100.0, 5000.0, 1.0) = 512.0;
uniform float contour_half_thickness  : hint_range(0.0, 4.0, 0.001) = 1.2;
group_uniforms;

// Single interval anti-aliased contour (returns ~0 on line, ~1 off line)
float single_contour(float thickness, float interval, float y, float y_fwidth, float dist, vec3 w_normal) {
	// Soft distance fall-off for thickness
	// Near is full thickness, far is reduced opacity, which prevents distant major lines looking too thick
	float dist_mod = mix(1.0, contour_far_opacity, smoothstep(80.0, contour_index_dist*.5, dist));
	thickness *= dist_mod;

	// Don't draw on perfectly flat slopes
	thickness *= step(0.0000001, 1.0 - w_normal.y);

	float mi = max(0.0, thickness - 1.0);
	float ma = max(1.0, thickness);
	float mx = max(0.0, 1.0 - thickness);
	float inv = 1.0 / interval;
	float f = abs(fract((y + interval * 0.5) * inv) - 0.5);
	float df = y_fwidth * inv;
	return clamp((f - df * mi) / (df * (ma - mi) + 1e-8), mx, 1.0);
}

// Distance-based opacity with a minimum floor
float contour_opacity(float dist, float fade_start, float fade_end, float min_op, float max_op) {
	float t = smoothstep(fade_end, fade_start, dist); // 1 near → 0 far
	return mix(min_op, max_op, t);
}

vec3 contour_thermal(float t) {
	t = clamp(t, 0.0, 1.0);
	// Blue → cyan → green → yellow → orange gradient
	return mix(
		mix(vec3(0.0, 0.1, 0.8), vec3(0.0, 0.9, 0.9), smoothstep(0.0, 0.35, t)),
		mix(vec3(0.1, 0.9, 0.1), vec3(1.0, 0.9, 0.0), smoothstep(0.35, 0.7, t)),
		smoothstep(0.35, 0.7, t)
	) * (1.0 - smoothstep(0.7, 1.0, t))
	+ vec3(1.0, 0.2, 0.0) * smoothstep(0.7, 1.0, t);
}

//INSERT: OVERLAY_CONTOURS_RENDER
	// Show contour lines
	{
		float __y_fwidth = abs(base_ddx.y) + abs(base_ddy.y);
		float __pixel_dist = length(v_vertex - v_camera_pos);

		float __index_line = single_contour(contour_index_thickness, contour_index_interval, v_vertex.y, __y_fwidth, __pixel_dist, w_normal);
		float __inter_line  = single_contour(contour_inter_thickness, contour_index_interval * .2, v_vertex.y, __y_fwidth, __pixel_dist, w_normal);
		float __half_line  = single_contour(contour_half_thickness, contour_index_interval * .1, v_vertex.y, __y_fwidth, __pixel_dist, w_normal);

		float __inter_op  = contour_opacity(__pixel_dist, contour_half_dist,  contour_inter_dist,  0., 1.);
		float __half_op  = contour_opacity(__pixel_dist, 0., contour_half_dist, 0., 0.8);
		float __contrib = max(max(
			(1.0 - __index_line),
			(1.0 - __inter_line)  * __inter_op),
			(1.0 - __half_line)  * __half_op);

		vec3 __line_col = contour_color.rgb;
		if (contour_thermal_color) {
			float __h = clamp(
				(v_vertex.y - contour_thermal_heights.x) / (contour_thermal_heights.y - contour_thermal_heights.x + 1e-5),
				0.0, 1.0
			);
			__line_col = contour_thermal(__h);
		}

		ALBEDO = mix(ALBEDO, __line_col, __contrib * contour_color.a);
	}

)"