# DIAGNOSTIC PROBE, not a gate. Finds what actually breaks when a Pasture3DPond is scaled up towards
# a 4 km^2 lake (2000 x 2000 m).
#
# A FRESH terrain per size, with only the regions that size needs. The first version of this probe
# reused one terrain and one origin, so each pond's baseline had already been carved by the previous
# one and the centre read "no change" -- a contaminated baseline reporting as a bug. Rebuilding per
# size is what makes each delta a measurement of THIS pond.
#
# Reports, per size: regions needed, the bake grid, whether the floor carved across the whole basin,
# and the wall-clock. Each size runs ONCE; this is a diagnostic, not a benchmark.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/PondScaleProbe.tscn
extends Node

## HALF-extents in metres, so the lake is 2*s square. 1000 -> 2000 x 2000 m = 4 km^2, the target.
const SIZES: Array[float] = [50.0, 250.0, 500.0, 1000.0]

var _root: Node3D


func _ready() -> void:
	print("\n=== Pasture3DPond scale probe ===\n")
	_root = Node3D.new()
	add_child(_root)
	for s in SIZES:
		_probe(s)
	print("\n=== probe complete ===\n")
	get_tree().quit(0)


func _probe(p_half: float) -> void:
	var side := 2.0 * p_half
	print("--- half-extent %.0f m  (%.0f x %.0f m, %.2f km^2) ---" % [
			p_half, side, side, side * side / 1.0e6])

	# Fresh terrain, so nothing this probe measures was carved by an earlier size.
	var terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(terrain)
	var rs: float = terrain.region_size * terrain.vertex_spacing
	# Regions covering the loop plus a margin, so every probe point has ground under it.
	var reach := int(ceil((p_half + 40.0) / rs))
	var made := 0
	for rx in range(-reach, reach + 1):
		for rz in range(-reach, reach + 1):
			terrain.data.add_region_blankp(Vector3((rx + 0.5) * rs, 0.0, (rz + 0.5) * rs), false)
			made += 1
	var vs: float = terrain.vertex_spacing
	var cells := int(side / vs) + 1
	print("    region_size %.0f m -> %d blank regions | bake grid %d x %d = %.2f M cells" % [
			rs, made, cells, cells, cells * cells / 1.0e6])

	var p := Pasture3DPond.new()
	p.name = "Pond%d" % int(p_half)
	p.auto_add_water = false # the water side is a separate question; this is about the carve
	p.auto_add_loop = false
	p.log_bake_timing = true
	_root.add_child(p)
	p.terrain = terrain
	p.global_position = Vector3.ZERO
	var path := Path3D.new()
	var c := Curve3D.new()
	c.add_point(Vector3(-p_half, 0.0, -p_half))
	c.add_point(Vector3(p_half, 0.0, -p_half))
	c.add_point(Vector3(p_half, 0.0, p_half))
	c.add_point(Vector3(-p_half, 0.0, p_half))
	c.closed = true
	path.curve = c
	p.add_child(path)

	# Baseline across the whole width BEFORE the bake, so every reading below is this pond's own work.
	var n := 17
	var xs: Array[float] = []
	var before: Array[float] = []
	for i in range(n):
		var x: float = -p_half + side * float(i) / float(n - 1)
		xs.append(x)
		before.append(_h(terrain, x))

	var t0 := Time.get_ticks_msec()
	p._refresh_owner(p._layer_owner, false, [])
	var ms := Time.get_ticks_msec() - t0

	var prof := ""
	var carved := 0
	var interior := 0
	var deepest := 0.0
	for i in range(n):
		var d := _h(terrain, xs[i]) - before[i]
		var is_edge: bool = i == 0 or i == n - 1
		if not is_finite(d):
			prof += " ? "
			continue
		if not is_edge:
			interior += 1
			if d < -0.5:
				carved += 1
		deepest = minf(deepest, d)
		prof += " # " if d < -0.5 else " . "
	print("    X profile (z=0):%s" % prof)
	print("    carved %d of %d interior samples | deepest %+.2f m | bake %d ms" % [
			carved, interior, deepest, ms])
	if carved < interior:
		print("    ^^ the basin is NOT carved across its whole width at this size")
	print("")

	p.queue_free()
	terrain.queue_free()


func _h(p_terrain, p_x: float) -> float:
	return p_terrain.data.get_height(Vector3(p_x, 0.0, 0.0))
