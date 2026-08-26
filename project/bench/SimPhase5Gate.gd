# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Phase 5 gates AA-AG for Pasture3DSim masking (PASTURE3D_SIM_NODE_SPEC.md §17.8).
#
# Two families, the same split phases 1-2 use:
#   AA-AC, AF  drive `selector_mask_field` and `erode_heightfield` DIRECTLY on synthetic grids. The mask
#              field is a pure function of a heightfield and a selector block, so these measure it with
#              no bake in the way.
#   AD, AE, AG drive a real Pasture3DSim on the demo terrain, because "the write mask does not change
#              the solve", "re-running does not drift" and "self-reference is refused" are claims about
#              the NODE, not about the arithmetic.
#
# THE GATE COMPUTES SLOPE, ALTITUDE AND CURVATURE ITSELF, from its own fixture, with its own central
# differences. It never asks `selector_mask_field` what the ground is doing and then checks the mask against
# that answer — a gate that takes its reference from the code under test agrees with the bug.
#
# NOTHING IS SAVED. Bakes write into the terrain's in-memory layer; demo/data on disk is only touched by
# an explicit save, which nothing here calls.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/SimPhase5Gate.tscn
extends Node

const DEMO_DATA := "res://demo/data"

## Synthetic grid for the field gates.
const SG := 128
const SCELL := 4.0
const BASE_Z := 200.0

## Selector filter types, mirroring Pasture3DTerrainMask.FilterType so the gate names them without importing
## resource's enum into every call site.
const K_SLOPE := 0
const K_ALTITUDE := 1
const K_CURVATURE := 2
const K_FLOW := 3
const K_EROSION := 4
const K_DEPOSITION := 5
const K_WETNESS := 6
const KIND_NAMES := ["SLOPE", "ALTITUDE", "CURVATURE", "FLOW", "EROSION", "DEPOSITION", "WETNESS"]

## Node-gate sites inside the loaded demo regions, far enough apart that their tile-snapped clear boxes
## cannot touch. Same band phases 1-4 proved.
const SITE_WRITE := Vector3(300.0, 0.0, 300.0)
const SITE_IDEMPOTENT := Vector3(700.0, 0.0, 300.0)
const SITE_SELF := Vector3(500.0, 0.0, 620.0)

const LOOP_HALF := 60.0
const NODE_MARGIN := 40.0

var _fail := 0
var _root: Node3D
var _terrain
var _data


func _ready() -> void:
	print("\n=== Pasture3DSim phase 5 (spec §17.8 gates AA-AG) ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_data = _terrain.data
	if _data == null or not _data.has_method("selector_mask_field"):
		_fail += 1
		print("!! this build has no selector_mask_field — phase 5 is unbuilt, not failing")
		_done()
		return

	_gate_aa_rate_mask()
	_gate_ab_own_field()
	_gate_ac_product()
	_gate_af_registration()
	_gate_ad_write_mask()
	_gate_ae_idempotent()
	_gate_ag_self_reference()

	_done()


func _done() -> void:
	print("\n=== %s (%d failures) ===\n" % ["SIM PHASE 5 PASS" if _fail == 0 else "SIM PHASE 5 FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- AA: the rate mask gates incision -------------------------------------------------------------
# A SLOPE band over a two-grade hillside must suppress incision on the gentle half while leaving the
# steep half eroding. Measured as mean |delta| inside and outside the band, masked against unmasked.
#
# CONTROL, two of them. `strength = 0` must reproduce the unmasked bake BITWISE — that is what proves an
# empty/neutral mask is a true no-op rather than "close enough". And the unmasked and masked runs must
# differ at all, or the fixture has nothing inside the band and the criterion is empty.
func _gate_aa_rate_mask() -> void:
	print("[AA] the rate mask gates incision (SLOPE band over a two-grade hillside):")
	var z := _two_grade_slope()
	var slope := _slope_field(z)
	# The band: the steep half only. The fixture's two grades are 1.7° and 14°, so 8° splits them with
	# room either side and no cell sits in the falloff.
	var steep := _mask_cells(slope, 8.0)
	print("    fixture: %d of %d cells steeper than 8 deg (%.0f%%)" % [
			steep.size(), SG * SG, 100.0 * float(steep.size()) / float(SG * SG)])
	if steep.size() < SG * SG / 8 or steep.size() > SG * SG * 7 / 8:
		_fail += 1
		print("    !! the fixture is not split by the band; AA would measure one population")
		return

	var field := _field(z, [_sel(K_SLOPE, 8.0, 90.0, 0.0, 0.0)])
	if field.size() != SG * SG:
		_fail += 1
		print("    !! selector_mask_field returned %d values, wanted %d" % [field.size(), SG * SG])
		return
	print("    mask field: mean %.3f on the steep half, %.3f on the gentle half" % [
			_mean_at(field, steep), _mean_outside(field, steep)])

	var plain := _solve(z, _EROSIVE, PackedFloat32Array())
	var masked := _solve(z, _EROSIVE, field, 0.0, 1.0)
	if plain.is_empty() or masked.is_empty():
		return
	var d_plain := _delta(z, plain["z"])
	var d_mask := _delta(z, masked["z"])
	var in_plain := _mean_abs_at(d_plain, steep)
	var in_mask := _mean_abs_at(d_mask, steep)
	var out_plain := _mean_abs_outside(d_plain, steep)
	var out_mask := _mean_abs_outside(d_mask, steep)
	print("    mean |delta| in band:  unmasked %.4f m -> masked %.4f m" % [in_plain, in_mask])
	print("    mean |delta| outside:  unmasked %.4f m -> masked %.4f m" % [out_plain, out_mask])
	if out_plain < 0.01:
		_fail += 1
		print("    !! the unmasked run barely eroded outside the band; there is nothing to suppress")
		return
	if out_mask > out_plain * 0.25:
		_fail += 1
		print("    !! the mask did not suppress erosion outside its band (want < 25%% of unmasked)")
	if in_mask < in_plain * 0.5:
		_fail += 1
		print("    !! the mask suppressed erosion INSIDE its own band; the band is inverted or misread")

	# CONTROL 1: strength 0 is a true no-op, bitwise.
	var neutral := _field(z, [_sel(K_SLOPE, 8.0, 90.0, 0.0, 0.0, false, 0.0)])
	var zero_run := _solve(z, _EROSIVE, neutral, 0.0, 1.0)
	if not zero_run.is_empty():
		var drift := _max_abs(_delta(plain["z"], zero_run["z"]))
		print("    CONTROL strength 0 vs unmasked: max |difference| %.9f m (want exactly 0)" % drift)
		if drift != 0.0:
			_fail += 1
			print("    !! a strength-0 mask is not a no-op, so 'empty masks reproduce phase 4' is false")

	# CONTROL 2: the two runs must differ at all.
	var sep := _max_abs(_delta(plain["z"], masked["z"]))
	print("    CONTROL masked vs unmasked: max |difference| %.4f m (want > 0)" % sep)
	if sep <= 0.0:
		_fail += 1
		print("    !! the mask changed nothing; AA is measuring two identical runs")


# --- AB: each filter type reads its own field -------------------------------------------------------------
# For each of the seven filter types, band the TOP DECILE of its own field (computed here, from the
# fixture) and check the mask passes those cells and not others.
#
# CONTROL: the same numeric band handed to every OTHER filter type. If one is cross-wired the impostor
# scores as well as the owner, and the gate says which pair collided.
func _gate_ab_own_field() -> void:
	print("[AB] each filter type reads its own field (top-decile band per filter type):")
	var z := _noisy_slope()
	var res := _make_sim_result_for_grid()
	var refs := {
		K_SLOPE: _slope_field(z),
		K_ALTITUDE: z,
		K_CURVATURE: _curvature_field(z),
		K_FLOW: _channel_ref(K_FLOW),
		K_EROSION: _channel_ref(K_EROSION),
		K_DEPOSITION: _channel_ref(K_DEPOSITION),
		K_WETNESS: _channel_ref(K_WETNESS),
	}
	for kind in refs.keys():
		var ref: PackedFloat32Array = refs[kind]
		var lo := _percentile(ref, 0.90)
		var hi := _max_abs(ref) + absf(lo) + 1.0e6 # an open top edge, whatever the units
		var passing := _mask_cells(_field(z, [_sel(kind, lo, hi, 0.0, 0.0)], res), 0.5)
		var own := _mask_cells(ref, lo)
		if own.is_empty() or passing.is_empty():
			_fail += 1
			print("    !! %s: the fixture has no top decile (%d ref cells, %d passing)" % [
					KIND_NAMES[kind], own.size(), passing.size()])
			continue
		var agree := _overlap(passing, own)
		print("    %s band >= %s: %d cells pass, %.1f%% of them are in the field's own top decile" % [
				KIND_NAMES[kind], String.num(lo, 4), passing.size(), 100.0 * agree])
		if agree < 0.98:
			_fail += 1
			print("    !! %s does not read its own field" % KIND_NAMES[kind])

		# CONTROL: the best-scoring impostor. Some overlap is inevitable (altitude and slope correlate on
		# a hillside), so the bar is that no other filter type scores as well as the owner does.
		var worst := 0.0
		var worst_name := "-"
		for other in refs.keys():
			if other == kind:
				continue
			var imp := _overlap(_mask_cells(_field(z, [_sel(other, lo, hi, 0.0, 0.0)], res), 0.5), own)
			if imp > worst:
				worst = imp
				worst_name = KIND_NAMES[other]
		print("      CONTROL best impostor %s scores %.1f%% (want well under %.1f%%)" % [
				worst_name, 100.0 * worst, 100.0 * agree])
		if worst >= agree - 0.02:
			_fail += 1
			print("    !! %s and %s are indistinguishable here; the band does not separate the filter types" % [
					KIND_NAMES[kind], worst_name])


# --- AC: selectors combine by product --------------------------------------------------------------
# Two overlapping bands together must give the elementwise PRODUCT of their weights.
#
# CONTROL: neither selector alone reproduces the pair, and `min` does not either. Without the second half
# the criterion would pass for a combiner that returns `min`, which is the obvious wrong answer.
func _gate_ac_product() -> void:
	print("[AC] selectors combine by product:")
	var z := _noisy_slope()
	var slope := _slope_field(z)
	var a := _sel(K_SLOPE, _percentile(slope, 0.40), 90.0, 6.0, 0.0)
	var b := _sel(K_ALTITUDE, _percentile(z, 0.35), 1.0e6, 12.0, 0.0)
	var fa := _field(z, [a])
	var fb := _field(z, [b])
	var fab := _field(z, [a, b])
	if fa.size() != SG * SG or fb.size() != SG * SG or fab.size() != SG * SG:
		_fail += 1
		print("    !! a mask field came back the wrong size")
		return

	var soft := 0
	for i in range(SG * SG):
		if fa[i] > 0.01 and fa[i] < 0.99:
			soft += 1
	print("    fixture: %d cells sit in a falloff (partial weight), not just 0 or 1" % soft)
	if soft < 100:
		_fail += 1
		print("    !! every weight is 0 or 1 here; product and min are indistinguishable on this fixture")
		return

	var worst := 0.0
	for i in range(SG * SG):
		worst = maxf(worst, absf(fab[i] - fa[i] * fb[i]))
	print("    max |AB - A*B| = %.9f" % worst)
	if worst > 1.0e-6:
		_fail += 1
		print("    !! the stack does not combine by product")

	# CONTROL: A alone, B alone, and min(A,B) must all be measurably different from the pair.
	var d_a := 0.0
	var d_b := 0.0
	var d_min := 0.0
	for i in range(SG * SG):
		d_a = maxf(d_a, absf(fab[i] - fa[i]))
		d_b = maxf(d_b, absf(fab[i] - fb[i]))
		d_min = maxf(d_min, absf(fab[i] - minf(fa[i], fb[i])))
	print("    CONTROL max |AB - A| %.4f, |AB - B| %.4f, |AB - min(A,B)| %.4f (all want > 0)" % [
			d_a, d_b, d_min])
	if d_a <= 1.0e-6 or d_b <= 1.0e-6:
		_fail += 1
		print("    !! the pair equals one of its members; the second selector is being ignored")
	if d_min <= 1.0e-6:
		_fail += 1
		print("    !! product and min are indistinguishable here; the criterion cannot tell them apart")


# --- AF: mask fields register with the terrain -----------------------------------------------------
# The three ground filter types are index-based and cannot be misregistered. The SIM ones are looked up in
# WORLD coordinates through the result's own extent, so this is where an origin can be wrong: build a
# result whose flow is high in a known world-X strip, and check the mask passes at that X.
#
# CONTROL: the same field built with the grid origin displaced by one catchment margin, which must move
# the passing strip. That is the mistake an off-by-one grid origin makes.
func _gate_af_registration() -> void:
	print("[AF] sim-filter-type mask fields register with the terrain (world-X strip):")
	var z := _noisy_slope()
	var res := _make_sim_result_for_grid()
	# The strip: cells 40..60 of the result, in world metres.
	var strip_lo := res.min_x + 40.0 * res.cell_size
	var strip_hi := res.min_x + 60.0 * res.cell_size
	for i in range(res.width * res.height):
		var wx: float = res.min_x + float(i % res.width) * res.cell_size
		res.flow[i] = log(50000.0) if (wx >= strip_lo and wx < strip_hi) else log(1.0)

	var sel := [_sel(K_FLOW, 10000.0, 1.0e9, 0.0, 0.0)]
	var here := _mask_cells(_field(z, sel, res, 0.0, 0.0), 0.5)
	var span := _x_span(here)
	print("    passing X span %.1f..%.1f m; the strip is %.1f..%.1f m" % [
			span[0], span[1], strip_lo, strip_hi])
	if here.is_empty():
		_fail += 1
		print("    !! nothing passed; the sim channel was never read")
		return
	if absf(span[0] - strip_lo) > SCELL or absf(span[1] - (strip_hi - SCELL)) > SCELL:
		_fail += 1
		print("    !! the passing cells are not where the strip is")

	# CONTROL: displace the grid origin by one margin.
	var moved := _x_span(_mask_cells(_field(z, sel, res, NODE_MARGIN, 0.0), 0.5))
	print("    CONTROL origin displaced by %.0f m: passing X span %.1f..%.1f m (want moved)" % [
			NODE_MARGIN, moved[0], moved[1]])
	if absf(moved[0] - span[0]) < SCELL:
		_fail += 1
		print("    !! displacing the grid origin did not move the mask; the lookup ignores world position")


# --- AD: the write mask does not change the solve --------------------------------------------------
# The criterion that proves §17.3's two masks are actually two. Same node, same selector, run twice:
# once on `write_mask` (flow must be BITWISE unchanged, heights must change) and once on `erosion_mask`
# (flow MUST change).
#
# CONTROL: that second run. Without it, "the write mask left the flow alone" is equally true of a mask
# that does nothing at all.
func _gate_ad_write_mask() -> void:
	print("[AD] the write mask gates the write, not the solve:")
	var sim = _make_sim("AD", SITE_WRITE)
	if sim == null:
		return
	var probes := _probe_ring(SITE_WRITE)

	var plain: Dictionary = sim.simulate_now(1, false)
	if not bool(plain.get("ok", false)):
		_fail += 1
		print("    !! the unmasked bake failed: %s" % plain.get("reason", "?"))
		return
	var flow_plain: PackedFloat32Array = sim.sim_result.flow.duplicate()
	var h_plain := _snapshot(probes)

	var sel: Array[Pasture3DTerrainMask] = [_sel(K_SLOPE, 12.0, 90.0, 4.0, 0.0)]
	sim.write_mask = sel
	var w: Dictionary = sim.simulate_now(1, false)
	if not bool(w.get("ok", false)):
		_fail += 1
		print("    !! the write-masked bake failed: %s" % w.get("reason", "?"))
		return
	var flow_w: PackedFloat32Array = sim.sim_result.flow
	var flow_drift := _max_abs_diff_packed(flow_plain, flow_w)
	var h_drift := _max_abs_diff(h_plain, _snapshot(probes))
	print("    write_mask: flow max |difference| %.9f (want exactly 0), heights moved %.4f m" % [
			flow_drift, h_drift])
	if flow_drift != 0.0:
		_fail += 1
		print("    !! the write mask changed the solve; it is not a write mask")
	if h_drift <= 0.001:
		_fail += 1
		print("    !! the write mask changed no heights either, so the criterion measured nothing")

	# CONTROL: the same selector on the erosion mask must move the flow field.
	sim.write_mask = [] as Array[Pasture3DTerrainMask]
	sim.erosion_mask = sel
	var e: Dictionary = sim.simulate_now(1, false)
	if not bool(e.get("ok", false)):
		_fail += 1
		print("    !! the erosion-masked bake failed: %s" % e.get("reason", "?"))
		return
	var e_drift := _max_abs_diff_packed(flow_plain, sim.sim_result.flow)
	print("    CONTROL same selector on erosion_mask: flow max |difference| %.6f (want > 0)" % e_drift)
	if e_drift <= 0.0:
		_fail += 1
		print("    !! the erosion mask did not change the solve either; the two masks are the same thing")


# --- AE: masking is idempotent ---------------------------------------------------------------------
# Gate H's claim with both mask stacks populated: a second Simulate over the same settings reproduces
# the surface exactly, because the mask is built from the surface BELOW the Sim's own layer and that
# surface does not move.
#
# CONTROL: clearing the erosion mask must change the surface. Without it, "identical" is equally true of
# a build where the mask does nothing.
func _gate_ae_idempotent() -> void:
	print("[AE] masking is idempotent (two Simulates, masks populated):")
	var sim = _make_sim("AE", SITE_IDEMPOTENT)
	if sim == null:
		return
	var probes := _probe_ring(SITE_IDEMPOTENT)
	var before := _snapshot(probes)
	# Bands derived from the SITE's own heights, so both stacks genuinely split this ground instead of
	# passing all of it. The first version used SLOPE 10-90 and an ALTITUDE band a million metres wide;
	# both passed almost everything, which made "idempotent WITH masks" barely different from gate H and
	# left the control moving only 0.2 m of a 21.8 m bake. A median split cannot be that weak anywhere.
	var mid := _median(before)
	sim.erosion_mask = [_sel(K_ALTITUDE, mid, 1.0e6, 0.0, 0.0)] as Array[Pasture3DTerrainMask]
	sim.write_mask = [_sel(K_ALTITUDE, mid - 5.0, 1.0e6, 0.0, 0.0)] as Array[Pasture3DTerrainMask]
	print("    bands split the site at %.1f m altitude (probe range %.1f..%.1f m)" % [
			mid, before.min(), before.max()])

	if not bool(sim.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the first masked bake failed")
		return
	var run1 := _snapshot(probes)
	var moved := _max_abs_diff(before, run1)
	print("    the masked bake really did something: max |delta| %.4f m" % moved)
	if moved < 0.05:
		_fail += 1
		print("    !! the bake barely moved the ground; AE would compare two copies of nothing")
		return

	if not bool(sim.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the second masked bake failed")
		return
	var drift := _max_abs_diff(run1, _snapshot(probes))
	print("    re-run drift: %.9f m (want exactly 0)" % drift)
	if drift != 0.0:
		_fail += 1
		print("    !! a masked Sim drifts on re-run")

	# CONTROL: the comparison can see a difference when there is one.
	sim.erosion_mask = [] as Array[Pasture3DTerrainMask]
	if bool(sim.simulate_now(1, false).get("ok", false)):
		var unmasked := _max_abs_diff(run1, _snapshot(probes))
		print("    CONTROL mask cleared: surface moved %.4f m (want > 0.5)" % unmasked)
		if unmasked <= 0.5:
			_fail += 1
			print("    !! clearing the mask barely changed the surface, so the mask was not really gating "
				+ "and the zero drift above proves less than it looks like")


# --- AG: self-reference is refused -----------------------------------------------------------------
# A sim-filter-type selector pointed at this Sim's OWN result is reading this node's own output. It must be
# ignored, and the node must say so — so the bake matches the unmasked bake exactly.
#
# CONTROL: the identical selector pointed at ANOTHER result, which must gate. Without it the refusal
# could be blanket — banning the useful case along with the broken one.
func _gate_ag_self_reference() -> void:
	print("[AG] a mask on the Sim's own result is refused:")
	var sim = _make_sim("AG", SITE_SELF)
	if sim == null:
		return
	var probes := _probe_ring(SITE_SELF)
	if not bool(sim.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the seeding bake failed")
		return
	var h_plain := _snapshot(probes)
	if sim.sim_result == null or not sim.sim_result.is_valid():
		_fail += 1
		print("    !! the bake produced no masks, so there is nothing to self-reference")
		return

	# Overwrite the Sim's OWN erosion channel with the same half-domain split the control uses, so the band
	# below is genuinely selective. Without this the criterion is vacuous: an `EROSION >= 0.05 m` band on a
	# real result passes nearly every eroded cell, the field comes out 1.0 everywhere, and "the surface is
	# unchanged" is true whether the refusal works or not — which is exactly what the first break test
	# found. The mutation is safe because _prepare_solve builds the mask before _write_result rewrites the
	# channels, and this is still the same object, so it is still self-reference.
	_split_erosion(sim.sim_result)
	sim.erosion_mask = [_sel(K_EROSION, 5.0, 1.0e6, 0.0, 0.0, false, 1.0, sim.sim_result)] as Array[Pasture3DTerrainMask]
	var warned := false
	for w in sim._get_configuration_warnings():
		if String(w).contains("own output"):
			warned = true
	print("    configuration warning naming the self-reference: %s" % ("yes" if warned else "NO"))
	if not warned:
		_fail += 1
		print("    !! the node does not warn about a mask on its own result")

	if not bool(sim.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the self-referencing bake failed")
		return
	var drift := _max_abs_diff(h_plain, _snapshot(probes))
	print("    surface vs the unmasked bake: max |difference| %.9f m (want exactly 0)" % drift)
	if drift != 0.0:
		_fail += 1
		print("    !! the self-referencing mask was applied anyway")

	# CONTROL: the same filter type and band against a FOREIGN result must gate.
	var foreign: Pasture3DSimResult = _foreign_result(sim.sim_result)
	sim.erosion_mask = [_sel(K_EROSION, 5.0, 1.0e6, 0.0, 0.0, false, 1.0, foreign)] as Array[Pasture3DTerrainMask]
	if bool(sim.simulate_now(1, false).get("ok", false)):
		var gated := _max_abs_diff(h_plain, _snapshot(probes))
		print("    CONTROL the same band on ANOTHER Sim's result: moved %.4f m (want > 0.1)" % gated)
		if gated <= 0.1:
			_fail += 1
			print("    !! the refusal is blanket — a foreign result is banned too, or the band gates nothing")


# --- fixtures -------------------------------------------------------------------------------------

## The (rate, diffusion, iterations) triple phase 1 calibrated for a visible network on a hillside.
const _EROSIVE := {"iterations": 40, "erosion_rate": 0.2, "area_exponent": 0.45, "diffusion": 0.5}


## A hillside with two grades: gentle for the first half in +Z, steep for the second. One SLOPE band
## therefore splits the domain into two populations of comparable size, which is what AA needs — a
## uniform slope would have the band either passing everything or nothing.
func _two_grade_slope() -> PackedFloat32Array:
	var z := PackedFloat32Array()
	z.resize(SG * SG)
	var h := BASE_Z
	for iz in range(SG):
		var drop := 0.12 if iz < SG / 2 else 1.0 # ~1.7 deg then ~14 deg at 4 m cells
		h -= drop
		for ix in range(SG):
			z[iz * SG + ix] = h
	return z


## Phase 1's hillside fixture: a plane falling in +Z with coherent fractal relief on it. Reused so the
## mask gates measure the same ground the solver gates did.
func _noisy_slope() -> PackedFloat32Array:
	var n := FastNoiseLite.new()
	n.seed = 1234
	n.frequency = 0.003
	n.fractal_octaves = 3
	var z := PackedFloat32Array()
	z.resize(SG * SG)
	for iz in range(SG):
		for ix in range(SG):
			z[iz * SG + ix] = BASE_Z - 0.02 * iz * SCELL + 20.0 * n.get_noise_2d(ix * SCELL, iz * SCELL)
	return z


## A Pasture3DSimResult covering the synthetic grid exactly, with four DIFFERENT synthetic channels so
## AB can tell them apart. Flow is stored log-scaled and erosion negative, matching §8.2 — the gate builds
## the resource the way the sim writes it, not the way the selector reads it.
func _make_sim_result_for_grid() -> Pasture3DSimResult:
	var r := Pasture3DSimResult.new()
	r.min_x = 0.0
	r.min_z = 0.0
	r.cell_size = SCELL
	r.width = SG
	r.height = SG
	var n := SG * SG
	r.flow.resize(n)
	r.erosion.resize(n)
	r.deposition.resize(n)
	r.wetness.resize(n)
	for iz in range(SG):
		for ix in range(SG):
			var i := iz * SG + ix
			var u := float(ix) / float(SG - 1)
			var v := float(iz) / float(SG - 1)
			r.flow[i] = log(maxf(1.0, 100000.0 * u * u))       # rises with +X
			r.erosion[i] = -(20.0 * v)                          # deepens with +Z, stored negative
			r.deposition[i] = 8.0 * (1.0 - u) * (1.0 - v)       # largest at the -X/-Z corner
			r.wetness[i] = 5.0 * u * (1.0 - v)                  # largest at the +X/-Z corner
	return r


## What AB compares a sim filter type against: the channel in the UNITS a band is written in (§9), derived
## here from the same generator above rather than read back through the resource.
func _channel_ref(p_kind: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(SG * SG)
	for iz in range(SG):
		for ix in range(SG):
			var i := iz * SG + ix
			var u := float(ix) / float(SG - 1)
			var v := float(iz) / float(SG - 1)
			match p_kind:
				K_FLOW: out[i] = maxf(1.0, 100000.0 * u * u)
				K_EROSION: out[i] = 20.0 * v
				K_DEPOSITION: out[i] = 8.0 * (1.0 - u) * (1.0 - v)
				K_WETNESS: out[i] = 5.0 * u * (1.0 - v)
	return out


## A SimResult over the SAME extent as `p_src` but with a synthetic erosion channel: 10 m removed over
## the -X half of the area and nothing over the +X half.
##
## A verbatim COPY of the Sim's own masks was the obvious control here, and it is a trap — the first run
## of AG used one and reported "the foreign mask changed nothing", correctly. An `EROSION >= 0.05 m` band
## passes essentially every cell the sim eroded, so the composed field comes out 1.0 everywhere and the
## bake is bitwise identical to the unmasked one for a reason that has nothing to do with the refusal.
## The half-domain split is what makes the control able to fail for the RIGHT reason.
func _foreign_result(p_src) -> Pasture3DSimResult:
	var r := Pasture3DSimResult.new()
	r.min_x = p_src.min_x
	r.min_z = p_src.min_z
	r.cell_size = p_src.cell_size
	r.width = p_src.width
	r.height = p_src.height
	var n: int = r.width * r.height
	r.flow.resize(n)
	r.erosion.resize(n)
	r.deposition.resize(n)
	r.wetness.resize(n)
	_split_erosion(r)
	return r


## 10 m removed over the -X half of a result, nothing over the +X half. An `EROSION >= 5 m` band over this
## gates half the area no matter what the ground underneath is doing, which is what both halves of AG need.
func _split_erosion(p_r) -> void:
	for iz in range(p_r.height):
		for ix in range(p_r.width):
			p_r.erosion[iz * p_r.width + ix] = -10.0 if ix < p_r.width / 2 else 0.0 # stored negative (§8.2)


# --- the gate's own reference fields ---------------------------------------------------------------
#
# Central differences over SCELL, clamped at the edges — the same formula relief_fields_build uses, and
# deliberately a SECOND implementation of it. If these called into the extension the gate would be
# asking the code under test what the right answer is.

func _slope_field(p_z: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(SG * SG)
	var inv2 := 1.0 / (2.0 * SCELL)
	for iz in range(SG):
		var row := iz * SG
		var zm := maxi(iz - 1, 0) * SG
		var zp := mini(iz + 1, SG - 1) * SG
		for ix in range(SG):
			var xm := maxi(ix - 1, 0)
			var xp := mini(ix + 1, SG - 1)
			var gx := (p_z[row + xp] - p_z[row + xm]) * inv2
			var gz := (p_z[zp + ix] - p_z[zm + ix]) * inv2
			out[row + ix] = rad_to_deg(atan(sqrt(gx * gx + gz * gz)))
	return out


func _curvature_field(p_z: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(SG * SG)
	# §21.6 units: METRES of deviation over one cell (the ring mean minus the centre), not the 1/m
	# Laplacian. AB derives its band from this field, so the two move together.
	for iz in range(SG):
		var row := iz * SG
		var zm := maxi(iz - 1, 0) * SG
		var zp := mini(iz + 1, SG - 1) * SG
		for ix in range(SG):
			var xm := maxi(ix - 1, 0)
			var xp := mini(ix + 1, SG - 1)
			out[row + ix] = (p_z[row + xp] + p_z[row + xm] + p_z[zp + ix] + p_z[zm + ix]
					- 4.0 * p_z[row + ix]) * 0.25
	return out


# --- helpers --------------------------------------------------------------------------------------

## One Pasture3DTerrainMask, built from the numbers a criterion cares about.
func _sel(p_kind: int, p_lo: float, p_hi: float, p_f_lo: float, p_f_hi: float,
		p_invert := false, p_strength := 1.0, p_result: Pasture3DSimResult = null) -> Pasture3DTerrainMask:
	var s := Pasture3DTerrainMask.new()
	s.filter_type = p_kind # first — a filter type change re-defaults an untouched band (§21.5)
	s.measure_radius = 0.0 # this gate computes its own ONE-CELL fields; CURVATURE's preset sets 8 m
	s.range_min = p_lo
	s.range_max = p_hi
	s.falloff_low = p_f_lo
	s.falloff_high = p_f_hi
	s.invert = p_invert
	s.strength = p_strength
	s.sim_result = p_result
	return s


## `selector_mask_field` over the synthetic grid. `p_dx`/`p_dz` displace the grid origin, which is how AF's
## control asks for a misregistered lookup.
func _field(p_z: PackedFloat32Array, p_sels: Array, p_result: Pasture3DSimResult = null,
		p_dx := 0.0, p_dz := 0.0) -> PackedFloat32Array:
	var block := PackedFloat32Array()
	for s: Pasture3DTerrainMask in p_sels:
		block.append_array(PackedFloat32Array(s.to_params()))
	var sim: Dictionary = {}
	if p_result != null:
		sim = {"min_x": p_result.min_x, "min_z": p_result.min_z, "cell_size": p_result.cell_size,
				"width": p_result.width, "height": p_result.height, "flow": p_result.flow,
				"erosion": p_result.erosion, "deposition": p_result.deposition,
				"wetness": p_result.wetness}
	return _data.selector_mask_field(p_z, {
			"gw": SG, "gh": SG, "cell_size": SCELL, "min_x": p_dx, "min_z": p_dz,
		}, block, sim)


func _solve(p_z: PackedFloat32Array, p_params: Dictionary, p_erod: PackedFloat32Array,
		p_lo := 0.0, p_hi := 1.0) -> Dictionary:
	var params := p_params.duplicate()
	params["gw"] = SG
	params["gh"] = SG
	params["cell_size"] = SCELL
	if not p_erod.is_empty():
		params["erodability_w"] = SG
		params["erodability_h"] = SG
		params["erodability_min"] = p_lo
		params["erodability_max"] = p_hi
	var res: Dictionary = _data.erode_heightfield(p_z, params, p_erod)
	if not bool(res.get("ok", false)):
		_fail += 1
		print("    !! the solver rejected the %dx%d grid" % [SG, SG])
		return {}
	return res


## Indices whose value is at or above a threshold. The gate's own set-membership, so a criterion never
## has to trust the mask to say which cells it selected.
func _mask_cells(p_a: PackedFloat32Array, p_at_least: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in range(p_a.size()):
		if p_a[i] >= p_at_least:
			out.append(i)
	return out


## |A ∩ B| / |A| — how much of the passing set really belongs to the reference set.
func _overlap(p_a: PackedInt32Array, p_b: PackedInt32Array) -> float:
	if p_a.is_empty():
		return 0.0
	var want := {}
	for i in p_b:
		want[i] = true
	var hit := 0
	for i in p_a:
		if want.has(i):
			hit += 1
	return float(hit) / float(p_a.size())


func _median(p_a: Array[float]) -> float:
	var s := p_a.duplicate()
	s.sort()
	return s[s.size() / 2] if not s.is_empty() else 0.0


func _percentile(p_a: PackedFloat32Array, p_q: float) -> float:
	var s := p_a.duplicate()
	s.sort()
	return s[clampi(int(p_q * float(s.size() - 1)), 0, s.size() - 1)]


func _x_span(p_cells: PackedInt32Array) -> Array:
	if p_cells.is_empty():
		return [NAN, NAN]
	var lo := INF
	var hi := -INF
	for i in p_cells:
		var x := float(i % SG) * SCELL
		lo = minf(lo, x)
		hi = maxf(hi, x)
	return [lo, hi]


func _mean_at(p_a: PackedFloat32Array, p_cells: PackedInt32Array) -> float:
	var s := 0.0
	for i in p_cells:
		s += p_a[i]
	return s / maxf(float(p_cells.size()), 1.0)


func _mean_outside(p_a: PackedFloat32Array, p_cells: PackedInt32Array) -> float:
	var inside := {}
	for i in p_cells:
		inside[i] = true
	var s := 0.0
	var n := 0
	for i in range(p_a.size()):
		if not inside.has(i):
			s += p_a[i]
			n += 1
	return s / maxf(float(n), 1.0)


func _mean_abs_at(p_a: PackedFloat32Array, p_cells: PackedInt32Array) -> float:
	var s := 0.0
	for i in p_cells:
		s += absf(p_a[i])
	return s / maxf(float(p_cells.size()), 1.0)


func _mean_abs_outside(p_a: PackedFloat32Array, p_cells: PackedInt32Array) -> float:
	var inside := {}
	for i in p_cells:
		inside[i] = true
	var s := 0.0
	var n := 0
	for i in range(p_a.size()):
		if not inside.has(i):
			s += absf(p_a[i])
			n += 1
	return s / maxf(float(n), 1.0)


func _delta(p_before: PackedFloat32Array, p_after: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_before.size())
	for i in range(p_before.size()):
		out[i] = p_after[i] - p_before[i]
	return out


func _max_abs(p_a: PackedFloat32Array) -> float:
	var m := 0.0
	for v in p_a:
		if is_finite(v):
			m = maxf(m, absf(v))
	return m


func _max_abs_diff_packed(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		if is_finite(p_a[i]) and is_finite(p_b[i]):
			m = maxf(m, absf(p_a[i] - p_b[i]))
	return m


func _max_abs_diff(p_a: Array[float], p_b: Array[float]) -> float:
	var m := 0.0
	for i in range(p_a.size()):
		if is_finite(p_a[i]) and is_finite(p_b[i]):
			m = maxf(m, absf(p_a[i] - p_b[i]))
	return m


# --- node fixtures --------------------------------------------------------------------------------

func _make_sim(p_name: String, p_at: Vector3):
	if not is_finite(_height(p_at)):
		_fail += 1
		print("    !! no terrain at %s; the fixture is outside demo/data" % p_at)
		return null
	var sim := Pasture3DSim.new()
	sim.name = p_name
	_root.add_child(sim)
	sim.terrain = _terrain
	sim.global_position = p_at
	sim.catchment_margin = NODE_MARGIN
	sim.iterations = 30
	sim.erosion_rate = 0.1
	sim.hillslope_diffusion = 0.15
	sim.falloff_width = 16.0
	sim.snap_to_surface = false
	# Its own layer per site: two Sims sharing "Erosion" clear each other's tiles (§12), and three of
	# these run in one process.
	sim._layer_owner = "pasture3d_brush:Erosion_%s" % p_name
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	c.add_point(Vector3(-LOOP_HALF, 0.0, -LOOP_HALF))
	c.add_point(Vector3(LOOP_HALF, 0.0, -LOOP_HALF))
	c.add_point(Vector3(LOOP_HALF, 0.0, LOOP_HALF))
	c.add_point(Vector3(-LOOP_HALF, 0.0, LOOP_HALF))
	c.closed = true
	path.curve = c
	sim.add_child(path)
	return sim


## A spread of probe points well inside the loop, so a criterion reads the eroded interior and not the
## falloff band where every difference is scaled towards zero.
func _probe_ring(p_at: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for dz in [-30.0, -10.0, 10.0, 30.0]:
		for dx in [-30.0, -10.0, 10.0, 30.0]:
			out.append(p_at + Vector3(dx, 0.0, dz))
	return out


func _snapshot(p_points: Array[Vector3]) -> Array[float]:
	var out: Array[float] = []
	for p in p_points:
		out.append(_height(p))
	return out


func _height(p_at: Vector3) -> float:
	return _data.get_height(Vector3(p_at.x, 0.0, p_at.z))
