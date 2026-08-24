# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DPond.water_offset — the pond's own water level. PASTURE3D_POND_WATER_OFFSET_SPEC.md §7.
#
# Every criterion here is about a WORLD Y, so the rim is computed in this file from the Path3D's own
# baked points and global transform rather than by asking _spline_level(). A gate that asks the code
# under test whether it is right agrees with the bug.
#
# The rim is deliberately 37.25 m and the loop's low point is one specific corner: a level that came
# from "the offset" alone, or from the first point, or from the average, lands somewhere this can see.
#
# NOTHING IS SAVED. Pools are built in memory; demo/data on disk is only touched by an explicit save.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/PondWaterOffsetCheck.tscn
extends Node

const DEMO_DATA := "res://demo/data"
const POOL_SCRIPT := "res://addons/pasture_3d/connectors/pasture3d_pool.gd"
## Not zero and not round. A rim of 0.0 makes "read the rim" and "ignore the rim" the same number.
const RIM_Y := 37.25
const LOOP_HALF := 24.0
## The loop's corner heights, in the spline's local space. The LOWEST is the rim, and it is not the
## first point — so a level taken from point 0, or from the mean, reads differently from a level
## taken from the minimum.
const CORNER_Y := [3.0, 0.0, 1.5, 2.25]
## Sites, far enough apart that no two loops share a cell. Only W3 needs real ground under it.
const SITE_W1 := Vector2(600.0, 100.0)
const SITE_CTL := Vector2(600.0, 300.0)
const SITE_W3 := Vector2(180.0, 100.0)
const SITE_W4 := Vector2(600.0, 500.0)
const SITE_W5 := Vector2(900.0, 100.0)
const SITE_OPEN := Vector2(900.0, 300.0)
const SITE_CLOSED := Vector2(900.0, 500.0)
const SITE_MULTI := Vector2(1200.0, 100.0)

const EPS := 0.001
const EXPECTED_CASES := 8

var _fail := 0
## Completed criteria. A GDScript runtime error abandons _ready() without touching _fail, so a
## criterion that throws would otherwise read as a pass.
var _cases := 0
var _terrain
var _root: Node3D


func _ready() -> void:
	print("\n=== Pasture3DPond.water_offset ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	if _terrain.data == null:
		_fail += 1
		print("  !! no terrain data at %s; every brush would be unconfigured" % DEMO_DATA)
		_done()
		return
	if not ClassDB.class_exists("Pasture3DPoolManager"):
		_fail += 1
		print("  !! the water classes are missing from this build; nothing here can run")
		_done()
		return

	_w1_seed()
	_w2_live()
	_w3_carve_untouched()
	_w4_default_inert()
	_w5_warnings()
	_w6_derived_not_accumulated()
	_w7_open_loop()
	_w8_multi_spline()

	print("\n--- what this gate does NOT reach (spec §7.3) ---")
	print("  * The inspector's undo action. EditorUndoRedoManager does not exist headless, so W6")
	print("    gates the MECHANISM Ctrl+Z depends on (an idempotent, derived push), not the keystroke.")
	print("  * Auto-seeded water. _seed_setup is behind Engine.is_editor_hint(), so this run never")
	print("    auto-seeds; every pool below was made by an explicit add_pool_now().")
	print("  * Whether the water LOOKS right. Depth drives the shader's colour and shore foam.")

	if _cases != EXPECTED_CASES:
		_fail += 1
		print("\n  !! %d of %d criteria completed — one abandoned its function partway, and an"
			% [_cases, EXPECTED_CASES])
		print("     unfinished criterion is not a passing one")
	_done()


# ---- W1: the seed ---------------------------------------------------------------

func _w1_seed() -> void:
	print("W1. a new pool is seeded at rim + water_offset")
	var pond := _make_pond("W1Pond", SITE_W1, -2.0)
	var rim := _rim_of(pond)
	var pool := _add_water(pond)
	if pool == null:
		return
	var want := rim + (-2.0)
	print("    rim %.3f   water_offset %.2f   want %.3f   got %.3f (fill_offset %.2f)"
		% [rim, pond.water_offset, want, pool.global_position.y, pool.fill_offset])
	if absf(pool.global_position.y - want) > EPS:
		_fail += 1
		print("    !! the pool was not seeded on water_offset")
	if absf(pool.fill_offset - pond.water_offset) > EPS:
		_fail += 1
		print("    !! the pool's fill_offset does not read back the brush's water_offset")

	# CONTROL. A plain Mound has no opinion, so its pool must land on the water body's OWN default.
	# Without this, W1 passes on a pond whose default happens to be -2.0 and on a _pool_fill_offset()
	# hook that _build_pool_for never calls.
	var mound := _make_mound("W1Mound", SITE_CTL)
	var m_rim := _rim_of(mound)
	var m_pool := _add_water(mound)
	if m_pool == null:
		return
	var m_default: float = load(POOL_SCRIPT).new().fill_offset
	print("    CONTROL Mound: hook %s, rim %.3f, want %.3f, got %.3f"
		% [mound._pool_fill_offset(), m_rim, m_rim + m_default, m_pool.global_position.y])
	if not is_nan(mound._pool_fill_offset()):
		_fail += 1
		print("    !! CONTROL failed: a plain Mound has an opinion about water level, so the hook")
		print("       is not opt-in and W1 does not show the Pond supplied anything")
	if absf(m_pool.global_position.y - (m_rim + m_default)) > EPS:
		_fail += 1
		print("    !! CONTROL failed: the Mound's pool is not on the water body's default either,")
		print("       so W1's number does not distinguish 'the Pond set it' from 'everything moved'")
	if absf(pool.global_position.y - rim) < EPS or absf(m_default - (-2.0)) < EPS:
		_fail += 1
		print("    !! CONTROL failed: the pond's offset and the default coincide, so W1 measured nothing")
	_cases += 1


# ---- W2: the live dial ----------------------------------------------------------

func _w2_live() -> void:
	print("\nW2. writing water_offset moves water that ALREADY EXISTS")
	var pond := _make_pond("W2Pond", SITE_W1 + Vector2(0.0, 900.0), -2.0)
	var rim := _rim_of(pond)
	var pool := _add_water(pond)
	if pool == null:
		return
	var before: float = pool.global_position.y
	pond.water_offset = -3.0
	var after: float = pool.global_position.y
	var want := rim + (-3.0)
	print("    pool y %.3f -> %.3f   want %.3f   fill_offset now %.2f"
		% [before, after, want, pool.fill_offset])
	if absf(after - want) > EPS:
		_fail += 1
		print("    !! the existing pool did not follow water_offset")
	if absf(pool.fill_offset - (-3.0)) > EPS:
		_fail += 1
		print("    !! the pool's fill_offset was not updated, so the two nodes now disagree")
	if absf(after - before) < EPS:
		_fail += 1
		print("    !! the pool did not MOVE — the two levels coincide, so this measured nothing")

	# CONTROL. The same write attempted on a Mound, which has no such property. Its pool must sit
	# still. If it moves, something ambient is re-levelling water and W2's number is not the Pond's.
	var mound := _make_mound("W2Mound", SITE_CTL + Vector2(0.0, 900.0))
	var m_pool := _add_water(mound)
	if m_pool == null:
		return
	var m_before: float = m_pool.global_position.y
	var has_prop := false
	for p in mound.get_property_list():
		if p.name == "water_offset":
			has_prop = true
	mound.set("water_offset", -3.0)
	var m_after: float = m_pool.global_position.y
	print("    CONTROL Mound: has water_offset = %s, pool y %.3f -> %.3f"
		% [has_prop, m_before, m_after])
	if has_prop:
		_fail += 1
		print("    !! CONTROL failed: the Mound has a water_offset too, so it is not an absence")
	if absf(m_after - m_before) > EPS:
		_fail += 1
		print("    !! CONTROL failed: the Mound's water moved as well, so W2 is not measuring the Pond")
	_cases += 1


# ---- W3: the carve is untouched -------------------------------------------------

func _w3_carve_untouched() -> void:
	print("\nW3. changing water_offset does not change the carve")
	var pond := _make_pond("W3Pond", SITE_W3, -1.0)
	pond._refresh_owner(pond._layer_owner, false, [])
	var a := _samples(SITE_W3)
	if a.is_empty():
		_fail += 1
		print("    !! no finite ground at %s; the fixture is outside demo/data and W3 measures nothing"
			% SITE_W3)
		return

	pond.water_offset = -3.25
	pond._refresh_owner(pond._layer_owner, false, [])
	var b := _samples(SITE_W3)
	var moved := 0
	var worst := 0.0
	for i in a.size():
		var d: float = absf(b[i] - a[i])
		worst = maxf(worst, d)
		if d > 0.0:
			moved += 1
	print("    %d samples, %d moved, worst delta %.6f m" % [a.size(), moved, worst])
	if moved > 0:
		_fail += 1
		print("    !! the water level changed the terrain")

	# CONTROL. The same probe across a change to `height` must report a difference. A probe reading
	# a stale or unbaked buffer says "identical" forever, and would report W3 green on a build where
	# water_offset DID move the ground.
	pond.height = 12.0
	pond._refresh_owner(pond._layer_owner, false, [])
	var c := _samples(SITE_W3)
	var ctl_worst := 0.0
	for i in a.size():
		ctl_worst = maxf(ctl_worst, absf(c[i] - a[i]))
	print("    CONTROL height 4 -> 12: worst delta %.3f m" % ctl_worst)
	if ctl_worst < 1.0:
		_fail += 1
		print("    !! CONTROL failed: the probe cannot see a carve change at all, so W3's")
		print("       'identical' is the probe being blind, not the feature being clean")
	_cases += 1


# ---- W4: the default is inert ---------------------------------------------------

func _w4_default_inert() -> void:
	print("\nW4. the default changes nothing in scenes that already exist")
	# Read BOTH defaults off the classes. Comparing each to the literal -0.5 keeps passing after
	# someone changes one of them.
	var pond_default: float = Pasture3DPond.new().water_offset
	var body_default: float = load(POOL_SCRIPT).new().fill_offset
	print("    Pasture3DPond.water_offset = %.4f" % pond_default)
	print("    Pasture3DPool.fill_offset  = %.4f  (read from the class, not a literal)" % body_default)
	if absf(pond_default - body_default) > EPS:
		_fail += 1
		print("    !! the two defaults disagree, so adding this property moves water in saved scenes")

	var pond := _make_pond("W4Pond", SITE_W4, NAN) # NAN = write nothing, keep the default
	var rim := _rim_of(pond)
	var pool := _add_water(pond)
	if pool == null:
		return
	print("    untouched pond: rim %.3f, pool y %.3f, want %.3f"
		% [rim, pool.global_position.y, rim + body_default])
	if absf(pool.global_position.y - (rim + body_default)) > EPS:
		_fail += 1
		print("    !! an untouched pond no longer lands where a pre-change pond did")
	_cases += 1


# ---- W5: the warnings -----------------------------------------------------------

func _w5_warnings() -> void:
	print("\nW5. the out-of-band warnings fire, one at a time, and stop")
	var pond := _make_pond("W5Pond", SITE_W5, -0.5)
	var pool := _add_water(pond)
	if pool == null:
		return
	# Baseline at the default. Region-coverage warnings live in here too; every case below is a
	# DELTA against this, so they cancel.
	var base := pond._get_configuration_warnings()
	print("    baseline at water_offset -0.5: %d warning(s)" % base.size())

	var msgs := PackedStringArray()
	_warn_case(pond, "spilling  (+1.0)", func(): pond.water_offset = 1.0, base.size(), "ABOVE", msgs)
	_warn_case(pond, "dry       (-height)", func(): pond.water_offset = -pond.height, base.size(),
		"dry", msgs)
	# Back to agreement, then desync the pool by hand — the case the on-change push deliberately
	# does not chase.
	pond.water_offset = -0.5
	_warn_case(pond, "hand-edited pool", func(): pool.fill_offset = -1.0, base.size(),
		"fill_offset", msgs)

	# CONTROL. Restore agreement and the count must come back to the baseline. A warning function
	# that returned all three unconditionally would have shown deltas of 3, and one that never
	# clears would fail here.
	pool.fill_offset = -0.5
	var restored := pond._get_configuration_warnings()
	print("    CONTROL restored: %d warning(s), baseline %d" % [restored.size(), base.size()])
	if restored.size() != base.size():
		_fail += 1
		print("    !! the water warnings do not clear, so they are not reporting a condition")
	if msgs.size() == 3 and (msgs[0] == msgs[1] or msgs[1] == msgs[2] or msgs[0] == msgs[2]):
		_fail += 1
		print("    !! two cases produced the SAME message, so the count is not telling them apart")
	_cases += 1


func _warn_case(p_pond: Node, p_label: String, p_apply: Callable, p_base: int, p_needle: String,
		p_msgs: PackedStringArray) -> void:
	p_apply.call()
	var w := p_pond._get_configuration_warnings()
	var delta := w.size() - p_base
	var found := ""
	for s in w:
		if s.contains(p_needle):
			found = s
	print("      %-20s delta %+d, mentions '%s': %s" % [p_label, delta, p_needle, found != ""])
	if delta != 1:
		_fail += 1
		print("      !! expected exactly one new warning, got %d" % delta)
	if found == "":
		_fail += 1
		print("      !! the new warning is not the one this case is about")
	p_msgs.append(found)


# ---- W6: derived, not accumulated -----------------------------------------------

func _w6_derived_not_accumulated() -> void:
	print("\nW6. the push is DERIVED — the undo mechanism, measured without an editor")
	var pond := _make_pond("W6Pond", SITE_W1 + Vector2(0.0, 1800.0), -2.0)
	var rim := _rim_of(pond)
	var pool := _add_water(pond)
	if pool == null:
		return
	var first: float = pool.global_position.y
	pond.water_offset = -3.0
	# The intermediate write must actually have moved something. Without this, a push that does
	# NOTHING AT ALL satisfies "returning to a value returns the water" trivially — the water never
	# left. W2 catches a dead push, but a criterion that is vacuous on its own is still vacuous.
	var mid: float = pool.global_position.y
	pond.water_offset = -2.0
	var again: float = pool.global_position.y
	print("    -2.0 -> %.4f, then -3.0 -> %.4f, then -2.0 -> %.4f" % [first, mid, again])
	if absf(mid - first) < EPS:
		_fail += 1
		print("    !! the intermediate write moved nothing, so the round trip proves nothing")
	if first != again:
		_fail += 1
		print("    !! returning to a value does not return the water; Ctrl+Z would revert the")
		print("       property and leave the level where the last push put it")

	# CONTROL. What an ACCUMULATING push would have produced from the same three writes. If the real
	# answer equalled this, the criterion would not be separating the two implementations.
	var acc: float = load(POOL_SCRIPT).new().fill_offset
	for v in [-2.0, -3.0, -2.0]:
		acc += v
	print("    CONTROL an accumulating push would land at %.4f (fill_offset %.2f)" % [rim + acc, acc])
	if absf(again - (rim + acc)) < EPS:
		_fail += 1
		print("    !! the derived and accumulating answers coincide, so W6 measured nothing")
	_cases += 1


# ---- W7: an opened loop is a stream, and is left alone --------------------------

func _w7_open_loop() -> void:
	print("\nW7. an OPENED pond loop is a stream, and water_offset does not pretend to drive it")
	var pond := _make_pond("W7Open", SITE_OPEN, -2.0, false) # false = open curve
	var body := _add_water(pond)
	if body == null:
		return
	# Answered with the Script API, not with the pond's own _is_stream helper: neutering that helper
	# must not make the gate agree with it.
	var label: String = body.get_class_label()
	print("    created a %s, fill_offset seeded to %.2f" % [label, body.fill_offset])
	if label != "Pasture3DStream":
		_fail += 1
		print("    !! an open loop did not produce a stream; W7 is not testing what it claims")
	# The seed applies to BOTH kinds (spec §5): at creation there is nothing else to seed a stream's
	# no-terrain fallback from.
	if absf(body.fill_offset - (-2.0)) > EPS:
		_fail += 1
		print("    !! the stream's fallback level was not seeded from the brush")

	var before: float = body.global_position.y
	pond.water_offset = -3.0
	var after: float = body.global_position.y
	print("    stream y %.3f -> %.3f (want unchanged), fill_offset %.2f (want -2.00)"
		% [before, after, body.fill_offset])
	if absf(after - before) > EPS:
		_fail += 1
		print("    !! the push moved a stream, whose surface comes from its banks")
	if absf(body.fill_offset - (-2.0)) > EPS:
		_fail += 1
		print("    !! the push wrote a stream's fill_offset, which its banks override anyway")

	# CONTROL. A CLOSED loop in the same fixture, same write, must move. Without it W7 passes on a
	# build where water_offset does nothing anywhere.
	var closed := _make_pond("W7Closed", SITE_CLOSED, -2.0)
	var pool := _add_water(closed)
	if pool == null:
		return
	var c_before: float = pool.global_position.y
	closed.water_offset = -3.0
	var c_after: float = pool.global_position.y
	print("    CONTROL closed loop: pool y %.3f -> %.3f" % [c_before, c_after])
	if absf(c_after - c_before) < EPS:
		_fail += 1
		print("    !! CONTROL failed: the closed pond's water did not move either, so W7's")
		print("       'unchanged' is the feature being inert, not the stream being respected")
	_cases += 1


# ---- W8: every loop, not just the first -----------------------------------------

func _w8_multi_spline() -> void:
	print("\nW8. a pond with TWO loops moves BOTH pools")
	# The single-loop fixtures above cannot tell _apply_water_offset's per-spline loop from an
	# implementation that only ever touches _get_splines()[0]. This one can.
	var pond := Pasture3DPond.new()
	pond.name = "W8Pond"
	pond.auto_add_water = false
	pond.auto_add_loop = false
	_root.add_child(pond)
	pond.terrain = _terrain
	pond.global_position = Vector3(SITE_MULTI.x, RIM_Y, SITE_MULTI.y)
	pond.water_offset = -2.0
	# Different LIFT, so the two loops have different rims and the two pools sit at different Ys.
	# Equal rims would make "both followed" and "one pool written twice" the same reading.
	_give_loop(pond, true, "LoopA", 0.0, Vector2.ZERO)
	_give_loop(pond, true, "LoopB", 6.0, Vector2(0.0, 120.0))

	var made: Array = pond.add_pool_now()
	print("    loops %d -> pools %d" % [pond._get_splines().size(), made.size()])
	if made.size() != 2:
		_fail += 1
		print("    !! the fixture did not produce two pools, so W8 cannot see the loop at all")
		return

	# Paired by the pool's own source_spline rather than by array order, and the rim of each is
	# computed here from that spline's baked points.
	var rims := PackedFloat64Array()
	for p in made:
		rims.append(_rim_from_path(p.source_spline))
	if absf(rims[0] - rims[1]) < 1.0:
		_fail += 1
		print("    !! the two loops have the same rim (%.3f, %.3f); 'both moved' and 'one moved"
			% [rims[0], rims[1]])
		print("       twice' would read identically, so this measured nothing")
		return

	pond.water_offset = -3.5
	var ok := true
	for i in made.size():
		var p = made[i]
		var want: float = rims[i] + (-3.5)
		var got: float = p.global_position.y
		print("      %-14s rim %.3f  want %.3f  got %.3f  fill_offset %.2f"
			% [p.name, rims[i], want, got, p.fill_offset])
		if absf(got - want) > EPS or absf(p.fill_offset - (-3.5)) > EPS:
			ok = false
	if not ok:
		_fail += 1
		print("    !! not every pool followed water_offset; the push is not per-spline")
	_cases += 1


# ---- fixture --------------------------------------------------------------------

## A configured pond at `p_xz`, with `p_offset` written BEFORE it is given water so the write goes
## through the seed path. Pass NAN to leave water_offset alone.
func _make_pond(p_name: String, p_xz: Vector2, p_offset: float, p_closed: bool = true) -> Node:
	var pond := Pasture3DPond.new()
	pond.name = p_name
	pond.auto_add_water = false # water here is always an explicit add_pool_now()
	pond.auto_add_loop = false  # ...and the loop is always this file's, with a known low corner
	_root.add_child(pond)
	pond.terrain = _terrain
	pond.global_position = Vector3(p_xz.x, RIM_Y, p_xz.y)
	if is_finite(p_offset):
		pond.water_offset = p_offset
	_give_loop(pond, p_closed)
	return pond


func _make_mound(p_name: String, p_xz: Vector2) -> Node:
	var mound := Pasture3DMound.new()
	mound.name = p_name
	_root.add_child(mound)
	mound.terrain = _terrain
	mound.global_position = Vector3(p_xz.x, RIM_Y, p_xz.y)
	_give_loop(mound, true)
	return mound


## `p_lift` raises every corner, so a second loop on the same brush has a DIFFERENT rim and the two
## pools it produces sit at two different levels. `p_shift` moves it clear of the first in XZ.
func _give_loop(p_brush: Node, p_closed: bool, p_name: String = "Loop1", p_lift: float = 0.0,
		p_shift: Vector2 = Vector2.ZERO) -> void:
	var path := Path3D.new()
	path.name = p_name
	path.position = Vector3(p_shift.x, 0.0, p_shift.y)
	var c := Curve3D.new()
	c.add_point(Vector3(-LOOP_HALF, CORNER_Y[0] + p_lift, -LOOP_HALF))
	c.add_point(Vector3(LOOP_HALF, CORNER_Y[1] + p_lift, -LOOP_HALF))
	c.add_point(Vector3(LOOP_HALF, CORNER_Y[2] + p_lift, LOOP_HALF))
	c.add_point(Vector3(-LOOP_HALF, CORNER_Y[3] + p_lift, LOOP_HALF))
	c.closed = p_closed
	path.curve = c
	p_brush.add_child(path)


## The rim: the lowest baked point of the brush's first spline, in world y.
##
## Computed here from Path3D and Curve3D directly rather than from Pasture3DWaterBody._spline_level(),
## which is the thing under test. It also subtracts nothing — _spline_level() folds fill_offset in,
## and a gate that reused it could not tell a missing offset from a doubled one.
func _rim_of(p_brush: Node) -> float:
	var splines: Array = p_brush._get_splines()
	return _rim_from_path(splines[0]) if not splines.is_empty() else NAN


func _rim_from_path(p_path: Path3D) -> float:
	if p_path == null or p_path.curve == null:
		return NAN
	var xf := p_path.global_transform
	var lowest := INF
	for p in p_path.curve.get_baked_points():
		lowest = minf(lowest, (xf * p).y)
	return lowest


func _add_water(p_brush: Node) -> Node:
	var made: Array = p_brush.add_pool_now()
	if made.is_empty():
		_fail += 1
		print("    !! add_pool_now() made nothing for '%s'; the fixture has no water to measure"
			% p_brush.name)
		return null
	return made[0]


## Baked height at the basin centre and four points inside the rim, or [] if any is off-region.
func _samples(p_xz: Vector2) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	var d := LOOP_HALF - 6.0
	var offsets := [Vector2.ZERO, Vector2(d, 0.0), Vector2(-d, 0.0), Vector2(0.0, d), Vector2(0.0, -d)]
	for o in offsets:
		var h: float = _terrain.data.get_height(Vector3(p_xz.x + o.x, 0.0, p_xz.y + o.y))
		if not is_finite(h):
			return PackedFloat64Array()
		out.append(h)
	return out


func _done() -> void:
	print("\n=== %s (%d failures, %d/%d criteria completed) ===\n"
		% ["PASS" if _fail == 0 else "FAIL", _fail, _cases, EXPECTED_CASES])
	get_tree().quit(0 if _fail == 0 else 1)
