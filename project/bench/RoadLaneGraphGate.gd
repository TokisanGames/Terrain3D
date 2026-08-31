# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadLaneGraphGate — P4b. The lane graph and the four queries a naive consumer needs (§6.4): given a
# lane, what are my legal next lanes, where is my stop line, what is the signal state, who do I yield to.
#
# This file grows with the phase. It starts at the bottom — the cross-section — because a connector
# joins two lanes and a stop line sits at the head of one, so an error there surfaces everywhere else as
# something that looks like a junction bug.
@tool
extends Node

var _fail: int = 0


func _ready() -> void:
	print("=== RoadLaneGraphGate: lanes, connectors and right of way (P4b) ===\n")
	_a_the_cross_section_tiles_the_carriageway()
	_b_traffic_side_decides_which_lanes_are_oncoming()
	_c_a_one_way_road_has_no_oncoming_lanes()
	_d_an_offset_finds_exactly_one_lane()
	_e_every_incoming_lane_reaches_every_other_arm()
	_f_a_connector_is_tangent_continuous_with_its_lanes()
	_g_traffic_side_decides_which_turn_crosses_traffic()
	_h_every_incoming_lane_has_a_stop_line_at_the_footprint()
	_i_only_movements_that_meet_are_in_conflict()
	_j_priority_decides_who_gives_way()
	_k_a_turn_across_oncoming_yields_to_the_traffic_it_crosses()
	_l_equal_priority_gives_way_to_the_priority_side()
	_m_phases_are_one_per_road_with_green_from_priority()
	_n_a_signalised_junction_cycles_and_publishes_its_state()
	print("\n=== %s (%d failures) ===\n" % ["ROAD LANE GRAPH PASS" if _fail == 0 else "ROAD LANE GRAPH FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	if not p_ok:
		_fail += 1
	print("%s %s: %s" % ["   " if p_ok else "!! ", p_name, p_detail])


func _offsets(p_lanes: Array) -> String:
	var parts := PackedStringArray()
	for l: Dictionary in p_lanes:
		parts.append("%+.2f%s" % [float(l["offset"]), "→" if int(l["direction"]) > 0 else "←"])
	return " ".join(parts)


# ---- A ------------------------------------------------------------------------------------------

## [A] The lanes exactly tile the carriageway: they abut with no gap and no overlap, they span the full
## width the road type claims, and they are symmetric about the centreline. Closed form, so the expected
## numbers are written out rather than derived by the same code under test.
func _a_the_cross_section_tiles_the_carriageway() -> void:
	print("[A] the cross-section tiles the carriageway")
	var lanes := Pasture3DRoadLanes.cross_section(4, 3.5, false, false)
	print("    4 lanes at 3.5 m: %s" % _offsets(lanes))
	# 4 × 3.5 = 14 m, so the edges are ±7 and the lane centres are ±5.25, ±1.75. Index 0 is the far
	# RIGHT lane, at the greatest offset.
	var want := PackedFloat32Array([5.25, 1.75, -1.75, -5.25])
	var placed := lanes.size() == 4
	for i in mini(lanes.size(), 4):
		if absf(float(lanes[i]["offset"]) - want[i]) > 1e-4:
			placed = false
	var abutting := true
	for i in range(1, lanes.size()):
		if absf(float(lanes[i - 1]["left_edge"]) - float(lanes[i]["right_edge"])) > 1e-5:
			abutting = false
	var spans: bool = absf(float(lanes[0]["right_edge"]) - 7.0) < 1e-5 			and absf(float(lanes[3]["left_edge"]) + 7.0) < 1e-5
	_check("A", placed and abutting and spans,
			"centres %s (want +5.25 +1.75 -1.75 -5.25); edges %s; span %.2f..%.2f (want 7.00..-7.00)" % [
				"correct" if placed else "WRONG", "abut" if abutting else "DO NOT ABUT",
				float(lanes[0]["right_edge"]), float(lanes[3]["left_edge"])])

	# CONTROL: a different width must move every number. Without this, [A] would pass on a kernel that
	# returned the 3.5 m answer for any input.
	var wide := Pasture3DRoadLanes.cross_section(4, 5.0, false, false)
	var moved: bool = absf(float(wide[0]["offset"]) - 7.5) < 1e-4 and absf(float(wide[0]["right_edge"]) - 10.0) < 1e-4
	print("    control: 4 lanes at 5.0 m -> outermost centre %.2f (want 7.50), edge %.2f (want 10.00)"
			% [float(wide[0]["offset"]), float(wide[0]["right_edge"])])
	if not moved:
		_fail += 1; print("    !! lane width does not move the cross-section")


# ---- B ------------------------------------------------------------------------------------------

## [B] Which lanes are oncoming is decided by `traffic_side`, and it is decided the RIGHT way round.
##
## The sign convention is the grader's — positive offset is LEFT of increasing arc length — so in
## right-hand traffic the forward lanes are the NEGATIVE ones. Getting this backwards is invisible in
## the geometry (the lanes still tile) and wrong in every connector, so it is asserted on the sign
## rather than on a count.
func _b_traffic_side_decides_which_lanes_are_oncoming() -> void:
	print("[B] traffic side puts forward traffic on the correct side, in WORLD space")
	# A road heading +X. Left of it is UP × heading — Godot's own axes, computed here with Vector3 so
	# the check cannot inherit the 2D convention it is testing. THIS IS THE CRITERION THAT WAS MISSING:
	# every earlier assertion compared the kernel against a fixture written in the same convention, so
	# an inverted left/right was invisible until a stop line appeared on the wrong side in the editor.
	var heading := Vector3(1.0, 0.0, 0.0)
	var world_left := Vector3.UP.cross(heading).normalized()
	var t2 := Vector2(heading.x, heading.z)

	var rht := Pasture3DRoadLanes.cross_section(4, 3.5, false, false)
	var lht := Pasture3DRoadLanes.cross_section(4, 3.5, false, true)
	print("    right-hand: %s" % _offsets(rht))
	print("    left-hand:  %s" % _offsets(lht))
	print("    heading %s -> world left is %s" % [heading, world_left])

	var rht_ok := true
	for l: Dictionary in rht:
		var at := Pasture3DRoadLanes.lane_point(Vector2.ZERO, t2, float(l["offset"]))
		# Positive along world_left means the lane sits on the LEFT of the heading. Drive on the right,
		# and every forward lane must be on the right — so this projection must be negative for them.
		var on_left := Vector3(at.x, 0.0, at.y).dot(world_left)
		if (on_left < 0.0) != (int(l["direction"]) == Pasture3DRoadLanes.FORWARD):
			rht_ok = false
	var lht_ok := true
	for l: Dictionary in lht:
		var at := Pasture3DRoadLanes.lane_point(Vector2.ZERO, t2, float(l["offset"]))
		var on_left := Vector3(at.x, 0.0, at.y).dot(world_left)
		if (on_left > 0.0) != (int(l["direction"]) == Pasture3DRoadLanes.FORWARD):
			lht_ok = false
	# CONTROL: the two worlds must actually DIFFER, or a kernel ignoring the flag could satisfy one of
	# the checks above by accident.
	var mirrored := true
	for i in 4:
		if int(rht[i]["direction"]) != -int(lht[i]["direction"]):
			mirrored = false
	_check("B", rht_ok and lht_ok and mirrored,
			"right-hand forward lanes are %s; left-hand %s; the two are %s" % [
				"on the world right" if rht_ok else "ON THE WRONG SIDE",
				"on the world left" if lht_ok else "ON THE WRONG SIDE",
				"mirrored" if mirrored else "IDENTICAL (the flag does nothing)"])

	# The innermost lane of each direction is the one against the divider, whichever side that is.
	var inner_f: Array = Pasture3DRoadLanes.lanes_in(rht, Pasture3DRoadLanes.FORWARD)
	var inner_b: Array = Pasture3DRoadLanes.lanes_in(rht, Pasture3DRoadLanes.BACKWARD)
	print("    ordinal 0 of each direction: forward %+.2f, backward %+.2f (want +1.75, -1.75)"
			% [float(inner_f[0]["offset"]), float(inner_b[0]["offset"])])
	if absf(float(inner_f[0]["offset"]) - 1.75) > 1e-4 or absf(float(inner_b[0]["offset"]) + 1.75) > 1e-4:
		_fail += 1; print("    !! ordinal 0 is not the lane against the divider")


# ---- C ------------------------------------------------------------------------------------------

## [C] A one-way road has no oncoming lanes, and an odd two-way count splits by the documented rule.
func _c_a_one_way_road_has_no_oncoming_lanes() -> void:
	print("[C] a one-way road is entirely forward; an odd count gives the extra lane to forward")
	var one := Pasture3DRoadLanes.cross_section(3, 3.5, true, false)
	var back := Pasture3DRoadLanes.lanes_in(one, Pasture3DRoadLanes.BACKWARD)
	print("    3 lanes one-way: %s -> %d oncoming (want 0)" % [_offsets(one), back.size()])
	if back.size() != 0:
		_fail += 1; print("    !! a one-way road has oncoming lanes")

	# CONTROL: the SAME three lanes two-way do have oncoming ones, 2 forward and 1 against — so [C] is
	# measuring the one-way flag rather than a fixture with nothing to find.
	var two := Pasture3DRoadLanes.cross_section(3, 3.5, false, false)
	var f := Pasture3DRoadLanes.lanes_in(two, Pasture3DRoadLanes.FORWARD)
	var b := Pasture3DRoadLanes.lanes_in(two, Pasture3DRoadLanes.BACKWARD)
	print("    control: the same 3 lanes two-way: %s -> %d forward, %d oncoming (want 2, 1)"
			% [_offsets(two), f.size(), b.size()])
	_check("C", back.size() == 0 and f.size() == 2 and b.size() == 1,
			"one-way %d oncoming; two-way %d/%d" % [back.size(), f.size(), b.size()])


# ---- D ------------------------------------------------------------------------------------------

## [D] An across-distance finds exactly one lane — the query behind `locate()`'s lane answer. The
## interesting inputs are the boundaries: a vehicle exactly on a lane line must be in one lane, not two
## and not none, and a point off the carriageway must be in none.
func _d_an_offset_finds_exactly_one_lane() -> void:
	print("[D] an offset finds exactly one lane, boundaries included")
	var lanes := Pasture3DRoadLanes.cross_section(4, 3.5, false, false)
	var probes := PackedFloat32Array([6.99, 5.25, 3.5, 0.0, -3.5, -6.99, -7.0])
	var want := PackedInt32Array([0, 0, 1, 2, 3, 3, 3])
	var ok := true
	var report := PackedStringArray()
	for i in probes.size():
		var l := Pasture3DRoadLanes.lane_at_offset(lanes, probes[i])
		var got: int = int(l["index"]) if not l.is_empty() else -1
		report.append("%+.2f→%s" % [probes[i], "none" if got < 0 else str(got)])
		if got != want[i]:
			ok = false
	print("    %s (want %s)" % [" ".join(report), " ".join(PackedStringArray(Array(want).map(func(v): return str(v))))])

	# Every lane line hit exactly once across the whole carriageway: no offset lands in two lanes.
	var doubled := 0
	for i in probes.size():
		var hits := 0
		for l: Dictionary in lanes:
			if probes[i] <= float(l["left_edge"]) and probes[i] > float(l["right_edge"]):
				hits += 1
		if hits > 1:
			doubled += 1

	# CONTROL: off the carriageway is NOT a lane. A query that clamped would answer "lane 0" for a
	# vehicle in the field, which is worse than answering nothing.
	var off_l := Pasture3DRoadLanes.lane_at_offset(lanes, 9.0)
	var off_r := Pasture3DRoadLanes.lane_at_offset(lanes, -9.0)
	print("    control: +9.00 -> %s, -9.00 -> %s (want none, none)"
			% ["none" if off_l.is_empty() else str(off_l["index"]),
			"none" if off_r.is_empty() else str(off_r["index"])])
	_check("D", ok and doubled == 0 and off_l.is_empty() and off_r.is_empty(),
			"%s; %d offset(s) in two lanes; off-carriageway %s" % [
				"boundaries correct" if ok else "WRONG LANE AT A BOUNDARY", doubled,
				"unclaimed" if off_l.is_empty() and off_r.is_empty() else "CLAMPED INTO A LANE"])


# ---- fixtures for the lane graph -----------------------------------------------------------------

const Conn: GDScript = preload("res://addons/pasture_3d/roads/pasture3d_road_lane_connector.gd")


## The four arms of a square crossroads: an east-west road and a north-south one, each trimmed back
## `p_trim` metres from the origin, each `p_lanes` lanes wide.
##
## Arm headings are written out rather than derived, so the fixture cannot agree with the code under
## test by sharing its arithmetic.
func _crossroads_arms(p_trim: float = 8.0, p_lanes: int = 2, p_left_hand: bool = false) -> Array:
	var lanes := Pasture3DRoadLanes.cross_section(p_lanes, 3.5, false, p_left_hand)
	return [
		# The EW road runs +X. Its BEFORE end is on the west side, its AFTER end on the east.
		{"key": "ew", "end": Conn.End.BEFORE, "point": Vector2(-p_trim, 0.0), "y": 0.0,
			"tangent": Vector2(1.0, 0.0), "lanes": lanes},
		{"key": "ew", "end": Conn.End.AFTER, "point": Vector2(p_trim, 0.0), "y": 0.0,
			"tangent": Vector2(1.0, 0.0), "lanes": lanes},
		# The NS road runs +Z.
		{"key": "ns", "end": Conn.End.BEFORE, "point": Vector2(0.0, -p_trim), "y": 0.0,
			"tangent": Vector2(0.0, 1.0), "lanes": lanes},
		{"key": "ns", "end": Conn.End.AFTER, "point": Vector2(0.0, p_trim), "y": 0.0,
			"tangent": Vector2(0.0, 1.0), "lanes": lanes},
	]


func _turn_name(p_turn: int) -> String:
	return ["straight", "left", "right", "U-turn"][p_turn]


# ---- E ------------------------------------------------------------------------------------------

## [E] Every incoming lane reaches a legal outgoing lane on every OTHER arm, and none on its own. On a
## two-lane crossroads that is four incoming lanes with exactly three connectors each — one straight,
## one left, one right — and the completeness half of the P4b bar: a consumer holding any lane has
## somewhere legal to go.
func _e_every_incoming_lane_reaches_every_other_arm() -> void:
	print("[E] every incoming lane reaches every other arm — one straight, one left, one right")
	var res := Pasture3DRoadLaneSolver.solve(_crossroads_arms())
	var connectors: Array = res["connectors"]
	var per_lane := {}
	var kinds := {}
	var same_arm := 0
	for c: Pasture3DRoadLaneConnector in connectors:
		var from_id := "%s:%d:%d" % [c.from_key, c.from_lane, c.from_end]
		per_lane[from_id] = int(per_lane.get(from_id, 0)) + 1
		kinds[from_id] = String(kinds.get(from_id, "")) + _turn_name(c.turn).substr(0, 1)
		if c.from_key == c.to_key and c.from_end == c.to_end:
			same_arm += 1
	var complete := per_lane.size() == 4
	for k in per_lane:
		if int(per_lane[k]) != 3:
			complete = false
	var one_of_each := true
	for k in kinds:
		var kind_str: String = String(kinds[k])
		if kind_str.count("s") != 1 or kind_str.count("l") != 1 or kind_str.count("r") != 1:
			one_of_each = false
	print("    %d connectors from %d incoming lanes: %s" % [connectors.size(), per_lane.size(), kinds])
	_check("E", connectors.size() == 12 and complete and one_of_each and same_arm == 0,
			"%d connectors (want 12); every lane %s; turn kinds %s; %d U-turns (want 0)" % [
				connectors.size(), "has 3" if complete else "DOES NOT HAVE 3",
				"one of each" if one_of_each else "WRONG", same_arm])

	# CONTROL: forbidding one turn removes exactly that connector from the legal set and leaves the
	# other eleven alone — the wording the phase table sets for this gate.
	var target: Pasture3DRoadLaneConnector = connectors[0]
	target.allowed_override = Conn.Tri.OFF
	var legal := 0
	for c: Pasture3DRoadLaneConnector in connectors:
		if c.allowed():
			legal += 1
	print("    control: forbidding %s -> %d of %d connectors legal (want 11 of 12)"
			% [target.id, legal, connectors.size()])
	if legal != 11:
		_fail += 1; print("    !! forbidding one turn did not remove exactly one connector")


# ---- F ------------------------------------------------------------------------------------------

## [F] A connector leaves along its incoming lane's heading and arrives along its outgoing lane's, so a
## vehicle handing over between the two never has to turn instantaneously. Measured on the CURVE — the
## direction it actually starts and ends in — rather than on the control points that were set from the
## headings, which would only be checking that an assignment happened.
func _f_a_connector_is_tangent_continuous_with_its_lanes() -> void:
	print("[F] a connector is tangent-continuous with the lanes it joins")
	var arms := _crossroads_arms()
	var res := Pasture3DRoadLaneSolver.solve(arms)
	var connectors: Array = res["connectors"]
	var worst_in := 0.0
	var worst_out := 0.0
	var turned := 0
	for c: Pasture3DRoadLaneConnector in connectors:
		var curve: Curve3D = c.curve
		var l := curve.get_baked_length()
		var start_dir := (curve.sample_baked(l * 0.02) - curve.sample_baked(0.0)).normalized()
		var end_dir := (curve.sample_baked(l) - curve.sample_baked(l * 0.98)).normalized()
		var want_in := _heading_of(arms, c.from_key, c.from_end, c.from_lane)
		var want_out := _heading_of(arms, c.to_key, c.to_end, c.to_lane)
		worst_in = maxf(worst_in, absf(rad_to_deg(Vector2(start_dir.x, start_dir.z).angle_to(want_in))))
		worst_out = maxf(worst_out, absf(rad_to_deg(Vector2(end_dir.x, end_dir.z).angle_to(want_out))))
		if start_dir.distance_to(end_dir) > 0.1:
			turned += 1
	# CONTROL: some of these connectors must actually TURN. If every start and end direction were the
	# same, tangent continuity would be the trivial statement that a straight line is straight.
	print("    worst entry error %.3f°, worst exit error %.3f°; %d of %d connectors change direction"
			% [worst_in, worst_out, turned, connectors.size()])
	_check("F", worst_in < 1.0 and worst_out < 1.0 and turned >= 8,
			"entry %.3f° and exit %.3f° off (want < 1°); %d connectors turn (want >= 8)" % [
				worst_in, worst_out, turned])


## The direction of travel of one lane at one arm, recovered from the fixture rather than from the
## solver, so [F] compares the curve against the arms it was built from.
func _heading_of(p_arms: Array, p_key: String, p_end: int, p_lane: int) -> Vector2:
	for arm: Dictionary in p_arms:
		if String(arm["key"]) != p_key or int(arm["end"]) != p_end:
			continue
		var t: Vector2 = (arm["tangent"] as Vector2).normalized()
		for l: Dictionary in arm["lanes"]:
			if int(l["index"]) == p_lane:
				return t if int(l["direction"]) == Pasture3DRoadLanes.FORWARD else -t
	return Vector2.RIGHT


# ---- G ------------------------------------------------------------------------------------------

## [G] Traffic side decides which turn crosses oncoming traffic. The turn KIND is geometry and does not
## change with handedness — there is a left turn and a right turn either way — so the assertion is on
## `crosses_oncoming`, which is the fact a consumer cannot derive for itself.
func _g_traffic_side_decides_which_turn_crosses_traffic() -> void:
	print("[G] traffic side decides which turn crosses oncoming traffic")
	var rht: Array = Pasture3DRoadLaneSolver.solve(_crossroads_arms(8.0, 2, false), [],
			{"left_hand": false})["connectors"]
	var lht: Array = Pasture3DRoadLaneSolver.solve(_crossroads_arms(8.0, 2, true), [],
			{"left_hand": true})["connectors"]
	var rht_bad := 0
	var rht_n := 0
	for c: Pasture3DRoadLaneConnector in rht:
		if c.crosses_oncoming != (c.turn == Conn.Turn.LEFT):
			rht_bad += 1
		if c.crosses_oncoming:
			rht_n += 1
	var lht_bad := 0
	var lht_n := 0
	for c: Pasture3DRoadLaneConnector in lht:
		if c.crosses_oncoming != (c.turn == Conn.Turn.RIGHT):
			lht_bad += 1
		if c.crosses_oncoming:
			lht_n += 1
	# CONTROL: both worlds have the SAME number of conflicted turns — one per incoming lane — so the
	# flag is moving which turns are marked rather than how many, which is what would happen if it were
	# quietly disabling the whole test.
	print("    right-hand: %d conflicted turns, all left? %s; left-hand: %d, all right? %s"
			% [rht_n, rht_bad == 0, lht_n, lht_bad == 0])
	_check("G", rht_bad == 0 and lht_bad == 0 and rht_n == 4 and lht_n == 4,
			"%d/%d misflagged; %d and %d conflicted turns (want 0/0 and 4/4)" % [
				rht_bad, lht_bad, rht_n, lht_n])


# ---- H ------------------------------------------------------------------------------------------

## [H] Every incoming lane has a stop line, no outgoing lane has one, and each sits at the head of its
## own lane on the footprint boundary — the arc length the trim-back put it at, offset to the lane
## centre. A consumer that has to solve for this is doing geometry the data should have carried.
func _h_every_incoming_lane_has_a_stop_line_at_the_footprint() -> void:
	print("[H] every incoming lane has a stop line at the footprint boundary")
	var res := Pasture3DRoadLaneSolver.solve(_crossroads_arms(8.0))
	var lines: Array = res["stop_lines"]
	var seen := {}
	var worst_r := 0.0
	var facing_in := 0
	for sl: Pasture3DRoadStopLine in lines:
		seen["%s:%d:%d" % [sl.road_key, sl.lane, sl.end]] = true
		var here := Vector2(sl.point.x, sl.point.z)
		worst_r = maxf(worst_r, here.length())
		# The heading must point INTO the junction: the vehicle is about to enter, so travelling along
		# it from the stop line decreases the distance to the centre.
		if (here + sl.heading * 0.5).length() < here.length():
			facing_in += 1
	# On this fixture the lane centres sit 1.75 m off the axis at 8 m out, so the furthest stop line is
	# sqrt(8² + 1.75²) = 8.189 m from the centre — written out rather than computed the same way twice.
	var want_r := 8.189
	print("    %d stop lines for %d distinct incoming lanes; furthest %.3f m from the centre (want %.3f); %d face the junction"
			% [lines.size(), seen.size(), worst_r, want_r, facing_in])
	_check("H", lines.size() == 4 and seen.size() == 4 and absf(worst_r - want_r) < 0.01
			and facing_in == 4,
			"%d lines / %d lanes (want 4/4); radius %.3f; %d facing in (want 4)" % [
				lines.size(), seen.size(), worst_r, facing_in])

	# CONTROL: a wider trim-back moves every stop line out with it. Without this, [H] would pass on a
	# generator that emitted stop lines at the junction centre.
	var wide: Array = Pasture3DRoadLaneSolver.solve(_crossroads_arms(20.0))["stop_lines"]
	var far := 0.0
	for sl: Pasture3DRoadStopLine in wide:
		far = maxf(far, Vector2(sl.point.x, sl.point.z).length())
	print("    control: trim-back 20 m -> furthest stop line %.3f m (want 20.076)" % far)
	if absf(far - 20.076) > 0.01:
		_fail += 1; print("    !! the stop lines do not follow the footprint boundary")


# ---- fixtures for right of way -------------------------------------------------------------------

## The crossroads' connectors, with priorities attached. Returns
## `{connectors, road_keys, priorities}` ready to hand to the right-of-way solver.
func _crossroads_row(p_ew_priority: int = 0, p_ns_priority: int = 0,
		p_left_hand: bool = false) -> Dictionary:
	var res := Pasture3DRoadLaneSolver.solve(_crossroads_arms(8.0, 2, p_left_hand), [],
			{"left_hand": p_left_hand})
	return {
		"connectors": res["connectors"],
		"road_keys": PackedStringArray(["ew", "ns"]),
		"priorities": PackedInt32Array([p_ew_priority, p_ns_priority]),
	}


## The one connector leaving `p_key` at `p_end` by `p_turn`, or null. The fixture has one incoming lane
## per arm, so the triple identifies a movement uniquely.
func _movement(p_connectors: Array, p_key: String, p_end: int, p_turn: int) -> Pasture3DRoadLaneConnector:
	for c: Pasture3DRoadLaneConnector in p_connectors:
		if c.from_key == p_key and c.from_end == p_end and c.turn == p_turn:
			return c
	return null


func _conflict_between(p_conflicts: Array, p_yielding: Pasture3DRoadLaneConnector,
		p_priority: Pasture3DRoadLaneConnector) -> Pasture3DRoadConflict:
	if p_yielding == null or p_priority == null:
		return null
	for r: Pasture3DRoadConflict in p_conflicts:
		if r.yielding_id == p_yielding.id and r.priority_id == p_priority.id:
			return r
	return null


func _reason_name(p_reason: int) -> String:
	return ["PRIORITY", "TURN_ACROSS", "APPROACH_SIDE", "MUTUAL"][clampi(p_reason, 0, 3)]


func _state_name(p_state: int) -> String:
	return {-1: "NONE", 0: "GREEN", 1: "YELLOW", 2: "RED"}.get(p_state, "?")


# ---- I ------------------------------------------------------------------------------------------

## [I] A conflict is emitted where two movements MEET and nowhere else.
##
## This is the criterion that says right of way is geometric rather than tabulated. Two movements that
## leave the same lane are a driver's choice and never a conflict; two that cross the middle of the
## junction always are. A table-driven implementation gets the first of those wrong on any junction it
## did not anticipate, so the pair it must NOT emit is asserted as hard as the pair it must.
func _i_only_movements_that_meet_are_in_conflict() -> void:
	print("[I] a conflict is emitted where two movements meet, and nowhere else")
	var fx := _crossroads_row()
	var conns: Array = fx["connectors"]
	var rows := Pasture3DRoadRightOfWay.conflicts(conns, {"ew": 0, "ns": 0}, false)

	var ew_straight := _movement(conns, "ew", Conn.End.BEFORE, Conn.Turn.STRAIGHT)
	var ns_straight := _movement(conns, "ns", Conn.End.BEFORE, Conn.Turn.STRAIGHT)
	var crossing: bool = _conflict_between(rows, ew_straight, ns_straight) != null \
			or _conflict_between(rows, ns_straight, ew_straight) != null

	# Same origin lane: the two movements a single vehicle chooses between.
	var same_origin := 0
	for r: Pasture3DRoadConflict in rows:
		var y := _by_id(conns, r.yielding_id)
		var w := _by_id(conns, r.priority_id)
		if y != null and w != null and y.from_key == w.from_key and y.from_lane == w.from_lane \
				and y.from_end == w.from_end:
			same_origin += 1
	print("    %d connectors -> %d conflict records; the two straight-aheads %s; %d same-origin pairs (want 0)"
			% [conns.size(), rows.size(), "cross" if crossing else "DO NOT CROSS", same_origin])
	_check("I", crossing and same_origin == 0 and rows.size() > 0,
			"straights %s; %d same-origin records; %d records total" % [
				"conflict" if crossing else "DO NOT CONFLICT", same_origin, rows.size()])

	# CONTROL: forbid every movement and the conflict set must empty. A movement nobody may make
	# conflicts with nothing, and without this the criterion would pass on an implementation that
	# ignored `allowed()` and told a consumer to yield to a banned turn.
	for c: Pasture3DRoadLaneConnector in conns:
		c.allowed_override = Conn.Tri.OFF
	var none := Pasture3DRoadRightOfWay.conflicts(conns, {"ew": 0, "ns": 0}, false)
	print("    control: every turn forbidden -> %d conflicts (want 0)" % none.size())
	if not none.is_empty():
		_fail += 1; print("    !! forbidden movements are still generating yield relations")
	for c: Pasture3DRoadLaneConnector in conns:
		c.allowed_override = Conn.Tri.INHERIT


func _by_id(p_connectors: Array, p_id: StringName) -> Pasture3DRoadLaneConnector:
	for c: Pasture3DRoadLaneConnector in p_connectors:
		if c.id == p_id:
			return c
	return null


# ---- J ------------------------------------------------------------------------------------------

## [J] The road with the higher `priority` has right of way over the one it crosses (§5.2).
func _j_priority_decides_who_gives_way() -> void:
	print("[J] the higher-priority road has right of way")
	var fx := _crossroads_row(10, 1)
	var conns: Array = fx["connectors"]
	var rows := Pasture3DRoadRightOfWay.conflicts(conns, {"ew": 10, "ns": 1}, false)

	# Every conflict BETWEEN the two roads must be yielded by the minor one, for the priority reason.
	var cross_records := 0
	var minor_yields := 0
	var by_priority := 0
	for r: Pasture3DRoadConflict in rows:
		var y := _by_id(conns, r.yielding_id)
		var w := _by_id(conns, r.priority_id)
		if y == null or w == null or y.from_key == w.from_key:
			continue
		cross_records += 1
		if y.from_key == "ns":
			minor_yields += 1
		if r.reason == Pasture3DRoadConflict.Reason.PRIORITY:
			by_priority += 1
	print("    ew=10 ns=1: %d records between the roads, %d yielded by the minor road, %d for PRIORITY"
			% [cross_records, minor_yields, by_priority])
	_check("J", cross_records > 0 and minor_yields == cross_records and by_priority == cross_records,
			"%d of %d between-road records yielded by the minor road; %d cite PRIORITY" % [
				minor_yields, cross_records, by_priority])

	# CONTROL: swap the priorities and every one of those must reverse. Without it the criterion passes
	# on an implementation that always yields whichever road the solver walked second.
	var swapped := Pasture3DRoadRightOfWay.conflicts(conns, {"ew": 1, "ns": 10}, false)
	var ew_yields := 0
	var between := 0
	for r: Pasture3DRoadConflict in swapped:
		var y := _by_id(conns, r.yielding_id)
		var w := _by_id(conns, r.priority_id)
		if y == null or w == null or y.from_key == w.from_key:
			continue
		between += 1
		if y.from_key == "ew":
			ew_yields += 1
	print("    control: ew=1 ns=10 -> %d of %d between-road records now yielded by ew" % [ew_yields, between])
	if between == 0 or ew_yields != between:
		_fail += 1; print("    !! swapping priority did not reverse right of way")


# ---- K ------------------------------------------------------------------------------------------

## [K] At equal priority, the movement that cuts across the oncoming carriageway gives way to the one
## it cuts across — and which movement that is follows `traffic_side`.
##
## The permissive turn. No per-road rule can see it: both movements are on the SAME road, at the same
## priority, and one of them still has to wait.
func _k_a_turn_across_oncoming_yields_to_the_traffic_it_crosses() -> void:
	print("[K] the turn across oncoming traffic yields to it")
	var fx := _crossroads_row(5, 5)
	var conns: Array = fx["connectors"]
	var rows := Pasture3DRoadRightOfWay.conflicts(conns, {"ew": 5, "ns": 5}, false)

	# Driving on the right, the LEFT turn is the one that crosses. It meets the straight-ahead coming
	# the other way along the same road — from the AFTER end, travelling back toward the BEFORE end.
	var turn := _movement(conns, "ew", Conn.End.BEFORE, Conn.Turn.LEFT)
	var oncoming := _movement(conns, "ew", Conn.End.AFTER, Conn.Turn.STRAIGHT)
	var rec := _conflict_between(rows, turn, oncoming)
	var wrong_way := _conflict_between(rows, oncoming, turn)
	print("    ew left turn crosses_oncoming=%s; conflict with the oncoming straight: %s"
			% ["yes" if turn != null and turn.crosses_oncoming else "NO",
				_reason_name(rec.reason) if rec != null else "MISSING"])
	_check("K", turn != null and turn.crosses_oncoming and rec != null
			and rec.reason == Pasture3DRoadConflict.Reason.TURN_ACROSS and wrong_way == null,
			"%s; %s; the reverse relation is %s" % [
				"the turn yields" if rec != null else "NO RELATION between the two",
				_reason_name(rec.reason) if rec != null else "-",
				"absent" if wrong_way == null else "ALSO PRESENT (both are yielding)"])

	# CONTROL: drive on the left and it must be the RIGHT turn that gives way instead. Without this the
	# criterion passes on an implementation that hard-codes "left turns yield".
	var lfx := _crossroads_row(5, 5, true)
	var lconns: Array = lfx["connectors"]
	var lrows := Pasture3DRoadRightOfWay.conflicts(lconns, {"ew": 5, "ns": 5}, true)
	var lturn := _movement(lconns, "ew", Conn.End.BEFORE, Conn.Turn.RIGHT)
	var lonc := _movement(lconns, "ew", Conn.End.AFTER, Conn.Turn.STRAIGHT)
	var lrec := _conflict_between(lrows, lturn, lonc)
	print("    control: left-hand traffic -> the RIGHT turn yields: %s"
			% ["yes (%s)" % _reason_name(lrec.reason) if lrec != null else "NO"])
	if lrec == null or lrec.reason != Pasture3DRoadConflict.Reason.TURN_ACROSS:
		_fail += 1; print("    !! traffic side does not decide which turn gives way")


# ---- L ------------------------------------------------------------------------------------------

## [L] At equal priority with neither movement crossing oncoming traffic, give way to the vehicle
## approaching from the side the world's handedness names — and the handedness decides which side.
func _l_equal_priority_gives_way_to_the_priority_side() -> void:
	print("[L] equal priority gives way to the vehicle on the priority side")
	var fx := _crossroads_row(5, 5)
	var conns: Array = fx["connectors"]
	var rows := Pasture3DRoadRightOfWay.conflicts(conns, {"ew": 5, "ns": 5}, false)
	var ew := _movement(conns, "ew", Conn.End.BEFORE, Conn.Turn.STRAIGHT)
	var ns := _movement(conns, "ns", Conn.End.BEFORE, Conn.Turn.STRAIGHT)
	# The EW movement heads +X; the NS movement approaches it from -Z... which under this world's
	# convention — positive across-distance is the driver's right — is the LEFT of a +X heading. So
	# driving on the right, the NS driver has the EW car on THEIR right and gives way.
	var ns_gives := _conflict_between(rows, ns, ew)
	var ew_gives := _conflict_between(rows, ew, ns)
	print("    right-hand: ns->ew %s, ew->ns %s" % [
			_reason_name(ns_gives.reason) if ns_gives != null else "none",
			_reason_name(ew_gives.reason) if ew_gives != null else "none"])
	var one_way_only: bool = (ns_gives == null) != (ew_gives == null)
	var by_side: bool = (ns_gives != null and ns_gives.reason == Pasture3DRoadConflict.Reason.APPROACH_SIDE) \
			or (ew_gives != null and ew_gives.reason == Pasture3DRoadConflict.Reason.APPROACH_SIDE)
	_check("L", one_way_only and by_side,
			"exactly one of the pair gives way: %s; by APPROACH_SIDE: %s" % [
				"yes" if one_way_only else "NO (both or neither)", "yes" if by_side else "NO"])

	# CONTROL: flip the world's handedness and the same pair must reverse. This is the only rule in the
	# set whose answer is pure handedness, so if `left_hand` were ignored here nothing else would say so.
	var flipped := Pasture3DRoadRightOfWay.conflicts(conns, {"ew": 5, "ns": 5}, true)
	var ns_gives_l := _conflict_between(flipped, ns, ew)
	var ew_gives_l := _conflict_between(flipped, ew, ns)
	var reversed: bool = (ns_gives != null) == (ew_gives_l != null) \
			and (ew_gives != null) == (ns_gives_l != null)
	print("    control: left-hand -> ns->ew %s, ew->ns %s (want the pair reversed)" % [
			"yes" if ns_gives_l != null else "no", "yes" if ew_gives_l != null else "no"])
	if not reversed:
		_fail += 1; print("    !! traffic side does not decide which approach side gives way")


# ---- M ------------------------------------------------------------------------------------------

## [M] Signal phases: one per participating road, green time from priority, and a floor under it.
##
## §6.4 says the higher-priority road gets the longer green. The floor is the part that is easy to leave
## out and painful to discover: a priority-1 road opposite a priority-100 road would otherwise get a
## green under a second, which is not a timing bug so much as a road nobody can ever leave.
func _m_phases_are_one_per_road_with_green_from_priority() -> void:
	print("[M] one phase per road, with the longer green on the higher priority")
	var keys := PackedStringArray(["ew", "ns"])
	var phases := Pasture3DRoadRightOfWay.phases(keys, PackedInt32Array([10, 1]), 60.0, 3.0)
	var names := PackedStringArray()
	for ph: Pasture3DRoadPhase in phases:
		names.append("%s %.1fs+%.1f" % [ph.road_keys[0], ph.green_time, ph.yellow_time])
	print("    ew=10 ns=1, cycle 60 yellow 3: %s" % " | ".join(names))
	# Green budget is 60 - 2x3 = 54; the shares are 10:1 over priorities shifted to start at 1, so ew
	# takes 54 x 10/11 = 49.09 and ns would take 4.91 — below the 6 s floor, so it is lifted to 6.
	var ok: bool = phases.size() == 2 and phases[0].road_keys[0] == "ew" \
			and absf(phases[0].green_time - 49.09) < 0.05 \
			and absf(phases[1].green_time - Pasture3DRoadRightOfWay.MIN_GREEN) < 0.01
	_check("M", ok, "%d phases; first is %s at %.2f s (want ew at 49.09); second %.2f s (want the %.1f s floor)" % [
			phases.size(), phases[0].road_keys[0] if not phases.is_empty() else "-",
			phases[0].green_time if not phases.is_empty() else NAN,
			phases[1].green_time if phases.size() > 1 else NAN, Pasture3DRoadRightOfWay.MIN_GREEN])

	# CONTROL: equal priority must give equal greens. Without it the criterion would pass on an
	# implementation that simply gave the first road the larger share.
	var even := Pasture3DRoadRightOfWay.phases(keys, PackedInt32Array([5, 5]), 60.0, 3.0)
	var same: bool = even.size() == 2 and absf(even[0].green_time - even[1].green_time) < 0.01 \
			and absf(even[0].green_time - 27.0) < 0.05
	print("    control: ew=5 ns=5 -> %.2f s and %.2f s (want 27.00 each)"
			% [even[0].green_time, even[1].green_time])
	if not same:
		_fail += 1; print("    !! green time does not follow priority")


# ---- N ------------------------------------------------------------------------------------------

## [N] A signalised junction cycles, publishes a state per road, and says NONE when it is not signalised.
##
## NONE is the clause that matters. A junction that is not signalised must not answer GREEN: a naive
## consumer reading a green light would drive through an uncontrolled crossroads without ever consulting
## the yield relations, which is the one failure mode this whole query exists to prevent.
func _n_a_signalised_junction_cycles_and_publishes_its_state() -> void:
	print("[N] a signalised junction cycles, and an unsignalised one says NONE")
	var j := Pasture3DRoadJunction.new()
	j.road_keys = PackedStringArray(["ew", "ns"])
	j.priorities = PackedInt32Array([5, 5])
	j.phases = _typed_phases(Pasture3DRoadRightOfWay.phases(j.road_keys, j.priorities, 60.0, 3.0))
	j.control = Pasture3DRoadJunction.ControlType.SIGNALS

	# Phase 0 is ew: 27 s of green then 3 s of yellow, while ns is red throughout.
	var samples := PackedFloat32Array([0.0, 26.0, 28.0, 31.0, 56.0, 58.0])
	var t := 0.0
	var ew_states := PackedStringArray()
	var ns_states := PackedStringArray()
	for want_t: float in samples:
		j.advance_signals(want_t - t)
		t = want_t
		ew_states.append(_state_name(j.signal_state("ew")))
		ns_states.append(_state_name(j.signal_state("ns")))
	var stamps := PackedStringArray()
	for x: float in samples:
		stamps.append("%.0f" % x)
	print("    t = %s" % ", ".join(stamps))
	print("    ew: %s" % ", ".join(ew_states))
	print("    ns: %s" % ", ".join(ns_states))
	var want_ew := PackedStringArray(["GREEN", "GREEN", "YELLOW", "RED", "RED", "RED"])
	var want_ns := PackedStringArray(["RED", "RED", "RED", "GREEN", "GREEN", "YELLOW"])
	var cycles: bool = ew_states == want_ew and ns_states == want_ns
	# The two roads must never be green together — the property the phases exist for, asserted rather
	# than assumed from the state strings above.
	var both_green := false
	for i in ew_states.size():
		if ew_states[i] == "GREEN" and ns_states[i] == "GREEN":
			both_green = true

	# A remaining time that counts down and stays positive is what a consumer decides on a yellow with.
	var remaining := j.signal_time_remaining("ew")
	var not_signalised := Pasture3DRoadJunction.new()
	not_signalised.road_keys = j.road_keys
	not_signalised.phases = j.phases
	not_signalised.control = Pasture3DRoadJunction.ControlType.INHERIT
	var none_state := not_signalised.signal_state("ew", Pasture3DRoadJunction.ControlType.PRIORITY)
	print("    ew time remaining at t=58: %.1f s; an unsignalised junction reports %s"
			% [remaining, _state_name(none_state)])
	_check("N", cycles and not both_green and remaining > 0.0
			and none_state == Pasture3DRoadPhase.State.NONE,
			"cycle %s; both green at once: %s; remaining %.1f; unsignalised says %s (want NONE)" % [
				"correct" if cycles else "WRONG", "YES" if both_green else "no", remaining,
				_state_name(none_state)])

	# CONTROL: a junction that is never advanced must never change. Without this the criterion could
	# pass on an implementation that derived the phase from the wall clock, which would cycle whether
	# or not the game was running and could not be reset or paused.
	var frozen := Pasture3DRoadJunction.new()
	frozen.road_keys = j.road_keys
	frozen.phases = j.phases
	frozen.control = Pasture3DRoadJunction.ControlType.SIGNALS
	var first := frozen.signal_state("ew")
	OS.delay_msec(20)
	var later := frozen.signal_state("ew")
	print("    control: never advanced -> %s then %s (want both GREEN)"
			% [_state_name(first), _state_name(later)])
	if first != later or first != Pasture3DRoadPhase.State.GREEN:
		_fail += 1; print("    !! the phase advances without anyone advancing it")


func _typed_phases(p_in: Array) -> Array[Pasture3DRoadPhase]:
	var out: Array[Pasture3DRoadPhase] = []
	for ph in p_in:
		if ph is Pasture3DRoadPhase:
			out.append(ph)
	return out
