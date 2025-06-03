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
#define COLOR_MAP_DEF vec4(1.0, 1.0, 1.0, 0.5)
#define DIV_255 0.003921568627450 // 1. / 255.
#define DIV_1024 0.0009765625 // 1. / 1024.
#define TAU_16TH -0.392699081698724 // -TAU / 16.

// Inline Functions
#define DECODE_BLEND(control) float(control >> 14u & 0xFFu) * DIV_255
#define DECODE_AUTO(control) bool(control & 0x1u)
#define DECODE_BASE(control) int(control >> 27u & 0x1Fu)
#define DECODE_OVER(control) int(control >> 22u & 0x1Fu)
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
uniform vec3 _camera_pos = vec3(0.f);
uniform float _mesh_size = 48.f;
uniform uint _background_mode = 1u; // NONE = 0, FLAT = 1, NOISE = 2
uniform uint _mouse_layer = 0x80000000u; // Layer 32
uniform float _vertex_spacing = 1.0;
uniform float _vertex_density = 1.0; // = 1./_vertex_spacing
uniform float _region_size = 1024.0;
uniform float _region_texel_size = 0.0009765625; // = 1./region_size
uniform int _region_map_size = 32;
uniform int _region_map[1024];
uniform vec2 _region_locations[1024];
uniform float _texture_normal_depth_array[32];
uniform float _texture_ao_strength_array[32];
uniform float _texture_roughness_mod_array[32];
uniform float _texture_uv_scale_array[32];
uniform vec2 _texture_detile_array[32];
uniform vec4 _texture_color_array[32];
uniform highp sampler2DArray _height_maps : repeat_disable;
uniform highp sampler2DArray _control_maps : repeat_disable;
//INSERT: TEXTURE_SAMPLERS_NEAREST
//INSERT: TEXTURE_SAMPLERS_LINEAR

// Public uniforms
//INSERT: AUTO_SHADER_UNIFORMS
//INSERT: DUAL_SCALING_UNIFORMS
uniform float blend_sharpness : hint_range(0, 1) = 0.5;
uniform bool flat_terrain_normals = false;
uniform bool enable_projection = true;
uniform float projection_threshold : hint_range(0.0, 0.99, 0.01) = 0.8;

uniform float mipmap_bias : hint_range(0.5, 1.5, 0.01) = 1.0;
uniform float depth_blur : hint_range(0.0, 35.0, 0.1) = 0.0;
uniform float bias_distance : hint_range(0.0, 16384.0, 0.1) = 512.0;

uniform bool enable_macro_variation = true;
uniform vec3 macro_variation1 : source_color = vec3(1.);
uniform vec3 macro_variation2 : source_color = vec3(1.);
uniform float macro_variation_slope : hint_range(0., 1.)  = 0.333;

// Generic noise at 2 scales, which can be used for anything 
//INSERT: NOISE_SAMPLER_NEAREST
//INSERT: NOISE_SAMPLER_LINEAR
uniform float noise1_scale : hint_range(0.001, 1.) = 0.04; // Used for macro variation 1. Scaled up 10x
uniform float noise1_angle : hint_range(0, 6.283) = 0.;
uniform vec2 noise1_offset = vec2(0.5);
uniform float noise2_scale : hint_range(0.001, 1.) = 0.076;	// Used for macro variation 2. Scaled up 10x

// Varyings & Types

// This struct contains decoded control map values, that may be accessed multiple times.
struct control_data {
	ivec2 texture_id;
	vec2 texture_weight;
	float blend;
	float angle;
	float scale;
};
// control_data constructor
#define CONTROL_DATA(control) control_data(ivec2(DECODE_BASE(control), DECODE_OVER(control)), vec2(0.), DECODE_BLEND(control), DECODE_ANGLE(control), DECODE_SCALE(control))

struct material {
	vec4 albedo_height;
	vec4 normal_rough;
	float normal_map_depth;
	float ao_strength;
	float total_weight;
};

varying float v_vertex_xz_dist;
varying vec3 v_vertex;
)"

		R"(
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
	ivec3 v_region = get_index_coord(start_pos, VERTEX_PASS);
	uint control = floatBitsToUint(texelFetch(_control_maps, v_region, 0)).r;
	bool hole = DECODE_HOLE(control);

	// Show holes to all cameras except mouse camera (on exactly 1 layer)
	if ( !(CAMERA_VISIBLE_LAYERS == _mouse_layer) && 
			(hole || (_background_mode == 0u && v_region.z == -1))) {
		v_vertex.x = 0. / 0.;
	} else {		
		// Set final vertex height & calculate vertex normals. 3 lookups
		ivec3 coord_a = get_index_coord(start_pos, VERTEX_PASS);
		ivec3 coord_b = get_index_coord(end_pos, VERTEX_PASS);
		float h = mix(texelFetch(_height_maps, coord_a, 0).r,texelFetch(_height_maps, coord_b, 0).r,vertex_lerp);
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

float random(in vec2 xy) {
	return fract(sin(dot(xy, vec2(12.9898, 78.233))) * 43758.5453);
}

mat2 rotate_plane(float angle) {
	float c = cos(angle), s = sin(angle);
	return mat2(vec2(c, s), vec2(-s, c));
}

// Computes total accumulated weight for a given texture_id across all 4 indicies.
float accumulate_weight(int texture_id, control_data data[4], vec4 weights) {
	float w = 0.0;
	for (int i = 0; i < 4; i++) {
		w += weights[i] * (1.0 - data[i].blend) * float(data[i].texture_id[0] == texture_id);
		w += weights[i] * data[i].blend * float(data[i].texture_id[1] == texture_id);
	}
	return w;
}

// 2-4 lookups ( 2-6 with dual scaling )
void accumulate_material(vec3 base_ddx, vec3 base_ddy, float weight, ivec3 index, control_data data,
			vec3 i_normal, float h, mat3 TANGENT_WORLD_MATRIX, float sharpness, inout material mat) {

		// Index position for detiling & projection.
		vec2 i_pos = vec2(index.xy);
		i_pos += _region_locations[index.z] * _region_size;
		i_pos *= _vertex_spacing;

		// Projection
		vec2 i_uv = v_vertex.xz;
		vec4 i_dd = vec4(base_ddx.xz, base_ddy.xz);
		mat2 p_align = mat2(1.);
		if (i_normal.y <= projection_threshold && enable_projection) {
			// Projected normal map alignment matrix
			p_align = mat2(vec2(i_normal.z, -i_normal.x), vec2(i_normal.x, i_normal.z));
			// Fast 45 degree snapping https://iquilezles.org/articles/noatan/
			vec2 xz = round(normalize(-i_normal.xz) * 1.3065629648763765); // sqrt(1.0 + sqrt(0.5))
			xz *= abs(xz.x) + abs(xz.y) > 1.5? sqrt(0.5) : 1.0;
			xz = vec2(-xz.y, xz.x);
			i_pos = floor(vec2(dot(i_pos, xz), -h));
			i_uv = vec2(dot(v_vertex.xz, xz), -v_vertex.y);
			i_dd.xy = vec2(dot(base_ddx.xz, xz), -base_ddx.y);
			i_dd.zw = vec2(dot(base_ddy.xz, xz), -base_ddy.y);
		}

		// Control map scale
		i_dd *= data.scale;
		i_uv *= data.scale;
		i_pos *= data.scale;

		// Control map rotation
		mat2 c_align = rotate_plane(-data.angle);
		i_dd.xy *= c_align;
		i_dd.zw *= c_align;
		i_uv *= c_align;
		i_pos *= c_align;

//INSERT: DUAL_SCALING

		// world normal adjustment requires acess to base layer from next iteration
		vec4 nrm = vec4(0.,1.,0.,1.); // if base is skipped dont reduce any of the overlay height value
		for (int t = 0; t < 2; t++) {
			// 3 seperate checks is faster..
			// base layer not visible.
			if (t == 0 && data.blend > 0.999) {
				continue;
			}
			// both id match on the same index.
			if (t == 1 && data.texture_id[1] == data.texture_id[0]) {
				continue;
			}
			// overlay layer not visible.
			if (t == 1 && data.blend < 0.01) {
				continue;
			}

			int id = data.texture_id[t];
			float id_w = data.texture_weight[t];
			float id_scale = _texture_uv_scale_array[id];
			vec2 id_uv = i_uv * id_scale;
			vec4 id_dd = i_dd * id_scale;
			
			// Detiling and Control map rotation
			vec2 uv_center = floor(i_pos * id_scale + 0.5);
			float detile = fma(random(uv_center), 2.0, -1.0) * TAU;
			vec2 detile_shift = vec2(_texture_detile_array[id].y * detile);
			// detile rotation matrix
			mat2 id_align = rotate_plane(detile * _texture_detile_array[id].x);
			// Apply rotation and shift around pivot, offset to center UV over pivot.
			id_uv = id_align * (id_uv - uv_center + detile_shift) + uv_center + 0.5;
			// Transpose to rotate derivatives and normals counter to uv rotation, include control map rotation.
			id_align = transpose(id_align) * c_align;
			// Align derivatives for correct anisotropic filtering
			id_dd.xy *= id_align;
			id_dd.zw *= id_align;
			
			vec4 alb = textureGrad(_texture_array_albedo, vec3(id_uv, float(id)), id_dd.xy, id_dd.zw);
			// do this before its overwriten
			float world_normal = t == 0 ? 1. : clamp((TANGENT_WORLD_MATRIX * normalize(nrm.xyz)).y, 0., 1.);
			nrm = textureGrad(_texture_array_normal, vec3(id_uv, float(id)), id_dd.xy, id_dd.zw);
			alb.rgb *= _texture_color_array[id].rgb;
			nrm.a = clamp(nrm.a + _texture_roughness_mod_array[id], 0., 1.);
			// Unpack and rotate normal map.
			nrm.xyz = fma(nrm.xzy, vec3(2.0), vec3(-1.0));
			nrm.xz *= id_align;

//INSERT: DUAL_SCALING_MIX

			// Align normals to projection plane, identity matrix if not projected.
			nrm.xz *= p_align;

			float id_weight = exp2(sharpness * log2(weight + id_w + alb.a * world_normal)) * weight;
			mat.albedo_height += alb * id_weight;
			mat.normal_rough += nrm * id_weight;
			mat.normal_map_depth += _texture_normal_depth_array[id] * id_weight;
			mat.ao_strength += _texture_ao_strength_array[id] * id_weight;
			mat.total_weight += id_weight;
		}
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
	// control map lookups, used for some normal lookups as well
	index[0] = get_index_coord(index_id + offsets.xy, FRAGMENT_PASS);
	index[1] = get_index_coord(index_id + offsets.yy, FRAGMENT_PASS);
	index[2] = get_index_coord(index_id + offsets.yx, FRAGMENT_PASS);
	index[3] = get_index_coord(index_id + offsets.xx, FRAGMENT_PASS);
	
	vec3 base_ddx = dFdxCoarse(v_vertex);
	vec3 base_ddy = dFdyCoarse(v_vertex);
	// Calculate the effective mipmap for regionspace, and when less than 0,
	// skip all extra lookups required for bilinear blend.
	float region_mip = log2(max(length(base_ddx.xz), length(base_ddy.xz)) * _vertex_density);
	bool bilerp = region_mip < 0.0 && region_uv.z > -1.;

	// Terrain normals
	vec3 index_normal[4];
	float h[4];
	// allows additional derivatives, eg world noise, brush previews etc
	float u = 0.0;
	float v = 0.0;
	
//INSERT: WORLD_NOISE3	
	// Re-use index[] for the first lookups, skipping some math. 3 lookups
	h[3] = texelFetch(_height_maps, index[3], 0).r; // 0 (0,0)
	h[2] = texelFetch(_height_maps, index[2], 0).r; // 1 (1,0)
	h[0] = texelFetch(_height_maps, index[0], 0).r; // 2 (0,1)
	index_normal[3] = normalize(vec3(h[3] - h[2] + u, _vertex_spacing, h[3] - h[0] + v));

	// Set flat world normal - overriden if bilerp is true
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
		h[1] = texelFetch(_height_maps, index[1], 0).r; // 3 (1,1)
		float h_4 = texelFetch(_height_maps, get_index_coord(index_id + offsets.yz, FRAGMENT_PASS), 0).r; // 4 (1,2)
		float h_5 = texelFetch(_height_maps, get_index_coord(index_id + offsets.zy, FRAGMENT_PASS), 0).r; // 5 (2,1)
		float h_6 = texelFetch(_height_maps, get_index_coord(index_id + offsets.zx, FRAGMENT_PASS), 0).r; // 6 (2,0)
		float h_7 = texelFetch(_height_maps, get_index_coord(index_id + offsets.xz, FRAGMENT_PASS), 0).r; // 7 (0,2)

		// Calculate the normal for the remaining index ids.
		index_normal[0] = normalize(vec3(h[0] - h[1] + u, _vertex_spacing, h[0] - h_7 + v));
		index_normal[1] = normalize(vec3(h[1] - h_5 + u, _vertex_spacing, h[1] - h_4 + v));
		index_normal[2] = normalize(vec3(h[2] - h_6 + u, _vertex_spacing, h[2] - h[1] + v));

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
	// Apply per face normals directly without modifying world normal values, as they are used for texture blending
	if (flat_terrain_normals) {
		NORMAL = normalize(cross(dFdyCoarse(VERTEX),dFdxCoarse(VERTEX)));
		TANGENT = normalize(cross(NORMAL, VIEW_MATRIX[2].xyz));
		BINORMAL = normalize(cross(NORMAL, TANGENT));
	}
	
	// Used for material world space normal map blending
	mat3 TANGENT_WORLD_MATRIX = mat3(w_tangent, w_normal, w_binormal);

	// Get index control data
	// 4 lookups
	uint control[4] = {
		floatBitsToUint(texelFetch(_control_maps, index[0], 0).r),
		floatBitsToUint(texelFetch(_control_maps, index[1], 0).r),
		floatBitsToUint(texelFetch(_control_maps, index[2], 0).r),
		floatBitsToUint(texelFetch(_control_maps, index[3], 0).r)
	};

	// Parse control data
	control_data data[4] = {
		CONTROL_DATA(control[0]),
		CONTROL_DATA(control[1]),
		CONTROL_DATA(control[2]),
		CONTROL_DATA(control[3])
	};

//INSERT: AUTO_SHADER
	// Set per texture ID weighting.
	for (int i = 0; i < 4; i++) {
		data[i].texture_weight[0] = accumulate_weight(data[i].texture_id[0], data, weights);
		data[i].texture_weight[1] = accumulate_weight(data[i].texture_id[1], data, weights);
	}

	// Struct to accumulate all texture data.
	material mat = material(vec4(0.0), vec4(0.0), 0., 0., 0.);
	float sharpness = fma(56., blend_sharpness, 8.);
	
	// 2 - 4 lookups, 2 - 6 if dual scale texture
	accumulate_material(base_ddx, base_ddy, weights[3], index[3], data[3], index_normal[3], h[3],
		TANGENT_WORLD_MATRIX, sharpness, mat);

	// 6 - 12 lookups, 6 - 18 if dual scale texture
	if (bilerp) {
		accumulate_material(base_ddx, base_ddy, weights[2], index[2], data[2], index_normal[2], h[2],
			TANGENT_WORLD_MATRIX, sharpness, mat);
		accumulate_material(base_ddx, base_ddy, weights[1], index[1], data[1], index_normal[1], h[1],
			TANGENT_WORLD_MATRIX, sharpness, mat);
		accumulate_material(base_ddx, base_ddy, weights[0], index[0], data[0], index_normal[0], h[0],
			TANGENT_WORLD_MATRIX, sharpness, mat);
	}

	// normalize accumulated values back to 0.0 - 1.0 range.
	float weight_inv = 1.0 / mat.total_weight;
	mat.albedo_height *= weight_inv;
	mat.normal_rough *= weight_inv;
	mat.normal_map_depth *= weight_inv;
	mat.ao_strength *= weight_inv;

	// Macro variation. 2 lookups
	vec3 macrov = vec3(1.);
	if (enable_macro_variation) {
		float noise1 = texture(noise_texture, (uv * noise1_scale * .1 + noise1_offset) * rotate_plane(noise1_angle)).r;
		float noise2 = texture(noise_texture, uv * noise2_scale * .1).r;
		macrov = mix(macro_variation1, vec3(1.), noise1);
		macrov *= mix(macro_variation2, vec3(1.), noise2);
		macrov = mix(vec3(1.0), macrov, clamp(w_normal.y + macro_variation_slope, 0., 1.));
	}
	
	// Wetness/roughness modifier, converting 0 - 1 range to -1 to 1 range, clamped to Godot roughness values 
	float roughness = clamp(fma(color_map.a - 0.5, 2.0, mat.normal_rough.a), 0., 1.);
	
	// Apply PBR
	ALBEDO = mat.albedo_height.rgb * color_map.rgb * macrov;
	ROUGHNESS = roughness;
	SPECULAR = 1. - mat.normal_rough.a;
	// Repack final normal map value.
	NORMAL_MAP = fma(normalize(mat.normal_rough.xzy), vec3(0.5), vec3(0.5));
	NORMAL_MAP_DEPTH = mat.normal_map_depth;

	// Higher and/or facing up, less occluded.
	float ao = (1. - (mat.albedo_height.a * log(2.1 - mat.ao_strength))) * (1. - mat.normal_rough.y);
	AO = clamp(1. - ao * mat.ao_strength, mat.albedo_height.a, 1.0);
	AO_LIGHT_AFFECT = (1.0 - mat.albedo_height.a) * mat.normal_rough.y;

}

)"
