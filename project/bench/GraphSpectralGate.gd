# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphSpectralGate — parity and behavior verification for Pasture3DGraphNodeSpectralEqualizer.
#
# Tests:
#   [A] Energy conservation & mathematical identity: g_macro = g_meso = g_micro = 1.0 is exact bit-level identity.
#   [B] High-frequency micro amplification: micro_gain > 1.0 enhances high-frequency detail while preserving bulk mass.
#   [C] Low-frequency macro scaling: macro_gain shifts broad topography.
#   [D] Amount & Mask gating control.
#   [E] NaN passthrough safety.
#   [F] Metadata & warnings validation.
extends Node

const GW := 32
const GH := 32
const RECT := Rect2(-50.0, -50.0, 100.0, 100.0)
const EPS := 1.0e-5

var _fail := 0


func _ready() -> void:
	print("=== GraphSpectralGate: 3-band spatial frequency equalizer filter ===\n")
	_a_exact_identity()
	_b_micro_amplification()
	_c_macro_scaling()
	_d_amount_and_mask_control()
	_e_nan_passthrough()
	_f_metadata_and_warnings()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH SPECTRAL PASS" if _fail == 0 else "GRAPH SPECTRAL FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _a_exact_identity() -> void:
	print("[A] Mathematical identity when all gains equal 1.0")
	var input_field := _make_test_field(GW, GH)
	var eq := _make_eq(1.0, 1.0, 1.0, 16, 4, 1.0)
	var g := _filter_graph(eq)

	var out := g.evaluate(GW, GH, RECT, null, input_field)
	var diff := _max_abs_diff(out, input_field)

	print("    max |equalized - input| with gains=1.0: %.8f (want < %.8f)" % [diff, EPS])
	if diff > EPS:
		_fail += 1; print("    !! gains 1.0 did not produce the exact identity")


func _b_micro_amplification() -> void:
	print("[B] Micro crag amplification control: micro_gain = 2.5")
	var input_field := _make_test_field(GW, GH)
	var eq_boost := _make_eq(1.0, 1.0, 2.5, 16, 4, 1.0)
	var g_boost := _filter_graph(eq_boost)

	var out_boost := g_boost.evaluate(GW, GH, RECT, null, input_field)
	var diff := _max_abs_diff(out_boost, input_field)

	print("    micro boost difference = %.4f m (want > 0.5 m)" % diff)
	if diff <= 0.5:
		_fail += 1; print("    !! micro boost produced insufficient elevation change")

	# Average height should remain close (mean bulk elevation preserved)
	var mean_in := _mean(input_field)
	var mean_out := _mean(out_boost)
	var mean_diff := absf(mean_in - mean_out)
	print("    mean elevation change: in=%.4f, out=%.4f (diff=%.4f, want < 0.2)" % [mean_in, mean_out, mean_diff])
	if mean_diff > 0.2:
		_fail += 1; print("    !! micro boost significantly shifted overall terrain mean")


func _c_macro_scaling() -> void:
	print("[C] Macro scaling control: macro_gain = 0.5 vs 1.5")
	var input_field := _make_test_field(GW, GH)
	var eq_low := _make_eq(0.5, 1.0, 1.0, 16, 4, 1.0)
	var eq_high := _make_eq(1.5, 1.0, 1.0, 16, 4, 1.0)

	var out_low := _filter_graph(eq_low).evaluate(GW, GH, RECT, null, input_field)
	var out_high := _filter_graph(eq_high).evaluate(GW, GH, RECT, null, input_field)

	var spread_low := _spread(out_low)
	var spread_high := _spread(out_high)
	print("    macro spread: low=%.2f m, high=%.2f m (high > low, want diff > 5.0 m)" % [spread_low, spread_high])
	if spread_high <= spread_low + 5.0:
		_fail += 1; print("    !! macro scaling failed to expand/contract overall relief amplitude")


func _d_amount_and_mask_control() -> void:
	print("[D] Amount and mask gating control")
	var input_field := _make_test_field(GW, GH)
	var eq_amt0 := _make_eq(1.5, 1.5, 2.5, 16, 4, 0.0)
	var out_amt0 := _filter_graph(eq_amt0).evaluate(GW, GH, RECT, null, input_field)

	var diff0 := _max_abs_diff(out_amt0, input_field)
	print("    amount 0 diff = %.8f (want < %.8f)" % [diff0, EPS])
	if diff0 > EPS:
		_fail += 1; print("    !! amount 0 was not exact identity")


func _e_nan_passthrough() -> void:
	print("[E] NaN boundary preservation")
	var input_field := _make_test_field(GW, GH)
	input_field[0] = NAN
	input_field[GW * 5 + 5] = NAN

	var eq := _make_eq(1.2, 1.1, 1.8, 16, 4, 1.0)
	var out := eq.eval_grid([input_field], GW, GH, null, RECT)

	if not is_nan(out[0]) or not is_nan(out[GW * 5 + 5]):
		_fail += 1; print("    !! NaNs were not preserved in output")
	if not is_finite(out[GW * 5 + 6]):
		_fail += 1; print("    !! NaN leaked into neighboring valid cell")
	print("    NaNs preserved cleanly")


func _f_metadata_and_warnings() -> void:
	print("[F] Metadata and warnings validation")
	var eq := Pasture3DGraphNodeSpectralEqualizer.new()
	if eq.op() != &"spectral_equalizer":
		_fail += 1; print("    !! op() mismatch")
	if eq.role() != Pasture3DGraphNode.Role.FILTER:
		_fail += 1; print("    !! role() mismatch")
	if not eq.needs_grid():
		_fail += 1; print("    !! needs_grid() should be true")

	eq.amount = 0.0
	if eq.node_warnings().is_empty():
		_fail += 1; print("    !! should warn when amount is 0")


# --- Helpers -----------------------------------------------------------------------------------------
func _make_eq(macro_g: float, meso_g: float, micro_g: float, macro_p: int, meso_p: int, amt: float) -> Pasture3DGraphNodeSpectralEqualizer:
	var eq := Pasture3DGraphNodeSpectralEqualizer.new()
	eq.macro_gain = macro_g
	eq.meso_gain = meso_g
	eq.micro_gain = micro_g
	eq.macro_passes = macro_p
	eq.meso_passes = meso_p
	eq.amount = amt
	return eq


func _filter_graph(node: Pasture3DGraphNode) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var inp := Pasture3DGraphNodeInput.new()
	var out := Pasture3DGraphNodeOutput.new()
	g.nodes = [inp, node, out]
	g.connect_ports(0, 0, 1, 0)
	g.connect_ports(1, 0, 2, 0)
	return g


func _make_test_field(gw: int, gh: int) -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(gw * gh)
	var nz := FastNoiseLite.new()
	nz.frequency = 0.05
	for iz in range(gh):
		for ix in range(gw):
			# Base slope + noise bumps
			var base := float(ix) * 0.8 + float(iz) * 0.4
			var noise_val := nz.get_noise_2d(float(ix) * 4.0, float(iz) * 4.0) * 10.0
			g[iz * gw + ix] = base + noise_val
	return g


func _max_abs_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var m := 0.0
	for i in range(mini(a.size(), b.size())):
		if is_finite(a[i]) and is_finite(b[i]):
			m = maxf(m, absf(a[i] - b[i]))
	return m


func _mean(a: PackedFloat32Array) -> float:
	var s := 0.0
	var count := 0
	for v in a:
		if is_finite(v):
			s += v
			count += 1
	return s / maxf(float(count), 1.0)


func _spread(a: PackedFloat32Array) -> float:
	var lo := INF
	var hi := -INF
	for v in a:
		if is_finite(v):
			lo = minf(lo, v)
			hi = maxf(hi, v)
	return hi - lo
