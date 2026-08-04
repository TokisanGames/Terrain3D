// Pasture3D Water Bodies — unlit surface readout for geometry A/B.
//
// water_body.gdshader with WATER_DEBUG_SURFACE turned on, which replaces the whole
// shading path with an EMISSION encoding of the wave normal and height (see
// water_shading.gdshaderinc). Used by the Phase 1 gate's instance-origin criterion.
//
// Unlit is not a convenience here, it is the measurement. Water is near-mirror, so
// image-diffing two SHADED water surfaces turns a normal difference far too small to
// see into a saturated specular pixel, and the metric ends up reporting highlight
// placement rather than geometry. That mistake cost two wrong verdicts in the
// shader work's Phase 2 and the rule not to repeat it is written down in
// PASTURE3D_WATER_SHADER_SPEC.md §8.3.
//
// Four waves, matching M_water_lake, because that is the tier a pool uses.
shader_type spatial;
render_mode cull_disabled, depth_draw_never, diffuse_lambert, specular_schlick_ggx, skip_vertex_transform;

#define WATER_WAVE_COUNT 4
#define WATER_DEBUG_SURFACE

#include "res://addons/pasture_3d/extras/shaders/water/water_common.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_waves.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_surface.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_shading.gdshaderinc"
