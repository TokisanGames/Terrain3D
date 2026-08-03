// Pasture3D Water — River / flowing channel. Spec §10.
//
// Two things separate this from the lake variant, and they are the same idea at
// two stages of the pipeline: on a river, motion follows the CHANNEL, not a
// world-space heading.
//
//   WATER_FLOW      — the detail layers and the shore foam advect along a
//                     per-vertex direction carried in ARRAY_COLOR instead of the
//                     fixed detail_flow0/1 vectors, so the surface texture runs
//                     with the channel through a bend rather than across it.
//   WATER_STREAM_WAVES — the VERTEX displacement comes from channel coordinates
//                     the mesh carries -- flow travel time (UV2.x), signed
//                     lateral offset and the stationary phase (CUSTOM0) --
//                     rather than from the Gerstner table, so crests run
//                     downstream on every reach, chop varies across the channel,
//                     and rapids stand still over a ford. See
//                     water_stream.gdshaderinc for why the table cannot do any of
//                     it, and what the demo scene had to do about it before.
//
// NOT DROP-ANYWHERE, unlike the other four (G6). It needs five things only a
// Pasture3DStream mesh writes: flow in ARRAY_COLOR.rgb, the shore fraction in
// ARRAY_COLOR.a, travel time in UV2.x, and the three channel coordinates in
// CUSTOM0. On a bare MeshInstance3D the vertex colours read white and UV2 and
// CUSTOM0 read zero, which is a full-speed diagonal with every vertex at the same
// phase -- the whole surface bobbing in unison, with the chop degenerated into
// more of the same and the standing waves gated off. Put it on a stream; the
// guide says so in §2 and §11.
//
// Costs two extra texture() calls in the fragment stage against water_body: the
// cross-fade needs a second copy of each layer. Priced at the Phase 7 gate. The
// water spec's four-fetch budget becomes six for rivers, and this says so rather
// than quietly exceeding it. The vertex stage is still CHEAPER than the lake's:
// five sine octaves against three full Gerstner waves, and no horizontal shear.
shader_type spatial;
render_mode cull_disabled, depth_draw_never, diffuse_lambert, specular_schlick_ggx, skip_vertex_transform;

// Still 3, though nothing evaluates the table now: it sizes the uniform array the
// manager uploads into, and a mismatch there is a silently truncated write rather
// than an error. The table is inert on this variant; ripple_* is the surface.
#define WATER_WAVE_COUNT 3
#define WATER_DETAIL
#define WATER_FLOW
#define WATER_STREAM_WAVES
#define WATER_DEPTH_FADE
#define WATER_FOAM_SHORE

#include "res://addons/pasture_3d/extras/shaders/water/water_common.gdshaderinc"
// water_waves is still included for the WaveSample struct and WATER_TAU, both of
// which water_stream builds on. water_eval_waves() itself goes unreferenced and
// is dead-code-eliminated.
#include "res://addons/pasture_3d/extras/shaders/water/water_waves.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_stream.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_surface.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_shading.gdshaderinc"
