#if !defined(__T3D_MATERIAL_STRUCT_DEF__)
#define __T3D_MATERIAL_STRUCT_DEF__
struct Material {
	vec4 alb_ht;
	vec4 nrm_rg;
	int base;
	int over;
	float blend;
};
#endif