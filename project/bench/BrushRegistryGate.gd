# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gates CF, CG, CH and CW — the eroding-brush registry and Bake All Brushes. Phase 4 of
# PASTURE3D_BRUSH_EROSION_SPEC.md §7.
#
# The complaint the phase answers is "the user doesn't have to track down all the brushes to resim them",
# so the thing under test is a REGISTRY: an explicit, diffable list of NodePaths on the manager, a button
# that re-solves everything in it, and the two ways that can go wrong — baking something that is not in
# the list, and dropping something that is.
#
# THE FIXTURE IS THE WORKFLOW, not a synthetic one. Every mound here carries `Relief → Erosion` with the
# erosion FROZEN, which is the shipped default; each is baked once, then its relief is changed underneath
# it. That leaves exactly the state the button exists for: the terrain is showing solves for shapes that
# have moved on, every brush knows it is stale, and nothing will re-solve until something asks. What Bake
# All does is ask — for the registered set only.
#
# WHY "IN LIST ORDER" IS MEASURED ON THE PLAN AND NOT ON THE SURFACE. Bake All is a loop, not a chain
# (§7): each brush erodes its own surface independently, so no ordering of independent bakes produces a
# different landscape and no height probe can distinguish one from another. Measuring order therefore
# means measuring the order of the work, and the gate says so rather than inventing a height statistic
# that would only appear to test it.
#
# NOTHING IS SAVED. Bakes write into the terrain's in-memory layers.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/BrushRegistryGate.tscn
extends Node

const DEMO_DATA := "res://demo/data"

## Sites far enough apart that no two brushes share ground, so a probe lattice over one sees only that
## one even when two of them are bound to the same layer.
const SITE_A := Vector3(180.0, 0.0, 120.0)
const SITE_B := Vector3(480.0, 0.0, 120.0)
const SITE_C := Vector3(780.0, 0.0, 120.0)
const SITE_D := Vector3(180.0, 0.0, 420.0)
const SITE_E := Vector3(480.0, 0.0, 420.0)
const SITE_F := Vector3(780.0, 0.0, 420.0)
const SITE_G := Vector3(180.0, 0.0, 720.0)
const SITE_H := Vector3(480.0, 0.0, 720.0)
## §10's Clear Simulation On All Brushes: two brushes on two layer owners, plus one unregistered.
const SITE_I := Vector3(780.0, 0.0, 720.0)
const SITE_J := Vector3(900.0, 0.0, 120.0)
const SITE_K := Vector3(900.0, 0.0, 420.0)

const HALF := 50.0
const PROBE_STRIDE := 2

var _fail := 0
## House rule (bench/OceanBench.gd): a GDScript runtime error abandons the function WITHOUT incrementing
## the failure count, so a suite that only counts failures reports a clean pass having measured nothing.
## This run proved it — three assignment errors, three abandoned gates, "PASS (0 failures)". Each gate
## increments this as its last statement, and the verdict below requires all of them.
const GATES := 4
var _completed := 0
var _root: Node3D
var _terrain
var _mgr
var _vs := 1.0


func _ready() -> void:
	print("\n=== Eroding-brush registry (gates CF, CG, CH) ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_vs = _terrain.vertex_spacing
	_mgr = Pasture3DSimManager.new()
	_mgr.name = "Manager"
	_root.add_child(_mgr)
	_mgr.terrain = _terrain

	_gate_cf_bakes_exactly_the_registered_set()
	_gate_cg_stale_path_warns_and_does_not_drop()
	await _gate_ch_one_undo_and_cancel()
	_gate_cw_scan_appends()
	_gate_df_clear_all_brushes()

	print("\n=== %s (%d failures) ===\n"
		% ["BRUSH REGISTRY PASS" if _fail == 0 else "BRUSH REGISTRY FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- CF: Bake All bakes exactly the registered set --------------------------------------------------
#
# Two claims, and the second is the one that decides whether the registry is real. If an unregistered
# brush also re-solves then the manager is scanning and the list is decoration.
#
# The unregistered brush deliberately SHARES A LAYER with a registered one, because that is the case
# where "untouched" is not trivially true: `_refresh_owner` clears the layer and repaints every tool bound
# to it, so the unregistered mound genuinely is re-stamped — it has to be, or clearing the layer would
# wipe it. What must not happen is that its EROSION re-solves. Its frozen cache is what makes the two
# statements compatible, and the control below proves the probe could have seen a change if there were one.
func _gate_cf_bakes_exactly_the_registered_set() -> void:
	print("\n[CF] Bake All bakes the registered set and nothing else:")
	var reg_a = _make_mound("RegA", SITE_A, "RegA")
	var reg_b = _make_mound("RegB", SITE_B, "Shared")
	var unreg = _make_mound("Unreg", SITE_C, "Shared")
	if reg_a == null or reg_b == null or unreg == null:
		return
	var pa := _lattice(SITE_A)
	var pb := _lattice(SITE_B)
	var pc := _lattice(SITE_C)

	# Bake once, so every brush holds a frozen solve and the layers hold its result.
	for m in [reg_a, reg_b, unreg]:
		m._refresh_owner(m._layer_owner, false, [])
	var fresh_a := _snapshot(pa)

	# Now move the ground under all three, and bake again.
	#
	# THE SECOND BAKE IS NOT REDUNDANT, and finding out why corrected this fixture. Staleness is detected
	# AT BAKE TIME, not at edit time: the flag is raised by the host when it serves a cached entry whose
	# key no longer matches the surface it was handed. In the editor `auto_refresh` supplies that bake on
	# the very edit that invalidates it, which is why the warning appears immediately; headless nothing
	# does, and the first draft of this gate asserted staleness that nothing had yet had a chance to
	# notice. So the fixture supplies the bake — and the heights must NOT move when it does, which is the
	# whole claim of a frozen modifier and is checked here rather than assumed.
	for m in [reg_a, reg_b, unreg]:
		_shape_of(m).strength = 24.0
	for m in [reg_a, reg_b, unreg]:
		m._refresh_owner(m._layer_owner, false, [])
	var a0 := _snapshot(pa)
	var b0 := _snapshot(pb)
	var c0 := _snapshot(pc)
	var held := _first_difference(fresh_a, a0)
	var stale_before := [_is_stale(reg_a), _is_stale(reg_b), _is_stale(unreg)]
	print("    after changing every shape, a bake serves the frozen solves unchanged: %s"
		% ["bitwise identical" if held < 0 else "MOVED at probe %d" % held])
	if held >= 0:
		_fail += 1
		print("    !! a Frozen modifier followed its input without being asked, so there is nothing here "
			+ "for Bake All to do and the rest of this gate is about nothing")

	var listed: Array[NodePath] = [_mgr.get_path_to(reg_a), _mgr.get_path_to(reg_b)]
	_mgr.eroding_brushes = listed
	var report: Dictionary = _mgr.bake_all_brushes_now(false)
	if not bool(report["ok"]):
		_fail += 1
		print("    !! Bake All refused to run: %s" % report["reason"])
		return
	var a1 := _snapshot(pa)
	var b1 := _snapshot(pb)
	var c1 := _snapshot(pc)
	var moved_a := _max_abs_diff(a0, a1)
	var moved_b := _max_abs_diff(b0, b1)
	var at_c := _first_difference(c0, c1)

	print("    %d of %d registered brush(es) baked across %d layer(s), %d frozen solve(s) cleared"
		% [int(report["baked"]), int(report["total"]), int(report["owners"]), int(report["cleared"])])
	print("    registered: RegA moved %.3f m, RegB moved %.3f m" % [moved_a, moved_b])
	print("    unregistered (sharing RegB's layer): %s"
		% ["bitwise identical" if at_c < 0 else "MOVED at probe %d" % at_c])
	print("    all three brushes now report themselves stale: %s" % str(stale_before))
	if not stale_before.all(func(v): return v):
		_fail += 1
		print("    !! the fixture did not go stale (%s), so nothing here needed re-solving and 'it baked' "
			% str(stale_before) + "is not evidence")
	if moved_a < 0.5 or moved_b < 0.5:
		_fail += 1
		print("    !! a registered brush did not follow its own changed shape, so Bake All is not "
			+ "re-solving — which is the whole of what the button does")
	if at_c >= 0:
		_fail += 1
		print("    !! an UNREGISTERED brush re-solved, so the manager is scanning and the list is "
			+ "decoration")
	if _is_stale(reg_a) or _is_stale(reg_b):
		_fail += 1
		print("    !! a registered brush is still marked stale after Bake All, so the run did not reach "
			+ "its cache")

	# --- CONTROL: site C is reachable by a repaint of that layer ---
	# Without this, "bitwise identical at C" could equally mean the probe is looking somewhere a bake
	# never goes. Clearing the unregistered brush's cache by hand and repainting the SAME layer must move
	# it — same layer, same repaint, one difference.
	if not _is_stale(unreg):
		_fail += 1
		print("    !! the unregistered brush lost its stale flag, so something cleared its cache")
	unreg.clear_erosion_caches()
	unreg._refresh_owner(unreg._layer_owner, false, [])
	var moved_c := _max_abs_diff(c1, _snapshot(pc))
	print("    control: clearing that brush's own cache and repainting the same layer moves it %.3f m"
		% moved_c)
	if moved_c < 0.5:
		_fail += 1
		print("    !! site C does not move even when its own cache IS cleared, so 'identical' above was "
			+ "measuring somewhere a bake never reaches")

	# --- ORDER: measured on the plan, for the reason in this file's header ---
	var forward: Array = _mgr._eroding_owner_plan(_mgr.resolved_eroding_brushes()["brushes"])
	var backwards: Array[NodePath] = [_mgr.get_path_to(reg_b), _mgr.get_path_to(reg_a)]
	_mgr.eroding_brushes = backwards
	var reversed: Array = _mgr._eroding_owner_plan(_mgr.resolved_eroding_brushes()["brushes"])
	var f := _owner_names(forward)
	var r := _owner_names(reversed)
	print("    order: the list runs as %s, and reversing the list runs as %s" % [str(f), str(r)])
	if f.size() != 2 or r.size() != 2 or f[0] == f[1] or r[0] != f[1] or r[1] != f[0]:
		_fail += 1
		print("    !! the work is not ordered by the list, so the manager is not 'the single place that "
			+ "knows the order'")
	_mgr.eroding_brushes = _none()
	_completed += 1


# --- CG: a stale path warns and does not drop -------------------------------------------------------
#
# The failure this prevents is a build that silently stops including something. A NodePath to a deleted
# brush has to say so BY NAME — the path is the only identifying thing left once the node is gone — and
# the rest of the list has to bake regardless, or one dead entry disables the button.
func _gate_cg_stale_path_warns_and_does_not_drop() -> void:
	print("\n[CG] a stale path warns, names itself, and does not stop the rest:")
	var keep = _make_mound("Keep", SITE_A, "RegA")
	var doomed = _make_mound("Doomed", SITE_D, "Doomed")
	if keep == null or doomed == null:
		return
	for m in [keep, doomed]:
		m._refresh_owner(m._layer_owner, false, [])
	var doomed_path: NodePath = _mgr.get_path_to(doomed)
	var pair: Array[NodePath] = [_mgr.get_path_to(keep), doomed_path]
	_mgr.eroding_brushes = pair

	# --- CONTROL FIRST: with every path valid, the registry must say nothing at all ---
	var clean := _registry_warnings()
	print("    control: with both paths valid the registry warns %d time(s)" % clean.size())
	if not clean.is_empty():
		_fail += 1
		print("    !! the registry complains about a healthy list, so a complaint below means nothing: %s"
			% str(clean))

	_shape_of(keep).strength = 24.0
	var probes := _lattice(SITE_A)
	var before := _snapshot(probes)
	doomed.free()

	var warns := _registry_warnings()
	var named := false
	for w in warns:
		if w.contains(String(doomed_path)):
			named = true
	print("    after deleting 'Doomed': %d warning(s), the path named: %s" % [warns.size(), named])
	if not named:
		_fail += 1
		print("    !! the dead path is not reported by name, which is the one thing left that identifies "
			+ "it")

	var report: Dictionary = _mgr.bake_all_brushes_now(false)
	var moved := _max_abs_diff(before, _snapshot(probes))
	print("    the rest still baked: %d of %d, %d stale path(s) reported, 'Keep' moved %.3f m"
		% [int(report["baked"]), int(report["total"]), int(report["stale"].size()), moved])
	if not bool(report["ok"]) or int(report["stale"].size()) != 1 or moved < 0.5:
		_fail += 1
		print("    !! one dead entry stopped the run, or the survivor did not bake — a stale path must "
			+ "cost exactly itself")
	if int(report["total"]) != 1:
		_fail += 1
		print("    !! the dead path was counted as a brush to bake, so 'N of M' is not a count of "
			+ "anything real")
	_mgr.eroding_brushes = _none()
	_completed += 1


# --- CH: one undo, and a cancel that leaves a coherent scene ----------------------------------------
#
# Bake All touches N layers, and N undo actions is N presses of Ctrl+Z to get back — which is not an undo
# of the button, it is an undo of its pieces. So the criterion is that ONE action carries every layer.
#
# EXERCISED THROUGH THE INVERSE, NOT THROUGH THE EDITOR. `EditorUndoRedoManager` does not exist in a
# headless run, so a gate that asked for it would test nothing. `_bake_all_finish` builds its action out
# of `_restore_owner(owner, snapshot)` pairs and hands the same pairs back in the report, so the gate can
# call the exact inverse the editor would call. Same argument the Add Water press already makes: an
# untestable undo is an undo that is wrong the first time someone presses Ctrl+Z.
func _gate_ch_one_undo_and_cancel() -> void:
	print("\n[CH] one undo restores every layer the run touched:")
	var one = _make_mound("UndoA", SITE_E, "UndoA")
	var two = _make_mound("UndoB", SITE_F, "UndoB")
	if one == null or two == null:
		return
	for m in [one, two]:
		m._refresh_owner(m._layer_owner, false, [])
	var p1 := _lattice(SITE_E)
	var p2 := _lattice(SITE_F)
	var before1 := _snapshot(p1)
	var before2 := _snapshot(p2)
	for m in [one, two]:
		_shape_of(m).strength = 24.0
	var both: Array[NodePath] = [_mgr.get_path_to(one), _mgr.get_path_to(two)]
	_mgr.eroding_brushes = both

	var report: Dictionary = _mgr.bake_all_brushes_now(false)
	var moved1 := _max_abs_diff(before1, _snapshot(p1))
	var moved2 := _max_abs_diff(before2, _snapshot(p2))
	var undo: Dictionary = report["undo"]
	var actions: Array = report["actions"]
	var carried: int = int(actions[0]["owners"].size()) if not actions.is_empty() else 0
	print("    the run moved 2 layers by %.3f m and %.3f m, and registers %d undo action(s) carrying %d layer(s)"
		% [moved1, moved2, actions.size(), carried])
	if moved1 < 0.5 or moved2 < 0.5:
		_fail += 1
		print("    !! one of the layers did not move, so restoring it proves nothing")
	if actions.size() != 1 or carried != 2:
		_fail += 1
		print("    !! this is not one action over both layers, so undoing the button takes more than one "
			+ "press")
	if int(undo["before"].size()) != 2 or int(undo["after"].size()) != 2:
		_fail += 1
		print("    !! the run did not snapshot both layers")

	for owner in undo["before"]:
		_mgr._restore_owner(owner, undo["before"][owner])
	var back1 := _first_difference(before1, _snapshot(p1))
	var back2 := _first_difference(before2, _snapshot(p2))
	print("    applying the action's inverse: layer 1 %s, layer 2 %s"
		% ["restored bitwise" if back1 < 0 else "DIFFERS at probe %d" % back1,
			"restored bitwise" if back2 < 0 else "DIFFERS at probe %d" % back2])
	if back1 >= 0 or back2 >= 0:
		_fail += 1
		print("    !! Ctrl+Z would not put the terrain back")

	# --- CONTROL: cancel mid-run ---
	#
	# Driven through the INTERACTIVE path, which is the only one that can be cancelled — the scripted one
	# runs straight through by design. `bake_all_brushes()` bakes the first layer synchronously and then
	# parks on a frame, so setting the flag while it is parked cancels it between layers, exactly where a
	# person pressing Cancel would.
	var c1 := _snapshot(p1)
	var c2 := _snapshot(p2)
	for m in [one, two]:
		_shape_of(m).strength = 40.0
	_mgr.bake_all_brushes() # deliberately not awaited: it resumes on its own frame
	_mgr.cancel_simulation()
	await get_tree().process_frame
	await get_tree().process_frame
	var cancelled: Dictionary = _mgr.last_bake_report
	var after1 := _max_abs_diff(c1, _snapshot(p1))
	var after2 := _max_abs_diff(c2, _snapshot(p2))
	print("    control: cancelled after %d of %d — layer 1 moved %.3f m, layer 2 moved %.3f m"
		% [int(cancelled.get("baked", -1)), int(cancelled.get("total", -1)), after1, after2])
	if not bool(cancelled.get("cancelled", false)):
		_fail += 1
		print("    !! the run did not report itself cancelled, so it ran to completion and this measures "
			+ "nothing")
	elif int(cancelled.get("baked", 0)) != 1 or int(cancelled.get("total", 0)) != 2:
		_fail += 1
		print("    !! the partial count is not 1 of 2, so the node cannot say how far it got")
	if after1 < 0.5:
		_fail += 1
		print("    !! the layer it DID reach was not baked, so cancel discarded completed work")
	if after2 > 0.0:
		_fail += 1
		print("    !! the layer it never reached was written to anyway")
	var warned := false
	for w in _mgr._get_configuration_warnings():
		if w.contains("CANCELLED"):
			warned = true
	print("             and the node says so on itself: %s" % warned)
	if not warned:
		_fail += 1
		print("    !! a partial bake is reported only in the Output log, where it will be missed")
	_mgr.eroding_brushes = _none()
	_completed += 1



# --- CW: Register Eroding Brushes discovers, without making membership implicit ---------------------
#
# The button exists so the artist does not have to hunt for the brushes; the LIST exists so that what
# will bake stays readable without running anything (§7). Those two pull in opposite directions, and the
# resolution is that the scan APPENDS to a list the artist still owns. So the criteria are: it finds what
# it should, it finds nothing it should not, it does not duplicate, and it does not reorder or replace
# what is already there.
#
# THE EXPECTED SET IS COMPUTED HERE, by this gate's own walk over its own fixtures, and not by asking the
# manager which brushes it thinks are eroding — a gate that asked the code under test whether it was
# right would agree with a broken `erosion_modifiers()` exactly as readily as with a working one.
func _gate_cw_scan_appends() -> void:
	print("\n[CW] Register Eroding Brushes finds the eroding brushes, and only them:")
	# Two brushes that must NOT be found, for the two different reasons a brush can fail to qualify.
	var plain = _make_mound("NoErosion", SITE_G, "Scan")
	var off = _make_mound("ErosionOff", SITE_H, "Scan")
	if plain == null or off == null:
		return
	var bare: Array[Pasture3DNode] = [_shape_of(plain)]
	plain.modifiers = bare
	_erosion_of(off).enabled = false

	var expected := _eroding_in_fixture()
	if expected.size() < 2:
		_fail += 1
		print("    !! the scene holds %d brush(es) with an enabled erosion modifier, so a scan that "
			% expected.size() + "found them all would be proving very little")
		return

	_mgr.eroding_brushes = _none()
	var added: int = _mgr.scan_for_eroding_brushes()
	var got := _registered_nodes()
	print("    scanned an empty list: registered %d of the %d eroding brush(es) in the scene" % [added, expected.size()])
	if got != expected:
		_fail += 1
		print("    !! the registered set is not the eroding set — registered %s, expected %s"
			% [_names(got), _names(expected)])
	if got.has(plain) or got.has(off):
		_fail += 1
		print("    !! a brush with no erosion modifier, or one whose modifier is disabled, was registered")
	if got.has(_mgr):
		_fail += 1
		print("    !! the manager registered ITSELF, which would bake its own layer on every press")

	# --- Pressing it twice must add nothing ---
	var again: int = _mgr.scan_for_eroding_brushes()
	print("    control: pressing it again added %d" % again)
	if again != 0 or _registered_nodes() != expected:
		_fail += 1
		print("    !! the scan duplicates entries, so the list grows every time it is pressed and 'N of "
			+ "M' counts the same brush twice")

	# --- It APPENDS: a hand-made list keeps its own order and its own entries ---
	#
	# This is the property that makes the list worth having. A scan that replaced would silently discard
	# an order the artist chose, which is the difference between discovery and implicit membership.
	var hand: Array[NodePath] = [_mgr.get_path_to(expected[expected.size() - 1])]
	_mgr.eroding_brushes = hand
	_mgr.scan_for_eroding_brushes()
	var after := _registered_nodes()
	print("    control: starting from a hand-made list of 1, the scan grew it to %d and left entry 0 as '%s'"
		% [after.size(), after[0].name if not after.is_empty() else "<none>"])
	if after.size() != expected.size() or after[0] != expected[expected.size() - 1]:
		_fail += 1
		print("    !! the scan replaced the list rather than appending to it, or reordered what was "
			+ "already in it")
	_mgr.eroding_brushes = _none()
	_completed += 1


## Every brush in this gate's own fixtures that carries an enabled erosion modifier, in tree order.
## Deliberately does NOT call `erosion_modifiers()` — see this gate's header.
func _eroding_in_fixture() -> Array:
	var out: Array = []
	_walk_fixture(_root, out)
	return out


func _walk_fixture(p_from: Node, r_out: Array) -> void:
	for c in p_from.get_children():
		if c is Pasture3DMound:
			for m in (c as Pasture3DMound).modifiers:
				if m is Pasture3DNodeErosion and (m as Pasture3DNodeErosion).enabled:
					r_out.append(c)
					break
		_walk_fixture(c, r_out)


func _registered_nodes() -> Array:
	var out: Array = []
	for path in _mgr.eroding_brushes:
		var n: Node = _mgr.get_node_or_null(path)
		if n != null:
			out.append(n)
	return out


func _names(p_nodes: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for n in p_nodes:
		out.append(String(n.name))
	return out


func _erosion_of(p_mound) -> Pasture3DNodeErosion:
	for m in p_mound.modifiers:
		if m is Pasture3DNodeErosion:
			return m
	return null


# ---- fixtures --------------------------------------------------------------------------------------


## A Mound carrying the shipped workflow: a craggy relief shaped into a dome, then FROZEN erosion over it.
func _make_mound(p_name: String, p_at: Vector3, p_layer: String):
	if not is_finite(_height(p_at)):
		_fail += 1
		print("    !! no terrain at %s; the fixture is outside demo/data" % p_at)
		return null
	var mound := Pasture3DMound.new()
	mound.name = p_name
	_root.add_child(mound)
	mound.terrain = _terrain
	mound.global_position = p_at
	mound.height = 55.0
	# ADD, not the MAX default: the demo terrain is already tall at these sites and MAX would clamp away
	# exactly the change a re-solve is supposed to make visible.
	mound.blend_mode = Pasture3DMound.BlendMode.ADD
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	c.add_point(Vector3(-HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, HALF))
	c.add_point(Vector3(-HALF, 0.0, HALF))
	c.closed = true
	path.curve = c
	mound.add_child(path)
	mound._set_layer_owner(Pasture3DTerrainBrush.BRUSH_OWNER_PREFIX + p_layer)

	var mat := Pasture3DReliefFractal.new()
	mat.style = Pasture3DReliefFractal.Style.CRAGGY
	mat.feature_size = 22.0
	mat.seed = 5
	var shape := Pasture3DNodeRelief.new()
	shape.label = "Shape"
	shape.material = mat
	shape.strength = 8.0
	var ero := Pasture3DNodeErosion.new()
	ero.label = "Erosion"
	ero.iterations = 30
	ero.erosion_rate = 0.09
	ero.hillslope_diffusion = 0.02
	# FROZEN is the shipped default and is left alone here, deliberately: the registry exists because a
	# frozen solve does not follow its input, and a gate that set this to Live would be testing a
	# configuration in which Bake All has nothing to do.
	var stack: Array[Pasture3DNode] = [shape, ero]
	mound.modifiers = stack
	return mound


## A typed empty list. An untyped `[]` does not convert through an `Array[NodePath]` property.
func _none() -> Array[NodePath]:
	return []


func _shape_of(p_mound) -> Pasture3DNodeRelief:
	return p_mound.modifiers[0] as Pasture3DNodeRelief


## Does this brush's erosion modifier consider itself stale — i.e. is it showing a solve for a shape that
## has since moved? Read through the brush's own warnings, which is where the artist reads it.
func _is_stale(p_mound) -> bool:
	for m in p_mound.modifiers:
		if m is Pasture3DNodeErosion:
			for w in (m as Pasture3DNodeErosion).modifier_warnings(p_mound):
				if w.contains("FROZEN") and w.contains("changed"):
					return true
	return false


func _registry_warnings() -> PackedStringArray:
	return _mgr._registry_warnings()


func _owner_names(p_plan: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for e in p_plan:
		out.append(String(e["owner"]))
	return out


# ---- measurement -----------------------------------------------------------------------------------


func _lattice(p_centre: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var step := _vs * PROBE_STRIDE
	var reach := HALF - _vs * 3.0
	var x := -reach
	while x <= reach:
		var z := -reach
		while z <= reach:
			out.append(Vector3(snappedf(p_centre.x + x, _vs), 0.0, snappedf(p_centre.z + z, _vs)))
			z += step
		x += step
	return out


func _snapshot(p_points: Array[Vector3]) -> Array[float]:
	var out: Array[float] = []
	for p in p_points:
		out.append(_height(p))
	return out


func _first_difference(p_a: Array[float], p_b: Array[float]) -> int:
	for i in range(mini(p_a.size(), p_b.size())):
		var same := p_a[i] == p_b[i] or (not is_finite(p_a[i]) and not is_finite(p_b[i]))
		if not same:
			return i
	return -1


func _max_abs_diff(p_a: Array[float], p_b: Array[float]) -> float:
	var worst := 0.0
	for i in range(mini(p_a.size(), p_b.size())):
		if is_finite(p_a[i]) and is_finite(p_b[i]):
			worst = maxf(worst, absf(p_a[i] - p_b[i]))
	return worst


func _height(p_at: Vector3) -> float:
	return _terrain.data.get_height(Vector3(p_at.x, 0.0, p_at.z))


# --- DF: Clear Simulation On All Brushes takes the erosion off, and only off the registered set ------
#
# Spec §14. The counterpart to Bake All Brushes and the brush-registry counterpart to Clear Simulation:
# every registered brush's frozen solve is dropped and its layer re-baked with the erosion suppressed, so
# the ground holds the shape the brushes make BEFORE they erode.
#
# BOTH HALVES ARE CLAIMS AND NEITHER IS ENOUGH ALONE, which is the whole reason this gate exists rather
# than a check that the caches are empty:
#
#   - drop the caches without re-baking, and the eroded heights stay in the layer. The button frees some
#     memory and appears to do nothing, which is the version that would ship if nobody measured HEIGHT.
#   - re-bake without dropping them, and the cached erosion is served straight back. Identical outcome,
#     opposite bug.
#
# CONTROL 1: an UNREGISTERED brush on its own layer must not move. "Clear everything" and "clear the
# registered set" produce the same reading on a fixture where everything is registered, and the list is
# the entire point of the registry.
#
# CONTROL 2: there has to have been an erosion on the ground to take off. A fixture whose solve cut
# nothing passes the headline claim perfectly and says nothing.
#
# CONTROL 3: it must be REVERSIBLE by Bake All Brushes. Clearing is not disabling — nothing about the
# brushes changed — and a clear that could not be re-baked would mean the button had edited the scene.
func _gate_df_clear_all_brushes() -> void:
	print("\n[DF] Clear Simulation On All Brushes takes the erosion off the registered set:")
	var reg_a = _make_mound("ClearA", SITE_I, "ClearA")
	var reg_b = _make_mound("ClearB", SITE_J, "ClearB")
	var unreg = _make_mound("ClearU", SITE_K, "ClearU")
	if reg_a == null or reg_b == null or unreg == null:
		return
	var pa := _lattice(SITE_I)
	var pb := _lattice(SITE_J)
	var pu := _lattice(SITE_K)

	# The un-eroded reference, taken first: the same stacks with the modifier unchecked.
	for m in [reg_a, reg_b, unreg]:
		(m.modifiers[1] as Pasture3DNodeErosion).enabled = false
		m._refresh_owner(m._layer_owner, false, [])
	var bare_a := _snapshot(pa)
	var bare_b := _snapshot(pb)
	for m in [reg_a, reg_b, unreg]:
		(m.modifiers[1] as Pasture3DNodeErosion).enabled = true
		m._refresh_owner(m._layer_owner, false, [])
	var eroded_a := _snapshot(pa)
	var eroded_u := _snapshot(pu)

	var listed: Array[NodePath] = [_mgr.get_path_to(reg_a), _mgr.get_path_to(reg_b)]
	_mgr.eroding_brushes = listed
	var report: Dictionary = _mgr.clear_all_brushes()
	if not bool(report["ok"]):
		_fail += 1
		print("    !! the button refused: %s" % report["reason"])
		return
	var clear_a := _snapshot(pa)
	var clear_b := _snapshot(pb)
	var clear_u := _snapshot(pu)

	var back_a := _first_difference(clear_a, bare_a)
	var back_b := _first_difference(clear_b, bare_b)
	var moved_u := _worst(clear_u, eroded_u)
	var took_off := _worst(clear_a, eroded_a)
	print("    %d brush(es) across %d layer(s), %d frozen solve(s) dropped"
			% [int(report["brushes"]), int(report["owners"]), int(report["cleared"])])
	print("    layer A back to its un-eroded shape: %s"
			% ["bitwise identical" if back_a < 0 else "MOVED at probe %d" % back_a])
	print("    layer B back to its un-eroded shape: %s"
			% ["bitwise identical" if back_b < 0 else "MOVED at probe %d" % back_b])
	print("    CONTROL it took a real erosion off layer A: %.4f m" % took_off)
	print("    CONTROL the unregistered brush did not move: %.8f m" % moved_u)
	if back_a >= 0 or back_b >= 0:
		_fail += 1
		print("    !! a cleared layer is not the shape the brush makes before it erodes")
	if int(report["owners"]) != 2:
		_fail += 1
		print("    !! expected 2 layer owners, got %d" % int(report["owners"]))
	if int(report["cleared"]) < 2:
		_fail += 1
		print("    !! fewer frozen solves were dropped than there are registered brushes")
	if not is_finite(took_off) or took_off < 1.0:
		_fail += 1
		print("    !! there was no erosion on the ground to clear, so clearing it proves nothing")
	if not is_finite(moved_u) or moved_u > 1.0e-6:
		_fail += 1
		print("    !! an UNREGISTERED brush moved, or its probes read off the terrain — either way this "
			+ "control is not controlling")

	# CONTROL 3. Nothing was disabled, so Bake All Brushes puts it back.
	var again: Dictionary = _mgr.bake_all_brushes_now(false)
	var re_a := _snapshot(pa)
	var restored := _first_difference(re_a, eroded_a)
	print("    CONTROL Bake All Brushes puts it back: %s (baked %d)"
			% ["bitwise identical" if restored < 0 else "MOVED at probe %d" % restored,
				int(again.get("baked", 0))])
	if restored >= 0:
		_fail += 1
		print("    !! the clear was not reversible, so it changed more than what is on the ground")


## Worst absolute difference between two probe runs, or NAN if either run read off the terrain.
##
## Non-finite is returned rather than skipped ON PURPOSE. A probe run of NaNs compares equal to nothing
## and `nan > tolerance` is FALSE, so a control built on one passes silently — which is exactly what this
## gate did on its first run, reporting "the unregistered brush did not move: nan" as a pass. Every caller
## checks `is_finite` on the way out.
func _worst(p_a: Array[float], p_b: Array[float]) -> float:
	var out := 0.0
	for i in range(mini(p_a.size(), p_b.size())):
		if not is_finite(p_a[i]) or not is_finite(p_b[i]):
			return NAN
		out = maxf(out, absf(p_a[i] - p_b[i]))
	return out
