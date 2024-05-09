// Copyright © 2023 Cory Petkovsek, Roope Palmroos, and Contributors.

R"(

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

#if defined(BG_WORLD_ENABLED)	// WORLD_NOISE1

uniform sampler2D _region_blend_map : hint_default_black, filter_linear, repeat_disable;

float hashf(float f) {
	return fract(sin(f) * 1e4); }

float hashv2(vec2 v) {
	return fract(1e4 * sin(17.0 * v.x + v.y * 0.1) * (0.1 + abs(sin(v.y * 13.0 + v.x)))); }

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
                du * ( vec2(k1, k2) + k3 * u.yx) ); }

float bg_world(vec2 p) {
    float a = 0.0;
    float b = 1.0;
    vec2  d = vec2(0.0);
    int octaves = int( clamp(
	float(_bg_world_max_octaves) - floor(v_vertex_xz_dist/(_bg_world_lod_distance)),
    float(_bg_world_min_octaves), float(_bg_world_max_octaves)) );
    for( int i=0; i < octaves; i++ ) {
        vec3 n = noise2D(p);
        d += n.yz;
        a += b * n.x / (1.0 + dot(d,d));
        b *= 0.5;
        p = mat2( vec2(0.8, -0.6), vec2(0.6, 0.8) ) * p * 2.0; }
    return a; }

// World Noise end
#endif

// 1 lookup
float get_height(vec2 uv) {
	highp float height = 0.0;
	vec3 region = get_region_uv2(uv);
	if (region.z >= 0.) {
		height = texture(_height_maps, region).r; }
#if defined(BG_WORLD_ENABLED)	// WORLD_NOISE2
	// World Noise
   	if(_bg_world_fill == 2u) {
	    float weight = texture(_region_blend_map, (uv/float(_region_map_size))+0.5).r;
	    float rmap_half_size = float(_region_map_size)*.5;
	    if(abs(uv.x) > rmap_half_size+.5 || abs(uv.y) > rmap_half_size+.5) {
		    weight = 0.; } 
		else {
		    if(abs(uv.x) > rmap_half_size-.5) {
			    weight = mix(weight, 0., abs(uv.x) - (rmap_half_size-.5)); }
		    if(abs(uv.y) > rmap_half_size-.5) {
			    weight = mix(weight, 0., abs(uv.y) - (rmap_half_size-.5)); } }
	    height = mix(height, bg_world((uv+_bg_world_offset.xz) * _bg_world_scale*.1) *
            _bg_world_height*10. + _bg_world_offset.y*100.,
		    clamp(smoothstep(_bg_world_blend_near, _bg_world_blend_far, 1.0 - weight), 0.0, 1.0)); }
#endif
 	return height; }

// 0 - 3 lookups
vec3 get_normal(vec2 uv, out vec3 tangent, out vec3 binormal) {
	float u, v, height;
	vec3 normal;
	// Use vertex normals within radius of _normals_distance, and along region borders.
	if (v_region_border_mask > 0.5 
	#if defined(NORMALS_BY_DISTANCE) 
	|| v_vertex_xz_dist < _normals_distance
	#endif
	) {
		normal = normalize(v_normal);
	} else {
		height = get_height(uv);
		u = height - get_height(uv + vec2(_region_texel_size, 0));
		v = height - get_height(uv + vec2(0, _region_texel_size));
		normal = normalize(vec3(u, _mesh_vertex_spacing, v));
	}
	tangent = cross(normal, vec3(0, 0, 1));
	binormal = cross(normal, tangent);
	return normal; }

//  _____________
//_/   VERTEX    \____________________________________________________
//                                                                    :
void vertex() {	
// *** INIT STANDARD VARYINGS
#include "res://addons/terrain_3d/shader/vertex/t3d_vertex_init_varyings.gdshaderinc"
// ---
// *** EARLY DISCARD TEST 
// This discards vertices that are marked as being a hole, or are within a region that
// is empty when the background mode is set to none, and checks camera layer versus mouse 
// layer for editor functionality.
// ---
#include "res://addons/terrain_3d/shader/vertex/t3d_vertex_early_discard_test.gdshaderinc"
{	// <- (!!!)
	// ---------------------------------------------------
	// [ BEGIN ] PRIMARY PRE-TESTED TERRAIN VERTEX CODE
	// ---

	// Set final vertex height & calculate vertex normals. 3 lookups.
	VERTEX.y = get_height(UV2);
	v_vertex.y = VERTEX.y;
	v_normal = vec3(
		v_vertex.y - get_height(UV2 + vec2(_region_texel_size,0)),
		_mesh_vertex_spacing,
		v_vertex.y - get_height(UV2 + vec2(0,_region_texel_size))
	);
	// Due to a bug caused by the GPUs linear interpolation across edges of region maps,
	// mask region edges and use vertex normals only across region boundaries.
	v_region_border_mask = mod(UV.x+2.5,_region_size) - fract(UV.x) < 5.0 || mod(UV.y+2.5,_region_size) - fract(UV.y) < 5.0 ? 1. : 0.;

	// [ END ] PRIMARY PRE-TESTED TERRAIN VERTEX CODE
	// ---------------------------------------------------
}	// <- (!!!)
// ---
	// Transform UVs to local to avoid poor precision during varying interpolation.
	v_uv_offset = MODEL_MATRIX[3].xz * _mesh_vertex_density;
	UV -= v_uv_offset;
	v_uv2_offset = v_uv_offset * _region_texel_size;
	UV2 -= v_uv2_offset;
}

//  __________________
//_/  MATERIAL MIXER  \_______________________________________________
//                                                                    :
// 2-4 lookups
void get_material(vec2 base_uv, uint control, ivec3 iuv_center, vec3 normal, out Material out_mat) {
	out_mat = Material(vec4(0.), vec4(0.), 0, 0, 0.0);
	vec2 uv_center = vec2(iuv_center.xy);
	int region = iuv_center.z;

#if defined(AUTO_TEXTURING_ENABLED)
	// Enable Autoshader if outside regions or painted in regions, otherwise manual painted
	bool auto_texturing = region<0 || bool(control & 0x1u);
	out_mat.base = int(auto_texturing)*_auto_texturing_base_texture + int(!auto_texturing)*int(control >>27u & 0x1Fu);
	out_mat.over = int(auto_texturing)*_auto_texturing_overlay_texture + int(!auto_texturing)*int(control >> 22u & 0x1Fu);
	out_mat.blend = float(auto_texturing)*clamp(
			dot(vec3(0., 1., 0.), normal * _auto_texturing_slope*2. - (_auto_texturing_slope*2.-1.)) 
			- _auto_texturing_height_reduction*.01*v_vertex.y // Reduce as vertices get higher
			, 0., 1.) + 
			 float(!auto_texturing)*float(control >>14u & 0xFFu) * 0.003921568627450; // 1./255.0		
#else
	out_mat.base = int(control >>27u & 0x1Fu);
	out_mat.over = int(control >> 22u & 0x1Fu);
	out_mat.blend = float(control >>14u & 0xFFu) * 0.003921568627450; // 1./255.0
#endif

	float random_value = random(uv_center);
	float random_angle = (random_value - 0.5) * TAU; // -180deg to 180deg
	base_uv *= .5; // Allow larger numbers on uv scale array - move to C++
	vec2 uv_scales = vec2(
		_texture_uv_scale_array[out_mat.base],
		_texture_uv_scale_array[out_mat.over]);
#if defined(UV_DISTORTION_ENABLED)
	vec2 uvd_scales = uv_scales / UVD_BASE_TEX_SCALE;
	vec2 uv1 = fma(base_uv,vec2(uv_scales.xx),(v_uvdistort * uvd_scales.x));
#else
	vec2 uv1 = base_uv * uv_scales.x;
#endif
	vec2 matUV = rotate_around(uv1, uv1 - 0.5, random_angle * _texture_uv_rotation_array[out_mat.base]);

	vec4 albedo_ht = vec4(0.);
	vec4 normal_rg = vec4(0.5f, 0.5f, 1.0f, 1.0f);
	vec4 albedo_far = vec4(0.);
	vec4 normal_far = vec4(0.5f, 0.5f, 1.0f, 1.0f);
	
#if defined(MULTI_SCALING_ENABLED)
	// If dual scaling, apply to base texture
	if(region < 0) {
		matUV *= _multi_scaling_near_size;
	}
	albedo_ht = texture(_texture_array_albedo, vec3(matUV, float(out_mat.base)));
	normal_rg = texture(_texture_array_normal, vec3(matUV, float(out_mat.base)));
	if(out_mat.base == _multi_scaling_texture || out_mat.over == _multi_scaling_texture) {
		albedo_far = texture(_texture_array_albedo, vec3(matUV*_multi_scaling_distant_size, float(_multi_scaling_texture)));
		normal_far = texture(_texture_array_normal, vec3(matUV*_multi_scaling_distant_size, float(_multi_scaling_texture)));
	}

	float far_factor = clamp(smoothstep(_multi_scaling_near, _multi_scaling_far, length(v_vertex - v_camera_pos)), 0.0, 1.0);
	if(out_mat.base == _multi_scaling_texture) {
		albedo_ht = mix(albedo_ht, albedo_far, far_factor);
		normal_rg = mix(normal_rg, normal_far, far_factor);
	}
#else
	albedo_ht = texture(_texture_array_albedo, vec3(matUV, float(out_mat.base)));
	normal_rg = texture(_texture_array_normal, vec3(matUV, float(out_mat.base)));
#endif

	// Apply color to base
	albedo_ht.rgb *= _texture_color_array[out_mat.base].rgb;

	// Unpack base normal for blending
	normal_rg.xz = unpack_normal(normal_rg).xz;

	// Setup overlay texture to blend
#if defined(UV_DISTORTION_ENABLED)
	vec2 uv2 = fma(base_uv,vec2(uv_scales.yy),(v_uvdistort * uvd_scales.y));
#else
	vec2 uv2 = base_uv * uv_scales.y;
#endif 
	vec2 matUV2 = rotate_around(uv2, uv2 - 0.5, random_angle * _texture_uv_rotation_array[out_mat.over]);

	vec4 albedo_ht2 = texture(_texture_array_albedo, vec3(matUV2, float(out_mat.over)));
	vec4 normal_rg2 = texture(_texture_array_normal, vec3(matUV2, float(out_mat.over)));

	// Though it would seem having the above lookups in this block, or removing the branch would
	// be more optimal, the first introduces artifacts #276, and the second is noticably slower. 
	// It seems the branching off dual scaling and the color array lookup is more optimal.
	if (out_mat.blend > 0.f) {
		#if defined(MULTI_SCALING_ENABLED)
			// If dual scaling, apply to overlay texture
			if(out_mat.over == _multi_scaling_texture) {
				albedo_ht2 = mix(albedo_ht2, albedo_far, far_factor);
				normal_rg2 = mix(normal_rg2, normal_far, far_factor);
			}
		#endif
		// Apply color to overlay
		albedo_ht2.rgb *= _texture_color_array[out_mat.over].rgb;
		
		// Unpack overlay normal for blending
		normal_rg2.xz = unpack_normal(normal_rg2).xz;

		#if defined(HEIGHT_BLENDING_ENABLED)
		// Blend overlay and base
			albedo_ht = height_blend(albedo_ht, albedo_ht.a, albedo_ht2, albedo_ht2.a, out_mat.blend);
			normal_rg = height_blend(normal_rg, albedo_ht.a, normal_rg2, albedo_ht2.a, out_mat.blend);
		#else
			albedo_ht = default_blend(albedo_ht, albedo_ht.a, albedo_ht2, albedo_ht2.a, out_mat.blend);
			normal_rg = default_blend(normal_rg, albedo_ht.a, normal_rg2, albedo_ht2.a, out_mat.blend);
		#endif
	}
	
	// Repack normals and return material
	normal_rg = pack_normal(normal_rg.xyz, normal_rg.a);
	out_mat.alb_ht = albedo_ht;
	out_mat.nrm_rg = normal_rg;
	return;
}

//  ____________
//_/  FRAGMENT  \_____________________________________________________
//                                                                    :
void fragment() {
	// Recover UVs
	vec2 uv = UV + v_uv_offset;
	vec2 uv2 = UV2 + v_uv2_offset;

	// Calculate Terrain Normals. 4 lookups
	#if defined(NORMALS_PER_VERTEX)
		vec3 w_normal	= normalize(v_normal);
		vec3 w_tangent	= cross(w_normal, vec3(0, 0, 1));
		vec3 w_binormal	= cross(w_normal, w_tangent);
	#else
		vec3 w_tangent, w_binormal;
		vec3 w_normal	= get_normal(uv2, w_tangent, w_binormal);
	#endif
	NORMAL		= mat3(VIEW_MATRIX) * w_normal;
	TANGENT		= mat3(VIEW_MATRIX) * w_tangent;
	BINORMAL	= mat3(VIEW_MATRIX) * w_binormal;

	// Idenfity 4 vertices surrounding this pixel
	vec2 texel_pos = uv;
	highp vec2 texel_pos_floor = floor(uv);
	
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
	get_material(uv, control00, index00UV, w_normal, mat[0]);
	get_material(uv, control01, index01UV, w_normal, mat[1]);
	get_material(uv, control10, index10UV, w_normal, mat[2]);
	get_material(uv, control11, index11UV, w_normal, mat[3]);

	// Calculate weight for the pixel position between the vertices
	// Bilinear interpolation of difference of uv and floor(uv)
	vec2 weights1 = clamp(texel_pos - texel_pos_floor, 0, 1);
	weights1 = mix(weights1, vec2(1.0) - weights1, mirror.xy);
	vec2 weights0 = vec2(1.0) - weights1;
	vec2 _w01y = vec2(weights0.y, weights1.y);
	// (!!!) "weights" EXTERNAL REF -> Debug View: DEBUG_CONTROL_TEXTURE
	vec4 weights = blend_weights_x4(
		vec4( (weights0.x * _w01y), (weights1.x * _w01y) ), 
		clamp ( 
	#if defined(NOISE_TINT_ENABLED)
		texture(_tinting_texture, uv*(1./(_tinting_noise3_scale*10000.))).r +
	#endif
		vec4 ( mat[0].alb_ht.a, mat[1].alb_ht.a, mat[2].alb_ht.a, mat[3].alb_ht.a ), vec4(0.), vec4(1.) ) );

	// (!!!) "weight_inv" EXTERNAL REF -> Debug View: DEBUG_CONTROL_TEXTURE
	float weight_inv = 1.0 / (weights.x + weights.y + weights.z + weights.w);

	vec4 _W = weights * weight_inv;
	// Weighted average of albedo & height
	vec4 albedo_height	= mat4(mat[0].alb_ht, mat[1].alb_ht, mat[2].alb_ht, mat[3].alb_ht) * _W;

	// Weighted average of normal & rough
	vec4 normal_rough	= mat4(mat[0].nrm_rg, mat[1].nrm_rg, mat[2].nrm_rg, mat[3].nrm_rg) * _W;

	/* // Weighted average of albedo & height
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
		mat[3].nrm_rg * weights.w ); */

	// Determine if we're in a region or not (region_uv.z>0)
	vec3 region_uv = get_region_uv2(uv2);

	// Colormap. 1 lookup
	vec4 color_map = vec4(1., 1., 1., .5);
	if (region_uv.z >= 0.) {
		float lod = textureQueryLod(_color_maps, uv2.xy).y;
		color_map = textureLod(_color_maps, region_uv, lod);
	}

	#if defined(NOISE_TINT_ENABLED)
		// Macro variation. 2 Lookups
		float noise1 = texture(_tinting_texture, rotate(uv*(1./(_tinting_noise1_scale*10000.)), cos(_tinting_noise1_angle), sin(_tinting_noise1_angle)) + _tinting_noise1_offset).r;
		float noise2 = texture(_tinting_texture, uv*(1./(_tinting_noise2_scale*10000.))).r;
		vec3 macrov = mix(_tinting_macro_variation1, vec3(1.), clamp(noise1 + v_vertex_xz_dist*.0002, 0., 1.));
		macrov *= mix(_tinting_macro_variation2, vec3(1.), clamp(noise2 + v_vertex_xz_dist*.0002, 0., 1.));
	#else
		vec3 macrov = vec3(1.);
	#endif

	// Wetness/roughness modifier, converting 0-1 range to -1 to 1 range
	float roughness = fma(color_map.a-0.5, 2.0, normal_rough.a);

	// Apply PBR
	ALBEDO = albedo_height.rgb * color_map.rgb * macrov;
	ROUGHNESS = roughness;
	SPECULAR = 1.-normal_rough.a;
	NORMAL_MAP = normal_rough.rgb;
	NORMAL_MAP_DEPTH = 1.0;

	#include "res://addons/terrain_3d/shader/mods/t3d_debug_view.gdshaderinc"
	
}

)"
