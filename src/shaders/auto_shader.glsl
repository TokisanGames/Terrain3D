// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

R"(

//INSERT: AUTO_SHADER_UNIFORMS
uniform float auto_slope : hint_range(0, 10) = 1.0;
uniform float auto_height_reduction : hint_range(0, 1) = 0.1;
uniform int auto_base_texture : hint_range(0, 31) = 0;
uniform int auto_overlay_texture : hint_range(0, 31) = 1;

//INSERT: AUTO_SHADER
	// Enable Autoshader if outside regions or painted in regions, otherwise manual painted
	float auto_blend = clamp((auto_slope * 2. * ( w_normal.y - 1.) + 1.)
			- auto_height_reduction * .01 * v_vertex.y // Reduce as vertices get higher
			, 0., 1.);
	for (int i = 0; i < 4; i++) {
		if (index[i].z < 0 || DECODE_AUTO(control[i])) {
			data[i].texture_id[0] = auto_base_texture;
			data[i].texture_id[1] = auto_overlay_texture;
			data[i].blend = auto_blend;
		}
	}

)"