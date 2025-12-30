shader_type spatial;
render_mode cull_back, depth_draw_always, diffuse_burley, specular_schlick_ggx, skip_vertex_transform;

//////////////////////////////
// Constants
//////////////////////////////
const int ITERATIONS_VERTEX = 3;
const int ITERATIONS_FRAGMENT = 4;

//////////////////////////////
// Uniforms
//////////////////////////////
group_uniforms water;
uniform float time_scale : hint_range(0.0, 16.0) = 3.0;
uniform float height_scale : hint_range(0.0, 16.0) = 3.0;
uniform float ocean_scale : hint_range(0.1, 64.0, 0.1) = 4.0;
uniform float sea_level : hint_range(-50.0, 50.0, 0.1) = 12.0;
uniform vec3 albedo_color : source_color = vec3(.102, .212, .318);
uniform float visible_depth : hint_range(0., 10000., .1) = 256.;
uniform float depth_curve : hint_range(0., 1.) = .2;
uniform float edge_fade_distance : hint_range(0.0, 10.0, 0.01) = 1.;
uniform float refraction_strength : hint_range(0.0, 0.1, 0.001) = 0.07;

group_uniforms light_scattering;
uniform float height_scattering : hint_range(0.0, 15.0) = 4.0;
uniform float height_threshold : hint_range(0.0, 1.0) = 0.1;
uniform float height_angle_threshold : hint_range(0.0, 1.0) = 0.21;
uniform float fersnel_scattering : hint_range(0.0, 70.0) = 15.0;
uniform float direct_scattering : hint_range(0.0, 70.0) = 10.0;
uniform float depth_absorbtion : hint_range(0.0, 10.0) = 1.0;
group_uniforms;

group_uniforms caustics;
uniform bool caustics_enabled = true;
uniform float caustic_depth : hint_range(0., 256., .1) = 64.;
uniform float caustic_intensity : hint_range(0., 32., .1) = 16.;
group_uniforms;

group_uniforms reflections;
uniform float fresnel_scale : hint_range(0., 1.) = .065;
uniform float fresnel_power = 1.;
uniform float specular : hint_range(0., 1.) = .5;
group_uniforms;

// Uniforms set by C++
group_uniforms private_dont_touch;
uniform float _mesh_size = 32.;
uniform float _subdiv = 1.;
uniform float _vertex_spacing = 1.;
uniform float _vertex_density = 1.;
uniform vec3 _target_pos = vec3(0.,0.,0.);
uniform bool _light_scattering_enabled = true;
uniform vec3 _light_direction = vec3(-0.196, 0.980, 0);
uniform vec3 _light_color : source_color = vec3(1.0, 1.0, .735);
group_uniforms;

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;

varying float vertex_distance;

//////////////////////////////
// Ocean Noise
//////////////////////////////

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
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
	uv += noise(uv * 0.5) * 2.;
	vec2 wave = 1.0 - abs(sin(uv));
	// Shapeing
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

void vertex() {
    // Get vertex of flat plane in world coordinates and set world UV
    vec3 vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    float scale = MODEL_MATRIX[0][0];
    float inv_scale = 1.0 / scale;
    float vertex_xz_distance = max(abs(vertex.x - _target_pos.x), abs(vertex.z - _target_pos.z));
    float vertex_lerp = smoothstep(0.0, 1.0, (vertex_xz_distance * inv_scale - _mesh_size - 4.0) / (_mesh_size - 4.0));
    vec2 v_fract = fract(VERTEX.xz * 0.5) * 2.0;
    // For LOD0 morph from a regular grid to an alternating grid to align with LOD1+
    vec2 shift = (scale < _vertex_spacing / _subdiv + 1e-6) ? // LOD0 or not
        // Shift from regular to symmetric
        mix(v_fract, vec2(v_fract.x, -v_fract.y),
            round(fract(round(mod(vertex.z * inv_scale, 4.0)) *
            round(mod(vertex.x * inv_scale, 4.0)) * 0.25))) :
        // symmetric shift
        v_fract * round((fract(vertex.xz * 0.25 * inv_scale) - 0.5) * 4.0);
    vertex.xz -= shift * scale * vertex_lerp;

    UV = (vertex.xz);

    vertex.y = sea_level + ocean_height(UV, ITERATIONS_VERTEX);

    VERTEX = (VIEW_MATRIX * vec4(vertex, 1.0)).xyz;
	vertex_distance = length(vertex - _target_pos);
}

//////////////////////////////
// Fragment
//////////////////////////////

void fragment() {
	float h, u, v;
	// adjust normal domain as screen space distance increases to reduce high frequency values across pixels
	float dv = max(0.25, length(fwidth(VERTEX)));
	h = ocean_height(UV, ITERATIONS_FRAGMENT);
	u = ocean_height(UV + vec2(dv, 0.0), ITERATIONS_FRAGMENT);
	v = ocean_height(UV + vec2(0.0, dv), ITERATIONS_FRAGMENT);
	vec3 world_normal = normalize(vec3(h - u, dv * _vertex_density, h - v));
	NORMAL = mat3(VIEW_MATRIX) * world_normal;
	TANGENT = normalize(cross(NORMAL, VIEW_MATRIX[2].xyz));
	BINORMAL = normalize(cross(NORMAL, TANGENT));

	float fresnel = clamp(fresnel_scale * pow(1.0 + dot(VIEW, NORMAL), fresnel_power), 0., 1.);
	ROUGHNESS = fresnel;
	SPECULAR = specular;

	// Depth fade
	float alpha = 1. - depth_curve + depth_curve * smoothstep(.0, 1., vertex_distance/visible_depth);

	// Edge fade
	float proximity_depth_tex = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec4 proximity_view_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, proximity_depth_tex, 1.0);
	proximity_view_pos.xyz /= proximity_view_pos.w;
	float edge_mask = 1.0 - clamp(1.0 - smoothstep(proximity_view_pos.z + 2. * edge_fade_distance, proximity_view_pos.z, VERTEX.z), 0.0, 1.0);
	alpha = clamp(alpha - edge_mask, 0., 1.);

	// Refraction: Distort screen UVs using the normal (tangent-space projection)
	vec2 refract_offset = NORMAL.xz * refraction_strength;
	// limit refraction at the bottom edge of the screen as normals push away in view direction.
	float y_limit = 1.0 - smoothstep(.0, length(refract_offset) * 4.0, 1.-SCREEN_UV.y);
	refract_offset = mix(refract_offset, vec2(0.), max(edge_mask, y_limit));
	vec2 refract_uv = SCREEN_UV + refract_offset;

	// Invert refract if target screenspace pixel is above ocean surface, replaces major artifact with minor one.
	proximity_depth_tex = textureLod(depth_texture, refract_uv, 0.0).r;
	proximity_view_pos = INV_PROJECTION_MATRIX * vec4(refract_uv * 2.0 - 1.0, proximity_depth_tex, 1.0);
	proximity_view_pos.xyz /= proximity_view_pos.w;
	refract_uv = SCREEN_UV + mix(refract_offset * (float(proximity_view_pos.z < VERTEX.z) * 2.0 - 1.0), vec2(0.), max(edge_mask, y_limit));

	// increase alpha with depth as more water means more light absorbed
	alpha = clamp(alpha+ min(abs(VERTEX.z - proximity_view_pos.z) * 0.001 * depth_absorbtion, 1.0), 0.0, 1.0);

	vec3 background = texture(screen_texture, refract_uv).rgb;
	ALBEDO = mix(background, albedo_color * _light_color, alpha * alpha);
	ALPHA = clamp(1.0 - edge_mask, 0., 1.);

	if (_light_scattering_enabled) {
		// Approximate light scattering
		vec3 ray_dir = normalize(mat3(INV_VIEW_MATRIX) * VIEW);
		// light scattering based on height and sun angle
		vec3 light_factor = height_scattering * max(h, height_threshold) * max(pow(dot(normalize(_light_direction), -ray_dir), 4.0), height_angle_threshold) * _light_color * pow(0.5 - 0.5 * dot(normalize(_light_direction), world_normal), 3.0);
		// light scattering based on view angle
		light_factor += fersnel_scattering *pow(dot(ray_dir, world_normal), 2.0) * _light_color * albedo_color;
		// direct light scattering
		light_factor += direct_scattering * dot(normalize(_light_direction), world_normal) * albedo_color * _light_color;
		BACKLIGHT = light_factor * 4.0 * clamp(alpha, 0.4, 1.0);
	}

	// Caustics
	if (caustics_enabled) {
		float depth = VERTEX.z - proximity_view_pos.z;
		vec2 uv = (INV_VIEW_MATRIX * vec4(proximity_view_pos.xyz, 1.)).xz + depth * _light_direction.xz;
		// fade and blur deep caustics
		float fade = pow(smoothstep(caustic_depth, 0., depth), 4.);
		dv /= fade * fade;
		// get projected ocean normal from underwater surface
		h = ocean_height(uv, ITERATIONS_FRAGMENT);
		u = ocean_height(uv + vec2(dv, 0.0), ITERATIONS_FRAGMENT);
		v = ocean_height(uv + vec2(0.0, dv), ITERATIONS_FRAGMENT);
		// light penetration from surface alignment with light
		vec3 n = normalize(vec3(h - u, dv * _vertex_density, h - v));
		float conv = pow(clamp(abs(dot(normalize(n), normalize(_light_direction))), 0., 1.), fade * 256.0);

		float caustics = clamp(conv, 0., 1.) * (1. - edge_mask) * fade;
		float dist_fade = 1. - smoothstep(0., 1., vertex_distance / visible_depth);

		BACKLIGHT += _light_color * caustics * dist_fade * caustic_intensity;
	}
}