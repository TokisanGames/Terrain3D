# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphDLANodeGate — the graph-native DLA mountain SOLVER (PASTURE3D_TERRAIN_GRAPH_SPEC.md, Solvers).
#
# Pure GDScript on the graph model + the Pasture3DReliefDLA growth engine (no DLL, no terrain). The node
# COMPOSES the relief DLA and drives its `grow_into` hook, so this gate does NOT re-derive the growth (which
# has its own long-standing DLAGate); it tests the graph adapter around it and the structural invariants a
# DLA massif must keep — the failure modes the growth's history records (empty, hollow/crater, cut off at
# the loop edge):
#   [A] DLA declares two outputs (height HEIGHT + footprint MASK), role SOLVER, one seed input.
#   [B] It grows a real massif: peak > 0 and INTERIOR (not a hollow ring), zero at the rect corners (outside
#       the coverage envelope — not cut off at the edge), height == amplitude·mask, and the growth is
#       deterministic (same seed → identical field). Control: amplitude scales the height and leaves the mask.
#   [C] Ridge Seeding uses the wired input: a ridged input with seeding ON grows a DIFFERENT field than the
#       central-seed one. Control: seeding ON with a FLAT (unwired) input falls back to the central seed, so
#       its field equals the seeding-OFF field.
#   [D] Per-solver freeze (FROZEN is the default): serves the cached mountain after a param change and
#       reports stale; Bake regrows. Control: LIVE regrows immediately and never goes stale.
#   [E] Multi-output routing: the footprint MASK (port 1) drives a Blend's mask input through the evaluator.
#       Control: unwiring the mask leaves the plain blend (mask == 1).
#
# Every criterion measures a concrete delta and carries a control that must fail if the path is dead.
extends Node

const DLAScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dla.gd")

const GW := 48
const GH := 48
const RECT := Rect2(-100.0, -100.0, 200.0, 200.0) # square so the massif and the seed frame are isotropic
const EPS := 1.0e-4

var _fail := 0


func _ready() -> void:
	print("=== GraphDLANodeGate: graph-native DLA mountain solver ===\n")
	_a_declares_two_outputs()
	_b_grows_a_massif()
	_c_ridge_seeding_uses_input()
	_d_per_solver_freeze()
	_e_multi_output_mask_routing()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH DLA NODE PASS" if _fail == 0 else "GRAPH DLA NODE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# A small, fast massif: 64² working grid, 3 hierarchy rounds — grows in well under a second.
func _new_dla(p_eval) -> Pasture3DGraphNodeDLA:
	var d := Pasture3DGraphNodeDLA.new()
	d.resolution = 64
	d.hierarchy_levels = 3
	d.blur_levels = 4
	d.coverage = 0.9
	d.amplitude = 100.0
	d.evaluation = p_eval
	return d


# A ridged input surface: three sinusoidal crest lines, so ridge seeding has something to find.
func _ridged_surface() -> PackedFloat32Array:
	var g := PackedFloat32Array(); g.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			var u := float(ix) / float(GW - 1)
			g[iz * GW + ix] = 20.0 * absf(sin(u * TAU * 1.5))
	return g


# ---- [A] --------------------------------------------------------------------------------------------

func _a_declares_two_outputs() -> void:
	print("[A] DLA declares two outputs (height + footprint mask), role SOLVER, one seed input")
	var d := _new_dla(DLAScript.Evaluation.LIVE)
	var types: PackedInt32Array = d.output_port_types()
	var in_types: PackedInt32Array = d.input_port_types()
	var ok: bool = d.output_count() == 2 and d.output_names().size() == 2 and types.size() == 2 \
			and types[0] == Pasture3DGraphNode.PortType.HEIGHT and types[1] == Pasture3DGraphNode.PortType.MASK \
			and d.role() == Pasture3DGraphNode.Role.SOLVER and d.needs_grid() \
			and in_types.size() == d.input_count() and d.input_names().size() == d.input_count() \
			and in_types.size() > 0 and in_types[0] == Pasture3DGraphNode.PortType.HEIGHT \
			and _param_ports(in_types) == d.input_count() - 1
	# One SEED input, at port 0. The node later grew FLOAT parameter sockets, so `input_count() == 1` stopped
	# being the way to say that; every port after the seed must be a scalar parameter, and the three port
	# arrays must agree on how many ports there are.
	print("    output_count=%d names=%s types=%s role=%d needs_grid=%s input_count=%d in_types=%s" % [
		d.output_count(), d.output_names(), types, d.role(), d.needs_grid(), d.input_count(), in_types])
	if not ok:
		_fail += 1; print("    !! DLA did not declare [HEIGHT, MASK] outputs as a grid SOLVER with one input")


# ---- [B] --------------------------------------------------------------------------------------------

func _b_grows_a_massif() -> void:
	print("[B] Grows a real massif: interior peak, zero at the corners, height == amplitude*mask, deterministic")
	var d := _new_dla(DLAScript.Evaluation.LIVE)
	var flat := PackedFloat32Array(); flat.resize(GW * GH) # unwired -> central seed
	var ch: Array = d.eval_grid_channels([flat], GW, GH, null, RECT)
	var height: PackedFloat32Array = ch[0]
	var mask: PackedFloat32Array = ch[1]

	# peak and its location
	var peak := 0.0
	var peak_i := 0
	var max_amp_err := 0.0
	for i in range(GW * GH):
		if height[i] > peak:
			peak = height[i]; peak_i = i
		max_amp_err = maxf(max_amp_err, absf(height[i] - 100.0 * mask[i]))
	var px := peak_i % GW
	var pz := peak_i / GW
	# distance of the peak from the rect centre, as a fraction of the half-extent
	var peak_r := sqrt(pow((float(px) + 0.5) / float(GW) * 2.0 - 1.0, 2.0) + pow((float(pz) + 0.5) / float(GH) * 2.0 - 1.0, 2.0))
	# corners of the rect are outside the coverage envelope -> must be zero
	var corner_max := maxf(maxf(height[0], height[GW - 1]), maxf(height[(GH - 1) * GW], height[GH * GW - 1]))
	print("    peak=%.3f m at fractional radius %.2f (want interior <0.6), max corner=%.4f (want ~0)" % [peak, peak_r, corner_max])
	print("    max |height - amplitude*mask| = %.6f" % max_amp_err)
	if peak <= EPS:
		_fail += 1; print("    !! DLA grew nothing (empty field)")
	if peak_r > 0.6:
		_fail += 1; print("    !! the peak sits near the rim — a hollow/ring massif, not a mountain")
	if corner_max > EPS:
		_fail += 1; print("    !! the massif is non-zero at the corners — cut off at the loop edge")
	if max_amp_err > EPS:
		_fail += 1; print("    !! height is not amplitude*mask (plumbing broken)")

	# determinism: same seed -> identical field
	var d2 := _new_dla(DLAScript.Evaluation.LIVE)
	var ch2: Array = d2.eval_grid_channels([flat], GW, GH, null, RECT)
	var det := _max_abs_diff(height, ch2[0])
	print("    determinism: two grows of the same seed differ by %.6f (want 0)" % det)
	if det > 0.0:
		_fail += 1; print("    !! DLA growth is not deterministic for a fixed seed")

	# CONTROL: doubling amplitude scales the height x2 and leaves the mask.
	d.amplitude = 200.0
	var ch3: Array = d.eval_grid_channels([flat], GW, GH, null, RECT)
	var h3: PackedFloat32Array = ch3[0]
	var m3: PackedFloat32Array = ch3[1]
	var mask_moved := _max_abs_diff(mask, m3)
	var scaled := true
	for i in range(GW * GH):
		if absf(h3[i] - 2.0 * height[i]) > 1.0e-3:
			scaled = false; break
	print("    control: amplitude 100->200 scaled height x2=%s, mask unchanged (dev %.6f)" % [scaled, mask_moved])
	if not scaled:
		_fail += 1; print("    !! amplitude did not scale the height linearly")
	if mask_moved > EPS:
		_fail += 1; print("    !! amplitude moved the mask (it must be amplitude-independent)")


# ---- [C] --------------------------------------------------------------------------------------------

func _c_ridge_seeding_uses_input() -> void:
	print("[C] Ridge Seeding grows out of the wired input's ridges")
	var surface := _ridged_surface()

	var off := _new_dla(DLAScript.Evaluation.LIVE)
	off.ridge_seeding = false
	var field_off: PackedFloat32Array = off.eval_grid_channels([surface], GW, GH, null, RECT)[1]

	var on := _new_dla(DLAScript.Evaluation.LIVE)
	on.ridge_seeding = true
	on.ridge_amount = 0.1
	var field_on: PackedFloat32Array = on.eval_grid_channels([surface], GW, GH, null, RECT)[1]

	var seeded_delta := _max_abs_diff(field_off, field_on)
	print("    seeding OFF vs ON over a ridged input differ by %.4f (want > 0)" % seeded_delta)
	if seeded_delta <= EPS:
		_fail += 1; print("    !! ridge seeding did not change the grown field (input ignored)")

	# CONTROL: seeding ON but a FLAT (unwired) input -> falls back to the central seed -> equals OFF.
	var flat := PackedFloat32Array(); flat.resize(GW * GH)
	var on_flat := _new_dla(DLAScript.Evaluation.LIVE)
	on_flat.ridge_seeding = true
	var field_on_flat: PackedFloat32Array = on_flat.eval_grid_channels([flat], GW, GH, null, RECT)[1]
	var off_flat := _new_dla(DLAScript.Evaluation.LIVE)
	var field_off_flat: PackedFloat32Array = off_flat.eval_grid_channels([flat], GW, GH, null, RECT)[1]
	var fallback_delta := _max_abs_diff(field_on_flat, field_off_flat)
	print("    control: seeding ON with a flat input falls back to central seed (delta %.6f, want 0)" % fallback_delta)
	if fallback_delta > EPS:
		_fail += 1; print("    !! a flat input did not fall back to the central seed")


# ---- [D] --------------------------------------------------------------------------------------------

func _d_per_solver_freeze() -> void:
	print("[D] Per-solver freeze: FROZEN serves the cached mountain and reports stale; Bake regrows")
	var d := _new_dla(DLAScript.Evaluation.FROZEN)
	print("    default evaluation is FROZEN=%s" % (Pasture3DGraphNodeDLA.new().evaluation == DLAScript.Evaluation.FROZEN))
	if Pasture3DGraphNodeDLA.new().evaluation != DLAScript.Evaluation.FROZEN:
		_fail += 1; print("    !! DLA did not default to FROZEN")

	var flat := PackedFloat32Array(); flat.resize(GW * GH)
	var ch1: Array = d.eval_grid_channels([flat], GW, GH, null, RECT) # solve -> caches
	var stale_after_first: bool = d._stale
	# Change a growth param while FROZEN: must serve the cache and go stale WITHOUT regrowing.
	d.seed = 999
	var ch2: Array = d.eval_grid_channels([flat], GW, GH, null, RECT)
	var served := _max_abs_diff(ch1[0], ch2[0]) < 1.0e-6
	print("    frozen: stale after fresh solve=%s, after seed change served cache=%s, stale=%s" % [stale_after_first, served, d._stale])
	if stale_after_first:
		_fail += 1; print("    !! FROZEN reported stale on its own fresh solve")
	if not served:
		_fail += 1; print("    !! FROZEN regrew instead of serving the cache after a param change")
	if not d._stale:
		_fail += 1; print("    !! FROZEN did not report itself stale after a param change")

	# Bake -> regrow with the new seed -> differs from the cached mountain.
	d.clear_cache()
	var ch3: Array = d.eval_grid_channels([flat], GW, GH, null, RECT)
	var regrew := _max_abs_diff(ch1[0], ch3[0]) > EPS
	print("    after Bake with the new seed: differs from cache=%s, stale cleared=%s" % [regrew, not d._stale])
	if not regrew:
		_fail += 1; print("    !! Bake did not regrow for the new seed")
	if d._stale:
		_fail += 1; print("    !! Bake did not clear the stale flag")

	# CONTROL: LIVE regrows immediately on a seed change and never goes stale.
	var live := _new_dla(DLAScript.Evaluation.LIVE)
	var la: Array = live.eval_grid_channels([flat], GW, GH, null, RECT)
	live.seed = 111
	var lb: Array = live.eval_grid_channels([flat], GW, GH, null, RECT)
	var live_ok := _max_abs_diff(la[0], lb[0]) > EPS and not live._stale
	print("    control: LIVE seed 0 vs 111 differ=%s, no stale=%s" % [_max_abs_diff(la[0], lb[0]) > EPS, not live._stale])
	if not live_ok:
		_fail += 1; print("    !! LIVE did not regrow on a param change / falsely went stale")


# ---- [E] --------------------------------------------------------------------------------------------

func _e_multi_output_mask_routing() -> void:
	print("[E] The footprint MASK (port 1) drives a Blend's mask input")
	var g := Pasture3DTerrainGraph.new()
	var inp := g.add_node(Pasture3DGraphNodeRegistry.create(&"input"), Vector2.ZERO)
	var dla_node := _new_dla(DLAScript.Evaluation.LIVE)
	var dn := g.add_node(dla_node, Vector2(200, 0))
	var ca = Pasture3DGraphNodeRegistry.create(&"const"); ca.set("value", 0.0)
	var cb = Pasture3DGraphNodeRegistry.create(&"const"); cb.set("value", 1.0)
	var na := g.add_node(ca, Vector2(0, 200))
	var nb := g.add_node(cb, Vector2(0, 300))
	var blend = Pasture3DGraphNodeRegistry.create(&"blend"); blend.set("mode", 0) # ADD
	var nbl := g.add_node(blend, Vector2(400, 100))
	var out := g.add_node(Pasture3DGraphNodeRegistry.create(&"output"), Vector2(600, 100))
	g.connect_ports(inp, 0, dn, 0)
	g.connect_ports(na, 0, nbl, 0)         # a = 0
	g.connect_ports(nb, 0, nbl, 1)         # b = 1
	g.connect_ports(dn, 1, nbl, 2)         # mask = DLA.mask (port 1) -> Blend mask (port 2)
	g.connect_ports(nbl, 0, out, 0)

	var flat := PackedFloat32Array(); flat.resize(GW * GH)
	var got := g.evaluate(GW, GH, RECT, null, flat)
	# Independent mask from an identical LIVE solve (deterministic): output = 0 + 1*clamp(mask,0,1) = mask.
	var solo := _new_dla(DLAScript.Evaluation.LIVE)
	var mask: PackedFloat32Array = solo.eval_grid_channels([flat], GW, GH, null, RECT)[1]
	var max_d := 0.0
	var gated := false
	for i in range(GW * GH):
		max_d = maxf(max_d, absf(got[i] - clampf(mask[i], 0.0, 1.0)))
		if mask[i] > 0.01 and mask[i] < 0.99:
			gated = true
	print("    max |blend - clamp(mask)| = %.6f (want ~0), mask spans partial values=%s" % [max_d, gated])
	if max_d > EPS:
		_fail += 1; print("    !! the DLA mask channel did not gate the blend correctly")
	if not gated:
		_fail += 1; print("    !! mask never took a partial value (gate not exercised)")

	# CONTROL: unwire the mask -> unwired default 1.0 -> plain blend = 1 everywhere.
	g.disconnect_ports(dn, 1, nbl, 2)
	var got2 := g.evaluate(GW, GH, RECT, null, flat)
	var cmax := 0.0
	for i in range(GW * GH):
		cmax = maxf(cmax, absf(got2[i] - 1.0))
	print("    control: mask unwired -> blend max dev from 1.0 = %.6f" % cmax)
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
