# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadSmoothGate — the alignment smoothing pass (road P9b).
# See PASTURE3D_ROAD_JUNCTION_PAINT_AND_SMOOTHING_SPEC.md §3.
#
# `smooth_radius` conditions the SOLVED vertical profile: it removes bumps shorter than the radius, and
# raising it removes progressively longer ones. Like the solver it wraps, this is pure arithmetic on a
# 1D array — no terrain, no scene — so every claim below is decidable from numbers.
#
#   A  radius 0 is BIT-IDENTICAL to a solve without the pass
#   B  a radius sized to the short bump kills the short band and spares the long one; a radius sized to
#      the long bump kills BOTH
#   C  pins are honoured exactly after smoothing
#   D  the gradient limit still holds after smoothing
#   E  curvature and banking are untouched by it
#   F  peak_grade and feasible describe the SMOOTHED profile
#   G  native and forced-GDScript agree, measured with the pass ON
#
# ---- EVERY CRITERION RUNS TWICE ----
#
# Once native and once under `force_gdscript`. The pass exists in both `road_align_solve`
# (src/pasture_3d_road_grade.cpp) and `Pasture3DRoadAlignmentSolver._smooth_profile`, which is the
# arrangement R7 established so the GDScript body stays an independent oracle. A native-only run cannot
# tell a correct pass from one the oracle never received.
#
# ---- WHY B IS THE CRITERION THAT MATTERS ----
#
# A smoothing pass that did nothing at all would pass A, C, D, E, F and G. Only B can tell "measured
# nothing" from "measured well", and only because it measures the two bands SEPARATELY: a drop in
# overall RMS is equally consistent with the pass having flattened the whole road.
#
# ---- WHAT THE MUTATION TESTS FOUND, SO NOBODY REPEATS THEM ----
#
# Three deliberate breakages were run against this gate before it was trusted:
#
#   two box passes instead of three  -> [B] and [G] fire. [B] catches it because it compares against
#       the kernel's closed-form transfer function rather than a threshold; a two-pass filter still
#       looks like smoothing and would sail past any round number.
#   drop BOTH re-projections         -> [C] and [G] fire. [D] does NOT: with the pins gone the pinned
#       samples slide with everything else, so the profile stays gentle. This is the trap - it makes
#       [D] look decorative.
#   keep _apply_pins, drop only      -> [D] fires at 0.732 against a 0.050 limit, which is the
#   _project_grade                      pin-adjacent breach the spec predicts: the pin snaps back to
#       its height while its neighbours have been smoothed away from it.
#
# So both projections are load-bearing and each is caught by a DIFFERENT criterion. Neither can be
# dropped as redundant, and [D] cannot be judged by the mutation that happens to be easiest to write.
extends Node

const DS := 1.0
## 2 km at 1 m. Long enough that a 400 m wavelength is resolved several times over.
const N := 2000

## The two bands the fixture superimposes. The short one is a bump a driver feels; the long one is the
## shape of the land, which smoothing must NOT eat at a small radius.
const SHORT_WAVELENGTH := 60.0
const SHORT_AMP := 0.3
const LONG_WAVELENGTH := 400.0
const LONG_AMP := 2.0

var _fail := 0


func _ready() -> void:
	print("=== RoadSmoothGate: alignment smoothing (P9b) ===\n")
	for forced: bool in [false, true]:
		var tag := "GDScript oracle" if forced else "native"
		print("---- %s ----" % tag)
		_a_zero_is_identical(forced, tag)
		_b_radius_selects_a_band(forced, tag)
		_c_pins_survive(forced, tag)
		_d_grade_limit_survives(forced, tag)
		_e_banking_is_untouched(forced, tag)
		_f_diagnostics_describe_the_smoothed_profile(forced, tag)
		print("")
	_g_native_matches_the_oracle()
	print("\n=== %s (%d failures) ===\n" % ["ROAD SMOOTH PASS" if _fail == 0 else "ROAD SMOOTH FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---- fixtures -----------------------------------------------------------------------------------

## Two superimposed sinusoids: the short bump the pass should remove, on the long shape it should keep.
func _two_band_ground() -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(N)
	for i in N:
		var s := float(i) * DS
		g[i] = SHORT_AMP * sin(TAU * s / SHORT_WAVELENGTH) + LONG_AMP * sin(TAU * s / LONG_WAVELENGTH)
	return g


## Amplitude of `p_z` at `p_wavelength`, by projection onto that band's sine and cosine.
##
## A band-specific measurement, not an RMS. The whole claim is that one band moves and the other does
## not, and an RMS cannot distinguish "removed the ripple" from "flattened everything".
func _band_amplitude(p_z: PackedFloat32Array, p_wavelength: float) -> float:
	var n := p_z.size()
	var acc_s := 0.0
	var acc_c := 0.0
	for i in n:
		var phase := TAU * float(i) * DS / p_wavelength
		acc_s += p_z[i] * sin(phase)
		acc_c += p_z[i] * cos(phase)
	return 2.0 * sqrt(acc_s * acc_s + acc_c * acc_c) / float(n)


## Gain of THREE box passes of half-width `p_half` at a wavelength of `p_lambda` samples, in closed
## form: the box's transfer function is a Dirichlet kernel, and three passes cube it.
##
## The criterion below compares against THIS rather than against a round number. A round number is a
## guess about what the filter should do; this is what a triple box provably does, so a kernel that
## drifted - a wrong half-width, two passes instead of three, a window off by one - fails even where it
## still looks like smoothing. The first draft of this gate asserted "the long band keeps >90%" and the
## implementation returned 89.3%; the implementation was right and the round number was wrong.
func _box3_gain(p_lambda: float, p_half: int) -> float:
	var w := float(2 * p_half + 1)
	var num := sin(PI * w / p_lambda)
	var den := w * sin(PI / p_lambda)
	if absf(den) < 1e-12:
		return 1.0
	var h := num / den
	return h * h * h


func _solve(p_ground: PackedFloat32Array, p_radius: float, p_forced: bool,
		p_pins: Dictionary = {}, p_max_grade: float = 0.15) -> Pasture3DRoadAlignment:
	return Pasture3DRoadAlignmentSolver.solve(p_ground, DS, p_max_grade,
			{"pins": p_pins, "smooth_radius": p_radius}, p_forced)


func _max_abs_delta(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var n := mini(p_a.size(), p_b.size())
	var m := 0.0
	for i in n:
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m


func _peak_grade_of(p_z: PackedFloat32Array) -> float:
	var m := 0.0
	for i in range(1, p_z.size()):
		m = maxf(m, absf(p_z[i] - p_z[i - 1]) / DS)
	return m


# ---- A ------------------------------------------------------------------------------------------

## The control that proves the pass is OFF at zero rather than approximately off. Bit-identical, not
## close: a filter with a half-width of zero that still ran would land within any tolerance.
func _a_zero_is_identical(p_forced: bool, p_tag: String) -> void:
	print("[A] radius 0 is bit-identical to no smoothing (%s)" % p_tag)
	var ground := _two_band_ground()
	var base := Pasture3DRoadAlignmentSolver.solve(ground, DS, 0.15, {}, p_forced)
	var zero := _solve(ground, 0.0, p_forced)
	var d := _max_abs_delta(base.z, zero.z)
	print("    max |dz| vs a solve with no smooth_radius at all: %.9f m" % d)
	if d != 0.0:
		_fail += 1; print("    !! radius 0 changed the profile")

	# Control: a non-zero radius must move it, or A is passing because nothing is wired up.
	var on := _solve(ground, 20.0, p_forced)
	var moved := _max_abs_delta(base.z, on.z)
	print("    control: radius 20 m moves it by %.5f m" % moved)
	if moved < 1e-4:
		_fail += 1; print("    !! smoothing changed nothing - the option is not reaching the solver")


# ---- B ------------------------------------------------------------------------------------------

func _b_radius_selects_a_band(p_forced: bool, p_tag: String) -> void:
	print("[B] the radius selects which band is removed (%s)" % p_tag)
	var ground := _two_band_ground()
	# No gradient limit worth binding and no pins: this criterion is about the filter, and a profile
	# clipped by the projections would confound the measurement.
	var base := _solve(ground, 0.0, p_forced, {}, 10.0)
	var short_0 := _band_amplitude(base.z, SHORT_WAVELENGTH)
	var long_0 := _band_amplitude(base.z, LONG_WAVELENGTH)
	print("    unsmoothed: short band %.4f m, long band %.4f m" % [short_0, long_0])
	if short_0 < 1e-3 or long_0 < 1e-3:
		_fail += 1; print("    !! the fixture carries no signal in one of its bands - nothing to measure")
		return

	# A radius at half the short wavelength: three box passes of that support annihilate it.
	var small_radius := SHORT_WAVELENGTH * 0.5
	var small := _solve(ground, small_radius, p_forced, {}, 10.0)
	var short_s := _band_amplitude(small.z, SHORT_WAVELENGTH) / short_0
	var long_s := _band_amplitude(small.z, LONG_WAVELENGTH) / long_0
	var predicted := _box3_gain(LONG_WAVELENGTH / DS, int(round(small_radius / DS)))
	print("    radius %.0f m: short band retains %.1f%%, long band retains %.1f%% (kernel predicts %.1f%%)"
			% [small_radius, short_s * 100.0, long_s * 100.0, predicted * 100.0])
	if short_s > 0.10:
		_fail += 1; print("    !! the short bump survived a radius sized to remove it")
	# The long band is NOT untouched - a triple box of this width takes a predictable bite out of it -
	# so the claim is that it loses only what the kernel says it must, and that the short band loses
	# an order of magnitude more.
	if absf(long_s - predicted) > 0.02:
		_fail += 1; print("    !! the long band does not match the kernel's own transfer function")
	if long_s < 0.80:
		_fail += 1; print("    !! a radius sized for the short bump ate the long one too")
	if short_s > long_s * 0.2:
		_fail += 1; print("    !! the two bands were attenuated alike - this is not band selection")

	# The control, and the actual claim the user asked for: raise it and the LONG band goes too.
	var big := _solve(ground, LONG_WAVELENGTH * 0.5, p_forced, {}, 10.0)
	var short_b := _band_amplitude(big.z, SHORT_WAVELENGTH) / short_0
	var long_b := _band_amplitude(big.z, LONG_WAVELENGTH) / long_0
	print("    radius %.0f m: short band retains %.1f%%, long band retains %.1f%%"
			% [LONG_WAVELENGTH * 0.5, short_b * 100.0, long_b * 100.0])
	if long_b > 0.10:
		_fail += 1; print("    !! raising the radius did not remove the larger bump")


# ---- C ------------------------------------------------------------------------------------------

## A filter over the solved profile would drag a pin off its height. Pins winning is the solver's
## documented contract, and a junction elevation that slid silently is the failure this prevents.
func _c_pins_survive(p_forced: bool, p_tag: String) -> void:
	print("[C] pins are honoured exactly after smoothing (%s)" % p_tag)
	var ground := _two_band_ground()
	var pins := {200: 8.0, 1200: -6.0}
	var a := _solve(ground, 40.0, p_forced, pins)
	var worst := 0.0
	for k: Variant in pins:
		worst = maxf(worst, absf(a.z[int(k)] - float(pins[k])))
	print("    worst pin error after a 40 m smooth: %.9f m (reported %.9f)" % [worst, a.pin_error])
	if worst > 1e-4:
		_fail += 1; print("    !! smoothing moved a pinned sample")

	# Control: the pins are far enough off the solved profile that an unprotected filter WOULD move
	# them. If they sit where the profile already was, C proves nothing.
	var unpinned := _solve(ground, 40.0, p_forced)
	var pull := 0.0
	for k: Variant in pins:
		pull = maxf(pull, absf(unpinned.z[int(k)] - float(pins[k])))
	print("    control: those samples sit %.3f m from the unpinned profile" % pull)
	if pull < 1.0:
		_fail += 1; print("    !! the pins are not displaced enough for this to be a test")


# ---- D ------------------------------------------------------------------------------------------

func _d_grade_limit_survives(p_forced: bool, p_tag: String) -> void:
	print("[D] the gradient limit still holds after smoothing (%s)" % p_tag)
	# Ground steep enough that the solve is pinned against the limit before smoothing runs.
	var ground := PackedFloat32Array()
	ground.resize(N)
	for i in N:
		ground[i] = 30.0 * sin(TAU * float(i) * DS / 90.0)
	var limit := 0.05
	var a := _solve(ground, 30.0, p_forced, {400: 12.0}, limit)
	var peak := _peak_grade_of(a.z)
	print("    peak grade after a 30 m smooth: %.5f (limit %.3f), feasible=%s"
			% [peak, limit, a.feasible])
	if peak > limit + 1e-4:
		_fail += 1; print("    !! smoothing breached the gradient limit")

	# Control: the fixture must actually bind the limit, or D is measuring a gentle road.
	var unsmoothed := _solve(ground, 0.0, p_forced, {400: 12.0}, limit)
	print("    control: unsmoothed peak is %.5f, i.e. %.0f%% of the limit"
			% [unsmoothed.peak_grade, unsmoothed.peak_grade / limit * 100.0])
	if unsmoothed.peak_grade < limit * 0.9:
		_fail += 1; print("    !! the fixture never approaches its limit - D cannot fail here")


# ---- E ------------------------------------------------------------------------------------------

## A guard rather than a claim about smoothing. Curvature comes from the PLAN and banking from
## curvature, so smoothing the vertical profile cannot touch either. If this ever fails, something is
## reading `z` that should not be.
func _e_banking_is_untouched(p_forced: bool, p_tag: String) -> void:
	print("[E] curvature and banking are untouched by smoothing (%s)" % p_tag)
	var ground := _two_band_ground()
	var plan := PackedVector2Array()
	plan.resize(N)
	var radius := 300.0
	for i in N:
		var theta := float(i) * DS / radius
		plan[i] = Vector2(radius * sin(theta), radius * (1.0 - cos(theta)))

	var off := Pasture3DRoadAlignmentSolver.solve_with_plan(plan, ground, DS, 0.15, 25.0, 0.08,
			{"smooth_radius": 0.0}, p_forced)
	var on := Pasture3DRoadAlignmentSolver.solve_with_plan(plan, ground, DS, 0.15, 25.0, 0.08,
			{"smooth_radius": 40.0}, p_forced)
	var dk := _max_abs_delta(off.curvature, on.curvature)
	var db := _max_abs_delta(off.bank, on.bank)
	print("    max |dcurvature| %.9f, max |dbank| %.9f" % [dk, db])
	if dk != 0.0 or db != 0.0:
		_fail += 1; print("    !! smoothing moved banking - something reads z that should not")

	# Control: banking is non-zero here, so "identical" means something.
	var peak_bank := 0.0
	for v in off.bank:
		peak_bank = maxf(peak_bank, absf(v))
	print("    control: the arc banks to %.4f rad" % peak_bank)
	if peak_bank < 1e-3:
		_fail += 1; print("    !! the fixture is not banking - E compares two zeroed arrays")


# ---- F ------------------------------------------------------------------------------------------

## The diagnostics must be filled AFTER the pass, or `peak_grade` and `feasible` describe a profile
## that is not the one being handed to the grader.
func _f_diagnostics_describe_the_smoothed_profile(p_forced: bool, p_tag: String) -> void:
	print("[F] peak_grade describes the smoothed profile (%s)" % p_tag)
	var ground := _two_band_ground()
	var a := _solve(ground, 50.0, p_forced, {}, 10.0)
	var measured := _peak_grade_of(a.z)
	print("    reported peak_grade %.6f vs measured on the returned z %.6f" % [a.peak_grade, measured])
	if absf(a.peak_grade - measured) > 1e-5:
		_fail += 1; print("    !! the reported grade is not the returned profile's")

	# Control: smoothing must have CHANGED the peak grade, or F would pass with the diagnostics
	# filled at any point in the solve.
	var unsmoothed := _solve(ground, 0.0, p_forced, {}, 10.0)
	print("    control: unsmoothed peak_grade is %.6f" % unsmoothed.peak_grade)
	if absf(unsmoothed.peak_grade - a.peak_grade) < 1e-5:
		_fail += 1; print("    !! smoothing did not move the peak grade - F cannot fail here")


# ---- G ------------------------------------------------------------------------------------------

## The A/B the whole two-implementation arrangement exists for. Measured with the pass ON: at radius 0
## both sides do nothing and agreement proves nothing about either.
func _g_native_matches_the_oracle() -> void:
	print("[G] native and the GDScript oracle agree with the pass ON")
	if not ClassDB.class_has_method("Pasture3DUtil", "road_align_solve"):
		print("    NO-SIGNAL: the extension is not loaded, so both paths ARE the oracle")
		_fail += 1
		return
	var ground := _two_band_ground()
	var pins := {200: 8.0, 1200: -6.0}
	for radius: float in [15.0, 40.0, 120.0]:
		var nat := _solve(ground, radius, false, pins)
		var gds := _solve(ground, radius, true, pins)
		var d := _max_abs_delta(nat.z, gds.z)
		print("    radius %6.1f m: max |dz| %.7f m, peak %.6f vs %.6f"
				% [radius, d, nat.peak_grade, gds.peak_grade])
		# 1e-3 m, the bar RoadNativeParityGate [G] already sets for this exact comparison. It is not a
		# widened threshold: the native solve carries a convergence break that stops when the whole
		# iteration moves less than 1e-4 m and the GDScript body runs its full iteration count, so the
		# two profiles differ by around that much BEFORE smoothing is involved at all. Asserting tighter
		# than the pre-existing difference would be asserting the wrong thing.
		if d > 1.0e-3:
			_fail += 1; print("    !! the two implementations diverge")

	# Control: the comparison is being made on a profile the pass actually changed.
	var off := _solve(ground, 0.0, false, pins)
	var on := _solve(ground, 40.0, false, pins)
	var moved := _max_abs_delta(off.z, on.z)
	print("    control: smoothing moves the compared profile by %.5f m" % moved)
	if moved < 1e-3:
		_fail += 1; print("    !! G is comparing two unsmoothed profiles")
