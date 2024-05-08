// *****************************************************************************
#if !defined(__T3D_INTERNAL_GLOBALS_AVAILABLE__)
// REQUIRED EXTERNAL TYPES:
// "Material" (struct): Provided by
//#include "res://addons/terrain_3d/shader/core/t3d_material_def.gdshaderinc"
// *****************************************************************************
// REQUIRED EXTERNAL FUNCTIONS:
//
// "get_materials"
//Material[4] get_materials( vec2 _uv, vec4 _g, uvec4 _c, ivec4 _n, vec4 _a) { Material _m[4]; return _m; }	//defined within "res://addons/terrain_3d/shader/core/t3d_deliver_mixed_mat_funcs.gdshaderinc"
//
// "P_TINT_NZ_SCL" -> vec3
//vec3 P_TINT_NZ_SCL() { return vec3(0.); } 	// Provides the tint noise scales.  This code uses the Z index for tint noise 3
//
// "blend_weights_x4" -> vec4 : Defined with t3d_standard_functions
//vec4 blend_weights_x4(vec4 _p1, vec4 _p2) { return vec4(0.); }
// *****************************************************************************
// REQUIRED EXTERNAL SAMPLERS:
//uniform sampler2D noise_texture;
// *****************************************************************************
// REQUIRED EXTERNAL LOCAL/INLINE INPUTS:
// "uv" (vec2)
// "RTX_GRAD" (vec4): The world space texture derivatives, xy is dFdX() and zw is dFdY()
// *****************************************************************************
// REQUIRED EXTERNAL VARYINGS:
// "v_control" flat uvec4: The control data for this texel and it's Right/Down and Right+Down neighbors
// "v_neighbors" flat ivec4
// "v_rangles" flat vec4: The random texture angle of this texl and it's neighbors
// *****************************************************************************
//	const vec2 uv 			= vec2(0.);
//	const vec4 RTX_GRAD 	= vec4(0.);
//	
//	const uvec4	v_control 	= uvec4(0);
//	const ivec4	v_neighbors	= ivec4(0);
//	const vec4 	v_rangles 	= vec4(0.);
// *****************************************************************************
#endif

// UV_DISTORT
// UV distortion

const float UVD_BASE_TEX_SCALE = 0.05;
const float TEMP_UVD_DISTORTION_POWER = 0.6;
const float TEMP_UVD_EXP_FALLOFF = 1.0;
const float TWO_SQRT_THREE=3.464;
const float DEG_TO_RAD=3.1415926/180.;
const float __UV_DISTORTION_MULT=43758.5453;
const ivec2 ZERO_iXY=ivec2(0);
const vec2 NEGONE_XY=vec2(-1.);
const vec2 ZERO_XY=vec2(0);
const vec2 ONE_XY=vec2(1.);
const vec2 TWO_XY=vec2(2.);
const vec3 NEGONE_XYZ=vec3(-1.);
const vec3 TWO_XYZ=vec3(2.);
const mat2 __TRIGRID_SKEW_MAT=mat2(vec2(1.,0.),vec2(-0.57735027,1.15470054));
const mat2 __UV_DISTORTION_HASH=mat2(vec2(127.132981,311.792343),vec2(269.5,183.3));

vec2 SINCOS(float _radians_) { return vec2(cos(_radians_),sin(_radians_)); }
vec3 INVNORM(vec3 _p_) { return (1.-abs(_p_)); }
float FUSED(vec3 _o_) { return (_o_.x*_o_.y*_o_.z); } 
vec3 CENTER(vec3 _p_) { return fma(_p_,TWO_XYZ,NEGONE_XYZ); }
float ONE_IF_OVER_ZERO(float _f_) { return clamp(_f_*999999.,0,1); }

// [ ROT0 ] Rotate a point around pivot point 0,0.
vec2 ROT0(vec2 p,float a){vec2 cs,d;cs=SINCOS(a);d=cs.yx*p.y;d.x*=-1.;return d+cs.xy*p.x;}

// [ ROT ] Rotate  a point around an arbitruary pivot point.
vec2 ROT(vec2 p,vec2 piv,float a){vec2 cs,d;p-=piv;cs=SINCOS(a);d=cs.yx*p.y;d.x*=-1.;return piv+d+cs.xy*p.x;}

// [ HASH_XY ] (DEF) World index position to random normal vec2
// _p_ is a vec2 in world space, typically integers, output is a pseudo-random XY offset 
// direction for that position, in the range of 0->1
vec2 HASH_XY(vec2 _p_) { return (abs(fma(fract(sin(_p_*__UV_DISTORTION_HASH)*__UV_DISTORTION_MULT),TWO_XY,NEGONE_XY))); }

// [ SCALE_STANDARD ] Utility to convert phase scale from human readable to algo specific
float SCALE_STANDARD(float _param_scale_) { return TEMP_UVD_DISTORTION_POWER*(1./(_param_scale_/TWO_SQRT_THREE)); }

// [ SCALED_HASH_XY ] Readability shorthand for calling the HASH_XY define and scaling it's results
vec2 SCALED_HASH_XY(ivec2 _p_,float _scale_) { return HASH_XY(vec2(_p_))*SCALE_STANDARD(_scale_); }

// [ TRIGRID: Position and index in a grid of triangles ]
// Given a world space uv, returns the x,y integer position of which triangle
// of an infinite grid of triangles the uv is within, as well as putting the
// (edge_a,cross edge_a) normalized offsets into (weights) w.xy, and their inverse
// total into w.z
ivec2 TRIGRID( vec2 uv, out vec3 w) {
	uv*=__TRIGRID_SKEW_MAT;
	w=vec3(fract(uv),0.);
	w.z=1.0-w.x-w.y;
	vec3 wo=1.-w.zyx;wo.x=-w.z;
	float ofs=ONE_IF_OVER_ZERO(w.z);
	w=wo*(1.-ofs)+w.zyx*ofs;
	return ivec2(floor(uv))+int(ofs);  }

// [ DISTORT_UV: World space to random XY offset ]
// Given a world space UV and a set of paramaters encoded in a vec3,
// returns a vec2 of the distortion offset at that point
// Params vec3: x = output power scale
//              y = tri-grid rotation (radians) 
//              z = tri-grid scale adjust
vec2 DISTORT_UV(vec2 _UV, vec3 _params) {
	vec3 weights;
	vec2 t_UV=SCALED_HASH_XY(TRIGRID((ROT0(_UV*_params.z,_params.y)),weights),1./_params.z);
	return _params.x*t_UV*pow(FUSED(INVNORM(CENTER(weights))),TEMP_UVD_EXP_FALLOFF); }

// [ ABOUT UV DISTORTION SETS ]
// A uv distortion set is an array of vec3 of size __UVD_PASSES_PER_SET
// It is passed as a parameter to RUN_DUV_SET (see below)
//
// Each vec3 corresponds to an additional iteration through a successive
// distortion process conducted in world space. The vec3 controls the
// output power of the iteration, and the rotation and size of the 
// tri-grid the uv is indexed against (for hashing purposes).
//
// The following constant is used by the distortion set definitions and
// run set function.  It's listed out of sequence here for clarity.
const uint __UVD_PASSES_PER_SET = 4U;
// x=power, y=angle(in radians), z=size
const vec3[__UVD_PASSES_PER_SET] _default_uvd_set = { 
	vec3( 0.3, 216.0420 * DEG_TO_RAD, TWO_SQRT_THREE*0.835723 ), 
	vec3( 0.8, 116.0420 * DEG_TO_RAD, TWO_SQRT_THREE*0.182517 ), 
	vec3( 0.7,  37.3231 * DEG_TO_RAD, TWO_SQRT_THREE*0.041083 ), 
	vec3( 1.0,  49.3443 * DEG_TO_RAD, TWO_SQRT_THREE*0.012169 ) };

// [ RUN_DUV_SET : Run a uv distortion set against a given world space UV ]
// Returns a vec2 of the total distortion at world space uv supplied
// Uses an array of vec3 defined above and of required length __UVD_PASSES_PER_SET
// The PowerScale, AngleOffset and SizeScale factors act as global scales / offset
// each pass's vec3 of parameters has applied before being calculated. 
vec2 RUN_DUV_SET(vec2 _origUV, vec3[__UVD_PASSES_PER_SET] _set,
	float PowerScale, float AngleOffset, float SizeScale ) {
	vec3 _pC, _tPS, _tAO;
	vec2 _dUV = _origUV;
	for (int _p=0;_p<_set.length();_p++){
		_pC=_set[_p]; 
		_pC.x *= PowerScale;
		_pC.y += AngleOffset;
		_pC.z *= SizeScale;
		_dUV+= DISTORT_UV(_dUV, _pC); }
	return _origUV-_dUV; }

vec2 UV_DISTORT(vec2 _uv_) { return RUN_DUV_SET(_uv_, _default_uvd_set,25.0 * _uv_distortion_size * _uv_distortion_power,0.0,0.01/max(0.0001, _uv_distortion_size) ); }