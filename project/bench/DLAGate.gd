# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gates CP, CQ, CR and CS — Pasture3DReliefDLA, phase 6 of PASTURE3D_BRUSH_EROSION_SPEC.md §9.
#
# DLA is the first relief op that is NOT point-evaluated. It grows a cluster once per compile in GDScript,
# bakes it into the program's field table, and both evaluators bilinear-sample the same bytes. That buys
# oracle parity by construction — but "by construction" is an argument, and this file is what turns it
# into a measurement. Four claims:
#
#   CP  the field is a pure function of the seed
#   CQ  the field is dendritic, not a smooth blob and not noise
#   CR  the C++ op and the GDScript oracle read the same field
#   CS  a loop-sized material warns under Mapping = Tile
#   CX  Coverage sizes it, Detail Size styles it, and neither does the other's job
#   CY  a seeded cluster grows along the ridges it was handed
#   CZ  the surface it is handed is the stack ABOVE it, so it cannot feed itself
#   DA  the ridges are the same size in both directions on a loop that is not square
#   DK  FROZEN holds the mountain it grew, and Bake Mountain regrows it against what is there NOW
#   DL  the growth run on a worker gives the same terrain as the growth run inside the bake
#
# CQ IS THE ONE THAT NEEDED THINKING ABOUT, so its design is written out at the gate. In short: no single
# scalar separates a DLA from both nulls, so it uses two, each with the null it is there to exclude.
#
# NOTHING IS SAVED. Bakes write into the terrain's in-memory layers.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/DLAGate.tscn
extends Node

const DEMO_DATA := "res://demo/data"
const SITE_CR := Vector3(300.0, 0.0, 300.0)
const SITE_CZ := Vector3(600.0, 0.0, 300.0)
const SITE_CZ_OFF := Vector3(300.0, 0.0, 600.0)
const SITE_DB := Vector3(600.0, 0.0, 600.0)
const SITE_DL := Vector3(900.0, 0.0, 300.0)
const SITE_DL2 := Vector3(900.0, 0.0, 600.0)
## Working grid for CY's synthetic seed surface.
const SEED_G := 129
## What counts as "the field is zero here". A cumulative box blur has finite support in exact arithmetic
## and a denormal tail in float32, so PRESENCE of a non-zero cell is not a usable test — 1e-30 of full
## height is 30 femtometres on a 30 m brush. The invariant is about magnitude, and this is the magnitude:
## a millionth of full height, which is sub-micron on any brush anyone will ever author.
const FIELD_ZERO := 1.0e-6
const HALF := 60.0

## The A/B tolerance every relief path in this plugin is held to (PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC §10).
const PARITY_TOL := 1.0e-4
## Relief amplitude for CR's absolute half. An ORDINARY one - HostProfileGate bakes 7 m, BrushRegistryGate
## 8 m - because the residual scales with it and a gate that picked a dramatic 30 m mountain would be
## reporting the amplitude it chose rather than anything about the sampling.
const RELIEF_M := 8.0

## House rule (bench/OceanBench.gd): a GDScript runtime error abandons the function WITHOUT incrementing
## the failure count, so a suite that only counts failures can report a clean pass having measured
## nothing. Each gate increments `_completed` as its last statement and the verdict requires all of them.
const GATES := 11
## DA's loop: 180 m by 60 m, i.e. 3:1. Enough that a stretched field is unmistakable, and not so much
## that the massif runs out of short axis to carry a ridge-spacing statistic (see bench/DlaAspectProbe.gd,
## where 9:1 at this resolution is dominated by that and not by any stretch).
const DA_EX := 90.0
const DA_EZ := 30.0
## Metres between DA's samples, and the fraction of the peak below which a sample is off the massif.
const DA_STEP := 0.5
const DA_FLOOR := 0.05
## The isotropy band. Wide on purpose: measured, this metric reads 0.908 on a genuinely isotropic SQUARE
## loop, so its own floor is nine points off 1.000 and a tight band would be reporting the metric. The
## defect it has to catch is 0.38 at this aspect and falls as 1/aspect, so there is a decade of daylight.
const DA_BAND_LO := 0.80
const DA_BAND_HI := 1.25

var _fail := 0
var _completed := 0
var _root: Node3D
var _terrain
var _vs := 1.0


func _ready() -> void:
	print("\n=== DLA relief (gates CP, CQ, CR, CS) ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_vs = _terrain.vertex_spacing

	_gate_cp_deterministic()
	_gate_cq_dendritic()
	_gate_cr_parity()
	_gate_cs_tile_warns()
	_gate_cx_size_and_detail()
	_gate_cy_seeded_growth()
	_gate_cz_capture_excludes_itself()
	_gate_da_isotropic()
	_gate_db_stacked_seeding()
	_gate_dk_frozen_holds()
	await _gate_dl_deferred_growth()

	if _completed != GATES:
		_fail += 1
		print("\n!! only %d of %d gates ran to completion; the rest hit a runtime error and measured nothing"
				% [_completed, GATES])
	print("\n=== %s (%d failures) ===\n" % ["DLA PASS" if _fail == 0 else "DLA FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- CP: the field is a pure function of the seed ---------------------------------------------------
#
# The field is part of the COMPILED PROGRAM, not of the saved resource. A .tres carries the seed and the
# growth properties; the mountain itself is regrown every time the material is loaded. So "same seed,
# same bytes" is not a nicety — it is the only thing standing between an artist and a landscape that
# moves under their brushes every time the project is reopened.
#
# Measured on TWO SEPARATE INSTANCES, never on one compiled twice: the material memoises its field on the
# growth inputs, so a single instance would compare a cache against itself and pass whatever the growth
# code did.
#
# CONTROL. The spec's: the same growth code driven by an RNG seeded from the clock, which must produce a
# different field on each of two runs. That is what shows the bitwise comparison has teeth, and it runs
# through _grow / _rasterise / _mass — the very functions under test — rather than through some other
# path that happens to differ.
func _gate_cp_deterministic() -> void:
	print("\n[CP] the field is a pure function of the seed:")
	var a := _dla(7, 256)
	var b := _dla(7, 256)
	var c := _dla(8, 256)
	var fa := _field(a)
	var fb := _field(b)
	var fc := _field(c)
	if fa.is_empty() or fb.is_empty() or fc.is_empty():
		_fail += 1
		print("    !! a material compiled to no field at all; nothing was measured")
		return

	# The field must actually be a mountain before "identical" means anything: two empty grids are
	# identical too, and so are two flat ones.
	var span := _span(fa)
	print("    field %d cells, range 0..%.4f, %.1f%% of it above half height"
			% [fa.size(), span, 100.0 * _frac_above(fa, 0.5)])
	if span < 0.9:
		_fail += 1
		print("    !! the field is flat; an identity test on it proves nothing")

	print("    seed 7 vs seed 7 (separate instances): %s"
			% ["BITWISE IDENTICAL" if _identical(fa, fb) else "DIFFER"])
	if not _identical(fa, fb):
		_fail += 1
		print("    !! two bakes of one seed produce different mountains")
	var moved := _max_diff(fa, fc)
	print("    seed 7 vs seed 8: worst |difference| %.4f of full height" % moved)
	if moved < 0.25:
		_fail += 1
		print("    !! changing the seed barely changed the field; the seed is not driving the growth")

	# CONTROL
	var t1 := _clock_grown(256)
	var t2 := _clock_grown(256)
	print("    CONTROL the same growth code on a clock-seeded RNG, twice: %s (worst %.4f)"
			% ["differ" if not _identical(t1, t2) else "IDENTICAL", _max_diff(t1, t2)])
	if _identical(t1, t2):
		_fail += 1
		print("    !! the growth ignores its RNG, so CP's identity result is about nothing")
	_completed += 1


# --- CQ: it is dendritic, not noise -----------------------------------------------------------------
#
# The claim §9 makes is structural: DLA arrives at the branching statistics erosion produces, which is
# why DLA-then-erosion reinforces. So the gate has to separate a branching network from the two things
# that would look plausible in a screenshot and be worthless underneath.
#
# NO SINGLE SCALAR DOES IT, and finding that out is most of this gate's history. Measured on the shipped
# defaults at 512²:
#
#     statistic                     DLA     blurred white noise     smooth cone
#     largest component's share    1.00            0.10                1.00
#     max components over a sweep    10             896                   1
#
# The first says the mass forms ONE network rather than scattered lumps; noise fails it, a cone passes it
# trivially. The second counts branches — how many separate pieces the superlevel set ever breaks into as
# the threshold falls, which is one per ridge crest before they merge; a cone fails it, noise passes it
# with hundreds of unrelated bumps. Dendritic is the conjunction, and each null is here to exclude the
# half the other cannot.
#
# CONTROLS, therefore, are two and each is REQUIRED TO FAIL ITS OWN HALF:
#   - the spec's null: white noise pushed through the identical blur stack, which must fail connectedness
#     (a blur stack alone produces something smooth and plausible, and that is precisely the hypothesis)
#   - a smooth cone, which must fail the branch count (if a featureless dome scores branches, the counter
#     is counting noise and the DLA's score is not evidence)
func _gate_cq_dendritic() -> void:
	print("\n[CQ] the field is dendritic, not a blob and not noise:")
	var mat := _dla(3, 512)
	var dla := _field(mat)
	if dla.is_empty():
		_fail += 1
		print("    !! the material compiled to no field; nothing was measured")
		return
	var n := 512

	# CONTROL 1 — the spec's null, through the SAME blur stack, so the only difference is what was fed in.
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var white := PackedFloat32Array()
	white.resize(n * n)
	for i in range(n * n):
		white[i] = rng.randf()
	var noise: PackedFloat32Array = mat._mass(white, n)

	# CONTROL 2 — a featureless cone over the same footprint.
	var cone := PackedFloat32Array()
	cone.resize(n * n)
	var c := float(n) * 0.5
	for y in range(n):
		for x in range(n):
			var d := sqrt(pow(float(x) - c, 2.0) + pow(float(y) - c, 2.0)) / (float(n) * 0.45)
			cone[y * n + x] = maxf(0.0, 1.0 - d)

	var d_share := _largest_share(dla, n, 0.15)
	var d_branch := _max_components(dla, n)
	var w_share := _largest_share(noise, n, 0.15)
	var w_branch := _max_components(noise, n)
	var c_share := _largest_share(cone, n, 0.15)
	var c_branch := _max_components(cone, n)
	print("    %-22s %8.3f          %6d" % ["DLA", d_share, d_branch])
	print("    %-22s %8.3f          %6d  (CONTROL for the share)" % ["blurred white noise", w_share, w_branch])
	print("    %-22s %8.3f          %6d  (CONTROL for the branches)" % ["smooth cone", c_share, c_branch])

	if d_share < 0.70:
		_fail += 1
		print("    !! the mass does not form one connected network; this is scattered lumps")
	if d_branch < 5:
		_fail += 1
		print("    !! the field never breaks into separate crests; this is a dome, not a ridge network")
	if w_share >= 0.70:
		_fail += 1
		print("    !! blurred noise scores as a network too; the share statistic is not measuring one")
	if c_branch > 2:
		_fail += 1
		print("    !! a featureless cone scores branches; the branch counter is counting noise")
	_completed += 1


# --- CR: both evaluators sample the same bytes ------------------------------------------------------
#
# One implementation, two readers — so the claim is not "the two implementations agree" (there is only
# one) but "the two READERS index the same block the same way". A slot rebased wrong, a row-major
# transpose, an off-by-one in the bilinear weights: all of those live entirely in the sampling and all of
# them would survive the argument that makes parity free.
#
# Baseline first, exactly as HostProfileGate's BQ does it and for the same reason: the Mound's own dome
# term carries a pre-existing C++/GDScript divergence, so what this gate owns is the DLA's ADDED
# contribution to the gap.
#
# MEASURED HERE, AND IT IS WORTH WRITING DOWN: that added gap is a fixed RELATIVE quantity — about
# 1e-5 of the relief amplitude, whatever the amplitude, wherever the brush is placed, and at any field
# resolution. It is not positional round-off (moving the brush from x=180 to x=780 does not change it) and
# it is not the field's gradient (dropping the field from 512 to 128 does not change it). A shipped
# point-evaluated op measured the same way sits at 5e-6, so the DLA is within a factor of two of an op
# nobody has ever complained about. The consequence for the plugin's 1e-4 m tolerance is that the
# tolerance holds up to roughly 10 m of relief on the modifier path and the DLA is not what breaks it,
# which is why this gate asserts BOTH: the absolute figure at an ordinary 8 m amplitude, and the relative
# figure against a reference op at an amplitude where the absolute one would no longer discriminate.
#
# CONTROLS. Three. The spec's — point the oracle at a field grown at a DIFFERENT RESOLUTION, and
# confirm the same comparison reports a large gap, because a parity test between two readers that both
# silently returned zero would pass. Then the fixture must be deforming the ground by far more than the
# tolerance. And the reference op, which is what turns "1e-5 is small" from an opinion into a comparison.
func _gate_cr_parity() -> void:
	print("
[CR] the native op and the GDScript oracle read the same field (tol %.6f m):" % PARITY_TOL)
	var mound = _make_mound("CR", SITE_CR)
	if mound == null:
		return
	var probes := _lattice(SITE_CR)
	var shape := mound.modifiers[0] as Pasture3DNodeRelief

	shape.strength = 0.0
	var dome_only := _parity_gap(mound, probes)
	shape.strength = RELIEF_M
	var full := _parity_gap(mound, probes)
	var added := full - dome_only
	print("    dome only:        worst |native - gdscript| = %.8f m" % dome_only)
	print("    dome + %.0f m DLA:  worst |native - gdscript| = %.8f m" % [RELIEF_M, full])
	print("    the DLA's own contribution to the gap: %+.8f m" % added)
	if added > PARITY_TOL:
		_fail += 1
		print("    !! the two readers disagree about the baked field")

	# The fixture has to be moving the ground by far more than the tolerance, or two nearly flat surfaces
	# are being compared and their agreement is about nothing.
	mound._refresh_owner(mound._layer_owner, false, [])
	var with_dla := _snapshot(probes)
	shape.strength = 0.0
	mound._refresh_owner(mound._layer_owner, false, [])
	var without := _snapshot(probes)
	var relief := _max_diff_arr(with_dla, without)
	shape.strength = RELIEF_M
	print("    CONTROL the DLA moves the ground by %.4f m across the probes" % relief)
	if relief < 1.0:
		_fail += 1
		print("    !! the DLA barely deformed anything; parity here proves nothing")

	# CONTROL — the same measurement on a shipped point-evaluated op, at an amplitude where the absolute
	# tolerance no longer separates anything. Relative, because that is the form the residual takes.
	var loud := RELIEF_M * 4.0
	shape.strength = loud
	var dla_rel := (_parity_gap(mound, probes) - dome_only) / loud
	shape.material = _fractal()
	var ref_full := _parity_gap(mound, probes)
	var ref_rel := (ref_full - dome_only) / loud
	print("    CONTROL at %.0f m: DLA %.9f of amplitude, a shipped FBM %.9f (ratio %.2fx)"
			% [loud, dla_rel, ref_rel, dla_rel / maxf(ref_rel, 1.0e-12)])
	if ref_rel <= 0.0:
		_fail += 1
		print("    !! the reference op shows no residual at all; there is nothing to compare against")
	elif dla_rel > ref_rel * 3.0:
		_fail += 1
		print("    !! the DLA's residual is a different order from a point-evaluated op's; this is not
"
			+ "       shared float32 rounding, it is the sampling")

	# CONTROL — desynchronise the two readers on purpose.
	var field := _dla(5, 512)
	shape.material = field
	shape.strength = RELIEF_M
	mound.force_gdscript_raster = false
	mound._refresh_owner(mound._layer_owner, false, [])
	var native := _snapshot(probes)
	field.resolution = 128
	mound.force_gdscript_raster = true
	mound._refresh_owner(mound._layer_owner, false, [])
	var oracle := _snapshot(probes)
	var desync := _max_diff_arr(native, oracle)
	mound.force_gdscript_raster = false
	print("    CONTROL the oracle reading a 128² field against a 512² native bake: %.4f m apart" % desync)
	if desync <= PARITY_TOL * 100.0:
		_fail += 1
		print("    !! two deliberately different fields still compared equal; CR is not comparing the field")
	_completed += 1


# --- CS: a loop-sized material cannot tile, because there is no tiling mode -------------------------
#
# DLA maps ONCE onto the loop's oriented rectangle, exactly as CRATER does. Under the old `mapping`
# property, TILE produced a grid of identical mountains, and the Plow warned about it; this section held
# both halves of that warning.
#
# The brush modifier stack removed mapping: relief now comes from Pasture3DNodeRelief modifiers, which are
# always evaluated at loop-normalised coordinates, so FIT is the only behaviour and TILE cannot be
# selected. The old body set `plow.mapping` and `plow.source`, neither of which exists — every read came
# back null, the warning never fired, and this reported a defect that had been designed away.
#
# What replaces it is the stronger claim: the thing the warning warned ABOUT is now unreachable. Asserted
# structurally (no `mapping` property to pick TILE with) and behaviourally (a DLA follows its loop rather
# than repeating through world space), because the structural half alone would still pass if the stack
# quietly went back to world-space sampling.
func _gate_cs_tile_warns() -> void:
	print("
[CS] a loop-sized material cannot tile: mapping is gone and relief follows the loop:")
	var plow := Pasture3DPlow.new()
	plow.name = "CSPlow"
	_root.add_child(plow)
	plow.terrain = _terrain
	plow.global_position = SITE_CR + Vector3(400.0, 0.0, 0.0)
	_add_loop(plow)

	var has_mapping := false
	for prop in plow.get_property_list():
		if String(prop["name"]) == "mapping":
			has_mapping = true
	print("    the brush exposes a `mapping` property = %s (want false)" % has_mapping)
	if has_mapping:
		_fail += 1
		print("      !! `mapping` is back, so a loop-sized material can tile again and nothing warns")

	# The behavioural half. A DLA is loop-sized, so moving the BRUSH must carry its massif along; a
	# world-space (tiled) sampling would leave the pattern behind and the stamp would change shape.
	var mr := Pasture3DNodeRelief.new()
	mr.resource_name = "Relief"
	mr.material = _dla(11, 128)
	mr.strength = 20.0
	plow.modifiers = [mr] as Array[Pasture3DNode]
	var probes: Array[Vector3] = []
	for i in range(-2, 3):
		for j in range(-2, 3):
			probes.append(plow.global_position + Vector3(i * 8.0, 0.0, j * 8.0))
	var base := _snapshot(probes)
	plow._refresh_owner(plow._layer_owner, false, [])
	var here := _snapshot(probes)
	var span := 0.0
	for k in range(probes.size()):
		span = maxf(span, absf(here[k] - base[k]))
	print("    CONTROL the DLA moves the probes by %.4f m (must be well above the threshold)" % span)
	if span < 1.0:
		_fail += 1
		print("      !! the DLA stamped nothing here, so the shape claim below proves nothing")
	plow.queue_free()
	_completed += 1


# --- CX: Coverage sizes it, Detail Size styles it ---------------------------------------------------
#
# Reported from the editor: the mountain did not fill its brush, and there was no way to tune the size of
# the detail. Both were true, and the second was the cause of the first — the only lever that moved the
# footprint was the particle count, and moving it changed the texture at the same time. Measured before
# the fix: the massif reached 0.67 of a loop it was allowed 0.96 of, and quadrupling the particles bought
# 0.05.
#
# So the two controls now name the two things, and this gate is what holds them apart:
#
#   CX.1  the massif ARRIVES — the cluster reaches the radius `coverage` allows it, at every setting.
#         Before, the budget decided the radius; now the radius is reached first and the rest of the
#         budget fills in behind it.
#   CX.2  `coverage` RESIZES — the finished field's radius tracks it proportionally.
#   CX.3  `detail_size` RESTYLES WITHOUT RESIZING — across its whole range the massif's SUPPORT radius
#         barely moves while the branch count moves a lot. That is the property the old particle knob
#         did not have.
#
#         MEASURED ON THE SUPPORT, not on the mass. A second editor report found `detail_size` dead over
#         half its range, because the blur was capped at a fixed share of the radius; removing that cap
#         means the blur now takes what it asks for and the CLUSTER takes the rest. So a coarse setting
#         genuinely does pull the ridge structure inward — r98 of the mass moves 34 % across the range —
#         while the massif's outer radius does not move at all. That IS the trade, it is what "coarser"
#         physically means, and the gate reports both numbers rather than gating the one that flatters.
#
# CONTROL. The border ring must be EXACTLY zero at every one of these settings. That invariant is the
# reason the geometry is derived from one property instead of set by two constants, and it is the thing
# that breaks first if the derivation drifts: a massif clipped by the field's edge puts a step at the loop
# boundary on every FIT-mapped brush. Plus the usual "measured nothing" guard — a flat field would sail
# through CX.3 by never changing size.
func _gate_cx_size_and_detail() -> void:
	print("\n[CX] Coverage sizes the massif, Detail Size styles it:")
	var n := 256
	print("    %-22s %8s %8s %8s %9s %9s"
			% ["", "reached", "support", "r98", "branches", "border"])
	var by_cover := {}
	var by_detail := {}
	var worst_border := 0.0
	var worst_arrival := 1.0
	var flat := false
	for e in [[0.5, 0.12], [0.95, 0.12], [1.0, 0.12], [0.95, 0.03], [0.95, 0.50]]:
		var m := _dla(3, n)
		m.coverage = e[0]
		m.detail_size = e[1]
		var f := _field(m)
		if f.is_empty():
			_fail += 1
			print("    !! compiled to no field; nothing was measured")
			return
		if _span(f) < 0.9:
			flat = true
		# The envelope is a Vector2 since the material learned about non-square loops; these fixtures are
		# all square, and the gate asserts that rather than assuming it.
		var env: Vector2 = m._grow_extent(n)
		if not is_equal_approx(env.x, env.y):
			_fail += 1
			print("    !! a square fixture grew a non-square envelope %s; CX is measuring the wrong thing" % env)
		var arrival: float = _reach(m, n) / maxf(env.x, 1.0)
		var r98 := _r_mass(f, n, 0.98) / (0.5 * float(n))
		var support := _support(f, n) / (0.5 * float(n))
		var branches := _max_components(f, n)
		var border := _border(f, n, m.coverage)
		print("    coverage %.2f detail %.2f %7.0f%% %8.3f %8.3f %9d %9.8f"
				% [e[0], e[1], 100.0 * arrival, support, r98, branches, border])
		worst_border = maxf(worst_border, border)
		worst_arrival = minf(worst_arrival, arrival)
		if is_equal_approx(e[1], 0.12):
			by_cover[e[0]] = support
		if is_equal_approx(e[0], 0.95):
			by_detail[e[1]] = [support, branches, r98]

	print("    CX.1 worst arrival at its allowed radius: %.0f%%" % [100.0 * worst_arrival])
	if worst_arrival < 0.90:
		_fail += 1
		print("    !! the cluster stops short of the radius Coverage allows; the budget is deciding the size")

	# CX.2 -- r98 must track coverage. Compared as a RATIO against the coverage ratio, so the criterion is
	# "it scales" rather than "it hit a number somebody wrote down".
	var small: float = by_cover[0.5]
	var big: float = by_cover[1.0]
	var got := big / maxf(small, 0.0001)
	var want := 1.0 / 0.5
	print("    CX.2 coverage 0.50 -> 1.00 grows the field %.2fx (coverage itself grows %.2fx)" % [got, want])
	if got < want * 0.7 or got > want * 1.3:
		_fail += 1
		print("    !! the field's size does not track Coverage; it is not the size control it claims to be")

	# CX.3 -- detail must NOT resize.
	var fine: Array = by_detail[0.03]
	var coarse: Array = by_detail[0.50]
	var drift: float = absf(float(coarse[0]) - float(fine[0])) / maxf(float(fine[0]), 0.0001)
	var style: float = float(fine[1]) / maxf(float(coarse[1]), 1.0)
	var mass_drift: float = absf(float(coarse[2]) - float(fine[2])) / maxf(float(fine[2]), 0.0001)
	print("    CX.3 detail 0.03 -> 0.50 moves the SUPPORT %.1f%% while the branch count changes %.1fx"
			% [100.0 * drift, style])
	print("         (and pulls r98 of the MASS in by %.0f%%, which is what a coarser ridge means)"
			% [100.0 * mass_drift])
	if drift > 0.05:
		_fail += 1
		print("    !! Detail Size is resizing the mountain; Coverage is not the size control it claims")
	if style < 1.5:
		_fail += 1
		print("    !! Detail Size barely changed the branching, so CX.3's other half is about nothing")

	# CONTROL
	print("    CONTROL worst value outside the radius Coverage promises, over all five: %.9f (limit %.9f)"
			% [worst_border, FIELD_ZERO])
	if worst_border > FIELD_ZERO:
		_fail += 1
		print("    !! the massif reaches the field's edge; a FIT-mapped brush would step at its loop")
	if flat:
		_fail += 1
		print("    !! one of these fields is flat; a flat field never changes size and passes CX.3 for free")
	_completed += 1


# --- CY: a seeded cluster grows along the ridges it was handed --------------------------------------
#
# Unseeded, DLA invents a trunk wherever its RNG puts one. The point of seeding is that a brush which
# already HAS ridges — a roughed-in landform, or the drainage an erosion step just carved — gets its
# branching grown onto those instead of somewhere else. §9.3 claims DLA and erosion "agree structurally";
# unseeded that is a claim about statistics, and seeded it is a claim about the same lines.
#
# The fixture is a five-armed star ridge, because a synthetic pattern is the only kind whose answer is
# known in advance. The statistic is the correlation between the finished field and the seed surface.
#
# CONTROLS, two, and the second is the one that matters:
#   - UNSEEDED against the same star. It does not score zero and must not be expected to: both are
#     centre-heavy, so a blob correlates with a star at 0.51 for free. What the gate asserts is the
#     MARGIN over that, which is the only part seeding is responsible for.
#   - A FLAT seed surface, which has no ridges in it. It must land on EXACTLY the unseeded number —
#     bitwise, not approximately. That is what proves the fallback is real and that switching seeding on
#     changes nothing by itself; a gate without it would pass on an implementation that perturbed the
#     RNG and called the perturbation an effect.
func _gate_cy_seeded_growth() -> void:
	print("\n[CY] a seeded cluster grows along the ridges it was handed:")
	var star := _star_ridges()
	var flat := PackedFloat32Array()
	flat.resize(SEED_G * SEED_G)
	flat.fill(12.0)

	var plain := _field(_seeded(4, null))
	var grown := _field(_seeded(4, star))
	var onflat := _field(_seeded(4, flat))
	if plain.is_empty() or grown.is_empty() or onflat.is_empty():
		_fail += 1
		print("    !! one of the arms compiled to no field; nothing was measured")
		return

	var base := _agreement(plain, star)
	var got := _agreement(grown, star)
	var ctrl := _agreement(onflat, star)
	print("    seeded on the star ridges : %.3f" % got)
	print("    CONTROL unseeded          : %.3f  (a blob correlates with a star for free)" % base)
	print("    CONTROL seeded on a FLAT surface: %.3f" % ctrl)
	print("    margin seeding is responsible for: %+.3f" % (got - base))
	if got - base < 0.05:
		_fail += 1
		print("    !! the seed is not steering the growth; it is being buried by it")
	if absf(ctrl - base) > 0.0001:
		_fail += 1
		print("    !! a surface with no ridges in it still changed the result, so CY is reading the RNG")

	# Determinism survives seeding — CP's claim, restated for the input CP does not cover.
	var a := _field(_seeded(4, star))
	print("    two instances, one seed, one surface: %s"
			% ["BITWISE IDENTICAL" if _identical(a, grown) else "DIFFER"])
	if not _identical(a, grown):
		_fail += 1
		print("    !! seeding made the growth non-deterministic")
	_completed += 1


# --- CZ: the captured surface is the stack ABOVE it -------------------------------------------------
#
# The seed surface arrives from a real bake, captured at the material's own position in the modifier
# list. Everything rests on WHERE that position is: a material seeded on the finished brush would read
# its own output and drift a little further every bake, which is the failure the spec keeps designing
# against everywhere else (a selector's Below Layer source, the host profile's "cannot feed itself").
#
# The claim is testable without inspecting any plumbing: bake TWICE. On the first the material has never
# seen a surface and stamps nothing; on the second it has one and stamps. If the capture included the
# material's own contribution the two captures would differ — so asserting they are BITWISE IDENTICAL is
# exactly the no-drift claim, and it is also the convergence claim, because an unchanged hash is what
# stops the brush scheduling a third bake.
#
# CONTROL. Seeding OFF: nothing is captured at all and the material stamps on the FIRST bake. Without it
# a capture that ran unconditionally would pass every assertion above while costing every stack a grid
# conversion it never asked for.
func _gate_cz_capture_excludes_itself() -> void:
	print("\n[CZ] the captured surface is the stack above, not the finished brush:")
	var mound = _make_seeded_mound("CZ", SITE_CZ, true)
	if mound == null:
		return
	var probes := _lattice(SITE_CZ)
	var grow := mound.modifiers[1] as Pasture3DNodeRelief
	var dla: Pasture3DReliefDLA = grow.material

	# The reference: the same brush with the seeded material switched OFF, which is what "it stamped
	# nothing" has to be measured against. Measured on the ground rather than by asking the material,
	# because by the time the gate can ask, the bake has already handed it a surface.
	grow.enabled = false
	mound._refresh_owner(mound._layer_owner, false, [])
	var rough_only := _snapshot(probes)
	grow.enabled = true

	mound._refresh_owner(mound._layer_owner, false, [])
	var after_1 := _snapshot(probes)
	var cap_1: PackedFloat32Array = dla._seed.get("surface", PackedFloat32Array())

	mound._refresh_owner(mound._layer_owner, false, [])
	var after_2 := _snapshot(probes)
	var cap_2: PackedFloat32Array = dla._seed.get("surface", PackedFloat32Array())

	print("    bake 1 captured %d cells; it differs from the rough-only brush by %.4f m"
			% [cap_1.size(), _max_diff_arr(after_1, rough_only)])
	print("    bake 2 differs from bake 1 by %.4f m" % _max_diff_arr(after_2, after_1))
	if cap_1.is_empty():
		_fail += 1
		print("    !! nothing was captured; the material can never be seeded")
		_completed += 1
		return
	if _max_diff_arr(after_1, rough_only) > 0.001:
		_fail += 1
		print("    !! it stamped a mountain before it had a surface, which the next bake would replace")
	if _max_diff_arr(after_2, after_1) < 0.5:
		_fail += 1
		print("    !! the second bake changed nothing; the seeded material contributed no relief")

	# THE NO-DRIFT CLAIM. The second bake stamps a mountain the first one did not, so if the capture
	# included this material's own contribution the two captures would differ. They must not.
	print("    the two captures are %s"
			% ["BITWISE IDENTICAL" if _identical(cap_1, cap_2) else "DIFFERENT"])
	if not _identical(cap_1, cap_2):
		_fail += 1
		print("    !! the capture moved once the material started stamping, so it is reading its own\n"
			+ "       output " + "\u2014" + " that drifts, and it never converges")

	# CONTROL
	var off = _make_seeded_mound("CZoff", SITE_CZ_OFF, false)
	if off == null:
		return
	var off_dla: Pasture3DReliefDLA = (off.modifiers[1] as Pasture3DNodeRelief).material
	var off_probes := _lattice(SITE_CZ_OFF)
	(off.modifiers[1] as Pasture3DNodeRelief).enabled = false
	off._refresh_owner(off._layer_owner, false, [])
	var off_rough := _snapshot(off_probes)
	(off.modifiers[1] as Pasture3DNodeRelief).enabled = true
	off._refresh_owner(off._layer_owner, false, [])
	var off_first := _snapshot(off_probes)
	print("    CONTROL seeding off: captured %d cells, and its FIRST bake already moves %.4f m"
			% [off_dla._seed.get("surface", PackedFloat32Array()).size(),
			_max_diff_arr(off_first, off_rough)])
	if not off_dla._seed.is_empty():
		_fail += 1
		print("    !! a stack that never asked for a surface was charged for one")
	if _max_diff_arr(off_first, off_rough) < 0.5:
		_fail += 1
		print("    !! an unseeded material stamped nothing either, so CZ's first-bake test is vacuous")
	_completed += 1


# --- helpers ----------------------------------------------------------------------------------------


## A shipped, point-evaluated op at the same amplitude: CR's reference for what the modifier-relief
## path's float32 residual looks like when no baked field is involved at all.
## How far the cluster itself got, in cells. Grown a second time with the material's own seed, which is
## exact: the growth is a pure function of it, which is what gate CP establishes.
func _reach(p_mat: Pasture3DReliefDLA, n: int) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = p_mat.seed
	var cl: Array = p_mat._grow(rng, maxi(n >> (p_mat.hierarchy_levels - 1), 16), n)
	var xs: PackedFloat32Array = cl[0]
	var ys: PackedFloat32Array = cl[1]
	var c := float(n) * 0.5
	var r := 0.0
	for i in range(xs.size()):
		r = maxf(r, sqrt(pow(xs[i] - c, 2.0) + pow(ys[i] - c, 2.0)))
	return r


## Radius, in cells, of the outermost cell the field is non-zero at: where the mountain actually ENDS,
## which is what `coverage` promises and what `detail_size` must not move.
func _support(g: PackedFloat32Array, n: int) -> float:
	var c := float(n) * 0.5
	var r := 0.0
	for y in range(n):
		for x in range(n):
			if g[y * n + x] > FIELD_ZERO:
				r = maxf(r, sqrt(pow(float(x) - c, 2.0) + pow(float(y) - c, 2.0)))
	return r


## Radius, in cells, inside which `q` of the field's mass sits. Used instead of a threshold because the
## fringe of a blurred dendrite is faint and a threshold reads whatever level you picked.
func _r_mass(g: PackedFloat32Array, n: int, q: float) -> float:
	var c := float(n) * 0.5
	var bins := PackedFloat32Array()
	bins.resize(n)
	var total := 0.0
	for y in range(n):
		for x in range(n):
			var v := g[y * n + x]
			if v <= 0.0:
				continue
			var d := int(sqrt(pow(float(x) - c, 2.0) + pow(float(y) - c, 2.0)))
			if d < n:
				bins[d] += v
				total += v
	var acc := 0.0
	for d in range(n):
		acc += bins[d]
		if acc >= total * q:
			return float(d)
	return float(n)


## The largest value anywhere OUTSIDE the radius `coverage` promises, with four cells of slack. Must be
## below FIELD_ZERO.
##
## Four and not two because the limit is enforced in INTEGER cells at three separate places — the blur
## budget truncates, the cell walk rounds, and the growth limit is compared against a rounded radius —
## so material can legitimately land a cell or so past the arithmetic boundary. At two cells this read
## 1e-7 at `coverage` 1.0, which is a rounding tail and not a massif escaping its loop; the fix is to
## measure where the invariant actually holds rather than to soften it into a tolerance.
##
## Measured against `coverage` and not against a fixed ring, because `coverage` is now what the invariant
## is stated in: the cluster and the blur together spend exactly that radius and nothing beyond it. A
## fixed 2 % ring tested a promise the material no longer makes — at `coverage` 1.0 the massif is
## SUPPOSED to reach the loop edge.
func _border(g: PackedFloat32Array, n: int, p_coverage: float) -> float:
	var c := float(n) * 0.5
	var limit := p_coverage * c + 4.0
	var w := 0.0
	for y in range(n):
		for x in range(n):
			if sqrt(pow(float(x) - c, 2.0) + pow(float(y) - c, 2.0)) > limit:
				w = maxf(w, g[y * n + x])
	return w


func _fractal() -> Pasture3DReliefFractal:
	var f := Pasture3DReliefFractal.new()
	f.style = Pasture3DReliefFractal.Style.CRAGGY
	f.feature_size = 20.0
	f.seed = 5
	return f


## A DLA at CY's working size, optionally handed a seed surface. `null` leaves seeding off entirely,
## which is the unseeded control rather than "seeding on with nothing supplied".
func _seeded(p_seed: int, p_surface) -> Pasture3DReliefDLA:
	var m := _dla(p_seed, 256)
	if p_surface == null:
		return m
	m.ridge_seeding = true
	m.set_seed_surface(_seed_dict(p_surface))
	return m


## The surface dictionary the host hands over, in one place. DB compares a stacked material's field
## against a bare one BITWISE, so the two arms must be handed the same bytes AND the same frame — a
## second literal here would let that comparison drift into being a comparison of two frames.
func _seed_dict(p_surface: PackedFloat32Array) -> Dictionary:
	return {"surface": p_surface, "gw": SEED_G, "gh": SEED_G,
			"frame": [0.0, 0.0, 1.0, 0.0, 64.0, 64.0, -64.0, -64.0, 1.0]}


## A five-armed star ridge: a synthetic stand-in for "the ridges the brush already has", and the only
## kind of fixture whose right answer is known before the material runs.
func _star_ridges() -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(SEED_G * SEED_G)
	var c := float(SEED_G - 1) * 0.5
	for y in range(SEED_G):
		for x in range(SEED_G):
			var dx := float(x) - c
			var dy := float(y) - c
			var r := sqrt(dx * dx + dy * dy) / c
			var arm := pow(maxf(cos(atan2(dy, dx) * 5.0), 0.0), 6.0)
			g[y * SEED_G + x] = 40.0 * arm * maxf(0.0, 1.0 - r) + 8.0 * maxf(0.0, 1.0 - r * 1.4)
	return g


## Correlation between a finished field and the surface it was seeded from, both read on the field's own
## square. Nearest-neighbour on purpose: an interpolated read would blur the star's arms and flatter the
## agreement for a reason that has nothing to do with the growth.
func _agreement(p_field: PackedFloat32Array, p_seed: PackedFloat32Array) -> float:
	var n := 256
	var a := PackedFloat32Array()
	var b := PackedFloat32Array()
	for y in range(n):
		var sy := int(float(y) / float(n - 1) * float(SEED_G - 1))
		for x in range(n):
			var sx := int(float(x) / float(n - 1) * float(SEED_G - 1))
			a.append(p_field[y * n + x])
			b.append(p_seed[sy * SEED_G + sx])
	return _pearson(a, b)


func _pearson(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var n := float(a.size())
	var ma := 0.0
	var mb := 0.0
	for i in range(a.size()):
		ma += a[i]
		mb += b[i]
	ma /= n
	mb /= n
	var num := 0.0
	var da := 0.0
	var db := 0.0
	for i in range(a.size()):
		var u := a[i] - ma
		var v := b[i] - mb
		num += u * v
		da += u * u
		db += v * v
	return num / maxf(sqrt(da * db), 1.0e-9)


## A Mound running `fractal -> DLA`, which is the stack ridge seeding exists for: the fractal puts ridges
## on the brush and the DLA grows its branching onto them.
func _make_seeded_mound(p_name: String, p_at: Vector3, p_seeding: bool):
	var mound = _make_mound(p_name, p_at)
	if mound == null:
		return null
	var rough := Pasture3DNodeRelief.new()
	rough.label = "Rough"
	rough.material = _fractal()
	rough.strength = RELIEF_M
	var dla := _dla(5, 256)
	dla.ridge_seeding = p_seeding
	var grow := Pasture3DNodeRelief.new()
	grow.label = "DLA"
	grow.material = dla
	grow.strength = RELIEF_M
	var stack: Array[Pasture3DNode] = [rough, grow]
	mound.modifiers = stack
	return mound


func _dla(p_seed: int, p_res: int) -> Pasture3DReliefDLA:
	var m := Pasture3DReliefDLA.new()
	m.resolution = p_res
	m.seed = p_seed
	# LIVE, because every criterion below MEASURES THE GROWTH. FROZEN is the shipped default and it holds
	# the field it has across exactly the changes these fixtures make — a host frame, a seed surface, a
	# slider — so a gate that left it there would read "nothing moved" for the right reason and prove
	# nothing. The same rule BrushErosionGate follows for a frozen solve.
	m.evaluation = Pasture3DReliefDLA.Evaluation.LIVE
	return m


## The material's baked field, straight out of the compiled program — the same bytes both evaluators
## read, rather than a second copy grown for the gate.
func _field(p_mat: Pasture3DReliefMaterial) -> PackedFloat32Array:
	return p_mat.compile()[4]


## The growth pipeline driven by a CLOCK-seeded RNG. CP's control: same code, different seeding.
func _clock_grown(p_res: int) -> PackedFloat32Array:
	var m := _dla(0, p_res)
	var rng := RandomNumberGenerator.new()
	rng.seed = Time.get_ticks_usec()
	var n0: int = maxi(p_res >> (m.hierarchy_levels - 1), 16)
	return m._mass(m._rasterise(m._grow(rng, n0, p_res), p_res), p_res)


## Bitwise-equal, with NaN counted as equal to NaN. A captured brush surface is NaN wherever the brush
## contributes nothing, and `NAN != NAN` is true — so the plain comparison reports two copies of the
## same grid as different, which is a gate that fails on a working implementation.
func _identical(a: PackedFloat32Array, b: PackedFloat32Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if a[i] == b[i]:
			continue
		if is_finite(a[i]) or is_finite(b[i]):
			return false
	return true


func _max_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var worst := 0.0
	for i in range(mini(a.size(), b.size())):
		worst = maxf(worst, absf(a[i] - b[i]))
	return worst


func _span(g: PackedFloat32Array) -> float:
	var lo := INF
	var hi := -INF
	for v in g:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return hi - lo


func _frac_above(g: PackedFloat32Array, t: float) -> float:
	var c := 0
	for v in g:
		if v > t:
			c += 1
	return float(c) / maxf(float(g.size()), 1.0)


## The value the top `q` fraction of cells lies above. Thresholding by QUANTILE rather than by height is
## what lets two fields be compared: both superlevel sets then have the same area by construction, so a
## difference in how many pieces they break into is a difference in shape and nothing else.
func _quantile(g: PackedFloat32Array, q: float) -> float:
	var v := g.duplicate()
	v.sort()
	return v[clampi(int(float(v.size()) * (1.0 - q)), 0, v.size() - 1)]


## Sizes of the 4-connected components of {cell : g > t}, in discovery order.
func _components(g: PackedFloat32Array, n: int, t: float) -> PackedInt32Array:
	var lab := PackedInt32Array()
	lab.resize(n * n)
	lab.fill(-1)
	var sizes := PackedInt32Array()
	var stack := PackedInt32Array()
	for s in range(n * n):
		if g[s] <= t or lab[s] >= 0:
			continue
		var id := sizes.size()
		var count := 0
		stack.clear()
		stack.append(s)
		lab[s] = id
		while not stack.is_empty():
			var i := stack[stack.size() - 1]
			stack.remove_at(stack.size() - 1)
			count += 1
			var x := i % n
			var y := i / n
			for d in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
				var nx: int = x + d[0]
				var ny: int = y + d[1]
				if nx < 0 or ny < 0 or nx >= n or ny >= n:
					continue
				var j := ny * n + nx
				if lab[j] < 0 and g[j] > t:
					lab[j] = id
					stack.append(j)
		sizes.append(count)
	return sizes


## The largest component's share of a fixed-area superlevel set: 1 when the high ground is one connected
## network, small when it is scattered lumps.
func _largest_share(g: PackedFloat32Array, n: int, q: float) -> float:
	var sizes := _components(g, n, _quantile(g, q))
	var tot := 0
	var big := 0
	for s in sizes:
		tot += s
		big = maxi(big, s)
	return float(big) / maxf(float(tot), 1.0)


## The most pieces the superlevel set ever breaks into as the threshold sweeps down from the summit. On a
## branching massif each crest surfaces as its own component before the flanks join them up; on a dome
## there is one component at every threshold, forever.
func _max_components(g: PackedFloat32Array, n: int) -> int:
	var best := 0
	for k in range(1, 41):
		best = maxi(best, _components(g, n, _quantile(g, float(k) * 0.005)).size())
	return best


func _make_mound(p_name: String, p_at: Vector3):
	if not is_finite(_height(p_at)):
		_fail += 1
		print("    !! no terrain at %s; the fixture is outside demo/data" % p_at)
		return null
	var mound := Pasture3DMound.new()
	mound.name = p_name
	_root.add_child(mound)
	mound.terrain = _terrain
	mound.global_position = p_at
	mound.height = 40.0
	mound.blend_mode = Pasture3DMound.BlendMode.ADD
	_add_loop(mound)
	mound._set_layer_owner(Pasture3DTerrainBrush.BRUSH_OWNER_PREFIX + p_name)
	var shape := Pasture3DNodeRelief.new()
	shape.label = "DLA"
	shape.material = _dla(5, 512)
	shape.strength = RELIEF_M
	var stack: Array[Pasture3DNode] = [shape]
	mound.modifiers = stack
	return mound


func _add_loop(p_brush) -> void:
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	c.add_point(Vector3(-HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, HALF))
	c.add_point(Vector3(-HALF, 0.0, HALF))
	c.closed = true
	path.curve = c
	p_brush.add_child(path)


## Worst |native - oracle| over the probes, baking the same brush down both paths.
func _parity_gap(p_mound, p_probes: Array[Vector3]) -> float:
	p_mound.force_gdscript_raster = false
	p_mound._refresh_owner(p_mound._layer_owner, false, [])
	var native := _snapshot(p_probes)
	p_mound.force_gdscript_raster = true
	p_mound._refresh_owner(p_mound._layer_owner, false, [])
	var oracle := _snapshot(p_probes)
	p_mound.force_gdscript_raster = false
	p_mound._refresh_owner(p_mound._layer_owner, false, [])
	return _max_diff_arr(native, oracle)


## Does this brush raise the loop-sized-material warning? Matched on the sentence's own wording rather
## than on the predicate, so the gate reads what an artist reads.
func _warned(p_brush) -> bool:
	for w in p_brush._get_configuration_warnings():
		if w.contains("sized by the loop"):
			return true
	return false


# --- DA: the ridges are the same size in both directions --------------------------------------------
#
# The field is stretched ONCE over the loop's oriented rectangle -- nu,nv are +/-1 at its edges -- so a
# field grown square and handed to a 3:1 loop arrives with every ridge width, branch spacing and blur
# radius multiplied by 3 along one axis. That is invisible on the square test loops this material was
# built on and is the first thing anyone sees on a hand-drawn one.
#
# MEASURED AS RIDGE DENSITY: local maxima per metre travelled across the massif, scanned along each of the
# loop's own axes, in world metres and not in cells. It is self-normalising -- maxima over the metres
# actually spent above the noise floor -- so a massif being LONGER one way does not move it. Only the
# ridges being WIDER one way does, which is the defect.
#
# CONTROL, and it is the whole gate: the same material with the frame withheld. That is not a mock-up of
# the old behaviour, it IS the old behaviour, because withholding the frame is what every host did before
# this material was given somewhere to put it. It must fail the isotropy band, and at about 1/aspect.
#
# SECOND CONTROL, against the opposite error: on a SQUARE loop, told and not told must produce bitwise
# identical fields. Without it the criterion would also pass an implementation that simply made every
# field different, and it is what pins "the crop is a no-op when there is nothing to crop".
func _gate_da_isotropic() -> void:
	print("\n[DA] the ridges are the same size in both directions:")
	var told := _dla(7, 256)
	told.set_host_frame(DA_EX, DA_EZ)
	var raw := _dla(7, 256)
	var meta: PackedInt32Array = told.compile()[5]
	if meta.size() < 3 or _field(told).is_empty():
		_fail += 1
		print("    !! the material compiled to no field at all; nothing was measured")
		return

	# 1. the grid follows the loop, and its cells stay square IN METRES -- which is the mechanism, and the
	#    thing a ratio of ridge counts could otherwise be talked into agreeing with by accident.
	var mx := DA_EX * 2.0 / float(meta[1] - 1)
	var mz := DA_EZ * 2.0 / float(meta[2] - 1)
	print("    field %d x %d cells over a %.0f x %.0f m loop -> %.3f x %.3f m per cell"
			% [meta[1], meta[2], DA_EX * 2.0, DA_EZ * 2.0, mx, mz])
	if absf(mx / mz - 1.0) > 0.05:
		_fail += 1
		print("    !! the field's cells are not square in world metres, so its ridges cannot be either")

	var a := _ridge_scan(told, DA_EX, DA_EZ)
	var b := _ridge_scan(raw, DA_EX, DA_EZ)
	if a[0] <= 0.0 or a[1] <= 0.0 or b[0] <= 0.0 or b[1] <= 0.0:
		_fail += 1
		print("    !! a scan found no ridges at all; the ratio below is about nothing")
		return
	var ratio: float = a[0] / a[1]
	var ctl: float = b[0] / b[1]
	print("    ridges per metre: %.4f along u, %.4f along v -> ratio %.3f" % [a[0], a[1], ratio])
	if ratio < DA_BAND_LO or ratio > DA_BAND_HI:
		_fail += 1
		print("    !! the ridges are %.1fx the size one way; the field is being stretched onto the loop"
				% (1.0 / ratio if ratio < 1.0 else ratio))

	# 2. and it still fills its loop. Un-squashing by INSCRIBING a round massif would pass everything
	#    above and leave the ends of the loop bare, which is the other way to get this wrong.
	print("    massif reaches %.2f of the half-extent along u, %.2f along v" % [a[2], a[3]])
	if minf(a[2], a[3]) < 0.5:
		_fail += 1
		print("    !! the massif does not reach its loop on one axis; it has been inscribed, not fitted")

	# CONTROL
	print("    CONTROL the same material, frame withheld (the old behaviour): ratio %.3f" % ctl)
	if ctl >= DA_BAND_LO:
		_fail += 1
		print("    !! the control passes the isotropy band, so the band is not measuring the stretch")

	# 3. THROUGH A STACK. A relief stack memoises its own spliced program, so a layer that regrows its
	#    field underneath it is invisible unless the layer says so and the stack listens -- and the first
	#    version of this change did neither, which made a stacked DLA silently keep the square field it
	#    was compiled with. Compared against the bare material rather than against a number, so the claim
	#    is "a layer is told what a material is told" and not "84 is the right answer".
	var inner := _dla(7, 256)
	var stack := Pasture3DReliefStack.new()
	stack.layers = [inner] as Array[Pasture3DReliefMaterial]
	# DUPLICATED, not just assigned: compile() hands back its own arrays, and the second compile clears
	# and refills them in place. Without the copy this reads the same array twice and the "it changed"
	# control below reports no change on a working implementation -- which is exactly what it did.
	var before: PackedInt32Array = stack.compile()[5].duplicate()
	stack.set_host_frame(DA_EX, DA_EZ)
	var after: PackedInt32Array = stack.compile()[5].duplicate()
	var bare := "%dx%d" % [meta[1], meta[2]]
	var was := "%dx%d" % [before[1], before[2]] if before.size() >= 3 else "none"
	var now := "%dx%d" % [after[1], after[2]] if after.size() >= 3 else "none"
	print("    in a Relief Stack: %s before the frame, %s after (the bare material: %s)"
			% [was, now, bare])
	if now != bare:
		_fail += 1
		print("    !! a stacked layer did not get the loop's shape; the stack is serving a stale splice")
	if was == now:
		_fail += 1
		print("    !! the stack's field never changed, so the comparison above proves nothing")

	# SECOND CONTROL
	var sq_told := _dla(7, 256)
	sq_told.set_host_frame(DA_EX, DA_EX)
	var sq_raw := _dla(7, 256)
	var same := _identical(_field(sq_told), _field(sq_raw))
	print("    CONTROL a SQUARE loop, told vs withheld: %s" % ["bitwise identical" if same else "DIFFER"])
	if not same:
		_fail += 1
		print("    !! a square loop regrows a different mountain; the crop is not a no-op where it should be")
	_completed += 1


## Local maxima per metre along u and along v, plus how far the massif reaches on each axis as a fraction
## of the half-extent. Sampled through the material's own oracle at the SAME loop-normalised coordinates
## the brush feeds it, so the scan sees exactly what the ground will.
func _ridge_scan(p_mat: Pasture3DReliefDLA, p_ex: float, p_ez: float) -> Array:
	var nx := int(2.0 * p_ex / DA_STEP) + 1
	var nz := int(2.0 * p_ez / DA_STEP) + 1
	var h := PackedFloat32Array()
	h.resize(nx * nz)
	var peak := 0.0
	for iz in range(nz):
		var lz := -p_ez + float(iz) * DA_STEP
		for ix in range(nx):
			var lx := -p_ex + float(ix) * DA_STEP
			var v: float = p_mat.eval(lx, lz, lx / p_ex, lz / p_ez, 1.0 / p_ex, 1.0 / p_ez)
			h[iz * nx + ix] = v
			peak = maxf(peak, v)
	if peak <= 0.0:
		return [0.0, 0.0, 0.0, 0.0]
	var cut := peak * DA_FLOOR
	var ru := 0.0
	var rv := 0.0
	for iz in range(nz):
		for ix in range(nx):
			if h[iz * nx + ix] <= cut:
				continue
			ru = maxf(ru, absf(-p_ex + float(ix) * DA_STEP) / p_ex)
			rv = maxf(rv, absf(-p_ez + float(iz) * DA_STEP) / p_ez)
	return [_ridge_density(h, nx, nz, cut, true), _ridge_density(h, nx, nz, cut, false), ru, rv]


## Maxima per metre along rows (u) or columns (v), with the identical rule both ways so the two numbers
## are comparable. Divided by the metres spent ABOVE the floor rather than by the loop's own width, so an
## elongated massif does not read as a stretched one.
func _ridge_density(h: PackedFloat32Array, nx: int, nz: int, cut: float, p_rows: bool) -> float:
	var n_outer := nz if p_rows else nx
	var n_inner := nx if p_rows else nz
	var maxima := 0
	var live := 0
	for o in range(n_outer):
		for i in range(1, n_inner - 1):
			var a: float = h[o * nx + (i - 1)] if p_rows else h[(i - 1) * nx + o]
			var b: float = h[o * nx + i] if p_rows else h[i * nx + o]
			var c: float = h[o * nx + (i + 1)] if p_rows else h[(i + 1) * nx + o]
			if b <= cut:
				continue
			live += 1
			if b > a and b >= c:
				maxima += 1
	return float(maxima) / maxf(float(live) * DA_STEP, 0.001)


func _lattice(p_centre: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var step := _vs * 3.0
	var reach := HALF - _vs * 3.0
	var x := -reach
	while x <= reach:
		var z := -reach
		while z <= reach:
			out.append(Vector3(snappedf(p_centre.x + x, _vs), 0.0, snappedf(p_centre.z + z, _vs)))
			z += step
		x += step
	return out


func _snapshot(p_points: Array[Vector3]) -> Array[float]:
	var out: Array[float] = []
	for p in p_points:
		out.append(_height(p))
	return out


func _max_diff_arr(a: Array[float], b: Array[float]) -> float:
	var worst := 0.0
	for i in range(mini(a.size(), b.size())):
		if is_finite(a[i]) and is_finite(b[i]):
			worst = maxf(worst, absf(a[i] - b[i]))
	return worst


func _height(p_at: Vector3) -> float:
	return _terrain.data.get_height(Vector3(p_at.x, 0.0, p_at.z))


# --- DB: ridge seeding survives being wrapped in a stack ---------------------------------------------
#
# CY and CZ both put the DLA on a Relief modifier DIRECTLY, and every claim they make held. Wrap the same
# material in a Pasture3DReliefStack and none of it happened: the host asked `has_method`, a stack
# implements no seeding of its own, so it answered no, nothing was captured, and the material sat waiting
# for a surface that was never coming. It compiles to NOTHING while it waits, so the symptom is a DLA
# that stamps no mountain at all, forever — and it fails CLOSED, which is why nothing caught it.
#
# The gate is in two halves because the bug has two halves.
#
# THE FORWARDING, measured on the compiled bytes. A DLA alone and the same DLA as a stack's only layer,
# handed the same surface, must produce the SAME FIELD. Bitwise, because there is no reason for a splice
# to change a single byte of it and a tolerance here would hide exactly the kind of resampling this
# material spent §9.8 removing.
#
# THE ROUTE, measured on the ground through a real bake, because "the stack answers the question" and
# "the host asks the stack" are different claims and only the second one is what an artist sees. Bake
# twice, exactly as CZ does: nothing on the first, a mountain on the second. Under the bug the second
# bake stamps 0.0000 m as well.
#
# CONTROL, and it is the one that matters: the same stack handed a FLAT surface must produce a DIFFERENT
# field. Two materials that both ignore what they are handed also agree bitwise, so without this the
# forwarding half passes just as well on the broken code path that started this — where both arms would
# be empty and `_identical` on two empty arrays is true.
#
# SECOND CONTROL, CZ's, restated for the composite: a stack with no seeded layer in it must answer NO, or
# every stack in the project pays for a grid conversion it never asked for.
func _gate_db_stacked_seeding() -> void:
	print("\n[DB] ridge seeding survives being wrapped in a stack:")
	var star := _star_ridges()
	var flat := PackedFloat32Array()
	flat.resize(SEED_G * SEED_G)
	flat.fill(12.0)

	var bare := _field(_seeded(4, star))
	if bare.is_empty():
		_fail += 1
		print("    !! the BARE arm compiled to no field; DB has no reference and measured nothing")
		return

	var stacked := _stacked_dla(4, star)
	var wants: bool = stacked.wants_seed_surface()
	var field := _field(stacked)
	print("    stack.wants_seed_surface() = %s, and it compiled %d field cells against the bare %d"
			% [wants, field.size(), bare.size()])
	if not wants:
		_fail += 1
		print("    !! the stack does not pass the question on, so the host never captures a surface")
	if field.is_empty():
		_fail += 1
		print("    !! the stacked material is still waiting for a surface, so it stamps nothing at all")
	elif not _identical(field, bare):
		_fail += 1
		print("    !! the stack changed the field on its way through; a splice must copy it, not resample it")
	else:
		print("    the stacked field is BITWISE IDENTICAL to the bare one")

	# CONTROL. Two materials that both ignore their surface also agree bitwise.
	var other := _field(_stacked_dla(4, flat))
	print("    CONTROL a FLAT surface through the same stack: %s"
			% ["DIFFERENT field" if not _identical(other, bare) else "the same field"])
	if _identical(other, bare):
		_fail += 1
		print("    !! the surface is not reaching the layer; the equality above is two arms ignoring it")

	# CONTROL, CZ's, for the composite: a stack nobody asked to seed must not ask for a capture.
	var quiet := Pasture3DReliefStack.new()
	var quiet_layers: Array[Pasture3DReliefMaterial] = [_fractal(), _dla(4, 256)]
	quiet.layers = quiet_layers
	print("    CONTROL a stack with no seeded layer wants a surface: %s" % quiet.wants_seed_surface())
	if quiet.wants_seed_surface():
		_fail += 1
		print("    !! every stack in the project is now charged for a capture it never asked for")

	# THE ROUTE. Everything above is the stack answering correctly; this is the host asking it.
	var mound = _make_stacked_mound("DB", SITE_DB)
	if mound == null:
		_completed += 1
		return
	var probes := _lattice(SITE_DB)
	var grow := mound.modifiers[1] as Pasture3DNodeRelief
	grow.enabled = false
	mound._refresh_owner(mound._layer_owner, false, [])
	var rough_only := _snapshot(probes)
	grow.enabled = true
	mound._refresh_owner(mound._layer_owner, false, [])
	var after_1 := _snapshot(probes)
	mound._refresh_owner(mound._layer_owner, false, [])
	var after_2 := _snapshot(probes)
	print("    through a real bake: first %.4f m, second %.4f m"
			% [_max_diff_arr(after_1, rough_only), _max_diff_arr(after_2, after_1)])
	if _max_diff_arr(after_1, rough_only) > 0.001:
		_fail += 1
		print("    !! it stamped before it had a surface, which the next bake would replace")
	if _max_diff_arr(after_2, after_1) < 0.5:
		_fail += 1
		print("    !! the second bake stamped nothing: the host is not routing the surface into the stack")
	_completed += 1


## The same DLA CY seeds bare, as the only layer of a stack, seeded THROUGH the stack rather than by
## reaching past it. One layer and not two on purpose: the claim is bitwise equality with the bare arm,
## and a second layer would add ops of its own to compare around.
func _stacked_dla(p_seed: int, p_surface: PackedFloat32Array) -> Pasture3DReliefStack:
	var inner := _dla(p_seed, 256)
	inner.ridge_seeding = true
	var stack := Pasture3DReliefStack.new()
	var l: Array[Pasture3DReliefMaterial] = [inner]
	stack.layers = l
	stack.set_seed_surface(_seed_dict(p_surface))
	return stack


## CZ's fixture with the DLA wrapped in a stack: fractal -> [stack: DLA]. The modifier list is otherwise
## identical, so a difference between the two gates' ground measurements is the wrapping and nothing else.
func _make_stacked_mound(p_name: String, p_at: Vector3):
	var mound = _make_mound(p_name, p_at)
	if mound == null:
		return null
	var rough := Pasture3DNodeRelief.new()
	rough.label = "Rough"
	rough.material = _fractal()
	rough.strength = RELIEF_M
	var dla := _dla(5, 256)
	dla.ridge_seeding = true
	var stack := Pasture3DReliefStack.new()
	var l: Array[Pasture3DReliefMaterial] = [dla]
	stack.layers = l
	var grow := Pasture3DNodeRelief.new()
	grow.label = "DLA in a stack"
	grow.material = stack
	grow.strength = RELIEF_M
	var mods: Array[Pasture3DNode] = [rough, grow]
	mound.modifiers = mods
	return mound


# --- DK: FROZEN holds the mountain it grew, and Bake Mountain regrows it ----------------------------
#
# §9.9. Growing a 512² cluster is seconds of GDScript and it happens inside compile(), so a material that
# regrew whenever anything it reads moved froze the editor for the length of every drag. FROZEN is the
# cure and it is one rule: EVERY growth input is held, because the key is a hash of all of them.
#
# TWO INPUTS ARE MEASURED, not one, because they arrive down different paths and the freeze that was
# reported came down the second: the loop's oriented frame reaches the material through `set_host_frame`
# DURING a bake, and the seeded surface through `set_seed_surface` AFTER one. The second is the one that
# made merely TRANSLATING a brush regrow the mountain — the captured surface moves when the brush does,
# so a seeded DLA answered "yes, and bake me again" on every frame of every drag.
#
# THE CONTROL IS THE SAME MATERIAL ON LIVE, down each path. Without it "the field did not change" is
# what a material that ignores its inputs entirely also reports, and this whole criterion would pass on
# a DLA that had been accidentally welded shut.
#
# DK.3 IS THE ONE WITH TEETH. "Bake Mountain changed something" would pass an implementation that
# regrew from the inputs it was holding when it was frozen. The bake must land BITWISE on what the LIVE
# arm grew for the CURRENT frame — same seed, same resolution, same everything, so the growth is
# deterministic and the only way to miss is to have regrown against the wrong inputs.
func _gate_dk_frozen_holds() -> void:
	print("\n[DK] FROZEN holds the mountain it grew, and Bake Mountain regrows it:")

	# ---- Path 1: the loop's shape, which arrives during a bake.
	var frozen := _dla(9, 128)
	frozen.evaluation = Pasture3DReliefDLA.Evaluation.FROZEN
	frozen.set_host_frame(1.0, 1.0)
	var square := _field(frozen).duplicate()
	frozen.set_host_frame(DA_EX, DA_EZ)
	var held := _field(frozen).duplicate()

	var live := _dla(9, 128) # already LIVE — see _dla
	live.set_host_frame(1.0, 1.0)
	var live_square := _field(live).duplicate()
	live.set_host_frame(DA_EX, DA_EZ)
	var live_stretched := _field(live).duplicate()

	if square.is_empty() or live_square.is_empty():
		_fail += 1
		print("    !! nothing grew on the first compile; the rest of this gate would compare two blanks")
		return
	print("    the loop is reshaped under it:  FROZEN %s   CONTROL LIVE %s"
			% ["held (bitwise)" if _identical(square, held) else "REGREW",
				"regrew" if not _identical(live_square, live_stretched) else "HELD"])
	if not _identical(square, held):
		_fail += 1
		print("    !! FROZEN regrew on a shape change — this is the reshape-drag freeze, still there")
	if _identical(live_square, live_stretched):
		_fail += 1
		print("    !! LIVE did not regrow either, so the comparison above proves nothing")

	# ---- Path 2: the seeded surface, which arrives after a bake. The reported freeze.
	var flat := PackedFloat32Array()
	flat.resize(SEED_G * SEED_G)
	flat.fill(12.0)
	var fz := _dla(4, 128)
	fz.evaluation = Pasture3DReliefDLA.Evaluation.FROZEN
	fz.ridge_seeding = true
	fz.set_seed_surface(_seed_dict(_star_ridges()))
	var seeded := _field(fz).duplicate()
	var fz_asked: bool = fz.set_seed_surface(_seed_dict(flat))
	var seeded_held := _field(fz).duplicate()

	var lv := _dla(4, 128)
	lv.ridge_seeding = true
	lv.set_seed_surface(_seed_dict(_star_ridges()))
	var lv_seeded := _field(lv).duplicate()
	var lv_asked: bool = lv.set_seed_surface(_seed_dict(flat))
	var lv_held := _field(lv).duplicate()

	print("    a new captured surface arrives: FROZEN %s and asks for a re-bake: %s"
			% ["held (bitwise)" if _identical(seeded, seeded_held) else "REGREW", str(fz_asked)])
	print("                                    CONTROL LIVE %s and asks: %s"
			% ["regrew" if not _identical(lv_seeded, lv_held) else "HELD", str(lv_asked)])
	if not _identical(seeded, seeded_held) or fz_asked:
		_fail += 1
		print("    !! a frozen seeded DLA still regrows and still asks for another bake — which is the\n"
			+ "       reported freeze: the capture moves whenever the brush is dragged anywhere at all")
	if _identical(lv_seeded, lv_held) or not lv_asked:
		_fail += 1
		print("    !! LIVE ignored the new surface too, so the frozen arm above is measuring nothing")

	# ---- DK.3: the bake regrows against what is there NOW, not against what it was holding.
	frozen.bake_mountain()
	var rebaked := _field(frozen).duplicate()
	var matches := _identical(rebaked, live_stretched)
	print("    Bake Mountain: %s the LIVE field for the CURRENT frame (%.6f worst cell apart)"
			% ["BITWISE identical to" if matches else "DIFFERS from", _max_diff(rebaked, live_stretched)])
	if not matches:
		_fail += 1
		print("    !! Bake Mountain regrew the mountain for the frame it was frozen at, not the live one")
	if _identical(rebaked, held):
		_fail += 1
		print("    !! Bake Mountain changed nothing at all, so 'it regrew' is unmeasured")

	# ---- The warning: a held mountain that no longer matches its inputs has to SAY so.
	var fresh_said := frozen._configuration_warning()
	frozen.set_host_frame(1.0, 1.0)
	var warned := frozen._configuration_warning().contains("Bake Mountain")
	print("    it warns once stale: %s   CONTROL freshly baked, it warns: %s"
			% [str(warned), str(fresh_said.contains("Bake Mountain"))])
	if not warned:
		_fail += 1
		print("    !! a stale frozen mountain says nothing, which is serving old data silently")
	if fresh_said.contains("Bake Mountain"):
		_fail += 1
		print("    !! it warns even when freshly baked, so the warning tracks nothing")
	_completed += 1


# --- DL: the growth run on a worker is the growth run inside the bake --------------------------------
#
# The same claim gate DC makes for the erosion solve, and it has to be made separately because the two
# take different routes through the driver: an erosion solve is delivered through the modifier's frozen
# CACHE, and a grown field is delivered by recompiling the material — which means the answer has to
# survive a memoised program, and a stack that copies its layers' bytes.
#
# THE CONTROL THAT MATTERS IS THE LAST ONE. "Deferred equals synchronous" is what a driver that quietly
# grew on the main thread would also report, and so is what a `defer` flag nobody reads would report.
# Baking with the deferral ON and the request thrown away is the pass that separates them: it must come
# out as the brush with no mountain at all.
func _gate_dl_deferred_growth() -> void:
	print("\n[DL] the deferred growth gives the same terrain as the synchronous one:")
	var mound = _make_mound("DL", SITE_DL)
	if mound == null:
		return
	var probes := _lattice(SITE_DL)
	var step: Pasture3DNodeRelief = mound.modifiers[0]
	var mat: Pasture3DReliefDLA = step.material
	# FROZEN, the shipped default: the configuration the editor actually runs.
	mat.evaluation = Pasture3DReliefDLA.Evaluation.FROZEN

	step.enabled = false
	mound._refresh_owner(mound._layer_owner, false, [])
	var bare := _snapshot(probes)
	step.enabled = true

	mat.clear_growth()
	mound._refresh_owner(mound._layer_owner, false, [])
	var sync := _snapshot(probes)

	mat.clear_growth()
	mound.force_deferred_erosion = true
	await mound._bake_deferred(mound._refresh_owner.bind(mound._layer_owner, false, []),
			mound._layer_owner, false)
	mound.force_deferred_erosion = false
	var deferred := _snapshot(probes)

	var worst := _max_diff_arr(sync, deferred)
	var relief := _max_diff_arr(bare, sync)
	print("    worst |deferred - synchronous| = %.8f m over %d probes" % [worst, probes.size()])
	print("    CONTROL the mountain moves the ground: %.4f m" % relief)
	if worst > 1.0e-5:
		_fail += 1
		print("    !! the worker and the main thread grew different mountains")
	if relief < 1.0:
		_fail += 1
		print("    !! the DLA barely moved the ground, so agreeing about it means nothing")

	print("    the grown field is held after the run: %d bytes" % mat.growth_bytes())
	if mat.growth_bytes() <= 0:
		_fail += 1
		print("    !! nothing was stored, so the last pass regrew on the main thread — the freeze is back")

	# CONTROL: the deferral honoured and the request dropped on the floor. This is pass 1 alone.
	mat.clear_growth()
	mound._growth_defer = true
	mound._refresh_owner(mound._layer_owner, false, [])
	mound._growth_defer = false
	mound._pending_growth = []
	var pass1 := _snapshot(probes)
	var gap := _max_diff_arr(pass1, bare)
	print("    CONTROL pass 1 alone, with the request discarded: %.8f m from the bare brush" % gap)
	if gap > 1.0e-5:
		_fail += 1
		print("    !! pass 1 already carries the mountain, so `defer` is not being read and the driver\n"
			+ "       is decoration around an ordinary synchronous growth")
	# ---- The STACKED arm, which the bare one above cannot stand in for. A Pasture3DReliefStack copies
	# its layers' bytes into its own program and memoises the splice, so a layer that grows underneath it
	# is invisible unless the layer says so and the stack listens — the exact shape of two bugs this
	# material has already had (§9.8, §9.6). On the deferred path the layer changes its program TWICE per
	# bake: to nothing when the offer is taken up, and back again when the field lands.
	var smound = _make_mound("DL2", SITE_DL2)
	if smound == null:
		_completed += 1
		return
	var sprobes := _lattice(SITE_DL2)
	var sstep: Pasture3DNodeRelief = smound.modifiers[0]
	var sdla := _dla(6, 256)
	sdla.evaluation = Pasture3DReliefDLA.Evaluation.FROZEN
	var sstack := Pasture3DReliefStack.new()
	var slayers: Array[Pasture3DReliefMaterial] = [sdla]
	sstack.layers = slayers
	sstep.material = sstack

	sstep.enabled = false
	smound._refresh_owner(smound._layer_owner, false, [])
	var sbare := _snapshot(sprobes)
	sstep.enabled = true

	sdla.clear_growth()
	smound._refresh_owner(smound._layer_owner, false, [])
	var ssync := _snapshot(sprobes)

	sdla.clear_growth()
	smound.force_deferred_erosion = true
	await smound._bake_deferred(smound._refresh_owner.bind(smound._layer_owner, false, []),
			smound._layer_owner, false)
	smound.force_deferred_erosion = false
	var sdef := _snapshot(sprobes)

	var sworst := _max_diff_arr(ssync, sdef)
	var srelief := _max_diff_arr(sbare, sdef)
	print("    in a Relief Stack: worst |deferred - synchronous| = %.8f m, and the stacked mountain "
			% sworst + "moves the ground %.4f m" % srelief)
	if sworst > 1.0e-5:
		_fail += 1
		print("    !! the stack served the splice it made before the field landed")
	if srelief < 1.0:
		_fail += 1
		print("    !! the stacked DLA stamps nothing on the deferred path, so it agrees with the\n"
			+ "       synchronous arm by both stamping nothing")
	_completed += 1

