# Phase 1 gate probe (spec §2.3): can water globals be registered at runtime and
# actually reach a shader?
#
# Tests, in order:
#   1. add-then-compile  -- globals registered before the shader is created
#   2. compile-then-add  -- shader created first (the realistic plugin-load race)
#   3. value propagation -- change a global, confirm the rendered pixel changes
#   4. persistence       -- does global_shader_parameter_add write to project.godot?
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/GlobalUniformProbe.tscn
extends Node

const SHADER_SRC := """
shader_type spatial;
render_mode unshaded, cull_disabled;
global uniform float water_time;
global uniform vec3 water_sun_color;
void fragment() {
	ALBEDO = vec3(water_time, water_sun_color.g, 0.0);
}
"""

var _vp: SubViewport
var _mesh: MeshInstance3D
var _mat: ShaderMaterial
var _fail := 0


func _ready() -> void:
	print("=== Phase 1 gate: global shader uniforms from runtime registration ===")
	print("Godot %s | %s" % [
		Engine.get_version_info().string, RenderingServer.get_current_rendering_method()])
	print("")

	_probe_pre_existing()
	await _test_compile_then_add()
	await _test_add_then_compile()
	await _test_value_propagation()
	_probe_persistence()

	print("")
	if _fail == 0:
		print("=== GATE PASS ===")
	else:
		print("=== GATE FAIL (%d) ===" % _fail)
	get_tree().quit()


func _probe_pre_existing() -> void:
	var existing := RenderingServer.global_shader_parameter_get_list()
	print("[0] pre-existing globals: %s" % str(existing))


func _add_globals() -> void:
	RenderingServer.global_shader_parameter_add(
		"water_time", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0)
	RenderingServer.global_shader_parameter_add(
		"water_sun_color", RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3(0.0, 0.0, 0.0))


func _remove_globals() -> void:
	RenderingServer.global_shader_parameter_remove("water_time")
	RenderingServer.global_shader_parameter_remove("water_sun_color")


func _build_render_target() -> void:
	if _vp != null:
		return
	_vp = SubViewport.new()
	_vp.size = Vector2i(64, 64)
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.transparent_bg = false
	add_child(_vp)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 2)
	cam.current = true
	_vp.add_child(cam)

	_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = SHADER_SRC
	_mat.shader = sh

	_mesh = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(100, 100)
	_mesh.mesh = quad
	_mesh.material_override = _mat
	_vp.add_child(_mesh)


# ---- Test 1: the realistic race -- shader exists before globals are registered ----
func _test_compile_then_add() -> void:
	_remove_globals()
	_build_render_target()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	print("[1] compile-then-add: shader created with globals ABSENT")
	_add_globals()
	RenderingServer.global_shader_parameter_set("water_time", 0.5)
	RenderingServer.global_shader_parameter_set("water_sun_color", Vector3(0.0, 1.0, 0.0))
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var px := _sample()
	var ok := px.r > 0.05 and px.g > 0.05
	print("    -> pixel %s  %s" % [_fmt(px), "RECOVERED" if ok else "STUCK (shader did not recompile)"])
	if not ok:
		_fail += 1
		print("    !! Plugin MUST register globals before any water material loads.")


# ---- Test 2: globals present before the shader is created ----
func _test_add_then_compile() -> void:
	_remove_globals()
	if _mesh != null:
		_mesh.queue_free()
		_mesh = null
	await RenderingServer.frame_post_draw

	_add_globals()
	RenderingServer.global_shader_parameter_set("water_time", 0.5)
	RenderingServer.global_shader_parameter_set("water_sun_color", Vector3(0.0, 1.0, 0.0))

	_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = SHADER_SRC
	_mat.shader = sh
	_mesh = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(100, 100)
	_mesh.mesh = quad
	_mesh.material_override = _mat
	_vp.add_child(_mesh)

	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var px := _sample()
	var ok := px.r > 0.05 and px.g > 0.05
	print("[2] add-then-compile: pixel %s  %s" % [_fmt(px), "OK" if ok else "FAIL"])
	if not ok:
		_fail += 1


# ---- Test 3: does changing a global actually move the pixel? ----
func _test_value_propagation() -> void:
	var readings := []
	for v in [0.0, 0.25, 0.5, 1.0]:
		RenderingServer.global_shader_parameter_set("water_time", v)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		readings.append({"set": v, "got": _sample().r})

	print("[3] value propagation (water_time -> ALBEDO.r):")
	var monotonic := true
	for i in readings.size():
		print("      set %.2f -> pixel %.4f" % [readings[i]["set"], readings[i]["got"]])
		if i > 0 and readings[i]["got"] <= readings[i - 1]["got"]:
			monotonic = false
	print("    -> %s" % ("monotonic, values reach the shader" if monotonic else "NOT monotonic - FAIL"))
	if not monotonic:
		_fail += 1


# ---- Test 4: is the registration persisted to project.godot? ----
func _probe_persistence() -> void:
	var in_settings := ProjectSettings.has_setting("shader_globals/water_time")
	print("[4] persistence: ProjectSettings has 'shader_globals/water_time' = %s" % in_settings)
	print("    -> registration is %s; plugin must re-register every run." % (
		"PERSISTED" if in_settings else "RUNTIME-ONLY"))
	print("    current global list: %s" % str(RenderingServer.global_shader_parameter_get_list()))


func _sample() -> Color:
	var img := _vp.get_texture().get_image()
	return img.get_pixel(img.get_width() / 2, img.get_height() / 2)


func _fmt(c: Color) -> String:
	return "(r=%.4f g=%.4f b=%.4f)" % [c.r, c.g, c.b]
