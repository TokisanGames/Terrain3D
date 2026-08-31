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
	# 4 × 3.5 = 14 m, so the edges are ±7 and the lane centres are ±5.25, ±1.75.
	var want := PackedFloat32Array([5.25, 1.75, -1.75, -5.25])
	var placed := lanes.size() == 4
	for i in mini(lanes.size(), 4):
		if absf(float(lanes[i]["offset"]) - want[i]) > 1e-4:
			placed = false
	var abutting := true
	for i in range(1, lanes.size()):
		if absf(float(lanes[i - 1]["right_edge"]) - float(lanes[i]["left_edge"])) > 1e-5:
			abutting = false
	var spans: bool = absf(float(lanes[0]["left_edge"]) - 7.0) < 1e-5 \
			and absf(float(lanes[3]["right_edge"]) + 7.0) < 1e-5
	_check("A", placed and abutting and spans,
			"centres %s (want +5.25 +1.75 -1.75 -5.25); edges %s; span %.2f..%.2f (want 7.00..-7.00)" % [
				"correct" if placed else "WRONG", "abut" if abutting else "DO NOT ABUT",
				float(lanes[0]["left_edge"]), float(lanes[3]["right_edge"])])

	# CONTROL: a different width must move every number. Without this, [A] would pass on a kernel that
	# returned the 3.5 m answer for any input.
	var wide := Pasture3DRoadLanes.cross_section(4, 5.0, false, false)
	var moved: bool = absf(float(wide[0]["offset"]) - 7.5) < 1e-4 and absf(float(wide[0]["left_edge"]) - 10.0) < 1e-4
	print("    control: 4 lanes at 5.0 m -> outermost centre %.2f (want 7.50), edge %.2f (want 10.00)"
			% [float(wide[0]["offset"]), float(wide[0]["left_edge"])])
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
	print("[B] traffic side decides which lanes are oncoming")
	var rht := Pasture3DRoadLanes.cross_section(4, 3.5, false, false)
	var lht := Pasture3DRoadLanes.cross_section(4, 3.5, false, true)
	print("    right-hand: %s" % _offsets(rht))
	print("    left-hand:  %s" % _offsets(lht))
	var rht_ok := true
	for l: Dictionary in rht:
		# Drive on the right => forward lanes sit right of the centreline => negative offset.
		if (float(l["offset"]) < 0.0) != (int(l["direction"]) == Pasture3DRoadLanes.FORWARD):
			rht_ok = false
	var lht_ok := true
	for l: Dictionary in lht:
		if (float(l["offset"]) > 0.0) != (int(l["direction"]) == Pasture3DRoadLanes.FORWARD):
			lht_ok = false
	# CONTROL: the two must actually DIFFER. A kernel that ignored the flag would satisfy neither check
	# above only if the sign test is real — so assert the mirror directly.
	var mirrored := true
	for i in 4:
		if int(rht[i]["direction"]) != -int(lht[i]["direction"]):
			mirrored = false
	_check("B", rht_ok and lht_ok and mirrored,
			"right-hand forward lanes are %s; left-hand %s; the two are %s" % [
				"right of centre" if rht_ok else "ON THE WRONG SIDE",
				"left of centre" if lht_ok else "ON THE WRONG SIDE",
				"mirrored" if mirrored else "IDENTICAL (the flag does nothing)"])

	# The innermost lane of each direction is the one against the divider, whichever side that is.
	var inner_f: Array = Pasture3DRoadLanes.lanes_in(rht, Pasture3DRoadLanes.FORWARD)
	var inner_b: Array = Pasture3DRoadLanes.lanes_in(rht, Pasture3DRoadLanes.BACKWARD)
	print("    ordinal 0 of each direction: forward %+.2f, backward %+.2f (want -1.75, +1.75)"
			% [float(inner_f[0]["offset"]), float(inner_b[0]["offset"])])
	if absf(float(inner_f[0]["offset"]) + 1.75) > 1e-4 or absf(float(inner_b[0]["offset"]) - 1.75) > 1e-4:
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
