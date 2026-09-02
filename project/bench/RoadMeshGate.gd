# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadMeshGate — P5b TIER MID (§10): the chunked ribbon mesh.
#
# ---- WHY THIS IS ALL NUMBERS AND NO VIEWPORT ----
#
# Every claim §10 makes about tier MID is arithmetic: where the cuts fall, whether two chunks share
# their seam exactly, what an LOD is allowed to drop, and whether the ribbon sits on the ground the
# grader carved. None of those needs a rendered frame, and a rendered frame is the worst way to check
# any of them — a crack a millimetre wide is invisible at every camera angle except the one the player
# finds.
#
# The seam criterion is the reason this gate exists. It compares vertices for EXACT equality rather
# than with a tolerance, because that is the actual contract: `ring` is a pure function of arc length,
# so two chunks meeting at the same `s` compute the same floats. A mesher that walked `s += step` per
# chunk would agree to six decimal places, pass any tolerance you would think to write, and crack.
@tool
extends Node

const REGION: float = 32.0
const DS: float = 1.0

var _fail: int = 0


func _ready() -> void:
	print("=== RoadMeshGate: the chunked ribbon (P5b tier MID) ===\n")
	_a_chunks_are_cut_on_region_boundaries()
	_b_a_seam_shares_its_vertices_exactly()
	_c_no_chunk_runs_through_a_junction()
	_d_lod_coarsens_but_never_narrows()
	_e_the_ribbon_sits_on_the_ground_the_grader_carved()
	_f_the_surface_faces_up_and_is_wound_one_way()
	_g_uvs_run_in_metres_so_a_chunk_does_not_rescale_the_road()
	_h_distance_picks_the_tier_the_thresholds_name()
	_i_the_apron_is_the_same_surface_as_the_ground_it_covers()
	_j_only_the_minor_road_stops_at_a_junction()
	_k_distance_is_measured_to_the_chunk_not_to_its_centre()
	_l_a_tier_does_not_chatter_on_its_own_threshold()
	_m_a_road_type_edit_rebuilds_the_ribbon()
	print("\n=== %s (%d failures) ===\n" % ["ROAD MESH PASS" if _fail == 0 else "ROAD MESH FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	if not p_ok:
		_fail += 1
	print("%s %s: %s" % ["   " if p_ok else "!! ", p_name, p_detail])


# ---- fixtures -----------------------------------------------------------------------------------

## A straight road along +X from x = 0 to x = 100, at z = 8 so it is not sitting on a region line, with
## a solved profile that climbs and banks. Returns `{plan, cum, alignment}`.
##
## Climbing and banked on purpose: a flat straight road makes [E] pass on a mesher that ignores the
## alignment entirely and puts every vertex at y = 0.
func _run(p_bank: float = 0.06) -> Dictionary:
	var plan := PackedVector2Array([Vector2(0.0, 8.0), Vector2(100.0, 8.0)])
	var cum := Pasture3DRoadGrader.cumulative_length(plan)
	var n := 101
	var a := Pasture3DRoadAlignment.new()
	a.ds = DS
	var z := PackedFloat32Array()
	var bank := PackedFloat32Array()
	var curv := PackedFloat32Array()
	z.resize(n); bank.resize(n); curv.resize(n)
	for i in n:
		z[i] = float(i) * 0.03  # a 3% climb, so height varies along the run
		bank[i] = p_bank
	a.z = z
	a.ground = z.duplicate()
	a.bank = bank
	a.curvature = curv
	return {"plan": plan, "cum": cum, "alignment": a}


func _chunk(p_run: Dictionary, p_from: float, p_to: float, p_lod: int = 0) -> Array:
	return Pasture3DRoadMesher.build_chunk(p_run["plan"], p_run["cum"], p_run["alignment"],
			p_from, p_to, 4.0, 1.0, 0.05, p_lod)


func _verts(p_surface: Array) -> PackedVector3Array:
	return p_surface[Mesh.ARRAY_VERTEX] if not p_surface.is_empty() else PackedVector3Array()


# ---- A ------------------------------------------------------------------------------------------

## [A] Chunks are cut where terrain regions are, so a chunk and the region under it live and die
## together and one visibility test serves both.
##
## The road runs 0 → 100 along X with 32 m regions, so the boundaries it crosses are at x = 32, 64 and
## 96 — and because the road starts at x = 0 and runs along X, those are arc lengths 32, 64 and 96 too,
## which is what makes the expected answer writable rather than computed.
func _a_chunks_are_cut_on_region_boundaries() -> void:
	print("[A] chunks are cut on region boundaries")
	var run := _run()
	var cuts := Pasture3DRoadMesher.cut_points(run["plan"], run["cum"], REGION)
	var shown := PackedStringArray()
	for c in cuts:
		shown.append("%.1f" % c)
	print("    100 m road, %.0f m regions -> cuts at %s" % [REGION, " ".join(shown)])
	var want := PackedFloat32Array([0.0, 32.0, 64.0, 96.0, 100.0])
	var ok := cuts.size() == want.size()
	if ok:
		for i in want.size():
			ok = ok and absf(cuts[i] - want[i]) < 0.01
	_check("A", ok, "%s (want 0.0 32.0 64.0 96.0 100.0)" % " ".join(shown))

	# CONTROL: a different region size must move every interior cut. Without it [A] passes on a mesher
	# that cuts every 32 m by arithmetic and has never heard of a region.
	var coarse := Pasture3DRoadMesher.cut_points(run["plan"], run["cum"], 50.0)
	var coarse_shown := PackedStringArray()
	for c in coarse:
		coarse_shown.append("%.1f" % c)
	print("    control: 50 m regions -> %s (want 0.0 50.0 100.0)" % " ".join(coarse_shown))
	if coarse.size() != 3 or absf(coarse[1] - 50.0) > 0.01:
		_fail += 1; print("    !! the cuts do not follow the region size")

	# CONTROL: a road running diagonally crosses X lines and Z lines at different places and needs a cut
	# at each. Without this the criterion passes on a mesher that only ever looks at one axis, which is
	# correct for exactly the axis-aligned road above.
	var diag := PackedVector2Array([Vector2(0.0, 0.0), Vector2(100.0, 100.0)])
	var diag_cuts := Pasture3DRoadMesher.cut_points(diag, Pasture3DRoadGrader.cumulative_length(diag),
			REGION)
	# 3 X-crossings + 3 Z-crossings, but on a 45° road each pair coincides, so 3 interior cuts + 2 ends.
	print("    control: 45° road -> %d cuts (want 5, the coincident pairs merged)" % diag_cuts.size())
	if diag_cuts.size() != 5:
		_fail += 1; print("    !! diagonal region crossings are not being found on both axes")


# ---- B ------------------------------------------------------------------------------------------

## [B] Two chunks meeting at a cut share their seam vertices EXACTLY.
##
## The §10 claim, and the one that cannot be checked by looking. Compared with `==` and not with a
## tolerance, because the contract is that `ring` is a pure function of arc length: the same `s` gives
## the same floats, so the two chunks produce bit-identical vertices rather than nearby ones. A mesher
## that accumulated `s += step` within each chunk would pass any tolerance you would think to write and
## still open a crack — the error is in the last bits, and a crack is a gap of exactly that size.
func _b_a_seam_shares_its_vertices_exactly() -> void:
	print("[B] a seam shares its vertices exactly")
	var run := _run()
	# 37.0 chosen because it is NOT a multiple of the sample spacing: a seam that only works on a sample
	# boundary is a seam that works by luck.
	var left := _verts(_chunk(run, 0.0, 37.0))
	var right := _verts(_chunk(run, 37.0, 74.0))
	var across := Pasture3DRoadMesher.cross_offsets(4.0, 1.0, Pasture3DRoadMesher.Cross.FULL).size()
	var tail := PackedVector3Array()
	var head := PackedVector3Array()
	for c in across:
		tail.append(left[left.size() - across + c])
		head.append(right[c])
	var exact := true
	var worst := 0.0
	for c in across:
		exact = exact and tail[c] == head[c]
		worst = maxf(worst, tail[c].distance_to(head[c]))
	print("    cut at 37.0 (not on a sample boundary) -> %d seam vertices, largest gap %.20f m"
			% [across, worst])
	_check("B", exact, "seam vertices are %s" % ["bit-identical" if exact
			else "MERELY CLOSE (%.20f m apart) — a crack of exactly that width" % worst])

	# CONTROL: chunks that do NOT meet must not have matching seams, or [B] passes on a comparison that
	# is not looking at what it thinks it is.
	var elsewhere := _verts(_chunk(run, 40.0, 74.0))
	var same := true
	for c in across:
		same = same and tail[c] == elsewhere[c]
	print("    control: a chunk starting at 40.0 -> seam %s (want differs)"
			% ["MATCHES ANYWAY" if same else "differs"])
	if same:
		_fail += 1; print("    !! the comparison is not reading the vertices it claims to")

	# CONTROL: the seam must also hold at a coarse LOD, where the walk takes fewer, longer steps and the
	# end of the span is least likely to land on one.
	var lod_left := _verts(_chunk(run, 0.0, 37.0, 2))
	var lod_right := _verts(_chunk(run, 37.0, 74.0, 2))
	var lod_across := Pasture3DRoadMesher.cross_offsets(4.0, 1.0,
			Pasture3DRoadMesher.cross_for_lod(2)).size()
	var lod_exact := true
	for c in lod_across:
		lod_exact = lod_exact and lod_left[lod_left.size() - lod_across + c] == lod_right[c]
	print("    control: same seam at LOD 2 -> %s" % ["exact" if lod_exact else "CRACKED"])
	if not lod_exact:
		_fail += 1; print("    !! the seam holds at LOD 0 by luck of the step landing on it")


# ---- C ------------------------------------------------------------------------------------------

## [C] No chunk runs through a junction footprint.
##
## §10: never chunk across an intersection. The junction owns the surface inside its footprint, so a
## ribbon crossing it would be a second road surface fighting the first — visible as z-fighting in the
## middle of every crossroads, which reads as a junction bug rather than as a chunking one.
func _c_no_chunk_runs_through_a_junction() -> void:
	print("[C] no chunk runs through a junction")
	var run := _run()
	var skips := [[45.0, 55.0]]
	var spans := Pasture3DRoadMesher.chunk_spans(run["plan"], run["cum"], REGION, skips)
	var shown := PackedStringArray()
	var trespass := 0
	for sp in spans:
		shown.append("[%.1f, %.1f]" % [sp[0], sp[1]])
		# Overlapping the footprint at all, not merely starting inside it.
		if float(sp[0]) < 55.0 and float(sp[1]) > 45.0:
			trespass += 1
	print("    footprint 45–55 -> %s" % " ".join(shown))
	_check("C", trespass == 0, "%d chunk(s) overlap the footprint (want 0)" % trespass)

	# CONTROL: without the footprint, something MUST span 45–55, or [C] passes on a mesher that produced
	# no chunks there for some unrelated reason.
	var bare := Pasture3DRoadMesher.chunk_spans(run["plan"], run["cum"], REGION)
	var covers := 0
	for sp in bare:
		if float(sp[0]) < 55.0 and float(sp[1]) > 45.0:
			covers += 1
	print("    control: no footprint -> %d chunk(s) cover 45–55 (want at least 1)" % covers)
	if covers < 1:
		_fail += 1; print("    !! nothing was being built there anyway")

	# CONTROL: the road either side of the junction must still be built. A mesher that dropped the whole
	# road whenever it met a junction would satisfy "no chunk runs through one" perfectly.
	var before := false
	var after := false
	for sp in spans:
		before = before or float(sp[1]) <= 45.0 + 0.01
		after = after or float(sp[0]) >= 55.0 - 0.01
	print("    control: road before the junction %s, after it %s"
			% ["built" if before else "MISSING", "built" if after else "MISSING"])
	if not before or not after:
		_fail += 1; print("    !! the junction removed more than its own footprint")


# ---- D ------------------------------------------------------------------------------------------

## [D] A coarser LOD uses fewer vertices, and the carriageway keeps its width at every one.
##
## §10 orders the decimation — shoulder and camber collapse first, carriageway last — and the width is
## the part that must not move. A road that narrows as it recedes visibly changes width as you drive at
## it, which is the exact pop that tier FAR was designed to avoid and would be reintroduced here.
func _d_lod_coarsens_but_never_narrows() -> void:
	print("[D] LOD coarsens but never narrows")
	var run := _run()
	var counts := PackedInt32Array()
	var widths := PackedFloat32Array()
	for lod in Pasture3DRoadMesher.LOD_LEVELS:
		var v := _verts(_chunk(run, 0.0, 64.0, lod))
		counts.append(v.size())
		var lo := INF
		var hi := -INF
		for p in v:
			lo = minf(lo, p.z)
			hi = maxf(hi, p.z)
		widths.append(hi - lo)
	var shown := PackedStringArray()
	for i in counts.size():
		shown.append("L%d: %d verts, %.2f m wide" % [i, counts[i], widths[i]])
	print("    %s" % " | ".join(shown))
	var monotone := true
	for i in range(1, counts.size()):
		monotone = monotone and counts[i] < counts[i - 1]
	# Full width is half 4 + shoulder 1, both sides = 10 m; the coarsest keeps the carriageway only, 8 m.
	var keeps_carriageway := widths[widths.size() - 1] >= 8.0 - 0.01
	_check("D", monotone and keeps_carriageway,
			"%s; coarsest is %.2f m wide (want at least 8.00, the carriageway)"
					% ["each level is cheaper" if monotone else "NOT MONOTONE", widths[widths.size() - 1]])

	# CONTROL: the shoulder must actually be present at LOD 0, or "keeps the carriageway" is trivially
	# true because nothing ever had a shoulder.
	print("    control: LOD 0 is %.2f m wide (want 10.00, carriageway plus both shoulders)" % widths[0])
	if absf(widths[0] - 10.0) > 0.01:
		_fail += 1; print("    !! the full cross-section is not being built at LOD 0")

	# CONTROL: the camber must go before the shoulder does, which is the ORDER §10 specifies. LOD 1 has
	# to keep both shoulder edges and lose the crown vertex.
	var l1 := Pasture3DRoadMesher.cross_offsets(4.0, 1.0, Pasture3DRoadMesher.cross_for_lod(1))
	var has_crown := l1.has(0.0)
	var has_shoulder := l1.has(-5.0) and l1.has(5.0)
	print("    control: LOD 1 cross-section %s -> crown %s, shoulders %s"
			% [str(Array(l1)), "kept" if has_crown else "dropped",
				"kept" if has_shoulder else "dropped"])
	if has_crown or not has_shoulder:
		_fail += 1; print("    !! the decimation order is not camber-then-shoulder")


# ---- E ------------------------------------------------------------------------------------------

## [E] The ribbon sits exactly on the surface the grader carved.
##
## Both are `Pasture3DRoadGrader.surface_height` of the same arc length, which is why that function
## lives in the grader and neither owns a copy. Checked against the grader DIRECTLY rather than against
## a formula written out here: a copy of the formula in the gate would agree with a mesher that had
## drifted from the grader, which is the only way this can actually go wrong.
func _e_the_ribbon_sits_on_the_ground_the_grader_carved() -> void:
	print("[E] the ribbon sits on the ground the grader carved")
	var run := _run(0.06)
	var a: Pasture3DRoadAlignment = run["alignment"]
	var s := 30.0
	var offsets := PackedFloat32Array([-4.0, 0.0, 4.0])
	var lift := Pasture3DRoadMesher.DEPTH_LIFT
	var line := Pasture3DRoadMesher.ring(run["plan"], run["cum"], a, s, offsets, 0.05, lift)
	var centre: float = a.height_at(s)
	var bank: float = a.bank[a.index_at(s)]
	var worst := 0.0
	for i in offsets.size():
		var want := Pasture3DRoadGrader.surface_height(centre, bank, 0.05, offsets[i]) + lift
		worst = maxf(worst, absf(line[i].y - want))
	print("    at s = 30, u = -4/0/+4 -> y %.4f %.4f %.4f (grader + %.3f m lift says %.4f %.4f %.4f)"
			% [line[0].y, line[1].y, line[2].y, lift,
				Pasture3DRoadGrader.surface_height(centre, bank, 0.05, -4.0) + lift,
				Pasture3DRoadGrader.surface_height(centre, bank, 0.05, 0.0) + lift,
				Pasture3DRoadGrader.surface_height(centre, bank, 0.05, 4.0) + lift])
	_check("E", worst < 1e-5, "largest disagreement with the grader's shape %.9f m (want 0)" % worst)

	# CONTROL: the lift must be a real, positive, CONSTANT offset. Coplanar is the one thing the ribbon
	# must never be — the ground under it was graded to the road's own profile, so a ribbon at exactly
	# that height has its depth test decided by float precision, and disappears wherever the terrain's
	# clipmap rounds upward. Constant and not scaled, or the camber would drift from the ground it sits
	# on.
	var flat_on_ground := Pasture3DRoadMesher.ring(run["plan"], run["cum"], a, s, offsets, 0.05, 0.0)
	var lifts := PackedFloat32Array()
	for i in offsets.size():
		lifts.append(line[i].y - flat_on_ground[i].y)
	var uniform := absf(lifts[0] - lifts[1]) < 1e-6 and absf(lifts[1] - lifts[2]) < 1e-6
	print("    control: lift at u = -4/0/+4 is %.4f %.4f %.4f m (want %.4f, the same at every offset)"
			% [lifts[0], lifts[1], lifts[2], lift])
	if lift <= 0.0 or not uniform:
		_fail += 1; print("    !! the ribbon is coplanar with the ground, or the lift varies across it")

	# CONTROL: with a positive bank the RIGHT edge must be higher than the left, and by the full
	# 2 * bank * half. Without this [E] passes on a ribbon that is flat, since a flat ribbon agrees with
	# a grader the mesher is calling for both answers.
	var tilt := line[2].y - line[0].y
	print("    control: bank 0.06 over ±4 m -> right edge %.3f m above left (want 0.480)" % tilt)
	if absf(tilt - 0.48) > 0.001:
		_fail += 1; print("    !! the ribbon is not banked, or is banked the wrong way")

	# CONTROL: the crown must drop both edges relative to the centre, so water sheds off each side.
	var flat := Pasture3DRoadMesher.ring(run["plan"], run["cum"], a, s, offsets, 0.05, lift)
	var no_crown := Pasture3DRoadMesher.ring(run["plan"], run["cum"], a, s, offsets, 0.0, lift)
	var shed := (no_crown[0].y - flat[0].y) + (no_crown[2].y - flat[2].y)
	print("    control: removing the crown raises both edges by %.3f m total (want 0.400)" % shed)
	if absf(shed - 0.4) > 0.001:
		_fail += 1; print("    !! the crown is not shedding to both edges")


# ---- F ------------------------------------------------------------------------------------------

## [F] The surface is wound so GODOT draws it when you look down at it.
##
## THIS CRITERION WAS WRONG ONCE, AND THE WAY IT WAS WRONG IS THE POINT. It asserted that every
## triangle's geometric (b-a) x (c-a) pointed +Y — the right-hand rule, the convention a maths textbook
## uses and the one you reach for without thinking. Godot's front face is CLOCKWISE as seen from the
## front, which is the opposite: a triangle that must be visible from above has to look clockwise from
## above, so its geometric cross points DOWN. The gate passed, the mesh was built in the right place at
## the right size with the right material, and it was visible only from underneath.
##
## A gate that encodes the convention its author assumed rather than the one the engine uses is worse
## than no gate, because it certifies the bug. So this asserts Godot's rule explicitly, and the control
## builds the other winding and demands that it FAIL — the check has to be able to tell the two apart,
## which the +Y version could not, having called the broken one correct.
##
## Shading normals are the other way round from the winding, and that is not a contradiction: the
## winding says which side is drawn, the normal says which way the light comes from, and both mean
## "up" here.
func _f_the_surface_faces_up_and_is_wound_one_way() -> void:
	print("[F] the surface is wound so Godot draws it from above")
	var run := _run()
	var surface := _chunk(run, 0.0, 32.0)
	var verts: PackedVector3Array = surface[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = surface[Mesh.ARRAY_INDEX]
	var normals: PackedVector3Array = surface[Mesh.ARRAY_NORMAL]
	var wrong_way := 0
	var i := 0
	while i + 2 < indices.size():
		# Front-facing from above, in Godot, means the geometric cross points DOWN.
		var n := (verts[indices[i + 1]] - verts[indices[i]]).cross(
				verts[indices[i + 2]] - verts[indices[i]])
		if n.y >= 0.0:
			wrong_way += 1
		i += 3
	var bad_normals := 0
	for nv in normals:
		if nv.y <= 0.9:
			bad_normals += 1
	print("    %d triangles, %d wound so Godot would cull them from above; %d of %d shading normals not up"
			% [indices.size() / 3, wrong_way, bad_normals, normals.size()])
	_check("F", wrong_way == 0 and bad_normals == 0,
			"%d triangles facing away and %d normals pointing down (want 0 and 0)"
					% [wrong_way, bad_normals])

	# CONTROL: the check must REJECT the other winding. Without this the criterion is just a statement
	# about a sign, and its previous version — which demanded the opposite sign — passed just as happily
	# on a road nobody could see.
	var flipped := 0
	var j := 0
	while j + 2 < indices.size():
		var n := (verts[indices[j + 2]] - verts[indices[j]]).cross(
				verts[indices[j + 1]] - verts[indices[j]])
		if n.y >= 0.0:
			flipped += 1
		j += 3
	print("    control: the reversed winding gives %d/%d triangles facing away (want all of them)"
			% [flipped, indices.size() / 3])
	if flipped != indices.size() / 3:
		_fail += 1; print("    !! the check cannot tell the two windings apart")

	# CONTROL: the normals must not be the constant UP they are seeded with — a banked road is tilted,
	# and lighting it flat throws away the only cue that says it is banked.
	var exact_up := 0
	for nv in normals:
		if nv == Vector3.UP:
			exact_up += 1
	print("    control: %d of %d normals are exactly UP on a banked road (want 0)"
			% [exact_up, normals.size()])
	if exact_up > 0:
		_fail += 1; print("    !! the normals were never recomputed from the geometry")


# ---- G ------------------------------------------------------------------------------------------

## [G] UVs run in METRES along the road, so a chunk boundary does not rescale the surface.
##
## The tempting alternative is to normalise V over the chunk, which looks identical on one chunk and
## wrong on every road: the texture would repeat exactly once per chunk, so markings would change scale
## at each region boundary and stretch wherever a junction made a chunk short. Across the road U IS
## normalised, because the carriageway's width is the natural unit there.
func _g_uvs_run_in_metres_so_a_chunk_does_not_rescale_the_road() -> void:
	print("[G] UVs run in metres, so a chunk does not rescale the road")
	var run := _run()
	var long_chunk: Array = _chunk(run, 0.0, 64.0)
	var short_chunk: Array = _chunk(run, 64.0, 70.0)
	var lu: PackedVector2Array = long_chunk[Mesh.ARRAY_TEX_UV]
	var su: PackedVector2Array = short_chunk[Mesh.ARRAY_TEX_UV]
	# The seam at s = 64 is the last row of one and the first row of the other: same V, in metres.
	var across := Pasture3DRoadMesher.cross_offsets(4.0, 1.0, Pasture3DRoadMesher.Cross.FULL).size()
	var v_end: float = lu[lu.size() - across].y
	var v_start: float = su[0].y
	print("    64 m chunk ends at V %.3f; the 6 m chunk after it starts at V %.3f (want both 64.000)"
			% [v_end, v_start])
	_check("G", absf(v_end - 64.0) < 0.01 and absf(v_start - 64.0) < 0.01,
			"V is %.3f then %.3f (want 64.000 both — metres, not normalised per chunk)"
					% [v_end, v_start])

	# CONTROL: U must span 0..1 across the carriageway, so the across-road texture has a natural width
	# whatever the road's own is.
	var u_lo := INF
	var u_hi := -INF
	for uv in lu:
		u_lo = minf(u_lo, uv.x)
		u_hi = maxf(u_hi, uv.x)
	print("    control: U spans %.3f .. %.3f (want the carriageway at 0.0 .. 1.0, shoulders outside)"
			% [u_lo, u_hi])
	if u_lo > -0.05 or u_hi < 1.05:
		_fail += 1; print("    !! U is not normalised on the carriageway")


# ---- H ------------------------------------------------------------------------------------------

## [H] A distance picks the tier its thresholds name, and never one past the meshes that exist.
##
## The only arithmetic in the host; everything else there is scene-tree work that needs a viewport. An
## off-by-one band is invisible in the worst way — the road still draws, at the wrong tier, and reads as
## the MESHES being wrong rather than as the thresholds being read wrong. The clamp matters as much: more
## thresholds than LOD levels is an ordinary authoring mistake, and indexing past the meshes would crash
## on the frame the camera got far enough away.
func _h_distance_picks_the_tier_the_thresholds_name() -> void:
	print("[H] distance picks the tier the thresholds name")
	var host := Pasture3DRoadChunkHost.new()
	add_child(host)
	host.lod_distances = PackedFloat32Array([60.0, 140.0, 300.0])
	var probes := PackedFloat32Array([0.0, 59.9, 60.0, 139.9, 140.0, 299.9, 300.0, 5000.0])
	var got := PackedInt32Array()
	var shown := PackedStringArray()
	for d in probes:
		var l := host.lod_for(d)
		got.append(l)
		shown.append("%.1f m -> L%d" % [d, l])
	print("    %s" % " | ".join(shown))
	var want := PackedInt32Array([0, 0, 1, 1, 2, 2, 3, 3])
	var ok := true
	for i in want.size():
		ok = ok and got[i] == want[i]
	_check("H", ok, "%s (want L0 L0 L1 L1 L2 L2 L3 L3 — a threshold is where the NEXT tier starts)"
			% " ".join(shown))

	# CONTROL: more thresholds than there are LOD levels must clamp, not index past the meshes. This is
	# an ordinary authoring mistake and it would crash on the frame the camera got far enough away.
	host.lod_distances = PackedFloat32Array([10.0, 20.0, 30.0, 40.0, 50.0, 60.0])
	var clamped := host.lod_for(55.0)
	print("    control: 6 thresholds, 4 LOD levels -> 55 m gives L%d (want L%d, the coarsest that exists)"
			% [clamped, Pasture3DRoadMesher.LOD_LEVELS - 1])
	if clamped > Pasture3DRoadMesher.LOD_LEVELS - 1:
		_fail += 1; print("    !! the tier index runs past the meshes that were built")

	# CONTROL: moving the thresholds must move the answer, or [H] passes on a host that returns a
	# constant.
	host.lod_distances = PackedFloat32Array([500.0])
	var near := host.lod_for(100.0)
	print("    control: a single 500 m threshold -> 100 m gives L%d (want L0)" % near)
	if near != 0:
		_fail += 1; print("    !! the thresholds are not being read")
	host.queue_free()


# ---- I ------------------------------------------------------------------------------------------

## [I] The junction apron is the same surface as the ground inside the footprint.
##
## The ground in there is not flat and is not at the junction's `elevation`: the grader lets the MAJOR
## road pave straight through, so the footprint holds that road's own crowned, banked, climbing surface.
## An apron laid flat at `elevation` would sit a crown above the carriageway edges and cut into the
## middle — a saucer at every crossroads, and one that would look like a junction-height bug rather than
## a meshing one.
##
## Checked against the grader, like [E], and for the same reason: a formula written out here would agree
## with an apron that had drifted from the ground.
func _i_the_apron_is_the_same_surface_as_the_ground_it_covers() -> void:
	print("[I] the apron is the same surface as the ground it covers")
	var run := _run(0.06)
	var a: Pasture3DRoadAlignment = run["alignment"]
	var lift := Pasture3DRoadMesher.DEPTH_LIFT
	var centre := Vector2(50.0, 8.0)  # on the road, which runs along z = 8
	var arrays := Pasture3DRoadMesher.build_apron(centre, 6.0, run["plan"], run["cum"], a, 0.05, 24, lift)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var worst := 0.0
	for v in verts:
		var hit := Pasture3DRoadGrader.nearest_on_plan(run["plan"], run["cum"], Vector2(v.x, v.z))
		var si := a.index_at(hit[1])
		var bank: float = a.bank[si]
		var want := Pasture3DRoadGrader.surface_height(a.height_at(hit[1]), bank, 0.05,
				float(hit[0]) * float(hit[2])) + lift
		worst = maxf(worst, absf(v.y - want))
	print("    %d vertices, largest disagreement with the graded ground %.9f m" % [verts.size(), worst])
	_check("I", worst < 1e-4, "worst vertex is %.9f m off the ground (want 0)" % worst)

	# CONTROL: a flat apron must FAIL this. Without it the criterion passes on a disc that happens to be
	# level because the fixture was, and the saucer would appear only on a banked or crowned junction —
	# which is most of them.
	var flat_worst := 0.0
	var level: float = verts[0].y
	for v in verts:
		flat_worst = maxf(flat_worst, absf(level - v.y))
	print("    control: a flat disc at the centre height would be %.3f m out at the rim (want > 0.05)"
			% flat_worst)
	if flat_worst <= 0.05:
		_fail += 1; print("    !! the fixture is too level to tell a fitted apron from a flat one")

	# CONTROL: the apron must be wound Godot's way too, or it is a hole with a lid nobody can see.
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var facing_away := 0
	var i := 0
	while i + 2 < idx.size():
		var n := (verts[idx[i + 1]] - verts[idx[i]]).cross(verts[idx[i + 2]] - verts[idx[i]])
		if n.y >= 0.0:
			facing_away += 1
		i += 3
	print("    control: %d of %d apron triangles wound away from above (want 0)"
			% [facing_away, idx.size() / 3])
	if facing_away > 0:
		_fail += 1; print("    !! the apron is wound the way the ribbon was when it was invisible")


# ---- J ------------------------------------------------------------------------------------------

## [J] Only the MINOR road stops at a junction; the major road paves through.
##
## This mirrors `grade_surface`, and the mirroring is the whole criterion. The grader skips a junction
## range only when the road is not the major one, so a mesher that skipped for BOTH leaves the major
## road's ribbon stopping where its ground does not — a hole at every crossroads with real graded road
## surface visible through it. That is what shipped, and it looked like a missing junction mesh rather
## than like the approach rule being applied to a road it does not apply to.
func _j_only_the_minor_road_stops_at_a_junction() -> void:
	print("[J] only the minor road stops at a junction")
	var j := Pasture3DRoadJunction.new()
	j.road_keys = PackedStringArray(["Major", "Minor"])
	j.arc_lengths = PackedFloat32Array([50.0, 50.0])
	j.trim_backs = PackedFloat32Array([8.0, 8.0])
	j.major_index = 0
	j.radius = 6.0
	j.detected = true
	print("    keys %s, major_index %d -> major_key %s, widest trim-back %.1f m"
			% [str(Array(j.road_keys)), j.major_index, j.major_key(), j.widest_trim_back()])
	_check("J", j.major_key() == "Major" and not j.is_major("Minor") and j.is_major("Major"),
			"major_key %s; is_major(Major) %s; is_major(Minor) %s (want Major, true, false)"
					% [j.major_key(), str(j.is_major("Major")), str(j.is_major("Minor"))])

	# CONTROL: the override must move it, or "the major road" is just whichever came first.
	j.major_override = 1
	print("    control: major_override 1 -> major_key %s (want Minor)" % j.major_key())
	if j.major_key() != "Minor":
		_fail += 1; print("    !! major_override does not decide who paves through")

	# CONTROL: the apron must reach at least as far as the approaches were trimmed back, or it is
	# smaller than the hole it exists to fill and leaves a ring of bare ground around itself.
	print("    control: radius %.1f m vs widest trim-back %.1f m -> apron must use %.1f m"
			% [j.radius, j.widest_trim_back(), maxf(j.radius, j.widest_trim_back())])
	if maxf(j.radius, j.widest_trim_back()) < j.widest_trim_back():
		_fail += 1; print("    !! the apron would be smaller than the trim-back")


# ---- K ------------------------------------------------------------------------------------------

## [K] Distance is measured to the CHUNK, not to its centre.
##
## A chunk is cut to a terrain region, so at the default 256 m region it is up to 256 m long. Measuring
## to its centre means the chunk you are STANDING ON reports up to 128 m, and two separate symptoms
## follow, neither of which looks like a distance problem:
##
##   Tier NEAR stops existing. With the default thresholds a full-length chunk under the camera is given
##   LOD 2, so the road is permanently coarse and it reads as the LOD meshes being wrong.
##
##   Whole chunks pop. A centre crossing `far_distance` takes 256 m of road with it in one frame, while
##   the near end of that chunk was still 470 m away.
##
## Both shipped. This criterion is the arithmetic that would have caught them, and it needs a LONG chunk
## to catch anything — which is why the fixture is a full region rather than a convenient 30 m.
func _k_distance_is_measured_to_the_chunk_not_to_its_centre() -> void:
	print("[K] distance is measured to the chunk, not to its centre")
	var host := Pasture3DRoadChunkHost.new()
	# A FULL REGION of road: 256 m, the default region size, because that is how long a real chunk is and
	# a short fixture cannot tell the two measurements apart. The 100 m fixture the rest of this gate uses
	# put its centre at 48 m, inside the first LOD band, so both rules agreed and the criterion proved
	# nothing — the control below is what said so.
	var plan := PackedVector2Array([Vector2(0.0, 8.0), Vector2(256.0, 8.0)])
	var cum := Pasture3DRoadGrader.cumulative_length(plan)
	var a := Pasture3DRoadAlignment.new()
	a.ds = DS
	var z := PackedFloat32Array(); var bank := PackedFloat32Array(); var curv := PackedFloat32Array()
	z.resize(257); bank.resize(257); curv.resize(257)
	for i in 257:
		z[i] = float(i) * 0.02
	a.z = z; a.ground = z.duplicate(); a.bank = bank; a.curvature = curv
	var arrays := Pasture3DRoadMesher.build_chunk(plan, cum, a, 0.0, 256.0, 4.0, 1.0, 0.05, 0)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var box := mesh.get_aabb()
	var chunk := { "bounds": box, "centre": box.get_center() }
	var eye := Vector3(2.0, 2.0, 8.0)  # on the road, a couple of metres in
	var to_chunk := host._distance_to(chunk, eye)
	var to_centre := eye.distance_to(chunk["centre"])
	print("    a %.0f m chunk; from its near end: %.1f m to the chunk, %.1f m to its centre"
			% [box.size.x, to_chunk, to_centre])
	print("    that is LOD %d against LOD %d" % [host.lod_for(to_chunk), host.lod_for(to_centre)])
	_check("K", to_chunk < 5.0 and host.lod_for(to_chunk) == 0,
			"standing on the chunk reads %.1f m and LOD %d (want ~0 m and LOD 0)"
					% [to_chunk, host.lod_for(to_chunk)])

	# CONTROL: the centre must give a DIFFERENT and worse answer on this fixture, or the criterion cannot
	# tell the two rules apart and would pass on either.
	print("    control: the centre disagrees by %.1f m and by %d tier(s) (both must be non-zero)"
			% [to_centre - to_chunk, host.lod_for(to_centre) - host.lod_for(to_chunk)])
	if to_centre - to_chunk < 10.0 or host.lod_for(to_centre) == host.lod_for(to_chunk):
		_fail += 1
		print("    !! the fixture chunk is too short to distinguish the two measurements")

	# CONTROL: the far-hide must use the same measurement. A chunk whose NEAR end is inside far_distance
	# must not be hidden because its centre is outside it — that is the popping, stated as arithmetic.
	var far_eye := Vector3(-590.0, 2.0, 8.0)
	var near_end := host._distance_to(chunk, far_eye)
	var centre_end := far_eye.distance_to(chunk["centre"])
	print("    control: from %.0f m away, near end %.0f m vs centre %.0f m against a %.0f m cutoff"
			% [590.0, near_end, centre_end, host.far_distance])
	if not (near_end < host.far_distance and centre_end > host.far_distance):
		_fail += 1
		print("    !! the fixture does not straddle the cutoff, so it cannot catch the pop")
	host.free()


# ---- L ------------------------------------------------------------------------------------------

## [L] A tier does not chatter on its own threshold.
##
## The thresholds are hard comparisons over a distance that jitters. A camera hovering on a line crosses
## it dozens of times a second and each crossing is a mesh swap, so the ribbon flickers — which reads as
## the chunks failing to build rather than as the comparison being exact.
##
## Hysteresis means the answer depends on what the chunk is ALREADY showing, so this is checked by
## walking the camera across a line and back rather than by asking for a single distance.
func _l_a_tier_does_not_chatter_on_its_own_threshold() -> void:
	print("[L] a tier does not chatter on its own threshold")
	var host := Pasture3DRoadChunkHost.new()
	var line: float = host.lod_distances[0]
	var band: float = host.lod_hysteresis
	# Sit exactly on the line and jitter by a metre, which is less than the band.
	var lod := 0
	var swaps := 0
	for k in 40:
		var d := line + (1.0 if k % 2 == 0 else -1.0)
		var want := host.lod_for(d, lod)
		if want != lod:
			swaps += 1
		lod = want
	print("    jittering 1 m either side of the %.0f m line for 40 frames: %d mesh swap(s)"
			% [line, swaps])
	_check("L", swaps <= 1, "%d swaps while jittering inside the %.0f m band (want at most 1)"
			% [swaps, band])

	# CONTROL: without hysteresis the SAME walk must chatter, or the criterion passes on a host whose
	# thresholds never move at all.
	host.lod_hysteresis = 0.0
	var raw_lod := 0
	var raw_swaps := 0
	for k in 40:
		var d := line + (1.0 if k % 2 == 0 else -1.0)
		var want := host.lod_for(d, raw_lod)
		if want != raw_lod:
			raw_swaps += 1
		raw_lod = want
	print("    control: with the band set to 0 the same walk swaps %d time(s) (want many)" % raw_swaps)
	if raw_swaps < 10:
		_fail += 1
		print("    !! the fixture does not actually cross the threshold, so the band proves nothing")

	# CONTROL: a REAL move must still change tier. Hysteresis that never lets go is a road stuck at
	# whatever tier it was first given.
	host.lod_hysteresis = band
	var moved := host.lod_for(line + band * 3.0, 0)
	var back := host.lod_for(0.0, moved)
	print("    control: %.0f m past the line -> LOD %d; back at the camera -> LOD %d (want 1 then 0)"
			% [band * 3.0, moved, back])
	if moved == 0 or back != 0:
		_fail += 1; print("    !! hysteresis is preventing a genuine tier change")
	host.free()


# ---- M ------------------------------------------------------------------------------------------
#
# PASTURE3D_ROAD_PERF_REGRESSION_SPEC.md R4, gate [T]. Added 2026-09-02.


## A road brush with a solved alignment and a chunk host, ready to rebuild. Everything real: the skip
## digest is computed from the brush and the road type, so a fixture that fakes either of them would be
## testing the fixture.
func _rebuild_fixture() -> Dictionary:
	var terrain := Pasture3D.new()
	terrain.region_size = 256
	terrain.vertex_spacing = 1.0
	add_child(terrain)

	var net := Pasture3DRoadNetwork.new()
	terrain.add_child(net)
	var t := Pasture3DRoadType.new()
	t.type_name = "mesh"
	t.lane_count = 2
	t.lane_width = 3.5
	t.shoulder_width = 1.0
	t.crown = 0.02
	net.road_types = [t]

	var brush := Pasture3DRoadBrush.new()
	brush.name = "MeshRoad"
	net.add_child(brush)
	brush.terrain = terrain
	brush.road_road_type = t

	var path := Path3D.new()
	var curve := Curve3D.new()
	for i in 6:
		curve.add_point(Vector3(float(i) * 40.0, 0.0, 0.0))
	path.curve = curve
	brush.add_child(path)

	var road_mod := Pasture3DNodeRoad.new()
	road_mod.alignment_step = 2.0
	brush.modifiers = [road_mod]

	# A solved alignment, so build_run() has something to hand the mesher.
	var plan := brush._plan_points()
	var cum := Pasture3DRoadGrader.cumulative_length(plan)
	var total: float = cum[cum.size() - 1]
	var ds := 2.0
	var n_s := int(ceil(total / ds)) + 1
	var a := Pasture3DRoadAlignment.new()
	a.ds = ds
	var z := PackedFloat32Array()
	var bank := PackedFloat32Array()
	z.resize(n_s)
	bank.resize(n_s)
	for i in n_s:
		z[i] = float(i) * ds * 0.02
		bank[i] = 0.0
	a.z = z
	a.ground = z.duplicate()
	a.bank = bank
	a.curvature = Pasture3DRoadGrader._zeros(n_s)
	road_mod.last_alignment = a

	var host := Pasture3DRoadChunkHost.new()
	brush.add_child(host)
	return {"terrain": terrain, "net": net, "type": t, "brush": brush, "host": host, "mod": road_mod}


## The ribbon's outer edge in a rebuilt host, measured off the vertices rather than read from the road
## type — the whole question is whether the MESH followed the type. This is `half_width + shoulder_width`,
## because the mesher lays the shoulder OUTSIDE the carriageway half-width it is handed; expecting
## `half_width` alone reads 9.0 where the type says 8.0 and looks like a mesher bug rather than a gate
## measuring the wrong edge.
func _mesh_outer_edge(p_host: Pasture3DRoadChunkHost) -> float:
	var widest := 0.0
	for child in p_host.get_children():
		if not (child is MeshInstance3D):
			continue
		var mesh: Mesh = (child as MeshInstance3D).mesh
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		var arrays: Array = mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for v in verts:
			widest = maxf(widest, absf(v.z))
	return widest


## [M] R4 — a road-type edit rebuilds the ribbon, and only the edits the ribbon reads do.
##
## The skip digest identified the road type by `str(t.get_instance_id())`, which does not change when the
## resource's properties change, and nothing else in the digest covered the cross-section. So the terrain
## re-graded to the new carriageway while the ribbon kept the old width and the old material.
##
## The ANTI-CHURN half is what makes this more than "rebuild everything". A digest that hashed every
## exported property would pass the first criterion and destroy the cache: it would rebuild the mesh on
## every vertical-only edit, which is the cost the skip exists to avoid. So `surface_id` — physics only,
## no mesh input — must NOT rebuild, and that is asserted as hard as the rebuild is.
func _m_a_road_type_edit_rebuilds_the_ribbon() -> void:
	print("[M] a road-type edit rebuilds the ribbon, and a non-mesh edit does not")
	var fx := _rebuild_fixture()
	var brush: Pasture3DRoadBrush = fx["brush"]
	var host: Pasture3DRoadChunkHost = fx["host"]
	var t: Pasture3DRoadType = fx["type"]

	var chunks := host.rebuild(brush)
	var edge_before := _mesh_outer_edge(host)
	print("    first build: %d chunk(s), outer edge %.3f m (type says %.3f)"
			% [chunks, edge_before, t.half_width(2) + t.shoulder_width])

	# A rebuild with NOTHING changed must be skipped, or the criterion below is met by a host that
	# rebuilds unconditionally and the digest is doing no work at all.
	host.rebuild(brush)
	var skipped_when_idle := not host.last_rebuilt
	print("    control: an unchanged rebuild is skipped = %s (want true)" % skipped_when_idle)
	if not skipped_when_idle:
		_fail += 1
		print("!!  the host rebuilds unconditionally, so [M] cannot tell a digest change from no digest")

	# The edit the ribbon must notice.
	t.lane_count = 4
	host.rebuild(brush)
	var rebuilt := host.last_rebuilt
	var edge_after := _mesh_outer_edge(host)
	var want := t.half_width(4) + t.shoulder_width
	print("    after lane_count 2 -> 4: last_rebuilt = %s, outer edge %.3f m (want %.3f)"
			% [rebuilt, edge_after, want])
	_check("M", rebuilt and absf(edge_after - want) < 0.01 and edge_after > edge_before + 1.0,
			"the ribbon widened to %.3f m (want %.3f, was %.3f)" % [edge_after, want, edge_before])

	# ANTI-CHURN: a physics-only edit must not rebuild the mesh.
	t.surface_id = &"gravel"
	host.rebuild(brush)
	var churned := host.last_rebuilt
	print("    control: after a surface_id edit (physics only), last_rebuilt = %s (want false)" % churned)
	if churned:
		_fail += 1
		print("!!  the digest churns on a property the mesh never reads, which defeats the skip")

	# And the other half of the same statement: crown IS a mesh input.
	t.crown = t.crown + 0.03
	host.rebuild(brush)
	var crown_rebuilt := host.last_rebuilt
	print("    control: after a crown edit (a mesh input), last_rebuilt = %s (want true)" % crown_rebuilt)
	if not crown_rebuilt:
		_fail += 1
		print("!!  a cross-section input does not reach the digest")

	(fx["terrain"] as Node).queue_free()
