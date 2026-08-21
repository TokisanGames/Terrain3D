# Copyright (c) 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gate CJ - multi-resolution amplification (PASTURE3D_BRUSH_EROSION_SPEC.md 8, phase 5).
#
# THE DECIDING GATE FOR THE PHASE'S SHAPE. Gate CK measured that the coarse/fine depth ratio is not a
# function of the resolution divisor and rejected the correction 8.1 planned. But amplification does not
# need the coarse stage's DEPTH to be right - it needs its STRUCTURE to be right, because the fine stage
# then re-deepens whatever the coarse stage chose. So this gate runs the pipeline with NO correction at
# all and asks whether the answer is already good enough:
#
#   if yes  the rejected correction was never needed and phase 5 is just the pipeline
#   if no   8.1's slope-baseline fallback is the work, and it is a solver change rather than a constant
#
# THE PIPELINE, and the one choice in it that is not arbitrary:
#
#   coarse   downsample z0 to 1/d, solve N_c iterations at cell size c*d
#   upsample take the coarse DELTA - not the coarse surface - and resample it back to the fine grid
#   fine     add it to z0 and solve N_f iterations at cell size c
#
# UPSAMPLING THE DELTA rather than the surface is what keeps the fine input's own high-frequency detail.
# Upsampling the coarse surface would replace a 1 m terrain with a bilinear blow-up of an 8 m one and
# throw away everything the brush stack put there, which is the opposite of amplification. It is also
# what Pasture3DSim already does when it writes a preview, so the two paths agree on the question.
#
# MEASURED THROUGH `erode_heightfield` AND `resample_grid` DIRECTLY, as gates J and CK are: driving a Sim
# would add its own resampling and its own chunked solve, and a number that could come from three places
# is not evidence about one of them.
#
# THE STATISTIC IS GATE J'S, DELIBERATELY. Pearson correlation of two delta fields after a `resample_grid`
# low-pass, reported across the scale ladder, with the high-pass residual as the control. That gate
# established 0.86-0.91 for a preview against a build; comparing this pipeline against a different
# statistic and then against J's number would be comparing two different things.
#
# NO WALL-CLOCK TIMING. 8's claim includes "measurably faster", and cost here is reported as
# CELL-ITERATIONS, which is exact, deterministic, and independent of what else the machine is doing. A
# stopwatch number taken while another engine is running would not be evidence, and timing runs on this
# machine need the user's say-so anyway.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/AmplificationGate.tscn
extends Node

const DEMO_DATA := "res://demo/data"

## Fine grid. 257 keeps (N-1)/d + 1 exact at every divisor on the ladder, which is what corner-aligned
## resampling needs (see the Sim spec's note on grid alignment).
const FINE := 257
## Metres per fine cell, so the fixture spans 512 m.
const CELL := 2.0
## Outlet border in METRES, identical at every resolution - a one-CELL border would be a different
## physical boundary per arm, sitting directly on the thing being compared.
const BORDER_M := 24.0

## The budget the reference spends, and how amplification splits it.
const REF_ITERATIONS := 60
const COARSE_DIVISOR := 8
const COARSE_ITERATIONS := 48
const FINE_ITERATIONS := 12

## 8's criterion. Gate J shipped at 0.75 having measured 0.882; this is the number 11 states for CJ.
const WANT_CORRELATION := 0.86

const SOLVER := {"time_step": 1.0, "erosion_rate": 0.06, "area_exponent": 0.45,
		"diffusion": 0.02, "deposition": 0.0}

const GATES := 3

var _fail := 0
var _completed := 0
var _terrain
var _data


func _ready() -> void:
	print("\n=== Multi-resolution amplification (gate CJ) ===\n")
	var root := Node3D.new()
	add_child(root)
	_terrain = ClassDB.instantiate("Pasture3D")
	root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_data = _terrain.data

	_cj_structure()
	_cj_control_coarse_zero()
	_cj_cost()
	_cj_split_sweep()

	if _completed != GATES:
		_fail += 1
		print("\n!! only %d of %d criteria ran to the end - the rest were abandoned by a runtime error"
			% [_completed, GATES])
	print("\n=== %s (%d failures) ===\n"
		% ["AMPLIFICATION PASS" if _fail == 0 else "AMPLIFICATION FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- CJ.1: does an UNCORRECTED coarse stage still produce the right structure? -----------------------
#
# MEASURED AGAINST A PER-FIXTURE NULL, and the first draft of this gate is why.
#
# The obvious criterion is "correlate the amplified delta against the reference delta after a low-pass,
# and want >= 0.86" - gate J's statistic, and what 11 states for CJ. Run that way the gate reported
# 0.929 / 0.782 / 0.910 across three fixtures. It also carried an independence null, and the null came
# back at 0.875: TWO UNRELATED SOLVES CORRELATE ALMOST AS WELL AS THE PIPELINE DOES.
#
# The reason is structural, not a fixture accident. Both arms erode the SAME z0, so both deltas carry the
# same landform-driven component - deep where the mountain is steep, shallow where it is flat - and after
# a low-pass that shared component is most of what is left. The statistic is largely measuring "both runs
# eroded the same mountain", which is true of any two runs whatsoever.
#
# So the criterion here is the correlation MINUS what the same filter gives two independent solves of the
# same landform. The null is built per fixture, from the same landform with different roughness, solved
# twice at full resolution: it shares exactly the confound the two arms share and nothing else. A
# pipeline that reproduces structure has to beat it; 0.86 against a floor of 0.875 is not a measurement.
#
# This also puts a caveat on gate J in the Sim spec, which has the same shape - preview and build both
# erode one z0 - and reports 0.882 with no null. Its high-pass control does discriminate there, so its
# verdict stands, but its NUMBER is inflated by the same shared landform and should not be read as "88%
# of the structure agrees".
func _cj_structure() -> void:
	print("\n[CJ.1] amplified against a full-resolution solve, on large-scale structure:")
	var margins: Array = []
	for fixture in ["bowl", "y_catchment", "demo"]:
		var z0 := _surface(fixture, FINE, CELL, 0)
		var ref := _solve(z0, FINE, CELL, REF_ITERATIONS)
		var amp := _amplify(z0, COARSE_DIVISOR, COARSE_ITERATIONS, FINE_ITERATIONS)
		if ref.is_empty() or amp.is_empty():
			_fail += 1
			print("    !! %s: an arm failed to solve" % fixture)
			continue
		var d_ref := _delta(z0, ref)
		var d_amp := _delta(z0, amp)
		if _rms(d_ref) < 0.05 or _rms(d_amp) < 0.05:
			_fail += 1
			print("    !! %s: an arm eroded nothing, so a correlation between them is a correlation of "
				% fixture + "two fields of zeros")
			continue
		var corr := _pearson(_low_pass(d_ref, 8), _low_pass(d_amp, 8))
		var null_corr := _null_for(fixture)
		var hp := _pearson(_high_pass(d_ref), _high_pass(d_amp))
		margins.append({"fixture": fixture, "corr": corr, "null": null_corr})
		print("    %-12s RMS ref %6.3f m amp %6.3f m (x%.2f) | 1/8 corr %.3f, null %.3f, margin %+.3f"
			% [fixture, _rms(d_ref), _rms(d_amp), _rms(d_amp) / maxf(_rms(d_ref), 1e-9),
				corr, null_corr, corr - null_corr])
		print("                 (high-pass residual %.3f)" % hp)

	if margins.is_empty():
		_fail += 1
		print("    !! nothing was measured")
		_completed += 1
		return

	# The null must itself be well below 1.0, or it is not a floor - it is the ceiling, and every margin
	# is measuring rounding.
	var worst_null := 0.0
	var worst_margin := 1.0
	var worst_name := ""
	for m in margins:
		worst_null = maxf(worst_null, float(m["null"]))
		if float(m["corr"]) - float(m["null"]) < worst_margin:
			worst_margin = float(m["corr"]) - float(m["null"])
			worst_name = String(m["fixture"])
	print("    criterion: worst margin over the null is %+.3f, on %s" % [worst_margin, worst_name])

	# THE HEADROOM CONTROL, and this criterion is empty without it. A margin of zero could mean the
	# pipeline adds nothing, or it could mean the statistic has nowhere to go - if the null were already
	# at the ceiling, no pipeline could beat it and "no margin" would be a fact about the filter. So:
	# a perfect arm must score a real margin. `coarse_iterations = 0` IS the reference, so its margin is
	# the whole of the headroom this statistic offers.
	var perfect := _null_for("y_catchment")
	var headroom := 1.0 - perfect
	print("    control: a perfect arm scores 1.000 against a null of %.3f, so the statistic offers "
		% perfect + "%+.3f of headroom to win" % headroom)
	if headroom < 0.05:
		_fail += 1
		print("    !! the null is at %.3f, so this filter reports near-perfect agreement between "
			% perfect + "unrelated solves and no margin over it could mean anything")

	# ASSERTED AS THE MEASURED FINDING, the same way gate CK asserts its rejection. Amplification with an
	# uncorrected coarse stage does NOT reproduce the structure, so that is what is locked in - and the
	# day someone lands 8.1's slope-baseline correction this criterion FAILS and says to re-read 8.1,
	# which is exactly when somebody should be told.
	if worst_margin > 0.05:
		_fail += 1
		print("    !! amplification NOW beats the null by %+.3f, so an uncorrected coarse stage has "
			% worst_margin + "started reproducing the full-resolution structure. That is the result "
			+ "8.1 was waiting for: re-read it, and reconsider whether the slope-baseline correction is "
			+ "still needed.")
	else:
		print("    RECORDED: an uncorrected coarse stage does not reproduce the full-resolution "
			+ "structure any better than an unrelated solve of the same landform does. 8.1's "
			+ "slope-baseline correction is required, and for a stronger reason than depth: it is the "
			+ "coarse stage's ROUTING that differs, and the fine stage inherits it.")
	_completed += 1


## The floor for one fixture: two INDEPENDENT full-resolution solves of the same landform with different
## roughness, through the identical filter. It shares the confound the two arms share - one landform -
## and nothing else, which is what makes it the right thing to subtract.
func _null_for(p_fixture: String) -> float:
	var a := _surface(p_fixture, FINE, CELL, 0)
	var b := _surface(p_fixture, FINE, CELL, 991)
	var sa := _solve(a, FINE, CELL, REF_ITERATIONS)
	var sb := _solve(b, FINE, CELL, REF_ITERATIONS)
	if sa.is_empty() or sb.is_empty():
		return 1.0 # a null that failed to solve must not silently become a low floor
	return _pearson(_low_pass(_delta(a, sa), 8), _low_pass(_delta(b, sb), 8))


# --- CJ.4: is the split wrong, or the approach? ------------------------------------------------------
#
# DIAGNOSTIC, NO VERDICT. If CJ.1 fails, the next question is which of two things it means: that 12 fine
# iterations are simply too few to repair what the coarse stage got wrong, or that the coarse stage's
# channels are in places no amount of refinement will move. 8's premise is the first - "structure is
# chosen early, deepened late" - and it is cheap to check, so this sweeps the split rather than leaving
# the phase to guess.
#
# Run on the Y-catchment, which is the fixture with a real confluence and so the one where routing
# decisions between resolutions differ most - and the one CJ.1 scores worst on.
#
# IT STAYS A DIAGNOSTIC BECAUSE ONE ROW OF IT IS CONFOUNDED, and the confound is worth naming. Spending
# MORE fine iterations against a fixed 60-iteration reference means the amplified arm has done more total
# incision than the thing it is compared against, so part of any fall in correlation is overshoot rather
# than misrouting. Pearson is invariant to a linear rescale but not to a landscape being further along.
# What is NOT confounded is the direction across the cheap rows: the closer the split gets to not
# amplifying at all, the closer it gets to the reference, and the cheapest split is the worst.
func _cj_split_sweep() -> void:
	print("\n[CJ.4] diagnostic, no verdict - does more refinement repair it?")
	var z0 := _surface("y_catchment", FINE, CELL, 0)
	var ref := _solve(z0, FINE, CELL, REF_ITERATIONS)
	if ref.is_empty():
		print("    the reference failed to solve; nothing swept")
		return
	var d_ref := _delta(z0, ref)
	var null_corr := _null_for("y_catchment")
	var fine_cells := FINE * FINE
	var coarse_n := (FINE - 1) / COARSE_DIVISOR + 1
	print("    null for this fixture: %.3f" % null_corr)
	print("    coarse / fine | 1/8 corr | margin | cell-iterations vs the reference")
	for split in [[48, 12], [48, 24], [48, 48], [24, 36], [0, 60]]:
		var nc: int = split[0]
		var nf: int = split[1]
		var amp := _amplify(z0, COARSE_DIVISOR, nc, nf)
		if amp.is_empty():
			continue
		var corr := _pearson(_low_pass(d_ref, 8), _low_pass(_delta(z0, amp), 8))
		var cost := coarse_n * coarse_n * nc + fine_cells * nf
		print("      %3d / %3d   |  %.3f   | %+.3f | %.2fx cheaper"
			% [nc, nf, corr, corr - null_corr, float(fine_cells * REF_ITERATIONS) / float(cost)])


# --- CJ.2: 8.2's stated control, and the pipeline's own plumbing -------------------------------------
#
# `coarse_iterations = 0` is the migration path: it must BE today's single-resolution solve, not merely
# resemble one. Asserted bitwise rather than by correlation - a pipeline that resampled, added a
# near-zero delta and solved would correlate at 1.000 while quietly perturbing every cell, and every
# already-authored scene would move the first time it was re-baked.
func _cj_control_coarse_zero() -> void:
	print("\n[CJ.2] with the coarse stage disabled, the pipeline IS the single-resolution solve:")
	for fixture in ["bowl", "demo"]:
		var z0 := _surface(fixture, FINE, CELL, 0)
		var ref := _solve(z0, FINE, CELL, REF_ITERATIONS)
		var off := _amplify(z0, COARSE_DIVISOR, 0, REF_ITERATIONS)
		if ref.is_empty() or off.is_empty():
			_fail += 1
			print("    !! %s: an arm failed to solve" % fixture)
			continue
		var at := _first_difference(ref, off)
		var corr := _pearson(_low_pass(_delta(z0, ref), 8), _low_pass(_delta(z0, off), 8))
		print("    %-12s %s, correlation with itself %.4f"
			% [fixture, "bitwise identical" if at < 0 else "DIFFERS at cell %d" % at, corr])
		if at >= 0:
			_fail += 1
			print("    !! coarse_iterations = 0 is not the solve it replaces, so migrating a scene onto "
				+ "this pipeline would move ground that nobody asked to move")
		if corr < 0.9999:
			_fail += 1
			print("    !! the correlation statistic does not return 1.000 for a field against itself, so "
				+ "every other number this gate prints is suspect")
	_completed += 1


# --- CJ.3: is it actually cheaper, and by how much ---------------------------------------------------
#
# In CELL-ITERATIONS, not seconds. See this file's header: an exact deterministic count is better
# evidence than a stopwatch reading taken while the machine is doing something else, and timing runs
# here need the user's go-ahead. The relationship to wall clock is not linear - 8 records that the
# priority flood is 61% of the cost and memory-bound, so a smaller working set is better than
# proportionally cheaper - which means this number is a LOWER bound on the saving, and it is reported
# that way rather than converted.
func _cj_cost() -> void:
	print("\n[CJ.3] cost, counted in cell-iterations:")
	var fine_cells := FINE * FINE
	var coarse_n := (FINE - 1) / COARSE_DIVISOR + 1
	var coarse_cells := coarse_n * coarse_n
	var ref_cost := fine_cells * REF_ITERATIONS
	var amp_cost := coarse_cells * COARSE_ITERATIONS + fine_cells * FINE_ITERATIONS
	var saving := float(ref_cost) / float(amp_cost)
	print("    reference : %d iterations x %d cells = %d" % [REF_ITERATIONS, fine_cells, ref_cost])
	print("    amplified : %d x %d (1/%d) + %d x %d = %d"
		% [COARSE_ITERATIONS, coarse_cells, COARSE_DIVISOR, FINE_ITERATIONS, fine_cells, amp_cost])
	print("    %.2fx fewer cell-iterations (a LOWER bound on the wall-clock saving; the flood is "
		% saving + "memory-bound, so the smaller working set helps beyond the count)")
	if saving <= 1.5:
		_fail += 1
		print("    !! amplification is not meaningfully cheaper at this split, so whatever CJ.1 says "
			+ "about its structure it is not worth having")
	# The control: the disabled configuration must cost the same as the reference, or the cost model is
	# not describing the same pipeline the other criteria measure.
	var off_cost := fine_cells * REF_ITERATIONS
	if off_cost != ref_cost:
		_fail += 1
		print("    !! coarse_iterations = 0 does not cost what the single-resolution solve costs")
	_completed += 1


# ---- the pipeline ----------------------------------------------------------------------------------


## Amplify: coarse solve, upsample the DELTA, then refine at full resolution. Returns the final fine
## surface, or empty if any arm failed. `p_coarse_iterations = 0` skips the coarse stage entirely, which
## must leave the fine solve untouched (CJ.2).
func _amplify(p_z0: PackedFloat32Array, p_div: int, p_coarse_iterations: int,
		p_fine_iterations: int) -> PackedFloat32Array:
	var start := p_z0
	if p_coarse_iterations > 0:
		var n := (FINE - 1) / p_div + 1
		var cell := CELL * float(FINE - 1) / float(n - 1)
		var z_c: PackedFloat32Array = _data.resample_grid(p_z0, FINE, FINE, n, n)
		var out_c := _solve(z_c, n, cell, p_coarse_iterations)
		if out_c.is_empty():
			return PackedFloat32Array()
		var d_c := _delta(z_c, out_c)
		var d_up: PackedFloat32Array = _data.resample_grid(d_c, n, n, FINE, FINE)
		start = PackedFloat32Array()
		start.resize(FINE * FINE)
		for i in range(FINE * FINE):
			# The border must stay NaN: it is the outlet, and a bilinear upsample can carry a finite
			# value into it, which would quietly move the boundary condition between the two arms.
			start[i] = (p_z0[i] + d_up[i]) if is_finite(p_z0[i]) else NAN
	return _solve(start, FINE, CELL, p_fine_iterations)


func _solve(p_z: PackedFloat32Array, p_n: int, p_cell: float, p_iterations: int) -> PackedFloat32Array:
	if p_iterations <= 0:
		return p_z
	var params := SOLVER.duplicate()
	params["gw"] = p_n
	params["gh"] = p_n
	params["cell_size"] = p_cell
	params["iterations"] = p_iterations
	var res: Dictionary = _data.erode_heightfield(p_z, params, PackedFloat32Array())
	return res["z"] if bool(res.get("ok", false)) else PackedFloat32Array()


# ---- fixtures --------------------------------------------------------------------------------------


## The same three fixtures gate CK sweeps, as continuous functions of world XZ. `p_seed` shifts only the
## roughness, so the independence null in CJ.1 is the same landform with different detail rather than a
## different landform.
func _surface(p_fixture: String, p_n: int, p_cell: float, p_seed: int) -> PackedFloat32Array:
	var span := float(p_n - 1) * p_cell
	var noise := FastNoiseLite.new()
	noise.seed = 7 + p_seed
	noise.frequency = 1.0 / (span * 0.06)
	var z := PackedFloat32Array()
	z.resize(p_n * p_n)
	for iz in range(p_n):
		for ix in range(p_n):
			var wx := float(ix) * p_cell
			var wz := float(iz) * p_cell
			if wx < BORDER_M or wz < BORDER_M or wx > span - BORDER_M or wz > span - BORDER_M:
				z[iz * p_n + ix] = NAN
				continue
			var u := wx / span
			var v := wz / span
			var rough := 6.0 * noise.get_noise_2d(wx, wz)
			var h := 0.0
			match p_fixture:
				"bowl":
					var dx := (u - 0.5) * 2.0
					var dv := (v - 0.5) * 2.0
					var r := clampf(sqrt(dx * dx + dv * dv), 0.0, 1.0)
					var pr := 1.0 - r
					h = 60.0 * pr * pr * (3.0 - 2.0 * pr) + rough * pr
				"y_catchment":
					var arm_a := absf(u - 0.30 - 0.20 * v)
					var arm_b := absf(u - 0.70 + 0.20 * v)
					var trunk := absf(u - 0.5)
					var valley := (minf(arm_a, arm_b) if v > 0.45 else trunk)
					h = 70.0 * (1.0 - v) - 28.0 * exp(-valley * valley / 0.004) + rough
				"demo":
					var g: float = _data.get_height(Vector3(200.0 + wx, 0.0, 200.0 + wz))
					h = (g if is_finite(g) else 0.0) + rough
			z[iz * p_n + ix] = h
	return z


# ---- measurement -----------------------------------------------------------------------------------


func _delta(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_a.size())
	for i in range(p_a.size()):
		out[i] = (p_b[i] - p_a[i]) if (is_finite(p_a[i]) and is_finite(p_b[i])) else 0.0
	return out


## Structure coarser than 1/div, as gate J measures it.
func _low_pass(p_a: PackedFloat32Array, p_div: int) -> PackedFloat32Array:
	if p_div <= 1:
		return p_a
	var m: int = (FINE - 1) / p_div + 1
	return _data.resample_grid(p_a, FINE, FINE, m, m)


## What is left after the structure coarser than 1/8 is removed - gate J's control.
func _high_pass(p_a: PackedFloat32Array) -> PackedFloat32Array:
	var m: int = (FINE - 1) / 8 + 1
	var coarse: PackedFloat32Array = _data.resample_grid(p_a, FINE, FINE, m, m)
	var trend: PackedFloat32Array = _data.resample_grid(coarse, m, m, FINE, FINE)
	var out := PackedFloat32Array()
	out.resize(p_a.size())
	for i in range(p_a.size()):
		out[i] = p_a[i] - trend[i]
	return out


func _pearson(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return 0.0
	var n := float(p_a.size())
	var ma := 0.0
	var mb := 0.0
	for i in range(p_a.size()):
		ma += p_a[i]
		mb += p_b[i]
	ma /= n
	mb /= n
	var sab := 0.0
	var saa := 0.0
	var sbb := 0.0
	for i in range(p_a.size()):
		var da := p_a[i] - ma
		var db := p_b[i] - mb
		sab += da * db
		saa += da * da
		sbb += db * db
	return sab / maxf(sqrt(saa * sbb), 1.0e-9)


func _rms(p_a: PackedFloat32Array) -> float:
	if p_a.is_empty():
		return 0.0
	var s := 0.0
	for v in p_a:
		s += v * v
	return sqrt(s / float(p_a.size()))


func _first_difference(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> int:
	if p_a.size() != p_b.size():
		return 0
	for i in range(p_a.size()):
		var same := p_a[i] == p_b[i] or (not is_finite(p_a[i]) and not is_finite(p_b[i]))
		if not same:
			return i
	return -1
