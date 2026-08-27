# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphTalusGate — parity and behavior verification for Pasture3DGraphNodeTalusProjection.
#
# Tests:
#   [A] Steep cliff relaxation: slopes > 35° shed elevation to lower cells.
#   [B] Volume conservation: mass removed from cliff crest equals mass deposited on toe (total sum conserved).
#   [C] Amount & Mask control: amount = 0 is identity; mask gates relaxation locally.
#   [D] NaN safety: boundary NaNs remain NaN without corrupting interior cells.
#   [E] Metadata & warnings validation.
extends Node

const GW := 32
const GH := 32
const RECT := Rect2(-32.0, -32.0, 64.0, 64.0)
const EPS := 1.0e-4

var _fail := 0


func _ready() -> void:
	print("=== GraphTalusGate: angle-of-repose slope relaxation filter ===\n")
	_a_cliff_relaxation()
	_b_volume_conservation()
	_c_amount_and_mask_control()
	_d_nan_safety()
	_e_metadata_and_warnings()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH TALUS PASS" if _fail == 0 else "GRAPH TALUS FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _a_cliff_relaxation() -> void:
	print("[A] Steep cliff relaxation toward angle of repose")
	var cliff := _make_steep_step_grid(GW, GH, 40.0) # 40m cliff in center
	var t := _make_talus(30.0, 24, 0.6, 1.0)
	var g := _filter_graph(t)

	var relaxed := g.evaluate(GW, GH, RECT, null, cliff)

	# The crest should decrease, and the base should increase
	var crest_orig := cliff[15 * GW + 15]
	var crest_new := relaxed[15 * GW + 15]
	var base_orig := cliff[15 * GW + 17]
	var base_new := relaxed[15 * GW + 17]

	print("    cliff crest: %.2f m -> %.2f m (delta %.2f m, want < -1.0 m)" % [crest_orig, crest_new, crest_new - crest_orig])
	if crest_new >= crest_orig - 1.0:
		_fail += 1; print("    !! cliff crest was not eroded")

	print("    cliff base: %.2f m -> %.2f m (delta +%.2f m, want > +1.0 m)" % [base_orig, base_new, base_new - base_orig])
	if base_new <= base_orig + 1.0:
		_fail += 1; print("    !! cliff base did not receive deposited talus")


func _b_volume_conservation() -> void:
	print("[B] Elevation volume conservation across closed grid")
	var cliff := _make_steep_step_grid(GW, GH, 30.0)
	var t := _make_talus(35.0, 16, 0.5, 1.0)
	var g := _filter_graph(t)

	var relaxed := g.evaluate(GW, GH, RECT, null, cliff)

	var sum_orig := 0.0
	var sum_new := 0.0
	for i in range(GW * GH):
		sum_orig += cliff[i]
		sum_new += relaxed[i]

	var diff := absf(sum_orig - sum_new)
	print("    total elevation mass: orig = %.4f, new = %.4f (diff = %.6f, want < %.4f)" % [sum_orig, sum_new, diff, 0.05])
	if diff > 0.05:
		_fail += 1; print("    !! talus projection failed to conserve total elevation volume")


func _c_amount_and_mask_control() -> void:
	print("[C] Amount zero identity and mask gating control")
	var cliff := _make_steep_step_grid(GW, GH, 30.0)

	# Amount 0 is exact identity
	var t0 := _make_talus(35.0, 16, 0.5, 0.0)
	var g0 := _filter_graph(t0)
	var out0 := g0.evaluate(GW, GH, RECT, null, cliff)
	var diff0 := _max_abs_diff(out0, cliff)
	print("    amount 0 diff from input = %.7f (want < %.7f)" % [diff0, EPS])
	if diff0 > EPS:
		_fail += 1; print("    !! amount 0 was not an exact identity")

	# Mask test: half mask
	var mask := PackedFloat32Array()
	mask.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			mask[iz * GW + ix] = 1.0 if ix < GW / 2 else 0.0

	var t_masked := _make_talus(35.0, 16, 0.5, 1.0)
	var g_masked := Pasture3DTerrainGraph.new()
	var in_node := Pasture3DGraphNodeInput.new()
	var mask_const := Pasture3DGraphNodeConst.new()
	var out_node := Pasture3DGraphNodeOutput.new()
	g_masked.nodes = [in_node, t_masked, out_node]
	g_masked.connect_ports(0, 0, 1, 0)
	g_masked.connect_ports(1, 0, 2, 0)

	var out_masked := t_masked.eval_grid([cliff, mask], GW, GH, null, RECT)
	var diff_right := 0.0
	for iz in range(GH):
		for ix in range(GW / 2, GW):
			diff_right = maxf(diff_right, absf(out_masked[iz * GW + ix] - cliff[iz * GW + ix]))
	print("    unmasked side difference = %.7f (want < %.7f)" % [diff_right, EPS])
	if diff_right > EPS:
		_fail += 1; print("    !! mask 0 did not protect the unmasked terrain")


func _d_nan_safety() -> void:
	print("[D] NaN boundary preservation")
	var cliff := _make_steep_step_grid(GW, GH, 30.0)
	cliff[0] = NAN
	cliff[1] = NAN
	cliff[GW] = NAN

	var t := _make_talus(35.0, 8, 0.5, 1.0)
	var out := t.eval_grid([cliff], GW, GH, null, RECT)

	if not is_nan(out[0]) or not is_nan(out[1]) or not is_nan(out[GW]):
		_fail += 1; print("    !! input NaNs were not preserved in output")
	if not is_finite(out[GW + 2]):
		_fail += 1; print("    !! NaN leaked into neighboring valid cell")
	print("    NaNs preserved correctly without poisoning neighbors")


func _e_metadata_and_warnings() -> void:
	print("[E] Metadata and configuration warnings")
	var t := Pasture3DGraphNodeTalusProjection.new()
	if t.op() != &"talus_projection":
		_fail += 1; print("    !! op() mismatch")
	if t.role() != Pasture3DGraphNode.Role.FILTER:
		_fail += 1; print("    !! role() mismatch")
	if not t.needs_grid():
		_fail += 1; print("    !! needs_grid() should be true")
	if t.input_count() != 2:
		_fail += 1; print("    !! input_count() != 2")

	t.amount = 0.0
	if t.node_warnings().is_empty():
		_fail += 1; print("    !! node_warnings() should warn on amount = 0")


# --- Helpers -----------------------------------------------------------------------------------------
func _make_talus(ang: float, iters: int, rate: float, amt: float) -> Pasture3DGraphNodeTalusProjection:
	var t := Pasture3DGraphNodeTalusProjection.new()
	t.talus_angle_deg = ang
	t.iterations = iters
	t.transfer_rate = rate
	t.amount = amt
	return t


func _filter_graph(node: Pasture3DGraphNode) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var inp := Pasture3DGraphNodeInput.new()
	var out := Pasture3DGraphNodeOutput.new()
	g.nodes = [inp, node, out]
	g.connect_ports(0, 0, 1, 0)
	g.connect_ports(1, 0, 2, 0)
	return g


func _make_steep_step_grid(gw: int, gh: int, step_height: float) -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(gw * gh)
	for iz in range(gh):
		for ix in range(gw):
			g[iz * gw + ix] = step_height if ix < gw / 2 else 0.0
	return g


func _max_abs_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var m := 0.0
	for i in range(mini(a.size(), b.size())):
		if is_finite(a[i]) and is_finite(b[i]):
			m = maxf(m, absf(a[i] - b[i]))
	return m
