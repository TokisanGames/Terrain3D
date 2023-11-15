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

// Private uniforms
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

// Public uniforms
uniform float height_blend_sharpness : hint_range(0.001, 1) = 0.13;

// Varyings & Types

struct Material {
	vec4 alb_ht;
	vec4 nrm_rg;
	uint base;
	uint over;
	float blend;
};

varying vec3 v_vertex;	// World coordinate vertex location

////////////////////////
// Vertex
////////////////////////

// Takes in UV world space coordinates, returns ivec3 with:
// XY: (0 to _region_size) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
ivec3 get_region_uv(vec2 uv) {
	uv *= _region_texel_size;
	ivec2 pos = ivec2(floor(uv)) + (_region_map_size / 2);
	int layer_index = _region_map[ pos.y * _region_map_size + pos.x ] - 1;
	return ivec3(ivec2((uv - _region_offsets[layer_index]) * _region_size), layer_index);
}

// Takes in UV2 region space coordinates, returns vec3 with:
// XY: (0 to 1) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
vec3 get_region_uv2(vec2 uv) {
	ivec2 pos = ivec2(floor(uv)) + (_region_map_size / 2);
	int layer_index = _region_map[ pos.y * _region_map_size + pos.x ] - 1;
	return vec3(uv - _region_offsets[layer_index], float(layer_index));
}

//INSERT: WORLD_NOISE1
// 1 lookup
float get_height(vec2 uv) {
	highp float height = 0.0;
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

float blend_weights(float weight, float detail) {
	weight = sqrt(weight * 0.5);
	float result = max(0.1 * weight, 10.0 * (weight + detail) + 1.0f - (detail + 10.0));
	return result;
}

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

vec2 rotate(vec2 v, float cosa, float sina) {
	return vec2(cosa * v.x - sina * v.y, sina * v.x + cosa * v.y);
}

vec4 height_blend(vec4 a_value, float a_height, vec4 b_value, float b_height, float t) {
	float ma = max(a_height + (1.0 - t), b_height + t) - height_blend_sharpness;
    float b1 = max(a_height + (1.0 - t) - ma, 0.0);
    float b2 = max(b_height + t - ma, 0.0);
    return (a_value * b1 + b_value * b2) / (b1 + b2);
}

// 2-4 lookups
void get_material(vec2 uv, uint control, ivec2 iuv_center, out Material out_mat) {
	out_mat = Material(vec4(0.), vec4(0.), 0u, 0u, 0.0);
	uint base_tex = control>>27u & 0x1Fu;
	out_mat.base = base_tex;
	vec2 uv_center = vec2(iuv_center);
	float r = random(uv_center) * PI;
	float rand = r * _texture_uv_rotation_array[base_tex];
	vec2 rot = vec2(cos(rand), sin(rand));
	uv *= .5; // Allow larger numbers on uv scale array - move to C++
	vec2 matUV = rotate(uv, rot.x, rot.y) * _texture_uv_scale_array[base_tex];

	vec4 albedo_ht = texture(_texture_array_albedo, vec3(matUV, float(base_tex)));
	albedo_ht.rgb *= _texture_color_array[base_tex].rgb;
	vec4 normal_rg = texture(_texture_array_normal, vec3(matUV, float(base_tex)));
	vec3 n = unpack_normal(normal_rg);
	normal_rg.xz = rotate(n.xz, rot.x, -rot.y);

	float blend = float(control >>14u & 0xFFu) * 0.003921568627450; // 1./255.0
	out_mat.blend = blend;
	if (blend > 0.f) {
		uint over_tex =  control >> 22u & 0x1Fu;
		out_mat.over = over_tex;
		float rand2 = r * _texture_uv_rotation_array[over_tex];
		vec2 rot2 = vec2(cos(rand2), sin(rand2));
		vec2 matUV2 = rotate(uv, rot2.x, rot2.y) * _texture_uv_scale_array[over_tex];
		vec4 albedo_ht2 = texture(_texture_array_albedo, vec3(matUV2, float(over_tex)));
		albedo_ht2.rgb *= _texture_color_array[over_tex].rgb;
		vec4 normal_rg2 = texture(_texture_array_normal, vec3(matUV2, float(over_tex)));
		n = unpack_normal(normal_rg2);
		normal_rg2.xz = rotate(n.xz, rot2.x, -rot2.y);

		albedo_ht = height_blend(albedo_ht, albedo_ht.a, albedo_ht2, albedo_ht2.a, blend);
		normal_rg = height_blend(normal_rg, albedo_ht.a, normal_rg2, albedo_ht2.a, blend);
	}

	normal_rg = pack_normal(normal_rg.xyz, normal_rg.a);
	out_mat.alb_ht = albedo_ht;
	out_mat.nrm_rg = normal_rg;
	return;
}

void fragment() {
	// Calculate Terrain Normals. 4 lookups
	vec3 w_tangent, w_binormal;
	vec3 w_normal = get_normal(UV2, w_tangent, w_binormal);
	NORMAL = mat3(VIEW_MATRIX) * w_normal;
	TANGENT = mat3(VIEW_MATRIX) * w_tangent;
	BINORMAL = mat3(VIEW_MATRIX) * w_binormal;

	// Idenfity 4 vertices surrounding this pixel
	vec2 texel_pos = UV;
	highp vec2 texel_pos_floor = floor(UV);
	
	// Create a cross hatch grid of alternating 0/1 horizontal and vertical stripes 1 unit wide in XY 
	vec4 mirror = vec4(fract(texel_pos_floor * 0.5) * 2.0, 1.0, 1.0);
	// And the opposite grid in ZW
	mirror.zw = vec2(1.0) - mirror.xy;

	// Get the region and control map ID for the vertices
	ivec3 index00UV = get_region_uv(texel_pos_floor + mirror.xy);
	ivec3 index01UV = get_region_uv(texel_pos_floor + mirror.xw);
	ivec3 index10UV = get_region_uv(texel_pos_floor + mirror.zy);
	ivec3 index11UV = get_region_uv(texel_pos_floor + mirror.zw);

	// Lookup adjacent vertices. 4 lookups
	uint control00 = texelFetch(_control_maps, index00UV, 0).r;
	uint control01 = texelFetch(_control_maps, index01UV, 0).r;
	uint control10 = texelFetch(_control_maps, index10UV, 0).r;
	uint control11 = texelFetch(_control_maps, index11UV, 0).r;

	// Get the textures for each vertex. 8-16 lookups (2-4 ea)
	Material mat[4];
	get_material(UV, control00, index00UV.xy, mat[0]);
	get_material(UV, control01, index01UV.xy, mat[1]);
	get_material(UV, control10, index10UV.xy, mat[2]);
	get_material(UV, control11, index11UV.xy, mat[3]);

	// Calculate weight for the pixel position between the vertices
	// Bilinear interpolation of difference of UV and floor(UV)
	vec2 weights1 = clamp(texel_pos - texel_pos_floor, 0, 1);
	weights1 = mix(weights1, vec2(1.0) - weights1, mirror.xy);
	vec2 weights0 = vec2(1.0) - weights1;
	// Then adjust the weights based upon the texture height
	vec4 weights;
	weights.x = blend_weights(weights0.x * weights0.y, mat[0].alb_ht.a);
	weights.y = blend_weights(weights0.x * weights1.y, mat[1].alb_ht.a);
	weights.z = blend_weights(weights1.x * weights0.y, mat[2].alb_ht.a);
	weights.w = blend_weights(weights1.x * weights1.y, mat[3].alb_ht.a);
	float weight_sum = weights.x + weights.y + weights.z + weights.w;
	float weight_inv = 1.0/weight_sum;

	// Calculate weighted average of albedo & height
	vec4 albedo_height = weight_inv * (
		mat[0].alb_ht * weights.x +
		mat[1].alb_ht * weights.y +
		mat[2].alb_ht * weights.z +
		mat[3].alb_ht * weights.w );

	// Calculate weighted average of normal & rough
	vec4 normal_rough = weight_inv * (
		mat[0].nrm_rg * weights.x +
		mat[1].nrm_rg * weights.y +
		mat[2].nrm_rg * weights.z +
		mat[3].nrm_rg * weights.w );

	// Get Colormap. 1 lookup
	vec3 ruv = get_region_uv2(UV2);
	vec4 color_map = vec4(1., 1., 1., .5);
	if (ruv.z >= 0.) {
		color_map = texture(_color_maps, ruv);
	}

	// Apply PBR

	ALBEDO = albedo_height.rgb * color_map.rgb;
	// Rougness + (rough_modifier-.5)*2 // Calc converts (0 to 1) to (-1 to 1)
	ROUGHNESS = clamp(fma(color_map.a-0.5, 2.0, normal_rough.a), 0., 1.);
	NORMAL_MAP = normal_rough.rgb;
	NORMAL_MAP_DEPTH = 1.0;

//INSERT: DEBUG_CHECKERED
//INSERT: DEBUG_GREY
//INSERT: DEBUG_HEIGHTMAP
//INSERT: DEBUG_COLORMAP
//INSERT: DEBUG_ROUGHMAP
//INSERT: DEBUG_CONTROL_TEXTURE
//INSERT: DEBUG_CONTROL_BLEND
//INSERT: DEBUG_TEXTURE_HEIGHT
//INSERT: DEBUG_TEXTURE_NORMAL
//INSERT: DEBUG_TEXTURE_ROUGHNESS
//INSERT: DEBUG_VERTEX_GRID
}

)"