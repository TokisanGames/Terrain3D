# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadLanes — where the lanes are across a road, and which way each one runs.
# See PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §6.4.
#
# ---- THIS IS THE BOTTOM OF P4b, AND EVERYTHING ELSE IS BUILT ON IT ----
#
# A connector joins two lanes. A stop line sits at the head of a lane. A yield relationship is between
# the vehicles in two lanes. So if "which lane is this and which way does it point" is wrong, every
# other answer P4b gives is wrong in a way that looks like a junction bug. It is a closed-form function
# of four numbers, so it is written once, here, and gated on its own.
#
# ---- THE SIGN CONVENTION IS THE GRADER'S, AND IT IS RIGHT-POSITIVE ----
#
# `offset` is the same signed across-distance `u` that Pasture3DRoadGrader crowns and banks with, so a
# lane centre can be fed straight to the grader's surface equation to get the height of that lane, and
# left and right are decided in exactly one place in the road system.
#
# POSITIVE IS THE DRIVER'S RIGHT. That is not a preference, it is what the code computes, and it was
# documented backwards until an inverted stop line in the editor made someone check. The derivation, in
# Godot's own axes: the plane is 2D (x, y) mapped to world (x, z); left of a heading h is UP x h; for
# h = +X that is Y x X = -(X x Y) = -Z. The grader's `side` — the 2D cross of the travel direction with
# the offset — is +1 at +Z for a +X heading, which is the RIGHT. Everything downstream (which lanes are
# oncoming, which way a turn goes, which side of a corner is banked up) follows from this one sign, so
# it is derived here rather than assumed anywhere.
#
# ---- TRAFFIC SIDE IS A WORLD CONSTANT (§6.4) ----
#
# Which side traffic drives on decides lane ordering, which turn crosses oncoming traffic, and which way
# a connector curves. It lives on Pasture3DRoadNetwork with no per-brush override, so it arrives here as
# a plain bool rather than being resolved per road: mixed handedness inside one world is a bug, and a
# kernel that could express it would make that bug representable.
@tool
class_name Pasture3DRoadLanes
extends RefCounted

## Travelling with increasing arc length.
const FORWARD: int = 1
## Travelling against it. A two-way road's oncoming lanes; never present on a one-way road.
const BACKWARD: int = -1


## The lanes across one road, RIGHT TO LEFT — `index` 0 is the far right lane, at the greatest `offset`.
##
## Each entry is `{index, ordinal, direction, offset, width, left_edge, right_edge}`:
##   index      — position in the cross-section, 0 at the right edge. Geometric, and independent of which
##                side traffic drives on, so it means the same thing on a road however it is used.
##   ordinal    — position within this lane's OWN direction, 0 nearest the centre of the road and
##                increasing outward. What a driver means by "the inside lane", and what a connector
##                pairs on.
##   direction  — FORWARD or BACKWARD.
##   offset     — lane centre, signed metres, positive RIGHT (the grader's `u`).
##   right_edge — the lane's own edges, same sign convention. `right_edge > left_edge` always, because
##   left_edge    the offsets decrease as the cross-section is walked from the right.
##
## An ODD lane count on a two-way road gives the extra lane to FORWARD. Real roads do this (a 2+1
## climbing lane) and there is no geometric fact that decides it, so it is a documented convention
## rather than a guess: a designer who wants the extra lane the other way makes the road one-way and
## pairs it, or sets the count even and overrides.
static func cross_section(p_lane_count: int, p_lane_width: float, p_one_way: bool,
		p_left_hand: bool) -> Array:
	var out: Array = []
	var n := maxi(p_lane_count, 1)
	var lw := maxf(p_lane_width, 0.1)
	var half := float(n) * lw * 0.5

	var forward := n if p_one_way else int(ceil(float(n) * 0.5))
	var backward := n - forward
	# Which direction occupies the RIGHT of the carriageway — the positive-offset side. Drive on the
	# right and that is the forward direction; drive on the left and it is the oncoming one. On a one-way
	# road there is nothing to be on the other side of, and every lane is forward.
	var right_group := forward if not p_left_hand else backward
	var right_dir := FORWARD if not p_left_hand else BACKWARD

	for i in n:
		var in_right_group := i < right_group
		var direction := right_dir if in_right_group else -right_dir
		if p_one_way:
			direction = FORWARD
		# Ordinal counts from the DIVIDER outward. The right group's innermost lane is its last (nearest
		# the middle of the road); the other group's innermost is its first.
		var ordinal := (right_group - 1 - i) if in_right_group else (i - right_group)
		if p_one_way:
			ordinal = i
		var right_edge := half - float(i) * lw
		out.append({
			"index": i,
			"ordinal": ordinal,
			"direction": direction,
			"offset": right_edge - lw * 0.5,
			"width": lw,
			"right_edge": right_edge,
			"left_edge": right_edge - lw,
		})
	return out


## The lanes running `p_direction` along the road, innermost first (`ordinal` order).
static func lanes_in(p_lanes: Array, p_direction: int) -> Array:
	var out: Array = []
	for l: Dictionary in p_lanes:
		if int(l["direction"]) == p_direction:
			out.append(l)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["ordinal"]) < int(b["ordinal"]))
	return out


## The lane containing across-distance `p_offset`, or {} when it is off the carriageway. The lookup
## behind `locate()`'s lane answer (§9.2): a vehicle's position projects to an offset, and this says
## which lane that is.
static func lane_at_offset(p_lanes: Array, p_offset: float) -> Dictionary:
	for l: Dictionary in p_lanes:
		# Half-open from the right, so a vehicle exactly on a lane line is in the LEFT-hand lane of the
		# two and never in both or neither.
		if p_offset <= float(l["right_edge"]) and p_offset > float(l["left_edge"]):
			return l
	# The left edge of the leftmost lane is the one boundary the half-open rule would exclude.
	if not p_lanes.is_empty():
		var last: Dictionary = p_lanes[p_lanes.size() - 1]
		if is_equal_approx(p_offset, float(last["left_edge"])):
			return last
	return {}


## World XZ of a lane's centreline at a point on the plan, given the direction of travel there.
##
## `p_tangent` is the plan direction at that point (increasing arc length). In the (x, z) plane the
## vector (-y, x) is the driver's RIGHT — see the header derivation — which is what puts a positive
## `offset` on the right.
static func lane_point(p_plan_point: Vector2, p_tangent: Vector2, p_offset: float) -> Vector2:
	var t := p_tangent.normalized()
	if not is_finite(t.x) or not is_finite(t.y) or t == Vector2.ZERO:
		return p_plan_point
	return p_plan_point + Vector2(-t.y, t.x) * p_offset
