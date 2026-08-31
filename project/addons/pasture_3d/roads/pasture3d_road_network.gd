# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadNetwork — the root of the road hierarchy: the world's road-type catalogue, the settings
# every road falls back to, and (from P4) the resolver that finds intersections and the queries a game
# reads. One per world. See PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §5.1.
#
# ---- WHAT THIS DOES NOT DO ----
#
# Pasture3D ships road and lane DATA and the queries over it. It does not implement traffic, AI,
# gameplay or race logic (§1.1). When the lane graph lands in P4b this node will answer "given a lane,
# what are my legal next lanes, where is my stop line, what is the signal state, who do I yield to" —
# and it will never drive a car. The same line holds for stages: a route publishes which runs it
# occupies, and whether traffic clears that corridor is the game's decision, not this node's.
#
# In P0 the network is the top of the resolve chain and the owner of the type catalogue. Everything else
# on it is a later phase.
@tool
@icon("res://addons/pasture_3d/icons/brush_terrain.svg")
class_name Pasture3DRoadNetwork
extends Node3D

## Group every network joins, so a brush can find its network without the caller holding a reference.
const NETWORK_GROUP: StringName = &"pasture3d_road_network"

## Which side of the road traffic drives on.
enum TrafficSide { RIGHT = 0, LEFT = 1 }

@export_group("Catalogue")
## Every road type available in this world. Groups add their own on top and may hide any of these from
## their children; see Pasture3DRoadGroup.available_road_types.
@export var road_types: Array[Pasture3DRoadType] = []:
	set(v):
		road_types = v
		_bump()

@export_group("World")
## Which side traffic drives on. A WORLD CONSTANT with no per-group or per-brush override, deliberately:
## it decides lane ordering, which turn crosses oncoming traffic, and which way a junction's connectors
## curve, so mixed handedness inside one world is a bug rather than a feature. (An earlier draft had
## this overridable per brush — see §6.4, which supersedes it.)
@export var traffic_side: TrafficSide = TrafficSide.RIGHT:
	set(v):
		traffic_side = v
		_bump()

@export_group("Defaults")
## The bottom of the resolve chain (§5.3): what every road in the world uses where no group, brush or
## segment has an opinion. Values left unset here fall through to the resolved Pasture3DRoadType.
@export var road_defaults: Pasture3DRoadOverrides:
	set(v):
		if road_defaults != null and road_defaults.changed.is_connected(_bump):
			road_defaults.changed.disconnect(_bump)
		road_defaults = v
		if road_defaults != null and not road_defaults.changed.is_connected(_bump):
			road_defaults.changed.connect(_bump)
		_bump()

@export_group("Right of way")
## What a junction whose own `control` is INHERIT uses. The world's default junction discipline: an
## unsignposted world is PRIORITY, a dense city might be SIGNALS. Per-junction overrides sit on the
## junction, where the user authored them.
@export var default_control: Pasture3DRoadJunction.ControlType = Pasture3DRoadJunction.ControlType.PRIORITY:
	set(v):
		# INHERIT here would inherit from nothing. Clamped rather than warned about, because it is
		# reachable only by dragging the enum to a value that has no meaning at this level.
		default_control = Pasture3DRoadJunction.ControlType.PRIORITY 				if v == Pasture3DRoadJunction.ControlType.INHERIT else v
		_bump()
## Total signal cycle at a signalised junction, seconds. Split between the participating roads in
## proportion to their priority (§6.4).
@export_range(10.0, 240.0, 1.0, "or_greater") var signal_cycle: float = 60.0:
	set(v):
		signal_cycle = v
		_bump()
## Yellow after each phase's green, seconds.
@export_range(0.0, 10.0, 0.1) var signal_yellow: float = 3.0:
	set(v):
		signal_yellow = v
		_bump()

## Emitted when any junction's signal phase changes. The publish half of "Pasture3D advances the phase
## and publishes the current state" (§6.4) — a consumer that wants to react to a light rather than poll
## it connects here, and Pasture3D still never decides what to do about it.
signal signals_changed(junction: Pasture3DRoadJunction)

## Bumped whenever anything that could change a resolved value changes. Brushes and (later) the
## intersection resolver key their staleness on it, so a catalogue edit invalidates the right caches
## without anyone diffing the catalogue.
var content_key: int = 0


func _init() -> void:
	if road_defaults == null:
		road_defaults = Pasture3DRoadOverrides.new()


func _ready() -> void:
	add_to_group(NETWORK_GROUP)
	if road_defaults != null and not road_defaults.changed.is_connected(_bump):
		road_defaults.changed.connect(_bump)


func _bump() -> void:
	content_key += 1
	update_configuration_warnings()


## The nearest Pasture3DRoadNetwork at or above `p_node`, or null. The lookup every level of the
## hierarchy uses, so a brush works wherever it is parented rather than needing a wired reference.
static func find_for(p_node: Node) -> Pasture3DRoadNetwork:
	var n: Node = p_node
	while n != null:
		if n is Pasture3DRoadNetwork:
			return n as Pasture3DRoadNetwork
		n = n.get_parent()
	return null


## The catalogue, with nulls dropped. Null entries are a normal intermediate state — the inspector adds
## an empty row when you grow the array — so they are filtered rather than warned about on every frame.
func valid_road_types() -> Array[Pasture3DRoadType]:
	var out: Array[Pasture3DRoadType] = []
	for t: Pasture3DRoadType in road_types:
		if t != null:
			out.append(t)
	return out


func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if valid_road_types().is_empty():
		out.append("No road types in the catalogue. Add a Pasture3DRoadType so brushes have something to build.")
	return out


# ---- JUNCTIONS (P4a) --------------------------------------------------------------------------------
#
# The network is where junctions live because a junction belongs to no single road: it is a fact about a
# PAIR, and either participant moving changes it. Each brush grades itself independently and knows only
# its own spline, so the crossing has to be found one level up, and the result handed back DOWN as pins
# (§6) rather than as heights to write.
#
# The order is necessarily two-pass, and that is not a wart: a crossing cannot be detected until both
# roads have a solved profile (the clearance test compares heights), and the profiles cannot honour the
# junction until it has been detected. So each brush bakes unpinned, asks for a resolve, and re-bakes only
# if the pins it would now receive differ from the ones it used. That converges after one extra pass and
# is the same guarded-rebake shape as the corridor widening in the brush.

## Every junction in this world, detected and reconciled. Saved with the scene, because the OVERRIDES on
## these records are the user's and must survive both a reload and a re-resolve.
@export var junctions: Array[Pasture3DRoadJunction] = []

var _resolve_queued: bool = false


## Ask for a junction resolve at the end of the frame. Coalesced, so ten brushes finishing their bakes in
## one refresh produce one resolve rather than ten.
func request_resolve() -> void:
	if _resolve_queued:
		return
	_resolve_queued = true
	resolve_junctions.call_deferred()


## Find every crossing between this network's roads, reconcile it against what is already stored, and ask
## any brush whose pins changed to bake again. Safe to call directly; `request_resolve` is the coalescing
## front door.
func resolve_junctions() -> void:
	_resolve_queued = false
	var brushes := road_brushes()
	var runs: Array = []
	for b in brushes:
		var run: Dictionary = b.build_run()
		if not run.is_empty():
			runs.append(run)
	# A road with no solved alignment yet contributes nothing, so a resolve that runs before the first
	# bake finds nothing rather than finding wrong things.
	junctions = _typed(Pasture3DRoadJunctionSolver.resolve(runs, junctions))
	# The lane graph is built from the RESOLVED junctions, so it runs after them and reads the trim-back
	# they just decided: an arm sits exactly where the approach's grading stops.
	_resolve_lane_graphs(brushes)
	for b in brushes:
		if b.junction_digest() != b.last_junction_digest:
			b.schedule_junction_rebake()
	# The junction gizmo draws from these records, and nothing else tells the editor they moved.
	update_gizmos()


## Build every detected junction's lane graph from its participants' arms.
##
## A junction that is disabled or no longer detected keeps whatever it had: the connectors carry the
## user's turn permissions, and rebuilding them from arms that are not there any more would throw those
## away for the same reason the junction records themselves are kept rather than deleted (§6).
##
## THE FIRST BUILD IS ONE PASS BEHIND, inherently. Arm heights come from each road's solved alignment,
## and on the resolve that FIRST detects a junction those alignments predate its pins — so the minor
## road's arms sit at the height it wanted before it was asked to meet the major road. The re-bake the
## pins trigger requests another resolve, and that one sees the profiles the junction asked for. Nothing
## needs to force it; it is the same fixed point the digest already converges on.
func _resolve_lane_graphs(p_brushes: Array) -> void:
	var by_key := {}
	for b in p_brushes:
		by_key[b.road_key()] = b
	var left_hand := traffic_side == TrafficSide.LEFT
	for j in junctions:
		if j == null or not j.detected or j.disabled:
			continue
		var arms := _arms_for(j, by_key)
		if arms.size() < 2:
			continue
		var res := Pasture3DRoadLaneSolver.solve(arms, j.connectors, {"left_hand": left_hand})
		j.connectors = _typed_connectors(res["connectors"])
		j.stop_lines = _typed_stop_lines(res["stop_lines"])
		# Right of way is built from the connectors that were just resolved, not alongside them: a
		# conflict is a fact about two PATHS meeting, so it cannot be known until the paths exist.
		j.priorities = _priorities_for(j, by_key)
		var row := Pasture3DRoadRightOfWay.solve(j.connectors, j.road_keys, j.priorities, {
			"left_hand": left_hand, "cycle": signal_cycle, "yellow": signal_yellow,
		})
		j.conflicts = _typed_conflicts(row["conflicts"])
		j.phases = _typed_phases(row["phases"])
		j.phase_index = clampi(j.phase_index, 0, maxi(j.phases.size() - 1, 0))


## The arms of one junction: two per participant — the approach BEFORE the footprint and the
## continuation AFTER it — at the arc lengths the trim-back put them.
##
## A road whose alignment has not been solved yet contributes nothing, the same rule `build_run` uses:
## an arm with no height is an arm whose connectors would be drawn at y = 0, running through the ground.
func _arms_for(p_junction: Pasture3DRoadJunction, p_by_key: Dictionary) -> Array:
	var out: Array = []
	for key in p_junction.road_keys:
		var brush = p_by_key.get(String(key), null)
		if brush == null:
			continue
		var lanes: Array = brush.resolved_lanes()
		if lanes.is_empty():
			continue
		var s: float = p_junction.arc_length_for(String(key))
		var trim: float = p_junction.trim_back_for(String(key))
		if not is_finite(s):
			continue
		for end in [Pasture3DRoadLaneConnector.End.BEFORE, Pasture3DRoadLaneConnector.End.AFTER]:
			var at: float = s - trim if end == Pasture3DRoadLaneConnector.End.BEFORE else s + trim
			var y: float = brush.height_at_arc(at)
			if not is_finite(y):
				continue
			out.append({
				"key": String(key),
				"end": end,
				"point": brush.point_at_arc(at),
				"y": y,
				"distance": at,
				"tangent": brush.tangent_at_arc(at),
				"lanes": lanes,
			})
	return out


## Each participant's resolved priority, parallel to `road_keys`. A road that has left the scene keeps
## the priority the junction last saw, rather than silently dropping to zero and inverting who gives way.
func _priorities_for(p_junction: Pasture3DRoadJunction, p_by_key: Dictionary) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in p_junction.road_keys.size():
		var brush = p_by_key.get(String(p_junction.road_keys[i]), null)
		if brush != null:
			out.append(brush.road_priority())
		elif i < p_junction.priorities.size():
			out.append(p_junction.priorities[i])
		else:
			out.append(0)
	return out


func _typed_conflicts(p_in: Array) -> Array[Pasture3DRoadConflict]:
	var out: Array[Pasture3DRoadConflict] = []
	for c in p_in:
		if c is Pasture3DRoadConflict:
			out.append(c)
	return out


func _typed_phases(p_in: Array) -> Array[Pasture3DRoadPhase]:
	var out: Array[Pasture3DRoadPhase] = []
	for ph in p_in:
		if ph is Pasture3DRoadPhase:
			out.append(ph)
	return out


func _typed_connectors(p_in: Array) -> Array[Pasture3DRoadLaneConnector]:
	var out: Array[Pasture3DRoadLaneConnector] = []
	for c in p_in:
		if c is Pasture3DRoadLaneConnector:
			out.append(c)
	return out


func _typed_stop_lines(p_in: Array) -> Array[Pasture3DRoadStopLine]:
	var out: Array[Pasture3DRoadStopLine] = []
	for sl in p_in:
		if sl is Pasture3DRoadStopLine:
			out.append(sl)
	return out


## Every road brush under this network, in scene order.
func road_brushes() -> Array[Pasture3DRoadBrush]:
	var out: Array[Pasture3DRoadBrush] = []
	_collect_brushes(self, out)
	return out


func _collect_brushes(p_at: Node, p_out: Array[Pasture3DRoadBrush]) -> void:
	for c in p_at.get_children():
		if c is Pasture3DRoadBrush:
			p_out.append(c as Pasture3DRoadBrush)
		# A nested network owns its own roads; stopping here is what keeps two networks in one scene from
		# resolving junctions between each other's roads.
		if not (c is Pasture3DRoadNetwork):
			_collect_brushes(c, p_out)


## Junctions `p_key` takes part in, skipping the disabled and the no-longer-detected.
func junctions_for(p_key: String) -> Array[Pasture3DRoadJunction]:
	var out: Array[Pasture3DRoadJunction] = []
	for j in junctions:
		if j != null and j.detected and not j.disabled and j.participant_index(p_key) >= 0:
			out.append(j)
	return out


func _typed(p_in: Array) -> Array[Pasture3DRoadJunction]:
	var out: Array[Pasture3DRoadJunction] = []
	for j in p_in:
		if j is Pasture3DRoadJunction:
			out.append(j)
	return out


# ---- SIGNALS (P4b) ----------------------------------------------------------------------------------
#
# "Pasture3D advances the phase and publishes the current state; obeying it is the consumer's job"
# (§6.4). This is the advancing half. It is the only per-frame work the road system does, it touches
# nothing but a float and an int per signalised junction, and it stops entirely in the editor — a scene
# whose lights cycled while you were building it would repaint the gizmo forever and mark the scene
# dirty for a value that is deliberately not saved.


func _process(p_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	for j in junctions:
		if j != null and j.advance_signals(p_delta, default_control):
			signals_changed.emit(j)


## Reset every junction to the start of its cycle. What a level restart wants: without it a race
## restarted after ten minutes begins with the lights wherever the last run left them.
func reset_signals() -> void:
	for j in junctions:
		if j != null:
			j.phase_index = 0
			j.phase_elapsed = 0.0


# ---- THE FOUR QUERIES (§6.4) ------------------------------------------------------------------------
#
# A consumer holds a lane — a road key, a lane index and which end of the road it is approaching — and
# asks these. Nothing below re-derives geometry, and nothing below decides what a vehicle should do.


## Given a lane, the legal movements out of it, across every junction it reaches. Query one.
func lane_connectors(p_key: String, p_lane: int, p_end: int) -> Array:
	var out: Array = []
	for j in junctions_for(p_key):
		out.append_array(j.connectors_from(p_key, p_lane, p_end))
	return out


## Where a vehicle in that lane holds, and at which junction. Query two. Returns
## `{junction, stop_line}`, or {} when that lane holds for nothing.
##
## `p_from_distance` is where the vehicle is now, as an arc length along its road; give it and the
## answer is the NEXT hold in the direction it is travelling rather than the first one in the junction
## list. A road that crosses two others has two stop lines for the same lane, so without this a vehicle
## halfway along it would be told to stop at the junction it has already passed — which is not a
## consumer error to guard against, it is a query that answered the wrong question.
func lane_stop(p_key: String, p_lane: int, p_end: int, p_from_distance: float = NAN) -> Dictionary:
	var best := {}
	var best_gap := INF
	for j in junctions_for(p_key):
		var sl := j.stop_line_for(p_key, p_lane, p_end)
		if sl == null:
			continue
		if not is_finite(p_from_distance) or not is_finite(sl.distance):
			return {"junction": j, "stop_line": sl}
		# A vehicle arriving at the BEFORE end is travelling with increasing arc length, so its next
		# hold is ahead of it; at the AFTER end it is travelling the other way.
		var gap: float = sl.distance - p_from_distance
		if p_end == Pasture3DRoadLaneConnector.End.AFTER:
			gap = -gap
		if gap >= 0.0 and gap < best_gap:
			best_gap = gap
			best = {"junction": j, "stop_line": sl}
	return best


## The signal a vehicle approaching `p_junction` on `p_key` sees. Query three. NONE means the junction
## is not signalised and query four is the one to ask.
func lane_signal(p_junction: Pasture3DRoadJunction, p_key: String) -> int:
	if p_junction == null:
		return Pasture3DRoadPhase.State.NONE
	return p_junction.signal_state(p_key, default_control)


## Who a movement gives way to. Query four.
func connector_yields_to(p_junction: Pasture3DRoadJunction,
		p_connector_id: StringName) -> Array[Pasture3DRoadConflict]:
	var empty: Array[Pasture3DRoadConflict] = []
	return p_junction.yields_to(p_connector_id) if p_junction != null else empty
