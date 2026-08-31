# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadLaneConnector — one legal path through a junction: from an incoming lane to an outgoing
# lane, as a short curve. See PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §6.4.
#
# ---- THE ANSWER TO "WHAT ARE MY LEGAL NEXT LANES" ----
#
# A consumer holding a lane asks the network for its connectors and gets these. Everything it needs is
# on the record — where the path goes, what kind of turn it is, and whether it is allowed — so following
# one requires no geometry of its own. That is the P4b completeness bar (§6.4): if a naive consumer has
# to re-derive geometry, the data is wrong.
#
# ---- GENERATED, BUT NOT DISPOSABLE ----
#
# Connectors are derived from the junction's arms, so the solver rebuilds them whenever the roads move.
# `allowed_override` is the one field it must never write: "no left turn here" is a decision about a
# place, and losing it because a spline 300 m away was nudged is the same failure the junction's own
# override split exists to prevent (§6).
@tool
class_name Pasture3DRoadLaneConnector
extends Resource

## Which end of a road an endpoint sits at. A road crosses the junction, so it presents lanes at BOTH
## the arc length before the footprint and the one after it, and "incoming" is a fact about the pair
## (end, lane direction) rather than about either alone.
enum End { BEFORE = 0, AFTER = 1 }

## What kind of turn this is, from the angle between the two headings. Geometry, not intent — a
## consumer that wants "the road ahead" asks for STRAIGHT rather than pattern-matching on road names.
enum Turn { STRAIGHT = 0, LEFT = 1, RIGHT = 2, U_TURN = 3 }

## Whether the connector may be used. INHERIT takes the generated default.
enum Tri { INHERIT = -1, OFF = 0, ON = 1 }

@export_group("Identity")
## Stable across re-resolves; derived from the two endpoints. See `make_id`.
@export var id: StringName = &""

@export_group("From")
## Content key of the road the vehicle arrives on.
@export var from_key: String = ""
## Index into that road's cross-section (Pasture3DRoadLanes.cross_section), NOT an ordinal.
@export var from_lane: int = 0
## Which end of that road the vehicle arrives at.
@export var from_end: End = End.BEFORE

@export_group("To")
@export var to_key: String = ""
@export var to_lane: int = 0
@export var to_end: End = End.AFTER

@export_group("Resolved")
## Solver output — overwritten on every resolve.
## The path through the junction, in WORLD space, tangent-continuous with both lanes at its ends.
@export var curve: Curve3D
## What kind of turn this is.
@export var turn: Turn = Turn.STRAIGHT
## Signed angle between the two headings, radians; positive turns RIGHT (the driver's right, the
## convention the whole road system shares). `turn` is this bucketed, kept
## alongside it because "how sharp" is a different question from "which way" and a consumer choosing a
## speed wants the number.
@export var turn_angle: float = 0.0
## Whether the generator considered this turn legal. The default `allowed()` falls back to.
@export var default_allowed: bool = true
## True when this turn crosses the oncoming carriageway — a left turn where traffic drives on the right,
## a right turn where it drives on the left.
##
## This is where `traffic_side` stops being cosmetic and becomes load-bearing (§6.4). The turn KIND is
## pure geometry and says nothing about conflict; whether it cuts across traffic coming the other way is
## the fact a consumer actually needs to yield correctly, and it is one a consumer cannot derive without
## knowing the world's handedness. So it is published rather than implied.
@export var crosses_oncoming: bool = false

@export_group("Overrides")
## The user's decision. Never written by the solver.
@export var allowed_override: Tri = Tri.INHERIT


## The id a connector between these two endpoints would have. Built from the endpoints alone, so it
## survives the junction's centre moving, the other arms changing, and the connector list being
## regenerated in a different order.
static func make_id(p_from_key: String, p_from_lane: int, p_from_end: int,
		p_to_key: String, p_to_lane: int, p_to_end: int) -> StringName:
	return StringName("%s:%d:%d>%s:%d:%d" % [p_from_key, p_from_lane, p_from_end,
			p_to_key, p_to_lane, p_to_end])


## Whether this connector may be used, honouring the override.
func allowed() -> bool:
	if allowed_override == Tri.INHERIT:
		return default_allowed
	return allowed_override == Tri.ON


## Where the path starts and ends, in world space. Convenience for a consumer that wants the endpoints
## without walking the curve.
func entry_point() -> Vector3:
	return curve.get_point_position(0) if curve != null and curve.point_count > 0 else Vector3.ZERO


func exit_point() -> Vector3:
	return curve.get_point_position(curve.point_count - 1) if curve != null and curve.point_count > 0 else Vector3.ZERO
