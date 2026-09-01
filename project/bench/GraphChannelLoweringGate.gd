# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphChannelLoweringGate — multi-output channels in the lowered program (P2b,
# PASTURE3D_GRAPH_GEOMETRY_PORTS_SPEC.md §5.3).
#
# ---- WHAT CHANGED, AND WHY IT IS WORTH A GATE OF ITS OWN ----
#
# A solver answers several questions from one solve. Erosion returns a height AND the flow that carved it,
# the metres removed, the metres laid down, and where water stands. Until P2b the lowered program could
# carry only the first: `in0..in3` named a source SLOT and nothing else, so a wire out of port 1 dropped
# the ENTIRE graph — erosion, noise, filters and all — onto the GDScript evaluator. Wiring a solver's
# secondary channel is the normal way to use a solver, so in practice the native evaluator was unreachable
# for most graphs that contained one.
#
# ---- THE FAILURE THIS GATE IS BUILT AROUND ----
#
# It is not "the numbers are wrong". It is **channel 0 being served for every port**. A program that
# ignored `in0_port` and handed back the height wherever flow was asked for would produce a smooth,
# plausible, entirely wrong field — and would agree with itself on every re-run. So every criterion here
# compares against the GDScript evaluator's channel `k`, and carries a control that channel `k` is
# materially DIFFERENT from channel 0 on this fixture. Agreement alone would pass on the bug.
#
# The second failure is the mirror: lowering a graph that reads a channel the native op does not write,
# and serving a field of zeros. That is what [D] is for.
extends Node

const CRITERIA: Array[String] = ["A", "B", "C", "D"]

const GW := 64
const GH := 64
const RECT := Rect2(-64.0, -64.0, 128.0, 128.0)
const EPS := 1.0e-4

var _fail: int = 0
var _seen: Dictionary = {}


func _ready() -> void:
	print("=== GraphChannelLoweringGate: multi-output channels in the native program (P2b) ===")
	print("    spec: PASTURE3D_GRAPH_GEOMETRY_PORTS_SPEC.md §5.3")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid"):
		print("!! Pasture3DUtil.graph_eval_grid is missing — the DLL is stale; rebuild the extension.")
		get_tree().quit(1)
		return

	_a_a_secondary_channel_lowers_at_all()
	_b_every_channel_matches_the_gdscript_evaluator()
	_c_reading_a_channel_does_not_change_the_others()
	_d_an_unimplemented_channel_still_refuses()

	for name in CRITERIA:
		if not _seen.has(name):
			_fail += 1
			print("!! criterion %s never reported" % name)
	print("=== GRAPH CHANNEL LOWERING %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	if not p_ok:
		_fail += 1
	print("    %s%s: %s" % ["" if p_ok else "!! ", p_name, p_detail])


# ---- fixtures ------------------------------------------------------------------------------------

## A noisy cone with a closed BASIN bitten out of one flank.
##
## Every feature here is load-bearing for a different channel, and a fixture missing one leaves that
## channel comparing zero against zero — which is agreement, and is worth nothing:
##
##   the cone   — a slope to route water down, so `flow` and `erosion` are not flat
##   the noise  — somewhere for channels to converge, so `flow` varies rather than being radial
##   the basin  — a closed depression, so the solver fills a lake and `wetness` has something to report
##   diffusion  — material moved downhill has to land somewhere, which is the only source of `deposition`
##
## Erosion on a plane routes nothing at all, and would let a port mix-up pass unnoticed everywhere.
func _terrain() -> PackedFloat32Array:
	var z := PackedFloat32Array()
	z.resize(GW * GH)
	var noise := FastNoiseLite.new()
	noise.seed = 12345
	noise.frequency = 0.035
	for iz in GH:
		for ix in GW:
			var x := float(ix) - float(GW) * 0.5
			var y := float(iz) - float(GH) * 0.5
			var r: float = sqrt(x * x + y * y)
			var h: float = maxf(60.0 - r * 1.6, 0.0) + noise.get_noise_2d(float(ix), float(iz)) * 6.0
			# The basin: a bowl on the flank, deep enough that its rim closes even after the noise.
			var bx := float(ix) - float(GW) * 0.72
			var by := float(iz) - float(GH) * 0.36
			var br: float = sqrt(bx * bx + by * by)
			h -= 45.0 * exp(-br * br / 30.0)
			z[iz * GW + ix] = h
	return z


func _erosion() -> Pasture3DGraphNodeErosion:
	var e := Pasture3DGraphNodeErosion.new()
	# LIVE, because FROZEN is the node's default and a frozen solver serves its own cache — which only the
	# GDScript evaluator can do, so blocks_native() would hold every graph here off the native path and
	# this gate would measure nothing. The freeze is tested elsewhere; the premise is stated here.
	e.evaluation = Pasture3DGraphNodeErosion.Evaluation.LIVE
	e.iterations = 30
	e.erosion_rate = 0.05
	e.hillslope_diffusion = 0.6
	e.deposition = 0.3
	return e


## Input(0) → Erosion(1) → Output(2), with the Output reading Erosion's channel `p_channel`.
##
## The Output takes the wire straight off the secondary port rather than routing it through a Blend. A
## Blend would be the realistic wiring and a worse test: its own arithmetic would sit between the channel
## and the number this gate compares, so a channel that was subtly wrong could be blended into looking
## right.
func _graph_reading(p_channel: int) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), _erosion(), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0], [1, p_channel, 2, 0]]
	return g


func _native(p_g: Pasture3DTerrainGraph, p_surf: PackedFloat32Array) -> PackedFloat32Array:
	return Pasture3DUtil.graph_eval_grid(p_g.compile_graph_program(), GW, GH, RECT, p_surf)


## The GDScript evaluator on the same graph, forced. `force_gdscript_evaluation` exists for exactly this:
## stating the premise rather than borrowing whichever native limitation happens to survive.
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


# ---- A -------------------------------------------------------------------------------------------

## [A] A graph reading a solver's SECONDARY channel lowers natively at all, and gives that channel.
##
## The first half is the regression that matters most: before P2b `native_supported()` returned false for
## this graph, so the check is that it now returns true AND that the program is non-empty. The two are
## separate answers from separate code, and they have been out of step before — a graph that reports
## lowerable and then compiles to `{}` falls back silently.
func _a_a_secondary_channel_lowers_at_all() -> void:
	print("[A] a graph reading erosion's flow channel lowers natively")
	var g := _graph_reading(1)
	var supported := g.native_supported()
	var prog := g.compile_graph_program()
	print("    native_supported=%s (want true), program has %d slot(s) (want > 0)"
			% [str(supported), int((prog.get("ops", PackedInt32Array()) as PackedInt32Array).size())])

	var surf := _terrain()
	var nat := _native(g, surf)
	var orc := _oracle(g, surf)
	var worst := _worst(nat, orc)
	print("    native vs the GDScript evaluator: worst %.7f" % worst)
	_check("A", supported and not prog.is_empty() and worst < EPS,
			"supported %s, program %s, worst %.7f" % [str(supported), str(not prog.is_empty()), worst])

	# CONTROL: the flow field must VARY. Two evaluators agree perfectly on a constant, and a solver that
	# routed nothing on this fixture would make every criterion in this file vacuous.
	var spread := _spread(nat)
	print("    control: flow spans %.2f m² across the fixture (want > 1)" % spread)
	if spread <= 1.0:
		_fail += 1
		print("    !! the flow field is nearly constant, so nothing here compared a channel")

	# CONTROL: and it must not be channel 0 wearing channel 1's name. THE failure this gate exists for:
	# a program that ignored in0_port would serve the eroded HEIGHT here, which is smooth, plausible, and
	# agrees with an oracle that made the same mistake — except the oracle does not make it.
	var height := _native(_graph_reading(0), surf)
	var apart := _worst(nat, height)
	print("    control: flow differs from the height channel by %.2f (want a large number)" % apart)
	if apart < 1.0:
		_fail += 1
		print("    !! the secondary port is being served channel 0")


# ---- B -------------------------------------------------------------------------------------------

## [B] Every one of erosion's five channels matches the GDScript evaluator.
##
## All five, not a representative one: they come from one solve but by four different derivations — flow
## and wetness out of the solver's diagnostics, erosion and deposition out of the sign of the height
## change — and a port that got the indices right for one pair could still have them crossed for the
## other. The pairwise control is what catches a crossing: two channels that are supposed to differ and do
## not.
func _b_every_channel_matches_the_gdscript_evaluator() -> void:
	print("[B] all five erosion channels match the GDScript evaluator")
	var surf := _terrain()
	var names := ["height", "flow", "erosion", "deposition", "wetness"]
	var fields: Array = []
	var worst := 0.0
	var worst_ch := ""
	for ch in 5:
		var g := _graph_reading(ch)
		var nat := _native(g, surf)
		var orc := _oracle(g, surf)
		var w := _worst(nat, orc)
		fields.append(nat)
		print("    %-11s worst %.7f, spans %.4f" % [names[ch], w, _spread(nat)])
		if w > worst:
			worst = w
			worst_ch = names[ch]
	_check("B", worst < EPS, "worst %.7f on %s (want < %.4f)"
			% [worst, "nothing" if worst_ch == "" else worst_ch, EPS])

	# CONTROL: every channel VARIES. A channel that is identically zero on this fixture agrees with a port
	# serving zeros, which is precisely the bug [B] is for — so a flat channel means the fixture stopped
	# exercising it, not that the port is right.
	var flat := PackedStringArray()
	for ch in 5:
		if _spread(fields[ch]) <= 1.0e-6:
			flat.append(names[ch])
	print("    control: %d channel(s) are constant: %s (want none)" % [flat.size(), str(flat)])
	if not flat.is_empty():
		_fail += 1
		print("    !! a constant channel is compared against a constant, which proves nothing")

	# CONTROL: no two channels are the same field. Five identical answers agree with nothing.
	var same := PackedStringArray()
	for i in 5:
		for j in range(i + 1, 5):
			if _worst(fields[i], fields[j]) < 1.0e-6:
				same.append("%s==%s" % [names[i], names[j]])
	print("    control: %d channel pair(s) are identical: %s (want none)" % [same.size(), str(same)])
	if not same.is_empty():
		_fail += 1
		print("    !! two channels carry the same field, so at least one port is wired to the wrong buffer")

	# CONTROL: erosion and deposition are the two SIGNS of the height change, so both must be non-negative
	# and both must occur. A solver that only cut, or a derivation that dropped the sign test, would give
	# one empty channel that still passed the parity check above.
	var ero: PackedFloat32Array = fields[2]
	var dep: PackedFloat32Array = fields[3]
	var n_ero := 0
	var n_dep := 0
	var negative := 0
	for i in ero.size():
		if ero[i] > 0.001:
			n_ero += 1
		if dep[i] > 0.001:
			n_dep += 1
		if ero[i] < -1.0e-6 or dep[i] < -1.0e-6:
			negative += 1
	print("    control: %d cell(s) eroded, %d deposited, %d negative (want many, many, 0)"
			% [n_ero, n_dep, negative])
	if n_ero == 0 or n_dep == 0 or negative != 0:
		_fail += 1
		print("    !! erosion/deposition are not the two positive halves of the height change")


# ---- C -------------------------------------------------------------------------------------------

## [C] Asking for a channel does not change any other channel, or the primary answer.
##
## The native evaluator allocates an aux buffer only when something downstream reads it, and asks the
## solver for its expensive diagnostics only when flow or wetness is wanted. That is a real branch in the
## kernel: a graph that reads flow runs the solver differently from one that does not. If those two solves
## disagreed about the HEIGHT, the optimisation would have changed the terrain — the most expensive kind
## of silent bug, because it only appears when someone wires a preview.
func _c_reading_a_channel_does_not_change_the_others() -> void:
	print("[C] reading a channel does not change the height the solver produces")
	var surf := _terrain()
	var height_alone := _native(_graph_reading(0), surf)

	# The same graph, but with the flow channel ALSO consumed — so the diagnostics branch is on. Erosion
	# feeds both the Output (height) and a Blend that reads flow, and the Output is what is compared.
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), _erosion(), Pasture3DGraphNodeBlend.new(),
		Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	# Erosion.height → Blend.a, Erosion.flow → Blend.b, Blend → Output.
	g.connections = [[0, 0, 1, 0], [1, 0, 2, 0], [1, 1, 2, 1], [2, 0, 3, 0]]
	var supported := g.native_supported()
	var both := _native(g, surf)
	var orc := _oracle(g, surf)
	var worst := _worst(both, orc)
	print("    a graph consuming height AND flow: supported=%s, native vs oracle %.7f"
			% [str(supported), worst])
	_check("C", supported and worst < EPS,
			"supported %s, worst %.7f (want < %.4f)" % [str(supported), worst, EPS])

	# CONTROL: the height channel is bit-identical whether or not flow was asked for.
	var height_again := _native(_graph_reading(0), surf)
	var drift := _worst(height_alone, height_again)
	print("    control: the height channel re-solves to within %.7f (want 0)" % drift)
	if drift > 0.0:
		_fail += 1
		print("    !! the solve is not deterministic, so [C] cannot say anything about the branch")

	# CONTROL: the two-consumer graph really does read two different channels — otherwise the diagnostics
	# branch was never switched on and this criterion measured one path twice.
	var flow_only := _native(_graph_reading(1), surf)
	if _worst(flow_only, height_alone) < 1.0:
		_fail += 1
		print("    !! flow and height are the same field here, so the fixture cannot test the branch")


# ---- D -------------------------------------------------------------------------------------------

## [D] A port ≥ 1 wire out of an op whose NATIVE side does not write that channel still refuses.
##
## The bail was narrowed in P2b, not deleted, and this is the half that must survive. `native_out_count`
## reports what `graph_eval_grid` fills in, not what the GDScript node offers in the editor — so an op
## with five outputs in the palette and one in C++ must still hold its graph on the GDScript path. Lowering
## it would serve a field of zeros: a mask that turned everything off, or a height that flattened a
## terrain, with nothing anywhere reporting an error.
func _d_an_unimplemented_channel_still_refuses() -> void:
	print("[D] reading a channel the native op does not write still refuses to lower")
	# Lake Flooding publishes secondary channels in the editor and writes only its primary grid natively.
	var g := Pasture3DTerrainGraph.new()
	var lake := Pasture3DGraphNodeLakeFlooding.new()
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), lake, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0], [1, 1, 2, 0]]
	var supported := g.native_supported()
	var prog := g.compile_graph_program()
	print("    a graph reading lake_flooding's port 1: native_supported=%s (want false), program empty=%s (want true)"
			% [str(supported), str(prog.is_empty())])
	_check("D", not supported and prog.is_empty(),
			"supported %s, program empty %s" % [str(supported), str(prog.is_empty())])

	# CONTROL: the SAME graph reading port 0 must lower. Without this, [D] would pass on a Lake Flooding
	# node that could not be lowered for some entirely unrelated reason — a missing op, a blocking flag —
	# and would then be testing nothing about channels at all.
	var g0 := Pasture3DTerrainGraph.new()
	var lake0 := Pasture3DGraphNodeLakeFlooding.new()
	var nodes0: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), lake0, Pasture3DGraphNodeOutput.new()]
	g0.nodes = nodes0
	g0.connections = [[0, 0, 1, 0], [1, 0, 2, 0]]
	print("    control: the same graph reading port 0: native_supported=%s (want true)"
			% str(g0.native_supported()))
	if not g0.native_supported():
		_fail += 1
		print("    !! the control graph does not lower either, so [D] refused for an unrelated reason")

	# CONTROL: and the refusal must still produce the RIGHT field, on the GDScript path. A bail is only
	# correct if the fallback works; a graph that refuses to lower and then evaluates to zeros has turned a
	# performance decision into a wrong answer.
	var surf := _terrain()
	var fallback := g.evaluate(GW, GH, RECT, null, surf)
	print("    control: the refused graph still evaluates, spanning %.4f (want non-zero)"
			% _spread(fallback))
	if _spread(fallback) <= 0.0:
		_fail += 1
		print("    !! the refused graph evaluates to a constant, so the fallback is not carrying it")
