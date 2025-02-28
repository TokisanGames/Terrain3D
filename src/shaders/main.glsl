// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

// Raw strings have a limit of 64k, but MSVC has a limit of 2k in a string literal. This file is split into
// multiple raw strings that are concatenated by the compiler.

R"(shader_type spatial;
render_mode blend_mix,depth_draw_opaque,cull_back,diffuse_burley,specular_schlick_ggx,skip_vertex_transform;

/* The terrain depends on this shader to function. Don't change most things in vertex() or 
 * terrain normal calculations in fragment(). You probably only want to customize the 
 * material calculation and PBR application in fragment().
 *
 * Uniforms that begin with _ are private and will not display in the inspector. However, 
 * you can set them via code. You are welcome to create more of your own hidden uniforms.
 *
 * This system only supports albedo, height, normal, roughness. Most textures don't need the other
 * PBR channels. Height can be used as an approximation for AO. For the rare textures do need
 * additional channels, you can add maps for that one texture. e.g. an emissive map for lava.
 *
 */

// Defined Constants
#define SKIP_PASS 0
#define VERTEX_PASS 1
#define FRAGMENT_PASS 2

// Private uniforms
uniform vec3 _camera_pos = vec3(0.f);
uniform float _mesh_size = 48.f;
uniform uint _background_mode = 1u; // NONE = 0, FLAT = 1, NOISE = 2
uniform uint _mouse_layer = 0x80000000u; // Layer 32
uniform float _vertex_spacing = 1.0;
uniform float _vertex_density = 1.0; // = 1/_vertex_spacing
uniform float _region_size = 1024.0;
uniform float _region_texel_size = 0.0009765625; // = 1/1024
uniform int _region_map_size = 32;
uniform int _region_map[1024];
uniform vec2 _region_locations[1024];
uniform float _texture_normal_depth_array[32];
uniform float _texture_uv_scale_array[32];
uniform vec2 _texture_detile_array[32];
uniform vec4 _texture_color_array[32];
uniform highp sampler2DArray _height_maps : repeat_disable;
uniform highp usampler2DArray _control_maps : repeat_disable;
//INSERT: TEXTURE_SAMPLERS_NEAREST
//INSERT: TEXTURE_SAMPLERS_LINEAR

// Public uniforms
//INSERT: AUTO_SHADER_UNIFORMS
//INSERT: DUAL_SCALING_UNIFORMS
uniform bool height_blending = true;
uniform bool world_space_normal_blend = true;
uniform float blend_sharpness : hint_range(0, 1) = 0.87;

uniform bool enable_projection = true;
uniform float projection_threshold : hint_range(0.0, 1.0, 0.01) = 0.8;
uniform float projection_angular_division : hint_range(1.0, 16.0, 0.001) = 2.0;

uniform float mipmap_bias : hint_range(0.5, 1.5, 0.01) = 1.0;
uniform float depth_blur : hint_range(0.0, 35.0, 0.1) = 0.0;
uniform float bias_distance : hint_range(0.0, 16384.0, 0.1) = 512.0;

uniform bool enable_macro_variation = true;
uniform vec3 macro_variation1 : source_color = vec3(1.);
uniform vec3 macro_variation2 : source_color = vec3(1.);
uniform float macro_variation_slope : hint_range(0., 1.)  = 0.333;

// Generic noise at 3 scales, which can be used for anything 
uniform float noise1_scale : hint_range(0.001, 1.) = 0.04; // Used for macro variation 1. Scaled up 10x
uniform float noise1_angle : hint_range(0, 6.283) = 0.;
uniform vec2 noise1_offset = vec2(0.5);
uniform float noise2_scale : hint_range(0.001, 1.) = 0.076;	// Used for macro variation 2. Scaled up 10x
uniform float noise3_scale : hint_range(0.001, 1.) = 0.225; // Used for texture blending edge

// Varyings & Types

struct Material {
	vec4 alb_ht;
	vec4 nrm_rg;
	int base;
	int over;
	float blend;
	float nrm_depth;
};


varying float v_vertex_xz_dist;
varying vec3 v_vertex;
)"

		R"(
////////////////////////
// Vertex
////////////////////////

// Takes in UV world space coordinates & search depth (only applicable for background mode none)
// Returns ivec3 with:
// XY: (0 to _region_size) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
ivec3 get_region_uv(const vec2 uv, const int search) {
	vec2 r_uv = round(uv);
	vec2 o_uv = mod(r_uv,_region_size);
	ivec2 pos;
	int bounds, layer_index = -1;
	for (int i = -1; i < clamp(search, SKIP_PASS, FRAGMENT_PASS); i++) {
		if ((layer_index == -1 && _background_mode == 0u ) || i < 0) {
			r_uv -= i == -1 ? vec2(0.0) : vec2(float(o_uv.x <= o_uv.y), float(o_uv.y <= o_uv.x));
			pos = ivec2(floor((r_uv) * _region_texel_size)) + (_region_map_size / 2);
			bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
			layer_index = (_region_map[ pos.y * _region_map_size + pos.x ] * bounds - 1);
		}
	}
	return ivec3(ivec2(mod(r_uv,_region_size)), layer_index);
}

// Takes in UV2 region space coordinates, returns vec3 with:
// XY: (0 to 1) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
vec3 get_region_uv2(const vec2 uv2) {
	ivec2 pos = ivec2(floor(uv2)) + (_region_map_size / 2);
	int bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
	int layer_index = _region_map[ pos.y * _region_map_size + pos.x ] * bounds - 1;
	return vec3(uv2 - _region_locations[layer_index], float(layer_index));
}

//INSERT: WORLD_NOISE1
void vertex() {
	// Get vertex of flat plane in world coordinates and set world UV
	v_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Camera distance to vertex on flat plane
	v_vertex_xz_dist = length(v_vertex.xz - _camera_pos.xz);

	// Geomorph vertex, set end and start for linear height interpolate
	float scale = MODEL_MATRIX[0][0];
	float vertex_lerp = smoothstep(0.55, 0.95, (v_vertex_xz_dist / scale - _mesh_size - 4.0) / (_mesh_size - 2.0));
	vec2 v_fract = fract(VERTEX.xz * 0.5) * 2.0;
	// For LOD0 morph from a regular grid to an alternating grid to align with LOD1+
	vec2 shift = (scale < _vertex_spacing + 1e-6) ? // LOD0 or not
		// Shift from regular to symetric
		mix(v_fract, vec2(v_fract.x, -v_fract.y),
			round(fract(round(mod(v_vertex.z * _vertex_density, 4.0)) *
			round(mod(v_vertex.x * _vertex_density, 4.0)) * 0.25))
			) :
		// Symetric shift
		v_fract * round((fract(v_vertex.xz * 0.25 / scale) - 0.5) * 4.0);
	vec2 start_pos = v_vertex.xz * _vertex_density;
	vec2 end_pos = (v_vertex.xz - shift * scale) * _vertex_density;
	v_vertex.xz -= shift * scale * vertex_lerp;

	// UV coordinates in world space. Values are 0 to _region_size within regions
	UV = v_vertex.xz * _vertex_density;

	// UV coordinates in region space + texel offset. Values are 0 to 1 within regions
	UV2 = fma(UV, vec2(_region_texel_size), vec2(0.5 * _region_texel_size));

	// Discard vertices for Holes. 1 lookup
	ivec3 v_region = get_region_uv(start_pos, VERTEX_PASS);
	uint control = texelFetch(_control_maps, v_region, 0).r;
	bool hole = bool(control >>2u & 0x1u);

	// Show holes to all cameras except mouse camera (on exactly 1 layer)
	if ( !(CAMERA_VISIBLE_LAYERS == _mouse_layer) && 
			(hole || (_background_mode == 0u && v_region.z == -1))) {
		v_vertex.x = 0. / 0.;
	} else {		
		// Set final vertex height & calculate vertex normals. 3 lookups
		ivec3 uv_a = get_region_uv(start_pos, VERTEX_PASS);
		ivec3 uv_b = get_region_uv(end_pos, VERTEX_PASS);
		float h = mix(texelFetch(_height_maps, uv_a, 0).r,texelFetch(_height_maps, uv_b, 0).r,vertex_lerp);
//INSERT: WORLD_NOISE2
		v_vertex.y = h;
	}

	// Convert model space to view space w/ skip_vertex_transform render mode
	VERTEX = (VIEW_MATRIX * vec4(v_vertex, 1.0)).xyz;
	NORMAL = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	BINORMAL = normalize((MODELVIEW_MATRIX * vec4(BINORMAL, 0.0)).xyz);
	TANGENT = normalize((MODELVIEW_MATRIX * vec4(TANGENT, 0.0)).xyz);
}
)"

		R"(
////////////////////////
// Fragment
////////////////////////

vec3 unpack_normal(vec4 rgba) {
	return fma(rgba.xzy, vec3(2.0), vec3(-1.0));
}

vec3 pack_normal(vec3 n) {
	return fma(normalize(n.xzy), vec3(0.5), vec3(0.5));
}

float random(in vec2 xy) {
	return fract(sin(dot(xy, vec2(12.9898, 78.233))) * 43758.5453);
}

vec2 rotate(vec2 v, float cosa, float sina) {
	return vec2(fma(cosa, v.x, - sina * v.y), fma(sina, v.x, cosa * v.y));
}

// Moves a point around a pivot point.
vec2 rotate_around(vec2 point, vec2 pivot, float angle){
	float x = pivot.x + (point.x - pivot.x) * cos(angle) - (point.y - pivot.y) * sin(angle);
	float y = pivot.y + (point.x - pivot.x) * sin(angle) + (point.y - pivot.y) * cos(angle);
	return vec2(x, y);
}

vec4 height_blend4(vec4 a_value, float a_height, vec4 b_value, float b_height, float blend) {
	if(height_blending) {
		float ma = max(a_height + (1.0 - blend), b_height + blend) - (1.001 - blend_sharpness);
	    float b1 = max(a_height + (1.0 - blend) - ma, 0.0);
	    float b2 = max(b_height + blend - ma, 0.0);
	    return (a_value * b1 + b_value * b2) / (b1 + b2);
	} else {
		float contrast = 1.0 - blend_sharpness;
		float factor = (blend - contrast) / contrast;
		return mix(a_value, b_value, clamp(factor, 0.0, 1.0));
	}
}

float height_blend1(float a_value, float a_height, float b_value, float b_height, float blend) {
	if(height_blending) {
		float ma = max(a_height + (1.0 - blend), b_height + blend) - (1.001 - blend_sharpness);
	    float b1 = max(a_height + (1.0 - blend) - ma, 0.0);
	    float b2 = max(b_height + blend - ma, 0.0);
	    return (a_value * b1 + b_value * b2) / (b1 + b2);
	} else {
		float contrast = 1.0 - blend_sharpness;
		float factor = (blend - contrast) / contrast;
		return mix(a_value, b_value, clamp(factor, 0.0, 1.0));
	}
}

vec2 detiling(vec2 uv, vec2 uv_center, int mat_id, inout float normal_rotation){
	if ((_texture_detile_array[mat_id].x + _texture_detile_array[mat_id].y) >= 0.001){
		uv_center = floor(uv_center) + 0.5;
		float detile = fma(random(uv_center), 2.0, -1.0) * TAU; // -180deg to 180deg
		// Rotation
		float rotation = detile * _texture_detile_array[mat_id].x;
		uv = rotate_around(uv, uv_center, rotation);
		// Accumulate total rotation for normal rotation
		normal_rotation += rotation;
		// Shift
		uv += rotate(vec2(_texture_detile_array[mat_id].y * detile), cos(detile), sin(detile));
	}
	return uv;
}

vec2 rotate_plane(vec2 plane, float angle) {
	float new_x = dot(vec2(cos(angle), sin(angle)), plane);
	angle = fma(PI, 0.5, angle);
	float new_y = dot(vec2(cos(angle), sin(angle)), plane);
	return vec2(new_x, new_y);
}

// 2-4 lookups ( 2-6 with dual scaling )
void get_material(vec3 i_normal, float i_height, vec4 ddxy, uint control, ivec3 iuv_center, mat3 TANGENT_WORLD_MATRIX, out Material out_mat) {
	out_mat = Material(vec4(0.), vec4(0.), 0, 0, 0.0, 0.0);
	vec2 uv_center = vec2(iuv_center.xy);
	int region = iuv_center.z;
	
	// Translate uv center to the current region.
	uv_center += _region_locations[region] * _region_size;
	uv_center *= _vertex_spacing;
	
	vec2 base_uv;
	float p_angle = 0.0;
	
	if (region < 0 || i_normal.y >= projection_threshold || !enable_projection) {
		base_uv = v_vertex.xz;
	} else { // Project UVs and determine surface normal angle
		// Quantize the normal otherwise textures lose continuity across domains
		// Avoid potential singularitys
		#define SQRT3 1.73205080757
		vec3 p_normal = normalize(round(i_normal * SQRT3 * projection_angular_division));
		vec3 p_tangent = normalize(cross(p_normal, vec3(1e-6, 1.0, 1e-6)));
	    p_angle = atan(-i_normal.x, -i_normal.z);
		base_uv = vec2(dot(v_vertex, p_tangent), dot(v_vertex, normalize(cross(p_tangent, p_normal))));
		// Project uv_center for detiling
		vec3 i_center = vec3(uv_center.x, i_height, uv_center.y);
		uv_center = vec2(dot(i_center, p_tangent), dot(i_center, normalize(cross(p_tangent, p_normal))));
	}

//INSERT: AUTO_SHADER_TEXTURE_ID
//INSERT: TEXTURE_ID
	out_mat.nrm_depth = _texture_normal_depth_array[out_mat.base];

	// Control map scale & rotation, apply to both base and uv_center.
	// Define base scale from control map value as array index. 0.5 as baseline.
	float[8] scale_array = { 0.5, 0.4, 0.3, 0.2, 0.1, 0.8, 0.7, 0.6};
	float control_scale = scale_array[(control >>7u & 0x7u)];
	base_uv *= control_scale;
	uv_center *=  control_scale;
	ddxy *= control_scale;

	// Apply global uv rotation from control map
	float uv_rotation = float(control >>10u & 0xFu) / 16. * TAU;
	base_uv = rotate_around(base_uv, vec2(0), uv_rotation);
	uv_center = rotate_around(uv_center, vec2(0), uv_rotation);

	vec2 matUV = base_uv;
	vec4 albedo_ht = vec4(0.);
	vec4 normal_rg = vec4(0.5, 0.5, 1.0, 1.0);
	vec4 albedo_far = vec4(0.);
	vec4 normal_far = vec4(0.5, 0.5, 1.0, 1.0);
	float mat_scale = _texture_uv_scale_array[out_mat.base];
	float normal_angle = uv_rotation + p_angle;
	vec4 dd1 = ddxy;
	
//INSERT: UNI_SCALING_BASE
//INSERT: DUAL_SCALING_BASE
	// Apply color to base
	albedo_ht.rgb *= _texture_color_array[out_mat.base].rgb;

	out_mat.alb_ht = albedo_ht;
	out_mat.nrm_rg = normal_rg;

	if (out_mat.blend > 0.) {
		// 2 lookups
		// Setup overlay texture to blend
		float mat_scale2 = _texture_uv_scale_array[out_mat.over];
		float normal_angle2 = uv_rotation + p_angle;
		vec2 matUV2 = detiling(base_uv * mat_scale2, uv_center * mat_scale2, out_mat.over, normal_angle2);
		vec4 dd2 = ddxy * mat_scale2;
		dd2.xy = rotate_plane(dd2.xy, -normal_angle2);
		dd2.zw = rotate_plane(dd2.zw, -normal_angle2);
		vec4 albedo_ht2 = textureGrad(_texture_array_albedo, vec3(matUV2, float(out_mat.over)), dd2.xy, dd2.zw);
		vec4 normal_rg2 = textureGrad(_texture_array_normal, vec3(matUV2, float(out_mat.over)), dd2.xy, dd2.zw);

		// Unpack & rotate overlay normal for blending
		normal_rg2.xyz = unpack_normal(normal_rg2);
		normal_rg2.xz = rotate_plane(normal_rg2.xz, -normal_angle2);

//INSERT: DUAL_SCALING_OVERLAY
		// Apply color to overlay
		albedo_ht2.rgb *= _texture_color_array[out_mat.over].rgb;

		// apply world space normal weighting from base, to overlay layer
		if (world_space_normal_blend) {
			albedo_ht2.a *= bool(control >>3u & 0x1u) ? 1.0 : clamp((TANGENT_WORLD_MATRIX * normal_rg.xyz).y, 0.0, 1.0);
		}

		// Blend overlay and base
		out_mat.alb_ht = height_blend4(albedo_ht, albedo_ht.a, albedo_ht2, albedo_ht2.a, out_mat.blend);
		out_mat.nrm_rg = height_blend4(normal_rg, albedo_ht.a, normal_rg2, albedo_ht2.a, out_mat.blend);
		out_mat.nrm_depth = height_blend1(_texture_normal_depth_array[out_mat.base], albedo_ht.a,
			_texture_normal_depth_array[out_mat.over], albedo_ht2.a, out_mat.blend);
	}
	return;
}

float blend_weights(float weight, float detail) {
	weight = smoothstep(0.0, 1.0, weight);
	weight = sqrt(weight * 0.5);
	float result = max(0.1 * weight, fma(10.0, (weight + detail), 1.0f - (detail + 10.0)));
	return result;
}

void fragment() {
	// Recover UVs
	vec2 uv = UV;
	vec2 uv2 = UV2;
	
	// Lookup offsets, ID and blend weight
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
	
	vec3 base_ddx = dFdxCoarse(v_vertex);
	vec3 base_ddy = dFdyCoarse(v_vertex);
	vec4 base_derivatives = vec4(base_ddx.xz, base_ddy.xz);
	// Calculate the effective mipmap for regionspace, and when less than 0,
	// skip all extra lookups required for bilinear blend.
	float region_mip = log2(max(length(base_ddx.xz), length(base_ddy.xz)) * _vertex_density);
	bool bilerp = region_mip < 0.0;

	ivec3 indexUV[4];
	// control map lookups, used for some normal lookups as well
	indexUV[0] = get_region_uv(index_id + offsets.xy, FRAGMENT_PASS);
	indexUV[1] = get_region_uv(index_id + offsets.yy, FRAGMENT_PASS);
	indexUV[2] = get_region_uv(index_id + offsets.yx, FRAGMENT_PASS);
	indexUV[3] = get_region_uv(index_id + offsets.xx, FRAGMENT_PASS);
	
	// Terrain normals
	vec3 index_normal[4];
	float h[8];
	// allows additional derivatives, eg world noise, brush previews etc
	float u = 0.0;
	float v = 0.0;
	
//INSERT: WORLD_NOISE3	
	// Re-use the indexUVs for the first lookups, skipping some math. 3 lookups
	h[3] = texelFetch(_height_maps, indexUV[3], 0).r; // 0 (0,0)
	h[2] = texelFetch(_height_maps, indexUV[2], 0).r; // 1 (1,0)
	h[0] = texelFetch(_height_maps, indexUV[0], 0).r; // 2 (0,1)
	index_normal[3] = normalize(vec3(h[3] - h[2] + u, _vertex_spacing, h[3] - h[0] + v));

	// Set flat world normal - overriden if bilerp is true
	vec3 w_normal = index_normal[3];

	// Setting this here, instead of after the branch appears to be ~10% faster.
	// Likley as flat derivatives seem more cache friendly for texture lookups.
	if (enable_projection && indexUV[3].z > -1 && w_normal.y < projection_threshold) {
		vec3 p_tangent = normalize(cross(w_normal, vec3(0.0, 0.0, 1.0)));
		vec3 p_binormal = normalize(cross(p_tangent, w_normal));
		base_derivatives.xy = vec2(dot(base_ddx, p_tangent), dot(base_ddx, p_binormal));
		base_derivatives.zw = vec2(dot(base_ddy, p_tangent), dot(base_ddy, p_binormal));
	}
	
	// Adjust derivatives for mipmap bias and depth blur effect
	base_derivatives *=  mix(mipmap_bias,
		depth_blur + 1.,
		smoothstep(0.0, 1.0, (v_vertex_xz_dist - bias_distance) / bias_distance));

	// Colormap. 1 - 4 lookups
	#define COLOR_MAP vec4(1.0, 1.0, 1.0, 0.5)
	vec4 color_map;
	vec3 region_uv = get_region_uv2(uv2);
	color_map = region_uv.z > -1.0 && !bilerp ? textureLod(_color_maps, region_uv, region_mip) : COLOR_MAP;

	// Branching smooth normals and interpolated color map must be done seperatley with unmodified weights.
	if (bilerp) {
		vec4 col_map[4];
		col_map[3] = indexUV[3].z > -1 ? texelFetch(_color_maps, indexUV[3], 0) : COLOR_MAP;
		color_map = col_map[3];
		#ifdef FILTER_LINEAR
		col_map[0] = indexUV[0].z > -1 ? texelFetch(_color_maps, indexUV[0], 0) : COLOR_MAP;
		col_map[1] = indexUV[1].z > -1 ? texelFetch(_color_maps, indexUV[1], 0) : COLOR_MAP;
		col_map[2] = indexUV[2].z > -1 ? texelFetch(_color_maps, indexUV[2], 0) : COLOR_MAP;
		
		color_map = 
			col_map[0] * weights[0] +
			col_map[1] * weights[1] +
			col_map[2] * weights[2] +
			col_map[3] * weights[3] ;
		#endif

		// 5 lookups
		// Fetch the additional required height values for smooth normals
		h[1] = texelFetch(_height_maps, indexUV[1], 0).r; // 3 (1,1)
		h[4] = texelFetch(_height_maps, get_region_uv(index_id + offsets.yz, FRAGMENT_PASS), 0).r; // 4 (1,2)
		h[5] = texelFetch(_height_maps, get_region_uv(index_id + offsets.zy, FRAGMENT_PASS), 0).r; // 5 (2,1)
		h[6] = texelFetch(_height_maps, get_region_uv(index_id + offsets.zx, FRAGMENT_PASS), 0).r; // 6 (2,0)
		h[7] = texelFetch(_height_maps, get_region_uv(index_id + offsets.xz, FRAGMENT_PASS), 0).r; // 7 (0,2)

		// Calculate the normal for the remaining index ids.
		index_normal[0] = normalize(vec3(h[0] - h[1] + u, _vertex_spacing, h[0] - h[7] + v));
		index_normal[1] = normalize(vec3(h[1] - h[5] + u, _vertex_spacing, h[1] - h[4] + v));
		index_normal[2] = normalize(vec3(h[2] - h[6] + u, _vertex_spacing, h[2] - h[1] + v));

		// Set interpolated world normal
		w_normal = 
			index_normal[0] * weights[0] +
			index_normal[1] * weights[1] +
			index_normal[2] * weights[2] +
			index_normal[3] * weights[3] ;
	}
		
	// Apply terrain normals
	vec3 w_tangent = normalize(cross(w_normal, vec3(0.0, 0.0, 1.0)));
	vec3 w_binormal = normalize(cross(w_normal, w_tangent));
	NORMAL = mat3(VIEW_MATRIX) * w_normal;
	TANGENT = mat3(VIEW_MATRIX) * w_tangent;
	BINORMAL = mat3(VIEW_MATRIX) * w_binormal;
	
	// Used for material world space normal map blending
	mat3 TANGENT_WORLD_MATRIX = mat3(w_tangent, w_normal, w_binormal);

	// Get last index
	// 1 lookup + get_material() = 3-7 total
	uint control[4];
	control[3] = texelFetch(_control_maps, indexUV[3], 0).r;

	Material mat[4];
	get_material(index_normal[3], h[3], base_derivatives, control[3], indexUV[3], TANGENT_WORLD_MATRIX, mat[3]);

	vec4 albedo_height = mat[3].alb_ht;
	vec4 normal_rough = mat[3].nrm_rg;
	float normal_map_depth = mat[3].nrm_depth;

	// Otherwise do full bilinear interpolation
	if (bilerp) {	
		// 4 lookups + 3x get_material() = 10-22 total
		control[0] = texelFetch(_control_maps, indexUV[0], 0).r;
		control[1] = texelFetch(_control_maps, indexUV[1], 0).r;
		control[2] = texelFetch(_control_maps, indexUV[2], 0).r;

		get_material(index_normal[0], h[0], base_derivatives, control[0], indexUV[0], TANGENT_WORLD_MATRIX, mat[0]);
		get_material(index_normal[1], h[1], base_derivatives, control[1], indexUV[1], TANGENT_WORLD_MATRIX, mat[1]);
		get_material(index_normal[2], h[2], base_derivatives, control[2], indexUV[2], TANGENT_WORLD_MATRIX, mat[2]);

		// rebuild weights for detail and noise blending
		float noise3 = texture(noise_texture, uv * noise3_scale).r * blend_sharpness;
		#define PARABOLA(x) (4.0 * x * (1.0 - x))
		weights = smoothstep(0, 1, weights);
		weights = vec4(
			blend_weights(weights.x + PARABOLA(weights.x) * noise3, mat[0].alb_ht.a),
			blend_weights(weights.y + PARABOLA(weights.y) * noise3, mat[1].alb_ht.a),
			blend_weights(weights.z + PARABOLA(weights.z) * noise3, mat[2].alb_ht.a),
			blend_weights(weights.w + PARABOLA(weights.w) * noise3, mat[3].alb_ht.a)
		);
		#undef PARABOLA
		// renormalize weights
		weights *= 1.0 / (weights.x + weights.y + weights.z + weights.w);
	
		// Interpolate Albedo/Height/Normal/Roughness
		albedo_height = 
			mat[0].alb_ht * weights[0] +
			mat[1].alb_ht * weights[1] +
			mat[2].alb_ht * weights[2] +
			mat[3].alb_ht * weights[3] ;
	
		normal_rough = 
			mat[0].nrm_rg * weights[0] +
			mat[1].nrm_rg * weights[1] +
			mat[2].nrm_rg * weights[2] +
			mat[3].nrm_rg * weights[3] ;

		normal_map_depth = 
			mat[0].nrm_depth * weights[0] +
			mat[1].nrm_depth * weights[1] +
			mat[2].nrm_depth * weights[2] +
			mat[3].nrm_depth * weights[3] ;
	}
	
	// Macro variation. 2 lookups
	vec3 macrov = vec3(1.);
	if (enable_macro_variation) {
		float noise1 = texture(noise_texture, rotate(uv * noise1_scale * .1, cos(noise1_angle), sin(noise1_angle)) + noise1_offset).r;
		float noise2 = texture(noise_texture, uv * noise2_scale * .1).r;
		macrov = mix(macro_variation1, vec3(1.), noise1);
		macrov *= mix(macro_variation2, vec3(1.), noise2);
		macrov = mix(vec3(1.0), macrov, clamp(w_normal.y + macro_variation_slope, 0., 1.));
	}
	
	// Wetness/roughness modifier, converting 0 - 1 range to -1 to 1 range
	float roughness = fma(color_map.a - 0.5, 2.0, normal_rough.a);
	
	// Apply PBR
	ALBEDO = albedo_height.rgb * color_map.rgb * macrov;
	ROUGHNESS = roughness;
	SPECULAR = 1. - normal_rough.a;
	NORMAL_MAP = pack_normal(normal_rough.rgb);
	NORMAL_MAP_DEPTH = normal_map_depth;

}

)"
