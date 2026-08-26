# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphNativeGraphGate — the native WHOLE-graph evaluator (terrain-graph grid-pass interleave, stage 1).
#
# The claim: Pasture3DUtil.graph_eval_grid (C++, src/pasture_3d_graph_ops.cpp), fed a program from
# Pasture3DTerrainGraph.compile_graph_program and an input surface, materialises every node — Input /
# Smooth / Output included — and produces the SAME field as the GDScript `_eval_unfolded` (the pre-fold
# reference, which `evaluate` matches to float32 rounding). So a graph carrying a GRID node runs end to end
# in C++, not just the cell runs. House discipline: measure a field/flag, carry a control that must move.
#
# Two oracles: `_eval_unfolded` (native mirrors it node-for-node — TIGHT) and `evaluate` (the folded live
# path — LOOSE, since the fold keeps intermediates in double). Both are asserted.
extends Node

const GW := 40
const GH := 28
const RECT := Rect2(-20.0, 12.0, 90.0, 70.0)
const TIGHT := 1.0e-4 # native vs _eval_unfolded: both materialise every node in float32
const LOOSE := 1.0e-2 # native vs evaluate: the fold keeps cell intermediates in double

var _fail := 0


func _ready() -> void:
	print("=== GraphNativeGraphGate: native whole-graph evaluator (grid-pass interleave) ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid"):
		print("!! Pasture3DUtil.graph_eval_grid is missing — the DLL is stale; rebuild the extension.")
		_fail += 1
		print("\n=== GRAPH NATIVE GRAPH FAIL (%d failures) ===\n" % _fail)
		get_tree().quit(1)
		return
	_a_identity()
	_b_smooth_filter()
	_c_add_over_surface()
	_d_generator_with_grid_barrier()
	_e_structure_and_scope()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH NATIVE GRAPH PASS" if _fail == 0 else "GRAPH NATIVE GRAPH FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- A. Input -> Output: native returns the surface (identity) ----------------------------------------
func _a_identity() -> void:
	print("[A] Input -> Output identity: native == surface == oracle")
	var g := _io([])
	var surf := _ramp(3.0)
	_check(g, surf, "identity")
	# CONTROL: a different surface changes the native output.
	var moved := _maxdiff(_native(g, surf), _native(g, _ramp(8.0)))
	print("    control: a different surface moves native by %.3f (want > 0.05)" % moved)
	if moved <= 0.05:
		_fail += 1; print("    !! control dead — Input is not read natively")


# --- B. Input -> Smooth -> Output: native == the NaN-aware blur -----------------------------------------
func _b_smooth_filter() -> void:
	print("[B] Input -> Smooth -> Output: native == blur_nan == oracle")
	var sm := Pasture3DGraphNodeSmooth.new(); sm.passes = 3
	var g := _io([sm])
	var surf := _ramp(5.0)
	_check(g, surf, "smooth")
	# CONTROL: native equals the independent NaN-aware blur, and it actually moved the surface.
	var nat := _native(g, surf)
	var blur := Pasture3DGraphOps.blur_nan(surf.duplicate(), GW, GH, 3)
	var dblur := _maxdiff(nat, blur)
	var changed := _maxdiff(nat, surf)
	print("    native vs blur_nan = %.7f (want < %.7f); moved surface by %.3f (want > 0.01)"
		% [dblur, TIGHT, changed])
	if dblur > TIGHT or changed <= 0.01:
		_fail += 1; print("    !! the native Smooth did not blur the surface")


# --- C. Input -> Blend(ADD) <- Noise -> Output: native adds noise to the surface -----------------------
func _c_add_over_surface() -> void:
	print("[C] Input -> Blend(ADD) <- Noise -> Output: native == oracle (adds noise over surface)")
	var noise := _make_noise(7, 0.05)
	# 0 Input, 1 Noise, 2 Blend(ADD)[a=Input,b=Noise], 3 Output.
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), _noise(noise, 6.0),
		_blend(Pasture3DGraphNodeBlend.Mode.ADD), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [_c4(0, 0, 2, 0), _c4(1, 0, 2, 1), _c4(2, 0, 3, 0)]
	var surf := _ramp(4.0)
	_check(g, surf, "add-noise")
	# CONTROL: the native result differs from the bare surface (the noise really landed).
	var d := _maxdiff(_native(g, surf), surf)
	print("    control: native differs from the bare surface by %.3f (want > 0.05)" % d)
	if d <= 0.05:
		_fail += 1; print("    !! control dead — the noise did not add over the surface")


# --- D. A generator with a grid barrier (no Input): Noise -> Smooth -> Output --------------------------
func _d_generator_with_grid_barrier() -> void:
	print("[D] Noise -> Smooth -> Output (no Input): native == oracle")
	var g := Pasture3DTerrainGraph.new()
	var sm := Pasture3DGraphNodeSmooth.new(); sm.passes = 2
	var nodes: Array[Pasture3DGraphNode] = [_noise(_make_noise(3, 0.06), 9.0), sm, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [_c4(0, 0, 1, 0), _c4(1, 0, 2, 0)]
	# A generator ignores the surface — pass one anyway to prove it does not leak in.
	_check(g, _ramp(5.0), "gen-barrier")
	var with_surf := _native(g, _ramp(5.0))
	var no_surf := _native(g, PackedFloat32Array())
	print("    control: generator ignores the surface (diff %.7f, want < %.7f)" % [_maxdiff(with_surf, no_surf), TIGHT])
	if _maxdiff(with_surf, no_surf) > TIGHT:
		_fail += 1; print("    !! a no-Input generator leaked the surface")


# --- E. compile_graph_program / native_supported scope ------------------------------------------------
func _e_structure_and_scope() -> void:
	print("[E] compile_graph_program and native_supported reflect the graph")
	var g := _io([Pasture3DGraphNodeSmooth.new()])
	print("    Input->Smooth->Output: native_supported=%s (want true), program empty=%s (want false)"
		% [g.native_supported(), g.compile_graph_program().is_empty()])
	if not g.native_supported() or g.compile_graph_program().is_empty():
		_fail += 1; print("    !! a fully supported graph did not lower")
	# CONTROL: a cycle refuses to lower and is not native-supported.
	var cyc := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [
		_blend(Pasture3DGraphNodeBlend.Mode.ADD), Pasture3DGraphNodeOutput.new()]
	cyc.nodes = nodes
	# Blend feeds Output, and Blend feeds itself -> a cycle in the ancestry.
	cyc.connections = [_c4(0, 0, 1, 0), _c4(0, 0, 0, 0)]
	print("    control: cyclic graph native_supported=%s (want false), program empty=%s (want true)"
		% [cyc.native_supported(), cyc.compile_graph_program().is_empty()])
	if cyc.native_supported() or not cyc.compile_graph_program().is_empty():
		_fail += 1; print("    !! a cyclic graph wrongly reported native / lowered")


# ---- helpers ----------------------------------------------------------------------------------------

## Assert native == _eval_unfolded (tight) and == evaluate (loose) for `p_g` over `p_surf`.
func _check(p_g: Pasture3DTerrainGraph, p_surf: PackedFloat32Array, p_name: String) -> void:
	var nat := _native(p_g, p_surf)
	var unf := p_g._eval_unfolded(GW, GH, RECT, null, p_surf)
	var fold := p_g.evaluate(GW, GH, RECT, null, p_surf)
	var du := _maxdiff(nat, unf)
	var df := _maxdiff(nat, fold)
	print("    %-12s native vs _eval_unfolded = %.7f (want < %.7f), vs evaluate = %.7f (want < %.7f)"
		% [p_name, du, TIGHT, df, LOOSE])
	if du > TIGHT:
		_fail += 1; print("    !! native diverged from the unfolded reference on '%s'" % p_name)
	if df > LOOSE:
		_fail += 1; print("    !! native diverged from the folded evaluate on '%s'" % p_name)


func _native(p_g: Pasture3DTerrainGraph, p_surf: PackedFloat32Array) -> PackedFloat32Array:
	return Pasture3DUtil.graph_eval_grid(p_g.compile_graph_program(), GW, GH, RECT, p_surf)


## Input(0) -> [mid nodes chained] -> Output(last).
func _io(p_mid: Array) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new()]
	for m in p_mid:
		nodes.append(m)
	nodes.append(Pasture3DGraphNodeOutput.new())
	g.nodes = nodes
	var conns: Array = []
	for i in range(nodes.size() - 1):
		conns.append(_c4(i, 0, i + 1, 0))
	g.connections = conns
	return g


func _c4(a: int, b: int, c: int, d: int) -> PackedInt32Array:
	return PackedInt32Array([a, b, c, d])


func _noise(p_noise: FastNoiseLite, p_a: float) -> Pasture3DGraphNodeNoise:
	var n := Pasture3DGraphNodeNoise.new(); n.noise = p_noise; n.amplitude = p_a
	return n


func _blend(p_mode) -> Pasture3DGraphNodeBlend:
	var n := Pasture3DGraphNodeBlend.new(); n.mode = p_mode
	return n


func _make_noise(p_seed: int, p_freq: float) -> FastNoiseLite:
	var n := FastNoiseLite.new(); n.seed = p_seed; n.frequency = p_freq
	return n


func _ramp(p_scale: float) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			s[iz * GW + ix] = p_scale * (float(ix) / GW + float(iz) / GH)
	return s


func _maxdiff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m
