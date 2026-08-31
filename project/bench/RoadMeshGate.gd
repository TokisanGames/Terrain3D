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
	var line := Pasture3DRoadMesher.ring(run["plan"], run["cum"], a, s, offsets, 0.05)
	var centre: float = a.height_at(s)
	var bank: float = a.bank[a.index_at(s)]
	var worst := 0.0
	for i in offsets.size():
		var want := Pasture3DRoadGrader.surface_height(centre, bank, 0.05, offsets[i])
		worst = maxf(worst, absf(line[i].y - want))
	print("    at s = 30, u = -4/0/+4 -> y %.4f %.4f %.4f (grader says %.4f %.4f %.4f)"
			% [line[0].y, line[1].y, line[2].y,
				Pasture3DRoadGrader.surface_height(centre, bank, 0.05, -4.0),
				Pasture3DRoadGrader.surface_height(centre, bank, 0.05, 0.0),
				Pasture3DRoadGrader.surface_height(centre, bank, 0.05, 4.0)])
	_check("E", worst < 1e-5, "largest disagreement with the grader %.9f m (want 0)" % worst)

	# CONTROL: with a positive bank the RIGHT edge must be higher than the left, and by the full
	# 2 * bank * half. Without this [E] passes on a ribbon that is flat, since a flat ribbon agrees with
	# a grader the mesher is calling for both answers.
	var tilt := line[2].y - line[0].y
	print("    control: bank 0.06 over ±4 m -> right edge %.3f m above left (want 0.480)" % tilt)
	if absf(tilt - 0.48) > 0.001:
		_fail += 1; print("    !! the ribbon is not banked, or is banked the wrong way")

	# CONTROL: the crown must drop both edges relative to the centre, so water sheds off each side.
	var flat := Pasture3DRoadMesher.ring(run["plan"], run["cum"], a, s, offsets, 0.05)
	var no_crown := Pasture3DRoadMesher.ring(run["plan"], run["cum"], a, s, offsets, 0.0)
	var shed := (no_crown[0].y - flat[0].y) + (no_crown[2].y - flat[2].y)
	print("    control: removing the crown raises both edges by %.3f m total (want 0.400)" % shed)
	if absf(shed - 0.4) > 0.001:
		_fail += 1; print("    !! the crown is not shedding to both edges")


# ---- F ------------------------------------------------------------------------------------------

## [F] The surface faces up, and every triangle is wound the same way.
##
## A ribbon wound the wrong way is invisible under backface culling and looks like the mesher not having
## run — the most confusing possible symptom for the most trivial possible cause. Normals are computed
## from the geometry rather than assumed UP, so a banked corner lights as banked; the check is therefore
## that they point upward, not that they equal UP.
func _f_the_surface_faces_up_and_is_wound_one_way() -> void:
	print("[F] the surface faces up and is wound one way")
	var run := _run()
	var surface := _chunk(run, 0.0, 32.0)
	var verts: PackedVector3Array = surface[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = surface[Mesh.ARRAY_INDEX]
	var normals: PackedVector3Array = surface[Mesh.ARRAY_NORMAL]
	var downward := 0
	var i := 0
	while i + 2 < indices.size():
		var n := (verts[indices[i + 1]] - verts[indices[i]]).cross(
				verts[indices[i + 2]] - verts[indices[i]])
		if n.y <= 0.0:
			downward += 1
		i += 3
	var bad_normals := 0
	for nv in normals:
		if nv.y <= 0.9:
			bad_normals += 1
	print("    %d triangles, %d wound downward; %d of %d normals not pointing up"
			% [indices.size() / 3, downward, bad_normals, normals.size()])
	_check("F", downward == 0 and bad_normals == 0,
			"%d downward triangles and %d bad normals (want 0 and 0)" % [downward, bad_normals])

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
