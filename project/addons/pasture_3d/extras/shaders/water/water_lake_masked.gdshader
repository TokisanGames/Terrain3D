// Pasture3D Water — Lake, cut to a shore mask. PROTOTYPE.
//
// water_body.gdshader with WATER_SHORE_MASK on: identical surface and shading,
// but the outline comes from a baked SDF instead of from the mesh. It exists to
// answer one question -- whether a sheet that does not know where the shore is
// can produce a rim as good as the meshed one -- because that is what decides
// whether a large lake can be drawn on a camera-centred clipmap.
//
// The uniforms it adds (_shore_sdf, _shore_rect, _shore_range, _shore_texels,
// _shore_kill_margin) are written by whatever hosts the sheet. Dropped on a bare
// MeshInstance3D with nothing set, the default black SDF decodes to -_shore_range
// everywhere, which is "well inside the water": the mask is inert and this
// behaves as water_body.gdshader does. That is the right failure -- a material
// that hid the whole surface when unwired would read as a broken shader.
shader_type spatial;
render_mode cull_disabled, depth_draw_never, diffuse_lambert, specular_schlick_ggx, skip_vertex_transform;

#define WATER_WAVE_COUNT 4
#define WATER_SHORE_MASK
#define WATER_DETAIL
#define WATER_DEPTH_FADE
#define WATER_FOAM_SHORE
#define WATER_SCATTER

#include "res://addons/pasture_3d/extras/shaders/water/water_common.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_waves.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_surface.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_shading.gdshaderinc"
