# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3D.light_target reaches the terrain shader, and an unassigned one is safe.
#
# Ported from upstream Terrain3D f6cdd9c, which suppresses terrain specular on faces turned away
# from the sun. Two things about that port are load-bearing and neither is obvious from a
# screenshot:
#
#  1. _light_direction is a PRIVATE uniform (leading underscore). Pasture3DMaterial._set() only
#     recognises public params, so set_shader_param() had to learn to route private names
#     straight to the RenderingServer. If that routing is wrong the write vanishes silently and
#     the terrain simply keeps its old look -- which is indistinguishable from "the feature is
#     off" unless something asserts the value moved. Criterion B is that assertion.
#
#  2. Upstream defaults _light_direction to vec3(0.), and normalize(vec3(0.)) is NaN. Every
#     existing scene has no light_target, so upstream's default path feeds NaN into the specular
#     term. This port guards it and treats zero as "fully lit". Criterion A is that guard: an
#     unassigned terrain must render finite pixels, not garbage.
#
# Criterion C is the control for A. A NaN check that passes on a black screen proves nothing, so
# C requires the unassigned render to have actual tonal range.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/LightTargetCheck.tscn
extends Node

const DEMO_DATA := "res://demo/data"
const DEMO_MATERIAL := "res://demo/data/M_terrain.tres"
const DEMO_ASSETS := "res://demo/data/assets.tres"

var _fail := 0
var _terrain: Pasture3D
var _camera: Camera3D
var _material: Pasture3DMaterial
var _sun: DirectionalLight3D
var _unassigned: Image


func _ready() -> void:
	print("\n=== Pasture3D.light_target ===\n")
	_build()
	await _settle()
	await _gate_a_unassigned_is_finite()
	await _gate_b_direction_reaches_shader()
	_gate_c_image_has_range()

	print("")
	if _fail == 0:
		print("=== LIGHT TARGET CHECK PASS ===")
	else:
		print("=== LIGHT TARGET CHECK FAIL (%d) ===" % _fail)
	get_tree().quit(1 if _fail > 0 else 0)


## No light_target assigned is the state every pre-existing scene is in. The shader must read the
## zero direction as "fully lit" rather than normalizing it into NaN.
func _gate_a_unassigned_is_finite() -> void:
	print("[A] no light_target assigned renders finite pixels:")
	_terrain.light_target = null
	await _settle()
	_unassigned = get_viewport().get_texture().get_image()
	var dir: Variant = _material.get_shader_param("_light_direction")
	var bad := _count_nonfinite(_unassigned)
	var ok: bool = bad == 0
	print("    _light_direction=%s  non-finite pixels=%d %s" % [
		str(dir), bad, "ok" if ok else "!! FAIL (normalize(vec3(0.)) leaked NaN into specular)"])
	if not ok:
		_fail += 1


## Assigning a light must change the image, and rotating it must change it again. Together those
## prove the private-uniform write actually lands: a dropped write would leave all three identical.
func _gate_b_direction_reaches_shader() -> void:
	print("\n[B] the assigned light's direction reaches the shader:")
	_terrain.light_target = _sun

	# Sun high and behind the camera: most of the terrain faces it.
	_sun.rotation_degrees = Vector3(-50.0, 0.0, 0.0)
	await _settle()
	var facing := get_viewport().get_texture().get_image()
	var facing_dir: Variant = _material.get_shader_param("_light_direction")

	# Sun low and from the opposite side: most of the terrain is turned away, so the
	# suppression term should bite and specular should drop.
	_sun.rotation_degrees = Vector3(-10.0, 180.0, 0.0)
	await _settle()
	var away := get_viewport().get_texture().get_image()
	var away_dir: Variant = _material.get_shader_param("_light_direction")

	var uniform_moved: bool = facing_dir != away_dir and facing_dir != null
	print("    uniform readback: facing=%s away=%s  moved=%s %s" % [
		_fmt(facing_dir), _fmt(away_dir), str(uniform_moved),
		"ok" if uniform_moved else "!! FAIL (private param write never reached the material)"])
	if not uniform_moved:
		_fail += 1

	var delta := _mean_delta(facing, away)
	var ok := delta > 0.001
	print("    mean delta facing vs away: %.6f %s" % [
		delta, "ok" if ok else "!! FAIL (light direction has no effect on the render)"])
	if not ok:
		_fail += 1

	var bad := _count_nonfinite(away)
	print("    non-finite pixels with a light assigned: %d %s" % [
		bad, "ok" if bad == 0 else "!! FAIL"])
	if bad > 0:
		_fail += 1


## CONTROL for A. A finite-pixel check passes trivially on a uniformly black or blown-out frame,
## which is what a broken fixture looks like. Require real tonal range before believing A.
func _gate_c_image_has_range() -> void:
	print("\n[C] CONTROL, the unassigned capture is a real terrain image:")
	if _unassigned == null:
		print("    !! FAIL (no capture)")
		_fail += 1
		return
	var lo := 2.0
	var hi := -1.0
	for y in range(0, _unassigned.get_height(), 8):
		for x in range(0, _unassigned.get_width(), 8):
			var l: float = _unassigned.get_pixel(x, y).get_luminance()
			lo = minf(lo, l)
			hi = maxf(hi, l)
	var span := hi - lo
	var ok := span > 0.05
	print("    luminance range %.4f .. %.4f (span %.4f) %s" % [
		lo, hi, span, "ok" if ok else "!! FAIL (flat frame; A proved nothing)"])
	if not ok:
		_fail += 1


# ---- fixtures ----------------------------------------------------------------

func _build() -> void:
	var env := Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-40, 30, 0)
	_sun.shadow_enabled = false
	add_child(_sun)

	_camera = Camera3D.new()
	_camera.far = 8000.0
	_camera.rotation_degrees = Vector3(-20, 0, 0)
	_camera.current = true
	add_child(_camera)

	_terrain = Pasture3D.new()
	_material = load(DEMO_MATERIAL).duplicate(true)
	_terrain.clipmap_target = _camera
	# add_child BEFORE assigning data/material: Pasture3D::_initialize() is gated on being
	# inside the tree, so anything assigned earlier is never picked up.
	add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_terrain.material = _material
	_terrain.assets = load(DEMO_ASSETS)
	if _terrain.assets != null:
		_terrain.assets.update_texture_list()
	_material.update(Pasture3DMaterial.TEXTURE_ARRAYS)

	var locs: Array = _terrain.data.region_locations
	var sum := Vector2.ZERO
	for l in locs:
		sum += Vector2(l)
	var region_world: float = float(_terrain.region_size) * _terrain.vertex_spacing
	var centre: Vector2 = (sum / maxf(float(locs.size()), 1.0) + Vector2(0.5, 0.5)) * region_world
	var ground: float = _terrain.data.get_height(Vector3(centre.x, 0.0, centre.y))
	if is_nan(ground):
		ground = 0.0
	_camera.position = Vector3(centre.x, ground + 12.0, centre.y)
	print("regions=%d  camera=%v" % [locs.size(), _camera.position])


func _fmt(p_v: Variant) -> String:
	if p_v == null:
		return "<null>"
	return "%v" % p_v


## NaN and Inf both survive into the framebuffer as values that fail their own equality test or
## exceed the 0-1 range a tonemapped LDR capture can hold.
func _count_nonfinite(p_img: Image) -> int:
	if p_img == null:
		return -1
	var bad := 0
	for y in range(0, p_img.get_height(), 4):
		for x in range(0, p_img.get_width(), 4):
			var c := p_img.get_pixel(x, y)
			for v in [c.r, c.g, c.b]:
				if is_nan(v) or is_inf(v):
					bad += 1
					break
	return bad


func _mean_delta(p_a: Image, p_b: Image) -> float:
	if p_a == null or p_b == null or p_a.get_size() != p_b.get_size():
		return -1.0
	var total := 0.0
	var n := 0
	for y in range(0, p_a.get_height(), 8):
		for x in range(0, p_a.get_width(), 8):
			var ca := p_a.get_pixel(x, y)
			var cb := p_b.get_pixel(x, y)
			total += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
			n += 1
	return total / maxf(float(n) * 3.0, 1.0)


func _settle() -> void:
	for i in 4:
		await get_tree().physics_frame
	for i in 4:
		await RenderingServer.frame_post_draw
