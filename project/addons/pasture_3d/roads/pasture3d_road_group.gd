# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadGroup — a container for road brushes that share a purpose: "Highways", "Farm Tracks",
# "Pit Lane". It sits between the network and the brushes in the resolve chain, contributes road types
# of its own, may hide network types from its children, and owns the terrain layer its roads paint into.
# See PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §5.1.
#
# It does NOT push settings onto its children. See Pasture3DRoadOverrides' header for why: a pushed-down
# value cannot be told apart from a deliberate override, so a group edit either destroys every override
# or updates nothing. Children read up the chain instead, which makes a group edit move exactly the
# brushes that never disagreed.
@tool
@icon("res://addons/pasture_3d/icons/brush_terrain.svg")
class_name Pasture3DRoadGroup
extends Node3D

## Blend and map type of the reserved surface layer. REPLACE, because the topmost covered layer wins and
## a road is opaque where it covers: two roads in one group that overlap should show the one that
## painted last, which the network orders by priority.
const PAINT_LAYER_BLEND: int = 0 # Pasture3DLayer.BLEND_REPLACE
const PAINT_LAYER_MAPTYPE: int = 1 # Pasture3DData.MapType.TYPE_CONTROL

@export_group("Catalogue")
## Road types unique to this group's children — a pit-lane surface no other road should offer.
@export var group_road_types: Array[Pasture3DRoadType] = []:
	set(v):
		group_road_types = v
		_bump()

## Network types this group's children may NOT use. Held BY REFERENCE, never by index into the
## network's array: an exclusion list of indices silently re-points at different types the moment
## anyone reorders the catalogue, which is the kind of bug that is found months later in saved content.
@export var excluded_road_types: Array[Pasture3DRoadType] = []:
	set(v):
		excluded_road_types = v
		_bump()

@export_group("Terrain")
## Display name of the terrain layer this group's roads paint into (P5). Created reserved and owned —
## Pasture3DLayer already has `set_reserved` / `set_owner_id` precisely so a tool can hold a layer that
## users cannot hand-edit out from under it.
@export var layer_name: String = "Roads":
	set(v):
		layer_name = v
		_bump()

@export_group("Defaults")
## What this group's brushes use where they have no opinion of their own. Sits between the brush and
## the network in the chain (§5.3).
@export var road_defaults: Pasture3DRoadOverrides:
	set(v):
		if road_defaults != null and road_defaults.changed.is_connected(_bump):
			road_defaults.changed.disconnect(_bump)
		road_defaults = v
		if road_defaults != null and not road_defaults.changed.is_connected(_bump):
			road_defaults.changed.connect(_bump)
		_bump()

## Bumped when anything that could change a child's resolved value changes.
var content_key: int = 0


func _init() -> void:
	if road_defaults == null:
		road_defaults = Pasture3DRoadOverrides.new()


func _ready() -> void:
	if road_defaults != null and not road_defaults.changed.is_connected(_bump):
		road_defaults.changed.connect(_bump)


func _bump() -> void:
	content_key += 1
	update_configuration_warnings()


## The nearest Pasture3DRoadGroup at or above `p_node`, or null. A group is OPTIONAL — a brush parented
## straight under the network resolves against the network alone.
static func find_for(p_node: Node) -> Pasture3DRoadGroup:
	var n: Node = p_node
	while n != null:
		if n is Pasture3DRoadGroup:
			return n as Pasture3DRoadGroup
		n = n.get_parent()
	return null


## The types this group's children may choose from: the group's own, plus every network type that has
## not been excluded. Comparison is by reference, so reordering the network catalogue changes nothing.
func available_road_types() -> Array[Pasture3DRoadType]:
	var out: Array[Pasture3DRoadType] = []
	for t: Pasture3DRoadType in group_road_types:
		if t != null and not out.has(t):
			out.append(t)
	var net := Pasture3DRoadNetwork.find_for(self)
	if net != null:
		for t: Pasture3DRoadType in net.valid_road_types():
			if not excluded_road_types.has(t) and not out.has(t):
				out.append(t)
	return out


func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if Pasture3DRoadNetwork.find_for(self) == null:
		out.append("No Pasture3DRoadNetwork above this group. Its children can only use the group's own road types.")
	if available_road_types().is_empty():
		out.append("No road types available to this group's children — everything is excluded, or the catalogue is empty.")
	return out

# ---- The reserved surface layer (P5, §10) ------------------------------------------------------------


## The reserved CONTROL layer this group's roads paint their surface into, created on first use.
##
## Reserved and owned, which is what stops a user hand-deleting it in the layers dock and leaving every
## road in the group painting into whatever happened to take its index. Negative on a terrain or a
## build without the typed-layer API — the paint then does nothing at all, rather than falling back to
## writing the control map destructively: a road that permanently overwrote hand-painted texturing the
## first time somebody nudged a spline is worse than a road that is not painted yet.
func ensure_paint_layer(p_terrain: Node) -> int:
	if p_terrain == null or p_terrain.get("data") == null:
		return -1
	var data = p_terrain.data
	if not data.has_method("create_owned_layer_typed"):
		return -1
	return int(data.create_owned_layer_typed(paint_layer_owner(), layer_name,
			PAINT_LAYER_BLEND, PAINT_LAYER_MAPTYPE))


## Owner id of that layer. Keyed on the group's own path so two groups in one scene own two
## layers even when the user named them both "Roads" — an owner keyed on the display name would silently
## merge them, and the first the user knew of it would be one group's edits moving the other's roads.
func paint_layer_owner() -> String:
	return "pasture3d_road_group:%s" % str(get_path())
