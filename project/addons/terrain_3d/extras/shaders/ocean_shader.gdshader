shader_type spatial;
render_mode cull_back, depth_draw_always, diffuse_burley, specular_schlick_ggx, skip_vertex_transform;

//////////////////////////////
// Constants
//////////////////////////////
const int ITERATIONS_VERTEX = 1;
const int ITERATIONS_FRAGMENT = 3;

//////////////////////////////
// Uniforms
//////////////////////////////
group_uniforms water;
uniform float sea_level : hint_range(-50.0, 50.0, 0.1) = 1.0;
uniform vec3 albedo_color : source_color = vec3(.1058, .1568, .2117); // This is a common deep blue
//uniform vec3 albedo_color : source_color = vec3(0.102, 0.212, 0.235); // This is a more green ocean
uniform float visible_depth : hint_range(0.001, 10000., .1) = 256.;
uniform float depth_curve : hint_range(0., 1.) = .2;
uniform float shore_blend : hint_range(0.0, 10.0, 0.01) = 1.;
uniform float refraction_strength : hint_range(0.0, 0.1, 0.001) = 0.02;
group_uniforms;

group_uniforms waves;
uniform float time_scale : hint_range(0.0, 64.0) = 8.0;
uniform float height_scale : hint_range(0.0, 16.0) = 3.0;
uniform float ocean_scale : hint_range(0.1, 8.0) = 2.0;
group_uniforms;

group_uniforms reflections;
uniform float fresnel_scale : hint_range(0., 1.) = .5;
uniform float fresnel_power : hint_range(0., 10.) = 1.;
uniform float specular : hint_range(0., 10.) = 1.;
group_uniforms;

group_uniforms foam;
uniform bool foam_enabled = true;
uniform float foam_height : hint_range(-2.0, 5.0) = 2.5;
uniform float foam_distance : hint_range(0.1, 16384.0) = 2048.;
uniform bool foam_shore_enabled = true;
uniform float foam_shore_intensity : hint_range(0.1, 100.0) = 2.;
uniform sampler2D foam_noise_texture;
uniform float foam_noise_scale : hint_range(0.1, 5.0) = 1.5;
group_uniforms;

group_uniforms light_scattering;
uniform bool light_scattering_enabled = true;
uniform float height_scattering : hint_range(0.0, 15.0) = 3.0;
uniform float height_threshold : hint_range(0.0, 1.0) = 0.1;
uniform float height_angle_threshold : hint_range(0.0, 1.0) = 0.21;
uniform float fersnel_scattering : hint_range(0.0, 70.0) = 20.0;
uniform float direct_scattering : hint_range(0.0, 70.0) = 10.0;
uniform float depth_absorption : hint_range(0.0, 10.0) = 1.0;
group_uniforms;


// Uniforms set by C++
group_uniforms private_set_by_terrain;
uniform float _mesh_size = 32.;
uniform float _subdiv = 1.;
uniform float _vertex_spacing = 1.;
uniform float _vertex_density = 1.;
uniform vec3 _target_pos = vec3(0.,0.,0.);
uniform vec3 _light_direction = vec3(-0.196, 0.980, 0);
uniform vec3 _light_color : source_color = vec3(1.0, 1.0, .735);
group_uniforms;

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;

varying vec3 v_vertex;
varying float v_vertex_distance;

//////////////////////////////
// Ocean Noise
//////////////////////////////

float hash(vec2 p) {
	uvec2 q = uvec2(ivec2(p)) * uvec2(1597334673u, 3812015801u);
    uint n = (q.x ^ q.y) * 1597334673u;
    return float(n) * (1.0 / float(0xffffffffu));
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = smoothstep(0., 1., f);
    vec2 i1 = i + 1.0;

    float a = hash(i);
    float b = hash(vec2(i1.x, i.y));
    float c = hash(vec2(i.x, i1.y));
    float d = hash(i1);

    return 2.0 * mix(mix(a, b, u.x), mix(c, d, u.x), u.y) - 1.0;
}

float octave(vec2 uv) {
	uv += noise((uv) * 0.5) * 2.;
	vec2 wave = 1.0 - abs(sin(uv));
	// Shaping
	float v = wave.x * wave.y + 1e-6;
	float s = v * inversesqrt(v);
	return 1.0 - 2.0 * s + v;
}

float ocean_height(vec2 pos, int iterations) {
	float freq = 0.03 * ocean_scale;
	float amp = 4.0;
	vec2 uv = pos;
	float h = 0.0;
	float t = TIME * time_scale;

	for (int i = 0; i < iterations; i++) {
	    h += (octave((uv + t) * freq) + octave((uv - t) * freq)) * amp;
	    uv *= mat2(vec2(1.8, 0.8), vec2(-0.8, 1.8));
	    freq *= 1.9;
	    amp *= 0.2;
	}
    return h * 0.1 * height_scale;
}

//////////////////////////////
// Vertex
//////////////////////////////


// vertex() positions the vertices of the clipmap mesh across the geomorphed lods. You'll need the
// first two blocks for any other water shader, from the start to setting v_vertex.xz. After that
// your own shader can set the UV and v_vertex.Y however you like.

void vertex() {
	// Get vertex of flat plane in world coordinates and set world UV
    v_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Geomorph vertex across clipmap LODs
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
    v_vertex.xz -= shift * scale * vertex_lerp;

	// UV coordinates in region space. 0-1 covers 1 region, 1-2 is the next region, etc.
    UV = v_vertex.xz;

	// Set height according to waves
    v_vertex.y = sea_level + ocean_height(UV, ITERATIONS_VERTEX);
    VERTEX = (VIEW_MATRIX * vec4(v_vertex, 1.0)).xyz;

	v_vertex_distance = length(v_vertex - _target_pos);
}

//////////////////////////////
// Fragment
//////////////////////////////

void fragment() {
	// Normals
	float h, u, v;
	// Adjust normal domain as screen space distance increases to reduce high frequency values across pixels
	float dv = max(0.25, length(fwidth(VERTEX)));
	vec2  n_uv = UV + dv * -0.66;
	h = ocean_height(n_uv, ITERATIONS_FRAGMENT);
	u = ocean_height(n_uv + vec2(dv, 0.0), ITERATIONS_FRAGMENT);
	v = ocean_height(n_uv + vec2(0.0, dv), ITERATIONS_FRAGMENT);
	const float wave_distance = 512.;
	vec3 world_normal = normalize(vec3(h - u, max(.1, v_vertex_distance/wave_distance), h - v));
	NORMAL = mat3(VIEW_MATRIX) * world_normal;
	TANGENT = normalize(cross(NORMAL, VIEW_MATRIX[2].xyz));
	BINORMAL = normalize(cross(NORMAL, TANGENT));

	// Horizon mask - 1.0 when light is above horizon w/ fade at edge
	float daytime_mask = smoothstep(0., .1, _light_direction.y);

	// Reflections
	float cos_theta = max(0.0, dot(NORMAL, VIEW));           // 1.0 when perpendicular (looking straight down), ~0.0 grazing
	float fresnel_base = pow(1.0 - cos_theta, fresnel_power); // high at grazing, low straight down
	float fresnel = clamp(fresnel_scale * fresnel_base, 0.0, 1.0);
	ROUGHNESS = mix(0.02, 0.8, fresnel) * daytime_mask;
	SPECULAR = specular * fresnel;
	SPECULAR = clamp ( SPECULAR - .5 *  (1. - daytime_mask), 0.15, 1.); // Mask far distance when sun is below horizon

	// Shore mask - 1.0 near the shore line
	float proximity_depth_tex = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec4 proximity_view_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, proximity_depth_tex, 1.0);
	proximity_view_pos.xyz /= proximity_view_pos.w;
	float shore_mask = 1.0 - clamp(1.0 - smoothstep(proximity_view_pos.z + 2. * shore_blend, proximity_view_pos.z, VERTEX.z), 0.0, 1.0);
	ALPHA = 1.0 - shore_mask;

	// Depth fade - based on vertex height rather than camera distance
	float depth_fade = 1. - depth_curve * (1. + smoothstep(0., 1., abs(sea_level - v_vertex.y) / visible_depth));

	// Albedo - start accumulation w/ sunlight color
	vec3 light_mult = light_scattering_enabled ? _light_color : vec3(1.0);
	vec3 final_color = albedo_color * light_mult;

	// Add foam
	float foam_mask = 0.0;
	if (foam_enabled) {
		float detail_wave = h * 0.005 ;
		float foam_noise = texture(foam_noise_texture, UV * .1 * foam_noise_scale).r;
		foam_mask = clamp(h * 0.5 + (detail_wave * 2.0 + shore_mask * foam_shore_intensity * float(foam_shore_enabled)) * foam_noise * 1.5 - foam_height, 0.0, 1.0);
		float dist_fade = 1. - smoothstep(0., 1., v_vertex_distance / foam_distance);
		foam_mask *= dist_fade;
		final_color = mix(final_color, vec3(0.8), foam_mask);
	}

	// Refraction: Distort screen UVs using the normal (tangent-space projection)
	{
		vec2 refract_offset = NORMAL.xz * refraction_strength;
		// limit refraction at the bottom edge of the screen as normals push away in view direction.
		float y_limit = 1.0 - smoothstep(.0, length(refract_offset) * 4.0, 1.-SCREEN_UV.y);
		refract_offset = mix(refract_offset, vec2(0.), max(shore_mask, y_limit));
		vec2 refract_uv = SCREEN_UV + refract_offset;
		refract_uv = clamp(refract_uv, vec2(0.001, 0.001), vec2(0.999, 0.999));  // slight inset to avoid exact edge artifacts

		// Invert refract if target screenspace pixel is above ocean surface, replaces major artifact with minor one.
		proximity_depth_tex = textureLod(depth_texture, refract_uv, 0.0).r;
		proximity_view_pos = INV_PROJECTION_MATRIX * vec4(refract_uv * 2.0 - 1.0, proximity_depth_tex, 1.0);
		proximity_view_pos.xyz /= proximity_view_pos.w;
		refract_uv = SCREEN_UV + mix(refract_offset * (float(proximity_view_pos.z < VERTEX.z) * 2.0 - 1.0), vec2(0.), max(shore_mask, y_limit));
		refract_uv = clamp(refract_uv, vec2(0.001, 0.001), vec2(0.999, 0.999));  // slight inset to avoid exact edge artifacts

		// Increase alpha with depth as more water means more light absorbed
		depth_fade = clamp(depth_fade + min(abs(VERTEX.z - proximity_view_pos.z) * 0.001 * depth_absorption, 1.0), 0.0, 1.0);

		vec3 background = texture(screen_texture, refract_uv).rgb;
		final_color = mix(background, final_color, depth_fade * depth_fade);
	}

	ALBEDO = final_color;

	if (light_scattering_enabled) {
		// Approximate light scattering
		vec3 ray_dir = normalize(mat3(INV_VIEW_MATRIX) * VIEW);
		// light scattering based on height and sun angle
		vec3 light_factor = height_scattering * max(h, height_threshold)
			* max(pow(dot(_light_direction, -ray_dir), 4.0), height_angle_threshold)
			* _light_color
			* pow(0.5 - 0.5 * dot(_light_direction, world_normal), 3.0);
		// light scattering based on view angle
		light_factor += fersnel_scattering * pow(dot(ray_dir, world_normal), 2.0) * _light_color * albedo_color;
		// direct light scattering
		light_factor += direct_scattering * dot(_light_direction, world_normal) * albedo_color * _light_color;
		// Apply horizon fade to the whole scattering
    	BACKLIGHT = light_factor * 4.0 * clamp(depth_fade, 0.4, 1.0) * max(1.0 - foam_mask, 0.5) * daytime_mask;
	}

}