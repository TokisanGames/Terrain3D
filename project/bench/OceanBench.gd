# Pasture3D Water Spec — Phase 0 baseline harness.
#
# Isolates the legacy ocean shader's GPU cost. Builds a scene containing nothing but
# the ocean clipmap, a sky, and a sun, then sweeps resolution x camera pitch x shader
# config, reporting median GPU ms per viewport.
#
# Configs decompose the cost:
#   OFF      ocean_enabled = false                       -> sky + sun floor
#   FLAT     same clipmap geometry, unshaded flat colour  -> + geometry / draw calls / raster
#   NOREFR   legacy shader minus the screen_texture read  -> + wave math, depth, foam, scattering
#   LEGACY   legacy shader as shipped                     -> + backbuffer copy & refraction
#
# Run:  Godot_v4.7-stable_win64_console.exe --path project bench/OceanBench.tscn
extends Node

const WARMUP_FRAMES := 90
const MEASURE_FRAMES := 240

const RESOLUTIONS := [Vector2i(1280, 800), Vector2i(2560, 1440)]
# Degrees below horizontal. -4 is the worst case: maximum ocean coverage and the
# most extreme minification, which is where the procedural noise aliases hardest.
const PITCHES := [-4.0, -20.0, -60.0]
const CONFIGS := ["OFF", "FLAT", "NOREFR", "LEGACY"]

var _terrain: Pasture3D
var _camera: Camera3D
var _sun: DirectionalLight3D

var _mat_legacy: ShaderMaterial
var _mat_norefr: ShaderMaterial
var _mat_flat: ShaderMaterial

var _jobs: Array = []
var _job_index := -1
var _frames_left := 0
var _warming := true
var _samples: Array[float] = []
var _draw_calls := 0
var _primitives := 0
var _results: Array = []


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

	_build_scene()
	_build_materials()

	for res in RESOLUTIONS:
		for pitch in PITCHES:
			for cfg in CONFIGS:
				_jobs.append({"res": res, "pitch": pitch, "cfg": cfg})

	print("=== Pasture3D ocean Phase 0 baseline ===")
	print("Godot %s | %s | %s" % [
		Engine.get_version_info().string,
		RenderingServer.get_video_adapter_name(),
		RenderingServer.get_current_rendering_method(),
	])
	print("warmup=%d measure=%d jobs=%d" % [WARMUP_FRAMES, MEASURE_FRAMES, _jobs.size()])
	print("")
	print("res,pitch_deg,config,gpu_ms_median,gpu_ms_p95,cpu_ms_median,draw_calls,primitives")
	_next_job()


func _build_scene() -> void:
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_energy_multiplier = 1.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	# Reflections come off the radiance map, so it must be present and real-time-ish.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-40.0, 30.0, 0.0)
	_sun.light_energy = 1.0
	_sun.shadow_enabled = false  # ocean shader is shadows_disabled; keep the floor clean
	add_child(_sun)

	_camera = Camera3D.new()
	_camera.position = Vector3(0.0, 30.0, 0.0)
	_camera.far = 20000.0
	_camera.current = true
	add_child(_camera)

	_terrain = Pasture3D.new()
	_terrain.ocean_enabled = true
	_terrain.ocean_light_target = _sun
	_terrain.clipmap_target = _camera
	# Terrain itself must not render: only the ocean is under measurement.
	_terrain.render_layers = 1 << 4
	_terrain.ocean_render_layers = 1
	_camera.cull_mask = 1
	add_child(_terrain)


func _build_materials() -> void:
	_mat_legacy = load("res://addons/pasture_3d/extras/shaders/M_ocean.tres")

	# Same parameters, screen_texture read removed.
	_mat_norefr = _mat_legacy.duplicate(true)
	_mat_norefr.shader = load("res://bench/ocean_shader_norefract.gdshader")

	_mat_flat = ShaderMaterial.new()
	_mat_flat.shader = load("res://bench/ocean_shader_flat.gdshader")


func _next_job() -> void:
	_job_index += 1
	if _job_index >= _jobs.size():
		_report()
		get_tree().quit()
		return

	var job: Dictionary = _jobs[_job_index]
	DisplayServer.window_set_size(job["res"])
	_camera.rotation_degrees = Vector3(job["pitch"], 0.0, 0.0)

	match job["cfg"]:
		"OFF":
			_terrain.ocean_enabled = false
		"FLAT":
			_terrain.ocean_material = _mat_flat
			_terrain.ocean_enabled = true
		"NOREFR":
			_terrain.ocean_material = _mat_norefr
			_terrain.ocean_enabled = true
		"LEGACY":
			_terrain.ocean_material = _mat_legacy
			_terrain.ocean_enabled = true

	_samples.clear()
	_warming = true
	_frames_left = WARMUP_FRAMES


func _process(_delta: float) -> void:
	if _job_index < 0 or _job_index >= _jobs.size():
		return

	_frames_left -= 1
	if _warming:
		if _frames_left <= 0:
			_warming = false
			_frames_left = MEASURE_FRAMES
		return

	var vp := get_viewport().get_viewport_rid()
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(vp)
	if gpu > 0.0:
		_samples.append(gpu)
	_draw_calls = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	_primitives = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)

	if _frames_left <= 0:
		_finish_job()


func _finish_job() -> void:
	var job: Dictionary = _jobs[_job_index]
	var cpu := RenderingServer.viewport_get_measured_render_time_cpu(get_viewport().get_viewport_rid())
	var row := {
		"res": "%dx%d" % [job["res"].x, job["res"].y],
		"pitch": job["pitch"],
		"cfg": job["cfg"],
		"gpu_median": _percentile(_samples, 0.5),
		"gpu_p95": _percentile(_samples, 0.95),
		"cpu_median": cpu,
		"draws": _draw_calls,
		"prims": _primitives,
	}
	_results.append(row)
	print("%s,%.1f,%s,%.4f,%.4f,%.4f,%d,%d" % [
		row["res"], row["pitch"], row["cfg"],
		row["gpu_median"], row["gpu_p95"], row["cpu_median"],
		row["draws"], row["prims"],
	])
	_next_job()


func _percentile(values: Array[float], q: float) -> float:
	if values.is_empty():
		return -1.0
	var sorted := values.duplicate()
	sorted.sort()
	var idx := int(round(q * float(sorted.size() - 1)))
	return sorted[clampi(idx, 0, sorted.size() - 1)]


func _find(res: String, pitch: float, cfg: String) -> Dictionary:
	for r in _results:
		if r["res"] == res and is_equal_approx(r["pitch"], pitch) and r["cfg"] == cfg:
			return r
	return {}


func _report() -> void:
	print("")
	print("=== Cost decomposition (GPU ms, median) ===")
	print("res,pitch_deg,geometry,shader_no_refract,refraction,ocean_total")
	for res in RESOLUTIONS:
		var rs := "%dx%d" % [res.x, res.y]
		for pitch in PITCHES:
			var off := _find(rs, pitch, "OFF")
			var flat := _find(rs, pitch, "FLAT")
			var nor := _find(rs, pitch, "NOREFR")
			var leg := _find(rs, pitch, "LEGACY")
			if off.is_empty() or flat.is_empty() or nor.is_empty() or leg.is_empty():
				continue
			print("%s,%.1f,%.4f,%.4f,%.4f,%.4f" % [
				rs, pitch,
				flat["gpu_median"] - off["gpu_median"],
				nor["gpu_median"] - flat["gpu_median"],
				leg["gpu_median"] - nor["gpu_median"],
				leg["gpu_median"] - off["gpu_median"],
			])
	print("")
	print("=== DONE ===")
