# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gates BM–BQ for the HOST PROFILE field — phase 1 of PASTURE3D_BRUSH_EROSION_SPEC.md §4, which is also
# the phase 8 that PASTURE3D_SIM_NODE_SPEC.md §14 left unspecced and §15.10 described.
#
# The claim under test: a landform brush's relief can be gated on, and banded across, the brush's OWN
# generated shape — which on a Mound placed on flat ground is the only thing there is to grip, because
# the below-layer fields are constant and every filter type returns one weight.
#
# House discipline (see bench/PlowReliefCheck.gd): every gate measures a HEIGHT DELTA at probe points,
# never a configuration flag, and every criterion carries a CONTROL that must fail if the path is dead —
# so a run of zeros reports "measured nothing" rather than passing.
#
# NOTHING IS SAVED. Bakes write into the terrain's in-memory layer.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/HostProfileGate.tscn
extends Node

const DEMO_DATA := "res://demo/data"
const RELIEF_DIR := "res://demo/data/relief"

## One site per gate, spaced so no two brushes share ground. Each is probed finite before use.
const SITE_BM := Vector3(180.0, 0.0, 120.0)
const SITE_BN := Vector3(420.0, 0.0, 120.0)
const SITE_BO := Vector3(660.0, 0.0, 120.0)
const SITE_BP := Vector3(180.0, 0.0, 360.0)
const SITE_BQ := Vector3(420.0, 0.0, 360.0)

const PARITY_TOL := 1.0e-4
## A probe counts as carrying relief when it departs from the plain-dome bake by more than this. Well
## above the raster's own noise floor and well below any amplitude these fixtures stamp.
const RELIEF_EPS := 0.02

var _fail := 0
var _root: Node3D
var _terrain


func _ready() -> void:
	print("\n=== Host Profile (gates BM-BQ) ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA

	_gate_bm_field_excludes_relief()
	_gate_bn_flanks_against_crown()
	_gate_bo_banding_follows_the_hill()
	_gate_bp_accumulator_is_unchanged()
	_gate_bq_parity()

	print("\n=== %s (%d failures) ===\n" % ["HOST PROFILE PASS" if _fail == 0 else "HOST PROFILE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- BM: the field is the brush's own SHAPE, and carries none of its relief --------------------------
#
# The whole safety argument for this feature is that the host profile is a function of the loop and the
# shape properties ONLY, so relief keyed on it cannot feed itself and drift. That is a claim about what
# the field is DERIVED FROM, and the way to measure it through a bake is to change the relief hard and
# check that the gate does not move.
#
# An ALTITUDE band on the host profile turns relief off below a fixed height up the dome. If the field
# were taken after the relief term — the mistake the obvious implementation makes, because `vals` is
# right there — that boundary would ride up and down with the relief's own amplitude.
func _gate_bm_field_excludes_relief() -> void:
	print("[BM] the host profile field carries the shape and not the relief:")
	var mound = _make_mound("BM", SITE_BM, 60.0, 60.0)
	if mound == null:
		return
	mound.height = 40.0

	# Probes marching out from the centre, so "where does relief stop" is an index into a line.
	var probes: Array[Vector3] = []
	for i in range(24):
		probes.append(SITE_BM + Vector3(i * 2.5, 0.0, 0.0))

	var mat := Pasture3DReliefFractal.new()
	mat.style = Pasture3DReliefFractal.Style.CRAGGY
	mat.feature_size = 18.0
	mat.seed = 7
	var sel := Pasture3DTerrainMask.new()
	sel.filter_type = Pasture3DTerrainMask.FilterType.ALTITUDE
	sel.field_source = Pasture3DTerrainMask.FieldSource.HOST_PROFILE
	# Metres UP THE DOME, not world height: the field is the brush's own contribution.
	sel.range_min = 20.0
	sel.range_max = 10000.0
	sel.falloff_low = 0.0 # a hard cut, so the boundary is a single index rather than a ramp
	sel.falloff_high = 0.0
	sel.strength = 1.0
	mat.selector = sel

	# The plain dome, with the relief switched off, is what "carries relief" is measured against.
	_stack(mound, mat, 0.0)
	mound._refresh_owner(mound._layer_owner, false, [])
	var plain := _snapshot(probes)

	_relief_strength(mound, 3.0)
	mound._refresh_owner(mound._layer_owner, false, [])
	var at_1x := _snapshot(probes)
	var edge_1x := _relief_edge(plain, at_1x)
	var amp_1x := _mean_relief(plain, at_1x, 0, edge_1x)

	_relief_strength(mound, 9.0)
	mound._refresh_owner(mound._layer_owner, false, [])
	var at_3x := _snapshot(probes)
	var edge_3x := _relief_edge(plain, at_3x)
	var amp_3x := _mean_relief(plain, at_3x, 0, edge_3x)

	print("    relief stops at probe %d (strength 3 m) and probe %d (strength 9 m)" % [edge_1x, edge_3x])
	if edge_1x < 2 or edge_1x >= probes.size() - 1:
		_fail += 1
		print("    !! the band gates everything or nothing; the fixture has no boundary to measure")
	elif edge_1x != edge_3x:
		_fail += 1
		print("    !! the gate MOVED when only the relief amplitude changed — the field is being derived")
		print("       from the relief-carrying surface, so a host-keyed selector feeds itself")

	# CONTROL — tripling the strength must triple the relief inside the band. Without this, a bake that
	# stamped no relief at all would report two identical boundaries and pass.
	print("    CONTROL mean |relief| inside the band: %.4f m at 3 m, %.4f m at 9 m (want ~3x)"
			% [amp_1x, amp_3x])
	if amp_1x < RELIEF_EPS or amp_3x < amp_1x * 2.0:
		_fail += 1
		print("    !! the relief did not scale with strength; the boundary comparison measured nothing")


# --- BN: flanks against crown, and the thing that could not be said before ---------------------------
#
# "Craggy on the flanks, smooth on top" is the most natural thing to want on a hill and was not
# expressible at all: a Mound's below-layer fields are the ground it was placed on, so on flat ground
# slope is 0 everywhere and a SLOPE band returns one constant.
#
# The control is therefore not decoration — it IS §15.10, measured. The same selector on Below Layer must
# fail to separate crown from flank on the same fixture.
func _gate_bn_flanks_against_crown() -> void:
	print("\n[BN] a Host Profile slope band separates flank from crown:")
	var at := SITE_BN
	print("    site %s, below-layer slope %.2f deg" % [at, _slope_at(at)])
	var mound = _make_mound("BN", at, 55.0, 55.0)
	if mound == null:
		return
	mound.height = 45.0
	mound.capped = true
	mound.falloff_width = 30.0 # a broad flat top with a steep flank, which is what the band divides

	# Crown probes sit inside the flat cap; flank probes on the ramp. Radii chosen off the loop half-width
	# (55 m) and the falloff (30 m): the ramp runs from 25 m out to the rim.
	var crown: Array[Vector3] = []
	var flank: Array[Vector3] = []
	for a in range(8):
		var ang := TAU * float(a) / 8.0
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		crown.append(at + dir * 8.0)
		flank.append(at + dir * 40.0)
	var probes: Array[Vector3] = crown + flank

	var mat := Pasture3DReliefFractal.new()
	mat.style = Pasture3DReliefFractal.Style.CRAGGY
	mat.feature_size = 14.0
	mat.seed = 21
	var sel := Pasture3DTerrainMask.new()
	sel.filter_type = Pasture3DTerrainMask.FilterType.SLOPE
	sel.range_min = 25.0
	sel.range_max = 90.0
	sel.falloff_low = 10.0
	sel.falloff_high = 0.0
	sel.strength = 1.0
	mat.selector = sel

	_stack(mound, mat, 0.0)
	mound._refresh_owner(mound._layer_owner, false, [])
	var plain := _snapshot(probes)
	_relief_strength(mound, 4.0)

	sel.field_source = Pasture3DTerrainMask.FieldSource.HOST_PROFILE
	mound._refresh_owner(mound._layer_owner, false, [])
	var host_vals := _snapshot(probes)
	var host_crown := _mean_relief(plain, host_vals, 0, crown.size())
	var host_flank := _mean_relief(plain, host_vals, crown.size(), probes.size())
	print("    Host Profile:  mean |relief| crown %.4f m | flank %.4f m" % [host_crown, host_flank])
	if host_flank < RELIEF_EPS:
		_fail += 1
		print("    !! nothing was stamped on the flank; the band excludes the whole brush")
	elif host_crown > host_flank * 0.25:
		_fail += 1
		print("    !! the crown is not being excluded; the host slope field is not separating them")

	# CONTROL 1 — the same selector on Below Layer, which is all a Mound could do before this phase. It
	# must FAIL TO SEPARATE crown from flank: that failure is the complaint this gate closes.
	#
	# The statistic is the SEPARATION, not either mean on its own, and that is what makes the control
	# independent of what the demo ground happens to be doing. Below Layer reads the terrain under the
	# Mound, which knows nothing about where this dome's crown is: on flat ground it excludes everything,
	# on uniformly steep ground it admits everything, and either way the two bins come out alike. Only a
	# below-layer slope that happens to trace this loop's crown would separate them, and then the gate
	# says so rather than crediting the result above.
	sel.field_source = Pasture3DTerrainMask.FieldSource.BELOW_LAYER
	mound._refresh_owner(mound._layer_owner, false, [])
	var below_vals := _snapshot(probes)
	var below_crown := _mean_relief(plain, below_vals, 0, crown.size())
	var below_flank := _mean_relief(plain, below_vals, crown.size(), probes.size())
	var host_sep := absf(host_flank - host_crown)
	var below_sep := absf(below_flank - below_crown)
	print("    CONTROL Below Layer: mean |relief| crown %.4f m | flank %.4f m" % [below_crown, below_flank])
	print("    CONTROL separation: Host Profile %.4f m vs Below Layer %.4f m (Below must be far smaller)"
			% [host_sep, below_sep])
	if below_sep > host_sep * 0.5:
		_fail += 1
		print("    !! Below Layer separated crown from flank nearly as well, so this fixture's ground")
		print("       happens to trace the loop and the Host Profile result is not evidence")

	# CONTROL 2 — strength 0 is "no gating at all", so relief must cover the crown as well.
	sel.field_source = Pasture3DTerrainMask.FieldSource.HOST_PROFILE
	sel.strength = 0.0
	mound._refresh_owner(mound._layer_owner, false, [])
	var open_vals := _snapshot(probes)
	var open_crown := _mean_relief(plain, open_vals, 0, crown.size())
	print("    CONTROL gate opened (strength 0): mean |relief| crown %.4f m (was %.4f)"
			% [open_crown, host_crown])
	if open_crown < RELIEF_EPS:
		_fail += 1
		print("    !! opening the gate changed nothing; the crown probes cannot receive relief at all")


# --- BO: the strata / terraces complaint, measured ---------------------------------------------------
#
# Reported as "terrace and strata reliefs are applied over random noise when they should be applied over
# the terrain input". Structurally true: TERRACE bands `acc`, and `acc` never contains the hill, so
# Base Relief exists purely to give it something to band — and that something is a fractal.
#
# The measurable difference is SYMMETRY. A square loop's signed-distance field is symmetric through its
# centre, so on a Host Profile band two probes mirrored about the centre sit at the same profile height
# and must land on the same bench. Under the accumulator they land wherever the fractal put them.
func _gate_bo_banding_follows_the_hill() -> void:
	print("\n[BO] Host Profile banding lies on the hill's contours:")
	var mound = _make_mound("BO", SITE_BO, 55.0, 55.0)
	if mound == null:
		return
	mound.height = 40.0

	# Mirrored pairs: (d) and (-d) share a signed distance, so they share a host profile exactly.
	var pairs: Array[Vector3] = []
	for a in range(9):
		var ang := TAU * float(a) / 18.0 # half-turn's worth; the mirror supplies the rest
		for r in [12.0, 22.0, 32.0, 42.0]:
			pairs.append(SITE_BO + Vector3(cos(ang), 0.0, sin(ang)) * r)
	var probes: Array[Vector3] = []
	for p in pairs:
		probes.append(p)
		probes.append(SITE_BO * 2.0 - p) # the same point mirrored through the loop's centre

	var terr := Pasture3DReliefTerraces.new()
	terr.steps = 6
	terr.hardness = 1.0
	terr.step_jitter = 0.0
	terr.base_amount = 0.0 # the hill IS the base under Host Profile
	terr.band_source = Pasture3DReliefMaterial.BandSource.HOST_PROFILE
	_stack(mound, terr, 0.0)

	# EVERY comparison below is on the RELIEF DELTA, never on the baked height. `relative_to_terrain` is
	# on, so a baked height carries the demo ground underneath it — which at these sites is hilly enough
	# to swamp a 6 m band by an order of magnitude and would make both arms of this gate read as "not
	# symmetric". Subtracting a plain-dome bake removes the terrain and the dome together, leaving the
	# material's own output, which is the only thing the band source can be blamed for.
	var virgin := _snapshot(probes)
	_relief_strength(mound, 0.0)
	mound._refresh_owner(mound._layer_owner, false, [])
	var plain := _snapshot(probes)

	_relief_strength(mound, 6.0)

	# DIAGNOSTIC FIRST, because it decides what the headline number below means.
	#
	# With hardness 0 the TERRACE op is a pass-through — band(tx, n, 0) is tx — so the output is a LINEAR
	# ramp of the host profile, and its mirrored disagreement measures the field's own symmetry with
	# nothing amplifying it.
	#
	# That disagreement is NOT zero, and it should not be. `signed_d` comes from a chamfer (or GPU) signed
	# distance field, which is a few per cent off exact through a square loop's centre — so the dome
	# itself is slightly lopsided, and a field that faithfully IS the dome inherits exactly that and adds
	# nothing. The claim this gate can therefore make, and the stronger one, is that the two lopsidednesses
	# are the SAME lopsidedness: the relief spans 2 x strength over a profile range of `height`, so the
	# field's asymmetry must be the dome's, scaled by 2 x strength / height. A field derived from anything
	# else — the relief-carrying surface, the wrong grid, the below-layer heights — would not track it.
	var dome_asym := _mirror_spread(_deltas(virgin, plain))
	terr.hardness = 0.0
	mound._refresh_owner(mound._layer_owner, false, [])
	var linear_sym := _mirror_spread(_deltas(plain, _snapshot(probes)))
	var scale: float = 2.0 * _strength_of(mound) / maxf(mound.height, 0.001)
	var predicted := dome_asym * scale
	print("    the dome's own asymmetry (the SDF's, not this phase's): %.4f m over a %.0f m dome"
			% [dome_asym, mound.height])
	print("    the field itself (hardness 0, a linear ramp): %.4f m, predicted %.4f m from the dome"
			% [linear_sym, predicted])
	if dome_asym < 1.0e-3:
		_fail += 1
		print("    !! the dome measures perfectly symmetric, so the prediction is 0 and this comparison")
		print("       cannot distinguish a correct field from a dead one")
	elif linear_sym > predicted * 1.5 + 0.01:
		_fail += 1
		print("    !! the field is MORE lopsided than the shape it is supposed to be — it is not being")
		print("       derived from the brush's own profile")

	terr.hardness = 1.0
	mound._refresh_owner(mound._layer_owner, false, [])
	var host_vals := _deltas(plain, _snapshot(probes))
	var host_sym := _mirror_spread(host_vals)
	var host_levels := _distinct_levels(host_vals, 0.35)
	# A riser is (2 / steps) x relief_strength metres tall, because the band output spans -1..1. Landing
	# on the SAME BENCH is the claim; half a riser is the widest disagreement that can still mean that.
	var riser: float = (2.0 / float(terr.steps)) * _strength_of(mound)
	print("    Host Profile: worst mirrored-pair disagreement %.4f m over %d pairs, %d distinct benches"
			% [host_sym, pairs.size(), host_levels])
	print("    a riser is %.2f m; mirrored points must land on the same bench (< %.2f m)"
			% [riser, riser * 0.5])
	if host_sym > riser * 0.5:
		_fail += 1
		print("    !! benches are not lying on the hill's contours; two points at the same height up the")
		print("       dome landed on different benches")
	if host_levels < 3:
		_fail += 1
		print("    !! fewer than 3 distinct benches — the band collapsed, so symmetry is trivially true")

	# CONTROL — today's behaviour: band the accumulator, with the built-in fractal supplying it. The
	# benches are then a function of the NOISE, so mirrored points land on different ones. If this
	# disagreement does not show up, the fixture cannot tell the two band sources apart and the
	# measurement above means nothing.
	terr.band_source = Pasture3DReliefMaterial.BandSource.ACCUMULATOR
	terr.base_amount = 1.0
	mound._refresh_owner(mound._layer_owner, false, [])
	var acc_vals := _deltas(plain, _snapshot(probes))
	var acc_sym := _mirror_spread(acc_vals)
	print("    CONTROL Accumulator + Base Relief: worst mirrored-pair disagreement %.4f m (must be large)"
			% acc_sym)
	if acc_sym <= host_sym * 2.0:
		_fail += 1
		print("    !! the accumulator path is just as symmetric, so this fixture is not measuring")
		print("       'banded across the hill' at all")


# --- BP: every material authored before this phase bakes what it did ---------------------------------
#
# Two new enums, both defaulting to the historical behaviour. This gate holds those defaults, on fresh
# resources AND on the shipped presets, because a default that drifts silently re-shapes every scene that
# ever loaded one.
func _gate_bp_accumulator_is_unchanged() -> void:
	print("\n[BP] the historical band source and field source are the defaults:")
	var t := Pasture3DReliefTerraces.new()
	var s := Pasture3DReliefStrata.new()
	var sel := Pasture3DTerrainMask.new()
	var ok := (t.band_source == Pasture3DReliefMaterial.BandSource.ACCUMULATOR
			and s.band_source == Pasture3DReliefMaterial.BandSource.ACCUMULATOR
			and sel.field_source == Pasture3DTerrainMask.FieldSource.BELOW_LAYER)
	print("    fresh Terraces %d, Strata %d (want 0), fresh Selector field source %d (want 0)"
			% [t.band_source, s.band_source, sel.field_source])
	if not ok:
		_fail += 1
		print("    !! a new default just re-shaped every material ever authored")

	# Every shipped preset must load on the historical settings too.
	var checked := 0
	for f in _relief_presets():
		var res := ResourceLoader.load(f)
		if res == null:
			continue
		for m in _flatten(res):
			if m is Pasture3DReliefTerraces or m is Pasture3DReliefStrata:
				checked += 1
				if m.band_source != Pasture3DReliefMaterial.BandSource.ACCUMULATOR:
					_fail += 1
					print("    !! %s loads with band_source %d" % [f, m.band_source])
			if m.selector != null:
				checked += 1
				if m.selector.field_source != Pasture3DTerrainMask.FieldSource.BELOW_LAYER:
					_fail += 1
					print("    !! %s has a selector loading with field_source %d"
							% [f, m.selector.field_source])
	print("    %d banding / selector settings across the shipped presets, all historical" % checked)
	if checked < 1:
		_fail += 1
		print("    !! no presets were inspected; the migration check measured nothing")

	# CONTROL — flipping one band source must change the surface. A migration gate that cannot detect a
	# change is not testing migration.
	var mound = _make_mound("BP", SITE_BP, 45.0, 45.0)
	if mound == null:
		return
	mound.height = 30.0
	var probes: Array[Vector3] = []
	for i in range(-2, 3):
		for j in range(-2, 3):
			probes.append(SITE_BP + Vector3(i * 9.0, 0.0, j * 9.0))
	var terr := Pasture3DReliefTerraces.new()
	terr.hardness = 1.0
	terr.step_jitter = 0.0
	_stack(mound, terr, 6.0)
	mound._refresh_owner(mound._layer_owner, false, [])
	var before := _snapshot(probes)
	terr.band_source = Pasture3DReliefMaterial.BandSource.HOST_PROFILE
	terr.base_amount = 0.0
	mound._refresh_owner(mound._layer_owner, false, [])
	var after := _snapshot(probes)
	var moved := 0.0
	for i in range(probes.size()):
		moved = maxf(moved, absf(after[i] - before[i]))
	print("    CONTROL switching one preset to Host Profile moves the ground %.4f m" % moved)
	if moved < RELIEF_EPS:
		_fail += 1
		print("    !! the two band sources bake the same surface; the defaults check is vacuous")


# --- BQ: the native evaluator and the GDScript oracle agree on the new paths -------------------------
#
# Every op in this system is implemented twice and the two must agree to 1e-4 m. This phase adds three
# places they can drift: the host field derivation, the selector's field-source dispatch, and the band
# coordinate. All three are exercised at once, because a program using one of them is not evidence about
# the others.
func _gate_bq_parity() -> void:
	print("\n[BQ] native rasteriser vs the GDScript oracle on the host-profile paths (tol %.6f m):"
			% PARITY_TOL)
	var mound = _make_mound("BQ", SITE_BQ, 50.0, 50.0)
	if mound == null:
		return
	mound.height = 35.0
	var probes: Array[Vector3] = []
	for i in range(-3, 4):
		for j in range(-3, 4):
			probes.append(SITE_BQ + Vector3(i * 6.0, 0.0, j * 6.0))

	# A fractal gated on the host profile's SLOPE, then terraces banding the host profile, then strata
	# banding world altitude — the three new paths in one program, stacked so the PROFILE ops also have a
	# non-trivial accumulator under them.
	var shape := Pasture3DReliefFractal.new()
	shape.style = Pasture3DReliefFractal.Style.CRAGGY
	shape.feature_size = 20.0
	shape.seed = 5
	var gate := Pasture3DTerrainMask.new()
	gate.filter_type = Pasture3DTerrainMask.FilterType.SLOPE
	gate.field_source = Pasture3DTerrainMask.FieldSource.HOST_PROFILE
	gate.range_min = 15.0
	gate.range_max = 90.0
	gate.falloff_low = 8.0
	gate.measure_radius = 6.0 # also covers the per-source measured grids
	shape.selector = gate

	var terr := Pasture3DReliefTerraces.new()
	terr.steps = 5
	terr.hardness = 0.9
	terr.step_jitter = 0.06
	terr.base_amount = 0.0
	terr.band_source = Pasture3DReliefMaterial.BandSource.HOST_PROFILE

	var strata := Pasture3DReliefStrata.new()
	strata.layers = 7
	strata.hardness = 0.5
	strata.base_amount = 0.0
	strata.band_source = Pasture3DReliefMaterial.BandSource.GROUND_ALTITUDE
	strata.band_range = Vector2(_height(SITE_BQ) - 5.0, _height(SITE_BQ) + 45.0)

	var stack := Pasture3DReliefStack.new()
	stack.layers = [shape, terr, strata]
	_stack(mound, stack, 7.0)

	var base := _snapshot(probes)

	# BASELINE FIRST, exactly as MoundReliefCheck's gate D does it, and for the same reason. The dome term
	# itself carries a small pre-existing divergence between the two paths — the C++ ramp LUT against
	# GDScript's `_ramp`, in float against double — which scales with the amplitude, so a 38 m fixture
	# starts several 1e-4 above zero before this phase's code runs at all. Measuring the dome alone first
	# is what separates a divergence THIS PHASE introduced from one it merely made visible.
	_relief_strength(mound, 0.0)
	var dome_only := _parity_gap(mound, probes)
	print("    dome only, no relief:                worst |native - gdscript| = %.8f m" % dome_only)

	_relief_strength(mound, 7.0)
	var full := _parity_gap(mound, probes)
	print("    dome + the three host-profile paths: worst |native - gdscript| = %.8f m" % full)

	var spread := 0.0
	for i in range(probes.size()):
		spread = maxf(spread, absf(_height(probes[i]) - base[i]))

	# The claim this gate owns: the new paths must not widen the gap between the two implementations.
	var added := full - dome_only
	print("    their own contribution to the gap: %+.8f m (tolerance %.6f)" % [added, PARITY_TOL])
	if added > PARITY_TOL:
		_fail += 1
		print("    !! the host-profile paths disagree between C++ and the GDScript oracle")

	# CONTROL — the fixture must be deforming the ground by far more than the tolerance, or two nearly
	# flat surfaces are being compared and the agreement is about nothing.
	print("    CONTROL max |deformation| across probes: %.4f m (must dwarf the tolerance)" % spread)
	if spread < 1.0:
		_fail += 1
		print("    !! this program barely moved the ground; parity here proves nothing")


# --- helpers ----------------------------------------------------------------------------------------

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
	var worst := 0.0
	for i in range(p_probes.size()):
		if is_finite(native[i]) and is_finite(oracle[i]):
			worst = maxf(worst, absf(native[i] - oracle[i]))
	return worst


## Per-probe height minus the plain-dome baseline: the material's OWN contribution, with the demo ground
## and the dome removed. Every comparison that is about the material must be made on these, not on baked
## heights — `relative_to_terrain` means a baked height carries whatever it was stamped onto.
func _deltas(p_plain: Array[float], p_with: Array[float]) -> Array[float]:
	var out: Array[float] = []
	for i in range(p_plain.size()):
		out.append(p_with[i] - p_plain[i] if (is_finite(p_plain[i]) and is_finite(p_with[i])) else NAN)
	return out


## Index of the first probe, walking outwards, that carries NO relief — i.e. where the gate shuts off.
## probes.size() when relief reaches the end.
func _relief_edge(p_plain: Array[float], p_with: Array[float]) -> int:
	for i in range(p_plain.size()):
		if absf(p_with[i] - p_plain[i]) <= RELIEF_EPS:
			return i
	return p_plain.size()


## Mean |relief| over the half-open probe range [from, to).
func _mean_relief(p_plain: Array[float], p_with: Array[float], p_from: int, p_to: int) -> float:
	var acc := 0.0
	var n := 0
	for i in range(p_from, mini(p_to, p_plain.size())):
		if is_finite(p_plain[i]) and is_finite(p_with[i]):
			acc += absf(p_with[i] - p_plain[i])
			n += 1
	return acc / float(n) if n > 0 else 0.0


## Worst disagreement between the mirrored pairs packed as [a0, mirror(a0), a1, mirror(a1), ...].
func _mirror_spread(p_vals: Array[float]) -> float:
	var worst := 0.0
	for i in range(0, p_vals.size() - 1, 2):
		if is_finite(p_vals[i]) and is_finite(p_vals[i + 1]):
			worst = maxf(worst, absf(p_vals[i] - p_vals[i + 1]))
	return worst


## How many distinct height plateaus the probes fall into, at `p_tol` metres of separation. A crude
## clustering, which is all "did it actually band" needs.
func _distinct_levels(p_vals: Array[float], p_tol: float) -> int:
	var sorted: Array[float] = []
	for v in p_vals:
		if is_finite(v):
			sorted.append(v)
	sorted.sort()
	if sorted.is_empty():
		return 0
	var n := 1
	for i in range(1, sorted.size()):
		if sorted[i] - sorted[i - 1] > p_tol:
			n += 1
	return n


func _slope_at(p_at: Vector3) -> float:
	var d := 1.0
	var gx := (_height(p_at + Vector3(d, 0, 0)) - _height(p_at - Vector3(d, 0, 0))) / (2.0 * d)
	var gz := (_height(p_at + Vector3(0, 0, d)) - _height(p_at - Vector3(0, 0, d))) / (2.0 * d)
	if not (is_finite(gx) and is_finite(gz)):
		return 0.0
	return rad_to_deg(atan(sqrt(gx * gx + gz * gz)))


## Every material in a preset, the resource itself plus a Stack's layers, one level deep — which is as
## deep as the shipped presets go.
func _flatten(p_res) -> Array:
	var out: Array = []
	if p_res is Pasture3DReliefMaterial:
		out.append(p_res)
		if p_res is Pasture3DReliefStack:
			for m in p_res.layers:
				if m != null:
					out.append(m)
	return out


func _relief_presets() -> Array:
	var out: Array = []
	var d := DirAccess.open(RELIEF_DIR)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".tres"):
			out.append(RELIEF_DIR + "/" + f)
	return out


func _make_mound(p_name: String, p_at: Vector3, p_hx: float, p_hz: float):
	if not is_finite(_height(p_at)):
		_fail += 1
		print("    !! no terrain at %s; the fixture is outside demo/data" % p_at)
		return null
	var mound := Pasture3DMound.new()
	mound.name = p_name
	_root.add_child(mound)
	mound.terrain = _terrain
	mound.global_position = p_at
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	c.add_point(Vector3(-p_hx, 0.0, -p_hz))
	c.add_point(Vector3(p_hx, 0.0, -p_hz))
	c.add_point(Vector3(p_hx, 0.0, p_hz))
	c.add_point(Vector3(-p_hx, 0.0, p_hz))
	c.closed = true
	path.curve = c
	mound.add_child(path)
	return mound


func _snapshot(p_points: Array[Vector3]) -> Array[float]:
	var out: Array[float] = []
	for p in p_points:
		out.append(_height(p))
	return out


func _height(p_at: Vector3) -> float:
	return _terrain.data.get_height(Vector3(p_at.x, 0.0, p_at.z))


# ---- Modifier-stack shims (PASTURE3D_BRUSH_EROSION_SPEC.md §6.6) -----------------------------------
#
# Phase 3a deleted Pasture3DMound's `noise` / `noise_strength` / `relief` / `relief_strength` /
# `smooth_passes` properties; an ordered `modifiers` list replaced them. These two helpers keep the gates
# below reading the way they always did — assign a material, then move its amplitude — without each of
# them having to build a stack by hand.
func _stack(p_mound, p_mat, p_strength: float, p_noise: FastNoiseLite = null,
		p_noise_strength: float = 0.0, p_passes: int = 0) -> void:
	var mods: Array[Pasture3DNode] = []
	if p_noise != null:
		var mn := Pasture3DNodeNoise.new()
		mn.noise = p_noise
		mn.strength = p_noise_strength
		mods.append(mn)
	if p_mat != null:
		# Kept in the list even at strength 0, so `_relief_strength` below always has something to move.
		# An inactive modifier is dropped at compile time, which is exactly what `relief_strength = 0`
		# used to do.
		var mr := Pasture3DNodeRelief.new()
		mr.material = p_mat
		mr.strength = p_strength
		mods.append(mr)
	if p_passes > 0:
		var ms := Pasture3DNodeSmooth.new()
		ms.passes = p_passes
		mods.append(ms)
	p_mound.modifiers = mods


## The Relief modifier's current amplitude, for the two gates that predict a height from it.
func _strength_of(p_mound) -> float:
	for m in p_mound.modifiers:
		if m is Pasture3DNodeRelief:
			return m.strength
	return 0.0


## The `relief_strength = x` idiom: move the Relief modifier's amplitude, leaving the stack alone.
func _relief_strength(p_mound, p_strength: float) -> void:
	for m in p_mound.modifiers:
		if m is Pasture3DNodeRelief:
			m.strength = p_strength
