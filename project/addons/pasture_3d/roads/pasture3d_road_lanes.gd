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
# ---- THE SIGN CONVENTION IS THE GRADER'S, NOT A NEW ONE ----
#
# `offset` is the same signed across-distance `u` that Pasture3DRoadGrader crowns and banks with:
# POSITIVE IS LEFT of the direction of increasing arc length. Reusing it means a lane centre can be fed
# straight to the grader's surface equation to get the height of that lane, and means there is exactly
# one place in the road system where left and right are decided.
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


## The lanes across one road, LEFT TO RIGHT — `index` 0 is the leftmost lane, at the greatest `offset`.
##
## Each entry is `{index, ordinal, direction, offset, width, left_edge, right_edge}`:
##   index      — position in the cross-section, 0 at the left edge. Geometric, and independent of which
##                side traffic drives on, so it means the same thing on a road however it is used.
##   ordinal    — position within this lane's OWN direction, 0 nearest the centre of the road and
##                increasing outward. What a driver means by "the inside lane", and what a connector
##                pairs on.
##   direction  — FORWARD or BACKWARD.
##   offset     — lane centre, signed metres, positive LEFT (the grader's `u`).
##   left_edge  — the lane's own edges, same sign convention. `left_edge > right_edge` always.
##   right_edge
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
	# Which direction occupies the LEFT of the carriageway. In right-hand traffic you drive on the right,
	# so the lanes coming at you are the ones on your left; in left-hand traffic it is reversed. On a
	# one-way road there is nothing to be on the other side of, and every lane is forward.
	var left_group := backward if not p_left_hand else forward
	var left_dir := BACKWARD if not p_left_hand else FORWARD

	for i in n:
		var in_left_group := i < left_group
		var direction := left_dir if in_left_group else -left_dir
		if p_one_way:
			direction = FORWARD
		# Ordinal counts from the DIVIDER outward. The left group's innermost lane is its last (nearest
		# the middle of the road); the right group's innermost is its first.
		var ordinal := (left_group - 1 - i) if in_left_group else (i - left_group)
		if p_one_way:
			ordinal = i
		var left_edge := half - float(i) * lw
		out.append({
			"index": i,
			"ordinal": ordinal,
			"direction": direction,
			"offset": left_edge - lw * 0.5,
			"width": lw,
			"left_edge": left_edge,
			"right_edge": left_edge - lw,
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
		# Half-open from the left, so a vehicle exactly on a lane line is in the RIGHT-hand lane of the
		# two and never in both or neither.
		if p_offset <= float(l["left_edge"]) and p_offset > float(l["right_edge"]):
			return l
	# The right edge of the rightmost lane is the one boundary the half-open rule would exclude.
	if not p_lanes.is_empty():
		var last: Dictionary = p_lanes[p_lanes.size() - 1]
		if is_equal_approx(p_offset, float(last["right_edge"])):
			return last
	return {}


## World XZ of a lane's centreline at a point on the plan, given the direction of travel there.
##
## `p_tangent` is the plan direction at that point (increasing arc length). The left normal of a 2D
## tangent (x, y) is (-y, x), which is what makes a positive `offset` land on the left.
static func lane_point(p_plan_point: Vector2, p_tangent: Vector2, p_offset: float) -> Vector2:
	var t := p_tangent.normalized()
	if not is_finite(t.x) or not is_finite(t.y) or t == Vector2.ZERO:
		return p_plan_point
	return p_plan_point + Vector2(-t.y, t.x) * p_offset
