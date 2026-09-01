# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphGeometryLoweringGate — a PATH as an operand in the lowered native program (P2c).
#
# ---- WHAT CHANGED, AND WHY IT NEEDS ITS OWN GATE ----
#
# The four road nodes each ran native maths already (P2a). What they could not do was travel in the
# LOWERED program: `GraphProgram` had nowhere to put a polyline, so every one of them returned
# `blocks_native() == true`, and because that bail is graph-wide a single Road Source dropped the whole
# graph — the erosion beside it, the noise above it — onto the GDScript evaluator.
#
# P2c adds the geometry table (PASTURE3D_GRAPH_GEOMETRY_PORTS_SPEC.md §4.1): geometry is bound to the
# program before evaluation, `in_g` names a table entry, and the three consumer ops read it. The four
# overrides are deleted. So the question this gate asks about every fixture is TWO questions, and they
# are answered by different code:
#
#   * does `native_supported()` say yes, and does `compile_graph_program()` actually produce a program
#   * and does that program give the same field the GDScript evaluator gives
#
# A graph that reports lowerable and then compiles to `{}` falls back silently and looks perfect.
#
# ---- THE ONE ANSWER WHOSE WRONG VALUE IS INVISIBLE ----
#
# An unwired geometry operand is the empty path, and §4.3 fixes what each op must answer for it:
# distance is `unreachable`, a mask is 0, a grade passes the surface through. The dangerous one is
# distance, because 0 does not read as an error — it reads as "every cell is on the road", and a
# downstream Road Grade then flattens the entire terrain to the road's crown and reports success. [A]
# carries that as a control rather than trusting the kernel's own empty branch, which is a different
# branch from the program's `in_g == -1`.
extends Node

const CRITERIA: Array[String] = ["A", "B", "C", "D", "E"]

const GW: int = 96
const GH: int = 96
const RECT := Rect2(-48.0, -48.0, 96.0, 96.0)
const EPS: float = 1.0e-4

var _fail: int = 0
var _seen: Dictionary = {}


func _ready() -> void:
	print("=== GraphGeometryLoweringGate: a PATH as an operand in the native program (P2c) ===")
	print("    spec: PASTURE3D_GRAPH_GEOMETRY_PORTS_SPEC.md §4, P2c")

	_a_a_path_reaches_the_lowered_program()
	_b_the_mask_lowers_in_both_of_its_two_rules()
	_c_the_grader_lowers_with_all_six_channels()
	_d_the_flagship_wiring_lowers_end_to_end()
	_e_one_road_read_four_times_is_one_table_entry()

	for name in CRITERIA:
		if not _seen.has(name):
			_fail += 1
			print("!! criterion %s never reported" % name)
	print("=== GRAPH GEOMETRY LOWERING %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	if not p_ok:
		_fail += 1
	print("    %s%s: %s" % ["" if p_ok else "!! ", p_name, p_detail])


# ---- fixtures ------------------------------------------------------------------------------------

## Ground that tilts across the road AND undulates along it, so the grader both cuts and fills and the
## batter meets ground at a different distance in every row. A flat fixture would make cut and fill the
## same field and two of [C]'s channels would agree with each other by accident.
func _terrain() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(GW * GH)
	var dx := RECT.size.x / float(GW)
	var dz := RECT.size.y / float(GH)
	for iz in GH:
		var wz: float = RECT.position.y + (float(iz) + 0.5) * dz
		for ix in GW:
			var wx: float = RECT.position.x + (float(ix) + 0.5) * dx
			out[iz * GW + ix] = 0.09 * wx + 3.0 * sin(wz * 0.08) + 1.5 * cos(wx * 0.11)
	return out


## A curving road with a solved alignment: the fixture RoadNativeParityGate [F] uses, so a disagreement
## here and a disagreement there point at the same road rather than at two different ones.
func _road() -> Pasture3DGraphPath:
	var plan := PackedVector2Array()
	for i in 41:
		var t := float(i)
		plan.append(Vector2(-40.0 + t * 2.0, -20.0 + 0.012 * t * t))
	var cum := Pasture3DRoadGrader.cumulative_length(plan)
	var total: float = cum[cum.size() - 1]
	var n_s := int(total) + 1

	var a := Pasture3DRoadAlignment.new()
	a.ds = 1.0
	a.s0 = 0.0
	var z := PackedFloat32Array()
	var bank := PackedFloat32Array()
	var half := PackedFloat32Array()
	var shoulder := PackedFloat32Array()
	var verge := PackedFloat32Array()
	var suppress := PackedByteArray()
	var skip := PackedByteArray()
	for i in n_s:
		var f := float(i) / float(maxi(n_s - 1, 1))
		z.append(4.0 - 8.0 * f) # climbs out of fill and into cut, so both batters run
		bank.append(0.06 * sin(f * TAU))
		half.append(3.0 + 2.0 * f) # a road that widens: the per-sample lookup has to move
		shoulder.append(0.8)
		verge.append(3.0)
		suppress.append(1 if i > int(n_s * 0.55) and i < int(n_s * 0.65) else 0)
		skip.append(1 if i > int(n_s * 0.85) else 0)
	a.z = z
	a.bank = bank

	var path := Pasture3DGraphPath.new()
	path.points = plan
	path.half_widths = half
	path.alignment = a
	path.sample_half_widths = half
	path.sample_shoulders = shoulder
	path.sample_verges = verge
	path.sample_suppress = suppress
	path.sample_skip = skip
	return path


## A closed outline, for the mask's REGION rule. An L-shaped hexagon rather than a convex blob: the
## concave notch is what tells an even-odd interior test from a distance threshold, which agree
## everywhere on a convex shape.
func _outline() -> Pasture3DGraphPath:
	var path := Pasture3DGraphPath.new()
	path.points = PackedVector2Array([
		Vector2(-30.0, -26.0), Vector2(6.0, -26.0), Vector2(6.0, -4.0),
		Vector2(26.0, -4.0), Vector2(26.0, 20.0), Vector2(-30.0, 20.0)])
	path.half_widths = PackedFloat32Array([4.0])
	path.closed = true
	return path


func _source(p_path: Pasture3DGraphPath) -> Pasture3DGraphNodeRoadSource:
	var n := Pasture3DGraphNodeRoadSource.new()
	n.path = p_path
	return n


func _native(p_g: Pasture3DTerrainGraph, p_surf: PackedFloat32Array) -> PackedFloat32Array:
	return Pasture3DUtil.graph_eval_grid(p_g.compile_graph_program(), GW, GH, RECT, p_surf)


## The GDScript evaluator on the same graph, forced. `force_gdscript_evaluation` states the premise
## rather than borrowing whichever native limitation happens to survive — and after P2c there is no
## limitation left to borrow, which is the point of the phase.
func _oracle(p_g: Pasture3DTerrainGraph, p_surf: PackedFloat32Array) -> PackedFloat32Array:
	p_g.force_gdscript_evaluation = true
	var out := p_g.evaluate(GW, GH, RECT, null, p_surf)
	p_g.force_gdscript_evaluation = false
	return out


func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var w := 0.0
	for i in mini(p_a.size(), p_b.size()):
		if is_nan(p_a[i]) or is_nan(p_b[i]):
			if not (is_nan(p_a[i]) and is_nan(p_b[i])):
				return INF
			continue
		w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


func _spread(p_v: PackedFloat32Array) -> float:
	var lo := INF
	var hi := -INF
	for v in p_v:
		if is_finite(v):
			lo = minf(lo, v)
			hi = maxf(hi, v)
	return 0.0 if lo > hi else hi - lo


## Both halves of "it lowered", reported together. They come from different code and have been out of
## step before: a graph can report lowerable and then compile to {}, which falls back in silence.
func _lowers(p_g: Pasture3DTerrainGraph) -> bool:
	return p_g.native_supported() and not p_g.compile_graph_program().is_empty()


# ---- A -------------------------------------------------------------------------------------------

## [A] A graph containing a Road Source lowers at all, and the path reaches the query.
##
## Before P2c this graph could not be lowered for FOUR independent reasons — one `blocks_native()` on the
## source and one on the query, plus the program having no geometry operand and no channel for `s`. The
## criterion is the whole chain: supported, compiled, and equal to what the GDScript evaluator produces.
func _a_a_path_reaches_the_lowered_program() -> void:
	print("[A] a Road Source and a Path Distance lower into the native program")
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [
		_source(_road()), Pasture3DGraphNodePathDistance.new(), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0], [1, 0, 2, 0]]

	var surf := _terrain()
	var supported := _lowers(g)
	var nat := _native(g, surf)
	var orc := _oracle(g, surf)
	var worst := _worst(nat, orc)
	print("    lowers=%s, native vs the GDScript evaluator: worst %.7f" % [str(supported), worst])
	_check("A", supported and worst < EPS, "lowers %s, worst %.7f" % [str(supported), worst])

	# CONTROL: the distance field must VARY, and the road must actually be reached. Two evaluators agree
	# perfectly on a constant, and a fixture the road missed entirely would make every number here the
	# unreachable fill compared against itself.
	var near := 0
	for v in nat:
		if v < 2.0:
			near += 1
	print("    control: distance spans %.2f m, %d cell(s) within 2 m of the road (want > 0 both)"
			% [_spread(nat), near])
	if _spread(nat) <= 1.0 or near == 0:
		_fail += 1
		print("    !! the road is not reached on this fixture, so nothing here compared a query")

	# CONTROL: §4.3. A Road Source with NO path is `in_g == -1` in the program — a different branch from
	# the kernel's own empty-geometry check — and it must read as FAR AWAY. Zero would mean every cell is
	# on the road, which is silent, total, and looks like a working graph until a grader flattens the
	# terrain to the crown.
	var ge := Pasture3DTerrainGraph.new()
	var nodes_e: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeRoadSource.new(), Pasture3DGraphNodePathDistance.new(),
		Pasture3DGraphNodeOutput.new()]
	ge.nodes = nodes_e
	ge.connections = [[0, 0, 1, 0], [1, 0, 2, 0]]
	var empty := _native(ge, surf)
	var min_v := INF
	for v in empty:
		min_v = minf(min_v, v)
	print("    control: an unresolved Road Source reads %.1f m everywhere (want 10000, never 0)" % min_v)
	if min_v < 9999.0:
		_fail += 1
		print("    !! the empty path does not read as unreachable, so a grade downstream would flatten the terrain")


# ---- B -------------------------------------------------------------------------------------------

## [B] Path Mask lowers under BOTH of its rules, and they stay two rules.
##
## Open is a corridor and closed is a region; they are not one rule with a parameter. A native side that
## collapsed them would still pass a corridor comparison and would mask a lake as two ribbons with a hole
## down the middle. The control is that the same six points read open and read closed give different
## fields — which is the difference the two rules ARE.
func _b_the_mask_lowers_in_both_of_its_two_rules() -> void:
	print("[B] Path Mask lowers as a corridor and as a region")
	var surf := _terrain()
	var worst := 0.0
	var supported := true
	var fields: Array = []
	for closed in [false, true]:
		var outline := _outline()
		outline.closed = closed
		var g := Pasture3DTerrainGraph.new()
		var mask := Pasture3DGraphNodePathMask.new()
		mask.feather = 3.0
		var nodes: Array[Pasture3DGraphNode] = [
			_source(outline), mask, Pasture3DGraphNodeOutput.new()]
		g.nodes = nodes
		g.connections = [[0, 0, 1, 0], [1, 0, 2, 0]]
		var nat := _native(g, surf)
		var w := _worst(nat, _oracle(g, surf))
		fields.append(nat)
		supported = supported and _lowers(g)
		worst = maxf(worst, w)
		print("    %-9s worst %.7f, spans %.4f" % ["closed" if closed else "open", w, _spread(nat)])
	_check("B", supported and worst < EPS, "lowers %s, worst %.7f" % [str(supported), worst])

	# CONTROL: the region really is filled, not a ribbon along the boundary.
	var inside := 0
	for v in fields[1]:
		if v > 0.99:
			inside += 1
	print("    control: %.1f%% of the grid is interior (want a real area, not a rim)"
			% (100.0 * float(inside) / float(GW * GH)))
	if inside < GW * GH / 20:
		_fail += 1
		print("    !! the closed reading fills almost nothing, so it is not masking a region")

	# CONTROL: the two rules disagree. Identical fields would mean `closed` never reached the kernel.
	var apart := 0
	for i in fields[0].size():
		if absf(fields[0][i] - fields[1][i]) > 0.01:
			apart += 1
	print("    control: %d cell(s) differ between the open and closed readings (want many)" % apart)
	if apart < 100:
		_fail += 1
		print("    !! open and closed produce the same mask, so the closed flag is not being carried")


# ---- C -------------------------------------------------------------------------------------------

## [C] Road Grade lowers, with all six channels.
##
## This is where P2b and P2c meet: the grader writes six grids and they can only be read because a slot
## may own channels. Every one is compared, not a representative one — they come from one solve but by
## different rules (a distance test, a sign test on the height change, a suppression flag), and getting
## the indices right for one says nothing about the others.
func _c_the_grader_lowers_with_all_six_channels() -> void:
	print("[C] Road Grade lowers with all six channels")
	var surf := _terrain()
	var names := ["height", "roadbed", "cut", "fill", "verge", "structure"]
	var fields: Array = []
	var worst := 0.0
	var worst_ch := ""
	var supported := true
	for ch in 6:
		var g := Pasture3DTerrainGraph.new()
		var nodes: Array[Pasture3DGraphNode] = [
			Pasture3DGraphNodeInput.new(), _source(_road()), Pasture3DGraphNodeRoadGrade.new(),
			Pasture3DGraphNodeOutput.new()]
		g.nodes = nodes
		# Input → Grade.surface, Source → Grade.path, Grade[ch] → Output.
		g.connections = [[0, 0, 2, 0], [1, 0, 2, 1], [2, ch, 3, 0]]
		supported = supported and _lowers(g)
		var nat := _native(g, surf)
		var w := _worst(nat, _oracle(g, surf))
		fields.append(nat)
		print("    %-10s worst %.7f, spans %.4f" % [names[ch], w, _spread(nat)])
		if w > worst:
			worst = w
			worst_ch = names[ch]
	_check("C", supported and worst < EPS, "lowers %s, worst %.7f on %s"
			% [str(supported), worst, "nothing" if worst_ch == "" else worst_ch])

	# CONTROL: the road actually MOVED the ground. A grader that passed the surface through would agree
	# with an oracle doing the same, and every channel above would be zero against zero.
	var moved := 0
	for i in surf.size():
		if absf(fields[0][i] - surf[i]) > 0.01:
			moved += 1
	print("    control: %d cell(s) changed height (want many)" % moved)
	if moved < 100:
		_fail += 1
		print("    !! the grader did not cut anything, so [C] compared a pass-through with a pass-through")

	# CONTROL: no channel is constant, and no two are the same field. A mask that is identically zero
	# agrees with a port serving zeros — which is exactly the bug channels can have.
	var flat := PackedStringArray()
	for ch in 6:
		if _spread(fields[ch]) <= 1.0e-6:
			flat.append(names[ch])
	var same := PackedStringArray()
	for i in 6:
		for j in range(i + 1, 6):
			if _worst(fields[i], fields[j]) < 1.0e-6:
				same.append("%s==%s" % [names[i], names[j]])
	print("    control: %d constant channel(s) %s, %d identical pair(s) %s (want none of either)"
			% [flat.size(), str(flat), same.size(), str(same)])
	if not flat.is_empty() or not same.is_empty():
		_fail += 1
		print("    !! a constant or duplicated channel proves nothing about the port that produced it")


# ---- D -------------------------------------------------------------------------------------------

## [D] §8's second wiring — the whole point of the road system in a graph — lowers end to end.
##
##   Input → Road Grade ─ height ──────────────→ Blend(MIX).b
##                      └ roadbed ─────────────→ Blend.mask
##              Erosion ───────────────────────→ Blend.a
##
## so the carriageway keeps its cut and everything off it is the weathered hillside. It needs three
## things that did not exist together before: a geometry operand, a secondary channel (`roadbed` is
## port 1), and GRAPH_BLEND_MIX. Any one of them missing drops the whole graph, so this criterion is the
## one that says P2c is finished.
##
## MIX also carries the §6.1 rule. The native BLEND op answers an unknown mode with `a` — plausible,
## silent, wrong — so a MIX that lowered before the opcode existed would have returned the erosion
## everywhere and looked like a road that had not been cut.
func _d_the_flagship_wiring_lowers_end_to_end() -> void:
	print("[D] the §8 road-and-erosion wiring lowers end to end")
	var surf := _terrain()
	var g := Pasture3DTerrainGraph.new()
	var ero := Pasture3DGraphNodeErosion.new()
	# LIVE, because a FROZEN solver owns a cache the native program knows nothing about and blocks the
	# native path on purpose. Stated here rather than discovered as a refusal.
	ero.evaluation = Pasture3DGraphNodeErosion.Evaluation.LIVE
	ero.iterations = 20
	var blend := Pasture3DGraphNodeBlend.new()
	blend.mode = Pasture3DGraphNodeBlend.Mode.MIX
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), _source(_road()), Pasture3DGraphNodeRoadGrade.new(),
		ero, blend, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [
		[0, 0, 2, 0], # Input → Grade.surface
		[1, 0, 2, 1], # Source → Grade.path
		[0, 0, 3, 0], # Input → Erosion
		[3, 0, 4, 0], # Erosion → Blend.a
		[2, 0, 4, 1], # Grade.height → Blend.b
		[2, 1, 4, 2], # Grade.roadbed → Blend.mask
		[4, 0, 5, 0]]
	var supported := _lowers(g)
	var nat := _native(g, surf)
	var orc := _oracle(g, surf)
	var worst := _worst(nat, orc)
	print("    lowers=%s, native vs the GDScript evaluator: worst %.7f" % [str(supported), worst])
	_check("D", supported and worst < EPS, "lowers %s, worst %.7f" % [str(supported), worst])

	# CONTROL: the result is neither of its two inputs. A MIX served by the op's `default: val = a` gives
	# the erosion everywhere; a mask read as all-ones gives the graded surface everywhere. Both are
	# plausible terrains, and the parity check alone cannot tell them apart from the right answer — only
	# from an oracle making a different mistake.
	var g_ero := Pasture3DTerrainGraph.new()
	var ero2 := Pasture3DGraphNodeErosion.new()
	ero2.evaluation = Pasture3DGraphNodeErosion.Evaluation.LIVE
	ero2.iterations = 20
	var nodes_e: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), ero2, Pasture3DGraphNodeOutput.new()]
	g_ero.nodes = nodes_e
	g_ero.connections = [[0, 0, 1, 0], [1, 0, 2, 0]]
	var eroded := _native(g_ero, surf)

	var g_road := Pasture3DTerrainGraph.new()
	var nodes_r: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), _source(_road()), Pasture3DGraphNodeRoadGrade.new(),
		Pasture3DGraphNodeOutput.new()]
	g_road.nodes = nodes_r
	g_road.connections = [[0, 0, 2, 0], [1, 0, 2, 1], [2, 0, 3, 0]]
	var graded := _native(g_road, surf)

	var like_ero := 0
	var like_road := 0
	for i in nat.size():
		if absf(nat[i] - eroded[i]) < 0.001:
			like_ero += 1
		if absf(nat[i] - graded[i]) < 0.001:
			like_road += 1
	var n := nat.size()
	print("    control: %d/%d cells match the erosion alone, %d/%d match the road alone (want both partial)"
			% [like_ero, n, like_road, n])
	if like_ero == n or like_road == n or like_ero == 0 or like_road == 0:
		_fail += 1
		print("    !! the MIX collapsed to one of its inputs, so the mask is not choosing per cell")


# ---- E -------------------------------------------------------------------------------------------

## [E] One road read four times is ONE geometry-table entry.
##
## Fanout is the property that makes geometry ambient context rather than a flowing value: several slots
## name the same entry, so the road is indexed once for the whole bake instead of once per consumer. It
## is not visible in any output — a table with four copies of one road produces exactly the same terrain,
## slightly slower — so it has to be read off the compiled program directly or it is never checked at all.
func _e_one_road_read_four_times_is_one_table_entry() -> void:
	print("[E] a road read by several nodes is one table entry")
	var road := _road()
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), _source(road), Pasture3DGraphNodePathDistance.new(),
		Pasture3DGraphNodePathMask.new(), Pasture3DGraphNodeRoadGrade.new(),
		Pasture3DGraphNodeBlend.new(), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [
		[1, 0, 2, 0], # Source → Path Distance
		[1, 0, 3, 0], # Source → Path Mask
		[0, 0, 4, 0], [1, 0, 4, 1], # Input + Source → Road Grade
		# All three consumers must reach the OUTPUT, or dead-code elimination drops them from the slot
		# order and the table has fewer readers than the graph appears to have.
		[4, 0, 5, 0], [2, 0, 5, 1], [3, 0, 5, 2], # Grade.height, distance, mask → Blend
		[5, 0, 6, 0]]
	var prog := g.compile_graph_program()
	var geom: Array = prog.get("geom", [])
	var in_g: PackedInt32Array = prog.get("in_g", PackedInt32Array())
	var readers := 0
	for v in in_g:
		if v >= 0:
			readers += 1
	print("    %d table entr(y/ies) for %d reading slot(s) (want 1 and 3)" % [geom.size(), readers])
	_check("E", geom.size() == 1 and readers == 3,
			"%d entries, %d readers" % [geom.size(), readers])

	# CONTROL: the entry carries a PROFILE. Without it Road Grade passes the surface through — a legal,
	# silent answer — so an entry that lost the alignment on the way into the table would look like a
	# road that simply had not been baked.
	var has_profile := geom.size() > 0 and (geom[0] as Dictionary).has("profile")
	print("    control: the entry carries a grading profile: %s (want true)" % str(has_profile))
	if not has_profile:
		_fail += 1
		print("    !! the profile did not reach the table, so Road Grade would pass the surface through")

	# CONTROL: two DIFFERENT roads are two entries. Deduplication that collapsed them would hand one
	# road's geometry to the other node — and both would still produce a plausible terrain.
	var g2 := Pasture3DTerrainGraph.new()
	var nodes2: Array[Pasture3DGraphNode] = [
		_source(_road()), _source(_outline()), Pasture3DGraphNodePathDistance.new(),
		Pasture3DGraphNodePathMask.new(), Pasture3DGraphNodeBlend.new(),
		Pasture3DGraphNodeOutput.new()]
	g2.nodes = nodes2
	g2.connections = [[0, 0, 2, 0], [1, 0, 3, 0], [2, 0, 4, 0], [3, 0, 4, 1], [4, 0, 5, 0]]
	var geom2: Array = g2.compile_graph_program().get("geom", [])
	print("    control: two different roads make %d entr(y/ies) (want 2)" % geom2.size())
	if geom2.size() != 2:
		_fail += 1
		print("    !! two roads share one table entry, so one of them is reading the other's geometry")
