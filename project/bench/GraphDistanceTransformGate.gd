# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphDistanceTransformGate — Pasture3DGraphNodeDistanceTransform, phase 2 of
# PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md §5.1. Criteria DA-DG.
#
# DB IS THE ONE THAT MATTERS. Hesiod measures distance in grid cells because its domain is the unit
# square; Pasture3D measures in metres. A kernel that forgets the conversion still produces a plausible
# picture at ONE resolution and silently rescales at every other — which is exactly the Salève bug this
# project already paid for once. DB bakes the same world rect at two grid sizes and demands the same
# metre distances.
#
# DF is the accuracy criterion. The kernel runs jump flooding, which is approximate; the gate computes an
# EXACT brute-force field as ground truth and requires JFA to land within one cell of it. Note that the
# oracle (DD) also runs JFA — it has to, or parity would be measuring the algorithm's error rather than
# the port's. DD and DF check different things and the gate needs both.
#
# Run WINDOWED, not --headless: DG has no RenderingDevice under --headless and can only report NO-SIGNAL.
#   Godot_v4.7-stable_win64_console.exe --path project bench/GraphDistanceTransformGate.tscn
extends Node

const GW := 64
const GH := 64
const RECT := Rect2(-160.0, -160.0, 320.0, 320.0)
## Native-vs-oracle: both sides accumulate in double, so this is a true bit-level budget.
const PARITY_EPS := 2.0e-6
## GPU-vs-CPU: the shader accumulates in float32. Matches GraphGpuParityGate.TOL.
const GPU_TOL := 1.0e-3

var _fail := 0


func _ready() -> void:
	print("=== GraphDistanceTransformGate: metric distance fields (§5.1) ===\n")
	_de_signal_guard()
	_da_single_seed_is_exact_euclid()
	_db_metric_invariance()
	_dc_signed_changes_sign_at_the_contour()
	_dd_native_matches_oracle()
	_df_jfa_is_within_a_cell_of_exact()
	_dg_gpu_parity()
	print("\n=== %s (%d failures) ===\n" % ["DISTANCE TRANSFORM PASS" if _fail == 0 else "DISTANCE TRANSFORM FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- DE. the fixture mask actually has two sides -----------------------------------------------------
func _de_signal_guard() -> void:
	print("[DE] NO-SIGNAL guard: the mask has an inside AND an outside")
	var m := _blob_mask()
	var inside := 0
	for i in m.size():
		if m[i] > 0.5:
			inside += 1
	print("    inside cells = %d of %d" % [inside, m.size()])
	if inside == 0 or inside == m.size():
		_fail += 1; print("    !! NO-SIGNAL — a uniform mask has no boundary, so every distance is degenerate")


# --- DA. one seed cell gives exactly the Euclidean distance to it ------------------------------------
func _da_single_seed_is_exact_euclid() -> void:
	print("[DA] a single interior seed yields cell_size * sqrt(i^2 + j^2)")
	var m := PackedFloat32Array()
	m.resize(GW * GH)
	var sx := GW / 2
	var sz := GH / 2
	m[sz * GW + sx] = 1.0

	var got := _solve(m, 0, 0, 0, 0.0) # OUTSIDE, EUCLIDEAN, METRES, unbounded
	var dx := RECT.size.x / float(GW)
	var dz := RECT.size.y / float(GH)

	# Only near the seed: far cells are where JFA is allowed to be approximate, and DF is the criterion
	# that measures that. Here we are checking the METRIC, not the flooding.
	var worst := 0.0
	for iz in range(sz - 8, sz + 9):
		for ix in range(sx - 8, sx + 9):
			var want := sqrt(pow((ix - sx) * dx, 2.0) + pow((iz - sz) * dz, 2.0))
			worst = maxf(worst, absf(got[iz * GW + ix] - want))
	print("    max |d - sqrt(i^2+j^2)*cell| near the seed = %.9f (want < 1e-5)" % worst)
	if worst > 1.0e-5:
		_fail += 1; print("    !! the Euclidean metric is wrong")

	# CONTROL: Manhattan must FAIL this comparison, or DA would pass for any metric at all.
	var manh := _solve(m, 0, 1, 0, 0.0)
	var mworst := 0.0
	for iz in range(sz - 8, sz + 9):
		for ix in range(sx - 8, sx + 9):
			var want := sqrt(pow((ix - sx) * dx, 2.0) + pow((iz - sz) * dz, 2.0))
			mworst = maxf(mworst, absf(manh[iz * GW + ix] - want))
	print("    control: Manhattan differs from Euclidean by %.4f m (want > 1.0)" % mworst)
	if mworst <= 1.0:
		_fail += 1; print("    !! control dead — the metric selector is being ignored")


# --- DB. distances are METRES, not cells -------------------------------------------------------------
func _db_metric_invariance() -> void:
	print("[DB] the same world rect at two resolutions gives the same METRE distances")
	# A disc defined in WORLD space, so the two grids describe the same shape rather than the same
	# cell pattern. Sampling the same geometry is what makes the comparison meaningful.
	var lo_n := 65
	var hi_n := 129
	var lo := _solve_at(_disc_mask(lo_n, 60.0), lo_n, 0, 0, 0, 0.0)
	var hi := _solve_at(_disc_mask(hi_n, 60.0), hi_n, 0, 0, 0, 0.0)

	# Compare at coincident world points: the centre of each coarse cell also exists on the fine grid.
	var worst := 0.0
	for iz in range(4, lo_n - 4):
		for ix in range(4, lo_n - 4):
			var w := _cell_world(ix, iz, lo_n)
			var fi := _nearest_index(w, hi_n)
			worst = maxf(worst, absf(lo[iz * lo_n + ix] - hi[fi]))

	var cell_lo := RECT.size.x / float(lo_n)
	print("    max |d(65^2) - d(129^2)| = %.4f m (want < one coarse cell = %.4f m)" % [worst, cell_lo])
	if worst > cell_lo:
		_fail += 1; print("    !! distances are resolution-dependent — the kernel is measuring in CELLS, not metres")

	# CONTROL: a deliberately cell-measured field must fail the same comparison. Without this, DB passes
	# for a kernel that returns a constant.
	var lo_cells := lo.duplicate()
	for i in lo_cells.size():
		lo_cells[i] /= cell_lo
	var cworst := 0.0
	for iz in range(4, lo_n - 4):
		for ix in range(4, lo_n - 4):
			var w := _cell_world(ix, iz, lo_n)
			cworst = maxf(cworst, absf(lo_cells[iz * lo_n + ix] - hi[_nearest_index(w, hi_n)]))
	print("    control: the same field expressed in CELLS differs by %.4f m (want > %.4f)" % [cworst, cell_lo])
	if cworst <= cell_lo:
		_fail += 1; print("    !! control dead — cells and metres are indistinguishable in this fixture")


# --- DC. SIGNED crosses zero at the threshold contour ------------------------------------------------
func _dc_signed_changes_sign_at_the_contour() -> void:
	print("[DC] SIGNED is negative inside, positive outside, zero on the boundary")
	var m := _blob_mask()
	var signed := _solve(m, 2, 0, 0, 0.0)

	var wrong := 0
	var max_in := -INF
	var min_out := INF
	for i in m.size():
		var d := signed[i]
		if m[i] > 0.5:
			if d > 0.0:
				wrong += 1
			max_in = maxf(max_in, d)
		else:
			if d < 0.0:
				wrong += 1
			min_out = minf(min_out, d)
	print("    cells on the wrong side of zero: %d (want 0)" % wrong)
	print("    deepest inside = %.3f m, nearest outside = %.3f m" % [max_in, min_out])
	if wrong > 0:
		_fail += 1; print("    !! the sign does not follow the threshold contour")
	# CONTROL: the field must actually reach both signs, or "no wrong cells" is vacuous.
	var lo := INF
	var hi := -INF
	for i in signed.size():
		lo = minf(lo, signed[i])
		hi = maxf(hi, signed[i])
	print("    control: range %.3f .. %.3f m (want to straddle 0 by > 1 m each way)" % [lo, hi])
	if lo > -1.0 or hi < 1.0:
		_fail += 1; print("    !! NO-SIGNAL — the signed field never reaches both sides")


# --- DD. native == oracle ----------------------------------------------------------------------------
func _dd_native_matches_oracle() -> void:
	print("[DD] native distance_transform_grid == the GDScript oracle (both run JFA)")
	if not ClassDB.class_has_method("Pasture3DUtil", "distance_transform_grid"):
		_fail += 1; print("    !! Pasture3DUtil.distance_transform_grid is not bound — rebuild the GDExtension")
		return
	var m := _random_mask(20260829)
	var native := _solve(m, 2, 0, 0, 0.0)

	var oracle := Pasture3DGraphNodeDevDistanceTransform.new()
	oracle.threshold = 0.5
	oracle.direction = 2
	oracle.metric = 0
	oracle.output_units = 0
	oracle.max_distance = 0.0
	var want: PackedFloat32Array = oracle.solve(m, GW, GH, RECT)

	var d := _max_abs_diff(native, want)
	print("    max |native - oracle| = %.9f (want < %.9f)" % [d, PARITY_EPS])
	if d > PARITY_EPS:
		_fail += 1; print("    !! the C++ kernel and the oracle disagree — they must run the SAME JFA schedule")
	var amp := 0.0
	for i in want.size():
		amp = maxf(amp, absf(want[i]))
	print("    control: the oracle produced a non-trivial field, max |d| = %.3f m (want > 1.0)" % amp)
	if amp <= 1.0:
		_fail += 1; print("    !! control dead — the oracle returned a flat field")


# --- DF. jump flooding is within a cell of the exact answer ------------------------------------------
func _df_jfa_is_within_a_cell_of_exact() -> void:
	print("[DF] JFA lands within one cell of an EXACT distance field")
	var m := _random_mask(4242)
	var got := _solve(m, 0, 0, 0, 0.0)
	var exact := _exact_distance(m)

	var dx := RECT.size.x / float(GW)
	var worst := 0.0
	var over := 0
	for i in got.size():
		var e := absf(got[i] - exact[i])
		worst = maxf(worst, e)
		if e > dx:
			over += 1
	print("    max |JFA - exact| = %.4f m, cells beyond one cell (%.3f m): %d" % [worst, dx, over])
	if over > 0:
		_fail += 1; print("    !! jump flooding is drifting further than a cell — the +1 repair pass is not enough here")
	# JFA is never BELOW the exact distance: it can only fail to find a nearer seed, never invent one.
	var under := 0
	for i in got.size():
		if got[i] < exact[i] - 1.0e-4:
			under += 1
	print("    control: cells reporting LESS than the exact distance = %d (want 0)" % under)
	if under > 0:
		_fail += 1; print("    !! a cell claims to be closer than its true nearest seed — the seeding is wrong")


# --- DG. GPU parity ----------------------------------------------------------------------------------
func _dg_gpu_parity() -> void:
	print("[DG] a graph containing DistanceTransform still takes the GPU path")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		_fail += 1; print("    !! Pasture3DUtil.graph_eval_grid_gpu is not bound — rebuild the GDExtension")
		return
	var m := _blob_mask()
	var g := _graph(2, 0, 0, 0.0)
	# Calling the GPU evaluator directly is the ROUTE proof: it returns an empty array when it bails,
	# and it bails graph-wide, so a non-empty return is proof the JFA plan was actually dispatched.
	var gpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(g.compile_graph_program(), GW, GH, RECT, m)
	if gpu.is_empty():
		var ctrl: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
				_io_graph().compile_graph_program(), GW, GH, RECT, m)
		if ctrl.is_empty():
			print("    NO-SIGNAL: no local RenderingDevice (headless / no driver) — GPU route unverified.")
			print("    Re-run WITHOUT --headless to actually exercise the JFA compute path.")
			return
		_fail += 1
		print("    !! the GPU evaluator bailed on DistanceTransform but not on a bare in->out graph.")
		print("       The bail is graph-wide, so this drops EVERY node in the graph to the CPU.")
		return

	var cpu := _solve(m, 2, 0, 0, 0.0)
	var d := _max_abs_diff(gpu, cpu)
	print("    the GPU evaluator accepted the graph (the JFA plan dispatched)")
	print("    max |gpu - cpu| = %.8f (want < %.8f)" % [d, GPU_TOL])
	if d > GPU_TOL:
		_fail += 1; print("    !! the GPU JFA disagrees with the CPU JFA — same seeding, same pass schedule?")

	# The configuration the GPU deliberately DECLINES: normalised with no explicit divisor needs a
	# whole-field maximum, which this kernel cannot reduce. It must bail rather than invent a different
	# divisor and hand back a field that silently disagrees with the CPU.
	var norm := _graph(0, 0, 1, 0.0)
	var norm_gpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
			norm.compile_graph_program(), GW, GH, RECT, m)
	print("    control: NORMALISED with Max Distance 0 returns %d cells (want 0 — a deliberate bail)"
			% norm_gpu.size())
	if not norm_gpu.is_empty():
		_fail += 1; print("    !! the GPU accepted a config whose divisor it cannot compute")


# --- helpers ------------------------------------------------------------------------------------------
func _graph(p_dir: int, p_metric: int, p_units: int, p_max: float) -> Pasture3DTerrainGraph:
	var n := Pasture3DGraphNodeDistanceTransform.new()
	n.threshold = 0.5
	n.direction = p_dir
	n.metric = p_metric
	n.output_units = p_units
	n.max_distance = p_max
	return _build_graph([n])


func _solve(p_mask: PackedFloat32Array, p_dir: int, p_metric: int, p_units: int,
		p_max: float) -> PackedFloat32Array:
	return _graph(p_dir, p_metric, p_units, p_max).evaluate(GW, GH, RECT, null, p_mask)


func _solve_at(p_mask: PackedFloat32Array, p_n: int, p_dir: int, p_metric: int, p_units: int,
		p_max: float) -> PackedFloat32Array:
	return _graph(p_dir, p_metric, p_units, p_max).evaluate(p_n, p_n, RECT, null, p_mask)


func _io_graph() -> Pasture3DTerrainGraph:
	return _build_graph([])


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


## An off-centre blob, so nothing is symmetric enough to pass a criterion by accident.
func _blob_mask() -> PackedFloat32Array:
	var m := PackedFloat32Array()
	m.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var w := _cell_world(ix, iz, GW)
			var d := w.distance_to(Vector2(30.0, -20.0))
			m[iz * GW + ix] = 1.0 if d < 70.0 else 0.0
	return m


## A disc defined in WORLD metres, so the same call at two grid sizes describes the same shape.
func _disc_mask(p_n: int, p_radius_m: float) -> PackedFloat32Array:
	var m := PackedFloat32Array()
	m.resize(p_n * p_n)
	for iz in p_n:
		for ix in p_n:
			var w := _cell_world(ix, iz, p_n)
			m[iz * p_n + ix] = 1.0 if w.length() < p_radius_m else 0.0
	return m


func _random_mask(p_seed: int) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = p_seed
	var m := PackedFloat32Array()
	m.resize(GW * GH)
	for i in m.size():
		m[i] = 1.0 if rng.randf() < 0.06 else 0.0
	return m


## Brute-force ground truth for DF: every cell against every seed. O(n * seeds) and unashamedly slow —
## being obviously correct is the entire job.
func _exact_distance(p_mask: PackedFloat32Array) -> PackedFloat32Array:
	var dx := RECT.size.x / float(GW)
	var dz := RECT.size.y / float(GH)
	var seeds: Array[Vector2i] = []
	for iz in GH:
		for ix in GW:
			if p_mask[iz * GW + ix] > 0.5:
				seeds.append(Vector2i(ix, iz))

	var out := PackedFloat32Array()
	out.resize(GW * GH)
	var fallback := sqrt(pow(GW * dx, 2.0) + pow(GH * dz, 2.0))
	for iz in GH:
		for ix in GW:
			var best := fallback
			for s in seeds:
				var ax := absf(float(ix - s.x)) * dx
				var az := absf(float(iz - s.y)) * dz
				best = minf(best, sqrt(ax * ax + az * az))
			out[iz * GW + ix] = best
	return out


func _cell_world(p_ix: int, p_iz: int, p_n: int) -> Vector2:
	return Pasture3DTerrainGraph.cell_to_world(p_ix, p_iz, p_n, p_n, RECT)


func _nearest_index(p_world: Vector2, p_n: int) -> int:
	var dx := RECT.size.x / float(p_n)
	var dz := RECT.size.y / float(p_n)
	var ix := clampi(int((p_world.x - RECT.position.x) / dx), 0, p_n - 1)
	var iz := clampi(int((p_world.y - RECT.position.y) / dz), 0, p_n - 1)
	return iz * p_n + ix


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
