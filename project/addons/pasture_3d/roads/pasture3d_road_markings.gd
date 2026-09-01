# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Lane markings — tier NEAR (§10, P5c). A PURE KERNEL, like Pasture3DRoadPaint and
# Pasture3DRoadMesher: no nodes, no terrain, no state. Two stages, deliberately separate.
#
#   plan()  — the cross-section question. Given the lanes and the divider type, WHERE are the painted
#             stripes and which are broken? Answers in the grader's `u` (signed metres across, positive
#             RIGHT), so a marking is placed in the same coordinate the carriageway was graded in.
#   build() — the geometry question. Given those stripes and an arc-length span, what triangles?
#
# The split is not tidiness. A stripe plan is a handful of numbers that can be asserted directly — "a
# one-way road has no centre line", "a double-solid divider is TWO stripes" — whereas the same claims
# read out of a mesh are inferences about vertex positions. Everything that can be wrong about markings
# is wrong in the plan; the builder only extrudes it.
@tool
class_name Pasture3DRoadMarkings
extends RefCounted

## A stripe is either continuous or broken. Nothing else: DOUBLE_SOLID and DASHED_SOLID are not styles
## at this level, they are TWO stripes, expanded by plan(). Downstream, one plan entry is one painted
## line, and the builder never asks what kind of divider produced it.
enum Style { SOLID, DASHED }

## Standard painted stripe width, metres. Narrow enough to read as paint rather than as a lane.
const STRIPE_WIDTH: float = 0.12
## Dash and the pitch it repeats on, metres. A 3 m dash every 9 m — the North American convention, and
## the one most readable at the speeds this system is aimed at. Real jurisdictions differ (the UK runs
## 2 m on 9 m in town and far longer out of it); these are constants rather than exports because a
## marking system that gets the pitch wrong is still a marking system, while one that gets the SIDES
## wrong is a road nobody can read.
const DASH_LENGTH: float = 3.0
const DASH_PITCH: float = 9.0
## Gap between the two stripes of a double divider, metres, centre to centre.
const DOUBLE_GAP: float = 0.25
## How far a marking floats above the road surface it is painted on. Applied ON TOP of the ribbon's own
## lift, never instead of it: the marking sits on the ribbon, and the ribbon sits on the ground. Same
## reasoning as DEPTH_LIFT — coplanar geometry is decided by float precision, not by draw order.
const MARKING_LIFT: float = 0.005


## The stripes across one road, as `{offset, style, width}` in the grader's `u`.
##
## ---- WHAT DECIDES A LINE ----
##
## Three kinds, and they answer different questions:
##
##   EDGE lines mark where the carriageway stops and the shoulder begins. Always solid, always present:
##     they are the road's own boundary, not a traffic rule, and they exist on every road including a
##     one-way one.
##   The DIVIDER separates OPPOSING traffic, and `divider_type` describes it. It exists only where there
##     is opposing traffic to separate: **a one-way road has no centre line**, whatever its type resource
##     says, because there is nothing on the other side of it. Painting one is not a cosmetic error —
##     it tells a driver the far lane is oncoming when it is not.
##   LANE lines separate traffic going the SAME way. Always dashed, because same-direction lanes may
##     always be changed between; a solid one would mean something this system has no way to express.
##
## So the divider is found by looking for the boundary where the DIRECTION changes, not by taking the
## middle of the road. Those coincide on a symmetric two-way road and diverge on every 2+1, and the
## centre of the road is the wrong answer on exactly the roads where the line matters most.
static func plan(p_lanes: Array, p_divider: int, p_one_way: bool) -> Array:
	var out: Array = []
	if p_lanes.size() < 1:
		return out

	# Edge lines: the outer edges of the outermost lanes.
	out.append({ "offset": float(p_lanes[0]["right_edge"]), "style": Style.SOLID, "width": STRIPE_WIDTH })
	out.append({ "offset": float(p_lanes[p_lanes.size() - 1]["left_edge"]), "style": Style.SOLID,
			"width": STRIPE_WIDTH })

	# Internal boundaries, walking right to left. Each is between lane i and lane i+1.
	for i in range(p_lanes.size() - 1):
		var boundary := float(p_lanes[i]["left_edge"])
		var changes_direction: bool = int(p_lanes[i]["direction"]) != int(p_lanes[i + 1]["direction"])
		if changes_direction and not p_one_way:
			out.append_array(_divider_stripes(boundary, p_divider))
		else:
			out.append({ "offset": boundary, "style": Style.DASHED, "width": STRIPE_WIDTH })
	return out


## One divider boundary expanded into the stripes actually painted there.
##
## DASHED_SOLID's asymmetry is a real rule and needs a stated convention: the SOLID stripe is on the
## positive-`u` (driver's-right) side of the divider, meaning the traffic on that side may not cross.
## There is no geometric fact that decides this — it is which side of the road the no-overtaking
## restriction applies to — so it is documented rather than guessed, and a designer who wants it the
## other way makes the road one-way and pairs it, the same escape hatch the odd-lane rule uses (§9.2).
static func _divider_stripes(p_at: float, p_divider: int) -> Array:
	match p_divider:
		Pasture3DRoadType.DividerType.NONE:
			return []
		Pasture3DRoadType.DividerType.SINGLE_SOLID:
			return [{ "offset": p_at, "style": Style.SOLID, "width": STRIPE_WIDTH }]
		Pasture3DRoadType.DividerType.DOUBLE_SOLID:
			return [
				{ "offset": p_at + DOUBLE_GAP * 0.5, "style": Style.SOLID, "width": STRIPE_WIDTH },
				{ "offset": p_at - DOUBLE_GAP * 0.5, "style": Style.SOLID, "width": STRIPE_WIDTH }]
		Pasture3DRoadType.DividerType.DASHED_SOLID:
			return [
				{ "offset": p_at + DOUBLE_GAP * 0.5, "style": Style.SOLID, "width": STRIPE_WIDTH },
				{ "offset": p_at - DOUBLE_GAP * 0.5, "style": Style.DASHED, "width": STRIPE_WIDTH }]
		_: # SINGLE_DASHED, and anything a newer version adds
			return [{ "offset": p_at, "style": Style.DASHED, "width": STRIPE_WIDTH }]


## The arc-length runs a stripe is actually painted over, within `[p_from, p_to]`.
##
## A solid stripe is one run. A dashed one is the dashes that INTERSECT the span, clipped to it — found
## from absolute arc length rather than from the start of the span, so a stripe's dashes land in the
## same places however the road was chunked. A dash pattern restarted per chunk would put a join in the
## middle of a dash at every region boundary, and the two halves would be a different length each time
## the region size changed.
static func runs(p_style: int, p_from: float, p_to: float) -> Array:
	if p_to <= p_from:
		return []
	if p_style != Style.DASHED:
		return [[p_from, p_to]]
	var out: Array = []
	var k := floor(p_from / DASH_PITCH)
	while k * DASH_PITCH < p_to:
		var a := maxf(k * DASH_PITCH, p_from)
		var b := minf(k * DASH_PITCH + DASH_LENGTH, p_to)
		if b > a:
			out.append([a, b])
		k += 1.0
	return out


## The markings over `[p_from, p_to]` as ONE surface array, or [] when nothing is painted there.
##
## Every stripe vertex goes through `Pasture3DRoadGrader.surface_height`, exactly as the ribbon's do —
## a marking that computed its own height would drift from the road it is painted on, and drift of a
## millimetre on a surface this thin is the marking disappearing rather than z-fighting visibly.
##
## Wound the same way as the ribbon: `[i0, i2, i1, i1, i2, i3]` is clockwise seen from above, which is
## Godot's front face. Reversed, markings are invisible from the road and visible only from beneath it.
static func build(p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_alignment: Pasture3DRoadAlignment, p_stripes: Array, p_from: float, p_to: float,
		p_crown: float, p_step: float = 2.0, p_lift: float = 0.0) -> Array:
	if p_alignment == null or p_plan.size() < 2 or p_stripes.is_empty():
		return []
	var lift := p_lift + MARKING_LIFT
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	for stripe: Dictionary in p_stripes:
		var offset := float(stripe["offset"])
		var hw := float(stripe["width"]) * 0.5
		for run: Array in runs(int(stripe["style"]), p_from, p_to):
			_emit_run(p_plan, p_cum, p_alignment, offset, hw, float(run[0]), float(run[1]),
					p_crown, p_step, lift, verts, normals, uvs, indices)
	if indices.is_empty():
		return []
	Pasture3DRoadMesher._recompute_normals(verts, indices, normals)
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = normals
	out[Mesh.ARRAY_TEX_UV] = uvs
	out[Mesh.ARRAY_INDEX] = indices
	return out


## One continuous painted run: a two-vertex-wide strip along the road, on the road's own surface.
static func _emit_run(p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_alignment: Pasture3DRoadAlignment, p_offset: float, p_half: float, p_from: float,
		p_to: float, p_crown: float, p_step: float, p_lift: float, r_verts: PackedVector3Array,
		r_normals: PackedVector3Array, r_uvs: PackedVector2Array, r_indices: PackedInt32Array) -> void:
	# INCREASING u, the same order `Pasture3DRoadMesher.cross_offsets` walks the carriageway in. The
	# order is not cosmetic: with the index pattern below it decides the handedness, so a stripe built
	# right-to-left is wound backwards and paints markings on the underside of the road.
	var offsets := PackedFloat32Array([p_offset - p_half, p_offset + p_half])
	var base := r_verts.size()
	var rings := 0
	var s := p_from
	while true:
		var ring := Pasture3DRoadMesher.ring(p_plan, p_cum, p_alignment, s, offsets, p_crown, p_lift)
		if ring.size() < 2:
			return
		for i in ring.size():
			r_verts.append(ring[i])
			r_normals.append(Vector3.UP)
			r_uvs.append(Vector2(float(i), s))
		rings += 1
		if s >= p_to:
			break
		# The final ring is `p_to` ITSELF, not wherever the walk landed — the same rule the ribbon's
		# spans follow, and for the same reason: a dash that ended a step short of its own end would be
		# a different length depending on where the chunk started.
		s = minf(s + maxf(p_step, 0.05), p_to)
	for r in range(rings - 1):
		var i0 := base + r * 2
		var i1 := i0 + 1
		var i2 := i0 + 2
		var i3 := i0 + 3
		r_indices.append_array(PackedInt32Array([i0, i2, i1, i1, i2, i3]))
