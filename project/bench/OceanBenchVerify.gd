# Phase 0 sanity check: proves the benchmark is measuring a frame full of water.
# Renders the same camera setup OceanBench.gd uses, saves a PNG per pitch, and
# reports what fraction of the frame the ocean actually covers (by diffing each
# shot against the same frame with the ocean disabled).
extends Node

const PITCHES := [-4.0, -20.0, -60.0]
const RES := Vector2i(1280, 800)
const SETTLE_FRAMES := 45

var _terrain: Pasture3D
var _camera: Camera3D
var _sun: DirectionalLight3D
var _out_dir := ""

var _steps: Array = []
var _step := -1
var _wait := 0
var _sky_shots := {}


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	DisplayServer.window_set_size(RES)
	_out_dir = OS.get_environment("BENCH_OUT")
	if _out_dir == "":
		_out_dir = "user://"
	_build_scene()

	# Capture sky-only first so ocean coverage can be measured by difference.
	for p in PITCHES:
		_steps.append({"pitch": p, "ocean": false})
	for p in PITCHES:
		_steps.append({"pitch": p, "ocean": true})

	print("=== Ocean coverage verification ===")
	print("output dir: %s" % _out_dir)
	_next()


func _build_scene() -> void:
	var env := Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-40.0, 30.0, 0.0)
	_sun.shadow_enabled = false
	add_child(_sun)

	_camera = Camera3D.new()
	_camera.position = Vector3(0.0, 30.0, 0.0)
	_camera.far = 20000.0
	_camera.current = true
	add_child(_camera)

	_terrain = Pasture3D.new()
	_terrain.ocean_material = load("res://bench/legacy/M_ocean.tres")
	_terrain.ocean_enabled = true
	_terrain.ocean_light_target = _sun
	_terrain.clipmap_target = _camera
	_terrain.render_layers = 1 << 4
	_terrain.ocean_render_layers = 1
	_camera.cull_mask = 1
	add_child(_terrain)


func _next() -> void:
	_step += 1
	if _step >= _steps.size():
		print("=== DONE ===")
		get_tree().quit()
		return
	var s: Dictionary = _steps[_step]
	_camera.rotation_degrees = Vector3(s["pitch"], 0.0, 0.0)
	_terrain.ocean_enabled = s["ocean"]
	_wait = SETTLE_FRAMES


func _process(_d: float) -> void:
	if _step < 0 or _step >= _steps.size():
		return
	_wait -= 1
	if _wait > 0:
		return
	if _wait == 0:
		await RenderingServer.frame_post_draw
		_capture()
		_next()


func _capture() -> void:
	var s: Dictionary = _steps[_step]
	var img := get_viewport().get_texture().get_image()
	var key := str(s["pitch"])
	if not s["ocean"]:
		_sky_shots[key] = img
		return

	var path := "%s/ocean_pitch%s.png" % [_out_dir, str(int(s["pitch"]))]
	img.save_png(path)

	var sky_img: Image = _sky_shots[key]
	var differing := 0
	var total := 0
	# Sample on a grid; full per-pixel compare is needless here.
	for y in range(0, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			total += 1
			var a := img.get_pixel(x, y)
			var b := sky_img.get_pixel(x, y)
			if abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) > 0.02:
				differing += 1
	var pct := 100.0 * float(differing) / float(total)
	print("pitch %5.1f  ocean coverage %5.1f%% of frame  ->  %s" % [s["pitch"], pct, path])
