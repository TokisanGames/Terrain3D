// Pasture3D Water — River / flowing ribbon. Spec §10.
//
// The lake variant plus WATER_FLOW: the detail layers and the shore foam advect
// along a per-vertex direction carried in ARRAY_COLOR instead of the fixed
// detail_flow0/1 vectors, so the surface runs with the channel through a bend
// rather than sliding across it.
//
// Drop it on any MeshInstance3D like the others (G6). A mesh with no vertex
// colours reads white, which decodes to a flow direction of (1,1) at full speed --
// so this variant is meant for meshes Pasture3DPool built, and a loop pool writes
// the neutral (0.5, 0.5, 0) that decodes to a zero vector and stands still.
//
// Costs two extra texture() calls in the fragment stage against water_body: the
// cross-fade needs a second copy of each layer. Priced at the Phase 7 gate. The
// water spec's four-fetch budget becomes six for rivers, and this says so rather
// than quietly exceeding it.
shader_type spatial;
render_mode cull_disabled, depth_draw_never, diffuse_lambert, specular_schlick_ggx, skip_vertex_transform;

#define WATER_WAVE_COUNT 3
#define WATER_DETAIL
#define WATER_FLOW
#define WATER_DEPTH_FADE
#define WATER_FOAM_SHORE

#include "res://addons/pasture_3d/extras/shaders/water/water_common.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_waves.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_surface.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_shading.gdshaderinc"
