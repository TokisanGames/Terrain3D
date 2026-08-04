# Phase 1 gate probe, part 2 (spec §2.3): does declaring globals via
# ProjectSettings["shader_globals/*"] work, and does it persist?
#
# This is the cleaner alternative to runtime global_shader_parameter_add():
# no ordering race, no "removed at some point" warning spam, survives export.
#
# SAFETY: writes then REVERTS the settings; does not call ProjectSettings.save()
# unless BENCH_ALLOW_SAVE=1, so the user's project.godot is left untouched by default.
extends Node

const SHADER_SRC := """
shader_type spatial;
render_mode unshaded, cull_disabled;
global uniform float water_time;
void fragment() { ALBEDO = vec3(water_time, 0.0, 0.0); }
"""

var _vp: SubViewport
var _fail := 0


func _ready() -> void:
	# Failsafe: never leave a window hanging if an await never resolves.
	var bail := Timer.new()
	bail.wait_time = 30.0
	bail.one_shot = true
	bail.timeout.connect(func():
		push_error("probe timed out")
		get_tree().quit(2))
	add_child(bail)
	bail.start()

	print("=== Phase 1 gate part 2: ProjectSettings-declared globals ===")
	var allow_save := OS.get_environment("BENCH_ALLOW_SAVE") == "1"
	print("allow_save=%s (project.godot will %s)" % [
		allow_save, "be written" if allow_save else "NOT be modified"])
	print("")

	var had_before := ProjectSettings.has_setting("shader_globals/water_time")
	print("[0] setting present before: %s" % had_before)

	# Declare exactly as the Project Settings > Globals tab would.
	ProjectSettings.set_setting("shader_globals/water_time", {
		"type": "float",
		"value": 0.0,
	})
	print("[1] declared shader_globals/water_time via ProjectSettings")
	print("    has_setting now: %s" % ProjectSettings.has_setting("shader_globals/water_time"))

	# Does the renderer see it without an explicit RenderingServer add()?
	var visible_to_rs := false
	RenderingServer.global_shader_parameter_set("water_time", 0.5)
	await RenderingServer.frame_post_draw
	var probed = RenderingServer.global_shader_parameter_get("water_time")
	visible_to_rs = probed != null and typeof(probed) == TYPE_FLOAT
	print("[2] RenderingServer.global_shader_parameter_get -> %s (type %s)" % [
		str(probed), type_string(typeof(probed))])

	_build()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var px := _sample()
	var ok := px.r > 0.05
	print("[3] rendered pixel: (r=%.4f) -> %s" % [px.r, "VALUE REACHED SHADER" if ok else "FAIL"])
	if not ok:
		_fail += 1
		print("    !! ProjectSettings declaration alone is not sufficient at runtime.")
		print("    !! Plugin must ALSO call global_shader_parameter_add() on init.")

	if allow_save:
		ProjectSettings.save()
		print("[4] saved project.godot")
	else:
		if not had_before:
			ProjectSettings.clear("shader_globals/water_time")
			print("[4] reverted in-memory setting; project.godot not written")

	print("")
	print("=== %s ===" % ("PART 2 PASS" if _fail == 0 else "PART 2 FAIL"))
	get_tree().quit()


func _build() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(64, 64)
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 2)
	cam.current = true
	_vp.add_child(cam)
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = SHADER_SRC
	mat.shader = sh
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(100, 100)
	mi.mesh = q
	mi.material_override = mat
	_vp.add_child(mi)


func _sample() -> Color:
	var img := _vp.get_texture().get_image()
	return img.get_pixel(img.get_width() / 2, img.get_height() / 2)
