# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Roadside props — tier NEAR (§10, P5c). Kerbs, guardrails, marker posts, verge planting: anything
# repeated along a road at a fixed distance from it.
#
# A PURE KERNEL. It produces transforms and hands them to whoever is placing them — which is
# `Pasture3DInstancer`, because the instancer already stores per-region multimeshes keyed by region
# location, so road props stream with terrain regions for free and need no streaming code of their own
# (§10). Keeping the placement maths out of that hand-off is what makes it checkable: "the posts are on
# the correct side of the road" is a claim about transforms, and reading it back out of a multimesh
# would be a claim about a rendering system instead.
@tool
class_name Pasture3DRoadProps
extends RefCounted


## Transforms for one line of props along `[p_from, p_to]`, at across-distance `p_offset`.
##
## ---- WHY SPACING IS ABSOLUTE, LIKE DASHES ----
##
## Placement walks ABSOLUTE arc length, the same rule `Pasture3DRoadMarkings.runs` follows. Restarting
## the count per chunk would put a post at every region boundary and change every gap when the region
## size changed — and unlike a dash, a post at a chunk seam is a post standing next to another post,
## because the neighbouring chunk starts its own count at the same metre.
##
## ---- WHAT `p_offset` MEANS ----
##
## Signed metres across, positive to the driver's RIGHT: the grader's `u`, the same coordinate the
## carriageway was graded in and the markings were planned in. A guardrail belongs OUTSIDE the
## carriageway, so its offset is greater than the half-width — passing a smaller one puts the rail in
## the road, which is a legal transform and a wrong one, so the caller states the offset rather than
## having a side inferred for it.
##
## Each transform is upright with -Z along the road (Godot's forward), so a prop authored facing -Z
## faces the way the traffic on its side of the road travels. Props are NOT banked with the carriageway:
## a post leans with the ground it is planted in, not with the camber of the road beside it, and a
## banked guardrail reads as a modelling error at every corner.
static func place(p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_alignment: Pasture3DRoadAlignment, p_from: float, p_to: float, p_offset: float,
		p_spacing: float, p_crown: float, p_lift: float = 0.0) -> Array:
	var out: Array = []
	if p_alignment == null or p_plan.size() < 2 or p_to <= p_from:
		return out
	var spacing := maxf(p_spacing, 0.25)
	var k: float = ceil(p_from / spacing)
	# HALF-OPEN: a prop is placed at `s` where p_from <= s < p_to. Closed at both ends, two chunks meeting
	# at an exact multiple of the spacing BOTH place one there — two posts in the same hole at every
	# region boundary that happens to land on the grid. Half-open costs at most one prop at the very end
	# of a road, which nobody sees; the alternative is a doubled prop at a boundary, which everyone does.
	while k * spacing < p_to:
		var s: float = k * spacing
		k += 1.0
		var at := Pasture3DRoadGrader.plan_point_at(p_plan, p_cum, s)
		var tangent := Pasture3DRoadGrader.plan_tangent_at(p_plan, p_cum, s)
		if tangent.length_squared() < 1e-12:
			continue
		tangent = tangent.normalized()
		# (-y, x) is the driver's RIGHT in the (x, z) plane — the same derivation the lane kernel uses.
		var right := Vector2(-tangent.y, tangent.x)
		var pos := at + right * p_offset
		var si := p_alignment.index_at(s)
		var bank: float = p_alignment.bank[si] if si < p_alignment.bank.size() else 0.0
		var y := Pasture3DRoadGrader.surface_height(p_alignment.height_at(s), bank, p_crown, p_offset)
		# Upright, facing along the road. Godot's forward is -Z, so the basis' -Z is the tangent.
		var fwd := Vector3(tangent.x, 0.0, tangent.y)
		var basis := Basis(Vector3(-fwd.z, 0.0, fwd.x).normalized(), Vector3.UP, -fwd)
		out.append(Transform3D(basis, Vector3(pos.x, y + p_lift, pos.y)))
	return out


## Both verges at once: `p_offset` to the right and its mirror to the left, each facing the way traffic
## on that side travels.
##
## The mirror is a rotation, not a negated offset with the same basis. A marker post copied straight
## across the road faces backwards — it is the same object seen from the other side — and on anything
## with a front (a sign, a chevron, a one-way guardrail) that is immediately visible.
static func place_both(p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_alignment: Pasture3DRoadAlignment, p_from: float, p_to: float, p_offset: float,
		p_spacing: float, p_crown: float, p_lift: float = 0.0) -> Array:
	var out := place(p_plan, p_cum, p_alignment, p_from, p_to, absf(p_offset), p_spacing, p_crown, p_lift)
	for t: Transform3D in place(p_plan, p_cum, p_alignment, p_from, p_to, -absf(p_offset), p_spacing,
			p_crown, p_lift):
		out.append(Transform3D(t.basis.rotated(Vector3.UP, PI), t.origin))
	return out
