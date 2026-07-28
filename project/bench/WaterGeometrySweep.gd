# Pasture3D Water Spec — §11 q6, the LOD0 density decision.
#
# Phase 4 gate C measured the shipped ocean defaults sitting 22 cm below the
# analytic surface at a LOD0 cell centre, because 4 m vertex spacing against a
# 10.2 m shortest wavelength is a ratio of 2.54 where water_waves.gdshaderinc
# asks for 8. This sweeps the ways of fixing that and prices each one.
#
# The thing worth measuring rather than reasoning about is what density COSTS.
# A clipmap is scale-invariant: LOD0 spacing sets the unit, and every level
# doubles it, so halving the spacing does NOT multiply triangles by four -- it
# divides the ocean's total extent by two, and you buy the extent back with one
# more ring. Whether "one more ring" is cheap is an empirical question, so each
# config here is held to the SAME total extent and the triangle count and GPU
# time are read off the renderer.
#
# Two numbers per config decide it:
#   ratio  = L_min / spacing, the rule-of-thumb target of 8
#   sag    = how far the drawn surface falls below the analytic one
#
# The sag is reported at LOD0, LOD1 and LOD2 spacing, not just LOD0, because a
# clipmap can only ever satisfy the rule near the camera. Fixing LOD0 alone
# moves the error outward rather than removing it, and the honest question is
# how far out the agreement has to hold -- which for a buoyancy query is "as far
# as the things that float".
#
# Run:  Godot_v4.7-stable_win64_console.exe --path project bench/WaterGeometrySweep.tscn
extends Node

const WARMUP_FRAMES := 90
const MEASURE_FRAMES := 180

# Held constant so the configs are comparable. -4 is the maximum-coverage pitch
# for a horizon view and -60 is where the ocean fills the frame (§8.1).
const PITCHES := [-4.0, -60.0]
const RESOLUTION := Vector2i(1280, 800)

# (mesh_size, vertex_spacing, mesh_lods). Every row is chosen to land within a
# factor of ~1.3 of the shipped 8192 m half-extent, so the comparison is density
# against density and not density against how much ocean there is.
#
#   half_extent = 2 * mesh_size * spacing * 2^(lods-1)
#   lod0_radius = 2 * mesh_size * spacing
const CONFIGS := [
	{"name": "shipped", "mesh_size": 16, "spacing": 4.0, "lods": 7},
	{"name": "half", "mesh_size": 16, "spacing": 2.0, "lods": 8},
	{"name": "quarter", "mesh_size": 16, "spacing": 1.0, "lods": 9},
	{"name": "wide-half", "mesh_size": 32, "spacing": 2.0, "lods": 7},
	{"name": "wide-quarter", "mesh_size": 32, "spacing": 1.0, "lods": 8},
	{"name": "rule-of-8", "mesh_size": 32, "spacing": 1.25, "lods": 8},
]

var _terrain: Pasture3D
var _camera: Camera3D
var _sun: DirectionalLight3D

var _jobs: Array = []
var _job_index := -1
var _frames_left := 0
var _warming := true
var _samples: Array[float] = []
var _draw_calls := 0
var _primitives := 0
var _results: Array = []
var _geometry: Dictionary = {}


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(RESOLUTION)
	Engine.max_fps = 0
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

	_build_scene()

	print("=== Pasture3D water — LOD0 density sweep (spec §11 q6) ===")
	print("Godot %s | %s | %s" % [
		Engine.get_version_info().string,
		RenderingServer.get_video_adapter_name(),
		RenderingServer.get_current_rendering_method(),
	])
	print("")

	# The geometry half of the answer needs no rendering at all: it is parametric
	# on both sides, so it is computed up front and printed as its own table.
	await get_tree().physics_frame
	_measure_geometry()

	for cfg in CONFIGS:
		for pitch in PITCHES:
			_jobs.append({"cfg": cfg, "pitch": pitch})

	print("")
	print("--- cost, %dx%d, ocean filling the frame ---" % [RESOLUTION.x, RESOLUTION.y])
	print("config,pitch_deg,gpu_ms_median,gpu_ms_p95,draw_calls,primitives")
	_next_job()


func _build_scene() -> void:
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-40.0, 30.0, 0.0)
	_sun.light_energy = 1.0
	add_child(_sun)

	_camera = Camera3D.new()
	_camera.position = Vector3(0.0, 30.0, 0.0)
	_camera.far = 20000.0
	_camera.current = true
	add_child(_camera)

	# The NEW shader, not the shipped M_ocean.tres -- this question is about the
	# replacement's geometry defaults, and the legacy material has no wave table to
	# read L_min off in the first place.
	var mat := ShaderMaterial.new()
	mat.shader = load("res://addons/pasture_3d/extras/shaders/water/water_ocean.gdshader")
	mat.set_shader_parameter("deep_color", Color(0.02, 0.09, 0.14))
	mat.set_shader_parameter("absorption", Vector3(0.35, 0.08, 0.05))

	_terrain = Pasture3D.new()
	_terrain.ocean_material = mat
	_terrain.ocean_enabled = true
	_terrain.ocean_light_target = _sun
	_terrain.clipmap_target = _camera
	# The wave knobs the sag depends on, pinned to the ocean defaults so the sweep
	# varies geometry and nothing else.
	_terrain.ocean_wave_count = 8
	_terrain.ocean_wave_direction = 20.0
	_terrain.ocean_wave_spread = 28.0
	_terrain.ocean_wave_amplitude = 1.6
	_terrain.ocean_wave_length_max = 137.0
	_terrain.ocean_wave_steepness = 0.35
	# Only the ocean is under measurement.
	_terrain.render_layers = 1 << 4
	_terrain.ocean_render_layers = 1
	_camera.cull_mask = 1
	add_child(_terrain)


# Sag is parametric on both sides -- the drawn surface at a cell centre is the
# mean of the four displaced corners, the analytic one is the displaced centre.
# No camera, no rasteriser, no shading, so this is exact and needs no averaging.
func _sag_at(p_spacing: float) -> float:
	var worst := 0.0
	for i in 40:
		for j in 40:
			var u := Vector2(float(i) * p_spacing * 3.0, float(j) * p_spacing * 3.0)
			var c0: Vector3 = _terrain.get_water_surface_point(u)
			var c1: Vector3 = _terrain.get_water_surface_point(u + Vector2(p_spacing, 0.0))
			var c2: Vector3 = _terrain.get_water_surface_point(u + Vector2(0.0, p_spacing))
			var c3: Vector3 = _terrain.get_water_surface_point(u + Vector2(p_spacing, p_spacing))
			var drawn: Vector3 = (c0 + c1 + c2 + c3) * 0.25
			var exact: Vector3 = _terrain.get_water_surface_point(
					u + Vector2(p_spacing, p_spacing) * 0.5)
			worst = maxf(worst, absf(exact.y - drawn.y))
	return worst


func _measure_geometry() -> void:
	var table: PackedVector4Array = _terrain.ocean_material.get_shader_parameter("_waves")
	var l_min := INF
	for w in table:
		if w.z > 0.0:
			l_min = minf(l_min, w.w)
	print("shortest wavelength in the table: %.2f m (rule of thumb wants spacing <= %.2f m)" % [
		l_min, l_min / 8.0])
	print("")
	print("--- fidelity and reach (no rendering involved) ---")
	print("config,mesh_size,spacing,lods,ratio,lod0_radius_m,half_extent_m,"
		+ "sag_lod0_cm,sag_lod1_cm,sag_lod2_cm")

	for cfg in CONFIGS:
		var spacing: float = cfg["spacing"]
		var ms: int = cfg["mesh_size"]
		var lods: int = cfg["lods"]
		var lod0_radius := 2.0 * float(ms) * spacing
		var half_extent := lod0_radius * pow(2.0, float(lods - 1))
		var row := {
			"name": cfg["name"],
			"ratio": l_min / spacing,
			"lod0_radius": lod0_radius,
			"half_extent": half_extent,
			"sag0": _sag_at(spacing) * 100.0,
			"sag1": _sag_at(spacing * 2.0) * 100.0,
			"sag2": _sag_at(spacing * 4.0) * 100.0,
		}
		_geometry[cfg["name"]] = row
		print("%s,%d,%.2f,%d,%.2f,%.0f,%.0f,%.1f,%.1f,%.1f" % [
			cfg["name"], ms, spacing, lods, row["ratio"],
			lod0_radius, half_extent, row["sag0"], row["sag1"], row["sag2"]])


func _next_job() -> void:
	_job_index += 1
	if _job_index >= _jobs.size():
		_report()
		get_tree().quit()
		return

	var job: Dictionary = _jobs[_job_index]
	var cfg: Dictionary = job["cfg"]
	_camera.rotation_degrees = Vector3(job["pitch"], 0.0, 0.0)
	_terrain.ocean_mesh_size = cfg["mesh_size"]
	_terrain.ocean_vertex_spacing = cfg["spacing"]
	_terrain.ocean_mesh_lods = cfg["lods"]

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
	var cfg: Dictionary = job["cfg"]
	var row := {
		"name": cfg["name"],
		"pitch": job["pitch"],
		"gpu_median": _percentile(_samples, 0.5),
		"gpu_p95": _percentile(_samples, 0.95),
		"draws": _draw_calls,
		"prims": _primitives,
	}
	_results.append(row)
	print("%s,%.1f,%.4f,%.4f,%d,%d" % [
		row["name"], row["pitch"], row["gpu_median"], row["gpu_p95"],
		row["draws"], row["prims"]])
	_next_job()


func _percentile(values: Array[float], q: float) -> float:
	if values.is_empty():
		return -1.0
	var sorted := values.duplicate()
	sorted.sort()
	var idx := int(round(q * float(sorted.size() - 1)))
	return sorted[clampi(idx, 0, sorted.size() - 1)]


func _report() -> void:
	# The whole point of the sweep is the trade, so print it as a trade: what each
	# config buys in fidelity against what it costs, both relative to shipped.
	var base_gpu := 0.0
	var base_prims := 0
	for r in _results:
		if r["name"] == "shipped" and is_equal_approx(r["pitch"], -60.0):
			base_gpu = r["gpu_median"]
			base_prims = r["prims"]
	var base_sag: float = _geometry["shipped"]["sag0"]

	print("")
	print("=== the trade, at -60 deg (ocean filling the frame), vs shipped ===")
	print("config,ratio,sag_lod0_cm,sag_vs_shipped,gpu_ms,gpu_delta_ms,gpu_vs_shipped,prims_vs_shipped")
	for cfg in CONFIGS:
		var name: String = cfg["name"]
		var g: Dictionary = _geometry[name]
		for r in _results:
			if r["name"] != name or not is_equal_approx(r["pitch"], -60.0):
				continue
			print("%s,%.2f,%.1f,%.2fx,%.4f,%+.4f,%.2fx,%.2fx" % [
				name, g["ratio"], g["sag0"], g["sag0"] / base_sag,
				r["gpu_median"], r["gpu_median"] - base_gpu,
				r["gpu_median"] / base_gpu if base_gpu > 0.0 else 0.0,
				float(r["prims"]) / float(base_prims) if base_prims > 0 else 0.0])
	print("")
	print("=== DONE ===")
