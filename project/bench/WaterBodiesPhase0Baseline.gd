# Pasture3D Water Bodies — Phase 0 baseline (spec §11, PASTURE3D_WATER_BODIES_SPEC.md).
#
# Phase 2 extracts the ocean out of Pasture3D into an Ocean3D node and rewires the
# clipmap mesher underneath BOTH the ocean and the terrain. Its gate is "pixel- and
# millisecond-neutral vs Phase 0", and that claim cannot be made against a memory of
# what the ocean used to look like. This run is the record it is made against.
#
# Nothing here changes any source file. It writes:
#   <BENCH_OUT>/phase0_baseline.json   the numbers Phase 2 diffs against
#   <BENCH_OUT>/phase0_*.png           the captures Phase 2 image-diffs against
#
# Run it TWICE. The first run writes the baseline; the second finds the file and
# compares against it, which is the only way "reproducible across two runs" gets
# tested by a process rather than asserted by a person. Delete the json to re-baseline.
#
# Criteria:
#   A. the clock is reconstructible -- two identical worlds reach the same water_time
#   B. the get_water_height/normal probe set, recorded; run twice in-process
#   C. CONTROL -- sea_level +1 m must move every height probe by exactly 1 m
#   D. cull behaviour vs sea level, recorded as on-screen coverage (§4.5's observable)
#   E. frame time for ocean high / ocean low / terrain clipmap, with the run-to-run
#      spread measured so Phase 2 knows what "neutral" is allowed to mean
#   F. six fixed camera captures, written and verified
#   G. cross-run comparison against a previously written baseline, if one exists
#
# Every criterion carries a control that must fail; see the header on each.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/WaterBodiesPhase0Baseline.tscn
extends Node

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const OCEAN_HIGH := WATER_DIR + "M_water_ocean.tres"
const OCEAN_LOW := WATER_DIR + "M_water_ocean_low.tres"
const DEMO_DATA := "res://demo/data"

const BENCH_RES := Vector2i(1280, 800)
const LOOP_PERIOD := 120.0
const PHYSICS_HZ := 60

# Matches WaterPhase5Gate so the two documents' numbers are comparable.
const PITCHES := [-4.0, -20.0, -60.0]
const PERF_WARMUP := 60
const PERF_FRAMES := 150
# How many times each frame-time configuration is measured. Three, because the
# point is not the number -- it is the SPREAD, which is what sets Phase 2's
# tolerance. One measurement cannot report a spread and would leave Phase 2
# comparing against a tolerance somebody invented.
const PERF_REPEATS := 3

# Ticks of physics run after the clock starts moving, before the probes are taken.
# t = PRIME + PROBE_TICKS[i] / PHYSICS_HZ, which is the whole reason these are
# constants and not "however many frames it took".
const PROBE_TICKS := [60, 120, 240]

# Probe lattice: 8x8 over +/- 4 km, which spans several of the longest wave (137 m)
# and lands nowhere near a multiple of it.
const PROBE_N := 8
const PROBE_SPAN := 4000.0

var _fail := 0
var _out_dir := ""
var _baseline := {}
var _prior = null # Dictionary if a previous run left one, else null


func _ready() -> void:
	var bail := Timer.new()
	bail.wait_time = 900.0
	bail.one_shot = true
	bail.timeout.connect(func():
		push_error("baseline run timed out")
		get_tree().quit(2))
	add_child(bail)
	bail.start()

	_out_dir = OS.get_environment("BENCH_OUT")
	if _out_dir == "":
		_out_dir = "user://"

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	Engine.physics_ticks_per_second = PHYSICS_HZ
	DisplayServer.window_set_size(BENCH_RES)
	# Without this every viewport_get_measured_render_time_gpu() reads exactly 0.0,
	# which is not an error and not a zero-cost frame -- it is the timer being off.
	# The empty-frame control in [E] is what catches it if this line is ever lost.
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

	print("=== Pasture3D Water Bodies — Phase 0 baseline ===")
	print("Godot %s | %s | %s" % [
		Engine.get_version_info().string,
		RenderingServer.get_video_adapter_name(),
		RenderingServer.get_current_rendering_method()])
	print("out: %s" % ProjectSettings.globalize_path(_out_dir))
	print("")

	_load_prior()

	_baseline["meta"] = {
		"spec": "PASTURE3D_WATER_BODIES_SPEC.md phase 0",
		"godot": Engine.get_version_info().string,
		"adapter": RenderingServer.get_video_adapter_name(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"resolution": [BENCH_RES.x, BENCH_RES.y],
		"physics_hz": PHYSICS_HZ,
		"loop_period": LOOP_PERIOD,
		"taken": Time.get_datetime_string_from_system(),
	}

	await _a_clock_reconstructible()
	await _b_probe_set()
	await _d_cull_vs_sea_level()
	await _e_frame_times()
	await _f_captures()
	_g_compare_prior()

	_write_baseline()

	print("")
	print("=== PHASE 0 BASELINE %s ===" % ("RECORDED" if _fail == 0 else "FAILED (%d)" % _fail))
	if _prior == null and _fail == 0:
		print("Run this scene a SECOND time — criterion G is vacuous until a prior")
		print("baseline exists to compare against.")
	get_tree().quit(0 if _fail == 0 else 1)


# ---- A: the clock is reconstructible -----------------------------------------
# Every probe below is taken at a frozen water_time, and the value of that clock is
# not something this harness can set: _water_time is a private C++ member advanced
# by __physics_process, so the only handle on it is "how many physics ticks have
# run since the node started processing". If that count is not deterministic, then
# neither is any probe, and Phase 2 would be diffing two different instants and
# calling the difference a regression.
#
# So it is measured, not assumed: two identically built worlds, primed and advanced
# identically, must reach the same clock. The control is the same comparison across
# a deliberately different tick count, which must differ -- otherwise "the two match"
# would also be what a clock stuck at zero looks like.
func _a_clock_reconstructible() -> void:
	print("[A] the frozen clock is reconstructible:")
	var t: Array[float] = []
	var primes: Array[int] = []
	for run in 2:
		var root := _make_world(Vector3(0, 30, 0), -20.0)
		var terrain := _make_ocean(root)
		var prime := await _prime(terrain)
		await _advance(terrain, PROBE_TICKS[0])
		t.append(terrain.get_water_time())
		primes.append(prime)
		root.queue_free()
		await _settle()

	print("    priming ticks: %d / %d" % [primes[0], primes[1]])
	print("    water_time after %d ticks: %.9f / %.9f" % [PROBE_TICKS[0], t[0], t[1]])

	if t[0] <= 0.0:
		_fail += 1
		print("    !! the clock never advanced; every probe below is two reads of t=0")
	elif absf(t[0] - t[1]) > 1e-6:
		_fail += 1
		print("    !! two identical worlds reach different clocks, so the probe set is")
		print("       not reproducible and Phase 2 cannot diff against it")
	else:
		print("    -> identical to 1e-6 s")

	# The control. A different tick count must produce a different clock, or the
	# agreement above is the agreement of a number that never moves.
	var root2 := _make_world(Vector3(0, 30, 0), -20.0)
	var terrain2 := _make_ocean(root2)
	await _prime(terrain2)
	await _advance(terrain2, PROBE_TICKS[0] + 30)
	var t_other: float = terrain2.get_water_time()
	root2.queue_free()
	await _settle()
	print("    CONTROL, 30 ticks further on: %.9f (must differ by 0.5 s)" % t_other)
	if absf(t_other - t[0] - 0.5) > 1e-4:
		_fail += 1
		print("    !! the clock does not advance one tick per tick; PROBE_TICKS does not")
		print("       describe the instant these probes are taken at")

	_baseline["clock"] = {
		"prime_ticks": primes[0],
		"probe_ticks": PROBE_TICKS,
		"t_at_first_probe": t[0],
		"reproducible": absf(t[0] - t[1]) <= 1e-6,
	}


# ---- B: the probe set ---------------------------------------------------------
# What Phase 2 must not change: the surface get_water_height() reports, everywhere,
# at three instants, in the two configurations that add terms on top of the raw wave
# sum -- a domain origin 12 km out and a sea level of 300 m. Those two are exactly
# where an extraction can drop a term on one side, because in Phase 2 the ocean's
# sea level stops being a material uniform and becomes the node's Y (§6.1).
#
# Recorded to nine decimal places rather than graded. The grade happens in Phase 2.
#
# Two non-vacuity checks, because a lattice of identical numbers would compare
# perfectly against itself forever: the heights must have real spread (a flat plane
# would pass any diff), and the normals must not all be straight up.
func _b_probe_set() -> void:
	print("")
	print("[B] get_water_height / get_water_normal probe set:")
	var cases := [
		["origin_0_sea_0", Vector3.ZERO, 0.0],
		["origin_12km_sea_300", Vector3(12000.0, 0.0, -8000.0), 300.0],
	]
	var probes := {}
	for case in cases:
		var name: String = case[0]
		var origin: Vector3 = case[1]
		var sea: float = case[2]

		var root := _make_world(Vector3(0, 30, 0), -20.0)
		var terrain := _make_ocean(root)
		var mat: ShaderMaterial = terrain.ocean_material
		# The domain origin moved off the material and onto the node in Phase 1 of
		# the water-bodies work: _water_domain_origin became an `instance uniform`,
		# which material.set_shader_parameter() cannot reach, so Pasture3D holds it
		# (WATER_BODIES_SPEC §5.4). Same semantics, different route -- and criterion
		# G reproducing the pre-Phase-1 baseline through it is the evidence of that.
		# sea_level is untouched and is still a material uniform until Phase 2.
		terrain.ocean_domain_origin = origin
		mat.set_shader_parameter("sea_level", sea)
		await _prime(terrain)

		var per_instant := []
		var ticks_done := 0
		for ticks in PROBE_TICKS:
			await _advance(terrain, ticks - ticks_done)
			ticks_done = ticks
			var t: float = terrain.get_water_time()
			var heights := PackedFloat64Array()
			var normals := PackedFloat64Array()
			for iz in PROBE_N:
				for ix in PROBE_N:
					var xz := _probe_xz(ix, iz) + Vector2(origin.x, origin.z)
					heights.append(terrain.get_water_height(xz))
					var n: Vector3 = terrain.get_water_normal(xz)
					normals.append(n.x)
					normals.append(n.y)
					normals.append(n.z)
			per_instant.append({
				"ticks": ticks,
				"t": t,
				"heights": Array(heights),
				"normals": Array(normals),
			})

		probes[name] = {"origin": [origin.x, origin.y, origin.z], "sea_level": sea,
			"instants": per_instant}

		var h0: Array = per_instant[0]["heights"]
		var spread: float = float(h0.max()) - float(h0.min())
		print("    %-22s t=%.4f  height span %.4f m  mean %.4f" % [
			name, per_instant[0]["t"], spread, _mean(h0)])
		if spread < 0.5:
			_fail += 1
			print("    !! the surface is nearly flat across 8 km; this probe set would")
			print("       compare equal against almost anything")

		var flat := true
		var n0: Array = per_instant[0]["normals"]
		for i in range(0, n0.size(), 3):
			if absf(n0[i]) > 1e-3 or absf(n0[i + 2]) > 1e-3:
				flat = false
				break
		if flat:
			_fail += 1
			print("    !! every normal is straight up; the normal probes measure nothing")

		# ---- C: the control -------------------------------------------------
		# Raising sea_level by exactly 1 m must raise every height probe by exactly
		# 1 m -- get_water_height() adds it as a scalar (pasture_3d.cpp:393). If it
		# does not, the harness is not reading the surface it thinks it is, and
		# "reproducible" would only mean "reproducibly wrong".
		mat.set_shader_parameter("sea_level", sea + 1.0)
		await _advance(terrain, 0)
		var worst := 0.0
		var idx := 0
		var last: Array = per_instant[per_instant.size() - 1]["heights"]
		for iz in PROBE_N:
			for ix in PROBE_N:
				var xz := _probe_xz(ix, iz) + Vector2(origin.x, origin.z)
				worst = maxf(worst, absf(terrain.get_water_height(xz) - last[idx] - 1.0))
				idx += 1
		print("      CONTROL, sea_level +1 m: worst height deviation from +1.000 m is %.6f m" % worst)
		if worst > 1e-3:
			_fail += 1
			print("      !! sea_level does not shift the query rigidly; the probe set is")
			print("         not measuring what it claims to")

		root.queue_free()
		await _settle()

	_baseline["probes"] = {"lattice_n": PROBE_N, "span": PROBE_SPAN, "cases": probes}


# ---- D: culling vs sea level --------------------------------------------------
# The mesher's cull AABBs are not readable from GDScript -- Pasture3DMesher is not a
# registered class and its mesh RIDs never leave C++. What IS readable is the thing
# the AABBs exist to control, and the thing §4.5 was a bug about: whether the water
# is on screen. So that is what gets baselined.
#
# It matters here specifically because Phase 2 deletes the IS_DATA_INIT guard from
# update_aabbs() (§6.2). If that edit is wrong, this is the number that moves.
#
# The camera sits below the water looking up, for the reason WaterPhase4Gate's gate
# E documents: a stale AABB left below a downward-looking camera is still inside the
# frustum and changes nothing measurable. Looking up, it is outside it.
func _d_cull_vs_sea_level() -> void:
	print("")
	print("[D] on-screen water coverage vs sea level (the observable §4.5 controls):")
	var root := _make_world(Vector3(0, -25, 0), 40.0)
	var cam: Camera3D = root.get_node("Camera3D")
	var terrain := _make_ocean(root)
	var mat: ShaderMaterial = terrain.ocean_material
	await _prime(terrain)
	terrain.set_physics_process(true)
	await _settle_physics(6)

	terrain.ocean_enabled = false
	await _settle_physics(6)
	var sky := _grab()
	terrain.ocean_enabled = true
	await _settle_physics(10)

	var rows := []
	for pair in [[0.0, -25.0], [5.0, -20.0], [300.0, 275.0]]:
		var sea: float = pair[0]
		var cam_y: float = pair[1]
		mat.set_shader_parameter("sea_level", sea)
		cam.position = Vector3(0, cam_y, 0)
		await _settle_physics(10)
		var cov := _coverage(sky, _grab())
		rows.append({"sea_level": sea, "camera_y": cam_y, "coverage": cov})
		print("    sea level %6.1f, camera %7.1f -> coverage %.4f" % [sea, cam_y, cov])

	# The control. Coverage is measured against a sky reference; if the reference and
	# the water frame were the same image the metric would read ~0 and every row
	# above would look like "the ocean is culled" -- which is also what a genuine
	# regression looks like. Prove the metric separates them.
	terrain.ocean_enabled = false
	await _settle_physics(8)
	var cov_off := _coverage(sky, _grab())
	terrain.ocean_enabled = true
	await _settle_physics(8)
	print("    CONTROL, ocean disabled: coverage %.4f (must be ~0)" % cov_off)
	if cov_off > 0.01:
		_fail += 1
		print("    !! the coverage metric reports water with the ocean off; it is not")
		print("       measuring the ocean")
	if float(rows[0]["coverage"]) < 0.5:
		_fail += 1
		print("    !! there is no water on screen at sea level 0; D baselines nothing")

	_baseline["cull"] = {"rows": rows, "control_ocean_off": cov_off}
	root.queue_free()
	await _settle()


# ---- E: frame times -----------------------------------------------------------
# Three configurations, each measured PERF_REPEATS times. The median of each config
# is the baseline; the min-to-max spread across repeats is what Phase 2's tolerance
# has to clear, because a refactor cannot be asked to land inside a band narrower
# than the measurement's own noise.
#
# The terrain clipmap is measured because Phase 2 rewires the mesher underneath IT
# too (§6.2), and the ocean passing while the terrain regressed is precisely the
# failure the host-interface edit invites.
func _e_frame_times() -> void:
	print("")
	print("[E] frame time baseline (median of %d frames, %d repeats):" % [
		PERF_FRAMES, PERF_REPEATS])
	var configs := {}

	for pitch in PITCHES:
		for tier in [["ocean_high", OCEAN_HIGH], ["ocean_low", OCEAN_LOW]]:
			var key := "%s_pitch%d" % [tier[0], int(-pitch)]
			var root := _make_world(Vector3(0, 30, 0), pitch)
			var terrain := _make_ocean(root)
			terrain.ocean_material = load(tier[1])
			if terrain.ocean_material == null:
				_fail += 1
				push_error("could not load %s" % tier[1])
				root.queue_free()
				await _settle()
				continue
			await _prime(terrain)
			_freeze_clock(37.5)
			configs[key] = await _measure_repeats(key)
			root.queue_free()
			await _settle()

	# Terrain clipmap, ocean off. Needs real region data; without it this measures
	# an empty frame and must say so rather than record a number.
	var troot := _make_world(Vector3(0, 300, 0), -30.0)
	var terrain2 := _make_terrain(troot)
	await _settle_physics(20)
	var regions := 0
	if terrain2.data != null:
		regions = terrain2.data.region_locations.size()
	print("    terrain regions loaded from %s: %d" % [DEMO_DATA, regions])
	if regions == 0:
		_fail += 1
		print("    !! no region data; the terrain clipmap baseline would be an empty")
		print("       frame and Phase 2 could regress it undetected")
		configs["terrain_clipmap"] = {"skipped": true, "reason": "no region data"}
	else:
		configs["terrain_clipmap"] = await _measure_repeats("terrain_clipmap")
		_screenshot(_out_dir.path_join("phase0_terrain_clipmap.png"))
	troot.queue_free()
	await _settle()

	_baseline["frame_ms"] = configs

	# The control on the measurement itself: an empty frame must be cheaper than
	# every configuration above. If it is not, the timer is not reading the GPU.
	var eroot := _make_world(Vector3(0, 30, 0), -20.0)
	await _settle()
	var empty := await _measure_ms()
	eroot.queue_free()
	await _settle()
	print("    CONTROL, empty frame (sky only): %.4f ms" % empty)
	_baseline["frame_ms"]["control_empty"] = empty
	var cheapest := 1e9
	for k in configs:
		if configs[k] is Dictionary and configs[k].has("median"):
			cheapest = minf(cheapest, float(configs[k]["median"]))
	if empty >= cheapest:
		_fail += 1
		print("    !! an empty frame costs as much as water does; these timings are not")
		print("       measuring the water and Phase 2 cannot be graded against them")


func _measure_repeats(p_label: String) -> Dictionary:
	var samples: Array[float] = []
	for i in PERF_REPEATS:
		samples.append(await _measure_ms())
	samples.sort()
	var median := samples[samples.size() / 2]
	var spread := samples[samples.size() - 1] - samples[0]
	var spread_pct := 0.0 if median <= 0.0 else 100.0 * spread / median
	print("    %-22s %.4f ms   spread %.4f ms (%.1f%%)  [%s]" % [
		p_label, median, spread, spread_pct,
		", ".join(samples.map(func(s): return "%.4f" % s))])
	return {"median": median, "samples": samples, "spread_pct": spread_pct}


# ---- F: captures --------------------------------------------------------------
# Six, as the spec asks: three pitches x two tiers. Frozen clock, physics stopped,
# fixed camera, procedural sky -- so Phase 2 can image-diff these directly.
#
# Every save is checked. A previous gate in this repo printed "written" for nine
# captures while every save had failed on a missing output directory, and still
# reported PASS.
func _f_captures() -> void:
	print("")
	print("[F] fixed camera captures:")
	var written := 0
	var paths := []
	for pitch in PITCHES:
		var root := _make_world(Vector3(0, 30, 0), pitch)
		var terrain := _make_ocean(root)
		await _prime(terrain)
		terrain.set_physics_process(false)
		_freeze_clock(37.5)

		for tier in [["high", OCEAN_HIGH], ["low", OCEAN_LOW]]:
			var mat = load(tier[1])
			if mat == null:
				_fail += 1
				push_error("could not load %s" % tier[1])
				continue
			terrain.ocean_material = mat
			_freeze_clock(37.5)
			await _settle()
			var path := _out_dir.path_join("phase0_ocean_%s_pitch%d.png" % [
				tier[0], int(-pitch)])
			if _screenshot(path):
				written += 1
				paths.append(path.get_file())
		root.queue_free()
		await _settle()

	print("    %d/6 captures written" % written)
	if written != 6:
		_fail += 1
		print("    !! the sign-off artefacts Phase 2 diffs against do not all exist")

	# The control: the two tiers must actually differ on screen. If they do not, the
	# material assignment is not taking, and six identical PNGs would diff perfectly
	# against six identical PNGs in Phase 2 while proving nothing.
	var root2 := _make_world(Vector3(0, 30, 0), -20.0)
	var terrain3 := _make_ocean(root2)
	await _prime(terrain3)
	terrain3.set_physics_process(false)
	terrain3.ocean_material = load(OCEAN_HIGH)
	_freeze_clock(37.5)
	await _settle()
	var img_high := _grab()
	terrain3.ocean_material = load(OCEAN_LOW)
	_freeze_clock(37.5)
	await _settle()
	var delta := _mean_delta(img_high, _grab())
	root2.queue_free()
	await _settle()
	print("    CONTROL, high vs low tier mean delta: %.5f (must be > 0.002)" % delta)
	if delta <= 0.002:
		_fail += 1
		print("    !! the two tiers render identically, so ocean_material is not taking")
		print("       effect and these captures do not distinguish shaders")

	_baseline["captures"] = {"files": paths, "tier_delta": delta}


# ---- G: cross-run comparison --------------------------------------------------
# The spec's stated Phase 0 gate is "the probe set is reproducible across two runs".
# One process cannot answer that about itself. This compares against a baseline a
# PREVIOUS process left behind, and says plainly when there is none rather than
# reporting a pass for a comparison it did not make.
func _g_compare_prior() -> void:
	print("")
	print("[G] cross-run reproducibility:")
	if _prior == null:
		print("    no prior baseline found — this run writes one. RUN THIS SCENE AGAIN.")
		print("    (G is not a pass; it is a comparison that has not happened yet.)")
		_baseline["cross_run"] = {"compared": false}
		return

	var worst_h := 0.0
	var worst_n := 0.0
	var compared := 0
	var prior_cases: Dictionary = _prior.get("probes", {}).get("cases", {})
	var now_cases: Dictionary = _baseline["probes"]["cases"]
	for name in now_cases:
		if not prior_cases.has(name):
			_fail += 1
			print("    !! prior baseline has no case '%s'; not comparable" % name)
			continue
		var a: Array = prior_cases[name]["instants"]
		var b: Array = now_cases[name]["instants"]
		if a.size() != b.size():
			_fail += 1
			print("    !! instant count differs for '%s'" % name)
			continue
		for i in a.size():
			var ah: Array = a[i]["heights"]
			var bh: Array = b[i]["heights"]
			var an: Array = a[i]["normals"]
			var bn: Array = b[i]["normals"]
			if ah.size() != bh.size() or an.size() != bn.size():
				_fail += 1
				print("    !! probe count differs for '%s' instant %d" % [name, i])
				continue
			for j in ah.size():
				worst_h = maxf(worst_h, absf(float(ah[j]) - float(bh[j])))
				compared += 1
			for j in an.size():
				worst_n = maxf(worst_n, absf(float(an[j]) - float(bn[j])))

	# Count what was actually compared. A loop that `continue`d out of every case
	# leaves worst_h at 0.0, which is what a perfect match also looks like.
	var expect := now_cases.size() * PROBE_TICKS.size() * PROBE_N * PROBE_N
	print("    compared %d/%d height probes against %s" % [
		compared, expect, _prior.get("meta", {}).get("taken", "an earlier run")])
	if compared != expect:
		_fail += 1
		print("    !! not every probe was compared; a zero difference here means")
		print("       'did not look', not 'identical'")
	else:
		print("    worst height difference %.9f m | worst normal component %.9f" % [
			worst_h, worst_n])
		if worst_h > 1e-6:
			_fail += 1
			print("    !! the probe set is NOT reproducible across runs; Phase 2 cannot")
			print("       be graded against it until this is understood")
		else:
			print("    -> reproducible to 1e-6 m")

	_baseline["cross_run"] = {"compared": true, "probes": compared,
		"worst_height_delta": worst_h, "worst_normal_delta": worst_n}


# ---- baseline io --------------------------------------------------------------
func _baseline_path() -> String:
	return _out_dir.path_join("phase0_baseline.json")


func _load_prior() -> void:
	var path := _baseline_path()
	if not FileAccess.file_exists(path):
		print("no prior baseline at %s — this run creates it" % path)
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_fail += 1
		push_error("prior baseline exists but could not be opened: %s" % path)
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		_prior = parsed
		print("prior baseline loaded: %s" % path)
	else:
		_fail += 1
		push_error("prior baseline is not valid JSON: %s" % path)


# Written to a .new file when a prior exists, so a comparison run never destroys the
# thing it just compared against. Re-baselining is then a deliberate file move.
func _write_baseline() -> void:
	var path := _baseline_path() if _prior == null else _baseline_path() + ".new"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_fail += 1
		push_error("could not write %s" % path)
		return
	f.store_string(JSON.stringify(_baseline, "\t"))
	f.close()
	print("")
	print("baseline written: %s" % ProjectSettings.globalize_path(path))


# ---- helpers ------------------------------------------------------------------
func _probe_xz(p_ix: int, p_iz: int) -> Vector2:
	var step := PROBE_SPAN * 2.0 / float(PROBE_N - 1)
	# Offset by a non-round amount so the lattice never lands on a wave multiple.
	return Vector2(-PROBE_SPAN + p_ix * step + 13.7, -PROBE_SPAN + p_iz * step - 7.3)


# Runs physics until the clock is moving, and reports how many ticks that took.
# Pasture3D disables its own physics processing until it has a camera and is
# initialized (pasture_3d.cpp:172), so "the first tick" is not the first tick.
#
# The clock is stopped BEFORE settling, and that ordering is the whole point. The
# first version settled with physics still running: _settle() awaits ten draws, and
# with vsync off the number of physics ticks that fit inside ten draws depends on
# how fast the frame happened to be. Two identical worlds reached 1.2167 s and
# 1.1500 s -- four ticks apart -- and criterion A caught it. Nothing may advance the
# clock except _advance().
func _prime(p_terrain: Pasture3D) -> int:
	var ticks := 0
	while p_terrain.get_water_time() <= 0.0 and ticks < 240:
		await get_tree().physics_frame
		ticks += 1
	p_terrain.set_physics_process(false)
	await _settle()
	if ticks >= 240:
		_fail += 1
		push_error("the water clock never started; nothing downstream is at a known instant")
	return ticks


# Advances exactly N physics ticks and then stops the clock, so the probes that
# follow are all taken at the same instant.
func _advance(p_terrain: Pasture3D, p_ticks: int) -> void:
	p_terrain.set_physics_process(true)
	for i in p_ticks:
		await get_tree().physics_frame
	p_terrain.set_physics_process(false)
	await _settle()


func _make_world(p_cam_pos: Vector3, p_pitch: float) -> Node3D:
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
	cam.position = p_cam_pos
	cam.rotation_degrees = Vector3(p_pitch, 0, 0)
	cam.far = 20000.0
	cam.cull_mask = 1
	cam.current = true
	root.add_child(cam)
	return root


# Ocean only: the terrain itself is pushed onto layer 5, which the camera does not
# see, so what is measured is water and sky. Matches WaterPhase5Gate exactly.
func _make_ocean(p_root: Node3D) -> Pasture3D:
	var terrain := Pasture3D.new()
	terrain.ocean_material = load(OCEAN_HIGH)
	terrain.ocean_enabled = true
	terrain.ocean_light_target = p_root.get_node("Sun")
	terrain.ocean_wave_count = 8
	terrain.ocean_wave_direction = 20.0
	terrain.ocean_wave_spread = 28.0
	terrain.ocean_wave_amplitude = 1.6
	terrain.ocean_wave_length_max = 137.0
	terrain.ocean_wave_steepness = 0.35
	terrain.ocean_wave_loop_period = LOOP_PERIOD
	terrain.render_layers = 1 << 4
	terrain.ocean_render_layers = 1
	p_root.add_child(terrain)
	return terrain


# Terrain clipmap only, no ocean. The mesher under this is the same one Phase 2
# rewires, and it is the half nobody would think to look at.
func _make_terrain(p_root: Node3D) -> Pasture3D:
	var terrain := Pasture3D.new()
	terrain.ocean_enabled = false
	terrain.render_layers = 1
	# data_directory is set AFTER the node is in the tree. Set before, the setter
	# runs against a node with no material or assets yet and tries to load("res://"),
	# which errors twice into the log. The regions still load either way; this is
	# noise removal, not a fix.
	p_root.add_child(terrain)
	terrain.data_directory = DEMO_DATA
	return terrain


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


func _freeze_clock(p_time: float) -> void:
	RenderingServer.global_shader_parameter_set("water_time", p_time)
	RenderingServer.global_shader_parameter_set("water_time_period", LOOP_PERIOD)


func _settle() -> void:
	for i in 10:
		await RenderingServer.frame_post_draw


func _settle_physics(p_n: int) -> void:
	for i in p_n:
		await get_tree().physics_frame
	await _settle()


func _grab() -> Image:
	return get_viewport().get_texture().get_image()


func _screenshot(p_path: String) -> bool:
	var err := _grab().save_png(p_path)
	if err != OK:
		_fail += 1
		push_error("could not write %s (error %d)" % [p_path, err])
		return false
	return true


func _mean_delta(p_a: Image, p_b: Image) -> float:
	var total := 0.0
	var n := 0
	for y in range(0, p_a.get_height(), 4):
		for x in range(0, p_a.get_width(), 4):
			var ca := p_a.get_pixel(x, y)
			var cb := p_b.get_pixel(x, y)
			total += (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
			n += 1
	return total / float(maxi(n, 1))


func _coverage(p_without: Image, p_with: Image) -> float:
	var changed := 0
	var total := 0
	for y in range(0, p_with.get_height(), 4):
		for x in range(0, p_with.get_width(), 4):
			total += 1
			var a := p_without.get_pixel(x, y)
			var b := p_with.get_pixel(x, y)
			if maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), absf(a.b - b.b)) > 0.02:
				changed += 1
	return float(changed) / float(maxi(total, 1))


func _mean(p_a: Array) -> float:
	var t := 0.0
	for v in p_a:
		t += float(v)
	return t / float(maxi(p_a.size(), 1))
