R"(

//INSERT: GRID
	// Display a checkered grid
	vec2 p = UV * 1.0; // scale
	vec2 ddx = dFdx(p);
	vec2 ddy = dFdy(p);
	vec2 w = max(abs(ddx), abs(ddy)) + 0.01;
	vec2 i = 2.0 * (abs(fract((p - 0.5 * w) / 2.0) - 0.5) - abs(fract((p + 0.5 * w) / 2.0) - 0.5)) / w;
	ALBEDO = vec3((0.5 - 0.5 * i.x * i.y) * 0.2 + 0.2);
	ROUGHNESS = 0.7;
	NORMAL_MAP = vec3(0.5f, 0.5f, 1.0f);
)"