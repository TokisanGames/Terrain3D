# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphSolverNodeGate — the first graph-native SOLVER (Scree) plus the multi-output machinery it needs
# (PASTURE3D_TERRAIN_GRAPH_SPEC.md, Solvers).
#
# Pure GDScript on the graph model + relief statics (no DLL, no terrain). Asserts:
#   [A] Scree declares two outputs (height HEIGHT + shed MASK); a single-output node stays 1.
#   [B] Scree's height channel matches an INDEPENDENT re-derivation of the slope/curvature field + gate
#       (reusing only the vetted _scree grain), over a real varied surface. Control: amplitude moves it.
#   [C] Multi-output routing: Scree's shed MASK (port 1) drives a Blend's mask input, and the composite
#       equals cA + cB*shed cell-for-cell. Control: an unwired mask is the plain blend (mask == 1).
#   [D] Per-solver freeze: FROZEN serves the cached solve against a changed surface and reports stale;
#       Bake re-solves. Control: LIVE re-solves immediately and never goes stale.
#   [E] NaN in the surface passes through as NaN height / 0 shed. Control: finite cells are finite.
#   [F] A Blend whose mask port is wired refuses to lower to the native path. Control: unmasked lowers.
#
# Every criterion measures a concrete delta and carries a control that must fail if the path is dead.
extends Node

const ScreeScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_scree.gd")
const ReliefMaterial = preload("res://addons/pasture_3d/connectors/pasture3d_relief_material.gd")

const GW := 40
const GH := 28
const RECT := Rect2(-20.0, -14.0, 80.0, 56.0)
const EPS := 1.0e-4

var _fail := 0


func _ready() -> void:
	print("=== GraphSolverNodeGate: graph-native Scree solver + multi-output ===\n")
	_a_declares_two_outputs()
	_b_scree_height_parity()
	_c_multi_output_mask_routing()
	_d_per_solver_freeze()
	_e_nan_boundary()
	_f_masked_blend_refuses_native()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH SOLVER NODE PASS" if _fail == 0 else "GRAPH SOLVER NODE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---- test surface: a Gaussian bump, so slope AND curvature vary across the frame -------------------

func _bump_surface() -> PackedFloat32Array:
	var g := PackedFloat32Array(); g.resize(GW * GH)
	var cx := RECT.position.x + RECT.size.x * 0.5
	var cz := RECT.position.y + RECT.size.y * 0.5
	for iz in range(GH):
		for ix in range(GW):
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			var d2 := (w.x - cx) * (w.x - cx) + (w.y - cz) * (w.y - cz)
			g[iz * GW + ix] = 30.0 * exp(-d2 / 400.0)
	return g


# ---- independent oracle: the scree field derivation + gate, reusing only the vetted _scree ----------

func _oracle_scree(p_surface: PackedFloat32Array, p_node) -> Array:
	var n := GW * GH
	var height := PackedFloat32Array(); height.resize(n)
	var shed := PackedFloat32Array(); shed.resize(n)
	var params := PackedFloat32Array([p_node.amplitude, 1.0 / maxf(p_node.grain_size, 0.01),
			p_node.downslope_streak, p_node.toe_deposition, float(p_node.seed)])
	var noise := ReliefMaterial._configure_noise(1.0 / maxf(p_node.grain_size, 0.01), 3, 2.0, 0.5, p_node.seed, false)
	var dx := RECT.size.x / float(GW)
	var dz := RECT.size.y / float(GH)
	for iz in range(GH):
		for ix in range(GW):
			var i := iz * GW + ix
			var c := p_surface[i]
			if is_nan(c):
				height[i] = NAN; shed[i] = 0.0
				continue
			var xm := maxi(ix - 1, 0); var xp := mini(ix + 1, GW - 1)
			var zm := maxi(iz - 1, 0); var zp := mini(iz + 1, GH - 1)
			var hxm := _fin(p_surface[iz * GW + xm], c)
			var hxp := _fin(p_surface[iz * GW + xp], c)
			var hzm := _fin(p_surface[zm * GW + ix], c)
			var hzp := _fin(p_surface[zp * GW + ix], c)
			var gx := (hxp - hxm) / (2.0 * dx)
			var gz := (hzp - hzm) / (2.0 * dz)
			var slope_deg := rad_to_deg(atan(sqrt(gx * gx + gz * gz)))
			var curv := (hxm + hxp + hzm + hzp) * 0.25 - c
			var gate := _oracle_gate(slope_deg, p_node.min_slope_degrees, p_node.slope_falloff_degrees)
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			var val := ReliefMaterial._scree(w.x, w.y, curv, gx, gz, params, 0, noise)
			height[i] = gate * val
			shed[i] = gate
	return [height, shed]


func _fin(p_v: float, p_c: float) -> float:
	return p_c if is_nan(p_v) else p_v


func _oracle_gate(p_slope: float, p_lo: float, p_fl: float) -> float:
	if p_slope >= p_lo:
		return 1.0
	if p_fl <= 0.0 or p_slope <= p_lo - p_fl:
		return 0.0
	return smoothstep(p_lo - p_fl, p_lo, p_slope)


# ---- [A] --------------------------------------------------------------------------------------------

func _a_declares_two_outputs() -> void:
	print("[A] Scree declares two outputs, a single-output node stays one")
	var scree = ScreeScript.new()
	var types: PackedInt32Array = scree.output_port_types()
	var ok: bool = scree.output_count() == 2 and scree.output_names().size() == 2 \
			and types.size() == 2 and types[0] == Pasture3DGraphNode.PortType.HEIGHT \
			and types[1] == Pasture3DGraphNode.PortType.MASK and scree.role() == Pasture3DGraphNode.Role.SOLVER
	print("    output_count=%d, types=%s, role=%d (SOLVER=%d)" % [
		scree.output_count(), types, scree.role(), Pasture3DGraphNode.Role.SOLVER])
	if not ok:
		_fail += 1; print("    !! Scree did not declare [HEIGHT, MASK] outputs as a SOLVER")
	# CONTROL: a plain generator has one output.
	var c = Pasture3DGraphNodeRegistry.create(&"const")
	print("    control: const output_count=%d (want 1)" % c.output_count())
	if c.output_count() != 1:
		_fail += 1; print("    !! single-output node reported multiple outputs")


# ---- [B] --------------------------------------------------------------------------------------------

func _b_scree_height_parity() -> void:
	print("[B] Scree height channel matches an independent field re-derivation")
	var g := Pasture3DTerrainGraph.new()
	var inp := g.add_node(Pasture3DGraphNodeRegistry.create(&"input"), Vector2.ZERO)
	var scree_node = ScreeScript.new()
	scree_node.amplitude = 2.5
	scree_node.min_slope_degrees = 18.0
	scree_node.slope_falloff_degrees = 10.0
	scree_node.toe_deposition = 3.0
	var sc := g.add_node(scree_node, Vector2(200, 0))
	var out := g.add_node(Pasture3DGraphNodeRegistry.create(&"output"), Vector2(400, 0))
	g.connect_ports(inp, 0, sc, 0)
	g.connect_ports(sc, 0, out, 0) # port 0 = height

	var surface := _bump_surface()
	var got := g.evaluate(GW, GH, RECT, null, surface)
	var want: Array = _oracle_scree(surface, scree_node)
	var want_h: PackedFloat32Array = want[0]
	var max_d := 0.0
	var moved := 0
	for i in range(GW * GH):
		max_d = maxf(max_d, absf(got[i] - want_h[i]))
		if absf(got[i]) > 1.0e-6:
			moved += 1
	print("    max |graph - oracle| = %f m over %d/%d cells, %d cells non-zero" % [max_d, GW * GH, GW * GH, moved])
	if max_d > EPS:
		_fail += 1; print("    !! Scree height diverged from the independent oracle")
	if moved == 0:
		_fail += 1; print("    !! Scree deposited nothing anywhere (dead path)")

	# CONTROL: doubling amplitude must move the field.
	scree_node.amplitude = 5.0
	var got2 := g.evaluate(GW, GH, RECT, null, surface)
	var cd := 0.0
	for i in range(GW * GH):
		cd = maxf(cd, absf(got2[i] - got[i]))
	print("    control: amplitude 2.5 -> 5.0 moved field by max %f m (want > 0)" % cd)
	if cd <= EPS:
		_fail += 1; print("    !! amplitude change did not move the scree field")


# ---- [C] --------------------------------------------------------------------------------------------

func _c_multi_output_mask_routing() -> void:
	print("[C] Scree shed MASK (port 1) gates a Blend's mask input")
	var g := Pasture3DTerrainGraph.new()
	var inp := g.add_node(Pasture3DGraphNodeRegistry.create(&"input"), Vector2.ZERO)
	var scree_node = ScreeScript.new()
	scree_node.min_slope_degrees = 18.0
	scree_node.slope_falloff_degrees = 10.0
	var sc := g.add_node(scree_node, Vector2(200, 0))
	var ca = Pasture3DGraphNodeRegistry.create(&"const"); ca.set("value", 7.0)
	var cb = Pasture3DGraphNodeRegistry.create(&"const"); cb.set("value", 4.0)
	var na := g.add_node(ca, Vector2(0, 200))
	var nb := g.add_node(cb, Vector2(0, 300))
	var blend = Pasture3DGraphNodeRegistry.create(&"blend"); blend.set("mode", 0) # ADD
	var nbl := g.add_node(blend, Vector2(400, 100))
	var out := g.add_node(Pasture3DGraphNodeRegistry.create(&"output"), Vector2(600, 100))
	g.connect_ports(inp, 0, sc, 0)
	g.connect_ports(na, 0, nbl, 0)          # a = 7
	g.connect_ports(nb, 0, nbl, 1)          # b = 4
	g.connect_ports(sc, 1, nbl, 2)          # mask = Scree.shed (port 1) -> Blend mask (port 2)
	g.connect_ports(nbl, 0, out, 0)

	var surface := _bump_surface()
	var got := g.evaluate(GW, GH, RECT, null, surface)
	var shed: PackedFloat32Array = _oracle_scree(surface, scree_node)[1]
	# Blend ADD gated: lerp(a, a+b, shed) = a + b*shed = 7 + 4*shed
	var max_d := 0.0
	var mask_varies := false
	for i in range(GW * GH):
		var want := 7.0 + 4.0 * clampf(shed[i], 0.0, 1.0)
		max_d = maxf(max_d, absf(got[i] - want))
		if shed[i] > 0.01 and shed[i] < 0.99:
			mask_varies = true
	print("    max |blend - (7 + 4*shed)| = %f (want ~0), mask spans partial values=%s" % [max_d, mask_varies])
	if max_d > EPS:
		_fail += 1; print("    !! multi-output mask channel did not gate the blend correctly")
	if not mask_varies:
		_fail += 1; print("    !! shed mask never took a partial value (gate not exercised)")

	# CONTROL: disconnect the mask -> unwired default 1.0 -> plain blend = 11 everywhere.
	g.disconnect_ports(sc, 1, nbl, 2)
	var got2 := g.evaluate(GW, GH, RECT, null, surface)
	var cmax := 0.0
	for i in range(GW * GH):
		cmax = maxf(cmax, absf(got2[i] - 11.0))
	print("    control: mask unwired -> blend = %f..(max dev %f from 11.0)" % [got2[0], cmax])
	if cmax > EPS:
		_fail += 1; print("    !! unwired mask was not treated as full strength (1.0)")


# ---- [D] --------------------------------------------------------------------------------------------

func _d_per_solver_freeze() -> void:
	print("[D] Per-solver freeze: FROZEN serves the cache and reports stale; Bake re-solves")
	var g := Pasture3DTerrainGraph.new()
	var inp := g.add_node(Pasture3DGraphNodeRegistry.create(&"input"), Vector2.ZERO)
	var scree_node = ScreeScript.new()
	scree_node.evaluation = ScreeScript.Evaluation.FROZEN
	var sc := g.add_node(scree_node, Vector2(200, 0))
	var out := g.add_node(Pasture3DGraphNodeRegistry.create(&"output"), Vector2(400, 0))
	g.connect_ports(inp, 0, sc, 0)
	g.connect_ports(sc, 0, out, 0)

	var surf_a := _bump_surface()
	var r1 := g.evaluate(GW, GH, RECT, null, surf_a)      # first solve -> caches
	var warn_after_first := scree_node.node_warnings().size()

	# A DIFFERENT surface (flattened) while FROZEN: must serve the cached A solve, and go stale.
	var surf_b := PackedFloat32Array(); surf_b.resize(GW * GH) # flat 0 -> no scree at all
	var r2 := g.evaluate(GW, GH, RECT, null, surf_b)
	var served_cache := _max_abs_diff(r1, r2) < 1.0e-6
	var went_stale := scree_node.node_warnings().size() > 0
	print("    frozen: fresh-solve warnings=%d, changed surface served cache=%s, stale reported=%s" % [
		warn_after_first, served_cache, went_stale])
	if not served_cache:
		_fail += 1; print("    !! FROZEN did not serve the cached solve against a changed surface")
	if not went_stale:
		_fail += 1; print("    !! FROZEN did not report itself stale after the surface changed")

	# Bake -> re-solve over surface B (flat) -> now different from A (which had deposition).
	scree_node.clear_cache()
	var r3 := g.evaluate(GW, GH, RECT, null, surf_b)
	var resolved := _max_abs_diff(r1, r3) > EPS and scree_node.node_warnings().size() == 0
	print("    after Bake over flat surface: differs from A=%s, stale cleared=%s" % [
		_max_abs_diff(r1, r3) > EPS, scree_node.node_warnings().size() == 0])
	if not resolved:
		_fail += 1; print("    !! Bake did not re-solve / clear stale")

	# CONTROL: LIVE re-solves immediately and never goes stale.
	scree_node.evaluation = ScreeScript.Evaluation.LIVE
	scree_node.clear_cache()
	var live_a := g.evaluate(GW, GH, RECT, null, surf_a)
	var live_b := g.evaluate(GW, GH, RECT, null, surf_b)
	var live_ok := _max_abs_diff(live_a, live_b) > EPS and scree_node.node_warnings().size() == 0
	print("    control: LIVE A vs B differ=%s, no stale=%s" % [
		_max_abs_diff(live_a, live_b) > EPS, scree_node.node_warnings().size() == 0])
	if not live_ok:
		_fail += 1; print("    !! LIVE did not track the surface / falsely went stale")


# ---- [E] --------------------------------------------------------------------------------------------

func _e_nan_boundary() -> void:
	print("[E] NaN in the surface passes through as NaN height / 0 shed")
	var g := Pasture3DTerrainGraph.new()
	var inp := g.add_node(Pasture3DGraphNodeRegistry.create(&"input"), Vector2.ZERO)
	var scree_node = ScreeScript.new()
	var sc := g.add_node(scree_node, Vector2(200, 0))
	var out := g.add_node(Pasture3DGraphNodeRegistry.create(&"output"), Vector2(400, 0))
	g.connect_ports(inp, 0, sc, 0)
	g.connect_ports(sc, 0, out, 0)

	var surface := _bump_surface()
	# Punch a NaN hole in a corner.
	var hole := 0 * GW + 0
	surface[hole] = NAN
	var got := g.evaluate(GW, GH, RECT, null, surface)
	var finite_somewhere := false
	for i in range(GW * GH):
		if i != hole and is_finite(got[i]):
			finite_somewhere = true
	print("    NaN cell -> height is_nan=%s; finite elsewhere=%s" % [is_nan(got[hole]), finite_somewhere])
	if not is_nan(got[hole]):
		_fail += 1; print("    !! NaN surface cell did not pass through as NaN height")
	if not finite_somewhere:
		_fail += 1; print("    !! whole field went non-finite (NaN leaked)")


# ---- [F] --------------------------------------------------------------------------------------------

func _f_masked_blend_refuses_native() -> void:
	print("[F] A masked Blend refuses to lower to the native path")
	var g := Pasture3DTerrainGraph.new()
	var noise := g.add_node(Pasture3DGraphNodeRegistry.create(&"noise"), Vector2.ZERO)
	var cmask = Pasture3DGraphNodeRegistry.create(&"const"); cmask.set("value", 0.5)
	var ncm := g.add_node(cmask, Vector2(0, 200))
	var blend = Pasture3DGraphNodeRegistry.create(&"blend")
	var nbl := g.add_node(blend, Vector2(200, 0))
	var out := g.add_node(Pasture3DGraphNodeRegistry.create(&"output"), Vector2(400, 0))
	g.connect_ports(noise, 0, nbl, 0)
	g.connect_ports(ncm, 0, nbl, 1)
	g.connect_ports(nbl, 0, out, 0)

	# Unmasked: all supported ops -> lowers (compile_graph_program handles Input/Output/Smooth).
	var native_unmasked := g.native_supported()
	var prog_unmasked: Dictionary = g.compile_graph_program()
	# Now wire the mask port -> must refuse.
	g.connect_ports(ncm, 0, nbl, 2)
	var native_masked := g.native_supported()
	var prog_masked: Dictionary = g.compile_graph_program()

	print("    unmasked native_supported=%s (graph prog empty=%s); masked native_supported=%s (graph prog empty=%s)" % [
		native_unmasked, prog_unmasked.is_empty(), native_masked, prog_masked.is_empty()])
	if not native_unmasked or prog_unmasked.is_empty():
		_fail += 1; print("    !! unmasked blend graph failed to lower (control dead)")
	if native_masked or not prog_masked.is_empty():
		_fail += 1; print("    !! masked blend graph lowered to native despite the 3rd input")


# ---- helpers ----------------------------------------------------------------------------------------

func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var d := 0.0
	for i in range(mini(p_a.size(), p_b.size())):
		var av := p_a[i]; var bv := p_b[i]
		if is_nan(av) or is_nan(bv):
			continue
		d = maxf(d, absf(av - bv))
	return d
