# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadJunctionGate — Pasture3DRoadJunctionSolver (P4a). Junctions are found from geometry, resolved once
# and RECONCILED thereafter, and the trim-back leaves the shape a mesher can build.
#
# Criteria E and F are here because P4a resolves junction footprints without anything ever having tried
# to mesh one (§11). Rather than defer the risk to P5, they assert the SHAPE properties a mesher needs —
# no gap and no overlap where an approach meets the junction — which is a numeric fact about the
# trim-back, available now.
@tool
extends Node

var _fail: int = 0


func _ready() -> void:
	print("=== RoadJunctionGate: junction detection and geometry (P4a) ===\n")
	_a_a_crossing_is_found_and_a_near_miss_is_not()
	_b_a_bridge_crosses_without_meeting()
	_c_priority_decides_elevation_and_who_bends()
	_d_an_override_survives_an_unrelated_edit()
	_e_the_trim_back_leaves_no_gap_and_no_overlap()
	_f_an_acute_crossing_trims_back_further()
	print("\n=== %s (%d failures) ===\n" % ["ROAD JUNCTION PASS" if _fail == 0 else "ROAD JUNCTION FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---- fixtures -----------------------------------------------------------------------------------

## A run description for the solver. `p_pts` is the world XZ centreline.
func _run(p_key: String, p_pts: PackedVector2Array, p_priority: int, p_half: float,
		p_height: float = 0.0, p_bridge_from: float = -1.0, p_bridge_to: float = -1.0) -> Dictionary:
	var cum := Pasture3DRoadGrader.cumulative_length(p_pts)
	var total: float = cum[cum.size() - 1]
	var n := maxi(int(ceil(total)) + 1, 2)
	var a := Pasture3DRoadAlignment.new()
	a.ds = 1.0
	var z := PackedFloat32Array()
	z.resize(n)
	z.fill(p_height)
	a.z = z
	a.ground = z.duplicate()
	var bridge := PackedByteArray()
	bridge.resize(n)
	bridge.fill(0)
	if p_bridge_from >= 0.0:
		for i in n:
			if float(i) >= p_bridge_from and float(i) <= p_bridge_to:
				bridge[i] = 1
	return {"key": p_key, "plan": p_pts, "cum": cum, "alignment": a, "bridge": bridge,
			"priority": p_priority, "half_width": p_half}


## A straight run along +X at z = 0, through the origin.
func _east_west(p_key: String, p_priority: int, p_half: float, p_height: float = 0.0,
		p_bridge_from: float = -1.0, p_bridge_to: float = -1.0) -> Dictionary:
	return _run(p_key, PackedVector2Array([Vector2(-100.0, 0.0), Vector2(100.0, 0.0)]),
			p_priority, p_half, p_height, p_bridge_from, p_bridge_to)


## A straight run along +Z at x = 0, through the origin — a square crossing with the one above.
func _north_south(p_key: String, p_priority: int, p_half: float, p_height: float = 0.0) -> Dictionary:
	return _run(p_key, PackedVector2Array([Vector2(0.0, -100.0), Vector2(0.0, 100.0)]),
			p_priority, p_half, p_height)


# ---- A ------------------------------------------------------------------------------------------

func _a_a_crossing_is_found_and_a_near_miss_is_not() -> void:
	print("[A] a crossing is found; roads that merely come close are not a junction")
	var js := Pasture3DRoadJunctionSolver.resolve([
		_east_west("ew", 10, 4.0), _north_south("ns", 5, 4.0)])
	print("    a square crossroads -> %d junction(s), centre %s" % [js.size(), js[0].center if js.size() > 0 else "-"])
	if js.size() != 1:
		_fail += 1; print("    !! expected exactly one junction")
	elif js[0].center.distance_to(Vector2.ZERO) > 0.5:
		_fail += 1; print("    !! the junction is not where the roads cross")
	elif js[0].road_keys.size() != 2:
		_fail += 1; print("    !! both roads should be participants")

	# CONTROL: move one road so they no longer touch. Same code path, no junction — so [A] is detecting
	# a crossing rather than reporting one whenever two roads exist.
	var apart := Pasture3DRoadJunctionSolver.resolve([
		_east_west("ew", 10, 4.0),
		_run("ns", PackedVector2Array([Vector2(0.0, 20.0), Vector2(0.0, 100.0)]), 5, 4.0)])
	print("    control: the same roads pulled apart -> %d junction(s)" % apart.size())
	if apart.size() != 0:
		_fail += 1; print("    !! a junction was reported where the roads do not meet")

	# CONTROL: two PARALLEL roads never cross, and 1/sin θ would be meaningless if they were treated as
	# though they did.
	var parallel := Pasture3DRoadJunctionSolver.resolve([
		_east_west("a", 10, 4.0),
		_run("b", PackedVector2Array([Vector2(-100.0, 30.0), Vector2(100.0, 30.0)]), 5, 4.0)])
	print("    control: two parallel roads -> %d junction(s)" % parallel.size())
	if parallel.size() != 0:
		_fail += 1; print("    !! parallel roads were treated as crossing")


# ---- B ------------------------------------------------------------------------------------------

func _b_a_bridge_crosses_without_meeting() -> void:
	print("[B] an overpass crosses without meeting — grade separation from data already in the design")
	# The east-west road is on a structure across the middle 40 m of its run, which is where the other
	# road passes beneath it. Arc length 100 is the origin on a 200 m run.
	var bridged := Pasture3DRoadJunctionSolver.resolve([
		_east_west("ew", 10, 4.0, 0.0, 80.0, 120.0), _north_south("ns", 5, 4.0)])
	print("    bridged crossing -> %d junction(s) (want 0)" % bridged.size())
	if bridged.size() != 0:
		_fail += 1; print("    !! a road on a bridge formed a junction with the road under it")

	# The OTHER exclusion, and it has to work on its own: two roads at road level but 12 m apart
	# vertically are passing, not meeting, even with no bridge flag set anywhere.
	var high := Pasture3DRoadJunctionSolver.resolve([
		_east_west("ew", 10, 4.0, 12.0), _north_south("ns", 5, 4.0, 0.0)])
	print("    12 m of vertical separation, no bridge flag -> %d junction(s) (want 0)" % high.size())
	if high.size() != 0:
		_fail += 1; print("    !! roads 12 m apart vertically were joined")

	# CONTROL: the same two roads WITHOUT the bridge, and at the same height, do meet — so [B] measures
	# the exclusion rather than a fixture that never crossed.
	var level := Pasture3DRoadJunctionSolver.resolve([
		_east_west("ew", 10, 4.0), _north_south("ns", 5, 4.0)])
	print("    control: unbridged and level -> %d junction(s) (want 1)" % level.size())
	if level.size() != 1:
		_fail += 1; print("    !! the control did not cross, so the exclusions prove nothing")

	# CONTROL: a road bridged SOMEWHERE ELSE still forms this junction — the test is at the crossing, not
	# a property of the whole road.
	var elsewhere := Pasture3DRoadJunctionSolver.resolve([
		_east_write_bridged_far(), _north_south("ns", 5, 4.0)])
	print("    control: bridged 150 m away -> %d junction(s) (want 1)" % elsewhere.size())
	if elsewhere.size() != 1:
		_fail += 1; print("    !! a bridge elsewhere on the road suppressed an unrelated junction")


func _east_write_bridged_far() -> Dictionary:
	return _east_west("ew", 10, 4.0, 0.0, 170.0, 190.0)


# ---- C ------------------------------------------------------------------------------------------

func _c_priority_decides_elevation_and_who_bends() -> void:
	print("[C] priority decides the junction's height, and the minor road gets the pin")
	# The two roads are solved at DIFFERENT heights. The junction must take the major road's, so the
	# road with right of way keeps the profile it solved.
	var major := _east_west("ew", 10, 4.0, 7.0)
	var minor := _north_south("ns", 5, 4.0, 2.0)
	var js := Pasture3DRoadJunctionSolver.resolve([major, minor])
	if js.size() != 1:
		_fail += 1; print("    !! expected one junction"); return
	var j: Pasture3DRoadJunction = js[0]
	print("    major road is '%s' (priority 10 vs 5); junction elevation %.2f (want 7.00, the major's)"
			% [j.road_keys[j.effective_major()], j.elevation])
	if j.road_keys[j.effective_major()] != "ew" or absf(j.elevation - 7.0) > 1e-3:
		_fail += 1; print("    !! the junction did not take the higher-priority road's height")

	# The pin is what makes this reach the alignment solver: the MAJOR road is pinned to nothing (it keeps
	# what it solved) and the minor road is pinned to the junction height.
	var pin_major := j.pin_for("ew")
	var pin_minor := j.pin_for("ns")
	print("    pin for the major road: %s (want none); for the minor: %.2f (want 7.00)"
			% ["none" if is_nan(pin_major) else str(pin_major), pin_minor])
	if not is_nan(pin_major):
		_fail += 1; print("    !! the major road was pinned, so it does not keep its own profile")
	if is_nan(pin_minor) or absf(pin_minor - 7.0) > 1e-3:
		_fail += 1; print("    !! the minor road was not pinned to the junction")

	# CONTROL: flip the priorities and the answer flips with them. Without this, [C] would pass on a
	# solver that always picks the first road.
	var flipped := Pasture3DRoadJunctionSolver.resolve([
		_east_west("ew", 1, 4.0, 7.0), _north_south("ns", 99, 4.0, 2.0)])
	print("    control: priorities flipped -> major '%s', elevation %.2f (want ns, 2.00)"
			% [flipped[0].road_keys[flipped[0].effective_major()], flipped[0].elevation])
	if flipped[0].road_keys[flipped[0].effective_major()] != "ns" or absf(flipped[0].elevation - 2.0) > 1e-3:
		_fail += 1; print("    !! priority does not decide the junction")


# ---- D ------------------------------------------------------------------------------------------

func _d_an_override_survives_an_unrelated_edit() -> void:
	print("[D] a resolved junction is reconciled, not rebuilt — the user's choice survives")
	var first := Pasture3DRoadJunctionSolver.resolve([
		_east_west("ew", 10, 4.0), _north_south("ns", 5, 4.0)])
	var j: Pasture3DRoadJunction = first[0]
	var id_before := j.id
	# The user makes a decision here.
	j.control = Pasture3DRoadJunction.ControlType.SIGNALS
	j.major_override = 1
	j.radius_override = 30.0

	# Now something unrelated changes: a THIRD road is added 300 m away, and the east-west road is
	# extended. The junction at the origin is untouched by either.
	var second := Pasture3DRoadJunctionSolver.resolve([
		_run("ew", PackedVector2Array([Vector2(-140.0, 0.0), Vector2(140.0, 0.0)]), 10, 4.0),
		_north_south("ns", 5, 4.0),
		_run("far", PackedVector2Array([Vector2(300.0, -50.0), Vector2(300.0, 50.0)]), 5, 4.0),
	], first)
	var kept: Pasture3DRoadJunction = null
	for k: Pasture3DRoadJunction in second:
		if k.id == id_before:
			kept = k
	print("    after an unrelated edit: %d junction(s); the original %s"
			% [second.size(), "survived" if kept != null else "WAS LOST"])
	if kept == null:
		_fail += 1; print("    !! the junction was rebuilt under a new id"); return
	print("    control setting %s, major override %d, radius override %.1f (want SIGNALS, 1, 30.0)"
			% [Pasture3DRoadJunction.ControlType.keys()[kept.control + 1], kept.major_override,
			kept.radius_override])
	if kept.control != Pasture3DRoadJunction.ControlType.SIGNALS or kept.major_override != 1 \
			or absf(kept.radius_override - 30.0) > 1e-3:
		_fail += 1; print("    !! the user's overrides were discarded by a re-resolve")
	# The override actually decides: priority says ew, the override says index 1.
	if kept.road_keys[kept.effective_major()] != "ns":
		_fail += 1; print("    !! the major override was stored but not honoured")

	# CONTROL: the resolved fields ARE refreshed — reconciling is not the same as ignoring the new
	# geometry. The far road is a genuinely new junction only if it crosses something; here it crosses
	# nothing, so the count must still be 1.
	print("    control: a road 300 m away that crosses nothing -> %d junction(s) total" % second.size())
	if second.size() != 1:
		_fail += 1; print("    !! an isolated road produced a junction")

	# CONTROL: pull the roads apart entirely. The junction is KEPT but marked undetected, so the
	# overrides survive a temporary drag rather than being thrown away.
	var pulled := Pasture3DRoadJunctionSolver.resolve([
		_east_west("ew", 10, 4.0),
		_run("ns", PackedVector2Array([Vector2(0.0, 40.0), Vector2(0.0, 100.0)]), 5, 4.0),
	], second)
	var stale: Pasture3DRoadJunction = null
	for k: Pasture3DRoadJunction in pulled:
		if k.id == id_before:
			stale = k
	print("    control: roads pulled apart -> junction kept: %s, detected: %s (want kept, false)"
			% [stale != null, stale.detected if stale != null else "-"])
	if stale == null or stale.detected:
		_fail += 1; print("    !! an undetected junction was deleted along with its overrides")


# ---- E ------------------------------------------------------------------------------------------

func _e_the_trim_back_leaves_no_gap_and_no_overlap() -> void:
	print("[E] the trim-back lands each approach exactly on the other road's edge (the mesher's bar)")
	# Square crossing, different widths, so a solver that used its OWN width instead of the other road's
	# would land in a visibly wrong place.
	var w_ew := 6.0
	var w_ns := 3.0
	var js := Pasture3DRoadJunctionSolver.resolve([
		_east_west("ew", 10, w_ew), _north_south("ns", 5, w_ns)])
	var j: Pasture3DRoadJunction = js[0]
	var t_ew := j.trim_back_for("ew")
	var t_ns := j.trim_back_for("ns")
	# At a square crossing sin θ = 1, so each road stops at exactly the OTHER road's half-width.
	print("    east-west (half %.1f) trims back %.3f (want %.1f, the NS half-width)" % [w_ew, t_ew, w_ns])
	print("    north-south (half %.1f) trims back %.3f (want %.1f, the EW half-width)" % [w_ns, t_ns, w_ew])
	if absf(t_ew - w_ns) > 1e-3 or absf(t_ns - w_ew) > 1e-3:
		_fail += 1; print("    !! an approach does not stop on the other road's edge")

	# Stated as the mesher will see it: the trimmed end of each approach is exactly on the other road's
	# boundary — no gap to fill, no overlap to resolve. This is the same number as above, expressed as
	# the property that actually matters, because that is the one a later refactor must not break.
	var gap_ew := t_ew - w_ns
	var gap_ns := t_ns - w_ew
	print("    gap at the EW approach %+.6f m, at the NS approach %+.6f m (want 0 and 0)"
			% [gap_ew, gap_ns])
	if absf(gap_ew) > 1e-3 or absf(gap_ns) > 1e-3:
		_fail += 1; print("    !! the junction footprint does not close against its approaches")

	# The footprint has to CONTAIN every trimmed end, or an approach would stop short of it and leave a
	# hole in the middle of the intersection.
	print("    radius %.3f (want >= the largest trim-back, %.3f)" % [j.radius, maxf(t_ew, t_ns)])
	if j.radius < maxf(t_ew, t_ns) - 1e-3:
		_fail += 1; print("    !! the footprint does not reach its own approaches")

	# CONTROL: widening the footprint pushes the approaches back WITH it, rather than leaving them
	# stranded inside a junction that grew around them.
	j.radius_override = 25.0
	print("    control: radius override 25 -> EW trims back %.3f (want %.3f)"
			% [j.trim_back_for("ew"), t_ew + (25.0 - j.radius)])
	if absf(j.trim_back_for("ew") - (t_ew + 25.0 - j.radius)) > 1e-3:
		_fail += 1; print("    !! a widened footprint did not push its approaches back")


# ---- F ------------------------------------------------------------------------------------------

func _f_an_acute_crossing_trims_back_further() -> void:
	print("[F] an acute crossing trims back further — 1/sin θ, not a fixed radius")
	var half := 4.0
	var results: Array = []
	for deg: float in [90.0, 45.0, 20.0]:
		var rad := deg_to_rad(deg)
		# A road through the origin at `deg` to the east-west road.
		var dir := Vector2(cos(rad), sin(rad))
		var js := Pasture3DRoadJunctionSolver.resolve([
			_east_west("ew", 10, half),
			_run("x", PackedVector2Array([-dir * 150.0, dir * 150.0]), 5, half)])
		if js.size() != 1:
			_fail += 1; print("    !! no junction at %.0f°" % deg); return
		var want: float = half / sin(rad)
		var got: float = js[0].trim_back_for("ew")
		results.append(got)
		print("    at %5.1f°: trim-back %7.3f (want %7.3f = half-width / sin θ)" % [deg, got, want])
		if absf(got - want) > 0.05:
			_fail += 1; print("    !! the trim-back is not half-width / sin θ")

	# The ordering is the point: a fixed-radius junction would give three equal numbers.
	print("    trim-backs 90° -> 45° -> 20°: %.2f, %.2f, %.2f (must strictly increase)"
			% [results[0], results[1], results[2]])
	if not (results[0] < results[1] and results[1] < results[2]):
		_fail += 1; print("    !! the trim-back does not grow as the crossing sharpens")

	# CONTROL: a road that is nearly parallel is not a crossing at all, which is where 1/sin θ would
	# otherwise run away to infinity and produce an absurd footprint.
	var rad2 := deg_to_rad(2.0)
	var dir2 := Vector2(cos(rad2), sin(rad2))
	var near := Pasture3DRoadJunctionSolver.resolve([
		_east_west("ew", 10, half),
		_run("x", PackedVector2Array([-dir2 * 150.0, dir2 * 150.0]), 5, half)])
	print("    control: a 2° crossing -> %d junction(s) (want 0, it is running alongside)" % near.size())
	if near.size() != 0:
		_fail += 1; print("    !! a near-parallel road produced a junction with a runaway footprint")
