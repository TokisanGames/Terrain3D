# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadConflict — one directed right-of-way relation: the connector that must give way, the one
# that has priority, and where their paths meet. See PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §6.4.
#
# ---- RIGHT OF WAY IS BETWEEN PATHS, NOT BETWEEN ROADS ----
#
# "The minor road yields to the major road" is nearly right and useless in practice: a right turn off the
# minor road onto the major one crosses nothing, and a left turn off the MAJOR road crosses the major
# road's own oncoming traffic. Both facts are invisible to a per-road relation and obvious to a
# per-connector one, because two movements only conflict if their paths actually meet.
#
# So a conflict is a fact about a PAIR OF CONNECTORS, and it is emitted only where the two curves cross
# (or merge into the same exit). "Who do I yield to" — the fourth of §6.4's four queries — is then a
# filter over these, and a consumer needs no geometry of its own to answer it.
#
# ---- CONTROL DECIDES HOW IT IS ENFORCED, NOT WHO GOES ----
#
# These relations are the same whether the junction is uncontrolled, signposted or signalised. A stop
# sign says a vehicle must HALT before proceeding; a signal says it must WAIT ITS PHASE; neither changes
# who has right of way once both are moving, which is why `control` is not an input here. A permissive
# turn across oncoming traffic yields on a green light for exactly the reason it yields at an
# uncontrolled crossroads, and that comes out of one rule rather than two.
@tool
class_name Pasture3DRoadConflict
extends Resource

## Why the yielding movement gives way. Published because a consumer that wants to explain itself — or
## to model a driver who creeps into a gap on a permissive turn but never runs a priority road — needs
## the kind, not just the fact.
enum Reason {
	## The road with the lower `priority` gives way (§5.2).
	PRIORITY = 0,
	## Equal priority, but this movement cuts across the oncoming carriageway and the other does not.
	TURN_ACROSS = 1,
	## Equal priority and neither crosses oncoming: give way to the vehicle approaching from the side
	## the world's handedness names. Right-hand traffic yields to the right.
	APPROACH_SIDE = 2,
	## Equal in every rule above — two head-on movements that meet. Emitted in BOTH directions, so a
	## consumer sees a mutual hold rather than a phantom winner. This is the case a signal or a stop
	## sign exists to break.
	MUTUAL = 3,
}

## The connector that must give way.
@export var yielding_id: StringName = &""
## The connector with right of way over it.
@export var priority_id: StringName = &""
## Where the two paths meet, world space. A merge reports the shared exit; a crossing reports the
## crossing. Given so a consumer can measure how far it is from the conflict without walking a curve.
@export var point: Vector3 = Vector3.ZERO
## True when the paths do not cross but END at the same lane — a merge rather than a crossing. Worth
## distinguishing: a crossing is cleared by waiting, a merge is cleared by finding a gap.
@export var merge: bool = false
@export var reason: Reason = Reason.PRIORITY
