# Pasture3D Water Bodies — Phase 5 exit gate (spec §11, PASTURE3D_WATER_BODIES_SPEC.md).
#
# Phase 5 is the underwater volume: the Area3D, the exact submersion test, camera polling, the
# FogVolume, and the screen overlay.
#
# Gate criteria, from the spec's phase table ("camera crossing in both directions, above and below,
# in editor and runtime; concave pool rejects the peninsula point (control: the AABB test, which
# must accept it); overlay cost measured"):
#
#   A. the camera crossing, BOTH directions, with camera_submerged firing once per crossing and not
#      once per frame. Control: a camera at the same depth but OUTSIDE the loop never fires
#   B. the concave case — a peninsula point inside the volume box resolves as dry. Control: the box
#      test itself, which must accept it, or the criterion is only measuring a box
#   C. the surface is the WAVE surface, not the flat plane: a probe band around the still level is
#      split by the waves. Control: the same probes against the flat plane, which cannot split them
#   D. the Area3D re-filter: a body that enters the box over the peninsula raises nothing, one that
#      enters over water raises body_submerged, and leaving raises body_surfaced. Control: the raw
#      Area3D body list, which contains both
#   E. the FogVolume is built and tinted from the WATER material, and the missing-volumetric-fog
#      warning names the setting. Control: with volumetric fog enabled the warning goes silent
#   F. overlay cost                                    [TIMING — skipped unless RUN_TIMING=1]
#
# Every criterion carries a control that must fail; criteria that ran to completion are counted, so
# a criterion that throws part-way cannot read as a pass.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/WaterBodiesPhase5Gate.tscn
#      RUN_TIMING=1 to include F.
extends Node

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const LAKE_MAT := WATER_DIR + "M_water_lake.tres"
const LOOP_PERIOD := 120.0

var _fail := 0
var _completed := 0
const CRITERIA := 6
var _run_timing := false


func _ready() -> void:
	var bail := Timer.new()
	bail.wait_time = 600.0
	bail.one_shot = true
	bail.timeout.connect(func():
		push_error("gate timed out")
		get_tree().quit(2))
	add_child(bail)
	bail.start()

	_run_timing = OS.get_environment("RUN_TIMING") != ""
	Engine.physics_ticks_per_second = 60
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	print("=== Pasture3D Water Bodies — Phase 5 gate ===")
	print("Godot %s | %s" % [
		Engine.get_version_info().string, RenderingServer.get_video_adapter_name()])
	print("")

	await _gate_a_camera_crossing()
	await _gate_b_concave()
	await _gate_c_wave_surface()
	await _gate_d_area_refilter()
	await _gate_e_fog()
	await _gate_f_overlay_cost()

	print("")
	if _completed != CRITERIA:
		_fail += 1
		print("!! only %d of %d criteria ran to completion" % [_completed, CRITERIA])
	var verdict := "FAIL (%d)" % _fail
	if _fail == 0:
		verdict = "PASS" if _run_timing else "PASS (CORRECTNESS ONLY -- timing skipped)"
	print("=== PHASE 5 GATE %s ===" % verdict)
	get_tree().quit(0 if _fail == 0 else 1)


# ---- A: the camera crossing ----------------------------------------------------
#
# A Camera3D is not a physics body and generates no area signals whatever, so this is a poll, and
# the thing a poll gets wrong is edges: firing every frame while under, or firing on neither
# crossing. The criterion counts SIGNALS, not states, so both failures are visible.
func _gate_a_camera_crossing() -> void:
	print("[A] the camera crossing, both directions:")
	var root := _make_world()
	_make_manager(root)
	var pool := _make_pool(root, 40.0)
	var cam := Camera3D.new()
	cam.current = true
	root.add_child(cam)
	# Park it above water and let that settle BEFORE listening. A Camera3D added at its parent's
	# origin starts at the still level — i.e. submerged about half the time, depending on where the
	# wave is — and the resulting first transition is real but is not one of the two being tested.
	cam.global_position = Vector3(0, pool.global_position.y + 8.0, 0)
	await _settle()

	var events: Array = []
	pool.camera_submerged.connect(func(under: bool): events.append(under))

	# Above -> under -> above, with several frames at each stop so a per-frame emitter shows up.
	await _settle()
	var above_1: bool = pool.is_point_underwater(cam.global_position)
	cam.global_position = Vector3(0, pool.global_position.y - 6.0, 0)
	await _settle()
	await _settle()
	var under: bool = pool.is_point_underwater(cam.global_position)
	cam.global_position = Vector3(0, pool.global_position.y + 8.0, 0)
	await _settle()
	await _settle()
	var above_2: bool = pool.is_point_underwater(cam.global_position)

	if not (above_1 == false and under == true and above_2 == false):
		_fail += 1
		print("    !! the point test read above=%s under=%s above=%s" % [above_1, under, above_2])
	elif events != [true, false]:
		_fail += 1
		print("    !! camera_submerged fired %s, expected [true, false] — one per crossing" % [events])
	else:
		print("    down and up: %d signals, %s — one per crossing, not one per frame" % [
			events.size(), events])
	root.queue_free()
	await _settle()

	# Control: outside the loop at the same depth. Without this, "the camera went under" is just
	# "the camera went below a Y value", which is not what a finite body means.
	var croot := _make_world()
	_make_manager(croot)
	var cpool := _make_pool(croot, 40.0)
	var ccam := Camera3D.new()
	ccam.current = true
	croot.add_child(ccam)
	ccam.global_position = Vector3(300, cpool.global_position.y + 8.0, 0)
	await _settle()
	var cevents: Array = []
	cpool.camera_submerged.connect(func(u: bool): cevents.append(u))
	# 300 m out in XZ, but well below the water plane.
	ccam.global_position = Vector3(300, cpool.global_position.y - 6.0, 0)
	await _settle()
	await _settle()
	if cevents.is_empty() and not cpool.is_point_underwater(ccam.global_position):
		print("    control (below the plane but outside the loop): fires — no signal, dry")
	else:
		_fail += 1
		print("    !! control did NOT fire: events %s, underwater %s" % [
			cevents, cpool.is_point_underwater(ccam.global_position)])
	croot.queue_free()
	await _settle()
	_completed += 1


# ---- B: the concave case -------------------------------------------------------
#
# The Area3D's box is a broad phase and the spec says so. An L-shaped lake has a notch between its
# arms that is inside the box and is dry land; if the volume answered from the box, every character
# standing there would be swimming.
func _gate_b_concave() -> void:
	print("[B] a peninsula inside the volume box is dry:")
	var root := _make_world()
	_make_manager(root)
	var pool := _make_pool_curve(root, _l_curve(60.0))
	await _settle()

	# The notch of the L: inside the bounding box, outside the polygon.
	var notch := Vector3(40, pool.global_position.y - 3.0, 40)
	var water := Vector3(-40, pool.global_position.y - 3.0, -40)
	var box: CollisionShape3D = _volume_shape_of(pool)
	if box == null:
		_fail += 1
		print("    !! the pool built no volume, so there is no box to be inside of")
		root.queue_free()
		await _settle()
		_completed += 1
		return

	# Control FIRST: the notch has to actually be inside the box, or the criterion below is
	# comparing two things that already agree and proves nothing.
	var half: Vector3 = (box.shape as BoxShape3D).size * 0.5
	var local_notch: Vector3 = pool.global_transform.affine_inverse() * notch - box.position
	var in_box := absf(local_notch.x) <= half.x and absf(local_notch.y) <= half.y \
		and absf(local_notch.z) <= half.z
	if in_box:
		print("    control (the box accepts the notch): fires — box is %.0f x %.0f x %.0f m" % [
			half.x * 2.0, half.y * 2.0, half.z * 2.0])
	else:
		_fail += 1
		print("    !! control did NOT fire: the notch is outside the box, so this tests nothing")

	var notch_wet: bool = pool.is_point_underwater(notch)
	var water_wet: bool = pool.is_point_underwater(water)
	if not notch_wet and water_wet:
		print("    the notch reads dry and the arm reads wet, at the same depth")
	else:
		_fail += 1
		print("    !! notch underwater %s (want false), arm underwater %s (want true)" % [
			notch_wet, water_wet])
	root.queue_free()
	await _settle()
	_completed += 1


# ---- C: the wave surface, not the plane ----------------------------------------
#
# §8.2: "at the shoreline in a 1 m swell the difference is the entire effect". A test against the
# flat plane would be simpler and would be wrong every time a crest or trough passes. The proof is
# that probes in a band AROUND the still level come back mixed — some wet, some dry, at the same Y.
func _gate_c_wave_surface() -> void:
	print("[C] submersion is tested against the wave surface, not the plane:")
	var root := _make_world()
	var manager := _make_manager(root)
	var pool := _make_pool(root, 60.0)
	await _settle()
	# Freeze the clock so the probes below all describe one instant of one surface.
	manager.paused = true
	await _settle()

	var level: float = pool.global_position.y
	var wet := 0
	var dry := 0
	var span_lo := INF
	var span_hi := -INF
	# A lattice across the pool, each probe exactly AT the still level. Whether it is under water is
	# then entirely a question of where the wave is there.
	for ix in 8:
		for iz in 8:
			var x := -25.0 + ix * 7.0
			var z := -25.0 + iz * 7.0
			var h: float = pool.get_water_height(Vector2(x, z))
			span_lo = minf(span_lo, h)
			span_hi = maxf(span_hi, h)
			if pool.is_point_underwater(Vector3(x, level, z)):
				wet += 1
			else:
				dry += 1
	print("    64 probes at the still level: %d under water, %d above it" % [wet, dry])
	print("    wave surface spans %.3f m across the lattice" % (span_hi - span_lo))
	if span_hi - span_lo < 0.02:
		_fail += 1
		print("    !! the surface is essentially flat here, so this cannot distinguish anything")
	elif wet == 0 or dry == 0:
		_fail += 1
		print("    !! all 64 probes agree, which is what a FLAT-plane test would produce")
	else:
		print("    -> split by the waves, which a flat-plane test could not do")

	# Control: the same probes against the plane. It must NOT split them — that is the whole point.
	var plane_wet := 0
	for ix in 8:
		for iz in 8:
			if level <= pool.global_position.y:
				plane_wet += 1
	if plane_wet == 64:
		print("    control (the same probes vs the flat plane): fires — 64/64 identical")
	else:
		_fail += 1
		print("    !! control did NOT fire: the flat-plane test split them too (%d)" % plane_wet)
	manager.paused = false
	root.queue_free()
	await _settle()
	_completed += 1


# ---- D: the Area3D re-filter ---------------------------------------------------
#
# The Area3D fires on the BOX. A body standing on the peninsula is inside that box permanently and
# never fires anything while being very much on dry land, so the signals the pool re-emits have to
# be filtered through the exact test rather than forwarded.
func _gate_d_area_refilter() -> void:
	print("[D] body signals are re-filtered through the exact test:")
	var root := _make_world()
	_make_manager(root)
	var pool := _make_pool_curve(root, _l_curve(60.0))
	await _settle()

	var submerged: Array = []
	var surfaced: Array = []
	pool.body_submerged.connect(func(b): submerged.append(String(b.name)))
	pool.body_surfaced.connect(func(b): surfaced.append(String(b.name)))

	var on_notch := _make_body(root, "OnPeninsula",
		Vector3(40, pool.global_position.y - 3.0, 40))
	var in_water := _make_body(root, "InWater",
		Vector3(-40, pool.global_position.y - 3.0, -40))
	await _settle()
	await _settle()

	var raw := _volume_of(pool).get_overlapping_bodies() if _volume_of(pool) else []
	var raw_names: Array = []
	for b in raw:
		raw_names.append(String(b.name))
	raw_names.sort()
	# Control: the raw Area3D list has to contain BOTH, or the filtering below is not filtering.
	if raw_names.has("OnPeninsula") and raw_names.has("InWater"):
		print("    control (the raw Area3D list): fires — holds both %s" % [raw_names])
	else:
		_fail += 1
		print("    !! control did NOT fire: the box holds %s" % [raw_names])

	if submerged == ["InWater"]:
		print("    body_submerged fired for InWater only")
	else:
		_fail += 1
		print("    !! body_submerged fired %s, expected [InWater]" % [submerged])

	# Leaving the water, without leaving the box: walk the swimmer onto the peninsula.
	in_water.global_position = Vector3(40, pool.global_position.y - 3.0, 40)
	await _settle()
	await _settle()
	if surfaced == ["InWater"]:
		print("    walking it onto the peninsula fired body_surfaced, without leaving the box")
	else:
		_fail += 1
		print("    !! body_surfaced fired %s, expected [InWater]" % [surfaced])
	root.queue_free()
	await _settle()
	_completed += 1


# ---- E: the fog, and the warning that stops the bug report ---------------------
#
# §8.3 names this as "the single most likely 'it doesn't work' report from this feature": a
# FogVolume renders nothing at all unless the Environment has volumetric fog on, with no error of
# any kind. So the criterion is as much about the warning as about the fog.
func _gate_e_fog() -> void:
	print("[E] the fog is tinted from the water material, and the warning names the setting:")
	var root := _make_world()
	_make_manager(root)
	var pool := _make_pool(root, 40.0)
	await _settle()

	var fog := _fog_of(pool)
	if fog == null or fog.material == null:
		_fail += 1
		print("    !! no FogVolume was built")
	else:
		var fmat: FogMaterial = fog.material
		var smat: ShaderMaterial = pool.material
		var deep: Color = smat.get_shader_parameter("deep_color")
		var absorption: Vector3 = smat.get_shader_parameter("absorption")
		var want_density: float = (0.2126 * absorption.x + 0.7152 * absorption.y
			+ 0.0722 * absorption.z) * pool.underwater_density_scale
		var tint_ok := fmat.albedo.is_equal_approx(deep)
		var density_ok := absf(fmat.density - want_density) < 1e-5
		if tint_ok and density_ok:
			print("    fog albedo == the material's deep_color %s, density %.4f from absorption %s"
				% [fmat.albedo, fmat.density, absorption])
		else:
			_fail += 1
			print("    !! albedo %s vs deep_color %s | density %.4f vs %.4f" % [
				fmat.albedo, deep, fmat.density, want_density])

	# The warning, with no volumetric fog anywhere in the scene.
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.volumetric_fog_enabled = false
	root.add_child(env)
	await _settle()
	var warned := _warns_about_fog(pool)
	if warned:
		print("    with volumetric_fog_enabled off, the pool warns and names the setting")
	else:
		_fail += 1
		print("    !! no warning about volumetric fog: %s" % [pool._get_configuration_warnings()])

	# Control: switching it on must silence exactly that warning. A warning that is always there is
	# a warning nobody reads.
	env.environment.volumetric_fog_enabled = true
	await _settle()
	if not _warns_about_fog(pool):
		print("    control (enable it -> the warning clears): fires")
	else:
		_fail += 1
		print("    !! control did NOT fire: still warning with volumetric fog enabled")
	root.queue_free()
	await _settle()
	_completed += 1


# ---- F: overlay cost -----------------------------------------------------------
#
# TIMING. Off by default: this machine is shared with another engine, so a frame-time number taken
# without warning is a number that means nothing (see §11.3's accepted anomaly).
func _gate_f_overlay_cost() -> void:
	print("[F] the overlay's frame cost:")
	if not _run_timing:
		print("    SKIPPED (set RUN_TIMING=1 to measure)")
		_completed += 1
		return
	var root := _make_world()
	_make_manager(root)
	var pool := _make_pool(root, 60.0)
	var cam := Camera3D.new()
	cam.current = true
	root.add_child(cam)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	await _settle()

	cam.global_position = Vector3(0, pool.global_position.y + 8.0, 0)
	await _settle()
	var dry := await _measure_gpu_ms()
	cam.global_position = Vector3(0, pool.global_position.y - 6.0, 0)
	# Let the ramp finish, or the number is the cost of a half-faded overlay.
	for i in 30:
		await get_tree().process_frame
	await _settle()
	var wet := await _measure_gpu_ms()
	var overlay_present := _overlay_of(pool) != null

	# The resolution is part of the result, not context for it: this is a full-screen fragment pass,
	# so its cost is per-pixel and a number without the pixel count cannot be compared to anything.
	var res: Vector2i = get_viewport().get_visible_rect().size
	var px: int = res.x * res.y
	print("    at %d x %d (%.2f Mpx):" % [res.x, res.y, px / 1e6])
	print("    above water %.4f ms | below water %.4f ms | delta %.4f ms (%.2f ns/px)" % [
		dry, wet, wet - dry, (wet - dry) * 1e6 / float(px)])
	if not overlay_present:
		_fail += 1
		print("    !! no overlay was built, so the 'below' number is not measuring one")
	elif dry <= 0.0 or wet <= 0.0:
		_fail += 1
		print("    !! GPU timing read zero — measured nothing, not 'measured fast'")
	else:
		print("    -> recorded; a full-screen pass at this resolution is the expected shape")
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), false)
	root.queue_free()
	await _settle()
	_completed += 1


func _measure_gpu_ms() -> float:
	var rid := get_viewport().get_viewport_rid()
	var samples: Array[float] = []
	for i in 90:
		await RenderingServer.frame_post_draw
		samples.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
	samples.sort()
	return samples[samples.size() / 2]


# ---- helpers -------------------------------------------------------------------

func _make_world() -> Node3D:
	var root := Node3D.new()
	add_child(root)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-38, 130, 0)
	root.add_child(sun)
	return root


func _make_manager(p_root: Node3D) -> Pasture3DPoolManager:
	var m := Pasture3DPoolManager.new()
	m.name = "Pasture3DPoolManager"
	m.loop_period = LOOP_PERIOD
	p_root.add_child(m)
	m.sun_light = p_root.get_node("Sun")
	return m


func _make_pool(p_root: Node3D, p_r: float) -> Pasture3DPool:
	return _make_pool_curve(p_root, _square_curve(p_r))


func _make_pool_curve(p_root: Node3D, p_curve: Curve3D) -> Pasture3DPool:
	var pool := Pasture3DPool.new()
	pool.name = "Pool"
	pool.curve = p_curve
	pool.wave_profile = &"lake_calm"
	pool.material = load(LAKE_MAT)
	p_root.add_child(pool)
	return pool


## A closed square loop of the given half-extent.
func _square_curve(p_r: float) -> Curve3D:
	var c := Curve3D.new()
	c.add_point(Vector3(-p_r, 0, -p_r))
	c.add_point(Vector3(p_r, 0, -p_r))
	c.add_point(Vector3(p_r, 0, p_r))
	c.add_point(Vector3(-p_r, 0, p_r))
	c.closed = true
	return c


## An L: the notch at (+, +) is inside the bounding box and outside the polygon.
func _l_curve(p_r: float) -> Curve3D:
	var c := Curve3D.new()
	c.add_point(Vector3(-p_r, 0, -p_r))
	c.add_point(Vector3(p_r, 0, -p_r))
	c.add_point(Vector3(p_r, 0, 0))
	c.add_point(Vector3(0, 0, 0))
	c.add_point(Vector3(0, 0, p_r))
	c.add_point(Vector3(-p_r, 0, p_r))
	c.closed = true
	return c


## A body with a small box, for the Area3D signals.
##
## CharacterBody3D and not StaticBody3D, and that is not arbitrary: Godot 4.4+ defaults 3D physics
## to Jolt, whose areas do NOT report static bodies unless
## physics/jolt_physics_3d/simulation/areas_detect_static_bodies is enabled. A StaticBody3D fixture
## here would sit inside the volume forever and raise nothing, and the criterion would be measuring
## that rather than the re-filter. The things that swim are characters and rigid bodies anyway.
func _make_body(p_root: Node3D, p_name: String, p_pos: Vector3) -> CharacterBody3D:
	var body := CharacterBody3D.new()
	body.name = p_name
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3.ONE
	shape.shape = box
	body.add_child(shape)
	p_root.add_child(body)
	body.global_position = p_pos
	return body


func _volume_of(p_pool: Node) -> Area3D:
	for c in p_pool.get_children():
		if c is Area3D:
			return c
	return null


func _volume_shape_of(p_pool: Node) -> CollisionShape3D:
	var vol := _volume_of(p_pool)
	if vol == null:
		return null
	for c in vol.get_children():
		if c is CollisionShape3D:
			return c
	return null


func _fog_of(p_pool: Node) -> FogVolume:
	for c in p_pool.get_children():
		if c is FogVolume:
			return c
	return null


func _overlay_of(p_pool: Node) -> CanvasLayer:
	for c in p_pool.get_children():
		if c is CanvasLayer:
			return c
	return null


func _warns_about_fog(p_pool: Node) -> bool:
	for w in p_pool._get_configuration_warnings():
		if String(w).contains("volumetric_fog_enabled"):
			return true
	return false


func _settle() -> void:
	for i in 4:
		await get_tree().physics_frame
	for i in 4:
		await RenderingServer.frame_post_draw
