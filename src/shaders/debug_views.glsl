R"(
//INSERT: DEBUG_GRID
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
	ALBEDO = index00.rgb;
	ROUGHNESS = 0.7;
	NORMAL_MAP = vec3(0.5, 0.5, 1.0);
)"