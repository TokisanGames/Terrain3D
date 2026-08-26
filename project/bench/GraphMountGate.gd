# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphMountGate — Pasture3DNodeGraph mounted in a brush's node stack (terrain-graph increment 2).
#
# The claim under test: a graph modifier, run through the SAME GDScript executor a real bake uses
# (Pasture3DTerrainBrush._run_modifier_stack -> _apply_graph_step), COMPOSITES its graph's output over the
# brush's exact per-cell world grid — a FILTER (input → output): the output replaces the incoming surface,
# feathered by the interior profile and scaled by Strength as a 0..1 amount. Over a ZERO input surface a
# generator graph reduces to `amount * output * profile`; [E] drives the filter path with a real surface
# and an Input node. A brush carrying one is forced onto the GDScript path (native cannot run &"graph").
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
	_d_native_supported_runs_native()
	_e_filter_reads_surface()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH MOUNT PASS" if _fail == 0 else "GRAPH MOUNT FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- A. The graph is composited at the brush's own world coords (min_x + ix*vs), scaled by amount --------
func _a_world_aligned_add() -> void:
	print("[A] graph output composited at min_x+ix*vs, scaled by the amount")
	var noise := _make_noise(2024, 0.04)
	var amp := 9.0
	var amount := 0.5
	var node := _graph_node(_single_noise_graph(noise, amp), amount)
	var flat := _const_grid(1.0)
	var got := _run([_step(node)], flat) # profile all 1, and a ZERO input surface (amp=0 in _run)

	# Oracle: over a zero input surface, lerp(0, output, amount*profile) = amount * output, vertex-aligned.
	var oracle := PackedFloat32Array(); oracle.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			oracle[iz * GW + ix] = amount * amp * noise.get_noise_2d(X0 + ix * VS, Z0 + iz * VS)
	var d := _max_abs_diff(got, oracle)
	print("    max |mounted - vertex-aligned oracle| = %.6f m (want < %.6f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! the graph is not composited at the brush's per-cell world coords")

	# CONTROL 1 (alignment): a CENTRE-shifted sampling (ix+0.5) must NOT match — proves vertex alignment.
	var centre := PackedFloat32Array(); centre.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			centre[iz * GW + ix] = amount * amp * noise.get_noise_2d(X0 + (ix + 0.5) * VS, Z0 + (iz + 0.5) * VS)
	var off := _max_abs_diff(got, centre)
	print("    control: vs centre-shifted sampling differs by %.3f m (want > %.2f)" % [off, LIVE])
	if off <= LIVE:
		_fail += 1; print("    !! control dead: cannot tell vertex from centre alignment")

	# CONTROL 2 (amount): amount 0 contributes nothing (the graph does not touch the surface).
	var zero := _run([_step(_graph_node(_single_noise_graph(noise, amp), 0.0))], flat)
	print("    control: amount 0 -> field all 0 = %s" % _all_zero(zero))
	if not _all_zero(zero):
		_fail += 1; print("    !! the amount did not scale the contribution")


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
	var got := _run([_step(_graph_node(g, 1.0))], _const_grid(1.0)) # amount 1, zero input surface

	# Oracle: over a zero surface with amount 1 and a flat profile, the output IS blur_nan(vertex noise).
	var raw := PackedFloat32Array(); raw.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			raw[iz * GW + ix] = amp * noise.get_noise_2d(X0 + ix * VS, Z0 + iz * VS)
	var oracle := Pasture3DGraphOps.blur_nan(raw.duplicate(), GW, GH, 3)
	var d := _max_abs_diff(got, oracle)
	print("    max |mounted - blur(noise)| = %.6f m (want < %.6f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! the Smooth grid node did not run correctly through the mount")

	# CONTROL: the smoothed mount differs from the raw (unsmoothed) mount.
	var rawmount := _run([_step(_graph_node(_single_noise_graph(noise, amp), 1.0))], _const_grid(1.0))
	var moved := _max_abs_diff(got, rawmount)
	print("    control: smoothing moved the field by %.3f m (want > %.2f)" % [moved, LIVE])
	if moved <= LIVE:
		_fail += 1; print("    !! control dead: Smooth changed nothing through the mount")


# --- D. A native-supported graph runs on the NATIVE path; an unsupported one falls back to GDScript ----
func _d_native_supported_runs_native() -> void:
	print("[D] a native-supported graph does NOT force GDScript (the grid-pass interleave runs it)")
	var gnode := _graph_node(_single_noise_graph(_make_noise(1, 0.05), 5.0), 1.0)
	_brush.modifiers = [gnode] as Array[Pasture3DNode]
	var forced: bool = _brush._stack_forces_gdscript()
	print("    native-supported graph -> forces GDScript = %s (want false)" % forced)
	if forced:
		_fail += 1; print("    !! a native-supported graph still forces GDScript — the flip did not take")

	# CONTROL 1: an UNSUPPORTED graph (a cycle -> native_supported false) DOES fall back to GDScript, so
	# native never silently drops it.
	var cyc := Pasture3DTerrainGraph.new()
	var cn: Array[Pasture3DGraphNode] = [_blend_add()]
	cyc.nodes = cn
	cyc.connections = [PackedInt32Array([0, 0, 0, 0])] # blend feeds itself -> a cycle
	cyc.output_node = 0
	_brush.modifiers = [_graph_node(cyc, 1.0)] as Array[Pasture3DNode]
	var cforced: bool = _brush._stack_forces_gdscript()
	print("    control: an unsupported (cyclic) graph -> forces GDScript = %s (want true)" % cforced)
	if not cforced:
		_fail += 1; print("    !! an unsupported graph did not fall back to GDScript")

	# CONTROL 2: a non-graph stack (a Noise node) does not force it either.
	var nnode := Pasture3DNodeNoise.new()
	nnode.noise = _make_noise(2, 0.05)
	nnode.strength = 3.0
	_brush.modifiers = [nnode] as Array[Pasture3DNode]
	var forced2: bool = _brush._stack_forces_gdscript()
	print("    control: noise-only stack -> forces GDScript = %s (want false)" % forced2)
	if forced2:
		_fail += 1; print("    !! control dead: a non-graph stack also forced GDScript")
	_brush.modifiers = [] as Array[Pasture3DNode]


# --- E. The FILTER path: an Input node reads the incoming surface; the output composites over it --------
func _e_filter_reads_surface() -> void:
	print("[E] Input -> Blend(ADD) <- Const composites over the incoming surface")
	var c := 3.0
	var amount := 0.5
	# graph: 0 Input, 1 Const(c), 2 Blend(ADD)[a=Input,b=Const], 3 Output.
	var g := Pasture3DTerrainGraph.new()
	var typed: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), _const_node(c),
		_blend_add(), Pasture3DGraphNodeOutput.new()]
	g.nodes = typed
	g.connections = [PackedInt32Array([0, 0, 2, 0]), PackedInt32Array([1, 0, 2, 1]),
			PackedInt32Array([2, 0, 3, 0])]
	# A non-zero incoming surface fed through amp (add mode: the working surface IS amp here).
	var surf := PackedFloat64Array(); surf.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			surf[iz * GW + ix] = 2.0 + 0.1 * ix - 0.05 * iz
	var got := _run_amp([_step(_graph_node(g, amount))], _const_grid(1.0), surf)

	# Oracle: over surface z, output = z + c, so composited = z + (c)*amount*profile = surface + c*amount.
	var worst := 0.0
	for i in range(GW * GH):
		worst = maxf(worst, absf(got[i] - (surf[i] + c * amount)))
	print("    max |mounted - (surface + c*amount)| = %.6f m (want < %.6f)" % [worst, EPS])
	if worst > EPS:
		_fail += 1; print("    !! the graph did not read the incoming surface (Input) and add over it")

	# CONTROL: a graph that IGNORES the input (Const -> Output, no Input) does NOT reproduce the surface —
	# it replaces toward the constant, proving [E]'s match came from actually reading the surface.
	var gen := Pasture3DTerrainGraph.new()
	var gtyped: Array[Pasture3DGraphNode] = [_const_node(c), Pasture3DGraphNodeOutput.new()]
	gen.nodes = gtyped
	gen.connections = [PackedInt32Array([0, 0, 1, 0])]
	var got2 := _run_amp([_step(_graph_node(gen, amount))], _const_grid(1.0), surf)
	var diff := 0.0
	for i in range(GW * GH):
		diff = maxf(diff, absf(got2[i] - (surf[i] + c * amount)))
	print("    control: a no-Input graph differs from surface+c*amount by %.3f (want > 0.05)" % diff)
	if diff <= 0.05:
		_fail += 1; print("    !! control dead: the Input node was not what read the surface")


# ---- helpers ----------------------------------------------------------------------------------------

func _run(p_steps: Array, p_profile: PackedFloat64Array) -> PackedFloat32Array:
	# A zero incoming surface: the graph's output composites over flat ground.
	return _run_amp(p_steps, p_profile, _zeros64(GW * GH))


## Like _run but with an explicit incoming contribution (the working surface under add mode).
func _run_amp(p_steps: Array, p_profile: PackedFloat64Array, p_amp: PackedFloat64Array) -> PackedFloat32Array:
	var n := GW * GH
	var amp := p_amp.duplicate()
	var basey := PackedFloat32Array(); basey.resize(n)  # 0 -> under add the surface is amp itself
	var ctx := {"gw": GW, "gh": GH, "vs": VS, "min_x": X0, "min_z": Z0, "add": true}
	return _brush._run_modifier_stack(p_steps, amp, p_profile, basey, ctx)


func _zeros64(p_n: int) -> PackedFloat64Array:
	var a := PackedFloat64Array(); a.resize(p_n)
	return a


func _const_node(p_v: float) -> Pasture3DGraphNodeConst:
	var n := Pasture3DGraphNodeConst.new(); n.value = p_v
	return n


func _blend_add() -> Pasture3DGraphNodeBlend:
	var n := Pasture3DGraphNodeBlend.new(); n.mode = Pasture3DGraphNodeBlend.Mode.ADD
	return n


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
