# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphErosionNodeGate — the graph-native stream-power SOLVER (Erosion) and its multi-output channels
# (PASTURE3D_TERRAIN_GRAPH_SPEC.md, Solvers).
#
# Needs the freshly built DLL: the node reaches the native erosion_solve through the new
# Pasture3DUtil.erosion_solve_grid binding, so the gate fails loudly with a "DLL is stale" line if the
# extension was not rebuilt. The native solver is the SAME one the brush erosion modifier and Pasture3DSim
# run and is already covered by the SimPhase gates, so THIS gate does not re-derive stream power — it tests
# the graph plumbing around it:
#   [A] Erosion declares five outputs (height HEIGHT + flow/erosion/deposition/wetness MASK), role SOLVER.
#   [B] A solve actually erodes a real surface (some erosion channel > 0, height moves). Control: with both
#       Erosion Rate and Hillslope Diffusion at 0 the height is unchanged — the solver routed water and cut
#       nothing.
#   [C] Channel consistency, the plumbing the C++ binding does: erosion == max(-(z-z0),0) and
#       deposition == max(z-z0,0) cell-for-cell, and every cell's flow >= one cell's area (it drains
#       itself). Control: erosion and deposition are never both positive in the same cell.
#   [D] Per-solver freeze (FROZEN is the default here): serves the cached solve against a changed surface
#       and reports stale; Bake re-solves. Control: LIVE re-solves immediately and never goes stale.
#   [E] NaN in the surface passes through as NaN height / 0 in every channel. Control: finite elsewhere.
#   [F] Multi-output routing: the "erosion" channel (port 2) drives a Blend's mask input and gates it.
#       Control: unwiring the mask leaves the plain blend (mask == 1).
#
# Every criterion measures a concrete delta and carries a control that must fail if the path is dead.
extends Node

const ErosionScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_erosion.gd")

const GW := 32
const GH := 24
const RECT := Rect2(-32.0, -24.0, 64.0, 48.0)
const ITERS := 8
const EPS := 1.0e-4

var _fail := 0


func _ready() -> void:
	print("=== GraphErosionNodeGate: graph-native Erosion solver + multi-output channels ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "erosion_solve_grid"):
		print("    !! DLL is stale: Pasture3DUtil.erosion_solve_grid is not bound. Rebuild the extension.")
		print("\n=== GRAPH EROSION NODE FAIL (1 failures) ===\n")
		get_tree().quit(1)
		return
	_a_declares_five_outputs()
	_b_solve_erodes()
	_c_channel_consistency()
	_d_per_solver_freeze()
	_e_nan_boundary()
	_f_multi_output_mask_routing()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH EROSION NODE PASS" if _fail == 0 else "GRAPH EROSION NODE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---- test surface: a Gaussian mound on a gently tilted plane, so water routes off it and cuts ---------

func _mound_surface() -> PackedFloat32Array:
	var g := PackedFloat32Array(); g.resize(GW * GH)
	var cx := RECT.position.x + RECT.size.x * 0.5
	var cz := RECT.position.y + RECT.size.y * 0.5
	for iz in range(GH):
		for ix in range(GW):
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			var d2 := (w.x - cx) * (w.x - cx) + (w.y - cz) * (w.y - cz)
			# 40 m mound + a slight tilt so the network has a downhill preference, not a symmetric standoff.
			g[iz * GW + ix] = 40.0 * exp(-d2 / 300.0) + 0.02 * w.x
	return g


func _new_erosion(p_eval) -> Pasture3DGraphNodeErosion:
	var e := Pasture3DGraphNodeErosion.new()
	e.iterations = ITERS
	e.evaluation = p_eval
	return e


# ---- [A] --------------------------------------------------------------------------------------------

func _a_declares_five_outputs() -> void:
	print("[A] Erosion declares five outputs (height + flow/erosion/deposition/wetness), role SOLVER")
	var e := _new_erosion(ErosionScript.Evaluation.LIVE)
	var types: PackedInt32Array = e.output_port_types()
	var names: PackedStringArray = e.output_names()
	var in_types: PackedInt32Array = e.input_port_types()
	var ok: bool = e.output_count() == 5 and names.size() == 5 and types.size() == 5 \
			and types[0] == Pasture3DGraphNode.PortType.HEIGHT \
			and types[1] == Pasture3DGraphNode.PortType.MASK \
			and types[4] == Pasture3DGraphNode.PortType.MASK \
			and e.role() == Pasture3DGraphNode.Role.SOLVER and e.needs_grid() \
			and in_types.size() == e.input_count() and e.input_names().size() == e.input_count() \
			and in_types.size() > 0 and in_types[0] == Pasture3DGraphNode.PortType.HEIGHT \
			and _param_ports(in_types) == e.input_count() - 1
	# One SURFACE input, at port 0. The node later grew INT/FLOAT parameter sockets, so `input_count() == 1`
	# stopped being the way to say that; every port after the surface must be a scalar parameter.
	print("    output_count=%d names=%s types=%s role=%d needs_grid=%s input_count=%d in_types=%s" % [
		e.output_count(), names, types, e.role(), e.needs_grid(), e.input_count(), in_types])
	if not ok:
		_fail += 1; print("    !! Erosion did not declare [HEIGHT, MASK*4] outputs as a grid SOLVER")


# ---- [B] --------------------------------------------------------------------------------------------

func _b_solve_erodes() -> void:
	print("[B] A solve erodes the surface (some cut, height moves)")
	var surface := _mound_surface()
	var e := _new_erosion(ErosionScript.Evaluation.LIVE)
	e.erosion_rate = 0.08
	e.hillslope_diffusion = 0.15
	var ch: Array = e.eval_grid_channels([surface], GW, GH, null, RECT)
	var height: PackedFloat32Array = ch[0]
	var ero: PackedFloat32Array = ch[2]
	var max_cut := 0.0
	var max_hmove := 0.0
	for i in range(GW * GH):
		max_cut = maxf(max_cut, ero[i])
		if is_finite(height[i]) and is_finite(surface[i]):
			max_hmove = maxf(max_hmove, absf(height[i] - surface[i]))
	print("    max erosion cut = %f m, max |height - input| = %f m" % [max_cut, max_hmove])
	if max_cut <= EPS or max_hmove <= EPS:
		_fail += 1; print("    !! the solve changed nothing (dead path)")

	# CONTROL: rate 0 AND diffusion 0 -> water routes, nothing is removed -> height == input.
	var e0 := _new_erosion(ErosionScript.Evaluation.LIVE)
	e0.erosion_rate = 0.0
	e0.hillslope_diffusion = 0.0
	var ch0: Array = e0.eval_grid_channels([surface], GW, GH, null, RECT)
	var h0: PackedFloat32Array = ch0[0]
	var cmax := 0.0
	for i in range(GW * GH):
		if is_finite(h0[i]) and is_finite(surface[i]):
			cmax = maxf(cmax, absf(h0[i] - surface[i]))
	print("    control: rate=0, diffusion=0 -> max |height - input| = %f m (want ~0)" % cmax)
	if cmax > EPS:
		_fail += 1; print("    !! a zero-rate, zero-diffusion solve altered the surface")


# ---- [C] --------------------------------------------------------------------------------------------

func _c_channel_consistency() -> void:
	print("[C] Channels are consistent with the height delta (the binding's plumbing)")
	var surface := _mound_surface()
	var e := _new_erosion(ErosionScript.Evaluation.LIVE)
	e.erosion_rate = 0.1
	e.deposition = 0.5 # let it lay some material back down, so deposition is exercised too
	var ch: Array = e.eval_grid_channels([surface], GW, GH, null, RECT)
	var height: PackedFloat32Array = ch[0]
	var flow: PackedFloat32Array = ch[1]
	var ero: PackedFloat32Array = ch[2]
	var dep: PackedFloat32Array = ch[3]
	var dx := RECT.size.x / float(GW)
	var dz := RECT.size.y / float(GH)
	var cell_area := dx * dz
	var max_ero_err := 0.0
	var max_dep_err := 0.0
	var min_flow := INF
	var both_positive := 0
	for i in range(GW * GH):
		if not is_finite(height[i]) or not is_finite(surface[i]):
			continue
		var d := height[i] - surface[i]
		max_ero_err = maxf(max_ero_err, absf(ero[i] - maxf(-d, 0.0)))
		max_dep_err = maxf(max_dep_err, absf(dep[i] - maxf(d, 0.0)))
		min_flow = minf(min_flow, flow[i])
		if ero[i] > EPS and dep[i] > EPS:
			both_positive += 1
	print("    max |ero - max(-d,0)| = %f, max |dep - max(d,0)| = %f" % [max_ero_err, max_dep_err])
	print("    min flow = %f m^2 (one cell area = %f), cells with ero&dep both>0 = %d" % [min_flow, cell_area, both_positive])
	if max_ero_err > EPS or max_dep_err > EPS:
		_fail += 1; print("    !! erosion/deposition channels disagree with the height delta")
	if min_flow < cell_area - 1.0e-2:
		_fail += 1; print("    !! a cell drains less than its own area (flow floor broken)")
	# CONTROL: a cell is either cutting or filling, never both at once.
	if both_positive != 0:
		_fail += 1; print("    !! a cell reported positive erosion AND deposition simultaneously")


# ---- [D] --------------------------------------------------------------------------------------------

func _d_per_solver_freeze() -> void:
	print("[D] Per-solver freeze: FROZEN serves the cache and reports stale; Bake re-solves")
	var e := Pasture3DGraphNodeErosion.new()
	e.iterations = ITERS
	e.erosion_rate = 0.1
	print("    default evaluation is FROZEN=%s" % (e.evaluation == ErosionScript.Evaluation.FROZEN))
	if e.evaluation != ErosionScript.Evaluation.FROZEN:
		_fail += 1; print("    !! Erosion did not default to FROZEN")

	var g := Pasture3DTerrainGraph.new()
	var inp := g.add_node(Pasture3DGraphNodeRegistry.create(&"input"), Vector2.ZERO)
	var er := g.add_node(e, Vector2(200, 0))
	var out := g.add_node(Pasture3DGraphNodeRegistry.create(&"output"), Vector2(400, 0))
	g.connect_ports(inp, 0, er, 0)
	g.connect_ports(er, 0, out, 0)

	var surf_a := _mound_surface()
	var r1 := g.evaluate(GW, GH, RECT, null, surf_a)      # first solve -> caches
	# Staleness is the `_stale` flag itself, not warning-count: node_warnings() also carries a benign
	# "holds N MB of frozen solve" notice whenever FROZEN with a cache, so counting warnings would report
	# stale even when it is not.
	var stale_after_first: bool = e._stale

	var surf_b := PackedFloat32Array(); surf_b.resize(GW * GH) # flat 0 -> nothing to erode
	var r2 := g.evaluate(GW, GH, RECT, null, surf_b)
	var served_cache := _max_abs_diff(r1, r2) < 1.0e-5
	var went_stale: bool = e._stale
	print("    frozen: stale after fresh solve=%s, changed surface served cache=%s, stale=%s" % [stale_after_first, served_cache, went_stale])
	if stale_after_first:
		_fail += 1; print("    !! FROZEN reported stale on its own fresh solve")
	if not served_cache:
		_fail += 1; print("    !! FROZEN did not serve the cached solve against a changed surface")
	if not went_stale:
		_fail += 1; print("    !! FROZEN did not report itself stale after the surface changed")

	# Bake -> re-solve over flat B -> height is the flat surface, differs from the eroded mound A.
	e.clear_cache()
	var r3 := g.evaluate(GW, GH, RECT, null, surf_b)
	var resolved := _max_abs_diff(r1, r3) > EPS
	print("    after Bake over flat surface: differs from A=%s, stale cleared=%s" % [resolved, not e._stale])
	if not resolved:
		_fail += 1; print("    !! Bake did not re-solve for the new surface")
	if e._stale:
		_fail += 1; print("    !! Bake did not clear the stale flag")

	# CONTROL: LIVE tracks the surface immediately and never goes stale.
	e.evaluation = ErosionScript.Evaluation.LIVE
	e.clear_cache()
	var live_a := g.evaluate(GW, GH, RECT, null, surf_a)
	var live_b := g.evaluate(GW, GH, RECT, null, surf_b)
	var live_ok := _max_abs_diff(live_a, live_b) > EPS and not e._stale
	print("    control: LIVE A vs B differ=%s, no stale=%s" % [_max_abs_diff(live_a, live_b) > EPS, not e._stale])
	if not live_ok:
		_fail += 1; print("    !! LIVE did not track the surface / falsely went stale")


# ---- [E] --------------------------------------------------------------------------------------------

func _e_nan_boundary() -> void:
	print("[E] NaN in the surface passes through as NaN height / 0 channels")
	var surface := _mound_surface()
	var hole := 0
	surface[hole] = NAN
	var e := _new_erosion(ErosionScript.Evaluation.LIVE)
	e.erosion_rate = 0.1
	var ch: Array = e.eval_grid_channels([surface], GW, GH, null, RECT)
	var height: PackedFloat32Array = ch[0]
	var ero: PackedFloat32Array = ch[2]
	var finite_somewhere := false
	for i in range(GW * GH):
		if i != hole and is_finite(height[i]):
			finite_somewhere = true
	var chan_zero := absf(ch[1][hole]) < EPS and absf(ero[hole]) < EPS and absf(ch[3][hole]) < EPS and absf(ch[4][hole]) < EPS
	print("    NaN cell -> height is_nan=%s, channels zero=%s; finite elsewhere=%s" % [is_nan(height[hole]), chan_zero, finite_somewhere])
	if not is_nan(height[hole]):
		_fail += 1; print("    !! NaN surface cell did not pass through as NaN height")
	if not chan_zero:
		_fail += 1; print("    !! NaN cell's channels were not zeroed")
	if not finite_somewhere:
		_fail += 1; print("    !! whole field went non-finite (NaN leaked)")


# ---- [F] --------------------------------------------------------------------------------------------

func _f_multi_output_mask_routing() -> void:
	print("[F] The erosion channel (port 2) drives a Blend's mask input")
	var g := Pasture3DTerrainGraph.new()
	var inp := g.add_node(Pasture3DGraphNodeRegistry.create(&"input"), Vector2.ZERO)
	var er_node := _new_erosion(ErosionScript.Evaluation.LIVE)
	er_node.erosion_rate = 0.12
	var er := g.add_node(er_node, Vector2(200, 0))
	var ca = Pasture3DGraphNodeRegistry.create(&"const"); ca.set("value", 0.0)
	var cb = Pasture3DGraphNodeRegistry.create(&"const"); cb.set("value", 1.0)
	var na := g.add_node(ca, Vector2(0, 200))
	var nb := g.add_node(cb, Vector2(0, 300))
	var blend = Pasture3DGraphNodeRegistry.create(&"blend"); blend.set("mode", 0) # ADD
	var nbl := g.add_node(blend, Vector2(400, 100))
	var out := g.add_node(Pasture3DGraphNodeRegistry.create(&"output"), Vector2(600, 100))
	g.connect_ports(inp, 0, er, 0)
	g.connect_ports(na, 0, nbl, 0)         # a = 0
	g.connect_ports(nb, 0, nbl, 1)         # b = 1
	g.connect_ports(er, 2, nbl, 2)         # mask = Erosion.erosion (port 2) -> Blend mask (port 2)
	g.connect_ports(nbl, 0, out, 0)

	var surface := _mound_surface()
	var got := g.evaluate(GW, GH, RECT, null, surface)
	# Independent channel from an identical LIVE solve (deterministic): output = 0 + 1*clamp(erosion,0,1).
	var solo = _new_erosion(ErosionScript.Evaluation.LIVE)
	solo.erosion_rate = 0.12
	var solo_ch: Array = solo.eval_grid_channels([surface], GW, GH, null, RECT)
	var ero: PackedFloat32Array = solo_ch[2]
	var max_d := 0.0
	var gated_somewhere := false
	for i in range(GW * GH):
		var want := clampf(ero[i], 0.0, 1.0)
		max_d = maxf(max_d, absf(got[i] - want))
		if ero[i] > EPS:
			gated_somewhere = true
	print("    max |blend - clamp(erosion)| = %f (want ~0), erosion channel non-zero somewhere=%s" % [max_d, gated_somewhere])
	if max_d > EPS:
		_fail += 1; print("    !! the erosion channel did not gate the blend correctly")
	if not gated_somewhere:
		_fail += 1; print("    !! erosion channel was zero everywhere (routing not exercised)")

	# CONTROL: unwire the mask -> unwired default 1.0 -> plain blend = 1 everywhere.
	g.disconnect_ports(er, 2, nbl, 2)
	var got2 := g.evaluate(GW, GH, RECT, null, surface)
	var cmax := 0.0
	for i in range(GW * GH):
		cmax = maxf(cmax, absf(got2[i] - 1.0))
	print("    control: mask unwired -> blend max dev from 1.0 = %f" % cmax)
	if cmax > EPS:
		_fail += 1; print("    !! unwired mask was not treated as full strength (1.0)")


# ---- helpers ----------------------------------------------------------------------------------------

func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var d := 0.0
	for i in range(mini(p_a.size(), p_b.size())):
		var av := p_a[i]; var bv := p_b[i]
		if is_nan(av) or is_nan(bv):
			continue
		d = maxf(d, absf(av - bv))
	return d


## How many of these ports are scalar parameter sockets rather than field inputs.
func _param_ports(p_types: PackedInt32Array) -> int:
	var c := 0
	for t in p_types:
		if t == Pasture3DGraphNode.PortType.FLOAT or t == Pasture3DGraphNode.PortType.INT:
			c += 1
	return c
