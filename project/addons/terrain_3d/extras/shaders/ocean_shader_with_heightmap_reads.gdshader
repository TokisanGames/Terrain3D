shader_type spatial;
render_mode specular_toon, cull_disabled, depth_draw_always, skip_vertex_transform;

// Shader adapted from https://docs.godotengine.org/en/4.4/tutorials/shaders/your_first_shader/your_second_3d_shader.html
// Also includes snippets from https://godotshaders.com/snippet/useful-code-snippets/

// Defined Constants
#define SKIP_PASS 0
#define VERTEX_PASS 1
#define FRAGMENT_PASS 2

group_uniforms ocean;
uniform float sea_level : hint_range(-50.0, 50.0, 0.1) = 0.0;
uniform vec3 albedo_color : source_color = vec3(.143, .255,  .34);
uniform float visible_depth : hint_range(0., 10000., .1) = 200.; 
uniform float height_scale : hint_range(0.01, 10.0, 0.01) = 0.5;
uniform float uv_scale : hint_range(1.0, 50.0, 1.0) = 8.0;
uniform float fresnel_scale : hint_range(0., 1.) = .2;
uniform float fresnel_power = 2.;
uniform int _cell_amount = 10;
uniform vec2 _period = vec2(5., 10.);
group_uniforms;

uniform sampler2D screen_tex : hint_screen_texture;

// Uniforms set by C++
uniform float _mesh_size = 48.;
uniform float _subdiv = 1.;
uniform float _vertex_spacing = 1.;
uniform float _vertex_density = 1.;
uniform vec3 _target_pos = vec3(0.,0.,0.); // should be derived from clipmap target position
uniform highp sampler2DArray _height_maps : repeat_disable;
uniform float _region_size = 1.;
uniform float _region_texel_size = 0.0009765625; // = 1./region_size
uniform int _region_map_size = 32;
uniform int _region_map[1024];
uniform float _terrain_vertex_spacing = 1.0f;

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
    uv = uv * float(_cell_amount);
    vec2 cellsMinimum = floor(uv);
    vec2 cellsMaximum = ceil(uv);
    vec2 uv_fract = fract(uv);

    cellsMinimum = modulo(cellsMinimum, _period);
    cellsMaximum = modulo(cellsMaximum, _period);

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

// Takes in world space XZ (UV) coordinates & search depth (only applicable for background mode none)
// Returns ivec3 with:
// XY: (0 to _region_size - 1) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
ivec3 get_index_coord(const vec2 uv, const int search) {
	vec2 r_uv = round(uv);
	vec2 o_uv = mod(r_uv, _region_size);
	ivec2 pos;
	int bounds, layer_index = -1;
	for (int i = -1; i < clamp(search, SKIP_PASS, FRAGMENT_PASS); i++) {
		if (i < 0) {
			r_uv -= i == -1 ? vec2(0.0) : vec2(float(o_uv.x <= o_uv.y), float(o_uv.y <= o_uv.x));
			pos = ivec2(floor((r_uv) * _region_texel_size)) + (_region_map_size / 2);
			bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
			layer_index = (_region_map[ pos.y * _region_map_size + pos.x ] * bounds - 1);
		}
	}
	return ivec3(ivec2(mod(r_uv, _region_size)), layer_index);
}

float interpolated_height(vec2 pos) {
	const vec2 offsets = vec2(0, 1);
	vec2 index_id = floor(pos);
	ivec3 index[4];
	index[0] = get_index_coord(index_id + offsets.xy, VERTEX_PASS);
	index[1] = get_index_coord(index_id + offsets.yy, VERTEX_PASS);
	index[2] = get_index_coord(index_id + offsets.yx, VERTEX_PASS);
	index[3] = get_index_coord(index_id + offsets.xx, VERTEX_PASS);
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

float get_terrain_height(float p_scale, float p_vertex_lerp, vec2 p_start_pos, vec2 p_end_pos, float p_v_vertex_xz_dist){
	// Set final vertex height.
		float h;
		// This branch is static for each of the clipmap segments
		// Interpolated reads only occur where sub-texel values are required.
		if (p_scale < _terrain_vertex_spacing) {
			h = mix(interpolated_height(p_start_pos), interpolated_height(p_end_pos), p_vertex_lerp);
		} else {
			ivec3 coord_a = get_index_coord(p_start_pos, VERTEX_PASS);
			ivec3 coord_b = get_index_coord(p_end_pos, VERTEX_PASS);
			h = mix(texelFetch(_height_maps, coord_a, 0).r, texelFetch(_height_maps, coord_b, 0).r, p_vertex_lerp);
		}
	return h;
}

void vertex() {
    // Get vertex of flat plane in world coordinates and set world UV
    vec3 vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

    float scale = MODEL_MATRIX[0][0];
    float inv_scale = 1.0 / scale;
    vertex_distance = max(abs(vertex.x - _target_pos.x), abs(vertex.z - _target_pos.z));
    float vertex_lerp = smoothstep(0.0, 1.0, (vertex_distance * inv_scale - _mesh_size - 4.0) / (_mesh_size - 4.0));
    vec2 v_fract = fract(VERTEX.xz * 0.5) * 2.0;
    // For LOD0 morph from a regular grid to an alternating grid to align with LOD1+
    vec2 shift = (scale < _vertex_spacing / _subdiv + 1e-6) ? // LOD0 or not
        // Shift from regular to symmetric
        mix(v_fract, vec2(v_fract.x, -v_fract.y),
            round(fract(round(mod(vertex.z * inv_scale, 4.0)) *
            round(mod(vertex.x * inv_scale, 4.0)) * 0.25))) :
        // symmetric shift
        v_fract * round((fract(vertex.xz * 0.25 * inv_scale) - 0.5) * 4.0);
	vec2 start_pos = vertex.xz * (1.0f / _terrain_vertex_spacing);
	vec2 end_pos = (vertex.xz - shift * scale) * (1.0f / _terrain_vertex_spacing);
    vertex.xz -= shift * scale * vertex_lerp;


    UV = (vertex.xz) / uv_scale;

    vertex.y = sea_level + get_height(UV, TIME * 0.5) * height_scale;

	if(vertex.y + 5.0 < get_terrain_height(scale, vertex_lerp, start_pos, end_pos, vertex_distance)){
		vertex.x = 0. / 0.;
	}
    VERTEX = (VIEW_MATRIX * vec4(vertex, 1.0)).xyz;
}

void fragment() {
	// not sure about these normals.
	float h, u, v;
	h = get_height(UV, TIME * 0.5) * height_scale;
	u = get_height(UV + vec2(0., .01), TIME * 0.5) * height_scale;
	v = get_height(UV + vec2(.01, 0.), TIME * 0.5) * height_scale;
	NORMAL = mat3(VIEW_MATRIX) * normalize(vec3(h - u, 0.1 * height_scale, h - u));
	TANGENT = normalize(cross(NORMAL, VIEW_MATRIX[2].xyz));
	BINORMAL = normalize(cross(NORMAL, TANGENT));

	float opacity = clamp(visible_depth/vertex_distance, .0001, 1.);
	vec3 screen_clr = texture(screen_tex, SCREEN_UV).rgb;
	ALBEDO = albedo_color * screen_clr * opacity;

    float fresnel = clamp(fresnel_scale * pow(1.0 + dot(VIEW, NORMAL), fresnel_power), 0., 1.);
    ROUGHNESS = fresnel;
	SPECULAR = 1.;
}