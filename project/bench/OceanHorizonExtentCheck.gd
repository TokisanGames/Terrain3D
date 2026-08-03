# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Does the ocean mesh END inside the frame when the camera is up high?
#
# §8.7 priced mesh_size from a camera 12 m above the water — a boat deck. That is the
# wrong viewpoint for the question "can the player see the edge of the world", and the
# recommendation it produced (mesh_size 64 / mesh_lods 7, holding the shipped 8192 m
# half-extent) was arrived at without ever pointing a camera down from a height.
#
# The geometry says altitude changes which knob matters. A clipmap is scale-invariant, so
# from sea level the LOD rings track the viewer and the outermost one is always past the
# point where water converges on the horizon line. Raise the camera and the mesh edge
# swings UP into the frame: at height h the edge at horizontal distance E sits
# atan(h / E) below the true horizon, which is 0.06 deg from a boat, 0.7 deg from a cliff
# and 3.5 deg from a mountain — that last one is tens of pixels of sky where sea should be.
#
# MEASURED, not computed, because the analytic angle does not know about the cull AABB,
# the far plane, or the geomorph. The method needs no horizon arithmetic:
#
#   topmost water row, candidate  vs  topmost water row, a 262 km reference ocean
#
# If the candidate's water stops lower down the screen than the reference's, the edge is
# in frame. The reference is the control: it is the same scene, same camera, same shader,
# with the only difference being an extent nothing could reach.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/OceanHorizonExtentCheck.tscn
extends Node

const OCEAN_HIGH := "res://addons/pasture_3d/extras/shaders/water/M_water_ocean.tres"
const RESOLUTION := Vector2i(1280, 800)
const LOOP_PERIOD := 120.0
const VERTEX_SPACING := 1.0
const TESSELLATION := 2
const CAM_FOV := 70.0
# Far enough that the MESH is the only thing that can end the water. A real project will
# usually have fog or a nearer far plane hiding this; that is a mitigation, not a fix, and
# it is not this harness's job to assume it.
const CAM_FAR := 200000.0
# Pitch chosen so the true horizon sits in frame at every height, with room below it for
# an edge to show.
const PITCH := -10.0

# The viewpoints the recommendation has to survive.
const VIEWPOINTS := [
	{"name": "boat deck", "height": 12.0},
	{"name": "coastal cliff", "height": 100.0},
	{"name": "mountain overlook", "height": 500.0},
]

# (mesh_size, mesh_lods). half_extent = mesh_size/2 * 2^(lods+1) at spacing 1.0, tess 2.
const CONFIGS := [
	{"name": "shipped", "size": 16, "lods": 9},
	{"name": "sec 8.7 rec", "size": 64, "lods": 7},
	{"name": "64 / lods 9", "size": 64, "lods": 9},
	{"name": "128 / lods 9", "size": 128, "lods": 9},
	{"name": "64 / lods 10", "size": 64, "lods": 10},
	{"name": "128 / lods 10", "size": 128, "lods": 10},
]
# CONTROL, and it must FAIL at every height including the boat deck. A 256 m ocean ends
# well inside any frame; a harness that calls this one "ok" is not detecting edges at all,
# it is reporting the tolerance. Without it, "no edge visible" is unfalsifiable.
const TINY_CONTROL := {"name": "CONTROL 256m", "size": 16, "lods": 4}
# The control. Nothing in frame can reach 262 km, so its water boundary IS the horizon.
const REFERENCE := {"name": "REFERENCE 262km", "size": 256, "lods": 10}

# A candidate whose boundary is within this many rows of the reference is treated as
# reaching the horizon. Two rows of 800 absorbs the geomorph's wobble at the last ring
# without hiding anything a player could see.
const ROW_TOLERANCE := 2
# Lighter than sec 8.7 (60/150/3). The repeats there agreed to four decimals, so the
# extra frames were buying precision this comparison does not need -- and 24 timed
# configs at the full profile is a harness nobody re-runs.
const PERF_WARMUP := 30
const PERF_FRAMES := 60
const PERF_REPEATS := 2

var _rows := {}
var _ms := {}


func _ready() -> void:
	get_viewport().size = RESOLUTION
	# Silently returns 0.0 for every sample when off; see OceanMeshSizeSweep.
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_run()


func _run() -> void:
	print("\n=== Ocean mesh edge vs camera altitude ===")
	print("%s | %s | %dx%d, fov %.0f, pitch %.0f, far %.0f m" % [
			Engine.get_version_info()["string"], RenderingServer.get_video_adapter_name(),
			RESOLUTION.x, RESOLUTION.y, CAM_FOV, PITCH, CAM_FAR])
	print("held: vertex_spacing=%.2f tessellation_level=%d\n" % [VERTEX_SPACING, TESSELLATION])

	var failures := 0
	var control_caught := 0
	for vp in VIEWPOINTS:
		print("-- %s, camera %.0f m above sea level --" % [vp["name"], vp["height"]])
		var ref_row: int = await _boundary_row(REFERENCE, vp["height"])
		print("  %-16s %10s %10s %9s %8s  %s" % [
				"config", "extent(km)", "top row", "vs ref", "gpu ms", "verdict"])
		print("  %-16s %10.1f %10d %9s %8.4f  %s" % [
				REFERENCE["name"], _extent(REFERENCE) / 1000.0, ref_row, "--",
				_ms[[REFERENCE["name"], vp["height"]]], "this IS the horizon"])
		for cfg in CONFIGS:
			var row: int = await _boundary_row(cfg, vp["height"])
			var delta: int = row - ref_row
			var reaches: bool = delta <= ROW_TOLERANCE
			if not reaches:
				failures += 1
			print("  %-16s %10.1f %10d %9s %8.4f  %s" % [
					cfg["name"], _extent(cfg) / 1000.0, row, "+%d" % delta,
					_ms[[cfg["name"], vp["height"]]],
					"ok" if reaches else "EDGE VISIBLE (%d px of sky below the horizon)" % delta])
		# The known-bad config, at every height, so a clean sheet above is falsifiable.
		var ctl_row: int = await _boundary_row(TINY_CONTROL, vp["height"])
		var ctl_delta: int = ctl_row - ref_row
		var caught: bool = ctl_delta > ROW_TOLERANCE
		if caught:
			control_caught += 1
		print("  %-16s %10.1f %10d %9s %8.4f  %s" % [
				TINY_CONTROL["name"], _extent(TINY_CONTROL) / 1000.0, ctl_row,
				"+%d" % ctl_delta, _ms[[TINY_CONTROL["name"], vp["height"]]],
				"CONTROL caught it" if caught else "!! CONTROL MISSED -- results above are worthless"])
		print("")

	# NOTE on the control that used to live here. It asserted the reference horizon row
	# MOVES with altitude, and it failed -- correctly, because the premise was wrong. The
	# horizon of an infinite flat plane is at eye level at every altitude; only earth
	# curvature would lower it, and Godot's world is flat. Measured rows 299/300/301 match
	# the analytic 400 - 400*tan(10)/tan(35) = 299 at all three heights, which is the real
	# confirmation that the boundary finder is locating the horizon. Sensitivity is what
	# needed a control, and TINY_CONTROL above is it.
	if control_caught != VIEWPOINTS.size():
		print("!! the control was missed at %d of %d viewpoints; this harness is not"
				% [VIEWPOINTS.size() - control_caught, VIEWPOINTS.size()]
				+ " detecting edges and every 'ok' above is meaningless")
		failures += 1000

	print("\n=== %s ===\n" % ("NO EDGE VISIBLE IN ANY TESTED CONFIG" if failures == 0
			else "%d config/viewpoint pairs show the mesh edge" % failures))
	get_tree().quit(0)


func _extent(p_cfg: Dictionary) -> float:
	var lod0_radius: float = 2.0 * p_cfg["size"] * (VERTEX_SPACING / pow(2.0, TESSELLATION))
	return lod0_radius * pow(2.0, p_cfg["lods"] + TESSELLATION - 1)


## Topmost screen row containing water, found by differencing against the same frame with
## the ocean switched off. Row 0 is the top of the screen, so a LARGER number is water that
## stops lower down -- an edge.
func _boundary_row(p_cfg: Dictionary, p_height: float) -> int:
	var root := _make_world(p_height)
	var ocean := _make_ocean(root)
	ocean.vertex_spacing = VERTEX_SPACING
	ocean.tessellation_level = TESSELLATION
	ocean.mesh_size = p_cfg["size"]
	ocean.mesh_lods = p_cfg["lods"]
	if ocean.mesh_size != p_cfg["size"] or ocean.mesh_lods != p_cfg["lods"]:
		push_error("clamped: asked %d/%d got %d/%d" % [
				p_cfg["size"], p_cfg["lods"], ocean.mesh_size, ocean.mesh_lods])
	RenderingServer.global_shader_parameter_set("water_time", 30.0)
	RenderingServer.global_shader_parameter_set("water_time_period", LOOP_PERIOD)

	ocean.enabled = false
	var without: Image = await _capture()
	ocean.enabled = true
	var with_water: Image = await _capture()

	# Cost at THIS altitude. §8.7 priced these from 12 m only, and altitude redistributes
	# which rings are on screen -- looking down from 500 m puts far more coarse rings in
	# frame and far less of LOD0, so the sea-level price list does not transfer.
	_ms[[p_cfg["name"], p_height]] = await _measure_ms()

	var row := with_water.get_height()
	for y in with_water.get_height():
		var found := false
		for x in range(0, with_water.get_width(), 4):
			var a := without.get_pixel(x, y)
			var b := with_water.get_pixel(x, y)
			if maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), absf(a.b - b.b)) > 0.02:
				found = true
				break
		if found:
			row = y
			break
	_rows[[p_cfg["name"], p_height]] = row
	root.queue_free()
	await get_tree().process_frame
	return row


func _measure_ms() -> float:
	var vp := get_viewport().get_viewport_rid()
	var passes: Array[float] = []
	for r in PERF_REPEATS + 1: # first pass discarded: fresh clipmap, pipeline setup
		for i in PERF_WARMUP:
			await RenderingServer.frame_post_draw
		var samples: Array[float] = []
		for i in PERF_FRAMES:
			await RenderingServer.frame_post_draw
			var ms := RenderingServer.viewport_get_measured_render_time_gpu(vp)
			if ms > 0.0:
				samples.append(ms)
		samples.sort()
		passes.append(0.0 if samples.is_empty() else samples[samples.size() / 2])
	passes.remove_at(0)
	passes.sort()
	return passes[passes.size() / 2]


func _capture() -> Image:
	for i in 8:
		await RenderingServer.frame_post_draw
	return get_viewport().get_texture().get_image()


func _make_world(p_height: float) -> Node3D:
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
	cam.position = Vector3(0.0, p_height, 0.0)
	cam.rotation_degrees = Vector3(PITCH, 0, 0)
	cam.fov = CAM_FOV
	cam.far = CAM_FAR
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
