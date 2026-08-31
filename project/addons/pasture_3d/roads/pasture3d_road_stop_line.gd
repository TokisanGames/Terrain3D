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
## Arc length along `road_key` at which the line sits, metres.
##
## Added because the reference agent could not do without it: a vehicle tracks its own position as an
## arc length, and turning the world-space `point` back into one means projecting onto the road's plan
## and solving — re-deriving geometry, which §6.4 says is the sign the published data is incomplete.
## It costs nothing here: the solver already knows the arc length, because the trim-back is what put
## the line where it is.
@export var distance: float = NAN
## Width of the lane the line spans, metres — enough to draw the line, or to test whether a vehicle is
## within its own lane at the hold.
@export var width: float = 3.5


## The two ends of the painted line, world space: the lane centre offset half a width either way along
## the across-road normal. Symmetric, so which of the two directions is the driver's right does not
## change the answer — but it is the RIGHT, and saying otherwise is how the convention drifts.
func endpoints() -> Array:
	var n := Vector2(-heading.y, heading.x) * (width * 0.5)
	return [point + Vector3(n.x, 0.0, n.y), point - Vector3(n.x, 0.0, n.y)]
