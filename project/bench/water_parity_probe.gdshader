// Pasture3D Water — G4 parity probe (spec §4.3, gate B of the Phase 4 gate).
//
// Evaluates the REAL water_eval_waves() -- the same include the shipped ocean
// wrapper uses, at the same WATER_WAVE_COUNT, with the default-table path left in
// so uploading a table has to suppress it the same way it does in the ocean --
// and reports, per probe, whether the GPU's answer matches the CPU's.
//
// It reports agreement as ZEROES AND ONES rather than as a difference, and that
// is the whole design. The readback path is an 8-bit render target: a magnitude
// encoded into it comes back through quantisation and whatever the compositor
// does to it, and a millimetre would not survive. A threshold comparison decided
// on the GPU in float and written as 0.0 or 1.0 survives anything.
//
//   R = |dy|  > 1 cm   -- G4's budget. Any lit pixel here is a gate failure.
//   G = |dy|  > 1 mm   -- one decade in, reported for headroom.
//   B = |dxz| > 1 cm   -- horizontal agreement. Gerstner displaces sideways too,
//                         and a CPU that got only the height right would still
//                         be describing a different surface.
//
// Cells run left to right along X, cell_px wide, one per probe. Pixels past
// probe_count render black, which is also what a passing probe renders -- so the
// gate must not read "all black" as a pass on its own. It doesn't: the caller
// runs a deliberately wrong CPU array as a control and requires R to light.
//
// Cell index probe_count is the clock cell, and reports the water_time the SHADER
// sees against the _water_time the CPU query used:
//
//   R = the two are more than 1e-5 s apart
//   G = the two are more than 1e-7 s apart (float rounding, reported for headroom)
//   B = the shader's clock is exactly zero, i.e. it never started
//
// This is here rather than in GDScript because there is no way to read a global
// shader parameter back at runtime -- global_shader_parameter_get() is editor-only
// and returns nil in a game -- and asking the shader is the better question
// anyway: what the global table holds is not evidence about what the draw got.
shader_type canvas_item;
render_mode unshaded;

#define WATER_WAVE_COUNT 8
// canvas_item cannot declare instance uniforms, and _water_domain_origin became one
// in Phase 1 of the water-bodies work. Opt back to a plain uniform; this probe sets
// it with material.set_shader_parameter() like everything else it drives.
#define WATER_PLAIN_DOMAIN_ORIGIN
#include "res://addons/pasture_3d/extras/shaders/water/water_common.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_waves.gdshaderinc"

// Must match PROBES in WaterPhase4Gate.gd.
#define PROBE_MAX 64

uniform int probe_count = 0;
uniform float cell_px = 8.0;
// xy = domain-space XZ handed to both evaluators. zw unused.
uniform vec4 probe_in[PROBE_MAX];
// xyz = the world-space surface point Pasture3D.get_water_surface_point() gave
// for the same domain XZ.
uniform vec4 probe_cpu[PROBE_MAX];
// The Y the clipmap sheet carries into water_eval_waves(), i.e. sea_level.
uniform float base_y = 0.0;
// What Pasture3D.get_water_time() reported for the same instant.
uniform float cpu_time = 0.0;

void fragment() {
	int idx = int(floor(FRAGCOORD.x / cell_px));
	vec3 rgb = vec3(0.0);
	if (idx == probe_count) {
		float drift = abs(water_time - cpu_time);
		rgb.r = drift > 1e-5 ? 1.0 : 0.0;
		rgb.g = drift > 1e-7 ? 1.0 : 0.0;
		rgb.b = water_time == 0.0 ? 1.0 : 0.0;
	} else if (idx < probe_count) {
		vec2 domain = probe_in[idx].xy;
		// water_eval_waves() takes an UNDISPLACED WORLD position and subtracts the
		// domain origin itself, so the origin has to be added back on here. Doing
		// it this way rather than passing domain space directly keeps the probe on
		// the same code path as water_surface.gdshaderinc.
		vec3 p = vec3(domain.x + _water_domain_origin.x, base_y,
				domain.y + _water_domain_origin.z);
		WaveSample s = water_eval_waves(p);

		vec3 cpu = probe_cpu[idx].xyz;
		float dy = abs(s.position.y - cpu.y);
		float dxz = length(s.position.xz - cpu.xz);

		rgb.r = dy > 0.01 ? 1.0 : 0.0;
		rgb.g = dy > 0.001 ? 1.0 : 0.0;
		rgb.b = dxz > 0.01 ? 1.0 : 0.0;
	}
	COLOR = vec4(rgb, 1.0);
}
