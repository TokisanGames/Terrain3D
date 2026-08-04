# Pasture3D Water — Phase 1 exit gate (spec §7).
#
# Gate criteria:
#   A. all four .gdshader variants compile
#   B. #include + #define static variants actually work (inline debug variant)
#   C. globals register at runtime and reach the shader
#   D. water_body runs on a plain MeshInstance3D with zero plugin involvement (G6)
#   E. water_ocean runs on the Pasture3D ocean clipmap
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/WaterPhase1Gate.tscn
extends Node

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const VARIANTS: Array[String] = [
	"water_ocean.gdshader",
	"water_ocean_low.gdshader",
	"water_body.gdshader",
	"water_body_low.gdshader",
]

const DEBUG_VARIANT_CODE := """
shader_type spatial;
render_mode cull_disabled, depth_draw_never, diffuse_lambert, skip_vertex_transform;
#define WATER_WAVE_COUNT 2
#define WATER_DEBUG_GLOBALS
#include "res://addons/pasture_3d/extras/shaders/water/water_common.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_waves.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_surface.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_shading.gdshaderinc"
"""

var _fail := 0
var _out_dir := ""
var _vp: SubViewport


func _ready() -> void:
	var bail := Timer.new()
	bail.wait_time = 60.0
	bail.one_shot = true
	bail.timeout.connect(func():
		push_error("gate timed out")
		get_tree().quit(2))
	add_child(bail)
	bail.start()

	_out_dir = OS.get_environment("BENCH_OUT")
	if _out_dir == "":
		_out_dir = "user://"

	print("=== Pasture3D Water — Phase 1 gate ===")
	print("Godot %s | %s | %s" % [
		Engine.get_version_info().string,
		RenderingServer.get_video_adapter_name(),
		RenderingServer.get_current_rendering_method()])
	print("")

	_register_globals()
	_gate_a_compile()
	await _gate_bc_globals()
	await _gate_d_plain_mesh()
	await _gate_e_clipmap()

	print("")
	print("=== PHASE 1 GATE %s ===" % ("PASS" if _fail == 0 else "FAIL (%d)" % _fail))
	get_tree().quit(0 if _fail == 0 else 1)


# Mirrors what the plugin will do on init (spec §2.3 runtime fallback).
# ProjectSettings.has_setting() is the runtime-safe existence check --
# global_shader_parameter_get_list() is editor-only and errors in a game build.
func _register_globals() -> void:
	var decls := {
		"water_time": [RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0],
		"water_sun_direction": [RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3(0, 1, 0)],
		"water_sun_color": [RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3(1, 1, 1)],
	}
	var added := 0
	for gname: String in decls.keys():
		if not ProjectSettings.has_setting("shader_globals/" + gname):
			var d: Array = decls[gname]
			RenderingServer.global_shader_parameter_add(gname, d[0], d[1])
			added += 1
	print("[globals] registered %d/%d at runtime (rest already in project.godot)" % [added, decls.size()])


# ---- A: all four variants compile -------------------------------------------
func _gate_a_compile() -> void:
	print("[A] compiling variants:")
	for v: String in VARIANTS:
		var sh: Shader = load(WATER_DIR + v)
		if sh == null:
			print("    %-26s LOAD FAILED" % v)
			_fail += 1
			continue
		# A shader whose preprocessor/parse failed exposes no uniforms.
		var uniforms: Array = sh.get_shader_uniform_list()
		var names: Array[String] = []
		for u in uniforms:
			names.append(String(u["name"]))
		var has_core: bool = names.has("absorption") and names.has("_waves")
		var has_clipmap: bool = names.has("_target_pos")
		var expect_clipmap: bool = v.begins_with("water_ocean")
		var ok: bool = has_core and (has_clipmap == expect_clipmap)
		print("    %-26s %-4s  uniforms=%2d  clipmap_uniforms=%s (expected %s)" % [
			v, "OK" if ok else "FAIL", names.size(), has_clipmap, expect_clipmap])
		if not ok:
			_fail += 1
			if not has_core:
				print("        !! core uniforms missing -> preprocessor/include failed")
			if has_clipmap != expect_clipmap:
				print("        !! WATER_CLIPMAP gating is not working")


# ---- B + C: inline #define variant, and globals reaching the shader ---------
func _gate_bc_globals() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(64, 64)
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 3)
	cam.current = true
	_vp.add_child(cam)

	var sh := Shader.new()
	sh.code = DEBUG_VARIANT_CODE
	var mat := ShaderMaterial.new()
	mat.shader = sh
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(50, 50)
	mi.mesh = q
	mi.material_override = mat
	_vp.add_child(mi)

	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var u := sh.get_shader_uniform_list()
	print("[B] inline #include + #define variant: %s (%d uniforms)" % [
		"OK" if u.size() > 0 else "FAIL", u.size()])
	if u.size() == 0:
		_fail += 1
		print("    !! runtime Shader.code with absolute-path #include did not compile")
		return

	print("[C] globals -> shader (ALBEDO.r=time, .g=sun_color.g, .b=sun_dir.y remapped):")
	var cases := [
		[0.0, Vector3(1, 0, 1), Vector3(0, 1, 0)],
		[0.5, Vector3(1, 0.5, 1), Vector3(0, 0, 0)],
		[1.0, Vector3(1, 1.0, 1), Vector3(0, -1, 0)],
	]
	var prev_r := -1.0
	var monotonic := true
	var sampled := 0
	for c: Array in cases:
		var t: float = c[0]
		var sun_col: Vector3 = c[1]
		var sun_dir: Vector3 = c[2]
		RenderingServer.global_shader_parameter_set("water_time", t)
		RenderingServer.global_shader_parameter_set("water_sun_color", sun_col)
		RenderingServer.global_shader_parameter_set("water_sun_direction", sun_dir)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var px := _sample(_vp)
		print("    time=%.2f sun_g=%.2f sun_y=%+.1f -> (%.3f, %.3f, %.3f)" % [
			t, sun_col.y, sun_dir.y, px.r, px.g, px.b])
		if px.r <= prev_r and prev_r >= 0.0:
			monotonic = false
		prev_r = px.r
		sampled += 1
	# A runtime error inside the loop above must not read as a pass.
	if sampled != cases.size():
		_fail += 1
		print("    !! only %d/%d cases sampled" % [sampled, cases.size()])
	elif not monotonic:
		_fail += 1
		print("    !! globals are not reaching the shader")
	else:
		print("    -> globals propagate")


# ---- D: plain MeshInstance3D, no plugin (spec G6) ---------------------------
func _gate_d_plain_mesh() -> void:
	var root := _make_world()
	var mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400, 400)
	plane.subdivide_width = 32
	plane.subdivide_depth = 32
	mi.mesh = plane
	# Deliberately nothing else: no Pasture3D node, no uniforms set by hand.
	mi.material_override = _mat_for("water_body.gdshader")
	root.add_child(mi)

	await _settle()
	var path := "%s/phase1_body_plainmesh.png" % _out_dir
	_screenshot(path)
	var cov := _coverage()
	print("[D] water_body on a bare MeshInstance3D: coverage %.1f%% -> %s" % [
		cov, "OK" if cov > 10.0 else "FAIL (nothing rendered)"])
	print("    %s" % path)
	if cov <= 10.0:
		_fail += 1
	root.queue_free()
	await _settle()


# ---- E: Pasture3D ocean clipmap --------------------------------------------
func _gate_e_clipmap() -> void:
	var root := _make_world()
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 30, 0)
	root.add_child(sun)

	var terrain := Pasture3D.new()
	terrain.ocean_material = _mat_for("water_ocean.gdshader")
	terrain.ocean_enabled = true
	terrain.ocean_light_target = sun
	terrain.render_layers = 1 << 4
	terrain.ocean_render_layers = 1
	root.add_child(terrain)

	await _settle()
	var path := "%s/phase1_ocean_clipmap.png" % _out_dir
	_screenshot(path)
	var cov := _coverage()
	print("[E] water_ocean on the Pasture3D clipmap: coverage %.1f%% -> %s" % [
		cov, "OK" if cov > 10.0 else "FAIL (nothing rendered)"])
	print("    %s" % path)
	if cov <= 10.0:
		_fail += 1
	root.queue_free()
	await _settle()


# ---- helpers ---------------------------------------------------------------
func _make_world() -> Node3D:
	var root := Node3D.new()
	add_child(root)
	var env := Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 12, 0)
	cam.rotation_degrees = Vector3(-15, 0, 0)
	cam.far = 20000.0
	cam.cull_mask = 1
	cam.current = true
	root.add_child(cam)
	return root


func _mat_for(variant: String) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(WATER_DIR + variant)
	m.set_shader_parameter("deep_color", Color(0.02, 0.09, 0.14))
	return m


func _settle() -> void:
	for i in 12:
		await RenderingServer.frame_post_draw


func _sample(vp: SubViewport) -> Color:
	var img := vp.get_texture().get_image()
	return img.get_pixel(img.get_width() / 2, img.get_height() / 2)


func _screenshot(path: String) -> void:
	get_viewport().get_texture().get_image().save_png(path)


# Fraction of the lower half of the frame that is not sky-coloured. Crude, but
# enough to distinguish "water rendered" from "nothing rendered".
func _coverage() -> float:
	var img := get_viewport().get_texture().get_image()
	var hit := 0
	var total := 0
	for y in range(img.get_height() / 2, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			total += 1
			var c := img.get_pixel(x, y)
			# Sky in this setup is bright and blue-dominant with high luminance.
			if c.get_luminance() < 0.35:
				hit += 1
	return 100.0 * float(hit) / float(max(total, 1))
