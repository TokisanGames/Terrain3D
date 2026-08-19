# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# The ribbon's surface comes from the BANKS, not from the bed.
#
# THE BUG. A Pasture3DTrough's spline is the bed FLOOR (follow_spline_height, the default), not a
# rim. fill_offset is measured downward from a rim -- correct for a loop pool, and exactly wrong
# here: the shipped -0.5 put the river surface half a metre BELOW its own channel floor. One
# property, two opposite meanings depending on which mesher read it.
#
# THE FIX, and why it is not just a sign flip. The surface is sampled from the terrain at the bank
# top and dropped by `bank_height`. That makes depth a function of the landscape rather than a
# constant, so a reach where the bed rises toward the surface becomes a FORD with no authoring --
# which a uniform depth, however correctly signed, could never produce.
#
# Tested WITHOUT a Trough on purpose. Pasture3DTerrainBrush.refresh() early-returns outside the
# editor, so no headless harness can bake one; and the feature under test is "does the surface
# track terrain", which a hand-placed ribbon over the demo terrain asks directly and without
# making the result depend on a brush's rasteriser.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/StreamBankSurfaceCheck.tscn
extends Node

const STREAM_SCRIPT := "res://addons/pasture_3d/connectors/pasture3d_stream.gd"
const RIVER_MAT := "res://addons/pasture_3d/extras/shaders/water/M_water_river.tres"
const DEMO_DATA := "res://demo/data"

## Where the demo terrain has relief to sample. The run crosses 42 m of it so bank heights differ
## row to row -- a flat reach would pass every check below while proving nothing about tracking.
##
## INSIDE THE LOADED REGIONS, which is not a free choice: demo/data holds 3 regions and
## get_height() returns NAN outside them. The first draft of this fixture ran at x = -40, entirely
## in the void, and every check failed for a reason that had nothing to do with the code.
const RUN_FROM := Vector3(180.0, 0.0, 0.0)
const RUN_TO := Vector3(180.0, 0.0, 200.0)
const ROWS := 9

var _fail := 0


func _ready() -> void:
	_run()


func _run() -> void:
	print("\n=== Stream bank-referenced surface ===\n")
	var root := Node3D.new()
	add_child(root)
	var terrain = ClassDB.instantiate("Pasture3D")
	root.add_child(terrain)
	terrain.data_directory = DEMO_DATA
	var manager = ClassDB.instantiate("Pasture3DPoolManager")
	root.add_child(manager)

	var pool = load(STREAM_SCRIPT).new()
	pool.material = load(RIVER_MAT)
	pool.wave_profile = &"river_flow"
	pool.vertex_spacing = 2.0
	pool.underwater_enabled = false
	pool.bank_height = 0.5
	pool.bank_search_width = 12.0
	pool.manager = manager
	root.add_child(pool)

	# A bed line dropped well below the ground: a channel, without needing a brush to carve one.
	var c := Curve3D.new()
	for i in ROWS:
		var t := float(i) / float(ROWS - 1)
		var p: Vector3 = RUN_FROM.lerp(RUN_TO, t)
		p.y = _ground(terrain, p) - 6.0
		c.add_point(p)
	pool.curve = c

	var stats: Dictionary = pool.rebuild()
	print("  ribbon: ok=%s vertices=%d reason=%s" % [
			stats.get("ok", false), stats.get("vertices", 0), stats.get("reason", "")])
	if not stats.get("ok", false):
		_fail += 1
		print("  !! the ribbon did not build; nothing below proves anything")
		_finish()
		return

	# The SAME pool with terrain removed and fill_offset 0 gives the rows sitting exactly on the
	# bed. Row count and XZ are identical between the two builds -- _ribbon_centreline distributes
	# rows by XZ distance and the surface is applied afterwards -- so this is an exact per-row bed
	# reference. Sampling the curve by arc fraction instead is NOT: the curve's Y variation makes
	# arc length and XZ distance diverge, which is what made the first version of this fixture
	# report two failures that were entirely its own.
	var bank_rows: PackedVector3Array = pool.get_centreline().duplicate()
	var bed_rows := _rebuild_without_terrain(root, terrain, pool, 0.0)
	if bed_rows.size() != bank_rows.size():
		_fail += 1
		print("  !! row counts differ (%d vs %d); the comparison below is invalid" % [
				bank_rows.size(), bed_rows.size()])
		_finish()
		return
	_reattach_terrain(root, terrain, pool)
	pool.fill_offset = -0.5
	pool.rebuild()

	var depths := PackedFloat32Array()
	var above := 0
	var deepest := 0
	for i in bank_rows.size():
		var depth: float = bank_rows[i].y - bed_rows[i].y
		depths.append(depth)
		if depth > 0.01:
			above += 1
		if depth > depths[deepest]:
			deepest = i

	# --- A: the surface is above the bed -------------------------------------
	print("A. the surface sits at the banks, not at the bed")
	print("  rows: %d | surface above the bed on %d of them" % [bank_rows.size(), above])
	print("  depth min %.2f m, max %.2f m" % [_min(depths), _max(depths)])
	# NOT "most rows must be wet". This fixture drops a bed 6 m into a 42 m hillside with no
	# built-up banks, so on the steep reaches the downhill crest sits BELOW the bed and the water
	# correctly drains away -- more than half the rows being dry is the right answer here, and an
	# earlier version of this check failed the code for giving it. What has to hold is that the
	# surface leaves the bed somewhere substantial; C is what proves it is the BANKS it followed.
	if above == 0:
		_fail += 1
		print("  !! no row has water above the bed; the surface never left the floor")
	elif _max(depths) < 1.0:
		_fail += 1
		print("  !! deepest row is under 1 m; the surface barely moved off the bed")

	# --- B: depth VARIES. The ford claim, and the whole reason for -----------
	#        sampling banks rather than offsetting the floor.
	print("
B. depth varies along the run (the ford claim)")
	var spread: float = _max(depths) - _min(depths)
	print("  depth spread %.2f m (must be > 0.25 to be tracking anything)" % spread)
	var dry := 0
	for d in depths:
		if d <= 0.01:
			dry += 1
	print("  %d of %d rows are dry -- fords, where the bed reaches the surface" % [
			dry, depths.size()])
	if spread <= 0.25:
		_fail += 1
		print("  !! depth is effectively constant; this is an offset, not a bank reference")

	# --- C: CONTROL. bank_height moves the surface 1:1 ----------------------
	# Measured on the DEEPEST row. On a dry row the surface is clamped to the bed and bank_height
	# legitimately does nothing, so testing there would fail the code for behaving correctly.
	print("
C. CONTROL, bank_height moves the surface (deepest row, %.2f m)" % depths[deepest])
	var before: float = bank_rows[deepest].y
	pool.bank_height = 3.5
	pool.rebuild()
	var after: float = pool.get_centreline()[deepest].y
	var moved: float = before - after
	print("  bank_height 0.5 -> 3.5 moved it down %.2f m (want ~3.00)" % moved)
	if absf(moved - 3.0) > 0.35:
		_fail += 1
		print("  !! the surface did not follow bank_height; it is not bank-referenced")
	pool.bank_height = 0.5
	pool.rebuild()

	# --- D: CONTROL. no terrain falls back to fill_offset -------------------
	# The water guide supports water in a scene with no Pasture3D at all, and that path has to keep
	# working or this feature silently breaks every bare-mesh river. Differential, for the same
	# reason as above: it needs no independent estimate of where the bed is.
	print("
D. CONTROL, no terrain falls back to fill_offset")
	var fb_a := _rebuild_without_terrain(root, terrain, pool, -1.25)
	var fb_b := _rebuild_without_terrain(root, terrain, pool, -4.25)
	var exact := fb_a.size() == fb_b.size() and fb_a.size() > 0
	if exact:
		for i in fb_a.size():
			if absf((fb_b[i].y - fb_a[i].y) + 3.0) > 0.001:
				exact = false
				break
	print("  fill_offset -1.25 -> -4.25 moved every row by exactly -3.0: %s" % exact)
	if not exact:
		_fail += 1
		print("  !! the no-terrain fallback is broken; bare-mesh rivers would break")

	# --- E: the waterline is per side ---------------------------------------
	print("
E. the waterline is found per side, not as one width")
	_reattach_terrain(root, terrain, pool)
	pool.rebuild()
	var l: PackedFloat32Array = pool._ribbon_half_l
	var r: PackedFloat32Array = pool._ribbon_half_r
	var asym := 0
	var widest := 0.0
	var narrowest := INF
	for i in mini(l.size(), r.size()):
		if absf(l[i] - r[i]) > 0.25:
			asym += 1
		widest = maxf(widest, l[i] + r[i])
		narrowest = minf(narrowest, l[i] + r[i])
	print("  per-row widths present: %s (%d rows)" % [l.size() > 0, l.size()])
	print("  width %.2f .. %.2f m | %d rows asymmetric by > 0.25 m" % [
			narrowest if narrowest != INF else 0.0, widest, asym])
	if l.is_empty() or r.is_empty():
		_fail += 1
		print("  !! no per-row widths; the ribbon fell back to a constant half-width")
	elif widest - narrowest <= 0.25:
		_fail += 1
		print("  !! the width never changes; the waterline is not being found")

	# --- F: flow_reverse flips direction, and ONLY direction -----------------
	print("
F. flow_reverse flips the encoded direction, not the geometry")
	var fwd_flow := _flow_dirs(pool)
	var fwd_l: PackedFloat32Array = pool._ribbon_half_l.duplicate()
	var fwd_r: PackedFloat32Array = pool._ribbon_half_r.duplicate()
	pool.flow_reverse = true
	pool.rebuild()
	var rev_flow := _flow_dirs(pool)
	var rev_l: PackedFloat32Array = pool._ribbon_half_l
	var rev_r: PackedFloat32Array = pool._ribbon_half_r

	var opposed := 0
	for i in mini(fwd_flow.size(), rev_flow.size()):
		if (fwd_flow[i] as Vector2).dot(rev_flow[i]) < -0.99:
			opposed += 1
	print("  %d of %d rows encode the exactly opposite direction" % [opposed, fwd_flow.size()])
	if opposed < fwd_flow.size():
		_fail += 1
		print("  !! flow did not reverse on every row")

	# CONTROL -- the waterlines must NOT move. Reversing flow by negating the tangent would also
	# negate the perpendicular and silently swap the two banks, which the containment test reads
	# by the same sign convention; the symptom would be a buoy beside the water it is in.
	var sides_held := fwd_l.size() == rev_l.size() and fwd_r.size() == rev_r.size()
	if sides_held:
		for i in fwd_l.size():
			if absf(fwd_l[i] - rev_l[i]) > 0.001 or absf(fwd_r[i] - rev_r[i]) > 0.001:
				sides_held = false
				break
	print("  CONTROL, left/right waterlines unchanged: %s" % sides_held)
	if not sides_held:
		_fail += 1
		print("  !! reversing flow moved the banks; the perpendicular got flipped too")
	pool.flow_reverse = false

	root.remove_child(pool)
	pool.free()
	_finish()


## Per-row flow direction as the shader decodes it: ARRAY_COLOR.rg remapped from [0,1] to [-1,1].
func _flow_dirs(p_pool: Node) -> Array:
	var out: Array = []
	var mesh: ArrayMesh = p_pool._surface.mesh
	if mesh == null or mesh.get_surface_count() == 0:
		return out
	var cols: PackedColorArray = mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var rows: int = p_pool.get_centreline().size()
	if rows == 0 or cols.is_empty():
		return out
	var cols_per_row: int = cols.size() / rows
	for r in rows:
		var c: Color = cols[r * cols_per_row]
		out.append(Vector2(c.r * 2.0 - 1.0, c.g * 2.0 - 1.0))
	return out


## Put the terrain back and re-seat its data directory.
##
## KNOWN NOISE: this still prints "Resource file not found: res://" twice per cycle. Pulling a
## Pasture3D out of the tree and returning it makes it reload from an empty path, and re-setting
## data_directory afterwards does not prevent the reload that already happened. It does not touch
## any number below -- D and E both come back exact -- and it is an artefact of this fixture
## yanking a terrain in and out, not something a real scene does. Recorded rather than left for
## the next person to re-diagnose.
func _reattach_terrain(p_root: Node, p_terrain: Node, p_pool: Node) -> void:
	if p_terrain.get_parent() == null:
		p_root.add_child(p_terrain)
	p_terrain.data_directory = DEMO_DATA
	p_pool._terrain_cache = null


## Rebuild with the terrain detached and a given fill_offset, and hand back the rows. Restores
## nothing -- callers re-attach when they need the terrain back.
func _rebuild_without_terrain(p_root: Node, p_terrain: Node, p_pool: Node,
		p_fill: float) -> PackedVector3Array:
	if p_terrain.get_parent() != null:
		p_root.remove_child(p_terrain)
	p_pool._terrain_cache = null
	p_pool.fill_offset = p_fill
	p_pool.rebuild()
	return p_pool.get_centreline().duplicate()


func _finish() -> void:
	print("\n=== %s (%d failures) ===\n" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


## Ground height, and a hard failure if the fixture is sampling outside the loaded regions.
## Silently substituting 0.0 here is what let the first run build a curve over the void and then
## report three code failures that were all this function's fault.
func _ground(p_terrain, p_pos: Vector3) -> float:
	var h: float = p_terrain.data.get_height(p_pos)
	if not is_finite(h):
		_fail += 1
		push_error("StreamBankSurfaceCheck: no terrain at %s -- the run is outside demo/data" % p_pos)
		return 0.0
	return h


func _min(a: PackedFloat32Array) -> float:
	var m := INF
	for v in a:
		m = minf(m, v)
	return 0.0 if m == INF else m


func _max(a: PackedFloat32Array) -> float:
	var m := -INF
	for v in a:
		m = maxf(m, v)
	return 0.0 if m == -INF else m
