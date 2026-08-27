# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphJordanNoiseGate — parity and behavior verification for Pasture3DGraphNodeNoiseJordan.
#
# Tests:
#   [A] Jordan Noise produces varied, non-trivial deterministic terrain for a fixed seed.
#   [B] Derivative warp effect: warp_strength > 0 alters coordinate trajectories vs warp_strength = 0.
#   [C] Slope damping effect: damp_strength > 0 attenuates high-frequency amplitude on steep slopes.
#   [D] Amplitude scaling: field scales linearly with amplitude; amplitude 0 -> flat 0.
#   [E] Fold parity: folded evaluate() matches unfolded reference evaluation.
#   [F] Metadata & warnings validation.
extends Node

const GW := 48
const GH := 48
const RECT := Rect2(-100.0, -100.0, 200.0, 200.0)
const EPS := 1.0e-5

var _fail := 0


func _ready() -> void:
	print("=== GraphJordanNoiseGate: derivative-feedback fBm noise generator ===\n")
	_a_determinism_and_variance()
	_b_gradient_warp_effect()
	_c_slope_damping_effect()
	_d_amplitude_scaling()
	_e_fold_parity()
	_f_metadata_and_warnings()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH JORDAN NOISE PASS" if _fail == 0 else "GRAPH JORDAN NOISE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _a_determinism_and_variance() -> void:
	print("[A] Jordan Noise determinism and spatial variance")
	var j1 := _make_jordan(100.0, 0.005, 6, 0.5, 2.0, 0.35, 0.8, 42)
	var g1 := _gen_graph(j1)
	var out1 := g1.evaluate(GW, GH, RECT)

	var j2 := _make_jordan(100.0, 0.005, 6, 0.5, 2.0, 0.35, 0.8, 42)
	var g2 := _gen_graph(j2)
	var out2 := g2.evaluate(GW, GH, RECT)

	var diff := _max_abs_diff(out1, out2)
	print("    reproducibility across evaluations: diff = %.7f (want < %.7f)" % [diff, EPS])
	if diff > EPS:
		_fail += 1; print("    !! Jordan noise is non-deterministic for identical parameters")

	var spread := _spread(out1)
	print("    spatial elevation spread = %.2f m (want > 20.0 m)" % spread)
	if spread < 20.0:
		_fail += 1; print("    !! field has insufficient spatial variation")


func _b_gradient_warp_effect() -> void:
	print("[B] Gradient warp control: warp_strength > 0 vs warp_strength = 0")
	var j_unwarped := _make_jordan(100.0, 0.005, 6, 0.5, 2.0, 0.0, 0.8, 123)
	var j_warped := _make_jordan(100.0, 0.005, 6, 0.5, 2.0, 0.5, 0.8, 123)

	var out_unwarped := _gen_graph(j_unwarped).evaluate(GW, GH, RECT)
	var out_warped := _gen_graph(j_warped).evaluate(GW, GH, RECT)

	var diff := _max_abs_diff(out_unwarped, out_warped)
	print("    max diff between unwarped and warped = %.3f m (want > 5.0 m)" % diff)
	if diff <= 5.0:
		_fail += 1; print("    !! warp_strength had no significant effect on octave coordinates")


func _c_slope_damping_effect() -> void:
	print("[C] Slope damping control: damp_strength > 0 vs damp_strength = 0")
	var j_undamped := _make_jordan(100.0, 0.005, 6, 0.5, 2.0, 0.35, 0.0, 99)
	var j_damped := _make_jordan(100.0, 0.005, 6, 0.5, 2.0, 0.35, 1.2, 99)

	var out_undamped := _gen_graph(j_undamped).evaluate(GW, GH, RECT)
	var out_damped := _gen_graph(j_damped).evaluate(GW, GH, RECT)

	var diff := _max_abs_diff(out_undamped, out_damped)
	print("    max diff between undamped and damped = %.3f m (want > 5.0 m)" % diff)
	if diff <= 5.0:
		_fail += 1; print("    !! damp_strength had no significant effect on slope attenuation")


func _d_amplitude_scaling() -> void:
	print("[D] Amplitude scaling linearity and zero control")
	var j0 := _make_jordan(0.0, 0.005, 6, 0.5, 2.0, 0.35, 0.8, 7)
	var out0 := _gen_graph(j0).evaluate(GW, GH, RECT)
	var max_flat := _absmax(out0)
	print("    amplitude 0 -> flat field (absmax = %.7f, want < %.7f)" % [max_flat, EPS])
	if max_flat > EPS:
		_fail += 1; print("    !! amplitude 0 did not produce a flat field")

	var j50 := _make_jordan(50.0, 0.005, 6, 0.5, 2.0, 0.35, 0.8, 7)
	var j100 := _make_jordan(100.0, 0.005, 6, 0.5, 2.0, 0.35, 0.8, 7)
	var out50 := _gen_graph(j50).evaluate(GW, GH, RECT)
	var out100 := _gen_graph(j100).evaluate(GW, GH, RECT)

	var scale_err := 0.0
	for i in range(out50.size()):
		scale_err = maxf(scale_err, absf(out100[i] - 2.0 * out50[i]))
	print("    2x amplitude scaling linearity error = %.7f (want < %.7f)" % [scale_err, EPS])
	if scale_err > EPS:
		_fail += 1; print("    !! amplitude scaling is non-linear")


func _e_fold_parity() -> void:
	print("[E] Fold parity: folded evaluate() == unfolded _eval_unfolded()")
	var j := _make_jordan(80.0, 0.004, 5, 0.5, 2.0, 0.3, 0.7, 555)
	var g := _gen_graph(j)

	var folded := g.evaluate(GW, GH, RECT)
	var unfolded := g._eval_unfolded(GW, GH, RECT)

	var diff := _max_abs_diff(folded, unfolded)
	print("    max |folded - unfolded| = %.7f (want < %.7f)" % [diff, EPS])
	if diff > EPS:
		_fail += 1; print("    !! folded evaluation diverged from unfolded oracle")


func _f_metadata_and_warnings() -> void:
	print("[F] Metadata, ports, and configuration warnings")
	var j := Pasture3DGraphNodeNoiseJordan.new()
	if j.op() != &"noise_jordan":
		_fail += 1; print("    !! op() mismatch: got %s, want &\"noise_jordan\"" % j.op())
	if j.role() != Pasture3DGraphNode.Role.GENERATOR:
		_fail += 1; print("    !! role() mismatch: got %d, want Role.GENERATOR" % j.role())
	if j.input_count() != 0:
		_fail += 1; print("    !! input_count() != 0")
	if j.needs_grid():
		_fail += 1; print("    !! needs_grid() should be false for cell node")

	j.amplitude = 0.0
	var w0 := j.node_warnings()
	if w0.is_empty():
		_fail += 1; print("    !! node_warnings() should warn when amplitude is 0")


# --- Helpers -----------------------------------------------------------------------------------------
func _make_jordan(amp: float, freq: float, octs: int, gain: float, lac: float, warp: float, damp: float, s: int) -> Pasture3DGraphNodeNoiseJordan:
	var j := Pasture3DGraphNodeNoiseJordan.new()
	j.amplitude = amp
	j.frequency = freq
	j.octaves = octs
	j.gain = gain
	j.lacunarity = lac
	j.warp_strength = warp
	j.damp_strength = damp
	j.seed = s
	return j


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
