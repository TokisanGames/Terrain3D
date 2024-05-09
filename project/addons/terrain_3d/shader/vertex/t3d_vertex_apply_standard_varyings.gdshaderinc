// --------------------------------------------------------------------------------------
// * Placeholder function / variable defs to appease syntax highlighter in Godot:
// --------------------------------------------------------------------------------------
#if !defined(__T3D_INTERNAL_GLOBALS_AVAILABLE__)
// * External samplers:
uniform usampler2DArray _control_maps	: repeat_disable;
// * External calls:
ivec3 get_region_uv( vec2 _param ) {return ivec3(0);}
float random(ivec2 _param) {return 0.;}
//
void placeholder_func_APPLY_STANDARD_VARYINGS() {
// * Godot supplied externals:
const mat4 INV_VIEW_MATRIX = mat4(vec4(0.),vec4(0.),vec4(0.),vec4(0.));
const mat4 MODEL_MATRIX = mat4(vec4(0.),vec4(0.),vec4(0.),vec4(0.));
// In this code portion, VERTEX should not be written to yet, so it's constant here.
const vec3 VERTEX = vec3(0.);

// * External parameters:
const float _mesh_vertex_density = 1.;
const float _region_size = 1.;
const float _region_texel_size = 1.;
const uint _CONTROL = 0u;

// * Local changes to:
float	v_height;
vec2	UV, v_uvdistort;
ivec3	v_region;
vec3	v_camera_pos, v_vertex, v_norm_region, v_noise, v_normal;
uvec4	v_control;
ivec4	v_neighbors;
vec4	v_rangles;
#endif
// --------------------------------------------------------------------------------------
// *** BEGIN: APPLY_STANDARD_VARYINGS 
// --------------------------------------------------------------------------------------
	v_height = VERTEX.y;
	v_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Get the region and control map ID for the vertices
	ivec3 i00, i01, i10, i11; ivec2 iUV=ivec2(UV); 
	i00=get_region_uv(UV);
	i01=get_region_uv(vec2(iUV+ivec2(0,1)));
	i10=get_region_uv(vec2(iUV+ivec2(1,0)));
	i11=get_region_uv(vec2(iUV+ivec2(1,1)));

	// Lookup adjacent vertices. 3 lookups
	//uint4 con = textureGather(_control_maps, v_region, 0);
	v_control = uvec4(
		_CONTROL,
		texelFetch(_control_maps,i01,0).r,
		texelFetch(_control_maps,i10,0).r,
		texelFetch(_control_maps,i11,0).r);

	v_neighbors=ivec4(i00.z,i01.z,i10.z,i11.z);
	v_rangles=TAU * (vec4(random(i00.xy), random(i01.xy), random(i10.xy), random(i11.xy))-0.5);

	#ifdef MULTI_SCALING_ENABLED
		v_far_factor = clamp(smoothstep(_multi_scaling_near, _multi_scaling_far, length(v_vertex - v_camera_pos)), 0.0, 1.0);
	#endif
// --------------------------------------------------------------------------------------
// *** END: APPLY_STANDARD_VARYINGS 
// --------------------------------------------------------------------------------------
#if !defined(__T3D_INTERNAL_GLOBALS_AVAILABLE__)
}
#endif