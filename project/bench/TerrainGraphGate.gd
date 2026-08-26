# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# TerrainGraphGate — the headless parity gate for Pasture3DTerrainGraph, increment 1.
#
# The claim under test: the graph evaluator produces exactly what an independent, hand-written
# computation of the same node semantics produces — a generator (Noise), a combiner (Blend), a grid node
# (Smooth), and the DAG plumbing (topological order, cycle handling, unwired-input-reads-0).
#
# House discipline (see bench/PlowReliefCheck.gd, bench/BrushStackGate.gd): every criterion measures a
# FIELD DELTA, not a configuration flag, and every criterion carries a CONTROL that must move if the path
# is dead — so a field of zeros reports "measured nothing" rather than passing.
extends Node

const GW := 48
const GH := 32
const RECT := Rect2(-40.0, 25.0, 120.0, 80.0) # deliberately off-origin and non-square

const EPS := 1.0e-6   # evaluator-vs-oracle must match this tight (same float ops, same order)
const LIVE := 0.05    # a control must move the field by at least this many metres to count as "alive"

var _fail := 0


func _ready() -> void:
	print("=== TerrainGraphGate: Pasture3DTerrainGraph evaluator parity (increment 1) ===\n")
	_a_noise_generator()
	_b_blend_combiner()
	_c_smooth_grid_node()
	_d_topology_and_cycle()
	_e_unwired_input_reads_zero()
	print("\n=== %s (%d failures) ===\n" % ["TERRAIN GRAPH PASS" if _fail == 0 else "TERRAIN GRAPH FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- A. A Noise generator reproduces FastNoiseLite sampled at the graph's own world coords ------------
func _a_noise_generator() -> void:
	print("[A] Noise generator == direct FastNoiseLite at cell_to_world")
	var noise := _make_noise(1337, 0.03)
	var amp := 12.0
	var g := _graph([_noise_node(noise, amp)], [], 0)
	var got := g.evaluate(GW, GH, RECT)
	var oracle := _direct_noise_grid(noise, amp, GW, GH, RECT)
	var d := _max_abs_diff(got, oracle)
	print("    max |graph - oracle| = %.8f m (want < %.8f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! the Noise node does not match direct sampling")

	# CONTROL: a different amplitude must produce a materially different field, or criterion A is
	# comparing two constant zeros and would 'pass' on a dead evaluator.
	var g2 := _graph([_noise_node(noise, amp * 2.0)], [], 0)
	var moved := _max_abs_diff(got, g2.evaluate(GW, GH, RECT))
	print("    control: doubling amplitude moves the field by %.3f m (want > %.2f)" % [moved, LIVE])
	if moved <= LIVE:
		_fail += 1; print("    !! control dead: amplitude changed nothing, so A proves nothing")


# --- B. Blend(ADD) of Noise + Const equals noise + const, per cell -----------------------------------
func _b_blend_combiner() -> void:
	print("[B] Blend combiner: ADD of Noise + Const")
	var noise := _make_noise(99, 0.05)
	var c := 3.5
	var add := _blend_node(Pasture3DGraphNodeBlend.Mode.ADD)
	# nodes: 0 = noise, 1 = const, 2 = blend(a=noise, b=const), output = blend
	var g := _graph([_noise_node(noise, 8.0), _const_node(c), add],
			[[0, 0, 2, 0], [1, 0, 2, 1]], 2)
	var got := g.evaluate(GW, GH, RECT)
	# Oracle computed in DOUBLE and rounded once, matching the fold (which keeps a folded chain's
	# intermediates in double rather than rounding each to float32 like a materialised grid would).
	var oracle := PackedFloat32Array()
	oracle.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			oracle[iz * GW + ix] = 8.0 * noise.get_noise_2d(w.x, w.y) + c
	var d := _max_abs_diff(got, oracle)
	print("    max |blend - (noise + c)| = %.8f m (want < %.8f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! ADD blend does not equal noise + const")

	# CONTROL: MUL must differ from ADD, or the mode is being ignored.
	var mul := _blend_node(Pasture3DGraphNodeBlend.Mode.MUL)
	var g2 := _graph([_noise_node(noise, 8.0), _const_node(c), mul],
			[[0, 0, 2, 0], [1, 0, 2, 1]], 2)
	var moved := _max_abs_diff(got, g2.evaluate(GW, GH, RECT))
	print("    control: MUL differs from ADD by %.3f m (want > %.2f)" % [moved, LIVE])
	if moved <= LIVE:
		_fail += 1; print("    !! control dead: blend mode is ignored")


# --- C. Smooth grid node == blur_nan of its input, and actually smooths ------------------------------
func _c_smooth_grid_node() -> void:
	print("[C] Smooth grid node == Pasture3DGraphOps.blur_nan(input)")
	var noise := _make_noise(7, 0.08) # higher frequency so smoothing bites
	var smooth := Pasture3DGraphNodeSmooth.new()
	smooth.passes = 3
	# nodes: 0 = noise, 1 = smooth(in = noise), output = smooth
	var g := _graph([_noise_node(noise, 10.0), smooth], [[0, 0, 1, 0]], 1)
	var got := g.evaluate(GW, GH, RECT)
	var raw := _direct_noise_grid(noise, 10.0, GW, GH, RECT)
	var oracle := Pasture3DGraphOps.blur_nan(raw.duplicate(), GW, GH, 3)
	var d := _max_abs_diff(got, oracle)
	print("    max |smooth - blur_nan| = %.8f m (want < %.8f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! the Smooth node does not match the shared blur")

	# CONTROL: the smoothed field must differ from the raw one, or nothing was smoothed.
	var moved := _max_abs_diff(got, raw)
	print("    control: smoothing moved the field by %.3f m (want > %.2f)" % [moved, LIVE])
	if moved <= LIVE:
		_fail += 1; print("    !! control dead: Smooth changed nothing")


# --- D. Topological order resolves a diamond; a cycle yields a flat field ----------------------------
func _d_topology_and_cycle() -> void:
	print("[D] Topology: a diamond evaluates; a cycle is caught")
	# Diamond: const c -> smooth s1, const c -> smooth s2 (0 passes = identity), blend(add) s1+s2 = 2c.
	var c := 4.0
	var s1 := Pasture3DGraphNodeSmooth.new(); s1.passes = 0
	var s2 := Pasture3DGraphNodeSmooth.new(); s2.passes = 0
	var add := _blend_node(Pasture3DGraphNodeBlend.Mode.ADD)
	# nodes: 0 = const, 1 = s1, 2 = s2, 3 = blend, output = blend
	var g := _graph([_const_node(c), s1, s2, add],
			[[0, 0, 1, 0], [0, 0, 2, 0], [1, 0, 3, 0], [2, 0, 3, 1]], 3)
	var out := g.evaluate(GW, GH, RECT)
	var ok := not g.has_cycle() and _field_all_equal(out, 2.0 * c, EPS)
	print("    diamond: no cycle=%s, output==2c everywhere=%s" % [not g.has_cycle(), _field_all_equal(out, 2.0 * c, EPS)])
	if not ok:
		_fail += 1; print("    !! the diamond did not evaluate to 2c through a correct topo order")

	# CONTROL: add a back-edge blend->const-consumer to make a cycle; it must be detected and flatten.
	# nodes: 0 = blend(a<-1,b<-2), 1 = smooth(in<-0), 2 = smooth(in<-1)  => 0->1->2->0 is a cycle.
	var cyc := _graph([_blend_node(Pasture3DGraphNodeBlend.Mode.ADD),
			Pasture3DGraphNodeSmooth.new(), Pasture3DGraphNodeSmooth.new()],
			[[0, 0, 1, 0], [1, 0, 2, 0], [2, 0, 0, 0]], 0)
	var flat := cyc.evaluate(GW, GH, RECT)
	print("    control: cycle detected=%s, output flat 0=%s" % [cyc.has_cycle(), _field_all_equal(flat, 0.0, EPS)])
	if not cyc.has_cycle() or not _field_all_equal(flat, 0.0, EPS):
		_fail += 1; print("    !! a cycle was not caught (would loop or read stale data)")


# --- E. An unwired input reads 0, and wiring it changes the result -----------------------------------
func _e_unwired_input_reads_zero() -> void:
	print("[E] Unwired input reads 0; wiring it changes the field")
	# Blend(add): port A <- const 5, port B unwired => 5 everywhere.
	var g := _graph([_const_node(5.0), _blend_node(Pasture3DGraphNodeBlend.Mode.ADD)],
			[[0, 0, 1, 0]], 1)
	var out := g.evaluate(GW, GH, RECT)
	var warned := false
	for s in g.graph_warnings():
		if s.contains("unconnected"):
			warned = true
	print("    A=5,B=unwired -> ==5 everywhere=%s, warning raised=%s" % [_field_all_equal(out, 5.0, EPS), warned])
	if not _field_all_equal(out, 5.0, EPS) or not warned:
		_fail += 1; print("    !! an unwired port did not read a clean 0 (or raised no warning)")

	# CONTROL: wire B to const 3 -> 8 everywhere. Proves the unwired port was really 0, not luck.
	var g2 := _graph([_const_node(5.0), _blend_node(Pasture3DGraphNodeBlend.Mode.ADD), _const_node(3.0)],
			[[0, 0, 1, 0], [2, 0, 1, 1]], 1)
	var out2 := g2.evaluate(GW, GH, RECT)
	print("    control: wiring B=3 -> ==8 everywhere=%s" % _field_all_equal(out2, 8.0, EPS))
	if not _field_all_equal(out2, 8.0, EPS):
		_fail += 1; print("    !! wiring the second input did not change the result as expected")


# ---- helpers ----------------------------------------------------------------------------------------

func _graph(p_nodes: Array, p_conns: Array, p_out: int) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var typed: Array[Pasture3DGraphNode] = []
	for n in p_nodes:
		typed.append(n)
	g.nodes = typed
	var conns: Array = []
	for c in p_conns:
		conns.append(PackedInt32Array(c))
	g.connections = conns
	g.output_node = p_out
	return g


func _noise_node(p_noise: FastNoiseLite, p_amp: float) -> Pasture3DGraphNodeNoise:
	var n := Pasture3DGraphNodeNoise.new()
	n.noise = p_noise
	n.amplitude = p_amp
	return n


func _const_node(p_v: float) -> Pasture3DGraphNodeConst:
	var n := Pasture3DGraphNodeConst.new()
	n.value = p_v
	return n


func _blend_node(p_mode) -> Pasture3DGraphNodeBlend:
	var n := Pasture3DGraphNodeBlend.new()
	n.mode = p_mode
	return n


func _make_noise(p_seed: int, p_freq: float) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = p_seed
	n.frequency = p_freq
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	return n


func _direct_noise_grid(p_noise: FastNoiseLite, p_amp: float, p_gw: int, p_gh: int, p_rect: Rect2) -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(p_gw * p_gh)
	for iz in range(p_gh):
		for ix in range(p_gw):
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, p_gw, p_gh, p_rect)
			g[iz * p_gw + ix] = p_amp * p_noise.get_noise_2d(w.x, w.y)
	return g


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m


func _field_all_equal(p_g: PackedFloat32Array, p_v: float, p_eps: float) -> bool:
	for x in p_g:
		if absf(x - p_v) > p_eps:
			return false
	return p_g.size() > 0
