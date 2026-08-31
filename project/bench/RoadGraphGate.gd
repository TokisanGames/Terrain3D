# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadGraphGate — P7a: the PATH port type, Road Source, and the analytic Path Distance (§8).
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

const CRITERIA: Array[String] = ["A", "B", "C", "D", "E", "F", "G"]

var _fail: int = 0
var _reported: Dictionary = {}


func _ready() -> void:
	print("=== RoadGraphGate: the PATH port, Road Source and Path Distance (P7a) ===\n")
	_a_the_index_agrees_with_brute_force()
	_b_distance_is_to_the_polyline_not_to_its_infinite_line()
	_c_s_is_absolute_arc_length()
	_d_t_is_normalised_and_positive_is_the_drivers_right()
	_e_an_unresolved_path_reads_far_away_not_on_the_road()
	_f_the_path_travels_down_the_wire()
	_g_a_moved_path_invalidates_the_cache()
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
	var node := Pasture3DGraphNodePathDistance.new()
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
	var dist := Pasture3DGraphNodePathDistance.new()
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
	var dist := Pasture3DGraphNodePathDistance.new()
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
