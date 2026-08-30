# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphWarpDownslopeGate — spec §7.1. WA-WE, plus the native-route and GPU-route checks Phase 2 taught us
# to make explicit rather than assume.
#
# WB is the criterion that says this is a DOWNSLOPE warp and not just a warp. A noise warp of the same
# displacement scrambles a cone without moving its mass outward, so WB measures the radius containing half
# the cone's volume and asserts it GROWS — and asserts that `reverse` shrinks it, which no direction-blind
# displacement can do.
#
# Run WINDOWED — the GPU criterion has no RenderingDevice under --headless.
#   Godot_v4.7-stable_win64_console.exe --path project bench/GraphWarpDownslopeGate.tscn
extends Node

const GW := 96
const GH := 96
const RECT := Rect2(-240.0, -240.0, 480.0, 480.0)
const PARITY_EPS := 2.0e-6
const GPU_TOL := 1.0e-3

var _fail := 0


func _ready() -> void:
	print("=== GraphWarpDownslopeGate: warp along the gradient (§7.1) ===\n")
	_wa_flat_is_unchanged()
	_wb_mass_moves_downhill()
	_wc_displacement_is_metric()
	_wd_parity_and_route()
	_we_no_signal_guard()
	_wf_gpu()
	print("\n=== %s (%d failures) ===\n" % ["WARP DOWNSLOPE PASS" if _fail == 0 else "WARP DOWNSLOPE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- WA. a flat plane does not move ------------------------------------------------------------------
func _wa_flat_is_unchanged() -> void:
	print("[WA] a flat plane is returned unchanged")
	var flat := PackedFloat32Array()
	flat.resize(GW * GH)
	flat.fill(75.0)
	var d := _max_abs_diff(_warp(flat, 40.0, 30.0, false, 1.0), flat)
	print("    max |warp(flat) - flat| = %.9f (want 0 exactly)" % d)
	if d > 0.0:
		_fail += 1; print("    !! a flat plane moved — the gradient epsilon is not gating")

	# CONTROL: a TILTED plane must move, or WA passes for a node that never displaces anything.
	var tilt := _tilted(0.4)
	var c := _max_abs_diff(_warp(tilt, 40.0, 30.0, false, 1.0), tilt)
	print("    control: a tilted plane moves by %.4f m (want > 1.0)" % c)
	if c <= 1.0:
		_fail += 1; print("    !! control dead — the node never displaces anything")


# --- WB. mass moves downhill -------------------------------------------------------------------------
func _wb_mass_moves_downhill() -> void:
	print("[WB] on a cone, mass spreads OUTWARD; reverse pulls it IN")
	var cone := _cone(140.0, 200.0)
	var r0 := _half_volume_radius(cone)
	var r_fwd := _half_volume_radius(_warp(cone, 40.0, 30.0, false, 1.0))
	var r_rev := _half_volume_radius(_warp(cone, 40.0, 30.0, true, 1.0))
	print("    radius containing 50%% of the cone's volume: input %.2f m" % r0)
	print("      downslope %.2f m (want >), upslope %.2f m (want <)" % [r_fwd, r_rev])
	if r_fwd <= r0:
		_fail += 1; print("    !! the warp did not move mass outward — it is not following the gradient")
	if r_rev >= r0:
		_fail += 1; print("    !! reverse did not move mass inward, so the direction is not being used")

	# CONTROL: a DIRECTION-BLIND displacement of the same 40 m must not spread the cone. Transform is the
	# honest control here; the noise Warp node is not, because it does not resample its input at all — it
	# adds a domain-warped noise field on top of it, so it could never move the cone's mass whatever its
	# settings, and using it would be a control that passes for the wrong reason.
	#
	# The measure is spread about the mass CENTROID, not about the origin, precisely so a rigid
	# translation scores identically to the input and only a genuine spreading shows up.
	var t := Pasture3DGraphNodeTransform.new()
	t.offset = Vector2(40.0, 0.0)
	t.amount = 1.0
	var shifted := _build_graph([t]).evaluate(GW, GH, RECT, null, cone)
	var moved := _max_abs_diff(shifted, cone)
	if moved <= 1.0:
		_fail += 1
		print("    !! the rigid-displacement control did not move the cone at all (%.4f m), so it is dead"
				% moved)
		print("       for the wrong reason and proves nothing about direction.")
	var r_shift := _half_volume_radius(shifted)
	print("    control: a rigid 40 m shift gives %.2f m (want near %.2f, not > %.2f)"
			% [r_shift, r0, r_fwd])
	if r_shift >= r_fwd:
		_fail += 1; print("    !! control dead — a direction-blind shift spread the cone as much as this did")


# --- WC. displacement is metres ----------------------------------------------------------------------
func _wc_displacement_is_metric() -> void:
	print("[WC] the same world displacement gives the same surface at two resolutions")
	var lo_n := 65
	var hi_n := 129
	var lo := _warp_at(_cone_at(lo_n, 140.0, 200.0), lo_n, 40.0, 30.0, false, 1.0)
	var hi := _warp_at(_cone_at(hi_n, 140.0, 200.0), hi_n, 40.0, 30.0, false, 1.0)
	var worst := _cross_resolution_diff(lo, lo_n, hi, hi_n)
	var relief := _relief(_cone_at(lo_n, 140.0, 200.0))
	print("    max |warp(65^2) - warp(129^2)| = %.3f m over %.1f m relief (want < 5%% of it)" % [worst, relief])
	if worst > 0.05 * relief:
		_fail += 1; print("    !! displacement is behaving as CELLS — it doubles when the grid does")

	# CONTROL: half the displacement must differ by more than the tolerance.
	var half := _warp_at(_cone_at(hi_n, 140.0, 200.0), hi_n, 20.0, 30.0, false, 1.0)
	var cw := _cross_resolution_diff(lo, lo_n, half, hi_n)
	print("    control: half the displacement changes it by %.3f m (want > %.3f)" % [cw, 0.05 * relief])
	if cw <= 0.05 * relief:
		_fail += 1; print("    !! control dead — this fixture cannot tell two displacements apart")


# --- WD. parity + the native route -------------------------------------------------------------------
func _wd_parity_and_route() -> void:
	print("[WD] native == oracle, and the node takes the native C++ route")
	var surf := _cone(140.0, 200.0)
	for rev in [false, true]:
		var label := "reverse" if rev else "downslope"
		var g := _build_graph([_node(40.0, 30.0, rev, 1.0)])
		var supported: bool = g.native_supported()
		if not supported:
			_fail += 1
			print("    %-10s native_supported() = FALSE" % label)
			print("      !! the op is missing from the SUPPORTED list in native_supported(). This does not")
			print("         fail loudly — it drops the WHOLE graph onto the GDScript evaluator.")
			continue
		var native := g.evaluate(GW, GH, RECT, null, surf)
		var dev := Pasture3DGraphNodeDevWarpDownslope.new()
		dev.displacement = 40.0
		dev.radius = 30.0
		dev.reverse = rev
		dev.amount = 1.0
		var oracle: PackedFloat32Array = dev.solve(surf, GW, GH, RECT)
		var d := _max_abs_diff(native, oracle)
		print("    %-10s route=native  max |native - oracle| = %.9f" % [label, d])
		if d > PARITY_EPS:
			_fail += 1; print("      !! the C++ kernel and the oracle disagree")
		if _max_abs_diff(native, surf) <= 0.01:
			_fail += 1; print("      !! NO-SIGNAL — this configuration is a pass-through, so parity compared nothing")


# --- WE. NO-SIGNAL when there is no gradient to follow -----------------------------------------------
func _we_no_signal_guard() -> void:
	print("[WE] a fixture whose gradient is everywhere below epsilon reports NO-SIGNAL, not success")
	# A plane tilted by 1e-6 m/m. Every cell's gradient is under GRADIENT_EPSILON, so the node correctly
	# does nothing — and a gate that took "unchanged" as a pass here would be measuring nothing at all.
	var nearly_flat := _tilted(1.0e-6)
	var moved := _max_abs_diff(_warp(nearly_flat, 40.0, 30.0, false, 1.0), nearly_flat)
	print("    a 1e-6 m/m tilt moves by %.9f m" % moved)
	if moved > 0.0:
		_fail += 1; print("    !! a sub-epsilon gradient still displaced the surface")
	else:
		print("    NO-SIGNAL as expected: below the gradient epsilon there is no direction to follow, so")
		print("    this fixture cannot verify displacement — WA/WB/WC are the criteria that do.")


# --- GPU route ---------------------------------------------------------------------------------------
func _wf_gpu() -> void:
	print("[gpu] the node still takes the GPU path")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		_fail += 1; print("    !! Pasture3DUtil.graph_eval_grid_gpu is not bound — rebuild the GDExtension")
		return
	var surf := _cone(140.0, 200.0)
	for rev in [false, true]:
		var label := "reverse" if rev else "downslope"
		var g := _build_graph([_node(40.0, 30.0, rev, 1.0)])
		var gpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
				g.compile_graph_program(), GW, GH, RECT, surf)
		if gpu.is_empty():
			var ctrl: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
					_build_graph([]).compile_graph_program(), GW, GH, RECT, surf)
			if ctrl.is_empty():
				print("    NO-SIGNAL: no local RenderingDevice — GPU route unverified. Re-run windowed.")
				return
			_fail += 1
			print("    %-10s !! the GPU bailed here but not on a bare in->out graph; the bail is" % label)
			print("       graph-wide, so this drops EVERY node in the graph to the CPU.")
			continue
		var cpu := g.evaluate(GW, GH, RECT, null, surf)
		var d := _max_abs_diff(gpu, cpu)
		print("    %-10s max |gpu - cpu| = %.8f" % [label, d])
		if d > GPU_TOL:
			_fail += 1; print("      !! the GPU kernel disagrees with the CPU kernel")
		if _max_abs_diff(gpu, surf) <= 0.01:
			_fail += 1; print("      !! NO-SIGNAL — the GPU returned the input unchanged")


# --- helpers -----------------------------------------------------------------------------------------
func _node(p_disp: float, p_radius: float, p_rev: bool, p_amount: float) -> Pasture3DGraphNode:
	var n := Pasture3DGraphNodeWarpDownslope.new()
	n.displacement = p_disp
	n.radius = p_radius
	n.reverse = p_rev
	n.amount = p_amount
	return n


func _warp(p_in: PackedFloat32Array, p_disp: float, p_radius: float, p_rev: bool,
		p_amount: float) -> PackedFloat32Array:
	return _build_graph([_node(p_disp, p_radius, p_rev, p_amount)]).evaluate(GW, GH, RECT, null, p_in)


func _warp_at(p_in: PackedFloat32Array, p_n: int, p_disp: float, p_radius: float, p_rev: bool,
		p_amount: float) -> PackedFloat32Array:
	return _build_graph([_node(p_disp, p_radius, p_rev, p_amount)]).evaluate(p_n, p_n, RECT, null, p_in)


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


func _cone(p_radius: float, p_height: float) -> PackedFloat32Array:
	return _cone_at(GW, p_radius, p_height)


func _cone_at(p_n: int, p_radius: float, p_height: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(p_n * p_n)
	for iz in p_n:
		for ix in p_n:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, p_n, p_n, RECT)
			a[iz * p_n + ix] = maxf(0.0, 1.0 - w.length() / p_radius) * p_height
	return a


func _tilted(p_slope: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			a[iz * GW + ix] = 100.0 + w.x * p_slope
	return a


## The radius about the mass CENTROID containing half the grid's total (non-negative) volume. A single
## scalar for "how spread out is this mass", which is exactly the quantity a downslope warp should
## increase — and, because it is measured about the centroid rather than the origin, a quantity a rigid
## translation leaves untouched. Measuring it from the origin instead would score a plain shift as
## spreading, and the control in WB would pass for the wrong reason.
func _half_volume_radius(p_g: PackedFloat32Array) -> float:
	var cx := 0.0
	var cz := 0.0
	var mass := 0.0
	for iz in GH:
		for ix in GW:
			var v := p_g[iz * GW + ix]
			if is_nan(v) or v <= 0.0:
				continue
			var wc := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			cx += wc.x * v
			cz += wc.y * v
			mass += v
	if mass <= 0.0:
		return 0.0
	var centroid := Vector2(cx / mass, cz / mass)

	var pairs: Array = []
	var total := 0.0
	for iz in GH:
		for ix in GW:
			var v := p_g[iz * GW + ix]
			if is_nan(v) or v <= 0.0:
				continue
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			pairs.append([w.distance_to(centroid), v])
			total += v
	if total <= 0.0:
		return 0.0
	pairs.sort_custom(func(a, b): return a[0] < b[0])
	var acc := 0.0
	for p in pairs:
		acc += p[1]
		if acc >= total * 0.5:
			return p[0]
	return pairs[-1][0]


func _cross_resolution_diff(p_a: PackedFloat32Array, p_an: int, p_b: PackedFloat32Array,
		p_bn: int) -> float:
	var worst := 0.0
	var dx := RECT.size.x / float(p_bn)
	var dz := RECT.size.y / float(p_bn)
	for iz in range(4, p_an - 4):
		for ix in range(4, p_an - 4):
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, p_an, p_an, RECT)
			var bx := clampi(int((w.x - RECT.position.x) / dx), 0, p_bn - 1)
			var bz := clampi(int((w.y - RECT.position.y) / dz), 0, p_bn - 1)
			worst = maxf(worst, absf(p_a[iz * p_an + ix] - p_b[bz * p_bn + bx]))
	return worst


func _relief(p_g: PackedFloat32Array) -> float:
	var lo := INF
	var hi := -INF
	for i in p_g.size():
		if is_nan(p_g[i]):
			continue
		lo = minf(lo, p_g[i])
		hi = maxf(hi, p_g[i])
	return maxf(hi - lo, 1.0)


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
