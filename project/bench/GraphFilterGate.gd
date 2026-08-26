# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphFilterGate — the Input/Output paradigm in Pasture3DTerrainGraph.
#
# The claim: an Input node yields the surface handed to `evaluate`, an Output node is the graph's result
# (output_index), and a graph built as Input → … → Output is a FILTER — a bare Input→Output is the
# identity, Input→Smooth→Output equals the NaN-aware blur of the surface, and Input→Blend(ADD)←Const adds a
# constant. Plus the bookkeeping the host relies on: output_index resolves to the sink, and reads_input is
# true exactly when an Input feeds the output. House discipline: measure a field/flag, carry a control.
extends Node

const GW := 40
const GH := 28
const RECT := Rect2(-20.0, 12.0, 90.0, 70.0)
const EPS := 1.0e-5

var _fail := 0


func _ready() -> void:
	print("=== GraphFilterGate: Pasture3DTerrainGraph Input/Output paradigm ===\n")
	_a_input_yields_surface()
	_b_smooth_filters_surface()
	_c_add_constant()
	_d_output_index_and_reads_input()
	_e_no_surface_reads_zero()
	_f_default_graph()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH FILTER PASS" if _fail == 0 else "GRAPH FILTER FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- A. A bare Input -> Output returns the surface unchanged (identity) -------------------------------
func _a_input_yields_surface() -> void:
	print("[A] Input -> Output is the identity (returns the surface handed in)")
	var g := _io_graph([]) # Input(0) -> Output(1), no nodes between
	var surf := _ramp(3.0)
	var d := _max_abs_diff(g.evaluate(GW, GH, RECT, null, surf), surf)
	print("    max |evaluate(surface) - surface| = %.7f (want < %.7f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! Input did not pass the surface through Output unchanged")
	# CONTROL: a different surface comes back different — the graph is not returning a constant.
	var moved := _max_abs_diff(g.evaluate(GW, GH, RECT, null, surf), g.evaluate(GW, GH, RECT, null, _ramp(7.0)))
	print("    control: a different surface changes the output by %.3f (want > 0.05)" % moved)
	if moved <= 0.05:
		_fail += 1; print("    !! control dead — the Input is not actually read")


# --- B. Input -> Smooth -> Output equals the NaN-aware blur of the surface ----------------------------
func _b_smooth_filters_surface() -> void:
	print("[B] Input -> Smooth -> Output == blur_nan(surface)")
	var sm := Pasture3DGraphNodeSmooth.new(); sm.passes = 2
	var g := _io_graph([sm]) # Input(0) -> Smooth(1) -> Output(2)
	var surf := _ramp(5.0)
	var got := g.evaluate(GW, GH, RECT, null, surf)
	var want := Pasture3DGraphOps.blur_nan(surf.duplicate(), GW, GH, 2)
	var d := _max_abs_diff(got, want)
	print("    max |filtered - blur_nan| = %.7f (want < %.7f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! the Smooth filter did not blur the incoming surface")
	# CONTROL: the filter genuinely changed the surface (a ramp is not its own blur at the ends).
	var changed := _max_abs_diff(got, surf)
	print("    control: filtered vs raw surface differ by %.3f (want > 0.01)" % changed)
	if changed <= 0.01:
		_fail += 1; print("    !! control dead — Smooth passed the surface straight through")


# --- C. Input -> Blend(ADD) <- Const adds a constant to the surface -----------------------------------
func _c_add_constant() -> void:
	print("[C] Input -> Blend(ADD) <- Const(c) == surface + c")
	var c := 4.0
	# 0 Input, 1 Const(c), 2 Blend(ADD) [a=Input, b=Const], 3 Output <- Blend.
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), _const(c),
		_blend(Pasture3DGraphNodeBlend.Mode.ADD), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [_c4(0, 0, 2, 0), _c4(1, 0, 2, 1), _c4(2, 0, 3, 0)]
	var surf := _ramp(6.0)
	var got := g.evaluate(GW, GH, RECT, null, surf)
	var worst := 0.0
	for i in range(surf.size()):
		worst = maxf(worst, absf(got[i] - (surf[i] + c)))
	print("    max |filtered - (surface + %.1f)| = %.7f (want < %.7f)" % [c, worst, EPS])
	if worst > EPS:
		_fail += 1; print("    !! adding a Const to the Input did not shift the surface by the constant")
	# CONTROL: c = 0 is the identity.
	var g0 := Pasture3DTerrainGraph.new()
	var nodes0: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), _const(0.0),
		_blend(Pasture3DGraphNodeBlend.Mode.ADD), Pasture3DGraphNodeOutput.new()]
	g0.nodes = nodes0
	g0.connections = [_c4(0, 0, 2, 0), _c4(1, 0, 2, 1), _c4(2, 0, 3, 0)]
	var id := _max_abs_diff(g0.evaluate(GW, GH, RECT, null, surf), surf)
	print("    control: adding Const(0) leaves the surface unchanged (diff %.7f, want < %.7f)" % [id, EPS])
	if id > EPS:
		_fail += 1; print("    !! Blend(ADD) with 0 was not the identity")


# --- D. output_index resolves to the sink; reads_input reflects an Input in the ancestry --------------
func _d_output_index_and_reads_input() -> void:
	print("[D] output_index -> the Output sink; reads_input iff an Input feeds it")
	var g := _io_graph([]) # Input(0) -> Output(1)
	print("    Input->Output: output_index=%d (want 1), reads_input=%s (want true)"
		% [g.output_index(), g.reads_input()])
	if g.output_index() != 1 or not g.reads_input():
		_fail += 1; print("    !! the sink is not the output, or the Input was not detected")
	# CONTROL: a pure generator (Const -> Output) is the output but reads no input.
	var gen := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [_const(2.0), Pasture3DGraphNodeOutput.new()]
	gen.nodes = nodes
	gen.connections = [_c4(0, 0, 1, 0)]
	print("    control: Const->Output: output_index=%d (want 1), reads_input=%s (want false)"
		% [gen.output_index(), gen.reads_input()])
	if gen.output_index() != 1 or gen.reads_input():
		_fail += 1; print("    !! a generator wrongly reported reading the input, or lost its output")


# --- E. With no surface handed in, an Input reads a flat 0 --------------------------------------------
func _e_no_surface_reads_zero() -> void:
	print("[E] no surface passed -> Input reads a flat 0")
	var g := _io_graph([]) # Input -> Output
	var got := g.evaluate(GW, GH, RECT) # no p_input
	print("    max |evaluate(no surface)| = %.7f (want < %.7f)" % [_absmax(got), EPS])
	if _absmax(got) > EPS:
		_fail += 1; print("    !! Input invented values when handed no surface")
	# CONTROL: hand it a surface and it is non-zero.
	var nz := _absmax(g.evaluate(GW, GH, RECT, null, _ramp(5.0)))
	print("    control: with a surface the output is non-zero (%.3f, want > 0.05)" % nz)
	if nz <= 0.05:
		_fail += 1; print("    !! control dead")


# --- F. create_default() is a pre-wired Input -> Output identity graph --------------------------------
func _f_default_graph() -> void:
	print("[F] create_default() -> Input -> Output, connected, identity")
	var g := Pasture3DTerrainGraph.create_default()
	var shape_ok := g.nodes.size() == 2 and g.nodes[0].op() == &"input" and g.nodes[1].op() == &"output" \
			and g.connections.size() == 1 and g.output_index() == 1 and g.reads_input()
	print("    2 nodes Input->Output, output_index=%d, reads_input=%s, wires=%d"
		% [g.output_index(), g.reads_input(), g.connections.size()])
	if not shape_ok:
		_fail += 1; print("    !! the default graph is not a connected Input -> Output pair")
	# It is the identity: a surface passes straight through.
	var surf := _ramp(4.0)
	var d := _max_abs_diff(g.evaluate(GW, GH, RECT, null, surf), surf)
	print("    default graph is the identity (diff %.7f, want < %.7f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! the default Input->Output did not pass the surface through unchanged")


# ---- helpers ----------------------------------------------------------------------------------------

## Input(0) -> [mid nodes, chained] -> Output(last). No mid nodes = a bare Input -> Output.
func _io_graph(p_mid: Array) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new()]
	for m in p_mid:
		nodes.append(m)
	nodes.append(Pasture3DGraphNodeOutput.new())
	g.nodes = nodes
	var conns: Array = []
	for i in range(nodes.size() - 1):
		conns.append(_c4(i, 0, i + 1, 0)) # chain each node's out 0 into the next's in 0
	g.connections = conns
	return g


func _c4(a: int, b: int, c: int, d: int) -> PackedInt32Array:
	return PackedInt32Array([a, b, c, d])


func _const(p_v: float) -> Pasture3DGraphNodeConst:
	var n := Pasture3DGraphNodeConst.new(); n.value = p_v
	return n


func _blend(p_mode) -> Pasture3DGraphNodeBlend:
	var n := Pasture3DGraphNodeBlend.new(); n.mode = p_mode
	return n


## A non-flat surface: a diagonal ramp so a blur and an add both visibly move it.
func _ramp(p_scale: float) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			s[iz * GW + ix] = p_scale * (float(ix) / GW + float(iz) / GH)
	return s


func _absmax(p: PackedFloat32Array) -> float:
	var m := 0.0
	for v in p:
		m = maxf(m, absf(v))
	return m


func _spread(p: PackedFloat32Array) -> float:
	if p.is_empty():
		return 0.0
	var lo := INF
	var hi := -INF
	for v in p:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return hi - lo


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m
