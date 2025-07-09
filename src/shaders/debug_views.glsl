// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

// These special inserts are injected into the shader code at the end of fragment().
// Variables should be prefaced with __ to avoid name conflicts.

R"(
//INSERT: DEBUG_CHECKERED
	// Show a checkered grid
	{
		vec2 __p = uv * 1.0; // scale
		vec2 __ddx = dFdx(__p);
		vec2 __ddy = dFdy(__p);
		vec2 __w = max(abs(__ddx), abs(__ddy)) + 0.01;
		vec2 __i = 2.0 * (abs(fract((__p - 0.5 * __w) / 2.0) - 0.5) - abs(fract((__p + 0.5 * __w) / 2.0) - 0.5)) / __w;
		ALBEDO = vec3((0.5 - 0.5 * __i.x * __i.y) * 0.2 + 0.2);
		ROUGHNESS = 0.7;
		SPECULAR = 0.;
		NORMAL_MAP = vec3(0.5, 0.5, 1.0);
		AO = 1.0;
	}

//INSERT: DEBUG_GREY
	// Show all grey
	{
		ALBEDO = vec3(0.2);
		ROUGHNESS = 0.7;
		SPECULAR = 0.;
		NORMAL_MAP = vec3(0.5, 0.5, 1.0);
		AO = 1.0;
	}

//INSERT: DEBUG_HEIGHTMAP_SETUP
group_uniforms debug_heightmap;
uniform float heightmap_black_height: hint_range(-2048.,2048.,.5) = -100.0;
uniform float heightmap_white_height: hint_range(-2048.,2048.,.5) = 300.0;
group_uniforms;

//INSERT: DEBUG_HEIGHTMAP
	// Show heightmap
	{
		float __lo = min(heightmap_black_height, heightmap_white_height);
		float __hi = max(heightmap_black_height, heightmap_white_height);
		float __factor = clamp((v_vertex.y - __lo) / max(__hi - __lo, 1e-6), 0.0, 1.0);
		__factor = mix(__factor, 1.0 - __factor, float(heightmap_white_height < heightmap_black_height));
		ALBEDO = vec3(smoothstep(0.0, 1.0, __factor));
		ROUGHNESS = 0.7;
		SPECULAR = 0.;
		NORMAL_MAP = vec3(0.5, 0.5, 1.0);
		AO = 1.0;
	}

//INSERT: DEBUG_JAGGEDNESS
	// Show turbulent areas of the terrain surface
	{
		const vec3 __offsets = vec3(0, 1, 2);
		vec2 __index_id = floor((INV_VIEW_MATRIX * vec4(VERTEX,1.0)).xz);
		float __h[6];
		__h[0] = texelFetch(_height_maps, get_index_coord(__index_id + __offsets.xy, FRAGMENT_PASS), 0).r;
		__h[1] = texelFetch(_height_maps, get_index_coord(__index_id + __offsets.yy, FRAGMENT_PASS), 0).r;
		__h[2] = texelFetch(_height_maps, get_index_coord(__index_id + __offsets.yx, FRAGMENT_PASS), 0).r;
		__h[3] = texelFetch(_height_maps, get_index_coord(__index_id + __offsets.xx, FRAGMENT_PASS), 0).r;
		__h[4] = texelFetch(_height_maps, get_index_coord(__index_id + __offsets.zx, FRAGMENT_PASS), 0).r;
		__h[5] = texelFetch(_height_maps, get_index_coord(__index_id + __offsets.xz, FRAGMENT_PASS), 0).r;

		vec3 __normal[3];
		__normal[0] = normalize(vec3(__h[0] - __h[1], _vertex_spacing, __h[0] - __h[5]));
		__normal[1] = normalize(vec3(__h[2] - __h[4], _vertex_spacing, __h[2] - __h[1]));
		__normal[2] = normalize(vec3(__h[3] - __h[2], _vertex_spacing, __h[3] - __h[0]));

		float __jaggedness = max(length(__normal[2] - __normal[1]),length(__normal[2] - __normal[0]));
		ALBEDO = vec3(0.01 + pow(__jaggedness, 8.));
		ROUGHNESS = 0.7;
		SPECULAR = 0.;
		NORMAL_MAP = vec3(0.5, 0.5, 1.0);
		AO = 1.0;
	}

//INSERT: DEBUG_AUTOSHADER
	// Show where autoshader enabled
	{
		ivec3 __ruv = get_index_coord(floor(uv), SKIP_PASS);
		uint __control = floatBitsToUint(texelFetch(_control_maps, __ruv, 0).r);
		float __autoshader = float( bool(__control & 0x1u) || __ruv.z<0 );
		ALBEDO = vec3(__autoshader);
		ROUGHNESS = 1.;
		SPECULAR = 0.;
		NORMAL_MAP = vec3(0.5, 0.5, 1.0);
		AO = 1.0;
	}

//INSERT: DEBUG_CONTROL_TEXTURE
	// Show control map texture selection
	{
		vec3 __t_colors[32];
		__t_colors[0] = vec3(1.0, 0.0, 0.0);
		__t_colors[1] = vec3(0.0, 1.0, 0.0);
		__t_colors[2] = vec3(0.0, 0.0, 1.0);
		__t_colors[3] = vec3(1.0, 0.0, 1.0);
		__t_colors[4] = vec3(0.0, 1.0, 1.0);
		__t_colors[5] = vec3(1.0, 1.0, 0.0);
		__t_colors[6] = vec3(0.2, 0.0, 0.0);
		__t_colors[7] = vec3(0.0, 0.2, 0.0);
		__t_colors[8] = vec3(0.0, 0.0, 0.35);
		__t_colors[9] = vec3(0.2, 0.0, 0.2);
		__t_colors[10] = vec3(0.0, 0.2, 0.2);
		__t_colors[11] = vec3(0.2, 0.2, 0.0);
		__t_colors[12] = vec3(0.1, 0.0, 0.0);
		__t_colors[13] = vec3(0.0, 0.1, 0.0);
		__t_colors[14] = vec3(0.0, 0.0, 0.15);
		__t_colors[15] = vec3(0.1, 0.0, 0.1);
		__t_colors[16] = vec3(0.0, 0.1, 0.1);
		__t_colors[17] = vec3(0.1, 0.1, 0.0);
		__t_colors[18] = vec3(0.2, 0.05, 0.05);
		__t_colors[19] = vec3(0.1, 0.3, 0.1);
		__t_colors[20] = vec3(0.05, 0.05, 0.2);
		__t_colors[21] = vec3(0.1, 0.05, 0.2);
		__t_colors[22] = vec3(0.05, 0.15, 0.2);
		__t_colors[23] = vec3(0.2, 0.2, 0.1);
		__t_colors[24] = vec3(1.0);
		__t_colors[25] = vec3(0.5);
		__t_colors[26] = vec3(0.35);
		__t_colors[27] = vec3(0.25);
		__t_colors[28] = vec3(0.15);
		__t_colors[29] = vec3(0.1);
		__t_colors[30] = vec3(0.05);
		__t_colors[31] = vec3(0.0125);
		ivec3 __uv = get_index_coord(floor(uv), SKIP_PASS);
		uint __control = floatBitsToUint(texelFetch(_control_maps, __uv, 0).r);
		vec3 __ctrl_base = __t_colors[int(__control >> 27u & 0x1Fu)];
		vec3 __ctrl_over = __t_colors[int(__control >> 22u & 0x1Fu)];
		float __blend = float(__control >> 14u & 0xFFu) * 0.003921568627450; // 1.0/255.0
		float base_over = (length(fract(uv) - 0.5) < fma(__blend, 0.45, 0.1) ? 1.0 : 0.0);
		ALBEDO = mix(__ctrl_base, __ctrl_over, base_over);	
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		NORMAL_MAP = vec3(0.5, 0.5, 1.0);
		AO = 1.0;
	}

//INSERT: DEBUG_CONTROL_BLEND
	// Show control map blend values
	{
		ivec3 __uv = get_index_coord(floor(uv), SKIP_PASS);
        uint __control = floatBitsToUint(texelFetch(_control_maps, __uv, 0).r);
        float __ctrl_blend = float(__control >> 14u & 0xFFu) * 0.003921568627450; // 1.0/255.0
		float __is_auto = 0.;
		#ifdef AUTO_SHADER
			__is_auto = float( bool(__control & 0x1u) || __uv.z<0 );
		#endif
		ALBEDO = vec3(__ctrl_blend) * (1.0 - __is_auto) + vec3(0.2, 0.0, 0.0) * __is_auto;
		ROUGHNESS = 1.;
		SPECULAR = 0.;
		NORMAL_MAP = vec3(0.5, 0.5, 1.0);
		AO = 1.0;
	}

//INSERT: DEBUG_CONTROL_ANGLE
	// Show control map texture angle
	{
		ivec3 __auv = get_index_coord(floor(uv), SKIP_PASS);
		uint __a_control = floatBitsToUint(texelFetch(_control_maps, __auv, 0)).r;
		uint __angle = (__a_control >>10u & 0xFu);
		vec3 __a_colors[16] = {
			vec3(1., .2, .0), vec3(.8, 0., .2), vec3(.6, .0, .4), vec3(.4, .0, .6),
			vec3(.2, 0., .8), vec3(.1, .1, .8), vec3(0., .2, .8), vec3(0., .4, .6),
			vec3(0., .6, .4), vec3(0., .8, .2), vec3(0., 1., 0.), vec3(.2, 1., 0.),
			vec3(.4, 1., 0.), vec3(.6, 1., 0.), vec3(.8, .6, 0.), vec3(1., .4, 0.)
		};
		ALBEDO = __a_colors[__angle];
		ROUGHNESS = 1.;
		SPECULAR = 0.;
		NORMAL_MAP = vec3(0.5, 0.5, 1.0);
		AO = 1.0;
	}

//INSERT: DEBUG_CONTROL_SCALE
	// Show control map texture scale
	{
		ivec3 __suv = get_index_coord(floor(uv), SKIP_PASS);
		uint __s_control = floatBitsToUint(texelFetch(_control_maps, __suv, 0)).r;
		uint __scale = (__s_control >>7u & 0x7u);
		vec3 __s_colors[8] = {
			vec3(.5, .5, .5), vec3(.675, .25, .375), vec3(.75, .125, .25), vec3(.875, .0, .125), vec3(1., 0., 0.),
			vec3(0., 0., 1.), vec3(.0, .166, .833), vec3(.166, .333, .666)
		};
		ALBEDO = __s_colors[__scale];
		ROUGHNESS = 1.;
		SPECULAR = 0.;
		NORMAL_MAP = vec3(0.5 ,0.5 ,1.0);
		AO = 1.0;
	}

//INSERT: DEBUG_COLORMAP
	// Show colormap
	{
		ALBEDO = color_map.rgb;
		ROUGHNESS = 0.7;
		SPECULAR = 0.;
		NORMAL_MAP = vec3(0.5, 0.5, 1.0);
		AO = 1.0;
	}

//INSERT: DEBUG_ROUGHMAP
	// Show roughness map
	{
		ALBEDO = vec3(color_map.a);
		ROUGHNESS = 0.7;
		SPECULAR = 0.;
		NORMAL_MAP = vec3(0.5, 0.5, 1.0);
		AO = 1.0;
	}

//INSERT: DEBUG_TEXTURE_HEIGHT
	// Show height textures
	{
		ALBEDO = vec3(mat.albedo_height.a);
		ROUGHNESS = 0.7;
		SPECULAR = 0.;
		NORMAL_MAP = vec3(0.5, 0.5, 1.0);
		AO = 1.0;
	}

//INSERT: DEBUG_TEXTURE_NORMAL
	// Show normal map textures
	{
		ALBEDO = fma(normalize(mat.normal_rough.xzy), vec3(0.5), vec3(0.5));
		ROUGHNESS = 0.7;
		SPECULAR = 0.;
		NORMAL_MAP = vec3(0.5, 0.5, 1.0);
		AO = 1.0;
	}

//INSERT: DEBUG_TEXTURE_ROUGHNESS
	// Show roughness textures
	{
		ALBEDO = vec3(mat.normal_rough.a);
		ROUGHNESS = 0.7;
		SPECULAR = 0.;
		NORMAL_MAP = vec3(0.5, 0.5, 1.0);
		AO = 1.0;
	}
)"