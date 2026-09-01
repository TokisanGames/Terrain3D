# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphShapeSourceGate — §8.1: a brush's own outline as a closed PATH, and the one host resolver.
#
# ---- WHAT IS AT RISK ----
#
# The closed-path branch has existed since P2a and until now nothing but a gate could reach it. That is
# the dangerous kind of feature: correct, exercised, and never once driven by the thing it was built for.
# So the criteria here are about the JOIN, not about winding — the kernel already has its own gate:
#
#   * the outline that arrives is the one the brush draws, in world space, and closed;
#   * a closed source through Path Mask fills the INTERIOR, where the same outline open gives a corridor
#     — the one comparison that proves the `closed` flag survived the whole trip into the table;
#   * the dropdown lists the scene's brushes and does not offer roads;
#   * one resolver call fills BOTH source kinds, because three host sites used to call two resolvers;
#   * and resolution is idempotent, or a graph with a shape in it re-solves on every bake.
@tool
extends Node

const CRITERIA: Array[String] = ["A", "B", "C", "D", "E"]
const GW := 96
const GH := 96
const RECT := Rect2(-48.0, -48.0, 96.0, 96.0)

var _fail: int = 0
var _reported: Dictionary = {}


func _ready() -> void:
	print("=== GraphShapeSourceGate: a brush outline as graph geometry (§8.1) ===\n")
	_a_the_outline_is_the_brushs_own()
	_b_closed_fills_the_interior_where_open_gives_a_corridor()
	_c_the_dropdown_lists_the_brushes_and_notifies()
	_d_every_host_site_resolves_the_same_set()
	_e_resolving_twice_changes_nothing()
	_account_for_silent_criteria()
	print("\n=== %s (%d failures) ===\n" % ["SHAPE SOURCE PASS" if _fail == 0 else "SHAPE SOURCE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_reported[p_name] = true
	if not p_ok:
		_fail += 1
	print("%s %s: %s" % ["   " if p_ok else "!! ", p_name, p_detail])


func _account_for_silent_criteria() -> void:
	for name in CRITERIA:
		if not _reported.has(name):
			_fail += 1
			print("!!  %s: never reported — it crashed or returned early, so nothing was measured" % name)


# --- the fixture ------------------------------------------------------------------------------------
#
# A real Pasture3D with a real Mound under it, OFFSET from the origin. The offset is the point: a spline
# holds LOCAL point positions, and handing those over unchanged would put the region at the world origin
# and still look like a perfectly plausible square. Criterion A is what catches that.
func _fixture() -> Dictionary:
	var terrain := Pasture3D.new()
	terrain.name = "Terrain"
	add_child(terrain)
	var mound := Pasture3DMound.new()
	mound.name = "Hill"
	terrain.add_child(mound)
	mound.position = Vector3(10.0, 0.0, -6.0)
	var sp := Path3D.new()
	sp.name = "Outline"
	var c := Curve3D.new()
	# A 20 x 14 rectangle in the brush's own space, so the WORLD ring is x in [0,20], z in [-13,1].
	for p in [Vector3(-10, 0, -7), Vector3(10, 0, -7), Vector3(10, 0, 7), Vector3(-10, 0, 7)]:
		c.add_point(p)
	sp.curve = c
	mound.add_child(sp)
	return {"terrain": terrain, "brush": mound}


func _mask_graph(p_src: Pasture3DGraphNode, p_mask: Pasture3DGraphNodePathMask) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [p_src, p_mask, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0], [1, 0, 2, 0]]
	return g


func _flat() -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(GW * GH)
	s.fill(0.0)
	return s


# --- A. The outline that arrives is the brush's own, in WORLD space --------------------------------
func _a_the_outline_is_the_brushs_own() -> void:
	var fx := _fixture()
	var brush: Pasture3DTerrainBrush = fx["brush"]
	var p := brush.graph_shape_path(0)
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for v in p.points:
		mn = mn.min(v)
		mx = mx.max(v)
	print("    the brush offers %d outline(s); outline 0 has %d point(s), closed=%s, bounds %s..%s"
			% [brush.graph_shape_count(), p.points.size(), str(p.closed), str(mn), str(mx)])
	# The brush sits at (10, -6), so the ring must be centred THERE and not at the origin.
	var placed := mn.is_equal_approx(Vector2(0.0, -13.0)) and mx.is_equal_approx(Vector2(20.0, 1.0))
	_check("A", p.points.size() == 4 and p.closed and placed,
			"%d point(s), closed=%s, world-placed=%s" % [p.points.size(), str(p.closed), str(placed)])

	# CONTROL: a spline index past the end resolves to EMPTY, not to the last spline. Clamping would let a
	# graph keep working while pointing at a shape nobody chose, after a spline was deleted.
	var past := brush.graph_shape_path(3)
	print("    control: spline index 3 of %d gave %d point(s) (want 0, not a clamp to the last)"
			% [brush.graph_shape_count(), past.points.size()])
	if past.points.size() != 0:
		_fail += 1
		print("    !! an out-of-range spline index clamped instead of resolving to nothing")
	fx["terrain"].queue_free()


# --- B. Closed fills the interior; the same ring open gives a corridor ------------------------------
#
# This is the criterion the whole node exists for. Both graphs are identical except for one bool on the
# path, so a `closed` dropped anywhere between the brush and the kernel shows here and only here.
func _b_closed_fills_the_interior_where_open_gives_a_corridor() -> void:
	var fx := _fixture()
	var brush: Pasture3DTerrainBrush = fx["brush"]

	var src := Pasture3DGraphNodeShapeSource.new()
	src.path = brush.graph_shape_path(0)
	var mask := Pasture3DGraphNodePathMask.new()
	mask.feather = 0.0
	var closed_field := _mask_graph(src, mask).evaluate(GW, GH, RECT, null, _flat())

	var open_src := Pasture3DGraphNodeShapeSource.new()
	var open_path := brush.graph_shape_path(0)
	open_path.closed = false
	open_src.path = open_path
	var open_mask := Pasture3DGraphNodePathMask.new()
	open_mask.feather = 0.0
	var open_field := _mask_graph(open_src, open_mask).evaluate(GW, GH, RECT, null, _flat())

	var inside := 0
	var corridor := 0
	for i in closed_field.size():
		if closed_field[i] > 0.5:
			inside += 1
		if open_field[i] > 0.5:
			corridor += 1
	# The middle of the rectangle: deep inside the region, and far from every edge of it.
	var cx := int((10.0 - RECT.position.x) / RECT.size.x * float(GW))
	var cz := int((-6.0 - RECT.position.y) / RECT.size.y * float(GH))
	var centre_closed: float = closed_field[cz * GW + cx]
	var centre_open: float = open_field[cz * GW + cx]
	print("    closed: %d cell(s) masked, centre reads %.3f" % [inside, centre_closed])
	print("    open:   %d cell(s) masked, centre reads %.3f" % [corridor, centre_open])
	# 20 x 14 m of a 96 x 96 m rect is 280 / 9216 = 3.0 % of the cells; the boundary gets a wide margin.
	var frac := float(inside) / float(GW * GH)
	_check("B", centre_closed > 0.9 and centre_open < 0.1 and inside > corridor
			and frac > 0.02 and frac < 0.05,
			"interior %.1f%% of the grid (want ~3.0%%), centre closed %.3f vs open %.3f"
					% [frac * 100.0, centre_closed, centre_open])
	fx["terrain"].queue_free()


# --- C. The dropdown lists the scene's brushes, and says so ----------------------------------------
func _c_the_dropdown_lists_the_brushes_and_notifies() -> void:
	var fx := _fixture()
	var brush: Pasture3DTerrainBrush = fx["brush"]
	var src := Pasture3DGraphNodeShapeSource.new()
	var told := [0]
	src.property_list_changed.connect(func() -> void: told[0] += 1)

	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [src]
	g.nodes = nodes
	Pasture3DGraphSources.resolve_shapes(g, brush)

	var hint := -1
	for prop in src.get_property_list():
		if prop["name"] == &"shape_key":
			hint = int(prop["hint"])
			break
	print("    offered %s; hint %d (want %d); the inspector was told %d time(s)"
			% [str(Array(src.editor_shape_keys)), hint, PROPERTY_HINT_ENUM_SUGGESTION, told[0]])
	_check("C", Array(src.editor_shape_keys).has(brush.shape_key())
			and hint == PROPERTY_HINT_ENUM_SUGGESTION and told[0] >= 1,
			"key listed=%s, hint %d, notified %d time(s)"
					% [str(Array(src.editor_shape_keys).has(brush.shape_key())), hint, told[0]])

	# CONTROL: a ROAD brush must not be offered here. Its centreline is open, so Path Mask would give a
	# corridor — which Road Source plus Path Mask already does, correctly, and with the road's real
	# per-vertex widths instead of none. Two ways to do one thing, one of them worse.
	var road := Pasture3DRoadBrush.new()
	road.name = "Street"
	fx["terrain"].add_child(road)
	var rsp := Path3D.new()
	var rc := Curve3D.new()
	rc.add_point(Vector3(-20, 0, 0))
	rc.add_point(Vector3(20, 0, 0))
	rsp.curve = rc
	road.add_child(rsp)
	var src2 := Pasture3DGraphNodeShapeSource.new()
	var g2 := Pasture3DTerrainGraph.new()
	var nodes2: Array[Pasture3DGraphNode] = [src2]
	g2.nodes = nodes2
	Pasture3DGraphSources.resolve_shapes(g2, brush)
	print("    control: with a road brush in the scene the shape list is %s (want the road absent)"
			% str(Array(src2.editor_shape_keys)))
	if Array(src2.editor_shape_keys).has(str(fx["terrain"].get_path_to(road))):
		_fail += 1
		print("    !! a road brush is offered as a shape, so its centreline can be masked as a region")
	fx["terrain"].queue_free()


# --- D. One resolver call fills both source kinds --------------------------------------------------
#
# The three host sites (the brush's graph step, the preview, the inspector hand-off) used to call the road
# resolver directly, so adding a second source kind meant six calls that had to stay in step. The failure
# when they do not is silent — a graph that previews resolved and bakes empty. They now share one entry
# point, and this is what says the entry point covers both.
func _d_every_host_site_resolves_the_same_set() -> void:
	var fx := _fixture()
	var brush: Pasture3DTerrainBrush = fx["brush"]
	var shape := Pasture3DGraphNodeShapeSource.new()
	shape.shape_key = brush.shape_key()
	var road := Pasture3DGraphNodeRoadSource.new()
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [shape, road]
	g.nodes = nodes

	var filled := Pasture3DGraphSources.resolve(g, brush)
	var pts: int = shape.path.points.size() if shape.path != null else -1
	var cl: String = str(shape.path.closed) if shape.path != null else "n/a"
	print("    one resolve() filled %d source(s); the shape holds %d point(s), closed=%s"
			% [filled, pts, cl])
	_check("D", pts == 4 and shape.path != null and shape.path.closed,
			"%d point(s), closed=%s" % [pts, cl])

	# CONTROL: a key naming no brush leaves the path ALONE rather than clearing it. Clearing would make a
	# brush mid-rename flatten every terrain reading it for one bake, which reads as a solver bug.
	var missing := Pasture3DGraphNodeShapeSource.new()
	missing.shape_key = "NoSuchBrush"
	missing.path = brush.graph_shape_path(0)
	var g2 := Pasture3DTerrainGraph.new()
	var nodes2: Array[Pasture3DGraphNode] = [missing]
	g2.nodes = nodes2
	Pasture3DGraphSources.resolve(g2, brush)
	var kept: int = missing.path.points.size() if missing.path != null else -1
	print("    control: an unresolvable key left %d point(s) in place (want them kept)" % kept)
	if kept != 4:
		_fail += 1
		print("    !! an unresolvable key wiped the outline instead of leaving it")

	# CONTROL: with no host at all, nothing resolves and nothing errors. A graph edited on its own is a
	# normal state, not a broken one — §4.3's empty-path rule is what keeps it from being a crash.
	var lone := Pasture3DGraphNodeShapeSource.new()
	lone.shape_key = brush.shape_key()
	var g3 := Pasture3DTerrainGraph.new()
	var nodes3: Array[Pasture3DGraphNode] = [lone]
	g3.nodes = nodes3
	var none := Pasture3DGraphSources.resolve(g3, null)
	print("    control: resolving with no host filled %d source(s) and left the path %s"
			% [none, "null" if lone.path == null else "assigned"])
	if none != 0 or lone.path != null:
		_fail += 1
		print("    !! a hostless resolve invented geometry from somewhere")
	fx["terrain"].queue_free()


# --- E. Resolving twice changes nothing ------------------------------------------------------------
#
# Assigning unconditionally emits `changed`, which bumps the node's revision, which invalidates every
# downstream cache. A graph with a shape in it would then re-solve from scratch on every bake and the
# cache would look broken rather than bypassed — the same trap Road Source has its own control for.
func _e_resolving_twice_changes_nothing() -> void:
	var fx := _fixture()
	var brush: Pasture3DTerrainBrush = fx["brush"]
	var src := Pasture3DGraphNodeShapeSource.new()
	src.shape_key = brush.shape_key()
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [src]
	g.nodes = nodes
	Pasture3DGraphSources.resolve(g, brush)
	var rev_before: int = src._dirty_revision
	Pasture3DGraphSources.resolve(g, brush)
	var rev_after: int = src._dirty_revision
	print("    re-resolving an unchanged brush moved the revision %d -> %d (want no change)"
			% [rev_before, rev_after])
	_check("E", rev_after == rev_before, "revision %d -> %d" % [rev_before, rev_after])

	# CONTROL: MOVING the spline must move the revision, or the criterion above passes on a resolver that
	# never assigns anything at all and every shape in every graph is permanently stale.
	var sp: Path3D = brush._get_splines()[0]
	sp.curve.set_point_position(0, Vector3(-14, 0, -7))
	Pasture3DGraphSources.resolve(g, brush)
	print("    control: after moving a spline point the revision is %d (want > %d)"
			% [src._dirty_revision, rev_after])
	if src._dirty_revision <= rev_after:
		_fail += 1
		print("    !! a moved outline did not dirty the node, so downstream serves a stale mask")
	fx["terrain"].queue_free()
