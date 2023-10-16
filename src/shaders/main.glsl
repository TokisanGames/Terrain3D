// Copyright © 2023 Cory Petkovsek, Roope Palmroos, and Contributors.

R"(shader_type spatial;
render_mode blend_mix,depth_draw_opaque,cull_back,diffuse_burley,specular_schlick_ggx;

uniform float _region_size = 1024.0;
uniform float _region_pixel_size = 0.0009765625; // 1.0 / 1024.0
uniform int _region_map_size = 16;
uniform int _region_map[256];
uniform vec2 _region_offsets[256];
uniform sampler2DArray _height_maps : filter_linear_mipmap, repeat_disable;
uniform sampler2DArray _control_maps : filter_linear_mipmap, repeat_disable;
uniform sampler2DArray _color_maps : filter_linear_mipmap, repeat_disable;

uniform sampler2DArray _texture_array_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray _texture_array_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float _texture_uv_scale_array[32];
uniform float _texture_uv_rotation_array[32];
uniform vec4 _texture_color_array[32];

//INSERT: WORLD_NOISE1

vec3 unpack_normal(vec4 rgba) {
	vec3 n = rgba.xzy * 2.0 - vec3(1.0);
	n.z *= -1.0;
	return n;
}

vec4 pack_normal(vec3 n, float a) {
	n.z *= -1.0;
	return vec4((n.xzy + vec3(1.0)) * 0.5, a);
}

// Takes location in world space coordinates, returns ivec3 with:
// XY: (0-_region_size) coordinates within the region
// Z: region index used for texturearrays, -1 if not in a region
ivec3 get_region(vec2 uv) {
	ivec2 pos = ivec2(floor(uv)) + (_region_map_size / 2);
	int index = _region_map[ pos.y*_region_map_size + pos.x ] - 1;
	return ivec3(ivec2((uv - _region_offsets[index]) * _region_size), index);
}

// vec3 form of get_region. Same return values
vec3 get_regionf(vec2 uv) {
	ivec2 pos = ivec2(floor(uv)) + (_region_map_size / 2);
	int index = _region_map[ pos.y*_region_map_size + pos.x ] - 1;
	return vec3(uv - _region_offsets[index], float(index));
}

float get_height(vec2 uv) {
	float height = 0.0;
	vec3 region = get_regionf(uv);
	if (region.z >= 0.) {
		height = texture(_height_maps, region).r;
	}
//INSERT: WORLD_NOISE2
 	return height;
}

float random(in vec2 xy) {
	return fract(sin(dot(xy, vec2(12.9898, 78.233))) * 43758.5453);
}

float blend_weights(float weight, float detail) {
	weight = sqrt(weight * 0.5);
	float result = max(0.1 * weight, 10.0 * (weight + detail) + 1.0f - (detail + 10.0));
	return result;
}

vec4 depth_blend(vec4 a_value, float a_bump, vec4 b_value, float b_bump, float t) {
	float ma = max(a_bump + (1.0 - t), b_bump + t) - 0.1;
	float ba = max(a_bump + (1.0 - t) - ma, 0.0);
	float bb = max(b_bump + t - ma, 0.0);
	return (a_value * ba + b_value * bb) / (ba + bb);
}

vec2 rotate(vec2 v, float cosa, float sina) {
	return vec2(cosa * v.x - sina * v.y, sina * v.x + cosa * v.y);
}

vec3 get_normal(vec2 uv, out vec3 tangent, out vec3 binormal) {
	// Normal calc
	// Control map is also sampled 4 times, so in theory we could reduce the region samples to 4 from 8,
	// but control map sampling is slightly different with the mirroring and doesn't work here.
	// The region map is very, very small, so maybe the performance cost isn't too high
	float left = get_height(uv + vec2(-_region_pixel_size, 0));
	float right = get_height(uv + vec2(_region_pixel_size, 0));
	float back = get_height(uv + vec2(0, -_region_pixel_size));
	float fore = get_height(uv + vec2(0, _region_pixel_size));
	vec3 horizontal = vec3(2.0, right - left, 0.0);
	vec3 vertical = vec3(0.0, back - fore, 2.0);
	vec3 normal = normalize(cross(vertical, horizontal));
	normal.z *= -1.0;
	tangent = cross(normal, vec3(0, 0, 1));
	binormal = cross(normal, tangent);
	return normal;
}

vec4 get_material(vec2 uv, vec4 index, vec2 uv_center, float weight, inout float total_weight, inout vec4 out_normal) {
	float material = index.r * 255.0;
	float r = random(uv_center) * PI;
	float rand = r * _texture_uv_rotation_array[int(material)];
	vec2 rot = vec2(cos(rand), sin(rand));
	vec2 matUV = rotate(uv, rot.x, rot.y) * _texture_uv_scale_array[int(material)];

	vec4 albedo = texture(_texture_array_albedo, vec3(matUV, material));
	albedo.rgb *= _texture_color_array[int(material)].rgb;
	vec4 normal = texture(_texture_array_normal, vec3(matUV, material));
	vec3 n = unpack_normal(normal);
	normal.xz = rotate(n.xz, rot.x, -rot.y);

	if (index.b > 0.0) {
		float materialOverlay = index.g * 255.0;
		float rand2 = r * _texture_uv_rotation_array[int(materialOverlay)];
		vec2 rot2 = vec2(cos(rand2), sin(rand2));
		vec2 matUV2 = rotate(uv, rot2.x, rot2.y) * _texture_uv_scale_array[int(materialOverlay)];
		vec4 albedo2 = texture(_texture_array_albedo, vec3(matUV2, materialOverlay));
		albedo2.rgb *= _texture_color_array[int(materialOverlay)].rgb;
		vec4 normal2 = texture(_texture_array_normal, vec3(matUV2, materialOverlay));
		n = unpack_normal(normal2);
		normal2.xz = rotate(n.xz, rot2.x, -rot2.y);

		albedo = depth_blend(albedo, albedo.a, albedo2, albedo2.a, index.b);
		normal = depth_blend(normal, albedo.a, normal2, albedo2.a, index.b);
	}

	normal = pack_normal(normal.xyz, normal.a);
	weight = blend_weights(weight, albedo.a);
	out_normal += normal * weight;
	total_weight += weight;
	return albedo * weight;
}

void vertex() {
	vec3 world_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	UV = world_vertex.xz * 0.5;	// Without this, individual material UV needs to be very small.
	UV2 = ((world_vertex.xz + vec2(0.5)) / vec2(_region_size));
	VERTEX.y = get_height(UV2);
	NORMAL = vec3(0, 1, 0);
}

void fragment() {
	// Calculate Terrain World Normals
	vec3 w_tangent, w_binormal;
	vec3 w_normal = get_normal(UV2, w_tangent, w_binormal);
	NORMAL = mat3(VIEW_MATRIX) * w_normal;
	TANGENT = mat3(VIEW_MATRIX) * w_tangent;
	BINORMAL = mat3(VIEW_MATRIX) * w_binormal;

	// Calculated Weighted Material
	// source : https://github.com/cdxntchou/IndexMapTerrain
	// black magic which I don't understand at all. Seems simple but what and why?
	vec2 pos_texel = UV2 * _region_size + 0.5;
	vec2 pos_texel00 = floor(pos_texel);
	vec4 mirror = vec4(fract(pos_texel00 * 0.5) * 2.0, 1.0, 1.0);
	mirror.zw = vec2(1.0) - mirror.xy;

	ivec3 index00UV = get_region((pos_texel00 + mirror.xy) * _region_pixel_size);
	ivec3 index01UV = get_region((pos_texel00 + mirror.xw) * _region_pixel_size);
	ivec3 index10UV = get_region((pos_texel00 + mirror.zy) * _region_pixel_size);
	ivec3 index11UV = get_region((pos_texel00 + mirror.zw) * _region_pixel_size);

	vec4 index00 = texelFetch(_control_maps, index00UV, 0);
	vec4 index01 = texelFetch(_control_maps, index01UV, 0);
	vec4 index10 = texelFetch(_control_maps, index10UV, 0);
	vec4 index11 = texelFetch(_control_maps, index11UV, 0);

	vec2 weights1 = clamp(pos_texel - pos_texel00, 0, 1);
	weights1 = mix(weights1, vec2(1.0) - weights1, mirror.xy);
	vec2 weights0 = vec2(1.0) - weights1;

	float total_weight = 0.0;
	vec4 normal = vec4(0.0);
	vec4 color = vec4(0.0);

	color = get_material(UV, index00, vec2(index00UV.xy), weights0.x * weights0.y, total_weight, normal);
	color += get_material(UV, index01, vec2(index01UV.xy), weights0.x * weights1.y, total_weight, normal);
	color += get_material(UV, index10, vec2(index10UV.xy), weights1.x * weights0.y, total_weight, normal);
	color += get_material(UV, index11, vec2(index11UV.xy), weights1.x * weights1.y, total_weight, normal);
	total_weight = 1.0 / total_weight;
	normal *= total_weight;
	color *= total_weight;

	// Apply Colormap
	vec3 ruv = get_regionf(UV2);
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