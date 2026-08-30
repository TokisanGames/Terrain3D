# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphGavoronoiseGate — spec §7.2. GA-GF, plus the native-route check.
#
# GB is the criterion that matters and the one that is easy to fake. "It looks dendritic" has TWO nulls,
# not one — a smooth blob and white noise — and no single scalar separates a branching field from both of
# them: smoothness alone calls the blob a winner, and structure alone calls the noise a winner. So GB
# measures two quantities, each against the null it exists to exclude, and runs both nulls as live
# controls rather than describing them. This is the same two-scalar approach the DLA gate uses.
#
# Run WINDOWED — the GPU criterion has no RenderingDevice under --headless.
#   Godot_v4.7-stable_win64_console.exe --path project bench/GraphGavoronoiseGate.tscn
extends Node

const GW := 128
const GH := 128
const RECT := Rect2(-1000.0, -1000.0, 2000.0, 2000.0)
const PARITY_EPS := 2.0e-6
## The GPU runs this in float32 while the CPU runs it in double, and the field is CHAOTIC: the derivative
## feedback means a last-bit difference in octave 0 is amplified by every octave after it. A tolerance
## scaled to the amplitude is the honest budget here, and it is stated as a fraction so it cannot quietly
## become slack when someone raises the amplitude in a fixture.
const GPU_TOL_FRACTION := 0.02

var _fail := 0


func _ready() -> void:
	print("=== GraphGavoronoiseGate: gradient-aware Voronoi (§7.2) ===\n")
	_ga_determinism()
	_gb_dendritic_not_blob_not_noise()
	_gc_strike_orients_the_ridges()
	_gd_amplitude_scales_linearly()
	_ge_parity_and_route()
	_gf_resolution_invariance()
	_gg_gpu()
	print("\n=== %s (%d failures) ===\n" % ["GAVORONOISE PASS" if _fail == 0 else "GAVORONOISE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- GA. the field is a pure function of the seed -----------------------------------------------------
func _ga_determinism() -> void:
	print("[GA] the field is a pure function of the seed")
	var a := _gen({"seed": 7})
	var b := _gen({"seed": 7})
	var d := _max_abs_diff(a, b)
	print("    two evaluations at seed 7 differ by %.9f (want 0 exactly)" % d)
	if d > 0.0:
		_fail += 1; print("    !! the generator is not deterministic")

	# CONTROL: a different seed must give a different field, or GA passes for a constant.
	var c := _gen({"seed": 8})
	var cd := _max_abs_diff(a, c)
	print("    control: seed 8 differs from seed 7 by %.4f m (want > 1.0)" % cd)
	if cd <= 1.0:
		_fail += 1; print("    !! control dead — the seed does not change the field")


# --- GB. dendritic: not a blob, not noise -------------------------------------------------------------
func _gb_dendritic_not_blob_not_noise() -> void:
	print("[GB] the field is DENDRITIC — measured against both nulls, each with a live control")
	var field := _gen({})

	# The blob null: a heavily smoothed version of the same field. Smooth, and structureless.
	var blob := _smoothed(field, 24)
	# The noise null: white noise of the same amplitude and mean.
	var noise := _white_noise_like(field)

	# Scalar 1 — RIDGE CONNECTIVITY. Of the cells in the top decile, what fraction has at least two
	# top-decile neighbours? A branch is a connected line, so its cells have neighbours along it. White
	# noise scatters its top decile and scores low. This is the scalar that EXCLUDES THE NOISE NULL.
	var conn_field := _ridge_connectivity(field)
	var conn_noise := _ridge_connectivity(noise)
	print("    connectivity  field %.3f  vs  white-noise null %.3f (want field clearly higher)"
			% [conn_field, conn_noise])
	if conn_field <= conn_noise + 0.15:
		_fail += 1; print("    !! the top decile is scattered like noise — no connected ridges")

	# Scalar 2 — HIGH-FREQUENCY ENERGY. The mean absolute Laplacian, normalised by relief. A blob has
	# almost none. This is the scalar that EXCLUDES THE BLOB NULL. Connectivity alone would not: a smooth
	# blob's top decile is perfectly connected, and would score BETTER than the real field.
	var hf_field := _high_frequency_energy(field)
	var hf_blob := _high_frequency_energy(blob)
	print("    hf energy     field %.5f  vs  smooth-blob null %.5f (want field clearly higher)"
			% [hf_field, hf_blob])
	if hf_field <= hf_blob * 2.0:
		_fail += 1; print("    !! the field is as smooth as a blob — there is no ridge structure in it")

	# And the honest part: state that each null BEATS the field on the other scalar, which is exactly why
	# one scalar could never have done this job.
	var conn_blob := _ridge_connectivity(blob)
	var hf_noise := _high_frequency_energy(noise)
	print("    (the blob scores %.3f on connectivity and the noise %.5f on hf energy — each null wins"
			% [conn_blob, hf_noise])
	print("     on the scalar it is not being judged by, which is why GB needs two.)")
	if conn_blob < conn_field and hf_noise < hf_field:
		_fail += 1
		print("    !! NO-SIGNAL: the field beat BOTH nulls on BOTH scalars. That means the nulls are not")
		print("       behaving as nulls here, so GB has not actually excluded anything.")


# --- GC. strike orientation ---------------------------------------------------------------------------
func _gc_strike_orients_the_ridges() -> void:
	print("[GC] angle_deg rotates the ridges; angle_spread = 0 makes them parallel")
	# With spread 0 the feature points sit on an exact lattice row, so the structure is banded. Measure
	# anisotropy as the ratio of mean |gradient| across the strike to along it: parallel bands vary
	# strongly across and barely at all along.
	var at0 := _anisotropy(_gen({"angle_deg": 0.0, "angle_spread": 0.0}), 0.0)
	var at90 := _anisotropy(_gen({"angle_deg": 90.0, "angle_spread": 0.0}), 90.0)
	print("    anisotropy measured in the strike frame: 0deg %.2f, 90deg %.2f (want both > 2.0)"
			% [at0, at90])
	if at0 <= 2.0 or at90 <= 2.0:
		_fail += 1; print("    !! spread 0 did not produce parallel ridges")

	# The rotation is real and not a relabelling: measure the 90-degree field in the WRONG (0 degree)
	# frame and the anisotropy must collapse.
	var wrong_frame := _anisotropy(_gen({"angle_deg": 90.0, "angle_spread": 0.0}), 0.0)
	print("    the 90deg field measured in the 0deg frame gives %.2f (want < 1.0 — it rotated)"
			% wrong_frame)
	if wrong_frame >= 1.0:
		_fail += 1; print("    !! angle_deg did not rotate the structure")

	# CONTROL: full spread must destroy the banding, or GC passes for a node whose output is always banded.
	var spread_full := _anisotropy(_gen({"angle_deg": 0.0, "angle_spread": 1.0}), 0.0)
	print("    control: spread 1.0 gives %.2f (want < %.2f — the banding is gone)" % [spread_full, at0])
	if spread_full >= at0:
		_fail += 1; print("    !! control dead — angle_spread has no effect on the banding")


# --- GD. amplitude scales linearly --------------------------------------------------------------------
func _gd_amplitude_scales_linearly() -> void:
	print("[GD] amplitude scales the field linearly")
	var a := _gen({"amplitude": 50.0})
	var b := _gen({"amplitude": 150.0})
	var worst := 0.0
	for i in a.size():
		worst = maxf(worst, absf(b[i] - a[i] * 3.0))
	print("    max |f(150) - 3*f(50)| = %.6f m (want < 1e-3)" % worst)
	if worst > 1.0e-3:
		_fail += 1; print("    !! amplitude is not a pure output scale — it is feeding back into the shape")
	if _relief(a) <= 1.0:
		_fail += 1; print("    !! NO-SIGNAL — the field is flat, so linearity was checked against nothing")


# --- GE. parity + the native route --------------------------------------------------------------------
func _ge_parity_and_route() -> void:
	print("[GE] native == oracle, and the node takes the native C++ route")
	var g := _build_graph(_node({}))
	var supported: bool = g.native_supported()
	print("    native_supported() = %s (want true)" % str(supported))
	if not supported:
		_fail += 1
		print("    !! the op is missing from the SUPPORTED list in native_supported(). This does not fail")
		print("       loudly — it drops the WHOLE graph onto the GDScript evaluator.")
		return
	var native := g.evaluate(GW, GH, RECT, null, PackedFloat32Array())

	var dev := Pasture3DGraphNodeDevGavoronoise.new()
	for k in _defaults():
		dev.set(k, _defaults()[k])
	var oracle: PackedFloat32Array = dev.solve(GW, GH, RECT)

	# TWO parity claims, kept apart on purpose.
	#
	# The first is the real one: the C++ kernel against the oracle, both fed identical DOUBLE parameters.
	# Nothing is allowed to differ here, so the budget is the usual 2e-6.
	var cfg := _defaults()
	var direct: PackedFloat32Array = Pasture3DUtil.gavoronoise_grid(GW, GH, RECT, cfg["amplitude"],
			cfg["frequency"], cfg["octaves"], cfg["seed"], cfg["angle_deg"], cfg["angle_spread"],
			cfg["slope_strength"], cfg["branch_strength"], cfg["z_cut_min"], cfg["z_cut_max"])
	var dk := _max_abs_diff(direct, oracle)
	print("    kernel vs oracle (identical doubles): %.9f (want < %.9f)" % [dk, PARITY_EPS])
	if dk > PARITY_EPS:
		_fail += 1; print("    !! the C++ kernel and the oracle disagree — the hash or the feedback has drifted")

	# The second is the graph ROUTE, and it cannot hold to 2e-6 for an honest reason: GraphProgram stores
	# its parameters as float32, so `frequency` reaches the kernel as 0.0005000000237 rather than 0.0005.
	# The field is chaotic — the derivative feedback amplifies any difference through every later octave —
	# so that last-bit change is worth a few thousandths of a metre in the output. Holding the route to the
	# kernel's own budget would be measuring float32 storage, not correctness.
	var dr := _max_abs_diff(native, direct)
	var route_budget := 0.001 * maxf(_relief(direct), 1.0)
	print("    graph route vs kernel: %.6f m (budget %.6f m = 0.1%% of relief; float32 params)"
			% [dr, route_budget])
	if dr > route_budget:
		_fail += 1; print("    !! the graph route differs by more than float32 parameter storage explains")
	if _relief(native) <= 1.0:
		_fail += 1; print("    !! NO-SIGNAL — the field is flat, so parity compared two flat grids")


# --- GF. resolution invariance ------------------------------------------------------------------------
func _gf_resolution_invariance() -> void:
	print("[GF] frequency is cycles per METRE — the same rect gives the same ridge spacing")
	var lo_n := 96
	var hi_n := 192
	# A LOWER frequency than the other criteria use, and the reason is not cosmetic. At the default
	# 0.002 cycles/m the fourth octave has a 62 m wavelength against a 20.8 m cell — barely above Nyquist —
	# so two resolutions sample genuinely different points of the same field. That is ALIASING, not a units
	# error, and a gate that let it stand would be blaming the node for the fixture. At 0.0005 the finest
	# octave spans about twelve coarse cells.
	var base := {"frequency": 0.0005}
	var lo := _gen_at(base, lo_n)
	var hi := _gen_at(base, hi_n)
	var relief := _relief(lo)

	# The statistic is the 99th PERCENTILE of the difference, not the maximum, and that is a real
	# concession rather than a loosened tolerance. This field is chaotic exactly at Voronoi cell walls: a
	# sample a hair either side of a wall picks a different winning feature point, its gradient flips, and
	# the derivative feedback amplifies that through every later octave. Those cells are a thin set and
	# they genuinely differ between two samplings of the SAME continuous field. The claim being tested is
	# that the field is the same field — a bulk property — so it is measured in bulk, and the maximum is
	# reported alongside so the concession is visible rather than hidden.
	var diffs := _resolution_diffs(lo, lo_n, hi, hi_n)
	var p99 := _percentile(diffs, 0.99)
	var worst := _percentile(diffs, 1.0)
	print("    |f(96^2) - f(192^2)|: p99 %.3f m, max %.3f m, over %.1f m relief (want p99 < 5%%)"
			% [p99, worst, relief])
	if p99 > 0.05 * relief:
		_fail += 1
		print("    !! the field changed with the grid. A `frequency / gw` implementation fails exactly")
		print("       here: it halves the ridge spacing every time the bake resolution doubles.")

	# CONTROL: halving the frequency must change the field by more than the tolerance, measured the same
	# way. Without it, GF would pass for a node that ignores `frequency` entirely.
	var halved := _gen_at({"frequency": 0.00025}, hi_n)
	var cw := _percentile(_resolution_diffs(lo, lo_n, halved, hi_n), 0.99)
	print("    control: half the frequency moves p99 to %.3f m (want > %.3f)" % [cw, 0.05 * relief])
	if cw <= 0.05 * relief:
		_fail += 1; print("    !! control dead — this fixture cannot tell two frequencies apart")


## Per-cell |difference| between a coarse grid and a fine one, at the coarse grid's world points.
##
## The fine grid is read BILINEARLY, not by nearest cell. Cell centres sit at (i + 0.5) * d, so a coarse
## centre never coincides with a fine one — the nearest fine cell is always half a fine cell away in each
## axis, and on a field with this much local slope that offset alone contributes more than the criterion's
## whole budget. Reading between the fine cells removes a sampling artefact, not a real disagreement.
func _resolution_diffs(p_a: PackedFloat32Array, p_an: int, p_b: PackedFloat32Array,
		p_bn: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var dx := RECT.size.x / float(p_bn)
	var dz := RECT.size.y / float(p_bn)
	for iz in range(4, p_an - 4):
		for ix in range(4, p_an - 4):
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, p_an, p_an, RECT)
			var fx := (w.x - RECT.position.x) / dx - 0.5
			var fz := (w.y - RECT.position.y) / dz - 0.5
			var x0 := clampi(int(floor(fx)), 0, p_bn - 1)
			var z0 := clampi(int(floor(fz)), 0, p_bn - 1)
			var x1 := clampi(x0 + 1, 0, p_bn - 1)
			var z1 := clampi(z0 + 1, 0, p_bn - 1)
			var tx := clampf(fx - float(x0), 0.0, 1.0)
			var tz := clampf(fz - float(z0), 0.0, 1.0)
			var top: float = lerpf(p_b[z0 * p_bn + x0], p_b[z0 * p_bn + x1], tx)
			var bot: float = lerpf(p_b[z1 * p_bn + x0], p_b[z1 * p_bn + x1], tx)
			out.append(absf(p_a[iz * p_an + ix] - lerpf(top, bot, tz)))
	return out


# --- GPU route ----------------------------------------------------------------------------------------
func _gg_gpu() -> void:
	print("[gpu] the generator still takes the GPU path")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		_fail += 1; print("    !! Pasture3DUtil.graph_eval_grid_gpu is not bound — rebuild the GDExtension")
		return
	var g := _build_graph(_node({}))
	var gpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
			g.compile_graph_program(), GW, GH, RECT, PackedFloat32Array())
	if gpu.is_empty():
		var ctrl: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
				_io_graph().compile_graph_program(), GW, GH, RECT, PackedFloat32Array())
		if ctrl.is_empty():
			print("    NO-SIGNAL: no local RenderingDevice — GPU route unverified. Re-run windowed.")
			return
		_fail += 1
		print("    !! the GPU bailed on Gavoronoise but not on a bare in->out graph; the bail is")
		print("       graph-wide, so this drops EVERY node in the graph to the CPU.")
		return
	var cpu := g.evaluate(GW, GH, RECT, null, PackedFloat32Array())
	var d := _max_abs_diff(gpu, cpu)
	var budget := GPU_TOL_FRACTION * maxf(_relief(cpu), 1.0)
	print("    max |gpu - cpu| = %.5f m (budget %.5f m = %.0f%% of relief)"
			% [d, budget, GPU_TOL_FRACTION * 100.0])
	if d > budget:
		_fail += 1; print("    !! the GPU kernel disagrees with the CPU kernel beyond float32 divergence")
	if _relief(gpu) <= 1.0:
		_fail += 1; print("    !! NO-SIGNAL — the GPU returned a flat field")


# --- construction --------------------------------------------------------------------------------------
func _defaults() -> Dictionary:
	return {
		"amplitude": 100.0,
		"frequency": 0.002,
		"octaves": 4,
		"seed": 1234,
		"angle_deg": 0.0,
		"angle_spread": 1.0,
		"slope_strength": 1.0,
		"branch_strength": 2.0,
		"z_cut_min": 0.0,
		"z_cut_max": 1.0,
	}


func _node(p_over: Dictionary) -> Pasture3DGraphNode:
	var n := Pasture3DGraphNodeGavoronoise.new()
	var cfg := _defaults()
	for k in p_over:
		cfg[k] = p_over[k]
	for k in cfg:
		n.set(k, cfg[k])
	return n


func _gen(p_over: Dictionary) -> PackedFloat32Array:
	return _gen_at(p_over, GW)


func _gen_at(p_over: Dictionary, p_n: int) -> PackedFloat32Array:
	return _build_graph(_node(p_over)).evaluate(p_n, p_n, RECT, null, PackedFloat32Array())


func _build_graph(p_gen: Pasture3DGraphNode) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [p_gen, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 1, 0])]
	return g


func _io_graph() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 1, 0])]
	return g


# --- the two GB scalars ----------------------------------------------------------------------------
## Of the cells in the top decile, the fraction with at least two top-decile 8-neighbours. A ridge is a
## connected line, so its cells have company along it; white noise scatters its top decile and scores low.
func _ridge_connectivity(p_g: PackedFloat32Array) -> float:
	var t := _percentile(p_g, 0.90)
	var hits := 0
	var connected := 0
	for iz in range(1, GH - 1):
		for ix in range(1, GW - 1):
			if p_g[iz * GW + ix] < t:
				continue
			hits += 1
			var neighbours := 0
			for oz in range(-1, 2):
				for ox in range(-1, 2):
					if ox == 0 and oz == 0:
						continue
					if p_g[(iz + oz) * GW + (ix + ox)] >= t:
						neighbours += 1
			if neighbours >= 2:
				connected += 1
	return (float(connected) / float(hits)) if hits > 0 else 0.0


## Mean absolute Laplacian, normalised by relief. Near zero for a smooth blob whatever its shape.
func _high_frequency_energy(p_g: PackedFloat32Array) -> float:
	var total := 0.0
	var count := 0
	for iz in range(1, GH - 1):
		for ix in range(1, GW - 1):
			var i := iz * GW + ix
			var lap := p_g[i - 1] + p_g[i + 1] + p_g[i - GW] + p_g[i + GW] - 4.0 * p_g[i]
			total += absf(lap)
			count += 1
	return (total / float(count) / _relief(p_g)) if count > 0 else 0.0


## Mean |gradient| ACROSS the strike divided by mean |gradient| ALONG it, both measured in the frame
## rotated by p_angle_deg. Parallel bands vary strongly across and hardly at all along, so this is large.
func _anisotropy(p_g: PackedFloat32Array, p_angle_deg: float) -> float:
	var th := deg_to_rad(p_angle_deg)
	var cs := cos(th)
	var sn := sin(th)
	var along := 0.0
	var across := 0.0
	var count := 0
	for iz in range(1, GH - 1):
		for ix in range(1, GW - 1):
			var i := iz * GW + ix
			var gx := (p_g[i + 1] - p_g[i - 1]) * 0.5
			var gz := (p_g[i + GW] - p_g[i - GW]) * 0.5
			# Rotate the gradient INTO the strike frame: +x runs along the strike.
			along += absf(gx * cs + gz * sn)
			across += absf(-gx * sn + gz * cs)
			count += 1
	if count == 0 or along <= 1.0e-9:
		return 0.0
	return across / along


# --- fixtures and measurement --------------------------------------------------------------------
func _smoothed(p_g: PackedFloat32Array, p_passes: int) -> PackedFloat32Array:
	var cur := p_g.duplicate()
	for _p in p_passes:
		var nxt := cur.duplicate()
		for iz in range(1, GH - 1):
			for ix in range(1, GW - 1):
				var i := iz * GW + ix
				nxt[i] = (cur[i] + cur[i - 1] + cur[i + 1] + cur[i - GW] + cur[i + GW]) / 5.0
		cur = nxt
	return cur


func _white_noise_like(p_g: PackedFloat32Array) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var lo := INF
	var hi := -INF
	for i in p_g.size():
		lo = minf(lo, p_g[i])
		hi = maxf(hi, p_g[i])
	var out := PackedFloat32Array()
	out.resize(p_g.size())
	for i in out.size():
		out[i] = rng.randf_range(lo, hi)
	return out


func _percentile(p_g: PackedFloat32Array, p_q: float) -> float:
	var arr := Array(p_g)
	arr.sort()
	return arr[clampi(int(arr.size() * p_q), 0, arr.size() - 1)]


func _relief(p_g: PackedFloat32Array) -> float:
	var lo := INF
	var hi := -INF
	for i in p_g.size():
		if is_nan(p_g[i]):
			continue
		lo = minf(lo, p_g[i])
		hi = maxf(hi, p_g[i])
	return maxf(hi - lo, 0.0)


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
