# Pasture3D Water Bodies — Phase 6 exit gate (spec §11, PASTURE3D_WATER_BODIES_SPEC.md).
#
# Phase 6 is Pasture3DBuoy: one sample point on a RigidBody3D, several of which make a hull float
# with pitch and roll for free.
#
# Gate criteria, from the spec's phase table ("boat floats level and still; 64 buoys <= 0.5 ms/tick;
# body handoff lake -> ocean without a frame of free-fall"):
#
#   A. a boat settles at the equilibrium the arithmetic PREDICTS, level and still. Not "it did not
#      sink" — the depth is computed from mass and displacement up front and the boat has to land
#      on it. Control: an under-displaced boat, which must sink through the water and keep going
#   B. angular drag is applied once per BODY, not once per buoy: one buoy and four buoys of the
#      same total displacement must damp a spin the same. Control: a body with 4x the angular_drag,
#      which is what per-buoy application would look like, and which must decay visibly faster
#   C. the handoff — a boat crossing from a pool into the ocean re-resolves its body WITHOUT a tick
#      of zero submersion. Control: the resolved body must actually change, or nothing was crossed
#   D. the sinking warning names the two numbers. Control: a floating boat is silent
#   E. 64 buoys <= 0.5 ms per physics tick   [TIMING — skipped unless RUN_TIMING=1]
#
# Every criterion carries a control that must fail; criteria that ran to completion are counted, so
# a criterion that throws part-way cannot read as a pass.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/WaterBodiesPhase6Gate.tscn
#      RUN_TIMING=1 to include E.
extends Node

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const LAKE_MAT := WATER_DIR + "M_water_lake.tres"
const OCEAN_MAT := WATER_DIR + "M_water_ocean.tres"

const LOOP_PERIOD := 120.0
## §9.3's budget.
const BUOY_BUDGET_MS := 0.5
const BUOY_COUNT := 64

var _fail := 0
var _completed := 0
const CRITERIA := 5
var _run_timing := false


func _ready() -> void:
	var bail := Timer.new()
	bail.wait_time = 900.0
	bail.one_shot = true
	bail.timeout.connect(func():
		push_error("gate timed out")
		get_tree().quit(2))
	add_child(bail)
	bail.start()

	_run_timing = OS.get_environment("RUN_TIMING") != ""
	Engine.physics_ticks_per_second = 60
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	print("=== Pasture3D Water Bodies — Phase 6 gate ===")
	print("Godot %s | %s" % [
		Engine.get_version_info().string, RenderingServer.get_video_adapter_name()])
	print("")

	await _gate_a_floats()
	await _gate_b_angular_once_per_body()
	await _gate_c_handoff()
	await _gate_d_warning()
	await _gate_e_cost()

	print("")
	if _completed != CRITERIA:
		_fail += 1
		print("!! only %d of %d criteria ran to completion" % [_completed, CRITERIA])
	var verdict := "FAIL (%d)" % _fail
	if _fail == 0:
		verdict = "PASS" if _run_timing else "PASS (CORRECTNESS ONLY -- timing skipped)"
	print("=== PHASE 6 GATE %s ===" % verdict)
	get_tree().quit(0 if _fail == 0 else 1)


# ---- A: the boat floats where the arithmetic says ------------------------------
#
# "It floated" is a weak claim — a boat with far too much displacement also floats, sitting on top
# of the water like a cork, and so does one whose drag is so high it never moved. So the criterion
# predicts the settling depth from mass and displacement BEFORE running anything, and requires the
# boat to land on it:
#
#     equilibrium frac  f = (mass / 1000) / sum(displacement)
#     settling depth      = f * full_depth   below the surface
#
# That is spec §9.1's model solved for rest, and it is the number the configuration warning quotes.
# If the force model is wrong in any of its terms, the boat settles somewhere else.
#
# On a near-flat profile, deliberately: "still" and "level" are only meaningful on a surface that is
# not itself moving. Wave response is Phase 1's business and is gated there.
func _gate_a_floats() -> void:
	print("[A] a boat settles at the predicted equilibrium, level and still:")
	var root := _make_world()
	_make_manager(root, 0.0005) # near-flat: amplitude half a millimetre
	var pool := _make_pool(root, 120.0)
	await _settle()

	# mass 400 kg needs 0.400 m3; four buoys at 0.15 give 0.600 -> f = 0.667 of full_depth.
	var boat := _make_boat(root, 400.0, 4, 0.15, Vector3(0, 6, 0))
	var f: float = (400.0 / 1000.0) / 0.6
	var expect_y: float = pool.global_position.y - f * 0.5
	await _run_physics(420)

	var y: float = boat.global_position.y
	var vel: float = boat.linear_velocity.length()
	var tilt: float = rad_to_deg(boat.global_transform.basis.get_euler().length())
	var spin: float = boat.angular_velocity.length()
	print("    predicted %.3f m (f = %.3f of full_depth) | settled %.3f m" % [expect_y, f, y])
	print("    residual: %.4f m/s linear, %.4f rad/s angular, %.3f deg of tilt" % [vel, spin, tilt])
	if absf(y - expect_y) > 0.03:
		_fail += 1
		print("    !! settled %.3f m from the prediction — the force model does not balance" % (y - expect_y))
	elif vel > 0.05 or spin > 0.05:
		_fail += 1
		print("    !! still moving, so this is not an equilibrium")
	elif tilt > 1.0:
		_fail += 1
		print("    !! not level")
	else:
		print("    -> within 3 cm of the prediction, at rest, level")

	# Control: an under-displaced boat must SINK. Without this, "it floated" could be a boat that
	# was never pulled down in the first place.
	var sinker := _make_boat(root, 400.0, 4, 0.05, Vector3(60, 6, 0)) # 0.20 m3 vs 0.40 needed
	var start_y: float = sinker.global_position.y
	await _run_physics(420)
	var sunk: float = start_y - sinker.global_position.y
	if sinker.global_position.y < pool.global_position.y - 2.0:
		print("    control (0.20 m3 against 0.40 needed): fires — sank %.1f m and kept going" % sunk)
	else:
		_fail += 1
		print("    !! control did NOT fire: it only dropped %.2f m" % sunk)
	root.queue_free()
	await _settle()
	_completed += 1


# ---- B: angular drag is per body, not per buoy ---------------------------------
#
# Four buoys on a hull must not damp its spin four times as hard as one. If they did, adding sample
# points to get better pitch and roll would silently change the boat's handling — the same hull
# would rotate differently for having been modelled more carefully, which is the worst kind of bug
# because it looks like tuning.
#
# The implementation applies angular damping once per body per tick, using the previous tick's
# largest submersion across that body's buoys. This is the criterion that holds it to that.
func _gate_b_angular_once_per_body() -> void:
	print("")
	print("[B] angular drag is applied once per body, whatever the buoy count:")
	var root := _make_world()
	_make_manager(root, 0.0005)
	_make_pool(root, 200.0)
	await _settle()

	# Same total displacement, same drag, different numbers of sample points — and all the buoys
	# STACKED at the body origin (spread 0).
	#
	# That last part is the whole trick, and the first version of this criterion got it wrong. Buoys
	# spread across a hull resist rotation through their LINEAR drag: each one's -v_point term is
	# evaluated at its own offset, so a spinning body drags four separated buoys sideways through
	# the water and is slowed enormously. That is correct physics and is most of why four sample
	# points feel better than one — but it is not the angular_drag term, and it swamped it by three
	# orders of magnitude. Stacking the buoys makes every offset zero, so the linear term
	# contributes no torque at all and the only thing damping the spin is the term under test.
	var one := _make_boat(root, 400.0, 1, 0.6, Vector3(-40, 0, 0), 0.0)
	var four := _make_boat(root, 400.0, 4, 0.15, Vector3(0, 0, 0), 0.0)
	# The reference for what PER-BUOY application would look like: four times the angular drag.
	var quad := _make_boat(root, 400.0, 1, 0.6, Vector3(40, 0, 0), 0.0)
	for b in quad.get_children():
		if b is Pasture3DBuoy:
			b.angular_drag = 8.0
	await _settle()

	var spin := Vector3(0, 2.0, 0)
	one.angular_velocity = spin
	four.angular_velocity = spin
	quad.angular_velocity = spin
	await _run_physics(120)

	var w1: float = one.angular_velocity.length()
	var w4: float = four.angular_velocity.length()
	var wq: float = quad.angular_velocity.length()
	print("    after 2 s from 2.00 rad/s: 1 buoy %.4f | 4 buoys %.4f | 4x drag %.4f" % [w1, w4, wq])
	var spread: float = absf(w4 - w1) / maxf(w1, 1e-6)
	if spread > 0.20:
		_fail += 1
		print("    !! 4 buoys damped %.0f%% differently from 1 — the per-body guard is not holding"
			% (spread * 100.0))
	else:
		print("    -> 1 and 4 buoys agree to within %.1f%%" % (spread * 100.0))

	# Control: the 4x-drag body must be clearly different, or the comparison above has no resolution
	# and would pass however the damping was applied.
	var gap: float = absf(w4 - wq) / maxf(w4, 1e-6)
	if gap > 0.20:
		print("    control (4x angular_drag, i.e. what per-buoy would look like): fires — %.0f%% apart"
			% (gap * 100.0))
	else:
		_fail += 1
		print("    !! control did NOT fire: 4x drag is only %.0f%% away, so the check above" % (gap * 100.0))
		print("       could not have detected per-buoy application either")
	root.queue_free()
	await _settle()
	_completed += 1


# ---- C: the lake-to-ocean handoff ----------------------------------------------
#
# §9.2. A boat leaving a lake for the ocean must not fall for a frame while the registry catches up.
# One tick of zero buoyancy at 60 Hz is a visible twitch, and it is exactly what a naive "re-resolve
# every N ticks" would produce.
func _gate_c_handoff() -> void:
	print("")
	print("[C] a boat crossing from a pool to the ocean never loses its footing:")
	var root := _make_world()
	_make_manager(root, 0.0005)
	var pool := _make_pool(root, 60.0)
	var ocean := Pasture3DOcean.new()
	ocean.name = "Ocean"
	ocean.material = load(OCEAN_MAT)
	ocean.wave_profile = &"flat_test"
	root.add_child(ocean)
	# Same level, so a horizontal move keeps the boat equally submerged and any dropout is the
	# registry's doing rather than geometry's.
	ocean.global_position = Vector3(0, pool.global_position.y, 0)
	await _settle()

	var boat := _make_boat(root, 400.0, 1, 0.6, Vector3(0, 0, 0))
	var buoy: Pasture3DBuoy = boat.get_child(1)
	await _run_physics(60)
	var body_before = buoy.get_resolved_body()

	# Walk it out past the rim, a metre a tick, sampling every tick.
	var min_submersion := 1.0
	var bodies_seen := {}
	for i in 200:
		boat.global_position = Vector3(boat.global_position.x + 1.0,
			pool.global_position.y - 0.4, boat.global_position.z)
		boat.linear_velocity = Vector3.ZERO
		await get_tree().physics_frame
		var b = buoy.get_resolved_body()
		if b != null:
			bodies_seen[b.name] = true
		min_submersion = minf(min_submersion, buoy.get_submersion())
	var body_after = buoy.get_resolved_body()

	print("    started in %s, ended in %s, %d distinct bodies seen" % [
		body_before, body_after, bodies_seen.size()])
	print("    lowest submersion across 200 ticks of crossing: %.3f" % min_submersion)
	# Control FIRST: it has to have actually crossed. If both ends are the same body the criterion
	# below is measuring a boat that never went anywhere.
	if body_before != null and body_after != null and body_before != body_after:
		print("    control (the body actually changed): fires — %s -> %s" % [
			body_before.name, body_after.name])
	else:
		_fail += 1
		print("    !! control did NOT fire: the resolved body never changed")
	if min_submersion <= 0.0:
		_fail += 1
		print("    !! submersion hit zero — that is the frame of free-fall the spec forbids")
	else:
		print("    -> never dropped to zero: no free-fall frame")
	root.queue_free()
	await _settle()
	_completed += 1


# ---- D: the sinking warning ----------------------------------------------------
#
# "Why does my boat sink" is a numbers puzzle with no way in: mass and displacement are in different
# places and the ratio between them is nowhere. The warning quotes both and the shortfall.
func _gate_d_warning() -> void:
	print("")
	print("[D] a boat that will sink says so, with the numbers:")
	var root := _make_world()
	_make_manager(root, 0.0005)
	_make_pool(root, 60.0)
	var sinker := _make_boat(root, 400.0, 4, 0.05, Vector3(0, 2, 0)) # 0.20 vs 0.40 needed
	await _settle()
	var buoy: Pasture3DBuoy = sinker.get_child(1)
	var warns: PackedStringArray = buoy.get_buoyancy_warnings()
	var found := ""
	for w in warns:
		if String(w).contains("SINK"):
			found = String(w)
	print("    have %.3f m3, need %.3f m3" % [
		buoy.get_body_displacement(), buoy.get_required_displacement()])
	if found != "" and found.contains("0.200") and found.contains("0.400"):
		print("    warning quotes both numbers: \"%s\"" % found.substr(0, 90))
	elif found != "":
		_fail += 1
		print("    !! it warns but does not quote both numbers: %s" % found)
	else:
		_fail += 1
		print("    !! no sinking warning at all: %s" % [warns])

	# Control: a boat that floats must be silent, or the warning is noise nobody reads.
	var floater := _make_boat(root, 400.0, 4, 0.15, Vector3(30, 2, 0))
	await _settle()
	var fbuoy: Pasture3DBuoy = floater.get_child(1)
	var quiet := true
	for w in fbuoy.get_buoyancy_warnings():
		if String(w).contains("SINK"):
			quiet = false
	if quiet:
		print("    control (a boat that floats): fires — silent")
	else:
		_fail += 1
		print("    !! control did NOT fire: a floating boat still warns about sinking")
	root.queue_free()
	await _settle()
	_completed += 1


# ---- E: cost -------------------------------------------------------------------
#
# §9.3's budget: 64 buoys inside 0.5 ms per physics tick. Measured by calling apply_buoyancy
# directly rather than by reading the engine's physics timer, so the number is this code's cost and
# not the engine's — the buoys' own _physics_process is switched off for the duration so the work is
# not being done twice.
func _gate_e_cost() -> void:
	print("")
	print("[E] %d buoys inside %.1f ms per physics tick:" % [BUOY_COUNT, BUOY_BUDGET_MS])
	if not _run_timing:
		print("    SKIPPED (set RUN_TIMING=1 to measure)")
		_completed += 1
		return
	var root := _make_world()
	_make_manager(root, 0.42) # the real lake_calm amplitude: the wave solve is the cost
	var pool := _make_pool(root, 300.0)
	await _settle()

	var ms_64 := await _measure_buoys(root, pool, BUOY_COUNT)
	var ms_256 := await _measure_buoys(root, pool, BUOY_COUNT * 4)
	print("    %3d buoys: %.4f ms/tick" % [BUOY_COUNT, ms_64])
	print("    %3d buoys: %.4f ms/tick" % [BUOY_COUNT * 4, ms_256])
	if ms_64 <= 0.0:
		_fail += 1
		print("    !! the timer read zero — measured nothing, not 'measured fast'")
	elif ms_64 > BUOY_BUDGET_MS:
		_fail += 1
		print("    !! over the %.1f ms budget; sample_interval is the knob (§9.3)" % BUOY_BUDGET_MS)
	else:
		print("    -> inside budget, with %.0f%% to spare" % ((1.0 - ms_64 / BUOY_BUDGET_MS) * 100.0))
	# Control: 4x the buoys must cost materially more. A measurement that did not scale would mean
	# the loop is not doing the work being budgeted for.
	if ms_256 > ms_64 * 2.0:
		print("    control (4x the buoys): fires — %.1fx the cost" % (ms_256 / maxf(ms_64, 1e-9)))
	else:
		_fail += 1
		print("    !! control did NOT fire: 4x the buoys cost only %.1fx, so this is not measuring"
			% (ms_256 / maxf(ms_64, 1e-9)))

	# sample_interval, the escape hatch §9.3 offers, measured rather than asserted.
	var ms_skip := await _measure_buoys(root, pool, BUOY_COUNT * 4, 2)
	print("    %3d buoys at sample_interval 2: %.4f ms/tick (%.0f%% of interval 1)" % [
		BUOY_COUNT * 4, ms_skip, ms_skip / maxf(ms_256, 1e-9) * 100.0])
	root.queue_free()
	await _settle()
	_completed += 1


## Median per-tick cost of running `p_count` buoys, in ms. Their own _physics_process is disabled so
## the work is done exactly once, here, where it can be timed.
func _measure_buoys(p_root: Node3D, p_pool: Node, p_count: int, p_interval: int = 1) -> float:
	var boat := _make_boat(p_root, 4000.0, p_count, 0.1, Vector3(0, 0, 0), 40.0)
	var buoys: Array = []
	for c in boat.get_children():
		if c is Pasture3DBuoy:
			c.set_physics_process(false)
			c.sample_interval = p_interval
			buoys.append(c)
	await _settle()
	# Prime: the first call per buoy resolves its body and takes the slow path.
	for b in buoys:
		b.apply_buoyancy(1.0 / 60.0)

	var samples: Array[float] = []
	for rep in 9:
		var t0 := Time.get_ticks_usec()
		for b in buoys:
			b.apply_buoyancy(1.0 / 60.0)
		samples.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		await get_tree().physics_frame
	samples.sort()
	boat.queue_free()
	await _settle()
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


## A manager carrying one profile, `flat_test`, whose amplitude the caller chooses. Criteria A-D use
## a near-flat surface so "level and still" is a meaningful assertion; E uses a real one, because the
## wave solve is the cost being budgeted.
func _make_manager(p_root: Node3D, p_amplitude: float) -> Pasture3DPoolManager:
	var m := Pasture3DPoolManager.new()
	m.name = "Pasture3DPoolManager"
	m.loop_period = LOOP_PERIOD
	var profile := Pasture3DWaveProfile.new()
	profile.profile_name = "flat_test"
	profile.wave_count = 2
	profile.amplitude = p_amplitude
	profile.length_max = 60.0
	profile.steepness = 0.2
	var profiles: Array[Pasture3DWaveProfile] = [profile]
	m.profiles = profiles
	p_root.add_child(m)
	m.sun_light = p_root.get_node("Sun")
	return m


func _make_pool(p_root: Node3D, p_r: float) -> Pasture3DPool:
	var pool := Pasture3DPool.new()
	pool.name = "Pool"
	pool.curve = _square_curve(p_r)
	pool.wave_profile = &"flat_test"
	pool.material = load(LAKE_MAT)
	pool.underwater_enabled = false # nothing here needs the Area3D; keep the fixture minimal
	p_root.add_child(pool)
	return pool


## A hull: a RigidBody3D with `p_count` buoys spread across a square of half-extent `p_spread`.
func _make_boat(p_root: Node3D, p_mass: float, p_count: int, p_displacement: float,
		p_pos: Vector3, p_spread: float = 1.0) -> RigidBody3D:
	var boat := RigidBody3D.new()
	boat.mass = p_mass
	boat.can_sleep = false # a sleeping body stops integrating, and every criterion here watches it
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2, 1, 4)
	shape.shape = box
	boat.add_child(shape)
	# Buoys on a grid, all at the SAME local Y so the predicted equilibrium in criterion A is one
	# depth rather than a per-buoy solve.
	var side := int(ceil(sqrt(float(p_count))))
	for i in p_count:
		var buoy := Pasture3DBuoy.new()
		buoy.name = "Buoy%d" % i
		buoy.displacement = p_displacement
		buoy.full_depth = 0.5
		buoy.linear_drag = 400.0
		buoy.angular_drag = 2.0
		boat.add_child(buoy)
		var ix := i % side
		var iz := i / side
		var step := (p_spread * 2.0) / maxf(float(side - 1), 1.0)
		buoy.position = Vector3(-p_spread + ix * step, 0.0, -p_spread + iz * step) \
			if side > 1 else Vector3.ZERO
	p_root.add_child(boat)
	boat.global_position = p_pos
	return boat


func _square_curve(p_r: float) -> Curve3D:
	var c := Curve3D.new()
	c.add_point(Vector3(-p_r, 0, -p_r))
	c.add_point(Vector3(p_r, 0, -p_r))
	c.add_point(Vector3(p_r, 0, p_r))
	c.add_point(Vector3(-p_r, 0, p_r))
	c.closed = true
	return c


func _run_physics(p_ticks: int) -> void:
	for i in p_ticks:
		await get_tree().physics_frame


func _settle() -> void:
	for i in 4:
		await get_tree().physics_frame
	for i in 4:
		await RenderingServer.frame_post_draw
