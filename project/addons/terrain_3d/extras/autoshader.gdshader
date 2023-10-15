shader_type spatial;
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

//varying vec3 v_region;
varying vec3 v_camera_pos;
varying float v_xz_dist;
varying vec3 v_vertex;
varying float v_vertex_dist;

////////////////////////
// Vertex
////////////////////////

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

// World Noise

uniform sampler2D _region_blend_map : hint_default_black, filter_linear, repeat_disable;
uniform int noise_max_octaves : hint_range(0, 15) = 4;
uniform int noise_min_octaves : hint_range(0, 15) = 2;
uniform float noise_lod_distance : hint_range(0, 40000, 1) = 7500.;
uniform float noise_scale : hint_range(0.5, 20, 0.01) = 5.0;
uniform float noise_height : hint_range(0, 1000, 0.1) = 64.0;
uniform vec3 noise_offset = vec3(0.0);
uniform float noise_blend_near : hint_range(0, .95, 0.01) = 0.5;
uniform float noise_blend_far : hint_range(.05, 1, 0.01) = 1.0;

float hashf(float f) {
	return fract(sin(f) * 1e4);
}

float hashv2(vec2 v) {
	return fract(1e4 * sin(17.0 * v.x + v.y * 0.1) * (0.1 + abs(sin(v.y * 13.0 + v.x))));
}

//https://iquilezles.org/articles/morenoise/
vec3 noise2D(vec2 x) {
    vec2 f = fract(x);
    // Quintic Hermine Curve.  Similar to SmoothStep()
    vec2 u = f*f*f*(f*(f*6.0-15.0)+10.0);
    vec2 du = 30.0*f*f*(f*(f-2.0)+1.0);

    // Generated hashes
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
		float(noise_max_octaves) - floor(v_xz_dist/(noise_lod_distance)),
        float(noise_min_octaves), float(noise_max_octaves)) );

    for( int i=0; i < octaves; i++ ) {
        vec3 n = noise2D(p);
        d += n.yz;
        a += b * n.x / (1.0 + dot(d,d));
        b *= 0.5;
        p = mat2( vec2(0.8, -0.6), vec2(0.6, 0.8) ) * p * 2.0;
    }
    return a;
}

// World Noise end
float get_height(vec2 uv) {
	float height = 0.0;
	vec3 region = get_regionf(uv);
	if (region.z >= 0.) {
		height = texture(_height_maps, region).r;
	}
	// World Noise
	float weight = texture(_region_blend_map, (uv/float(_region_map_size))+0.5).r;
	float rmap_half_size = float(_region_map_size)*.5;
	if(abs(uv.x) > rmap_half_size+.5 || abs(uv.y) > rmap_half_size+.5) {
		weight = 0.;
	} else {
		if(abs(uv.x) > rmap_half_size-.5) {
			weight = mix(weight, 0., abs(uv.x) - (rmap_half_size-.5));
		}
		if(abs(uv.y) > rmap_half_size-.5) {
			weight = mix(weight, 0., abs(uv.y) - (rmap_half_size-.5));
		}
	}
	height = mix(height, world_noise((uv+noise_offset.xz) * noise_scale*.1) 
        * noise_height*10. + noise_offset.y*100.,
		clamp(smoothstep(noise_blend_near, noise_blend_far, 1.0 - weight), 0.0, 1.0));
 	return height;
}

void vertex() {
	// Get camera pos in world vertex coords
    v_camera_pos = INV_VIEW_MATRIX[3].xyz;

    // Get vertex in world coordinates
    vec3 world_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Get camera XZ distance to vertex
    v_xz_dist = length(world_vertex.xz - v_camera_pos.xz);
	
    // Scale world UV coordinates down, so individual material UVs can be larger
    UV = world_vertex.xz * 0.5;
    UV2 = ((world_vertex.xz + vec2(0.5)) / vec2(_region_size));
	VERTEX.y = get_height(UV2);
	
	//Save final vertex in world space and get camera distance to final vertex
	v_vertex = (MODEL_MATRIX * vec4(VERTEX,1.0)).xyz;
    v_vertex_dist = length(v_vertex - v_camera_pos);

	NORMAL = vec3(0, 1, 0);
}

////////////////////////
// Fragment
////////////////////////

vec3 get_normal(vec2 uv, out vec3 tangent, out vec3 binormal) {
	// Normal calc
	// Control map is also sampled 4 times, so in theory we could reduce the region samples to 4 from 8,
	// but control map sampling is slightly different with the mirroring and doesn't work here.
	// The region map is very, very small, so maybe the performance cost isn't too high
	float left = get_height(uv + vec2(-_region_pixel_size, 0));
	float right = get_height(uv + vec2(_region_pixel_size, 0));
	float back = get_height(uv + vec2(0, -_region_pixel_size));
	float front = get_height(uv + vec2(0, _region_pixel_size));
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

//vec4 height_blend(vec4 a_value, float a_bump, vec4 b_value, float b_bump, float t) {
vec4 height_blend(vec4 a_value, vec4 b_value, float factor) {
	float ma = max(a_value.a + (1.0 - factor), b_value.a + factor) - 0.1;
	float ba = max(a_value.a + (1.0 - factor) - ma, 0.0);
	float bb = max(b_value.a + factor - ma, 0.0);
	return (a_value * ba + b_value * bb) / (ba + bb);
}

vec2 rotate(vec2 v, float cosa, float sina) {
	return vec2(cosa * v.x - sina * v.y, sina * v.x + cosa * v.y);
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

		albedo = height_blend(albedo, albedo2, index.b);
		normal = height_blend(normal, normal2, index.b);
	}

	normal = pack_normal(normal.xyz, normal.a);
	weight = blend_weights(weight, albedo.a);
	out_normal += normal * weight;
	total_weight += weight;
	return albedo * weight;
}

uniform int base_material = 0;
uniform int cover_material = 1;
uniform bool height_blending = true;
uniform float myslope : hint_range(0,10) = 1.;
uniform float far_scale_reduction : hint_range(0,1) = .1;
uniform float far_distance : hint_range(0,1000) = 160.;
uniform float near_distance : hint_range(0,1000) = 80.;


void fragment() {
	// Calculate Terrain Normals
	vec3 w_tangent, w_binormal;
	vec3 w_normal = get_normal(UV2, w_tangent, w_binormal);
	NORMAL = mat3(VIEW_MATRIX) * w_normal;
	TANGENT = mat3(VIEW_MATRIX) * w_tangent;
	BINORMAL = mat3(VIEW_MATRIX) * w_binormal;

	vec4 color = vec4(0.0);
	vec4 normal = vec4(0.0);
	
	if(true) {
		float slope = clamp(
			dot(vec3(0., 1., 0.), w_normal * myslope*2. - (myslope*2.-1.)) 
			- .001*v_vertex.y // Reduce as vertices get higher
			, 0., 1.);
		
		vec2 matUV0 = UV * _texture_uv_scale_array[base_material];
		vec2 matUV1 = UV * _texture_uv_scale_array[cover_material];
		vec4 base_alb_near = texture(_texture_array_albedo, vec3(matUV0, float(base_material)));
		vec4 base_nrm_near = texture(_texture_array_normal, vec3(matUV0, float(base_material)));
		vec4 base_alb_far = texture(_texture_array_albedo, vec3(matUV0*far_scale_reduction, float(base_material)));
		vec4 base_nrm_far = texture(_texture_array_normal, vec3(matUV0*far_scale_reduction, float(base_material)));
		vec4 top_alb = texture(_texture_array_albedo, vec3(matUV1, float(cover_material)));
		vec4 top_nrm = texture(_texture_array_normal, vec3(matUV1, float(cover_material)));
		
		// Multiple texture set albedo color
		base_alb_near.rgb *= _texture_color_array[base_material].rgb;
		base_alb_far.rgb *= _texture_color_array[base_material].rgb;
		top_alb.rgb *= _texture_color_array[cover_material].rgb;

		// Mix textures by near/far and slope
		float far_factor = 
			clamp(smoothstep(near_distance, far_distance, length(v_vertex_dist)), 0.0, 1.0);

		vec4 base_alb = mix(base_alb_near, base_alb_far, far_factor);
		vec4 base_nrm = mix(base_nrm_near, base_nrm_far, far_factor);

		if (height_blending) {
			// Height blend textures
			color = height_blend(base_alb, top_alb, slope);
			normal = height_blend(base_nrm, top_nrm, slope);
		} else {
			// Alpha blend textures
			color = mix(base_alb, top_alb, slope);
			normal = mix(base_nrm, top_nrm, slope);
		}

	} else
	{
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

	color = get_material(UV, index00, vec2(index00UV.xy), weights0.x * weights0.y, total_weight, normal);
	color += get_material(UV, index01, vec2(index01UV.xy), weights0.x * weights1.y, total_weight, normal);
	color += get_material(UV, index10, vec2(index10UV.xy), weights1.x * weights0.y, total_weight, normal);
	color += get_material(UV, index11, vec2(index11UV.xy), weights1.x * weights1.y, total_weight, normal);
	total_weight = 1.0 / total_weight;
	normal *= total_weight;
	color *= total_weight;
	}

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

//	ALBEDO = mat3(INV_VIEW_MATRIX) * NORMAL.rgb;
//	ALBEDO = vec3(w_normal.b);
//	ALBEDO = vec3(slope);
//	ALBEDO = vec3(v_vertex_dist*.0001);
//	ALBEDO = mix(vec3(1.,0.,0.), vec3(0.,0.,1.), v_vertex_dist/far_distance);
//	ALBEDO = mix(vec3(1.,0.,0.), vec3(0.,0.,1.), v_vertex_dist/(4.*far_distance));
//	ALBEDO = mix(vec3(1.,0.,0.), vec3(0.,0.,1.), 
//		clamp(smoothstep(near_distance, far_distance, length(v_vertex_dist)), 0.0, 1.0) );
}

