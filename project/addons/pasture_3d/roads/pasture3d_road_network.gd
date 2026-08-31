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

## Blend and map type of the reserved surface layer. REPLACE, because the topmost covered layer wins and
## a road is opaque where it covers: two roads in one network that overlap should show the one that
## painted last, which the network orders by priority.
const PAINT_LAYER_BLEND: int = 0 # Pasture3DLayer.BLEND_REPLACE
const PAINT_LAYER_MAPTYPE: int = 1 # Pasture3DData.MapType.TYPE_CONTROL

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

@export_group("Terrain")
## Metres the tier-MID ribbon rides above the ground it was graded into (P5b, §10).
##
## Lives HERE and not only on the chunk host, because the host is built output and is not saved with the
## scene — there is no node in the dock to select, so an export on it is an export nobody can reach.
## The network owns every road's chunks anyway, so this is also the level at which the answer should be
## the same for all of them.
##
## Raise it to something obvious (a metre) to find out whether a ribbon you cannot see is being drawn
## behind the terrain or not drawn at all. See Pasture3DRoadMesher.DEPTH_LIFT for why it is never zero.
@export var ribbon_lift: float = Pasture3DRoadMesher.DEPTH_LIFT:
	set(v):
		ribbon_lift = v
		_bump()


## Name of the reserved CONTROL layer the carriageway paints into (P5a, §10).
##
## SEPARATE FROM `layer_name`, which names the HEIGHT layer the grading goes into, and it has to be:
## the two are different map types doing unrelated jobs, and when both were called "Roads" the layers
## dock showed two identically named rows. Deleting the wrong one silently moved every road's surface
## paint onto a height layer, or the grading onto a control layer, with nothing to say which row was
## which.
@export var paint_layer_name: String = "Road Surface":
	set(v):
		paint_layer_name = v
		_bump()


## Display name of the terrain layer roads with NO GROUP paint into. A group of its own overrides this
## for its children; this is the fallback for a brush parented straight under the network, which §5.1
## allows and which would otherwise have nowhere to paint.
@export var layer_name: String = "Roads":
	set(v):
		layer_name = v
		_bump()

@export_group("Ribbon")
## Distance in metres at which each tier takes over: NEAR, then the coarser mesh tiers. Beyond the last,
## `ribbon_far_distance` decides whether the chunk is drawn at all.
##
## Here for the same reason `ribbon_lift` is (see above): the chunk hosts are BUILT output, not owned by
## the edited scene, so there is no node in the dock to select and an export on the host is an export
## nobody can reach. Every one of these was unreachable until it was noticed that the collision toggle
## could not be found — the setting existed, was documented, and had no way in.
@export var ribbon_lod_distances: PackedFloat32Array = PackedFloat32Array([60.0, 140.0, 300.0]):
	set(v):
		ribbon_lod_distances = v
		_bump()
		_push_lod_live()

## Beyond this, no ribbon at all: tier FAR carries the road, because the carriageway is painted into the
## terrain already (P5a) and there is nothing left to draw. 0 disables hiding, which is for looking at
## the mesh rather than for shipping.
@export var ribbon_far_distance: float = 600.0:
	set(v):
		ribbon_far_distance = v
		_bump()
		_push_lod_live()

## Dead band on every threshold above, metres. A tier only changes once the distance is this far past
## the line, so a camera parked on a threshold does not swap the mesh every frame.
@export var ribbon_hysteresis: float = 12.0:
	set(v):
		ribbon_hysteresis = v
		_bump()
		_push_lod_live()

## Give every chunk and every junction apron a collider on the carriageway.
##
## ---- NOT THE DRIVING SURFACE ----
##
## The road went through the HEIGHTMAP (P2), so the terrain's own collision already IS the road: a
## vehicle is held up by the graded ground whether this is on or off. What it adds is IDENTITY — a
## raycast that answers "am I on tarmac or on grass", on its own physics layer, without sampling the
## control map and decoding a texture id. Off by default, because a road nobody asks that question about
## should not pay for the shapes.
@export var ribbon_collision: bool = false:
	set(v):
		ribbon_collision = v
		_bump()

## Physics layer and mask for those colliders. Layer 2 by default so a road query cannot be confused with
## a terrain query, and mask 0 because these shapes answer questions — nothing collides WITH them.
@export_flags_3d_physics var ribbon_collision_layer: int = 2:
	set(v):
		ribbon_collision_layer = v
		_bump()

@export_flags_3d_physics var ribbon_collision_mask: int = 0:
	set(v):
		ribbon_collision_mask = v
		_bump()

## Draw lane markings on the carriageway (P5c). Junction aprons never take markings: the lane paths
## through a junction are the connectors' business, not a stripe's.
@export var ribbon_markings: bool = true:
	set(v):
		ribbon_markings = v
		_bump()

## Place the road type's verge props along the shoulders (P5c). Off makes a road with a prop mesh set
## build nothing rather than fail, which is the difference between "no props here" and "props broken".
@export var ribbon_props: bool = true:
	set(v):
		ribbon_props = v
		_bump()


## Push the three THRESHOLD settings into every live host, without a rebake.
##
## Separate from `_configure_host` because these three change nothing that was built: choosing a tier is
## a mesh swap over meshes that already exist, so a slider can move and the road can answer on the next
## frame. Everything else in the Ribbon group changes the GEOMETRY — colliders, stripes, props are
## made at bake — and cannot honestly be applied without one.
func _push_lod_live() -> void:
	for host in _all_hosts():
		host.lod_distances = ribbon_lod_distances
		host.far_distance = ribbon_far_distance
		host.lod_hysteresis = ribbon_hysteresis


## Every chunk host under this network: the junction aprons' own, and one per road brush that has built.
## Does NOT create them, so moving a slider before the first bake is a no-op rather than a bake.
func _all_hosts() -> Array[Pasture3DRoadChunkHost]:
	var out: Array[Pasture3DRoadChunkHost] = []
	for child in get_children():
		if child is Pasture3DRoadChunkHost:
			out.append(child)
	for b in road_brushes():
		for child in b.get_children():
			if child is Pasture3DRoadChunkHost:
				out.append(child)
	return out


## Push the network's ribbon settings into one host.
##
## Applied at BUILD rather than bound once, because a host is created on first use and replaced whenever
## its road is rebuilt — a setting written to the host at the moment it was made would be lost by the
## next bake, and would come back as a default that looks like the export having no effect.
func _configure_host(p_host: Pasture3DRoadChunkHost) -> void:
	if p_host == null:
		return
	p_host.lod_distances = ribbon_lod_distances
	p_host.far_distance = ribbon_far_distance
	p_host.lod_hysteresis = ribbon_hysteresis
	p_host.depth_lift = ribbon_lift
	p_host.collision_enabled = ribbon_collision
	p_host.collision_layer = ribbon_collision_layer
	p_host.collision_mask = ribbon_collision_mask
	p_host.markings_enabled = ribbon_markings
	p_host.props_enabled = ribbon_props


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
	# The ribbon is BUILT output and is deliberately not saved (see Pasture3DRoadBrush.ensure_chunk_host),
	# so something has to build it when a scene opens. Deferred: brushes are ready before their parent, but
	# their splines' global transforms are not settled until the whole tree is in, and the digest reads
	# them. Not gated on the editor — a shipped game needs the ribbon more than the editor does.
	restore_built_output.call_deferred()
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
	paint_roads(brushes)
	build_chunks(brushes)
	build_runtime(brushes)
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

# ---- The reserved surface layer (P5, §10) ------------------------------------------------------------


## The reserved CONTROL layer this network's roads paint their surface into, created on first use.
##
## Reserved and owned, which is what stops a user hand-deleting it in the layers dock and leaving every
## road in the network painting into whatever happened to take its index. Negative on a terrain or a
## build without the typed-layer API — the paint then does nothing at all, rather than falling back to
## writing the control map destructively: a road that permanently overwrote hand-painted texturing the
## first time somebody nudged a spline is worse than a road that is not painted yet.
func ensure_paint_layer(p_terrain: Node) -> int:
	if p_terrain == null or p_terrain.get("data") == null:
		return -1
	var data = p_terrain.data
	if not data.has_method("create_owned_layer_typed"):
		return -1
	return int(data.create_owned_layer_typed(paint_layer_owner(), paint_layer_name,
			PAINT_LAYER_BLEND, PAINT_LAYER_MAPTYPE))


## Owner id of that layer. Keyed on the network's own path so two networks in one scene own two
## layers even when the user named them both "Roads" — an owner keyed on the display name would silently
## merge them, and the first the user knew of it would be one network's edits moving the other's roads.
func paint_layer_owner() -> String:
	return "pasture3d_road_network:%s" % str(get_path())


# ---- TIER FAR: painting the roads (P5, §10) -----------------------------------------------------------


## Build the apron inside every detected junction footprint (§6, §10).
##
## THE HOLE THIS FILLS IS ONE THE MESHER CREATES ON PURPOSE. Approaches stop at the footprint so two
## roads never mesh the same cells, which leaves the footprint itself belonging to nobody — and the
## ground in there is real, graded road surface, so without this you see terrain through a hole at every
## crossroads.
##
## The apron follows the MAJOR road, because the major road is what graded that ground: the grader skips
## only the minor approaches. So the participant whose alignment the disc is built from is the same one
## that paved it, and the two agree by construction rather than by tuning.
func build_junction_surfaces(p_brushes: Array = []) -> int:
	var brushes: Array = p_brushes if not p_brushes.is_empty() else road_brushes()
	var by_key := {}
	for b in brushes:
		by_key[b.road_key()] = b
	var aprons: Array = []
	for j in junctions:
		if not j.detected or j.radius <= 0.01:
			continue
		var major_key: String = j.major_key()
		if not by_key.has(major_key):
			continue
		var b = by_key[major_key]
		var run: Dictionary = b.build_run()
		if run.is_empty():
			continue
		var t: Pasture3DRoadType = b.resolved_road_type()
		aprons.append({
			"id": j.id,
			"center": j.center,
			# The disc has to reach at least the trim-back the approaches stopped at, or the apron is
			# smaller than the hole it exists to fill and leaves a ring of bare ground round itself.
			"radius": maxf(j.radius, j.widest_trim_back()),
			"plan": run["plan"],
			"cum": run["cum"],
			"alignment": run["alignment"],
			"crown": t.crown if t != null else 0.05,
			"material": t.surface_material if t != null else null,
		})
	var host := ensure_junction_host()
	if host == null:
		return 0
	_configure_host(host)
	return host.rebuild_aprons(aprons, ribbon_lift)


## Fill in every Road Source node in `p_graph` with the geometry of the road it names. Returns how many
## were resolved.
##
## ---- WHY THE HOST HAS TO DO THIS ----
##
## A Pasture3DTerrainGraph is a Resource. It has no position in the scene, no parent, and no way to find a
## road brush — which is the property that makes a graph reusable across brushes and worth keeping. So
## a Road Source holds a road KEY, and whoever runs the graph resolves it, exactly as the input surface is
## handed in rather than fetched.
##
## An EMPTY key resolves to `p_default`, the brush hosting the graph. That is the common case by a wide
## margin: a graph on a road, talking about that road. Requiring the key to be typed out would make the
## first and simplest use of this feature the one that needs a name nobody has looked up yet.
##
## A key that names no road leaves the node's path ALONE rather than clearing it. Clearing would make a
## momentarily unresolvable road — one mid-rename, one whose brush is being reparented — flatten
## every terrain that reads it for one bake, in a way that looks like a solver bug rather than a lookup.
func resolve_graph_paths(p_graph: Pasture3DTerrainGraph, p_default: Node = null) -> int:
	if p_graph == null:
		return 0
	var by_key := {}
	var collected := false
	var filled := 0
	for node in p_graph.nodes:
		if node == null or node.op() != &"road_source":
			continue
		var src: Pasture3DGraphNodeRoadSource = node
		if src.road_key.is_empty():
			if p_default != null and p_default.has_method("graph_path"):
				_assign(src, p_default.call("graph_path"))
				filled += 1
			continue
		if not collected:
			collected = true
			for b in road_brushes():
				by_key[b.road_key()] = b
		if by_key.has(src.road_key):
			_assign(src, by_key[src.road_key].graph_path())
			filled += 1
	return filled


## Put a freshly built path onto a Road Source, but only when it actually differs.
##
## Assigning unconditionally would emit `changed` on every bake, which bumps the node's revision, which
## invalidates every downstream cache — so a graph containing a road would re-solve its erosion from
## scratch whenever anything in the scene was baked, and the cache would look broken rather than bypassed.
## Compared by CONTENT, because the path is rebuilt from the road each time and is a different object even
## when the road has not moved.
func _assign(p_src: Pasture3DGraphNodeRoadSource, p_path: Pasture3DGraphPath) -> void:
	if p_path == null:
		return
	var old := p_src.path
	if old != null and old.points == p_path.points and old.half_widths == p_path.half_widths:
		if old.heights == p_path.heights:
			return
	p_src.path = p_path


## The node the junction aprons hang from. On the NETWORK, because a junction belongs to no single road.
func ensure_junction_host() -> Pasture3DRoadChunkHost:
	for child in get_children():
		if child is Pasture3DRoadChunkHost:
			return child
	var host := Pasture3DRoadChunkHost.new()
	host.name = "JunctionSurfaces"
	add_child(host)
	return host


## Clear the reserved paint layer under every road about to be repainted, one box per layer.
##
## Grouped by layer AND by terrain: two groups paint into two different layers, and clearing one over the
## other's roads would erase a surface nobody was asking to repaint.
func _clear_paint_layers(p_brushes: Array) -> void:
	var boxes := {}
	for b in p_brushes:
		if b.terrain == null or b.terrain.data == null:
			continue
		if not b.terrain.data.has_method("clear_layer_in_area"):
			continue
		var layer_id: int = b.paint_layer_id()
		if layer_id < 0:
			continue
		var box: AABB = b.paint_bounds()
		if box.size == Vector3.ZERO:
			continue
		var key := "%d:%d" % [b.terrain.get_instance_id(), layer_id]
		if boxes.has(key):
			boxes[key]["box"] = (boxes[key]["box"] as AABB).merge(box)
		else:
			boxes[key] = {"terrain": b.terrain, "layer": layer_id, "box": box}
	for entry in boxes.values():
		# Composite deferred: the paint pass composites once at the end, so a clear that composited here
		# would push every touched region twice.
		entry["terrain"].data.clear_layer_in_area(int(entry["layer"]), entry["box"], false)


## Stable run ids, keyed by `road_key()`. Held so an id survives a re-resolve: a route names runs by id
## (§9.2), and an id that changed every bake would detach every route on every edit — the exact failure
## the id exists to prevent, arriving through the back door.
@export var run_ids: Dictionary = {}
@export var next_run_id: int = 0

## The baked runtime (§9.1). Exported so it saves with the scene and can be handed to a game, which then
## needs neither this node nor a terrain to read it.
@export var runtime: Pasture3DRoadRuntime


## Bake the resolved network into a resource a GAME can load — no editor plugin, no terrain (§9.1).
##
## Built AFTER the junction resolve and the lane graphs, because a run carries the alignment those
## produced and the links come from the junction records themselves. Building it earlier would bake the
## profiles roads wanted before they were asked to meet each other.
##
## Everything is COPIED. Nothing in the runtime may reach back into the scene: that is what makes the
## editor-free load real rather than aspirational, and it is why a run holds `source_key` as a string it
## never resolves.
func build_runtime(p_brushes: Array = []) -> int:
	var brushes: Array = p_brushes if not p_brushes.is_empty() else road_brushes()
	var rt := Pasture3DRoadRuntime.new()
	rt.built_at = Time.get_datetime_string_from_system()
	var id_of := {}
	for b in brushes:
		var run: Dictionary = b.build_run()
		if run.is_empty():
			continue
		var key: String = run["key"]
		if not run_ids.has(key):
			run_ids[key] = next_run_id
			next_run_id += 1
		var r := Pasture3DRoadRun.new()
		r.id = int(run_ids[key])
		r.source_key = key
		r.label = b.name
		r.plan = run["plan"]
		r.cum = run["cum"]
		r.alignment = run["alignment"]
		r.half_width = float(run["half_width"])
		var t: Pasture3DRoadType = b.resolved_road_type()
		if t != null:
			r.shoulder_width = t.shoulder_width
			r.crown = t.crown
		r.one_way = b.resolved_one_way()
		r.lanes = b.resolved_lanes()
		r.corridor_half_width = b.corridor_half_width()
		r.surfaces = b.surface_intervals()
		id_of[key] = r.id
		rt.runs.append(r)

	for j in junctions:
		if not j.detected:
			continue
		var ids := PackedInt32Array()
		var at_s := PackedFloat32Array()
		for i in j.road_keys.size():
			var k: String = j.road_keys[i]
			if not id_of.has(k):
				continue
			ids.append(int(id_of[k]))
			at_s.append(j.arc_lengths[i] if i < j.arc_lengths.size() else 0.0)
		# A link needs two ends. A junction whose other participants failed to bake is not a connection
		# yet, and recording it as one would let the validator pass a route across a gap.
		if ids.size() >= 2:
			rt.links.append({ "at": j.center, "runs": ids, "s": at_s })
	runtime = rt
	return rt.runs.size()


## Rebuild the built output every road needs and nothing saves: the ribbon chunks, the junction aprons
## and the lane graphs. Returns the number of roads restored.
##
## ---- WHAT THIS IS FOR ----
##
## Opening a scene used to give you a road that was in the terrain and nowhere else. The heightmap, the
## surface paint, the junction records, the connectors and the baked runtime all save; the mesh does not,
## and the solved profile did not either, so every road came back needing a manual bake — at which
## point it looked identical to how it had looked when you saved it. The whole symptom was that the work
## did not stick.
##
## ---- WHAT IT DELIBERATELY DOES NOT DO ----
##
## It does not grade, paint, or re-solve junctions, and that is the difference between this and
## `resolve_junctions`. Those three WROTE to the terrain and to `junctions`, and their results are on
## disk already. Redoing them at every scene open would rewrite the heightmap from a load hook —
## dirtying the scene, filling the undo history, and making an open-and-close a modification.
##
## A road whose stored profile no longer matches its spline is skipped rather than rebuilt from it, and
## said out loud, because "your road needs a bake" is a far better outcome than a ribbon confidently
## drawn along a centreline the road no longer has.
func restore_built_output() -> int:
	var brushes := road_brushes()
	if brushes.is_empty():
		return 0
	var ready: Array = []
	var stale := 0
	for b in brushes:
		if b.restorable_alignment() != null:
			ready.append(b)
		else:
			stale += 1
	if not ready.is_empty():
		_resolve_lane_graphs(ready)
		build_chunks(ready)
		update_gizmos()
	if Engine.is_editor_hint() and (not ready.is_empty() or stale > 0):
		print("[Pasture3D] roads restored on load: %d road(s) rebuilt from a saved profile, %d need a bake"
				% [ready.size(), stale])
	return ready.size()


## Rebuild every road's tier-MID ribbon (§10, P5b). Returns the total chunk count.
##
## Driven from here rather than from each brush's own bake for a plainer reason than the paint's: a road's
## chunks are cut around its JUNCTION footprints, and a junction is not resolved until every road that
## meets at it has baked. A brush chunking at the end of its own bake would cut around the footprints as
## they stood before the road it crosses had been placed.
func build_chunks(p_brushes: Array = []) -> int:
	var brushes: Array = p_brushes if not p_brushes.is_empty() else road_brushes()
	var total := 0
	var silent := 0
	for b in brushes:
		_configure_host(b.ensure_chunk_host())
		var made: int = b.rebuild_chunks(ribbon_lift)
		total += made
		if made == 0:
			silent += 1
	# Said out loud in the editor, because every way this returns zero is a SILENT one: no alignment yet,
	# no road type, no spans left after the footprints. The road looks exactly the same in all of them and
	# exactly the same as when the pass never ran at all, which is the state that wastes the most time.
	total += build_junction_surfaces(brushes)
	if Engine.is_editor_hint() and not brushes.is_empty():
		print("[Pasture3D] road ribbons: %d chunk(s) across %d road(s); %d road(s) built nothing"
				% [total, brushes.size(), silent])
	return total


## The order roads must be painted in: LOWEST PRIORITY FIRST, so the most important road writes last
## and is the one you see where two overlap.
##
## Separated from `paint_roads` because it is the only part of the pass that can be checked without a
## terrain — and it is the part that is silently wrong, since a paint in the wrong order still produces
## a fully painted road, just the other road's.
func paint_order(p_brushes: Array) -> Array:
	var ordered: Array = p_brushes.duplicate()
	ordered.sort_custom(func(a, b) -> bool: return a.road_priority() < b.road_priority())
	return ordered


## Paint every road's surface into its reserved layer, LOWEST PRIORITY FIRST.
##
## The order is the whole point of doing this here rather than in each brush's bake. Where two roads
## overlap, the layer is REPLACE and the last write wins — so painting in ascending priority makes the
## more important road the one you see, which is what §5.2 says priority means and what a brush painting
## itself at the end of its own bake cannot arrange, because bakes happen in scene order.
##
## Returns the number of cells written across every road.
func paint_roads(p_brushes: Array = []) -> int:
	var brushes: Array = p_brushes if not p_brushes.is_empty() else road_brushes()
	if brushes.is_empty():
		return 0
	var ordered := paint_order(brushes)
	var written := 0
	var terrains := {}
	# CLEAR BEFORE PAINTING. Nothing else does it: the height layer is reconciled by the terrain brush on
	# every bake, but the paint layer is written here and would otherwise keep every cell any road has ever
	# covered — so moving a road left its old carriageway painted across the landscape behind it, with the
	# new one painted beside it. Cleared as one box per layer over the union of the roads that share it,
	# because the whole pass repaints all of them: clearing per road would drop a neighbour's cells at a
	# shared tile boundary (clear_layer_in_area drops WHOLE tiles) and only the road painted afterwards
	# would put them back.
	_clear_paint_layers(ordered)
	for b in ordered:
		written += b.paint_surface()
		if b.terrain != null:
			terrains[b.terrain.get_instance_id()] = b.terrain
	# One composite for the whole pass. Each road painted with `composite` off, so an overlap is
	# composited once rather than once per road that touched it.
	if written > 0:
		for t in terrains.values():
			if t.data != null and t.data.has_method("composite_regions"):
				t.data.composite_regions()
	return written
