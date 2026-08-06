# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3D landscape material — GPU cost decomposition.
#
# The ocean got this treatment and the terrain never did, which is backwards: the terrain
# material is on screen in every frame of every scene, and it carries a 4x multiplier in its
# hot path that nothing in this repo has ever measured. This is the instrument. It does not
# assert a budget, because there is no measured budget yet to assert — it produces the numbers
# a budget would be written from.
#
# WHAT IT DECOMPOSES
#
# The fragment shader's cost splits into layers that can each be switched off through the
# material API, so each row below is the one above plus one thing:
#
#   OFF        terrain not drawn                  -> sky + sun floor
#   MINIMUM    minimum.gdshader, no texturing      -> + clipmap raster, vertex, height fetches
#   BASE       main shader, every feature off      -> + control decode, splat, normals, PBR
#   +PROJ      BASE + projection_enabled           -> + triplanar-ish slope projection (ALU)
#   +MACRO     BASE + macro_variation_enabled      -> + 2 noise lookups
#   +AUTO      BASE + auto_shader_enabled          -> + slope/height auto blend
#   +DUAL      BASE + dual_scaling_enabled         -> + up to 8 more textureGrad
#   DEMO       exactly what demo/data/M_terrain.tres ships
#   *_NOBILERP the same config with the bilinear control-map path forced off
#
# THE ONE THAT MATTERS IS NOBILERP. The control map packs texture IDs into a uint32, and packed
# IDs cannot be hardware filtered — you cannot lerp "ID 7" and "ID 12". So main.glsl point-samples
# four corners and runs accumulate_material() on each, four full material evaluations blended by
# hand (main.glsl, the `bilerp` branch). It is gated on `region_mip < 4.0`, i.e. it switches OFF
# with distance — which means it is ON exactly where the terrain fills the most pixels. NOBILERP
# forces that branch off by patching the generated shader, so the delta is the price of the
# design decision rather than of any one feature. It is not a shippable config: it will show
# visible seams at region and texel boundaries. It is a measurement.
#
# RESOLUTION SWEEP (RES_SWEEP=1) doubles the job count and answers whether the shader is
# fragment-bound. If cost scales with pixel count it is; if it does not, look at the vertex
# stage and the draw calls instead.
#
# CONTROLS. Every number here can be produced by measuring nothing, so the run ends with a
# control block that must pass before any figure above it means anything: the data has to have
# loaded, the GPU timer has to have returned real values, the terrain has to actually cost more
# than an empty sky, and the NOBILERP patch has to have changed the shader it claims to have
# changed. See the bench-gate practice notes: a criterion satisfiable by an absent subject is
# not a criterion.
#
# THIS IS A BENCHMARK. Frame times are only meaningful on an otherwise-idle machine. Close the
# other engine first.
#
# Run:  Godot_v4.7-stable_win64_console.exe --path project bench/TerrainMaterialBench.tscn
#       RES_SWEEP=1 to add 2560x1440. BENCH_OUT=<dir> to write the eyeball captures somewhere.
extends Node

const DEMO_DATA := "res://demo/data"
const DEMO_MATERIAL := "res://demo/data/M_terrain.tres"
const DEMO_ASSETS := "res://demo/data/assets.tres"
const MINIMUM_SHADER := "res://addons/pasture_3d/extras/shaders/minimum.gdshader"

const WARMUP_FRAMES := 90
const MEASURE_FRAMES := 180
# SMOKE=1 runs every job for a handful of frames instead of 270. The timings it produces are
# NOISE and it says so — the point is to prove the harness itself works (data loads, every
# config applies, the patch takes, the captures write) WITHOUT running a benchmark, which on
# this machine is something to schedule rather than something to do casually.
const SMOKE_WARMUP := 2
const SMOKE_MEASURE := 3

const BASE_RES := Vector2i(1280, 800)
const SWEEP_RES := Vector2i(2560, 1440)
## Metres above the ground at the centre of the loaded regions. Standing height, not a flyover.
const CAMERA_EYE_HEIGHT := 12.0
# Degrees below horizontal. -4 is the worst case: the terrain fills the frame to the horizon,
# every pixel is inside the bilerp radius near the camera, and minification is hardest far away.
const PITCHES := [-4.0, -20.0, -60.0]

# The string in the generated shader that gates the 4x control-map path, and what to replace it
# with so the branch is never taken. Exact-match on purpose: if main.glsl's threshold is ever
# retuned this stops matching, and the control below fails loudly rather than the bench silently
# measuring BASE twice.
const BILERP_NEEDLE := "region_mip < 4.0"
const BILERP_PATCH := "region_mip < -1.0"

var _terrain: Pasture3D
var _camera: Camera3D
var _sun: DirectionalLight3D
var _material: Pasture3DMaterial
var _nobilerp_shader: Shader

var _jobs: Array = []
var _job_index := -1
var _frames_left := 0
var _warming := true
var _samples: Array[float] = []
var _draw_calls := 0
var _primitives := 0
var _results: Array = []
var _out_dir := ""

# Control state, gathered as the run proceeds.
var _regions := 0
var _texture_count := 0
var _patch_applied := false
var _patch_occurrences := -1
var _captures_written := 0
var _smoke := false


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

	_smoke = OS.get_environment("SMOKE") == "1"
	_out_dir = OS.get_environment("BENCH_OUT")
	if _out_dir == "":
		_out_dir = "user://"

	_build_scene()
	await get_tree().process_frame
	_build_nobilerp_shader()

	var resolutions := [BASE_RES]
	if OS.get_environment("RES_SWEEP") == "1":
		resolutions.append(SWEEP_RES)

	var configs := ["OFF", "MINIMUM", "BASE", "+PROJ", "+MACRO", "+AUTO", "+DUAL", "+NOISE_BG",
		"DEMO", "BASE_NOBILERP", "DEMO_NOBILERP"]

	for res in resolutions:
		for pitch in PITCHES:
			for cfg in configs:
				_jobs.append({"res": res, "pitch": pitch, "cfg": cfg})

	print("=== Pasture3D landscape material — GPU cost decomposition ===")
	print("Godot %s | %s | %s" % [
		Engine.get_version_info().string,
		RenderingServer.get_video_adapter_name(),
		RenderingServer.get_current_rendering_method(),
	])
	if _smoke:
		print("")
		print("*** SMOKE RUN — %d/%d frames per job. THE TIMINGS BELOW ARE NOISE. ***" % [
			SMOKE_WARMUP, SMOKE_MEASURE])
		print("*** It proves the harness runs; it measures nothing. Drop SMOKE=1 to benchmark. ***")
		print("")
	print("regions=%d  textures=%d  camera=%v  warmup=%d  measure=%d  jobs=%d" % [
		_regions, _texture_count, _camera.position,
		_warmup_frames(), _measure_frames(), _jobs.size()])
	print("")
	print("res,pitch_deg,config,gpu_ms_median,gpu_ms_p95,cpu_ms_median,draw_calls,primitives")
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
	# Shadows OFF. They are a real cost but they are the SHADOW map's cost, not the material's,
	# and leaving them on would put a second full terrain draw inside every number here.
	_sun.shadow_enabled = false
	add_child(_sun)

	_camera = Camera3D.new()
	# Positioned in _place_camera() once the region data is known. Ground level is the worst
	# case and the common one; a top-down camera would flatter every config equally.
	_camera.far = 8000.0
	_camera.current = true
	add_child(_camera)

	_terrain = Pasture3D.new()
	# The material is DUPLICATED, not used in place: this bench toggles features on it, and
	# writing those toggles into demo/data/M_terrain.tres on disk would edit the user's demo.
	_material = load(DEMO_MATERIAL).duplicate(true)
	_terrain.clipmap_target = _camera

	# ORDER MATTERS, and getting it wrong is silent. Pasture3D::_initialize() is gated on
	# `_is_inside_world && is_inside_tree()`, so material and assets assigned BEFORE add_child
	# are stored and never initialised. The texture arrays then stay empty, and an empty array
	# makes the material force its CHECKERED DEBUG VIEW on (pasture_3d_material.cpp, the
	# get_generated_array_size() == 0 branch). Every "material" number would then have been the
	# cost of the debug shader, and with one texture ID everywhere the second texture branch in
	# accumulate_material() never runs either — understating the real cost by roughly half,
	# while looking entirely plausible. Control [8] exists because this happened.
	add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_terrain.material = _material
	_terrain.assets = _usable_assets()
	# Force the arrays to build now rather than whenever the editor would have.
	if _terrain.assets != null:
		_terrain.assets.update_texture_list()
	_material.update(Pasture3DMaterial.TEXTURE_ARRAYS)

	if _terrain.data != null:
		_regions = _terrain.data.region_locations.size()
	if _terrain.assets != null:
		_texture_count = _terrain.assets.get_texture_count()

	_place_camera()


## The demo asset list, minus any entry that would stop the texture arrays building.
##
## demo/data/assets.tres ships three textures, and the third (noise_test_alb) has an albedo with
## no normal map. Pasture3DAssets then generates a placeholder normal for it in an uncompressed
## format while the other two are BC-compressed, the format check in _update_texture_files()
## rejects the whole set — "Texture ID 2 normal format: 5 doesn't match format of first texture:
## 22" — and NOTHING builds. The material sees an empty array and silently switches to its
## checkered debug view, which is where this bench's first run went.
##
## Filtered on a DUPLICATE, so the user's demo assets on disk are untouched. This is a
## workaround, not a fix: the demo data has a real defect and the printed line below is there so
## running the bench keeps saying so rather than quietly papering over it.
func _usable_assets() -> Pasture3DAssets:
	var src: Pasture3DAssets = load(DEMO_ASSETS)
	if src == null:
		return null
	var out: Pasture3DAssets = src.duplicate(true)
	var kept: Array[Pasture3DTextureAsset] = []
	var dropped: PackedStringArray = []
	for t in out.get_texture_list():
		var asset: Pasture3DTextureAsset = t
		if asset == null:
			continue
		if asset.get_albedo_texture() == null or asset.get_normal_texture() == null:
			dropped.append(asset.get_name())
			continue
		asset.set_id(kept.size()) # ids must stay contiguous from 0
		kept.append(asset)
	if not dropped.is_empty():
		print("NOTE: dropped %d demo texture asset(s) with an incomplete map set: %s" % [
			dropped.size(), ", ".join(dropped)])
		print("      They break the shared-format check and leave the arrays empty (see _usable_assets).")
	out.set_texture_list(kept)
	return out


## Puts the camera over the middle of the loaded regions, at eye height above the ground.
##
## Not a hardcoded position. The first fixture used (0, 40, 0), which on the demo data sits on a
## region boundary looking along a vertical wall where the loaded regions end — half the frame
## was cliff face and background, which is not what the terrain material costs when you are
## standing on it. The centroid follows the data instead of assuming it.
func _place_camera() -> void:
	if _terrain.data == null:
		return
	var locs: Array = _terrain.data.region_locations
	if locs.is_empty():
		return
	var sum := Vector2.ZERO
	for l in locs:
		sum += Vector2(l)
	var region_world: float = float(_terrain.region_size) * _terrain.vertex_spacing
	# +0.5 puts it at the region's centre rather than its corner.
	var centre: Vector2 = (sum / float(locs.size()) + Vector2(0.5, 0.5)) * region_world
	var ground: float = _terrain.data.get_height(Vector3(centre.x, 0.0, centre.y))
	if is_nan(ground):
		ground = 0.0
	_camera.position = Vector3(centre.x, ground + CAMERA_EYE_HEIGHT, centre.y)


## Builds the bilerp-disabled variant by patching the shader the material actually generated.
##
## Read back rather than hand-written, so this tracks main.glsl instead of being a stale copy of
## it: whatever inserts the current feature set produced are in here, and only the one branch
## differs. _patch_occurrences is recorded for the control — a needle that stops matching would
## otherwise hand back an unmodified shader and the NOBILERP rows would silently equal their
## parents.
func _build_nobilerp_shader() -> void:
	var rid := _material.get_shader_rid()
	if not rid.is_valid():
		_patch_occurrences = -1
		return
	var code := RenderingServer.shader_get_code(rid)
	_patch_occurrences = code.count(BILERP_NEEDLE)
	if _patch_occurrences <= 0:
		return
	_nobilerp_shader = Shader.new()
	_nobilerp_shader.code = code.replace(BILERP_NEEDLE, BILERP_PATCH)
	_patch_applied = _nobilerp_shader.code != code


## Every config is expressed as a delta from a known-clean state, so no job inherits a toggle
## from the one before it.
func _apply_config(p_cfg: String) -> void:
	# Reset to BASE: features off, no override, terrain visible.
	_material.shader_override_enabled = false
	_material.auto_shader_enabled = false
	_material.dual_scaling_enabled = false
	_material.macro_variation_enabled = false
	_material.projection_enabled = false
	_material.world_background = 0 # NONE
	_terrain.visible = true

	match p_cfg:
		"OFF":
			_terrain.visible = false
		"MINIMUM":
			var sh := Shader.new()
			sh.code = FileAccess.get_file_as_string(MINIMUM_SHADER)
			_material.shader_override = sh
			_material.shader_override_enabled = true
		"BASE":
			pass
		"+PROJ":
			_material.projection_enabled = true
		"+MACRO":
			_material.macro_variation_enabled = true
		"+AUTO":
			_material.auto_shader_enabled = true
		"+DUAL":
			_material.dual_scaling_enabled = true
		"+NOISE_BG":
			# The procedural terrain that fills the world OUTSIDE the loaded regions. Added
			# after the first run left 0.57 ms of DEMO unattributed at 1440p — every other
			# feature had a row and this did not, so the largest single unexplained cost was
			# the one nothing measured.
			_material.world_background = 2 # NOISE
		"DEMO":
			_apply_demo_features()
		"BASE_NOBILERP":
			_apply_nobilerp()
		"DEMO_NOBILERP":
			_apply_demo_features()
			_apply_nobilerp()


## What demo/data/M_terrain.tres actually ships with — which is every feature on, including the
## noise world background. Spelled out here rather than read off the resource so the bench says
## what it is measuring, and so a later edit to the demo material shows up as a diff here
## instead of silently redefining the DEMO row.
func _apply_demo_features() -> void:
	_material.auto_shader_enabled = true
	_material.dual_scaling_enabled = true
	_material.macro_variation_enabled = true
	_material.projection_enabled = true
	_material.world_background = 2 # NOISE


func _apply_nobilerp() -> void:
	if _nobilerp_shader == null:
		return
	# Re-patch against the CURRENT generated shader: the feature toggles above change the
	# generated code, so a shader patched from the BASE variant would also silently revert
	# every feature DEMO_NOBILERP is supposed to have on.
	var rid := _material.get_shader_rid()
	if rid.is_valid():
		var code := RenderingServer.shader_get_code(rid)
		if code.count(BILERP_NEEDLE) > 0:
			var sh := Shader.new()
			sh.code = code.replace(BILERP_NEEDLE, BILERP_PATCH)
			_material.shader_override = sh
			_material.shader_override_enabled = true


func _next_job() -> void:
	_job_index += 1
	if _job_index >= _jobs.size():
		_report()
		get_tree().quit(0 if _controls_pass() else 1)
		return

	var job: Dictionary = _jobs[_job_index]
	DisplayServer.window_set_size(job["res"])
	_camera.rotation_degrees = Vector3(job["pitch"], 0.0, 0.0)
	_apply_config(job["cfg"])

	_samples.clear()
	_warming = true
	_frames_left = _warmup_frames()


func _warmup_frames() -> int:
	return SMOKE_WARMUP if _smoke else WARMUP_FRAMES


func _measure_frames() -> int:
	return SMOKE_MEASURE if _smoke else MEASURE_FRAMES


func _process(_delta: float) -> void:
	if _job_index < 0 or _job_index >= _jobs.size():
		return

	_frames_left -= 1
	if _warming:
		if _frames_left <= 0:
			_warming = false
			_frames_left = _measure_frames()
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
		"samples": _samples.size(),
	}
	_results.append(row)
	print("%s,%.1f,%s,%.4f,%.4f,%.4f,%d,%d" % [
		row["res"], row["pitch"], row["cfg"],
		row["gpu_median"], row["gpu_p95"], row["cpu_median"],
		row["draws"], row["prims"],
	])

	# One capture per pitch at the shipped config, at the base resolution. Bench practice: two of
	# the three wrong verdicts in the water phases were caught by opening the PNGs and none by
	# tightening a threshold. These exist so "the camera was pointed at the sky" is visible
	# rather than inferred from a suspiciously low number.
	if job["cfg"] == "DEMO" and job["res"] == BASE_RES:
		_screenshot(_out_dir.path_join("terrain_demo_pitch%d.png" % int(-job["pitch"])))

	_next_job()


func _screenshot(p_path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		return
	if img.save_png(ProjectSettings.globalize_path(p_path)) == OK:
		_captures_written += 1


func _percentile(values: Array[float], q: float) -> float:
	if values.is_empty():
		return -1.0
	var sorted := values.duplicate()
	sorted.sort()
	var idx := int(round(q * float(sorted.size() - 1)))
	return sorted[clampi(idx, 0, sorted.size() - 1)]


func _find(p_res: String, p_pitch: float, p_cfg: String) -> Dictionary:
	for r in _results:
		if r["res"] == p_res and is_equal_approx(r["pitch"], p_pitch) and r["cfg"] == p_cfg:
			return r
	return {}


func _ms(p_res: String, p_pitch: float, p_cfg: String) -> float:
	var r := _find(p_res, p_pitch, p_cfg)
	return -1.0 if r.is_empty() else float(r["gpu_median"])


# ---- reporting ---------------------------------------------------------------

func _report() -> void:
	var resolutions: Array = []
	for r in _results:
		if not resolutions.has(r["res"]):
			resolutions.append(r["res"])

	print("")
	print("=== Cost decomposition (GPU ms, median, each row minus the layer beneath it) ===")
	print("res,pitch_deg,geometry,base_material,projection,macro_var,auto_shader,dual_scaling,noise_bg,demo_total,unattributed")
	for rs in resolutions:
		for pitch in PITCHES:
			var off := _ms(rs, pitch, "OFF")
			var minimum := _ms(rs, pitch, "MINIMUM")
			var base := _ms(rs, pitch, "BASE")
			if off < 0.0 or minimum < 0.0 or base < 0.0:
				continue
			var parts := [
				minimum - off,
				base - minimum,
				_ms(rs, pitch, "+PROJ") - base,
				_ms(rs, pitch, "+MACRO") - base,
				_ms(rs, pitch, "+AUTO") - base,
				_ms(rs, pitch, "+DUAL") - base,
				_ms(rs, pitch, "+NOISE_BG") - base,
			]
			var total: float = _ms(rs, pitch, "DEMO") - off
			# What DEMO costs beyond the sum of its parts. Not noise in the statistical
			# sense: it is whatever the features cost TOGETHER that they do not cost
			# separately. Printed rather than hidden, because the first version of this
			# table had no noise_bg column and quietly buried 0.57 ms here.
			var summed := 0.0
			for p in parts:
				summed += float(p)
			print("%s,%.1f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f" % [
				rs, pitch, parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], parts[6],
				total, total - summed,
			])

	print("")
	print("=== The bilinear control-map path (the 4x) ===")
	print("The share of material cost spent evaluating four corners instead of one.")
	print("res,pitch_deg,base_ms,base_nobilerp_ms,base_saving_pct,demo_ms,demo_nobilerp_ms,demo_saving_pct")
	for rs in resolutions:
		for pitch in PITCHES:
			var base := _ms(rs, pitch, "BASE")
			var base_nb := _ms(rs, pitch, "BASE_NOBILERP")
			var demo := _ms(rs, pitch, "DEMO")
			var demo_nb := _ms(rs, pitch, "DEMO_NOBILERP")
			if base < 0.0 or base_nb < 0.0 or demo < 0.0 or demo_nb < 0.0:
				continue
			print("%s,%.1f,%.4f,%.4f,%.1f%%,%.4f,%.4f,%.1f%%" % [
				rs, pitch, base, base_nb,
				100.0 * (base - base_nb) / maxf(base, 1e-9),
				demo, demo_nb,
				100.0 * (demo - demo_nb) / maxf(demo, 1e-9),
			])

	if resolutions.size() > 1:
		print("")
		print("=== Fragment-bound? (cost vs pixel count) ===")
		var pixel_ratio := float(SWEEP_RES.x * SWEEP_RES.y) / float(BASE_RES.x * BASE_RES.y)
		print("A perfectly fragment-bound shader scales by %.2fx. Much less means the vertex" % pixel_ratio)
		print("stage or the draw calls dominate, and the fragment work is not where to look.")
		print("pitch_deg,config,ms_low,ms_high,scale_factor")
		for pitch in PITCHES:
			for cfg in ["BASE", "DEMO"]:
				var lo := _ms("%dx%d" % [BASE_RES.x, BASE_RES.y], pitch, cfg)
				var hi := _ms("%dx%d" % [SWEEP_RES.x, SWEEP_RES.y], pitch, cfg)
				if lo <= 0.0 or hi <= 0.0:
					continue
				print("%.1f,%s,%.4f,%.4f,%.2fx" % [pitch, cfg, lo, hi, hi / lo])

	_report_controls()


## Nothing above means anything unless these hold. Each one exists because the corresponding
## failure produces plausible-looking numbers rather than an error.
func _report_controls() -> void:
	print("")
	print("=== CONTROLS (every figure above is void unless these pass) ===")
	var ok := true
	var bilerp_ok := true

	# Measuring an empty world would give a clean, stable, meaningless decomposition.
	var c1 := _regions > 0
	print("  [1] terrain data loaded:        %d regions %s" % [_regions, "ok" if c1 else "!! FAIL"])
	ok = ok and c1

	# A GPU timer that returns 0 every frame yields a median of -1 and differences near zero,
	# which reads as "everything is free" rather than as "nothing was timed".
	var min_samples := 1 << 30
	for r in _results:
		min_samples = mini(min_samples, int(r["samples"]))
	var c2 := min_samples > 0
	print("  [2] GPU timer returned values:  min %d samples/job %s" % [
		min_samples, "ok" if c2 else "!! FAIL (measured nothing, not 'measured fast')"])
	ok = ok and c2

	# If the terrain is off screen, or not drawn at all, every config costs the sky and the
	# whole decomposition is differences between equal numbers.
	var rs := "%dx%d" % [BASE_RES.x, BASE_RES.y]
	var off := _ms(rs, PITCHES[0], "OFF")
	var demo := _ms(rs, PITCHES[0], "DEMO")
	# In a smoke run three frames cannot separate these, so the magnitude controls are reported
	# and NOT counted. They are the ones a smoke run cannot speak to; saying so beats either
	# failing a harness that works or passing a comparison that was never made.
	var advisory := " (advisory: smoke run)" if _smoke else ""
	var c3 := off > 0.0 and demo > off * 1.2
	print("  [3] terrain costs > sky floor:  OFF %.4f vs DEMO %.4f %s%s" % [
		off, demo, "ok" if c3 else "!! FAIL (terrain not on screen or not drawn)", advisory])
	ok = ok and (c3 or _smoke)

	# Geometry above the floor proves the clipmap is rasterising, separately from whether the
	# material is doing anything — this is what distinguishes "wrong camera" from "cheap shader".
	var minimum := _ms(rs, PITCHES[0], "MINIMUM")
	var c4 := minimum > off
	print("  [4] geometry above the floor:   MINIMUM %.4f > OFF %.4f %s%s" % [
		minimum, off, "ok" if c4 else "!! FAIL (clipmap not rasterising)", advisory])
	ok = ok and (c4 or _smoke)

	# The whole point of the NOBILERP rows. A needle that no longer matches main.glsl would
	# leave the shader unpatched and the saving would read as a genuine 0%.
	# [5] and [6] are SCOPED TO THE BILERP TABLE, not to the run. They used to count toward the
	# global verdict, and the first run where the bilerp delta fell under a percent printed
	# "BENCH VOID" over a set of world-noise and auto-shader numbers that were entirely sound.
	# An instrument that cries void over one inconclusive sub-result gets ignored, which is
	# worse than the sub-result being inconclusive.
	var c5 := _patch_applied and _patch_occurrences > 0
	print("  [5] bilerp patch applied:       %d occurrence(s) of \"%s\" %s" % [
		_patch_occurrences, BILERP_NEEDLE,
		"ok" if c5 else "!! FAIL (needle stale — NOBILERP measured the unpatched shader)"])
	bilerp_ok = bilerp_ok and c5

	# ...and that it actually changed the cost. A patch that applies but changes nothing means
	# the branch was already never taken at this camera distance, so the rows are not evidence
	# about the 4x either way.
	var base := _ms(rs, PITCHES[0], "BASE")
	var base_nb := _ms(rs, PITCHES[0], "BASE_NOBILERP")
	var c6 := base > 0.0 and base_nb > 0.0 and absf(base - base_nb) / base > 0.01
	print("  [6] bilerp patch changed cost:  BASE %.4f vs NOBILERP %.4f %s%s" % [
		base, base_nb,
		"ok" if c6 else "INCONCLUSIVE (delta under 1% — the bilerp table alone is void)",
		advisory])
	bilerp_ok = bilerp_ok and (c6 or _smoke)

	var c7 := _captures_written == PITCHES.size()
	print("  [7] captures written to disk:   %d of %d %s" % [
		_captures_written, PITCHES.size(), "ok" if c7 else "!! FAIL (nothing to eyeball)"])
	ok = ok and c7

	# The one this bench was built without and immediately needed. An empty texture array makes
	# the material switch itself to the checkered debug view, so the whole decomposition becomes
	# the cost of a debug shader over a single texture ID — a plausible-looking set of numbers
	# about the wrong shader. Both halves are checked: textures present, AND the debug view the
	# material would have turned on is off.
	var c8 := _texture_count > 0 and not _material.get_show_checkered()
	print("  [8] real textures, not the debug view: %d texture(s), checkered=%s %s" % [
		_texture_count, str(_material.get_show_checkered()),
		"ok" if c8 else "!! FAIL (measuring the checkered debug shader, not the material)"])
	ok = ok and c8

	print("")
	if not bilerp_ok:
		print("NOTE: the bilinear control-map table above is VOID for this run — see [5]/[6].")
		print("      Every other figure stands; those two controls scope to that table only.")
	if not ok:
		print("=== TERRAIN MATERIAL BENCH VOID — a control failed; ignore the figures above ===")
	elif _smoke:
		print("=== SMOKE RUN OK — the harness works. It measured nothing; run without SMOKE=1. ===")
	else:
		print("=== TERRAIN MATERIAL BENCH COMPLETE — controls pass, figures stand ===")
		print("Captures in %s — open them. A number is not evidence that the right thing was drawn." % _out_dir)


func _controls_pass() -> bool:
	if _regions <= 0 or not _patch_applied:
		return false
	if _texture_count <= 0 or _material.get_show_checkered():
		return false
	for r in _results:
		if int(r["samples"]) <= 0:
			return false
	return _captures_written == PITCHES.size()
