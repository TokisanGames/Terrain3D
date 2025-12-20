shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx, skip_vertex_transform;

// Shader adapted from https://docs.godotengine.org/en/4.4/tutorials/shaders/your_first_shader/your_second_3d_shader.html
// Also includes snippets from https://godotshaders.com/snippet/useful-code-snippets/

group_uniforms water;
uniform float sea_level : hint_range(-50.0, 50.0, 0.1) = 0.0;
uniform vec3 albedo_color : source_color = vec3(.088, .157, .21);
uniform float visible_depth : hint_range(0., 10000., .1) = 256.;
uniform float depth_curve : hint_range(0., 1.) = .2;
uniform float edge_fade_distance : hint_range(0.0, 10.0, 0.01) = 3.;
uniform float refraction_strength : hint_range(0.0, 0.1, 0.001) = 0.02;
group_uniforms;
group_uniforms reflections;
uniform float fresnel_scale : hint_range(0., 1.) = .065;
uniform float fresnel_power = 1.;
uniform float specular : hint_range(0., 1.) = .5;
group_uniforms;
group_uniforms waves;
uniform float height_scale : hint_range(0.01, 128.0, 0.01) = 12;
uniform float uv_scale : hint_range(1.0, 256.0, 1.0) = 50.0;
uniform int cell_amount = 10;
uniform vec2 period = vec2(5., 10.);
group_uniforms;

// Uniforms set by C++
group_uniforms private_dont_touch;
uniform float _mesh_size = 32.;
uniform float _subdiv = 1.;
uniform float _vertex_spacing = 1.;
uniform float _vertex_density = 1.;
uniform vec3 _target_pos = vec3(0.,0.,0.);
group_uniforms;

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;

varying float vertex_distance;

vec2 modulo(vec2 divident, vec2 divisor) {
    vec2 positiveDivident = mod(divident, divisor) + divisor;
    return mod(positiveDivident, divisor);
}

vec2 random(vec2 value){
    value = vec2( dot(value, vec2(127.1,311.7) ),
                  dot(value, vec2(269.5,183.3) ) );
    return -1.0 + 2.0 * fract(sin(value) * 43758.5453123);
}

float seamless_noise(vec2 uv) {
    uv = uv * float(cell_amount);
    vec2 cellsMinimum = floor(uv);
    vec2 cellsMaximum = ceil(uv);
    vec2 uv_fract = fract(uv);

    cellsMinimum = modulo(cellsMinimum, period);
    cellsMaximum = modulo(cellsMaximum, period);

    vec2 blur = smoothstep(0.0, 1.0, uv_fract);

    vec2 lowerLeftDirection = random(vec2(cellsMinimum.x, cellsMinimum.y));
    vec2 lowerRightDirection = random(vec2(cellsMaximum.x, cellsMinimum.y));
    vec2 upperLeftDirection = random(vec2(cellsMinimum.x, cellsMaximum.y));
    vec2 upperRightDirection = random(vec2(cellsMaximum.x, cellsMaximum.y));

    vec2 fraction = fract(uv);

    return mix( mix( dot( lowerLeftDirection, fraction - vec2(0, 0) ),
                     dot( lowerRightDirection, fraction - vec2(1, 0) ), blur.x),
                mix( dot( upperLeftDirection, fraction - vec2(0, 1) ),
                     dot( upperRightDirection, fraction - vec2(1, 1) ), blur.x), blur.y) * 0.8 + 0.5;
}

float fbm(vec2 uv) {
    int octaves = 6;
    float amplitude = 5.0;
    float frequency = 2.0;
    float value = 0.0;

    for(int i = 0; i < octaves; i++) {
        value += amplitude * seamless_noise(frequency * uv);
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    return value;
}

float wave(vec2 position){
  position += fbm(position * 0.01) * 2.0 - 1.0;
  vec2 wv = 1.0 - abs(sin(position));
  return pow(1.0 - pow(wv.x * wv.y, 0.65), 4.0);
}

float get_height(vec2 position, float time) {
  float d = wave((position + time) * 0.4) * 0.3;
  d += wave((position - time) * 0.3) * 0.3;
  d += wave((position + time) * 0.5) * 0.2;
  d += wave((position - time) * 0.6) * 0.2;
  return d;
}

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

    UV = (vertex.xz) / uv_scale;

    float h;
    h = sea_level + get_height(UV, TIME * 0.5) * height_scale;
    vertex.y = h;

    VERTEX = (VIEW_MATRIX * vec4(vertex, 1.0)).xyz;
	vertex_distance = length(vertex - _target_pos);
}

void fragment() {
	float h, u, v;
	h = get_height(UV, TIME * 0.5) * height_scale;
	u = get_height(UV + vec2(.01, 0.), TIME * 0.5) * height_scale;
	v = get_height(UV + vec2(0., .01), TIME * 0.5) * height_scale;
	NORMAL = mat3(VIEW_MATRIX) * normalize(vec3(h - u, vertex_distance/1024., h - v));
	TANGENT = normalize(cross(NORMAL, VIEW_MATRIX[2].xyz));
	BINORMAL = normalize(cross(NORMAL, TANGENT));

    float fresnel = clamp(fresnel_scale * pow(1.0 + dot(VIEW, NORMAL), fresnel_power), 0., 1.);
    ROUGHNESS = fresnel;
	SPECULAR = specular;

	// Refraction: Distort screen UVs using the normal (tangent-space projection)
    vec2 refract_offset = NORMAL.xz * refraction_strength;
    vec2 refract_uv = SCREEN_UV + refract_offset;
    vec3 background = texture(screen_texture, refract_uv).rgb;

	ALPHA = 1. - depth_curve + depth_curve * smoothstep(.0, 1., vertex_distance/visible_depth);
    ALBEDO = mix(background, albedo_color, ALPHA);

	// Fade Edge
	float proximity_depth_tex = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec4 proximity_view_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, proximity_depth_tex, 1.0);
	proximity_view_pos.xyz /= proximity_view_pos.w;
	float edge_mask = 1.0 - clamp(1.0 - smoothstep(proximity_view_pos.z + 2. * edge_fade_distance, proximity_view_pos.z, VERTEX.z), 0.0, 1.0);
	ALPHA = clamp(ALPHA - edge_mask, 0., 1.);
}