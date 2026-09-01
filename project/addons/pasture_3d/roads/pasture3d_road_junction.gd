# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadJunction — one resolved intersection: which roads meet, where along each of them, how far
# each is trimmed back, what height the junction sits at, and which road's decision that was.
# See PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §6.
#
# ---- THIS IS STORED, NOT RECOMPUTED (§6, addition 2) ----
#
# Auto-detection decides that a junction EXISTS. It does not get to decide everything about it: a user who
# set "traffic light, no left turn" here must not lose that because a spline 300 m away was nudged. So a
# resolved junction is a saved resource with a stable id, and the network RECONCILES on change — matching
# detections to existing records by their participants and position — rather than rebuilding the set.
#
# The fields split accordingly. Everything under Resolved is the solver's output and is overwritten on
# every resolve. Everything under Overrides is the user's and is never written by the solver; a negative
# or empty value means "no opinion, use the resolved one". That split is the same one the §5.3 resolve
# chain makes, and for the same reason: a value that cannot say whether it was authored or inherited
# cannot be safely recomputed.
@tool
class_name Pasture3DRoadJunction
extends Resource

## What decides right of way here. Geometry only in P4a — the lane connectors, stop lines and phase
## groups this feeds are P4b. It lives here rather than there because it is the user's authored choice
## and has to survive a re-resolve from the moment they can make it.
# NOT named `Control`: that is a built-in Godot Node class, and the annotation silently resolved to it
# rather than to this enum — five parse errors, none of which named the collision.
enum ControlType { INHERIT = -1, UNCONTROLLED = 0, PRIORITY = 1, STOP = 2, SIGNALS = 3 }

@export_group("Identity")
## Stable across re-resolves. Derived from the participants rather than from an index, so inserting an
## unrelated road elsewhere in the scene does not renumber every junction and detach every override.
@export var id: StringName = &""

@export_group("Resolved")
## Solver output — overwritten on every resolve. Do not hand-edit; use the Overrides below.
## World XZ of the junction centre.
@export var center: Vector2 = Vector2.ZERO
## Content keys of the roads that meet here, in the order the solver found them.
@export var road_keys: PackedStringArray = PackedStringArray()
## Arc length along each participating road at which it enters the junction, metres, parallel to
## `road_keys`.
@export var arc_lengths: PackedFloat32Array = PackedFloat32Array()
## How far each participant is trimmed back from `center`, metres, parallel to `road_keys`. The distance
## at which that road's grading stops so it meets the junction footprint rather than running through it.
@export var trim_backs: PackedFloat32Array = PackedFloat32Array()
## Radius of the junction footprint, metres — the disc the trimmed approaches surround.
@export var radius: float = 0.0
## Solved height of the junction, metres. The MAJOR road's height at its own arc length: a junction that
## averaged its approaches would put a dip or a hump in the road that had right of way.
@export var elevation: float = 0.0
## Index into `road_keys` of the road whose priority won. Its alignment is left alone; every other
## participant is pinned to `elevation` at its arc length.
@export var major_index: int = 0
## True when the solver last ran and found this junction still geometrically real. A junction that stops
## being detected is kept (its overrides may be wanted again) but marked, rather than deleted outright.
@export var detected: bool = true

@export_group("Lane graph")
## The legal paths through this junction, one per (incoming lane, outgoing lane) pair the generator
## allowed. Solver output EXCEPT each connector's own `allowed_override`, which is reconciled by id and
## never rewritten — see Pasture3DRoadLaneConnector.
@export var connectors: Array[Pasture3DRoadLaneConnector] = []
## Where a vehicle holds, one per incoming lane. Purely derived: unlike the connectors there is nothing
## on a stop line for a user to author, so these are rebuilt outright on every resolve.
@export var stop_lines: Array[Pasture3DRoadStopLine] = []

@export_group("Right of way")
## Resolved `priority` of each participant (§5.2), parallel to `road_keys`. Stored rather than looked up
## because right of way must still answer after a road is deleted from the scene: a junction that has
## stopped being detected keeps its overrides, and an override on a relation nobody can evaluate is not
## an override.
@export var priorities: PackedInt32Array = PackedInt32Array()
## Every directed yield relation between movements that meet here. Purely derived; rebuilt each resolve.
@export var conflicts: Array[Pasture3DRoadConflict] = []
## The signal cycle, one phase per participating road. Present whether or not `control` is SIGNALS — the
## timings are derived from priority and cost nothing to keep, and a junction switched to signals at
## runtime is then already timed.
@export var phases: Array[Pasture3DRoadPhase] = []

## Where the cycle is right now. RUNTIME STATE, deliberately not exported: a saved scene that remembered
## its lights would come back with every junction in the world mid-phase at whatever moment it was saved.
var phase_index: int = 0
var phase_elapsed: float = 0.0

@export_group("Overrides")
## The user's choices. Never written by the solver.
@export var control: ControlType = ControlType.INHERIT
## Force a different participant to be the major road. -1 leaves it to priority.
@export var major_override: int = -1
## Widen the junction footprint beyond what the geometry implies, metres. Negative inherits. Cannot make
## it SMALLER than the resolved radius: a footprint tighter than the conflict area would put two roads'
## grading in the same cells, which is the overlap the trim-back exists to prevent.
@export var radius_override: float = -1.0
## Suppress this junction entirely — the roads simply cross, ungraded and unconnected. The escape hatch
## for a detection the author disagrees with, and the reason detection never has to be perfect.
@export var disabled: bool = false


## The id a junction between these roads at this place would have. Built from the SORTED participant
## keys, so the same junction gets the same id no matter which road the solver happened to walk first,
## plus the centre rounded to a metre — two distinct junctions between the same pair of roads (a road
## that crosses another twice) stay distinct, and a re-resolve that moves the centre slightly keeps it.
static func make_id(p_road_keys: PackedStringArray, p_center: Vector2) -> StringName:
	var keys := Array(p_road_keys)
	keys.sort()
	return StringName("%s@%d,%d" % ["+".join(keys), int(round(p_center.x)), int(round(p_center.y))])


## Effective radius, honouring the override but never letting it shrink the conflict area.
func effective_radius() -> float:
	return maxf(radius_override, radius) if radius_override >= 0.0 else radius


## Which participant is the major road, honouring the override.
func effective_major() -> int:
	if major_override >= 0 and major_override < road_keys.size():
		return major_override
	return clampi(major_index, 0, maxi(road_keys.size() - 1, 0))


## Index of `p_key` among the participants, or -1.
func participant_index(p_key: String) -> int:
	for i in road_keys.size():
		if road_keys[i] == p_key:
			return i
	return -1


## Arc length at which `p_key` enters this junction, or NAN when it is not a participant.
func arc_length_for(p_key: String) -> float:
	var i := participant_index(p_key)
	return arc_lengths[i] if i >= 0 and i < arc_lengths.size() else NAN


## How far `p_key` is trimmed back here, or 0.
func trim_back_for(p_key: String) -> float:
	var i := participant_index(p_key)
	if i < 0 or i >= trim_backs.size():
		return 0.0
	# An override that widens the footprint has to push the approaches back with it, or the roads would
	# be graded into ground the junction now claims.
	var extra := maxf(effective_radius() - radius, 0.0)
	return trim_backs[i] + extra


## True when `p_key` is the road that keeps its own alignment through here.
func is_major(p_key: String) -> bool:
	return participant_index(p_key) == effective_major()


## The height `p_key` must be pinned to at its crossing, or NAN when it is the major road (which is
## pinned to nothing — it keeps the profile it solved) or is not a participant.
##
## Returning a PIN rather than a height to write is the whole trick: P1 already honours pins exactly and
## already reports an impossible pair as an infeasible gradient breach. A junction that cannot be built
## at the grade it demands therefore surfaces through machinery that exists and is gated, instead of
## through a new failure mode of its own.
## The legal connectors leaving one lane of one road at one end — the answer to "what are my legal next
## lanes". Forbidden connectors are filtered here rather than by the caller, so a consumer that ignores
## `allowed()` cannot accidentally drive a banned turn.
func connectors_from(p_key: String, p_lane: int, p_end: int) -> Array:
	var out: Array = []
	if disabled:
		return out
	for c in connectors:
		if c != null and c.from_key == p_key and c.from_lane == p_lane and c.from_end == p_end \
				and c.allowed():
			out.append(c)
	return out


## Where a vehicle in one lane holds at this junction, or null when that lane is not an incoming one.
func stop_line_for(p_key: String, p_lane: int, p_end: int) -> Pasture3DRoadStopLine:
	for sl in stop_lines:
		if sl != null and sl.road_key == p_key and sl.lane == p_lane and sl.end == p_end:
			return sl
	return null


func pin_for(p_key: String) -> float:
	if disabled:
		return NAN
	var i := participant_index(p_key)
	if i < 0 or i == effective_major():
		return NAN
	return elevation


# ---- RIGHT OF WAY (P4b) -----------------------------------------------------------------------------
#
# The last two of §6.4's four queries. Both are answered from stored records, so a consumer needs no
# geometry: `signal_state` reads the cycle, `yields_to` filters the conflict set.


## What kind of control this junction has, resolving INHERIT against the world default.
func effective_control(p_default: ControlType = ControlType.PRIORITY) -> ControlType:
	return p_default if control == ControlType.INHERIT else control


## Advance the signal cycle by `p_delta` seconds. Does nothing at a junction that is not signalised, so
## the network can call it on everything without asking first. Returns true when the phase changed.
func advance_signals(p_delta: float, p_default: ControlType = ControlType.PRIORITY) -> bool:
	if phases.is_empty() or effective_control(p_default) != ControlType.SIGNALS or disabled:
		return false
	phase_elapsed += maxf(p_delta, 0.0)
	var changed := false
	# A loop rather than a single test: a long frame — a stall, a level load, a debugger step — must not
	# leave the cycle a whole phase behind and then catch up one phase per frame.
	var guard := 0
	while phase_elapsed >= phases[phase_index].duration() and guard < 64:
		phase_elapsed -= phases[phase_index].duration()
		phase_index = (phase_index + 1) % phases.size()
		changed = true
		guard += 1
	return changed


## Index of the phase serving `p_key`, or -1 when no phase does.
func phase_for(p_key: String) -> int:
	for i in phases.size():
		if phases[i] != null and phases[i].serves(p_key):
			return i
	return -1


## The signal a vehicle on `p_key` sees, as a Pasture3DRoadPhase.State.
##
## NONE at a junction that is not signalised — which is NOT the same as green. A consumer that gets NONE
## must fall back on `yields_to`; one that gets GREEN may go once its conflicts are clear. Collapsing the
## two would make an uncontrolled crossroads read as a green light in every direction.
func signal_state(p_key: String, p_default: ControlType = ControlType.PRIORITY) -> int:
	if disabled or phases.is_empty() or effective_control(p_default) != ControlType.SIGNALS:
		return Pasture3DRoadPhase.State.NONE
	var mine := phase_for(p_key)
	if mine < 0:
		return Pasture3DRoadPhase.State.RED
	if mine != phase_index:
		return Pasture3DRoadPhase.State.RED
	var ph := phases[phase_index]
	return Pasture3DRoadPhase.State.GREEN if phase_elapsed < ph.green_time 			else Pasture3DRoadPhase.State.YELLOW


## Seconds until the signal `p_key` sees changes, or NAN when the junction is not signalised. What a
## consumer deciding whether to stop for a yellow actually needs.
func signal_time_remaining(p_key: String, p_default: ControlType = ControlType.PRIORITY) -> float:
	if signal_state(p_key, p_default) == Pasture3DRoadPhase.State.NONE:
		return NAN
	var mine := phase_for(p_key)
	if mine == phase_index:
		var ph := phases[phase_index]
		if phase_elapsed < ph.green_time:
			return ph.green_time - phase_elapsed
		return ph.duration() - phase_elapsed
	# A red: the rest of the current phase plus every phase between here and mine.
	var t := phases[phase_index].duration() - phase_elapsed
	var i := (phase_index + 1) % phases.size()
	while i != mine and i != phase_index:
		t += phases[i].duration()
		i = (i + 1) % phases.size()
	return t


## Who a movement must give way to: the conflicts in which `p_connector_id` is the yielding side.
##
## The fourth of §6.4's four queries, and the reason the conflict records are directed. A consumer holds
## a connector, asks this, and gets the movements it must see clear — with the point at which each is
## crossed, so it knows how far in it can commit.
func yields_to(p_connector_id: StringName) -> Array[Pasture3DRoadConflict]:
	var out: Array[Pasture3DRoadConflict] = []
	if disabled:
		return out
	for c in conflicts:
		if c != null and c.yielding_id == p_connector_id:
			out.append(c)
	return out


## The mirror: movements that must give way to `p_connector_id`. Not needed to drive correctly, and
## needed constantly to debug a junction, which is why it is one line here rather than a filter every
## consumer writes.
func has_priority_over(p_connector_id: StringName) -> Array[Pasture3DRoadConflict]:
	var out: Array[Pasture3DRoadConflict] = []
	if disabled:
		return out
	for c in conflicts:
		if c != null and c.priority_id == p_connector_id:
			out.append(c)
	return out


## The connector with this id, or null.
func connector_by_id(p_id: StringName) -> Pasture3DRoadLaneConnector:
	for c in connectors:
		if c != null and c.id == p_id:
			return c
	return null


## Content key of the road that won priority here — the one whose profile the junction is built on.
func major_key() -> String:
	var i := major_override if major_override >= 0 and major_override < road_keys.size() else major_index
	return road_keys[i] if i >= 0 and i < road_keys.size() else ""


## The largest trim-back any approach was given, metres. The apron must reach at least this far or it is
## smaller than the hole the trim-backs opened.
func widest_trim_back() -> float:
	var out := 0.0
	for t in trim_backs:
		out = maxf(out, t)
	return out
