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
