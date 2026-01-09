// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

// These special inserts are injected into the shader code at the end of fragment().
// Variables should be prefaced with __ to avoid name conflicts.

R"(
//INSERT: PBR_TEXTURE_ALBEDO
	// Show albedo textures
	{
		ALBEDO = mat.albedo_height.rgb;
		ROUGHNESS = 0.7;
		SPECULAR = 0.;
		NORMAL_MAP = vec3(0.5, 0.5, 1.0);
		AO = 1.0;
	}

//INSERT: PBR_TEXTURE_HEIGHT
	// Show height textures
	{
		ALBEDO = vec3(mat.albedo_height.a);
		ROUGHNESS = 0.7;
		SPECULAR = 0.;
		NORMAL_MAP = vec3(0.5, 0.5, 1.0);
		AO = 1.0;
	}

//INSERT: PBR_TEXTURE_NORMAL
	// Show normal map textures
	{
		ALBEDO = fma(normalize(mat.normal_rough.xzy), vec3(0.5), vec3(0.5));
		ROUGHNESS = 0.7;
		SPECULAR = 0.;
		NORMAL_MAP = vec3(0.5, 0.5, 1.0);
		AO = 1.0;
	}

//INSERT: PBR_TEXTURE_ROUGHNESS
	// Show roughness textures
	{
		ALBEDO = vec3(mat.normal_rough.a);
		ROUGHNESS = 0.7;
		SPECULAR = 0.;
		NORMAL_MAP = vec3(0.5, 0.5, 1.0);
		AO = 1.0;
	}

//INSERT: PBR_TEXTURE_AO
	// Show normal map decoded AO value
	{
		ALBEDO = vec3(mat.ao);
		ROUGHNESS = 0.7;
		SPECULAR = 0.;
		NORMAL_MAP = vec3(0.5, 0.5, 1.0);
		AO = 1.0;
	}

//INSERT: OUTPUT_ALBEDO
	ALBEDO = mat.albedo_height.rgb * color_map.rgb;
//INSERT: OUTPUT_ALBEDO_GREY
	ALBEDO = vec3(0.2);
//INSERT: OUTPUT_ROUGHNESS
	ROUGHNESS = roughness;
	SPECULAR = 1. - mat.normal_rough.a;
//INSERT: OUTPUT_NORMAL_MAP
	// Repack final normal map value.
	NORMAL_MAP = fma(normalize(mat.normal_rough.xzy), vec3(0.5), vec3(0.5));
	NORMAL_MAP_DEPTH = mat.normal_map_depth;
//INSERT: OUTPUT_AMBIENT_OCCLUSION
	AO = clamp(mat.ao, 0., 1.);
	AO_LIGHT_AFFECT = mat.ao_affect;

)"
