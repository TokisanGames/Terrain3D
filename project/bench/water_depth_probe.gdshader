// Validates the cheap scalar linear-depth reconstruction of spec §3.5 against
// the full INV_PROJECTION_MATRIX path the legacy shader used, under Godot's
// reversed-Z convention. Phase 2 gate.
//
// Output channels, read back by bench/WaterPhase2Gate.gd:
//   R = 1.0 where the two disagree by more than DEPTH_TOL relative, else 0.0
//   G = scalar-path view depth, normalised   -- these two exist so a pass
//   B = mat4-path view depth, normalised     -- cannot be vacuous
//
// The G/B channels matter as much as R: if the depth buffer were empty, or the
// quad were drawn where nothing is behind it, both methods would trivially
// agree on garbage and R would be black for the wrong reason.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
uniform float depth_norm = 100.0; // metres mapped to 1.0 in G/B
uniform float tolerance = 1e-4;   // relative

void fragment() {
	float raw = texture(depth_tex, SCREEN_UV).r;

	// Reference: full inverse-projection transform plus perspective divide.
	// This is what ocean_shader.gdshader did twice per fragment.
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw);
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	float vz_mat4 = view.z / view.w;

	// Candidate: only the z row and the w row, no xy contribution.
	// Exact for a symmetric perspective frustum; this test is what decides
	// whether that assumption survives contact with Godot's actual matrix.
	float vz_scalar = (INV_PROJECTION_MATRIX[2][2] * raw + INV_PROJECTION_MATRIX[3][2])
			/ (INV_PROJECTION_MATRIX[2][3] * raw + INV_PROJECTION_MATRIX[3][3]);

	float rel = abs(vz_scalar - vz_mat4) / max(abs(vz_mat4), 1e-6);

	ALBEDO = vec3(
		rel > tolerance ? 1.0 : 0.0,
		clamp(-vz_scalar / depth_norm, 0.0, 1.0),
		clamp(-vz_mat4 / depth_norm, 0.0, 1.0));
	ALPHA = 1.0;
}
