shader_type spatial;

render_mode cull_disabled, diffuse_burley;

uniform sampler2D noise : source_color;
uniform sampler2D normal_map : source_color;
uniform float noise_scale = 10.0;

float height(vec2 uv) {
	return texture(noise, uv).r;
}

void vertex() {
	float k = height(UV) * noise_scale;
	VERTEX.y += k ;
	NORMAL = texture(normal_map, UV).xyz;
}

void fragment() {
	ALBEDO = vec3(1.0, 1.0, 1.0);
	ROUGHNESS = 0.0;
	SPECULAR = 0.0;
	METALLIC = 0.0;
}


