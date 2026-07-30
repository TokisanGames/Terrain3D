# Pasture3D Water Bodies — Phase 3 exit gate (spec §11, PASTURE3D_WATER_BODIES_SPEC.md).
#
# Phase 3 adds Pasture3DPool: a finite water body meshed from a brush's spline, plus
# the body registry deferred from Phase 1.
#
# Gate criteria, from the spec's phase table:
#   A. a 500 m lake rebuilds in <= 500 ms          [TIMING — skipped by SKIP_TIMING=1]
#   B. automatic vertex spacing meets the L_min/8 rule; the control is 4x spacing,
#      which must show measurably more surface sag
#   C. a pool in a scene with no Pasture3D
#   D. a pool sharing a brush's curve does not trip the brush's shared-curve warning
#   E. the body registry: body_at() finds the pool for a point inside it, the ocean
#      for a point outside, and honours a CONCAVE outline
#
# Every criterion carries a control that must fail; criteria that ran to completion
# are counted, so a criterion that throws cannot read as a pass.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/WaterBodiesPhase3Gate.tscn
#      SKIP_TIMING=1 to run everything except A.
extends Node

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const LAKE_MAT := WATER_DIR + "M_water_lake.tres"
const OCEAN_MAT := WATER_DIR + "M_water_ocean.tres"

const LOOP_PERIOD := 120.0
const BUILD_BUDGET_MS := 500.0

var _fail := 0
var _completed := 0
const CRITERIA := 5
var _skip_timing := false
var _out_dir := ""


func _ready() -> void:
	var bail := Timer.new()
	bail.wait_time = 600.0
	bail.one_shot = true
	bail.timeout.connect(func():
		push_error("gate timed out")
		get_tree().quit(2))
	add_child(bail)
	bail.start()

	_skip_timing = OS.get_environment("SKIP_TIMING") != ""
	_out_dir = OS.get_environment("BENCH_OUT")
	if _out_dir == "":
		_out_dir = "user://"
	Engine.physics_ticks_per_second = 60
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	print("=== Pasture3D Water Bodies — Phase 3 gate ===")
	print("Godot %s | %s" % [
		Engine.get_version_info().string, RenderingServer.get_video_adapter_name()])
	print("")

	await _gate_a_build_time()
	await _gate_b_spacing_rule()
	await _gate_c_no_terrain()
	await _gate_d_shared_curve()
	await _gate_e_registry()

	print("")
	if _completed != CRITERIA:
		_fail += 1
		print("!! only %d of %d criteria ran to completion" % [_completed, CRITERIA])
	var verdict := "FAIL (%d)" % _fail
	if _fail == 0:
		verdict = "PASS (CORRECTNESS ONLY -- timing skipped)" if _skip_timing else "PASS"
	print("=== PHASE 3 GATE %s ===" % verdict)
	get_tree().quit(0 if _fail == 0 else 1)


# ---- A: build time -------------------------------------------------------------
# The spec's budget: a 500 m lake at the automatic spacing, rebuilt off the interaction
# path, in <= 500 ms. §4.3 chose GDScript for this node over C++ knowing the brushes
# had to move rasterisation to C++ to stay usable, and this is the measurement that
# decides whether that call was right (§12 q1 holds the escape hatch).
#
# The control is the vertex count: a build that produced almost no geometry would be
# fast and meaningless, so the criterion asserts the mesh is actually large.
func _gate_a_build_time() -> void:
	print("[A] a 500 m lake rebuilds inside %.0f ms:" % BUILD_BUDGET_MS)
	if _skip_timing:
		print("    SKIPPED (timing pass disabled)")
		_completed += 1
		return
	var root := _make_world()
	_make_manager(root)
	var pool := _make_pool(root, _square_curve(250.0), "lake_calm")
	await _settle()

	var stats: Dictionary = pool.rebuild()
	print("    spacing %.2f m -> %d vertices, %d triangles in %.1f ms" % [
		stats["spacing"], stats["vertices"], stats["triangles"], stats["ms"]])
	if not stats["ok"]:
		_fail += 1
		print("    !! the build failed: %s" % stats["reason"])
	elif int(stats["vertices"]) < 50000:
		_fail += 1
		print("    !! only %d vertices; this is not the 500 m lake the budget is for," % int(stats["vertices"]))
		print("       so the timing below measures something else")
	elif float(stats["ms"]) > BUILD_BUDGET_MS:
		_fail += 1
		print("    !! over the %.0f ms budget; see spec §12 q1 for the native escape hatch" % BUILD_BUDGET_MS)
	else:
		print("    -> inside budget")
	root.queue_free()
	await _settle()
	_completed += 1


# ---- B: the spacing rule -------------------------------------------------------
# Waves are a vertex effect, so spacing is correctness. The water guide requires vertex
# spacing <= L_min/8; below that the drawn surface chords across crests and drifts from
# what get_water_height() reports, which is the number a boat floats on.
#
# Measured as SAG: the gap between the analytic surface and the flat chord between two
# adjacent vertices, at the cell centre. The control is 4x spacing, which must show
# materially more sag -- otherwise the metric is not sensitive to spacing at all and
# the criterion proves nothing.
func _gate_b_spacing_rule() -> void:
	print("")
	print("[B] automatic vertex spacing honours the L_min/8 rule:")
	var root := _make_world()
	var manager := _make_manager(root)
	var pool := _make_pool(root, _square_curve(60.0), "lake_calm")
	await _settle()

	var profile = manager.get_profile("lake_calm")
	var l_min: float = profile.get_min_wavelength()
	var auto_stats: Dictionary = pool.rebuild()
	var auto_spacing: float = auto_stats["spacing"]
	var ratio := l_min / maxf(auto_spacing, 1e-6)
	print("    shortest wavelength %.2f m | automatic spacing %.2f m | ratio %.2f" % [
		l_min, auto_spacing, ratio])
	if ratio < 8.0 - 1e-3:
		_fail += 1
		print("    !! ratio below 8; the surface will visibly chord across crests")
	else:
		print("    -> meets the rule")

	var sag_auto := _measure_sag(manager, "lake_calm", auto_spacing)
	pool.vertex_spacing = auto_spacing * 4.0
	pool.rebuild()
	var sag_coarse := _measure_sag(manager, "lake_calm", auto_spacing * 4.0)
	print("    surface sag at automatic spacing: %.4f m" % sag_auto)
	print("    CONTROL, sag at 4x spacing:       %.4f m (must be materially worse)" % sag_coarse)
	if sag_coarse <= sag_auto * 2.0:
		_fail += 1
		print("    !! coarsening the grid 4x barely changes the sag, so this metric is")
		print("       not measuring tessellation and B proves nothing")

	root.queue_free()
	await _settle()
	_completed += 1


## Worst gap between the analytic surface and the chord between adjacent vertices,
## sampled at cell centres along a line. This is the quantity the L_min/8 rule bounds.
func _measure_sag(p_manager: Node, p_profile: StringName, p_spacing: float) -> float:
	var worst := 0.0
	for i in 200:
		var x := -100.0 + i * 0.7
		var a: float = p_manager.evaluate_height(p_profile, Vector2(x, 0.0))
		var b: float = p_manager.evaluate_height(p_profile, Vector2(x + p_spacing, 0.0))
		var mid: float = p_manager.evaluate_height(p_profile, Vector2(x + p_spacing * 0.5, 0.0))
		worst = maxf(worst, absf(mid - (a + b) * 0.5))
	return worst


# ---- C: a pool with no terrain -------------------------------------------------
# Same claim as the ocean's (W4): the water bodies are independent of Pasture3D. A pool
# is authored FROM a brush, which does need a terrain, so it would be easy for the pool
# to have picked up a dependency without anyone noticing.
#
# The control asserts there is genuinely no Pasture3D in the tree -- "it worked" would
# otherwise be satisfied by one having been left behind by an earlier criterion.
func _gate_c_no_terrain() -> void:
	print("")
	print("[C] a pool in a scene with no Pasture3D:")
	var root := _make_world()
	_make_manager(root)
	var pool := _make_pool(root, _square_curve(40.0), "pond_still")
	await _settle()
	var stats: Dictionary = pool.rebuild()

	var terrains := 0
	for n in _all_nodes(root):
		if n.get_class() == "Pasture3D":
			terrains += 1
	print("    Pasture3D nodes in the scene: %d (must be 0)" % terrains)
	print("    built: %s | %d vertices" % [str(stats["ok"]), int(stats["vertices"])])
	var h: float = pool.get_water_height(Vector2(3.0, -7.0))
	print("    get_water_height(3,-7) = %.6f" % h)
	if terrains != 0:
		_fail += 1
		print("    !! a Pasture3D is present, so C does not test what it claims")
	if not stats["ok"] or int(stats["vertices"]) < 100:
		_fail += 1
		print("    !! the pool did not build without a terrain")
	if not is_finite(h):
		_fail += 1
		print("    !! the height query returned a non-finite value")
	root.queue_free()
	await _settle()
	_completed += 1


# ---- D: sharing a brush's curve ------------------------------------------------
# Pasture3DTerrainBrush warns when two splines share a Curve3D, because duplicating a
# brush shares the curve by reference and one edit then drives every clone's bake -- a
# silent performance trap. A pool READING a brush's curve is the intended case for this
# whole feature and must not trip it.
#
# The control is the warning still firing for the case it exists for: two real splines
# sharing a curve. Without that, "no warning" would also be what a broken check looks
# like.
func _gate_d_shared_curve() -> void:
	print("")
	print("[D] a pool sharing a brush's curve does not trip the shared-curve warning:")
	var root := _make_world()
	_make_manager(root)

	var brush := Pasture3DMound.new()
	brush.name = "Basin"
	root.add_child(brush)
	var spline := Path3D.new()
	spline.name = "Loop1"
	spline.curve = _square_curve(30.0)
	brush.add_child(spline)
	await _settle()

	var pool := Pasture3DPool.new()
	pool.name = "BasinWater"
	pool.source_spline = spline
	pool.material = load(LAKE_MAT)
	root.add_child(pool)
	await _settle()

	var warned := _has_shared_curve_warning(brush)
	print("    brush warns about a shared curve with a pool attached: %s (must be false)" % str(warned))
	if warned:
		_fail += 1
		print("    !! the intended case trips the warning; every pool would nag")

	# The control: a second SPLINE sharing the same Curve3D. That is the trap the
	# warning exists for and it must still fire.
	var twin := Path3D.new()
	twin.name = "Loop2"
	twin.curve = spline.curve
	brush.add_child(twin)
	await _settle()
	var warned_twin := _has_shared_curve_warning(brush)
	print("    CONTROL, two splines sharing one Curve3D: %s (must be true)" % str(warned_twin))
	if not warned_twin:
		_fail += 1
		print("    !! the shared-curve warning no longer fires at all, so D is vacuous")

	root.queue_free()
	await _settle()
	_completed += 1


func _has_shared_curve_warning(p_brush: Node) -> bool:
	for w in p_brush._get_configuration_warnings():
		if String(w).contains("share a Curve3D"):
			return true
	return false


# ---- E: the body registry ------------------------------------------------------
# Deferred from Phase 1 because nothing implemented a body then. body_at() is what
# lets a buoy (Phase 6) work without being told which lake it is in.
#
# The concave case is the point. A pool's outline is frequently concave, and an AABB
# test would claim the notch of an L-shaped lake is water. The control is exactly that
# point: inside the bounding box, outside the polygon.
func _gate_e_registry() -> void:
	print("")
	print("[E] the body registry finds the right body:")
	var root := _make_world()
	var manager := _make_manager(root)

	# An L-shaped pool: the notch is inside its AABB but outside its outline.
	var l_curve := Curve3D.new()
	for p in [Vector3(-40, 0, -40), Vector3(40, 0, -40), Vector3(40, 0, 0),
			Vector3(0, 0, 0), Vector3(0, 0, 40), Vector3(-40, 0, 40)]:
		l_curve.add_point(p)
	l_curve.closed = true
	var pool := _make_pool(root, l_curve, "lake_calm")
	pool.edge_offset = 0.0
	pool.global_position = Vector3.ZERO

	var ocean := Pasture3DOcean.new()
	ocean.material = load(OCEAN_MAT)
	ocean.wave_profile = "lake_calm"
	root.add_child(ocean)
	# AFTER add_child: global_position needs a tree, and setting it before leaves the
	# node at the origin with only a console warning -- so the ocean's sea level would
	# have been 0 rather than -50, and this criterion would have been testing a
	# different scene than the one it describes.
	ocean.global_position = Vector3(0, -50, 0)
	await _settle()
	pool.rebuild()

	var bodies: Array = manager.get_bodies()
	print("    registered bodies: %d (pool + ocean = 2)" % bodies.size())
	if bodies.size() != 2:
		_fail += 1
		print("    !! expected exactly the pool and the ocean")

	# Deep inside the L's arm, below the surface.
	var inside := Vector3(-20.0, -1.0, -20.0)
	var got_inside = manager.body_at(inside)
	print("    body_at(inside the pool)  -> %s" % (got_inside.name if got_inside else "<null>"))
	if got_inside != pool:
		_fail += 1
		print("    !! a point inside the pool did not resolve to the pool")

	# Far outside the pool entirely, below the ocean's surface.
	var far := Vector3(5000.0, -60.0, 5000.0)
	var got_far = manager.body_at(far)
	print("    body_at(open water)       -> %s" % (got_far.name if got_far else "<null>"))
	if got_far != ocean:
		_fail += 1
		print("    !! a point in open water did not fall through to the ocean")

	# CONTROL: the notch. Inside the pool's bounding box, outside its outline. An AABB
	# test would call this water.
	var notch := Vector3(20.0, -1.0, 20.0)
	var got_notch = manager.body_at(notch)
	var in_box := pool._surface != null and pool._surface.custom_aabb.has_point(
		Vector3(notch.x, 0.0, notch.z))
	print("    CONTROL, the concave notch: inside the mesh AABB: %s | body_at -> %s" % [
		str(in_box), (got_notch.name if got_notch else "<null>")])
	if not in_box:
		_fail += 1
		print("    !! the notch is not inside the AABB, so it does not test concavity")
	elif got_notch == pool:
		_fail += 1
		print("    !! the notch resolved to the pool, so containment is a box test")

	root.queue_free()
	await _settle()
	_completed += 1


# ---- helpers -------------------------------------------------------------------

func _make_world() -> Node3D:
	var root := Node3D.new()
	add_child(root)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-38, 130, 0)
	root.add_child(sun)
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.position = Vector3(0, 30, 0)
	cam.rotation_degrees = Vector3(-25, 0, 0)
	cam.current = true
	root.add_child(cam)
	return root


func _make_manager(p_root: Node3D) -> Pasture3DPoolManager:
	var m := Pasture3DPoolManager.new()
	m.name = "Pasture3DPoolManager"
	m.loop_period = LOOP_PERIOD

	var lake := Pasture3DWaveProfile.new()
	lake.profile_name = "lake_calm"
	lake.wave_count = 4
	lake.amplitude = 0.42
	lake.length_max = 60.0
	lake.steepness = 0.35

	var pond := Pasture3DWaveProfile.new()
	pond.profile_name = "pond_still"
	pond.wave_count = 2
	pond.amplitude = 0.09
	pond.length_max = 18.0
	pond.steepness = 0.20

	var profiles: Array[Pasture3DWaveProfile] = [lake, pond]
	m.profiles = profiles
	p_root.add_child(m)
	m.sun_light = p_root.get_node("Sun")
	return m


func _make_pool(p_root: Node3D, p_curve: Curve3D, p_profile: StringName) -> Pasture3DPool:
	var pool := Pasture3DPool.new()
	pool.name = "Pool"
	pool.curve = p_curve
	pool.wave_profile = p_profile
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


func _all_nodes(p_root: Node) -> Array:
	var out := [p_root]
	for c in p_root.get_children():
		out.append_array(_all_nodes(c))
	return out


func _settle() -> void:
	for i in 4:
		await get_tree().physics_frame
	for i in 4:
		await RenderingServer.frame_post_draw
