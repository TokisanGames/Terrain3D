# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadMesher — TIER MID (§10): the chunked ribbon mesh. Where tier FAR says what the surface is
# made of, this gives it a surface of its own — close enough to see the camber, far enough that a chunk
# is still a chunk.
#
# ---- THE RIBBON SITS ON GROUND THAT IS ALREADY THE RIGHT SHAPE ----
#
# P1/P2 graded the terrain to the road's own profile, so this ribbon is not draped, projected or fought
# against the heightmap: both are `Pasture3DRoadGrader.surface_height` of the same arc length, which is
# why that function lives in the grader and neither of them owns a copy. A millimetre of disagreement
# would z-fight along the entire road and read as a rendering bug rather than as arithmetic.
#
# ---- A KERNEL, NOT A HOST ----
#
# Nothing here is a Node, touches a Terrain, or allocates a mesh resource. It turns a run into vertex
# arrays, and the chunk host does the hosting — the same split as the grader and the paint kernel, and
# for the same reason: every claim §10 makes about chunking is a claim about NUMBERS (where the cuts
# fall, whether two chunks share their seam vertices exactly, what an LOD drops), and numbers can be
# gated without a viewport deciding whether the road looked right.
#
# ---- THE THREE RULES §10 SETS, AND WHERE EACH IS ENFORCED ----
#
#   "chunks are cut on arc length, snapped to region boundaries"  ->  `chunk_spans`
#   "never chunk across an intersection"                          ->  `chunk_spans`, via skip ranges
#   "seams land on shared vertices so no crack can open"          ->  `ring`, which is a function of
#                                                                     ARC LENGTH ALONE
#
# The third is the one that is easy to get wrong and impossible to see until it cracks. A ring is
# generated from `s` and nothing else — not from the chunk, not from the vertex index within the chunk,
# not from an accumulated step. Two chunks meeting at `s` therefore compute the same floats from the
# same inputs, and are equal bit for bit rather than equal to within a tolerance. A mesher that walked
# `s += step` per chunk would produce seams that agree to six decimal places and crack anyway.
@tool
class_name Pasture3DRoadMesher
extends RefCounted

## Cross-section detail, coarsening with distance. §10: "shoulder and camber collapse first,
## carriageway last" — the carriageway edges are in every level, because a road that narrows as it
## recedes is a road that visibly changes width as you drive at it.
enum Cross {
	FULL,      ## shoulders, both carriageway edges, and the crown vertex down the centre
	NO_CROWN,  ## shoulders and carriageway edges; the camber flattens
	NO_SHOULDER,  ## carriageway edges only
}

## Longitudinal spacing doubles per LOD level, so level `n` samples every `ds * 2^n` metres.
const LOD_LEVELS: int = 4

## How far the ribbon is lifted above the surface the grader carved, metres.
##
## NOT a fudge, and not tunable away to zero. The ground under the road was graded to the road's own
## profile (P1/P2), so the ribbon and the terrain are the SAME surface — which means the depth test
## between them is decided by float precision, and at distance the terrain's own clipmap moves its
## vertices anyway. Coplanar is the one thing this ribbon must never be: it z-fights up close and
## disappears entirely wherever the terrain rounds upward.
##
## 2 cm: below what a camera can see at any driving distance, above what depth precision loses.
const DEPTH_LIFT: float = 0.02

## Arc lengths closer together than this are the same cut. Region boundaries and junction footprints
## land near each other constantly — a road entering a junction just inside a region edge would
## otherwise produce a chunk a few centimetres long, which costs a draw call to draw nothing.
const CUT_EPSILON: float = 0.5


## The cross-section detail for an LOD level.
static func cross_for_lod(p_lod: int) -> Cross:
	if p_lod <= 0:
		return Cross.FULL
	if p_lod == 1:
		return Cross.NO_CROWN
	return Cross.NO_SHOULDER


## Longitudinal sample spacing at an LOD level, metres.
static func step_for_lod(p_ds: float, p_lod: int) -> float:
	return maxf(p_ds, 0.01) * pow(2.0, float(clampi(p_lod, 0, LOD_LEVELS - 1)))


## The signed across-distances of one cross-section, left to right.
##
## Left to right and NOT outward from the centre, so the triangle strip between two rings is a simple
## zip of equal-length arrays. Every level keeps ±half — see `Cross`.
static func cross_offsets(p_half: float, p_shoulder: float, p_cross: Cross) -> PackedFloat32Array:
	var half := maxf(p_half, 0.01)
	var shoulder := maxf(p_shoulder, 0.0)
	match p_cross:
		Cross.NO_SHOULDER:
			return PackedFloat32Array([-half, half])
		Cross.NO_CROWN:
			return PackedFloat32Array([-(half + shoulder), -half, half, half + shoulder])
		_:
			return PackedFloat32Array([-(half + shoulder), -half, 0.0, half, half + shoulder])


## One cross-section of the ribbon at arc length `p_s`, in world space.
##
## A PURE FUNCTION OF ARC LENGTH — this is the seam contract. Nothing about which chunk asked, which
## vertex index it is, or how far the caller has walked enters the arithmetic, so two chunks meeting at
## `p_s` produce identical floats and share their seam exactly. Everything else in this file exists to
## make sure the boundary arc lengths are the same number on both sides; this makes the same number
## produce the same vertex.
static func ring(p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_alignment: Pasture3DRoadAlignment, p_s: float, p_offsets: PackedFloat32Array,
		p_crown: float, p_lift: float = 0.0) -> PackedVector3Array:
	var out := PackedVector3Array()
	if p_alignment == null or p_plan.size() < 2:
		return out
	var at := Pasture3DRoadGrader.plan_point_at(p_plan, p_cum, p_s)
	var tangent := Pasture3DRoadGrader.plan_tangent_at(p_plan, p_cum, p_s)
	# Positive across-distance is the driver's RIGHT (§5.1). In the (x, z) plane that is (-t.y, t.x) —
	# see the sign-convention note in Pasture3DRoadLanes, and do not re-derive it here.
	var across := Vector2(-tangent.y, tangent.x)
	var centre: float = p_alignment.height_at(p_s)
	var si := p_alignment.index_at(p_s)
	var bank: float = p_alignment.bank[si] if si < p_alignment.bank.size() else 0.0
	for u in p_offsets:
		var xz := at + across * u
		# The lift is a CONSTANT added to the profile, never a scale on it: the ribbon must be the same
		# shape as the ground, sitting above it, or the camber and the banking would drift apart from the
		# terrain they were graded into.
		out.append(Vector3(xz.x,
				Pasture3DRoadGrader.surface_height(centre, bank, p_crown, u) + p_lift, xz.y))
	return out


## The arc lengths at which the ribbon must be cut, ascending, always including 0 and the run's length.
##
## Two rules, both from §10, and they are combined here rather than applied in sequence because a cut is
## a cut whatever put it there:
##
##   * REGION BOUNDARIES. A chunk that ends where a terrain region ends has the same lifetime as that
##     region, so one visibility test serves both and the road streams for free with the terrain it is
##     cut into. This is what §4.2 decoupled chunks from spline intervals FOR.
##   * JUNCTION FOOTPRINTS. Never chunk across an intersection: the junction owns the surface inside its
##     footprint, and a ribbon running through it would be a second road surface fighting the first.
##
## `p_skips` is an array of `[from, to]` arc-length pairs — the footprints, which the brush already
## computes as the trim-back it grades around.
static func cut_points(p_plan: PackedVector2Array, p_cum: PackedFloat32Array, p_region_size: float,
		p_skips: Array = []) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if p_plan.size() < 2 or p_cum.size() < p_plan.size():
		return out
	var total: float = p_cum[p_cum.size() - 1]
	out.append(0.0)
	out.append(total)
	for pair in p_skips:
		if pair is Array and pair.size() >= 2:
			out.append(clampf(float(pair[0]), 0.0, total))
			out.append(clampf(float(pair[1]), 0.0, total))
	if p_region_size > 0.0:
		for i in range(1, p_plan.size()):
			_boundaries_between(out, p_plan[i - 1], p_plan[i], p_cum[i - 1], p_cum[i], p_region_size)
	out.sort()
	# Collapse cuts that are the same cut. Without this a road entering a junction just inside a region
	# edge produces a chunk a few centimetres long: a draw call, a mesh resource and a seam, to draw
	# nothing.
	var merged := PackedFloat32Array()
	for s in out:
		if merged.is_empty() or s - merged[merged.size() - 1] > CUT_EPSILON:
			merged.append(s)
	if merged.size() > 1 and total - merged[merged.size() - 1] <= CUT_EPSILON:
		merged[merged.size() - 1] = total
	return merged


## Arc lengths where the segment `p_a` → `p_b` crosses a region grid line, appended to `p_into`.
##
## Both axes: a road running diagonally crosses X boundaries and Z boundaries at different places and
## needs a cut at each, because it enters a new region at whichever comes first.
static func _boundaries_between(p_into: PackedFloat32Array, p_a: Vector2, p_b: Vector2,
		p_s_a: float, p_s_b: float, p_size: float) -> void:
	var span := p_s_b - p_s_a
	if span <= 1e-6:
		return
	for axis in 2:
		var a: float = p_a.x if axis == 0 else p_a.y
		var b: float = p_b.x if axis == 0 else p_b.y
		if is_equal_approx(a, b):
			continue
		var lo := int(floor(minf(a, b) / p_size)) + 1
		var hi := int(floor(maxf(a, b) / p_size))
		for k in range(lo, hi + 1):
			var line := float(k) * p_size
			p_into.append(p_s_a + span * ((line - a) / (b - a)))


## The spans to build chunks for: consecutive cut points, minus anything inside a junction footprint.
##
## Returns an array of `[from, to]`. A span whose midpoint falls in a skip range is dropped entirely
## rather than shortened — the footprint is not the mesher's to render, and a chunk that stopped at its
## edge would still have started inside it.
static func chunk_spans(p_plan: PackedVector2Array, p_cum: PackedFloat32Array, p_region_size: float,
		p_skips: Array = []) -> Array:
	var cuts := cut_points(p_plan, p_cum, p_region_size, p_skips)
	var out: Array = []
	for i in range(1, cuts.size()):
		var from: float = cuts[i - 1]
		var to: float = cuts[i]
		if to - from <= CUT_EPSILON:
			continue
		var mid := (from + to) * 0.5
		var skipped := false
		for pair in p_skips:
			if pair is Array and pair.size() >= 2 and mid >= float(pair[0]) and mid <= float(pair[1]):
				skipped = true
				break
		if not skipped:
			out.append([from, to])
	return out


## Build one chunk's surface arrays over `[p_from, p_to]` at LOD `p_lod`.
##
## Returns a Godot `ArrayMesh` surface array (`Mesh.ARRAY_MAX` long) ready for `add_surface_from_arrays`,
## or an empty Array when there is nothing to build. Positions, normals, UVs and indices only — a
## resource is the host's business.
##
## THE ENDS ARE ALWAYS SAMPLED EXACTLY. The longitudinal walk is by index from the start, and the final
## ring is `p_to` itself rather than wherever the walk happened to stop. That is the other half of the
## seam contract: `ring` guarantees the same `s` gives the same vertex, and this guarantees the two
## chunks are asked about the same `s`.
## `p_force_gdscript` skips the native delegation and runs the body below, for the same reason the
## alignment solver has one: this file is the reference the native mesher was written against, and once
## `ClassDB.class_has_method` started answering yes the body became unreachable in any session with the
## extension loaded. A parity gate that calls `build_chunk` twice compares the native path to itself.
static func build_chunk(p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_alignment: Pasture3DRoadAlignment, p_from: float, p_to: float, p_half: float,
		p_shoulder: float, p_crown: float, p_lod: int = 0,
		p_lift: float = DEPTH_LIFT, p_force_gdscript: bool = false) -> Array:
	if p_alignment == null or p_plan.size() < 2 or p_to - p_from <= 1e-4:
		return []
	if not p_force_gdscript and ClassDB.class_has_method("Pasture3DUtil", "road_mesh_build_chunk"):
		return Pasture3DUtil.road_mesh_build_chunk(p_plan, p_cum, p_alignment.ds,
				p_alignment.z, p_alignment.bank, p_from, p_to, p_half, p_shoulder,
				p_crown, p_lod, p_lift, p_alignment.s0)

	var offsets := cross_offsets(p_half, p_shoulder, cross_for_lod(p_lod))
	var across_count := offsets.size()
	if across_count < 2:
		return []
	var step := step_for_lod(p_alignment.ds, p_lod)
	var rows := maxi(int(ceil((p_to - p_from) / step)), 1) + 1

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var half := maxf(p_half, 0.01)

	for r in rows:
		# The last row is `p_to` itself, not `p_from + r * step`. Rounding the final ring to the nearest
		# sample is exactly how a seam opens.
		var s: float = p_to if r == rows - 1 else minf(p_from + float(r) * step, p_to)
		var line := ring(p_plan, p_cum, p_alignment, s, offsets, p_crown, p_lift)
		if line.size() != across_count:
			return []
		for c in across_count:
			verts.append(line[c])
			# V IN METRES, not normalised over the chunk. Normalising would make the texture repeat once
			# per chunk, so the road markings would change scale at every region boundary and stretch
			# wherever a junction made a chunk short.
			uvs.append(Vector2(offsets[c] / half * 0.5 + 0.5, s))
			normals.append(Vector3.UP)

	for r in range(rows - 1):
		for c in range(across_count - 1):
			var i0 := r * across_count + c
			var i1 := i0 + 1
			var i2 := i0 + across_count
			var i3 := i2 + 1
			# GODOT'S FRONT FACE IS CLOCKWISE AS SEEN FROM THE FRONT, which is the opposite of the
			# right-hand rule. For a surface that must be visible from ABOVE, the triangle has to look
			# clockwise looking down — so its geometric (b-a) x (c-a) points DOWN, not up. Winding it the
			# "mathematically up" way makes the road visible only from underneath: it draws, it is in the
			# right place, and from every normal camera angle there is nothing there.
			indices.append_array(PackedInt32Array([i0, i2, i1, i1, i2, i3]))

	_recompute_normals(verts, indices, normals)
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = normals
	out[Mesh.ARRAY_TEX_UV] = uvs
	out[Mesh.ARRAY_INDEX] = indices
	return out


## The junction apron: the disc of surface inside a junction footprint, as a triangle fan.
##
## ---- WHY IT FOLLOWS THE MAJOR ROAD RATHER THAN BEING FLAT ----
##
## The ground inside a footprint is not flat and is not at the junction's `elevation`. The grader lets
## the MAJOR road pave straight through (only minor approaches are skipped), so the ground in there is
## the major road's own surface — crowned, banked, climbing. An apron laid flat at `elevation` would sit
## up to a crown above the carriageway edges and cut into the middle: a visible saucer at every
## crossroads.
##
## So every fan vertex is projected onto the major road's plan and given exactly the height the grader
## gave that cell, through the same `surface_height`. The apron and the ground are the same surface for
## the same reason the ribbon and the ground are.
##
## Returns a surface array, or an empty Array when there is nothing to build.
static func build_apron(p_center: Vector2, p_radius: float, p_plan: PackedVector2Array,
		p_cum: PackedFloat32Array, p_alignment: Pasture3DRoadAlignment, p_crown: float,
		p_segments: int = 24, p_lift: float = DEPTH_LIFT,
		p_force_gdscript: bool = false) -> Array:
	if p_alignment == null or p_plan.size() < 2 or p_radius <= 0.01:
		return []
	if not p_force_gdscript and ClassDB.class_has_method("Pasture3DUtil", "road_mesh_build_apron"):
		return Pasture3DUtil.road_mesh_build_apron(p_center, p_radius, p_plan, p_cum,
				p_alignment.ds, p_alignment.z, p_alignment.bank, p_crown, p_segments, p_lift,
				p_alignment.s0)
	var segments := maxi(p_segments, 3)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	verts.append(_apron_point(p_center, p_plan, p_cum, p_alignment, p_crown, p_lift))
	uvs.append(Vector2(0.5, 0.5))
	normals.append(Vector3.UP)
	for i in segments:
		var a := TAU * float(i) / float(segments)
		var at := p_center + Vector2(cos(a), sin(a)) * p_radius
		verts.append(_apron_point(at, p_plan, p_cum, p_alignment, p_crown, p_lift))
		uvs.append(Vector2(0.5 + cos(a) * 0.5, 0.5 + sin(a) * 0.5))
		normals.append(Vector3.UP)
	for i in segments:
		# (centre, ring i, ring i+1) with the angle INCREASING is clockwise seen from above, which is
		# Godot's front face — the same convention as the ribbon, and wrong the same way if reversed.
		indices.append_array(PackedInt32Array([0, 1 + i, 1 + (i + 1) % segments]))

	_recompute_normals(verts, indices, normals)
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = normals
	out[Mesh.ARRAY_TEX_UV] = uvs
	out[Mesh.ARRAY_INDEX] = indices
	return out


## One apron vertex: world XZ `p_at`, lifted onto the major road's graded surface.
static func _apron_point(p_at: Vector2, p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_alignment: Pasture3DRoadAlignment, p_crown: float, p_lift: float) -> Vector3:
	var hit := Pasture3DRoadGrader.nearest_on_plan(p_plan, p_cum, p_at)
	var d: float = hit[0]
	var s: float = hit[1]
	var side: float = hit[2]
	var si := p_alignment.index_at(s)
	var bank: float = p_alignment.bank[si] if si < p_alignment.bank.size() else 0.0
	var y := Pasture3DRoadGrader.surface_height(p_alignment.height_at(s), bank, p_crown, d * side)
	return Vector3(p_at.x, y + p_lift, p_at.y)


## Area-weighted vertex normals.
##
## Computed rather than assumed UP: a banked corner and a steep climb are both real surface tilts the
## alignment solved for, and lighting a superelevated corner as though it were flat throws away the one
## visual cue that says the road is banked at all.
static func _recompute_normals(p_verts: PackedVector3Array, p_indices: PackedInt32Array,
		p_normals: PackedVector3Array) -> void:
	for i in p_normals.size():
		p_normals[i] = Vector3.ZERO
	var tri := 0
	while tri + 2 < p_indices.size():
		var a := p_indices[tri]
		var b := p_indices[tri + 1]
		var c := p_indices[tri + 2]
		# Negated, because the winding above is Godot's and not the right-hand rule's: the geometric cross
		# of a front-facing triangle points AWAY from the side you see it from. A shading normal has to
		# point AT the viewer, so it is the opposite of the winding that makes the face visible.
		#
		# Not normalised: the cross product's length is twice the triangle's area, which weights big
		# triangles more than slivers and is what stops a decimated LOD shading differently.
		var n := -(p_verts[b] - p_verts[a]).cross(p_verts[c] - p_verts[a])
		p_normals[a] += n
		p_normals[b] += n
		p_normals[c] += n
		tri += 3
	for i in p_normals.size():
		var n := p_normals[i]
		p_normals[i] = n.normalized() if n.length_squared() > 1e-12 else Vector3.UP
