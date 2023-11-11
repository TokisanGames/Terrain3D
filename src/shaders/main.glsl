// Copyright © 2023 Cory Petkovsek, Roope Palmroos, and Contributors.

R"(shader_type spatial;
render_mode blend_mix,depth_draw_opaque,cull_back,diffuse_burley,specular_schlick_ggx;

/* This shader is generated based upon the debug views you have selected.
 * The terrain function depends on this shader. So don't change:
 * - vertex positioning in vertex()
 * - terrain normal calculation in fragment()
 *
 * Most will only want to customize the material calculation and PBR application in fragment()
 *
 * Uniforms that begin with _ are private and will not display in the inspector. However, 
 * you can set them via code. You are welcome to create more of your own hidden uniforms.
 *
 * This system only supports albedo, height, normal, roughness. Most textures don't need the other
 * PBR channels. Height can be used as an approximation for AO. For the rare textures do need
 * additional channels, you can add maps for that one texture. e.g. an emissive map for lava.
 *
 */

uniform float _region_size = 1024.0;
uniform float _region_texel_size = 0.0009765625; // = 1./1024.
uniform int _region_map_size = 16;
uniform int _region_uv_limit = 8;
uniform int _region_map[256];
uniform vec2 _region_offsets[256];
uniform sampler2DArray _height_maps : repeat_disable;
uniform usampler2DArray _control_maps : repeat_disable;
uniform sampler2DArray _color_maps : source_color, repeat_disable;
uniform sampler2DArray _texture_array_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray _texture_array_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float _texture_uv_scale_array[32];
uniform float _texture_uv_rotation_array[32];
uniform vec4 _texture_color_array[32];

varying vec3 v_vertex;	// World coordinate vertex location

////////////////////////
// Vertex
////////////////////////

// Takes in UV world space coordinates, returns ivec3 with:
// XY: (0 to _region_size) coordinates within a region
// Z: region index used for texturearrays, -1 if not in a region
ivec3 get_region_uv(vec2 uv) {
	uv *= _region_texel_size;
	ivec2 pos = ivec2(floor(uv)) + (_region_map_size / 2);
	int index = _region_map[ pos.y * _region_map_size + pos.x ] - 1;
	return ivec3(ivec2((uv - _region_offsets[index]) * _region_size), index);
}

// Takes in UV2 region space coordinates, returns vec3 with:
// XY: (0 to 1) coordinates within a region
// Z: region index used for texturearrays, -1 if not in a region
vec3 get_region_uv2(vec2 uv) {
	ivec2 pos = ivec2(floor(uv)) + (_region_map_size / 2);
	int index = _region_map[ pos.y * _region_map_size + pos.x ] - 1;
	return vec3(uv - _region_offsets[index], float(index));
}

//INSERT: WORLD_NOISE1
// 1 lookup
float get_height(vec2 uv) {
	float height = 0.0;
	vec3 region = get_region_uv2(uv);
	if (region.z >= 0. && abs(uv.x) < float(_region_uv_limit) && abs(uv.y) < float(_region_uv_limit)) {
		height = texture(_height_maps, region).r;
	}
//INSERT: WORLD_NOISE2
 	return height;
}

void vertex() {
	// Get vertex of flat plane in world coordinates and set world UV
	v_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	
	// UV coordinates in world space. Values are 0 to _region_size within regions
	UV = v_vertex.xz;

	// UV coordinates in region space + texel offset. Values are 0 to 1 within regions
	UV2 = (UV + vec2(0.5)) * _region_texel_size;

	// Get final vertex location and save it
	VERTEX.y = get_height(UV2);
	v_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Flatten normal to be calculated in fragment()
	NORMAL = vec3(0, 1, 0);
}

////////////////////////
// Fragment
////////////////////////

// 4 lookups
vec3 get_normal(vec2 uv, out vec3 tangent, out vec3 binormal) {
	float left = get_height(uv + vec2(-_region_texel_size, 0));
	float right = get_height(uv + vec2(_region_texel_size, 0));
	float back = get_height(uv + vec2(0, -_region_texel_size));
	float front = get_height(uv + vec2(0, _region_texel_size));
	vec3 horizontal = vec3(2.0, right - left, 0.0);
	vec3 vertical = vec3(0.0, back - front, 2.0);
	vec3 normal = normalize(cross(vertical, horizontal));
	normal.z *= -1.0;
	tangent = cross(normal, vec3(0, 0, 1));
	binormal = cross(normal, tangent);
	return normal;
}

vec3 unpack_normal(vec4 rgba) {
	vec3 n = rgba.xzy * 2.0 - vec3(1.0);
	n.z *= -1.0;
	return n;
}

vec4 pack_normal(vec3 n, float a) {
	n.z *= -1.0;
	return vec4((n.xzy + vec3(1.0)) * 0.5, a);
}

float random(in vec2 xy) {
	return fract(sin(dot(xy, vec2(12.9898, 78.233))) * 43758.5453);
}

float blend_weights(float weight, float detail) {
	weight = sqrt(weight * 0.5);
	float result = max(0.1 * weight, 10.0 * (weight + detail) + 1.0f - (detail + 10.0));
	return result;
}

vec4 height_blend(vec4 a_value, float a_bump, vec4 b_value, float b_bump, float t) {
	float ma = max(a_bump + (1.0 - t), b_bump + t) - 0.1;
	float ba = max(a_bump + (1.0 - t) - ma, 0.0);
	float bb = max(b_bump + t - ma, 0.0);
	return (a_value * ba + b_value * bb) / (ba + bb);
}

vec2 rotate(vec2 v, float cosa, float sina) {
	return vec2(cosa * v.x - sina * v.y, sina * v.x + cosa * v.y);
}

// 2-4 lookups
vec4 get_material(vec2 uv, uint control, vec2 uv_center, float weight, inout float total_weight, inout vec4 out_normal) {
	uint base_tex = control>>27u & 0x1Fu;
	float r = random(uv_center) * PI;
	float rand = r * _texture_uv_rotation_array[base_tex];
	vec2 rot = vec2(cos(rand), sin(rand));
	uv *= .5; // Allow larger numbers on uv scale array - move to C++
	vec2 matUV = rotate(uv, rot.x, rot.y) * _texture_uv_scale_array[base_tex];

	vec4 albedo = texture(_texture_array_albedo, vec3(matUV, float(base_tex)));
	albedo.rgb *= _texture_color_array[base_tex].rgb;
	vec4 normal = texture(_texture_array_normal, vec3(matUV, float(base_tex)));
	vec3 n = unpack_normal(normal);
	normal.xz = rotate(n.xz, rot.x, -rot.y);

	float blend = float(control >>14u & 0xFFu) * 0.003921568627450f; // X/255.0
	if (blend > 0.f) {
		uint over_tex =  control >> 22u & 0x1Fu;
		float rand2 = r * _texture_uv_rotation_array[over_tex];
		vec2 rot2 = vec2(cos(rand2), sin(rand2));
		vec2 matUV2 = rotate(uv, rot2.x, rot2.y) * _texture_uv_scale_array[over_tex];
		vec4 albedo2 = texture(_texture_array_albedo, vec3(matUV2, float(over_tex)));
		albedo2.rgb *= _texture_color_array[over_tex].rgb;
		vec4 normal2 = texture(_texture_array_normal, vec3(matUV2, float(over_tex)));
		n = unpack_normal(normal2);
		normal2.xz = rotate(n.xz, rot2.x, -rot2.y);

		albedo = height_blend(albedo, albedo.a, albedo2, albedo2.a, blend);
		normal = height_blend(normal, albedo.a, normal2, albedo2.a, blend);
	}

	normal = pack_normal(normal.xyz, normal.a);
	weight = blend_weights(weight, albedo.a);
	out_normal += normal * weight;
	total_weight += weight;
	return albedo * weight;
}

void fragment() {
	// Calculate Terrain Normals. 4 lookups
	vec3 w_tangent, w_binormal;
	vec3 w_normal = get_normal(UV2, w_tangent, w_binormal);
	NORMAL = mat3(VIEW_MATRIX) * w_normal;
	TANGENT = mat3(VIEW_MATRIX) * w_tangent;
	BINORMAL = mat3(VIEW_MATRIX) * w_binormal;

	// Calculated Weighted Material
	// https://github.com/cdxntchou/IndexMapTerrain/blob/master/Assets/Terrain/Shaders/IndexedTerrainShader.shader
	vec2 texel_pos = UV;
	vec2 texel_pos_floor = floor(UV);
	
	// Create a cross hatch grid of alternating 0/1 horizontal and vertical stripes 1 unit wide in XY 
	vec4 mirror = vec4(fract(texel_pos_floor * 0.5) * 2.0, 1.0, 1.0);
	// And the opposite grid in ZW
	mirror.zw = vec2(1.0) - mirror.xy;

	// Get the region and control map ID of four vertices surrounding this pixel
	ivec3 index00UV = get_region_uv(texel_pos_floor + mirror.xy);
	ivec3 index01UV = get_region_uv(texel_pos_floor + mirror.xw);
	ivec3 index10UV = get_region_uv(texel_pos_floor + mirror.zy);
	ivec3 index11UV = get_region_uv(texel_pos_floor + mirror.zw);

	uint control00 = texelFetch(_control_maps, index00UV, 0).r;
	uint control01 = texelFetch(_control_maps, index01UV, 0).r;
	uint control10 = texelFetch(_control_maps, index10UV, 0).r;
	uint control11 = texelFetch(_control_maps, index11UV, 0).r;

	// Calculate weight for the pixel position between the vertices
	// Bilinear interpolate difference of UV and floor UV
	vec2 weights1 = clamp(texel_pos - texel_pos_floor, 0, 1);
	weights1 = mix(weights1, vec2(1.0) - weights1, mirror.xy);
	vec2 weights0 = vec2(1.0) - weights1;

	float total_weight = 0.0;
	vec4 normal = vec4(0.0);
	vec4 color = vec4(0.0);

	// Accumulate material. 8-16 lookups
	color  = get_material(UV, control00, vec2(index00UV.xy), weights0.x * weights0.y, total_weight, normal);
	color += get_material(UV, control01, vec2(index01UV.xy), weights0.x * weights1.y, total_weight, normal);
	color += get_material(UV, control10, vec2(index10UV.xy), weights1.x * weights0.y, total_weight, normal);
	color += get_material(UV, control11, vec2(index11UV.xy), weights1.x * weights1.y, total_weight, normal);
	total_weight = 1.0 / total_weight;
	normal *= total_weight;
	color *= total_weight;

	// Apply Colormap. 1 lookup
	vec3 ruv = get_region_uv2(UV2);
	vec4 color_tex = vec4(1., 1., 1., .5);
	if (ruv.z >= 0.) {
		color_tex = texture(_color_maps, ruv);
	}

	// Apply PBR
	ALBEDO = color.rgb * color_tex.rgb;
	ROUGHNESS = clamp(fma(color_tex.a-0.5, 2.0, normal.a), 0., 1.);
	NORMAL_MAP = normal.rgb;
	NORMAL_MAP_DEPTH = 1.0;

//INSERT: DEBUG_CHECKERED
//INSERT: DEBUG_GREY
//INSERT: DEBUG_HEIGHTMAP
//INSERT: DEBUG_COLORMAP
//INSERT: DEBUG_ROUGHMAP
//INSERT: DEBUG_CONTROLMAP
//INSERT: DEBUG_TEXTURE_HEIGHT
//INSERT: DEBUG_TEXTURE_NORMAL
//INSERT: DEBUG_TEXTURE_ROUGHNESS
//INSERT: DEBUG_VERTEX_GRID
}

)"