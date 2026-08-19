# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Phase 6.5 gates BE-BH — the SELECTOR half (PASTURE3D_SIM_NODE_SPEC.md §21.5, §21.6, §21.9).
#
# BA-BD belong to the pass-container half of §21 and are not here; that half lands separately and gets its
# own scene, so a failure in one half names itself.
#
# THE GATE COMPUTES ITS OWN REFERENCES, always. BF's fixture is an analytic paraboloid whose deviation over
# a radius is known in closed form (k*r^2), so "curvature in metres" is checked against maths and never
# against the code's own number. BF's bitwise claim is checked by sandwiching the stored float32 between
# the gate's own independently computed slope value and the NEXT float32 above it — if the field were one
# ulp off, the sandwich would open.
#
# READING A FIELD THROUGH A BAND. Nothing exposes the slope / curvature grids directly, so the gate
# recovers a cell's field value by binary-searching the band edge at which `selector_mask_field` flips that
# cell: the mask passes iff value >= range_min, so the flip point IS the value. That is a measurement of
# the thing under test through the interface that ships, rather than a second implementation of it.
#
# NOTHING IS SAVED except one throwaway .tres in user:// (BE's round-trip), which is deleted again.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/SimPhase65SelectorGate.tscn
extends Node

const DEMO_DATA := "res://demo/data"

## Selector filter types, mirroring Pasture3DReliefSelector.FilterType.
const K_SLOPE := 0
const K_ALTITUDE := 1
const K_CURVATURE := 2
const K_FLOW := 3
const K_EROSION := 4
const K_DEPOSITION := 5
const K_WETNESS := 6
const KIND_NAMES := ["SLOPE", "ALTITUDE", "CURVATURE", "FLOW", "EROSION", "DEPOSITION", "WETNESS"]

## BF's analytic grid. 1 m cells, because that is the spacing §21.5's audit measured at and the spacing at
## which the old and new curvature units differ by the clean factor of 4 the criterion quotes.
const BG_W := 129
const BG_CELL := 1.0
## z = DOME_K * r^2 (a bowl: every ring sits ABOVE the centre, so the deviation is positive = a hollow).
const DOME_K := 0.004
## The two radii BF compares, in metres. 16 / 4 = 4, so the predicted deviation ratio is 16.
const R_SMALL := 4.0
const R_LARGE := 16.0

## BG's fixture: a real solve at the SHIPPED solver defaults, so a preset is judged against ground the
## shipped settings actually make. 320 cells at 2.5 m is an 800 m site — large enough that a trunk channel
## gathers the thousands of square metres FLOW's preset asks about, which a 300 m fixture never does.
const SIM_W := 320
const SIM_CELL := 2.5
const SHIPPED_RATE := 0.08
const SHIPPED_DIFFUSION := 0.15
const SHIPPED_ITERATIONS := 30
## §21.9: a preset that selects less than this is a band nobody can use, more than this is not a gate.
const BG_MIN_FRACTION := 0.02
const BG_MAX_FRACTION := 0.60

## BH's node sites, inside the loaded demo regions and far enough apart that their clear boxes cannot meet.
const SITE_BAND := Vector3(300.0, 0.0, 900.0)
const LOOP_HALF := 50.0

var _fail := 0
var _root: Node3D
var _terrain
var _data


func _ready() -> void:
	print("\n=== Pasture3DReliefSelector phase 6.5 (spec §21.9 gates BE-BH) ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_data = _terrain.data
	if _data == null or not _data.has_method("selector_mask_field"):
		_fail += 1
		print("!! this build has no selector_mask_field — the selector path is unbuilt, not failing")
		_done()
		return
	if not (Pasture3DReliefSelector.new() as Object).has_method("uses_measure_radius"):
		_fail += 1
		print("!! this build's selector has no measure_radius — phase 6.5 is unbuilt, not failing")
		_done()
		return

	_gate_be_presets()
	_gate_bf_curvature_and_radius()
	_gate_bg_preset_coverage()
	_gate_bh_inverted_band()

	_done()


func _done() -> void:
	print("\n=== %s (%d failures) ===\n" % [
			"SIM PHASE 6.5 SELECTOR PASS" if _fail == 0 else "SIM PHASE 6.5 SELECTOR FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- BE: presets follow an untouched filter type change, and never an edited one --------------------------
#
# CONTROLS, both of which must fail if "untouched" is decided by the wrong comparison:
#   1. range_min set to the INCOMING filter type's preset value. It is still an edit, because the
#      comparison is against the OUTGOING one — an implementation checking the incoming would re-default.
#   2. A TWO-HOP chain, SLOPE -> FLOW -> EROSION. The second hop only re-defaults if "untouched" means
#      "still the outgoing filter type's preset"; an implementation that compares against the constructor's
#      shipped defaults instead would freeze the band at FLOW's numbers.
# Plus a save/load round-trip, because the preset hook fires on every `kind` assignment INCLUDING the one
# ResourceLoader makes while deserialising, and an authored band that does not survive that is worse than
# no presets at all.
func _gate_be_presets() -> void:
	print("[BE] filter type presets apply to untouched bands and never to edited ones:")

	# Every filter type, from a fresh selector, re-defaults to its own preset.
	var wrong := 0
	for kind in range(7):
		var s := Pasture3DReliefSelector.new()
		s.filter_type = kind
		var want: Array = Pasture3DReliefSelector.PRESETS[kind]
		var got := _band(s)
		if not _bands_equal(got, want):
			wrong += 1
			print("    !! %s got %s, preset is %s" % [KIND_NAMES[kind], got, want])
	print("    fresh selector -> each of the 7 filter types lands on its own preset: %d wrong" % wrong)
	if wrong > 0:
		_fail += 1

	# ALTITUDE is the filter type that keeps today's band (§21.10 decision 1). Stated as its own check because
	# "it has no preset" and "its preset is the shipped band" are different implementations with the same
	# first hop, and only the second lets a LATER filter type change re-default.
	var alt := Pasture3DReliefSelector.new()
	alt.filter_type = K_ALTITUDE
	print("    ALTITUDE keeps the shipped band: %s (want [25, 90, 10, 10, 0])" % [_band(alt)])
	if not _bands_equal(_band(alt), [25.0, 90.0, 10.0, 10.0, 0.0]):
		_fail += 1
		print("    !! ALTITUDE was given a band of its own; §21.10 decision 1 says it keeps today's")

	# An EDITED band survives.
	var edited := Pasture3DReliefSelector.new()
	edited.range_min = 40.0
	edited.filter_type = K_FLOW
	print("    edited (range_min 40 on SLOPE) then -> FLOW: %s (want [40, 90, 10, 10, 0])" % [_band(edited)])
	if not _bands_equal(_band(edited), [40.0, 90.0, 10.0, 10.0, 0.0]):
		_fail += 1
		print("    !! an edited band was overwritten by the incoming filter type's preset")

	# CONTROL 1: edited TO the incoming filter type's own preset value.
	var trap := Pasture3DReliefSelector.new()
	trap.range_min = Pasture3DReliefSelector.PRESETS[K_FLOW][0] # 5000, which is FLOW's own range_min
	trap.filter_type = K_FLOW
	var trap_band := _band(trap)
	print("    CONTROL range_min set to FLOW's own 5000 while still SLOPE, then -> FLOW: %s" % [trap_band])
	print("             (want [5000, 90, 10, 10, 0] — edited; a re-default would read [5000, 1e+09, 2500, 0, 0])")
	if not _bands_equal(trap_band, [5000.0, 90.0, 10.0, 10.0, 0.0]):
		_fail += 1
		print("    !! 'untouched' is being decided against the INCOMING filter type, not the outgoing one")

	# CONTROL 2: two hops. The second only moves if the comparison tracks the outgoing filter type.
	var chain := Pasture3DReliefSelector.new()
	chain.filter_type = K_FLOW
	var mid := _band(chain)
	chain.filter_type = K_EROSION
	var end_band := _band(chain)
	print("    CONTROL two hops SLOPE -> FLOW %s -> EROSION %s" % [mid, end_band])
	if not _bands_equal(mid, Pasture3DReliefSelector.PRESETS[K_FLOW]):
		_fail += 1
		print("    !! the first hop did not re-default, so the second proves nothing")
	elif not _bands_equal(end_band, Pasture3DReliefSelector.PRESETS[K_EROSION]):
		_fail += 1
		print("    !! the second hop froze; 'untouched' is being compared against the shipped defaults")

	# A hand-tuned band survives being written to disk and read back — the preset hook fires on the `kind`
	# assignment ResourceLoader makes too.
	var authored := Pasture3DReliefSelector.new()
	authored.filter_type = K_CURVATURE
	authored.range_min = 0.6
	authored.range_max = 3.0
	authored.falloff_low = 0.05
	authored.falloff_high = 0.02
	authored.measure_radius = 21.0
	var path := "user://phase65_selector_roundtrip.tres"
	var saved := ResourceSaver.save(authored, path)
	var back: Pasture3DReliefSelector = null
	if saved == OK:
		back = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if back == null:
		_fail += 1
		print("    !! the round-trip could not save/load (%d); the load-order claim is untested" % saved)
	else:
		print("    save/load round-trip of a hand-tuned CURVATURE band: %s (want %s)" % [
				_band(back), _band(authored)])
		if back.filter_type != K_CURVATURE or not _bands_equal(_band(back), _band(authored)):
			_fail += 1
			print("    !! the preset hook ate an authored band while ResourceLoader was setting `kind`")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	# The property was called `kind` until it was renamed to `filter_type`. Godot DISCARDS a stored
	# property it cannot find, so without a migration every selector authored before the rename would come
	# back as Slope — the default, and so the one wrong answer that looks like nothing happened. This
	# writes the pre-rename format BY HAND (a `kind = 3` line, exactly what the shipped .tres files hold)
	# rather than trusting a fixture the new code produced.
	var legacy_path := "user://phase65_selector_legacy.tres"
	var f := FileAccess.open(legacy_path, FileAccess.WRITE)
	if f == null:
		_fail += 1
		print("    !! could not write the pre-rename fixture; the migration is untested")
	else:
		f.store_string("[gd_resource type=\"Resource\" script_class=\"Pasture3DReliefSelector\" "
			+ "load_steps=2 format=3]

"
			+ "[ext_resource type=\"Script\" path=\"res://addons/pasture_3d/connectors/pasture3d_relief_selector.gd\" "
			+ "id=\"1_sel\"]

"
			+ "[resource]
script = ExtResource(\"1_sel\")
kind = 3
range_min = 2000.0
"
			+ "range_max = 1e+09
falloff_low = 1500.0
falloff_high = 0.0
invert = false
"
			+ "strength = 1.0
")
		f.close()
		var legacy: Pasture3DReliefSelector = ResourceLoader.load(legacy_path, "",
				ResourceLoader.CACHE_MODE_IGNORE)
		if legacy == null:
			_fail += 1
			print("    !! the pre-rename fixture did not load at all")
		else:
			print(("    a pre-rename resource (`kind = 3`, a hand-tuned FLOW band) loads as filter_type %d "
					+ "with band %s") % [legacy.filter_type, _band(legacy)])
			if legacy.filter_type != K_FLOW:
				_fail += 1
				print("    !! the rename silently reverted an authored selector to Slope")
			if not _bands_equal(_band(legacy), [2000.0, 1.0e9, 1500.0, 0.0, 0.0]):
				_fail += 1
				print("    !! the band did not survive the migration")
			# CONTROL: a property that never existed must still be refused, or `_set` is swallowing
			# everything and the migration above would pass no matter what it did.
			var fresh := Pasture3DReliefSelector.new()
			var refused: bool = not fresh._set(&"no_such_property", 7)
			print("    CONTROL an unknown property is still refused: %s (want true)" % refused)
			if not refused:
				_fail += 1
				print("    !! _set accepts anything, so the migration result means nothing")
		DirAccess.remove_absolute(ProjectSettings.globalize_path(legacy_path))


# --- BF: curvature is metres of deviation, and measure_radius reaches SLOPE too --------------------
#
# Four claims, each with its own control:
#   1. On a paraboloid z = k*r^2 the one-cell curvature is EXACTLY k*vs^2 metres. CONTROL: the same
#      surface on a 2 m grid, where the metre answer must be 4x the 1 m one for the same k*vs^2 reason —
#      and the OLD 1/m units, computed here, are the same number at both spacings while the new ones are
#      not. That is the resolution-dependence §21.6 exists to kill, measured rather than asserted.
#   2. The deviation at r = 4 m and r = 16 m is k*r^2, so the ratio is 16. CONTROL: radius 0, which must
#      differ from both by the ratio the formula predicts — a radius that changes nothing is a parameter
#      in name only.
#   3. A slope band over a NOISY ramp of known mean grade converges on that grade as the radius grows.
#      CONTROL: radius 0 on the same ground, which must be far off it.
#   4. measure_radius = 0 reproduces the SLOPE field BITWISE, sandwiched against the gate's own central
#      differences. CONTROL: the same sandwich at radius 16, which must open.
func _gate_bf_curvature_and_radius() -> void:
	print("\n[BF] curvature is metres of deviation over measure_radius, and the radius reaches SLOPE:")

	var probe := (BG_W / 2) * BG_W + (BG_W / 2 + 24) # off-centre, so the ring is not symmetric about a peak
	var px := float(probe % BG_W) * BG_CELL
	var pz := float(probe / BG_W) * BG_CELL

	# 1 — one cell, at two spacings.
	var z1 := _dome(BG_W, BG_CELL)
	var one_cell := _read_value(z1, BG_W, BG_CELL, K_CURVATURE, 0.0, probe)
	var want_one := DOME_K * BG_CELL * BG_CELL
	print("    one-cell curvature on z = %s*r^2 at %.0f m spacing: %.6f m (maths says %.6f)" % [
			String.num(DOME_K, 4), BG_CELL, one_cell, want_one])
	if absf(one_cell - want_one) > 1.0e-4:
		_fail += 1
		print("    !! the one-cell curvature is not the ring mean minus the centre, in metres")

	var z2 := _dome(BG_W, BG_CELL * 2.0)
	var one_cell2 := _read_value(z2, BG_W, BG_CELL * 2.0, K_CURVATURE, 0.0, probe)
	var want_one2 := DOME_K * (BG_CELL * 2.0) * (BG_CELL * 2.0)
	print(("    CONTROL the same dome at %.0f m spacing: %.6f m (maths says %.6f — 4x, because one cell "
			+ "is 4x the area)") % [BG_CELL * 2.0, one_cell2, want_one2])
	if absf(one_cell2 - want_one2) > 1.0e-3:
		_fail += 1
		print("    !! the metre reading does not scale with the cell it is measured over")
	# And the same two numbers in the OLD 1/m units, computed here: identical at both spacings, which is
	# exactly why a band tuned at one spacing could not survive the other.
	print(("    CONTROL the old 1/m units on the same two grids: %.6f and %.6f (identical — a number that "
			+ "cannot tell 1 m ground from 2 m ground)") % [
			one_cell * 4.0 / (BG_CELL * BG_CELL), one_cell2 * 4.0 / (BG_CELL * 2.0 * BG_CELL * 2.0)])

	# 2 — two radii on the same ground.
	var small := _read_value(z1, BG_W, BG_CELL, K_CURVATURE, R_SMALL, probe)
	var large := _read_value(z1, BG_W, BG_CELL, K_CURVATURE, R_LARGE, probe)
	var want_small := DOME_K * R_SMALL * R_SMALL
	var want_large := DOME_K * R_LARGE * R_LARGE
	print("    deviation at r = %.0f m: %.4f m (maths says %.4f) | at r = %.0f m: %.4f m (maths says %.4f)"
			% [R_SMALL, small, want_small, R_LARGE, large, want_large])
	# The discrete ring is a band one cell wide, so its mean of d^2 is r^2 only to within that width.
	if absf(small - want_small) > 0.05 * want_small or absf(large - want_large) > 0.05 * want_large:
		_fail += 1
		print("    !! the deviation is not k*r^2; the ring is not being measured at the radius asked for")
	var ratio := large / small if small != 0.0 else 0.0
	print("    ratio r=%.0f / r=%.0f = %.3f (maths says %.3f)" % [
			R_LARGE, R_SMALL, ratio, (R_LARGE * R_LARGE) / (R_SMALL * R_SMALL)])
	print(("    CONTROL radius 0 on the same cell reads %.6f m — %.0fx smaller than r = %.0f m, which is "
			+ "what k*r^2 predicts (%.0fx)") % [one_cell, large / one_cell if one_cell != 0.0 else 0.0,
			R_LARGE, (R_LARGE * R_LARGE) / (BG_CELL * BG_CELL)])
	if absf(one_cell - large) < 1.0e-6:
		_fail += 1
		print("    !! the radius changed nothing; measure_radius is a parameter in name only")

	# 3 — slope over a noisy ramp.
	#
	# A wide central difference does not average the noise away, it OUTRUNS it: the noise contributes a
	# fixed height difference between the two samples while the baseline grows with the radius, so the
	# error in the gradient falls as 1/r. That is a statement about the DISTRIBUTION, and one cell is not
	# a distribution — at r = 16 m a single cell still sits a degree or two off the true grade. So the
	# criterion is the MEDIAN measured slope across the whole grid, found by bisecting the band edge that
	# half the cells pass, and the per-cell spread is reported through the +/-2 deg band beside it.
	var grade := 0.20 # 20% => 11.31 degrees
	var want_deg := rad_to_deg(atan(grade))
	var ramp := _noisy_ramp(BG_W, BG_CELL, grade, 1.0)
	var med0 := _median_value(ramp, BG_W, BG_CELL, K_SLOPE, 0.0)
	var med16 := _median_value(ramp, BG_W, BG_CELL, K_SLOPE, R_LARGE)
	var band := _sel(K_SLOPE, want_deg - 2.0, want_deg + 2.0, 0.0, 0.0, 0.0)
	var band16 := _sel(K_SLOPE, want_deg - 2.0, want_deg + 2.0, 0.0, 0.0, R_LARGE)
	var f0 := _fraction(_field(ramp, BG_W, BG_CELL, [band]), 0.5)
	var f16 := _fraction(_field(ramp, BG_W, BG_CELL, [band16]), 0.5)
	print(("    noisy %.0f%% ramp (true grade %.2f deg): median slope %.2f deg at one cell, %.2f deg at "
			+ "r = %.0f m") % [grade * 100.0, want_deg, med0, med16, R_LARGE])
	print(("    a +/-2 deg band on the true grade passes %.1f%% of the grid at one cell, %.1f%% at "
			+ "r = %.0f m") % [100.0 * f0, 100.0 * f16, R_LARGE])
	if absf(med16 - want_deg) > 0.5 or f16 < 0.70:
		_fail += 1
		print("    !! a wide radius did not recover the ramp's real grade")
	print("    CONTROL one cell is %.2f deg off the true grade; r = %.0f m is %.2f deg off" % [
			absf(med0 - want_deg), R_LARGE, absf(med16 - want_deg)])
	if f0 > 0.5 * f16 or absf(med0 - want_deg) < 2.0:
		_fail += 1
		print("    !! the one-cell reading was already clean, so the fixture has no noise to average and "
				+ "the widening claim is untested")

	# 4 — the bitwise claim.
	var probes: Array[int] = [0, BG_W - 1, 37 * BG_W + 11, 64 * BG_W + 64, 100 * BG_W + 92,
			(BG_W - 1) * BG_W + BG_W - 1]
	var own := _slope_field(ramp, BG_W, BG_CELL)
	var tight := 0
	var opened := 0
	for i in probes:
		if _passes_at(ramp, BG_W, BG_CELL, K_SLOPE, 0.0, i, own[i]) \
				and not _passes_at(ramp, BG_W, BG_CELL, K_SLOPE, 0.0, i, _next_f32(own[i])):
			tight += 1
	print(("    measure_radius = 0 vs the gate's own central differences: %d/%d probe cells sandwiched to "
			+ "the exact float32 (band at the value passes, band one ulp above does not)") % [
			tight, probes.size()])
	if tight != probes.size():
		_fail += 1
		print("    !! the radius-0 SLOPE field is not bit-for-bit the field it has always been")
	for i in probes:
		if not _passes_at(ramp, BG_W, BG_CELL, K_SLOPE, R_LARGE, i, own[i]) \
				or _passes_at(ramp, BG_W, BG_CELL, K_SLOPE, R_LARGE, i, _next_f32(own[i])):
			opened += 1
	print(("    CONTROL the same sandwich at r = %.0f m: %d/%d cells no longer fit it (want all of them — "
			+ "otherwise the test cannot see a changed field)") % [R_LARGE, opened, probes.size()])
	if opened != probes.size():
		_fail += 1
		print("    !! the sandwich is insensitive; the bitwise result above proves nothing")


# --- BG: every filter type's preset selects a useful fraction of real ground ------------------------------
#
# §21.5's audit turned into a standing check. One solve at the SHIPPED solver defaults, then each filter
# type's shipped band over that solve's own ground.
#
# CONTROL: the 25-90 band this phase replaces, over the same ground, which must fail for the filter types
# §21.5 measured at 0.0% and for SLOPE at the other end.
#
# THE FIXTURE IS REPORTED FIRST, because a preset selecting 0% of an empty field says nothing about the
# preset. Deposition in particular is identically zero on steep ground with a large catchment (§21.5), so
# a fixture that fails to produce any is a broken fixture and is failed as one, not silently passed.
func _gate_bg_preset_coverage() -> void:
	print("\n[BG] every filter type's preset selects between %.0f%% and %.0f%% of real ground:" % [
			100.0 * BG_MIN_FRACTION, 100.0 * BG_MAX_FRACTION])
	var z0 := _bg_fixture()
	# NOTE the solver's dict key is "diffusion"; the NODE property is `hillslope_diffusion`. Passing the
	# node's name here silently leaves diffusion at 0 — which is exactly how the first run of this gate
	# measured "deposition is impossible at shipped defaults" and nearly wrote it down as a finding.
	var solved: Dictionary = _data.erode_heightfield(z0, {
			"gw": SIM_W, "gh": SIM_W, "cell_size": SIM_CELL,
			"iterations": SHIPPED_ITERATIONS, "erosion_rate": SHIPPED_RATE,
			"diffusion": SHIPPED_DIFFUSION, "want_diagnostics": true,
		}, PackedFloat32Array())
	if int(solved.get("diffusion_substeps", 0)) < 1:
		_fail += 1
		print("    !! the solve ran with no hillslope diffusion, so deposition cannot exist and BG's "
				+ "DEPOSITION row would be a fixture artefact")
		return
	if not bool(solved.get("ok", false)):
		_fail += 1
		print("    !! the solver rejected the fixture; BG has no ground to measure")
		return
	var z1: PackedFloat32Array = solved["z"]
	var area: PackedFloat32Array = solved["flow"]
	var lake: PackedFloat32Array = solved["lake_depth"]

	# The four sim channels, built HERE from the solve rather than read back out of sim_result_build, in
	# the units the resource stores (log flow, negative erosion) — the same construction §8.2 documents.
	var res := Pasture3DSimResult.new()
	res.min_x = 0.0
	res.min_z = 0.0
	res.cell_size = SIM_CELL
	res.width = SIM_W
	res.height = SIM_W
	var n := SIM_W * SIM_W
	res.flow.resize(n)
	res.erosion.resize(n)
	res.deposition.resize(n)
	res.wetness.resize(n)
	for i in range(n):
		var d := z1[i] - z0[i]
		res.flow[i] = log(maxf(area[i], 1.0))
		res.erosion[i] = minf(d, 0.0)
		res.deposition[i] = maxf(d, 0.0)
		res.wetness[i] = maxf(lake[i], 0.0)

	# The fixture, in the units a band is written in — the gate's own reference for every filter type.
	var refs := {
		K_SLOPE: _slope_field(z1, SIM_W, SIM_CELL),
		K_ALTITUDE: z1,
		K_CURVATURE: _curvature_field(z1, SIM_W, 8.0, SIM_CELL), # CURVATURE's preset radius
		K_FLOW: _map(area, func(v): return maxf(v, 1.0)),
		K_EROSION: _map_i(n, func(i): return maxf(z0[i] - z1[i], 0.0)),
		K_DEPOSITION: _map_i(n, func(i): return maxf(z1[i] - z0[i], 0.0)),
		K_WETNESS: _map(lake, func(v): return maxf(v, 0.0)),
	}
	var degenerate := 0
	for kind in refs.keys():
		var r: PackedFloat32Array = refs[kind]
		var lo := _min_of(r)
		var hi := _max_of(r)
		print("    fixture %-11s %12s .. %-12s median %s  p90 %s" % [KIND_NAMES[kind],
				String.num(lo, 3), String.num(hi, 3),
				String.num(_percentile(r, 0.5), 3), String.num(_percentile(r, 0.9), 3)])
		if hi - lo <= 0.0:
			degenerate += 1
	if degenerate > 0:
		_fail += 1
		print(("    !! %d of the 7 fields are constant on this fixture; their preset result would be "
				+ "vacuous. Fix the fixture, do not relax the criterion.") % degenerate)
		return

	var bad := 0
	var control_failures := 0
	for kind in refs.keys():
		var p: Array = Pasture3DReliefSelector.PRESETS[kind]
		var preset := _sel(kind, p[0], p[1], p[2], p[3], p[4])
		preset.sim_result = res
		var frac := _fraction(_field(z1, SIM_W, SIM_CELL, [preset], res), 0.5)
		# CONTROL: the band this phase replaces, on the same filter type and the same ground.
		var old := _sel(kind, 25.0, 90.0, 10.0, 10.0, 0.0)
		old.sim_result = res
		var old_frac := _fraction(_field(z1, SIM_W, SIM_CELL, [old], res), 0.5)
		var ok := frac >= BG_MIN_FRACTION and frac <= BG_MAX_FRACTION
		var old_ok := old_frac >= BG_MIN_FRACTION and old_frac <= BG_MAX_FRACTION
		print("    %-11s preset %-34s selects %6.2f%%   %s   | CONTROL 25-90 selects %6.2f%% %s" % [
				KIND_NAMES[kind], "[%s..%s f %s/%s r %s]" % [String.num(p[0], 2), String.num(p[1], 2),
				String.num(p[2], 2), String.num(p[3], 2), String.num(p[4], 1)],
				100.0 * frac, "ok" if ok else "!!", 100.0 * old_frac, "(also ok)" if old_ok else "(fails)"])
		if not ok:
			bad += 1
		if not old_ok:
			control_failures += 1
	if bad > 0:
		_fail += 1
		print("    !! %d preset(s) are outside the usable band; §21.5's audit has rotted" % bad)
	print(("    CONTROL the 25-90 band fails on %d of the 7 filter types (want at least 3 — §21.5 measured "
			+ "CURVATURE, WETNESS and DEPOSITION at 0.0%% and SLOPE at 93.7%%)") % control_failures)
	if control_failures < 3:
		_fail += 1
		print("    !! the old band is nearly as good here, so this fixture cannot tell a preset from a "
				+ "shipped default and BG is not measuring what it claims")


# --- BH: an inverted band is refused, not silently empty -------------------------------------------
#
# CONTROL: the same selector the right way round, which must NOT warn — and must gate something, or the
# warning is the only thing being tested.
func _gate_bh_inverted_band() -> void:
	print("\n[BH] an inverted band raises a configuration warning on the brush that owns it:")

	var mat := Pasture3DReliefFractal.new()
	mat.feature_size = 20.0
	var sel := Pasture3DReliefSelector.new()
	sel.filter_type = K_SLOPE
	sel.range_min = 60.0
	sel.range_max = 20.0 # inverted
	sel.falloff_low = 0.0
	sel.falloff_high = 0.0
	mat.selector = sel

	var plow = _make_plow("InvertedBand", SITE_BAND)
	if plow == null:
		return
	plow.source = Pasture3DPlow.Source.RELIEF
	plow.relief = mat
	plow.height_scale = 6.0
	var warned := _warns_about_band(plow)
	print("    Plow with a 60..20 band: %s" % ("warns" if warned else "SILENT"))
	if not warned:
		_fail += 1
		print("    !! an inverted band is silently accepted on a brush")

	# The same stack on a Sim, which owns selectors on its own terms (§17).
	var sim = _make_sim("InvertedBandSim", SITE_BAND + Vector3(0.0, 0.0, 200.0))
	if sim != null:
		sim.erosion_mask = [sel] as Array[Pasture3DReliefSelector]
		var sim_warned := _warns_about_band(sim)
		print("    Sim with the same band in its Erosion Mask: %s" % ("warns" if sim_warned else "SILENT"))
		if not sim_warned:
			_fail += 1
			print("    !! an inverted band is silently accepted on a Sim's mask stack")

	# CONTROL: the right way round. No warning, and it must gate something.
	sel.range_min = 20.0
	sel.range_max = 60.0
	var still := _warns_about_band(plow)
	print("    CONTROL the same band as 20..60: %s (want silent)" % ("warns" if still else "silent"))
	if still:
		_fail += 1
		print("    !! the warning fires on a valid band too, so it is not testing the inversion")

	# ...and the valid band actually gates: some of the fixture passes and some does not.
	var ramp := _noisy_ramp(BG_W, BG_CELL, 0.6, 6.0)
	var good := _fraction(_field(ramp, BG_W, BG_CELL, [_sel(K_SLOPE, 20.0, 60.0, 0.0, 0.0, 0.0)]), 0.5)
	var inverted := _fraction(_field(ramp, BG_W, BG_CELL, [_sel(K_SLOPE, 60.0, 20.0, 0.0, 0.0, 0.0)]), 0.5)
	print("    CONTROL over a %d-cell ramp 20..60 passes %.1f%%; inverted it passes %.1f%%" % [
			BG_W * BG_W, 100.0 * good, 100.0 * inverted])
	if good < 0.05 or good > 0.95:
		_fail += 1
		print("    !! the valid band does not gate anything here, so 'no warning' is all that was tested")
	if inverted != 0.0:
		_fail += 1
		print("    !! an inverted band passed something; the warning is describing the wrong failure")


# --- fixtures -------------------------------------------------------------------------------------

## z = DOME_K * r^2 about the grid centre. A paraboloid, because the mean of ANY symmetric ring at radius
## r around a point on it sits exactly k*r^2 above that point — so the deviation BF is measuring has a
## closed form the gate can state without running any of the code under test.
func _dome(p_w: int, p_cell: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_w * p_w)
	var c := float(p_w - 1) * 0.5 * p_cell
	for iz in range(p_w):
		for ix in range(p_w):
			var dx := float(ix) * p_cell - c
			var dz := float(iz) * p_cell - c
			out[iz * p_w + ix] = DOME_K * (dx * dx + dz * dz)
	return out


## A plane of known grade with fine noise on top: the grade survives averaging over a radius, the noise
## does not. `p_amp` is the noise amplitude in metres at ~4 m wavelength, which is what makes the one-cell
## slope reading useless and the 16 m one honest.
func _noisy_ramp(p_w: int, p_cell: float, p_grade: float, p_amp: float) -> PackedFloat32Array:
	var n := FastNoiseLite.new()
	n.seed = 90210
	n.frequency = 0.25 # ~4 m wavelength at 1 m cells
	n.fractal_octaves = 1
	var out := PackedFloat32Array()
	out.resize(p_w * p_w)
	for iz in range(p_w):
		for ix in range(p_w):
			var x := float(ix) * p_cell
			out[iz * p_w + ix] = x * p_grade + p_amp * n.get_noise_2d(x, float(iz) * p_cell)
	return out


## BG's ground before the solve: a plateau, an escarpment and a plain, with two basins in the plain.
##
## THE SHAPE IS THE FIXTURE'S WHOLE JOB, and it took several tries. A single tilted hillside makes every
## filter type ask about the same ground: everything is steep, so everything erodes, and the deposition and
## wetness channels come back identically zero (§21.5 saw the same thing on the demo site). Three zones
## give the seven filter types somewhere different to look — flat ground that deposits and floods, steep
## ground that incises, and a channel network with real catchments in between.
##
## The altitude span is a FIXTURE CHOICE and is reported as one: ALTITUDE is the filter type with no derivable
## preset (§21.10 decision 1), so BG asks whether the shipped 25-90 m band is usable on a map of this
## size, not whether it is universal.
func _bg_fixture() -> PackedFloat32Array:
	var n := FastNoiseLite.new()
	n.seed = 4711
	n.frequency = 0.004
	n.fractal_octaves = 4
	# A second, finer band. Hollows at this wavelength are what hillslope diffusion can actually fill in
	# 30 iterations at 0.15, and without it DEPOSITION is empty and its row proves nothing.
	var m := FastNoiseLite.new()
	m.seed = 815
	m.frequency = 0.03
	m.fractal_octaves = 1
	var out := PackedFloat32Array()
	out.resize(SIM_W * SIM_W)
	var span := float(SIM_W - 1) * SIM_CELL
	for iz in range(SIM_W):
		for ix in range(SIM_W):
			var x := float(ix) * SIM_CELL
			var zc := float(iz) * SIM_CELL
			var u := x / span
			var h := 20.0 + 110.0 * (1.0 - smoothstep(0.30, 0.62, u))
			# The coarse roughness is mostly on the escarpment and the plain below it; the plateau stays
			# smooth, which is what leaves it un-incised enough to deposit.
			h += 7.0 * n.get_noise_2d(x, zc) * (0.25 + 0.75 * smoothstep(0.30, 0.62, u))
			h += 3.0 * m.get_noise_2d(x, zc)
			for b: PackedFloat32Array in [PackedFloat32Array([0.78, 0.30]),
					PackedFloat32Array([0.85, 0.70])]:
				var dx: float = x - span * b[0]
				var dz: float = zc - span * b[1]
				h -= 22.0 * exp(-(dx * dx + dz * dz) / (2.0 * 34.0 * 34.0))
			out[iz * SIM_W + ix] = h
	return out


# --- reading the field through the interface that ships --------------------------------------------

## The mask field over a grid, from a stack of selectors. Same call the Sim's masks and the mask preview
## make, so BF and BG measure the shipping path rather than a private copy of it.
func _field(p_z: PackedFloat32Array, p_w: int, p_cell: float, p_sels: Array,
		p_result: Pasture3DSimResult = null) -> PackedFloat32Array:
	var block := PackedFloat32Array()
	for s: Pasture3DReliefSelector in p_sels:
		block.append_array(PackedFloat32Array(s.to_params()))
	var sim: Dictionary = {}
	if p_result != null:
		sim = {"min_x": p_result.min_x, "min_z": p_result.min_z, "cell_size": p_result.cell_size,
				"width": p_result.width, "height": p_result.height, "flow": p_result.flow,
				"erosion": p_result.erosion, "deposition": p_result.deposition,
				"wetness": p_result.wetness}
	return _data.selector_mask_field(p_z, {
			"gw": p_w, "gh": p_w, "cell_size": p_cell, "min_x": 0.0, "min_z": 0.0,
		}, block, sim)


## True when a hard band with its lower edge at `p_at` passes cell `p_index`. The mask is 1 iff the field
## value is >= that edge, so this is a single comparison against the stored value.
func _passes_at(p_z: PackedFloat32Array, p_w: int, p_cell: float, p_kind: int, p_radius: float,
		p_index: int, p_at: float) -> bool:
	var f := _field(p_z, p_w, p_cell, [_sel(p_kind, p_at, 1.0e30, 0.0, 0.0, p_radius)])
	return f.size() > p_index and f[p_index] >= 0.5


## A cell's field value, recovered by bisecting the band edge at which the mask flips. 60 halvings takes
## a [-1e4, 1e4] bracket below 1e-14, which is finer than the float32 the field is stored in.
func _read_value(p_z: PackedFloat32Array, p_w: int, p_cell: float, p_kind: int, p_radius: float,
		p_index: int) -> float:
	var lo := -10000.0
	var hi := 10000.0
	if not _passes_at(p_z, p_w, p_cell, p_kind, p_radius, p_index, lo):
		return NAN # below the bracket: the caller's fixture is not what it thinks it is
	for _i in range(60):
		var mid := (lo + hi) * 0.5
		if _passes_at(p_z, p_w, p_cell, p_kind, p_radius, p_index, mid):
			lo = mid
		else:
			hi = mid
	return lo


## The value half the cells are at or above, found by bisecting the band edge whose passing fraction is
## 0.5. A distribution-level read of the same field `_read_value` samples at one cell.
func _median_value(p_z: PackedFloat32Array, p_w: int, p_cell: float, p_kind: int,
		p_radius: float) -> float:
	var lo := -1000.0
	var hi := 1000.0
	for _i in range(50):
		var mid := (lo + hi) * 0.5
		if _fraction(_field(p_z, p_w, p_cell, [_sel(p_kind, mid, 1.0e30, 0.0, 0.0, p_radius)]), 0.5) >= 0.5:
			lo = mid
		else:
			hi = mid
	return lo


## The next representable float32 above `p_v`, by incrementing the stored bit pattern. Used to prove the
## field is bit-for-bit a value rather than merely close to it.
func _next_f32(p_v: float) -> float:
	var a := PackedFloat32Array([p_v])
	var bytes := a.to_byte_array()
	var bits := bytes.decode_u32(0)
	bits += 1 # p_v is positive and finite in every call site here, so +1 walks upward
	bytes.encode_u32(0, bits)
	return bytes.to_float32_array()[0]


# --- the gate's own reference fields ---------------------------------------------------------------

## Slope in degrees, central differences with clamped edges. Written here so BF never asks the code under
## test what the right answer is.
func _slope_field(p_z: PackedFloat32Array, p_w: int, p_cell: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_w * p_w)
	var inv2 := 1.0 / (2.0 * p_cell)
	for iz in range(p_w):
		var row := iz * p_w
		var zm := maxi(iz - 1, 0) * p_w
		var zp := mini(iz + 1, p_w - 1) * p_w
		for ix in range(p_w):
			var xm := maxi(ix - 1, 0)
			var xp := mini(ix + 1, p_w - 1)
			var gx := (p_z[row + xp] - p_z[row + xm]) * inv2
			var gz := (p_z[zp + ix] - p_z[zm + ix]) * inv2
			out[row + ix] = rad_to_deg(atan(sqrt(gx * gx + gz * gz)))
	return out


## Metres of deviation over `p_radius`: the mean of the ring of cells at that radius, minus the centre.
## The gate's own stencil, from §21.6's definition rather than from the implementation.
func _curvature_field(p_z: PackedFloat32Array, p_w: int, p_radius: float,
		p_cell: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_w * p_w)
	var rr := maxi(1, int(ceil(p_radius / p_cell)))
	var dxs := PackedInt32Array()
	var dzs := PackedInt32Array()
	for dz in range(-rr, rr + 1):
		for dx in range(-rr, rr + 1):
			if absf(sqrt(float(dx * dx + dz * dz)) * p_cell - p_radius) <= p_cell * 0.5:
				dxs.append(dx)
				dzs.append(dz)
	for iz in range(p_w):
		for ix in range(p_w):
			var acc := 0.0
			for i in range(dxs.size()):
				acc += p_z[clampi(iz + dzs[i], 0, p_w - 1) * p_w + clampi(ix + dxs[i], 0, p_w - 1)]
			out[iz * p_w + ix] = acc / float(dxs.size()) - p_z[iz * p_w + ix]
	return out


# --- small helpers ---------------------------------------------------------------------------------

func _sel(p_kind: int, p_lo: float, p_hi: float, p_f_lo: float, p_f_hi: float,
		p_radius: float) -> Pasture3DReliefSelector:
	var s := Pasture3DReliefSelector.new()
	# First: a filter type change re-defaults an untouched band (§21.5), so everything else follows it.
	s.filter_type = p_kind
	s.range_min = p_lo
	s.range_max = p_hi
	s.falloff_low = p_f_lo
	s.falloff_high = p_f_hi
	s.measure_radius = p_radius
	return s


func _band(p_s: Pasture3DReliefSelector) -> Array:
	return [p_s.range_min, p_s.range_max, p_s.falloff_low, p_s.falloff_high, p_s.measure_radius]


func _bands_equal(p_a: Array, p_b: Array) -> bool:
	for i in range(5):
		if not is_equal_approx(float(p_a[i]), float(p_b[i])):
			return false
	return true


## Fraction of cells whose mask weight is at least `p_at_least`.
func _fraction(p_f: PackedFloat32Array, p_at_least: float) -> float:
	if p_f.is_empty():
		return 0.0
	var c := 0
	for v in p_f:
		if v >= p_at_least:
			c += 1
	return float(c) / float(p_f.size())


func _min_of(p_a: PackedFloat32Array) -> float:
	var m := INF
	for v in p_a:
		m = minf(m, v)
	return m


func _max_of(p_a: PackedFloat32Array) -> float:
	var m := -INF
	for v in p_a:
		m = maxf(m, v)
	return m


func _percentile(p_a: PackedFloat32Array, p_q: float) -> float:
	var s := p_a.duplicate()
	s.sort()
	return s[clampi(int(p_q * float(s.size() - 1)), 0, s.size() - 1)]


func _map(p_a: PackedFloat32Array, p_fn: Callable) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_a.size())
	for i in range(p_a.size()):
		out[i] = p_fn.call(p_a[i])
	return out


func _map_i(p_n: int, p_fn: Callable) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_n)
	for i in range(p_n):
		out[i] = p_fn.call(i)
	return out


## True when this node's configuration warnings mention an inverted band. Matched on the phrase both hosts
## share rather than on the whole sentence, which differs by host on purpose.
func _warns_about_band(p_node) -> bool:
	for w in p_node._get_configuration_warnings():
		if String(w).findn("Range Min above Range Max") >= 0:
			return true
	return false


func _make_plow(p_name: String, p_site: Vector3):
	var plow := Pasture3DPlow.new()
	plow.name = p_name
	_root.add_child(plow)
	plow.terrain = _terrain
	plow.global_position = p_site
	plow._layer_owner = "pasture3d_brush:Relief_%s" % p_name
	_add_loop(plow, LOOP_HALF)
	return plow


func _make_sim(p_name: String, p_site: Vector3):
	var sim := Pasture3DSim.new()
	sim.name = p_name
	_root.add_child(sim)
	sim.terrain = _terrain
	sim.global_position = p_site
	sim.snap_to_surface = false
	sim._layer_owner = "pasture3d_brush:Erosion_%s" % p_name
	_add_loop(sim, LOOP_HALF)
	return sim


func _add_loop(p_node, p_half: float) -> void:
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	c.add_point(Vector3(-p_half, 0.0, -p_half))
	c.add_point(Vector3(p_half, 0.0, -p_half))
	c.add_point(Vector3(p_half, 0.0, p_half))
	c.add_point(Vector3(-p_half, 0.0, p_half))
	c.closed = true
	path.curve = c
	p_node.add_child(path)
