# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadLaneFollower — a reference vehicle that drives Pasture3D's lane graph. THE SUFFICIENCY CHECK for
# P4b (§6.4, §11): if this needs to re-derive geometry, the published data is incomplete.
#
# ---- THIS IS NOT PART OF PASTURE3D, AND MUST NEVER BECOME PART OF IT ----
#
# It lives in bench/, not in addons/. Pasture3D ships road and lane DATA and the queries over it, and
# does not implement traffic, AI, gameplay or race logic (§1.1). This file is the customer, not the
# product: it exists to prove the data is usable and to fail loudly where it is not, and a developer
# reading it should see a worked example of consuming the four queries — not a component to instantiate.
#
# ---- HOW IT IS ALLOWED TO CHEAT: IT ISN'T ----
#
# Everything below goes through the published surface, listed in `USES` and enforced by the gate, which
# reads this file and fails if it names any of the solvers. The rule it is proving is a narrow one and
# worth stating exactly: the follower may ASK the road system anything, and may do arithmetic on the
# answers, but it may not recompute an answer the road system already knows. Projecting its position
# onto a road's plan to find out which junction is next would be recomputing; asking for the next stop
# line and subtracting arc lengths is not.
#
# Three gaps were found by writing it, and all three were closed in the data rather than worked around
# here: a stop line carried no arc length, `lane_stop` answered with the first junction rather than the
# next one, and a road would not say how long it was.
@tool
extends RefCounted

## The published surface this follower uses. Declared so the gate can check that the list is honest —
## every name here must exist on the class it names, or the surface has moved and this has not.
const USES: Array = [
	["Pasture3DRoadNetwork", ["road_brushes", "junctions_for", "lane_connectors", "lane_stop",
		"lane_signal", "connector_yields_to"]],
	["Pasture3DRoadBrush", ["road_key", "road_length", "resolved_lanes", "point_at_arc",
		"tangent_at_arc", "height_at_arc"]],
	["Pasture3DRoadJunction", ["arc_length_for", "trim_back_for", "connector_by_id"]],
	["Pasture3DRoadLanes", ["lane_point", "lanes_in"]],
]

## Metres per second. Constant — this is a data check, not a driving model.
const SPEED: float = 8.0

var network: Pasture3DRoadNetwork
## Where it is: which road, which lane of that road's cross-section, and how far along.
var road_key: String = ""
var lane: int = 0
var distance: float = 0.0
## Which way it travels along the arc length.
var direction: int = Pasture3DRoadLanes.FORWARD
## Set while it is crossing a junction.
var connector: Pasture3DRoadLaneConnector = null
var junction: Pasture3DRoadJunction = null
var connector_t: float = 0.0

## What it is doing, for the gate to assert on.
var holding: bool = false
var hold_reason: String = ""
var junctions_crossed: int = 0
var finished: bool = false

## Every time a query could not answer something this follower needed. THE POINT OF THE EXERCISE: a
## non-zero count is the data being insufficient, and the gate reports the reasons verbatim.
var missing: PackedStringArray = PackedStringArray()

## Returns true when `p_connector_id` is occupied by somebody else. Supplied by the caller, because who
## else is on the road is the game's business and Pasture3D neither knows nor should.
var occupancy: Callable = func(_id: StringName) -> bool: return false


func _note_missing(p_what: String) -> void:
	if not missing.has(p_what):
		missing.append(p_what)


## Put the follower on a road, in the innermost lane running `p_direction`.
func start(p_network: Pasture3DRoadNetwork, p_key: String, p_direction: int,
		p_distance: float) -> bool:
	network = p_network
	road_key = p_key
	direction = p_direction
	distance = p_distance
	var brush := _brush()
	if brush == null:
		_note_missing("no brush answers to the road key %s" % p_key)
		return false
	var lanes: Array = brush.resolved_lanes()
	var mine: Array = Pasture3DRoadLanes.lanes_in(lanes, p_direction)
	if mine.is_empty():
		_note_missing("road %s has no lane running direction %d" % [p_key, p_direction])
		return false
	lane = int(mine[0]["index"])
	return true


## The brush for `road_key`. A lookup, not a derivation: the network publishes its brushes and each
## brush publishes its key.
func _brush() -> Pasture3DRoadBrush:
	if network == null:
		return null
	for b in network.road_brushes():
		if b.road_key() == road_key:
			return b
	return null


## Which end of a junction this follower arrives at. It is travelling with increasing arc length or
## against it, and that alone decides it — see Pasture3DRoadLaneSolver's `_is_incoming`, which is the
## same fact from the junction's side.
func _arrival_end() -> int:
	return Pasture3DRoadLaneConnector.End.BEFORE if direction == Pasture3DRoadLanes.FORWARD \
			else Pasture3DRoadLaneConnector.End.AFTER


## Where the follower is in the world.
func position() -> Vector3:
	if connector != null and connector.curve != null:
		var length := connector.curve.get_baked_length()
		return connector.curve.sample_baked(clampf(connector_t, 0.0, length))
	var brush := _brush()
	if brush == null:
		return Vector3.ZERO
	var lanes: Array = brush.resolved_lanes()
	var here: Dictionary = {}
	for l: Dictionary in lanes:
		if int(l["index"]) == lane:
			here = l
	if here.is_empty():
		return Vector3.ZERO
	var at := Pasture3DRoadLanes.lane_point(brush.point_at_arc(distance),
			brush.tangent_at_arc(distance), float(here["offset"]))
	return Vector3(at.x, brush.height_at_arc(distance), at.y)


## One step. Returns false once the follower has run out of road.
func step(p_delta: float) -> bool:
	if finished:
		return false
	if connector != null:
		return _step_connector(p_delta)
	return _step_road(p_delta)


## Crossing a junction: follow the connector to its end, then adopt the lane it delivered us to.
func _step_connector(p_delta: float) -> bool:
	holding = false
	hold_reason = ""
	var length := connector.curve.get_baked_length() if connector.curve != null else 0.0
	connector_t += SPEED * p_delta
	if connector_t < length:
		return true
	# Arrived. The connector says which road, which lane and which end it ends at, and the junction says
	# what arc length that end is — everything needed to be back on a road with no geometry of our own.
	var to_key := connector.to_key
	var to_lane := connector.to_lane
	var s: float = junction.arc_length_for(to_key)
	var trim: float = junction.trim_back_for(to_key)
	if not is_finite(s):
		_note_missing("junction does not publish an arc length for the road a connector leads to")
		finished = true
		return false
	road_key = to_key
	lane = to_lane
	distance = s + trim if connector.to_end == Pasture3DRoadLaneConnector.End.AFTER else s - trim
	# Which way we now travel is the lane's own direction, read from the road we have just joined.
	direction = _direction_of(to_key, to_lane)
	connector = null
	junction = null
	connector_t = 0.0
	junctions_crossed += 1
	return true


func _direction_of(p_key: String, p_lane: int) -> int:
	var saved := road_key
	road_key = p_key
	var brush := _brush()
	road_key = saved
	if brush == null:
		return direction
	for l: Dictionary in brush.resolved_lanes():
		if int(l["index"]) == p_lane:
			return int(l["direction"])
	_note_missing("road %s publishes no lane %d for a connector that ends there" % [p_key, p_lane])
	return direction


## Running along a road: roll forward until the next hold, then decide whether to take it.
func _step_road(p_delta: float) -> bool:
	var brush := _brush()
	if brush == null:
		finished = true
		return false
	var end := _arrival_end()
	var hold: Dictionary = network.lane_stop(road_key, lane, end, distance)
	var step_len := SPEED * p_delta

	if hold.is_empty():
		# No junction ahead in this lane: run to the end of the road and stop there.
		holding = false
		hold_reason = ""
		distance += step_len * float(direction)
		var length := brush.road_length()
		if not is_finite(length):
			_note_missing("road %s will not say how long it is" % road_key)
			finished = true
			return false
		if distance <= 0.0 or distance >= length:
			finished = true
		return not finished

	var sl: Pasture3DRoadStopLine = hold["stop_line"]
	var j: Pasture3DRoadJunction = hold["junction"]
	if not is_finite(sl.distance):
		_note_missing("stop line carries no arc length, so a vehicle cannot tell how far away it is")
		finished = true
		return false
	var gap: float = absf(sl.distance - distance)

	if gap > step_len:
		holding = false
		hold_reason = ""
		distance += step_len * float(direction)
		return true
	# Within one step of the line: arrive exactly ON it rather than somewhere near it. The first draft
	# decided a stopping distance out and, when the way was clear, entered the connector from there —
	# which teleported the vehicle the length of that margin, because a connector begins at the stop
	# line and not wherever the decision was made. The gate's continuity criterion is what found it.
	distance = sl.distance

	# At the hold. Choose a movement, then decide whether it may be taken.
	var choice := _choose(j, end)
	if choice == null:
		_note_missing("no legal movement out of %s lane %d at a junction it arrives at" % [road_key, lane])
		finished = true
		return false
	var blocked := _blocked(j, choice)
	if blocked != "":
		holding = true
		hold_reason = blocked
		return true
	holding = false
	hold_reason = ""
	connector = choice
	junction = j
	connector_t = 0.0
	if connector.curve == null or connector.curve.point_count < 2:
		_note_missing("a legal connector carries no path to follow")
		finished = true
		return false
	return true


## Which way to go. Prefers straight on, which is what makes the gate's trip deterministic; anything
## else would be a route, and routes are P6.
func _choose(p_junction: Pasture3DRoadJunction, p_end: int) -> Pasture3DRoadLaneConnector:
	var options: Array = network.lane_connectors(road_key, lane, p_end)
	var best: Pasture3DRoadLaneConnector = null
	for c: Pasture3DRoadLaneConnector in options:
		if c.turn == Pasture3DRoadLaneConnector.Turn.STRAIGHT:
			return c
		if best == null:
			best = c
	return best


## Whether the chosen movement must wait, and why. The two published reasons to hold, in the order a
## driver meets them: the signal, then the traffic that has priority.
func _blocked(p_junction: Pasture3DRoadJunction, p_connector: Pasture3DRoadLaneConnector) -> String:
	var state := network.lane_signal(p_junction, road_key)
	if state == Pasture3DRoadPhase.State.RED or state == Pasture3DRoadPhase.State.YELLOW:
		return "signal"
	# NONE is not green — it means this junction has no signal and the yield relations are the answer.
	# A follower that treated it as green would drive through every uncontrolled crossroads in the world.
	for r: Pasture3DRoadConflict in network.connector_yields_to(p_junction, p_connector.id):
		if occupancy.call(r.priority_id):
			return "yield"
	return ""
