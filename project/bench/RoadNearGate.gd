# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadNearGate — P5c TIER NEAR (§10): lane markings, collision, roadside props.
#
# ---- WHAT MAKES THIS TIER DIFFERENT TO GATE ----
#
# Tier FAR and tier MID are wrong in ways that are visible: an unpainted road, a cracked seam, an
# invisible ribbon. Tier NEAR is wrong in ways that are LEGIBLE BUT MEANINGLESS — a centre line down a
# one-way road, a dashed line where a solid one belongs, a guardrail on the wrong side. Each of those
# renders perfectly, and each tells a driver something false about the road they are on.
#
# So the criteria here are mostly about MEANING rather than about geometry, and the markings kernel is
# split in two to make that checkable: `plan()` answers "which stripes, where, broken or not" in a few
# numbers that can be asserted directly, while `build()` only extrudes them. Reading "this road has no
# centre line" out of a mesh would be an inference about vertex positions; reading it out of a plan is
# the claim itself.
@tool
extends Node

const DS: float = 1.0

var _fail: int = 0


func _ready() -> void:
	print("=== RoadNearGate: markings, collision and props (P5c tier NEAR) ===\n")
	_a_a_one_way_road_has_no_centre_line()
	_b_the_divider_type_decides_the_stripes_it_names()
	_c_the_divider_sits_where_the_direction_changes()
	_d_dashes_are_placed_in_absolute_arc_length()
	_e_markings_sit_on_the_road_and_above_it()
	_f_collision_is_the_graded_surface_not_the_lifted_one()
	_g_props_stand_on_the_side_of_the_road_they_were_asked_for()
	print("\n=== %s (%d failures) ===\n" % ["ROAD NEAR PASS" if _fail == 0 else "ROAD NEAR FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


## Every criterion this gate intends to run. A criterion that CRASHES prints its heading, aborts before
## reaching any _check, and would otherwise leave the tally at zero and the gate reporting PASS — a gate
## that says "no failures" because nothing was measured is worse than no gate. So the expected names are
## declared up front and the ones that never reported are counted as failures.
const CRITERIA: Array[String] = ["A", "B", "C", "D", "E", "F", "G"]

var _reported: Dictionary = {}


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_reported[p_name] = true
	if not p_ok:
		_fail += 1
	print("%s %s: %s" % ["   " if p_ok else "!! ", p_name, p_detail])


## The criteria that never reached a _check at all.
func _account_for_silent_criteria() -> void:
	for name in CRITERIA:
		if not _reported.has(name):
			_fail += 1
			print("!!  %s: never reported — it crashed or returned early, so nothing was measured" % name)


func _lanes(p_count: int, p_one_way: bool, p_left_hand: bool = false) -> Array:
	return Pasture3DRoadLanes.cross_section(p_count, 3.5, p_one_way, p_left_hand)


## Stripes that are DASHED, by offset — the shape most criteria here are actually about.
func _styles(p_stripes: Array) -> String:
	var parts: Array = []
	for s: Dictionary in p_stripes:
		parts.append("%+.3f%s" % [float(s["offset"]),
				"=" if int(s["style"]) == Pasture3DRoadMarkings.Style.DASHED else "-"])
	return ", ".join(parts)


# ---- A ------------------------------------------------------------------------------------------

## [A] A one-way road has no centre line, whatever its type resource says.
##
## `divider_type` describes the line between OPPOSING streams, and a one-way road has none — so the
## setting is not merely inapplicable, acting on it is actively false. A centre line tells a driver the
## far lane is oncoming. On a one-way road every lane goes the same way and the boundary between them is
## a lane line, which may be crossed.
##
## This is the criterion a marking system fails by being reasonable: taking `divider_type` at face value
## and drawing what it says is the obvious implementation, and it is wrong on every one-way road.
func _a_a_one_way_road_has_no_centre_line() -> void:
	print("[A] a one-way road has no centre line")
	var solid := Pasture3DRoadType.DividerType.DOUBLE_SOLID
	var one_way := Pasture3DRoadMarkings.plan(_lanes(2, true), solid, true)
	print("    2-lane ONE-WAY, divider_type DOUBLE_SOLID -> %s" % _styles(one_way))
	var solids := 0
	for s: Dictionary in one_way:
		if int(s["style"]) == Pasture3DRoadMarkings.Style.SOLID:
			solids += 1
	# Two solids exactly: the two edge lines. Any more and a divider was drawn.
	_check("A", one_way.size() == 3 and solids == 2,
			"%d stripes, %d solid (want 3 and 2: two edges plus one dashed lane line)"
					% [one_way.size(), solids])

	# CONTROL: the SAME road two-way must draw the divider, or [A] passes on a kernel that never draws
	# a divider at all — which would be a marking system with no centre lines anywhere.
	var two_way := Pasture3DRoadMarkings.plan(_lanes(2, false), solid, false)
	var two_solids := 0
	for s: Dictionary in two_way:
		if int(s["style"]) == Pasture3DRoadMarkings.Style.SOLID:
			two_solids += 1
	print("    control: the same road TWO-WAY -> %s" % _styles(two_way))
	if two_way.size() != 4 or two_solids != 4:
		_fail += 1
		print("    !! the two-way road did not draw its double-solid divider (%d stripes, %d solid)"
				% [two_way.size(), two_solids])


# ---- B ------------------------------------------------------------------------------------------

## [B] Each divider type draws the stripes its name describes.
##
## The interesting half is that DOUBLE_SOLID and DASHED_SOLID are TWO stripes, not one stripe with a
## style. A kernel that carried them as styles all the way to the mesh would have to expand them in the
## builder, and the builder is the wrong place: it would mean the plan — the thing that says what the
## road MEANS — could not be read without knowing how it renders.
##
## DASHED_SOLID also has an asymmetry with no geometric answer: which side may not be crossed. It is a
## stated convention (solid on the driver's right), and it is checked here because a convention nobody
## asserts is a convention that flips the next time the code is touched.
func _b_the_divider_type_decides_the_stripes_it_names() -> void:
	print("[B] the divider type decides the stripes it names")
	var lanes := _lanes(2, false)
	var counts: Array = []
	var expect := [2, 3, 3, 4, 4]  # NONE, SINGLE_DASHED, SINGLE_SOLID, DOUBLE_SOLID, DASHED_SOLID
	for t in [Pasture3DRoadType.DividerType.NONE, Pasture3DRoadType.DividerType.SINGLE_DASHED,
			Pasture3DRoadType.DividerType.SINGLE_SOLID, Pasture3DRoadType.DividerType.DOUBLE_SOLID,
			Pasture3DRoadType.DividerType.DASHED_SOLID]:
		var p := Pasture3DRoadMarkings.plan(lanes, t, false)
		counts.append(p.size())
		print("    divider %d -> %d stripes: %s" % [t, p.size(), _styles(p)])
	_check("B", counts == expect, "stripe counts %s (want %s)" % [str(counts), str(expect)])

	# The DASHED_SOLID convention, stated and asserted: solid on the positive-u (driver's-right) side.
	var ds := Pasture3DRoadMarkings.plan(lanes, Pasture3DRoadType.DividerType.DASHED_SOLID, false)
	var solid_u := NAN
	var dashed_u := NAN
	for s: Dictionary in ds:
		if absf(float(s["offset"])) > 3.0:
			continue  # an edge line, not part of the divider
		if int(s["style"]) == Pasture3DRoadMarkings.Style.SOLID:
			solid_u = float(s["offset"])
		else:
			dashed_u = float(s["offset"])
	print("    DASHED_SOLID: solid at u %+.3f, dashed at u %+.3f (solid must be the RIGHT one)"
			% [solid_u, dashed_u])
	if not (is_finite(solid_u) and is_finite(dashed_u) and solid_u > dashed_u):
		_fail += 1; print("    !! the no-crossing side is not the one the convention names")

	# CONTROL: NONE must remove the divider and NOTHING else. An implementation that returned [] for the
	# whole plan would pass a count check that only looked at the divider.
	var none := Pasture3DRoadMarkings.plan(lanes, Pasture3DRoadType.DividerType.NONE, false)
	print("    control: divider NONE still draws %d edge lines (want 2)" % none.size())
	if none.size() != 2:
		_fail += 1; print("    !! NONE removed more than the divider")


# ---- C ------------------------------------------------------------------------------------------

## [C] The divider sits where the DIRECTION changes, not at the middle of the road.
##
## Those are the same place on a symmetric two-way road and different on every 2+1 — a three-lane road
## with two lanes one way and one the other, which is exactly the layout where a driver most needs the
## line to be right. A kernel that took the centre of the carriageway would put the divider through the
## middle of the two-lane side, marking half of a forward lane as oncoming.
func _c_the_divider_sits_where_the_direction_changes() -> void:
	print("[C] the divider sits where the direction changes")
	var lanes := _lanes(3, false)  # 2 forward + 1 backward, per the odd-lane convention (§9.2)
	var p := Pasture3DRoadMarkings.plan(lanes, Pasture3DRoadType.DividerType.SINGLE_SOLID, false)
	var divider_u := NAN
	for s: Dictionary in p:
		if int(s["style"]) == Pasture3DRoadMarkings.Style.SOLID and absf(float(s["offset"])) < 5.0:
			divider_u = float(s["offset"])
	# Lanes are 3.5 m and the carriageway is 10.5 m wide, so the centre is u = 0 and the direction
	# change is one lane off it, at u = -1.75.
	var want := -1.75
	print("    3-lane 2+1: divider at u %+.3f; the middle of the road is u %+.3f" % [divider_u, 0.0])
	_check("C", is_finite(divider_u) and absf(divider_u - want) < 1e-4,
			"divider at u %+.4f (want %+.4f, where forward meets backward)" % [divider_u, want])

	# CONTROL: the middle of the road must be a DIFFERENT place on this fixture, or the criterion cannot
	# tell the two rules apart and would pass on either.
	print("    control: those differ by %.3f m (want > 0.5)" % absf(want - 0.0))
	if absf(want - 0.0) <= 0.5:
		_fail += 1; print("    !! the fixture is symmetric; it cannot distinguish the two rules")

	# CONTROL: driving on the LEFT must move the divider to the mirror offset. If it does not, the
	# kernel is reading lane order rather than lane direction.
	var left := Pasture3DRoadMarkings.plan(_lanes(3, false, true),
			Pasture3DRoadType.DividerType.SINGLE_SOLID, false)
	var left_u := NAN
	for s: Dictionary in left:
		if int(s["style"]) == Pasture3DRoadMarkings.Style.SOLID and absf(float(s["offset"])) < 5.0:
			left_u = float(s["offset"])
	print("    control: left-hand traffic puts it at u %+.3f (want %+.3f)" % [left_u, -want])
	if not (is_finite(left_u) and absf(left_u + want) < 1e-4):
		_fail += 1; print("    !! traffic side does not move the divider")


# ---- D ------------------------------------------------------------------------------------------

## [D] Dashes are placed in ABSOLUTE arc length, so chunking cannot move them.
##
## A dash pattern restarted per chunk puts a join in the middle of a dash at every region boundary, and
## makes the two halves a different length each time the region size changes. The fix is that `runs`
## takes absolute `s` and clips: asking for [0, 100] and asking for [0, 40] then [40, 100] must paint
## the same metres of road.
##
## This is the seam contract from P5b in another form, and it fails the same silent way: the road looks
## right everywhere except at the boundaries, which is where nobody thinks to look.
func _d_dashes_are_placed_in_absolute_arc_length() -> void:
	print("[D] dashes are placed in absolute arc length")
	var dashed := Pasture3DRoadMarkings.Style.DASHED
	var whole := Pasture3DRoadMarkings.runs(dashed, 0.0, 100.0)
	# Cut at 37 m, which is INSIDE the dash running 36-39 m. Cutting in a gap would split nothing and
	# the criterion would pass on a kernel that dropped every dash straddling a boundary.
	var split := Pasture3DRoadMarkings.runs(dashed, 0.0, 37.0)
	split.append_array(Pasture3DRoadMarkings.runs(dashed, 37.0, 100.0))
	var whole_m := 0.0
	for r: Array in whole:
		whole_m += float(r[1]) - float(r[0])
	var split_m := 0.0
	for r: Array in split:
		split_m += float(r[1]) - float(r[0])
	print("    one span: %d dashes, %.3f m painted; split at 37 m: %d dashes, %.3f m painted"
			% [whole.size(), whole_m, split.size(), split_m])
	_check("D", absf(whole_m - split_m) < 1e-4,
			"%.4f m painted whole vs %.4f m split (want equal)" % [whole_m, split_m])

	# A dash landing ON the cut must be split, not dropped or duplicated: 40 m is inside the dash that
	# starts at 36 m, so the split must produce exactly one MORE run than the whole span did.
	print("    the cut at 37 m falls inside the dash running 36-39 m -> %d runs vs %d"
			% [split.size(), whole.size()])
	if split.size() != whole.size() + 1:
		_fail += 1; print("    !! the dash across the cut was dropped or duplicated, not split")

	# CONTROL: a SOLID stripe is one run over any span, or the dashing logic is running on everything.
	var solid := Pasture3DRoadMarkings.runs(Pasture3DRoadMarkings.Style.SOLID, 0.0, 100.0)
	print("    control: a solid stripe over the same span -> %d run (want 1)" % solid.size())
	if solid.size() != 1:
		_fail += 1; print("    !! a solid stripe is being broken into dashes")


# ---- E ------------------------------------------------------------------------------------------

## [E] Markings sit ON the road surface, and strictly above it.
##
## Both halves matter and they pull against each other. Checked against the GRADER, like the ribbon in
## RoadMeshGate [E]: a marking that computed its own height would drift from the road it is painted on,
## and on a surface this thin drift does not z-fight visibly, it makes the marking vanish. But it must
## also be strictly HIGHER than the ribbon, by MARKING_LIFT, or it is coplanar with it and which one
## draws is decided by float precision.
func _e_markings_sit_on_the_road_and_above_it() -> void:
	print("[E] markings sit on the road and above it")
	var plan := PackedVector2Array([Vector2(0.0, 8.0), Vector2(100.0, 8.0)])
	var cum := Pasture3DRoadGrader.cumulative_length(plan)
	var a := Pasture3DRoadAlignment.new()
	a.ds = DS
	var z := PackedFloat32Array(); var bank := PackedFloat32Array(); var curv := PackedFloat32Array()
	z.resize(101); bank.resize(101); curv.resize(101)
	for i in 101:
		z[i] = float(i) * 0.03
		bank[i] = 0.06
	a.z = z; a.ground = z.duplicate(); a.bank = bank; a.curvature = curv

	var ribbon_lift := Pasture3DRoadMesher.DEPTH_LIFT
	var stripes := Pasture3DRoadMarkings.plan(_lanes(2, false),
			Pasture3DRoadType.DividerType.SINGLE_SOLID, false)
	var arrays := Pasture3DRoadMarkings.build(plan, cum, a, stripes, 0.0, 30.0, 0.05, 2.0, ribbon_lift)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var worst := 0.0
	for v in verts:
		var hit := Pasture3DRoadGrader.nearest_on_plan(plan, cum, Vector2(v.x, v.z))
		var si := a.index_at(hit[1])
		var want := Pasture3DRoadGrader.surface_height(a.height_at(hit[1]), a.bank[si], 0.05,
				float(hit[0]) * float(hit[2])) + ribbon_lift + Pasture3DRoadMarkings.MARKING_LIFT
		worst = maxf(worst, absf(v.y - want))
	print("    %d vertices, largest disagreement with the graded surface %.9f m" % [verts.size(), worst])
	_check("E", verts.size() > 0 and worst < 1e-4,
			"worst marking vertex is %.9f m off the road (want 0)" % worst)

	# CONTROL: strictly above the ribbon, and by the amount the constant names.
	print("    control: markings clear the ribbon by %.4f m (want > 0)"
			% Pasture3DRoadMarkings.MARKING_LIFT)
	if Pasture3DRoadMarkings.MARKING_LIFT <= 0.0:
		_fail += 1; print("    !! markings are coplanar with the ribbon")

	# CONTROL: wound Godot's way, or the markings are visible only from under the road — the exact bug
	# the ribbon shipped with in P5b.
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var facing_away := 0
	var i := 0
	while i + 2 < idx.size():
		var n := (verts[idx[i + 1]] - verts[idx[i]]).cross(verts[idx[i + 2]] - verts[idx[i]])
		if n.y >= 0.0:
			facing_away += 1
		i += 3
	print("    control: %d of %d marking triangles wound away from above (want 0)"
			% [facing_away, idx.size() / 3])
	if facing_away > 0:
		_fail += 1; print("    !! the markings are wound the way the ribbon was when it was invisible")


# ---- F ------------------------------------------------------------------------------------------

## [F] Collision is the GRADED surface, not the lifted ribbon.
##
## The ribbon floats DEPTH_LIFT above the ground it was graded into, so it cannot z-fight with it. A
## collider built from the same arrays inherits that lift and becomes a road sitting two centimetres
## above itself: a wheel rests early, a ground raycast hits the road before the terrain, and "on the
## road" and "on the ground" stop being the same height. The lift fixes a rendering problem; collision
## has no rendering problem to fix.
##
## Small enough to look like nothing and exactly the kind of thing that is never traced back — a car
## that floats fractionally reads as suspension tuning, not as geometry.
func _f_collision_is_the_graded_surface_not_the_lifted_one() -> void:
	print("[F] collision is the graded surface, not the lifted ribbon")
	var run := _fixture()
	var plan: PackedVector2Array = run["plan"]
	var cum: PackedFloat32Array = run["cum"]
	var a: Pasture3DRoadAlignment = run["alignment"]
	var collide := Pasture3DRoadMesher.build_chunk(plan, cum, a, 0.0, 30.0, 4.0, 1.0, 0.05, 0, 0.0)
	var verts: PackedVector3Array = collide[Mesh.ARRAY_VERTEX]
	var worst := 0.0
	for v in verts:
		var hit := Pasture3DRoadGrader.nearest_on_plan(plan, cum, Vector2(v.x, v.z))
		var si := a.index_at(hit[1])
		var want := Pasture3DRoadGrader.surface_height(a.height_at(hit[1]), a.bank[si], 0.05,
				float(hit[0]) * float(hit[2]))
		worst = maxf(worst, absf(v.y - want))
	print("    %d collision vertices, largest disagreement with the graded ground %.9f m"
			% [verts.size(), worst])
	_check("F", verts.size() > 0 and worst < 1e-4,
			"worst collision vertex is %.9f m off the graded ground (want 0)" % worst)

	# CONTROL: the RENDERED chunk over the same span must NOT match it, and must be high by exactly the
	# lift. Without this the criterion passes on a build that dropped the lift everywhere -- which would
	# fix collision by breaking the ribbon, the bug P5b spent a session on.
	var drawn := Pasture3DRoadMesher.build_chunk(plan, cum, a, 0.0, 30.0, 4.0, 1.0, 0.05, 0,
			Pasture3DRoadMesher.DEPTH_LIFT)
	var drawn_verts: PackedVector3Array = drawn[Mesh.ARRAY_VERTEX]
	var gap := 0.0
	var same := true
	for i in mini(verts.size(), drawn_verts.size()):
		var d := drawn_verts[i].y - verts[i].y
		gap = maxf(gap, d)
		if absf(d - Pasture3DRoadMesher.DEPTH_LIFT) > 1e-6:
			same = false
	print("    control: the drawn ribbon over the same span is %.4f m higher, uniformly %s"
			% [gap, "yes" if same else "NO"])
	if gap <= 0.0 or not same:
		_fail += 1
		print("    !! the ribbon is not lifted above its own collider by exactly DEPTH_LIFT")


# ---- G ------------------------------------------------------------------------------------------

## [G] Props stand on the side of the road they were asked for, facing the way that side travels.
##
## Two claims, and the second is the one that gets skipped. Placing a post at the mirrored offset is
## easy; the copy across the road faces BACKWARDS unless it is turned, because it is the same object
## seen from the other side. On anything with a front -- a sign, a chevron, a one-way guardrail -- that
## is visible immediately, and on a plain post it is invisible until the first prop with a front is
## swapped in and everything on one verge is suddenly wrong.
func _g_props_stand_on_the_side_of_the_road_they_were_asked_for() -> void:
	print("[G] props stand on the side of the road they were asked for")
	var run := _fixture()
	var plan: PackedVector2Array = run["plan"]
	var cum: PackedFloat32Array = run["cum"]
	var a: Pasture3DRoadAlignment = run["alignment"]
	# The road runs along +X at z = 8, so the driver's right is +Z: a positive offset must raise z.
	var right := Pasture3DRoadProps.place(plan, cum, a, 0.0, 30.0, 6.0, 10.0, 0.05)
	var off_side := 0
	for t: Transform3D in right:
		if t.origin.z <= 8.0:
			off_side += 1
	print("    %d props at u +6 m; %d landed on the wrong side of the centreline (want 0)"
			% [right.size(), off_side])
	_check("G", right.size() == 3 and off_side == 0,
			"%d props (want 3, at s = 0/10/20), %d on the wrong side" % [right.size(), off_side])

	# CONTROL: a NEGATIVE offset must put them on the other side, or the sign is being discarded and
	# every prop is on the same verge.
	var left := Pasture3DRoadProps.place(plan, cum, a, 0.0, 30.0, -6.0, 10.0, 0.05)
	var crossed := 0
	for t: Transform3D in left:
		if t.origin.z < 8.0:
			crossed += 1
	print("    control: u -6 m puts %d of %d on the other side (want all)" % [crossed, left.size()])
	if left.size() == 0 or crossed != left.size():
		_fail += 1; print("    !! a negative offset does not cross the road")

	# CONTROL: spacing is absolute, so a span split in two places the same props. Same rule as dashes,
	# and a worse failure: two chunks each starting their own count put two posts at every seam.
	var whole := Pasture3DRoadProps.place(plan, cum, a, 0.0, 30.0, 6.0, 10.0, 0.05)
	# Split at 20 m: an EXACT multiple of the spacing, which is the case that doubles. A cut at 13 m
	# would pass on a closed interval, because no prop sits there to be placed twice.
	var split := Pasture3DRoadProps.place(plan, cum, a, 0.0, 20.0, 6.0, 10.0, 0.05)
	split.append_array(Pasture3DRoadProps.place(plan, cum, a, 20.0, 30.0, 6.0, 10.0, 0.05))
	print("    control: one span places %d, split ON a prop at 20 m places %d (want equal)"
			% [whole.size(), split.size()])
	if whole.size() != split.size():
		_fail += 1; print("    !! chunking changes where the props stand")

	# CONTROL: place_both must TURN the far side, not just mirror it.
	var both := Pasture3DRoadProps.place_both(plan, cum, a, 0.0, 30.0, 6.0, 10.0, 0.05)
	var facings: Array = []
	for t: Transform3D in both:
		facings.append(-t.basis.z)
	var opposed := false
	for f: Vector3 in facings:
		for h: Vector3 in facings:
			if f.dot(h) < -0.5:
				opposed = true
	print("    control: place_both makes %d props; the two verges face opposite ways: %s"
			% [both.size(), "yes" if opposed else "NO"])
	if both.size() != right.size() + left.size() or not opposed:
		_fail += 1; print("    !! the far verge was copied rather than turned")


## A straight road along +X at z = 8, climbing and banked. Shared by [F] and [G]; flat and level would
## let both pass on code that ignored the alignment.
func _fixture() -> Dictionary:
	var plan := PackedVector2Array([Vector2(0.0, 8.0), Vector2(100.0, 8.0)])
	var cum := Pasture3DRoadGrader.cumulative_length(plan)
	var a := Pasture3DRoadAlignment.new()
	a.ds = DS
	var z := PackedFloat32Array(); var bank := PackedFloat32Array(); var curv := PackedFloat32Array()
	z.resize(101); bank.resize(101); curv.resize(101)
	for i in 101:
		z[i] = float(i) * 0.03
		bank[i] = 0.06
	a.z = z; a.ground = z.duplicate(); a.bank = bank; a.curvature = curv
	return {"plan": plan, "cum": cum, "alignment": a}
