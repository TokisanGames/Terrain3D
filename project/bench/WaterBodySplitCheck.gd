# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# The water body split: Pasture3DPool / Pasture3DStream / Pasture3DWaterBody.
# See PASTURE3D_WATER_BODIES_SPEC.md §13.
#
# The behaviour the split is claimed not to have changed is covered by the phase gates, which were
# moved onto the new classes and kept their criteria. This file covers the things the split ADDED,
# which no existing gate is looking at:
#
#   A. a Pasture3DPool refuses an open curve and names the fix. CONTROL: the same pool with a
#      closed curve builds, so "refuses" is about the curve and not about the fixture
#   B. Convert to Stream produces a Pasture3DStream carrying the settings, in the same tree slot.
#      CONTROL: pressed on a closed curve it refuses, so the button is not simply always converting
#   C. a stream gets an underwater volume -- the bug §13.4 records, where ribbons silently had none.
#      CONTROL: underwater_enabled = false gives no volume, so the check reads the flag and not the
#      mere existence of children
#   D. a failed build forgets the geometry it used to answer containment from. CONTROL: the same
#      point before the failure, which must be inside
#   E. both classes are in the pasture3d_pool group, which is what the selection gizmo, the brush's
#      idempotence check and the Phase 4 gate all find water through. CONTROL: a bare Node3D, which
#      must not be
#
# Headless: none of it needs a renderer, and none of it needs terrain -- a stream with no Pasture3D
# in the scene falls back to fill_offset, which is a supported path and enough to have a mesh.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/WaterBodySplitCheck.tscn
extends Node

const POOL_SCRIPT := "res://addons/pasture_3d/connectors/pasture3d_pool.gd"
const STREAM_SCRIPT := "res://addons/pasture_3d/connectors/pasture3d_stream.gd"
const LAKE_MAT := "res://addons/pasture_3d/extras/shaders/water/M_water_lake.tres"

var _fail := 0
var _completed := 0
const CRITERIA := 5


func _ready() -> void:
	print("\n=== Water body split ===")
	_a_pool_refuses_open_curve()
	_b_convert_to_stream()
	_c_stream_has_a_volume()
	_d_failed_build_forgets()
	_e_both_in_the_group()

	print("")
	if _completed != CRITERIA:
		_fail += 1
		print("!! only %d of %d criteria ran to completion" % [_completed, CRITERIA])
	print("=== %s ===" % ("PASS" if _fail == 0 else "FAIL (%d)" % _fail))
	get_tree().quit(0 if _fail == 0 else 1)


# ---- A ------------------------------------------------------------------------

func _a_pool_refuses_open_curve() -> void:
	print("\nA. a Pasture3DPool refuses an open curve and says to convert")
	var root := _world()
	var pool = _make(POOL_SCRIPT, root)
	pool.curve = _open_curve(80.0)
	var stats: Dictionary = pool.rebuild()
	var warnings := "; ".join(pool._get_configuration_warnings())
	print("    open curve  -> ok=%s reason=%s" % [stats.get("ok", false), stats.get("reason", "")])
	print("    warning: %s" % warnings)
	if stats.get("ok", false):
		_fail += 1
		print("    !! it built a mesh from an open curve")
	# The warning has to name the ROUTE, not just report a shape problem. A user arriving here has a
	# river that used to work and now draws nothing; "fewer than 3 points" would be a wrong answer
	# confidently given.
	if not warnings.contains("Convert to Stream") or not warnings.contains("Pasture3DStream"):
		_fail += 1
		print("    !! the warning does not point at Pasture3DStream / Convert to Stream")

	# CONTROL: the same node, closed curve. If this does not build, A proves nothing about curves.
	pool.curve = _closed_curve(40.0)
	var cstats: Dictionary = pool.rebuild()
	print("    CONTROL closed -> ok=%s vertices=%d" % [
			cstats.get("ok", false), cstats.get("vertices", 0)])
	if not cstats.get("ok", false) or int(cstats.get("vertices", 0)) < 100:
		_fail += 1
		print("    !! CONTROL did not fire: the pool cannot build a closed curve either")
	root.queue_free()
	_completed += 1


# ---- B ------------------------------------------------------------------------

func _b_convert_to_stream() -> void:
	print("\nB. Convert to Stream carries the settings across")
	var root := _world()
	var filler := Node3D.new() # so the pool is at index 1 and the slot can be checked
	filler.name = "Filler"
	root.add_child(filler)
	var pool = _make(POOL_SCRIPT, root)
	pool.name = "RiverWater"
	pool.curve = _open_curve(80.0)
	pool.position = Vector3(12.0, -3.5, 7.0)
	pool.edge_offset = 3.25
	pool.volume_depth = 42.0
	pool.vertex_spacing = 2.0
	pool.wave_profile = &"river_flow"
	var idx_before := pool.get_index()

	var stream = pool.convert_to_stream()
	if stream == null:
		_fail += 1
		print("    !! convert_to_stream returned null; the rest of B proves nothing")
		root.queue_free()
		_completed += 1
		return
	var stats: Dictionary = stream.rebuild()
	print("    %s -> %s, index %d -> %d, ok=%s vertices=%d" % [
			pool.get_class_label(), stream.get_class_label(), idx_before, stream.get_index(),
			stats.get("ok", false), stats.get("vertices", 0)])

	var problems := PackedStringArray()
	if not (stream is Pasture3DStream):
		problems.append("not a Pasture3DStream")
	if String(stream.name) != "RiverWater":
		problems.append("renamed to '%s'" % stream.name)
	if stream.get_index() != idx_before:
		problems.append("moved from index %d to %d" % [idx_before, stream.get_index()])
	if pool.get_parent() != null:
		problems.append("the old pool is still in the tree")
	# The settings, one per kind: a transform, a Shape float, an Underwater float, a StringName.
	if not stream.position.is_equal_approx(Vector3(12.0, -3.5, 7.0)):
		problems.append("position %s" % stream.position)
	if not is_equal_approx(stream.edge_offset, 3.25):
		problems.append("edge_offset %.2f" % stream.edge_offset)
	if not is_equal_approx(stream.volume_depth, 42.0):
		problems.append("volume_depth %.2f" % stream.volume_depth)
	if stream.wave_profile != &"river_flow":
		problems.append("wave_profile %s" % stream.wave_profile)
	if not stats.get("ok", false):
		problems.append("the stream did not build: %s" % stats.get("reason", ""))
	if problems.is_empty():
		print("    -> class, name, slot, transform and four settings all carried")
	else:
		_fail += 1
		print("    !! %s" % "; ".join(problems))

	# CONTROL: a closed curve has nothing to convert, and the button must say so rather than making
	# a stream out of a lake.
	var croot := _world()
	var lake = _make(POOL_SCRIPT, croot)
	lake.curve = _closed_curve(40.0)
	lake.rebuild()
	var refused = lake.convert_to_stream()
	print("    CONTROL closed curve -> convert returned %s" % ("null" if refused == null else "a node"))
	if refused != null:
		_fail += 1
		print("    !! CONTROL did not fire: it converted a lake")
	root.queue_free()
	croot.queue_free()
	_completed += 1


# ---- C ------------------------------------------------------------------------

func _c_stream_has_a_volume() -> void:
	print("\nC. a stream gets an underwater volume (the bug in spec §13.4)")
	var root := _world()
	var stream = _make(STREAM_SCRIPT, root)
	stream.underwater_enabled = true
	stream.curve = _open_curve(80.0)
	var stats: Dictionary = stream.rebuild()
	if not stats.get("ok", false):
		_fail += 1
		print("    !! the stream did not build (%s); C proves nothing" % stats.get("reason", ""))
		root.queue_free()
		_completed += 1
		return
	var area := _area_of(stream)
	var size := Vector3.ZERO
	if area != null:
		for c in area.get_children():
			if c is CollisionShape3D and c.shape is BoxShape3D:
				size = (c.shape as BoxShape3D).size
	print("    volume: %s, box %.1v" % ["present" if area != null else "ABSENT", size])
	if area == null:
		_fail += 1
		print("    !! no Area3D — rivers still have no submersion volume")
	elif size.x < 1.0 or size.z < 1.0:
		_fail += 1
		print("    !! the volume box has no footprint; _poly_bounds was never set")

	# CONTROL: the flag genuinely governs it. Without this, "an Area3D exists" could be unconditional.
	var croot := _world()
	var dry = _make(STREAM_SCRIPT, croot)
	dry.underwater_enabled = false
	dry.curve = _open_curve(80.0)
	dry.rebuild()
	var carea := _area_of(dry)
	print("    CONTROL underwater_enabled=false -> %s" % ("no volume" if carea == null else "a volume"))
	if carea != null:
		_fail += 1
		print("    !! CONTROL did not fire: the volume ignores underwater_enabled")
	root.queue_free()
	croot.queue_free()
	_completed += 1


# ---- D ------------------------------------------------------------------------

func _d_failed_build_forgets() -> void:
	print("\nD. a failed build forgets the geometry it answered containment from")
	var root := _world()
	var pool = _make(POOL_SCRIPT, root)
	pool.curve = _closed_curve(40.0)
	var stats: Dictionary = pool.rebuild()
	# Well below the surface and well inside the loop, so this is a polygon answer and not a wave one.
	var probe := Vector3(0.0, pool.global_position.y - 5.0, 0.0)
	var inside_before: bool = pool.contains_point(probe)
	print("    built (%d verts): the loop's centre is inside = %s" % [
			int(stats.get("vertices", 0)), inside_before])
	if not stats.get("ok", false) or not inside_before:
		_fail += 1
		print("    !! CONTROL did not fire: the point was not inside to begin with, so the")
		print("       'no longer inside' below would be true for the wrong reason")
		root.queue_free()
		_completed += 1
		return

	# Take the loop away. The build fails; the question is whether the PREVIOUS build's polygon is
	# still answering. Before _build_failed() it was.
	pool.curve = Curve3D.new()
	var failed: Dictionary = pool.rebuild()
	var inside_after: bool = pool.contains_point(probe)
	print("    curve emptied -> ok=%s reason=%s | still inside = %s" % [
			failed.get("ok", false), failed.get("reason", ""), inside_after])
	if failed.get("ok", false):
		_fail += 1
		print("    !! an empty curve still built a mesh")
	if inside_after:
		_fail += 1
		print("    !! the pool still reports water that is no longer drawn")
	root.queue_free()
	_completed += 1


# ---- E ------------------------------------------------------------------------

func _e_both_in_the_group() -> void:
	print("\nE. both classes join pasture3d_pool")
	var root := _world()
	var pool = _make(POOL_SCRIPT, root)
	var stream = _make(STREAM_SCRIPT, root)
	var plain := Node3D.new()
	root.add_child(plain)
	var found := get_tree().get_nodes_in_group(&"pasture3d_pool")
	# The count includes the earlier criteria's nodes: queue_free() takes effect at the end of the
	# frame and this whole file runs inside one. Membership of THESE two is the claim; the count is
	# printed only so a zero is visible rather than silent.
	print("    group holds %d node(s) this frame: pool=%s stream=%s" % [
			found.size(), found.has(pool), found.has(stream)])
	if not found.has(pool) or not found.has(stream):
		_fail += 1
		print("    !! a water body is missing from the group the gizmo and the brush look in")
	# CONTROL: the group is not simply everything.
	print("    CONTROL a bare Node3D -> in the group = %s" % found.has(plain))
	if found.has(plain):
		_fail += 1
		print("    !! CONTROL did not fire: the group lookup matches anything")
	root.queue_free()
	_completed += 1


# ---- helpers -------------------------------------------------------------------

func _world() -> Node3D:
	var root := Node3D.new()
	add_child(root)
	var m = ClassDB.instantiate("Pasture3DPoolManager")
	m.name = "Pasture3DPoolManager"
	root.add_child(m)
	return root


## In the tree BEFORE the curve is assigned: _schedule_rebuild() early-returns outside the tree, so
## a node built the other way round sits there unbuilt and every criterion measures nothing.
func _make(p_script: String, p_root: Node3D) -> Node:
	var n: Node = load(p_script).new()
	n.material = load(LAKE_MAT)
	n.vertex_spacing = 2.0
	p_root.add_child(n)
	return n


func _closed_curve(p_half: float) -> Curve3D:
	var c := Curve3D.new()
	for p in [Vector3(-p_half, 0, -p_half), Vector3(p_half, 0, -p_half),
			Vector3(p_half, 0, p_half), Vector3(-p_half, 0, p_half)]:
		c.add_point(p)
	c.closed = true
	return c


func _open_curve(p_length: float) -> Curve3D:
	var c := Curve3D.new()
	for i in 9:
		var t := float(i) / 8.0
		c.add_point(Vector3(-p_length * 0.5 + t * p_length, -t * 4.0, 0.0))
	return c


func _area_of(p_node: Node) -> Area3D:
	for c in p_node.get_children():
		if c is Area3D:
			return c
	return null
