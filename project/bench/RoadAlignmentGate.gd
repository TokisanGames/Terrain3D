# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadAlignmentGate — the vertical alignment solver (road P1).
# See PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §7 and §11.
#
# This is the piece that decides whether a road reads as built or as a ribbon draped on a hill, and it
# is pure arithmetic on a 1D array — no terrain, no scene, no DLL. So it is tested against closed-form
# answers rather than against a fixture's remembered numbers:
#
#   A  the gradient limit is a HARD constraint, honoured on terrain that violates it everywhere
#   B  the road CUTS a crest and FILLS a dip — the behaviour that is the whole point
#   C  a vertical wall is refused rather than climbed
#   D  banking equals v²·κ/g against an analytic circular arc, and clamps at max_superelevation
#   E  a pinned height is honoured exactly, and an impossible pair of pins is REPORTED, not smoothed away
#   F  the solved profile's second derivative signs a crest and a dip — the pace-note claim (P6) that a
#      draped road could not support
#
# House discipline: every criterion carries a CONTROL that must move if the path is dead.
extends Node

const DS := 1.0

var _fail := 0


func _ready() -> void:
	print("=== RoadAlignmentGate: vertical alignment solver (P1) ===\n")
	_a_gradient_limit_is_hard()
	_b_cuts_a_crest_and_fills_a_dip()
	_c_a_wall_is_refused()
	_d_banking_matches_physics()
	_e_pins_are_honoured_and_conflicts_reported()
	_f_profile_signs_crest_and_dip()
	print("\n=== %s (%d failures) ===\n" % ["ROAD ALIGNMENT PASS" if _fail == 0 else "ROAD ALIGNMENT FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---- fixtures -----------------------------------------------------------------------------------

## Rolling terrain steep enough that following it would breach any sane gradient limit.
func _rolling(p_n: int, p_amp: float = 30.0, p_wavelength: float = 90.0) -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(p_n)
	for i in p_n:
		g[i] = p_amp * sin(TAU * float(i) * DS / p_wavelength)
	return g


## Flat ground with one Gaussian bump of `p_amp` metres centred at `p_centre`.
func _bump(p_n: int, p_centre: float, p_amp: float, p_sigma: float) -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(p_n)
	for i in p_n:
		var d := (float(i) * DS - p_centre) / p_sigma
		g[i] = p_amp * exp(-0.5 * d * d)
	return g


func _add(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> PackedFloat32Array:
	var out := p_a.duplicate()
	for i in mini(out.size(), p_b.size()):
		out[i] += p_b[i]
	return out


func _rms_delta(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var n := mini(p_a.size(), p_b.size())
	if n == 0:
		return 0.0
	var acc := 0.0
	for i in n:
		var d := p_a[i] - p_b[i]
		acc += d * d
	return sqrt(acc / float(n))


# ---- A ------------------------------------------------------------------------------------------

func _a_gradient_limit_is_hard() -> void:
	print("[A] the gradient limit is a hard constraint")
	var ground := _rolling(400, 30.0, 90.0)
	var ground_grade := 0.0
	for i in range(1, ground.size()):
		ground_grade = maxf(ground_grade, absf(ground[i] - ground[i - 1]) / DS)

	var a := Pasture3DRoadAlignmentSolver.solve(ground, DS, 0.05)
	print("    ground peaks at %.3f grade; solved peak %.5f (limit 0.050), feasible=%s"
			% [ground_grade, a.peak_grade, a.feasible])
	if a.peak_grade > 0.05 + 1e-4 or not a.feasible:
		_fail += 1; print("    !! the solved profile breached its gradient limit")
	if ground_grade <= 0.05:
		_fail += 1; print("    !! fixture is too gentle to test the constraint at all")

	# CONTROL: the limit is what shaped it — raising it produces a DIFFERENT, steeper profile that
	# follows the ground more closely.
	var loose := Pasture3DRoadAlignmentSolver.solve(ground, DS, 0.30)
	var delta := _rms_delta(a.z, loose.z)
	print("    control: limit 0.30 -> peak %.5f, RMS difference from the 0.05 profile %.3f m"
			% [loose.peak_grade, delta])
	if loose.peak_grade <= a.peak_grade + 1e-4 or delta < 0.5:
		_fail += 1; print("    !! raising the limit did not change the profile — the constraint is not binding")


# ---- B ------------------------------------------------------------------------------------------

func _b_cuts_a_crest_and_fills_a_dip() -> void:
	print("[B] the road cuts a crest and fills a dip")
	var n := 600
	var ground := _add(_bump(n, 200.0, 25.0, 40.0), _bump(n, 400.0, -25.0, 40.0))
	var a := Pasture3DRoadAlignmentSolver.solve(ground, DS, 0.10)

	var crest := a.offset_at(200) # road minus ground at the top of the hill: must be NEGATIVE (cut)
	var dip := a.offset_at(400)   # at the bottom of the pit: must be POSITIVE (fill)
	print("    at the crest offset %+.2f m (want cut, <0); at the dip %+.2f m (want fill, >0)"
			% [crest, dip])
	print("    cut %.0f m³/m, fill %.0f m³/m, feasible=%s" % [a.cut_volume, a.fill_volume, a.feasible])
	if crest >= -1.0 or dip <= 1.0:
		_fail += 1; print("    !! the profile followed the terrain instead of cutting and filling")

	# CONTROL: this is the SMOOTHNESS term doing it, not an artefact. Drop it to zero and lift the
	# gradient limit out of the way, and the solve collapses onto the ground — no cut, no fill.
	var hug := Pasture3DRoadAlignmentSolver.solve(ground, DS, 10.0, { "w_smooth": 0.0 })
	var hug_err := _rms_delta(hug.z, ground)
	print("    control: w_smooth=0, limit 10.0 -> RMS from ground %.4f m, cut %.2f, fill %.2f"
			% [hug_err, hug.cut_volume, hug.fill_volume])
	if hug_err > 0.05 or hug.cut_volume > 5.0 or hug.fill_volume > 5.0:
		_fail += 1; print("    !! with smoothness off the profile did not collapse onto the ground")


# ---- C ------------------------------------------------------------------------------------------

func _c_a_wall_is_refused() -> void:
	print("[C] a vertical wall is refused, not climbed")
	# 4 km of run for a 100 m step. An 8% road needs 1250 m to climb that, so a SHORTER fixture would
	# measure the road running out of room rather than the constraint — it would cut the whole 100 m and
	# never embank, which is the correct answer to an impossible question and tells us nothing.
	var n := 4000
	var ground := PackedFloat32Array()
	ground.resize(n)
	for i in n:
		ground[i] = 0.0 if i < n / 2 else 100.0 # a 100 m step, straight up

	var a := Pasture3DRoadAlignmentSolver.solve(ground, DS, 0.08)
	var step_grade := absf(ground[n / 2] - ground[n / 2 - 1]) / DS
	print("    the ground steps at grade %.1f; the road peaks at %.5f (limit 0.080), feasible=%s"
			% [step_grade, a.peak_grade, a.feasible])
	if a.peak_grade > 0.08 + 1e-4 or not a.feasible:
		_fail += 1; print("    !! the road climbed the wall")

	# It refuses by CUTTING AND FILLING across the step rather than by giving up: it should stand well
	# above the low side and well below the high side, near the discontinuity.
	var below := a.offset_at(n / 2 - 300)
	var above := a.offset_at(n / 2 + 300)
	print("    300 m before the step offset %+.1f m (fill); 300 m after %+.1f m (cut)" % [below, above])
	if below <= 1.0 or above >= -1.0:
		_fail += 1; print("    !! the road did not embank up to / cut down from the step")

	# The earth term is symmetric and the ground is antisymmetric about the step, so the correct profile
	# is too: it should cross the step at half height, spending as much fill on the low side as cut on the
	# high side. This is the check that caught a direction-biased gradient projection which produced a
	# feasible profile with about four times the earthworks — see _project_grade.
	var at_step := a.z[n / 2] - 50.0
	print("    the road crosses the step at %+.1f m from half height; fill %.0f vs cut %.0f"
			% [at_step, a.fill_volume, a.cut_volume])
	if absf(at_step) > 5.0:
		_fail += 1; print("    !! the climb is not centred on the step — the projection is biased")
	if absf(a.fill_volume - a.cut_volume) > 0.05 * maxf(a.fill_volume, 1.0):
		_fail += 1; print("    !! cut and fill are lopsided on symmetric ground")

	# CONTROL: a gradient limit that CAN take the step is met exactly — so [C] measures the constraint,
	# not an inability to move.
	var steep := Pasture3DRoadAlignmentSolver.solve(ground, DS, 2.0)
	print("    control: limit 2.0 -> peak %.4f, feasible=%s" % [steep.peak_grade, steep.feasible])
	if not steep.feasible or steep.peak_grade <= a.peak_grade:
		_fail += 1; print("    !! a permissive limit did not produce a steeper legal profile")


# ---- D ------------------------------------------------------------------------------------------

func _d_banking_matches_physics() -> void:
	print("[D] banking equals v²·κ/g on an analytic arc")
	var radius := 200.0
	var n := 500
	var plan := PackedVector2Array()
	plan.resize(n)
	for i in n:
		var theta := float(i) * DS / radius # arc length -> angle, so samples are DS apart
		plan[i] = Vector2(radius * cos(theta), radius * sin(theta)) # counter-clockwise = turning LEFT
	var ground := PackedFloat32Array()
	ground.resize(n)
	ground.fill(0.0)

	var speed := 25.0
	var a := Pasture3DRoadAlignmentSolver.solve_with_plan(plan, ground, DS, 0.08, speed, 1.0)
	var mid := n / 2
	var want_k := 1.0 / radius
	var want_bank := speed * speed * want_k / 9.81
	print("    curvature %.6f (want %.6f), bank %.5f (want %.5f)"
			% [a.curvature[mid], want_k, a.bank[mid], want_bank])
	# Menger curvature is EXACT for three points on a circle, so the residual here is pure float32:
	# the plan is stored as Vector2 (32-bit), and a curvature built from differences of ~200 m
	# coordinates loses about three digits to cancellation. 1% of 1/R is the honest tolerance, and it is
	# a real limit worth carrying forward — see the note in Pasture3DRoadAlignmentSolver.plan_curvature.
	if absf(a.curvature[mid] - want_k) > want_k * 0.01:
		_fail += 1; print("    !! plan curvature does not match 1/R")
	if absf(a.bank[mid] - want_bank) > want_bank * 0.01:
		_fail += 1; print("    !! banking does not match v²·κ/g")
	if a.curvature[mid] <= 0.0:
		_fail += 1; print("    !! a left-hand turn did not produce positive curvature")

	# CONTROL 1: the cap binds. Same corner, a road-legal max_superelevation.
	var capped := Pasture3DRoadAlignmentSolver.solve_with_plan(plan, ground, DS, 0.08, speed, 0.06)
	print("    control: max_superelevation 0.06 -> bank %.5f (clamped)" % capped.bank[mid])
	if absf(capped.bank[mid] - 0.06) > 1e-4:
		_fail += 1; print("    !! max_superelevation did not clamp the bank")

	# CONTROL 2: a straight road banks at zero, so [D] is measuring curvature and not a constant.
	var straight := PackedVector2Array()
	straight.resize(n)
	for i in n:
		straight[i] = Vector2(float(i) * DS, 0.0)
	var flat := Pasture3DRoadAlignmentSolver.solve_with_plan(straight, ground, DS, 0.08, speed, 1.0)
	print("    control: a straight run banks %.6f (want 0)" % flat.bank[mid])
	if absf(flat.bank[mid]) > 1e-5:
		_fail += 1; print("    !! a straight road was banked")


# ---- E ------------------------------------------------------------------------------------------

func _e_pins_are_honoured_and_conflicts_reported() -> void:
	print("[E] pins are honoured exactly; an impossible pair is reported")
	var n := 400
	var ground := _rolling(n, 20.0, 120.0)

	# Feasible: two pins 300 m apart asking for 6 m of rise. Needs 2%, and the road allows 8%.
	var pins := { 50: 10.0, 350: 16.0 }
	var a := Pasture3DRoadAlignmentSolver.solve(ground, DS, 0.08, { "pins": pins })
	var at_50 := a.z[50]
	var at_350 := a.z[350]
	print("    pinned 50->10.0 got %.4f, 350->16.0 got %.4f; pin_error %.8f, peak %.5f, feasible=%s"
			% [at_50, at_350, a.pin_error, a.peak_grade, a.feasible])
	if absf(at_50 - 10.0) > 1e-3 or absf(at_350 - 16.0) > 1e-3:
		_fail += 1; print("    !! a pinned height was not honoured")
	if not a.feasible:
		_fail += 1; print("    !! a satisfiable pin pair was reported infeasible")

	# CONTROL: the pins actually shaped the result — the same terrain unpinned differs at those samples.
	var unpinned := Pasture3DRoadAlignmentSolver.solve(ground, DS, 0.08)
	print("    control: unpinned, sample 50 is %.3f (pinned run: %.3f)" % [unpinned.z[50], at_50])
	if absf(unpinned.z[50] - at_50) < 1.0:
		_fail += 1; print("    !! pinning changed nothing — the pins are not being applied")

	# Impossible: 50 m of rise over 10 m of road, on an 8% limit. Pins win, so the breach shows up in
	# the GRADIENT rather than as a pin that quietly slid.
	var bad := Pasture3DRoadAlignmentSolver.solve(ground, DS, 0.08, { "pins": { 100: 0.0, 110: 50.0 } })
	print("    impossible pins -> z[100]=%.3f z[110]=%.3f, peak %.4f, feasible=%s"
			% [bad.z[100], bad.z[110], bad.peak_grade, bad.feasible])
	if bad.feasible:
		_fail += 1; print("    !! an unsatisfiable pin pair was reported feasible")
	if absf(bad.z[100]) > 1e-3 or absf(bad.z[110] - 50.0) > 1e-3:
		_fail += 1; print("    !! pins did not win — one was silently moved to satisfy the gradient")


# ---- F ------------------------------------------------------------------------------------------

func _f_profile_signs_crest_and_dip() -> void:
	print("[F] the solved profile's second derivative signs a crest and a dip (the P6 pace-note claim)")
	# The bump is deliberately GENTLE — 15 m over a 150 m sigma peaks at about 6% against a 10% limit. A
	# steeper one measures the wrong thing: where the gradient constraint binds, the solved profile is a
	# straight max-grade ramp, whose second difference is exactly zero. That is the solver working, but it
	# reads as "no crest" and the first version of this criterion failed on it.
	var n := 900
	var ground := _add(_bump(n, 300.0, 15.0, 150.0), _bump(n, 600.0, -15.0, 150.0))
	var a := Pasture3DRoadAlignmentSolver.solve(ground, DS, 0.10)

	# And the sample points are the ROAD's own crest and dip, not the ground's. The solve is free to shift
	# a summit downhill, so asking at the ground's peak index tests where the terrain is highest rather
	# than what the road does — the two only coincide on a road that drapes.
	var hi := 1
	var lo := 1
	for i in range(1, a.count() - 1):
		if a.z[i] > a.z[hi]:
			hi = i
		if a.z[i] < a.z[lo]:
			lo = i
	var at_crest := a.vertical_curvature_at(hi)
	var at_dip := a.vertical_curvature_at(lo)
	print("    road crest at s=%d (ground crest 300), dip at s=%d (ground dip 600)" % [hi, lo])
	print("    d²z/ds² at the crest %+.8f (want <0), at the dip %+.8f (want >0)" % [at_crest, at_dip])
	if at_crest >= 0.0 or at_dip <= 0.0:
		_fail += 1; print("    !! the profile does not distinguish a crest from a dip")
	if absf(hi - 300) > 120 or absf(lo - 600) > 120:
		_fail += 1; print("    !! the road's crest/dip is nowhere near the terrain's")

	# CONTROL: flat ground produces neither call, so [F] is reading road shape rather than always
	# reporting a feature wherever it is asked.
	var flat_ground := PackedFloat32Array()
	flat_ground.resize(n)
	flat_ground.fill(12.0)
	var flat := Pasture3DRoadAlignmentSolver.solve(flat_ground, DS, 0.10)
	var flat_crest := absf(flat.vertical_curvature_at(200))
	print("    control: flat terrain -> |d²z/ds²| %.9f (want ~0)" % flat_crest)
	if flat_crest > 1e-6:
		_fail += 1; print("    !! a flat road reported vertical curvature")

	# The structure helper gets its OWN fixture. The gentle bump above is right for reading curvature and
	# wrong for this: the road stands under a metre clear of it, so any threshold that reported an
	# interval there would be reporting the threshold. A steep pair puts the road tens of metres off the
	# ground, and both a tunnel (through the crest) and a bridge (over the dip) should appear.
	var steep_ground := _add(_bump(600, 200.0, 25.0, 60.0), _bump(600, 400.0, -25.0, 60.0))
	var steep := Pasture3DRoadAlignmentSolver.solve(steep_ground, DS, 0.10)
	var peak_offset := 0.0
	for i in steep.count():
		peak_offset = maxf(peak_offset, absf(steep.offset_at(i)))
	print("    steep fixture: the road stands at most %.1f m clear of the ground" % peak_offset)
	var intervals := steep.structure_intervals(4.0, 4.0)
	print("    structure intervals (threshold 4 m): %s" % [intervals])
	var saw_bridge := false
	var saw_tunnel := false
	for iv: Array in intervals:
		if bool(iv[2]):
			saw_bridge = true
		else:
			saw_tunnel = true
	if not saw_bridge or not saw_tunnel:
		_fail += 1; print("    !! expected a tunnel through the crest and a bridge over the dip")

	# CONTROL: the same helper on the gentle fixture, where the road hugs the ground, reports nothing —
	# so an interval means the road stood clear, not that the helper always finds something.
	print("    control: gentle fixture at the same threshold -> %s" % [a.structure_intervals(4.0, 4.0)])
	if not a.structure_intervals(4.0, 4.0).is_empty():
		_fail += 1; print("    !! a road hugging the ground reported a structure")
