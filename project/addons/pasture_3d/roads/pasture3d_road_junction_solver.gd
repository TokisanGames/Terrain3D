# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadJunctionSolver — finds where roads actually meet, and works out what that costs each of
# them. See PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §6. Static and node-free, like the grader, so every claim
# below is measurable on fixtures whose answer is known by hand.
#
# ---- TRIM-BACK IS A CLOSED FORM, NOT A TUNED CONSTANT ----
#
# Two roads of half-width wA and wB crossing at angle θ overlap in a parallelogram. Road A must stop
# before it enters that overlap, and the distance from the crossing at which A's centreline is exactly
# wB away from B's centreline is:
#
#     trim_A = wB / sin θ
#
# That is not an approximation and it is not a fudge factor: at that distance A's end lands exactly on
# B's edge, so there is no gap to fill and no overlap to resolve. It falls out that an acute crossing
# trims back much further than a square one — 1/sin θ diverges — which is correct (a 20° slip road eats a
# long way into both roads) and is the criterion that tells this apart from a fixed-radius junction.
#
# ---- OVERLAPPING IS NOT INTERSECTING (§6, addition 1) ----
#
# Detection is XZ-planar, so an overpass crosses everything beneath it. Two exclusions, both of which
# have to be applied where the crossing is found rather than afterwards: a stretch marked `is_bridge`
# never participates, and neither does a crossing whose two roads are solved more than `clearance` apart
# vertically. Grade separation then falls out of data the design already carries.
@tool
class_name Pasture3DRoadJunctionSolver
extends RefCounted

## Crossings closer together than this are one junction, metres. A staggered crossroads authored as two
## T-junctions a few metres apart is one intersection to a driver and should be one to the solver.
const DEFAULT_CLUSTER_RADIUS: float = 12.0

## Vertical separation at which two roads are considered to pass rather than to meet, metres. Roughly a
## lorry plus deck; below it, two roads at different heights would still collide.
const DEFAULT_CLEARANCE: float = 5.5

## Angles shallower than this are treated as parallel — 1/sin θ has no useful value there, and two roads
## meeting at 2° are running alongside each other, not crossing.
const MIN_CROSSING_ANGLE: float = 0.12 # radians, about 7°


## Find every crossing between the given runs.
##
## Each run is a Dictionary:
##   key        String                — stable identity of the road (its content key)
##   plan       PackedVector2Array    — world XZ centreline
##   cum        PackedFloat32Array    — cumulative arc length, from Pasture3DRoadGrader
##   alignment  Pasture3DRoadAlignment or null — solved heights, for the clearance test
##   bridge     PackedByteArray       — per ALIGNMENT SAMPLE, 1 where this road is on a structure
##   priority   int                   — higher wins the junction (§5.2)
##   half_width float                 — half the formation, metres
##
## Returns raw crossings: `[{a, b, point, s_a, s_b, angle}, …]`, indices into `p_runs`.
static func find_crossings(p_runs: Array, p_opts: Dictionary = {}) -> Array:
	var clearance: float = float(p_opts.get("clearance", DEFAULT_CLEARANCE))
	var out: Array = []
	for ia in range(p_runs.size()):
		for ib in range(ia + 1, p_runs.size()):
			var ra: Dictionary = p_runs[ia]
			var rb: Dictionary = p_runs[ib]
			var pa: PackedVector2Array = ra["plan"]
			var pb: PackedVector2Array = rb["plan"]
			var ca: PackedFloat32Array = ra["cum"]
			var cb: PackedFloat32Array = rb["cum"]
			for i in range(pa.size() - 1):
				for j in range(pb.size() - 1):
					var hit := _segment_crossing(pa[i], pa[i + 1], pb[j], pb[j + 1])
					if hit.is_empty():
						continue
					var ta: float = hit[0]
					var tb: float = hit[1]
					var s_a: float = ca[i] + (ca[i + 1] - ca[i]) * ta
					var s_b: float = cb[j] + (cb[j + 1] - cb[j]) * tb
					# A bridged stretch is not a junction — it is an overpass. Tested at the crossing,
					# not filtered afterwards, so a road that is bridged HERE and level 200 m away still
					# forms junctions there.
					if _is_bridged(ra, s_a) or _is_bridged(rb, s_b):
						continue
					var za := _height_of(ra, s_a)
					var zb := _height_of(rb, s_b)
					if is_finite(za) and is_finite(zb) and absf(za - zb) > clearance:
						continue
					var da := (pa[i + 1] - pa[i]).normalized()
					var db := (pb[j + 1] - pb[j]).normalized()
					# The acute angle between the two LINES, in [0, π/2]: taking |dot| first folds
					# direction away, so a road crossing at 150° presents the same 30° geometry to the
					# trim-back as one crossing at 30°, which is what the overlap parallelogram sees.
					var cross_ang := acos(clampf(absf(da.dot(db)), 0.0, 1.0))
					if cross_ang < MIN_CROSSING_ANGLE:
						continue
					out.append({
						"a": ia, "b": ib, "point": pa[i].lerp(pa[i + 1], ta),
						"s_a": s_a, "s_b": s_b, "angle": cross_ang,
					})
	return out


## Group crossings that are close enough to be one intersection, and resolve each group into a
## Pasture3DRoadJunction. Existing junctions are matched by id so their overrides carry over.
static func resolve(p_runs: Array, p_existing: Array = [], p_opts: Dictionary = {}) -> Array:
	var cluster_r: float = float(p_opts.get("cluster_radius", DEFAULT_CLUSTER_RADIUS))
	var crossings := find_crossings(p_runs, p_opts)
	var groups := _cluster(crossings, cluster_r)

	var by_id := {}
	for j in p_existing:
		if j is Pasture3DRoadJunction:
			by_id[String(j.id)] = j

	var out: Array = []
	for g: Array in groups:
		var j := _resolve_group(p_runs, crossings, g)
		if j == null:
			continue
		var prior: Pasture3DRoadJunction = by_id.get(String(j.id), null)
		if prior != null:
			# RECONCILE, do not rebuild: the resolved fields are replaced wholesale and the user's
			# overrides are the ones already on `prior`, so an unrelated spline edit cannot silently
			# discard a choice made here.
			prior.center = j.center
			prior.road_keys = j.road_keys
			prior.arc_lengths = j.arc_lengths
			prior.trim_backs = j.trim_backs
			prior.radius = j.radius
			prior.elevation = j.elevation
			prior.major_index = j.major_index
			prior.detected = true
			out.append(prior)
		else:
			out.append(j)

	# A junction that is no longer detected is KEPT and marked, not deleted. The roads may be dragged
	# back together in a moment, and throwing away the overrides in between would be a silent loss.
	var live := {}
	for j: Pasture3DRoadJunction in out:
		live[String(j.id)] = true
	for k in by_id:
		if not live.has(k):
			var stale: Pasture3DRoadJunction = by_id[k]
			stale.detected = false
			out.append(stale)
	return out


## Resolve one cluster of crossings into a junction.
static func _resolve_group(p_runs: Array, p_crossings: Array, p_group: Array) -> Pasture3DRoadJunction:
	# Participants, and the arc length at which each enters. A road crossing the cluster twice keeps its
	# FIRST arc length here; the second crossing is a separate cluster unless they are within the cluster
	# radius, in which case they genuinely are one intersection.
	var arc := {}
	var center := Vector2.ZERO
	for ci: int in p_group:
		var c: Dictionary = p_crossings[ci]
		center += c["point"]
		if not arc.has(c["a"]):
			arc[c["a"]] = c["s_a"]
		if not arc.has(c["b"]):
			arc[c["b"]] = c["s_b"]
	center /= float(p_group.size())
	var idx: Array = arc.keys()
	idx.sort()
	if idx.size() < 2:
		return null

	var j := Pasture3DRoadJunction.new()
	j.center = center
	var keys := PackedStringArray()
	var arcs := PackedFloat32Array()
	for i: int in idx:
		keys.append(String((p_runs[i] as Dictionary)["key"]))
		arcs.append(float(arc[i]))
	j.road_keys = keys
	j.arc_lengths = arcs
	j.id = Pasture3DRoadJunction.make_id(keys, center)

	# TRIM-BACK. Each participant is pushed back far enough to clear EVERY other participant's edge, so
	# the binding constraint is the widest road at the sharpest angle — which is why this is a max over
	# pairs rather than a single computation.
	var trims := PackedFloat32Array()
	trims.resize(idx.size())
	trims.fill(0.0)
	for gi in range(idx.size()):
		for gj in range(idx.size()):
			if gi == gj:
				continue
			var ang := _angle_between(p_crossings, p_group, idx[gi], idx[gj])
			var other_w: float = float((p_runs[idx[gj]] as Dictionary).get("half_width", 4.0))
			var s: float = sin(maxf(ang, MIN_CROSSING_ANGLE))
			trims[gi] = maxf(trims[gi], other_w / s)
	j.trim_backs = trims

	# The footprint has to contain every trimmed end, so it is the largest of them.
	var r := 0.0
	for t in trims:
		r = maxf(r, t)
	j.radius = r

	# PRIORITY DECIDES ELEVATION (§5.2). The junction sits at the major road's own solved height, so the
	# road with right of way keeps the profile it solved and the minor roads bend to meet it. Averaging
	# would put a dip or a hump in the major road, which is the one road that must not have one.
	var best := 0
	var best_priority := -2147483648
	for gi in range(idx.size()):
		var pr := int((p_runs[idx[gi]] as Dictionary).get("priority", 0))
		if pr > best_priority:
			best_priority = pr
			best = gi
	j.major_index = best
	var major_run: Dictionary = p_runs[idx[best]]
	var z := _height_of(major_run, arcs[best])
	j.elevation = z if is_finite(z) else 0.0
	return j


## The crossing angle recorded between two participants, or a right angle when they never crossed each
## other directly (a three-way cluster where A meets B and B meets C, but A never meets C).
static func _angle_between(p_crossings: Array, p_group: Array, p_i: int, p_j: int) -> float:
	for ci: int in p_group:
		var c: Dictionary = p_crossings[ci]
		if (c["a"] == p_i and c["b"] == p_j) or (c["a"] == p_j and c["b"] == p_i):
			return float(c["angle"])
	return PI * 0.5


## Single-linkage clustering: crossings within `p_radius` of any member join that group. Single linkage
## rather than a fixed grid, because a staggered crossroads is a CHAIN of near crossings and a grid would
## split it on a cell boundary.
static func _cluster(p_crossings: Array, p_radius: float) -> Array:
	var n := p_crossings.size()
	var group_of := PackedInt32Array()
	group_of.resize(n)
	group_of.fill(-1)
	var groups: Array = []
	for i in range(n):
		if group_of[i] >= 0:
			continue
		var gi := groups.size()
		groups.append([])
		var queue: Array[int] = [i]
		group_of[i] = gi
		while not queue.is_empty():
			var at: int = queue.pop_back()
			(groups[gi] as Array).append(at)
			var pa: Vector2 = (p_crossings[at] as Dictionary)["point"]
			for k in range(n):
				if group_of[k] < 0 and pa.distance_to((p_crossings[k] as Dictionary)["point"]) <= p_radius:
					group_of[k] = gi
					queue.append(k)
	return groups


## Where two segments cross, as `[t_a, t_b]` in 0..1, or empty. Endpoint-inclusive, so two roads that
## meet exactly at a shared point (a T-junction authored by ending one spline on another) are found.
static func _segment_crossing(p_a0: Vector2, p_a1: Vector2, p_b0: Vector2, p_b1: Vector2) -> Array:
	var r := p_a1 - p_a0
	var s := p_b1 - p_b0
	var denom := r.cross(s)
	if absf(denom) < 1e-12:
		return [] # parallel or degenerate: not a crossing, and 1/sin θ would be meaningless anyway
	var qp := p_b0 - p_a0
	var t := qp.cross(s) / denom
	var u := qp.cross(r) / denom
	if t < 0.0 or t > 1.0 or u < 0.0 or u > 1.0:
		return []
	return [t, u]


static func _is_bridged(p_run: Dictionary, p_s: float) -> bool:
	var bridge: PackedByteArray = p_run.get("bridge", PackedByteArray())
	if bridge.is_empty():
		return false
	var a: Pasture3DRoadAlignment = p_run.get("alignment", null)
	var i := int(round(p_s / (a.ds if a != null and a.ds > 0.0 else 1.0)))
	return bridge[clampi(i, 0, bridge.size() - 1)] != 0


static func _height_of(p_run: Dictionary, p_s: float) -> float:
	var a: Pasture3DRoadAlignment = p_run.get("alignment", null)
	return a.height_at(p_s) if a != null and a.count() > 0 else NAN
