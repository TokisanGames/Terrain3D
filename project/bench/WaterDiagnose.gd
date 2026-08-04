# Pasture3D Water — one-variable-at-a-time capture, for diagnosing a visual defect.
#
# Not a gate. The Phase 5 A/B captures came back with rust-coloured speckle, white
# aliasing speckle and flat slabs along the horizon, and the three plausible causes
# (the new geometry defaults, the new presets, the detail/foam layers) all changed
# in the same phase. This renders the same frozen frame with exactly one thing
# moved per image so the cause is read off rather than argued about.
#
# Run:  Godot_v4.7-stable_win64_console.exe --path project bench/WaterDiagnose.tscn
extends Node

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const OCEAN_HIGH := WATER_DIR + "M_water_ocean.tres"
const BENCH_RES := Vector2i(1280, 800)

var _out_dir := ""
var _terrain: Pasture3D
var _mat: ShaderMaterial


func _ready() -> void:
	_out_dir = OS.get_environment("BENCH_OUT")
	if _out_dir == "":
		_out_dir = "user://"
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	DisplayServer.window_set_size(BENCH_RES)

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
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-38, 130, 0)
	sun.shadow_enabled = false
	root.add_child(sun)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 30, 0)
	cam.rotation_degrees = Vector3(-20, 0, 0)
	cam.far = 20000.0
	cam.cull_mask = 1
	cam.current = true
	root.add_child(cam)

	_mat = load(OCEAN_HIGH)
	_terrain = Pasture3D.new()
	_terrain.ocean_material = _mat
	_terrain.ocean_enabled = true
	_terrain.ocean_light_target = sun
	_terrain.ocean_wave_count = 8
	_terrain.ocean_wave_direction = 20.0
	_terrain.ocean_wave_spread = 28.0
	_terrain.ocean_wave_amplitude = 1.6
	_terrain.ocean_wave_length_max = 137.0
	_terrain.ocean_wave_steepness = 0.35
	_terrain.ocean_wave_loop_period = 120.0
	_terrain.render_layers = 1 << 4
	_terrain.ocean_render_layers = 1
	root.add_child(_terrain)

	# Let physics run long enough for the clipmap to build and the sun globals to be
	# written, THEN freeze. Freezing first is how the Phase 4 gate measured a
	# half-built scene (§8.5 finding 4).
	for i in 20:
		await get_tree().physics_frame
	_terrain.set_physics_process(false)
	RenderingServer.global_shader_parameter_set("water_time", 37.5)
	RenderingServer.global_shader_parameter_set("water_time_period", 120.0)

	print("sun globals: dir=%s color=%s" % [
		str(RenderingServer.global_shader_parameter_get("water_sun_direction")),
		str(RenderingServer.global_shader_parameter_get("water_sun_color"))])

	# Baseline: exactly what the Phase 5 gate captured.
	await _shot("00_baseline")

	# The detail strength sweep. The texture's decoded slope has rms 0.277 PER
	# LAYER and reaches 1.0, so at detail_strength 1.0 with two layers the detail
	# alone contributes ~0.39 rms slope with excursions past 2.0 -- normals tilted
	# far enough to point the reflection vector under the horizon, which is where
	# the rust colour comes from (it is the procedural sky's ground hemisphere).
	for s in [0.15, 0.25, 0.35, 0.5]:
		_mat.set_shader_parameter("detail_strength", s)
		await _shot("00_strength_%03d" % int(s * 100.0))
	_mat.set_shader_parameter("detail_strength", 1.0)

	# 1. Geometry. If the slabs and the flatness are the q6 defaults, this restores
	#    the old look; if they persist, geometry is not the cause.
	_terrain.ocean_vertex_spacing = 4.0
	_terrain.ocean_mesh_lods = 7
	await _shot("01_old_geometry")
	_terrain.ocean_vertex_spacing = 1.0
	_terrain.ocean_mesh_lods = 9

	# 2. The detail texture, which is the only thing on the surface with enough
	#    spatial frequency to speckle.
	_mat.set_shader_parameter("detail_strength", 0.0)
	await _shot("02_no_detail")
	_mat.set_shader_parameter("detail_strength", 1.0)

	# 3. Foam, which is the only layer that adds a colour the water does not have.
	_mat.set_shader_parameter("foam_crest_amount", 0.0)
	_mat.set_shader_parameter("foam_shore_amount", 0.0)
	await _shot("03_no_foam")
	_mat.set_shader_parameter("foam_crest_amount", 1.0)
	_mat.set_shader_parameter("foam_shore_amount", 0.8)

	# 4. Crest foam alone, then shore foam alone.
	_mat.set_shader_parameter("foam_shore_amount", 0.0)
	await _shot("04_crest_foam_only")
	_mat.set_shader_parameter("foam_shore_amount", 0.8)
	_mat.set_shader_parameter("foam_crest_amount", 0.0)
	await _shot("05_shore_foam_only")
	_mat.set_shader_parameter("foam_crest_amount", 1.0)

	# 6. Scattering, the other additive term.
	_mat.set_shader_parameter("scatter_strength", 0.0)
	await _shot("06_no_scatter")
	_mat.set_shader_parameter("scatter_strength", 3.5)

	# 7. Geometry only, no shading at all: says whether the WAVES are right,
	#    independent of everything above.
	_terrain.ocean_material = _variant(
		"cull_disabled, depth_draw_never, diffuse_lambert, specular_schlick_ggx,"
		+ " skip_vertex_transform, unshaded", ["WATER_DEBUG_SURFACE"])
	await _shot("07_debug_surface")

	# 8. cull_back instead of cull_disabled, at the shipped detail strength.
	#    Hypothesis for the residual dark dashes: the water is depth_draw_never, so
	#    it does not occlude itself, and cull_disabled therefore draws the BACK
	#    faces of wave crests that a solid surface would have hidden. The shader
	#    flips the normal on !FRONT_FACING -- correct for a camera under the water,
	#    wrong for the far side of a crest seen from above -- so those fragments
	#    shade with a downward normal and come out dark.
	#
	#    Phase 3 measured cull_back and cull_disabled at the same cost (§8.4), so if
	#    this is the cause the fix is free.
	for s in [0.25, 1.0]:
		var back := _variant(
			"cull_back, depth_draw_never, diffuse_lambert, specular_schlick_ggx,"
			+ " skip_vertex_transform",
			["WATER_DETAIL", "WATER_DEPTH_FADE", "WATER_FOAM_CREST", "WATER_FOAM_SHORE",
			"WATER_SCATTER"])
		back.set_shader_parameter("detail_strength", s)
		_terrain.ocean_material = back
		await _shot("08_cull_back_%03d" % int(s * 100.0))

		var both := _variant(
			"cull_disabled, depth_draw_never, diffuse_lambert, specular_schlick_ggx,"
			+ " skip_vertex_transform",
			["WATER_DETAIL", "WATER_DEPTH_FADE", "WATER_FOAM_CREST", "WATER_FOAM_SHORE",
			"WATER_SCATTER"])
		both.set_shader_parameter("detail_strength", s)
		_terrain.ocean_material = both
		await _shot("09_cull_disabled_%03d" % int(s * 100.0))

	print("done")
	get_tree().quit()


# Same includes the shipped wrappers use, assembled at runtime so a render mode or
# a feature define can be moved without editing a .gdshader on disk.
func _variant(p_modes: String, p_defines: PackedStringArray) -> ShaderMaterial:
	var code := "shader_type spatial;\nrender_mode " + p_modes + ";\n"
	code += "#define WATER_CLIPMAP\n#define WATER_WAVE_COUNT 8\n"
	for d in p_defines:
		code += "#define " + d + "\n"
	for inc in ["common", "waves", "surface", "shading"]:
		code += '#include "' + WATER_DIR + "water_" + inc + '.gdshaderinc"\n'
	var sh := Shader.new()
	sh.code = code
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("deep_color", Color(0.015, 0.05, 0.08))
	mat.set_shader_parameter("absorption", Vector3(0.35, 0.08, 0.05))
	mat.set_shader_parameter("detail_deriv", load(WATER_DIR + "T_water_deriv.png"))
	mat.set_shader_parameter("foam_tex", load(WATER_DIR + "T_water_foam.png"))
	return mat


func _shot(p_name: String) -> void:
	for i in 12:
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
			_out_dir.path_join("diag_%s.png" % p_name))
	print("  wrote diag_%s.png" % p_name)
