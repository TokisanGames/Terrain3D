# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadGraphGate — §8: the PATH port type, Road Source, Path Distance (P7a), and Road Grade / Path
# Mask with the two orderings against erosion (P7b).
#
# ---- WHAT IS ACTUALLY AT RISK HERE ----
#
# A distance field is the most convincing wrong answer in the whole system. It is smooth, it is centred on
# the road, it falls off the way one expects, and it looks correct in a preview whichever of these is
# broken: the sign of `t`, the off-by-one ring in the index, a `s` that restarts per segment, cell corners
# instead of cell centres, an empty path reading 0 instead of far away. None of those show up as an
# artifact. They show up as a road graded on the wrong side, or as a terrain flattened everywhere.
#
# So almost every criterion below is checked against something that can DISAGREE: a brute-force oracle for
# the index, a closed-form line distance for the geometry, and a second path for the conventions. The two
# that cannot be checked that way — the wire and the cache — are checked by breaking them on purpose.
@tool
extends Node

const CRITERIA: Array[String] = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O"]

var _fail: int = 0
var _reported: Dictionary = {}


func _ready() -> void:
	print("=== RoadGraphGate: the PATH port, Road Source, Path Distance, Road Grade (§8) ===\n")
	_a_the_index_agrees_with_brute_force()
	_b_distance_is_to_the_polyline_not_to_its_infinite_line()
	_c_s_is_absolute_arc_length()
	_d_t_is_normalised_and_positive_is_the_drivers_right()
	_e_an_unresolved_path_reads_far_away_not_on_the_road()
	_f_the_path_travels_down_the_wire()
	_g_a_moved_path_invalidates_the_cache()
	_h_a_real_road_resolves_into_a_graph()
	_i_every_registered_node_reaches_the_palette()
	_j_the_mask_follows_the_road_not_a_distance()
	_k_the_graph_cuts_the_same_road_the_brush_does()
	_l_the_two_wirings_differ_as_predicted()
	_m_multi_spline_partial_bake_integrity()
	_n_shared_layer_stamp_cache_isolation()
	_o_native_stamp_road_line_parity()
	_account_for_silent_criteria()
	print("\n=== %s (%d failures) ===\n" % ["ROAD GRAPH PASS" if _fail == 0 else "ROAD GRAPH FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_reported[p_name] = true
	if not p_ok:
		_fail += 1
	print("%s %s: %s" % ["   " if p_ok else "!! ", p_name, p_detail])


## The criteria that never reached a _check at all. A gate that crashes halfway and still prints PASS is
## worse than no gate: it reports on the criteria it survived and stays silent about the rest.
func _account_for_silent_criteria() -> void:
	for name in CRITERIA:
		if not _reported.has(name):
			_fail += 1
			print("!!  %s: never reported — it crashed or returned early, so nothing was measured" % name)


# ---- fixtures -----------------------------------------------------------------------------------

## A path that DOUBLES BACK on itself: out along +X, a hairpin, and back 40 m to the north.
##
## Chosen because a straight road cannot catch the two failures that matter. On a straight road every
## wrong nearest-segment is also nearly the right distance, so an off-by-one in the index is invisible;
## and both limbs of a hairpin are close to the same query point, so the index has to actually decide.
func _hairpin() -> Pasture3DGraphPath:
	var pts := PackedVector2Array()
	for i in 21:
		pts.append(Vector2(float(i) * 10.0, 0.0))
	for i in range(1, 8):
		var a: float = float(i) * PI / 7.0
		pts.append(Vector2(200.0 + sin(a) * 20.0, 20.0 - cos(a) * 20.0))
	for i in range(1, 21):
		pts.append(Vector2(200.0 - float(i) * 10.0, 40.0))
	var p := Pasture3DGraphPath.new()
	p.points = pts
	p.source_label = "hairpin"
	return p


## A straight 100 m road along +X at z = 0, with a half-width that WIDENS from 4 m to 8 m.
func _straight(p_half_a: float = 4.0, p_half_b: float = 8.0) -> Pasture3DGraphPath:
	var p := Pasture3DGraphPath.new()
	p.points = PackedVector2Array([Vector2(0.0, 0.0), Vector2(50.0, 0.0), Vector2(100.0, 0.0)])
	p.half_widths = PackedFloat32Array([p_half_a, (p_half_a + p_half_b) * 0.5, p_half_b])
	return p


# ---- A ------------------------------------------------------------------------------------------

## [A] The indexed query agrees with brute force, everywhere.
##
## The index exists so a 48-segment road does not cost 48 point-to-segment tests per cell, and its whole
## correctness rests on one stopping rule: a segment in a bucket `k` rings out is at least `(k-1)*cell`
## away, so the search may stop once the best answer beats that. An off-by-one there returns a WRONG
## NEAREST SEGMENT, and that is silent — the distance stays plausible and only `s` is absurd, which is
## why this compares `segment` and `s` and not only `distance`.
func _a_the_index_agrees_with_brute_force() -> void:
	print("[A] the indexed query agrees with brute force")
	var path := _hairpin()
	var worst_d := 0.0
	var worst_s := 0.0
	var real := 0
	var ties := 0
	var tested := 0
	for iz in range(-4, 30):
		for ix in range(-4, 46):
			var at := Vector2(float(ix) * 5.0, float(iz) * 2.0)
			var fast := path.nearest(at)
			var slow := path.nearest_brute(at)
			tested += 1
			var dd := absf(float(fast["distance"]) - float(slow["distance"]))
			var ds := absf(float(fast["s"]) - float(slow["s"]))
			worst_d = maxf(worst_d, dd)
			worst_s = maxf(worst_s, ds)
			if int(fast["segment"]) != int(slow["segment"]):
				# A TIE, not a disagreement: a query level with a vertex is exactly equidistant from the
				# two segments meeting there, and both answers name the same POINT. Counting those as
				# failures would make the criterion demand that two searches visiting the segments in
				# different orders break ties the same way, which is a claim about iteration order rather
				# than about the answer. A tie is only a tie when the distance AND the arc length agree;
				# anything else is a genuinely wrong nearest segment.
				if dd <= 1e-6 and ds <= 1e-6:
					ties += 1
				else:
					real += 1
	print("    %d probes over a %d-segment hairpin: worst distance %.9f m, worst s %.9f m"
			% [tested, path.segment_count(), worst_d, worst_s])
	print("    %d wrong segment(s), %d tie(s) at a vertex where both answers name the same point"
			% [real, ties])
	_check("A", worst_d < 1e-5 and worst_s < 1e-4 and real == 0,
			"worst distance %.9f m / worst s %.9f m / %d wrong segment(s) (want 0)"
					% [worst_d, worst_s, real])

	# CONTROL: the index must actually be BUILT and must actually be NARROWING the search, or this
	# criterion is comparing brute force with brute force and passes on any stopping rule at all.
	var all := path.segment_count()
	var narrowed := 0
	var probes := 0
	for ix in range(0, 40):
		var cands: int = path._candidates(Vector2(float(ix) * 5.0, 10.0)).size()
		probes += 1
		if cands < all:
			narrowed += 1
	print("    control: the index narrowed %d of %d probes below all %d segments (want most of them)"
			% [narrowed, probes, all])
	if narrowed < probes / 2:
		_fail += 1
		print("    !! the index is not narrowing the search, so A is brute force against brute force")

	# CONTROL: a path SHORT enough to skip the index must still answer, and must still answer correctly.
	# The fallback is the path a two-segment road takes in production and it is the one nobody looks at.
	var tiny := Pasture3DGraphPath.new()
	tiny.points = PackedVector2Array([Vector2(0.0, 0.0), Vector2(10.0, 0.0)])
	var tq := tiny.nearest(Vector2(5.0, 3.0))
	print("    control: an unindexed 1-segment path answers %.3f m at s %.3f (want 3.000 at 5.000)"
			% [float(tq["distance"]), float(tq["s"])])
	if absf(float(tq["distance"]) - 3.0) > 1e-5 or absf(float(tq["s"]) - 5.0) > 1e-5:
		_fail += 1
		print("    !! the unindexed fallback disagrees with the indexed path")


# ---- B ------------------------------------------------------------------------------------------

## [B] Distance is to the POLYLINE, clamped at its ends — not to the infinite line through it.
##
## The difference only shows up past an end, and past an end is exactly where a road grader decides how
## far its influence reaches. Measuring to the infinite line makes a road's cut continue straight off the
## end of the road, forever, through whatever is out there.
func _b_distance_is_to_the_polyline_not_to_its_infinite_line() -> void:
	print("[B] distance is to the polyline, not to its infinite line")
	var path := _straight()
	var beside := path.nearest(Vector2(50.0, 12.0))
	# 30 m beyond the far end and 40 m to the side: the radial distance to the endpoint is 50 m, while
	# the perpendicular to the infinite line would be 40 m.
	var past := path.nearest(Vector2(130.0, 40.0))
	print("    beside the road: %.4f m (want 12); 30 m past the end and 40 m out: %.4f m (want 50, not 40)"
			% [float(beside["distance"]), float(past["distance"])])
	_check("B", absf(float(beside["distance"]) - 12.0) < 1e-4
					and absf(float(past["distance"]) - 50.0) < 1e-4,
			"%.4f m beside, %.4f m past the end" % [float(beside["distance"]), float(past["distance"])])

	# CONTROL: the two answers must actually DIFFER by the amount claimed, or the probe is not past the
	# end at all and the criterion would pass on a query that never clamps.
	print("    control: the infinite line would answer 40.0000 m there, a %.4f m difference (want 10)"
			% [float(past["distance"]) - 40.0])
	if absf(float(past["distance"]) - 40.0 - 10.0) > 1e-4:
		_fail += 1
		print("    !! the probe does not distinguish the polyline from its infinite line")

	# CONTROL: s past the end must clamp to the road's own length rather than run on.
	print("    control: s past the end reads %.4f m against a %.4f m road (want equal)"
			% [float(past["s"]), path.length()])
	if absf(float(past["s"]) - path.length()) > 1e-4:
		_fail += 1
		print("    !! s runs past the end of the road")


# ---- C ------------------------------------------------------------------------------------------

## [C] `s` is ABSOLUTE arc length in metres, continuous across the vertices.
##
## Two ways to get this wrong and both look fine in a preview. Restarting `s` at each segment gives a
## sawtooth that reads as a repeating pattern rather than as a bug; normalising it to [0,1] makes the same
## physical place a different number as soon as the road gets longer, which silently moves everything a
## graph placed by arc length — every bridge, every prop run, every surface change.
func _c_s_is_absolute_arc_length() -> void:
	print("[C] s is absolute arc length")
	var path := _straight()
	var at_30 := path.nearest(Vector2(30.0, 5.0))
	# 70 m along is on the SECOND segment: a per-segment s would read 20 there.
	var at_70 := path.nearest(Vector2(70.0, 5.0))
	print("    30 m along reads s = %.4f; 70 m along (second segment) reads s = %.4f (want 30 and 70)"
			% [float(at_30["s"]), float(at_70["s"])])
	_check("C", absf(float(at_30["s"]) - 30.0) < 1e-4 and absf(float(at_70["s"]) - 70.0) < 1e-4,
			"s = %.4f and %.4f" % [float(at_30["s"]), float(at_70["s"])])

	# CONTROL: the second probe must be on a LATER segment than the first, or a per-segment s would pass.
	print("    control: the two probes are on segments %d and %d (want different)"
			% [int(at_30["segment"]), int(at_70["segment"])])
	if int(at_30["segment"]) == int(at_70["segment"]):
		_fail += 1
		print("    !! both probes are on one segment, so a per-segment s would read the same")

	# CONTROL: EXTENDING the road must not move s at a place that did not move. This is the claim that s
	# is not normalised, and it is the one a preview cannot show.
	var longer := Pasture3DGraphPath.new()
	longer.points = PackedVector2Array([Vector2(0.0, 0.0), Vector2(50.0, 0.0), Vector2(100.0, 0.0),
			Vector2(400.0, 0.0)])
	var again := longer.nearest(Vector2(30.0, 5.0))
	print("    control: the road is now %.0f m instead of %.0f m; s at the same place reads %.4f (want 30)"
			% [longer.length(), path.length(), float(again["s"])])
	if absf(float(again["s"]) - 30.0) > 1e-4:
		_fail += 1
		print("    !! s moved when the road got longer, so it is normalised rather than absolute")


# ---- D ------------------------------------------------------------------------------------------

## [D] `t` is normalised by the half-width there, and POSITIVE IS THE DRIVER'S RIGHT.
##
## Two separate claims, both invisible.
##
## Normalisation is what makes `t` worth carrying: unnormalised it is a signed copy of `distance`, and a
## graph masking with `|t| <= 1` would mask a constant-width corridor down a road that changes width.
##
## The sign convention has to match the rest of the road system, and a fixture that shares the code's own
## convention cannot catch it being inverted — which is why the check here is a road running the OTHER
## WAY past the same world point. Reversing the road must flip the side of a point that did not move.
func _d_t_is_normalised_and_positive_is_the_drivers_right() -> void:
	print("[D] t is normalised, and positive is the driver's right")
	var path := _straight(4.0, 8.0)
	# The same 4 m offset at the narrow end and at the wide end.
	var narrow := path.nearest(Vector2(0.0, 4.0))
	var wide := path.nearest(Vector2(100.0, 4.0))
	# Driving along +X on Godot's XZ plane, the driver's right is +Z.
	var right := path.nearest(Vector2(50.0, 6.0))
	var left := path.nearest(Vector2(50.0, -6.0))
	print("    4 m out at half-width %.0f -> t = %.4f; at half-width %.0f -> t = %.4f (want 1.00 and 0.50)"
			% [path.half_width_at(0.0), float(narrow["t"]), path.half_width_at(100.0), float(wide["t"])])
	print("    +Z of a road heading +X -> t = %.4f; -Z -> t = %.4f (want positive then negative)"
			% [float(right["t"]), float(left["t"])])
	_check("D", absf(float(narrow["t"]) - 1.0) < 1e-4 and absf(float(wide["t"]) - 0.5) < 1e-4
					and float(right["t"]) > 0.0 and float(left["t"]) < 0.0,
			"t = %.4f / %.4f across the widening, %.4f right and %.4f left"
					% [float(narrow["t"]), float(wide["t"]), float(right["t"]), float(left["t"])])

	# CONTROL: unnormalised, both offsets would read the same. If they already do, the fixture does not
	# widen and the normalisation half of this criterion proves nothing.
	print("    control: the two offsets are the same %.1f m in metres, and differ by %.4f in t (want > 0)"
			% [4.0, absf(float(narrow["t"]) - float(wide["t"]))])
	if absf(float(narrow["t"]) - float(wide["t"])) < 0.1:
		_fail += 1
		print("    !! the fixture does not widen, so a signed distance would pass as a normalised t")

	# CONTROL: THE SAME WORLD POINT ON A REVERSED ROAD MUST BE ON THE OTHER SIDE. This is the only check
	# here that a fixture sharing the code's convention cannot quietly agree with.
	var back := Pasture3DGraphPath.new()
	back.points = PackedVector2Array([Vector2(100.0, 0.0), Vector2(50.0, 0.0), Vector2(0.0, 0.0)])
	var reversed_t: float = float(back.nearest(Vector2(50.0, 6.0))["t"])
	print("    control: the same point on the road driven the other way -> t = %.4f (want the other sign)"
			% reversed_t)
	if signf(reversed_t) == signf(float(right["t"])) or absf(reversed_t) < 1e-6:
		_fail += 1
		print("    !! reversing the road did not change which side the point is on")


# ---- E ------------------------------------------------------------------------------------------

## [E] An unresolved path reads FAR AWAY, not "on the road" and not INF.
##
## A Road Source with no host resolves to nothing, and that is a normal state: a graph opened on its own,
## a road not yet baked, a brush just deleted. What the node fills the field with then decides what a
## graph does about it, and the two obvious answers are both catastrophic. 0 means every cell is on the
## road, so a Road Grade downstream flattens the entire terrain to the road. INF turns every downstream
## arithmetic node into NAN, which propagates to the output and is unrecoverable.
func _e_an_unresolved_path_reads_far_away_not_on_the_road() -> void:
	print("[E] an unresolved path reads far away, not on the road")
	var node := Pasture3DGraphNodeDevPathDistance.new()
	node.set_path_inputs([null])
	var chans := node.eval_grid_channels([], 8, 8, null, Rect2(0.0, 0.0, 64.0, 64.0))
	var dist: PackedFloat32Array = chans[0]
	var finite := true
	var on_road := 0
	for v in dist:
		if not is_finite(v):
			finite = false
		if v < 1.0:
			on_road += 1
	print("    %d cells: all finite %s, %d reading as on the road, fill = %.1f m"
			% [dist.size(), str(finite), on_road, dist[0]])
	_check("E", finite and on_road == 0 and dist.size() == 64
					and absf(dist[0] - node.unreachable_distance) < 1e-4,
			"finite %s, %d on-road cell(s), fill %.1f m" % [str(finite), on_road, dist[0]])

	# CONTROL: a RESOLVED path through the same node must produce a field that varies, or this criterion
	# passes on a node that fills the unreachable value whatever it is given.
	node.set_path_inputs([_straight()])
	var live: PackedFloat32Array = node.eval_grid_channels([], 8, 8, null, Rect2(0.0, -32.0, 100.0, 64.0))[0]
	var lo := INF
	var hi := -INF
	for v in live:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	print("    control: a resolved path gives %.2f .. %.2f m across the same grid (want a real range)"
			% [lo, hi])
	if hi - lo < 1.0 or hi >= node.unreachable_distance:
		_fail += 1
		print("    !! the node fills a constant whether or not it has a path")

	# CONTROL: the three channels must not be the same array. `s` and `t` mean nothing if the node
	# returned its distance grid three times, and every value would still look plausible.
	var s_grid: PackedFloat32Array = node.eval_grid_channels([], 8, 8, null,
			Rect2(0.0, -32.0, 100.0, 64.0))[1]
	var differs := 0
	for i in live.size():
		if absf(live[i] - s_grid[i]) > 1e-6:
			differs += 1
	print("    control: distance and s differ in %d of %d cells (want most)" % [differs, live.size()])
	if differs < live.size() / 2:
		_fail += 1
		print("    !! the channels are duplicates of one another")


# ---- F ------------------------------------------------------------------------------------------

## [F] The PATH actually travels down the wire.
##
## This is the one claim the kernels cannot make for themselves. Everything else in the graph moves as a
## grid; a PATH moves as a resource carried beside the grids, and a consumer that quietly reached for a
## path some other way — a preloaded default, a leftover from a previous call — would pass every other
## criterion in this file. So the check is the wire itself: the same node, the same graph, evaluated with
## the connection and then without it.
func _f_the_path_travels_down_the_wire() -> void:
	print("[F] the path travels down the wire")
	var graph := Pasture3DTerrainGraph.new()
	var src := Pasture3DGraphNodeRoadSource.new()
	src.path = _straight()
	var dist := Pasture3DGraphNodeDevPathDistance.new()
	var out := Pasture3DGraphNodeOutput.new()
	var i_src := graph.add_node(src)
	var i_dist := graph.add_node(dist)
	var i_out := graph.add_node(out)
	graph.connect_ports(i_src, 0, i_dist, 0)
	graph.connect_ports(i_dist, 0, i_out, 0)
	graph.set_output(i_out)
	var rect := Rect2(0.0, -32.0, 100.0, 64.0)
	var wired := graph.evaluate(16, 16, rect)
	# The cell nearest the centreline should read close to 0; the corners should read tens of metres.
	var lo := INF
	var hi := -INF
	for v in wired:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	print("    wired: %d cells, %.2f .. %.2f m" % [wired.size(), lo, hi])
	_check("F", wired.size() == 256 and lo < 3.0 and hi > 20.0 and hi < dist.unreachable_distance,
			"%d cells reading %.2f .. %.2f m" % [wired.size(), lo, hi])

	# CONTROL: cut the wire and the SAME node must fall back to the unreachable fill. If it does not, it
	# is getting the path from somewhere other than the connection and the wire is decorative.
	graph.disconnect_ports(i_src, 0, i_dist, 0)
	dist.clear_cache()
	out.clear_cache()
	var cut := graph.evaluate(16, 16, rect)
	print("    control: with the wire cut, the field reads %.1f m (want the %.1f m unreachable fill)"
			% [cut[0], dist.unreachable_distance])
	if absf(cut[0] - dist.unreachable_distance) > 1e-3:
		_fail += 1
		print("    !! the node still has a path with nothing wired into it")


# ---- G ------------------------------------------------------------------------------------------

## [G] Moving the path invalidates the field.
##
## Path Distance is a cached grid node like any other, and its cache key is built from its INPUT GRIDS. A
## PATH produces no input grid — the source's grid slot is zeros before and after — so nothing about the
## geometry reaches the hash by the normal route. What saves it is that the hash also folds the SOURCE
## NODE's revision, and Road Source re-emits `changed` when its path resource does.
##
## That is a two-link chain of things that are easy to leave out, and if either link is missing the graph
## serves the old field forever: the road moves in the viewport and the terrain keeps the old cut.
func _g_a_moved_path_invalidates_the_cache() -> void:
	print("[G] moving the path invalidates the field")
	var graph := Pasture3DTerrainGraph.new()
	var src := Pasture3DGraphNodeRoadSource.new()
	var path := _straight()
	src.path = path
	var dist := Pasture3DGraphNodeDevPathDistance.new()
	var out := Pasture3DGraphNodeOutput.new()
	var i_src := graph.add_node(src)
	var i_dist := graph.add_node(dist)
	var i_out := graph.add_node(out)
	graph.connect_ports(i_src, 0, i_dist, 0)
	graph.connect_ports(i_dist, 0, i_out, 0)
	graph.set_output(i_out)
	var rect := Rect2(0.0, -32.0, 100.0, 64.0)
	var before := graph.evaluate(16, 16, rect).duplicate()

	# CONTROL FIRST: evaluating again with NOTHING changed must give the identical field. Without this,
	# "the field changed" proves nothing — it could change on every call.
	var again := graph.evaluate(16, 16, rect)
	var drift := 0
	for i in before.size():
		if absf(before[i] - again[i]) > 1e-6:
			drift += 1
	print("    control: re-evaluating unchanged moved %d of %d cells (want 0)" % [drift, before.size()])
	if drift != 0:
		_fail += 1
		print("    !! the field is not stable, so a change in it means nothing")

	# Move the road 20 m north. Its length, its widths and its vertex count are unchanged, so nothing but
	# the geometry could have invalidated anything.
	var moved := PackedVector2Array()
	for p in path.points:
		moved.append(p + Vector2(0.0, 20.0))
	path.points = moved
	var after := graph.evaluate(16, 16, rect)
	var changed := 0
	var worst := 0.0
	for i in before.size():
		var d := absf(before[i] - after[i])
		worst = maxf(worst, d)
		if d > 1e-4:
			changed += 1
	print("    the road moved 20 m north: %d of %d cells changed, by up to %.2f m"
			% [changed, before.size(), worst])
	_check("G", changed > before.size() / 4 and worst > 5.0,
			"%d of %d cells moved, worst %.2f m" % [changed, before.size(), worst])


# ---- H ------------------------------------------------------------------------------------------

## [H] A REAL ROAD resolves into a graph, by key and by default.
##
## [A]-[G] are all about a path that was handed to the node directly. That is the whole feature except for
## the part a user touches: dropping a Road Source into a graph and getting THEIR road. Between the two
## sits a lookup that nothing else exercises — a graph is a Resource, it cannot reach the scene, so the
## host has to walk its nodes and fill them in. Until that existed, every criterion above passed and a
## Road Source in the editor produced nothing at all.
##
## Both routes are checked, because they fail differently. A NAMED key is the reusable case and goes
## through the network's brush table; an EMPTY key means "the road this graph is on" and goes through the
## host brush, which is the common case and the one nobody would think to type a name for.
func _h_a_real_road_resolves_into_a_graph() -> void:
	print("[H] a real road resolves into a graph")
	var net := Pasture3DRoadNetwork.new()
	add_child(net)
	var t := Pasture3DRoadType.new()
	t.type_name = "major"
	t.lane_count = 2
	t.lane_width = 3.5
	t.shoulder_width = 0.5
	net.road_types = [t]
	var brush := Pasture3DRoadBrush.new()
	brush.name = "Lane"
	net.add_child(brush)
	var path3d := Path3D.new()
	var curve := Curve3D.new()
	curve.add_point(Vector3(-50.0, 0.0, 0.0))
	curve.add_point(Vector3(50.0, 0.0, 0.0))
	path3d.curve = curve
	brush.add_child(path3d)
	brush.road_road_type = t
	var road_mod := Pasture3DNodeRoad.new()
	road_mod.alignment_step = 1.0
	brush.modifiers = [road_mod]
	# Solve the alignment: without one, graph_path is legitimately empty and H would be testing nothing.
	var ground := PackedFloat32Array()
	ground.resize(121 * 121)
	var mod: Pasture3DNodeRoad = brush.road_modifier()
	brush.grade_surface(mod, ground, 121, 121, -60.0, -60.0, 1.0)

	var built := brush.graph_path()
	print("    the road built a path of %d point(s), %.1f m long, half-width %.2f m at the middle"
			% [built.points.size(), built.length(), built.half_width_at(built.length() * 0.5)])

	var graph := Pasture3DTerrainGraph.new()
	var named := Pasture3DGraphNodeRoadSource.new()
	named.road_key = brush.road_key()
	var defaulted := Pasture3DGraphNodeRoadSource.new()
	graph.add_node(named)
	graph.add_node(defaulted)
	var filled := net.resolve_graph_paths(graph, brush)
	var by_key: int = named.path.segment_count() if named.path != null else -1
	var by_default: int = defaulted.path.segment_count() if defaulted.path != null else -1
	print("    resolved %d source(s): by key %d segment(s), by default (empty key) %d segment(s)"
			% [filled, by_key, by_default])
	_check("H", filled == 2 and by_key > 0 and by_key == by_default and built.length() > 90.0,
			"%d resolved, %d / %d segment(s), path %.1f m" % [filled, by_key, by_default, built.length()])

	# THE DROPDOWN. `road_key` is a node path relative to the network, derived and never stored, so there
	# was no way to find out what to type. Resolving is the one moment the graph and the scene are both in
	# hand, so the candidate list is handed over there — alongside the path, for the same reason.
	#
	# Checked on the EMPTY-key node too: a list gathered only for nodes that already name a road would
	# arrive exactly when it is no longer needed, and this criterion would not notice.
	var offered := Array(defaulted.editor_road_keys)
	print("    the inspector was offered %d road key(s): %s" % [offered.size(), str(offered)])
	if not offered.has(brush.road_key()) or not Array(named.editor_road_keys).has(brush.road_key()):
		_fail += 1
		print("    !! the dropdown does not list the road that is actually there")

	# ...AND THE ALREADY-BUILT INSPECTOR HAS TO BE TOLD. This is the half that was missing, and it is the
	# half you can see: the keys were collected, `_validate_property` wrote the hint correctly, and the
	# field was still a plain String box. `_validate_property` runs while Godot BUILDS a property list,
	# so a list stamped after that build is invisible until something else rebuilds the inspector.
	#
	# Note what cannot be asserted here: reading the hint back off `get_property_list` passes either way,
	# because that call re-runs `_validate_property`. The observable difference is the NOTIFICATION, so
	# that is what is watched.
	var told := [0]
	var fresh := Pasture3DGraphNodeRoadSource.new()
	fresh.property_list_changed.connect(func() -> void: told[0] += 1)
	fresh.editor_road_keys = PackedStringArray([brush.road_key()])
	var hint := -1
	var hint_str := ""
	for prop in fresh.get_property_list():
		if prop["name"] == &"road_key":
			hint = int(prop["hint"])
			hint_str = str(prop["hint_string"])
			break
	print("    stamping the keys rebuilt the inspector %d time(s), and road_key builds with hint %d "
			% [told[0], hint] + "(want %d) and choices \"%s\"" % [PROPERTY_HINT_ENUM_SUGGESTION, hint_str])
	if hint != PROPERTY_HINT_ENUM_SUGGESTION or not hint_str.split(",").has(brush.road_key()):
		_fail += 1
		print("    !! road_key does not build as a choice list at all")
	if told[0] < 1:
		_fail += 1
		print("    !! the keys arrived without telling the inspector, so the field stays a String box")

	# CONTROL: stamping the SAME list again must NOT rebuild. An unconditional notify would rebuild the
	# inspector on every preview render """ + EM + u""" which resolves """ + EM + u""" and eat the text you were part-way through
	# typing into the very field this exists to fill.
	told[0] = 0
	fresh.editor_road_keys = PackedStringArray([brush.road_key()])
	print("    control: re-stamping an unchanged list rebuilt it %d time(s) (want 0)" % told[0])
	if told[0] != 0:
		_fail += 1
		print("    !! the inspector rebuilds on every resolve, so the field cannot be typed in")

	# CONTROL: an unresolved node must offer NOTHING. This is why the hint is ENUM_SUGGESTION and not a
	# hard ENUM: a graph opened without its network shows an empty list, and a hard enum would render the
	# key it already holds as invalid and rewrite it to another road on the first click.
	var lone := Pasture3DGraphNodeRoadSource.new()
	print("    control: a source that was never resolved offers %d key(s) (want 0, hence a suggestion)"
			% lone.editor_road_keys.size())
	if not lone.editor_road_keys.is_empty():
		_fail += 1
		print("    !! an unresolved source claims to know the network\'s roads")
	var lone_hint := -1
	for prop in lone.get_property_list():
		if prop["name"] == &"road_key":
			lone_hint = int(prop["hint"])
			break
	print("    control: an unresolved source builds road_key with hint %d (want NOT %d, i.e. typeable)"
			% [lone_hint, PROPERTY_HINT_ENUM_SUGGESTION])
	if lone_hint == PROPERTY_HINT_ENUM_SUGGESTION:
		_fail += 1
		print("    !! an empty list still claims to be a choice list")

	# CONTROL: a key naming NO road must leave the node alone rather than clearing it. Clearing would make
	# a road mid-rename flatten every terrain reading it for one bake, which reads as a solver bug.
	var missing := Pasture3DGraphNodeRoadSource.new()
	missing.road_key = "NoSuchRoad"
	missing.path = built
	graph.add_node(missing)
	net.resolve_graph_paths(graph, brush)
	print("    control: an unresolvable key left %d segment(s) in place (want them kept)"
			% (missing.path.segment_count() if missing.path != null else -1))
	if missing.path == null or missing.path.segment_count() == 0:
		_fail += 1
		print("    !! an unresolvable key wiped the path instead of leaving it")

	# CONTROL: re-resolving an UNCHANGED road must not touch the node. Assigning unconditionally emits
	# `changed`, which bumps the revision, which invalidates every downstream cache — so a graph with a
	# road in it would re-solve from scratch on every bake and the cache would look broken, not bypassed.
	var rev_before: int = named._dirty_revision
	net.resolve_graph_paths(graph, brush)
	print("    control: re-resolving an unchanged road moved the revision %d -> %d (want no change)"
			% [rev_before, named._dirty_revision])
	if named._dirty_revision != rev_before:
		_fail += 1
		print("    !! resolving dirties the node every time, so nothing downstream can ever cache")
	net.queue_free()


# ---- I ------------------------------------------------------------------------------------------

## [I] The three GDScript ORACLES are reachable behind the developer flag and invisible without it, and
## the four production road nodes are the other way round.
##
## ---- TWO OPPOSITE FAILURES, AND THIS CRITERION HAS TO CATCH BOTH ----
##
## The first version of [I] checked only that these nodes reach the palette, because they had shipped
## registered, instantiable, and absent from the Add menu — which is indistinguishable from not
## existing. That failure is still real and still checked, but only with the developer flag ON.
##
## The house rule (PASTURE3D_GDSCRIPT_CPP_NODE_SEPARATION_SPEC.md §3.0, playbook Step 0) is that a node
## whose mathematics runs in GDScript is a [Dev/GD] node and is HIDDEN by default. All four road nodes are
## GDScript, so the second failure is the mirror of the first: one of them turning up in a normal user\'s
## palette, where it would look like a production node and would silently drop their whole graph to the
## CPU evaluator. A criterion that only checked reachability would pass on that with nothing to say.
func _i_every_registered_node_reaches_the_palette() -> void:
	print("[I] the road nodes are reachable behind the dev flag and hidden without it")
	var ops: Array[StringName] = [&"dev_path_distance", &"dev_path_mask", &"dev_road_grade"]
	var prod_ops: Array[StringName] = [&"road_source", &"path_distance", &"path_mask", &"road_grade"]

	var by_cat := Pasture3DGraphNodeRegistry.entries_by_category(true)
	var listed := Pasture3DGraphNodeRegistry.categories(true)
	var reachable := {}
	for cat in listed:
		for e in by_cat.get(cat, []):
			reachable[e["op"]] = true
	var missing := PackedStringArray()
	for o in ops:
		if not reachable.has(o):
			missing.append(String(o))
	print("    with the flag on, the palette lists %d categor(ies) reaching %d node type(s); %d road node(s) missing"
			% [listed.size(), reachable.size(), missing.size()])

	# The other direction, through the SAME path a user\'s editor takes: the default palette.
	var open_cat := Pasture3DGraphNodeRegistry.entries_by_category(false)
	var exposed := PackedStringArray()
	for cat in Pasture3DGraphNodeRegistry.categories(false):
		for e in open_cat.get(cat, []):
			if ops.has(e["op"]):
				exposed.append(String(e["op"]))
	print("    with the flag off, %d oracle(s) are visible: %s" % [exposed.size(), str(exposed)])

	# And the production four must be there for a user who never turns the flag on. Hiding the oracles is
	# only correct while the shipped nodes are visible; both halves hidden is the feature not shipping.
	var open_reach := {}
	for cat in Pasture3DGraphNodeRegistry.categories(false):
		for e in open_cat.get(cat, []):
			open_reach[e["op"]] = true
	var prod_missing := PackedStringArray()
	for o in prod_ops:
		if not open_reach.has(o):
			prod_missing.append(String(o))
	print("    with the flag off, %d of %d production road node(s) are missing: %s"
			% [prod_missing.size(), prod_ops.size(), str(prod_missing)])

	_check("I", missing.is_empty() and exposed.is_empty() and prod_missing.is_empty(),
			"%d oracle(s) missing behind the flag, %d exposed without it, %d production node(s) missing"
			% [missing.size(), exposed.size(), prod_missing.size()])

	# CONTROL: `create` must still make them by op REGARDLESS of the flag. Hiding a node from the menu must
	# not stop a saved graph containing one from loading — that would turn a settings toggle into data
	# loss, and it is why the factory searches entries(true).
	var a := Pasture3DGraphNodeRegistry.create(&"dev_path_distance")
	var b := Pasture3DGraphNodeRegistry.create(&"dev_road_grade")
	print("    control: the factory made %s and %s with the flag off (want true, true)"
			% [str(a != null and a is Pasture3DGraphNodeDevPathDistance),
				str(b != null and b is Pasture3DGraphNodeDevRoadGrade)])
	if a == null or not (a is Pasture3DGraphNodeDevPathDistance) or b == null \
			or not (b is Pasture3DGraphNodeDevRoadGrade):
		_fail += 1
		print("    !! a saved graph holding a road node could not be reconstructed")

	# CONTROL: the flag must actually be OFF in this run, or "hidden" was never tested. is_dev_nodes_enabled
	# reads a project setting and returns false outside the editor, which is exactly the headless case —
	# so this states the assumption rather than relying on it.
	print("    control: is_dev_nodes_enabled() is %s in this run (want false, or nothing was hidden)"
			% str(Pasture3DGraphNodeRegistry.is_dev_nodes_enabled()))
	if Pasture3DGraphNodeRegistry.is_dev_nodes_enabled():
		_fail += 1
		print("    !! dev nodes are enabled here, so the flag-off half of [I] proved nothing")


# ---- P7b fixtures -------------------------------------------------------------------------------

const G_N: int = 121
const G_MIN: float = -60.0
const G_VS: float = 1.0


## A ridge running north-south across the middle, so an east-west road has to cut through something.
## Erosion on a flat plane does nothing, and a criterion about ordering against erosion on a fixture
## erosion cannot change would pass whatever the wiring did.
func _ridge() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(G_N * G_N)
	for iz in G_N:
		for ix in G_N:
			var wx := G_MIN + float(ix) * G_VS
			var wz := G_MIN + float(iz) * G_VS
			out[iz * G_N + ix] = 24.0 * exp(-(wx * wx) / 600.0) + 0.6 * sin(wz * 0.35)
	return out


## A baked road across that ridge, returned as the network, the brush and its graph path.
func _road_over_the_ridge() -> Dictionary:
	var net := Pasture3DRoadNetwork.new()
	add_child(net)
	var t := Pasture3DRoadType.new()
	t.type_name = "major"
	t.lane_count = 2
	t.lane_width = 3.5
	t.shoulder_width = 0.5
	net.road_types = [t]
	var brush := Pasture3DRoadBrush.new()
	brush.name = "Over"
	net.add_child(brush)
	var path3d := Path3D.new()
	var curve := Curve3D.new()
	curve.add_point(Vector3(-50.0, 0.0, 0.0))
	curve.add_point(Vector3(50.0, 0.0, 0.0))
	path3d.curve = curve
	brush.add_child(path3d)
	brush.road_road_type = t
	var road_mod := Pasture3DNodeRoad.new()
	road_mod.alignment_step = 1.0
	brush.modifiers = [road_mod]
	var ground := _ridge()
	var graded: Dictionary = brush.grade_surface(road_mod, ground, G_N, G_N, G_MIN, G_MIN, G_VS)
	return {"net": net, "brush": brush, "mod": road_mod, "ground": ground, "graded": graded,
			"path": brush.graph_path()}


## The graph rect matching the fixture grid. Road Grade and Path Mask sample cell CENTRES, so the rect
## starts half a cell BEFORE the first sample point: get this wrong and every criterion below is off by
## half a metre in a way that still looks like a road.
func _rect() -> Rect2:
	return Rect2(G_MIN - 0.5 * G_VS, G_MIN - 0.5 * G_VS, float(G_N) * G_VS, float(G_N) * G_VS)


func _idx(p_wx: float, p_wz: float) -> int:
	var ix := clampi(int(round((p_wx - G_MIN) / G_VS)), 0, G_N - 1)
	var iz := clampi(int(round((p_wz - G_MIN) / G_VS)), 0, G_N - 1)
	return iz * G_N + ix


# ---- J ------------------------------------------------------------------------------------------

## [J] Path Mask follows the ROAD, not a distance.
##
## The reason this node is not just a threshold on Path Distance. A road that widens from 4 m to 8 m has
## one edge, and a mask built by comparing `distance` against a constant has two different answers about
## where it is. Thresholding `t` — the across-position already divided by the half-width there — has one.
##
## Checked on `_straight(4, 8)`, whose half-width doubles along its length, so a distance threshold and a
## `t` threshold DISAGREE on the fixture rather than happening to agree on it.
func _j_the_mask_follows_the_road_not_a_distance() -> void:
	print("[J] Path Mask follows the road, not a distance")
	var path := _straight(4.0, 8.0)
	var node := Pasture3DGraphNodeDevPathMask.new()
	node.feather = 0.0
	node.set_path_inputs([path])
	var rect := Rect2(-10.0, -20.0, 130.0, 40.0)
	var gw := 130
	var gh := 40
	var m := node.eval_grid([], gw, gh, null, rect)

	# Walk out from the centreline at the narrow end and at the wide end, and find where each stops
	# being masked. Those two numbers must differ by the same factor the road widens by.
	var edge_at := func(p_wx: float) -> float:
		var last := 0.0
		for step in range(0, 200):
			var d := float(step) * 0.25
			if node._path.nearest(Vector2(p_wx, d))["distance"] > 40.0:
				break
			var q := node._path.nearest(Vector2(p_wx, d))
			var half: float = node._path.half_width_at(q["s"])
			if float(q["distance"]) <= half:
				last = d
		return last
	var narrow: float = edge_at.call(2.0)
	var wide: float = edge_at.call(98.0)
	# And the same question asked of the grid the node actually produced, which is what ships.
	var on_road := 0
	var off_road := 0
	for iz in gh:
		for ix in gw:
			var wz: float = rect.position.y + (float(iz) + 0.5) * rect.size.y / float(gh)
			var v: float = m[iz * gw + ix]
			if absf(wz) < 3.0:
				on_road += 1 if v > 0.99 else 0
			elif absf(wz) > 12.0:
				off_road += 1 if v < 0.01 else 0
	print("    the edge is %.2f m out at the narrow end and %.2f m at the wide end (ratio %.2f, want ~2)"
			% [narrow, wide, wide / maxf(narrow, 1e-6)])
	_check("J", absf(wide / maxf(narrow, 1e-6) - 2.0) < 0.15 and on_road > 0 and off_road > 0,
			"width ratio %.2f; %d cell(s) masked on the road, %d clear well off it"
					% [wide / maxf(narrow, 1e-6), on_road, off_road])

	# CONTROL: an empty path must mask NOTHING, and inverting must mask EVERYTHING. An unresolved Road
	# Source is a normal state; the inverted mask protecting nothing would erase what it was guarding.
	var empty := Pasture3DGraphNodeDevPathMask.new()
	empty.set_path_inputs([Pasture3DGraphPath.new()])
	var e0 := empty.eval_grid([], 8, 8, null, rect)
	empty.invert = true
	var e1 := empty.eval_grid([], 8, 8, null, rect)
	print("    control: an empty path masks %.1f, inverted %.1f (want 0.0 then 1.0)" % [e0[0], e1[0]])
	if e0[0] != 0.0 or e1[0] != 1.0:
		_fail += 1
		print("    !! an unresolved road does not read as \'no road here\'")

	# CONTROL: the feather must actually soften. Without this, `feather` could be ignored entirely and
	# every assertion above still holds, since both are measured on the hard part of the mask.
	node.feather = 6.0
	var soft := node.eval_grid([], gw, gh, null, rect)
	var partial := 0
	for v in soft:
		if v > 0.02 and v < 0.98:
			partial += 1
	print("    control: with a 6 m feather, %d cell(s) are partly masked (want more than 0)" % partial)
	if partial == 0:
		_fail += 1
		print("    !! the feather does nothing, so the mask is a hard edge whatever it is set to")


# ---- K ------------------------------------------------------------------------------------------

## [K] The graph cuts the SAME road the brush does.
##
## Road Grade is an adapter over Pasture3DRoadGrader, deliberately, and this is the criterion that keeps
## it one. A second grading implementation would not fail loudly: it would produce a road that looks
## entirely correct on its own and differs from the brush\'s by centimetres, so a scene using both would
## have a seam nobody could account for.
##
## Two things have to be right for this to pass and both are easy to get wrong: the rect-to-metres
## conversion (cell centres, not corners) and the profile arrays, which are handed over verbatim in the
## grader\'s alignment-sample space rather than resampled onto the path\'s vertices.
func _k_the_graph_cuts_the_same_road_the_brush_does() -> void:
	print("[K] the graph cuts the same road the brush does")
	var f := _road_over_the_ridge()
	var brush_h: PackedFloat32Array = f["graded"]["height"]
	var brush_bed: PackedFloat32Array = f["graded"]["roadbed"]
	var path: Pasture3DGraphPath = f["path"]

	var node := Pasture3DGraphNodeDevRoadGrade.new()
	node.set_path_inputs([null, path])
	var ch := node.eval_grid_channels([f["ground"]], G_N, G_N, null, _rect())
	var graph_h: PackedFloat32Array = ch[0]
	var graph_bed: PackedFloat32Array = ch[1]

	var worst := 0.0
	var bed_diff := 0
	var cut_cells := 0
	for i in G_N * G_N:
		worst = maxf(worst, absf(graph_h[i] - brush_h[i]))
		if absf(graph_bed[i] - brush_bed[i]) > 0.01:
			bed_diff += 1
		if brush_bed[i] > 0.5:
			cut_cells += 1
	print("    %d roadbed cell(s) in the brush\'s cut; worst height difference %.4f m, %d roadbed cell(s) differ"
			% [cut_cells, worst, bed_diff])
	_check("K", worst < 1e-3 and bed_diff == 0 and cut_cells > 100,
			"worst %.4f m, %d bed cell(s) differ, %d cell(s) cut" % [worst, bed_diff, cut_cells])

	# CONTROL: the cut has to be a real change to the ground, or \'they agree\' is two no-ops agreeing.
	var moved := 0.0
	for i in G_N * G_N:
		moved = maxf(moved, absf(brush_h[i] - (f["ground"] as PackedFloat32Array)[i]))
	print("    control: the road moved the ground by up to %.2f m (want a real cut)" % moved)
	if moved < 1.0:
		_fail += 1
		print("    !! the fixture road barely touches the terrain, so agreeing about it proves nothing")

	# CONTROL: a path with no solved profile must PASS THE SURFACE THROUGH, not flatten it. A graph mid
	# edit passes through this state constantly, and a node that returned zeros would read as the
	# terrain having been destroyed rather than as a road not being resolved yet.
	var bare := Pasture3DGraphNodeDevRoadGrade.new()
	bare.set_path_inputs([null, _straight()])
	var through := bare.eval_grid_channels([f["ground"]], G_N, G_N, null, _rect())
	var passed: bool = (through[0] as PackedFloat32Array) == (f["ground"] as PackedFloat32Array)
	print("    control: a path with no solved profile passed the surface through: %s" % str(passed))
	if not passed:
		_fail += 1
		print("    !! an ungradeable path changes the terrain anyway")
	(f["net"] as Node).queue_free()


# ---- L ------------------------------------------------------------------------------------------

## [L] The two §8 wirings differ, and they differ where §8 is about.
##
## THE POINT OF THE WHOLE GRAPH SIDE OF §8. The brush can only ever cut the road last. Terrain3D\'s
## connector flattens the heightmap after the fact and erosion never learns it happened. Here the order
## is a wire:
##
##   1. Input → Erosion → Road Grade → Output          the road cuts the weathered mountain
##   2. Input → Road Grade → Blend(MIX) ← Erosion       the hillside weathers AROUND the cut
##                └─ roadbed (inverted) → Blend.mask
##
## ---- WHAT THIS CRITERION EXPECTED, AND WHAT IS ACTUALLY TRUE ----
##
## It was written expecting the two to differ ON THE CARRIAGEWAY. They do not, and cannot: the road\'s
## surface height comes from the SOLVED ALIGNMENT, and the alignment is a property of the road rather
## than of the surface it is being cut into. Both wirings write the same absolute z there, to the metre
## the solver decided. That is a good property and it is worth having found out: the ordering cannot move
## the road, only the ground around it.
##
## So the difference lives in the BATTERS and the verge, and that is checked here in both directions:
## they must differ (or the ordering is doing nothing), and the roadbed must NOT (or the road is being
## moved by something that has no business deciding where it goes).
##
## The third surface is what the mask actually buys. Erode after grading with no mask and the road is
## eaten — that is the failure Terrain3D\'s ordering has and the one §8 exists to avoid — so [L] measures
## it rather than asserting it.
func _l_the_two_wirings_differ_as_predicted() -> void:
	print("[L] the two §8 wirings differ as predicted")
	var f := _road_over_the_ridge()
	var path: Pasture3DGraphPath = f["path"]
	var ground: PackedFloat32Array = f["ground"]
	var rect := _rect()

	# ---- wiring 1: erode, then cut
	var er := Pasture3DGraphNodeErosion.new()
	er.iterations = 30
	var eroded: PackedFloat32Array = er.eval_grid_channels([ground], G_N, G_N, null, rect)[0]
	var cut_after := Pasture3DGraphNodeDevRoadGrade.new()
	cut_after.set_path_inputs([null, path])
	var w1: PackedFloat32Array = cut_after.eval_grid_channels([eroded], G_N, G_N, null, rect)[0]

	# ---- wiring 2: cut, then let the hillside weather around it
	var cut_first := Pasture3DGraphNodeDevRoadGrade.new()
	cut_first.set_path_inputs([null, path])
	var ch := cut_first.eval_grid_channels([ground], G_N, G_N, null, rect)
	var cut_h: PackedFloat32Array = ch[0]
	var bed: PackedFloat32Array = ch[1]
	var cutm: PackedFloat32Array = ch[2]
	var fillm: PackedFloat32Array = ch[3]
	var er2 := Pasture3DGraphNodeErosion.new()
	er2.iterations = 30
	var unmasked: PackedFloat32Array = er2.eval_grid_channels([cut_h], G_N, G_N, null, rect)[0]
	var blend := Pasture3DGraphNodeBlend.new()
	blend.mode = Pasture3DGraphNodeBlend.Mode.MIX
	var w2 := PackedFloat32Array()
	w2.resize(G_N * G_N)
	for i in G_N * G_N:
		# a = the cut, b = the weathered version of it, mask = NOT the roadbed. So the carriageway keeps
		# its solved profile and everything else is whatever erosion made of it.
		w2[i] = blend.eval_cell(0.0, 0.0, PackedFloat32Array([cut_h[i], unmasked[i], 1.0 - bed[i]]))

	var on_bed := 0.0
	var on_batter := 0.0
	var bed_cells := 0
	var batter_cells := 0
	for i in G_N * G_N:
		var d := absf(w1[i] - w2[i])
		if bed[i] > 0.5:
			bed_cells += 1
			on_bed = maxf(on_bed, d)
		elif cutm[i] > 0.5 or fillm[i] > 0.5:
			batter_cells += 1
			on_batter = maxf(on_batter, d)
	print("    roadbed (%d cell(s)): the wirings differ by %.4f m — the alignment decides the road\'s height"
			% [bed_cells, on_bed])
	print("    batters (%d cell(s)): they differ by up to %.3f m — this is what the ordering changes"
			% [batter_cells, on_batter])
	_check("L", bed_cells > 100 and batter_cells > 100 and on_bed < 1e-3 and on_batter > 0.05,
			"roadbed %.4f m (want none), batters %.3f m (want a real difference)" % [on_bed, on_batter])

	# WHAT THE MASK BUYS. Wiring 2 without it is erosion running straight over the carriageway, which is
	# the failure mode §8 exists to avoid. Measured, not asserted: if the mask were being ignored, every
	# number above would still look reasonable and the road would be quietly washing away.
	var eaten := 0.0
	for i in G_N * G_N:
		if bed[i] > 0.5:
			eaten = maxf(eaten, absf(unmasked[i] - cut_h[i]))
	print("    without the roadbed mask, erosion moves the carriageway by up to %.2f m (the mask holds it at 0)"
			% eaten)
	if eaten < 0.05:
		_fail += 1
		print("    !! erosion does not touch the road even unmasked, so the mask is not being tested")

	# CONTROL: erosion must actually have changed the hillside. On a fixture it cannot move, both
	# wirings are the same arithmetic and [L] would pass by describing nothing.
	var eroded_by := 0.0
	for i in G_N * G_N:
		eroded_by = maxf(eroded_by, absf(eroded[i] - ground[i]))
	print("    control: erosion moved the ground by up to %.2f m (want a real change)" % eroded_by)
	if eroded_by < 0.05:
		_fail += 1
		print("    !! erosion did nothing on this fixture, so the two wirings are trivially equal")

	# CONTROL: Blend MIX must actually be a mix. A mode that fell through to `a` — which is exactly what
	# the native op does for a mode it does not know — would make wiring 2 the bare cut everywhere, and
	# the batter half of [L] would still pass while measuring the wrong thing.
	var mixed: float = blend.eval_cell(0.0, 0.0, PackedFloat32Array([10.0, 20.0, 1.0]))
	var held: float = blend.eval_cell(0.0, 0.0, PackedFloat32Array([10.0, 20.0, 0.0]))
	print("    control: Blend MIX at mask 1 gives %.1f and at mask 0 gives %.1f (want 20 then 10)"
			% [mixed, held])
	if not (is_equal_approx(mixed, 20.0) and is_equal_approx(held, 10.0)):
		_fail += 1
		print("    !! Blend MIX is not a mix, so wiring 2 is not the wiring §8 describes")
	(f["net"] as Node).queue_free()


# ---- M ------------------------------------------------------------------------------------------

## [M] Multi-spline partial bake integrity: graph_path() spans the full concatenated road.
func _m_multi_spline_partial_bake_integrity() -> void:
	print("[M] multi-spline partial bake integrity: graph_path() spans the full road")
	var net := Pasture3DRoadNetwork.new()
	add_child(net)
	var t := Pasture3DRoadType.new()
	t.type_name = "multi"
	t.lane_count = 2
	t.lane_width = 3.5
	net.road_types = [t]
	var brush := Pasture3DRoadBrush.new()
	brush.name = "MultiSplineRoad"
	net.add_child(brush)

	var p1 := Path3D.new()
	var c1 := Curve3D.new()
	c1.add_point(Vector3(-60.0, 0.0, 0.0))
	c1.add_point(Vector3(0.0, 0.0, 0.0))
	p1.curve = c1
	brush.add_child(p1)

	var p2 := Path3D.new()
	var c2 := Curve3D.new()
	c2.add_point(Vector3(0.0, 0.0, 0.0))
	c2.add_point(Vector3(60.0, 0.0, 0.0))
	p2.curve = c2
	brush.add_child(p2)

	brush.road_road_type = t
	var road_mod := Pasture3DNodeRoad.new()
	road_mod.alignment_step = 1.0
	brush.modifiers = [road_mod]

	var ground := _ridge()
	brush.grade_surface(road_mod, ground, G_N, G_N, G_MIN, G_MIN, G_VS)
	var path := brush.graph_path()
	var total_len: float = path.length()
	var seg_count: int = path.segment_count()
	print("    full multi-spline road: %d segment(s), total length %.1f m" % [seg_count, total_len])
	_check("M", seg_count >= 2 and total_len >= 119.0,
			"%d segment(s), %.1f m total span (want >= 119.0 m)" % [seg_count, total_len])
	net.queue_free()


# ---- N ------------------------------------------------------------------------------------------

## [N] Shared-layer stamp cache isolation: editing Road A does not bump Road B's Road Source revision.
func _n_shared_layer_stamp_cache_isolation() -> void:
	print("[N] shared-layer stamp cache isolation")
	var net := Pasture3DRoadNetwork.new()
	add_child(net)
	var t := Pasture3DRoadType.new()
	t.type_name = "test"
	net.road_types = [t]

	var brush_a := Pasture3DRoadBrush.new()
	brush_a.name = "RoadA"
	net.add_child(brush_a)
	var pa := Path3D.new()
	var ca := Curve3D.new()
	ca.add_point(Vector3(-40.0, 0.0, -20.0))
	ca.add_point(Vector3(40.0, 0.0, -20.0))
	pa.curve = ca
	brush_a.add_child(pa)
	brush_a.road_road_type = t
	var mod_a := Pasture3DNodeRoad.new()
	brush_a.modifiers = [mod_a]

	var brush_b := Pasture3DRoadBrush.new()
	brush_b.name = "RoadB"
	net.add_child(brush_b)
	var pb := Path3D.new()
	var cb := Curve3D.new()
	cb.add_point(Vector3(-40.0, 0.0, 20.0))
	cb.add_point(Vector3(40.0, 0.0, 20.0))
	pb.curve = cb
	brush_b.add_child(pb)
	brush_b.road_road_type = t
	var mod_b := Pasture3DNodeRoad.new()
	brush_b.modifiers = [mod_b]

	var ground := _ridge()
	brush_a.grade_surface(mod_a, ground, G_N, G_N, G_MIN, G_MIN, G_VS)
	brush_b.grade_surface(mod_b, ground, G_N, G_N, G_MIN, G_MIN, G_VS)

	var graph := Pasture3DTerrainGraph.new()
	var src_b := Pasture3DGraphNodeRoadSource.new()
	src_b.road_key = brush_b.road_key()
	graph.add_node(src_b)
	net.resolve_graph_paths(graph, brush_b)

	var rev_before: int = src_b._dirty_revision

	# Now modify Road A and re-resolve
	ca.set_point_position(1, Vector3(45.0, 0.0, -20.0))
	brush_a.grade_surface(mod_a, ground, G_N, G_N, G_MIN, G_MIN, G_VS)
	net.resolve_graph_paths(graph, brush_b)

	var rev_after: int = src_b._dirty_revision
	print("    editing RoadA moved RoadB's Road Source revision %d -> %d (want no change)"
			% [rev_before, rev_after])
	_check("N", rev_before == rev_after,
			"RoadB revision preserved (%d == %d)" % [rev_before, rev_after])
	net.queue_free()


# ---- O ------------------------------------------------------------------------------------------

## [O] Native stamp_road_line parity with Road Grade graph node.
func _o_native_stamp_road_line_parity() -> void:
	print("[O] native stamp_road_line and Road Grade graph node mathematical parity")
	var f := _road_over_the_ridge()
	var path: Pasture3DGraphPath = f["path"]
	var brush_h: PackedFloat32Array = f["graded"]["height"]
	var brush_bed: PackedFloat32Array = f["graded"]["roadbed"]

	var node := Pasture3DGraphNodeDevRoadGrade.new()
	node.set_path_inputs([null, path])
	var ch := node.eval_grid_channels([f["ground"]], G_N, G_N, null, _rect())
	var graph_h: PackedFloat32Array = ch[0]
	var graph_bed: PackedFloat32Array = ch[1]

	var worst := 0.0
	var bed_diff := 0
	for i in G_N * G_N:
		worst = maxf(worst, absf(graph_h[i] - brush_h[i]))
		if absf(graph_bed[i] - brush_bed[i]) > 0.01:
			bed_diff += 1

	print("    worst height diff %.6f m, %d roadbed cells differ" % [worst, bed_diff])
	_check("O", worst < 1e-4 and bed_diff == 0,
			"parity ok: worst %.6f m, %d bed diffs" % [worst, bed_diff])
	(f["net"] as Node).queue_free()
