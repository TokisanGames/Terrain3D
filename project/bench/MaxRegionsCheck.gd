# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DMaterial.max_regions compiles the right array and draws the same terrain.
#
# Ported from upstream Terrain3D 5e352f7. The shader used to declare _region_locations[1024]
# unconditionally -- 8 KB of uniform data in every terrain material, half of GLES3's guaranteed
# 16 KB uniform block, on projects that typically use a handful of regions. max_regions picks the
# compiled length instead.
#
# It is a COMPILE-TIME array length, spliced in as one of five mutually exclusive //INSERT:
# blocks, so the failure mode if the excludes are wrong is not a warning: it is either five
# conflicting declarations of the same uniform (shader dead) or none (MAX_REGIONS undefined,
# shader dead). Criterion A checks the declaration directly rather than trusting that a render
# happened to look right.
#
# Criterion B is the one that matters for shipping: with 3 regions loaded, every size from 64 up
# holds them all, so every size must draw the IDENTICAL image. Its control is A -- the shader
# genuinely differs between the sizes being compared, so B is not passing because nothing changed.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/MaxRegionsCheck.tscn
extends Node

const DEMO_DATA := "res://demo/data"
const DEMO_MATERIAL := "res://demo/data/M_terrain.tres"
const DEMO_ASSETS := "res://demo/data/assets.tres"
const SIZES := [64, 128, 256, 512, 1024]

var _fail := 0
var _terrain: Pasture3D
var _camera: Camera3D
var _material: Pasture3DMaterial
var _codes := {}
var _images := {}


func _ready() -> void:
	print("\n=== Pasture3DMaterial.max_regions ===\n")
	_build()
	await _settle()
	await _gate_a_declaration()
	await _gate_b_identical_render()
	_gate_c_codes_differ()

	print("")
	if _fail == 0:
		print("=== MAX REGIONS CHECK PASS ===")
	else:
		print("=== MAX REGIONS CHECK FAIL (%d) ===" % _fail)
	get_tree().quit(1 if _fail > 0 else 0)


## The compiled shader must declare _region_locations at exactly the requested length, and define
## MAX_REGIONS to match. Read out of the generated code, because this is the thing the excludes
## either got right or silently got wrong.
func _gate_a_declaration() -> void:
	print("[A] the shader declares the array it was asked for:")
	for size in SIZES:
		_material.max_regions = size
		await _settle()
		var code: String = RenderingServer.shader_get_code(_material.get_shader_rid())
		_codes[size] = code
		if size == 64 and OS.get_environment("DUMP_SHADER") == "1":
			var f := FileAccess.open("user://maxregions_dump.txt", FileAccess.WRITE)
			if f != null:
				f.store_string(code)
				f.close()
				print("        dumped generated shader to user://maxregions_dump.txt")
		var has_decl := code.contains("uniform vec2 _region_locations[%d];" % size)
		# Exactly one declaration: five inserts, four excluded. More than one means the excludes
		# did not fire and the shader carries conflicting declarations of the same uniform.
		var decl_count := code.count("uniform vec2 _region_locations[")
		# The SUBSTITUTED value of MAX_REGIONS, not the #define. shader_get_code() returns code
		# after Godot's shader preprocessor has run, so `#define MAX_REGIONS 64` is consumed and
		# its uses are replaced by the literal. Asserting on the substitution is the stronger
		# test anyway: it proves the bounds check in get_index_coord() is comparing against the
		# array length that was actually compiled, which is the thing that would silently read
		# off the end of the uniform if the two ever disagreed.
		# Whitespace-stripped before matching: Godot's preprocessor pads a substituted macro with
		# spaces, so `raw_index < MAX_REGIONS` comes back as `raw_index <  64 `. Matching the
		# spaced form would be matching an implementation detail of the preprocessor.
		var bound := "raw_index<%d)" % size
		var has_bound := code.replace(" ", "").contains(bound)
		var ok: bool = has_decl and has_bound and decl_count == 1
		print("    max_regions=%-4d decl=%s bound(%s)=%s declarations=%d %s" % [
			size, str(has_decl), bound, str(has_bound), decl_count, "ok" if ok else "!! FAIL"])
		if not ok:
			_fail += 1


## Every size from 64 up holds the 3 loaded regions, so every size must draw the same image.
## A difference means the bounds check or the padded upload is dropping a region it should keep.
func _gate_b_identical_render() -> void:
	print("\n[B] every size draws the identical terrain (3 regions fit in all of them):")
	for size in SIZES:
		_material.max_regions = size
		await _settle()
		_images[size] = get_viewport().get_texture().get_image()
	var ref: Image = _images[1024]
	if ref == null:
		_fail += 1
		print("    !! no reference capture")
		return
	for size in SIZES:
		if size == 1024:
			continue
		var delta := _mean_delta(ref, _images[size])
		var ok := delta < 0.001
		print("    max_regions=%-4d mean delta vs 1024: %.6f %s" % [
			size, delta, "ok" if ok else "!! FAIL (a region was dropped or misplaced)"])
		if not ok:
			_fail += 1


## CONTROL for B. If the generated shaders were identical between sizes, B would pass by
## comparing a config against itself and would keep passing if max_regions did nothing at all.
func _gate_c_codes_differ() -> void:
	print("\n[C] CONTROL, the shader actually changed between sizes:")
	var same: bool = _codes.get(64, "") == _codes.get(1024, "")
	print("    code(64) == code(1024): %s %s" % [
		str(same), "!! FAIL (max_regions is a no-op; B proved nothing)" if same else "ok"])
	if same:
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

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 30, 0)
	sun.shadow_enabled = false
	add_child(sun)

	_camera = Camera3D.new()
	_camera.far = 8000.0
	_camera.rotation_degrees = Vector3(-20, 0, 0)
	_camera.current = true
	add_child(_camera)

	_terrain = Pasture3D.new()
	_material = load(DEMO_MATERIAL).duplicate(true)
	_terrain.clipmap_target = _camera
	add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_terrain.material = _material
	_terrain.assets = load(DEMO_ASSETS)
	if _terrain.assets != null:
		_terrain.assets.update_texture_list()
	_material.update(Pasture3DMaterial.TEXTURE_ARRAYS)

	# Over the middle of the loaded regions, as TerrainMaterialBench does.
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


func _mean_delta(p_a: Image, p_b: Image) -> float:
	if p_a == null or p_b == null or p_a.get_size() != p_b.get_size():
		return 1.0
	var total := 0.0
	var n := 0
	# Every 8th pixel; enough to catch a shifted or missing region, cheap enough to stay instant.
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
