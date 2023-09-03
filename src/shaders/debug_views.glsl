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
	ALBEDO = color_tex.rgb;
	ROUGHNESS = 0.7;
	NORMAL_MAP = vec3(0.5, 0.5, 1.0);

//INSERT: DEBUG_ROUGHMAP
	// Show roughness map
	ALBEDO = vec3(color_tex.a);
	ROUGHNESS = 0.7;
	NORMAL_MAP = vec3(0.5, 0.5, 1.0);

//INSERT: DEBUG_CONTROLMAP
	// Show control map
	index00.rg *= 8.;	// Since there are only 32 colors, emphasize change between each one
	ALBEDO = index00.rgb;
	ROUGHNESS = 0.7;
	NORMAL_MAP = vec3(0.5, 0.5, 1.0);

//INSERT: DEBUG_TEXTURE_HEIGHT
	// Show height textures
	ALBEDO = vec3(color.a);
	ROUGHNESS = 0.7;
	NORMAL_MAP = vec3(0.5, 0.5, 1.0);

//INSERT: DEBUG_TEXTURE_NORMAL
	// Show normal map textures
	ALBEDO = normal.rgb;
	ROUGHNESS = 0.7;
	NORMAL_MAP = vec3(0.5, 0.5, 1.0);

//INSERT: DEBUG_TEXTURE_ROUGHNESS
	// Show roughness textures
	ALBEDO = vec3(normal.a);
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
	if (mod(_pixel_pos.x + region_size*.5 + _region_line*.5, region_size) <= _region_line || 
		mod(_pixel_pos.z + region_size*.5 + _region_line*.5, region_size) <= _region_line ) {
		ALBEDO = vec3(1.);
	}
	if ( _camera_dist < _view_distance ) {
		// Draw vertex grid
		if ( mod(_pixel_pos.x + _grid_line*.5, _grid_step) < _grid_line || 
		  	 mod(_pixel_pos.z + _grid_line*.5, _grid_step) < _grid_line ) { 
				ALBEDO *= vec3(0.5);
		}

		// Draw Vertices
		if ( mod(UV.x*2. + _grid_line*_vertex_size*.5, _grid_step) < _grid_line*_vertex_size &&
		  	 mod(UV.y*2. + _grid_line*_vertex_size*.5, _grid_step) < _grid_line*_vertex_size ) { 
				ALBEDO += vec3(0.15);
		}
	}
)"