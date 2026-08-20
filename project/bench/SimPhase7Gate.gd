# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Phase 7 gates AP and AQ — the threaded solve. See PASTURE3D_SIM_NODE_SPEC.md §20.7.
#
# WHAT THIS GATE DOES NOT TEST, and §20.7 says so before it lists the criteria: **AO and AR are
# editor-path criteria and headless-blind.** AO is a frame-time budget during a threaded build and there
# is no viewport here to measure one; AR is teardown mid-solve with the scene closing and the editor
# reloading a @tool script, which needs an editor doing those things. This gate asserts the half a
# headless run can — that the worker produces the same landscape and that Cancel joins it — and prints
# what it did not, rather than letting four green lines imply more than was measured. The same
# accommodation gates M4 and AS-AY already make.
#
# The other two criteria are here in full:
#   AP — the threaded result is BITWISE identical to the synchronous one.
#   AQ — Cancel joins the worker, writes nothing, and leaves the node able to run again.
#
# NOTHING IS SAVED. Bakes write into the terrain's in-memory layer; demo/data on disk is only touched by
# an explicit save, which nothing here calls.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/SimPhase7Gate.tscn
extends Node

const DEMO_DATA := "res://demo/data"

const SITE_AP := Vector3(300.0, 0.0, 300.0)
const SITE_AQ := Vector3(500.0, 0.0, 500.0)

const LOOP_HALF := 60.0
const MARGIN := 40.0

## AQ needs a solve long enough that Cancel can land INSIDE it. A big loop at many iterations; the gate
## asserts it had not finished rather than trusting this number.
const AQ_HALF := 250.0
const AQ_MARGIN := 128.0
const AQ_ITERATIONS := 200

var _fail := 0
var _root: Node3D
var _terrain
var _data


func _ready() -> void:
	print("\n=== Pasture3DSim phase 7 (spec §20.7, gates AP and AQ) ===\n")
	print("NOTE: AO (frame-time budget) and AR (teardown mid-solve) are NOT tested here — both are")
	print("      editor-path criteria and headless has no viewport and no scene tab. §20.7 records this.")
	print("      A checklist for running them by hand is printed at the end.\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_data = _terrain.data
	if _data == null or not _data.has_method("erode_heightfield"):
		_fail += 1
		print("!! this build has no solver")
		_done()
		return

	await _gate_ap()
	await _gate_aq()
	_checklist()
	_done()


func _done() -> void:
	print("\n=== %s (%d failures) ===\n" % ["SIM PHASE 7 PASS" if _fail == 0 else "SIM PHASE 7 FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- AP: the worker produces the same landscape ----------------------------------------------------
#
# Gate I extended across DRIVERS rather than across runs. `simulate_now` runs the solve straight through
# on this thread; `_simulate_interactive` hands the identical states to a WorkerThreadPool task. Same
# `_begin`, same `_solve_chunk`, same `_finish` — only who calls them differs, which is the whole claim
# §20.2 makes about the state machine being the seam.
#
# Compared as the committed SURFACE rather than as the report, because the surface is what a user gets
# and a report can agree while the layer does not.
func _gate_ap() -> void:
	print("[AP] the threaded solve is bitwise the synchronous one:")
	var mgr := _make_manager("AP", SITE_AP, LOOP_HALF, MARGIN, 30)
	if mgr == null:
		_fail += 1
		print("    !! no terrain at %s\n" % SITE_AP)
		return
	var layer_id: int = mgr._ensure_layer_for(mgr._layer_owner, true)
	var g := _grid(SITE_AP, LOOP_HALF + MARGIN)
	var ground := _surface(layer_id, g)

	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the synchronous solve failed\n")
		return
	var sync_z := _surface(layer_id + 1, g)

	# PRECONDITION: the solve has to have MOVED the ground, or AP compares two copies of the input and
	# would pass on a driver that did nothing at all.
	var moved := _max_abs_diff(ground, sync_z)
	print("    the synchronous solve moved the ground by %.3f m over %d cells" % [moved, sync_z.size()])
	if moved <= 0.0:
		_fail += 1
		print("    !! nothing was eroded; AP cannot tell the two drivers apart")
		return

	await mgr._simulate_interactive(1, false)
	var thr_z := _surface(layer_id + 1, g)
	print("    threaded run: task id after the join = %d (want -1), still running = %s (want false)" % [
			mgr._task_id, mgr._running])
	if mgr._task_id != -1 or mgr._running:
		_fail += 1
		print("    !! the worker was not joined")

	var same := sync_z.to_byte_array() == thr_z.to_byte_array()
	print("    surfaces identical, BITWISE: %s" % same)
	if not same:
		_fail += 1
		print("    !! max |threaded - synchronous| = %.9f m" % _max_abs_diff(sync_z, thr_z))

	# CONTROL. The comparison must be able to SEE a difference, or "bitwise identical" is a statement
	# about a comparison that always returns true. One fewer iteration must change the surface.
	(mgr.get_child(0) as Pasture3DSim).iterations = 29
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the control solve failed")
		return
	var fewer := _surface(layer_id + 1, g)
	var delta := _max_abs_diff(sync_z, fewer)
	print("    CONTROL 29 iterations instead of 30 differs by %.6f m (want > 0)" % delta)
	if delta <= 0.0:
		_fail += 1
		print("    !! the surface does not depend on the solve; AP is vacuous")
	print("")


# --- AQ: Cancel joins ------------------------------------------------------------------------------
#
# §20.7 is explicit about the control: assert the solve had NOT finished when Cancel landed, or "cancel
# worked" is indistinguishable from "the solve completed first". So the fixture is deliberately large,
# and the gate reports how far in it got rather than assuming.
func _gate_aq() -> void:
	print("[AQ] Cancel joins the worker, writes nothing, and the node can run again:")
	var mgr := _make_manager("AQ", SITE_AQ, AQ_HALF, AQ_MARGIN, AQ_ITERATIONS)
	if mgr == null:
		_fail += 1
		print("    !! no terrain at %s\n" % SITE_AQ)
		return
	var layer_id: int = mgr._ensure_layer_for(mgr._layer_owner, true)
	var g := _grid(SITE_AQ, AQ_HALF + AQ_MARGIN)
	var before := _surface(layer_id + 1, g)

	# Start the threaded solve WITHOUT awaiting it: a GDScript coroutine runs to its first await and
	# returns, so this leaves a live worker and hands control back here.
	mgr._simulate_interactive(1, false)
	for i in range(3):
		await get_tree().process_frame

	# THE CONTROL, checked before cancelling rather than after: the solve must still be in flight.
	var in_flight: bool = mgr._running and mgr._task_id != -1
	var progressed := 0
	for st in mgr.last_chain:
		progressed += 1
	print("    CONTROL the solve is still in flight when Cancel lands: %s (task id %d)" % [
			in_flight, mgr._task_id])
	if not in_flight:
		_fail += 1
		print("    !! it had already finished; AQ would pass on a Cancel that did nothing")
		return

	mgr.cancel_simulation()
	var frames := 0
	while mgr._running and frames < 600:
		frames += 1
		await get_tree().process_frame
	print("    after Cancel: joined in %d frame(s), task id = %d (want -1), running = %s (want false)" % [
			frames, mgr._task_id, mgr._running])
	if mgr._task_id != -1:
		_fail += 1
		print("    !! the worker was not joined; the task still holds this node's arrays")
	if mgr._running:
		_fail += 1
		print("    !! the node still thinks it is running, so Simulate stays blocked forever")

	var after := _surface(layer_id + 1, g)
	var touched := _max_abs_diff(before, after)
	print("    the layer was not written: max |after - before| = %.9f m (want 0)" % touched)
	if touched != 0.0:
		_fail += 1
		print("    !! a cancelled solve committed something")

	# And the node is usable again — a cancel that leaves it wedged is not a cancel.
	(mgr.get_child(0) as Pasture3DSim).iterations = 10
	var rep := mgr.simulate_now(1, false)
	print("    it runs again afterwards: ok = %s" % bool(rep.get("ok", false)))
	if not bool(rep.get("ok", false)):
		_fail += 1
		print("    !! the node was left unable to solve")
	print("")


func _checklist() -> void:
	print("[AO/AR] NOT RUN — editor-path criteria (§20.7). To close phase 7, in the editor:")
	print("    AO  Open sculpting_2.tscn, press Simulate on a manager over a large loop and watch the")
	print("        editor stay interactive for the whole solve — drag a gizmo, scrub the viewport. On")
	print("        the synchronous path the same build hitched about 477 ms per chunk, six times.")
	print("    AR  Start a build, then (a) delete the manager mid-solve, (b) close the scene tab")
	print("        mid-solve, and (c) edit and save a connector script mid-solve to force a @tool")
	print("        reload. None may crash or leave an orphan task. Each needs a CONTROL run that is")
	print("        allowed to finish normally, to show the teardown path is what was exercised.")


# --- helpers ---------------------------------------------------------------------------------------

func _make_manager(p_name: String, p_at: Vector3, p_half: float, p_margin: float,
		p_iter: int) -> Pasture3DSimManager:
	if not is_finite(_data.get_height(p_at)):
		return null
	var m := Pasture3DSimManager.new()
	m.name = "M_%s" % p_name
	_root.add_child(m)
	m.terrain = _terrain
	m.global_position = p_at
	m.snap_to_surface = false
	m.catchment_margin = p_margin
	m._layer_owner = "pasture3d_brush:Phase7_%s" % p_name
	var s := Pasture3DSim.new()
	s.name = "P1"
	m.add_child(s)
	s.terrain = _terrain
	s.snap_to_surface = false
	s.catchment_margin = p_margin
	s.iterations = p_iter
	s.erosion_rate = 0.15
	s.hillslope_diffusion = 0.15
	s.falloff_width = 12.0
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	for p in [Vector3(-p_half, 0, -p_half), Vector3(p_half, 0, -p_half),
			Vector3(p_half, 0, p_half), Vector3(-p_half, 0, p_half)]:
		c.add_point(p)
	c.closed = true
	path.curve = c
	s.add_child(path)
	return m


## [min_x, min_z, gw, gh, cell] covering the loop and its margin, snapped to the terrain grid.
func _grid(p_at: Vector3, p_pad: float) -> Array:
	var vs: float = _terrain.vertex_spacing
	var pad := p_pad + 4.0
	var min_x := floorf((p_at.x - pad) / vs) * vs
	var min_z := floorf((p_at.z - pad) / vs) * vs
	var max_x := ceilf((p_at.x + pad) / vs) * vs
	var max_z := ceilf((p_at.z + pad) / vs) * vs
	return [min_x, min_z, int(round((max_x - min_x) / vs)) + 1, int(round((max_z - min_z) / vs)) + 1, vs]


## The composited surface through layer `p_below - 1`. Passing layer_id + 1 includes the manager's own
## committed delta, which is what "the landscape a user got" means.
func _surface(p_below: int, p_g: Array) -> PackedFloat32Array:
	return _data.composite_height_below(p_below, p_g[0], p_g[1], p_g[4], p_g[2], p_g[3])


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		if is_finite(p_a[i]) and is_finite(p_b[i]):
			m = maxf(m, absf(p_a[i] - p_b[i]))
	return m
