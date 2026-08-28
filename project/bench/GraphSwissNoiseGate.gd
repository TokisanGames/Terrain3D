# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphSwissNoiseGate — parity and behavior verification for Pasture3DGraphNodeNoiseSwiss.
#
# Tests:
#   [A] Swiss Noise produces continuous ridge-and-valley alpine formations.
#   [B] Ridge offset control: higher offset broadens ridges and raises base elevations.
#   [C] Erosion accent control: erosion_accent modulates valley floors and derivative accumulation.
#   [D] Amplitude scaling: field scales linearly with amplitude; amplitude 0 -> flat 0.
#   [E] Fold parity: folded evaluate() matches unfolded reference evaluation.
#   [F] Metadata & warnings validation.
extends Node

const GW := 48
const GH := 48
const RECT := Rect2(-100.0, -100.0, 200.0, 200.0)
const EPS := 1.0e-4

var _fail := 0


func _ready() -> void:
	print("=== GraphSwissNoiseGate: Swiss Alps ridge fractal noise generator ===\n")
	_a_determinism_and_variance()
	_b_ridge_offset_control()
	_c_erosion_accent_control()
	_d_amplitude_scaling()
	_e_fold_parity()
	_f_metadata_and_warnings()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH SWISS NOISE PASS" if _fail == 0 else "GRAPH SWISS NOISE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _a_determinism_and_variance() -> void:
	print("[A] Swiss Noise determinism and spatial variance")
	var s1 := _make_swiss(100.0, 0.005, 6, 0.5, 2.0, 1.0, 0.15, 42)
	var g1 := _gen_graph(s1)
	var out1 := g1.evaluate(GW, GH, RECT)

	var s2 := _make_swiss(100.0, 0.005, 6, 0.5, 2.0, 1.0, 0.15, 42)
	var g2 := _gen_graph(s2)
	var out2 := g2.evaluate(GW, GH, RECT)

	var diff := _max_abs_diff(out1, out2)
	print("    reproducibility across evaluations: diff = %.7f (want < %.7f)" % [diff, EPS])
	if diff > EPS:
		_fail += 1; print("    !! Swiss noise is non-deterministic for identical parameters")

	var spread := _spread(out1)
	print("    spatial elevation spread = %.2f m (want > 20.0 m)" % spread)
	if spread < 20.0:
		_fail += 1; print("    !! field has insufficient spatial variation")


func _b_ridge_offset_control() -> void:
	print("[B] Ridge offset control: ridge_offset = 0.7 vs ridge_offset = 1.3")
	var s_thin := _make_swiss(100.0, 0.005, 6, 0.5, 2.0, 0.7, 0.15, 77)
	var s_broad := _make_swiss(100.0, 0.005, 6, 0.5, 2.0, 1.3, 0.15, 77)

	var out_thin := _gen_graph(s_thin).evaluate(GW, GH, RECT)
	var out_broad := _gen_graph(s_broad).evaluate(GW, GH, RECT)

	var diff := _max_abs_diff(out_thin, out_broad)
	print("    max diff between thin and broad ridge offset = %.3f m (want > 10.0 m)" % diff)
	if diff <= 10.0:
		_fail += 1; print("    !! ridge_offset had insufficient effect on terrain mass")


func _c_erosion_accent_control() -> void:
	print("[C] Erosion accent control: erosion_accent = 0.0 vs erosion_accent = 0.4")
	var s_no_ero := _make_swiss(100.0, 0.005, 6, 0.5, 2.0, 1.0, 0.0, 88)
	var s_ero := _make_swiss(100.0, 0.005, 6, 0.5, 2.0, 1.0, 0.4, 88)

	var out_no_ero := _gen_graph(s_no_ero).evaluate(GW, GH, RECT)
	var out_ero := _gen_graph(s_ero).evaluate(GW, GH, RECT)

	var diff := _max_abs_diff(out_no_ero, out_ero)
	print("    max diff between raw and erosion-accentuated = %.3f m (want > 5.0 m)" % diff)
	if diff <= 5.0:
		_fail += 1; print("    !! erosion_accent had insufficient effect on slope modulation")


func _d_amplitude_scaling() -> void:
	print("[D] Amplitude scaling linearity and zero control")
	var s0 := _make_swiss(0.0, 0.005, 6, 0.5, 2.0, 1.0, 0.15, 11)
	var out0 := _gen_graph(s0).evaluate(GW, GH, RECT)
	var max_flat := _absmax(out0)
	print("    amplitude 0 -> flat field (absmax = %.7f, want < %.7f)" % [max_flat, EPS])
	if max_flat > EPS:
		_fail += 1; print("    !! amplitude 0 did not produce a flat field")

	var s50 := _make_swiss(50.0, 0.005, 6, 0.5, 2.0, 1.0, 0.15, 11)
	var s100 := _make_swiss(100.0, 0.005, 6, 0.5, 2.0, 1.0, 0.15, 11)
	var out50 := _gen_graph(s50).evaluate(GW, GH, RECT)
	var out100 := _gen_graph(s100).evaluate(GW, GH, RECT)

	var scale_err := 0.0
	for i in range(out50.size()):
		scale_err = maxf(scale_err, absf(out100[i] - 2.0 * out50[i]))
	print("    2x amplitude scaling linearity error = %.7f (want < %.7f)" % [scale_err, EPS])
	if scale_err > EPS:
		_fail += 1; print("    !! amplitude scaling is non-linear")


func _e_fold_parity() -> void:
	print("[E] Fold parity: folded evaluate() == unfolded _eval_unfolded()")
	var s := _make_swiss(80.0, 0.004, 5, 0.5, 2.0, 1.1, 0.2, 444)
	var g := _gen_graph(s)

	var folded := g.evaluate(GW, GH, RECT)
	var unfolded := g._eval_unfolded(GW, GH, RECT)

	var diff := _max_abs_diff(folded, unfolded)
	print("    max |folded - unfolded| = %.7f (want < %.7f)" % [diff, EPS])
	if diff > EPS:
		_fail += 1; print("    !! folded evaluation diverged from unfolded oracle")


func _f_metadata_and_warnings() -> void:
	print("[F] Metadata, ports, and configuration warnings")
	var s := Pasture3DGraphNodeNoiseSwiss.new()
	if s.op() != &"noise_swiss":
		_fail += 1; print("    !! op() mismatch: got %s, want &\"noise_swiss\"" % s.op())
	if s.role() != Pasture3DGraphNode.Role.GENERATOR:
		_fail += 1; print("    !! role() mismatch: got %d, want Role.GENERATOR" % s.role())
	if s.input_count() != 0:
		_fail += 1; print("    !! input_count() != 0")
	if s.needs_grid():
		_fail += 1; print("    !! needs_grid() should be false for cell node")

	s.amplitude = 0.0
	var w0 := s.node_warnings()
	if w0.is_empty():
		_fail += 1; print("    !! node_warnings() should warn when amplitude is 0")


# --- Helpers -----------------------------------------------------------------------------------------
func _make_swiss(amp: float, freq: float, octs: int, gain: float, lac: float, roff: float, eacc: float, s: int) -> Pasture3DGraphNodeNoiseSwiss:
	var sw := Pasture3DGraphNodeNoiseSwiss.new()
	sw.amplitude = amp
	sw.frequency = freq
	sw.octaves = octs
	sw.gain = gain
	sw.lacunarity = lac
	sw.ridge_offset = roff
	sw.erosion_accent = eacc
	sw.seed = s
	return sw


func _gen_graph(node: Pasture3DGraphNode) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var out := Pasture3DGraphNodeOutput.new()
	g.nodes = [node, out]
	g.connect_ports(0, 0, 1, 0)
	return g


func _max_abs_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var m := 0.0
	for i in range(mini(a.size(), b.size())):
		m = maxf(m, absf(a[i] - b[i]))
	return m


func _absmax(a: PackedFloat32Array) -> float:
	var m := 0.0
	for v in a:
		m = maxf(m, absf(v))
	return m


func _spread(a: PackedFloat32Array) -> float:
	if a.is_empty():
		return 0.0
	var lo := INF
	var hi := -INF
	for v in a:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return hi - lo
