# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadLaneSolver — turns a resolved junction into a lane graph: the connectors through it and
# the stop line at the head of every incoming lane. See PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §6.4.
#
# ---- A JUNCTION HAS ARMS, NOT ROADS ----
#
# The unit here is an ARM: one end of one road at the footprint, with its lanes and its heading. A road
# that crosses a junction presents TWO arms — the approach before the footprint and the continuation
# after it — and that is what makes "continue straight" fall out of the same code as "turn left": both
# are an incoming lane on one arm reaching an outgoing lane on another. Modelling the participants as
# roads instead would have made the straight-ahead case special, and the straight-ahead case is the one
# every consumer uses most.
#
# It also makes the U-turn exclusion structural rather than a rule: a U-turn is an incoming lane
# reaching an outgoing lane ON THE SAME ARM, so skipping same-arm pairs excludes it by construction and
# there is no angle threshold to get wrong.
#
# ---- STATIC, ARRAYS IN, RESOURCES OUT ----
#
# Same reason as the grader and the junction solver: nothing here touches a Node or an editor, so the
# gate can build a crossroads out of literals and check the connector count, the turn classification and
# the tangent continuity against numbers known in advance.
@tool
class_name Pasture3DRoadLaneSolver
extends RefCounted

const Connector: GDScript = preload("res://addons/pasture_3d/roads/pasture3d_road_lane_connector.gd")

## Fraction of the straight-line distance between two endpoints used as the Bezier handle length. 0.42
## is close to the circular-arc fit for a right-angle turn (the exact value for a quarter circle is
## 4/3·(√2−1) ≈ 0.5523 of the RADIUS, which is this fraction of the chord) and stays sane on the
## shallow and the sharp cases either side of it.
const HANDLE: float = 0.42

## Turns sharper than this from straight-ahead are LEFT or RIGHT rather than STRAIGHT, radians.
const STRAIGHT_ARC: float = PI * 0.25
## Turns sharper than this are U-turns. Only reachable through a hand-built arm set — the same-arm
## exclusion means the generator never produces one — but classification is asked of the ANGLE, so it
## answers for any angle rather than only the ones this file happens to emit.
const U_TURN_ARC: float = PI * 0.75


## Build the lane graph for one junction.
##
## `p_arms` is one Dictionary per arm:
##   key       — the road's content key
##   end       — Pasture3DRoadLaneConnector.End, which end of that road this arm is
##   point     — world XZ of the CENTRELINE at the footprint boundary
##   y         — the road's solved height there, metres
##   tangent   — the road's plan direction at that point, world XZ, in the direction of INCREASING arc
##               length. Not the direction of travel: a BACKWARD lane travels against it.
##   lanes     — that road's cross-section (Pasture3DRoadLanes.cross_section)
##
## `p_existing` is the junction's current connectors, reconciled by id so `allowed_override` survives.
## `p_opts` may carry `left_hand` (bool), the world's traffic side, which decides which turns cross the
## oncoming carriageway.
##
## Returns `{connectors: Array[Pasture3DRoadLaneConnector], stop_lines: Array[Pasture3DRoadStopLine]}`.
static func solve(p_arms: Array, p_existing: Array = [], p_opts: Dictionary = {}) -> Dictionary:
	var left_hand := bool(p_opts.get("left_hand", false))
	var by_id := {}
	for c in p_existing:
		if c is Pasture3DRoadLaneConnector:
			by_id[String(c.id)] = c

	# Every lane endpoint on every arm, split by whether traffic there is entering or leaving.
	var incoming: Array = []
	var outgoing: Array = []
	for ai in p_arms.size():
		var arm: Dictionary = p_arms[ai]
		for lane: Dictionary in arm.get("lanes", []):
			var ep := _endpoint(ai, arm, lane)
			if _is_incoming(int(arm.get("end", 0)), int(lane["direction"])):
				incoming.append(ep)
			else:
				outgoing.append(ep)

	var connectors: Array = []
	for from_ep: Dictionary in incoming:
		for to_ep: Dictionary in outgoing:
			# SAME ARM IS A U-TURN. Excluded structurally; see the header.
			if from_ep["arm"] == to_ep["arm"]:
				continue
			# Lanes pair by ORDINAL, not by index: the inside lane of one road feeds the inside lane of
			# the next, which is what a driver does and what keeps paths from crossing inside the
			# footprint. Where the roads have different lane counts the ordinal is clamped, so a
			# two-lane road feeding a one-lane road merges rather than dropping a connector.
			if int(to_ep["ordinal"]) != _target_ordinal(int(from_ep["ordinal"]), p_arms, to_ep):
				continue
			connectors.append(_connector(from_ep, to_ep, by_id, left_hand))

	var stop_lines: Array = []
	for ep: Dictionary in incoming:
		var sl := Pasture3DRoadStopLine.new()
		sl.road_key = ep["key"]
		sl.lane = int(ep["lane"])
		sl.end = int(ep["end"])
		sl.point = Vector3(ep["pos"].x, ep["y"], ep["pos"].y)
		sl.heading = ep["heading"]
		sl.width = float(ep["width"])
		stop_lines.append(sl)

	return {"connectors": connectors, "stop_lines": stop_lines}


## True when traffic in a lane of `p_direction` at `p_end` is entering the junction.
##
## At the BEFORE end — the arc length below the footprint — a FORWARD lane runs toward the junction and
## a BACKWARD lane runs away from it. At the AFTER end both are reversed. This one line is the whole of
## what "incoming" means, and every other file asks it rather than re-deriving it.
static func _is_incoming(p_end: int, p_direction: int) -> bool:
	if p_end == Connector.End.BEFORE:
		return p_direction == Pasture3DRoadLanes.FORWARD
	return p_direction == Pasture3DRoadLanes.BACKWARD


## One lane's endpoint on one arm: where it meets the footprint, and which way traffic there travels.
static func _endpoint(p_arm_index: int, p_arm: Dictionary, p_lane: Dictionary) -> Dictionary:
	var tangent: Vector2 = (p_arm.get("tangent", Vector2.RIGHT) as Vector2).normalized()
	var pos := Pasture3DRoadLanes.lane_point(p_arm.get("point", Vector2.ZERO), tangent,
			float(p_lane["offset"]))
	# The direction of TRAVEL, which is the plan tangent for a forward lane and its reverse otherwise.
	var heading := tangent if int(p_lane["direction"]) == Pasture3DRoadLanes.FORWARD else -tangent
	return {
		"arm": p_arm_index,
		"key": String(p_arm.get("key", "")),
		"end": int(p_arm.get("end", 0)),
		"lane": int(p_lane["index"]),
		"ordinal": int(p_lane["ordinal"]),
		"width": float(p_lane["width"]),
		"pos": pos,
		"y": float(p_arm.get("y", 0.0)),
		"heading": heading,
	}


## The ordinal an incoming lane targets on the arm it is entering, clamped to what that arm has.
static func _target_ordinal(p_from_ordinal: int, p_arms: Array, p_to_ep: Dictionary) -> int:
	var arm: Dictionary = p_arms[int(p_to_ep["arm"])]
	var most := 0
	for lane: Dictionary in arm.get("lanes", []):
		# Only the lanes traffic can actually leave by — the outgoing ones on this arm.
		if _is_incoming(int(arm.get("end", 0)), int(lane["direction"])):
			continue
		most = maxi(most, int(lane["ordinal"]))
	return clampi(p_from_ordinal, 0, most)


## One connector, reconciled onto its prior record when there is one.
static func _connector(p_from: Dictionary, p_to: Dictionary, p_by_id: Dictionary,
		p_left_hand: bool) -> Pasture3DRoadLaneConnector:
	var id := Pasture3DRoadLaneConnector.make_id(p_from["key"], int(p_from["lane"]), int(p_from["end"]),
			p_to["key"], int(p_to["lane"]), int(p_to["end"]))
	var c: Pasture3DRoadLaneConnector = p_by_id.get(String(id), null)
	if c == null:
		c = Pasture3DRoadLaneConnector.new()
		c.id = id
		c.from_key = p_from["key"]
		c.from_lane = int(p_from["lane"])
		c.from_end = int(p_from["end"])
		c.to_key = p_to["key"]
		c.to_lane = int(p_to["lane"])
		c.to_end = int(p_to["end"])
	# Resolved fields are rebuilt every time; `allowed_override` is not among them.
	c.turn_angle = signed_angle(p_from["heading"], p_to["heading"])
	c.turn = classify(c.turn_angle)
	c.default_allowed = c.turn != Connector.Turn.U_TURN
	# Drive on the right and it is the LEFT turn that cuts across the traffic coming at you; drive on
	# the left and it is the right turn. The turn kind alone never says this, which is exactly why it
	# is published (§6.4).
	c.crosses_oncoming = (c.turn == Connector.Turn.RIGHT) if p_left_hand else (c.turn == Connector.Turn.LEFT)
	c.curve = build_curve(p_from, p_to)
	return c


## Signed angle from `p_from` to `p_to`, radians, POSITIVE TURNING RIGHT.
##
## Right is the same right the lane offsets use: in the (x, z) plane the vector (−y, x) is the driver's
## right, so a heading that rotates toward it has a positive 2D cross product. Sharing the one
## convention is what makes a right turn identifiable without re-deriving the world's handedness here.
static func signed_angle(p_from: Vector2, p_to: Vector2) -> float:
	var a := p_from.normalized()
	var b := p_to.normalized()
	return atan2(a.x * b.y - a.y * b.x, a.dot(b))


## Bucket an angle into a turn kind.
static func classify(p_angle: float) -> int:
	var m := absf(p_angle)
	if m >= U_TURN_ARC:
		return Connector.Turn.U_TURN
	if m < STRAIGHT_ARC:
		return Connector.Turn.STRAIGHT
	return Connector.Turn.RIGHT if p_angle > 0.0 else Connector.Turn.LEFT


## The path between two lane endpoints, as a cubic with its handles ALONG THE TWO HEADINGS.
##
## That is what makes it tangent-continuous with the lanes it joins — a vehicle leaving the lane and
## picking up the connector does not have to turn instantaneously — and it is a property of the
## construction rather than something to be checked and corrected afterwards. The gate asserts it
## anyway, because "the handle is along the heading" and "the curve leaves along the heading" are only
## the same statement while the handle is non-zero.
static func build_curve(p_from: Dictionary, p_to: Dictionary) -> Curve3D:
	var a := Vector3(p_from["pos"].x, float(p_from["y"]), p_from["pos"].y)
	var b := Vector3(p_to["pos"].x, float(p_to["y"]), p_to["pos"].y)
	var d := a.distance_to(b) * HANDLE
	var ha: Vector2 = p_from["heading"]
	var hb: Vector2 = p_to["heading"]
	var curve := Curve3D.new()
	# Godot's Curve3D control points are RELATIVE to their point, and `out` of the first with `in` of
	# the second is the cubic between them.
	curve.add_point(a, Vector3.ZERO, Vector3(ha.x, 0.0, ha.y) * d)
	curve.add_point(b, Vector3(-hb.x, 0.0, -hb.y) * d, Vector3.ZERO)
	return curve
