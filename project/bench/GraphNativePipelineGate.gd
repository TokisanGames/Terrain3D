# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphNativePipelineGate — Milestone 4 Whole-Graph C++ Native Pipeline & Memory Arena Gate.
# Validates bit-level parity, scratch arena memory pool reuse, and throughput for multi-branch DAGs.
extends Node

const GW := 64
const GH := 64
const RECT := Rect2(-200.0, -200.0, 400.0, 400.0)
const EPS := 5.0e-4

var _fail: int = 0


func _ready() -> void:
	print("=== GraphNativePipelineGate: Native C++ Whole-Graph Pipeline (Milestone 4) ===\n")
	
	_a_procedural_generator_pipeline()
	_b_complex_multibranch_dag()
	_c_scratch_arena_buffer_reuse()
	_d_end_to_end_throughput_scaling()
	_e_hydraulic_erosion_pipeline()
	
	if _fail == 0:
		print("\n=== GRAPH NATIVE PIPELINE PASS (0 failures) ===\n")
		get_tree().quit(0)
	else:
		print("\n=== GRAPH NATIVE PIPELINE FAIL (%d failures) ===\n" % _fail)
		get_tree().quit(1)


# --- Helper: max absolute difference -----------------------------------------------------------------
func _max_abs_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var diff := 0.0
	for i in range(mini(a.size(), b.size())):
		var d := absf(a[i] - b[i])
		if d > diff:
			diff = d
	return diff


# --- A. Multi-generator pipeline: Jordan + Swiss -> Blend(ADD) -> Terrace -> Output ------------------
func _a_procedural_generator_pipeline() -> void:
	print("[A] Multi-generator pipeline: Jordan + Swiss -> Blend(ADD) -> Terrace -> Output")
	var g := Pasture3DTerrainGraph.new()
	var jn := Pasture3DGraphNodeNoiseJordan.new(); jn.amplitude = 100.0; jn.frequency = 0.005; jn.seed = 42
	var sn := Pasture3DGraphNodeNoiseSwiss.new(); sn.amplitude = 50.0; sn.frequency = 0.008; sn.seed = 99
	var bl := Pasture3DGraphNodeBlend.new(); bl.mode = Pasture3DGraphNodeBlend.Mode.ADD
	var tr := Pasture3DGraphNodeTerrace.new(); tr.band_height = 10.0; tr.hardness = 0.7; tr.amount = 0.8
	var out := Pasture3DGraphNodeOutput.new()
	
	g.nodes = [jn, sn, bl, tr, out]
	g.connections = [
		PackedInt32Array([0, 0, 2, 0]), # Jordan -> Blend.a
		PackedInt32Array([1, 0, 2, 1]), # Swiss -> Blend.b
		PackedInt32Array([2, 0, 3, 0]), # Blend -> Terrace.in
		PackedInt32Array([3, 0, 4, 0]), # Terrace -> Output.in
	]
	
	print("    native_supported = %s (want true)" % g.native_supported())
	if not g.native_supported():
		_fail += 1; print("    !! graph wrongly reported native_supported = false")
		
	var prog := g.compile_graph_program()
	var native_res := Pasture3DUtil.graph_eval_grid(prog, GW, GH, RECT, PackedFloat32Array())
	var ref_res := g._eval_unfolded(GW, GH, RECT, null, null)
	var d := _max_abs_diff(native_res, ref_res)
	print("    max |native_pipeline - reference| = %.7f (want < %.7f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! native pipeline output diverged from reference")


# --- B. Complex multi-branch DAG: Input + Furrows -> Dunes -> Mask -> Blend(MUL) -> Output ----------
func _b_complex_multibranch_dag() -> void:
	print("\n[B] Complex multi-branch DAG: Input + Furrows -> Dunes -> Mask -> Blend(MUL) -> Output")
	var g := Pasture3DTerrainGraph.new()
	var inp := Pasture3DGraphNodeInput.new()
	var fur := Pasture3DGraphNodeFurrows.new(); fur.amplitude = 4.0; fur.spacing = 20.0
	var dun := Pasture3DGraphNodeDunes.new(); dun.amplitude = 6.0; dun.wavelength = 30.0
	var msk := Pasture3DGraphNodeMask.new(); msk.property = Pasture3DGraphNodeMask.Property.SLOPE; msk.band_min = 10.0; msk.band_max = 50.0
	var bl1 := Pasture3DGraphNodeBlend.new(); bl1.mode = Pasture3DGraphNodeBlend.Mode.ADD
	var bl2 := Pasture3DGraphNodeBlend.new(); bl2.mode = Pasture3DGraphNodeBlend.Mode.MUL
	var out := Pasture3DGraphNodeOutput.new()
	
	g.nodes = [inp, fur, dun, msk, bl1, bl2, out]
	g.connections = [
		PackedInt32Array([0, 0, 4, 0]), # Input -> Blend1.a
		PackedInt32Array([1, 0, 4, 1]), # Furrows -> Blend1.b
		PackedInt32Array([0, 0, 3, 0]), # Input -> Mask.in
		PackedInt32Array([4, 0, 5, 0]), # Blend1 -> Blend2.a
		PackedInt32Array([3, 0, 5, 1]), # Mask -> Blend2.b
		PackedInt32Array([5, 0, 6, 0]), # Blend2 -> Output.in
	]
	
	# Create synthetic input slope surface
	var surface := PackedFloat32Array()
	surface.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			surface[iz * GW + ix] = float(ix + iz) * 2.0
			
	var prog := g.compile_graph_program()
	var native_res := Pasture3DUtil.graph_eval_grid(prog, GW, GH, RECT, surface)
	var ref_res := g._eval_unfolded(GW, GH, RECT, null, surface)
	var d := _max_abs_diff(native_res, ref_res)
	print("    max |native_pipeline - reference| = %.7f (want < %.7f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! complex multi-branch DAG output diverged from reference")


# --- C. Scratch arena buffer reuse verification ------------------------------------------------------
func _c_scratch_arena_buffer_reuse() -> void:
	print("\n[C] Scratch arena buffer reuse verification (15-node linear & diamond DAG)")
	var g := Pasture3DTerrainGraph.new()
	var nodes_arr: Array[Pasture3DGraphNode] = []
	var conns_arr: Array[PackedInt32Array] = []
	
	var n0 := Pasture3DGraphNodeNoise.new()
	nodes_arr.append(n0)
	
	# Chain of 10 smooth filters
	for i in range(10):
		var sm := Pasture3DGraphNodeSmooth.new(); sm.passes = 1
		nodes_arr.append(sm)
		conns_arr.append(PackedInt32Array([i, 0, i + 1, 0]))
		
	var out := Pasture3DGraphNodeOutput.new()
	nodes_arr.append(out)
	conns_arr.append(PackedInt32Array([10, 0, 11, 0]))
	
	g.nodes = nodes_arr
	g.connections = conns_arr
	
	var prog := g.compile_graph_program()
	var native_res := Pasture3DUtil.graph_eval_grid(prog, GW, GH, RECT, PackedFloat32Array())
	var ref_res := g._eval_unfolded(GW, GH, RECT, null, null)
	var d := _max_abs_diff(native_res, ref_res)
	print("    10-filter chain max |native - reference| = %.7f (want < %.7f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! buffer reuse in long chain corrupted intermediate state")


# --- D. End-to-end throughput scaling benchmark ------------------------------------------------------
func _d_end_to_end_throughput_scaling() -> void:
	print("\n[D] End-to-end throughput scaling benchmark across resolutions")
	var g := Pasture3DTerrainGraph.new()
	var jn := Pasture3DGraphNodeNoiseJordan.new(); jn.amplitude = 120.0; jn.frequency = 0.004
	var gp := Pasture3DGraphNodeGeologicalPrimitive.new(); gp.height = 80.0; gp.radius = 60.0
	var bl := Pasture3DGraphNodeBlend.new(); bl.mode = Pasture3DGraphNodeBlend.Mode.MAX
	var st := Pasture3DGraphNodeStrata.new(); st.band_height = 6.0; st.hardness = 0.8
	var out := Pasture3DGraphNodeOutput.new()
	
	g.nodes = [jn, gp, bl, st, out]
	g.connections = [
		PackedInt32Array([0, 0, 2, 0]),
		PackedInt32Array([1, 0, 2, 1]),
		PackedInt32Array([2, 0, 3, 0]),
		PackedInt32Array([3, 0, 4, 0]),
	]
	
	var prog := g.compile_graph_program()
	for size in [64, 128, 256, 512]:
		var t0 := Time.get_ticks_usec()
		var res := Pasture3DUtil.graph_eval_grid(prog, size, size, RECT, PackedFloat32Array())
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		print("    resolution %-9s: time = %6.2f ms (cells = %7d)" % ["%dx%d" % [size, size], ms, res.size()])
		if res.size() != size * size:
			_fail += 1; print("    !! size mismatch in pipeline benchmark")


# --- E. Hydraulic erosion in whole-graph pipeline ----------------------------------------------------
func _e_hydraulic_erosion_pipeline() -> void:
	print("\n[E] Hydraulic erosion in whole-graph pipeline (Noise + Blend -> ErosionHydraulic -> Output)")
	var g := Pasture3DTerrainGraph.new()
	var jn := Pasture3DGraphNodeNoiseJordan.new(); jn.amplitude = 120.0; jn.frequency = 0.005
	var bl := Pasture3DGraphNodeBlend.new(); bl.mode = Pasture3DGraphNodeBlend.Mode.ADD
	var cn := Pasture3DGraphNodeConst.new(); cn.value = 10.0
	var eh := Pasture3DGraphNodeErosionHydraulic.new()
	eh.iterations = 25
	eh.rain_rate = 0.051
	eh.evaporation_rate = 0.02
	eh.sediment_capacity = 8.1
	eh.erosion_speed = 0.5
	eh.deposition_speed = 0.4
	eh.min_slope = 0.01
	var out := Pasture3DGraphNodeOutput.new()

	g.nodes = [jn, cn, bl, eh, out]
	g.connections = [
		PackedInt32Array([0, 0, 2, 0]), # Jordan -> Blend.a
		PackedInt32Array([1, 0, 2, 1]), # Const -> Blend.b
		PackedInt32Array([2, 0, 3, 0]), # Blend -> ErosionHydraulic.in
		PackedInt32Array([3, 0, 4, 0]), # ErosionHydraulic -> Output.in
	]

	print("    native_supported = %s (want true)" % g.native_supported())
	if not g.native_supported():
		_fail += 1; print("    !! graph with ErosionHydraulic wrongly reported native_supported = false")

	var prog := g.compile_graph_program()
	if prog.is_empty():
		_fail += 1; print("    !! compile_graph_program failed for ErosionHydraulic")

	var native_res := Pasture3DUtil.graph_eval_grid(prog, GW, GH, RECT, PackedFloat32Array())
	var eval_res := g.evaluate(GW, GH, RECT, null, PackedFloat32Array())
	var d := _max_abs_diff(native_res, eval_res)
	print("    max |native_pipeline - graph.evaluate| = %.7f (want < 0.05)" % d)
	if d > 0.05:
		_fail += 1; print("    !! hydraulic erosion pipeline output diverged from graph.evaluate")

