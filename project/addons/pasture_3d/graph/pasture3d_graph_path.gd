# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphPath — the payload of a PATH port (§8): a world-space polyline with a width at every
# vertex, plus the query every consumer of a path actually wants.
#
# ---- WHY A PATH IS A PORT TYPE AND NOT A GRID ----
#
# Everything else in the graph travels as a grid because everything else IS a field. A road is not: it is
# a few hundred metres of centreline, and rasterising it into a grid to send it down a wire would fix its
# resolution at the wire rather than at the consumer, throw away the arc length, and make Road Grade
# re-extract from pixels what the brush already knew exactly. So a PATH carries the geometry, and each
# consumer rasterises at its own resolution, from the real thing.
#
# ---- THE QUERY IS ANALYTIC, AND THAT IS THE POINT (§8) ----
#
# The graph's DISTANCE TRANSFORM uses jump flooding, because an exact scan is sequential and could not go
# to the GPU: CPU and GPU would disagree and the same terrain would change as it crossed the 256²
# threshold. None of that reasoning survives the move to a set of line segments. Point-to-segment is
# closed form, the candidate set is small and comes from a uniform index, and every cell is independent —
# exact, embarrassingly parallel, and bit-comparable on both backends by construction. It also yields `s`
# and `t`, which JFA cannot produce at all: a flood knows which cell it came from, not how far along a
# road that cell was.
#
# ---- WHAT distance, s AND t MEAN ----
#
#   `distance` is unsigned metres to the polyline itself, CLAMPED at the ends, so beyond a road's end it
#   is the radial distance to the endpoint rather than a distance to the infinite line.
#
#   `s` is ABSOLUTE arc length in metres from the start of the polyline, the same s the brush, the runs
#   and the pace notes use. Not normalised: normalising would make the same physical place a different
#   number on a road that later got longer.
#
#   `t` is the across-position NORMALISED BY THE HALF-WIDTH there, so t = ±1 is the carriageway edge and
#   |t| <= 1 is "on the road" whatever the road's width does along its length. That normalisation is what
#   makes `t` worth carrying at all: unnormalised it would just be a signed copy of `distance`. Signed,
#   and POSITIVE IS THE DRIVER'S RIGHT — the same convention as the rest of the road system, deliberately,
#   because a second sign convention inside one feature is a bug generator and the first was argued once.
@tool
class_name Pasture3DGraphPath
extends Resource

## World-space XZ vertices of the centreline. Fewer than two makes an empty path, which every query
## answers with INF rather than by failing: an unwired or not-yet-baked Road Source is a normal state,
## not an error, and a graph being edited passes through it constantly.
@export var points: PackedVector2Array = PackedVector2Array():
	set(v):
		points = v
		_built = false
		emit_changed()

## Half-width in metres at each vertex, interpolated along a segment. Empty means a half-width of 1.0
## everywhere, which makes `t` read as signed METRES — the useful degenerate case, and the reason this is
## allowed to be empty rather than required to match `points`.
@export var half_widths: PackedFloat32Array = PackedFloat32Array():
	set(v):
		half_widths = v
		emit_changed()

## Height in metres at each vertex, for consumers that grade TO the road rather than only mask against
## it. Empty means the path carries no elevation and a grader has to get one elsewhere.
@export var heights: PackedFloat32Array = PackedFloat32Array():
	set(v):
		heights = v
		emit_changed()

## True when the last vertex joins back to the first: this path is a REGION boundary, not a route.
##
## ---- WHAT CLOSING CHANGES, AND WHAT IT DOES NOT ----
##
## Every query still works and still means the same thing: `distance` is to the boundary, `s` runs around
## it, `t` is across it. What closing adds is the CLOSING EDGE — the segment from the last vertex back to
## the first, which an open reading of the same points does not have, and whose absence shows up as a
## notch of wrongly-large distance across the mouth of the shape.
##
## It also makes `inside` answerable. That is the point of the flag: a closed path is what lets a Mound,
## Plow or Pond outline be reused as a graph mask instead of the region being drawn a second time as a
## Plow (PASTURE3D_GRAPH_GEOMETRY_PORTS_SPEC.md §8.1).
@export var closed: bool = false:
	set(v):
		closed = v
		_built = false
		emit_changed()

## Where this path came from, for warnings and for the editor. No query reads it.
@export var source_label: String = ""

@export_group("Grading")
# ---- WHY THERE ARE WIDTHS IN TWO PLACES ------------------------------------------------------------
#
# `half_widths` above is per VERTEX and answers `t`. The arrays below are per ALIGNMENT SAMPLE, which is
# the space Pasture3DRoadGrader works in, and they are handed over verbatim from the same
# Pasture3DRoadBrush.grading_profile call the brush's own grading step uses. Resampling one into the
# other would put an extra interpolation between the brush's road and the graph's, so the same road cut
# by a Road Grade node and by the brush step would differ by centimetres in the corners. Two samplings of
# one source is a smaller problem than two sources.
#
# All of this is OPTIONAL. A hand-built path — a gate fixture, a spline someone wants to mask against —
# carries points and widths and nothing here, and answers every query in this file. `can_grade` is the
# question a consumer asks before assuming otherwise.

## The solved vertical profile: how high the road is at every sample, and what the ground under it was.
## Null means this path describes where a road GOES but not what height it sits at, so it can be masked
## against and measured but not graded to.
@export var alignment: Pasture3DRoadAlignment = null:
	set(v):
		alignment = v
		emit_changed()

## Carriageway half-width, shoulder and verge at each alignment sample, metres.
@export var sample_half_widths: PackedFloat32Array = PackedFloat32Array()
@export var sample_shoulders: PackedFloat32Array = PackedFloat32Array()
@export var sample_verges: PackedFloat32Array = PackedFloat32Array()

## 1 where a structure carries the road: the grader reports the interval and does not touch the ground.
@export var sample_suppress: PackedByteArray = PackedByteArray()

## 1 where this arc length belongs to something else — a junction footprint the approach was trimmed
## back from. NOT the same as `sample_suppress`: skipped ground is left alone AND unreported, because
## marking a crossroads as a bridge deck would tell every later phase to build a viaduct there.
@export var sample_skip: PackedByteArray = PackedByteArray()

## Cross-section constants: crown sheds water to both edges, the batters are rise/run of the cut and fill
## slopes. Carried on the path because they are the road's, and a graph cannot reach the road type.
@export var crown: float = 0.05
@export var cut_batter: float = 1.0
@export var fill_batter: float = 0.6


## True when this path carries enough to be graded, not merely measured.
##
## The one question a Road Grade node has to ask. Answering it with a null check on the alignment alone
## would let a path with a solved profile and no widths through, and the grader would fall back to its
## own 3.5 m default — a road that silently becomes a different road.
func can_grade() -> bool:
	return alignment != null and alignment.count() > 0 \
			and sample_half_widths.size() >= alignment.count()

# The vertices the queries actually walk: `points`, plus the first point repeated at the end when
# `closed`. Built in _ensure and dropped whenever the geometry changes.
#
# A separate array rather than a flag checked at every segment lookup, because the closing edge would
# otherwise be a special case inside _resolve, _segment_distance, _signed, the index build AND the ring
# walk — five places to keep in step, four of which would look right on an open path forever.
var _ring: PackedVector2Array = PackedVector2Array()

# Cumulative arc length at each vertex: _cum[i] is the distance from the start to _ring[i].
var _cum: PackedFloat32Array = PackedFloat32Array()
# Uniform bucket index, Vector2i cell -> segment indices. Built on first query, dropped when points move.
var _index: Dictionary = {}
var _cell: float = 0.0
var _origin: Vector2 = Vector2.ZERO
var _max_ring: int = 0
var _built: bool = false

## Below this many segments the index is not built and every query is brute force. Building buckets for a
## four-segment path costs more than checking all four, and the brute path is the definition anyway.
const INDEX_MIN_SEGMENTS: int = 5


## Total arc length in metres. 0 for a path with fewer than two points.
func length() -> float:
	_ensure()
	return _cum[_cum.size() - 1] if _cum.size() > 0 else 0.0


## Number of segments — including the closing edge when this path is closed.
func segment_count() -> int:
	_ensure()
	return maxi(_ring.size() - 1, 0)


## Half-width at arc length `p_s`, interpolated between the vertices either side.
func half_width_at(p_s: float) -> float:
	if half_widths.is_empty():
		return 1.0
	if half_widths.size() == 1:
		return half_widths[0]
	_ensure()
	return _lerp_at(half_widths, p_s)


## Height at arc length `p_s`, interpolated. NAN when the path carries no heights — a question the caller
## has to answer, rather than a zero it can quietly add to a terrain.
func height_at(p_s: float) -> float:
	if heights.is_empty():
		return NAN
	if heights.size() == 1:
		return heights[0]
	_ensure()
	return _lerp_at(heights, p_s)


## Is `p_at` inside this closed path? Always false for an open one — an open polyline has no interior,
## and answering anything else would make a half-drawn shape mask a region that does not exist yet.
##
## ---- EVEN-ODD, AND WHY IT IS WRITTEN DOWN RATHER THAN CHOSEN PER BACKEND ----
##
## A ray cast in +x from the query point, counting boundary crossings: odd is inside. The rule matters
## because a brush outline is NOT guaranteed simple — a Plow dragged back over itself, a Pond with a
## pinched waist — and even-odd and non-zero winding disagree about exactly those shapes. Two backends
## each picking the "obvious" rule would produce a mask that changed when the graph went native, so the
## rule is stated here, in the oracle, and is what the C++ kernel is gated against.
##
## The half-open comparison (`>` on one end, `<=` on the other) is what stops a vertex exactly level with
## the ray being counted twice — the classic point-in-polygon bug, and one that shows up as single wrong
## cells in a straight line, which reads as noise rather than as a rule error.
func inside(p_at: Vector2) -> bool:
	_ensure()
	if not closed or _ring.size() < 4:
		return false
	var n := _ring.size() - 1
	var odd := false
	for i in n:
		var a: Vector2 = _ring[i]
		var b: Vector2 = _ring[i + 1]
		if (a.y > p_at.y) != (b.y > p_at.y):
			var dy := b.y - a.y
			if absf(dy) > 0.0:
				var x_cross: float = a.x + (p_at.y - a.y) / dy * (b.x - a.x)
				if p_at.x < x_cross:
					odd = not odd
	return odd


## The nearest point on the polyline to `p_at`, as `{distance, s, t, segment}`. See the header for what
## each means. An empty path answers `{INF, 0, 0, -1}`; a caller rasterising a whole grid should test for
## that once rather than per cell.
func nearest(p_at: Vector2) -> Dictionary:
	_ensure()
	if segment_count() == 0:
		return {"distance": INF, "s": 0.0, "t": 0.0, "segment": -1}
	return _resolve(p_at, _candidates(p_at))


## The same query with NO INDEX: every segment, every time.
##
## Kept in production rather than in the gate, because it is the DEFINITION the indexed path has to match
## and a definition that lives only in a test drifts from the thing it defines. It is also what `nearest`
## itself falls back to below INDEX_MIN_SEGMENTS.
func nearest_brute(p_at: Vector2) -> Dictionary:
	_ensure()
	var n := segment_count()
	if n == 0:
		return {"distance": INF, "s": 0.0, "t": 0.0, "segment": -1}
	var all := PackedInt32Array()
	for i in n:
		all.append(i)
	return _resolve(p_at, all)


## Pick the winner out of a candidate set and turn it into the answer. The single place a segment index
## becomes a distance, an s and a t, so the indexed and brute queries cannot disagree about anything
## except WHICH segments they looked at — which is the only thing the index is allowed to change.
func _resolve(p_at: Vector2, p_candidates: PackedInt32Array) -> Dictionary:
	var best := INF
	var best_seg := -1
	var best_f := 0.0
	for si: int in p_candidates:
		var a: Vector2 = _ring[si]
		var ab: Vector2 = _ring[si + 1] - a
		var len2 := ab.length_squared()
		var f: float = 0.0 if len2 <= 0.0 else clampf((p_at - a).dot(ab) / len2, 0.0, 1.0)
		var d := p_at.distance_to(a + ab * f)
		# THE TIE RULE: on an exact tie the LOWER SEGMENT INDEX wins, so the answer does not depend on the
		# order the caller offered candidates in — which the index and `nearest_brute` disagree about. See
		# Pasture3DPathGeom::resolve in pasture_3d_path_query.cpp, where the same rule is written at
		# length: `distance` is identical either way and only `s` moves, so the symptom is a corridor mask
		# stepping on one cell beside a distance field that is exact.
		if d < best or (d == best and (best_seg < 0 or si < best_seg)):
			best = d
			best_seg = si
			best_f = f
	if best_seg < 0:
		return {"distance": INF, "s": 0.0, "t": 0.0, "segment": -1}
	var s: float = _cum[best_seg] + (_cum[best_seg + 1] - _cum[best_seg]) * best_f
	var t: float = _signed(p_at, best_seg, best) / maxf(half_width_at(s), 0.0001)
	return {"distance": best, "s": s, "t": t, "segment": best_seg}


## Which side of the segment `p_at` fell on, as ±`p_distance`.
##
## POSITIVE IS THE DRIVER'S RIGHT, matching Pasture3DRoadLaneGraph and everything downstream of it. On
## Godot's XZ plane with +Y up, the right of a heading (dx, dz) is (-dz, dx), so the side is the sign of
## the 2D cross product of the heading with the offset. Spelled out because this is exactly the step a
## fixture that shares the code's convention cannot catch being inverted — see the road sign convention.
func _signed(p_at: Vector2, p_seg: int, p_distance: float) -> float:
	var a: Vector2 = _ring[p_seg]
	var ab: Vector2 = _ring[p_seg + 1] - a
	if ab.length_squared() <= 0.0:
		return p_distance
	var cross := ab.x * (p_at.y - a.y) - ab.y * (p_at.x - a.x)
	return p_distance if cross >= 0.0 else -p_distance


## Segments worth testing for a query at `p_at`: the buckets in an expanding ring, stopping as soon as
## the best answer found is closer than the ring's guaranteed reach.
##
## The stopping rule IS the correctness argument. A segment sitting in a bucket `k` rings out from the
## query cell is at least `(k - 1) * cell` away, so once `best <= (k - 1) * cell` no unexamined bucket can
## hold anything nearer. This stops one ring later than that bound to keep the off-by-one on the safe
## side, because getting it wrong returns a WRONG NEAREST SEGMENT on a path that doubles back, and that is
## silent: the distance is still plausible and only `s` is absurd.
func _candidates(p_at: Vector2) -> PackedInt32Array:
	var n := segment_count()
	if _index.is_empty():
		var all := PackedInt32Array()
		for i in n:
			all.append(i)
		return all
	var cx := int(floor((p_at.x - _origin.x) / _cell))
	var cy := int(floor((p_at.y - _origin.y) / _cell))
	var seen := {}
	var out := PackedInt32Array()
	var best := INF
	var ring := 0
	while ring <= _max_ring:
		for gy in range(cy - ring, cy + ring + 1):
			for gx in range(cx - ring, cx + ring + 1):
				# Only this ring's own shell; the interior was collected on an earlier pass.
				if ring > 0 and absi(gx - cx) != ring and absi(gy - cy) != ring:
					continue
				var bucket = _index.get(Vector2i(gx, gy))
				if bucket == null:
					continue
				for si: int in bucket:
					if seen.has(si):
						continue
					seen[si] = true
					out.append(si)
					best = minf(best, _segment_distance(si, p_at))
		if best <= float(ring) * _cell:
			break
		ring += 1
	return out


func _segment_distance(p_seg: int, p_at: Vector2) -> float:
	var a: Vector2 = _ring[p_seg]
	var ab: Vector2 = _ring[p_seg + 1] - a
	var len2 := ab.length_squared()
	var f: float = 0.0 if len2 <= 0.0 else clampf((p_at - a).dot(ab) / len2, 0.0, 1.0)
	return p_at.distance_to(a + ab * f)


## Interpolate a per-vertex array at arc length `p_s`. Shared by half_width_at and height_at so the two
## cannot drift apart on how they handle a short array or an s past the end.
func _lerp_at(p_values: PackedFloat32Array, p_s: float) -> float:
	var i := _vertex_before(p_s)
	var a: float = p_values[mini(i, p_values.size() - 1)]
	var b: float = p_values[mini(i + 1, p_values.size() - 1)]
	var seg: float = _cum[i + 1] - _cum[i]
	var f: float = 0.0 if seg <= 0.0 else clampf((p_s - _cum[i]) / seg, 0.0, 1.0)
	return lerpf(a, b, f)


## Arc lengths and the bucket index, built once and dropped whenever `points` is assigned.
func _ensure() -> void:
	if _built:
		return
	_built = true
	# The closing edge is added HERE, once, rather than being remembered by every query. Three points is
	# the minimum for an area; a two-point "closed" path is a line doubled back on itself and closing it
	# would only add a duplicate segment, so it is left open.
	_ring = points
	if closed and points.size() >= 3:
		_ring = points.duplicate()
		_ring.append(points[0])
	_cum.resize(_ring.size())
	_index.clear()
	if _ring.is_empty():
		return
	_cum[0] = 0.0
	for i in range(1, _ring.size()):
		_cum[i] = _cum[i - 1] + _ring[i].distance_to(_ring[i - 1])
	var n := maxi(_ring.size() - 1, 0)
	if n < INDEX_MIN_SEGMENTS:
		return
	# One cell per segment on average, floored: a path of very short segments must not explode into
	# millions of buckets, and a path of one huge segment must not put everything into one.
	var total: float = _cum[_cum.size() - 1]
	_cell = maxf(total / float(n), 0.5)
	var bounds := Rect2(_ring[0], Vector2.ZERO)
	for p in _ring:
		bounds = bounds.expand(p)
	_origin = bounds.position
	_max_ring = int(ceil(maxf(bounds.size.x, bounds.size.y) / _cell)) + 2
	for si in n:
		var a: Vector2 = _ring[si]
		var b: Vector2 = _ring[si + 1]
		var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y)) - _origin
		var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y)) - _origin
		for gy in range(int(floor(lo.y / _cell)), int(floor(hi.y / _cell)) + 1):
			for gx in range(int(floor(lo.x / _cell)), int(floor(hi.x / _cell)) + 1):
				var key := Vector2i(gx, gy)
				var arr: PackedInt32Array = _index.get(key, PackedInt32Array())
				arr.append(si)
				_index[key] = arr


func _vertex_before(p_s: float) -> int:
	var last := _ring.size() - 2
	if last < 0:
		return 0
	for i in range(_ring.size() - 1):
		if p_s <= _cum[i + 1]:
			return i
	return last
