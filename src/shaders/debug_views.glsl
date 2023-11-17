// Copyright © 2023 Cory Petkovsek, Roope Palmroos, and Contributors.

R"(
//INSERT: DEBUG_CHECKERED
	// Show a checkered grid
	vec2 p = UV * 1.0; // scale
	vec2 ddx = dFdx(p);
	vec2 ddy = dFdy(p);
	vec2 w = max(abs(ddx), abs(ddy)) + 0.01;
	vec2 i = 2.0 * (abs(fract((p - 0.5 * w) / 2.0) - 0.5) - abs(fract((p + 0.5 * w) / 2.0) - 0.5)) / w;
	ALBEDO = vec3((0.5 - 0.5 * i.x * i.y) * 0.2 + 0.2);
	ROUGHNESS = 0.7;
	NORMAL_MAP = vec3(0.5, 0.5, 1.0);

//INSERT: DEBUG_GREY
	// Show all grey
	ALBEDO = vec3(0.3);
	ROUGHNESS = 0.7;
	NORMAL_MAP = vec3(0.5, 0.5, 1.0);

//INSERT: DEBUG_HEIGHTMAP
	// Show heightmap
	ALBEDO = vec3(smoothstep(-0.1, 2.0, 0.5 + get_height(UV2)/300.0));
	ROUGHNESS = 0.7;
	NORMAL_MAP = vec3(0.5, 0.5, 1.0);

//INSERT: DEBUG_COLORMAP
	// Show colormap
	ALBEDO = color_map.rgb;
	ROUGHNESS = 0.7;
	NORMAL_MAP = vec3(0.5, 0.5, 1.0);

//INSERT: DEBUG_ROUGHMAP
	// Show roughness map
	ALBEDO = vec3(color_map.a);
	ROUGHNESS = 0.7;
	NORMAL_MAP = vec3(0.5, 0.5, 1.0);

//INSERT: DEBUG_CONTROL_TEXTURE
	// Show control map texture selection
	float ctrl_base = weight_inv * (
	float(mat[0].base) * weights.x +
	float(mat[1].base) * weights.y +
	float(mat[2].base) * weights.z +
	float(mat[3].base) * weights.w )/96.;
	float ctrl_over = weight_inv * (
	float(mat[0].over) * weights.x +
	float(mat[1].over) * weights.y +
	float(mat[2].over) * weights.z +
	float(mat[3].over) * weights.w )/96.;
	ALBEDO = vec3(ctrl_base, ctrl_over, 0.);
	ROUGHNESS = 0.9;
	NORMAL_MAP = vec3(0.5, 0.5, 1.0);

//INSERT: DEBUG_CONTROL_BLEND
	// Show control map blend values
	float ctrl_blend = weight_inv * (
	float(mat[0].blend) * weights.x +
	float(mat[1].blend) * weights.y +
	float(mat[2].blend) * weights.z +
	float(mat[3].blend) * weights.w );
	ALBEDO = vec3(ctrl_blend);
	ROUGHNESS = 1.0;
	NORMAL_MAP = vec3(0.5, 0.5, 1.0);

//INSERT: DEBUG_AUTOSHADER
	float autoshader = float(control00 & 0x1u);
	ALBEDO = vec3(autoshader);

//INSERT: DEBUG_HOLES
	float holes = float(control00 >>2u & 0x1u);
	ALBEDO = vec3(holes);

//INSERT: DEBUG_NAVIGATION
	float navigation = float(control00 >>1u & 0x1u);
	ALBEDO = vec3(navigation);

//INSERT: DEBUG_TEXTURE_HEIGHT
	// Show height textures
	ALBEDO = vec3(albedo_height.a);
	ROUGHNESS = 0.7;
	NORMAL_MAP = vec3(0.5, 0.5, 1.0);

//INSERT: DEBUG_TEXTURE_NORMAL
	// Show normal map textures
	ALBEDO = normal_rough.rgb;
	ROUGHNESS = 0.7;
	NORMAL_MAP = vec3(0.5, 0.5, 1.0);

//INSERT: DEBUG_TEXTURE_ROUGHNESS
	// Show roughness textures
	ALBEDO = vec3(normal_rough.a);
	ROUGHNESS = 0.7;
	NORMAL_MAP = vec3(0.5, 0.5, 1.0);

//INSERT: DEBUG_VERTEX_GRID
	// Show region and vertex grids
	vec3 _camera_pos = INV_VIEW_MATRIX[3].xyz;
	vec3 _pixel_pos = (INV_VIEW_MATRIX * vec4(VERTEX,1.0)).xyz;
	float _camera_dist = length(_camera_pos - _pixel_pos);
	float _region_line = 0.5;		// Region line thickness
	float _grid_line = 0.05;		// Vertex grid line thickness
	float _grid_step = 1.0;			// Vertex grid size, 1.0 == integer units
	float _vertex_size = 4.;		// Size of vertices
	float _view_distance = 100.0;	// Visible distance of grid
	// Draw region grid
	_region_line = .1*sqrt(_camera_dist);
	if (mod(_pixel_pos.x + _region_line*.5, _region_size) <= _region_line || 
		mod(_pixel_pos.z + _region_line*.5, _region_size) <= _region_line ) {
		ALBEDO = vec3(1.);
	}
	if ( _camera_dist < _view_distance ) {
		// Draw vertex grid
		if ( mod(_pixel_pos.x + _grid_line*.5, _grid_step) < _grid_line || 
		  	 mod(_pixel_pos.z + _grid_line*.5, _grid_step) < _grid_line ) { 
				ALBEDO *= vec3(0.5);
		}

		// Draw Vertices
		if ( mod(UV.x + _grid_line*_vertex_size*.5, _grid_step) < _grid_line*_vertex_size &&
		  	 mod(UV.y + _grid_line*_vertex_size*.5, _grid_step) < _grid_line*_vertex_size ) { 
				ALBEDO += vec3(0.15);
		}
	}
)"