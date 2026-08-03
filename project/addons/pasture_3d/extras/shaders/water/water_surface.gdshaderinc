// Pasture3D Water — vertex stage.
// Spec: PASTURE3D_WATER_SHADER_SPEC.md §3.1, §4.1
//
// Owns vertex(). All wave work lives here so the fragment stage does none
// (§0 conclusion 1: the shader is fragment-bound, so work moves up).
//
// Assumes render_mode skip_vertex_transform in every wrapper, so both the
// clipmap and plain-mesh paths share one transform convention.

#ifndef WATER_SURFACE_INC
#define WATER_SURFACE_INC

void vertex() {
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

#ifdef WATER_CLIPMAP
	// Geomorph across clipmap LOD rings. Ported verbatim from the legacy shader
	// (ocean_shader.gdshader:137-151) -- this is load-bearing for the Pasture3D
	// mesher and must not be "cleaned up" without re-verifying LOD seams.
	float scale = MODEL_MATRIX[0][0];
	float inv_scale = 1.0 / scale;
	float max_xz = max(abs(world_pos.x - _target_pos.x), abs(world_pos.z - _target_pos.z));
	float vertex_lerp = smoothstep(0.0, 1.0, (max_xz * inv_scale - _mesh_size - 4.0) / (_mesh_size - 4.0));
	vec2 vertex_fract = fract(VERTEX.xz * 0.5) * 2.0;
	// For LOD0 morph from a regular grid to an alternating grid to align with LOD1+
	vec2 shift = (scale < _vertex_spacing / _subdiv + 1e-6) ? // LOD0 or not
		mix(vertex_fract, vec2(vertex_fract.x, -vertex_fract.y),
			round(fract(round(mod(world_pos.z * inv_scale, 4.0)) *
			round(mod(world_pos.x * inv_scale, 4.0)) * 0.25))) :
		vertex_fract * round((fract(world_pos.xz * 0.25 * inv_scale) - 0.5) * 4.0);
	world_pos.xz -= shift * scale * vertex_lerp;

	// The clipmap is a flat sheet at y=0; sea_level positions it.
	world_pos.y = sea_level;
#endif

	// Before the waves displace it: this is the flat sheet the water sits on, and
	// the fragment stage compares the camera against it to decide which side of
	// the surface the viewer is on.
	v_base_y = world_pos.y;

#ifdef WATER_FLOW
	// Decoded BEFORE the waves on a stream, not after: the stream evaluator needs
	// the flow direction and speed to place its ripples, where the lake path only
	// needs them later for the detail advection.
	//
	// Per-vertex data decoded here rather than in the fragment stage, so the
	// direction turns smoothly through a bend instead of stepping at every row.
	// rg is the XZ direction remapped from [-1,1], b the normalised speed (§10).
	v_flow = vec3(COLOR.rg * 2.0 - 1.0, COLOR.b);
#endif

#ifdef WATER_STREAM_WAVES
	v_shore = COLOR.a;
	// UV2.x is the cumulative flow travel time from the head of the channel, in
	// seconds -- the coordinate that makes crests run downstream on every reach.
	// CUSTOM0 carries the three later ones: lateral offset, the stationary phase,
	// and depth. See water_stream.gdshaderinc.
	//
	// CUSTOM0 is zero on any mesh that does not supply it, which is the degradation
	// we want: chop and standing waves fall out and the ripples are untouched, so a
	// river material dropped on a bare plane still runs rather than going wild.
	WaveSample wave = water_eval_stream_waves(world_pos, UV2.x, v_flow, v_shore, CUSTOM0);
#else
	WaveSample wave = water_eval_waves(world_pos);
#endif

	v_world_pos = wave.position;
	v_wave_normal = wave.normal;
	// Passed through RAW, in fold-limit units: sum(Q*w*A*sin) reaches 1.0 exactly
	// where the Gerstner surface would begin to self-intersect, so the signal
	// spans [-wave_steepness, +wave_steepness] and its scale is physical.
	//
	// An earlier version divided by wave_steepness so a threshold would sit at a
	// fixed point in the distribution whatever the knob. That was wrong for the
	// thing it feeds: it made whitecap coverage identical on a millpond and a
	// gale, which is precisely the correlation foam exists to express. Keeping the
	// raw value means the steepness knob drives foam and scattering for free, and
	// the threshold means "this fraction of the breaking limit".
	v_jacobian = wave.jacobian;
	v_view_dist = length(wave.position - CAMERA_POSITION_WORLD);

	VERTEX = (VIEW_MATRIX * vec4(wave.position, 1.0)).xyz;
	NORMAL = normalize(mat3(VIEW_MATRIX) * wave.normal);
}

#endif // WATER_SURFACE_INC
