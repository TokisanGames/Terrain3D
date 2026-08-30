# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphNativeRouteGate — every graph node claims a native C++ route, and actually takes it.
#
# THIS GATE EXISTS BECAUSE OF A BUG IT WOULD HAVE CAUGHT IMMEDIATELY. Phases 1 and 2 shipped five nodes
# whose C++ kernels, opcodes, lowering and GPU shader modes were all correct and all verified — and every
# graph containing one of them still ran on the GDScript evaluator, because the op was missing from the
# `SUPPORTED` allow-list in Pasture3DTerrainGraph.native_supported(). Nothing failed. Nothing warned. The
# per-node parity gates all passed, because they compared the GPU against that same GDScript fallback.
#
# The lesson is that a missing entry in that list is INVISIBLE to any criterion that only compares two
# evaluators for agreement. It has to be checked as a route, per op, by name.
#
# Two claims, for each of the five nodes:
#   R  native_supported() is true for a graph containing it — it takes the C++ path at all.
#   P  the native evaluator agrees with the GDScript reference evaluator — the LOWERING is right.
#      Nothing else tests the lowering: the per-node gates call Pasture3DUtil kernels directly and so
#      never exercise the parameter packing in _lower_node_op().
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/GraphNativeRouteGate.tscn
extends Node

const GW := 48
const GH := 48
const RECT := Rect2(-120.0, -120.0, 240.0, 240.0)
## Both paths materialise to float32, and the native side accumulates in double — the same bar
## GraphCppParityGate holds the cell evaluator to.
const EPS := 1.0e-4

var _fail := 0


func _ready() -> void:
	print("=== GraphNativeRouteGate: no node silently falls back to GDScript ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid"):
		print("!! Pasture3DUtil.graph_eval_grid is missing — the DLL is stale; rebuild the extension.")
		get_tree().quit(1)
		return

	_check("Falloff", _falloff())
	_check("Contrast", _contrast())
	_check("Transform", _transform())
	_check("DistanceTransform", _distance_transform(), _blob_mask())
	_check("ExpandShrink", _expand_shrink())
	_check("RelativeElevation", _relative_elevation())
	_check("SmoothFill", _smooth_fill())
	_check("RecastCliff", _recast_cliff())
	_check("WarpDownslope", _warp_downslope())
	_check_generator("Gavoronoise", _gavoronoise())
	_check("FloodingUniformLevel", _flooding_uniform_level())
	_check("WaterMask", _water_mask(), _depth_field())
	_check("Mudslide", _mudslide())
	_control_an_unlisted_op_is_refused()

	print("\n=== %s (%d failures) ===\n" % ["NATIVE ROUTE PASS" if _fail == 0 else "NATIVE ROUTE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_node: Pasture3DGraphNode, p_input := PackedFloat32Array()) -> void:
	print("[%s]" % p_name)
	var surf := p_input if not p_input.is_empty() else _bumps()
	var g := _build_graph([p_node])

	# R — the route itself.
	var supported: bool = g.native_supported()
	print("    native_supported() = %s (want true)" % str(supported))
	if not supported:
		_fail += 1
		print("    !! op \"%s\" is missing from the SUPPORTED list in native_supported()." % str(p_node.op()))
		print("       This does not fail loudly: it drops the WHOLE graph onto the GDScript evaluator,")
		print("       where a pointwise node runs per cell in script. Add the op to that list.")
		return

	var prog: Dictionary = g.compile_graph_program()
	if prog.is_empty():
		_fail += 1; print("    !! compile_graph_program returned nothing — the op has no _lower_node_op case")
		return

	# P — the lowering. compile_graph_program packs this node's parameters into the program's parallel
	# arrays by hand; a parameter written to the wrong slot produces a plausible field that simply is not
	# the one the node describes, and only a comparison against the GDScript node object catches it.
	var native: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(prog, GW, GH, RECT, surf)
	var script_side: PackedFloat32Array = g._eval_unfolded(GW, GH, RECT, null, surf)

	if native.size() != GW * GH:
		_fail += 1; print("    !! the native evaluator returned %d cells, expected %d" % [native.size(), GW * GH])
		return

	var d := _max_abs_diff(native, script_side)
	print("    max |native - gdscript| = %.7f (want < %.6f)" % [d, EPS])
	if d > EPS:
		_fail += 1
		print("    !! the native lowering disagrees with the node's own GDScript evaluation.")
		print("       Check the parameter slots in _lower_node_op() against the evaluator case.")

	# CONTROL: the node must have DONE something, or both paths returning the input would pass P.
	var moved := _max_abs_diff(native, surf)
	print("    control: the node changed the field by %.4f (want > 0.01)" % moved)
	if moved <= 0.01:
		_fail += 1; print("    !! NO-SIGNAL — this configuration is a pass-through, so P compared nothing")


## The control for the gate as a whole: native_supported() must still REFUSE something. If it started
## returning true unconditionally, every R above would pass for the wrong reason.
func _control_an_unlisted_op_is_refused() -> void:
	print("[control] an op with no native kernel is still refused")
	var dev := Pasture3DGraphNodeDevExpandShrink.new()
	var g := _build_graph([dev])
	var supported: bool = g.native_supported()
	print("    native_supported() on a [Dev/GD] node = %s (want false)" % str(supported))
	if supported:
		_fail += 1
		print("    !! native_supported() is accepting an op that has no native kernel — every route")
		print("       criterion in this gate is now passing vacuously.")


# --- node fixtures ------------------------------------------------------------------------------------
func _falloff() -> Pasture3DGraphNode:
	var n := Pasture3DGraphNodeFalloff.new()
	n.centre = Vector2(10.0, -15.0)
	n.radius = 50.0
	n.feather = 60.0
	n.strength = 1.0
	return n


func _contrast() -> Pasture3DGraphNode:
	var n := Pasture3DGraphNodeContrast.new()
	n.mode = 0
	n.amount = 2.2
	n.range_min = -20.0
	n.range_max = 25.0
	return n


func _transform() -> Pasture3DGraphNode:
	var n := Pasture3DGraphNodeTransform.new()
	n.offset = Vector2(17.0, -9.0)
	n.rotation_deg = 21.0
	n.scale = 1.2
	n.pivot = Vector2(5.0, 5.0)
	return n


func _distance_transform() -> Pasture3DGraphNode:
	var n := Pasture3DGraphNodeDistanceTransform.new()
	n.threshold = 0.5
	n.direction = 2
	n.metric = 0
	n.output_units = 0
	n.max_distance = 0.0
	return n


func _expand_shrink() -> Pasture3DGraphNode:
	var n := Pasture3DGraphNodeExpandShrink.new()
	n.mode = 2
	n.radius = 14.0
	n.kernel = 0
	n.iterations = 1
	return n


func _relative_elevation() -> Pasture3DGraphNode:
	var n := Pasture3DGraphNodeRelativeElevation.new()
	n.radius = 40.0
	n.output_units = 0
	return n


func _smooth_fill() -> Pasture3DGraphNode:
	var n := Pasture3DGraphNodeSmoothFill.new()
	n.mode = 0
	n.radius = 30.0
	n.k = 0.1
	n.amount = 1.0
	return n


func _recast_cliff() -> Pasture3DGraphNode:
	var n := Pasture3DGraphNodeRecastCliff.new()
	n.talus_angle_deg = 30.0
	n.radius = 15.0
	n.amplitude = 8.0
	n.gain = 2.0
	n.direction_deg = -1.0
	n.amount = 1.0
	return n


## GENERATORS take no height input, so _check's "wire the surface into port 0" harness does not apply —
## on Gavoronoise port 0 is `amplitude`, and feeding a height grid into it would be testing something
## else entirely. Same two claims, different wiring.
func _check_generator(p_name: String, p_node: Pasture3DGraphNode) -> void:
	print("[%s]" % p_name)
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [p_node, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 1, 0])]

	var supported: bool = g.native_supported()
	print("    native_supported() = %s (want true)" % str(supported))
	if not supported:
		_fail += 1
		print("    !! op \"%s\" is missing from the SUPPORTED list in native_supported()." % str(p_node.op()))
		print("       This does not fail loudly: it drops the WHOLE graph onto the GDScript evaluator.")
		return

	var prog: Dictionary = g.compile_graph_program()
	if prog.is_empty():
		_fail += 1; print("    !! compile_graph_program returned nothing — the op has no _lower_node_op case")
		return

	var empty := PackedFloat32Array()
	var native: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(prog, GW, GH, RECT, empty)
	var script_side: PackedFloat32Array = g._eval_unfolded(GW, GH, RECT, null, empty)
	var d := _max_abs_diff(native, script_side)
	print("    max |native - gdscript| = %.7f (want < %.6f)" % [d, EPS])
	if d > EPS:
		_fail += 1
		print("    !! the native lowering disagrees with the node's own GDScript evaluation.")
		print("       Check the parameter slots in _lower_node_op() against the evaluator case.")

	var lo := INF
	var hi := -INF
	for i in native.size():
		lo = minf(lo, native[i])
		hi = maxf(hi, native[i])
	print("    control: the generator produced %.4f m of relief (want > 0.01)" % (hi - lo))
	if hi - lo <= 0.01:
		_fail += 1; print("    !! NO-SIGNAL — a flat field, so the comparison above compared two flat grids")


func _gavoronoise() -> Pasture3DGraphNode:
	var n := Pasture3DGraphNodeGavoronoise.new()
	n.amplitude = 80.0
	n.frequency = 0.01
	n.octaves = 3
	n.seed = 5
	n.z_cut_min = 0.0
	n.z_cut_max = 1.0
	return n


func _warp_downslope() -> Pasture3DGraphNode:
	var n := Pasture3DGraphNodeWarpDownslope.new()
	n.displacement = 18.0
	n.radius = 12.0
	n.reverse = false
	n.amount = 1.0
	return n


func _flooding_uniform_level() -> Pasture3DGraphNode:
	var n := Pasture3DGraphNodeFloodingUniformLevel.new()
	# Between the troughs and the crests of _bumps(), so the node has something to clamp and something to
	# leave alone. A level under the whole field would pass R and P while doing nothing.
	n.water_level = 4.0
	n.clamp_terrain = true
	return n


func _water_mask() -> Pasture3DGraphNode:
	var n := Pasture3DGraphNodeWaterMask.new()
	n.depth_threshold = 0.5
	n.shore_width = 20.0
	n.shore_falloff = Pasture3DGraphNodeWaterMask.ShoreFalloff.SMOOTH
	return n


func _mudslide() -> Pasture3DGraphNode:
	var n := Pasture3DGraphNodeMudslide.new()
	n.talus_angle_deg = 20.0
	n.depth = 6.0
	n.travel_distance = 40.0
	n.depth_exponent = 1.0
	n.viscosity_power = 1.0
	n.amount = 1.0
	# LIVE, not the node's FROZEN default: a frozen node serves a cache, and this gate is comparing the
	# routes that produce the field, not the cache in front of them.
	n.evaluation = Pasture3DGraphNodeMudslide.Evaluation.LIVE
	return n


## A depth field for WaterMask: positive in a disc, zero outside. Feeding it _bumps() would work too, but a
## depth is what the port actually means and a fixture that lies about units is how metres get lost.
func _depth_field() -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var wx := RECT.position.x + (float(ix) + 0.5) * RECT.size.x / float(GW)
			var wz := RECT.position.y + (float(iz) + 0.5) * RECT.size.y / float(GH)
			var r := sqrt(wx * wx + wz * wz)
			g[iz * GW + ix] = maxf(60.0 - r, 0.0) * 0.2
	return g


# --- helpers ------------------------------------------------------------------------------------------
func _build_graph(p_mid: Array) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new()]
	for mnode in p_mid:
		nodes.append(mnode)
	nodes.append(Pasture3DGraphNodeOutput.new())
	g.nodes = nodes
	var conns: Array = []
	for i in range(nodes.size() - 1):
		conns.append(PackedInt32Array([i, 0, i + 1, 0]))
	g.connections = conns
	return g


func _bumps() -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			a[iz * GW + ix] = 22.0 * sin(w.x * 0.019) * cos(w.y * 0.014) + 7.0 * sin(w.y * 0.041)
	return a


func _blob_mask() -> PackedFloat32Array:
	var m := PackedFloat32Array()
	m.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			m[iz * GW + ix] = 1.0 if w.distance_to(Vector2(20.0, -10.0)) < 45.0 else 0.0
	return m


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in p_a.size():
		var x := p_a[i]
		var y := p_b[i]
		if is_nan(x) and is_nan(y):
			continue
		if is_nan(x) or is_nan(y):
			return INF
		m = maxf(m, absf(x - y))
	return m
