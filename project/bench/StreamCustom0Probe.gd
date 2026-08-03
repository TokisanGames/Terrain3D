# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Does CUSTOM0 reach the vertex shader? Spec §10.3, §10.4.
#
# THE GAP THIS CLOSES. The chop and the standing waves read three coordinates the older wave terms
# did not need -- signed lateral offset, the stationary phase, and depth -- and there is nowhere
# left in UV2 or COLOR to put them, so they travel in ARRAY_CUSTOM0. That is a vertex FORMAT, and a
# vertex format is the one part of this pipeline that fails silently in both directions:
#
#   * Omit the format flag on add_surface_from_arrays and Godot drops the array without a word.
#   * Ask for a custom channel the mesh does not carry and the shader reads zeros.
#
# Either way CUSTOM0 comes back as vec4(0), which makes the lateral offset zero everywhere (chop
# becomes a second set of athwart ripples), depth zero (standing waves gated off), and resolved zero
# (standing waves gated off again). The surface still moves. Nothing errors. Every CPU-side gate
# still passes, because the CPU reads its own arrays and never asks the GPU anything.
#
# So this renders the stream's OWN mesh through a shader that writes CUSTOM0 straight out, reads the
# pixels back, and compares them to what the mesher put in. It is the only check here that puts a
# number the GPU produced next to the number the CPU produced.
#
# NEEDS A REAL RENDERER. Under --headless the dummy driver rasterises nothing and every pixel comes
# back black, which is indistinguishable from the failure this is looking for -- so it refuses to
# run there rather than passing or failing on a lie.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/StreamCustom0Probe.tscn
extends Node

const STREAM_SCRIPT := "res://addons/pasture_3d/connectors/stream.gd"
const RIVER_MAT := "res://addons/pasture_3d/extras/shaders/water/M_water_river.tres"

const VIEW := 512
## Metres the encoding spreads the lateral offset over, and the depth. Both chosen so the values
## under test land near the middle of the 0..1 range: an 8-bit render target quantises hardest at
## the ends, and a channel that reads 0 because it is genuinely 0 is exactly what must not be
## confused with a channel that reads 0 because it never arrived.
const LATERAL_SCALE := 32.0
const DEPTH_SCALE := 8.0

## Depth given to the fixture, via fill_offset with no terrain in the scene. A flat 3 m of water:
## the point here is that the number SURVIVES THE TRIP, not that it varies -- criterion H of
## StreamRippleCheck already owns whether depth tracks the bed.
const FIXTURE_DEPTH := 3.0
const FIXTURE_SPEED := 4.0
const FIXTURE_SPACING := 1.0

## Fraction of full scale the GPU reading may differ by. Generous on purpose. The render target is
## 8-bit and sRGB-encoded, so a couple of percent is the pipeline and not the code -- and the
## failure being hunted is a channel arriving as zeros or as the wrong component, which misses by
## tens of percent or by everything.
const TOLERANCE := 0.05

var _fail := 0
var _shader := Shader.new()
var _camera: Camera3D = null


func _ready() -> void:
	_run()


func _run() -> void:
	print("\n=== Stream CUSTOM0 readback ===")
	if DisplayServer.get_name() == "headless":
		print("  !! headless: nothing is rasterised, so every pixel would be black and this")
		print("     check cannot tell a working channel from a missing one. Run windowed.")
		get_tree().quit(2)
		return

	_shader.code = _PROBE_SHADER
	await _case("CUSTOM0 present", true)
	# CONTROL: the identical mesh built WITHOUT the format flag. If the readings do not collapse,
	# the probe is not reading CUSTOM0 -- it is reading something else that happens to look right,
	# and the case above proved nothing about the channel.
	await _case("CONTROL, format flag withheld", false)

	print("")
	print("=== %s ===" % ("PASS" if _fail == 0 else "FAIL (%d)" % _fail))
	get_tree().quit(0 if _fail == 0 else 1)


func _case(p_label: String, p_with_flag: bool) -> void:
	print("\n%s" % p_label)
	var root := Node3D.new()
	add_child(root)
	var manager = ClassDB.instantiate("Pasture3DPoolManager")
	manager.name = "Pasture3DPoolManager"
	root.add_child(manager)

	var stream = load(STREAM_SCRIPT).new()
	stream.material = load(RIVER_MAT)
	stream.wave_profile = &"river_flow"
	stream.underwater_enabled = false
	stream.vertex_spacing = FIXTURE_SPACING
	stream.flow_speed = FIXTURE_SPEED
	stream.flow_slope_gain = 0.0
	# No terrain in the scene, so the surface is the bed plus fill_offset and the depth IS that
	# offset -- a channel with a known depth and no terrain fixture to set up.
	stream.fill_offset = FIXTURE_DEPTH
	stream.manager = manager
	root.add_child(stream)
	var c := Curve3D.new()
	for i in 25:
		c.add_point(Vector3(-60.0 + i * 5.0, 0.0, 0.0))
	stream.curve = c
	var stats: Dictionary = stream.rebuild()
	if not stats.get("ok", false):
		_fail += 1
		print("  !! the fixture did not build (%s)" % stats.get("reason", ""))
		root.queue_free()
		return

	var mesh: ArrayMesh = stream._surface.mesh
	if not p_with_flag:
		mesh = _strip_custom0(mesh)
	var carries := (mesh.surface_get_format(0) & Mesh.ARRAY_FORMAT_CUSTOM0) != 0
	print("  mesh declares CUSTOM0: %s" % carries)

	var rows: PackedVector3Array = stream.get_centreline()
	var mid: Vector3 = stream.global_transform * rows[rows.size() / 2]
	var image: Image = await _render(mesh, mid)
	if image == null:
		_fail += 1
		print("  !! the probe viewport produced no image")
		root.queue_free()
		return

	# Three points across one cross-section: the two mesh edges and the centreline. Lateral offset
	# is the one channel that VARIES across the strip, so reading it at three places is what
	# separates "the channel arrived" from "some constant arrived".
	var half: float = stream._row_half(rows.size() / 2, false)
	var expect_depth := FIXTURE_DEPTH if p_with_flag else 0.0
	var ok := true
	for probe in [[-half, "left edge"], [0.0, "centreline"], [half, "right edge"]]:
		var offset: float = probe[0]
		var world := Vector3(mid.x, mid.y, mid.z + offset)
		var px := _camera.unproject_position(world)
		var got: Variant = _read(image, px)
		if got == null:
			_fail += 1
			print("  !! %s projected outside the probe viewport" % probe[1])
			ok = false
			continue
		var lateral: float = (got.r - 0.5) * LATERAL_SCALE
		var depth: float = got.g * DEPTH_SCALE
		var want_lateral: float = offset if p_with_flag else 0.0
		print("  %-11s GPU lateral %+6.2f m (mesher %+6.2f), depth %.2f m (mesher %.2f), "
				% [probe[1], lateral, want_lateral, depth, expect_depth]
				+ "resolved %.2f" % got.b)
		# The lateral tolerance is in metres of the encoded RANGE, not a fraction of the value:
		# at the centreline the value is 0 and a relative tolerance would demand infinite accuracy.
		if absf(lateral - want_lateral) > TOLERANCE * LATERAL_SCALE:
			ok = false
		if absf(depth - expect_depth) > TOLERANCE * DEPTH_SCALE:
			ok = false

	if p_with_flag and not ok:
		_fail += 1
		print("  !! CUSTOM0 does not arrive in the vertex shader as the mesher wrote it.")
		print("     Chop and the standing waves are drawn from vec4(0) and the CPU is alone.")
	elif not p_with_flag and ok:
		_fail += 1
		print("  !! CONTROL did not fire: stripping the format flag changed nothing, so the")
		print("     probe is not reading CUSTOM0 and the case above is unproven")
	elif not p_with_flag:
		print("  control fires: without the format flag the channel reads as zeros")
	root.queue_free()


# ---- rendering -----------------------------------------------------------------

## One frame of the mesh from directly above, at a scale where the strip fills the frame.
func _render(p_mesh: ArrayMesh, p_centre: Vector3) -> Image:
	var vp := SubViewport.new()
	vp.size = Vector2i(VIEW, VIEW)
	vp.own_world_3d = true
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)

	var mi := MeshInstance3D.new()
	mi.mesh = p_mesh
	var mat := ShaderMaterial.new()
	mat.shader = _shader
	mat.set_shader_parameter("lateral_scale", LATERAL_SCALE)
	mat.set_shader_parameter("depth_scale", DEPTH_SCALE)
	mi.material_override = mat
	vp.add_child(mi)

	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	# 20 m across, so a strip about 12 m wide fills most of the frame and each metre is ~25 px.
	_camera.size = 20.0
	_camera.near = 0.1
	_camera.far = 200.0
	_camera.position = p_centre + Vector3(0.0, 50.0, 0.0)
	_camera.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	vp.add_child(_camera)

	# Two frames: one for the viewport to be sized and the camera to become current, one to draw.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img: Image = vp.get_texture().get_image()
	vp.queue_free()
	return img


## The pixel at a projected position, converted out of sRGB, or null if it is off the image.
##
## get_image() hands back what the render target stores, which is sRGB-encoded -- so a raw read of
## a channel holding 0.375 comes back around 0.65 and every comparison below would be wrong by a
## curve. Undoing it here keeps the encoding the shader wrote and the value the mesher wrote in the
## same units.
func _read(p_image: Image, p_px: Vector2) -> Variant:
	var x := int(round(p_px.x))
	var y := int(round(p_px.y))
	if x < 0 or y < 0 or x >= p_image.get_width() or y >= p_image.get_height():
		return null
	var c := p_image.get_pixel(x, y)
	return Color(_to_linear(c.r), _to_linear(c.g), _to_linear(c.b), 1.0)


func _to_linear(p_c: float) -> float:
	return p_c / 12.92 if p_c <= 0.04045 else pow((p_c + 0.055) / 1.055, 2.4)


## The same mesh with the CUSTOM0 array and its format flag left off -- the control's whole content.
func _strip_custom0(p_mesh: ArrayMesh) -> ArrayMesh:
	var arrays := p_mesh.surface_get_arrays(0)
	arrays[Mesh.ARRAY_CUSTOM0] = null
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return out


# Unshaded, so ALBEDO reaches the framebuffer without a light touching it, and cull_disabled so a
# top-down camera cannot miss the strip on winding.
const _PROBE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;

uniform float lateral_scale = 32.0;
uniform float depth_scale = 8.0;
varying vec4 v_chan;

void vertex() {
	v_chan = CUSTOM0;
}

void fragment() {
	// Lateral is signed, so it is biased into the middle of the range rather than clipped at 0.
	ALBEDO = vec3(
		clamp(v_chan.x / lateral_scale + 0.5, 0.0, 1.0),
		clamp(v_chan.z / depth_scale, 0.0, 1.0),
		clamp(v_chan.w, 0.0, 1.0));
}
"""
