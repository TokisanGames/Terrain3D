shader_type spatial;
render_mode world_vertex_coords, cull_disabled;

uniform sampler2D screen : hint_screen_texture, filter_linear_mipmap_anisotropic, repeat_disable;

group_uniforms controls;
uniform float sea_level = 0.0;

group_uniforms colours;
uniform vec3 surfacecolour : source_color;
uniform vec3 volumecolour : source_color;

group_uniforms material;
uniform float AirIOR = 1.0;
uniform float IOR = 1.33;

group_uniforms textures;
uniform vec2 sampler1speed = vec2(0.02, 0.0);
uniform vec2 sampler2speed = vec2(0.0, 0.02);
uniform float samplermix : hint_range(0.0, 1.0, 0.1) = 0.5;
uniform vec2 samplerscale = vec2(0.1);
uniform sampler2D normal1tex : filter_linear_mipmap_anisotropic, hint_normal;
uniform sampler2D normal2tex : filter_linear_mipmap_anisotropic, hint_normal;
uniform float normalstrength : hint_range(0.0, 5.0, 0.01) = 1.0;
uniform sampler2D height1tex : filter_linear_mipmap_anisotropic;
uniform sampler2D height2tex : filter_linear_mipmap_anisotropic;
uniform float heightstrength : hint_range(0.0, 5.0, 0.01) = 0.12;
uniform sampler2D edge1tex : filter_linear_mipmap_anisotropic;
uniform sampler2D edge2tex : filter_linear_mipmap_anisotropic;

varying vec2 position;
varying vec3 wposition;

group_uniforms refraction;

uniform float refrationamount : hint_range(0.0, 1.0, 0.01);
uniform bool fog_underwater;

group_uniforms edge;

uniform float edge_size : hint_range(0.01, 0.5, 0.01) = 0.1;
uniform bool foam_or_fade = false;

uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear_mipmap, repeat_disable;

group_uniforms screen_space_reflection;

uniform float far_clip = 50.0;
uniform int steps : hint_range(64, 1024, 16) = 512;
uniform float ssr_screen_fade : hint_range(0.01, 0.5, 0.01) = 0.05;

float schlickfresnel(float ior1, float ior2, vec3 view, vec3 norm) {
	float incident = dot(view, norm);
	float reflectance = pow(((ior2 - ior1)/(ior2 + ior1)), 2.0);
	float fresnelincident = reflectance + (1.0 - reflectance) * pow(1.0 - cos(incident), 5.0);
	return(fresnelincident / incident);
}

void vertex() {
	position = VERTEX.xz;
	UV = VERTEX.xz * samplerscale + (sampler1speed * TIME);
	UV2 = VERTEX.xz * samplerscale + (sampler2speed * TIME);
	float height = sea_level + mix(texture(height1tex, UV),texture(height2tex, UV2),samplermix).x;
	VERTEX.y += (height - 0.5) * heightstrength;
	wposition = VERTEX;
	// Called for every vertex the material is visible on.
}

float snells_window(vec3 normal, vec3 view, float ior) {
	float cos_theta = dot(normal, view);
	return step(sqrt(1.0 - cos_theta * cos_theta) * ior, 1.0);
}

float linear_depth(float nonlinear_depth, mat4 inv_projection_matrix) {
	return 1.0 / (nonlinear_depth * inv_projection_matrix[2].w + inv_projection_matrix[3].w);
}

float nonlinear_depth(float linear_depth, mat4 inv_projection_matrix) {
	return (1.0 / linear_depth - inv_projection_matrix[3].w) / inv_projection_matrix[2].w;
}

vec2 view2uv(vec3 position_view_space, mat4 proj_m)
{
	vec4 position_clip_space = proj_m * vec4(position_view_space.xyz, 1.0);
	vec2 position_ndc = position_clip_space.xy / position_clip_space.w;
	return position_ndc.xy * 0.5 + 0.5;
}

float remap(float x, float min1, float max1, float min2, float max2) {
	return ((x - min1) / (max1 - min1) + min2) * (max2 - min2);
}
float remap1(float x, float min1, float max1) {
	return (x - min1) / (max1 - min1);
}

float edge_fade(vec2 uv, float size) {
	float x1 = clamp(remap1(uv.x, 0.0, size), 0.0, 1.0);
	float x2 = clamp(remap1(uv.x, 1.0, 1.0 - size), 0.0, 1.0);
	float y1 = clamp(remap1(uv.y, 0.0, size), 0.0, 1.0);
	float y2 = clamp(remap1(uv.y, 1.0, 1.0 - size), 0.0, 1.0);
	return x1*x2*y1*y2;
}

void fragment() {

	vec3 onorm = NORMAL;

	vec2 normmap = mix(texture(normal1tex, UV),texture(normal2tex, UV2),samplermix).xy;
	NORMAL += TANGENT * (normmap.x - 0.5) * normalstrength;
	NORMAL += BINORMAL * (normmap.y - 0.5) * normalstrength;

	vec3 wnorm = (vec4(NORMAL, 0.0) * VIEW_MATRIX).xyz;
	vec3 wview = (vec4(VIEW, 0.0) * VIEW_MATRIX).xyz;
	if (FRONT_FACING) {

		ROUGHNESS = 0.0;
		METALLIC = 1.0;
		SPECULAR = 0.0;

		float fres = schlickfresnel(AirIOR, IOR, VIEW, NORMAL);
		ALBEDO = surfacecolour * fres;
		
		// REFRACTION
		
		float lineardepth = linear_depth(texture(DEPTH_TEXTURE, SCREEN_UV).r, INV_PROJECTION_MATRIX);
		float selfdepth = -VERTEX.z;
		float depth_diff = lineardepth - selfdepth;
		vec3 tanx = BINORMAL * (normmap.x - 0.5) * normalstrength;
		vec3 tany = TANGENT * (normmap.y - 0.5) * normalstrength;
		vec2 refracted_uv = SCREEN_UV + (tanx + tany).xy * refrationamount * depth_diff / lineardepth;
		float newdepth = linear_depth(texture(DEPTH_TEXTURE, refracted_uv).r, INV_PROJECTION_MATRIX);
		//float selfdepth = 1.0/(1.0 + 2.0 * distance(wposition, CAMERA_POSITION_WORLD));
		vec3 newvolcolour = mix(volumecolour, vec3(1.0), clamp(1.0 / (depth_diff * 1.0), 0.0, 1.0));
		EMISSION = newvolcolour * texture(screen, refracted_uv).rgb;

		if (newdepth < selfdepth) {
			EMISSION = newvolcolour * texture(screen, SCREEN_UV).rgb;
		}
		
		// SSR
		
		vec3 reflected = -reflect(VIEW, NORMAL);
		vec3 pos = VERTEX;
		int curstep = 0;
		bool finished = false;
		vec2 uv;
		float currentdepth;
		while (curstep < steps) {
			float step_scale = float(curstep + 1) / float(steps);
			float step_dist = step_scale * step_scale * far_clip;
			pos += reflected * step_dist;
			curstep += 1;
			currentdepth = -pos.z;
			uv = view2uv(pos, PROJECTION_MATRIX);
			if (!(uv.x < 1.0 && uv.y < 1.0 && uv.x > 0.0 && uv.y > 0.0)) {
				break;
			}
			float testdepth = linear_depth(texture(DEPTH_TEXTURE, uv).r, INV_PROJECTION_MATRIX);
			if (testdepth < currentdepth) {
				finished = true;
				break;
			}
		}
		if (finished && currentdepth < far_clip * 0.99) {
			ALBEDO *= 1.0 - edge_fade(uv, ssr_screen_fade);
			METALLIC *= 1.0 - edge_fade(uv, ssr_screen_fade);
			EMISSION += texture(screen, uv).xyz * schlickfresnel(1.0, 1.33, VIEW, NORMAL) * edge_fade(uv, ssr_screen_fade);
		}
		
		// EDGE EFFECT
		
		float distfromedge = depth_diff * dot(normalize(NORMAL), normalize(-VERTEX)) / VIEW.z;
		if (distfromedge < edge_size) {
			distfromedge /= edge_size;
			if (foam_or_fade) {
				ALPHA = distfromedge;
			} else {
				float edgetex = mix(texture(edge1tex, UV).r, texture(edge2tex, UV2).r, samplermix);
				if (edgetex > distfromedge) {
					ALBEDO = vec3(1.0);
					ROUGHNESS = 1.0;
					METALLIC = 1.0;
					EMISSION = vec3(0.0);
					NORMAL = onorm;
				}
			}
		}

	} else {
		
		// SNELLS WINDOW
		float window = snells_window(wnorm, wview, IOR);

		if (window > 0.5) {
			ROUGHNESS = 1.0;
			METALLIC = 1.0;
			ALBEDO = vec3(0.0);
			SPECULAR = 0.0;
			float linear_depth = 1.0 / (texture(DEPTH_TEXTURE, SCREEN_UV).r * INV_PROJECTION_MATRIX[2].w + INV_PROJECTION_MATRIX[3].w);
			float selfdepth = 1.0 / (FRAGCOORD.z * INV_PROJECTION_MATRIX[2].w + INV_PROJECTION_MATRIX[3].w);
			float depth_diff = linear_depth - selfdepth;
			vec3 tanx = BINORMAL * (normmap.x - 0.5) * normalstrength;
			vec3 tany = TANGENT * (normmap.y - 0.5) * normalstrength;
			float newdepth = 1.0 / (texture(DEPTH_TEXTURE, SCREEN_UV + (tanx + tany).xy * refrationamount).r * INV_PROJECTION_MATRIX[2].w + INV_PROJECTION_MATRIX[3].w);
			//float selfdepth = 1.0/(1.0 + 2.0 * distance(wposition, CAMERA_POSITION_WORLD));
			vec3 newvolcolour = mix(volumecolour, vec3(1.0), clamp(1.0 / (selfdepth * 1.0), 0.0, 1.0));
			if (!fog_underwater) {
				newvolcolour = vec3(1.0);
			}
			EMISSION = newvolcolour * texture(screen, SCREEN_UV + (tanx + tany).xy * refrationamount).rgb;
		} else {
			ALBEDO = surfacecolour;
			ROUGHNESS = 0.0;
			METALLIC = 1.0;
			
			// SSR
			
			vec3 reflected = -reflect(VIEW, NORMAL);
			vec3 pos = VERTEX;
			int curstep = 0;
			bool finished = false;
			vec2 uv;
			float currentdepth;
			while (curstep < steps) {
				float step_scale = float(curstep + 1) / float(steps);
				float step_dist = step_scale * step_scale * far_clip;
				pos += reflected * step_dist;
				curstep += 1;
				currentdepth = -pos.z;
				uv = view2uv(pos, PROJECTION_MATRIX);
				if (!(uv.x < 1.0 && uv.y < 1.0 && uv.x > 0.0 && uv.y > 0.0)) {
					break;
				}
				float testdepth = linear_depth(texture(DEPTH_TEXTURE, uv).r, INV_PROJECTION_MATRIX);
				if (testdepth < currentdepth) {
					finished = true;
					break;
				}
			}
			if (finished && currentdepth < far_clip * 0.99) {
				ALBEDO *= 1.0 - edge_fade(uv, ssr_screen_fade);
				METALLIC *= 1.0 - edge_fade(uv, ssr_screen_fade);
				EMISSION += texture(screen, uv).xyz * schlickfresnel(1.0, 1.33, VIEW, NORMAL) * edge_fade(uv, ssr_screen_fade);
			}
		}

	}
}