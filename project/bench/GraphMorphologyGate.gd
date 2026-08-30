# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphMorphologyGate — Pasture3DGraphNodeExpandShrink, phase 2 of
# PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md §5.2. Criteria EA-EE plus GPU parity.
#
# EC is the criterion that carries the batch's units rule: the radius is METRES, so the same world radius
# must grow a mask by the same world distance at 65² and at 129². A cell-valued radius passes every other
# criterion here and fails only this one.
#
# ED is where the two disc definitions get reconciled. The native kernel decomposes the disc into
# per-row horizontal passes, the oracle walks the offsets directly, and the GPU gathers the whole 2D
# neighbourhood — three different traversals that must agree on the SAME structuring element, the unit
# ellipse in cell space. A floor-versus-round slip in the row half-width is invisible everywhere except
# here.
#
# Run WINDOWED: the GPU criterion has no RenderingDevice under --headless.
#   Godot_v4.7-stable_win64_console.exe --path project bench/GraphMorphologyGate.tscn
extends Node

const GW := 64
const GH := 64
const RECT := Rect2(-160.0, -160.0, 320.0, 320.0)
const PARITY_EPS := 2.0e-6
const GPU_TOL := 1.0e-3

var _fail := 0


func _ready() -> void:
	print("=== GraphMorphologyGate: grayscale morphology (§5.2) ===\n")
	_e0_signal_guard()
	_ee_zero_radius_is_pass_through()
	_ea_close_is_idempotent_on_coarse_features()
	_eb_open_removes_speckle_only()
	_ec_radius_is_metric()
	_ed_native_matches_oracle()
	_eg_gpu_parity()
	print("\n=== %s (%d failures) ===\n" % ["MORPHOLOGY PASS" if _fail == 0 else "MORPHOLOGY FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- E0. the fixture has features on both sides of the radius ----------------------------------------
func _e0_signal_guard() -> void:
	print("[E0] NO-SIGNAL guard: the fixture has both a large blob and sub-radius speckle")
	var m := _speckled_mask()
	var on := 0
	for i in m.size():
		if m[i] > 0.5:
			on += 1
	print("    set cells = %d of %d (want a real minority, not empty and not everything)" % [on, m.size()])
	if on < 50 or on > m.size() - 50:
		_fail += 1; print("    !! NO-SIGNAL — this fixture cannot distinguish removed features from kept ones")


# --- EE. radius 0 is a pass-through ------------------------------------------------------------------
func _ee_zero_radius_is_pass_through() -> void:
	print("[EE] radius = 0 passes the input through unchanged")
	var m := _speckled_mask()
	var got := _eval(m, 0, 0.0, 0, 1, 1.0)
	var d := _max_abs_diff(got, m)
	print("    max |expand(r=0) - in| = %.9f (want 0)" % d)
	if d > 0.0:
		_fail += 1; print("    !! a zero radius is still modifying the field")
	# CONTROL: a real radius must change it, or EE passes for a node that does nothing at all.
	var moved := _max_abs_diff(_eval(m, 0, 20.0, 0, 1, 1.0), m)
	print("    control: radius 20 m changes the field by %.3f (want > 0.5)" % moved)
	if moved <= 0.5:
		_fail += 1; print("    !! control dead — the radius is being ignored")


# --- EA. close is idempotent once the gaps are already filled ----------------------------------------
func _ea_close_is_idempotent_on_coarse_features() -> void:
	print("[EA] CLOSE applied twice equals CLOSE applied once (idempotence)")
	# Idempotence is the defining algebraic property of opening and closing, and it is the cheapest
	# statement that the two half-operations are exact inverses on the features that survive.
	var m := _speckled_mask()
	var once := _eval(m, 3, 15.0, 0, 1, 1.0)
	var twice := _eval(once, 3, 15.0, 0, 1, 1.0)
	var d := _max_abs_diff(once, twice)
	print("    max |close(close(x)) - close(x)| = %.9f (want < 1e-5)" % d)
	if d > 1.0e-5:
		_fail += 1; print("    !! CLOSE is not idempotent — the dilate and erode passes disagree on the kernel")
	# CONTROL: EXPAND is NOT idempotent, so this comparison can actually fail.
	var e1 := _eval(m, 0, 15.0, 0, 1, 1.0)
	var e2 := _eval(e1, 0, 15.0, 0, 1, 1.0)
	var cd := _max_abs_diff(e1, e2)
	print("    control: EXPAND twice differs from once by %.3f (want > 0.5)" % cd)
	if cd <= 0.5:
		_fail += 1; print("    !! control dead — every operation looks idempotent here")


# --- EB. open removes sub-radius speckle and keeps the big blob --------------------------------------
func _eb_open_removes_speckle_only() -> void:
	print("[EB] OPEN removes features smaller than the radius, keeps larger ones")
	var m := _speckled_mask()
	var opened := _eval(m, 2, 18.0, 0, 1, 1.0)

	# The speckle sits in a band the blob does not reach, so the two populations can be counted apart.
	var speck_before := _count_in(m, _speckle_region())
	var speck_after := _count_in(opened, _speckle_region())
	var blob_before := _count_in(m, _blob_region())
	var blob_after := _count_in(opened, _blob_region())
	print("    speckle cells: %d -> %d (want a large drop)" % [speck_before, speck_after])
	print("    blob cells:    %d -> %d (want almost unchanged)" % [blob_before, blob_after])
	if speck_after > speck_before / 4:
		_fail += 1; print("    !! OPEN did not remove the sub-radius speckle")
	if blob_after < blob_before * 0.8:
		_fail += 1; print("    !! OPEN ate the large feature it was supposed to preserve")


# --- EC. the radius is metres ------------------------------------------------------------------------
func _ec_radius_is_metric() -> void:
	print("[EC] the same world radius grows a mask by the same WORLD distance at two resolutions")
	var radius := 24.0
	var lo_n := 65
	var hi_n := 129
	var lo := _eval_at(_disc_mask(lo_n, 50.0), lo_n, 0, radius, 0, 1, 1.0)
	var hi := _eval_at(_disc_mask(hi_n, 50.0), hi_n, 0, radius, 0, 1, 1.0)

	# Measure the grown disc by its area, converted to metres², which is resolution-independent.
	var area_lo := _set_area(lo, lo_n)
	var area_hi := _set_area(hi, hi_n)
	var want_r := 50.0 + radius
	var want_area := PI * want_r * want_r
	print("    grown area: %.0f m^2 (65^2) vs %.0f m^2 (129^2), ideal %.0f m^2" % [area_lo, area_hi, want_area])
	var rel := absf(area_lo - area_hi) / maxf(area_hi, 1.0)
	print("    relative difference = %.4f (want < 0.06)" % rel)
	if rel > 0.06:
		_fail += 1; print("    !! the radius is behaving as CELLS — it grows further on the finer grid")

	# CONTROL: a radius genuinely measured in cells would differ by roughly the resolution ratio. Show
	# that this fixture is sensitive enough to see that, by comparing against the halved-radius run.
	var half := _eval_at(_disc_mask(hi_n, 50.0), hi_n, 0, radius * 0.5, 0, 1, 1.0)
	var area_half := _set_area(half, hi_n)
	var crel := absf(area_lo - area_half) / maxf(area_half, 1.0)
	print("    control: half the radius gives %.0f m^2, a relative difference of %.4f (want > 0.06)"
			% [area_half, crel])
	if crel <= 0.06:
		_fail += 1; print("    !! control dead — this fixture cannot tell two different radii apart")


# --- ED. native == oracle ----------------------------------------------------------------------------
func _ed_native_matches_oracle() -> void:
	print("[ED] native expand_shrink_grid == the naive GDScript oracle, in every mode")
	if not ClassDB.class_has_method("Pasture3DUtil", "expand_shrink_grid"):
		_fail += 1; print("    !! Pasture3DUtil.expand_shrink_grid is not bound — rebuild the GDExtension")
		return
	var surf := _bumps()
	var names := ["EXPAND", "SHRINK", "OPEN", "CLOSE", "GRADIENT"]
	for kern in [0, 1]:
		for mode in range(5):
			var native := _eval(surf, mode, 12.0, kern, 1, 1.0)
			var oracle := Pasture3DGraphNodeDevExpandShrink.new()
			oracle.mode = mode
			oracle.radius = 12.0
			oracle.kernel = kern
			oracle.iterations = 1
			oracle.amount = 1.0
			var want: PackedFloat32Array = oracle.solve(surf, GW, GH, RECT)
			var d := _max_abs_diff(native, want)
			var kname := "SQUARE" if kern == 1 else "DISC"
			print("    %-6s %-8s max |native - oracle| = %.9f" % [kname, names[mode], d])
			if d > PARITY_EPS:
				_fail += 1
				print("      !! disagreement — the two traversals are walking DIFFERENT structuring elements")
	# CONTROL: the oracle must actually be doing something.
	var oracle_e := Pasture3DGraphNodeDevExpandShrink.new()
	oracle_e.radius = 12.0
	var moved := _max_abs_diff(oracle_e.solve(surf, GW, GH, RECT), surf)
	print("    control: the oracle moved the field by %.3f m (want > 0.5)" % moved)
	if moved <= 0.5:
		_fail += 1; print("    !! control dead — the oracle returned the input unchanged")


# --- EG. GPU parity ----------------------------------------------------------------------------------
func _eg_gpu_parity() -> void:
	print("[EG] a graph containing ExpandShrink still takes the GPU path")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		_fail += 1; print("    !! Pasture3DUtil.graph_eval_grid_gpu is not bound — rebuild the GDExtension")
		return
	var surf := _bumps()
	var names := ["EXPAND", "SHRINK", "OPEN", "CLOSE", "GRADIENT"]
	for kern in [0, 1]:
		for mode in range(5):
			var g := _graph(mode, 12.0, kern, 1, 1.0)
			var gpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
					g.compile_graph_program(), GW, GH, RECT, surf)
			if gpu.is_empty():
				var ctrl: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
						_build_graph([]).compile_graph_program(), GW, GH, RECT, surf)
				if ctrl.is_empty():
					print("    NO-SIGNAL: no local RenderingDevice — GPU route unverified. Re-run windowed.")
					return
				_fail += 1
				print("    !! the GPU bailed on ExpandShrink but not on a bare in->out graph;")
				print("       the bail is graph-wide, so this drops EVERY node to the CPU.")
				return
			var cpu := _eval(surf, mode, 12.0, kern, 1, 1.0)
			var d := _max_abs_diff(gpu, cpu)
			var kname := "SQUARE" if kern == 1 else "DISC"
			print("    %-6s %-8s max |gpu - cpu| = %.8f" % [kname, names[mode], d])
			if d > GPU_TOL:
				_fail += 1; print("      !! the GPU gather and the CPU decomposition disagree")
	# CONTROL: the GPU must have actually changed the field, not returned a copy of the input.
	var probe: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
			_graph(0, 12.0, 0, 1, 1.0).compile_graph_program(), GW, GH, RECT, surf)
	if not probe.is_empty():
		var amp := _max_abs_diff(probe, surf)
		print("    control: the GPU moved the field by %.3f m (want > 0.5)" % amp)
		if amp <= 0.5:
			_fail += 1; print("    !! NO-SIGNAL — the GPU returned the input unchanged")


# --- helpers ------------------------------------------------------------------------------------------
func _graph(p_mode: int, p_radius: float, p_kernel: int, p_iter: int,
		p_amount: float) -> Pasture3DTerrainGraph:
	var n := Pasture3DGraphNodeExpandShrink.new()
	n.mode = p_mode
	n.radius = p_radius
	n.kernel = p_kernel
	n.iterations = p_iter
	n.amount = p_amount
	return _build_graph([n])


func _eval(p_in: PackedFloat32Array, p_mode: int, p_radius: float, p_kernel: int, p_iter: int,
		p_amount: float) -> PackedFloat32Array:
	return _graph(p_mode, p_radius, p_kernel, p_iter, p_amount).evaluate(GW, GH, RECT, null, p_in)


func _eval_at(p_in: PackedFloat32Array, p_n: int, p_mode: int, p_radius: float, p_kernel: int,
		p_iter: int, p_amount: float) -> PackedFloat32Array:
	return _graph(p_mode, p_radius, p_kernel, p_iter, p_amount).evaluate(p_n, p_n, RECT, null, p_in)


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


## One large blob plus a field of single-cell speckle, in world regions that do not overlap so the two
## populations can be counted separately.
func _speckled_mask() -> PackedFloat32Array:
	var m := PackedFloat32Array()
	m.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var w := _cell_world(ix, iz, GW)
			m[iz * GW + ix] = 1.0 if w.distance_to(Vector2(-70.0, -70.0)) < 45.0 else 0.0
	# Speckle: isolated single cells, each far smaller than the 18 m test radius.
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	for _k in 120:
		var ix := rng.randi_range(GW / 2 + 2, GW - 3)
		var iz := rng.randi_range(2, GH - 3)
		m[iz * GW + ix] = 1.0
	return m


func _speckle_region() -> Rect2i:
	return Rect2i(GW / 2 + 1, 0, GW - GW / 2 - 1, GH)


func _blob_region() -> Rect2i:
	return Rect2i(0, 0, GW / 2, GH)


func _count_in(p_g: PackedFloat32Array, p_r: Rect2i) -> int:
	var c := 0
	for iz in range(p_r.position.y, p_r.position.y + p_r.size.y):
		for ix in range(p_r.position.x, p_r.position.x + p_r.size.x):
			if p_g[iz * GW + ix] > 0.5:
				c += 1
	return c


func _disc_mask(p_n: int, p_radius_m: float) -> PackedFloat32Array:
	var m := PackedFloat32Array()
	m.resize(p_n * p_n)
	for iz in p_n:
		for ix in p_n:
			m[iz * p_n + ix] = 1.0 if _cell_world(ix, iz, p_n).length() < p_radius_m else 0.0
	return m


## Area of the set in metres², which is the resolution-independent way to compare two grids.
func _set_area(p_g: PackedFloat32Array, p_n: int) -> float:
	var cell := (RECT.size.x / float(p_n)) * (RECT.size.y / float(p_n))
	var c := 0
	for i in p_g.size():
		if p_g[i] > 0.5:
			c += 1
	return float(c) * cell


## Continuous relief, so min/max differences are graded rather than binary — a binary fixture would let
## a wrong-by-one-cell kernel agree with the oracle everywhere the value happens to be flat.
func _bumps() -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var w := _cell_world(ix, iz, GW)
			a[iz * GW + ix] = 30.0 * sin(w.x * 0.021) * cos(w.y * 0.013) + 9.0 * sin(w.y * 0.05 + 0.7)
	return a


func _cell_world(p_ix: int, p_iz: int, p_n: int) -> Vector2:
	return Pasture3DTerrainGraph.cell_to_world(p_ix, p_iz, p_n, p_n, RECT)


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
