// Pasture3D Water — Ocean, low tier.
// Clipmap geometry, reduced feature set: no scattering, no crest foam, no
// shadow receive. Spec §2.1.
shader_type spatial;
render_mode cull_disabled, depth_draw_never, diffuse_lambert, specular_schlick_ggx, skip_vertex_transform,
	shadows_disabled;

#define WATER_CLIPMAP
#define WATER_WAVE_COUNT 4
#define WATER_DETAIL
// One detail layer, not two. Phase 3 priced the second at 0.041 ms of the 0.259 ms
// high tier (§8.4) -- 16% of the whole shader for breaking up a 10 m tile, which
// is the first thing to go when the frame budget is a Steam Deck's.
#define WATER_DETAIL_LAYERS 1
#define WATER_DEPTH_FADE
#define WATER_FOAM_SHORE

#include "res://addons/pasture_3d/extras/shaders/water/water_common.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_waves.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_surface.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_shading.gdshaderinc"
