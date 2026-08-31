# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadRightOfWay — the last two of §6.4's four queries: what is the signal state, and who do I
# yield to. Takes a junction's connectors and gives back its conflict set and its signal phases.
#
# ---- CONFLICTS ARE FOUND GEOMETRICALLY, NOT FROM A TURN TABLE ----
#
# The tempting shape is a table: "a left turn conflicts with the oncoming straight-ahead". It is wrong at
# every junction that is not a symmetric crossroads — a skew crossing, a road that meets another at 30°,
# a three-arm junction where the straight-ahead movements do not oppose each other. The connectors are
# already curves in world space, so whether two movements conflict is a question their geometry answers
# exactly, for any junction shape, with no cases to enumerate and no cases to miss.
#
# The rules that then decide WHO gives way are a table, and a short one, because by that point the only
# question left is which of two movements that provably meet has the better claim.
#
# ---- STATIC, AND CONTROL IS NOT AN INPUT ----
#
# Same reason as the other road kernels. And `control` is deliberately absent: see the header of
# Pasture3DRoadConflict — a stop sign changes how right of way is enforced, not who has it.
@tool
class_name Pasture3DRoadRightOfWay
extends RefCounted

const Conflict: GDScript = preload("res://addons/pasture_3d/roads/pasture3d_road_conflict.gd")

## How finely a connector's curve is sampled when looking for crossings. A connector is a few tens of
## metres of gentle arc, so this is well inside the error that would move a conflict point enough to
## matter, and it keeps the pair loop cheap enough to run on every resolve.
const TESSELLATE_STAGES: int = 3
const TESSELLATE_TOLERANCE: float = 4.0

## Two movements whose entry points are closer than this are treated as leaving the same place, and the
## side rule cannot separate them. Metres.
const SIDE_EPSILON: float = 0.25

## Default total cycle length of a signalised junction, seconds, and the floor under any one road's
## green. The floor is what stops a priority-1 road opposite a priority-100 road from getting a green
## measured in milliseconds.
const DEFAULT_CYCLE: float = 60.0
const MIN_GREEN: float = 6.0
const DEFAULT_YELLOW: float = 3.0


## Everything right-of-way about one junction.
##
## `p_connectors` are the junction's connectors; forbidden ones are skipped, because a movement nobody
## may make conflicts with nothing.
## `p_road_keys` are the participating roads, and `p_priorities` is a parallel array of their resolved
## `priority` values (§5.2).
## `p_opts` may carry `left_hand` (bool), `cycle` and `yellow` (seconds).
##
## Returns `{conflicts: Array[Pasture3DRoadConflict], phases: Array[Pasture3DRoadPhase]}`.
static func solve(p_connectors: Array, p_road_keys: PackedStringArray,
		p_priorities: PackedInt32Array, p_opts: Dictionary = {}) -> Dictionary:
	return {
		"conflicts": conflicts(p_connectors, _priority_map(p_road_keys, p_priorities),
				bool(p_opts.get("left_hand", false))),
		"phases": phases(p_road_keys, p_priorities,
				float(p_opts.get("cycle", DEFAULT_CYCLE)),
				float(p_opts.get("yellow", DEFAULT_YELLOW))),
	}


## The directed yield relations between every pair of movements that meet.
static func conflicts(p_connectors: Array, p_priorities: Dictionary, p_left_hand: bool) -> Array:
	var live: Array = []
	for c in p_connectors:
		if c is Pasture3DRoadLaneConnector and c.allowed() and c.curve != null \
				and c.curve.point_count >= 2:
			live.append({"c": c, "poly": _polyline(c.curve)})

	var out: Array = []
	for i in live.size():
		for j in range(i + 1, live.size()):
			var a: Pasture3DRoadLaneConnector = live[i]["c"]
			var b: Pasture3DRoadLaneConnector = live[j]["c"]
			# SAME ORIGIN IS A CHOICE, NOT A CONFLICT. One vehicle in one lane takes one of these; it
			# never has to give way to the path it did not pick.
			if a.from_key == b.from_key and a.from_lane == b.from_lane and a.from_end == b.from_end:
				continue
			var merge: bool = a.to_key == b.to_key and a.to_lane == b.to_lane and a.to_end == b.to_end
			var at := Vector3.ZERO
			if merge:
				at = a.exit_point()
			else:
				var hit := _crossing(live[i]["poly"], live[j]["poly"])
				if hit == null:
					continue
				at = _lift_onto(a.curve, hit)
			_decide(a, b, at, merge, p_priorities, p_left_hand, out)
	return out


## Which of two movements that meet gives way, appended to `p_out` as one record — or as two when
## nothing separates them.
static func _decide(p_a: Pasture3DRoadLaneConnector, p_b: Pasture3DRoadLaneConnector, p_at: Vector3,
		p_merge: bool, p_priorities: Dictionary, p_left_hand: bool, p_out: Array) -> void:
	var pa := int(p_priorities.get(p_a.from_key, 0))
	var pb := int(p_priorities.get(p_b.from_key, 0))
	if pa != pb:
		var yielding := p_a if pa < pb else p_b
		var wins := p_b if pa < pb else p_a
		p_out.append(_record(yielding, wins, p_at, p_merge, Conflict.Reason.PRIORITY))
		return
	# Equal priority. A movement that cuts across the oncoming carriageway gives way to one that does
	# not — the permissive left (or right, driving on the left) that every junction has and no per-road
	# rule can see.
	if p_a.crosses_oncoming != p_b.crosses_oncoming:
		var across := p_a if p_a.crosses_oncoming else p_b
		var through := p_b if p_a.crosses_oncoming else p_a
		p_out.append(_record(across, through, p_at, p_merge, Conflict.Reason.TURN_ACROSS))
		return
	# Give way to the vehicle approaching from the priority side: the right, driving on the right.
	var a_gives := _approaches_from_priority_side(p_a, p_b, p_left_hand)
	var b_gives := _approaches_from_priority_side(p_b, p_a, p_left_hand)
	if a_gives != b_gives:
		var y := p_a if a_gives else p_b
		var w := p_b if a_gives else p_a
		p_out.append(_record(y, w, p_at, p_merge, Conflict.Reason.APPROACH_SIDE))
		return
	# Nothing separates them: two head-on movements that meet. Emitted BOTH ways so a consumer reading
	# `yields_to` from either side sees the hold, rather than one side believing it has priority.
	p_out.append(_record(p_a, p_b, p_at, p_merge, Conflict.Reason.MUTUAL))
	p_out.append(_record(p_b, p_a, p_at, p_merge, Conflict.Reason.MUTUAL))


## True when `p_other` comes at `p_self` from the side the world's handedness gives way to.
static func _approaches_from_priority_side(p_self: Pasture3DRoadLaneConnector,
		p_other: Pasture3DRoadLaneConnector, p_left_hand: bool) -> bool:
	var origin := p_self.entry_point()
	var toward := p_other.entry_point() - origin
	var rel := Vector2(toward.x, toward.z)
	if rel.length() < SIDE_EPSILON:
		return false
	# Positive is the driver's right — the same convention the lanes and the grader use, asked here of
	# the direction to the other vehicle rather than of an across-distance.
	var head := _entry_heading(p_self)
	var side := head.x * rel.y - head.y * rel.x
	return side > 0.0 if not p_left_hand else side < 0.0


## The direction a connector leaves its lane in, world XZ. Read off the curve rather than passed in, so
## a hand-built or hand-edited connector answers for the path it actually describes.
static func _entry_heading(p_c: Pasture3DRoadLaneConnector) -> Vector2:
	var poly := _polyline(p_c.curve)
	if poly.size() < 2:
		return Vector2.RIGHT
	var d := poly[1] - poly[0]
	return d.normalized() if d.length() > 0.0 else Vector2.RIGHT


static func _record(p_yielding: Pasture3DRoadLaneConnector, p_priority: Pasture3DRoadLaneConnector,
		p_at: Vector3, p_merge: bool, p_reason: int) -> Pasture3DRoadConflict:
	var r := Pasture3DRoadConflict.new()
	r.yielding_id = p_yielding.id
	r.priority_id = p_priority.id
	r.point = p_at
	r.merge = p_merge
	r.reason = p_reason
	return r


## The crossing point put back on the road surface. `_crossing` works in plan, so it comes back with a
## zero Y; the height a consumer wants is the height of the path THERE, which the curve already knows.
## Returning a point floating at y = 0 would put every conflict marker underground on a hill road and
## make a distance-to-conflict test wrong by the elevation.
static func _lift_onto(p_curve: Curve3D, p_at: Vector3) -> Vector3:
	if p_curve == null or p_curve.point_count < 2:
		return p_at
	# Seeded with the curve's own start height so the closest-point search is not resolving a metres-tall
	# vertical offset it would have to trade against the horizontal one it actually cares about.
	var seed := Vector3(p_at.x, p_curve.get_point_position(0).y, p_at.z)
	var on := p_curve.get_closest_point(seed)
	return Vector3(p_at.x, on.y, p_at.z)


## A connector's path flattened to world XZ.
static func _polyline(p_curve: Curve3D) -> PackedVector2Array:
	var out := PackedVector2Array()
	if p_curve == null or p_curve.point_count < 2:
		return out
	for p in p_curve.tessellate(TESSELLATE_STAGES, TESSELLATE_TOLERANCE):
		out.append(Vector2(p.x, p.z))
	return out


## Where two paths cross in plan, or null. The FIRST crossing along `p_a`, which is the one a vehicle
## following it reaches first and therefore the one it has to be clear of.
static func _crossing(p_a: PackedVector2Array, p_b: PackedVector2Array) -> Variant:
	for i in range(p_a.size() - 1):
		for j in range(p_b.size() - 1):
			var hit: Variant = Geometry2D.segment_intersects_segment(p_a[i], p_a[i + 1], p_b[j], p_b[j + 1])
			if hit != null:
				var at: Vector2 = hit
				return Vector3(at.x, 0.0, at.y)
	return null


## The signal phases of a junction: one per participating road, longest green to the highest priority.
##
## Ordered by priority DESCENDING, so the cycle starts on the road that matters most. That is a
## presentation choice rather than a traffic one, and it is made here so every junction in a world
## cycles the same way round instead of in whatever order the solver happened to walk the roads.
static func phases(p_road_keys: PackedStringArray, p_priorities: PackedInt32Array,
		p_cycle: float = DEFAULT_CYCLE, p_yellow: float = DEFAULT_YELLOW) -> Array:
	var out: Array = []
	var n := p_road_keys.size()
	if n == 0:
		return out
	var yellow := maxf(p_yellow, 0.0)
	var order: Array = []
	for i in n:
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		var pa: int = p_priorities[a] if a < p_priorities.size() else 0
		var pb: int = p_priorities[b] if b < p_priorities.size() else 0
		if pa != pb:
			return pa > pb
		return a < b)

	# Shares are taken over priorities shifted to be positive: priority is a RANKING and may legally be
	# zero or negative (§5.2), and a share of a negative total is meaningless. Shifting preserves the
	# order, which is the only thing the ranking promises.
	# Seeded from the FIRST participant, not from 0: seeded at zero the shift only ever moves negative
	# priorities, so a 10-against-1 junction would be split 11:2 rather than 10:1 and the ranking's own
	# ratio would quietly depend on where it happened to sit relative to zero.
	var lowest: int = p_priorities[0] if p_priorities.size() > 0 else 0
	for i in n:
		lowest = mini(lowest, p_priorities[i] if i < p_priorities.size() else 0)
	var total := 0.0
	for i in n:
		total += float((p_priorities[i] if i < p_priorities.size() else 0) - lowest) + 1.0
	var green_budget := maxf(p_cycle - yellow * float(n), MIN_GREEN * float(n))

	for i: int in order:
		var ph := Pasture3DRoadPhase.new()
		ph.road_keys = PackedStringArray([p_road_keys[i]])
		var share := (float((p_priorities[i] if i < p_priorities.size() else 0) - lowest) + 1.0) / total
		ph.green_time = maxf(green_budget * share, MIN_GREEN)
		ph.yellow_time = yellow
		out.append(ph)
	return out


static func _priority_map(p_road_keys: PackedStringArray, p_priorities: PackedInt32Array) -> Dictionary:
	var out := {}
	for i in p_road_keys.size():
		out[p_road_keys[i]] = p_priorities[i] if i < p_priorities.size() else 0
	return out
