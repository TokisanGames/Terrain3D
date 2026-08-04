// Phase 0 benchmark floor: same clipmap geometry, near-zero shading work.
// Opaque, unshaded, no texture reads, no wave math. The delta between this and
// the legacy ocean shader is the shader cost the replacement has to beat.
shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled, unshaded, shadows_disabled;

void fragment() {
	ALBEDO = vec3(0.1058, 0.1568, 0.2117);
}
