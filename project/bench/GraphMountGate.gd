# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphMountGate — Pasture3DNodeGraph mounted in a brush's node stack (terrain-graph increment 2).
#
# The claim under test: a graph modifier, run through the SAME GDScript executor a real bake uses
# (Pasture3DTerrainBrush._run_modifier_stack -> _apply_graph_step), adds its graph's output over the
# brush's exact per-cell world grid, feathered by the interior profile — and a brush carrying one is
# forced onto the GDScript path (the native rasteriser cannot run &"graph").
#
# House discipline: every criterion measures a FIELD DELTA and carries a CONTROL that must move if the
# path is dead. No terrain is needed — the executor operates on grids handed in through the context.
extends Node

const GW := 40
const GH := 28
const VS := 1.0
const X0 := -15.0 # deliberately off-origin so a bad world mapping shows
const Z0 := 8.0

const EPS := 1.0e-4
const LIVE := 0.05

var _fail := 0
var _brush: Pasture3DMound


func _ready() -> void:
	print("=== GraphMountGate: Pasture3DNodeGraph in a brush stack (increment 2) ===\n")
	_brush = Pasture3DMound.new()
	add_child(_brush)
	_a_world_aligned_add()
	_b_feathered_by_profile()
	_c_grid_node_in_graph()
	_d_forces_gdscript_path()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH MOUNT PASS" if _fail == 0 else "GRAPH MOUNT FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- A. The graph is added at the brush's own world coords (min_x + ix*vs), scaled by strength ---------
func _a_world_aligned_add() -> void:
	print("[A] graph output added at min_x+ix*vs, times strength")
	var noise := _make_noise(2024, 0.04)
	var amp := 9.0
	var node := _graph_node(_single_noise_graph(noise, amp), 2.0)
	var flat := _const_grid(1.0)
	var got := _run([_step(node)], flat) # profile all 1

	# Oracle: strength * amplitude * noise(min_x+ix*vs, min_z+iz*vs), vertex-aligned.
	var oracle := PackedFloat32Array(); oracle.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			oracle[iz * GW + ix] = 2.0 * amp * noise.get_noise_2d(X0 + ix * VS, Z0 + iz * VS)
	var d := _max_abs_diff(got, oracle)
	print("    max |mounted - vertex-aligned oracle| = %.6f m (want < %.6f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! the graph is not added at the brush's per-cell world coords")

	# CONTROL 1 (alignment): a CENTRE-shifted sampling (ix+0.5) must NOT match — proves vertex alignment.
	var centre := PackedFloat32Array(); centre.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			centre[iz * GW + ix] = 2.0 * amp * noise.get_noise_2d(X0 + (ix + 0.5) * VS, Z0 + (iz + 0.5) * VS)
	var off := _max_abs_diff(got, centre)
	print("    control: vs centre-shifted sampling differs by %.3f m (want > %.2f)" % [off, LIVE])
	if off <= LIVE:
		_fail += 1; print("    !! control dead: cannot tell vertex from centre alignment")

	# CONTROL 2 (strength): strength 0 contributes nothing.
	var zero := _run([_step(_graph_node(_single_noise_graph(noise, amp), 0.0))], flat)
	print("    control: strength 0 -> field all 0 = %s" % _all_zero(zero))
	if not _all_zero(zero):
		_fail += 1; print("    !! strength did not scale the contribution")


# --- B. The interior profile feathers the graph output (rim stays clean) ------------------------------
func _b_feathered_by_profile() -> void:
	print("[B] output feathered by the interior profile")
	var node := _graph_node(_single_noise_graph(_make_noise(5, 0.06), 10.0), 1.0)
	# Profile 0 on the border ring, 1 inside.
	var ramp := PackedFloat64Array(); ramp.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			ramp[iz * GW + ix] = 0.0 if (ix == 0 or ix == GW - 1 or iz == 0 or iz == GH - 1) else 1.0
	var got := _run([_step(node)], ramp)
	var border_clean := true
	var interior_alive := false
	for iz in range(GH):
		for ix in range(GW):
			var v: float = got[iz * GW + ix]
			if ix == 0 or ix == GW - 1 or iz == 0 or iz == GH - 1:
				if absf(v) > EPS: border_clean = false
			elif absf(v) > LIVE:
				interior_alive = true
	print("    border == 0 = %s, interior alive = %s" % [border_clean, interior_alive])
	if not border_clean or not interior_alive:
		_fail += 1; print("    !! the profile did not feather the graph output")

	# CONTROL: an all-1 profile leaves the border non-zero.
	var full := _run([_step(node)], _const_grid(1.0))
	var border_full := false
	for ix in range(GW):
		if absf(full[ix]) > LIVE: border_full = true # top row
	print("    control: all-1 profile leaves the border alive = %s" % border_full)
	if not border_full:
		_fail += 1; print("    !! control dead: profile is not actually gating the border")


# --- C. A grid node inside the graph (Smooth) runs through the mount ----------------------------------
func _c_grid_node_in_graph() -> void:
	print("[C] a Smooth grid node inside the mounted graph")
	var noise := _make_noise(11, 0.09)
	var amp := 10.0
	# graph: Noise -> Smooth(3)
	var g := Pasture3DTerrainGraph.new()
	var typed: Array[Pasture3DGraphNode] = []
	typed.append(_noise_gn(noise, amp))
	var sm := Pasture3DGraphNodeSmooth.new(); sm.passes = 3
	typed.append(sm)
	g.nodes = typed
	g.connections = [PackedInt32Array([0, 0, 1, 0])]
	g.output_node = 1
	var got := _run([_step(_graph_node(g, 1.5))], _const_grid(1.0))

	# Oracle: blur_nan(vertex-aligned noise) * strength.
	var raw := PackedFloat32Array(); raw.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			raw[iz * GW + ix] = amp * noise.get_noise_2d(X0 + ix * VS, Z0 + iz * VS)
	var blurred := Pasture3DGraphOps.blur_nan(raw.duplicate(), GW, GH, 3)
	var oracle := PackedFloat32Array(); oracle.resize(GW * GH)
	for i in range(oracle.size()):
		oracle[i] = 1.5 * blurred[i]
	var d := _max_abs_diff(got, oracle)
	print("    max |mounted - 1.5*blur(noise)| = %.6f m (want < %.6f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! the Smooth grid node did not run correctly through the mount")

	# CONTROL: the smoothed mount differs from the raw (unsmoothed) mount.
	var rawmount := _run([_step(_graph_node(_single_noise_graph(noise, amp), 1.5))], _const_grid(1.0))
	var moved := _max_abs_diff(got, rawmount)
	print("    control: smoothing moved the field by %.3f m (want > %.2f)" % [moved, LIVE])
	if moved <= LIVE:
		_fail += 1; print("    !! control dead: Smooth changed nothing through the mount")


# --- D. An active graph modifier forces the GDScript path --------------------------------------------
func _d_forces_gdscript_path() -> void:
	print("[D] an active graph modifier forces the GDScript rasteriser")
	var gnode := _graph_node(_single_noise_graph(_make_noise(1, 0.05), 5.0), 1.0)
	var stack: Array[Pasture3DNode] = [gnode]
	_brush.modifiers = stack
	var forced: bool = _brush._stack_forces_gdscript()
	print("    graph in stack -> forces GDScript = %s" % forced)
	if not forced:
		_fail += 1; print("    !! a graph modifier did NOT force the GDScript path (native would drop it)")

	# CONTROL: a non-graph stack (a Noise node) does not force it.
	var nnode := Pasture3DNodeNoise.new()
	nnode.noise = _make_noise(2, 0.05)
	nnode.strength = 3.0
	var stack2: Array[Pasture3DNode] = [nnode]
	_brush.modifiers = stack2
	var forced2: bool = _brush._stack_forces_gdscript()
	print("    control: noise-only stack -> forces GDScript = %s (want false)" % forced2)
	if forced2:
		_fail += 1; print("    !! control dead: a non-graph stack also forced GDScript")
	_brush.modifiers = [] as Array[Pasture3DNode]


# ---- helpers ----------------------------------------------------------------------------------------

func _run(p_steps: Array, p_profile: PackedFloat64Array) -> PackedFloat32Array:
	var n := GW * GH
	var amp := PackedFloat64Array(); amp.resize(n)      # 0 -> a pure-graph contribution
	var basey := PackedFloat32Array(); basey.resize(n)  # unused under add
	var ctx := {"gw": GW, "gh": GH, "vs": VS, "min_x": X0, "min_z": Z0, "add": true}
	return _brush._run_modifier_stack(p_steps, amp, p_profile, basey, ctx)


func _step(p_node: Pasture3DNodeGraph) -> Dictionary:
	return {"mod": p_node, "op": p_node.op(), "grid": p_node.needs_grid()}


func _graph_node(p_graph: Pasture3DTerrainGraph, p_strength: float) -> Pasture3DNodeGraph:
	var n := Pasture3DNodeGraph.new()
	n.graph = p_graph
	n.strength = p_strength
	return n


func _single_noise_graph(p_noise: FastNoiseLite, p_amp: float) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var typed: Array[Pasture3DGraphNode] = []
	typed.append(_noise_gn(p_noise, p_amp))
	g.nodes = typed
	g.output_node = 0
	return g


func _noise_gn(p_noise: FastNoiseLite, p_amp: float) -> Pasture3DGraphNodeNoise:
	var n := Pasture3DGraphNodeNoise.new()
	n.noise = p_noise
	n.amplitude = p_amp
	return n


func _make_noise(p_seed: int, p_freq: float) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = p_seed
	n.frequency = p_freq
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	return n


func _const_grid(p_v: float) -> PackedFloat64Array:
	var g := PackedFloat64Array(); g.resize(GW * GH)
	g.fill(p_v)
	return g


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m


func _all_zero(p_g: PackedFloat32Array) -> bool:
	for x in p_g:
		if absf(x) > EPS:
			return false
	return p_g.size() > 0
