# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadStopLine — where a vehicle in one incoming lane should hold at a junction.
# See PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §6.4.
#
# ---- WHY THIS IS DATA AND NOT A CONSUMER'S PROBLEM ----
#
# It is trivial to emit here: the trim-back boundary already exists, and the lane centre and heading at
# that arc length are what the connector generator just computed. It is painful to reconstruct: a
# consumer would have to find the junction, work out the trim-back, project its lane onto the plan and
# solve for the arc length — re-deriving geometry, which is the test §6.4 sets for what belongs in the
# published data.
#
# One per INCOMING lane per junction. An outgoing lane has nothing to hold for.
@tool
class_name Pasture3DRoadStopLine
extends Resource

## The road the vehicle is on.
@export var road_key: String = ""
## Index into that road's cross-section, matching Pasture3DRoadLaneConnector.from_lane.
@export var lane: int = 0
## Which end of the road this lane arrives at, matching the connector's `from_end`.
@export var end: int = 0

## Lane centre at the hold point, world space. The road's solved elevation is already in the Y.
@export var point: Vector3 = Vector3.ZERO
## Direction of travel there, world XZ, normalised and pointing INTO the junction. A vehicle has
## stopped correctly when its progress along this direction reaches the point.
@export var heading: Vector2 = Vector2.RIGHT
## Width of the lane the line spans, metres — enough to draw the line, or to test whether a vehicle is
## within its own lane at the hold.
@export var width: float = 3.5


## The two ends of the painted line, world space: the lane centre offset either way along the lane's
## left normal by half its width.
func endpoints() -> Array:
	var n := Vector2(-heading.y, heading.x) * (width * 0.5)
	return [point + Vector3(n.x, 0.0, n.y), point - Vector3(n.x, 0.0, n.y)]
