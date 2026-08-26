# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphFoldGate — the cell-node fold in Pasture3DTerrainGraph.evaluate (terrain-graph increment 5).
#
# The claim: folding a run of cell nodes into one loop (materialising only grid nodes, the output,
# fan-out points, and grid-node inputs) produces the same field as the pre-fold per-node evaluator
# (`_eval_unfolded`) and the same as an independent double-precision math oracle — while actually folding
# (fewer materialised grids). House discipline: measure a field/count and carry a control that must move.
extends Node

const GW := 32
const GH := 24
const RECT := Rect2(-20.0, 12.0, 90.0, 70.0)
const EPS := 1.0e-4    # folded output stored to float32
const EQV := 1.0e-3    # folded vs unfolded: same maths, different intermediate rounding

var _fail := 0


func _ready() -> void:
	print("=== GraphFoldGate: Pasture3DTerrainGraph cell-node fold (increment 5) ===\n")
	_a_chain_matches_math()
	_b_folded_equals_unfolded()
	_c_fold_actually_happens()
	_d_fanout_materialises()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH FOLD PASS" if _fail == 0 else "GRAPH FOLD FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- A. A folded cell chain matches an independent double-precision oracle ----------------------------
func _a_chain_matches_math() -> void:
	print("[A] folded chain == double-precision math oracle")
	var noise := _make_noise(5, 0.05)
	# 0 noise(A) -> 2 blend ADD (b=1 const c1) -> 4 blend MUL (b=3 const c2); output 4.
	var a := 6.0
	var c1 := 4.0
	var c2 := 0.5
	var g := _chain(noise, a, c1, c2)
	var got := g.evaluate(GW, GH, RECT)
	var oracle := PackedFloat32Array()
	oracle.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			oracle[iz * GW + ix] = (a * noise.get_noise_2d(w.x, w.y) + c1) * c2
	var d := _max_abs_diff(got, oracle)
	print("    max |folded - (A*noise + c1) * c2| = %.7f (want < %.1e)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! the folded chain does not compute the expected maths")
	# CONTROL: a different c2 moves the field (so A is not comparing two flat zeros).
	var moved := _max_abs_diff(got, _chain(noise, a, c1, c2 * 3.0).evaluate(GW, GH, RECT))
	print("    control: changing c2 moves the field by %.3f (want > 0.05)" % moved)
	if moved <= 0.05:
		_fail += 1; print("    !! control dead")


# --- B. Folded == unfolded across a chain, a diamond, and a grid barrier ------------------------------
func _b_folded_equals_unfolded() -> void:
	print("[B] folded == _eval_unfolded (to float32 rounding)")
	var noise := _make_noise(9, 0.06)
	var shapes := {
		"chain": _chain(noise, 5.0, 2.0, 1.5),
		"diamond": _diamond(noise, 7.0),
		"grid-barrier": _grid_barrier(noise, 8.0, 3.0),
	}
	for name in shapes:
		var g: Pasture3DTerrainGraph = shapes[name]
		var d := _max_abs_diff(g.evaluate(GW, GH, RECT), g._eval_unfolded(GW, GH, RECT))
		print("    %-13s max |folded - unfolded| = %.7f (want < %.1e)" % [name, d, EQV])
		if d > EQV:
			_fail += 1; print("    !! folded diverged from the unfolded reference on '%s'" % name)


# --- C. Folding actually happens: a cell chain materialises fewer grids than nodes --------------------
func _c_fold_actually_happens() -> void:
	print("[C] a cell chain folds (fewer materialised grids than nodes)")
	var g := _chain(_make_noise(1, 0.05), 5.0, 2.0, 1.5)
	var mat := _count_materialised(g)
	var total: int = g._fold_plan()["order"].size()
	print("    chain: %d materialised of %d nodes (want fewer)" % [mat, total])
	if not (mat < total):
		_fail += 1; print("    !! nothing folded — every node materialised")
	# CONTROL: a chain of GRID nodes cannot fold; every node materialises.
	var gg := _grid_chain(_make_noise(2, 0.05))
	var gmat := _count_materialised(gg)
	var gtotal: int = gg._fold_plan()["order"].size()
	print("    control: grid chain %d materialised of %d (want equal)" % [gmat, gtotal])
	if gmat != gtotal:
		_fail += 1; print("    !! a grid node was wrongly folded")


# --- D. A fan-out node materialises (so it is computed once, not per consumer) ------------------------
func _d_fanout_materialises() -> void:
	print("[D] a fan-out node materialises")
	var diamond := _diamond(_make_noise(3, 0.05), 7.0) # noise feeds BOTH blend inputs -> fanout 2
	var mat: Dictionary = diamond._fold_plan()["materialize"]
	print("    diamond: shared noise materialised = %s" % mat[0])
	if not mat[0]:
		_fail += 1; print("    !! a fan-out node was folded (would be recomputed per consumer)")
	# CONTROL: the same noise feeding ONE consumer folds.
	var single := _chain(_make_noise(3, 0.05), 7.0, 0.0, 1.0)
	var smat: Dictionary = single._fold_plan()["materialize"]
	print("    control: single-consumer noise materialised = %s (want false)" % smat[0])
	if smat[0]:
		_fail += 1; print("    !! a single-consumer cell node was needlessly materialised")


# ---- graph builders ---------------------------------------------------------------------------------

## 0 noise(A) -> 2 blend ADD (b = 1 const c1) -> 4 blend MUL (b = 3 const c2); output 4.
func _chain(p_noise: FastNoiseLite, p_a: float, p_c1: float, p_c2: float) -> Pasture3DTerrainGraph:
	var nodes: Array[Pasture3DGraphNode] = [
		_noise(p_noise, p_a), _const(p_c1), _blend(Pasture3DGraphNodeBlend.Mode.ADD),
		_const(p_c2), _blend(Pasture3DGraphNodeBlend.Mode.MUL)]
	return _graph(nodes, [[0, 0, 2, 0], [1, 0, 2, 1], [2, 0, 4, 0], [3, 0, 4, 1]], 4)


## 0 noise -> 1 blend ADD with BOTH ports from node 0 (fan-out 2); output 1 => 2*noise.
func _diamond(p_noise: FastNoiseLite, p_a: float) -> Pasture3DTerrainGraph:
	var nodes: Array[Pasture3DGraphNode] = [_noise(p_noise, p_a), _blend(Pasture3DGraphNodeBlend.Mode.ADD)]
	return _graph(nodes, [[0, 0, 1, 0], [0, 0, 1, 1]], 1)


## 0 noise(A) -> 2 blend ADD (b = 1 const) -> 3 smooth; output 3. The blend feeds a GRID node.
func _grid_barrier(p_noise: FastNoiseLite, p_a: float, p_c: float) -> Pasture3DTerrainGraph:
	var sm := Pasture3DGraphNodeSmooth.new(); sm.passes = 2
	var nodes: Array[Pasture3DGraphNode] = [
		_noise(p_noise, p_a), _const(p_c), _blend(Pasture3DGraphNodeBlend.Mode.ADD), sm]
	return _graph(nodes, [[0, 0, 2, 0], [1, 0, 2, 1], [2, 0, 3, 0]], 3)


## 0 noise -> 1 smooth -> 2 smooth; output 2. All grid nodes downstream — nothing can fold.
func _grid_chain(p_noise: FastNoiseLite) -> Pasture3DTerrainGraph:
	var s1 := Pasture3DGraphNodeSmooth.new(); s1.passes = 1
	var s2 := Pasture3DGraphNodeSmooth.new(); s2.passes = 1
	var nodes: Array[Pasture3DGraphNode] = [_noise(p_noise, 5.0), s1, s2]
	return _graph(nodes, [[0, 0, 1, 0], [1, 0, 2, 0]], 2)


func _graph(p_nodes: Array[Pasture3DGraphNode], p_conns: Array, p_out: int) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	g.nodes = p_nodes
	var conns: Array = []
	for c in p_conns:
		conns.append(PackedInt32Array(c))
	g.connections = conns
	g.output_node = p_out
	return g


func _noise(p_noise: FastNoiseLite, p_a: float) -> Pasture3DGraphNodeNoise:
	var n := Pasture3DGraphNodeNoise.new(); n.noise = p_noise; n.amplitude = p_a
	return n


func _const(p_v: float) -> Pasture3DGraphNodeConst:
	var n := Pasture3DGraphNodeConst.new(); n.value = p_v
	return n


func _blend(p_mode) -> Pasture3DGraphNodeBlend:
	var n := Pasture3DGraphNodeBlend.new(); n.mode = p_mode
	return n


func _make_noise(p_seed: int, p_freq: float) -> FastNoiseLite:
	var n := FastNoiseLite.new(); n.seed = p_seed; n.frequency = p_freq
	return n


func _count_materialised(p_g: Pasture3DTerrainGraph) -> int:
	var mat: Dictionary = p_g._fold_plan()["materialize"]
	var c := 0
	for k in mat:
		if mat[k]:
			c += 1
	return c


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m
