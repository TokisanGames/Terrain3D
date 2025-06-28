// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

// These special inserts are injected into the shader code at the end of fragment().
// Variables should be prefaced with __ to avoid name conflicts.

R"(
//INSERT: OVERLAY_REGION_GRID
	// Show region grid
	{
		vec3 __pixel_pos = (INV_VIEW_MATRIX * vec4(VERTEX,1.0)).xyz;
		float __region_line = 1.0;		// Region line thickness
		__region_line *= .1*sqrt(length(_camera_pos - __pixel_pos));
		if (mod(__pixel_pos.x * _vertex_density + __region_line*.5, _region_size) <= __region_line || 
			mod(__pixel_pos.z * _vertex_density + __region_line*.5, _region_size) <= __region_line ) {
			ALBEDO = vec3(1.);
		}
	}

//INSERT: OVERLAY_INSTANCER_GRID
	// Show region grid
	{
		vec3 __pixel_pos = (INV_VIEW_MATRIX * vec4(VERTEX,1.0)).xyz;
		float __cell_line = 0.5;		// Cell line thickness
		__cell_line *= .1*sqrt(length(_camera_pos - __pixel_pos));
		#define CELL_SIZE 32
		if (mod(__pixel_pos.x * _vertex_density + __cell_line*.5, CELL_SIZE) <= __cell_line || 
			mod(__pixel_pos.z * _vertex_density + __cell_line*.5, CELL_SIZE) <= __cell_line ) {
			ALBEDO = vec3(.033);
		}
	}

//INSERT: OVERLAY_VERTEX_GRID
	// Show vertex grids
	{
		vec3 __pixel_pos = (INV_VIEW_MATRIX * vec4(VERTEX,1.0)).xyz;
		float __grid_line = 0.05;		// Vertex grid line thickness
		float __grid_step = 1.0;			// Vertex grid size, 1.0 == integer units
		float __vertex_size = 4.;		// Size of vertices
		float __view_distance = 300.0;	// Visible distance of grid
		vec3 __vertex_mul = vec3(0.);
		vec3 __vertex_add = vec3(0.);
		float __distance_factor = clamp(1.-length(_camera_pos - __pixel_pos)/__view_distance, 0., 1.);
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

//INSERT: OVERLAY_CONTOURS_SETUP
uniform float contour_interval: hint_range(0.25, 100.0, 0.001) = 1.0;
uniform float contour_thickness : hint_range(0.0, 10.0, 0.001) = 1.0;
uniform vec4 contour_color : source_color = vec4(.85, .85, .19, 1.);

float fractal_contour_lines(float thickness, float interval, vec3 spatial_coords, vec3 normal, vec3 base_ddx, vec3 base_ddy) {
    float depth = max(log(length(spatial_coords - _camera_pos) / interval) * (1.0 / log2(2.0)) - 1.0, 1.0);

    float interval_a = interval * exp2(max(floor(depth) - 1.0, 1.0)) * 0.5;
    float interval_b = interval * exp2(max(floor(depth), 1.0)) * 0.5;
    float interval_c = interval * exp2(max(floor(depth + 0.5) - 1.0, 1.0)) * 0.5;

    float y = spatial_coords.y;
    float y_fwidth = abs(base_ddx.y) + abs(base_ddy.y);

    thickness *= smoothstep(0., 0.0125, clamp(1.0 - normal.y, 0., 1.));
    float mi = max(0.0, thickness - 1.0);
    float ma = max(1.0, thickness);
    float mx = max(0.0, 1.0 - thickness);

    // Line A
    float inv_interval_a = 1.0 / interval_a;
    float f_a = abs(fract((y + interval_a * 0.5) * inv_interval_a) - 0.5);
    float df_a = y_fwidth * inv_interval_a;
    float line_a = clamp((f_a - df_a * mi) / (df_a * (ma - mi)), mx, 1.0);

    // Line B
    float inv_interval_b = 1.0 / interval_b;
    float f_b = abs(fract((y + interval_b * 0.5) * inv_interval_b) - 0.5);
    float df_b = y_fwidth * inv_interval_b;
    float line_b = clamp((f_b - df_b * mi) / (df_b * (ma - mi)), mx, 1.0);

    // Line C
    float inv_interval_c = 1.0 / interval_c;
    float f_c = abs(fract((y + interval_c * 0.5) * inv_interval_c) - 0.5);
    float df_c = y_fwidth * inv_interval_c;
    float line_c = clamp((f_c - df_c * mi) / (df_c * (ma - mi)), mx, 1.0);

    // Blend out
    float p = fract(depth - 0.5);
    float line = mix(mix(line_a, line_b, fract(depth)), line_c, (4.0 * p * (1.0 - p)));
    return line;
}

//INSERT: OVERLAY_CONTOURS_RENDER
	// Show contour lines
	{
		vec3 __pixel_pos = (INV_VIEW_MATRIX * vec4(VERTEX,1.0)).xyz;
		vec3 __base_ddx = dFdxCoarse(__pixel_pos);
		vec3 __base_ddy = dFdyCoarse(__pixel_pos);
		vec3 __w_normal = normalize(cross(__base_ddy, __base_ddx));
		float __line = fractal_contour_lines(contour_thickness, contour_interval, __pixel_pos, __w_normal, __base_ddx, __base_ddy);
		ALBEDO = mix(ALBEDO, contour_color.rgb, (1.-__line) * contour_color.a);
	}
)"