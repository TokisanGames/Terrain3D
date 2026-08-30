# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphTerrainMetricsGate — Phase 3 of PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md §6. All three nodes:
# RelativeElevation (RA-RD), SmoothFill (SA-SF) and RecastCliff (KA-KF), plus the native-route check that
# Phase 2 taught us to make explicit.
#
# RB IS THE CRITERION THAT JUSTIFIES RelativeElevation EXISTING. Two cones of very different absolute
# heights must BOTH read ~1 at their summits. Mask (Altitude) — the node people would otherwise reach for
# — cannot do this, and RB runs it as the control precisely so the difference is measured rather than
# asserted in a comment.
#
# SA is the same kind of claim for SmoothFill: the asymmetry between ridges and valleys IS the node. A
# symmetric blur fills valleys just as well and would pass every other criterion here, so SA runs one as
# its control.
#
# Run WINDOWED — the GPU criteria have no RenderingDevice under --headless.
#   Godot_v4.7-stable_win64_console.exe --path project bench/GraphTerrainMetricsGate.tscn
extends Node

const GW := 64
const GH := 64
const RECT := Rect2(-160.0, -160.0, 320.0, 320.0)
const PARITY_EPS := 2.0e-6
const GPU_TOL := 1.0e-3

var _fail := 0


func _ready() -> void:
	print("=== GraphTerrainMetricsGate: Phase 3 terrain metrics (§6) ===\n")
	_ra_cone_reads_zero_at_base_one_at_apex()
	_rb_two_cones_both_reach_one()
	_rc_relative_elevation_radius_is_metric()
	_sa_fill_is_asymmetric()
	_sb_volume_moves_the_right_way()
	_sc_k_converges_to_hard_max()
	_sd_deposition_matches_the_height_change()
	_ka_flat_ground_is_untouched()
	_kb_steep_gains_gentle_does_not()
	_kc_directional_spares_the_opposite_face()
	_kd_zero_amplitude_is_pass_through()
	_parity_and_route()
	_gpu_parity()
	print("\n=== %s (%d failures) ===\n" % ["TERRAIN METRICS PASS" if _fail == 0 else "TERRAIN METRICS FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- RA. a cone reads ~0 at its base and ~1 at its apex ----------------------------------------------
func _ra_cone_reads_zero_at_base_one_at_apex() -> void:
	print("[RA] RelativeElevation: 0 on the local basin floor, 1 on the local crest")
	var surf := _cone(Vector2.ZERO, 120.0, 200.0, 0.0)
	var got := _rel_elev(surf, 90.0, 0)
	var apex := got[_idx(Vector2.ZERO)]
	var base := got[_idx(Vector2(140.0, 0.0))]
	print("    at the apex = %.4f (want > 0.9), out on the flat = %.4f" % [apex, base])
	if apex < 0.9:
		_fail += 1; print("    !! the summit does not read as a local crest")

	# NO-SIGNAL guard, and the spec names it explicitly: a flat plane has no local relief anywhere, so
	# the output is constant and every comparison against it is vacuous.
	var flat := PackedFloat32Array()
	flat.resize(GW * GH)
	flat.fill(42.0)
	var flat_out := _rel_elev(flat, 90.0, 0)
	var lo := INF
	var hi := -INF
	for i in flat_out.size():
		lo = minf(lo, flat_out[i])
		hi = maxf(hi, flat_out[i])
	print("    control: a flat plane spans %.4f .. %.4f (want a CONSTANT — no relief to measure)" % [lo, hi])
	if hi - lo > 1.0e-5:
		_fail += 1; print("    !! a flat plane produced relief — the local min/max are not equal on it")


# --- RB. the criterion Mask(Altitude) cannot pass ----------------------------------------------------
func _rb_two_cones_both_reach_one() -> void:
	print("[RB] two cones of DIFFERENT absolute heights both read ~1 at their summits")
	# The whole reason this node exists. A 400 m peak and a 60 m hill in one graph: a snowline gated on
	# absolute height puts snow on one and none on the other.
	var tall := Vector2(-80.0, -80.0)
	var short := Vector2(80.0, 80.0)
	var surf := _two_cones(tall, 400.0, short, 60.0, 65.0)

	var got := _rel_elev(surf, 55.0, 0)
	var a := got[_idx(tall)]
	var b := got[_idx(short)]
	print("    tall summit (400 m) = %.4f, short summit (60 m) = %.4f (want BOTH > 0.9)" % [a, b])
	if a < 0.9 or b < 0.9:
		_fail += 1; print("    !! a summit failed to read as a local crest — the metric is not local")

	# CONTROL: Mask (Altitude) must FAIL the same test. Without this, RB is just an assertion that the
	# node works, not a demonstration that it does something Mask cannot.
	var m := Pasture3DGraphNodeMask.new()
	m.property = Pasture3DGraphNodeMask.Property.ALTITUDE
	m.band_min = 300.0
	m.band_max = 500.0
	var masked := _build_graph([m]).evaluate(GW, GH, RECT, null, surf)
	var ma := masked[_idx(tall)]
	var mb := masked[_idx(short)]
	print("    control: Mask(Altitude 300-500) reads %.4f and %.4f (want the short one to MISS)" % [ma, mb])
	if mb > 0.5:
		_fail += 1; print("    !! control dead — Mask(Altitude) passed this too, so RB proves nothing")


# --- RC. the radius is metres ------------------------------------------------------------------------
func _rc_relative_elevation_radius_is_metric() -> void:
	print("[RC] the same world radius gives the same field at two resolutions")
	# The fixture is analytic in WORLD coordinates and has relief everywhere. A cone on a flat plain
	# would not do: outside the cone the neighbourhood is perfectly flat, the node correctly returns the
	# 0.5 midpoint, and the ring where the disc just grazes the cone flips between 0.5 and 0 for reasons
	# that are about the fixture's flat region, not about whether the radius is metric.
	var lo_n := 65
	var hi_n := 129
	var lo := _rel_elev_at(_ridges_at(lo_n), lo_n, 70.0, 0)
	var hi := _rel_elev_at(_ridges_at(hi_n), hi_n, 70.0, 0)

	var worst := _cross_resolution_diff(lo, lo_n, hi, hi_n)
	print("    max |field(65^2) - field(129^2)| = %.4f (want < 0.12)" % worst)
	if worst > 0.12:
		_fail += 1; print("    !! the radius is behaving as CELLS — the neighbourhood shrinks on the fine grid")

	# CONTROL: halving the radius must move the field by more than the tolerance, or RC would pass for a
	# node that ignores its radius.
	var half := _rel_elev_at(_ridges_at(hi_n), hi_n, 12.0, 0)
	var cw := _cross_resolution_diff(lo, lo_n, half, hi_n)
	print("    control: a different radius changes the field by %.4f (want > 0.12)" % cw)
	if cw <= 0.12:
		_fail += 1; print("    !! control dead — this fixture cannot tell two radii apart")


## Worst disagreement between two grids of different resolution, compared at the coarse grid's cells and
## skipping a border the two cannot sample alike.
func _cross_resolution_diff(p_a: PackedFloat32Array, p_an: int, p_b: PackedFloat32Array,
		p_bn: int) -> float:
	var worst := 0.0
	for iz in range(6, p_an - 6):
		for ix in range(6, p_an - 6):
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, p_an, p_an, RECT)
			worst = maxf(worst, absf(p_a[iz * p_an + ix] - p_b[_nearest(w, p_bn)]))
	return worst


# --- SA. the fill is asymmetric ----------------------------------------------------------------------
func _sa_fill_is_asymmetric() -> void:
	print("[SA] SmoothFill raises valley floors and leaves ridge crests alone")
	var surf := _ridges()
	var got := _smooth_fill(surf, 0, 40.0, 0.1, 1.0)

	var crest_move := _mean_abs_move_where(surf, got, true)
	var floor_move := _mean_abs_move_where(surf, got, false)
	var prominence := _relief(surf)
	print("    mean |move| on crests  = %.4f m (%.2f%% of %.1f m prominence)"
			% [crest_move, 100.0 * crest_move / prominence, prominence])
	print("    mean |move| on valleys = %.4f m" % floor_move)
	if crest_move > 0.01 * prominence:
		_fail += 1; print("    !! ridge crests moved more than 1% of prominence — this is behaving as a blur")
	if floor_move <= crest_move * 3.0:
		_fail += 1; print("    !! valleys did not rise decisively more than crests — the asymmetry is missing")

	# CONTROL: a symmetric blur must FAIL the asymmetry test. This is what stops SA from being a claim
	# that any smoothing operation would satisfy.
	var sm := Pasture3DGraphNodeSmooth.new()
	sm.passes = 8
	var blurred := _build_graph([sm]).evaluate(GW, GH, RECT, null, surf)
	var b_crest := _mean_abs_move_where(surf, blurred, true)
	var b_floor := _mean_abs_move_where(surf, blurred, false)
	print("    control: a symmetric Smooth moves crests %.4f m vs valleys %.4f m (want comparable)"
			% [b_crest, b_floor])
	if b_crest <= 0.01 * prominence:
		_fail += 1; print("    !! control dead — the blur did not move crests either, so SA proves nothing")


# --- SB. volume moves the right way ------------------------------------------------------------------
func _sb_volume_moves_the_right_way() -> void:
	print("[SB] FILL_VALLEYS adds material, SMEAR_PEAKS removes it")
	var surf := _ridges()
	var v0 := _sum(surf)
	var v_fill := _sum(_smooth_fill(surf, 0, 40.0, 0.1, 1.0))
	var v_smear := _sum(_smooth_fill(surf, 2, 40.0, 0.1, 1.0))
	print("    volume: input %.1f, filled %.1f (want >), smeared %.1f (want <)" % [v0, v_fill, v_smear])
	if v_fill <= v0:
		_fail += 1; print("    !! FILL_VALLEYS did not add material")
	if v_smear >= v0:
		_fail += 1; print("    !! SMEAR_PEAKS did not remove material")


# --- SC. k -> 0 converges to a hard max --------------------------------------------------------------
func _sc_k_converges_to_hard_max() -> void:
	print("[SC] as k -> 0 the fill converges to a hard max(z, blur(z))")
	var surf := _ridges()
	var blurred: PackedFloat32Array = Pasture3DUtil.box_mean_grid(surf, GW, GH, RECT, 40.0)
	var hard := PackedFloat32Array()
	hard.resize(surf.size())
	for i in surf.size():
		hard[i] = maxf(surf[i], blurred[i])

	var d_small := _max_abs_diff(_smooth_fill(surf, 0, 40.0, 0.0001, 1.0), hard)
	var d_large := _max_abs_diff(_smooth_fill(surf, 0, 40.0, 8.0, 1.0), hard)
	print("    k=0.0001: max |fill - hard max| = %.6f (want < 0.01)" % d_small)
	print("    k=8.0   : max |fill - hard max| = %.6f (want > 0.5 — the control)" % d_large)
	if d_small > 0.01:
		_fail += 1; print("    !! a vanishing k does not converge to the hard max — check the smax normalisation")
	if d_large <= 0.5:
		_fail += 1; print("    !! control dead — k has no effect, so the convergence above means nothing")


# --- SD. deposition marks exactly where the height changed -------------------------------------------
func _sd_deposition_matches_the_height_change() -> void:
	print("[SD] the deposition channel is non-zero exactly where the height changed")
	var surf := _ridges()
	var node := Pasture3DGraphNodeSmoothFill.new()
	node.mode = 0
	node.radius = 40.0
	node.k = 0.1
	node.amount = 1.0
	var channels := node.eval_grid_channels([surf], GW, GH, null, RECT)
	var height: PackedFloat32Array = channels[0]
	var dep: PackedFloat32Array = channels[1]
	var divisor := node.last_deposition_divisor

	var mismatched := 0
	var worst := 0.0
	for i in surf.size():
		var actual := height[i] - surf[i]
		var claimed := dep[i] * divisor
		worst = maxf(worst, absf(actual - claimed))
		if (absf(actual) > 1.0e-4) != (absf(claimed) > 1.0e-4):
			mismatched += 1
	print("    divisor = %.4f m, max |deposition*divisor - (out - in)| = %.6f" % [divisor, worst])
	print("    cells where the two disagree about having changed: %d (want 0)" % mismatched)
	if worst > 1.0e-4 or mismatched > 0:
		_fail += 1; print("    !! the deposition channel does not describe the height change it came from")
	# CONTROL: the divisor must be a real measurement, not a stuck 1.0 that happens to work.
	print("    control: divisor differs from 1.0 by %.4f (want > 0.01 — a measured value)" % absf(divisor - 1.0))
	if absf(divisor - 1.0) <= 0.01:
		_fail += 1; print("    !! the divisor looks like an untouched default, so SD compared unnormalised data")


# --- KA. flat ground is untouched --------------------------------------------------------------------
func _ka_flat_ground_is_untouched() -> void:
	print("[KA] RecastCliff leaves ground below the talus angle alone")
	var flat := PackedFloat32Array()
	flat.resize(GW * GH)
	flat.fill(30.0)
	var got := _recast(flat, 40.0, 20.0, 10.0, -1.0)
	var d := _max_abs_diff(got, flat)
	print("    max |recast(flat) - flat| = %.9f (want < 1e-6)" % d)
	if d > 1.0e-6:
		_fail += 1; print("    !! flat ground was recast — the slope gate is not gating")
	# CONTROL: a talus angle of ~0 must change SOMETHING on a sloped fixture, or KA passes for a node
	# that never does anything.
	var ramp := _ramp(0.9)
	var c := _max_abs_diff(_recast(ramp, 1.0, 20.0, 10.0, -1.0), ramp)
	print("    control: talus 1° on a steep ramp moves it by %.4f m (want > 0.1)" % c)
	if c <= 0.1:
		_fail += 1; print("    !! control dead — the node never modifies anything")


# --- KB. steep gains, gentle does not ----------------------------------------------------------------
func _kb_steep_gains_gentle_does_not() -> void:
	print("[KB] a ramp above the talus angle is recast; one below it is not")
	# tan(40°) ~= 0.839. A 1.5 m/m ramp is well above it; a 0.2 m/m ramp well below.
	var steep := _ramp(1.5)
	var gentle := _ramp(0.2)
	var steep_move := _max_abs_diff(_recast(steep, 40.0, 20.0, 10.0, -1.0), steep)
	var gentle_move := _max_abs_diff(_recast(gentle, 40.0, 20.0, 10.0, -1.0), gentle)
	print("    steep ramp (1.5 m/m) moved %.4f m (want > 0.5)" % steep_move)
	print("    gentle ramp (0.2 m/m) moved %.6f m (want < 1e-6)" % gentle_move)
	if steep_move <= 0.5:
		_fail += 1; print("    !! ground above the talus angle was not recast")
	if gentle_move > 1.0e-6:
		_fail += 1; print("    !! ground below the talus angle was modified")


# --- KC. directional mode spares the opposite face ---------------------------------------------------
func _kc_directional_spares_the_opposite_face() -> void:
	print("[KC] directional mode leaves a face pointing the other way bit-identical")
	# A ridge with two opposing faces. Aim the window at one of them; the other must be untouched.
	var surf := _ridge_pair()
	# The east-facing half descends toward +X, so it faces bearing 0.
	var got := _recast(surf, 30.0, 20.0, 10.0, 0.0)

	var east_move := 0.0
	var west_move := 0.0
	for iz in GH:
		for ix in GW:
			var i := iz * GW + ix
			var d := absf(got[i] - surf[i])
			if ix > GW / 2 + 2:
				east_move = maxf(east_move, d)
			elif ix < GW / 2 - 2:
				west_move = maxf(west_move, d)
	print("    east face (inside the window) moved %.4f m (want > 0.2)" % east_move)
	print("    west face (opposite)          moved %.6f m (want < 1e-6)" % west_move)
	if east_move <= 0.2:
		_fail += 1; print("    !! the targeted face was not recast")
	if west_move > 1.0e-6:
		_fail += 1; print("    !! the opposite face was modified — the angular window is not gating")
	# CONTROL: omnidirectional must hit BOTH, or KC would pass for a node that only ever touches one side.
	var omni := _recast(surf, 30.0, 20.0, 10.0, -1.0)
	var omni_west := 0.0
	for iz in GH:
		for ix in range(0, GW / 2 - 2):
			omni_west = maxf(omni_west, absf(omni[iz * GW + ix] - surf[iz * GW + ix]))
	print("    control: omnidirectional moves the west face by %.4f m (want > 0.2)" % omni_west)
	if omni_west <= 0.2:
		_fail += 1; print("    !! control dead — the west face is never recast under any setting")


# --- KD. amplitude 0 is a pass-through ---------------------------------------------------------------
func _kd_zero_amplitude_is_pass_through() -> void:
	print("[KD] amplitude = 0 passes the input through unchanged")
	var surf := _ramp(1.5)
	var d := _max_abs_diff(_recast(surf, 40.0, 20.0, 0.0, -1.0), surf)
	print("    max |recast(amplitude=0) - in| = %.9f (want 0)" % d)
	if d > 0.0:
		_fail += 1; print("    !! a zero amplitude still modified the terrain")


# --- native route + oracle parity --------------------------------------------------------------------
func _parity_and_route() -> void:
	print("[parity] native == oracle, and each node takes the native C++ route")
	var surf := _ridges()

	var cases := [
		["RelativeElevation", _rel_elev_node(70.0, 0), _dev(0, 70.0, 0, 0.0, 0.0, 0.0)],
		["SmoothFill/VALLEYS", _smooth_fill_node(0, 40.0, 0.1, 1.0), _dev(1, 40.0, 0, 0.1, 0.0, 0.0)],
		["SmoothFill/HOLES", _smooth_fill_node(1, 40.0, 0.1, 1.0), _dev(1, 40.0, 1, 0.1, 0.0, 0.0)],
		["SmoothFill/SMEAR", _smooth_fill_node(2, 40.0, 0.1, 1.0), _dev(1, 40.0, 2, 0.1, 0.0, 0.0)],
		["RecastCliff/omni", _recast_node(35.0, 20.0, 10.0, -1.0), _dev(2, 20.0, 0, 0.0, 35.0, -1.0)],
		["RecastCliff/dir", _recast_node(35.0, 20.0, 10.0, 0.0), _dev(2, 20.0, 0, 0.0, 35.0, 0.0)],
	]

	for c in cases:
		var name: String = c[0]
		var g := _build_graph([c[1]])
		var supported: bool = g.native_supported()
		if not supported:
			_fail += 1
			print("    %-20s native_supported() = FALSE" % name)
			print("      !! the op is missing from the SUPPORTED list in native_supported(). This does")
			print("         not fail loudly — it drops the WHOLE graph onto the GDScript evaluator.")
			continue
		var native := g.evaluate(GW, GH, RECT, null, surf)
		var oracle: PackedFloat32Array = c[2].solve(surf, GW, GH, RECT)
		var d := _max_abs_diff(native, oracle)
		print("    %-20s route=native  max |native - oracle| = %.9f" % [name, d])
		if d > PARITY_EPS:
			_fail += 1; print("      !! the C++ kernel and the oracle disagree")
		var moved := _max_abs_diff(native, surf)
		if moved <= 0.01:
			_fail += 1; print("      !! NO-SIGNAL — this configuration is a pass-through, so parity compared nothing")


# --- GPU parity --------------------------------------------------------------------------------------
func _gpu_parity() -> void:
	print("[gpu] each Phase 3 node still takes the GPU path")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		_fail += 1; print("    !! Pasture3DUtil.graph_eval_grid_gpu is not bound — rebuild the GDExtension")
		return
	var surf := _ridges()
	var cases := [
		["RelativeElevation", _rel_elev_node(70.0, 0)],
		["SmoothFill/VALLEYS", _smooth_fill_node(0, 40.0, 0.1, 1.0)],
		["SmoothFill/HOLES", _smooth_fill_node(1, 40.0, 0.1, 1.0)],
		["SmoothFill/SMEAR", _smooth_fill_node(2, 40.0, 0.1, 1.0)],
		["RecastCliff/omni", _recast_node(35.0, 20.0, 10.0, -1.0)],
		["RecastCliff/dir", _recast_node(35.0, 20.0, 10.0, 0.0)],
	]
	for c in cases:
		var name: String = c[0]
		var g := _build_graph([c[1]])
		var gpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
				g.compile_graph_program(), GW, GH, RECT, surf)
		if gpu.is_empty():
			var ctrl: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
					_build_graph([]).compile_graph_program(), GW, GH, RECT, surf)
			if ctrl.is_empty():
				print("    NO-SIGNAL: no local RenderingDevice — GPU route unverified. Re-run windowed.")
				return
			_fail += 1
			print("    %-20s !! the GPU bailed on this node but not on a bare in->out graph;" % name)
			print("       the bail is graph-wide, so this drops EVERY node in the graph to the CPU.")
			continue
		var cpu := g.evaluate(GW, GH, RECT, null, surf)
		var d := _max_abs_diff(gpu, cpu)
		print("    %-20s max |gpu - cpu| = %.8f" % [name, d])
		if d > GPU_TOL:
			_fail += 1; print("      !! the GPU kernel disagrees with the CPU kernel")
		var moved := _max_abs_diff(gpu, surf)
		if moved <= 0.01:
			_fail += 1; print("      !! NO-SIGNAL — the GPU returned the input unchanged")


# --- node builders ------------------------------------------------------------------------------------
func _rel_elev_node(p_radius: float, p_units: int) -> Pasture3DGraphNode:
	var n := Pasture3DGraphNodeRelativeElevation.new()
	n.radius = p_radius
	n.output_units = p_units
	return n


func _smooth_fill_node(p_mode: int, p_radius: float, p_k: float, p_amount: float) -> Pasture3DGraphNode:
	var n := Pasture3DGraphNodeSmoothFill.new()
	n.mode = p_mode
	n.radius = p_radius
	n.k = p_k
	n.amount = p_amount
	return n


func _recast_node(p_talus: float, p_radius: float, p_amplitude: float,
		p_dir: float) -> Pasture3DGraphNode:
	var n := Pasture3DGraphNodeRecastCliff.new()
	n.talus_angle_deg = p_talus
	n.radius = p_radius
	n.amplitude = p_amplitude
	n.gain = 2.0
	n.direction_deg = p_dir
	n.direction_spread_deg = 60.0
	n.amount = 1.0
	return n


func _dev(p_which: int, p_radius: float, p_mode: int, p_k: float, p_talus: float,
		p_dir: float) -> Pasture3DGraphNodeDevTerrainMetrics:
	var d := Pasture3DGraphNodeDevTerrainMetrics.new()
	d.which = p_which
	d.radius = p_radius
	d.mode = p_mode
	d.k = p_k
	d.talus_angle_deg = p_talus if p_talus > 0.0 else 40.0
	d.amplitude = 10.0
	d.gain = 2.0
	d.direction_deg = p_dir
	d.direction_spread_deg = 60.0
	d.amount = 1.0
	d.output_units = 0
	return d


# --- evaluation helpers -------------------------------------------------------------------------------
func _rel_elev(p_in: PackedFloat32Array, p_radius: float, p_units: int) -> PackedFloat32Array:
	return _build_graph([_rel_elev_node(p_radius, p_units)]).evaluate(GW, GH, RECT, null, p_in)


func _rel_elev_at(p_in: PackedFloat32Array, p_n: int, p_radius: float,
		p_units: int) -> PackedFloat32Array:
	return _build_graph([_rel_elev_node(p_radius, p_units)]).evaluate(p_n, p_n, RECT, null, p_in)


func _smooth_fill(p_in: PackedFloat32Array, p_mode: int, p_radius: float, p_k: float,
		p_amount: float) -> PackedFloat32Array:
	return _build_graph([_smooth_fill_node(p_mode, p_radius, p_k, p_amount)]).evaluate(GW, GH, RECT, null, p_in)


func _recast(p_in: PackedFloat32Array, p_talus: float, p_radius: float, p_amplitude: float,
		p_dir: float) -> PackedFloat32Array:
	return _build_graph([_recast_node(p_talus, p_radius, p_amplitude, p_dir)]).evaluate(GW, GH, RECT, null, p_in)


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


# --- fixtures -----------------------------------------------------------------------------------------
func _cone(p_centre: Vector2, p_radius: float, p_height: float, p_base: float) -> PackedFloat32Array:
	return _cone_at(GW, p_centre, p_radius, p_height, p_base)


func _cone_at(p_n: int, p_centre: Vector2, p_radius: float, p_height: float,
		p_base: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(p_n * p_n)
	for iz in p_n:
		for ix in p_n:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, p_n, p_n, RECT)
			var d := w.distance_to(p_centre)
			a[iz * p_n + ix] = p_base + maxf(0.0, 1.0 - d / p_radius) * p_height
	return a


func _two_cones(p_a: Vector2, p_ah: float, p_b: Vector2, p_bh: float,
		p_radius: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			var ha := maxf(0.0, 1.0 - w.distance_to(p_a) / p_radius) * p_ah
			var hb := maxf(0.0, 1.0 - w.distance_to(p_b) / p_radius) * p_bh
			a[iz * GW + ix] = maxf(ha, hb)
	return a


## Parallel ridges: sharp crests, sharp valleys, symmetric — so any asymmetry in the OUTPUT came from
## the node and not from the fixture.
func _ridges() -> PackedFloat32Array:
	return _ridges_at(GW)


func _ridges_at(p_n: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(p_n * p_n)
	for iz in p_n:
		for ix in p_n:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, p_n, p_n, RECT)
			a[iz * p_n + ix] = 40.0 * absf(sin(w.x * 0.035)) - 20.0 + 6.0 * sin(w.y * 0.02)
	return a


## A single ridge running north-south: the east half descends toward +X, the west half toward -X.
func _ridge_pair() -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			a[iz * GW + ix] = 120.0 - 1.2 * absf(w.x)
	return a


func _ramp(p_slope: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			a[iz * GW + ix] = w.x * p_slope
	return a


# --- measurement helpers ------------------------------------------------------------------------------
## Mean absolute movement over the cells in the top (crest) or bottom (valley) quartile of the input.
func _mean_abs_move_where(p_in: PackedFloat32Array, p_out: PackedFloat32Array,
		p_crests: bool) -> float:
	var sorted := p_in.duplicate()
	var arr := Array(sorted)
	arr.sort()
	var q_hi: float = arr[int(arr.size() * 0.75)]
	var q_lo: float = arr[int(arr.size() * 0.25)]
	var total := 0.0
	var count := 0
	for i in p_in.size():
		var take := (p_in[i] >= q_hi) if p_crests else (p_in[i] <= q_lo)
		if take:
			total += absf(p_out[i] - p_in[i])
			count += 1
	return (total / float(count)) if count > 0 else 0.0


func _idx(p_world: Vector2) -> int:
	return _nearest(p_world, GW)


func _nearest(p_world: Vector2, p_n: int) -> int:
	var dx := RECT.size.x / float(p_n)
	var dz := RECT.size.y / float(p_n)
	var ix := clampi(int((p_world.x - RECT.position.x) / dx), 0, p_n - 1)
	var iz := clampi(int((p_world.y - RECT.position.y) / dz), 0, p_n - 1)
	return iz * p_n + ix


func _sum(p_g: PackedFloat32Array) -> float:
	var s := 0.0
	for i in p_g.size():
		if not is_nan(p_g[i]):
			s += p_g[i]
	return s


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
