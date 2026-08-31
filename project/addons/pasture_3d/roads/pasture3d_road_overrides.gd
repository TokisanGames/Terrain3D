# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadOverrides — the inheritable field set shared by every level of the road hierarchy, and
# the resolver that walks them. See PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §5.3.
#
# ---- WHY OVERRIDES RESOLVE AT READ AND ARE NEVER PUSHED DOWN ----
#
# The obvious design is for a RoadGroup to copy its settings onto its children when they are added and
# re-push them when the group changes, with a child free to override. That design has a defect that
# surfaces the first week it is used: it cannot distinguish "this brush has 2 lanes because it inherited
# 2" from "this brush was deliberately set to 2". When the group moves to 4 there is no way to know which
# children should follow, so either every override is silently destroyed or none of them update.
#
# So nothing is ever copied. Each level stores only what it OVERRIDES, unset fields carry a sentinel, and
# a read walks Segment -> Brush -> Group -> Network -> the RoadType's own default and returns the first
# level that has an opinion. "Reset to inherited" is then a one-click clear rather than a value the user
# has to remember and retype, and a group edit moves exactly the children that never disagreed.
#
# ---- THE SENTINELS ----
#
# GDScript has no nullable int or float, so "unset" is a value rather than an absence. One rule covers
# every field, which is what keeps `is_unset` a single function rather than a per-field table:
#
#   Object / Resource   unset when null
#   int (and enums)     unset when NEGATIVE — every road enum below therefore declares INHERIT = -1
#   float               unset when NaN — the same "no data here" NaN the terrain sampler and the brush
#                       loop boundary already use, so the convention is not a new one to learn
#   String/StringName   unset when empty
#
# A bool has no spare value, so a tri-state enum is used instead. That is why there is no plain bool in
# the field set below.
@tool
class_name Pasture3DRoadOverrides
extends Resource

## Tri-state stand-in for a bool, because a bool has no value left over to mean "inherit".
enum Tri { INHERIT = -1, OFF = 0, ON = 1 }
## Which way traffic runs along the road. INHERIT defers to the level above.
enum TrafficFlow { INHERIT = -1, ONE_WAY = 0, TWO_WAY = 1 }

## The road type this level selects. Null inherits. The type also supplies the FINAL fallback for
## several fields below, so the resolved type is looked up first and then asked for its own defaults.
@export var road_type: Pasture3DRoadType = null:
	set(v):
		road_type = v
		emit_changed()

## Lanes across the carriageway. -1 inherits.
@export var lane_count: int = -1:
	set(v):
		lane_count = v if v < 0 else maxi(v, 1)
		emit_changed()

## One-way or two-way. INHERIT defers.
@export var traffic_flow: TrafficFlow = TrafficFlow.INHERIT:
	set(v):
		traffic_flow = v
		emit_changed()

## Physics surface (&"tarmac", &"gravel", …). Empty inherits. This is the field a mid-stage surface
## change overrides on a single segment — see PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §4.4.
@export var surface_id: StringName = &"":
	set(v):
		surface_id = v
		emit_changed()

## Signposted speed, m/s, published for consumers. NaN inherits.
@export var speed_limit: float = NAN:
	set(v):
		speed_limit = v
		emit_changed()

## ON drapes the road on the terrain instead of solving a grade-limited alignment (P1). INHERIT defers.
## Off is the default at the network level: a draped road is the failure the alignment solver exists to
## avoid, and it should be asked for explicitly rather than fallen into.
@export var follow_terrain: Tri = Tri.INHERIT:
	set(v):
		follow_terrain = v
		emit_changed()


## Every field this resource inherits, in one place, so the resolver and the gate cannot drift from the
## export list above.
const FIELDS: Array[StringName] = [
	&"road_type", &"lane_count", &"traffic_flow", &"surface_id", &"speed_limit", &"follow_terrain",
]


## True when `p_value` carries this field set's "no opinion" sentinel. One rule per type — see the
## header. Note a NEGATIVE int is unset, which is why every road enum declares INHERIT = -1.
static func is_unset(p_value: Variant) -> bool:
	if p_value == null:
		return true
	match typeof(p_value):
		TYPE_INT:
			return int(p_value) < 0
		TYPE_FLOAT:
			return is_nan(float(p_value))
		TYPE_STRING, TYPE_STRING_NAME:
			return String(p_value).is_empty()
	return false


## Walk `p_chain` (nearest level FIRST) and return the first level with an opinion about `p_field`.
## Returns null when nobody sets it — an unset field is not an error, it is a question for the RoadType.
static func resolve(p_chain: Array, p_field: StringName) -> Variant:
	for src: Object in p_chain:
		if src == null:
			continue
		var v: Variant = src.get(p_field)
		if not is_unset(v):
			return v
	return null


## Clear every override on this level, so it inherits wholesale. The "reset to inherited" the push-down
## design could not offer.
func clear_overrides() -> void:
	road_type = null
	lane_count = -1
	traffic_flow = TrafficFlow.INHERIT
	surface_id = &""
	speed_limit = NAN
	follow_terrain = Tri.INHERIT


## True when this level has no opinion about anything — the state a freshly added Group or Brush is in,
## and the state `clear_overrides` returns it to.
func is_empty() -> bool:
	for f: StringName in FIELDS:
		if not is_unset(get(f)):
			return false
	return true
