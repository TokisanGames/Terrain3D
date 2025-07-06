// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

R"(

//INSERT: DISPLACEMENT_FUNCTIONS
#define DISPLACEMENT
group_uniforms displacement;
uniform float displacement_scale : hint_range(0.0, 2.0, 0.01) = 1.0;
group_uniforms;
uniform highp sampler2D _displacement_buffer : repeat_disable, filter_linear;

vec3 get_displacement(vec2 pos, float scale) {
	float s = floor(log2(1.0 / (scale * _vertex_density)));
	scale = pow(2.0, s) * 0.5;
	vec2 d_uv = (pos - round(_target_pos.xz * _vertex_density * scale) / scale) / (_mesh_size * 2.0 / scale) + 0.5;
	d_uv.x += s - 1.;
	d_uv.x /= log2(_subdiv);
	highp vec3 nrm_h = vec3(0.);
	if (all(greaterThanEqual(d_uv, vec2(0.0))) && all(lessThanEqual(d_uv, vec2(1.0)))) {
		nrm_h = textureLod(_displacement_buffer, d_uv, 0.).rgb;
		float height = nrm_h.z - 0.5;
		nrm_h.xy = fma(nrm_h.xy, vec2(2.0), vec2(-1.0));
		nrm_h.z = sqrt(clamp(1.0 - dot(nrm_h.xy, nrm_h.xy), 0.0, 1.0));
		nrm_h = nrm_h.xzy * height * displacement_scale;
	}
	return nrm_h;
}

//INSERT: DISPLACEMENT_VERTEX
		if (!(CAMERA_VISIBLE_LAYERS == _mouse_layer)) {
			displacement = mix(get_displacement(start_pos, scale), get_displacement(end_pos, scale * 2.0), vertex_lerp);
		}

)"
