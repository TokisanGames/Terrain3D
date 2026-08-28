# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphPreviewTapGate — the single-pass MULTI-TAP evaluator behind the graph editor's inline node previews.
#
# The claim: Pasture3DUtil.graph_eval_grid_taps (C++, src/pasture_3d_graph_ops.cpp) evaluates ONE compiled
# program (from Pasture3DTerrainGraph.compile_graph_program_multi) and returns EVERY requested node's buffer
# from that single pass — including intermediate nodes the scratch-arena would normally recycle. Each tapped
# buffer must equal what the proven single-root native path (graph_eval_grid, GraphNativeGraphGate) produces
# for that node alone. This is what lets N inline previews cost one low-res eval instead of N.
#
# House discipline (bench-gate practices): every criterion carries a control that must move, and each check
# can tell "measured nothing" (all-zero / same buffer) from "measured well". No timing here — correctness
# only, so this is safe to run without a perf ask.
extends Node

const GW := 48
const GH := 32
const RECT := Rect2(-30.0, -18.0, 90.0, 60.0)
const TIGHT := 1.0e-4 # a tapped buffer must match the single-root native eval to float32 rounding

var _fail := 0


func _ready() -> void:
	print("=== GraphPreviewTapGate: single-pass multi-tap node previews ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_taps"):
		print("!! Pasture3DUtil.graph_eval_grid_taps is missing — the DLL is stale; rebuild the extension.")
		_fail += 1
		print("\n=== GRAPH PREVIEW TAP FAIL (%d failures) ===\n" % _fail)
		get_tree().quit(1)
		return
	_a_taps_match_single_root()
	_b_one_pass_dedups_union()
	_c_hillshade_shape_and_mask()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH PREVIEW TAP PASS" if _fail == 0 else "GRAPH PREVIEW TAP FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- A. Every tapped buffer == the single-root native eval of that node (intermediates included) ---------
func _a_taps_match_single_root() -> void:
	print("[A] taps match single-root native eval — incl. recycled intermediates")
	var g := _pipeline()
	# Roots: Noise(1) and Blend(2) are INTERMEDIATE (each has exactly one consumer, so the scratch pool would
	# recycle them without tap-protection); Smooth(3) feeds Output. Tapping all three exercises protection.
	var roots: Array = [1, 2, 3]
	var compiled: Dictionary = g.compile_graph_program_multi(roots)
	if compiled.is_empty():
		_fail += 1; print("    !! compile_graph_program_multi returned {} for a fully-native graph")
		return
	var program: Dictionary = compiled["program"]
	var slot_of: Dictionary = compiled["slot_of"]
	var input := _ramp(4.0)
	var tap_slots := PackedInt32Array()
	var node_of_slot := {}
	for r in roots:
		if not slot_of.has(r):
			_fail += 1; print("    !! slot_of is missing root %d" % r)
			return
		tap_slots.append(int(slot_of[r]))
		node_of_slot[int(slot_of[r])] = r
	var taps: Dictionary = Pasture3DUtil.graph_eval_grid_taps(program, GW, GH, RECT, input, tap_slots)
	if taps.size() != roots.size():
		_fail += 1; print("    !! expected %d tapped fields, got %d" % [roots.size(), taps.size()])
		return
	var by_node := {}
	for slot in taps:
		by_node[int(node_of_slot[slot])] = taps[slot]
	for r in roots:
		var tapped: PackedFloat32Array = by_node.get(r, PackedFloat32Array())
		var oracle: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(g.compile_graph_program(r), GW, GH, RECT, input)
		var d := _maxdiff(tapped, oracle)
		var mag := _maxabs(tapped)
		print("    node %d: tap size=%d, vs single-root = %.7f (want < %.7f), |tap|max=%.3f (want > 0)"
			% [r, tapped.size(), d, TIGHT, mag])
		if tapped.size() != GW * GH:
			_fail += 1; print("    !! tap for node %d is the wrong size" % r)
		if d > TIGHT:
			_fail += 1; print("    !! tap for node %d diverged from its single-root eval (recycled buffer?)" % r)
		if mag <= 0.0:
			_fail += 1; print("    !! tap for node %d is all zero — measured nothing" % r)
	# CONTROL: distinct nodes tap DISTINCT buffers (not one buffer aliased to every tap).
	var spread := _maxdiff(by_node[1], by_node[3])
	print("    control: Noise tap vs Smooth tap differ by %.3f (want > 0.05)" % spread)
	if spread <= 0.05:
		_fail += 1; print("    !! taps are aliased — every preview would show the same buffer")


# --- B. One pass over the UNION ancestry — each node compiled once, not per root ------------------------
func _b_one_pass_dedups_union() -> void:
	print("[B] one program over the union ancestry (shared Input compiled once)")
	var g := _pipeline()
	# Ancestry of {Noise(1), Blend(2), Smooth(3)} is {Input(0), Noise(1), Blend(2), Smooth(3)} — Output(4)
	# is downstream of every root, so it is NOT included. Input is shared by Blend and Smooth: a single pass
	# must carry it ONCE (4 slots), where a naive per-root concatenation would duplicate it.
	var compiled: Dictionary = g.compile_graph_program_multi([1, 2, 3])
	if compiled.is_empty():
		_fail += 1; print("    !! multi compile returned {}")
		return
	var ops: PackedInt32Array = compiled["program"]["ops"]
	print("    program slot count = %d (want 4: Input, Noise, Blend, Smooth)" % ops.size())
	if ops.size() != 4:
		_fail += 1; print("    !! union ancestry was not deduped to one slot per node")
	# CONTROL: an empty root set does not lower.
	var empty := g.compile_graph_program_multi([])
	print("    control: empty root set -> program empty=%s (want true)" % empty.is_empty())
	if not empty.is_empty():
		_fail += 1; print("    !! an empty root set wrongly produced a program")


# --- C. Hillshade returns w*h*4 bytes, and the is_mask flag changes the render -------------------------
func _c_hillshade_shape_and_mask() -> void:
	print("[C] hillshade_image_grid shape and mask control")
	var ramp := _ramp(6.0)
	var rgba := Pasture3DUtil.hillshade_image_grid(ramp, GW, GH, false)
	print("    height hillshade bytes = %d (want %d)" % [rgba.size(), GW * GH * 4])
	if rgba.size() != GW * GH * 4:
		_fail += 1; print("    !! hillshade did not return a full RGBA image")
	# CONTROL 1: a flat field renders differently from a ramp (the shade actually reads the surface).
	var flat := PackedFloat32Array(); flat.resize(GW * GH); flat.fill(1.0)
	var flat_rgba := Pasture3DUtil.hillshade_image_grid(flat, GW, GH, false)
	print("    control: flat vs ramp hillshade differ = %s (want true)" % (flat_rgba != rgba))
	if flat_rgba == rgba:
		_fail += 1; print("    !! hillshade ignores the surface — flat and ramp render identically")
	# CONTROL 2: the is_mask flag changes the mapping for a normalized [0,1] field.
	var norm := PackedFloat32Array(); norm.resize(GW * GH)
	for i in range(norm.size()):
		norm[i] = float(i % GW) / float(GW)
	var as_height := Pasture3DUtil.hillshade_image_grid(norm, GW, GH, false)
	var as_mask := Pasture3DUtil.hillshade_image_grid(norm, GW, GH, true)
	print("    control: is_mask flag changes the render = %s (want true)" % (as_height != as_mask))
	if as_height == as_mask:
		_fail += 1; print("    !! is_mask flag is a no-op")


# ---- helpers ----------------------------------------------------------------------------------------

## 0 Input -> 2 Blend(ADD) <- 1 Noise ; 2 Blend -> 3 Smooth -> 4 Output.
func _pipeline() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var noise := FastNoiseLite.new(); noise.seed = 11; noise.frequency = 0.05
	var nz := Pasture3DGraphNodeNoise.new(); nz.noise = noise; nz.amplitude = 7.0
	var bl := Pasture3DGraphNodeBlend.new(); bl.mode = Pasture3DGraphNodeBlend.Mode.ADD
	var sm := Pasture3DGraphNodeSmooth.new(); sm.passes = 2
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), nz, bl, sm, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [
		PackedInt32Array([0, 0, 2, 0]), PackedInt32Array([1, 0, 2, 1]),
		PackedInt32Array([2, 0, 3, 0]), PackedInt32Array([3, 0, 4, 0])]
	g.output_node = 4
	return g


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


func _maxabs(p_a: PackedFloat32Array) -> float:
	var m := 0.0
	for i in range(p_a.size()):
		m = maxf(m, absf(p_a[i]))
	return m
