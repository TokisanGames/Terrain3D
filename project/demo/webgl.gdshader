shader_type spatial;
render_mode blend_mix,depth_draw_opaque,cull_back,diffuse_burley,specular_schlick_ggx,skip_vertex_transform;

// COMPATIBILITY_DEFINES - This code block is added and removed by the editor, do not modify it.
// This is added automatically when in compatibility mode. It is not required for Mobile or Forward+.
#define IS_COMPATIBILITY
#define fma(a, b, c) (a) * (b) + (c)
#define dFdxCoarse(a) dFdx(a)
#define dFdyCoarse(a) dFdy(a)
#define textureQueryLod(a, b) vec4(0.0)
#define texelOffset(b, c) ivec3(ivec2(b.xy * _region_size + c - 0.4979), int(b.z))
#define textureGather(a, b) vec4( \
    texelFetch(a, texelOffset(b, vec2(0,1)), 0).r, \
    texelFetch(a, texelOffset(b, vec2(1,1)), 0).r, \
    texelFetch(a, texelOffset(b, vec2(1,0)), 0).r, \
    texelFetch(a, texelOffset(b, vec2(0,0)), 0).r  \
)
// END_COMPAT_DEFINES

/* This shader is generated based upon the debug views you have selected.
 * The terrain function depends on this shader. So don't change:
 * - vertex positioning in vertex()
 * - terrain normal calculation in fragment()
 * - the last function being fragment() as the editor injects code before the closing }
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
uniform float _region_texel_size = 0.0009765625; // = 1/1024
uniform float _vertex_spacing = 1.0;
uniform float _vertex_density = 1.0; // = 1/_vertex_spacing
uniform int _region_map_size = 32;
uniform int _region_map[1024];
uniform vec2 _region_locations[1024];
uniform highp sampler2DArray _height_maps : repeat_disable;
uniform highp sampler2DArray _control_maps : repeat_disable;
uniform highp sampler2DArray _color_maps : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform highp sampler2DArray _texture_array_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform highp sampler2DArray _texture_array_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform highp sampler2D noise_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;

uniform float _texture_uv_scale_array[32];
uniform float _texture_detile_array[32];
uniform vec4 _texture_color_array[32];
uniform uint _background_mode = 1u;  // NONE = 0, FLAT = 1, NOISE = 2
uniform uint _mouse_layer = 0x80000000u; // Layer 32

// Public uniforms
uniform float vertex_normals_distance : hint_range(0, 1024) = 128.0;
uniform bool height_blending = true;
uniform float blend_sharpness : hint_range(0, 1) = 0.87;
uniform float auto_slope : hint_range(0, 10) = 1.0;
uniform float auto_height_reduction : hint_range(0, 1) = 0.1;
uniform int auto_base_texture : hint_range(0, 31) = 0;
uniform int auto_overlay_texture : hint_range(0, 31) = 1;

uniform int dual_scale_texture : hint_range(0,31) = 0;
uniform float dual_scale_reduction : hint_range(0.001,1) = 0.3;
uniform float tri_scale_reduction : hint_range(0.001,1) = 0.3;
uniform float dual_scale_far : hint_range(0,1000) = 170.0;
uniform float dual_scale_near : hint_range(0,1000) = 100.0;

uniform vec3 macro_variation1 : source_color = vec3(1.);
uniform vec3 macro_variation2 : source_color = vec3(1.);

// Generic noise at 3 scales, which can be used for anything 
uniform float noise1_scale : hint_range(0.001, 1.) = 0.04;	// Used for macro variation 1. Scaled up 10x
uniform float noise1_angle : hint_range(0, 6.283) = 0.;
uniform vec2 noise1_offset = vec2(0.5);
uniform float noise2_scale : hint_range(0.001, 1.) = 0.076;	// Used for macro variation 2. Scaled up 10x
uniform float noise3_scale : hint_range(0.001, 1.) = 0.225;  // Used for texture blending edge.

// Varyings & Types

struct Material {
	vec4 alb_ht;
	vec4 nrm_rg;
	int base;
	int over;
	float blend;
};

varying flat vec3 v_vertex;	// World coordinate vertex location
varying flat vec3 v_camera_pos;
varying float v_vertex_xz_dist;
varying flat ivec3 v_region;
varying flat vec2 v_uv_offset;
varying flat vec2 v_uv2_offset;
varying vec3 v_normal;
varying float v_region_border_mask;

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

// World Noise
uniform float world_noise_region_blend : hint_range(0.05, 0.95, 0.01) = 0.33;
uniform int world_noise_max_octaves : hint_range(0, 15) = 4;
uniform int world_noise_min_octaves : hint_range(0, 15) = 2;
uniform float world_noise_lod_distance : hint_range(0, 40000, 1) = 7500.;
uniform float world_noise_scale : hint_range(0.25, 20, 0.01) = 5.0;
uniform float world_noise_height : hint_range(0, 1000, 0.1) = 64.0;
uniform vec3 world_noise_offset = vec3(0.0);

// Takes in UV2 region space coordinates, returns 1.0 or 0.0 if a region is present or not.
float check_region(const vec2 uv2) {
	ivec2 pos = ivec2(floor(uv2)) + (_region_map_size / 2);
	int layer_index = 0;
	if (uint(pos.x | pos.y) < uint(_region_map_size)) {
		layer_index = clamp(_region_map[ pos.y * _region_map_size + pos.x ] - 1, -1, 0) + 1;
	}
	return float(layer_index);
}

// Takes in UV2 region space coordinates, returns a blend value (0 - 1 range) between empty, and valid regions
float region_blend(vec2 uv2) {
	uv2 -= 0.5;
	const vec2 offset = vec2(0.0,1.0);
	float a = check_region(uv2 + offset.xy);
	float b = check_region(uv2 + offset.yy);
	float c = check_region(uv2 + offset.yx);
	float d = check_region(uv2 + offset.xx);
	vec2 w = smoothstep(vec2(0.0), vec2(1.0), fract(uv2));
	float blend = mix(mix(d, c, w.x), mix(a, b, w.x), w.y);
    return 1.0 - blend;
}

float hashf(float f) {
	return fract(sin(f) * 1e4);
}

float hashv2(vec2 v) {
	return fract(1e4 * sin(17.0 * v.x + v.y * 0.1) * (0.1 + abs(sin(v.y * 13.0 + v.x))));
}

// https://iquilezles.org/articles/morenoise/
vec3 noise2D(vec2 x) {
    vec2 f = fract(x);
    // Quintic Hermine Curve.  Similar to SmoothStep()
    vec2 u = f*f*f*(f*(f*6.0-15.0)+10.0);
    vec2 du = 30.0*f*f*(f*(f-2.0)+1.0);

    vec2 p = floor(x);

	// Four corners in 2D of a tile
	float a = hashv2( p+vec2(0,0) );
    float b = hashv2( p+vec2(1,0) );
    float c = hashv2( p+vec2(0,1) );
    float d = hashv2( p+vec2(1,1) );

    // Mix 4 corner percentages
    float k0 =   a;
    float k1 =   b - a;
    float k2 =   c - a;
    float k3 =   a - b - c + d;
    return vec3( k0 + k1 * u.x + k2 * u.y + k3 * u.x * u.y,
                du * ( vec2(k1, k2) + k3 * u.yx) );
}

float world_noise(vec2 p) {
    float a = 0.0;
    float b = 1.0;
    vec2  d = vec2(0.0);

    int octaves = int( clamp(
	float(world_noise_max_octaves) - floor(v_vertex_xz_dist/(world_noise_lod_distance)),
    float(world_noise_min_octaves), float(world_noise_max_octaves)) );
	
    for( int i=0; i < octaves; i++ ) {
        vec3 n = noise2D(p);
        d += n.yz;
        a += b * n.x / (1.0 + dot(d,d));
        b *= 0.5;
        p = mat2( vec2(0.8, -0.6), vec2(0.6, 0.8) ) * p * 2.0;
    }
    return a;
}

float get_noise_height(const vec2 uv) {
	float weight = region_blend(uv);
	// only calculate world noise when it could be visibile.
	if (weight <= 1.0 - world_noise_region_blend) {
		return 0.0;
	}
	//TODO: Offset/scale UVs are semi-dependent upon region size 1024. Base on v_vertex.xz instead
	float noise = world_noise((uv + world_noise_offset.xz * 1024. / _region_size) * world_noise_scale * _region_size / 1024. * .1) *
            world_noise_height * 10. + world_noise_offset.y * 100.;
	weight = smoothstep(1.0 - world_noise_region_blend, 1.0, weight);
	return mix(0.0, noise, weight);
}

// World Noise end

// 1 lookup
float get_height(vec2 uv) {
	highp float height = 0.0;
	vec3 region = get_region_uv2(uv);
	if (region.z >= 0.) {
		height = texture(_height_maps, region).r;
	}
	// World Noise
   	if (_background_mode == 2u) {
	    height += get_noise_height(uv);
    }
 	return height;
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
	uint control = floatBitsToUint(texelFetch(_control_maps, v_region, 0).r);
	bool hole = bool(control >>2u & 0x1u);

	// Show holes to all cameras except mouse camera (on exactly 1 layer)
	if ( !(CAMERA_VISIBLE_LAYERS == _mouse_layer) && 
			(hole || (_background_mode == 0u && (get_region_uv(UV - _region_texel_size) & v_region).z < 0))) {
		VERTEX.x = 0. / 0.;
	} else {		
		// Set final vertex height & calculate vertex normals. 3 lookups.
		VERTEX.y = get_height(UV2);
		v_vertex.y = VERTEX.y;
		v_normal = vec3(
			v_vertex.y - get_height(UV2 + vec2(_region_texel_size, 0)),
			_vertex_spacing,
			v_vertex.y - get_height(UV2 + vec2(0, _region_texel_size))
		);
		// Due to a bug caused by the GPUs linear interpolation across edges of region maps,
		// mask region edges and use vertex normals only across region boundaries.
		v_region_border_mask = mod(UV.x + 2.5, _region_size) - fract(UV.x) < 5.0 || mod(UV.y + 2.5, _region_size) - fract(UV.y) < 5.0 ? 1. : 0.;
	}
		
	// Transform UVs to local to avoid poor precision during varying interpolation.
	v_uv_offset = MODEL_MATRIX[3].xz * _vertex_density;
	UV -= v_uv_offset;
	v_uv2_offset = v_uv_offset * _region_texel_size;
	UV2 -= v_uv2_offset;

	// Convert model space to view space w/ skip_vertex_transform render mode
	VERTEX = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX = (VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	NORMAL = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	BINORMAL = normalize((MODELVIEW_MATRIX * vec4(BINORMAL, 0.0)).xyz);
	TANGENT = normalize((MODELVIEW_MATRIX * vec4(TANGENT, 0.0)).xyz);
}

////////////////////////
// Fragment
////////////////////////

// 0 - 3 lookups
vec3 get_normal(vec2 uv, out vec3 tangent, out vec3 binormal) {
	float u, v, height;
	vec3 normal;
	// Use vertex normals within radius of vertex_normals_distance, and along region borders.
	if ((v_region_border_mask > 0.5 || v_vertex_xz_dist < vertex_normals_distance) && v_region.z >= 0) {
		normal = normalize(v_normal);
	} else {
		height = get_height(uv);
		u = height - get_height(uv + vec2(_region_texel_size, 0));
		v = height - get_height(uv + vec2(0, _region_texel_size));
		normal = normalize(vec3(u, _vertex_spacing, v));
	}
	tangent = normalize(cross(normal, vec3(0, 0, 1)));
	binormal = normalize(cross(normal, tangent));
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

// Moves a point around a pivot point.
vec2 rotate_around(vec2 point, vec2 pivot, float angle){
	float x = pivot.x + (point.x - pivot.x) * cos(angle) - (point.y - pivot.y) * sin(angle);
	float y = pivot.y + (point.x - pivot.x) * sin(angle) + (point.y - pivot.y) * cos(angle);
	return vec2(x, y);
}

vec4 height_blend(vec4 a_value, float a_height, vec4 b_value, float b_height, float blend) {
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
	if (_texture_detile_array[mat_id] >= 0.001){
		uv_center = floor(uv_center) + 0.5;
		float detile = (random(uv_center) - 0.5) * 2.0 * TAU * _texture_detile_array[mat_id]; // -180deg to 180deg
		uv = rotate_around(uv, uv_center, detile);
		// Accumulate total rotation for normal rotation
		normal_rotation += detile;
	}
	return uv;
}

vec2 rotate_normal(vec2 normal, float angle) {
	angle += PI * 0.5;
	float new_y = dot(vec2(cos(angle), sin(angle)), normal);
	angle -= PI * 0.5;
	float new_x = dot(vec2(cos(angle) ,sin(angle)) ,normal);
	return vec2(new_x, new_y);
}

// 2-4 lookups
void get_material(vec2 base_uv, uint control, ivec3 iuv_center, vec3 normal, out Material out_mat) {
	out_mat = Material(vec4(0.), vec4(0.), 0, 0, 0.0);
	vec2 uv_center = vec2(iuv_center.xy);
	int region = iuv_center.z;

	// Enable Autoshader if outside regions or painted in regions, otherwise manual painted
	bool auto_shader = region < 0 || bool(control & 0x1u);
	out_mat.base = int(auto_shader) * auto_base_texture + int(!auto_shader) * int(control >>27u & 0x1Fu);
	out_mat.over = int(auto_shader) * auto_overlay_texture + int(!auto_shader) * int(control >> 22u & 0x1Fu);
	out_mat.blend = float(auto_shader) * clamp(
			dot(vec3(0., 1., 0.), normal * auto_slope * 2. - (auto_slope * 2. - 1.)) 
			- auto_height_reduction * .01 * v_vertex.y // Reduce as vertices get higher
			, 0., 1.) + 
			 float(!auto_shader) * float(control >>14u & 0xFFu) * 0.003921568627450; // 1./255.0		

	// Control map scale & rotation, apply to both base and 
	// uv_center. Translate uv center to the current region.
	uv_center += _region_locations[region] * _region_size;
	// Define base scale from control map value as array index. 0.5 as baseline.
	float[8] scale_array = { 0.5, 0.4, 0.3, 0.2, 0.1, 0.8, 0.7, 0.6};
	float control_scale = scale_array[(control >>7u & 0x7u)];
	base_uv *= control_scale;
	uv_center *=  control_scale;
	// calculate baseline derivatives
	vec2 ddx = dFdxCoarse(base_uv);
	vec2 ddy = dFdyCoarse(base_uv);
	// Apply global uv rotation from control map.
	float uv_rotation = float(control >>10u & 0xFu) / 16. * TAU;
	base_uv = rotate_around(base_uv, vec2(0), uv_rotation);
	uv_center = rotate_around(uv_center, vec2(0), uv_rotation);

	vec2 matUV = base_uv;
	vec4 albedo_ht = vec4(0.);
	vec4 normal_rg = vec4(0.5f, 0.5f, 1.0f, 1.0f);
	vec4 albedo_far = vec4(0.);
	vec4 normal_far = vec4(0.5f, 0.5f, 1.0f, 1.0f);
	float mat_scale = _texture_uv_scale_array[out_mat.base];
	float normal_angle = uv_rotation;
	vec2 ddx1 = ddx;
	vec2 ddy1 = ddy;
	
	// If dual scaling, apply to base texture
	if(region < 0) {
		mat_scale *= tri_scale_reduction;
	}
	//each time we change scale, recalculate antitiling from baseline to maintain continuity.
	matUV = detiling(base_uv * mat_scale, uv_center * mat_scale, out_mat.base, normal_angle);
	ddx1 *= mat_scale;
	ddy1 *= mat_scale;
	albedo_ht = textureGrad(_texture_array_albedo, vec3(matUV, float(out_mat.base)), ddx1, ddy1);
	normal_rg = textureGrad(_texture_array_normal, vec3(matUV, float(out_mat.base)), ddx1, ddy1);

	// Unpack & rotate base normal for blending
	normal_rg.xz = unpack_normal(normal_rg).xz;
	normal_rg.xz = rotate_normal(normal_rg.xz, normal_angle);

	if(out_mat.base == dual_scale_texture || out_mat.over == dual_scale_texture) {
		mat_scale *= dual_scale_reduction;
		ddx1 *= dual_scale_reduction;
		ddy1 *= dual_scale_reduction;
		float dual_scale_normal = uv_rotation; //do not add near & far rotations
		// Do not apply detiling if tri-scale reduction occurs.
		matUV = region < 0 ? base_uv * mat_scale : detiling(base_uv * mat_scale, uv_center * mat_scale, dual_scale_texture, dual_scale_normal);
		albedo_far = textureGrad(_texture_array_albedo, vec3(matUV, float(dual_scale_texture)), ddx1, ddy1);
		normal_far = textureGrad(_texture_array_normal, vec3(matUV, float(dual_scale_texture)), ddx1, ddy1);

		// Unpack & rotate dual scale normal for blending
		normal_far.xz = unpack_normal(normal_far).xz;
		normal_far.xz = rotate_normal(normal_far.xz, dual_scale_normal);
	}

	float far_factor = clamp(smoothstep(dual_scale_near, dual_scale_far, length(v_vertex - v_camera_pos)), 0.0, 1.0);
	if(out_mat.base == dual_scale_texture) {
		albedo_ht = mix(albedo_ht, albedo_far, far_factor);
		normal_rg = mix(normal_rg, normal_far, far_factor);
	}

	// Apply color to base
	albedo_ht.rgb *= _texture_color_array[out_mat.base].rgb;

	// Setup overlay texture to blend
	float mat_scale2 = _texture_uv_scale_array[out_mat.over];
	float normal_angle2 = uv_rotation;
	vec2 matUV2 = detiling(base_uv * mat_scale2, uv_center * mat_scale2, out_mat.over, normal_angle2);
	vec2 ddx2 = ddx * mat_scale2;
	vec2 ddy2 = ddy * mat_scale2;
	vec4 albedo_ht2 = textureGrad(_texture_array_albedo, vec3(matUV2, float(out_mat.over)), ddx2, ddy2);
	vec4 normal_rg2 = textureGrad(_texture_array_normal, vec3(matUV2, float(out_mat.over)), ddx2, ddy2);

	// Though it would seem having the above lookups in this block, or removing the branch would
	// be more optimal, the first introduces artifacts #276, and the second is noticably slower. 
	// It seems the branching off dual scaling and the color array lookup is more optimal.
	if (out_mat.blend > 0.f) {
		// Unpack & rotate overlay normal for blending
		normal_rg2.xz = unpack_normal(normal_rg2).xz;
		normal_rg2.xz = rotate_normal(normal_rg2.xz, normal_angle2);

		// If dual scaling, apply to overlay texture
		if(out_mat.over == dual_scale_texture) {
			albedo_ht2 = mix(albedo_ht2, albedo_far, far_factor);
			normal_rg2 = mix(normal_rg2, normal_far, far_factor);
		}

		// Apply color to overlay
		albedo_ht2.rgb *= _texture_color_array[out_mat.over].rgb;

		// Blend overlay and base
		albedo_ht = height_blend(albedo_ht, albedo_ht.a, albedo_ht2, albedo_ht2.a, out_mat.blend);
		normal_rg = height_blend(normal_rg, albedo_ht.a, normal_rg2, albedo_ht2.a, out_mat.blend);
	}
	
	// Repack normals and return material
	normal_rg = pack_normal(normal_rg.xyz, normal_rg.a);
	out_mat.alb_ht = albedo_ht;
	out_mat.nrm_rg = normal_rg;
	return;
}

float blend_weights(float weight, float detail) {
	weight = smoothstep(0.0, 1.0, weight);
	weight = sqrt(weight * 0.5);
	float result = max(0.1 * weight, 10.0 * (weight + detail) + 1.0f - (detail + 10.0));
	return result;
}

void fragment() {
	// Recover UVs
	vec2 uv = UV + v_uv_offset;
	vec2 uv2 = UV2 + v_uv2_offset;

	// Calculate Terrain Normals. 4 lookups
	vec3 w_normal = normalize(v_normal);
	vec3 w_tangent = normalize(cross(w_normal, vec3(0, 0, 1)));
	vec3 w_binormal = normalize(cross(w_normal, w_tangent));
	NORMAL = mat3(VIEW_MATRIX) * w_normal;
	TANGENT = mat3(VIEW_MATRIX) * w_tangent;
	BINORMAL = mat3(VIEW_MATRIX) * w_binormal;
		
	// Idenfity 4 vertices surrounding this pixel
	vec2 texel_pos = uv;
	highp vec2 texel_pos_floor = floor(uv);
	
	// Create a cross hatch grid of alternating 0/1 horizontal and vertical stripes 1 unit wide in XY 
	vec4 mirror = vec4(fract(texel_pos_floor * 0.5) * 2.0, 1.0, 1.0);
	// And the opposite grid in ZW
	mirror.zw = vec2(1.0) - mirror.xy;

	// Get the region and control map ID for the vertices
	ivec3 indexUV[4] = {
		get_region_uv(texel_pos_floor + mirror.xy),
		get_region_uv(texel_pos_floor + mirror.xw),
		get_region_uv(texel_pos_floor + mirror.zy),
		get_region_uv(texel_pos_floor + mirror.zw)
	};

	// Lookup adjacent vertices. 4 lookups
	uint control[4] = {
		floatBitsToUint(texelFetch(_control_maps, indexUV[0], 0).r),
		floatBitsToUint(texelFetch(_control_maps, indexUV[1], 0).r),
		floatBitsToUint(texelFetch(_control_maps, indexUV[2], 0).r),
		floatBitsToUint(texelFetch(_control_maps, indexUV[3], 0).r)
	};

	// Get the textures for each vertex. 8-16 lookups (2-4 ea)
	Material mat[4];
	get_material(uv, control[0], indexUV[0], w_normal, mat[0]);
	get_material(uv, control[1], indexUV[1], w_normal, mat[1]);
	get_material(uv, control[2], indexUV[2], w_normal, mat[2]);
	get_material(uv, control[3], indexUV[3], w_normal, mat[3]);

	// Calculate weight for the pixel position between the vertices
	// Bilinear interpolation of difference of uv and floor(uv)
	vec2 weights1 = clamp(texel_pos - texel_pos_floor, 0, 1);
	weights1 = mix(weights1, vec2(1.0) - weights1, mirror.xy);
	vec2 weights0 = vec2(1.0) - weights1;
	// Adjust final weights by texture's height/depth + noise. 1 lookup
	float noise3 = texture(noise_texture, uv*noise3_scale).r;
	vec4 weights;
	weights.x = blend_weights(weights0.x * weights0.y, clamp(mat[0].alb_ht.a + noise3, 0., 1.));
	weights.y = blend_weights(weights0.x * weights1.y, clamp(mat[1].alb_ht.a + noise3, 0., 1.));
	weights.z = blend_weights(weights1.x * weights0.y, clamp(mat[2].alb_ht.a + noise3, 0., 1.));
	weights.w = blend_weights(weights1.x * weights1.y, clamp(mat[3].alb_ht.a + noise3, 0., 1.));
	float weight_sum = weights.x + weights.y + weights.z + weights.w;
	float weight_inv = 1.0 / weight_sum;

	// Weighted average of albedo & height
	vec4 albedo_height = weight_inv * (
		mat[0].alb_ht * weights.x +
		mat[1].alb_ht * weights.y +
		mat[2].alb_ht * weights.z +
		mat[3].alb_ht * weights.w );

	// Weighted average of normal & rough
	vec4 normal_rough = weight_inv * (
		mat[0].nrm_rg * weights.x +
		mat[1].nrm_rg * weights.y +
		mat[2].nrm_rg * weights.z +
		mat[3].nrm_rg * weights.w );

	// Determine if we're in a region or not (region_uv.z>0)
	vec3 region_uv = get_region_uv2(uv2);

	// Colormap. 1 lookup
	vec4 color_map = vec4(1., 1., 1., .5);
	if (region_uv.z >= 0.) {
		float lod = textureQueryLod(_color_maps, uv2.xy).y;
		color_map = textureLod(_color_maps, region_uv, lod);
	}

	// Macro variation. 2 Lookups
	float noise1 = texture(noise_texture, rotate(uv*noise1_scale * .1, cos(noise1_angle), sin(noise1_angle)) + noise1_offset).r;
	float noise2 = texture(noise_texture, uv*noise2_scale * .1).r;
	vec3 macrov = mix(macro_variation1, vec3(1.), clamp(noise1 + v_vertex_xz_dist * .0002, 0., 1.));
	macrov *= mix(macro_variation2, vec3(1.), clamp(noise2 + v_vertex_xz_dist * .0002, 0., 1.));

	// Wetness/roughness modifier, converting 0-1 range to -1 to 1 range
	float roughness = fma(color_map.a - 0.5, 2.0, normal_rough.a);

	// Apply PBR
	ALBEDO = albedo_height.rgb * color_map.rgb * macrov;
	ROUGHNESS = roughness;
	SPECULAR = 1. - normal_rough.a;
	NORMAL_MAP = normal_rough.rgb;
	NORMAL_MAP_DEPTH = 1.0;

}

