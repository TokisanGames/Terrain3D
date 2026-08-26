# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphFreezeGate — the FROZEN cache for Pasture3DNodeGraph (terrain-graph increment 4). Drives the REAL
# host freeze path — Pasture3DTerrainBrush._run_modifier_stack + _commit_modifier_caches on a
# Pasture3DMound — the same two calls a bake makes, so the cache is exercised end to end without a terrain.
#
# The claim: a frozen graph evaluates once per extent, SERVES the cached raw output afterwards (reporting
# stale when the graph has changed since, rather than re-solving mid-edit), re-evaluates on an explicit
# Bake, and misses per new extent. LIVE always re-evaluates. House control discipline throughout.
extends Node

const GW := 16
const GH := 16
const VS := 1.0
const EPS := 1.0e-4
const LIVE := 0.05

var _fail := 0
var _brush: Pasture3DMound


func _ready() -> void:
	print("=== GraphFreezeGate: Pasture3DNodeGraph frozen cache (increment 4) ===\n")
	_brush = Pasture3DMound.new()
	add_child(_brush)
	_run_all()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH FREEZE PASS" if _fail == 0 else "GRAPH FREEZE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _run_all() -> void:
	var noise := _make_noise()
	var g := _single_noise_graph(noise, 10.0)
	var m := Pasture3DNodeGraph.new()
	m.graph = g
	m.strength = 1.0                                  # amount (0..1); defaults to FROZEN in _init

	# Bake 1: a cold FROZEN cache MISSES, evaluates, and stores.
	var v1 := _bake(m, "E1", -5.0, 3.0)
	print("[setup] cold bake produced a field: alive=%s" % (not _all_zero(v1)))
	if _all_zero(v1):
		_fail += 1; print("    !! the first bake produced nothing"); return

	# Mutate the graph so a fresh evaluation would TRIPLE (amplitude 10 -> 30).
	noise.frequency = noise.frequency # no-op touch guard
	g.nodes[0].set("amplitude", 30.0)

	# [A] FROZEN serves the OLD cached output (not the tripled one) and reports stale.
	print("[A] frozen serves the cached output and flags stale")
	var v2 := _bake(m, "E1", -5.0, 3.0)
	var served := _max_abs_diff(v2, v1)
	print("    max |served - cached| = %.6f (want < %.6f), stale=%s" % [served, EPS, m._stale])
	if served > EPS or not m._stale:
		_fail += 1; print("    !! a frozen graph did not serve its cache (or did not report stale)")

	# CONTROL: a LIVE node re-evaluates and reflects the 3x change.
	m.evaluation = Pasture3DNode.Evaluation.LIVE
	var v3 := _bake(m, "E1", -5.0, 3.0)
	var live_tripled := _max_abs_diff(v3, _scaled(v1, 3.0))
	var live_moved := _max_abs_diff(v3, v1)
	print("    control: LIVE == 3x cold=%s, differs from cache=%s" % [live_tripled < EPS, live_moved > LIVE])
	if live_tripled > EPS or live_moved <= LIVE:
		_fail += 1; print("    !! LIVE did not re-evaluate to the changed graph")

	# [B] Bake (clear_cache) re-evaluates the frozen node.
	print("[B] Bake re-evaluates the frozen cache")
	m.evaluation = Pasture3DNode.Evaluation.FROZEN
	m.clear_cache()
	var v4 := _bake(m, "E1", -5.0, 3.0)
	var baked_tripled := _max_abs_diff(v4, _scaled(v1, 3.0))
	print("    max |rebaked - 3x cold| = %.6f (want < %.6f), stale cleared=%s" % [baked_tripled, EPS, not m._stale])
	if baked_tripled > EPS or m._stale:
		_fail += 1; print("    !! Bake did not re-evaluate (or left the stale flag set)")

	# [C] A new extent MISSES and evaluates fresh for its own world origin.
	print("[C] a new extent misses and evaluates for its own coords")
	var v5 := _bake(m, "E2", 40.0, -20.0)
	# A generator over a zero surface with amount 1 and a flat profile composites to the raw graph output.
	var ref5 := _raw(g, 40.0, -20.0)
	var d5 := _max_abs_diff(v5, ref5)
	print("    max |E2 bake - fresh E2 eval| = %.6f (want < %.6f)" % [d5, EPS])
	if d5 > EPS:
		_fail += 1; print("    !! a new extent served a stale grid instead of evaluating fresh")
	# CONTROL: E2 differs from E1 (different world origin), so C is not trivially comparing equal fields.
	print("    control: E2 differs from E1 bake by %.3f (want > %.2f)" % [_max_abs_diff(v5, v4), LIVE])
	if _max_abs_diff(v5, v4) <= LIVE:
		_fail += 1; print("    !! control dead: the two extents produced the same field")


# ---- helpers ----------------------------------------------------------------------------------------

## One bake through the real host path: fresh out slot, run the stack, commit the caches. Returns vals.
func _bake(p_m: Pasture3DNodeGraph, p_extent: String, p_x0: float, p_z0: float) -> PackedFloat32Array:
	var n := GW * GH
	var step := {"mod": p_m, "op": &"graph", "grid": true, "out": {}}
	var amp := PackedFloat64Array(); amp.resize(n)
	var basey := PackedFloat32Array(); basey.resize(n)
	var profile := PackedFloat64Array(); profile.resize(n); profile.fill(1.0)
	var ctx := {"gw": GW, "gh": GH, "vs": VS, "min_x": p_x0, "min_z": p_z0, "add": true, "extent": p_extent}
	var vals: PackedFloat32Array = _brush._run_modifier_stack([step], amp, profile, basey, ctx)
	_brush._commit_modifier_caches({"gd": [step]}, p_extent)
	return vals


func _raw(p_g: Pasture3DTerrainGraph, p_x0: float, p_z0: float) -> PackedFloat32Array:
	var rect := Rect2(p_x0 - 0.5 * VS, p_z0 - 0.5 * VS, float(GW) * VS, float(GH) * VS)
	return p_g.evaluate(GW, GH, rect)


func _single_noise_graph(p_noise: FastNoiseLite, p_amp: float) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var node := Pasture3DGraphNodeNoise.new()
	node.noise = p_noise
	node.amplitude = p_amp
	var typed: Array[Pasture3DGraphNode] = [node]
	g.nodes = typed
	g.output_node = 0
	return g


func _make_noise() -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = 42
	n.frequency = 0.07
	return n


func _scaled(p_a: PackedFloat32Array, p_s: float) -> PackedFloat32Array:
	var o := p_a.duplicate()
	for i in range(o.size()):
		o[i] = p_a[i] * p_s
	return o


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var mx := 0.0
	for i in range(p_a.size()):
		mx = maxf(mx, absf(p_a[i] - p_b[i]))
	return mx


func _all_zero(p_g: PackedFloat32Array) -> bool:
	for x in p_g:
		if absf(x) > EPS:
			return false
	return p_g.size() > 0
