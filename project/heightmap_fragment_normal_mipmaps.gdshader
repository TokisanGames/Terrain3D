shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx, skip_vertex_transform;

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
#define COLOR_MAP_DEF vec4(1.0, 1.0, 1.0, 0.5)
#define DIV_255 0.003921568627450 // 1. / 255.
#define DIV_1024 0.0009765625 // 1. / 1024.
#define TAU_16TH -0.392699081698724 // -TAU / 16.

// Inline Functions
#define DECODE_BLEND(control) float(control >>14u & 0xFFu) * DIV_255
#define DECODE_AUTO(control) bool(control & 0x1u)
#define DECODE_BASE(control) int(control >>27u & 0x1Fu)
#define DECODE_OVER(control) int(control >>22u & 0x1Fu)
#define DECODE_ANGLE(control) float(control >>10u & 0xFu) * TAU_16TH
// This math recreates the scale value directly rather than using an 8 float const array.
#define DECODE_SCALE(control) (0.9 - float(((control >>7u & 0x7u) + 3u) % 8u + 1u) * 0.1)
#define DECODE_HOLE(control) bool(control >>2u & 0x1u)

#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
    #define fma(a, b, c) ((a) * (b) + (c))
    #define dFdxCoarse(a) dFdx(a)
    #define dFdyCoarse(a) dFdy(a)
#endif

// Private uniforms
group_uniforms private;
uniform vec3 _target_pos = vec3(0.f);
uniform float _mesh_size = 48.f;
uniform float _subdiv = 1.f;
uniform float _tessellation_level = 0.f;
uniform uint _background_mode = 1u; // NONE = 0, FLAT = 1, NOISE = 2
uniform uint _mouse_layer = 0x80000000u; // Layer 32
uniform float _vertex_spacing = 1.0;
uniform float _vertex_density = 1.0; // = 1./_vertex_spacing
uniform float _region_size = 1024.0;
uniform float _region_texel_size = 0.0009765625; // = 1./region_size
uniform int _region_map_size = 32;
uniform int _region_map[1024];
uniform vec2 _region_locations[1024];
#define MAX_REGIONS 1024

uniform float _texture_normal_depth_array[32];
uniform float _texture_ao_strength_array[32];
uniform float _texture_ao_affect_array[32];
uniform float _texture_roughness_mod_array[32];
uniform float _texture_uv_scale_array[32];
uniform vec2 _texture_detile_array[32];
uniform vec4 _texture_color_array[32];
uniform highp sampler2DArray _height_maps : repeat_disable;
uniform highp sampler2DArray _control_maps : repeat_disable;
#define FILTER_LINEAR
#define FILTER_METHOD filter_linear_mipmap_anisotropic

uniform highp sampler2DArray _color_maps : source_color, FILTER_METHOD, repeat_disable;
uniform highp sampler2DArray _texture_array_albedo : source_color, FILTER_METHOD, repeat_enable;
uniform highp sampler2DArray _texture_array_normal : hint_normal, FILTER_METHOD, repeat_enable;
uniform vec3 _light_direction = vec3(0., 0., 0);
uniform vec3 _light_color : source_color = vec3(1.0, 1.0, .735);
group_uniforms;

// Public uniforms
group_uniforms general_uniforms;
uniform float ground_level : hint_range(-1000., 1000.) = 0.0;
uniform float region_blend : hint_range(.001, 1., 0.001) = 0.25;

uniform bool flat_terrain_normals = false;
uniform float distant_normal_scale : hint_range(1.0, 10.0, 0.1) = 2.0;
uniform float blend_sharpness : hint_range(0, 1) = 0.5;
group_uniforms;

#define AUTO_SHADER
group_uniforms auto_shader;
uniform float auto_slope : hint_range(0, 10) = 1.0;
uniform float auto_height_reduction : hint_range(0, 1) = 0.1;
uniform int auto_base_texture : hint_range(0, 31) = 0;
uniform int auto_overlay_texture : hint_range(0, 31) = 1;
group_uniforms;

#define DISPLACEMENT
uniform float _displacement_scale : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform highp sampler2D _displacement_buffer : repeat_disable, filter_linear;

group_uniforms dual_scaling;
uniform int dual_scale_texture : hint_range(0,31) = 0;
uniform float dual_scale_reduction : hint_range(0.001,1) = 0.3;
uniform float tri_scale_reduction : hint_range(0.001,1) = 0.3;
uniform float dual_scale_far : hint_range(0,1000) = 170.0;
uniform float dual_scale_near : hint_range(0,1000) = 100.0;
group_uniforms;

group_uniforms macro_variation;
uniform vec3 macro_variation1 : source_color = vec3(1.);
uniform vec3 macro_variation2 : source_color = vec3(1.);
uniform float macro_variation_slope : hint_range(0., 1.)  = 0.333;
uniform highp sampler2D noise_texture : source_color, FILTER_METHOD, repeat_enable;
uniform float noise1_scale : hint_range(0.001, 1.) = 0.04; // Used for macro variation 1. Scaled up 10x
uniform float noise1_angle : hint_range(0, 6.283) = 0.;
uniform vec2 noise1_offset = vec2(0.5);
uniform float noise2_scale : hint_range(0.001, 1.) = 0.076;	// Used for macro variation 2. Scaled up 10x
group_uniforms;


group_uniforms mipmaps;
uniform float bias_distance : hint_range(0.0, 16384.0, 0.1) = 512.0;
uniform float mipmap_bias : hint_range(0.5, 1.5, 0.01) = 1.0;
uniform float depth_blur : hint_range(0.0, 35.0, 0.1) = 0.0;
group_uniforms;

group_uniforms world_background_noise;
uniform bool world_noise_fragment_normals = false;
uniform int world_noise_max_octaves : hint_range(0, 15) = 4;
uniform int world_noise_min_octaves : hint_range(0, 15) = 2;
uniform float world_noise_lod_distance : hint_range(0., 40000., 1.) = 7500.;
uniform float world_noise_scale : hint_range(0.25, 20, 0.01) = 5.0;
uniform float world_noise_height : hint_range(-1000., 1000., 0.1) = 32.0;
uniform vec3 world_noise_offset = vec3(0.0);
group_uniforms;
varying vec2 world_noise_ddxy;


// Varyings & Types

struct material {
	vec4 albedo_height;
	vec4 normal_rough;
	float normal_map_depth;
	float ao;
	float ao_affect;
	float total_weight;
};

varying vec3 v_vertex;
varying float v_vertex_xz_dist;
varying vec3 v_camera_pos;

////////////////////////
// Vertex
////////////////////////

// Takes in world space XZ (UV) coordinates
// Returns ivec3 with:
// XY: (0 to _region_size - 1) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
ivec3 get_index_coord(const vec2 uv) {
	vec2 r_uv = round(uv);
	ivec2 pos = ivec2(floor(r_uv * _region_texel_size)) + (_region_map_size / 2);
	int bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
	int map_val = _region_map[pos.y * _region_map_size + pos.x];
	int raw_index = map_val - 1;
	// Real regions limited by max_regions
	int is_region = bounds * int(raw_index >= 0) * int(raw_index < MAX_REGIONS);
	// Editor dummies are negative; keep them != -1 so the shader still sees a region
	int is_dummy = bounds * int(map_val < 0);
	int layer_index = is_region * raw_index
	               + is_dummy * (map_val - 1)
	               - (1 - is_region - is_dummy);
	return ivec3(ivec2(mod(r_uv, _region_size)), layer_index);
}

// Takes in descaled (world_space / region_size) world to region space XZ (UV2) coordinates, returns vec3 with:
// XY: (0. to 1.) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
vec3 get_index_uv(const vec2 uv2) {
	ivec2 pos = ivec2(floor(uv2)) + (_region_map_size / 2);
	int bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
	int map_val = _region_map[pos.y * _region_map_size + pos.x];
	int raw_index = map_val - 1;
	int is_region = bounds * int(raw_index >= 0) * int(raw_index < MAX_REGIONS);
	int is_dummy = bounds * int(map_val < 0);
	int layer_index = is_region * raw_index
	               + is_dummy * (map_val - 1)
	               - (1 - is_region - is_dummy);
	return vec3(uv2 - _region_locations[layer_index], float(layer_index));
}

float interpolated_height(vec2 pos) {
	const vec2 offsets = vec2(0, 1);
	vec2 index_id = floor(pos);
	ivec3 index[4];
	index[0] = get_index_coord(index_id + offsets.xy);
	index[1] = get_index_coord(index_id + offsets.yy);
	index[2] = get_index_coord(index_id + offsets.yx);
	index[3] = get_index_coord(index_id + offsets.xx);
	float h0 = texelFetch(_height_maps, index[0], 0).r;
	float h1 = texelFetch(_height_maps, index[1], 0).r;
	float h2 = texelFetch(_height_maps, index[2], 0).r;
	float h3 = texelFetch(_height_maps, index[3], 0).r;
	vec2 f = fract(pos);
	vec2 i = 1.0 - f;
	vec4 w = vec4(i.x * f.y, f.x * f.y, f.x * i.y, i.x * i.y);
	float h = h0 * w[0] + h1 * w[1] + h2 * w[2] + h3 * w[3];
	return h;
}

vec3 get_displacement(vec2 pos, float scale) {
	float s = floor(log2(1.0 / (scale * _vertex_density)));
	scale = pow(2.0, s) * 0.5;
	vec2 d_uv = (scale * pos - round(_target_pos.xz * _vertex_density * scale)) / (_mesh_size * 2.0) + 0.5;
	d_uv.x += s - 1.;
	d_uv.x /= log2(_subdiv);
	highp vec3 disp = vec3(0.);
	if (all(greaterThanEqual(d_uv, vec2(0.0))) && all(lessThanEqual(d_uv, vec2(1.0)))) {
		disp = textureLod(_displacement_buffer, d_uv, 0.).rgb * 2.0 - 1.0;
		disp *= _displacement_scale;
	}
	return disp;
}

// Takes in UV2 region space coordinates, returns 1.0 or 0.0 if a region is present or not.
float check_region(const vec2 uv2) {
	ivec2 pos = ivec2(floor(uv2)) + (_region_map_size / 2);
    int bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
    int raw_index = _region_map[pos.y * _region_map_size + pos.x] - 1;
    int is_valid = bounds * int(raw_index >= 0) * int(raw_index < MAX_REGIONS);
	return float(is_valid);
}

// Takes in UV2 region space coordinates, returns a blend value (0 - 1 range) between empty, and valid regions
float get_region_blend(vec2 uv2) {
	uv2 -= 0.5011; // correct for floating point error
	const vec2 offset = vec2(0.0, 1.0);
	float a = check_region(uv2 + offset.xy);
	float b = check_region(uv2 + offset.yy);
	float c = check_region(uv2 + offset.yx);
	float d = check_region(uv2 + offset.xx);
	vec2 blend_factor = vec2(2.0 + 126.0 * (1.0 - region_blend));
	vec2 f = fract(uv2);
	vec2 w = 1.0 / (1.0 + exp(blend_factor * log((1.0 - f) / f)));
	float blend = mix(mix(d, c, w.x), mix(a, b, w.x), w.y);
	return (1.0 - blend) * 2.0;
}

// World Noise Functions Start

// Takes in UV2 region space coordinates, returns a blend value (0 - 1 range) between empty, and valid regions
// Intentionally and subtly different from get_region_blend()
float get_noise_region_blend(vec2 uv2) {
	uv2 -= 0.5011; // correct for floating point error
	const vec2 offset = vec2(0.0, 1.0);
	float a = check_region(uv2 + offset.xy);
	float b = check_region(uv2 + offset.yy);
	float c = check_region(uv2 + offset.yx);
	float d = check_region(uv2 + offset.xx);
	vec2 w = smoothstep(vec2(0.0), vec2(1.0), fract(uv2));
	float blend = mix(mix(d, c, w.x), mix(a, b, w.x), w.y);
    return 1.0 - blend * 2.0;
}

float hashf(float f) {
	return fract(sin(f) * 1e4);
}

float hashv2(vec2 v) {
	return fract(1e4 * sin(fma(17.0, v.x, v.y * 0.1)) * (0.1 + abs(sin(fma(v.y, 13.0, v.x)))));
}

// https://iquilezles.org/articles/morenoise/
vec3 noise2D(vec2 x) {
    vec2 f = fract(x);
    // Quintic Hermine Curve.  Similar to SmoothStep()
	vec2 f2 = f * f, f3 = f2 * f, s = f - 1.0, s2 = s * s;
	vec2 u = f3 * fma(vec2(6.0), f2, fma(vec2(-15.0), f, vec2(10.0)));
	vec2 du = 30.0 * f2 * s2;

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
    float k3 =   d - (b + k2);
	return vec3(fma(k2, u.y, fma(u.x, fma(k3, u.y, k1), k0)),
		 du * fma(vec2(k3), u.yx, vec2(k1, k2)));
}

float world_noise(vec2 p) {
    float a = 0.0;
    float b = 1.0;
    vec2  d = vec2(0.0);

    int octaves = int( clamp(
		float(world_noise_max_octaves) - floor(v_vertex_xz_dist/(world_noise_lod_distance)),
		float(world_noise_min_octaves), float(world_noise_max_octaves))
	);
	
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
	float weight = get_noise_region_blend(uv);
	// Only calculate world noise when it would be visible.
    if (weight <= 0.5) {
		return 0.0;
	}
	//TODO: Offset/scale UVs are semi-dependent upon region size 1024. Base on v_vertex.xz instead
	float noise = world_noise((uv + world_noise_offset.xz * 1024. / _region_size) * world_noise_scale * _region_size / 1024. * .1) *
            world_noise_height * 10. + world_noise_offset.y * 100.;
    weight = smoothstep(0.5, 1.0, weight);
    return mix(0.0, noise, weight);
}

// World Noise Functions End


void vertex() {
	// Save Camera Position to varying for access in later functions
	v_camera_pos = MAIN_CAM_INV_VIEW_MATRIX[3].xyz;

	// Get vertex of flat plane in world coordinates and set world UV
	v_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Distance from target node to vertex on a flat plane
	v_vertex_xz_dist = length(v_vertex.xz - _target_pos.xz);

	// Geomorph vertex across clipmap LODs, set end and start for linear height interpolate
	float scale = MODEL_MATRIX[0][0];
	float inv_scale = 1.0 / scale;
	float max_xz = max(abs(v_vertex.x - _target_pos.x), abs(v_vertex.z - _target_pos.z));
	float vertex_lerp = smoothstep(0.0, 1.0, (max_xz * inv_scale - _mesh_size - 4.0) / (_mesh_size - 4.0));
	vec2 vertex_fract = fract(VERTEX.xz * 0.5) * 2.0;
	// For LOD0 morph from a regular grid to an alternating grid to align with LOD1+
	vec2 shift = (scale < _vertex_spacing / _subdiv + 1e-6) ? // LOD0 or not
		// Shift from regular to symmetric
		mix(vertex_fract, vec2(vertex_fract.x, -vertex_fract.y),
			round(fract(round(mod(v_vertex.z * inv_scale, 4.0)) *
			round(mod(v_vertex.x * inv_scale, 4.0)) * 0.25))) :
		// Symmetric shift
		vertex_fract * round((fract(v_vertex.xz * 0.25 * inv_scale) - 0.5) * 4.0);
	vec2 start_pos = v_vertex.xz * _vertex_density;
	vec2 end_pos = (v_vertex.xz - shift * scale) * _vertex_density;
	v_vertex.xz -= shift * scale * vertex_lerp;

	// UV coordinates in region space. 0-1 covers 1 region, 1-2 is the next region, etc.
	UV = v_vertex.xz * _vertex_density;

	// UV coordinates in region space + texel offset. Values are 0 to 1 within regions
	UV2 = fma(UV, vec2(_region_texel_size), vec2(0.5 * _region_texel_size));

	// Discard vertices for Holes. 1 lookup
	ivec3 v_region = get_index_coord(start_pos);
	uint control = floatBitsToUint(texelFetch(_control_maps, v_region, 0)).r;
	bool hole = DECODE_HOLE(control);

	vec3 displacement = vec3(0.);
	// Show holes to all cameras except mouse camera (on exactly 1 layer)
	if ( !(CAMERA_VISIBLE_LAYERS == _mouse_layer) && (hole
		)){
		v_vertex.x = 0. / 0.;
	} else {
		// Set final vertex height.
		float h;
		// This branch is static for each of the clipmap segments
		// Interpolated reads only occur where sub-texel values are required.
		if (scale < _vertex_spacing) {
			h = interpolated_height(UV);
		} else {
			ivec3 coord_a = get_index_coord(start_pos);
			ivec3 coord_b = get_index_coord(end_pos);
			h = mix(texelFetch(_height_maps, coord_a, 0).r, texelFetch(_height_maps, coord_b, 0).r, vertex_lerp);
		}

		// Apply background ground level and region blend, dont include texel offset
		h = mix(h, ground_level, smoothstep(0.0, 1.0, get_region_blend(UV * _region_texel_size)));

		// World Noise
		if (_background_mode == 2u) {
			vec2 nuv_a = start_pos * _region_texel_size;
			vec2 nuv_b = end_pos * _region_texel_size;
			float nh = mix(get_noise_height(nuv_a), get_noise_height(nuv_b), vertex_lerp);
			float nu = mix(get_noise_height(nuv_a + vec2(_region_texel_size, 0.0)),
				get_noise_height(nuv_b + vec2(_region_texel_size, 0.0)), vertex_lerp);
			float nv = mix(get_noise_height(nuv_a + vec2(0.0, _region_texel_size)),
				get_noise_height(nuv_b + vec2(0.0, _region_texel_size)), vertex_lerp);
			world_noise_ddxy = vec2(nh - nu, nh - nv);
			h += nh;
		}

		if (!(CAMERA_VISIBLE_LAYERS == _mouse_layer)) {
			displacement = mix(get_displacement(start_pos, scale), get_displacement(end_pos, scale * 2.0), vertex_lerp);
		}

		v_vertex.y = h;
	}

	// Convert model space to view space w/ skip_vertex_transform render mode
	// Include displacement without modifying v_vertex.
	VERTEX = (VIEW_MATRIX * vec4(v_vertex + displacement, 1.0)).xyz;
	NORMAL = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	BINORMAL = normalize((MODELVIEW_MATRIX * vec4(BINORMAL, 0.0)).xyz);
	TANGENT = normalize((MODELVIEW_MATRIX * vec4(TANGENT, 0.0)).xyz);
}

////////////////////////
// Fragment
////////////////////////

float random(in vec2 xy) {
	return fract(sin(dot(xy, vec2(12.9898, 78.233))) * 43758.5453);
}

vec2 rotate_vec2(const vec2 v, const vec2 cs) {
	return vec2(fma(cs.x, v.x,  cs.y * v.y), fma(cs.x, v.y, -cs.y * v.x));
}

// 2-4 lookups ( 2-6 with dual scaling )
void accumulate_material(vec3 base_ddx, vec3 base_ddy, const mat3 TNB, const float weight, const ivec3 index,
			const uint control, const vec2 texture_weight, const ivec2 texture_id, const vec3 i_normal,
			float h, inout material mat) {

	// Applying scaling before projection reduces the number of multiplys ops required.
	vec3 i_vertex = v_vertex;

	// Control map scale
	float control_scale = DECODE_SCALE(control);
	base_ddx *= control_scale;
	base_ddy *= control_scale;
	i_vertex *= control_scale;
	h *= control_scale;

	// Index position for detiling.
	vec2 i_pos = fma(_region_locations[index.z], vec2(_region_size), vec2(index.xy));
	i_pos *= _vertex_spacing * control_scale;

	// Projection
	vec2 i_uv = i_vertex.xz;
	vec4 i_dd = vec4(base_ddx.xz, base_ddy.xz);
	mat2 p_align = mat2(1.);
	if (i_normal.y <= 0.7071067811865475) { // sqrt(0.5)
		// Projected normal map alignment matrix
		p_align = mat2(vec2(i_normal.z, -i_normal.x), vec2(i_normal.x, i_normal.z));
		// Fast 45 degree snapping https://iquilezles.org/articles/noatan/
		vec2 xz = round(normalize(-i_normal.xz) * 1.3065629648763765); // sqrt(1.0 + sqrt(0.5))
		xz *= abs(xz.x) + abs(xz.y) > 1.5 ? 0.7071067811865475 : 1.0; // sqrt(0.5)
		xz = vec2(-xz.y, xz.x);
		i_pos = floor(vec2(dot(i_pos, xz), -h));
		i_uv = vec2(dot(i_vertex.xz, xz), -i_vertex.y);
		#ifndef IS_DISPLACEMENT_BUFFER
		i_dd.xy = vec2(dot(base_ddx.xz, xz), -base_ddx.y);
		i_dd.zw = vec2(dot(base_ddy.xz, xz), -base_ddy.y);
		#endif
	}


	// Control map rotation. Must be applied seperatley from detiling to maintain UV continuity.
	float c_angle = DECODE_ANGLE(control);
	vec2 c_cs_angle = vec2(cos(c_angle), sin(c_angle));
	i_uv = rotate_vec2(i_uv, c_cs_angle);
	i_pos = rotate_vec2(i_pos, c_cs_angle);

	// Blend adjustment of Higher ID from Lower ID normal map in world space.
	float world_normal = 1.;
	// mat3 multiply, reduced to 2x fma and 1x mult.
	#define FAST_WORLD_NORMAL(n) fma(TNB[0], vec3(n.x), fma(TNB[2], vec3(n.z), TNB[1] * vec3(n.y)))
	
	float blend = DECODE_BLEND(control); // only used for branching.
	float sharpness = fma(60., blend_sharpness, 4.);

	// dual scaling
	float far_factor = clamp(smoothstep(dual_scale_near, dual_scale_far, length(v_vertex - v_camera_pos)), 0.0, 1.0);
	vec4 far_alb = vec4(0.);
	vec4 far_nrm = vec4(0.);
	float far_ao = 1.0;
	if (far_factor > 0. && any(equal(texture_id, ivec2(dual_scale_texture)))) {
		float far_scale = _texture_uv_scale_array[dual_scale_texture] * dual_scale_reduction;
		if (index.z < 0) {
			far_scale *= tri_scale_reduction;
		}
		vec4 far_dd = i_dd * far_scale;

		// Detiling and Control map rotation
		vec2 uv_center = floor(fma(i_pos, vec2(far_scale), vec2(0.5)));
		vec2 far_detile = fma(random(uv_center), 2.0, -1.0) * _texture_detile_array[dual_scale_texture] * TAU;
		vec2 far_cs_angle = vec2(cos(far_detile.x), sin(far_detile.x));
		// Apply UV rotation and shift around pivot.
		vec2 far_uv = rotate_vec2(fma(i_uv, vec2(far_scale), -uv_center), far_cs_angle) + uv_center + far_detile.y - 0.5;
		// Manual transpose to rotate derivatives and normals counter to uv rotation whilst also
		// including control map rotation. avoids extra matrix op, and sin/cos calls.
		far_cs_angle = vec2(
			fma(far_cs_angle.x, c_cs_angle.x, -far_cs_angle.y * c_cs_angle.y),
			fma(far_cs_angle.y, c_cs_angle.x, far_cs_angle.x * c_cs_angle.y));
		// Align derivatives for correct anisotropic filtering
		far_dd.xy = rotate_vec2(far_dd.xy, far_cs_angle);
		far_dd.zw = rotate_vec2(far_dd.zw, far_cs_angle);

		far_alb = textureGrad(_texture_array_albedo, vec3(far_uv, float(dual_scale_texture)), far_dd.xy, far_dd.zw);
		far_nrm = textureGrad(_texture_array_normal, vec3(far_uv, float(dual_scale_texture)), far_dd.xy, far_dd.zw);
		far_alb.rgb *= _texture_color_array[dual_scale_texture].rgb;
		far_nrm.a = clamp(far_nrm.a + _texture_roughness_mod_array[dual_scale_texture], 0., 1.);
		// Unpack and rotate normal map.
		far_nrm.xyz = fma(far_nrm.xzy, vec3(2.0), vec3(-1.0));
		far_ao = length(far_nrm.xyz) * 2.0 - 1.0;
		far_ao = mix(far_ao * far_ao * _texture_ao_strength_array[dual_scale_texture] + 1.0 - _texture_ao_strength_array[dual_scale_texture], 1.0, far_alb.a * far_alb.a);
		far_nrm.xyz = normalize(far_nrm.xyz);
		far_nrm.xz = rotate_vec2(far_nrm.xz, far_cs_angle) * p_align;
		
		// apply weighting when far_factor == 1.0 as the later lookup will be skipped.
		if (far_factor == 1.0) {
			float id_w = texture_id[0] == dual_scale_texture ? texture_weight[0] : texture_weight[1];
			float id_weight = exp2(sharpness * log2(weight + id_w + far_alb.a)) * weight;
			world_normal = FAST_WORLD_NORMAL(far_nrm).y;
			mat.albedo_height = fma(far_alb, vec4(id_weight), mat.albedo_height);
			mat.normal_rough = fma(far_nrm, vec4(id_weight), mat.normal_rough);
			mat.normal_map_depth = fma(_texture_normal_depth_array[dual_scale_texture], id_weight, mat.normal_map_depth);
			mat.ao = fma(far_ao, id_weight, mat.ao);
			mat.ao_affect = fma(_texture_ao_affect_array[dual_scale_texture], id_weight, mat.ao_affect);
			mat.total_weight += id_weight;
		}
	}


	// 1st Texture Asset ID
	if (blend < 1.0 
			&& !(far_factor == 1.0 && texture_id[0] == dual_scale_texture)
		) {
		int id = texture_id[0];
		float id_w = texture_weight[0];
		float id_scale = _texture_uv_scale_array[id];
		vec4 id_dd = i_dd * id_scale;

		// Detiling and Control map rotation
		vec2 uv_center = floor(fma(i_pos, vec2(id_scale), vec2(0.5)));
		vec2 id_detile = fma(random(uv_center), 2.0, -1.0) * _texture_detile_array[id] * TAU;
		vec2 id_cs_angle = vec2(cos(id_detile.x), sin(id_detile.x));
		// Apply UV rotation and shift around pivot.
		vec2 id_uv = rotate_vec2(fma(i_uv, vec2(id_scale), -uv_center), id_cs_angle) + uv_center + id_detile.y - 0.5;
		// Manual transpose to rotate derivatives and normals counter to uv rotation whilst also
		// including control map rotation. avoids extra matrix op, and sin/cos calls.
		id_cs_angle = vec2(
			fma(id_cs_angle.x, c_cs_angle.x, -id_cs_angle.y * c_cs_angle.y),
			fma(id_cs_angle.y, c_cs_angle.x, id_cs_angle.x * c_cs_angle.y));
		// Align derivatives for correct anisotropic filtering
		id_dd.xy = rotate_vec2(id_dd.xy, id_cs_angle);
		id_dd.zw = rotate_vec2(id_dd.zw, id_cs_angle);

		vec4 alb = textureGrad(_texture_array_albedo, vec3(id_uv, float(id)), id_dd.xy, id_dd.zw);
		vec4 nrm = textureGrad(_texture_array_normal, vec3(id_uv, float(id)), id_dd.xy, id_dd.zw);
		alb.rgb *= _texture_color_array[id].rgb;
		nrm.a = clamp(nrm.a + _texture_roughness_mod_array[id], 0., 1.);
		// Unpack and rotate normal map.
		nrm.xyz = fma(nrm.xzy, vec3(2.0), vec3(-1.0));
		float ao = length(nrm.xyz) * 2.0 - 1.0;
		ao = mix(ao * ao * _texture_ao_strength_array[id] + 1.0 - _texture_ao_strength_array[id], 1.0, alb.a * alb.a);
		nrm.xyz = normalize(nrm.xyz);
		nrm.xz = rotate_vec2(nrm.xz, id_cs_angle) * p_align;

		// If dual scaling, apply to overlay texture
		if (id == dual_scale_texture && far_factor > 0.) {
			alb = mix(alb, far_alb, far_factor);
			nrm = mix(nrm, far_nrm, far_factor);
			ao = mix(ao, far_ao, far_factor);
			world_normal = mix(world_normal, 1.0, far_factor);
		}
		world_normal = FAST_WORLD_NORMAL(nrm).y;

		float id_weight = exp2(sharpness * log2(weight + id_w + alb.a)) * weight;
		mat.albedo_height = fma(alb, vec4(id_weight), mat.albedo_height);
		mat.normal_rough = fma(nrm, vec4(id_weight), mat.normal_rough);
		mat.normal_map_depth = fma(_texture_normal_depth_array[id], id_weight, mat.normal_map_depth);
		mat.ao = fma(ao, id_weight, mat.ao);
		mat.ao_affect = fma(_texture_ao_affect_array[id], id_weight, mat.ao_affect);
		mat.total_weight += id_weight;
	}

	// 2nd Texture Asset ID
	if (blend > 0.0 && texture_id[1] != texture_id[0]
		&& !(far_factor == 1.0 && texture_id[1] == dual_scale_texture)
		) {
		int id = texture_id[1];
		float id_w = texture_weight[1];
		float id_scale = _texture_uv_scale_array[id];
		vec4 id_dd = i_dd * id_scale;

		// Detiling and Control map rotation
		vec2 uv_center = floor(fma(i_pos, vec2(id_scale), vec2(0.5)));
		vec2 id_detile = fma(random(uv_center), 2.0, -1.0) * _texture_detile_array[id] * TAU;
		vec2 id_cs_angle = vec2(cos(id_detile.x), sin(id_detile.x));
		// Apply UV rotation and shift around pivot.
		vec2 id_uv = rotate_vec2(fma(i_uv, vec2(id_scale), -uv_center), id_cs_angle) + uv_center + id_detile.y - 0.5;
		// Manual transpose to rotate derivatives and normals counter to uv rotation whilst also
		// including control map rotation. avoids extra matrix op, and sin/cos calls.
		id_cs_angle = vec2(
			fma(id_cs_angle.x, c_cs_angle.x, -id_cs_angle.y * c_cs_angle.y),
			fma(id_cs_angle.y, c_cs_angle.x, id_cs_angle.x * c_cs_angle.y));
		// Align derivatives for correct anisotropic filtering
		id_dd.xy = rotate_vec2(id_dd.xy, id_cs_angle);
		id_dd.zw = rotate_vec2(id_dd.zw, id_cs_angle);

		vec4 alb = textureGrad(_texture_array_albedo, vec3(id_uv, float(id)), id_dd.xy, id_dd.zw);
		vec4 nrm = textureGrad(_texture_array_normal, vec3(id_uv, float(id)), id_dd.xy, id_dd.zw);
		alb.rgb *= _texture_color_array[id].rgb;
		nrm.a = clamp(nrm.a + _texture_roughness_mod_array[id], 0., 1.);
		// Unpack and rotate normal map.
		nrm.xyz = fma(nrm.xzy, vec3(2.0), vec3(-1.0));
		float ao = length(nrm.xyz) * 2.0 - 1.0;
		ao = mix(ao * ao * _texture_ao_strength_array[id] + 1.0 - _texture_ao_strength_array[id], 1.0, alb.a * alb.a);
		nrm.xyz = normalize(nrm.xyz);
		nrm.xz = rotate_vec2(nrm.xz, id_cs_angle) * p_align;

		// If dual scaling, apply to overlay texture
		if (id == dual_scale_texture && far_factor > 0.) {
			alb = mix(alb, far_alb, far_factor);
			nrm = mix(nrm, far_nrm, far_factor);
			ao = mix(ao, far_ao, far_factor);
			world_normal = mix(world_normal, 1.0, far_factor);
		}
		float id_weight = exp2(sharpness * log2(weight + id_w + alb.a * clamp(world_normal, 0., 1.))) * weight;
		mat.albedo_height = fma(alb, vec4(id_weight), mat.albedo_height);
		mat.normal_rough = fma(nrm, vec4(id_weight), mat.normal_rough);
		mat.normal_map_depth = fma(_texture_normal_depth_array[id], id_weight, mat.normal_map_depth);
		mat.ao = fma(ao, id_weight, mat.ao);
		mat.ao_affect = fma(_texture_ao_affect_array[id], id_weight, mat.ao_affect);
		mat.total_weight += id_weight;
	}
}

float get_height(vec2 index_id, vec2 offset, float region_mipmap) {
	float weight = clamp(region_mipmap - floor(region_mipmap), 0., 1.);
	int mip_low = max(int(floor(region_mipmap)), 0);
	int mip_high = max(int(ceil(region_mipmap)), 0);
	ivec3 coord_low = get_index_coord(index_id + offset * exp2(float(mip_low)));
	ivec3 coord_high = get_index_coord(index_id + offset * exp2(float(mip_high)));
	coord_low.xy = coord_low.xy >> mip_low;
	coord_high.xy = coord_high.xy >> mip_high;
	float height = mix(
		texelFetch(_height_maps, coord_low, mip_low).r,
		texelFetch(_height_maps, coord_high, mip_high).r,
		weight);
	if (_background_mode != 0u) {
		float blend = get_region_blend(index_id * _region_texel_size + offset * max(1., exp2(region_mipmap)) * _region_texel_size);
		height = mix(height, ground_level, smoothstep(0., 1., blend));
	}
	return height;
}


void fragment() {
	// Recover UVs
	vec2 uv = UV;
	vec2 uv2 = UV2;
	
	// Lookup offsets, ID and blend weight
	vec3 region_uv = get_index_uv(uv2);
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

	ivec3 index[4];
	// control map lookups
	index[0] = get_index_coord(index_id + offsets.xy);
	index[1] = get_index_coord(index_id + offsets.yy);
	index[2] = get_index_coord(index_id + offsets.yx);
	index[3] = get_index_coord(index_id + offsets.xx);
	
	vec3 base_ddx = dFdxCoarse(v_vertex);
	vec3 base_ddy = dFdyCoarse(v_vertex);
	// Calculate the effective mipmap for regionspace, and when less than 0,
	// skip all extra lookups required for bilinear blend.
	float region_mip = log2(max(length(base_ddx.xz), length(base_ddy.xz)) * _vertex_density);
	bool bilerp = region_mip < 4.0 && any(greaterThan(ivec4(index[0].z, index[1].z, index[2].z, index[3].z), ivec4(-1)));

	// seperate weights are needed to blend across mipmapped normals
	float normal_mip_scale = max(1., exp2(region_mip));
	vec2 n_weight = fract(uv / normal_mip_scale);
	vec2 n_invert = 1.0 - n_weight;
	vec4 n_weights = vec4(
		n_invert.x * n_weight.y, // 0
		n_weight.x * n_weight.y, // 1
		n_weight.x * n_invert.y, // 2
		n_invert.x * n_invert.y  // 3
	);

	// Terrain normals
	vec3 index_normal[4];
	float h[4];
	// Allows for additional derivatives, eg world background, brush previews etc
	float u = 0.0;
	float v = 0.0;

	// World Noise
	if (_background_mode == 2u && world_noise_fragment_normals) {
		float noise_height = get_noise_height(uv2);
		u += noise_height - get_noise_height(uv2 + vec2(_region_texel_size, 0.0));
		v += noise_height - get_noise_height(uv2 + vec2(0.0, _region_texel_size));
	}
	if (_background_mode == 2u && !world_noise_fragment_normals) {
		u += world_noise_ddxy.x;
		v += world_noise_ddxy.y;
	}
	u *= normal_mip_scale;
	v *= normal_mip_scale;

	h[3] = get_height(index_id, offsets.xx, region_mip); // 0 (0, 0)
	h[2] = get_height(index_id, offsets.yx, region_mip); // 1 (1, 0)
	h[0] = get_height(index_id, offsets.xy, region_mip); // 2 (0, 1)
	index_normal[3] = normalize(vec3(h[3] - h[2] + u, _vertex_spacing * normal_mip_scale, h[3] - h[0] + v));

	// Set flat world normal - overwritten if bilerp is true
	vec3 w_normal = index_normal[3];

	// Adjust derivatives for mipmap bias and depth blur effect
	float bias = mix(mipmap_bias,
		depth_blur + 1.,
		smoothstep(0.0, 1.0, (v_vertex_xz_dist - bias_distance) * DIV_1024));
	base_ddx *= bias;
	base_ddy *= bias;

	// Color map
	vec4 color_map = region_uv.z > -1.0 ? textureLod(_color_maps, region_uv, region_mip) : COLOR_MAP_DEF;

	// Branching smooth normals and manually interpolated color map - fixes cross region artifacts
	if (bilerp) {
		// 4 lookups if linear filtering, else 1 lookup.
		vec4 col_map[4];
		col_map[3] = index[3].z > -1 ? texelFetch(_color_maps, index[3], 0) : COLOR_MAP_DEF;
		#ifdef FILTER_LINEAR
		col_map[0] = index[0].z > -1 ? texelFetch(_color_maps, index[0], 0) : COLOR_MAP_DEF;
		col_map[1] = index[1].z > -1 ? texelFetch(_color_maps, index[1], 0) : COLOR_MAP_DEF;
		col_map[2] = index[2].z > -1 ? texelFetch(_color_maps, index[2], 0) : COLOR_MAP_DEF;

		color_map =
			col_map[0] * weights[0] +
			col_map[1] * weights[1] +
			col_map[2] * weights[2] +
			col_map[3] * weights[3] ;
		#else
		color_map = col_map[3];
		#endif

		// 5 lookups
		// Fetch the additional required height values for smooth normals
		h[1] = get_height(index_id, offsets.yy, region_mip); // 3 (1, 1)
		float h_4 = get_height(index_id, offsets.yz, region_mip); // 4 (1, 2)
		float h_5 = get_height(index_id, offsets.zy, region_mip); // 5 (2, 1)
		float h_6 = get_height(index_id, offsets.zx, region_mip); // 6 (2, 0)
		float h_7 = get_height(index_id, offsets.xz, region_mip); // 7 (0, 2)

		// Calculate the normal for the remaining index ids.
		index_normal[0] = normalize(vec3(h[0] - h[1] + u, _vertex_spacing * normal_mip_scale, h[0] - h_7 + v));
		index_normal[1] = normalize(vec3(h[1] - h_5 + u, _vertex_spacing * normal_mip_scale, h[1] - h_4 + v));
		index_normal[2] = normalize(vec3(h[2] - h_6 + u, _vertex_spacing * normal_mip_scale, h[2] - h[1] + v));

		// Set interpolated world normal
		w_normal =
			index_normal[0] * n_weights[0] +
			index_normal[1] * n_weights[1] +
			index_normal[2] * n_weights[2] +
			index_normal[3] * n_weights[3] ;
	}

	vec3 w_tangent = normalize(cross(w_normal, vec3(0.0, 0.0, 1.0)));
	vec3 w_binormal = normalize(cross(w_normal, w_tangent));
	mat3 TNB = mat3(w_tangent, w_normal, w_binormal);

	// Apply terrain normals
	if (flat_terrain_normals) {
		NORMAL = normalize(cross(dFdyCoarse(VERTEX), dFdxCoarse(VERTEX)));
		TANGENT = normalize(cross(NORMAL, VIEW_MATRIX[2].xyz));
		BINORMAL = normalize(cross(NORMAL, TANGENT));
	} else {
		NORMAL = mat3(VIEW_MATRIX) * w_normal;
		TANGENT = mat3(VIEW_MATRIX) * w_tangent;
		BINORMAL = mat3(VIEW_MATRIX) * w_binormal;
	}

	// Get index control data
	// 1 - 4 lookups
	uvec4 control = uvec4(floatBitsToUint(texelFetch(_control_maps, index[3], 0).r));
	if (bilerp) {
		control = uvec4(
		floatBitsToUint(texelFetch(_control_maps, index[0], 0).r),
		floatBitsToUint(texelFetch(_control_maps, index[1], 0).r),
		floatBitsToUint(texelFetch(_control_maps, index[2], 0).r),
		control[3]);
	}

	{
		// Auto blend calculation
		float auto_blend = clamp(fma(auto_slope * 2.0, (w_normal.y - 1.0), 1.0)
			- auto_height_reduction * 0.01 * v_vertex.y, 0.0, 1.0);
		// Enable Autoshader if outside regions or painted in regions, otherwise manual painted
		uvec4 is_auto = (control & uvec4(0x1u)) | 
			uvec4(lessThan(ivec4(index[0].z, index[1].z, index[2].z, index[3].z), ivec4(0)));
		uint u_auto = 
			((uint(auto_base_texture) & 0x1Fu) << 27u) |
			((uint(auto_overlay_texture) & 0x1Fu) << 22u) |
			((uint(fma(auto_blend, 255.0 , 0.5)) & 0xFFu) << 14u);
		control = control * (1u - is_auto) + u_auto * is_auto;
	}


	// Texture weights
	// Vectorised Deocode of all texture IDs, then swizzle to per index mapping.
	// Passed to accumulate_material to avoid repeated decoding.
	ivec4 t_id[2] = {ivec4(control >> uvec4(27u) & uvec4(0x1Fu)),
		ivec4(control >> uvec4(22u) & uvec4(0x1Fu))};
	ivec2 texture_ids[4] = ivec2[4](
		ivec2(t_id[0].x, t_id[1].x),
		ivec2(t_id[0].y, t_id[1].y),
		ivec2(t_id[0].z, t_id[1].z),
		ivec2(t_id[0].w, t_id[1].w));

	// uninterpolated weights.
	vec4 weights_id_1 = vec4(control >> uvec4(14u) & uvec4(0xFFu)) * DIV_255;
	vec4 weights_id_0 = 1.0 - weights_id_1;
	vec2 t_weights[4] = vec2[4](
				vec2(weights_id_0[0], weights_id_1[0]),
				vec2(weights_id_0[1], weights_id_1[1]),
				vec2(weights_id_0[2], weights_id_1[2]),
				vec2(weights_id_0[3], weights_id_1[3]));
	// interpolated weights
	if (bilerp) {
		t_weights = {vec2(0), vec2(0), vec2(0), vec2(0)};
		weights_id_0 *= weights;
		weights_id_1 *= weights;
		for (int i = 0; i < 4; i++) {
			vec2 w_0 = vec2(weights_id_0[i]);
			vec2 w_1 = vec2(weights_id_1[i]);
			ivec2 id_0 = texture_ids[i].xx;
			ivec2 id_1 = texture_ids[i].yy;
			t_weights[0] += fma(w_0, vec2(equal(texture_ids[0], id_0)), w_1 * vec2(equal(texture_ids[0], id_1)));
			t_weights[1] += fma(w_0, vec2(equal(texture_ids[1], id_0)), w_1 * vec2(equal(texture_ids[1], id_1)));
			t_weights[2] += fma(w_0, vec2(equal(texture_ids[2], id_0)), w_1 * vec2(equal(texture_ids[2], id_1)));
			t_weights[3] += fma(w_0, vec2(equal(texture_ids[3], id_0)), w_1 * vec2(equal(texture_ids[3], id_1)));
		}
	}

	// Struct to accumulate all texture data.
	material mat = material(vec4(0.0), vec4(0.0), 0., 0., 0., 0.);

	// 2 - 4 lookups, 2 - 6 if dual scale texture
	accumulate_material(base_ddx, base_ddy, TNB, weights[3], index[3], control[3], t_weights[3],
		texture_ids[3], index_normal[3], h[3], mat);

	// 6 - 12 lookups, 6 - 18 if dual scale texture
	if (bilerp) {
		accumulate_material(base_ddx, base_ddy, TNB, weights[2], index[2], control[2], t_weights[2],
			texture_ids[2], index_normal[2], h[2], mat);
		accumulate_material(base_ddx, base_ddy, TNB, weights[1], index[1], control[1], t_weights[1],
			texture_ids[1], index_normal[1], h[1], mat);
		accumulate_material(base_ddx, base_ddy, TNB, weights[0], index[0], control[0], t_weights[0],
			texture_ids[0], index_normal[0], h[0], mat);
	}

	// normalize accumulated values back to 0.0 - 1.0 range.
	float weight_inv = 1.0 / max(mat.total_weight, 1e-8);
	mat.albedo_height *= weight_inv;
	mat.normal_rough *= weight_inv;
	mat.normal_map_depth *= weight_inv;
	mat.ao *= weight_inv;
	mat.ao_affect *= weight_inv;

	vec3 normal_map = fma(normalize(mat.normal_rough.xzy), vec3(0.5), vec3(0.5));
	float distant_normal_amplifier = clamp(max(length(base_ddx.xz), length(base_ddy.xz)), 1., distant_normal_scale);
	mat.normal_map_depth *= distant_normal_amplifier;

		// Macro variation. 2 lookups
	{
		float noise1 = texture(noise_texture, rotate_vec2(fma(uv, vec2(noise1_scale * .1), noise1_offset) , vec2(cos(noise1_angle), sin(noise1_angle)))).r;
		float noise2 = texture(noise_texture, uv * noise2_scale * .1).r;
		vec3 macrov = mix(macro_variation1, vec3(1.), noise1);
		macrov *= mix(macro_variation2, vec3(1.), noise2);
		mat.albedo_height.rgb *= mix(vec3(1.0), macrov, clamp(w_normal.y + macro_variation_slope, 0., 1.));
	}


	// Wetness/roughness modifier, converting 0 - 1 range to -1 to 1 range, clamped to Godot roughness values 
	float wetness = fma(color_map.a, -2., 1.);
	float roughness = clamp(mat.normal_rough.a - wetness, 0., 1.);
	
	// Specular w/ non-light-facing suppression. Apply wetness after so it reflects the sky after sunset
	float terrain_facing_light = clamp(dot(w_normal, normalize(_light_direction)), 0.0, 1.0);
	float specular = 1. - mat.normal_rough.a;
	specular *= mix(0.0, 1.0, terrain_facing_light);
	specular = clamp(specular + wetness, 0., 1.);

	// Apply PBR
	ALBEDO = mat.albedo_height.rgb * color_map.rgb;
	ROUGHNESS = roughness;
	SPECULAR = specular;
	// Repack final normal map value
	NORMAL_MAP = normal_map;
	NORMAL_MAP_DEPTH = mat.normal_map_depth;
	AO = clamp(mat.ao, 0., 1.);
	AO_LIGHT_AFFECT = mat.ao_affect;


}

