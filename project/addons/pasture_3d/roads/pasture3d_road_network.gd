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
	for b in brushes:
		if b.junction_digest() != b.last_junction_digest:
			b.schedule_junction_rebake()


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
