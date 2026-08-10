# DIAGNOSTIC PROBE. Does a Pond whose loop reaches past the created regions say anything about it?
#
# Both native write paths skip cells with no region under them -- _stamp_write (brush_raster.cpp:343)
# and _apply_stamp_block ("only write where a region exists", brush_raster.cpp:396). Neither warns.
# At 4 km^2 a lake needs 121 regions at the 256 m default, so a partly-covered loop is the normal case,
# not an edge case.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/PondRegionCoverageProbe.tscn
extends Node


func _ready() -> void:
	print("\n=== Pond vs region coverage ===\n")
	var root := Node3D.new()
	add_child(root)
	var terrain = ClassDB.instantiate("Pasture3D")
	root.add_child(terrain)
	var rs: float = terrain.region_size * terrain.vertex_spacing

	# Cover only the NEGATIVE-X half of what the loop will span.
	for rx in range(-2, 0):
		for rz in range(-2, 2):
			terrain.data.add_region_blankp(Vector3((rx + 0.5) * rs, 0.0, (rz + 0.5) * rs), false)
	print("regions cover x in [%.0f, %.0f); the loop will span [-400, +400]" % [-2.0 * rs, 0.0])

	var p := Pasture3DPond.new()
	p.auto_add_water = false
	p.auto_add_loop = false
	root.add_child(p)
	p.terrain = terrain
	p.global_position = Vector3.ZERO
	var path := Path3D.new()
	var c := Curve3D.new()
	for v in [Vector3(-400, 0, -400), Vector3(400, 0, -400), Vector3(400, 0, 400), Vector3(-400, 0, 400)]:
		c.add_point(v)
	c.closed = true
	path.curve = c
	p.add_child(path)

	var xs := [-300.0, -200.0, -100.0, 100.0, 200.0, 300.0]
	var before: Array[float] = []
	for x in xs:
		before.append(terrain.data.get_height(Vector3(x, 0.0, 0.0)))

	p._refresh_owner(p._layer_owner, false, [])

	print("\n  x      before     after      carved?")
	for i in range(xs.size()):
		var a: float = terrain.data.get_height(Vector3(xs[i], 0.0, 0.0))
		var carved := is_finite(a) and is_finite(before[i]) and (a - before[i]) < -0.5
		print("  %+7.0f  %8s  %8s  %s" % [xs[i], _f(before[i]), _f(a), "yes" if carved else "NO"])

	var warnings := p._get_configuration_warnings()
	print("\n  configuration warnings the brush raises: %d" % warnings.size())
	for w in warnings:
		print("    - %s" % w)
	if warnings.is_empty():
		print("    (none -- the uncarved half is silent)")

	print("\n=== probe complete ===\n")
	get_tree().quit(0)


func _f(v: float) -> String:
	return "nan" if not is_finite(v) else "%.2f" % v
