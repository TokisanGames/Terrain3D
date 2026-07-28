// Pasture3D Water — Pond / finite body, low tier.
// The cheapest variant: 2 waves, no scattering, no crest foam, no shadow
// receive. At pond scale nothing in the high tier is visible, so it should not
// be compiled at all -- that is the point of static variants (spec §6).
shader_type spatial;
render_mode cull_disabled, depth_draw_never, diffuse_lambert, specular_schlick_ggx, skip_vertex_transform,
	shadows_disabled;

#define WATER_WAVE_COUNT 2
#define WATER_DETAIL
// One detail layer (§8.4). At pond scale the surface is small enough that the tile
// repeat is hidden by the shore, so the second layer buys the least here.
#define WATER_DETAIL_LAYERS 1
#define WATER_DEPTH_FADE
#define WATER_FOAM_SHORE

#include "res://addons/pasture_3d/extras/shaders/water/water_common.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_waves.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_surface.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_shading.gdshaderinc"
