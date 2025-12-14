// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

R"(

//INSERT: PROJECTION
	if (i_normal.y <= 0.7071067811865475) { // sqrt(0.5)
		// Projected normal map alignment matrix
		p_align = mat2(vec2(i_normal.z, -i_normal.x), vec2(i_normal.x, i_normal.z));
		// Fast 45 degree snapping https://iquilezles.org/articles/noatan/
		vec2 xz = round(normalize(-i_normal.xz) * 1.3065629648763765); // sqrt(1.0 + sqrt(0.5))
		xz *= abs(xz.x) + abs(xz.y) > 1.5 ? 0.7071067811865475 : 1.0; // sqrt(0.5)
		xz = vec2(-xz.y, xz.x);
		p_pos = floor(vec2(dot(i_pos, xz), -h));
		p_uv = vec2(dot(i_vertex.xz, xz), -i_vertex.y);
		#ifndef IS_DISPLACEMENT_BUFFER
		p_dd.xy = vec2(dot(base_ddx.xz, xz), -base_ddx.y);
		p_dd.zw = vec2(dot(base_ddy.xz, xz), -base_ddy.y);
		#endif
	}

)"
