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
# F, G and H are the buoy remediation's Phase 1 (PASTURE3D_BUOY_REMEDIATION_SPEC.md §2), added
# because A-E all passed while the ocean path cost twice what §9.3 budgets. Criterion E measures a
# Pasture3DPool, which memoises get_water_height(); Pasture3DOcean did not, so a buoy in open water
# ran the Gerstner inverse twice per tick — once through contains_point() in the body resolve and
# once for the height sample — and nothing here looked:
#
#   F. one buoy over an OCEAN costs exactly one solve per tick, not two. Control: a forced second
#      query at another position, which must take the counter to 2
#   G. the §9.3 budget holds on the ocean, in solves as well as milliseconds. Control: 4x the buoys
#      must cost exactly 4x the solves
#   H. the memo does not move the answer, and it is dropped when the answer changes for a reason
#      other than the frame. Control: moving the ocean mid-frame must change the height, and the
#      pre-move value must then compare UNEQUAL — so the comparison is known to be able to fail
#
# I, J and K are Phase 2 of the same remediation (§3). Once the memo made the second query free,
# sample_interval — §9.3's documented relief valve for crowds of buoys — was throttling only the
# free one, and saved nothing at any N. The resolve and the sample now happen on the same tick:
#
#   I. sample_interval N costs 1/N the solves. Control: N = 1 over 8 ticks must read exactly 8, or
#      the counter is not counting ticks and the ratios below mean nothing
#   J. a boat at N = 4 settles where a boat at N = 1 does — the HEIGHT is held, not the force, so
#      the buoy still answers its own motion between samples. Control: holding frac instead must
#      miss the predicted equilibrium
#   K. handoff latency is bounded by sample_interval and by nothing else. Control: the same crossing
#      at N = 1 must resolve faster, or the test is not sensitive to the interval
#
# L, M and N are Phase 3 (§4) — the force model against the engine's actual rigid body rather than an
# idealised one. All three were invisible to A–E because the fixture was a box centred on its origin,
# at gravity_scale 1, with can_sleep switched off:
#
#   L. drag's lever arm is the centre of mass, not the node origin. Control: the two arms must
#      predict measurably different forces, or the fixture cannot tell them apart
#   M. gravity_scale does not move the waterline (the equilibrium is scale-invariant). Control: a
#      genuinely under-buoyant boat must sink
#   N. a settled boat that has gone to sleep still rises when the water does. Control: it must
#      actually have been asleep first
#
# O, P, Q and R are Phase 4 (§5) — the buoy's bookkeeping rather than its physics. Each is state that
# outlives the tick it describes, or a set membership nobody checked:
#
#   O. an explicit water_body that has left the tree is no body, and the boat falls rather than
#      floating on a phantom flat plane. Control: with the body in the tree it must float
#   P. angular damping does not depend on child order even when the buoys carry different
#      angular_drag. Control: an all-low hull must damp measurably differently
#   Q. unfreezing does not apply damping saved from before the freeze. Control: an ordinary tick
#      must take a visible bite, or "it lost nothing" is what any tick would say
#   R. a nested RigidBody3D's buoys do not count toward the hull. Control: the dinghy must have
#      displacement of its own, or nothing was excluded
#
# These are stated in SOLVE COUNTS rather than milliseconds on purpose. A count is an integer, it is
# reproducible on a contended machine, and it says which implementation was measured — all three of
# which the millisecond budget failed to do. Pasture3DPoolManager.get_solve_count() is the
# instrument, and it is the same idea as get_upload_count() from Phase 1 of the water bodies spec.
#
# Every criterion carries a control that must fail; criteria that ran to completion are counted, so
# a criterion that throws part-way cannot read as a pass.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/WaterBodiesPhase6Gate.tscn
#      RUN_TIMING=1 to include E and G's millisecond half. F, G's solve counts and H always run.
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
const CRITERIA := 18
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
	await _gate_f_ocean_solves_once()
	await _gate_g_ocean_budget()
	await _gate_h_memo_parity()
	await _gate_i_sample_interval_saves()
	await _gate_j_held_height_not_force()
	await _gate_k_handoff_latency()
	await _gate_l_centre_of_mass_lever()
	await _gate_m_gravity_scale()
	await _gate_n_sleep()
	await _gate_o_water_body_validity()
	await _gate_p_drag_order_independent()
	await _gate_q_freeze_residue()
	await _gate_r_nested_bodies()

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
	# Same level as the pool, so a horizontal move keeps the boat equally submerged and any dropout
	# is the registry's doing rather than geometry's.
	_make_ocean(root, pool.global_position.y)
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


## solve_domain() calls made by `p_count` buoys over `p_ticks` physics ticks.
##
## The counting twin of _measure_buoys(), and the one the criteria actually turn on: an integer that
## does not care how busy the machine is. Their own _physics_process is disabled for the same reason
## it is there — the engine would otherwise run apply_buoyancy() a second time per frame and every
## count would be doubled by work nobody asked for.
##
## The ticks are separated by a real physics frame because the memo is keyed on the frame counter.
## Counting two passes inside one frame would measure the memo, not the tick.
func _solves_per_tick(p_root: Node3D, p_manager: Pasture3DPoolManager, p_count: int,
		p_interval: int = 1, p_ticks: int = 1) -> int:
	var boat := _make_boat(p_root, 4000.0, p_count, 0.1, Vector3.ZERO, 40.0)
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
	await get_tree().physics_frame

	p_manager.reset_solve_count()
	for t in p_ticks:
		if t > 0:
			await get_tree().physics_frame
		for b in buoys:
			b.apply_buoyancy(1.0 / 60.0)
	var solves := p_manager.get_solve_count()
	boat.queue_free()
	await _settle()
	return solves


## Median per-tick cost of running `p_count` buoys, in ms. Their own _physics_process is disabled so
## the work is done exactly once, here, where it can be timed.
##
## `p_body` is documentation rather than plumbing: the buoys resolve their own body from the manager's
## registry, so what this measures is whatever water is in `p_root`. Pass the body anyway, so the call
## site says which one is being measured — criterion E reads a pool and criterion G an ocean, and that
## difference is the whole reason G exists.
func _measure_buoys(p_root: Node3D, p_body: Node, p_count: int, p_interval: int = 1) -> float:
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


# ---- F: the ocean costs one solve per buoy per tick, not two --------------------
#
# The defect this exists for: _resolve_body() asks the cached body contains_point(), which on an
# ocean is a vertical test against get_water_height(); apply_buoyancy() then asks get_water_height()
# directly. Same position, same frame, two full solve_domain() calls — until Pasture3DOcean got the
# memo Pasture3DWaterBody always had.
#
# Counted, not timed. Two solves versus one is a 2x on the dominant cost and it hid inside the noise
# of a millisecond budget measured on the other body implementation.
func _gate_f_ocean_solves_once() -> void:
	print("")
	print("[F] one buoy over an ocean costs one solve per tick:")
	var root := _make_world()
	var manager := _make_manager(root, 0.42) # a real amplitude: the solve has to be worth counting
	var ocean := _make_ocean(root, 0.0)
	await _settle()

	var boat := _make_boat(root, 400.0, 1, 0.6, Vector3(0, -0.2, 0))
	var buoy: Pasture3DBuoy = boat.get_child(1)
	# Its own _physics_process would run apply_buoyancy a second time per frame and warm the memo
	# from outside the measurement. Same reason _measure_buoys() does this.
	buoy.set_physics_process(false)
	await _settle()

	# Prime: the first call resolves the body and takes the slow path.
	buoy.apply_buoyancy(1.0 / 60.0)
	await get_tree().physics_frame # a new frame, so the memo is cold again

	manager.reset_solve_count()
	buoy.apply_buoyancy(1.0 / 60.0)
	var solves := manager.get_solve_count()
	print("    resolved body: %s | solves for one tick: %d" % [
		buoy.get_resolved_body(), solves])

	# Control FIRST: the counter has to be able to reach 2, or "1" means the instrument is stuck
	# rather than the cost being one. A DIFFERENT position, so the memo cannot serve it.
	ocean.get_water_height(Vector2(4321.0, 8765.0))
	var after_forced := manager.get_solve_count()
	if after_forced == solves + 1:
		print("    control (a forced query elsewhere): fires — counter went %d -> %d"
			% [solves, after_forced])
	else:
		_fail += 1
		print("    !! control did NOT fire: forcing a second query moved the counter %d -> %d, so it"
			% [solves, after_forced])
		print("       is not counting solves and the number above means nothing")

	if solves == 1:
		print("    -> exactly one solve per buoy per tick")
	else:
		_fail += 1
		print("    !! %d solves, not 1 — the containment check and the height sample are not"
			% solves)
		print("       sharing a memo (2 = the pre-remediation ocean path)")
	root.queue_free()
	await _settle()
	_completed += 1


# ---- G: the §9.3 budget, on the ocean --------------------------------------------
#
# Criterion E's question asked of the body a boat in open water actually floats on. The solve count
# is the load-bearing half and runs always; the millisecond half is inherited from E and is advisory,
# because this machine shares a GPU and a contended run reads like a regression.
func _gate_g_ocean_budget() -> void:
	print("")
	print("[G] %d buoys on an OCEAN, in solves and (optionally) milliseconds:" % BUOY_COUNT)
	var root := _make_world()
	var manager := _make_manager(root, 0.42)
	_make_ocean(root, 0.0)
	await _settle()

	var solves_64 := await _solves_per_tick(root, manager, BUOY_COUNT)
	var solves_256 := await _solves_per_tick(root, manager, BUOY_COUNT * 4)
	print("    %3d buoys: %d solves/tick" % [BUOY_COUNT, solves_64])
	print("    %3d buoys: %d solves/tick" % [BUOY_COUNT * 4, solves_256])

	# Control: 4x the buoys must be exactly 4x the solves. An EXACT multiple, not "materially more" —
	# the count is an integer and anything else means buoys are sharing or repeating work by accident.
	if solves_256 == solves_64 * 4:
		print("    control (4x the buoys): fires — exactly 4x the solves")
	else:
		_fail += 1
		print("    !! control did NOT fire: %d buoys cost %d solves and %d cost %d, which is not 4x"
			% [BUOY_COUNT, solves_64, BUOY_COUNT * 4, solves_256])
	if solves_64 == BUOY_COUNT:
		print("    -> one solve per buoy per tick at scale")
	else:
		_fail += 1
		print("    !! %d buoys cost %d solves; the budget is one each" % [BUOY_COUNT, solves_64])

	if _run_timing:
		var ms_64 := await _measure_buoys(root, null, BUOY_COUNT)
		print("    %3d buoys: %.4f ms/tick (budget %.1f)" % [BUOY_COUNT, ms_64, BUOY_BUDGET_MS])
		if ms_64 <= 0.0:
			_fail += 1
			print("    !! the timer read zero — measured nothing, not 'measured fast'")
		elif ms_64 > BUOY_BUDGET_MS:
			_fail += 1
			print("    !! over the %.1f ms budget on the ocean" % BUOY_BUDGET_MS)
		else:
			print("    -> inside budget, with %.0f%% to spare"
				% ((1.0 - ms_64 / BUOY_BUDGET_MS) * 100.0))
	else:
		print("    milliseconds SKIPPED (set RUN_TIMING=1); the solve counts above are the criterion")
	root.queue_free()
	await _settle()
	_completed += 1


# ---- H: the memo does not move the answer ---------------------------------------
#
# A cache that is faster and wrong is worse than no cache. Two things have to hold: within a frame the
# memoised answer must equal the arithmetic it stands in for, and outside the frame key the memo must
# be dropped whenever the answer changes for another reason — this node's Y (sea level IS the node's
# Y, §6.1), the domain origin, or the wave profile.
#
# This criterion does NOT prove the memo exists — a build with no cache at all passes it, and one was
# run to check that. F and G are what fail when the memo is missing; H is what fails when it is
# present and lying. Both halves are needed and neither substitutes for the other.
#
# Two comparisons with two different standards, deliberately:
#
#   miss vs hit   EXACT. Both are the same real_t the C++ query returned, so a difference means the
#                 memo stored or returned something other than what it computed.
#   hit vs fresh  within 1e-5 m. NOT slack for the memo — the reconstruction crosses the language
#                 boundary, so `sea_level + evaluate_height(...)` is summed as two float32s inside
#                 get_water_height() and as two doubles here. Those round differently in the last
#                 bit or two of a float32, at no fault of the cache. 1e-5 m is a hundredth of a
#                 millimetre: far below anything the wave model means, far above float32 noise.
func _gate_h_memo_parity() -> void:
	print("")
	print("[H] the height memo returns what the solve would have:")
	var root := _make_world()
	var manager := _make_manager(root, 0.42)
	var ocean := _make_ocean(root, 0.0)
	await _settle()

	const PARITY_EPS := 1.0e-5
	var origin := ocean.domain_origin
	var not_transparent := 0 # miss != hit: the memo changed the value it stored
	var not_parity := 0      # hit != the arithmetic it stands in for
	var worst := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260806
	for i in 200:
		var xz := Vector2(rng.randf_range(-2000.0, 2000.0), rng.randf_range(-2000.0, 2000.0))
		var miss := ocean.get_water_height(xz)  # populates
		var hit := ocean.get_water_height(xz)   # served from the memo
		var target := xz - Vector2(origin.x, origin.z)
		var fresh: float = ocean.get_sea_level() \
			+ manager.evaluate_height(&"flat_test", manager.solve_domain(&"flat_test", target))
		if miss != hit:
			not_transparent += 1
		var delta := absf(hit - fresh)
		worst = maxf(worst, delta)
		if delta > PARITY_EPS:
			not_parity += 1
	# %s for the epsilon, not %e: GDScript's format has no %e and throws on it, which printed the
	# raw format string and left this criterion passing with its numbers unreadable.
	print("    200 positions | memo hit != miss: %d | hit vs fresh: %d over %s m (worst %.9f m)"
		% [not_transparent, not_parity, str(PARITY_EPS), worst])
	if not_transparent == 0 and not_parity == 0:
		print("    -> the memo is transparent")
	else:
		_fail += 1
		print("    !! the memo returns a different surface than the solve does")

	# Invalidation, WITHIN a frame. force_update_transform() flushes the notification immediately —
	# without it Godot defers NOTIFICATION_TRANSFORM_CHANGED to the end of the frame and the frame
	# key would invalidate the memo anyway, which would prove nothing about the drop.
	var probe := Vector2(12.0, -7.0)
	var before := ocean.get_water_height(probe)
	ocean.global_position = Vector3(0, 5.0, 0)
	ocean.force_update_transform()
	var after := ocean.get_water_height(probe)
	if is_equal_approx(after - before, 5.0):
		print("    control (move the ocean 5 m mid-frame): fires — height moved %.4f m"
			% (after - before))
	else:
		_fail += 1
		print("    !! control did NOT fire: the ocean moved 5 m mid-frame and the height moved"
			+ " %.4f m — the memo is not being dropped on the transform" % (after - before))
	# ...and the same numbers as control 2: the pre-move value must now compare UNEQUAL to the
	# post-move one. If it did not, the equality test above could not have detected a mismatch
	# either, and 0 mismatches would mean nothing.
	if before != after:
		print("    control (the comparison can fail): fires — %.4f != %.4f" % [before, after])
	else:
		_fail += 1
		print("    !! control did NOT fire: pre- and post-move heights compare EQUAL, so the"
			+ " equality test in this criterion cannot detect a mismatch")

	# The domain origin is the other synchronous invalidation, and it goes through a setter rather
	# than a deferred notification, so it can be checked without forcing anything.
	var pre_origin := ocean.get_water_height(probe)
	ocean.domain_origin = Vector3(137.0, 0.0, 419.0)
	var post_origin := ocean.get_water_height(probe)
	if pre_origin != post_origin:
		print("    control (domain_origin mid-frame): fires — %.4f -> %.4f"
			% [pre_origin, post_origin])
	else:
		_fail += 1
		print("    !! control did NOT fire: domain_origin changed and the height did not")
	root.queue_free()
	await _settle()
	_completed += 1


# ---- I: sample_interval buys what §9.3 says it buys ------------------------------
#
# N ticks per sample must cost 1/N the solves. It used to cost all of them: the interval gated the
# height read, the memo had already made the height read free, and the body resolve underneath —
# which is the same wave query, at full price — ran every tick regardless.
#
# Counted over 8 ticks rather than one, because the saving only exists across ticks: a single tick at
# N = 4 is either a sampling tick or not, and neither number on its own is the rate.
func _gate_i_sample_interval_saves() -> void:
	print("")
	print("[I] sample_interval N costs 1/N the solves:")
	var root := _make_world()
	var manager := _make_manager(root, 0.42)
	_make_ocean(root, 0.0)
	await _settle()

	const TICKS := 8
	var n1 := await _solves_per_tick(root, manager, 1, 1, TICKS)
	var n2 := await _solves_per_tick(root, manager, 1, 2, TICKS)
	var n4 := await _solves_per_tick(root, manager, 1, 4, TICKS)
	print("    one buoy over %d ticks: N=1 %d solves | N=2 %d | N=4 %d" % [TICKS, n1, n2, n4])

	# Control FIRST: N = 1 has to read one solve per tick exactly. If it does not, the counter is not
	# counting ticks and the ratios below are arithmetic on noise.
	if n1 == TICKS:
		print("    control (N=1 over %d ticks): fires — exactly %d solves" % [TICKS, TICKS])
	else:
		_fail += 1
		print("    !! control did NOT fire: N=1 cost %d solves over %d ticks, so the counts below"
			% [n1, TICKS])
		print("       are not measuring one solve per tick")
	if n2 == TICKS / 2 and n4 == TICKS / 4:
		print("    -> the interval divides the cost: %d, %d, %d for N = 1, 2, 4" % [n1, n2, n4])
	else:
		_fail += 1
		print("    !! expected %d and %d solves at N=2 and N=4, got %d and %d — the interval is not"
			% [TICKS / 2, TICKS / 4, n2, n4])
		print("       throttling the body resolve, only the (free) height read")
	root.queue_free()
	await _settle()
	_completed += 1


# ---- J: the HEIGHT is held, not the force ----------------------------------------
#
# The saving in I is only allowed because of what is held between samples. Holding the wave height
# leaves the buoy computing its own submersion from its own position every tick, so it still answers
# its own motion; holding the force would leave it pushing with yesterday's number and the boat would
# ring rather than settle.
#
# So this is criterion A re-run at N = 4, and it asserts the same two things A does: the boat lands on
# the predicted depth AND it is at rest when it gets there. The second is the one that separates the
# two designs — a held force still floats a boat, it just will not stop moving.
func _gate_j_held_height_not_force() -> void:
	print("")
	print("[J] a boat at sample_interval 4 settles where a boat at 1 does:")
	var root := _make_world()
	_make_manager(root, 0.0005) # near-flat, for the same reason criterion A uses it
	var pool := _make_pool(root, 120.0)
	await _settle()

	# Criterion A's boat: 400 kg needs 0.400 m3, four buoys at 0.15 give 0.600 -> f = 0.667.
	var f: float = (400.0 / 1000.0) / 0.6
	var expect_y: float = pool.global_position.y - f * 0.5
	var fast := _make_boat(root, 400.0, 4, 0.15, Vector3(0, 6, 0))
	var slow := _make_boat(root, 400.0, 4, 0.15, Vector3(40, 6, 0))
	for c in slow.get_children():
		if c is Pasture3DBuoy:
			c.sample_interval = 4
	# The control: a boat that genuinely belongs somewhere else. It proves the settle-depth
	# comparison has the resolution to notice a difference — without it, "the two agree" would also
	# be true of a measurement that reads the same number whatever the boat does.
	var other := _make_boat(root, 400.0, 4, 0.20, Vector3(-40, 6, 0)) # f = 0.500, not 0.667
	var expect_other: float = pool.global_position.y - ((400.0 / 1000.0) / 0.8) * 0.5
	await _run_physics(420)

	var y1: float = fast.global_position.y
	var y4: float = slow.global_position.y
	var v4: float = slow.linear_velocity.length()
	var yo: float = other.global_position.y
	print("    predicted %.3f m | N=1 settled %.3f | N=4 settled %.3f (residual %.4f m/s)"
		% [expect_y, y1, y4, v4])
	if absf(yo - expect_other) < 0.03 and absf(yo - y4) > 0.05:
		print("    control (a boat with f = 0.500): fires — settled %.3f m, %.3f m away from N=4"
			% [yo, absf(yo - y4)])
	else:
		_fail += 1
		print("    !! control did NOT fire: the f = 0.500 boat settled %.3f m (expected %.3f), so"
			% [yo, expect_other])
		print("       this measurement cannot tell two equilibria apart")
	if absf(y4 - expect_y) > 0.03:
		_fail += 1
		print("    !! N=4 settled %.3f m from the prediction" % (y4 - expect_y))
	elif absf(y4 - y1) > 0.03:
		_fail += 1
		print("    !! N=4 and N=1 disagree by %.3f m" % absf(y4 - y1))
	elif v4 > 0.05:
		_fail += 1
		print("    !! N=4 is still moving at %.4f m/s — it is ringing, which is what holding the"
			% v4)
		print("       FORCE rather than the height would look like")
	else:
		print("    -> same equilibrium, at rest: the height is what is held")
	root.queue_free()
	await _settle()
	_completed += 1


# ---- K: handoff latency is bounded by sample_interval ----------------------------
#
# The price of I. Body resolution now happens on sampling ticks, so a buoy notices it has left its
# water within sample_interval ticks instead of on the tick it happens. That is a contract change to
# §9.2 and it needs a number on it, not a shrug.
#
# The crossing is a teleport rather than criterion C's walk, because this measures LATENCY and a walk
# spreads the crossing over the ticks being counted. And it is aligned first: the solve counter says
# which ticks sampled, so the teleport lands immediately after a sample and N=4 is deterministically
# four ticks away from noticing rather than "somewhere between one and four, depending".
func _gate_k_handoff_latency() -> void:
	print("")
	print("[K] a buoy notices it has left its body within sample_interval ticks:")
	var root := _make_world()
	var manager := _make_manager(root, 0.0005)
	var pool := _make_pool(root, 60.0)
	_make_ocean(root, pool.global_position.y)
	await _settle()

	var lat1 := await _handoff_latency(root, manager, pool, 1)
	var lat4 := await _handoff_latency(root, manager, pool, 4)
	print("    ticks to re-resolve after leaving the pool: N=1 %d | N=4 %d" % [lat1, lat4])

	# Control: the two intervals must differ, or this is not measuring the interval at all — a
	# latency of 1 at both would be the pre-Phase-2 behaviour and would read as a pass against a
	# bound of "<= N".
	if lat1 == 1 and lat4 > lat1:
		print("    control (N=1 resolves next tick): fires — %d vs %d ticks" % [lat1, lat4])
	else:
		_fail += 1
		print("    !! control did NOT fire: N=1 took %d ticks and N=4 took %d, so this is not"
			% [lat1, lat4])
		print("       sensitive to sample_interval")
	if lat4 >= 1 and lat4 <= 4:
		print("    -> bounded by sample_interval, as §9.2 now promises")
	else:
		_fail += 1
		print("    !! N=4 took %d ticks, outside the 1..4 the contract allows" % lat4)
	root.queue_free()
	await _settle()
	_completed += 1


## Ticks between a buoy leaving `p_pool` and its resolved body changing, at `p_interval`.
##
## Returns 99 if it never re-resolves inside a generous window, so a hang reads as a number the
## criterion can fail on rather than as a stuck gate.
func _handoff_latency(p_root: Node3D, p_manager: Pasture3DPoolManager, p_pool: Node,
		p_interval: int) -> int:
	var boat := _make_boat(p_root, 400.0, 1, 0.6, Vector3(0, p_pool.global_position.y - 0.2, 0))
	var buoy: Pasture3DBuoy = boat.get_child(1)
	buoy.set_physics_process(false)
	buoy.sample_interval = p_interval
	await _settle()
	for i in 8: # settle onto the pool and let the resolve cache warm
		buoy.apply_buoyancy(1.0 / 60.0)
		await get_tree().physics_frame

	# Align to a sampling tick. The solve counter is the only way to see one from here, and without
	# this the answer depends on where in the cycle the teleport happens to land.
	for i in 16:
		p_manager.reset_solve_count()
		buoy.apply_buoyancy(1.0 / 60.0)
		var sampled: bool = p_manager.get_solve_count() > 0
		await get_tree().physics_frame
		if sampled:
			break

	# Out of the pool (radius 60) and over open ocean, in one step.
	boat.global_position = Vector3(500.0, p_pool.global_position.y - 0.2, 0.0)
	var latency := 99
	for i in range(1, 17):
		buoy.apply_buoyancy(1.0 / 60.0)
		if buoy.get_resolved_body() != p_pool:
			latency = i
			break
		await get_tree().physics_frame
	boat.queue_free()
	await _settle()
	return latency


# ---- L: the drag lever arm is the centre of mass, not the node origin ------------
#
# get_linear_velocity() returns the velocity of the CENTRE OF MASS, so the point velocity a buoy
# needs is v_com + w x (p - com). The buoy used the node ORIGIN for that arm, and reused the same
# vector for apply_force(), whose offset genuinely IS origin-relative. The two coincide only when the
# centre of mass sits on the origin — which is what every fixture before this one built, and is not
# what a boat with a hull shape hanging below its origin looks like.
#
# Measured as a single tick of force rather than as a simulated behaviour, because the difference is
# then exact arithmetic instead of an argument about what a spinning boat ought to look like:
#
#   gravity_scale 0 and displacement 0     -> the ONLY force on the body is buoy drag
#   frac = 1, v = 0, w = (2,0,0)           -> the drag is fully determined by the lever arm
#   com at (0,-1.5,0), buoys at local y=0
#
#   right arm: w x (p-com) = (0,-2z,3) per buoy, four buoys -> sum (0,0,12)
#   wrong arm: w x (p-org) = (0,-2z,0) per buoy, four buoys -> sum (0,0,0)
#
# So the correct model pushes hard in -Z and the pre-fix one does not push at all. The predictions
# are recomputed here from the boat's own state rather than hardcoded, and the gate reads the net
# force back out of the velocity the engine integrated.
func _gate_l_centre_of_mass_lever() -> void:
	print("")
	print("[L] drag uses the centre of mass as its lever arm:")
	var root := _make_world()
	_make_manager(root, 0.0005)
	var pool := _make_pool(root, 120.0)
	await _settle()

	const COM := Vector3(0, -1.5, 0)
	const OMEGA := Vector3(2, 0, 0)
	const DT := 1.0 / 60.0
	# Sunk 0.6 m: deeper than full_depth (0.5), so frac is exactly 1 and drops out of the arithmetic.
	var boat := _make_boat(root, 400.0, 4, 0.0, Vector3(0, pool.global_position.y - 0.6, 0),
		1.0, COM, 0.0)
	var buoys: Array = []
	for c in boat.get_children():
		if c is Pasture3DBuoy:
			c.angular_drag = 0.0 # isolate the LINEAR drag term; angular damping would move w
			c.set_physics_process(false)
			buoys.append(c)
	await _settle()
	for b in buoys: # prime the body resolve so the measured tick is a plain one
		b.apply_buoyancy(DT)
	await get_tree().physics_frame

	# Predict both models from the boat's actual state.
	boat.linear_velocity = Vector3.ZERO
	boat.angular_velocity = OMEGA
	var com_world: Vector3 = boat.global_transform * COM
	var f_right := Vector3.ZERO
	var f_wrong := Vector3.ZERO
	for b in buoys:
		var p: Vector3 = b.global_position
		f_right += -(OMEGA.cross(p - com_world)) * b.linear_drag
		f_wrong += -(OMEGA.cross(p - boat.global_position)) * b.linear_drag
	print("    predicted net drag: COM arm %v | origin arm %v" % [f_right, f_wrong])

	# Control FIRST: the two models have to disagree, or this fixture cannot tell them apart and
	# whatever the engine reports would match both.
	if (f_right - f_wrong).length() > 100.0:
		print("    control (the two arms differ): fires — %.0f N apart"
			% (f_right - f_wrong).length())
	else:
		_fail += 1
		print("    !! control did NOT fire: the two lever arms predict forces only %.1f N apart,"
			% (f_right - f_wrong).length())
		print("       so this fixture cannot distinguish them")

	await get_tree().physics_frame
	boat.linear_velocity = Vector3.ZERO
	boat.angular_velocity = OMEGA
	for b in buoys:
		b.apply_buoyancy(DT)
	await get_tree().physics_frame
	# Only drag acted, so the momentum change over one tick IS the net force times the step.
	var measured: Vector3 = boat.linear_velocity * boat.mass / DT
	var err_right: float = (measured - f_right).length()
	var err_wrong: float = (measured - f_wrong).length()
	print("    measured from one tick of integration: %v" % measured)
	print("    distance to COM-arm prediction %.0f N | to origin-arm prediction %.0f N"
		% [err_right, err_wrong])
	if err_right < err_wrong and err_right < (f_right - f_wrong).length() * 0.25:
		print("    -> the engine integrated the COM-arm force")
	else:
		_fail += 1
		print("    !! the measured force is not the COM-arm one")
	root.queue_free()
	await _settle()
	_completed += 1


# ---- M: gravity_scale does not move the waterline --------------------------------
#
# Buoyancy has to balance the gravity the body is ACTUALLY under. The buoy read the project setting,
# which ignores RigidBody3D.gravity_scale and any Area3D override, so a hull at scale 2 weighed twice
# what its buoyancy was computed against and sank with a correct-looking displacement.
#
# The assertion is that the settling depth does NOT move, which is the whole point: equilibrium is
# rho*g*V*frac = m*g and the g cancels, so a correct implementation is scale-invariant and
# get_required_displacement() needs no change. A boat that settles deeper at scale 2 is the defect.
func _gate_m_gravity_scale() -> void:
	print("")
	print("[M] gravity_scale does not move the waterline:")
	var root := _make_world()
	_make_manager(root, 0.0005)
	var pool := _make_pool(root, 120.0)
	await _settle()

	var f: float = (400.0 / 1000.0) / 0.6
	var expect_y: float = pool.global_position.y - f * 0.5
	var g1 := _make_boat(root, 400.0, 4, 0.15, Vector3(0, 6, 0), 1.0, null, 1.0)
	var g2 := _make_boat(root, 400.0, 4, 0.15, Vector3(40, 6, 0), 1.0, null, 2.0)
	# Control: a boat that is genuinely under-buoyant must sink. 800 kg against 0.600 m3 needs
	# 0.800 — the SAME mismatch a scale-2 boat had before the fix, arrived at by doubling the mass
	# instead of the gravity. If this one floats, the fixture cannot see an unbalanced boat at all
	# and the two agreeing above would mean nothing.
	var heavy := _make_boat(root, 800.0, 4, 0.15, Vector3(-40, 6, 0), 1.0, null, 1.0)
	await _run_physics(420)

	var y1: float = g1.global_position.y
	var y2: float = g2.global_position.y
	var yh: float = heavy.global_position.y
	print("    predicted %.3f m | scale 1 settled %.3f | scale 2 settled %.3f" % [expect_y, y1, y2])
	if yh < expect_y - 1.0:
		print("    control (the same mismatch as mass, 800 kg on 0.600 m3): fires — sank to %.1f m"
			% yh)
	else:
		_fail += 1
		print("    !! control did NOT fire: an under-buoyant boat settled at %.3f m instead of"
			% yh)
		print("       sinking, so this fixture cannot see an unbalanced boat")
	if absf(y2 - expect_y) > 0.03:
		_fail += 1
		print("    !! the scale-2 boat settled %.3f m from the prediction — gravity_scale is not"
			% (y2 - expect_y))
		print("       in the buoyant term")
	elif absf(y2 - y1) > 0.03:
		_fail += 1
		print("    !! scale 1 and scale 2 settled %.3f m apart" % absf(y2 - y1))
	else:
		print("    -> both settle on the prediction: the equilibrium is scale-invariant")
	root.queue_free()
	await _settle()
	_completed += 1


# ---- N: a settled boat does not stop answering the water -------------------------
#
# Every fixture before this one set can_sleep = false, so nothing here had ever floated a body that
# was allowed to sleep. This criterion covers that gap.
#
# It was written expecting to FAIL. The review behind this remediation claimed apply_force() does not
# wake a sleeping RigidBody3D, which would mean a settled boat silently stops floating — and a
# keep_awake export was built to fix it. Then this criterion's control refused to fire: the boat that
# was supposed to stay stuck rose with the water anyway. A standalone probe settled it — on Godot 4.7
# apply_force() wakes the body by itself — so the export was removed and the claim retracted. See
# PASTURE3D_BUOY_REMEDIATION_SPEC.md §4.4.
#
# What is left is still worth its place: "a boat that has settled and gone to sleep still rises when
# the water does" is a real user-facing property that nothing else asserts, and it now rests on
# engine behaviour this plugin does not control — which is exactly the kind of thing that should be
# pinned by a gate rather than remembered.
#
# The control is that the boat must ACTUALLY have been asleep before the water moved. `sleeping` is
# readable, so this is observed and not assumed; without it, a boat that never slept would sail
# through and the criterion would be measuring nothing.
func _gate_n_sleep() -> void:
	print("")
	print("[N] a boat that has settled and slept still rises when the water does:")
	var root := _make_world()
	_make_manager(root, 0.0005) # near-flat, so a boat can become still enough to cross the threshold
	var pool := _make_pool(root, 120.0)
	await _settle()

	var boat := _make_boat(root, 400.0, 4, 0.15, Vector3(0, 1, 0), 1.0, null, 1.0, true)
	await _run_physics(600) # settle, then hold still long enough to fall asleep

	# Control FIRST: it has to be asleep, or the water move below says nothing about a sleeping body.
	if boat.sleeping:
		print("    control (can_sleep on, left to settle): fires — the boat is asleep")
	else:
		_fail += 1
		print("    !! control did NOT fire: the boat never slept after 10 s at rest, so this")
		print("       criterion cannot tell a woken boat from one that was always awake")

	var y_before: float = boat.global_position.y
	pool.global_position += Vector3(0, 2.0, 0) # the swell
	await _run_physics(240)
	var rose: float = boat.global_position.y - y_before
	print("    water raised 2.000 m -> the boat rose %.3f m" % rose)
	if rose > 1.9:
		print("    -> it followed the water up; the buoyancy force wakes it by itself")
	else:
		_fail += 1
		print("    !! it rose only %.3f m — a sleeping body is no longer being floated" % rose)
	root.queue_free()
	await _settle()
	_completed += 1


# ---- O: an explicit water_body out of the tree is no body ------------------------
#
# A body removed from the tree still answers has_method("get_water_height"), and
# Pasture3DWaterBody cannot reach a manager when it is not inside a tree — so it returns its still
# level with NO wave displacement rather than failing. The buoy resolved the instance id and asked,
# and a boat went on floating on a flat plane that was not being drawn. Free fall is the correct
# behaviour: the water this buoy was told to use is gone.
func _gate_o_water_body_validity() -> void:
	print("")
	print("[O] an explicit water_body that has left the tree is no body:")
	var root := _make_world()
	_make_manager(root, 0.0005)
	var pool := _make_pool(root, 120.0)
	await _settle()

	var boat := _make_boat(root, 400.0, 4, 0.15, Vector3(0, pool.global_position.y, 0))
	for c in boat.get_children():
		if c is Pasture3DBuoy:
			c.water_body = pool
	var buoy: Pasture3DBuoy = boat.get_child(1)
	await _run_physics(420) # criterion A's settling time; 120 leaves it still moving at 0.1 m/s

	# Control FIRST: while the body IS in the tree the boat must float, or "it fell" below proves
	# nothing — a boat can fall for plenty of reasons.
	var y_floating: float = boat.global_position.y
	var resolved_before = buoy.get_resolved_body()
	if resolved_before != null and absf(boat.linear_velocity.y) < 0.05:
		print("    control (water_body in the tree): fires — resolved %s, floating at %.3f m"
			% [resolved_before.name, y_floating])
	else:
		_fail += 1
		print("    !! control did NOT fire: with water_body set and in the tree the boat resolved")
		print("       %s and had %.3f m/s of vertical motion" % [resolved_before, boat.linear_velocity.y])

	# Out of the tree, still alive and still assigned. The property must keep reporting it — a scene
	# save has to round-trip — while the buoy declines to float on it.
	root.remove_child(pool)
	await _run_physics(30)
	var resolved_after = buoy.get_resolved_body()
	var kept: bool = buoy.water_body == pool
	var fell: float = -boat.linear_velocity.y
	print("    after remove_child: resolved body %s | property still set %s | falling at %.2f m/s"
		% [resolved_after, kept, fell])
	if resolved_after == null and fell > 1.0:
		print("    -> no body, and the boat is in free fall rather than on a phantom surface")
	else:
		_fail += 1
		print("    !! it still resolved %s / fell at %.2f m/s" % [resolved_after, fell])
	if kept:
		print("    -> the property round-trips: what was assigned is still reported")
	else:
		_fail += 1
		print("    !! the water_body property forgot its assignment, so a scene save would drop it")
	pool.free() # it is out of the tree, so queue_free would leave it to nobody
	root.queue_free()
	await _settle()
	_completed += 1


# ---- P: angular damping does not depend on child order ---------------------------
#
# Criterion B proved the damping is applied once per BODY rather than once per buoy — but every buoy
# in its fixture carried the same angular_drag, so it could not see that the COEFFICIENT was taken
# from whichever buoy ran first while the submersion fraction was properly a max. A hull with mixed
# values therefore damped differently depending on the order its buoys sat in the inspector, which
# is precisely what B exists to forbid.
func _gate_p_drag_order_independent() -> void:
	print("")
	print("[P] angular damping is the same whatever order the buoys are in:")
	var root := _make_world()
	_make_manager(root, 0.0005)
	_make_pool(root, 120.0)
	await _settle()

	var w_asc := await _spin_decay(root, [2.0, 2.0, 8.0, 8.0], Vector3(0, 0, 0))
	var w_desc := await _spin_decay(root, [8.0, 8.0, 2.0, 2.0], Vector3(40, 0, 0))
	# Control: a hull where every buoy carries the LOW value must damp measurably less than the
	# mixed ones, which are damped at the high value. Without it, two hulls agreeing would also be
	# true of a fixture where angular_drag does nothing at all.
	var w_low := await _spin_decay(root, [2.0, 2.0, 2.0, 2.0], Vector3(-40, 0, 0))
	print("    spin after 0.5 s from 2.00 rad/s: [2,2,8,8] %.4f | [8,8,2,2] %.4f | all-2 %.4f"
		% [w_asc, w_desc, w_low])

	var spread: float = absf(w_asc - w_desc) / maxf(w_asc, 1e-9)
	var vs_low: float = absf(w_asc - w_low) / maxf(w_low, 1e-9)
	# Both halves of the control matter. The mixed hulls must still have spin left to compare —
	# two hulls damped to exactly zero "agree" no matter how the coefficient is chosen — and an
	# all-low hull must land somewhere else, or the fixture is blind to the coefficient entirely.
	if w_asc < 0.01:
		_fail += 1
		print("    !! control did NOT fire: the mixed hulls damped to %.4f, so the agreement below"
			% w_asc)
		print("       is a comparison of two zeros")
	elif vs_low > 0.2:
		print("    control (all buoys at the low value): fires — %.0f%% away from the mixed hulls"
			% (vs_low * 100.0))
	else:
		_fail += 1
		print("    !! control did NOT fire: an all-low hull is only %.0f%% from a mixed one, so"
			% (vs_low * 100.0))
		print("       this fixture cannot see the coefficient change at all")
	if spread < 0.01:
		print("    -> the two orders agree to within %.2f%%" % (spread * 100.0))
	else:
		_fail += 1
		print("    !! the two child orders disagree by %.1f%% — the coefficient is first-buoy-wins"
			% (spread * 100.0))
	root.queue_free()
	await _settle()
	_completed += 1


## Angular speed left after half a second, for a hull whose buoys carry `p_drags` in that child order.
##
## The buoys are STACKED at the hull's centre, for the reason criterion B documents: separated buoys
## drag a spinning body through the water linearly and that term swamps the angular one.
##
## HALF a second, not the two that criterion B uses. At angular_drag 8 the spin is annihilated inside
## a second — both mixed hulls read 0.0000 and "they agree" becomes a comparison of two zeros, which
## is true of any broken implementation that also reaches zero. The window is chosen so the number
## being compared is still moving.
func _spin_decay(p_root: Node3D, p_drags: Array, p_pos: Vector3) -> float:
	var boat := _make_boat(p_root, 400.0, p_drags.size(), 0.6 / p_drags.size(), p_pos, 0.0)
	var i := 0
	for c in boat.get_children():
		if c is Pasture3DBuoy:
			c.angular_drag = p_drags[i]
			i += 1
	await _settle()
	await _run_physics(60)
	boat.angular_velocity = Vector3(0, 2.0, 0)
	await _run_physics(30)
	var w: float = boat.angular_velocity.length()
	boat.queue_free()
	await _settle()
	return w


# ---- Q: a freeze leaves no residue -----------------------------------------------
#
# The frozen-body path returned before the per-body bookkeeping, so frac_prev survived the freeze —
# and the first tick after unfreezing damped the body against a submersion from before it. Small,
# but it is the same class of mistake as the child-order one: state that outlives the tick it
# describes.
func _gate_q_freeze_residue() -> void:
	print("")
	print("[Q] unfreezing does not apply damping saved up from before the freeze:")
	var root := _make_world()
	_make_manager(root, 0.0005)
	var pool := _make_pool(root, 120.0)
	await _settle()

	var boat := _make_boat(root, 400.0, 4, 0.15, Vector3(0, pool.global_position.y, 0), 0.0)
	await _run_physics(120)
	boat.angular_velocity = Vector3(0, 2.0, 0)
	await _run_physics(1)
	var w_before: float = boat.angular_velocity.length()

	boat.freeze = true
	await _run_physics(30)
	# A frozen body integrates nothing, so its spin must be exactly what it was.
	boat.freeze = false
	boat.angular_velocity = Vector3(0, w_before, 0)
	await _run_physics(1)
	var w_after: float = boat.angular_velocity.length()
	var drop: float = (w_before - w_after) / maxf(w_before, 1e-9)
	print("    spin %.4f before the freeze, %.4f on the first tick after it (%.3f%% lost)"
		% [w_before, w_after, drop * 100.0])

	# Control: the damping must be capable of taking a visible bite in one tick, or "it lost nothing"
	# is what any tick would have reported.
	await _run_physics(1)
	var w_damped: float = boat.angular_velocity.length()
	var bite: float = (w_after - w_damped) / maxf(w_after, 1e-9)
	if bite > 0.005:
		print("    control (an ordinary submerged tick): fires — it takes %.2f%% per tick"
			% (bite * 100.0))
	else:
		_fail += 1
		print("    !! control did NOT fire: a normal tick only damps %.3f%%, so a stale one would"
			% (bite * 100.0))
		print("       not have been visible either")
	if drop < bite * 0.5:
		print("    -> the first post-freeze tick is not carrying a stale submersion")
	else:
		_fail += 1
		print("    !! it lost %.3f%% on the first tick out of the freeze, comparable to a full"
			% (drop * 100.0))
		print("       submerged tick — frac_prev survived the freeze")
	root.queue_free()
	await _settle()
	_completed += 1


# ---- R: a nested rigid body's buoys are its own ----------------------------------
#
# get_body_displacement() walked the hull's whole subtree without stopping at another RigidBody3D, so
# a boat towing a dinghy counted the dinghy's buoys toward the hull. That inflates the one message
# somebody reads when a boat will not float, and it is asymmetric: the dinghy's buoys correctly find
# the dinghy through _find_parent_body().
#
# The assertion is that invariant rather than two magic numbers: the traversal must visit exactly the
# buoys whose parent body is this body.
func _gate_r_nested_bodies() -> void:
	print("")
	print("[R] a nested RigidBody3D's buoys do not count toward the hull:")
	var root := _make_world()
	_make_manager(root, 0.0005)
	var pool := _make_pool(root, 120.0)
	await _settle()

	var boat := _make_boat(root, 400.0, 4, 0.15, Vector3(0, pool.global_position.y, 0)) # 0.600
	var dinghy := _make_boat(boat, 100.0, 2, 0.30, Vector3(0, pool.global_position.y, 0)) # 0.600
	await _settle()

	var hull_buoy: Pasture3DBuoy = boat.get_child(1)
	var dinghy_buoy: Pasture3DBuoy = dinghy.get_child(1)
	var hull_total: float = hull_buoy.get_body_displacement()
	var dinghy_total: float = dinghy_buoy.get_body_displacement()
	print("    hull reports %.3f m3 | dinghy reports %.3f m3" % [hull_total, dinghy_total])

	# Control: the dinghy has to be carrying displacement of its own, or there was nothing to
	# exclude and the hull's total would be right by accident.
	if dinghy_total > 0.001:
		print("    control (the dinghy has buoys of its own): fires — %.3f m3" % dinghy_total)
	else:
		_fail += 1
		print("    !! control did NOT fire: the dinghy reports no displacement, so this criterion")
		print("       is measuring an empty set")

	# The invariant, checked directly rather than against a constant: every Pasture3DBuoy anywhere
	# under the hull, partitioned by which body it actually belongs to.
	var expect_hull := 0.0
	for b in _all_buoys(boat):
		if _owning_body(b) == boat:
			expect_hull += b.displacement
	if absf(hull_total - expect_hull) < 0.0001:
		print("    -> the hull counts exactly the buoys whose parent body is the hull (%.3f m3)"
			% expect_hull)
	else:
		_fail += 1
		print("    !! the hull reports %.3f m3 but owns %.3f m3" % [hull_total, expect_hull])
	root.queue_free()
	await _settle()
	_completed += 1


func _all_buoys(p_node: Node) -> Array:
	var out: Array = []
	if p_node is Pasture3DBuoy:
		out.append(p_node)
	for c in p_node.get_children():
		out.append_array(_all_buoys(c))
	return out


## The nearest RigidBody3D ancestor — the GDScript twin of Pasture3DBuoy::_find_parent_body().
func _owning_body(p_node: Node) -> Node:
	var n := p_node.get_parent()
	while n != null:
		if n is RigidBody3D:
			return n
		n = n.get_parent()
	return null


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


## An ocean at `p_y`, on the same `flat_test` profile every fixture here uses.
func _make_ocean(p_root: Node3D, p_y: float) -> Pasture3DOcean:
	var ocean := Pasture3DOcean.new()
	ocean.name = "Ocean"
	ocean.material = load(OCEAN_MAT)
	ocean.wave_profile = &"flat_test"
	p_root.add_child(ocean)
	ocean.global_position = Vector3(0, p_y, 0)
	return ocean


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
##
## The four trailing parameters exist for Phase 3's criteria and default to what every earlier
## criterion already assumed. `p_com` null leaves CENTER_OF_MASS_MODE_AUTO alone; a Vector3 switches
## to CUSTOM at that local offset, including Vector3.ZERO, which is a different thing from AUTO and
## is criterion L's control.
func _make_boat(p_root: Node3D, p_mass: float, p_count: int, p_displacement: float,
		p_pos: Vector3, p_spread: float = 1.0, p_com: Variant = null,
		p_gravity_scale: float = 1.0, p_can_sleep: bool = false) -> RigidBody3D:
	var boat := RigidBody3D.new()
	boat.mass = p_mass
	boat.gravity_scale = p_gravity_scale
	if p_com != null:
		boat.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
		boat.center_of_mass = p_com
	# Default false: a sleeping body stops integrating, and every criterion before Phase 3 watches
	# one move. Criterion N is the one that needs it true, because sleeping is what it is about.
	boat.can_sleep = p_can_sleep
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


## Let physics tick and the deferred/debounced rebuilds land.
##
## The second loop waits on RENDER frames, and under --headless there are none: the dummy renderer
## never emits frame_post_draw, so awaiting it hangs the gate at the first call with no message.
## That is why this file's header documents a windowed run. The wait itself is not about rendering
## though -- it is about letting the water bodies' debounced rebuilds and deferred calls come round --
## and process_frame is the same beat without a GPU, so headless gets that instead.
##
## Worth having: every criterion except E's and G's millisecond halves is a correctness check, and a
## correctness check that needs a window is one nobody runs while doing something else on the machine.
func _settle() -> void:
	var headless := DisplayServer.get_name() == "headless"
	for i in 4:
		await get_tree().physics_frame
	for i in 4:
		if headless:
			await get_tree().process_frame
		else:
			await RenderingServer.frame_post_draw
