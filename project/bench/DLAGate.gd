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
const GATES := 5

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
	print("    %-22s %-18s %s" % ["", "network share", "branches"])
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
	var shape := mound.modifiers[0] as Pasture3DModRelief

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


# --- CS: a loop-sized material warns under Mapping = Tile -------------------------------------------
#
# DLA maps ONCE onto the loop's oriented rectangle, exactly as CRATER does, so Tile produces a grid of
# identical mountains. The Plow already had this warning for craters; phase 6 generalises the predicate
# from "has a CRATER op" to "has a loop-sized op", and this gate holds BOTH halves of that change: the
# new material must warn, and the old one must still warn.
#
# CONTROL. The spec's: Mapping = Fit, which must not warn. A predicate that returned true unconditionally
# would otherwise pass every positive assertion here.
func _gate_cs_tile_warns() -> void:
	print("\n[CS] Mapping = Tile warns on a loop-sized material:")
	var plow := Pasture3DPlow.new()
	plow.name = "CSPlow"
	_root.add_child(plow)
	plow.terrain = _terrain
	plow.global_position = SITE_CR + Vector3(400.0, 0.0, 0.0)
	plow.source = Pasture3DPlow.Source.RELIEF
	_add_loop(plow)

	var dla := _dla(11, 128)
	var crater := Pasture3DReliefCrater.new()
	var fractal := Pasture3DReliefFractal.new()
	fractal.feature_size = 20.0

	for e in [["DLA", dla, true], ["Crater", crater, true], ["Fractal", fractal, false]]:
		plow.relief = e[1]
		plow.mapping = Pasture3DPlow.Mapping.TILE
		var tiled := _warned(plow)
		plow.mapping = Pasture3DPlow.Mapping.FIT
		var fitted := _warned(plow)
		print("    %-8s Tile warns %-5s   Fit warns %-5s   (loop-sized: %s)"
				% [e[0], str(tiled), str(fitted), str(e[2])])
		if bool(e[2]) and not tiled:
			_fail += 1
			print("      !! a loop-sized material tiled without a word")
		if not bool(e[2]) and tiled:
			_fail += 1
			print("      !! a material that tiles correctly was warned about")
		if fitted:
			_fail += 1
			print("      !! Fit warned; the warning does not depend on the mapping at all")
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
#   CX.3  `detail_size` RESTYLES WITHOUT RESIZING — across its whole range the radius barely moves
#         while the branch count moves a lot. That is the property the old particle knob did not have.
#
# CONTROL. The border ring must be EXACTLY zero at every one of these settings. That invariant is the
# reason the geometry is derived from one property instead of set by two constants, and it is the thing
# that breaks first if the derivation drifts: a massif clipped by the field's edge puts a step at the loop
# boundary on every FIT-mapped brush. Plus the usual "measured nothing" guard — a flat field would sail
# through CX.3 by never changing size.
func _gate_cx_size_and_detail() -> void:
	print("\n[CX] Coverage sizes the massif, Detail Size styles it:")
	var n := 256
	print("    %-22s %8s %8s %9s %9s" % ["", "reached", "r98", "branches", "border"])
	var by_cover := {}
	var by_detail := {}
	var worst_border := 0.0
	var worst_arrival := 1.0
	var flat := false
	for e in [[0.5, 0.12], [0.9, 0.12], [0.98, 0.12], [0.9, 0.05], [0.9, 0.30]]:
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
		var arrival: float = _reach(m, n) / maxf(m._grow_extent(n), 1.0)
		var r98 := _r_mass(f, n, 0.98) / (0.5 * float(n))
		var branches := _max_components(f, n)
		var border := _border(f, n)
		print("    coverage %.2f detail %.2f %7.0f%% %8.3f %9d %9.6f"
				% [e[0], e[1], 100.0 * arrival, r98, branches, border])
		worst_border = maxf(worst_border, border)
		worst_arrival = minf(worst_arrival, arrival)
		if is_equal_approx(e[1], 0.12):
			by_cover[e[0]] = r98
		if is_equal_approx(e[0], 0.9):
			by_detail[e[1]] = [r98, branches]

	print("    CX.1 worst arrival at its allowed radius: %.0f%%" % [100.0 * worst_arrival])
	if worst_arrival < 0.90:
		_fail += 1
		print("    !! the cluster stops short of the radius Coverage allows; the budget is deciding the size")

	# CX.2 -- r98 must track coverage. Compared as a RATIO against the coverage ratio, so the criterion is
	# "it scales" rather than "it hit a number somebody wrote down".
	var small: float = by_cover[0.5]
	var big: float = by_cover[0.98]
	var got := big / maxf(small, 0.0001)
	var want := 0.98 / 0.5
	print("    CX.2 coverage 0.50 -> 0.98 grows the field %.2fx (coverage itself grows %.2fx)" % [got, want])
	if got < want * 0.7 or got > want * 1.3:
		_fail += 1
		print("    !! the field's size does not track Coverage; it is not the size control it claims to be")

	# CX.3 -- detail must NOT resize.
	var fine: Array = by_detail[0.05]
	var coarse: Array = by_detail[0.30]
	var drift: float = absf(float(coarse[0]) - float(fine[0])) / maxf(float(fine[0]), 0.0001)
	var style: float = float(fine[1]) / maxf(float(coarse[1]), 1.0)
	print("    CX.3 detail 0.05 -> 0.30 moves the size %.0f%% while the branch count changes %.1fx"
			% [100.0 * drift, style])
	if drift > 0.25:
		_fail += 1
		print("    !! Detail Size is resizing the mountain; the two controls are still coupled")
	if style < 1.5:
		_fail += 1
		print("    !! Detail Size barely changed the branching, so CX.3's other half is about nothing")

	# CONTROL
	print("    CONTROL worst value anywhere in the border ring, over all five: %.8f" % worst_border)
	if worst_border > 0.0:
		_fail += 1
		print("    !! the massif reaches the field's edge; a FIT-mapped brush would step at its loop")
	if flat:
		_fail += 1
		print("    !! one of these fields is flat; a flat field never changes size and passes CX.3 for free")
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


## The largest value anywhere in the outermost 2 % ring. Must be exactly 0.
func _border(g: PackedFloat32Array, n: int) -> float:
	var band := maxi(1, int(float(n) * 0.02))
	var w := 0.0
	for y in range(n):
		for x in range(n):
			if x < band or y < band or x >= n - band or y >= n - band:
				w = maxf(w, g[y * n + x])
	return w


func _fractal() -> Pasture3DReliefFractal:
	var f := Pasture3DReliefFractal.new()
	f.style = Pasture3DReliefFractal.Style.CRAGGY
	f.feature_size = 20.0
	f.seed = 5
	return f


func _dla(p_seed: int, p_res: int) -> Pasture3DReliefDLA:
	var m := Pasture3DReliefDLA.new()
	m.resolution = p_res
	m.seed = p_seed
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


func _identical(a: PackedFloat32Array, b: PackedFloat32Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if a[i] != b[i]:
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
	var shape := Pasture3DModRelief.new()
	shape.label = "DLA"
	shape.material = _dla(5, 512)
	shape.strength = RELIEF_M
	var stack: Array[Pasture3DBrushModifier] = [shape]
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
