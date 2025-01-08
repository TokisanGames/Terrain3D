// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.
// This shader is the minimum needed to allow the terrain to function, without any texturing.

shader_type spatial;
render_mode blend_mix,depth_draw_opaque,cull_back,diffuse_burley,specular_schlick_ggx,skip_vertex_transform;

// Private uniforms
uniform uint _background_mode = 1u; // NONE = 0, FLAT = 1, NOISE = 2
uniform uint _mouse_layer = 0x80000000u; // Layer 32
uniform float _vertex_spacing = 1.0;
uniform float _vertex_density = 1.0; // = 1/_vertex_spacing
uniform float _region_size = 1024.0;
uniform float _region_texel_size = 0.0009765625; // = 1/1024
uniform int _region_map_size = 32;
uniform int _region_map[1024];
uniform vec2 _region_locations[1024];
uniform float _texture_uv_scale_array[32];
uniform float _texture_detile_array[32];
uniform vec4 _texture_color_array[32];
uniform highp sampler2DArray _height_maps : repeat_disable;
uniform highp usampler2DArray _control_maps : repeat_disable;
uniform highp sampler2DArray _color_maps : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform highp sampler2DArray _texture_array_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform highp sampler2DArray _texture_array_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;

// Varyings & Types
varying flat vec3 v_camera_pos;
varying flat ivec3 v_region;
varying flat vec2 v_uv_offset;
varying flat vec2 v_uv2_offset;
varying float v_vertex_xz_dist;
varying vec3 v_vertex;

////////////////////////
// Vertex
////////////////////////

// Takes in UV world space coordinates, returns ivec3 with:
// XY: (0 to _region_size) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
ivec3 get_region_uv(const vec2 uv) {
	ivec2 pos = ivec2(floor(uv * _region_texel_size)) + (_region_map_size / 2);
	int bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
	int layer_index = _region_map[ pos.y * _region_map_size + pos.x ] * bounds - 1;
	return ivec3(ivec2(mod(uv,_region_size)), layer_index);
}

// Takes in UV2 region space coordinates, returns vec3 with:
// XY: (0 to 1) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
vec3 get_region_uv2(const vec2 uv2) {
	// Remove Texel Offset to ensure correct region index.
	ivec2 pos = ivec2(floor(uv2 - vec2(_region_texel_size * 0.5))) + (_region_map_size / 2);
	int bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
	int layer_index = _region_map[ pos.y * _region_map_size + pos.x ] * bounds - 1;
	return vec3(uv2 - _region_locations[layer_index], float(layer_index));
}

void vertex() {
	// Get camera pos in world vertex coords
	v_camera_pos = INV_VIEW_MATRIX[3].xyz;

	// Get vertex of flat plane in world coordinates and set world UV
	v_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Camera distance to vertex on flat plane
	v_vertex_xz_dist = length(v_vertex.xz - v_camera_pos.xz);

	// UV coordinates in world space. Values are 0 to _region_size within regions
	UV = round(v_vertex.xz * _vertex_density);

	// UV coordinates in region space + texel offset. Values are 0 to 1 within regions
	UV2 = fma(UV, vec2(_region_texel_size), vec2(0.5 * _region_texel_size));

	// Discard vertices for Holes. 1 lookup
	v_region = get_region_uv(UV);
	uint control = texelFetch(_control_maps, v_region, 0).r;
	bool hole = bool(control >>2u & 0x1u);

	// Show holes to all cameras except mouse camera (on exactly 1 layer)
	if ( !(CAMERA_VISIBLE_LAYERS == _mouse_layer) &&
			(hole || (_background_mode == 0u && (get_region_uv(UV - _region_texel_size) & v_region).z < 0))) {
		v_vertex.x = 0. / 0.;
	} else {
		// Set final vertex height, 1 lookup.
		float h = texelFetch(_height_maps, v_region, 0).r;
		v_vertex.y = h;
	}

	// Transform UVs to local to avoid poor precision during varying interpolation.
	v_uv_offset = MODEL_MATRIX[3].xz * _vertex_density;
	UV -= v_uv_offset;
	v_uv2_offset = v_uv_offset * _region_texel_size;
	UV2 -= v_uv2_offset;

	// Convert model space to view space w/ skip_vertex_transform render mode
	VERTEX = (VIEW_MATRIX * vec4(v_vertex, 1.0)).xyz;
	NORMAL = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	BINORMAL = normalize((MODELVIEW_MATRIX * vec4(BINORMAL, 0.0)).xyz);
	TANGENT = normalize((MODELVIEW_MATRIX * vec4(TANGENT, 0.0)).xyz);
}

////////////////////////
// Fragment
////////////////////////

void fragment() {
	// Recover UVs
	vec2 uv = UV + v_uv_offset;
	vec2 uv2 = UV2 + v_uv2_offset;

	// Lookup offsets, ID and bilinear weights
	const vec3 offsets = vec3(0, 1, 2);
	vec2 index_id = floor(uv);
	vec2 weight = fract(uv);
	vec2 invert = 1.0 - weight;
	vec4 weights = vec4(
		invert.x * weight.y, // 0
		weight.x * weight.y, // 1
		weight.x * invert.y, // 2
		invert.x * invert.y  // 3
	);

	// Terrain normals, sample height map 8 times, because these are adjacent values
	// they are cache friendly. texelFetch avoids any cross texture border interpolation errors.
	// 8 lookups
	float h[8];
	h[0] = texelFetch(_height_maps, get_region_uv(index_id + offsets.xx), 0).r; // 0 (0,0)
	h[1] = texelFetch(_height_maps, get_region_uv(index_id + offsets.yx), 0).r; // 1 (1,0)
	h[2] = texelFetch(_height_maps, get_region_uv(index_id + offsets.xy), 0).r; // 2 (0,1)
	h[3] = texelFetch(_height_maps, get_region_uv(index_id + offsets.yy), 0).r; // 3 (1,1)
	h[4] = texelFetch(_height_maps, get_region_uv(index_id + offsets.yz), 0).r; // 4 (1,2)
	h[5] = texelFetch(_height_maps, get_region_uv(index_id + offsets.zy), 0).r; // 5 (2,1)
	h[6] = texelFetch(_height_maps, get_region_uv(index_id + offsets.zx), 0).r; // 6 (2,0)
	h[7] = texelFetch(_height_maps, get_region_uv(index_id + offsets.xz), 0).r; // 7 (0,2)

	// Calculate the normal from height map derivatives at 4 points.
	vec3 index_normal[4];
	index_normal[0] = normalize(vec3(h[2] - h[3], _vertex_spacing, h[2] - h[7]));
	index_normal[1] = normalize(vec3(h[3] - h[5], _vertex_spacing, h[3] - h[4]));
	index_normal[2] = normalize(vec3(h[1] - h[6], _vertex_spacing, h[1] - h[3]));
	index_normal[3] = normalize(vec3(h[0] - h[1], _vertex_spacing, h[0] - h[2]));

	// Interpolate
	vec3 w_normal =
		index_normal[0] * weights[0] +
		index_normal[1] * weights[1] +
		index_normal[2] * weights[2] +
		index_normal[3] * weights[3];

	vec3 w_tangent = normalize(cross(w_normal, vec3(0.0, 0.0, 1.0)));
	vec3 w_binormal = normalize(cross(w_normal, w_tangent));
	NORMAL = mat3(VIEW_MATRIX) * w_normal;
	TANGENT = mat3(VIEW_MATRIX) * w_tangent;
	BINORMAL = mat3(VIEW_MATRIX) * w_binormal;

	// Apply PBR
	ALBEDO = vec3(0.2);
}
