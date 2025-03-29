shader_type spatial;
render_mode blend_mix,depth_draw_opaque,cull_back,diffuse_burley,specular_schlick_ggx,skip_vertex_transform;

/* This is an example stripped down shader with maximum performance in mind.
 * Only Autoshader/Base/Over/Blend/Holes/Colormap are supported.
 * All terrain normal calculations take place in vetex() as well as control map reads
 * for the bilinear blend, when not skippable have moved to vertex() too.
 *
 * A single controlmap lookup in fragment is added at distances where the vertices spread too wide.
 */

// Defined Constants
#define SKIP_PASS 0
#define VERTEX_PASS 1
#define FRAGMENT_PASS 2

#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
    #define fma(a, b, c) ((a) * (b) + (c))
    #define dFdxCoarse(a) dFdx(a)
    #define dFdyCoarse(a) dFdy(a)
#endif

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
uniform float _texture_ao_strength_array[32];
uniform float _texture_roughness_mod_array[32];
uniform float _texture_uv_scale_array[32];
uniform vec4 _texture_color_array[32];
uniform highp sampler2DArray _height_maps : repeat_disable;
uniform highp sampler2DArray _control_maps : repeat_disable;
uniform highp sampler2DArray _color_maps : source_color, filter_linear_mipmap, repeat_disable;
uniform highp sampler2DArray _texture_array_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform highp sampler2DArray _texture_array_normal : hint_normal, filter_linear_mipmap, repeat_enable;


// Public uniforms
uniform float auto_slope : hint_range(0, 10) = 1.0;
uniform float auto_height_reduction : hint_range(0, 1) = 0.1;
uniform int auto_base_texture : hint_range(0, 31) = 0;
uniform int auto_overlay_texture : hint_range(0, 31) = 1;

uniform bool height_blending = true;
uniform bool world_space_normal_blend = true;
uniform float blend_sharpness : hint_range(0, 1) = 0.87;

// Varyings & Types

struct Material {
	vec4 alb_ht;
	vec4 nrm_rg;
	int base;
	int over;
	float blend;
	float nrm_depth;
	float ao_str;
};


varying vec3 v_vertex;
varying vec3 v_normal;
varying flat uint v_control[4];
varying flat int v_lerp;
varying mat3 v_tbn;

////////////////////////
// Vertex
////////////////////////

// Takes in world space XZ (UV) coordinates & search depth (only applicable for background mode none)
// Returns ivec3 with:
// XY: (0 to _region_size - 1) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
ivec3 get_index_coord(const vec2 uv, const int search) {
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

// Takes in descaled (world_space / region_size) world to region space XZ (UV2) coordinates, returns vec3 with:
// XY: (0. to 1.) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
vec3 get_index_uv(const vec2 uv2) {
	ivec2 pos = ivec2(floor(uv2)) + (_region_map_size / 2);
	int bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
	int layer_index = _region_map[ pos.y * _region_map_size + pos.x ] * bounds - 1;
	return vec3(uv2 - _region_locations[layer_index], float(layer_index));
}

void vertex() {
	// Get vertex of flat plane in world coordinates and set world UV
	v_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Camera distance to vertex on flat plane
	float v_vertex_xz_dist = length(v_vertex.xz - _camera_pos.xz);

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
	
	const vec3 offsets = vec3(0, 1, 2);
	ivec3 indexUV[4];
	// control map lookups in vertex, used for bilinear blend in fragment.
	indexUV[0] = get_index_coord(start_pos + offsets.xy, VERTEX_PASS);
	indexUV[1] = get_index_coord(start_pos + offsets.yy, VERTEX_PASS);
	indexUV[2] = get_index_coord(start_pos + offsets.yx, VERTEX_PASS);
	indexUV[3] = get_index_coord(start_pos + offsets.xx, VERTEX_PASS);
	// Mask off Scale/Rotation/Navigation bits to 0, as they are not used.
	#define CONTROL_MASK 0xFFFFC07Du
	v_control[0] = floatBitsToUint(texelFetch(_control_maps, indexUV[0], 0)).r & CONTROL_MASK;
	v_control[1] = floatBitsToUint(texelFetch(_control_maps, indexUV[1], 0)).r & CONTROL_MASK;
	v_control[2] = floatBitsToUint(texelFetch(_control_maps, indexUV[2], 0)).r & CONTROL_MASK;
	v_control[3] = floatBitsToUint(texelFetch(_control_maps, indexUV[3], 0)).r & CONTROL_MASK;
	bool full_auto = !bool((v_control[0] & v_control[1] & v_control[2] & v_control[3]) & 0x1u);
	bool identical = !(
			(v_control[0] == v_control[1]) &&
			(v_control[1] == v_control[2]) &&
			(v_control[2] == v_control[3]));
	// Verticies are close enough, full auto shader, or all 4 indicies match, skip bilinear blend in fragment.
	v_lerp = scale <  _vertex_spacing + 1e-3 && vertex_lerp < 1e-3 && (full_auto || identical) ? 1 : 0;
	
	// Discard vertices for Holes. 1 lookup
	bool hole = bool(v_control[3] >>2u & 0x1u);
	
	// Show holes to all cameras except mouse camera (on exactly 1 layer)
	if ( !(CAMERA_VISIBLE_LAYERS == _mouse_layer) && 
			(hole || (_background_mode == 0u && indexUV[3].z == -1))) {
		v_vertex.x = 0. / 0.;
	} else {
		// Set final vertex height & calculate vertex normals. 3 lookups
		ivec3 uv_a = get_index_coord(start_pos, VERTEX_PASS);
		ivec3 uv_b = get_index_coord(end_pos, VERTEX_PASS);
		float h = mix(texelFetch(_height_maps, uv_a, 0).r,texelFetch(_height_maps, uv_b, 0).r,vertex_lerp);
		float u = mix(texelFetch(_height_maps, get_index_coord(start_pos + vec2(1,0), VERTEX_PASS), 0).r,
			texelFetch(_height_maps, get_index_coord(end_pos + vec2(1,0), VERTEX_PASS), 0).r, vertex_lerp);
		float v = mix(texelFetch(_height_maps, get_index_coord(start_pos + vec2(0,1), VERTEX_PASS), 0).r,
			texelFetch(_height_maps, get_index_coord(end_pos + vec2(0,1), VERTEX_PASS), 0).r, vertex_lerp);
		v_vertex.y = h;
		v_normal = vec3(h - u, _vertex_spacing, h - v);
	}
	
	// Convert model space to view space w/ skip_vertex_transform render mode
	VERTEX = (VIEW_MATRIX * vec4(v_vertex, 1.0)).xyz;
	
	// Apply terrain normals
	vec3 w_normal = normalize(v_normal);
	vec3 w_tangent = normalize(cross(w_normal, vec3(0.0, 0.0, 1.0)));
	vec3 w_binormal = normalize(cross(w_normal, w_tangent));
	
	v_tbn = mat3(w_tangent, w_normal, w_binormal);
	
	NORMAL = normalize((VIEW_MATRIX * vec4(w_normal, 0.0)).xyz);
	BINORMAL = normalize((VIEW_MATRIX * vec4(w_binormal, 0.0)).xyz);
	TANGENT = normalize((VIEW_MATRIX * vec4(w_tangent, 0.0)).xyz);
}

////////////////////////
// Fragment
////////////////////////

vec3 unpack_normal(vec4 rgba) {
	return fma(rgba.xzy, vec3(2.0), vec3(-1.0));
}

vec3 pack_normal(vec3 n) {
	return fma(normalize(n.xzy), vec3(0.5), vec3(0.5));
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

// 2-4 lookups ( 2-6 with dual scaling )
void get_material(vec4 ddxy, uint control, vec3 iuv_center, out Material out_mat) {
	out_mat = Material(vec4(0.), vec4(0.), 0, 0, 0.0, 0.0, 0.0);
	int region = int(iuv_center.z);
	vec2 base_uv = v_vertex.xz * 0.5;
	ddxy *= 0.5;
	
	// Enable Autoshader if outside regions or painted in regions, otherwise manual painted
	bool auto_shader = region < 0 || bool(control & 0x1u);
	out_mat.base = int(auto_shader) * auto_base_texture + int(!auto_shader) * int(control >>27u & 0x1Fu);
	out_mat.over = int(auto_shader) * auto_overlay_texture + int(!auto_shader) * int(control >> 22u & 0x1Fu);
	out_mat.blend = float(auto_shader) * clamp(
			(auto_slope * 2. * ( v_tbn[1].y - 1.) + 1.)
			- auto_height_reduction * .01 * v_vertex.y // Reduce as vertices get higher
			, 0., 1.) + 
			 float(!auto_shader) * float(control >>14u & 0xFFu) * 0.003921568627450; // 1./255.0
	
	out_mat.nrm_depth = _texture_normal_depth_array[out_mat.base];
	out_mat.ao_str = _texture_ao_strength_array[out_mat.base];
	
	vec2 matUV = base_uv;
	vec4 albedo_ht = vec4(0.);
	vec4 normal_rg = vec4(0.5, 0.5, 1.0, 1.0);
	vec4 albedo_far = vec4(0.);
	vec4 normal_far = vec4(0.5, 0.5, 1.0, 1.0);
	float mat_scale = _texture_uv_scale_array[out_mat.base];
	vec4 base_dd = ddxy;
	
	if (out_mat.blend < 1.0) {
		// 2 lookups
		//each time we change scale, recalculate antitiling from baseline to maintain continuity.
		matUV = base_uv * mat_scale;
		base_dd *= mat_scale;
		albedo_ht = textureGrad(_texture_array_albedo, vec3(matUV, float(out_mat.base)), base_dd.xy, base_dd.zw);
		normal_rg = textureGrad(_texture_array_normal, vec3(matUV, float(out_mat.base)), base_dd.xy, base_dd.zw);
		
		// Unpack & rotate base normal for blending
		normal_rg.xyz = unpack_normal(normal_rg);
	}
	// Apply color to base
	albedo_ht.rgb *= _texture_color_array[out_mat.base].rgb;
	
	// Apply Roughness modifier to base
	normal_rg.a = clamp(normal_rg.a + _texture_roughness_mod_array[out_mat.base], 0., 1.);
	
	out_mat.alb_ht = albedo_ht;
	out_mat.nrm_rg = normal_rg;
	
	if (out_mat.blend > 0.) {
		// 2 lookups
		// Setup overlay texture to blend
		float mat_scale2 = _texture_uv_scale_array[out_mat.over];
		vec2 matUV2 = base_uv * mat_scale2;
		vec4 over_dd = ddxy * mat_scale2;
		vec4 albedo_ht2 = textureGrad(_texture_array_albedo, vec3(matUV2, float(out_mat.over)), over_dd.xy, over_dd.zw);
		vec4 normal_rg2 = textureGrad(_texture_array_normal, vec3(matUV2, float(out_mat.over)), over_dd.xy, over_dd.zw);
		
		// Unpack & rotate overlay normal for blending
		normal_rg2.xyz = unpack_normal(normal_rg2);
		
		// Apply color to overlay
		albedo_ht2.rgb *= _texture_color_array[out_mat.over].rgb;
		
		// Apply Roughness modifier to overlay
		normal_rg2.a = clamp(normal_rg2.a + _texture_roughness_mod_array[out_mat.over], 0., 1.);
		
		// apply world space normal weighting from base, to overlay layer
		// Its a matrix Mult, but the value is rather high, so not cutting this one.
		if (world_space_normal_blend) {
			albedo_ht2.a *= bool(control >>3u & 0x1u) ? 1.0 : clamp((v_tbn * normal_rg.xyz).y, 0.0, 1.0);
		}
		
		// Blend overlay and base
		out_mat.alb_ht = height_blend4(albedo_ht, albedo_ht.a, albedo_ht2, albedo_ht2.a, out_mat.blend);
		out_mat.nrm_rg = height_blend4(normal_rg, albedo_ht.a, normal_rg2, albedo_ht2.a, out_mat.blend);
		out_mat.nrm_depth = height_blend1(_texture_normal_depth_array[out_mat.base], albedo_ht.a,
			_texture_normal_depth_array[out_mat.over], albedo_ht2.a, out_mat.blend);
		out_mat.ao_str = height_blend1(_texture_ao_strength_array[out_mat.base], albedo_ht.a,
			_texture_ao_strength_array[out_mat.over], albedo_ht2.a, out_mat.blend);
	}
	return;
}

void fragment() {
	// Recover UVs
	vec2 uv = UV;
	vec2 uv2 = UV2;

	vec3 base_ddx = dFdxCoarse(v_vertex);
	vec3 base_ddy = dFdyCoarse(v_vertex);
	vec4 base_derivatives = vec4(base_ddx.xz, base_ddy.xz);
	float region_mip = log2(max(length(base_ddx.xz), length(base_ddy.xz)) * _vertex_density);

	// Colormap. 1 lookup
	// For speed sake, we'll live with cross region artifacts.
	#define COLOR_MAP vec4(1.0, 1.0, 1.0, 0.5)
	vec3 region_uv = get_index_uv(uv2);
	vec4 color_map = region_uv.z > -1.0 ? textureLod(_color_maps, region_uv, region_mip) : COLOR_MAP;
	
	Material mat[4];
	uint control = floatBitsToUint(texelFetch(_control_maps, get_index_coord(floor(uv), FRAGMENT_PASS), 0)).r;
	get_material(base_derivatives, control, region_uv, mat[3]);

	vec4 albedo_height = mat[3].alb_ht;
	vec4 normal_rough = mat[3].nrm_rg;
	float normal_map_depth = mat[3].nrm_depth;
	float ao_strength = mat[3].ao_str;

	// Only do blend if we really have to.
	if (v_lerp == 1) {
		get_material(base_derivatives, v_control[0], region_uv, mat[0]);
		get_material(base_derivatives, v_control[1], region_uv, mat[1]);
		get_material(base_derivatives, v_control[2], region_uv, mat[2]);
		
		// we dont need weights before this point when using vertex normals.
		vec2 weight = fract(uv);
		vec2 invert = 1.0 - weight;
		vec4 weights = vec4(
			invert.x * weight.y, // 0
			weight.x * weight.y, // 1
			weight.x * invert.y, // 2
			invert.x * invert.y  // 3
		);
		
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
		
		ao_strength = 
			mat[0].ao_str * weights[0] +
			mat[1].ao_str * weights[1] +
			mat[2].ao_str * weights[2] +
			mat[3].ao_str * weights[3] ;
	}
	
	// Wetness/roughness modifier, converting 0 - 1 range to -1 to 1 range
	float roughness = fma(color_map.a - 0.5, 2.0, normal_rough.a);
	
	// Apply PBR
	ALBEDO = albedo_height.rgb * color_map.rgb;
	ROUGHNESS = roughness;
	SPECULAR = 1. - normal_rough.a;
	NORMAL_MAP = pack_normal(normal_rough.rgb);
	NORMAL_MAP_DEPTH = normal_map_depth;
	
	// Higher and/or facing up, less occluded.
	// This is also virtually free.
	float ao = (1.0 - (albedo_height.a * log(2.1 - ao_strength))) * (1.0 - normal_rough.y);
	AO = clamp(1.0 - ao * ao_strength, albedo_height.a, 1.0);
	AO_LIGHT_AFFECT = albedo_height.a;
	
}
