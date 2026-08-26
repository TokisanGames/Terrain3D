# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphNativeBakeGate — the native rasteriser bakes a graph modifier the same as the GDScript oracle
# (terrain-graph grid-pass interleave, stage 2).
#
# The claim: with the interleave, a Pasture3DMound carrying a native-supported Pasture3DTerrainGraph is no
# longer forced onto the GDScript path (`_stack_forces_gdscript` returns false), and the native rasteriser's
# BrushModStep::GRAPH bakes the SAME surface the GDScript executor does — to the house 1e-4 m parity
# tolerance, over a real terrain, through get_height.
#
# METHOD (mirrors BrushStackGate's BW-oracle). The bare dome carries a pre-existing float-vs-double gap
# between the two rasterisers that scales with amplitude; the question is whether the GRAPH step ADDS
# disagreement of its own, so the dome gap is measured first and subtracted. The graph runs LIVE, so neither
# path serves a frozen cache the other filled (which would make the A/B compare a path against itself).
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/GraphNativeBakeGate.tscn
extends Node

const DEMO_DATA := "res://demo/data"
const SITE := Vector3(200.0, 0.0, 160.0)
const HALF := 50.0
const PROBE_STRIDE := 2
const PARITY_TOL := 1.0e-4

var _fail := 0
var _root: Node3D
var _terrain
var _vs := 1.0


func _ready() -> void:
	print("\n=== GraphNativeBakeGate: native graph bake == GDScript oracle (grid-pass interleave, stage 2) ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_vs = _terrain.vertex_spacing
	_a_native_matches_gdscript()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH NATIVE BAKE PASS" if _fail == 0 else "GRAPH NATIVE BAKE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _a_native_matches_gdscript() -> void:
	var mound = _make_mound(SITE)
	if mound == null:
		return
	mound.height = 40.0
	var probes := _lattice(SITE)
	print("    %d probes on the vertex lattice" % probes.size())

	# BASELINE: the bare dome's native-vs-GDScript gap (pre-existing, see BrushStackGate BW-oracle).
	var none: Array[Pasture3DNode] = []
	mound.modifiers = none
	mound.force_gdscript_raster = false
	var dome_native := _bake(mound, probes)
	mound.force_gdscript_raster = true
	var dome_oracle := _bake(mound, probes)
	if not _all_finite(dome_native):
		_fail += 1; print("    !! the probes read no terrain; the fixture is outside demo/data"); return
	var dome_gap := _max_abs_diff(dome_native, dome_oracle)

	# A native-supported FILTER graph: Input -> Blend(ADD) <- Noise -> Output (adds noise over the surface).
	var noise := _make_noise()
	var gmod := _graph_mod(noise, 6.0, 0.5)
	mound.modifiers = [gmod] as Array[Pasture3DNode]

	# THE HEADLINE FLIP: a native-supported graph must NOT force the GDScript path, or the A/B below would
	# trivially agree (both GDScript) and prove nothing.
	var forces: bool = mound._stack_forces_gdscript()
	print("    native-supported graph forces GDScript = %s (want false)" % forces)
	if forces:
		_fail += 1; print("    !! the graph still forces GDScript — the native rasteriser is not running it")

	mound.force_gdscript_raster = false
	var native := _bake(mound, probes)
	mound.force_gdscript_raster = true
	var oracle := _bake(mound, probes)
	mound.force_gdscript_raster = false

	var gap := _max_abs_diff(native, oracle)
	var added := gap - dome_gap
	print("    bare dome native vs GDScript: %.6f m (pre-existing)" % dome_gap)
	print("    with the graph:               %.6f m  ->  the graph ADDS %.6f m (want < %.5f)"
		% [gap, added, PARITY_TOL])

	# CONTROL: doubling the amount moves the native bake substantially. If the two paths agreed only because
	# both baked a bare dome (the graph contributing nothing), this would not move.
	gmod.strength = 1.0
	var native_2x := _bake(mound, probes)
	var moved := _max_abs_diff(native, native_2x)
	print("    control: doubling the amount moves the native bake by %.4f m (want > 0.5)" % moved)
	if moved < 0.5:
		_fail += 1; print("    !! the graph barely changed the bake, so the two paths agreeing proves nothing")
	elif added > PARITY_TOL:
		_fail += 1; print("    !! the native graph bake diverges from the GDScript oracle beyond tolerance")


# ---- fixtures ---------------------------------------------------------------------------------------

func _graph_mod(p_noise: FastNoiseLite, p_amp: float, p_amount: float) -> Pasture3DNodeGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), _noise_gn(p_noise, p_amp),
		_blend_add(), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 2, 0]), PackedInt32Array([1, 0, 2, 1]), PackedInt32Array([2, 0, 3, 0])]
	var m := Pasture3DNodeGraph.new()
	m.graph = g
	m.strength = p_amount
	m.evaluation = Pasture3DNode.Evaluation.LIVE # both paths re-evaluate fresh; no cross-path cache
	return m


func _noise_gn(p_noise: FastNoiseLite, p_amp: float) -> Pasture3DGraphNodeNoise:
	var n := Pasture3DGraphNodeNoise.new(); n.noise = p_noise; n.amplitude = p_amp
	return n


func _blend_add() -> Pasture3DGraphNodeBlend:
	var n := Pasture3DGraphNodeBlend.new(); n.mode = Pasture3DGraphNodeBlend.Mode.ADD
	return n


## A FastNoiseLite the two paths share BY REFERENCE, so the comparison is about the bake, not two noise
## objects configured alike.
func _make_noise() -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = 1337
	n.frequency = 0.02
	return n


func _make_mound(p_at: Vector3):
	if not is_finite(_height(p_at)):
		_fail += 1; print("    !! no terrain at %s; the fixture is outside demo/data" % p_at); return null
	var mound := Pasture3DMound.new()
	mound.name = "GraphNativeBake"
	_root.add_child(mound)
	mound.terrain = _terrain
	mound.global_position = p_at
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	c.add_point(Vector3(-HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, HALF))
	c.add_point(Vector3(-HALF, 0.0, HALF))
	c.closed = true
	path.curve = c
	mound.add_child(path)
	return mound


func _lattice(p_centre: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var step := _vs * PROBE_STRIDE
	var reach := HALF - _vs * 2.0
	var x := -reach
	while x <= reach:
		var z := -reach
		while z <= reach:
			out.append(Vector3(snappedf(p_centre.x + x, _vs), 0.0, snappedf(p_centre.z + z, _vs)))
			z += step
		x += step
	return out


func _bake(p_mound, p_probes: Array[Vector3]) -> Array[float]:
	p_mound._refresh_owner(p_mound._layer_owner, false, [])
	return _snapshot(p_probes)


func _snapshot(p_points: Array[Vector3]) -> Array[float]:
	var out: Array[float] = []
	for p in p_points:
		out.append(_height(p))
	return out


func _height(p_at: Vector3) -> float:
	return _terrain.data.get_height(Vector3(p_at.x, 0.0, p_at.z))


func _max_abs_diff(p_a: Array[float], p_b: Array[float]) -> float:
	var worst := 0.0
	for i in range(mini(p_a.size(), p_b.size())):
		if is_finite(p_a[i]) and is_finite(p_b[i]):
			worst = maxf(worst, absf(p_a[i] - p_b[i]))
	return worst


func _all_finite(p_vals: Array[float]) -> bool:
	for v in p_vals:
		if not is_finite(v):
			return false
	return true
