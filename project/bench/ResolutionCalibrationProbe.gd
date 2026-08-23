# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# ResolutionCalibrationProbe — the phase 5 MEASUREMENT (PASTURE3D_BRUSH_EROSION_SPEC.md §8.1).
#
# NO VERDICT. This prints numbers so that gate CK's criteria can be set from what the solver actually
# does rather than from what the spec hoped it would. §8.1 says the phase begins with a measurement and
# names the case in which it changes shape; this is that measurement.
#
# THE QUESTION. PASTURE3D_SIM_NODE_SPEC §6 measured that a coarse solve erodes DEEPER than a fine one —
# 1.28x the delta RMS on a synthetic fixture, 2.5x at one demo probe — and declined to ship a correction
# because a preview is looked at and discarded. Amplification uses the coarse solve as an INPUT, so the
# error propagates, and the phase needs to know:
#
#   is that ratio a function of the DIVISOR ALONE, or also of relief, of erosion rate, and of the base
#   cell size the divisor is applied to?
#
# The first makes it a calibration curve. The second makes it a fudge factor fitted to whatever fixture
# was in front of us, and §8.1 commits the phase to changing shape rather than shipping one.
#
# HOW IT IS MEASURED, and the two choices that decide whether the number means anything:
#
# 1. THROUGH `erode_heightfield` DIRECTLY, not by driving a Pasture3DSim. The Sim adds its own grid
#    resampling and its own chunked solve; a ratio that could come from any of three places is not
#    evidence about one of them. Same reasoning as gate CD.
# 2. THE COARSE ARM IS SAMPLED, NOT DOWNSAMPLED. A coarse solve evaluates the terrain at coarser spacing —
#    it does not average a fine grid — so each fixture is defined as a CONTINUOUS function and every
#    resolution samples it. Downsampling would fold in a low-pass the real path never applies.
# 3. THE COMPARISON IS ON THE SAME CELLS. The coarse delta is bilinearly upsampled to the fine grid before
#    its RMS is taken, so both numbers are averages over identical sample points and the only difference
#    is what produced the field. It is also exactly what amplification would do with the coarse delta, so
#    what is measured is what would propagate.
# 4. THE BOUNDARY IS A FIXED PHYSICAL WIDTH. `erosion_solve` turns non-finite input into a fixed outlet,
#    so every fixture carries a NaN border of the same METRES at every resolution. A one-CELL border would
#    be a different physical boundary per arm, which is a confound sitting directly on the thing measured.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/ResolutionCalibrationProbe.tscn
extends Node

const DEMO_DATA := "res://demo/data"

## Fine grid, in cells. Every coarse arm is this divided by its divisor, so 256 keeps 2/4/8 exact.
const FINE := 256
## Outlet border, in METRES. See note 4.
const BORDER_M := 24.0
## Solver iterations, held constant across every arm — the question is about resolution, not budget.
const ITERATIONS := 60

var _terrain
var _rows: Array = []


func _ready() -> void:
	print("\n=== Resolution calibration (phase 5 §8.1 measurement — NO VERDICT) ===\n")
	var root := Node3D.new()
	add_child(root)
	_terrain = ClassDB.instantiate("Pasture3D")
	root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA

	# The sweep spans every axis the ratio is allowed to depend on, and the three it must not.
	for fixture in ["bowl", "y_catchment", "demo", "km_dome"]:
		for relief in [1.0, 3.0]:
			for rate in [0.03, 0.09, 0.27]:
				for cell in [1.0, 4.0]:
					_measure(fixture, relief, rate, cell)

	_report()
	_budget_stage()
	_saturation_stage(0.02)
	get_tree().quit(0)


## One fixture at one relief / rate / base cell size, solved at every divisor.
func _measure(p_fixture: String, p_relief: float, p_rate: float, p_cell: float) -> void:
	var base := _solve_at(p_fixture, p_relief, p_rate, p_cell, 1)
	if base.is_empty() or base["rms"] <= 0.0:
		print("  %-12s relief x%.0f rate %.2f cell %.0f m -> the fine arm eroded nothing; skipped"
			% [p_fixture, p_relief, p_rate, p_cell])
		return
	# LIVE is judged on the FINE arm alone — the reference — so the filter never depends on
	# the coarse result it is used to weigh.
	var row := {"fixture": p_fixture, "relief": p_relief, "rate": p_rate, "cell": p_cell,
			"fine_rms": base["rms"], "fine_cut": base["cut"],
			"left": base["relief_left"], "live": base["relief_left"] >= 0.25, "ratio": {}}
	for d in [2, 4, 8]:
		var arm := _solve_at(p_fixture, p_relief, p_rate, p_cell, d)
		if arm.is_empty():
			continue
		row["ratio"][d] = arm["rms"] / base["rms"]
	_rows.append(row)
	print("  %-12s relief x%.0f rate %.2f cell %.0f m | RMS %8.3f cut %7.3f relief left %5.1f%%%s | "
		% [p_fixture, p_relief, p_rate, p_cell, base["rms"], base["cut"], base["relief_left"] * 100.0,
			" " if row["live"] else "*"]
		+ "d2 %.3f d4 %.3f d8 %.3f"
		% [row["ratio"].get(2, NAN), row["ratio"].get(4, NAN), row["ratio"].get(8, NAN)])


## Solve one arm and return `{rms, cut}` — the RMS of its delta measured on the FINE lattice, and the
## mean absolute cut on its own grid (a sanity number, so an RMS built from nothing is visible).
func _solve_at(p_fixture: String, p_relief: float, p_rate: float, p_cell: float, p_div: int,
		p_diffusion: float = 0.02) -> Dictionary:
	var n := FINE / p_div
	var cell := p_cell * float(p_div)
	var span := float(FINE) * p_cell # the physical box, identical for every arm
	var z_in := _surface(p_fixture, n, cell, span, p_relief)
	var res: Dictionary = _terrain.data.erode_heightfield(z_in, {
		"gw": n, "gh": n, "cell_size": cell, "time_step": 1.0,
		"iterations": ITERATIONS, "erosion_rate": p_rate, "area_exponent": 0.45,
		"diffusion": p_diffusion, "deposition": 0.0, "want_diagnostics": true,
	}, PackedFloat32Array())
	if not bool(res.get("ok", false)):
		return {}
	var kp := _median_kp(res, n, cell, p_rate)
	var z_out: PackedFloat32Array = res["z"]
	var delta := PackedFloat32Array()
	delta.resize(n * n)
	var cut := 0.0
	var live := 0
	for i in range(n * n):
		if is_finite(z_in[i]) and is_finite(z_out[i]):
			delta[i] = z_out[i] - z_in[i]
			cut += absf(delta[i])
			live += 1
		else:
			delta[i] = NAN
	if live == 0:
		return {}
	return {"rms": _rms_on_fine(delta, n), "cut": cut / float(live),
			"relief_left": _relief(z_out) / maxf(_relief(z_in), 1e-6), "kp": kp}


## Peak-to-trough of the finite part of a grid. THE SATURATION DIAGNOSTIC, and the reason this probe was
## re-run after its first result: a solve that has flattened its fixture into a plain has no structure
## left for a resolution to disagree about, so its ratio of 1.000 is an agreement between two ruins and
## not evidence that resolution stops mattering. A number that clean is the tell.
func _relief(p_z: PackedFloat32Array) -> float:
	var lo := INF
	var hi := -INF
	for v in p_z:
		if is_finite(v):
			lo = minf(lo, v)
			hi = maxf(hi, v)
	return (hi - lo) if hi > -INF else 0.0


## RMS of a delta grid, evaluated at the FINE lattice's sample points by bilinear interpolation. See
## note 3: both arms are then averages over identical points.
func _rms_on_fine(p_delta: PackedFloat32Array, p_n: int) -> float:
	var sum := 0.0
	var count := 0
	var scale := float(p_n - 1) / float(FINE - 1)
	for iz in range(FINE):
		for ix in range(FINE):
			var v := _bilinear(p_delta, p_n, float(ix) * scale, float(iz) * scale)
			if is_finite(v):
				sum += v * v
				count += 1
	return sqrt(sum / float(count)) if count > 0 else 0.0


func _bilinear(p_g: PackedFloat32Array, p_n: int, p_x: float, p_z: float) -> float:
	var x0 := clampi(int(floor(p_x)), 0, p_n - 1)
	var z0 := clampi(int(floor(p_z)), 0, p_n - 1)
	var x1 := mini(x0 + 1, p_n - 1)
	var z1 := mini(z0 + 1, p_n - 1)
	var fx := p_x - float(x0)
	var fz := p_z - float(z0)
	var a := p_g[z0 * p_n + x0]
	var b := p_g[z0 * p_n + x1]
	var c := p_g[z1 * p_n + x0]
	var d := p_g[z1 * p_n + x1]
	# A non-finite corner is the outlet border, and interpolating through it would smear the boundary
	# inward by a cell of whatever size this arm uses — which is the confound note 4 exists to avoid.
	if not (is_finite(a) and is_finite(b) and is_finite(c) and is_finite(d)):
		return NAN
	return lerp(lerp(a, b, fx), lerp(c, d, fx), fz)


## Every fixture as a CONTINUOUS function of world XZ, sampled at whatever spacing the arm uses (note 2).
## `p_span` is the physical box in metres, identical across arms.
func _surface(p_fixture: String, p_n: int, p_cell: float, p_span: float, p_relief: float) -> PackedFloat32Array:
	var z := PackedFloat32Array()
	z.resize(p_n * p_n)
	var noise := FastNoiseLite.new()
	noise.seed = 7
	noise.frequency = 1.0 / (p_span * 0.06)
	for iz in range(p_n):
		for ix in range(p_n):
			var wx := float(ix) * p_cell
			var wz := float(iz) * p_cell
			if wx < BORDER_M or wz < BORDER_M or wx > p_span - BORDER_M or wz > p_span - BORDER_M:
				z[iz * p_n + ix] = NAN # the outlet, at a fixed physical width
				continue
			z[iz * p_n + ix] = _height_of(p_fixture, wx, wz, p_span, p_relief, noise)
	return z


func _height_of(p_fixture: String, p_x: float, p_z: float, p_span: float, p_relief: float,
		p_noise: FastNoiseLite) -> float:
	var u := p_x / p_span
	var v := p_z / p_span
	var rough := 6.0 * p_relief * p_noise.get_noise_2d(p_x, p_z)
	match p_fixture:
		"bowl":
			# A smooth dome: its own divide, draining outward in every direction.
			var dx := (u - 0.5) * 2.0
			var dv := (v - 0.5) * 2.0
			var r := clampf(sqrt(dx * dx + dv * dv), 0.0, 1.0)
			var pr := 1.0 - r
			return 60.0 * p_relief * pr * pr * (3.0 - 2.0 * pr) + rough * pr
		"y_catchment":
			# Two valleys joining into one — a real confluence, which is where routing decisions differ
			# most between resolutions.
			var ridge := 70.0 * p_relief * (1.0 - v)
			var arm_a := absf(u - 0.30 - 0.20 * v)
			var arm_b := absf(u - 0.70 + 0.20 * v)
			var trunk := absf(u - 0.5)
			var valley := (minf(arm_a, arm_b) if v > 0.45 else trunk)
			return ridge - 28.0 * p_relief * exp(-valley * valley / 0.004) + rough
		"demo":
			# Real ground, with all of its baked history in it. Sampled at the arm's own spacing, which is
			# exactly what a Sim does when it resamples the terrain onto a coarse grid.
			var h: float = _terrain.data.get_height(Vector3(200.0 + p_x, 0.0, 200.0 + p_z))
			return (h if is_finite(h) else 0.0) * p_relief
		"km_dome":
			# The km-scale case, at its own metres-per-cell. Whether the ratio survives a change of BASE
			# cell size is half the question: stream power reads drainage area in m² and slope over
			# metres, so a divisor is not obviously scale-free.
			var kx := (u - 0.5) * 2.0
			var kz := (v - 0.5) * 2.0
			var kr := clampf(sqrt(kx * kx + kz * kz), 0.0, 1.0)
			return 300.0 * p_relief * (1.0 - kr) + 3.0 * rough
	return 0.0


# ---- the statistic --------------------------------------------------------------------------------
#
# The claim is "the ratio is a function of the divisor alone". Stated that way it is a question about
# VARIANCE: of all the variation in log(ratio) across the sweep, how much is explained by which divisor
# a point belongs to, and how much is left over inside each divisor?
#
# Reported as a fraction rather than tested against a threshold, and with the residual spread printed in
# per-cent so the reader can judge what a calibration curve built from it would be worth.
func _report() -> void:
	print("\n---- collapse ----")
	if _rows.size() < 4:
		print("  only %d fixture(s) measured; there is nothing to collapse" % _rows.size())
		return
	var logs: Array = []      # [divisor, ln(ratio)] — everything
	var live_logs: Array = [] # the same, restricted to arms that still have a landscape
	var dead := 0
	for row in _rows:
		if not row["live"]:
			dead += 1
		for d in row["ratio"]:
			var r: float = row["ratio"][d]
			if r > 0.0 and is_finite(r):
				logs.append([d, log(r)])
				if row["live"]:
					live_logs.append([d, log(r)])
	print("  %d points across %d fixtures x relief x rate x base cell" % [logs.size(), _rows.size()])
	print("  %d of those fixtures (marked *) were FLATTENED by the fine solve: under 25%% of their relief"
		% dead + " survives, so there is nothing left for a resolution to disagree about")
	print("  divisor | mean ratio |  min   |  max   | spread (max/min)")
	for d in [2, 4, 8]:
		var vals: Array = []
		for e in logs:
			if e[0] == d:
				vals.append(exp(e[1]))
		if vals.is_empty():
			continue
		var lo: float = vals.min()
		var hi: float = vals.max()
		var mean := 0.0
		for v in vals:
			mean += v
		mean /= float(vals.size())
		print("     %2d   |   %6.3f   | %6.3f | %6.3f | %.2fx" % [d, mean, lo, hi, hi / lo])
	print("  variance in ln(ratio) explained by the divisor: %.1f%% (ALL arms)" % (_explained(logs) * 100.0))
	print("  the same statistic with the divisor labels SHUFFLED (chance): %.1f%%"
		% (_shuffled(logs) * 100.0))
	print("\n  ---- the same, over the %d LIVE points only ----" % live_logs.size())
	print("  divisor | mean ratio |  min   |  max   | spread (max/min)")
	for d in [2, 4, 8]:
		var vals: Array = []
		for e in live_logs:
			if e[0] == d:
				vals.append(exp(e[1]))
		if vals.is_empty():
			continue
		var mean := 0.0
		for v in vals:
			mean += v
		mean /= float(vals.size())
		print("     %2d   |   %6.3f   | %6.3f | %6.3f | %.2fx"
			% [d, mean, float(vals.min()), float(vals.max()),
				float(vals.max()) / maxf(float(vals.min()), 1e-9)])
	print("  variance explained by the divisor: %.1f%% (chance %.1f%%)"
		% [_explained(live_logs) * 100.0, _shuffled(live_logs) * 100.0])
	print("\n  Per axis, the spread WITHIN one divisor, which is what a curve would have to ignore:")
	print("    (all arms)")
	for axis in ["fixture", "relief", "rate", "cell"]:
		print("      %-8s %s" % [axis, _spread_by(axis, false)])
	print("    (live arms only)")
	for axis in ["fixture", "relief", "rate", "cell"]:
		print("      %-8s %s" % [axis, _spread_by(axis, true)])


## Fraction of the variance in ln(ratio) explained by group membership (the divisor).
func _explained(p_points: Array) -> float:
	if p_points.size() < 2:
		return 0.0
	var grand := 0.0
	for e in p_points:
		grand += e[1]
	grand /= float(p_points.size())
	var total := 0.0
	for e in p_points:
		total += (e[1] - grand) * (e[1] - grand)
	if total <= 0.0:
		return 0.0
	var between := 0.0
	for d in [2, 4, 8]:
		var sum := 0.0
		var n := 0
		for e in p_points:
			if e[0] == d:
				sum += e[1]
				n += 1
		if n > 0:
			var m := sum / float(n)
			between += float(n) * (m - grand) * (m - grand)
	return between / total


## The same statistic with the labels randomised: what "explained" looks like when the grouping means
## nothing. Without it, a number like 60% has no scale to be read against.
func _shuffled(p_points: Array) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var worst := 0.0
	for trial in range(20):
		var labels: Array = []
		for e in p_points:
			labels.append(e[0])
		for i in range(labels.size() - 1, 0, -1):
			var j := rng.randi_range(0, i)
			var t = labels[i]
			labels[i] = labels[j]
			labels[j] = t
		var shuffled: Array = []
		for i in range(p_points.size()):
			shuffled.append([labels[i], p_points[i][1]])
		worst = maxf(worst, _explained(shuffled))
	return worst


## For one axis of the sweep, the widest ratio spread seen inside a single divisor — i.e. how much the
## answer moves when only that axis changes and the divisor does not.
func _spread_by(p_axis: String, p_live_only: bool) -> String:
	var out := PackedStringArray()
	for d in [2, 4, 8]:
		var by := {}
		for row in _rows:
			if not row["ratio"].has(d) or (p_live_only and not row["live"]):
				continue
			var k = row[p_axis]
			if not by.has(k):
				by[k] = []
			by[k].append(row["ratio"][d])
		var means := []
		for k in by:
			var m := 0.0
			for v in by[k]:
				m += v
			means.append(m / float(by[k].size()))
		if means.size() < 2:
			continue
		out.append("d%d %.2fx" % [d, float(means.max()) / maxf(float(means.min()), 1e-9)])
	return " | ".join(out)


# ---- stage 2: is the governing parameter the INCISION BUDGET? --------------------------------------
#
# ANSWER, MEASURED: NO, not usefully. The numbers below look convincing at first sight - one budget spent
# three ways gives a 1.068x median spread against 1.421x between budgets - and they do not survive the
# saturation column printed beside them. Most of the between-budget separation comes from arms marked *,
# where the fine solve had FLATTENED the fixture: at K*N = 16.2 the bowl keeps 5% of its relief and its
# ratio is 1.000 by construction. Restricted to budgets that leave a landscape standing, within-budget
# and between-budget spreads are comparable (1.040x against 1.138x, gate CK.3) and the recast explains
# little. Section 8.1's slope-baseline fallback is the route. The sweep is kept because it is the
# evidence for that, and because the saturation column is the reusable part.
#
# Stage 1's answer is that the divisor alone does not explain the ratio, and that the axis which does
# most of the explaining is `erosion_rate`. That is a result, not a dead end, because of the SHAPE of the
# dependence: the coarse/fine disagreement is largest at a low rate and vanishes as the rate rises.
#
# THE HYPOTHESIS. In the stream-power update, K and the iteration count N are not independent knobs —
# each iteration incises in proportion to K, so what a solve has spent by the time it stops is K*N. If the
# disagreement is really about how far through its transient a solve is, then the governing parameter is
# that budget, and the ratio should be a function of (divisor, K*N) rather than of (divisor, K).
#
# THIS IS A PREDICTION, NOT A FIT, and the distinction is the whole reason this stage exists. Stage 1
# varied K at a FIXED N = 60, so it cannot tell K from K*N — every point in it has N = 60. Stage 2 varies
# N as well and asks a question stage 1's data could not answer: do (K = 0.09, N = 60), (K = 0.18, N = 30)
# and (K = 0.045, N = 120) — the same budget spent three different ways — give the same ratio?
#
# If they do, phase 5's correction is a two-parameter surface in (divisor, K*N): still a stored constant,
# still an interface, and honest about what it depends on. If they do not, §8.1's own fallback is the
# route — match the coarse solve's SLOPE BASELINE rather than scale its output.
#
# THE CONTROL is the between-budget spread. If the ratio barely moves between budgets, then "it collapses
# within a budget" is true of everything and the test has discriminated nothing.
func _budget_stage() -> void:
	print("\n\n=== Stage 2: is the governing parameter the incision budget K x N? ===\n")
	# Each group is one budget spent three ways. Held at relief x1 and cell 1 m: stage 1 measured relief
	# to be EXACTLY neutral (1.00x at every divisor, in both populations), and cell size to be a minor
	# 1.1x, so neither is what this stage is about.
	var groups := [
		{"budget": 1.8, "runs": [[0.030, 60], [0.060, 30], [0.015, 120]]},
		{"budget": 5.4, "runs": [[0.090, 60], [0.180, 30], [0.045, 120]]},
		{"budget": 16.2, "runs": [[0.270, 60], [0.540, 30], [0.135, 120]]},
	]
	var table: Array = []
	for fixture in ["bowl", "y_catchment", "demo", "km_dome"]:
		for g in groups:
			for run in g["runs"]:
				var rate: float = run[0]
				var iters: int = run[1]
				var base := _solve_budget(fixture, rate, iters, 1)
				if base.is_empty() or base["rms"] <= 0.0:
					continue
				var row := {"fixture": fixture, "budget": g["budget"], "rate": rate, "iters": iters,
						"live": base["relief_left"] >= 0.25, "ratio": {}}
				for d in [2, 4, 8]:
					var arm := _solve_budget(fixture, rate, iters, d)
					if not arm.is_empty():
						row["ratio"][d] = arm["rms"] / base["rms"]
				table.append(row)
				print("  %-12s K*N %5.1f (K %.3f x N %3d) relief left %5.1f%%%s | d2 %.3f d4 %.3f d8 %.3f"
					% [fixture, g["budget"], rate, iters, base["relief_left"] * 100.0,
						" " if row["live"] else "*", row["ratio"].get(2, NAN),
						row["ratio"].get(4, NAN), row["ratio"].get(8, NAN)])

	print("\n---- does one budget, spent three ways, give one ratio? ----")
	print("  (each cell is the spread max/min across the three K,N pairs of equal K*N)")
	print("  fixture      budget | d2     d4     d8")
	var within: Array = []
	for fixture in ["bowl", "y_catchment", "demo", "km_dome"]:
		for g in groups:
			var line := PackedStringArray()
			for d in [2, 4, 8]:
				var vals: Array = []
				for row in table:
					if row["fixture"] == fixture and row["budget"] == g["budget"] \
							and row["live"] and row["ratio"].has(d):
						vals.append(row["ratio"][d])
				if vals.size() < 2:
					line.append("  --  ")
					continue
				var spread: float = float(vals.max()) / maxf(float(vals.min()), 1e-9)
				within.append(spread)
				line.append("%.3fx" % spread)
			print("  %-12s %5.1f  | %s" % [fixture, g["budget"], " ".join(line)])

	# --- THE CONTROL: the same statistic BETWEEN budgets, which must be much larger ---
	var between: Array = []
	for fixture in ["bowl", "y_catchment", "demo", "km_dome"]:
		for d in [2, 4, 8]:
			var means: Array = []
			for g in groups:
				var vals: Array = []
				for row in table:
					if row["fixture"] == fixture and row["budget"] == g["budget"] \
							and row["live"] and row["ratio"].has(d):
						vals.append(row["ratio"][d])
				if vals.is_empty():
					continue
				var m := 0.0
				for v in vals:
					m += v
				means.append(m / float(vals.size()))
			if means.size() >= 2:
				between.append(float(means.max()) / maxf(float(means.min()), 1e-9))
	print("\n  WITHIN one budget (must be near 1.00x if the budget is the parameter): worst %.3fx, median %.3fx"
		% [_worst(within), _median(within)])
	print("  BETWEEN budgets  (the control - must be large, or nothing was discriminated): worst %.3fx, median %.3fx"
		% [_worst(between), _median(between)])


## One arm of stage 2. Same machinery as stage 1, with the iteration count free.
func _solve_budget(p_fixture: String, p_rate: float, p_iters: int, p_div: int) -> Dictionary:
	var n := FINE / p_div
	var cell := 1.0 * float(p_div)
	var span := float(FINE)
	var z_in := _surface(p_fixture, n, cell, span, 1.0)
	var res: Dictionary = _terrain.data.erode_heightfield(z_in, {
		"gw": n, "gh": n, "cell_size": cell, "time_step": 1.0,
		"iterations": p_iters, "erosion_rate": p_rate, "area_exponent": 0.45,
		"diffusion": 0.02, "deposition": 0.0,
	}, PackedFloat32Array())
	if not bool(res.get("ok", false)):
		return {}
	var z_out: PackedFloat32Array = res["z"]
	var delta := PackedFloat32Array()
	delta.resize(n * n)
	var live := 0
	for i in range(n * n):
		if is_finite(z_in[i]) and is_finite(z_out[i]):
			delta[i] = z_out[i] - z_in[i]
			live += 1
		else:
			delta[i] = NAN
	if live == 0:
		return {}
	return {"rms": _rms_on_fine(delta, n),
			"relief_left": _relief(z_out) / maxf(_relief(z_in), 1e-6)}


func _worst(p_vals: Array) -> float:
	return float(p_vals.max()) if not p_vals.is_empty() else 0.0


func _median(p_vals: Array) -> float:
	if p_vals.is_empty():
		return 0.0
	var v := p_vals.duplicate()
	v.sort()
	return float(v[v.size() / 2])


## ---- Stage 3: the implicit step's own saturation — TESTED AND NOT CONFIRMED -----------------------
##
## Stages 1 and 2 established what the ratio is NOT. This stage proposed a mechanism with a closed form,
## and the stage's own control refuted it. The negative is worth keeping because the hypothesis is the
## obvious one to have, and because the control that killed it is cheap and reusable.
##
## THE HYPOTHESIS. §4.3's implicit update is `z' = (z + kp*zr)/(1 + kp)` with
##
##     kp = dt * K * erod * A^m / len
##
## and `len` the D8 receiver distance, which IS a cell size — apparently the only place resolution
## enters, because `area` is accumulated in SQUARE METRES and is therefore resolution-free. One step
## removes `kp/(1+kp) * drop`, and on a surface of slope S the drop to a receiver one cell away is
## `S*len`. Writing `c = dt*K*erod*A^m` so that `kp = c/len`:
##
##     removed = [c/len / (1 + c/len)] * S * len = c * S * len / (len + c)
##
## which rises with `len` and saturates at `c*S`: a coarse cell removes more per step because the
## implicit form cannot remove more than the drop to its receiver, and a fine grid is clamped by that
## while a coarse grid is not. Assuming both arms see the same A and the same S, that gives
##
##     ratio(d) = (1 + kp_f) / (1 + kp_f/d)
##
## one expression, no fitted parameters, with `kp_f` measured on the fine arm rather than fitted.
##
## MEASURED 2026-08-21, and it agrees in a band and not outside it. At kp_f = 0.131 the prediction lands
## within **0.96-1.01x** on both fixtures at all three divisors — six arms, zero free parameters, which
## is exactly the sort of result that gets believed. At kp_f = 0.044, on the HEALTHIEST arms in the whole
## sweep (87-95 % of relief still standing), it under-predicts by up to **1.66x**. Diffusion was the
## obvious confound and is not it: rerunning the whole stage at `diffusion = 0` moved the worst error
## 1.66x to 1.60x.
##
## WHAT KILLED IT IS THE `kc*d/kf` COLUMN, which tests the derivation's own premise rather than its
## conclusion. If `len` were the only resolution term, the coarse arm's kp would be exactly `kp_f/d` and
## that column would read 1.00. It reads **1.87 at d=2, 3.48 at d=4 and 6.50 at d=8** — kp barely moves
## between arms (0.044 -> 0.035) because the median channel cell on a coarse grid drains a far larger
## area, and A^m grows by almost as much as `len` does. **So the premise is false by up to 6.5x, and a
## conclusion that agrees in one band while its premise is violated everywhere is a coincidence, not a
## mechanism.** The six good numbers are not evidence.
##
## WHAT IT DOES LEAVE, and it points where CJ already pointed. The thing that moves most between
## resolutions is not the slope baseline and not the implicit clamp: it is WHERE THE DRAINAGE NETWORK
## PUTS ITS AREA. A coarse grid concentrates the same catchment into fewer channel cells, and every term
## carrying A^m inherits that. CJ measured the same conclusion from the other end — that the coarse
## stage's error is ROUTING, which the fine stage then incises rather than re-routes.
##
## NEXT, and it should be measured before anything is built: whether a coarse arm whose channel cells are
## made to carry the fine arm's drainage area reproduces the fine structure. That is a statement about
## the accumulation, not about the incision, and it is what §8.1's remaining work should be re-aimed at.
func _saturation_stage(p_diffusion: float = 0.02) -> void:
	print("\n\n=== STAGE 3: the ratio against the implicit step's own saturation (diffusion %.2f) ===\n"
			% p_diffusion)
	print("  prediction  ratio(d) = (1 + kp_f) / (1 + kp_f/d), kp_f MEASURED on the fine arm")
	print("  no free parameters: kp_f is the median of dt*K*A^m/len over channel cells\n")
	print("  %-13s %5s %4s %7s %7s %6s %8s %8s %7s %6s"
			% ["fixture", "rate", "div", "kp_f", "kp_c", "kc*d/kf", "predicted", "measured", "err", "left"])
	var errs: Array = []
	var live_errs: Array = []
	for fixture in ["bowl", "y_catchment"]:
		for rate in [0.05, 0.15, 0.4]:
			var fine := _solve_at(fixture, 1.0, rate, 4.0, 1, p_diffusion)
			if fine.is_empty() or float(fine["rms"]) <= 0.0:
				print("  %-14s %6.2f   fine arm produced nothing" % [fixture, rate])
				continue
			var kp_f: float = float(fine["kp"])
			for d in [2, 4, 8]:
				var coarse := _solve_at(fixture, 1.0, rate, 4.0, d, p_diffusion)
				if coarse.is_empty():
					continue
				var measured: float = float(coarse["rms"]) / float(fine["rms"])
				var predicted: float = (1.0 + kp_f) / (1.0 + kp_f / float(d))
				var err: float = measured / maxf(predicted, 1e-6)
				# The saturation guard stage 1 had to learn: a flattened arm agrees with anything.
				var left: float = minf(float(fine["relief_left"]), float(coarse["relief_left"]))
				# kp_c * d / kp_f tests the derivation's OWN assumption: it should be 1.00 if the two
				# arms see the same drainage area at their channel cells and `len` is the only thing
				# that differs. Anything else is a second resolution term the closed form omits.
				var kp_c: float = float(coarse["kp"])
				var assume: float = kp_c * float(d) / maxf(kp_f, 1e-9)
				print("  %-13s %5.2f %4d %7.3f %7.3f %6.2f %8.3f %8.3f %7.2fx %5.0f%%"
						% [fixture, rate, d, kp_f, kp_c, assume, predicted, measured, err, 100.0 * left])
				errs.append(err)
				if left > 0.25:
					live_errs.append(err)
	if errs.is_empty():
		print("\n  nothing measured")
		return
	print("\n  worst |predicted/measured| over ALL arms:  %.2fx" % _worst(errs))
	if live_errs.is_empty():
		print("  every arm was flattened; this stage measured nothing")
		return
	print("  worst over arms with >25%% of their relief still standing: %.2fx (%d of %d arms)"
			% [_worst(live_errs), live_errs.size(), errs.size()])
	print("\n  READ THE kc*d/kf COLUMN FIRST. The closed form assumes `len` is the only resolution term,")
	print("  which makes that column 1.00 by construction. It is not: kp barely moves between arms because")
	print("  a coarse grid's channel cells drain far more area, so A^m grows nearly as fast as len. The")
	print("  agreement at kp_f = 0.13 is therefore a coincidence in a band, not a mechanism — see the")
	print("  note above this function. What moves between resolutions is WHERE THE NETWORK PUTS ITS AREA,")
	print("  which is the same place gate CJ's routing finding points.")


## Median `kp` over the cells that carry a channel, computed from the solver's OWN diagnostics rather
## than from an assumed drainage area — `flow` is the accumulated area in m², and `receiver` gives the
## exact D8 distance including diagonals.
##
## Taken over cells above the MEDIAN drainage area, because kp is dominated by A^m and the ratio this
## predicts is an RMS over the whole grid, which channels dominate. Hillslope cells sit at A = one cell
## and would drag the median toward a value no incision anywhere is happening at.
func _median_kp(p_res: Dictionary, p_n: int, p_cell: float, p_rate: float) -> float:
	var flow: PackedFloat32Array = p_res.get("flow", PackedFloat32Array())
	var recv: PackedInt32Array = p_res.get("receiver", PackedInt32Array())
	if flow.size() != p_n * p_n or recv.size() != p_n * p_n:
		return 0.0
	var areas: Array = []
	for i in range(p_n * p_n):
		if is_finite(flow[i]) and flow[i] > 0.0:
			areas.append(flow[i])
	if areas.size() < 16:
		return 0.0
	areas.sort()
	var a_cut: float = areas[areas.size() / 2]
	var diag := p_cell * sqrt(2.0)
	var kps: Array = []
	for i in range(p_n * p_n):
		if not is_finite(flow[i]) or flow[i] < a_cut:
			continue
		var r := recv[i]
		if r < 0 or r == i:
			continue
		var dx: int = (i % p_n) - (r % p_n)
		var dz: int = (i / p_n) - (r / p_n)
		var l: float = diag if (dx != 0 and dz != 0) else p_cell
		kps.append(1.0 * p_rate * pow(flow[i], 0.45) / l)
	if kps.is_empty():
		return 0.0
	kps.sort()
	return kps[kps.size() / 2]
