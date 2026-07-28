// Pasture3D Water — Lake / finite body, high tier.
// Runs on ANY MeshInstance3D with no plugin involvement (spec G6). No clipmap
// uniforms are declared, so nothing needs wiring: drop the material on a mesh.
// Height comes from the mesh transform, not sea_level.
shader_type spatial;
render_mode cull_disabled, depth_draw_never, diffuse_lambert, specular_schlick_ggx, skip_vertex_transform;

#define WATER_WAVE_COUNT 4
#define WATER_DETAIL
#define WATER_DEPTH_FADE
#define WATER_FOAM_SHORE
#define WATER_SCATTER

#include "res://addons/pasture_3d/extras/shaders/water/water_common.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_waves.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_surface.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_shading.gdshaderinc"
