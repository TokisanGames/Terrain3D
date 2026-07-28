// Pasture3D Water — Ocean, high tier.
// Pasture3D clipmap geometry, full feature set. Spec §2.1.
shader_type spatial;
render_mode cull_disabled, depth_draw_never, diffuse_lambert, specular_schlick_ggx, skip_vertex_transform;

#define WATER_CLIPMAP
#define WATER_WAVE_COUNT 8
#define WATER_DETAIL
#define WATER_DEPTH_FADE
#define WATER_FOAM_CREST
#define WATER_FOAM_SHORE
#define WATER_SCATTER
// WATER_REFRACTION deliberately off: measured at 16-22% of ocean cost for an
// effect capped at 22.5% opacity (spec §8.1 conclusion 2). Opt in per project.

#include "res://addons/pasture_3d/extras/shaders/water/water_common.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_waves.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_surface.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_shading.gdshaderinc"
