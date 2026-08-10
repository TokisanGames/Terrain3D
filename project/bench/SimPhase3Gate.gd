# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Phase 3 gate L for Pasture3DSim (PASTURE3D_SIM_NODE_SPEC.md §14): the relief selector Kinds FLOW,
# EROSION, DEPOSITION and WETNESS.
#
# The whole phase is one claim — "a relief material can be gated on what the erosion sim did" — so it is
# one gate letter with seven criteria under it, the way E1/E2 sit under E. Every one drives a REAL
# Pasture3DSim and a REAL Pasture3DPlow on the demo terrain and measures a height delta, because "the
# selector compiles" and "the ground moved where the water goes" are different claims and only the
# second ships. Same discipline as bench/PlowReliefCheck.tscn's gate K, whose structure L1 borrows.
#
#   L1  a FLOW gate confines relief to the channels          control: strength 0 brings the ridges back
#   L2  all four Kinds are actually wired to the evaluator   control: the admit-nothing band per Kind
#   L3  FLOW's band is in m2, NOT in log units               control: a band of plausible log values
#   L4  EROSION reads as a POSITIVE depth                    control: the resource's own negative sign
#   L5  outside the result's extent the gate is a defined 0  control: the same brush inside it
#   L6  native and GDScript agree with a sim gate active     control: the relief is not flat
#   L7  a sim-gated bake does not drift on re-bake           control: L1 proved the bake is not a no-op
#
# L3 and L4 are the two that exist because of a unit conversion nobody can see. The resource stores
# log(area) and a negative delta; a selector band is written in m2 and in positive metres, and the
# conversion happens in TWO places that must agree (Pasture3DPlow._sim_fields and relief_fields_add_sim).
# If either were dropped the material would still gate, still look plausible, and be keyed on the wrong
# numbers by a factor of e.
#
# NOTHING IS SAVED. Bakes write into the terrain's in-memory layer, and the Sim Result is created
# without a file, so demo/data on disk is untouched.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/SimPhase3Gate.tscn
extends Node

const DEMO_DATA := "res://demo/data"

## The eroded area. Large enough that the sim carves a real channel network inside it, and clear of the
## sites bench/SimPhase2Gate.tscn uses (this runs in its own process, but a shared site is a trap
## waiting for whoever merges the two).
const SITE_SIM := Vector3(512.0, 0.0, 200.0)
const SIM_HALF := 150.0
const SIM_MARGIN := 64.0
## The plow sits well inside the sim's loop, so every probe is in ground the sim actually wrote to.
const PLOW_HALF := 90.0
## Clear of the sim's extent (loop + margin reaches X 186..614), for L5.
const SITE_OUTSIDE := Vector3(860.0, 0.0, 620.0)

## Probe spacing, in metres. Deliberately fine: a drainage network is one to three cells wide, so a
## 10 m grid lands on a trunk channel about four times in three hundred and the channel bin comes back
## too thin to mean anything. This was measured, not guessed.
const PROBE_STEP := 4.0
const PROBE_HALF := 20 # probes each way from the site
## Where the channel and ridge bins are cut, as PERCENTILES of the probes' own catchment areas rather
## than as fixed areas in m2. The absolute numbers depend entirely on where the loop sits and how much
## upslope feeds it, so a hardcoded threshold is a statement about this site and not about the selector;
## a percentile populates both bins by construction and still gets asserted below in case it does not.
## The channel cut is ALSO the selector band's floor, so the gate compares the same population it gates.
const CHANNEL_PCT := 0.95
const RIDGE_PCT := 0.50
## Native vs GDScript, same tolerance PlowReliefCheck uses.
const PARITY_TOL := 1.0e-4

var _fail := 0
var _root: Node3D
var _terrain
var _data
var _result: Pasture3DSimResult
## The same area at PREVIEW resolution, kept only for L6: its cells do not line up with the bake grid,
## which is what makes a parity comparison actually exercise the two bilinear samplers.
var _coarse: Pasture3DSimResult
## Probe points inside the plow loop, and their catchment areas from the Sim Result.
var _probes: Array[Vector3] = []
var _areas: Array[float] = []
## Height of every probe before any plow bake — every delta below is against this.
var _base: Array[float] = []
## The bin cuts, in m2, taken from the probes' own catchment distribution in _erode().
var _channel_m2 := 0.0
var _ridge_m2 := 0.0
## Per-probe values of all four channels, indexed [Kind - FLOW][probe], in band units.
var _ch: Array[PackedFloat32Array] = []


func _ready() -> void:
	print("\n=== Pasture3DSim phase 3 (spec §14 gate L: the sim relief selectors) ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_data = _terrain.data
	if _data == null or not _data.has_method("sim_result_build"):
		_fail += 1
		print("!! this build has no sim_result_build — phases 2-3 are unbuilt, not failing")
		_done()
		return
	if Pasture3DReliefSelector.Kind.size() < 7:
		_fail += 1
		print("!! Pasture3DReliefSelector has no sim Kinds — phase 3 is unbuilt, not failing")
		_done()
		return

	if not _erode():
		_done()
		return
	_gate_l1_flow_gates_relief()
	_gate_l2_all_kinds_wired()
	_gate_l3_flow_band_is_area()
	_gate_l4_erosion_is_positive()
	_gate_l5_outside_extent()
	_gate_l6_parity()
	_gate_l7_no_drift()

	_done()


func _done() -> void:
	print("\n=== %s (%d failures) ===\n" % ["SIM PHASE 3 PASS" if _fail == 0 else "SIM PHASE 3 FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


## Run the sim once, and bin a grid of probes by the catchment area its masks report. Everything below
## reuses this: the erosion is the fixture, and re-running it per criterion would only be slower.
func _erode() -> bool:
	print("[fixture] eroding a %.0f m area and binning probes by catchment:" % (SIM_HALF * 2.0))
	if not is_finite(_height(SITE_SIM)):
		_fail += 1
		print("    !! no terrain at %s; the fixture is outside demo/data" % SITE_SIM)
		return false
	var sim := Pasture3DSim.new()
	sim.name = "Phase3Sim"
	_root.add_child(sim)
	sim.terrain = _terrain
	sim.global_position = SITE_SIM
	sim.catchment_margin = SIM_MARGIN
	sim.iterations = 30
	sim.erosion_rate = 0.1
	sim.hillslope_diffusion = 2.0
	sim.falloff_width = 24.0
	sim.snap_to_surface = false
	_add_loop(sim, SIM_HALF)
	# The coarse pass first, and DUPLICATED, because the node rewrites the same resource object on every
	# bake — holding a reference to it and re-simulating would silently replace what L6 is comparing
	# against. The build-resolution pass afterwards is what leaves the terrain in its final state.
	if bool(sim.simulate_now(3, false).get("ok", false)) and sim.sim_result != null:
		_coarse = sim.sim_result.duplicate(true)
	var rep: Dictionary = sim.simulate_now(1, false)
	if not bool(rep.get("ok", false)):
		_fail += 1
		print("    !! the simulation did not run: %s" % rep.get("reason", "?"))
		return false
	_result = sim.sim_result
	if _result == null or not _result.is_valid():
		_fail += 1
		print("    !! the sim wrote no masks; phase 3 has nothing to read")
		return false
	print("    %s" % _result.describe())

	var vs: float = _terrain.vertex_spacing
	for i in range(-PROBE_HALF, PROBE_HALF + 1):
		for j in range(-PROBE_HALF, PROBE_HALF + 1):
			_probes.append(Vector3(snappedf(SITE_SIM.x + i * PROBE_STEP, vs), 0.0,
					snappedf(SITE_SIM.z + j * PROBE_STEP, vs)))
	# Every channel at every probe, in the units a band is written in — the same conversion the brush
	# does. L2 needs these to predict which probes a given Kind and band SHOULD select.
	for k in range(4):
		_ch.append(PackedFloat32Array())
	for p in _probes:
		_areas.append(_result.drainage_area_at(p))
		_ch[0].append(_result.drainage_area_at(p))
		_ch[1].append(maxf(-_result.sample(Pasture3DSimResult.Channel.EROSION, p), 0.0))
		_ch[2].append(maxf(_result.sample(Pasture3DSimResult.Channel.DEPOSITION, p), 0.0))
		_ch[3].append(maxf(_result.sample(Pasture3DSimResult.Channel.WETNESS, p), 0.0))
	for k in range(4):
		print("    %-11s median %.4f | p75 %.4f | p95 %.4f | max %.4f" % [
				_kind_name(k + Pasture3DReliefSelector.Kind.FLOW),
				_pct(_ch[k], 0.50), _pct(_ch[k], 0.75), _pct(_ch[k], 0.95), _pct(_ch[k], 1.0)])
	var sorted := _areas.duplicate()
	sorted.sort()
	_channel_m2 = sorted[int(float(sorted.size()) * CHANNEL_PCT)]
	_ridge_m2 = sorted[int(float(sorted.size()) * RIDGE_PCT)]
	var channel := 0
	var ridge := 0
	for a in _areas:
		if a >= _channel_m2:
			channel += 1
		elif a <= _ridge_m2:
			ridge += 1
	print("    catchment over %d probes: median %.0f m2, p95 %.0f m2, max %.0f m2" % [
			_probes.size(), _ridge_m2, _channel_m2, sorted[sorted.size() - 1]])
	print("    bins: %d channel (>= %.0f m2), %d ridge (<= %.0f m2)" % [
			channel, _channel_m2, ridge, _ridge_m2])
	if channel < 20 or ridge < 20:
		_fail += 1
		print("    !! the site does not span both catchment bands; L1 could not measure anything here")
		return false
	# The separation has to be real, not just ordinal: if the p95 cell drains barely more than the median
	# one, the sim carved no network here and every criterion below would be comparing two samples of the
	# same hillslope.
	if _channel_m2 < _ridge_m2 * 8.0:
		_fail += 1
		print("    !! the channel and ridge bins are not meaningfully different catchments")
		return false
	_base = _snapshot(_probes)
	return true


# --- L1: a FLOW gate confines relief to the channels ---------------------------------------------
# The claim §9 is for: "boulders and roughness only in channels". Bin by the sim's own flow channel and
# compare populations, rather than hand-picking one channel and one ridge probe, which invites a lucky
# result.
# CONTROL: selector strength 0 means "no gating at all", so the SAME material must now cover the ridges
# too. Without it the alternative explanation stands — that the fractal simply happens to be near zero
# wherever the ridge probes landed.
func _gate_l1_flow_gates_relief() -> void:
	print("\n[L1] a FLOW selector confines relief to the channels:")
	var plow = _make_plow("FlowGate")
	if plow == null:
		return
	var sel := _sim_selector(Pasture3DReliefSelector.Kind.FLOW, _channel_m2, 1.0e9)
	sel.falloff_low = 0.0
	var mat := _fractal(sel)
	plow.relief = mat

	var gated := _bake_and_bin(plow)
	print("    gated:   mean |relief| channel %.4f m | ridge %.4f m" % [gated[0], gated[1]])
	if gated[0] < 0.2:
		_fail += 1
		print("    !! the gated material stamped nothing even in the channels")
	if gated[1] > gated[0] * 0.35:
		_fail += 1
		print("    !! the ridges got comparable relief; the FLOW selector is not gating")

	# CONTROL
	sel.strength = 0.0
	var open := _bake_and_bin(plow)
	print("    CONTROL ungated: mean |relief| channel %.4f m | ridge %.4f m" % [open[0], open[1]])
	if open[1] < gated[1] * 2.0 or open[1] < 0.2:
		_fail += 1
		print("    !! ungating did not bring the ridges back; the gated result proves nothing")
	_clear(plow)


# --- L2: each Kind reads ITS OWN channel ----------------------------------------------------------
# One Kind working does not mean four are wired: the value has to be sampled, converted, carried into
# ReliefSample and picked out again by kind id, in two implementations. A typo in any one of those
# branches leaves that Kind reading whatever the previous branch left behind.
#
# The obvious form of this test does not work, and it is worth writing down why, because it PASSED. Bake
# each Kind with a band admitting everything and again with one admitting nothing, and require the two to
# differ: all four Kinds then return byte-identical numbers, because "admit everything" is the ungated
# material whatever it reads. A Kind wired to the wrong channel passes. A Kind wired to a channel that is
# CONSTANTLY ZERO passes too — and at the first site this gate used, DEPOSITION and WETNESS were exactly
# that, so two of the four criteria were measuring a field of zeros and reporting success.
#
# So: read the channel out of the resource here, pick the band from that channel's OWN distribution, and
# predict which probes it should select. Relief must land on the predicted cells and nowhere else. If
# DEPOSITION were reading wetness the predicted set would not be the set that got stamped, and both
# halves would fail. The fixture also has to prove the channel is not flat before it can conclude
# anything, which is what the earlier form never did.
func _gate_l2_all_kinds_wired() -> void:
	print("\n[L2] each Kind reads its own channel (band taken from that channel's distribution):")
	var plow = _make_plow("AllKinds")
	if plow == null:
		return
	for k in range(4):
		var kind: int = k + Pasture3DReliefSelector.Kind.FLOW
		var vals: PackedFloat32Array = _ch[k]
		# The band floor: whatever value puts roughly the top 30 probes inside it. Taken from the channel
		# rather than chosen, so the criterion adapts to a channel that is sparse (deposition, wetness)
		# without becoming a different test.
		var t := _pct(vals, 1.0 - 30.0 / float(vals.size()))
		var n_in := 0
		for v in vals:
			if v >= t:
				n_in += 1
		if t <= 0.0 or n_in < 10 or n_in > vals.size() / 2:
			_fail += 1
			print("    %-11s !! too flat at this site to gate on (band floor %.4f, %d of %d probes in)" % [
					_kind_name(kind), t, n_in, vals.size()])
			continue
		plow.relief = _fractal(_sim_selector(kind, t, 1.0e9))
		plow._refresh_owner(plow._layer_owner, false, [])
		var hit := 0.0
		var miss := 0.0
		var n_out := 0
		for i in range(_probes.size()):
			var d := absf(_height(_probes[i]) - _base[i])
			if vals[i] >= t:
				hit += d
			else:
				miss += d
				n_out += 1
		hit /= maxf(float(n_in), 1.0)
		miss /= maxf(float(n_out), 1.0)
		print("    %-11s band >= %-10.4f | on the %d predicted cells %.4f m | on the other %d %.4f m" % [
				_kind_name(kind), t, n_in, hit, n_out, miss])
		if hit < 0.2:
			_fail += 1
			print("      !! nothing was stamped where this channel says it should be")
		# Correct code puts EXACTLY 0.0000 here — the falloffs are zero, so a probe outside the band gets
		# a selector value of 0 and no relief at all. The tolerance is only for a probe sitting on the
		# band edge, and it is deliberately far below the 0.05 that a single cross-wired Kind produced.
		if miss > 0.02:
			_fail += 1
			print("      !! relief landed where this channel says it should not; the Kind is reading")
			print("         something other than its own channel")
	_clear(plow)


# --- L3: FLOW's band is in m2, not in log units ---------------------------------------------------
# The resource stores log(area) because the range spans decades (§8.2). A selector band is written in
# m2 of catchment, so somebody has to exp() it, and that somebody is the brush — twice, once per raster
# path. If either dropped the conversion the material would still gate, still look like channels, and be
# keyed on numbers a factor of e wrong.
#
# The two bands here are the test and its own control, and they are INVERSES of one another. On correct
# code the m2 band lights the channels and the log-valued band selects nothing at all (no cell drains
# 8 to 13 square metres once the floor is a whole cell). If the conversion were missing, exactly the
# opposite would happen — which is a much stronger statement than "the number looks about right".
func _gate_l3_flow_band_is_area() -> void:
	print("\n[L3] a FLOW band is read as m2 of catchment, not as log units:")
	var plow = _make_plow("FlowUnits")
	if plow == null:
		return
	var biggest := _max_area()
	print("    the masks' largest catchment here is %.0f m2, i.e. log %.2f" % [biggest, log(biggest)])
	var sel := _sim_selector(Pasture3DReliefSelector.Kind.FLOW, _channel_m2, 1.0e9)
	plow.relief = _fractal(sel)
	var as_area := _bake_and_bin(plow)
	print("    band %.0f..1e9 (m2):     channel %.4f m | ridge %.4f m" % [
			_channel_m2, as_area[0], as_area[1]])
	if as_area[0] < 0.2:
		_fail += 1
		print("    !! an m2 band selected nothing; the values reaching the gate are not areas")

	# CONTROL — the same band written as the LOG values the resource actually stores. The two hypotheses
	# are exact inverses of one another, which is what makes this sharp:
	#
	#   correct  a band of 8..13 is 8..13 SQUARE METRES, so it picks out hillslope cells and leaves the
	#            trunks alone — it selects plenty of ground, just not the channels
	#   bug      a band of 8..13 is 8..13 LOG UNITS, i.e. 3 000..442 000 m2, so it picks out exactly the
	#            trunks, and the m2 band above would have selected nothing at all
	#
	# So the criterion is that the log-valued band must NOT light up the channel bin, and the evidence
	# that it is live at all is that it stamps somewhere.
	sel.range_min = 8.0
	sel.range_max = 13.0
	var as_log := _bake_and_bin(plow)
	var log_all := _mean_abs(_probes, _base)
	print("    CONTROL band 8..13 (log units): channel %.4f m (want ~0) | everywhere %.4f m (want > 0)" % [
			as_log[0], log_all])
	if as_log[0] > 0.01:
		_fail += 1
		print("    !! a band of log values lit up the channels; the gate compares against raw logarithms")
	if log_all < 0.01:
		_fail += 1
		print("    !! the control band selected nothing anywhere, so it cannot distinguish the two cases")
	_clear(plow)


# --- L4: EROSION reads as a positive depth ---------------------------------------------------------
# The channel stores a NEGATIVE delta, because erosion and deposition are the two signs of one field
# (§8.2). A band reading "-50 to -5" is a terrible way to say "between 5 and 50 metres were stripped",
# so the brush flips it on the way in. Same shape of test as L3: the positive band must select, and the
# band written in the resource's own sign must select nothing.
func _gate_l4_erosion_is_positive() -> void:
	print("\n[L4] an EROSION band is read as a positive depth removed:")
	var plow = _make_plow("ErosionSign")
	if plow == null:
		return
	var deepest := -_min_of(_result.erosion)
	print("    the masks' deepest incision here is %.2f m" % deepest)
	if deepest < 2.0:
		_fail += 1
		print("    !! the sim barely eroded; L4 has no band to test")
		return
	var sel := _sim_selector(Pasture3DReliefSelector.Kind.EROSION, 2.0, 1.0e9)
	plow.relief = _fractal(sel)
	var positive := _bake_mean(plow)
	print("    band 2..1e9 (m removed): mean |relief| %.4f m" % positive)
	if positive < 0.2:
		_fail += 1
		print("    !! a positive-depth band selected nothing; erosion is not reaching the gate as a depth")

	# CONTROL — the sign the RESOURCE stores.
	sel.range_min = -1.0e9
	sel.range_max = -2.0
	var negative := _bake_mean(plow)
	print("    CONTROL band -1e9..-2 (the stored sign): mean |relief| %.4f m (want ~0)" % negative)
	if negative > 0.01:
		_fail += 1
		print("    !! the stored negative sign also selected; the gate is reading the raw channel")
	_clear(plow)


# --- L5: outside the result's extent, the gate is a defined 0 -------------------------------------
# §9 is explicit that these Kinds must return a defined 0 outside the extent and never garbage — a
# selector reading noise off the end of a mask would be close to undiagnosable. A plow well clear of
# anything the sim simulated must therefore stamp nothing at all with an admit-everything-positive band.
# CONTROL: the identical brush and material inside the extent, which must stamp. Without it this passes
# on a brush that is simply broken.
func _gate_l5_outside_extent() -> void:
	print("\n[L5] outside the masks' extent the gate reads a defined 0:")
	var b := _result.world_bounds()
	print("    the masks cover X %.0f..%.0f; the outside probe is at X %.0f" % [b[0], b[1], SITE_OUTSIDE.x])
	if SITE_OUTSIDE.x <= b[1] + PLOW_HALF:
		_fail += 1
		print("    !! the outside site is not clear of the extent; this gate would measure nothing")
		return
	var outside = _make_plow("Outside", SITE_OUTSIDE)
	if outside == null:
		return
	# A band that admits every value the channel can actually hold, but NOT the defined 0.
	var sel := _sim_selector(Pasture3DReliefSelector.Kind.FLOW, 1.5, 1.0e9)
	outside.relief = _fractal(sel)
	var probes: Array[Vector3] = []
	for i in range(-4, 5):
		for j in range(-4, 5):
			probes.append(SITE_OUTSIDE + Vector3(i * 15.0, 0.0, j * 15.0))
	var base := _snapshot(probes)
	outside._refresh_owner(outside._layer_owner, false, [])
	var out_mean := _mean_abs(probes, base)
	print("    outside: mean |relief| %.6f m (want ~0)" % out_mean)
	if out_mean > 0.01:
		_fail += 1
		print("    !! relief was stamped outside the simulated area; the gate is not reading 0 there")
	_clear(outside)

	# CONTROL — the same brush and band inside the extent.
	var inside = _make_plow("Inside")
	if inside == null:
		return
	inside.relief = _fractal(_sim_selector(Pasture3DReliefSelector.Kind.FLOW, 1.5, 1.0e9))
	var in_mean := _bake_mean(inside)
	print("    CONTROL the same brush inside the extent: mean |relief| %.4f m (want > 0.2)" % in_mean)
	if in_mean < 0.2:
		_fail += 1
		print("    !! the material stamps nothing anywhere, so 'nothing outside' proves nothing")
	_clear(inside)


# --- L6: the two raster paths agree with a sim gate active ----------------------------------------
# The repo's standing rule for relief: the native rasteriser and the GDScript oracle must agree to 1e-4 m
# on the finished height. Phase 3 adds a second implementation of the sampling AND of the two unit
# conversions, so this is where a mismatch between them shows up as a number rather than as a look.
#
# It uses the COARSE result on purpose. At build resolution the sim grid and the bake grid are both 1 m
# and corner-aligned, so every lookup lands exactly on a sample, both bilinear implementations reduce to
# picking one cell, and the parity comes back at exactly 0.00000000 without either interpolator having
# been asked a question. A preview-resolution result has no such alignment, so the two interpolators are
# genuinely compared — which is the only reason this criterion exists.
func _gate_l6_parity() -> void:
	print("\n[L6] native vs the GDScript oracle with a sim selector active (tol %.6f m):" % PARITY_TOL)
	if _coarse == null or not _coarse.is_valid():
		_fail += 1
		print("    !! no coarse Sim Result; the interpolators would not be exercised")
		return
	print("    using the preview-resolution masks: %.2f m cells against a %.2f m bake grid" % [
			_coarse.cell_size, _terrain.vertex_spacing])
	if absf(_coarse.cell_size - _terrain.vertex_spacing) < 0.01:
		_fail += 1
		print("    !! the two grids align after all, so this measures no interpolation")
	var plow = _make_plow("Parity")
	if plow == null:
		return
	var sel := _sim_selector(Pasture3DReliefSelector.Kind.FLOW, _channel_m2, 1.0e9)
	sel.sim_result = _coarse
	plow.relief = _fractal(sel)
	plow.force_gdscript_raster = false
	plow._refresh_owner(plow._layer_owner, false, [])
	var native := _snapshot(_probes)
	plow.force_gdscript_raster = true
	plow._refresh_owner(plow._layer_owner, false, [])
	var worst := 0.0
	var spread := 0.0
	for i in range(_probes.size()):
		var g := _height(_probes[i])
		worst = maxf(worst, absf(g - native[i]))
		spread = maxf(spread, absf(g - _base[i]))
	print("    %d probes | worst |native - gdscript| %.8f m" % [_probes.size(), worst])
	if worst > PARITY_TOL:
		_fail += 1
		print("    !! the two paths sample or convert the sim channels differently")
	print("    CONTROL max |relief| across probes: %.4f m" % spread)
	if spread < 0.1:
		_fail += 1
		print("    !! the probes measured flat ground, so the parity result is vacuous")
	plow.force_gdscript_raster = false
	_clear(plow)


# --- L7: a sim-gated bake does not drift ------------------------------------------------------------
# The phase-1 idempotency argument, carried into phase 3. A selector reads the layers BELOW its brush,
# and now also a Sim Result, which is a stored output nothing in this bake writes. Neither can feed the
# brush's own relief back into its own mask, so a re-bake must land in exactly the same place.
func _gate_l7_no_drift() -> void:
	print("\n[L7] re-baking a sim-gated material does not drift:")
	var plow = _make_plow("Drift")
	if plow == null:
		return
	plow.relief = _fractal(_sim_selector(Pasture3DReliefSelector.Kind.FLOW, _channel_m2, 1.0e9))
	plow._refresh_owner(plow._layer_owner, false, [])
	var first := _snapshot(_probes)
	var moved := 0.0
	for i in range(_probes.size()):
		moved = maxf(moved, absf(first[i] - _base[i]))
	print("    the first bake really moved the ground: max |delta| %.4f m" % moved)
	if moved < 0.1:
		_fail += 1
		print("    !! nothing was stamped, so 'no drift' is trivially true")
		return
	plow._refresh_owner(plow._layer_owner, false, [])
	var drift := 0.0
	for i in range(_probes.size()):
		drift = maxf(drift, absf(_height(_probes[i]) - first[i]))
	print("    re-bake drift: %.8f m (tol 1e-3)" % drift)
	if drift > 1.0e-3:
		_fail += 1
		print("    !! the sim-gated bake drifts; something in the mask path reads this brush's output")
	_clear(plow)


# --- fixture helpers ---------------------------------------------------------------------------------

func _sim_selector(p_kind: int, p_min: float, p_max: float) -> Pasture3DReliefSelector:
	var s := Pasture3DReliefSelector.new()
	s.kind = p_kind
	s.range_min = p_min
	s.range_max = p_max
	s.falloff_low = 0.0
	s.falloff_high = 0.0
	s.sim_result = _result
	return s


## A craggy fractal, the same material PlowReliefCheck's selector gates use, so a difference between the
## two gate files is a difference in the selector and not in the relief.
func _fractal(p_sel: Pasture3DReliefSelector) -> Pasture3DReliefFractal:
	var mat := Pasture3DReliefFractal.new()
	mat.style = Pasture3DReliefFractal.Style.CRAGGY
	mat.feature_size = 20.0
	mat.selector = p_sel
	return mat


func _make_plow(p_name: String, p_at: Vector3 = SITE_SIM):
	if not is_finite(_height(p_at)):
		_fail += 1
		print("    !! no terrain at %s; the fixture is outside demo/data" % p_at)
		return null
	var plow := Pasture3DPlow.new()
	plow.name = p_name
	_root.add_child(plow)
	plow.terrain = _terrain
	plow.global_position = p_at
	plow.source = Pasture3DPlow.Source.RELIEF
	plow.height_scale = 8.0
	_add_loop(plow, PLOW_HALF)
	return plow


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


## Bake and return [mean |delta| over channel probes, over ridge probes], both against `_base`.
func _bake_and_bin(p_plow) -> Array:
	p_plow._refresh_owner(p_plow._layer_owner, false, [])
	var ch := 0.0
	var nch := 0
	var rg := 0.0
	var nrg := 0
	for i in range(_probes.size()):
		var d := absf(_height(_probes[i]) - _base[i])
		if _areas[i] >= _channel_m2:
			ch += d
			nch += 1
		elif _areas[i] <= _ridge_m2:
			rg += d
			nrg += 1
	return [ch / maxf(float(nch), 1.0), rg / maxf(float(nrg), 1.0)]


## Bake and return the mean |delta| over every probe.
func _bake_mean(p_plow) -> float:
	p_plow._refresh_owner(p_plow._layer_owner, false, [])
	return _mean_abs(_probes, _base)


func _mean_abs(p_probes: Array[Vector3], p_base: Array[float]) -> float:
	var total := 0.0
	for i in range(p_probes.size()):
		total += absf(_height(p_probes[i]) - p_base[i])
	return total / maxf(float(p_probes.size()), 1.0)


## Empty the brush's layer and drop it, so the next criterion measures against untouched ground.
func _clear(p_plow) -> void:
	p_plow.relief = null
	p_plow.source = Pasture3DPlow.Source.RELIEF
	p_plow._refresh_owner(p_plow._layer_owner, false, [])
	p_plow.queue_free()


## Percentile of a field, 0..1 (1.0 = the maximum).
func _pct(p_a: PackedFloat32Array, p_q: float) -> float:
	if p_a.is_empty():
		return 0.0
	var s := p_a.duplicate()
	s.sort()
	return s[clampi(int(float(s.size()) * p_q), 0, s.size() - 1)]


func _max_area() -> float:
	var m := 0.0
	for a in _areas:
		m = maxf(m, a)
	return m


func _min_of(p_a: PackedFloat32Array) -> float:
	var m := INF
	for v in p_a:
		m = minf(m, v)
	return m


func _kind_name(p_kind: int) -> String:
	match p_kind:
		Pasture3DReliefSelector.Kind.FLOW: return "FLOW"
		Pasture3DReliefSelector.Kind.EROSION: return "EROSION"
		Pasture3DReliefSelector.Kind.DEPOSITION: return "DEPOSITION"
		_: return "WETNESS"


func _snapshot(p_points: Array[Vector3]) -> Array[float]:
	var out: Array[float] = []
	for p in p_points:
		out.append(_height(p))
	return out


func _height(p_at: Vector3) -> float:
	return _data.get_height(Vector3(p_at.x, 0.0, p_at.z))
