# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadPhase — one signal phase of a signalised junction: which arms are green, and for how
# long. See PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §6.4.
#
# ---- ONE PHASE PER ROAD, AND THE GREEN TIME COMES FROM PRIORITY ----
#
# A road's own two arms never need separating from each other: traffic along a road does not cross its
# own path, and the one movement that does — the turn across the oncoming carriageway — is governed by
# the yield relations, which hold on a green light exactly as they hold at an uncontrolled crossroads.
# So the phase groups are the participating ROADS, and a crossroads gets the two-phase cycle everyone
# expects without a graph colouring that would produce the same answer more slowly and less predictably.
#
# Green time is each road's share of the total `priority` (§5.2), floored so a minor road is never
# starved. That is the whole of what "the higher-priority road gets the longer green" means, and it is
# derived rather than authored so it tracks a priority edit without anyone re-timing the junction.
@tool
class_name Pasture3DRoadPhase
extends Resource

## What a consumer sees when it asks an arm for its signal. NONE is not a colour: it means this junction
## is not signalised at all, and the consumer should be reading the yield relations instead. Returning
## GREEN there would be a lie that a naive consumer would drive straight through a stop sign on.
enum State { NONE = -1, GREEN = 0, YELLOW = 1, RED = 2 }

## The roads whose arms are green in this phase. A road, not an arm: both ends go green together.
@export var road_keys: PackedStringArray = PackedStringArray()
## Seconds of green.
@export var green_time: float = 20.0
## Seconds of yellow after it. Traffic in this phase is still moving but must not enter.
@export var yellow_time: float = 3.0


## Total time this phase holds the cycle.
func duration() -> float:
	return maxf(green_time, 0.0) + maxf(yellow_time, 0.0)


## Whether `p_key`'s arms are the ones this phase serves.
func serves(p_key: String) -> bool:
	return road_keys.has(p_key)
