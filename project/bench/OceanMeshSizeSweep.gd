# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# What does Pasture3DOcean.mesh_size COST?
#
# The knob was capped at 64 by the Phase 2 extraction and has been restored to its
# pre-extraction ceiling of 256. That is a dial with no price list, so this is the price
# list: GPU time per setting, at the two camera pitches the water spec uses.
#
# WHAT mesh_size ACTUALLY DOES, because it is easy to get backwards. It is quads per
# clipmap tile. The clipmap is scale-invariant -- LOD0 spacing sets the unit and every ring
# doubles it -- so mesh_size does NOT make the water denser. Vertex spacing at the camera
# is vertex_spacing / 2^tessellation_level either way. What it changes is how FAR the
# finest ring reaches before the LOD halves:
#
#   lod0_radius = 2 * mesh_size * (vertex_spacing / 2^tessellation_level)
#   half_extent = lod0_radius * 2^(mesh_lods + tessellation_level - 1)
#
# So this is the knob for "the water goes coarse too close to the camera", and the cost of
# a step is the cost of covering four times the area at the same density -- it should scale
# with the square. Whether it does, and where that stops being affordable, is the question.
#
# Everything except mesh_size is held at what sculpting_2.tscn uses, so the numbers apply
# to that scene directly rather than to a fixture nobody ships.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/OceanMeshSizeSweep.tscn
extends Node

const OCEAN_HIGH := "res://addons/pasture_3d/extras/shaders/water/M_water_ocean.tres"
const RESOLUTION := Vector2i(1280, 800)
const LOOP_PERIOD := 120.0

# Matches the Phase 2 gate, so a number here is comparable with a number there.
const PERF_WARMUP := 60
const PERF_FRAMES := 150
const PERF_REPEATS := 3

# -4 is the maximum-coverage horizon view; -60 is where the ocean fills the frame (§8.1).
const PITCHES := [-4.0, -60.0]
const CAM_POS := Vector3(0.0, 12.0, 0.0)

# Held at sculpting_2.tscn's ocean.
const VERTEX_SPACING := 1.0
const TESSELLATION := 2
const MESH_LODS := 9

# 16 is the shipped default. 64 was the cap this work removed. 256 is the restored
# ceiling and the terrain's. The steps between are where the decision actually lives.
const SIZES := [16, 32, 48, 64, 96, 128, 192, 256]

# PHASE 2 -- the same detail radius bought at CONSTANT EXTENT.
#
# Phase 1 raises mesh_size alone, which raises the LOD0 radius and the total extent
# together: at 256 the ocean reaches 131 km, and nobody is looking at 131 km of water. The
# outer rings are being paid for and never seen.
#
# Here mesh_size and mesh_lods move in opposite directions to hold the shipped 8192 m
# half-extent, so each row is "the same ocean, with a bigger sharp region". With
# vertex_spacing 1.0 and tessellation 2 the arithmetic is exact:
#
#   lod0_radius = mesh_size / 2        half_extent = lod0_radius * 2^(mesh_lods + 1)
#
# so every doubling of mesh_size buys back exactly one ring. Powers of two only, because a
# row that missed the target extent would be comparing two things at once.
const EXTENT_CONFIGS := [
	{"size": 16, "lods": 9},   # the shipped config, and the drift check against phase 1
	{"size": 32, "lods": 8},
	{"size": 64, "lods": 7},
	{"size": 128, "lods": 6},
	{"size": 256, "lods": 5},
]

var _results: Array = []
var _extent_results: Array = []


func _ready() -> void:
	get_viewport().size = RESOLUTION
	# Without this every viewport_get_measured_render_time_gpu() returns 0.0 -- silently,
	# and a table of zeros is a sweep that measured nothing while looking like it ran.
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_run()


func _run() -> void:
	print("\n=== Pasture3DOcean mesh_size sweep ===")
	print("%s | %s | %dx%d" % [
			Engine.get_version_info()["string"],
			RenderingServer.get_video_adapter_name(), RESOLUTION.x, RESOLUTION.y])
	print("held: vertex_spacing=%.2f tessellation_level=%d mesh_lods=%d (sculpting_2.tscn)" % [
			VERTEX_SPACING, TESSELLATION, MESH_LODS])
	var lod0_spacing: float = VERTEX_SPACING / pow(2.0, TESSELLATION)
	print("LOD0 vertex spacing is %.3f m at every row -- mesh_size moves the LOD0 BOUNDARY,\n"
			% lod0_spacing + "not the density.\n")

	# Split into phases you can run separately: both together is ~26 timed configs and
	# several minutes, and a harness that cannot be run in pieces gets run less often.
	var phase := "all"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--phase="):
			phase = arg.trim_prefix("--phase=")

	if phase == "1" or phase == "all":
		_sweep_mesh_size()
		await _sweep_mesh_size_body()
	if phase == "2" or phase == "all":
		await _sweep_constant_extent()

	_verdict()
	get_tree().quit(0)


func _sweep_mesh_size() -> void:
	print("### PHASE 1 -- mesh_size alone (LOD0 radius AND extent both grow)\n")


func _sweep_mesh_size_body() -> void:
	for pitch in PITCHES:
		print("-- camera pitch %.0f deg --" % pitch)
		print("  %-6s %10s %12s %11s %11s %9s" % [
				"size", "LOD0 r(m)", "half ext(km)", "tris(M)", "gpu ms", "vs 16"])
		var baseline := 0.0
		for size in SIZES:
			var r: Dictionary = await _measure(size, pitch)
			if size == SIZES[0]:
				baseline = r["ms"]
			var factor: String = "--" if size == SIZES[0] \
					else "%.2fx" % (r["ms"] / maxf(baseline, 1e-6))
			print("  %-6d %10.1f %12.2f %11.2f %11.4f %9s" % [
					size, r["lod0_radius"], r["half_extent"] / 1000.0,
					r["tris"] / 1000000.0, r["ms"], factor])
			_results.append(r)
		print("")


## Phase 2: hold the extent, buy detail radius by trading rings for tile size.
func _sweep_constant_extent() -> void:
	print("### PHASE 2 -- constant extent (mesh_lods drops as mesh_size rises)\n")
	for pitch in PITCHES:
		print("-- camera pitch %.0f deg --" % pitch)
		print("  %-6s %6s %10s %12s %11s %11s %9s" % [
				"size", "lods", "LOD0 r(m)", "half ext(km)", "tris(M)", "gpu ms", "vs 16/9"])
		var baseline := 0.0
		for cfg in EXTENT_CONFIGS:
			var r: Dictionary = await _measure(cfg["size"], pitch, cfg["lods"])
			if cfg == EXTENT_CONFIGS[0]:
				baseline = r["ms"]
			var factor: String = "--" if cfg == EXTENT_CONFIGS[0] \
					else "%.2fx" % (r["ms"] / maxf(baseline, 1e-6))
			print("  %-6d %6d %10.1f %12.2f %11.2f %11.4f %9s" % [
					cfg["size"], cfg["lods"], r["lod0_radius"], r["half_extent"] / 1000.0,
					r["tris"] / 1000000.0, r["ms"], factor])
			_extent_results.append(r)
		# CONTROL -- every row must have landed on the same extent, or this is phase 1
		# again with extra steps.
		var extents: Array = _extent_results.filter(func(x): return x["pitch"] == pitch) \
				.map(func(x): return snappedf(x["half_extent"], 1.0))
		var uniform: bool = extents.all(func(e): return is_equal_approx(e, extents[0]))
		print("  CONTROL, every row at the same half extent: %s (%s m)" % [
				uniform, extents[0] if not extents.is_empty() else "n/a"])
		print("")


func _measure(p_size: int, p_pitch: float, p_lods: int = MESH_LODS) -> Dictionary:
	var root := _make_world(p_pitch)
	var ocean := _make_ocean(root)
	ocean.mesh_size = p_size
	ocean.vertex_spacing = VERTEX_SPACING
	ocean.tessellation_level = TESSELLATION
	ocean.mesh_lods = p_lods
	# The setters clamp silently. A row that asked for 256 and got 64 would look like a
	# flat cost curve, which is the exact conclusion this sweep exists to draw.
	if ocean.mesh_size != p_size or ocean.mesh_lods != p_lods:
		push_error("Pasture3DOcean clamped the config: asked %d/%d, got %d/%d" % [
				p_size, p_lods, ocean.mesh_size, ocean.mesh_lods])
	# Frozen, so every config draws the same instant of the same wave field and a
	# difference is geometry rather than where the swell happened to be.
	RenderingServer.global_shader_parameter_set("water_time", 30.0)
	RenderingServer.global_shader_parameter_set("water_time_period", LOOP_PERIOD)
	for i in 10:
		await RenderingServer.frame_post_draw

	# One discarded pass, as the gate does: the first draw of a freshly built clipmap
	# stalls on pipeline setup that is not the geometry under test.
	var _discard: float = await _measure_ms()
	var samples: Array[float] = []
	for i in PERF_REPEATS:
		samples.append(await _measure_ms())
	samples.sort()

	var lod0_spacing: float = VERTEX_SPACING / pow(2.0, TESSELLATION)
	var lod0_radius: float = 2.0 * p_size * lod0_spacing
	var out := {
		"size": p_size,
		"lods": p_lods,
		"pitch": p_pitch,
		"ms": samples[samples.size() / 2],
		"lod0_radius": lod0_radius,
		"half_extent": lod0_radius * pow(2.0, p_lods + TESSELLATION - 1),
		"tris": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
	}
	root.queue_free()
	await get_tree().process_frame
	return out


func _measure_ms() -> float:
	var vp := get_viewport().get_viewport_rid()
	for i in PERF_WARMUP:
		await RenderingServer.frame_post_draw
	var samples: Array[float] = []
	for i in PERF_FRAMES:
		await RenderingServer.frame_post_draw
		var ms := RenderingServer.viewport_get_measured_render_time_gpu(vp)
		if ms > 0.0:
			samples.append(ms)
	samples.sort()
	return 0.0 if samples.is_empty() else samples[samples.size() / 2]


## Does the cost scale with the square, as the geometry says it must?
##
## Reported rather than asserted. This is a price list, not a gate -- there is no correct
## answer for "how many milliseconds of ocean is too many", only the user's frame budget.
## But a measured curve that does NOT follow area is a sign the sweep measured something
## other than what it thinks (a CPU bound, a cull, a config that never rebuilt), so the
## comparison against the analytic prediction is the check that these numbers mean anything.
func _verdict() -> void:
	# The sweep must be able to tell "the ocean is free" from "the clock was never
	# started". viewport_set_measure_render_time() off returns a clean 0.0 for every
	# sample, which reads as the former and is the latter.
	var all_rows: Array = _results + _extent_results
	var timed: Array = all_rows.filter(func(r): return r["ms"] > 0.0)
	if all_rows.is_empty() or timed.size() != all_rows.size():
		print("!! %d of %d rows measured 0.0000 ms -- GPU timing was not running." % [
				all_rows.size() - timed.size(), all_rows.size()])
		print("!! These numbers are not a price list. Fix the measurement before reading them.\n")
		return

	if not _extent_results.is_empty():
		print("=== detail radius per millisecond, at constant extent ===")
		print("The question this sweep exists for: what does a bigger sharp region cost when")
		print("you are NOT also buying ocean nobody looks at.\n")
		for pitch in PITCHES:
			var rows: Array = _extent_results.filter(func(r): return r["pitch"] == pitch)
			if rows.is_empty():
				continue
			var base: Dictionary = rows[0]
			print("  pitch %.0f (baseline %d/%d: %.1f m radius, %.4f ms):" % [
					pitch, base["size"], base["lods"], base["lod0_radius"], base["ms"]])
			for i in range(1, rows.size()):
				var r: Dictionary = rows[i]
				var d_ms: float = r["ms"] - base["ms"]
				print("    %3d/%d: %6.1f m radius (x%4.1f) for %+0.4f ms (%+.0f%%)" % [
						r["size"], r["lods"], r["lod0_radius"],
						r["lod0_radius"] / base["lod0_radius"], d_ms,
						100.0 * d_ms / maxf(base["ms"], 1e-6)])
			print("")

	if _results.is_empty():
		return
	print("=== cost vs the square law (phase 1) ===")
	print("mesh_size doubles -> LOD0 area quadruples, so a doubling should cost ~4x the")
	print("geometry. Deviation below means the ocean stopped being geometry-bound.\n")
	for pitch in PITCHES:
		var rows: Array = _results.filter(func(r): return r["pitch"] == pitch)
		print("  pitch %.0f:" % pitch)
		for i in range(1, rows.size()):
			var prev: Dictionary = rows[i - 1]
			var cur: Dictionary = rows[i]
			var size_ratio: float = float(cur["size"]) / float(prev["size"])
			var tri_ratio: float = cur["tris"] / maxf(prev["tris"], 1.0)
			var ms_ratio: float = cur["ms"] / maxf(prev["ms"], 1e-6)
			print("    %3d -> %3d (x%.2f size): tris x%.2f, ms x%.2f  [square law predicts x%.2f]" % [
					prev["size"], cur["size"], size_ratio, tri_ratio, ms_ratio,
					size_ratio * size_ratio])
		print("")


func _make_world(p_pitch: float) -> Node3D:
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
	cam.name = "Camera3D"
	cam.position = CAM_POS
	cam.rotation_degrees = Vector3(p_pitch, 0, 0)
	cam.far = 20000.0
	cam.cull_mask = 1
	cam.current = true
	root.add_child(cam)
	return root


func _make_ocean(p_root: Node3D) -> Pasture3DOcean:
	var manager := Pasture3DPoolManager.new()
	manager.loop_period = LOOP_PERIOD
	var profile := Pasture3DWaveProfile.new()
	profile.profile_name = &"ocean_default"
	profile.wave_count = 8
	profile.direction_deg = 20.0
	profile.spread_deg = 28.0
	profile.amplitude = 1.6
	profile.length_max = 137.0
	profile.steepness = 0.35
	var profiles: Array[Pasture3DWaveProfile] = [profile]
	manager.profiles = profiles
	p_root.add_child(manager)
	manager.sun_light = p_root.get_node("Sun")

	var ocean := Pasture3DOcean.new()
	ocean.material = load(OCEAN_HIGH)
	ocean.wave_profile = &"ocean_default"
	ocean.render_layers = 1
	ocean.clipmap_target = p_root.get_node("Camera3D")
	p_root.add_child(ocean)
	return ocean
