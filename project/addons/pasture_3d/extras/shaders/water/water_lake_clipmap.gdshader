// Pasture3D Water — Lake, on a camera-centred clipmap, cut to a shore mask.
//
// water_lake_masked.gdshader plus WATER_CLIPMAP: the same surface, the same shading and the same
// distance-field cut, drawn on Pasture3DMesher's rings instead of a static sheet. That is what
// makes the vertex count a property of the CLIPMAP rather than of the lake, and it is what gives
// wave-spacing detail near the camera on a body far too large to mesh at wave spacing.
//
// The two defines have to compose in this order of effects, and they do:
//
//   WATER_CLIPMAP  geomorphs the vertex across LOD rings and then lifts the sheet to sea_level;
//   WATER_SHORE_MASK reads the vertex AFTER that, so the shore is tested against where the vertex
//                    actually ended up rather than where its ring started it.
//
// sea_level is written by the body that owns the clipmap -- unlike Pasture3DOcean, where it is the
// node's own Y, because the clipmap is world-anchored and a Pasture3DWaterClipmap's transform means
// nothing. _mesh_size, _vertex_spacing, _subdiv and _target_pos are written by the clipmap itself.
shader_type spatial;
render_mode cull_disabled, depth_draw_never, diffuse_lambert, specular_schlick_ggx, skip_vertex_transform;

#define WATER_WAVE_COUNT 4
#define WATER_CLIPMAP
#define WATER_SHORE_MASK
#define WATER_DETAIL
#define WATER_DEPTH_FADE
#define WATER_FOAM_SHORE
#define WATER_SCATTER

#include "res://addons/pasture_3d/extras/shaders/water/water_common.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_waves.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_surface.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_shading.gdshaderinc"
