shader_type spatial;
render_mode specular_toon;

// Shader adapted from https://docs.godotengine.org/en/4.4/tutorials/shaders/your_first_shader/your_second_3d_shader.html
// Also includes snippets from https://godotshaders.com/snippet/useful-code-snippets/ 

group_uniforms ocean;
uniform float sea_level : hint_range(-50.0, 50.0, 0.1) = 0.0;
uniform float height_scale : hint_range(0.01, 10.0, 0.01) = 0.5;
uniform float uv_scale : hint_range(1.0, 50.0, 1.0) = 1.0;
group_uniforms;

uniform sampler2D screen_tex : hint_screen_texture;

uniform int _cell_amount = 10;
uniform vec2 _period = vec2(5., 10.);

vec2 modulo(vec2 divident, vec2 divisor){
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

void vertex() {
	// Get vertex of flat plane in world coordinates and set world UV
	vec3 vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 uv = (vertex.xz / 2.0 + 0.5) / uv_scale;
	float height = get_height(uv, TIME);
	VERTEX.y = sea_level + (height  * height_scale);
	NORMAL = normalize(vec3(height - get_height(uv + vec2(0.1, 0.0), TIME), 0.1, height - get_height(uv + vec2(0.0, 0.1), TIME)));
}

void fragment() {
	float fresnel = sqrt(1.0 - dot(NORMAL, VIEW));
	vec3 screen_clr = texture(screen_tex, SCREEN_UV).rgb;
	RIM = 0.1;
	ROUGHNESS = 0.01;
	METALLIC = 0.0;
	ALBEDO = screen_clr + (0.1 * fresnel);	
}