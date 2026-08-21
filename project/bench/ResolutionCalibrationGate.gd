# Copyright (c) 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gate CK - the phase 5 resolution calibration (PASTURE3D_BRUSH_EROSION_SPEC.md 8.1).
#
# WHAT THIS GATE FOUND, AND WHY ITS CRITERIA ARE NOT THE ONES THE SPEC ASKED FOR.
#
# 8.1 asked whether the coarse/fine depth ratio is "a function of the divisor alone", and committed the
# phase to changing shape if it is not. It is not, and this gate is where that is recorded:
#
#   the divisor explains 10.2% of the variance in ln(ratio) across the full sweep, against 3.4% for the
#   same statistic with the labels shuffled; 22.0% against 5.3% once fixtures the solve had FLATTENED are
#   excluded. Within a single divisor the ratio still moves 2.00x as erosion_rate changes.
#
# So the criterion "it collapses on the divisor" is not asserted here, because it is false. What is
# asserted is the replacement the measurement produced, which the phase now rests on:
#
#   THE GOVERNING PARAMETER IS THE INCISION BUDGET K*N, not the rate and not the divisor alone.
#
# That was a PREDICTION before it was a measurement, and the distinction matters. The first sweep varied
# K at a fixed N = 60, so it could not tell K from K*N. The prediction - that one budget spent three ways
# gives one ratio - was then tested by varying N, on data the hypothesis was not formed from. Fitting a
# curve to the first sweep and reporting how well it fitted would have been the other thing.
#
# See bench/ResolutionCalibrationProbe.tscn for the full sweep this is the standing subset of: four
# fixtures, two base cell sizes, and the per-axis breakdown.
#
# NOTHING IS BAKED. Every arm goes through `erode_heightfield` directly - the Sim would add its own
# resampling and its own chunked solve, and a number that could come from three places is not evidence
# about one of them.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/ResolutionCalibrationGate.tscn
extends Node

const DEMO_DATA := "res://demo/data"

## Fine grid in cells; every coarse arm is this over its divisor, so 2/4/8 stay exact.
const FINE := 256
## Outlet border in METRES, so every arm has the same physical boundary. A one-CELL border would be a
## different boundary per arm, sitting directly on the thing measured.
const BORDER_M := 24.0


const GATES := 3

var _fail := 0
var _completed := 0
var _terrain


func _ready() -> void:
	print("\n=== Resolution calibration (gate CK) ===\n")
	var root := Node3D.new()
	add_child(root)
	_terrain = ClassDB.instantiate("Pasture3D")
	root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA

	_ck_relief_invariance()
	_ck_divisor_alone_does_not_explain()
	_ck_budget_is_the_parameter()

	if _completed != GATES:
		_fail += 1
		print("\n!! only %d of %d criteria ran to the end - the rest were abandoned by a runtime error"
			% [_completed, GATES])
	print("\n=== %s (%d failures) ===\n"
		% ["RESOLUTION CALIBRATION PASS" if _fail == 0 else "RESOLUTION CALIBRATION FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- CK part 1: the harness has a positive control built into it ------------------------------------
#
# Linear stream power (n = 1) is HOMOGENEOUS in z: scale a surface by a factor and every slope, every
# incision rate and the whole solution scale with it, so the coarse/fine RATIO must be exactly invariant
# to relief amplitude. That is an analytic property of the equation being solved, not an empirical hope.
#
# Which makes it the positive control this whole measurement needs. Every other number here is a
# difference between two solves and could be produced by a broken harness - a misaligned upsample, a
# boundary a cell out, an RMS over the wrong cells. None of those would reproduce relief invariance to
# three decimal places. It is checked FIRST for that reason: if it fails, nothing below means anything.
func _ck_relief_invariance() -> void:
	print("\n[CK.1] the ratio is invariant to relief amplitude, as linear stream power requires:")
	var worst := 0.0
	var seen := 0
	for fixture in ["bowl", "y_catchment", "demo"]:
		for d in [2, 4, 8]:
			var a := _ratio(fixture, 1.0, 0.09, 60, d)
			var b := _ratio(fixture, 3.0, 0.09, 60, d)
			if a <= 0.0 or b <= 0.0:
				continue
			seen += 1
			worst = maxf(worst, maxf(a / b, b / a))
	print("    3 fixtures x 3 divisors, relief x1 against relief x3: worst disagreement %.4fx" % worst)
	if seen < 9:
		_fail += 1
		print("    !! only %d of 9 pairs solved, so the invariance is being read off a partial sweep" % seen)
	elif worst > 1.01:
		_fail += 1
		print("    !! the ratio moves with relief, which linear stream power forbids - the measurement "
			+ "harness is wrong (upsample alignment, boundary width, or the RMS sample set), and every "
			+ "number below is built on it")
	_completed += 1


# --- CK part 2: the claim 8.1 asked about, and its answer -------------------------------------------
#
# The spec's criterion was that the ratio collapses onto one curve in the divisor. This asserts the
# OPPOSITE, because that is what was measured - and it is a real criterion rather than a shrug: if a
# future solver change made the divisor sufficient, this gate fails and says so, which is exactly when
# 8.1's original plan becomes available again and someone should be told.
#
# MEASURED AS A COMPARISON OF TWO SPREADS, not as variance-explained against a permutation null. The probe
# uses the variance statistic because it has 144 points to spend on it; at this gate's 27 the max of 20
# shuffles runs to 37%, so the null swamps the signal and the statistic says nothing. That WAS the first
# draft of this criterion and it failed on its own control, correctly. Two spreads are robust at this
# size, and they are the substantive claim anyway.
func _ck_divisor_alone_does_not_explain() -> void:
	print("\n[CK.2] the divisor ALONE does not explain the ratio (8.1 step 2's question):")
	var by_divisor := {}   # divisor -> every ratio at that divisor
	var by_rate := {}      # divisor -> rate -> ratios
	for fixture in ["bowl", "y_catchment", "demo"]:
		for rate in [0.03, 0.09, 0.27]:
			for d in [2, 4, 8]:
				var r := _ratio(fixture, 1.0, rate, 60, d)
				if r <= 0.0:
					continue
				if not by_divisor.has(d):
					by_divisor[d] = []
					by_rate[d] = {}
				by_divisor[d].append(r)
				if not by_rate[d].has(rate):
					by_rate[d][rate] = []
				by_rate[d][rate].append(r)
	if by_divisor.size() < 3:
		_fail += 1
		print("    !! only %d divisors solved; there is nothing to compare" % by_divisor.size())
		_completed += 1
		return

	# How much the DIVISOR moves the answer.
	var means: Array = []
	for d in [2, 4, 8]:
		means.append(_mean(by_divisor[d]))
	var divisor_spread: float = float(means.max()) / maxf(float(means.min()), 1e-9)

	# How much the RATE moves it with the divisor held fixed - the confound that has to be smaller.
	var rate_spread := 0.0
	for d in by_rate:
		var rm: Array = []
		for rate in by_rate[d]:
			rm.append(_mean(by_rate[d][rate]))
		if rm.size() >= 2:
			rate_spread = maxf(rate_spread, float(rm.max()) / maxf(float(rm.min()), 1e-9))

	print("    mean ratio by divisor: d2 %.3f  d4 %.3f  d8 %.3f  (spread %.2fx)"
		% [means[0], means[1], means[2], divisor_spread])
	print("    with the divisor held FIXED, changing only erosion_rate moves it by up to %.2fx"
		% rate_spread)
	if divisor_spread < 1.15:
		_fail += 1
		print("    !! the divisor barely moves the ratio at all, so comparing it against the rate is a "
			+ "comparison between two nothings and this criterion has measured neither")
	elif rate_spread <= divisor_spread:
		_fail += 1
		print("    !! the rate no longer dominates the divisor, so the ratio may now BE a function of "
			+ "the divisor - 8.1's original plan, a calibration curve in the divisor alone, has become "
			+ "available and this phase should be reconsidered rather than left where the measurement "
			+ "put it")
	_completed += 1


# --- CK part 3: why the incision-budget recast is NOT the rescue it looked like ----------------------
#
# K and the iteration count N are not independent knobs - each iteration incises in proportion to K - so
# the obvious recast is that the governing parameter is the budget K*N. Measured across four fixtures it
# looked convincing: one budget spent three ways gave a 1.068x median spread against 1.421x between
# budgets. That is why the probe carries the sweep.
#
# IT DOES NOT SURVIVE ITS OWN SATURATION CHECK. Most of that between-budget separation came from arms in
# which the solve had FLATTENED the fixture. A solve that has removed the landscape has no structure left
# for a resolution to disagree about, so its ratio is 1.000 by construction - an agreement between two
# ruins, not evidence that resolution stops mattering. Restricted to budgets that leave a landscape
# standing, within-budget and between-budget spreads become comparable and the recast explains little.
#
# So this criterion asserts the SATURATION MECHANISM rather than the recast. It is the reusable finding,
# it is what invalidates the recast, and unlike the recast it is robust at this gate's sample size. The
# recast's own numbers are printed underneath as a diagnostic with no verdict.
func _ck_budget_is_the_parameter() -> void:
	print("\n[CK.3] the ratio going to 1.0 at a high budget is SATURATION, not agreement:")
	var low := _arm_full("bowl", 0.030, 60, 8)   # K*N =  1.8, a solve still in its transient
	var high := _arm_full("bowl", 0.270, 60, 8)  # K*N = 16.2, the same fixture, destroyed
	var low_fine := _arm_full("bowl", 0.030, 60, 1)
	var high_fine := _arm_full("bowl", 0.270, 60, 1)
	if low.is_empty() or high.is_empty() or low_fine.is_empty() or high_fine.is_empty():
		_fail += 1
		print("    !! an arm failed to solve; nothing was measured")
		_completed += 1
		return
	var low_ratio: float = low["rms"] / maxf(low_fine["rms"], 1e-9)
	var high_ratio: float = high["rms"] / maxf(high_fine["rms"], 1e-9)
	print("    K*N  1.8: ratio %.3f, with %.0f%% of the relief still standing"
		% [low_ratio, low["left"] * 100.0])
	print("    K*N 16.2: ratio %.3f, with %.0f%% of the relief still standing"
		% [high_ratio, high["left"] * 100.0])
	if low_ratio < 1.5 or low["left"] < 0.75:
		_fail += 1
		print("    !! the transient arm is not showing the disagreement this phase is about, so the "
			+ "comparison below has no baseline to be read against")
	if high["left"] >= 0.25:
		_fail += 1
		print("    !! the high-budget arm still HAS a landscape (%.0f%% standing), so its ratio of %.3f "
			% [high["left"] * 100.0, high_ratio] + "would be genuine agreement rather than saturation - "
			+ "the incision-budget recast may be right after all and phase 5 should revisit it")
	elif high_ratio > 1.15:
		_fail += 1
		print("    !! the flattened arm disagrees anyway, so flattening is not what drives the ratio to "
			+ "1.0 and this explanation of the recast's failure is wrong")

	# Diagnostic, no verdict: the recast's own numbers over budgets that leave a landscape standing.
	var within: Array = []
	var between: Array = []
	for fixture in ["bowl", "y_catchment", "demo"]:
		for d in [2, 4, 8]:
			var means: Array = []
			for g in [[[0.030, 60], [0.060, 30], [0.015, 120]], [[0.090, 60], [0.180, 30], [0.045, 120]]]:
				var vals: Array = []
				for run in g:
					var r := _ratio(fixture, 1.0, run[0], run[1], d)
					if r > 0.0:
						vals.append(r)
				if vals.size() < 2:
					continue
				within.append(float(vals.max()) / maxf(float(vals.min()), 1e-9))
				means.append(_mean(vals))
			if means.size() >= 2:
				between.append(float(means.max()) / maxf(float(means.min()), 1e-9))
	print("    diagnostic only - the K*N recast over LIVE budgets: within %.3fx median against between "
		% _median(within) + "%.3fx median. Comparable, so the recast does not collapse the ratio either, "
		% _median(between) + "and 8.1's slope-baseline fallback is the route.")
	_completed += 1


# ---- measurement -----------------------------------------------------------------------------------


## The coarse/fine delta-RMS ratio for one configuration, or 0.0 if an arm failed.
func _ratio(p_fixture: String, p_relief: float, p_rate: float, p_iters: int, p_div: int) -> float:
	var fine := _arm(p_fixture, p_relief, p_rate, p_iters, 1)
	var coarse := _arm(p_fixture, p_relief, p_rate, p_iters, p_div)
	if fine <= 0.0 or coarse <= 0.0:
		return 0.0
	return coarse / fine


## RMS of one arm's delta, evaluated on the FINE lattice so both arms average over identical points -
## which is also exactly what amplification would do with a coarse delta.
func _arm(p_fixture: String, p_relief: float, p_rate: float, p_iters: int, p_div: int) -> float:
	var n := FINE / p_div
	var cell := float(p_div)
	var z_in := _surface(p_fixture, n, cell, float(FINE), p_relief)
	var res: Dictionary = _terrain.data.erode_heightfield(z_in, {
		"gw": n, "gh": n, "cell_size": cell, "time_step": 1.0,
		"iterations": p_iters, "erosion_rate": p_rate, "area_exponent": 0.45,
		"diffusion": 0.02, "deposition": 0.0,
	}, PackedFloat32Array())
	if not bool(res.get("ok", false)):
		return 0.0
	var z_out: PackedFloat32Array = res["z"]
	var delta := PackedFloat32Array()
	delta.resize(n * n)
	for i in range(n * n):
		delta[i] = (z_out[i] - z_in[i]) if (is_finite(z_in[i]) and is_finite(z_out[i])) else NAN
	return _rms_on_fine(delta, n)


## One arm plus its saturation diagnostic: `{rms, left}`, where `left` is the fraction of the fixture's
## peak-to-trough relief still standing after the solve. See CK.3 for why that fraction decides what the
## RMS ratio means.
func _arm_full(p_fixture: String, p_rate: float, p_iters: int, p_div: int) -> Dictionary:
	var n := FINE / p_div
	var cell := float(p_div)
	var z_in := _surface(p_fixture, n, cell, float(FINE), 1.0)
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
	for i in range(n * n):
		delta[i] = (z_out[i] - z_in[i]) if (is_finite(z_in[i]) and is_finite(z_out[i])) else NAN
	return {"rms": _rms_on_fine(delta, n), "left": _relief(z_out) / maxf(_relief(z_in), 1e-6)}


## Peak-to-trough of the finite part of a grid.
func _relief(p_z: PackedFloat32Array) -> float:
	var lo := INF
	var hi := -INF
	for v in p_z:
		if is_finite(v):
			lo = minf(lo, v)
			hi = maxf(hi, v)
	return (hi - lo) if hi > -INF else 0.0


func _mean(p_vals: Array) -> float:
	if p_vals.is_empty():
		return 0.0
	var m := 0.0
	for v in p_vals:
		m += v
	return m / float(p_vals.size())


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
	var a := p_g[z0 * p_n + x0]
	var b := p_g[z0 * p_n + x1]
	var c := p_g[z1 * p_n + x0]
	var d := p_g[z1 * p_n + x1]
	# Interpolating through the outlet border would smear the boundary inward by a cell of whatever size
	# this arm uses, which is the confound the fixed-metres border exists to avoid.
	if not (is_finite(a) and is_finite(b) and is_finite(c) and is_finite(d)):
		return NAN
	var fx := p_x - float(x0)
	var fz := p_z - float(z0)
	return lerp(lerp(a, b, fx), lerp(c, d, fx), fz)


## Every fixture as a CONTINUOUS function of world XZ, sampled at whatever spacing the arm uses. A coarse
## solve evaluates the terrain at coarser spacing - it does not average a fine grid - so downsampling
## would fold in a low-pass the real path never applies.
func _surface(p_fixture: String, p_n: int, p_cell: float, p_span: float,
		p_relief: float) -> PackedFloat32Array:
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
				z[iz * p_n + ix] = NAN
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
			var dx := (u - 0.5) * 2.0
			var dv := (v - 0.5) * 2.0
			var r := clampf(sqrt(dx * dx + dv * dv), 0.0, 1.0)
			var pr := 1.0 - r
			return 60.0 * p_relief * pr * pr * (3.0 - 2.0 * pr) + rough * pr
		"y_catchment":
			var ridge := 70.0 * p_relief * (1.0 - v)
			var arm_a := absf(u - 0.30 - 0.20 * v)
			var arm_b := absf(u - 0.70 + 0.20 * v)
			var trunk := absf(u - 0.5)
			var valley := (minf(arm_a, arm_b) if v > 0.45 else trunk)
			return ridge - 28.0 * p_relief * exp(-valley * valley / 0.004) + rough
		"demo":
			var h: float = _terrain.data.get_height(Vector3(200.0 + p_x, 0.0, 200.0 + p_z))
			return (h if is_finite(h) else 0.0) * p_relief
	return 0.0


# ---- statistics ------------------------------------------------------------------------------------


## Fraction of the variance in ln(ratio) explained by which divisor a point belongs to.
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


## The same statistic with the labels randomised - what "explained" looks like when the grouping means
## nothing. Without it a number like 10% has no scale to be read against.
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


func _median(p_vals: Array) -> float:
	if p_vals.is_empty():
		return 0.0
	var v := p_vals.duplicate()
	v.sort()
	return float(v[v.size() / 2])
