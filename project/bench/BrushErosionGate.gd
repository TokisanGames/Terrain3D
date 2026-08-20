# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gates CA, CB, CC, BX, BY and CE for BRUSH-HOSTED EROSION — phase 3b of PASTURE3D_BRUSH_EROSION_SPEC.md §6.7.
#
# The claim under test: the stream-power solver runs as a modifier over a brush's OWN output, before it
# composites, and the four channels it produces are readable by the modifiers after it — with no
# Pasture3DSim node, no second spline, no Pasture3DSimResult on disk and no layer ordering to get right.
#
# House discipline (see bench/PlowReliefCheck.gd): every gate measures a HEIGHT DELTA at probe points,
# never a configuration flag, and every criterion carries a CONTROL that must fail if the path is dead —
# so a run of zeros reports "measured nothing" rather than passing.
#
# NOTHING IS SAVED. Bakes write into the terrain's in-memory layer.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/BrushErosionGate.tscn
extends Node

const DEMO_DATA := "res://demo/data"

## One site per gate, spaced so no two brushes share ground. Each is probed finite before use.
const SITE_CA := Vector3(180.0, 0.0, 120.0)
const SITE_CB_FLAT := Vector3(420.0, 0.0, 120.0)
const SITE_CB_SLOPE := Vector3(660.0, 0.0, 120.0)
const SITE_CC := Vector3(180.0, 0.0, 360.0)
const SITE_BX := Vector3(420.0, 0.0, 360.0)
const SITE_CE := Vector3(660.0, 0.0, 360.0)
const SITE_BY := Vector3(180.0, 0.0, 600.0)

## Half-extent of the test loop, metres. Large enough that a drainage network has room to organise.
const HALF := 60.0
## Probe every Nth vertex, on the lattice, so a bitwise comparison compares stored samples rather than
## an interpolation between them.
const PROBE_STRIDE := 2

var _fail := 0
var _root: Node3D
var _terrain
var _vs := 1.0


func _ready() -> void:
	print("\n=== Brush-hosted erosion (gates CA, CB, CC, BX, CE) ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_vs = _terrain.vertex_spacing

	_gate_ca_it_erodes()
	_gate_cb_absolute_surface()
	_gate_cc_published_fields()
	_gate_bx_positional()
	_gate_by_frozen_is_a_cache()
	_gate_ce_idempotent()

	print("\n=== %s (%d failures) ===\n" % ["BRUSH EROSION PASS" if _fail == 0 else "BRUSH EROSION FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- CA: a brush-hosted erosion modifier erodes, and erodes ACCORDING TO WHERE WATER GOES -----------
#
# "It changed the surface" is too weak on its own: a uniform lowering would pass it, and a uniform
# lowering is what a broken solve looks like. So the criterion is that the DRAINAGE-AREA TERM matters —
# `area_exponent` is the exponent on how much land drains through a cell, and setting it to 0 leaves the
# same solver routing the same water while making the answer independent of the routing.
#
# WHY NOT "CONCENTRATED IN CHANNELS", WHICH IS WHAT THE SPEC SAID. It was measured and it is not what the
# height delta looks like at this scale. Two statistics were tried and both refused to discriminate:
#
#   top-decile share of the cut   m=0.45 -> 24%,  m=0 -> 18%    (and on the baked fixture, 19% vs 39%:
#                                 INVERTED, because slope-only erosion eats the crags and crags are
#                                 peakier than channels)
#   connectivity of the deep cut  m=0.45 -> 93% in one component, m=0 -> 94%. No separation at all.
#
# The heavy tail is real, but it is in the FLOW FIELD, not in the metres removed: drainage area runs to
# ~600 m² against a 90th percentile of 46 with routing on, and tops out at 150 with it off. Gate CC
# measures that tail directly, through a band that only the channelised tenth of the loop passes. So the
# claim is made where it is true, and CA measures the thing the cut can actually show.
func _gate_ca_it_erodes() -> void:
	print("[CA] the erosion modifier cuts, and the cut depends on where the water goes:")
	var mound = _make_mound("CA", SITE_CA)
	if mound == null:
		return
	var probes := _lattice(SITE_CA)

	# Relief FIRST: a perfectly smooth dome has no asymmetry for water to organise around, so a gate
	# built on one would be measuring the solver's response to floating-point noise.
	var shape := _craggy(8.0)
	var ero := _erosion(60, 0.09)
	var stack: Array[Pasture3DBrushModifier] = [shape, ero]

	ero.enabled = false
	mound.modifiers = stack
	var before := _bake(mound, probes)

	ero.enabled = true
	mound.modifiers = stack
	var after := _bake(mound, probes)
	var routed := _mean_cut(before, after)

	# THE CONTROL — the routing term removed. Same solver, same water, same iterations; only "how much
	# drains through here" stops counting.
	ero.area_exponent = 0.0
	mound.modifiers = stack
	var slope_only := _bake(mound, probes)
	var unrouted := _mean_cut(before, slope_only)
	ero.area_exponent = 0.45

	print("    mean cut %.2f m with the drainage-area term, %.2f m without it (%.1fx)"
		% [routed, unrouted, routed / unrouted if unrouted > 0.0 else 0.0])
	print("    diagnostic only: the deepest 10%% of cells carry %.0f%% of the cut"
		% (_top_share(_cut_array(before, after), 0.10) * 100.0))
	if routed < 0.05:
		_fail += 1
		print("    !! the solver removed essentially nothing, so nothing here is being measured")
	elif routed < unrouted * 1.5:
		_fail += 1
		print("    !! removing the drainage-area term barely changed the result, so the solve is not "
			+ "responding to where water accumulates — it is lowering the surface by slope alone")

	# CONTROL 2 — disabled must reproduce the un-eroded bake BITWISE. Anything else means the modifier
	# is changing the pipeline even when it is switched off.
	ero.enabled = false
	mound.modifiers = stack
	var off := _bake(mound, probes)
	var at := _first_difference(before, off)
	print("    control: disabled reproduces the un-eroded bake: %s"
		% ["bitwise identical" if at < 0 else "DIFFERS at probe %d" % at])
	if at >= 0:
		_fail += 1
		print("    !! a disabled erosion modifier does not leave the bake alone")


# --- CB: the solver sees the ABSOLUTE surface, not the brush's delta ---------------------------------
#
# The bug this exists to catch is forgetting `base_below` — handing the solver the mound's own
# contribution instead of the composite it sits on.
#
# THE FIXTURE IS ONE SITE WITH TWO BASE REFERENCES, not two sites. `relative_to_terrain` decides only
# what the dome's height is measured FROM; under an ADD blend the stored delta is the same either way,
# because the delta is the dome and the dome has not changed. So with erosion off the two bakes must be
# bitwise identical — and with erosion on they must not, because the solver is looking at
# `ground + dome` in one case and `plane + dome` in the other, and stream power reads the slopes of the
# whole surface.
#
# (Comparing two different SITES, which is what the first draft did, cannot work: the demo terrain
# already carries baked content and the sites do not start equal.)
func _gate_cb_absolute_surface() -> void:
	print("
[CB] the solver reads base_below + vals, not vals alone:")
	var mound = _make_mound("CB", SITE_CB_SLOPE)
	if mound == null:
		return
	var probes := _lattice(SITE_CB_SLOPE)
	var ground := _ground_relief(mound, probes)
	print("    the ground under this site varies by %.1f m" % ground)
	if ground < 5.0:
		_fail += 1
		print("    !! the site is too flat for the two base references to differ — stream power is "
			+ "invariant to a CONSTANT offset, so a flat site cannot tell them apart")
		return

	var ero := _erosion(60, 0.09)
	var stack: Array[Pasture3DBrushModifier] = [_craggy(8.0), ero]
	mound.modifiers = stack

	# THE CONTROL FIRST, because it decides what the headline number means.
	ero.enabled = false
	mound.relative_to_terrain = true
	var on_ground := _bake(mound, probes)
	mound.relative_to_terrain = false
	var on_plane := _bake(mound, probes)
	var at := _first_difference(on_ground, on_plane)
	print("    control: with erosion off, the two base references bake %s"
		% ["identically" if at < 0 else "DIFFERENTLY at probe %d (%.4f vs %.4f)"
			% [at, on_ground[at], on_plane[at]]])
	if at >= 0:
		_fail += 1
		print("    !! under ADD the stored delta already depends on the base reference, so a "
			+ "difference below cannot be attributed to what the solver was shown")
		return

	ero.enabled = true
	mound.relative_to_terrain = true
	var ero_ground := _bake(mound, probes)
	mound.relative_to_terrain = false
	var ero_plane := _bake(mound, probes)
	var moved := _max_abs_diff(ero_ground, ero_plane)
	mound.relative_to_terrain = true
	print("    with erosion on, they differ by %.3f m" % moved)
	if moved < 0.5:
		_fail += 1
		print("    !! eroding against the terrain and against a flat plane gave the same answer, so "
			+ "the solver never sees base_below and is eroding the delta")


# --- CC: a later modifier reads the erosion modifier's fields, with no SimResult anywhere -----------
#
# THIS IS THE WORKFLOW THE PHASE EXISTS FOR. One node: shape the mountain, erode it, then stamp detail
# only where the water ran — with nothing on disk and nothing to wire up.
func _gate_cc_published_fields() -> void:
	print("\n[CC] a Relief modifier below the erosion gates on the channels it just cut:")
	var mound = _make_mound("CC", SITE_CC)
	if mound == null:
		return
	var probes := _lattice(SITE_CC)

	var shape := _craggy(8.0)
	var ero := _erosion(60, 0.09)
	var detail := _flow_gated(4.0, 1.0)
	var stack: Array[Pasture3DBrushModifier] = [shape, ero, detail]

	# The baseline is the same stack with the DETAIL modifier off — so every number below is the detail
	# pass alone, not the erosion's own cut.
	detail.enabled = false
	mound.modifiers = stack
	var baseline := _bake(mound, probes)

	detail.enabled = true
	mound.modifiers = stack
	var gated := _bake(mound, probes)
	var covered := _covered_fraction(baseline, gated)
	print("    flow-gated detail lands on %.0f%% of the loop" % (covered * 100.0))

	# CONTROL 1 — publishing off. The same selector must then read its defined zero and stamp nothing.
	ero.publish_fields = false
	mound.modifiers = stack
	var unpublished := _bake(mound, probes)
	var covered_off := _covered_fraction(baseline, unpublished)
	ero.publish_fields = true

	# CONTROL 2 — the selector neutered instead. Strength 0 means "gate nothing", so the detail must
	# cover EVERYTHING. Without this, "nothing appeared" and "the field is missing" read the same.
	var sel: Pasture3DReliefSelector = detail.material.selector
	sel.strength = 0.0
	mound.modifiers = stack
	var ungated := _bake(mound, probes)
	var covered_all := _covered_fraction(baseline, ungated)
	sel.strength = 1.0

	print("    control: publish_fields off -> %.0f%% | selector strength 0 -> %.0f%%"
		% [covered_off * 100.0, covered_all * 100.0])
	# Not 100%: the interior profile fades the relief out toward the rim, and a good share of the probe
	# lattice sits out there where an ungated pass legitimately stamps less than the 5 cm this counts.
	if covered_all < 0.6:
		_fail += 1
		print("    !! an ungated detail pass does not cover the loop either, so the material is not "
			+ "stamping at all and the coverage numbers mean nothing")
	elif covered < 0.02:
		_fail += 1
		print("    !! the flow-gated detail landed nowhere; the published FLOW field is not reaching "
			+ "the selector")
	elif covered > 0.75:
		_fail += 1
		print("    !! the flow gate let almost everything through, so it is not gating on a "
			+ "heavy-tailed drainage field")
	elif covered_off > covered * 0.25:
		_fail += 1
		print("    !! turning publish_fields OFF barely changed the coverage, so the selector is "
			+ "reading something other than this modifier's channels")


# --- BX: a modifier reads only what precedes it -----------------------------------------------------
#
# §6.4's invariant, measured through a bake: the SAME two modifiers, in the two orders. Below the
# erosion, the flow gate reads the real field; above it, the defined zero.
func _gate_bx_positional() -> void:
	print("\n[BX] a modifier reads only what precedes it:")
	var mound = _make_mound("BX", SITE_BX)
	if mound == null:
		return
	var probes := _lattice(SITE_BX)
	var shape := _craggy(8.0)
	var ero := _erosion(60, 0.09)
	var detail := _flow_gated(4.0, 1.0)

	var below: Array[Pasture3DBrushModifier] = [shape, ero, detail]
	mound.modifiers = below
	var after_erosion := _bake(mound, probes)

	var above: Array[Pasture3DBrushModifier] = [shape, detail, ero]
	mound.modifiers = above
	var before_erosion := _bake(mound, probes)

	var moved := _max_abs_diff(after_erosion, before_erosion)
	print("    detail below the erosion vs above it: %.3f m apart" % moved)
	if moved < 0.25:
		_fail += 1
		print("    !! both orders agree, so the field context is not positional — a modifier can read "
			+ "a field produced after it, and §6.4's invariant is unenforced")

	# THE CONTROL: with publishing off, the two orders must converge — the only thing that distinguished
	# them was the field, so removing it must remove the difference. Without this, "the orders differ"
	# could just as well mean the blur-vs-relief ordering effect the stack already had in 3a.
	ero.publish_fields = false
	mound.modifiers = below
	var a2 := _bake(mound, probes)
	mound.modifiers = above
	var b2 := _bake(mound, probes)
	var moved_off := _max_abs_diff(a2, b2)
	ero.publish_fields = true
	print("    control: with publish_fields off the two orders are %.3f m apart" % moved_off)
	if moved_off > moved * 0.5:
		_fail += 1
		print("    !! the orders still differ nearly as much with nothing published, so the gap above "
			+ "is ordering in general and not the field context")


# --- BY: Frozen is a CACHE, not a different answer --------------------------------------------------
#
# Freezing is what makes an expensive modifier tunable at all — freeze the erosion and the modifiers
# after it stay editable at interactive speed. That is only true if a frozen solve is the SAME solve,
# so the first criterion is bitwise equality against Live.
#
# The second is the one that decides whether "frozen" means anything: change the surface underneath it.
# Live must follow, Frozen must NOT, and the brush must say the modifier is stale. A freeze that quietly
# keeps up is not a freeze; one that quietly serves old data with no warning is worse.
func _gate_by_frozen_is_a_cache() -> void:
	print("\n[BY] a frozen solve is the same solve, and it stops following its input:")
	var mound = _make_mound("BY", SITE_BY)
	if mound == null:
		return
	var probes := _lattice(SITE_BY)
	var shape := _craggy(8.0)
	var ero := _erosion(60, 0.09)
	var stack: Array[Pasture3DBrushModifier] = [shape, ero]
	mound.modifiers = stack

	ero.evaluation = Pasture3DBrushModifier.Evaluation.LIVE
	ero.clear_cache()
	var live := _bake(mound, probes)

	ero.evaluation = Pasture3DBrushModifier.Evaluation.FROZEN
	ero.clear_cache()
	var frozen_fresh := _bake(mound, probes)
	var at := _first_difference(live, frozen_fresh)
	print("    a freshly baked Frozen modifier vs Live: %s"
		% ["bitwise identical" if at < 0 else "DIFFERS at probe %d" % at])
	if at >= 0:
		_fail += 1
		print("    !! freezing changed the answer; the cache is not holding what the solver produced")

	# Nothing has been cached yet if this stayed empty — a Frozen modifier with no cache must SOLVE, not
	# skip, or reopening a scene would silently lose its erosion.
	var held := ero.cache_bytes()
	print("    the frozen modifier now holds %.2f MB across %d probes' worth of grid"
		% [held / 1048576.0, probes.size()])
	if held <= 0:
		_fail += 1
		print("    !! nothing was cached, so every 'frozen' bake below is really just another solve")

	# --- change the surface underneath it ---
	shape.strength = 16.0

	ero.evaluation = Pasture3DBrushModifier.Evaluation.LIVE
	ero.clear_cache()
	var live_after := _bake(mound, probes)
	var live_moved := _max_abs_diff(live, live_after)

	# Frozen, with the cache from the ORIGINAL surface still in hand.
	ero.evaluation = Pasture3DBrushModifier.Evaluation.FROZEN
	ero.clear_cache()
	shape.strength = 8.0
	var _seed := _bake(mound, probes) # solve and cache against the original shape
	shape.strength = 16.0
	var frozen_after := _bake(mound, probes)
	var frozen_moved := _max_abs_diff(frozen_fresh, frozen_after)
	var warns := ero.modifier_warnings(mound)
	var says_stale := false
	for w in warns:
		if w.contains("FROZEN") and w.contains("changed"):
			says_stale = true

	print("    doubling the relief under it: Live moves %.3f m, Frozen moves %.3f m, stale warning: %s"
		% [live_moved, frozen_moved, says_stale])
	if live_moved < 0.5:
		_fail += 1
		print("    !! Live did not follow the change either, so the fixture never changed anything and "
			+ "'Frozen did not follow' is not evidence")
	elif frozen_moved > live_moved * 0.25:
		_fail += 1
		print("    !! the frozen modifier followed the change nearly as far as Live did, so it is "
			+ "re-solving and the freeze does nothing")
	if not says_stale:
		_fail += 1
		print("    !! the brush does not report the frozen modifier as stale, so it is serving old data "
			+ "with nothing said — which is the one failure this design must not have")

	# THE CONTROL ON THE WARNING: pressing Bake must clear it AND catch the surface up.
	ero.clear_cache()
	var rebaked := _bake(mound, probes)
	var caught_up := _max_abs_diff(rebaked, live_after)
	var still_stale := false
	for w in ero.modifier_warnings(mound):
		if w.contains("FROZEN") and w.contains("changed"):
			still_stale = true
	print("    control: after Bake Erosion it is %.4f m from the Live answer, stale warning: %s"
		% [caught_up, still_stale])
	if caught_up > 0.001 or still_stale:
		_fail += 1
		print("    !! Bake Erosion did not re-solve against the current surface, so a stale modifier "
			+ "cannot be recovered")


# --- CE: idempotent and deterministic ---------------------------------------------------------------
#
# The configuration most able to feed itself: a flow-gated modifier downstream of the erosion, on a brush
# that re-bakes into a layer it also reads under. If anything read the composite ABOVE its own layer, the
# second bake would land somewhere else.
func _gate_ce_idempotent() -> void:
	print("\n[CE] two bakes of the same stack are bitwise identical:")
	var mound = _make_mound("CE", SITE_CE)
	if mound == null:
		return
	var probes := _lattice(SITE_CE)
	var ero := _erosion(60, 0.09)
	var stack: Array[Pasture3DBrushModifier] = [_craggy(8.0), ero, _flow_gated(4.0, 1.0)]
	mound.modifiers = stack

	var first := _bake(mound, probes)
	var second := _bake(mound, probes)
	var third := _bake(mound, probes)
	var d12 := _first_difference(first, second)
	var d13 := _first_difference(first, third)
	print("    bake 1 vs 2: %s | 1 vs 3: %s"
		% ["identical" if d12 < 0 else "DIFFERS at %d" % d12, "identical" if d13 < 0 else "DIFFERS at %d" % d13])
	if d12 >= 0 or d13 >= 0:
		_fail += 1
		print("    !! the bake drifts on re-run; something in the stack is reading its own output")

	# THE CONTROL: the probe has to be able to SEE a change, or "identical" is not evidence.
	ero.iterations = 61
	mound.modifiers = stack
	var bumped := _bake(mound, probes)
	var moved := _max_abs_diff(first, bumped)
	ero.iterations = 60
	print("    control: one more solver iteration moves the bake by %.4f m" % moved)
	if moved < 0.001:
		_fail += 1
		print("    !! the probe cannot detect a change at all, so the three identical bakes above are "
			+ "not evidence of determinism")


# ---- fixtures --------------------------------------------------------------------------------------


## A craggy Relief modifier. Erosion needs something to organise around: a perfectly smooth dome has no
## asymmetry, so water would only follow floating-point noise.
func _craggy(p_strength: float) -> Pasture3DModRelief:
	var mat := Pasture3DReliefFractal.new()
	mat.style = Pasture3DReliefFractal.Style.CRAGGY
	mat.feature_size = 22.0
	mat.seed = 5
	var m := Pasture3DModRelief.new()
	m.label = "Shape"
	m.material = mat
	m.strength = p_strength
	return m


## Solver settings calibrated on a mound-sized craggy dome (bench/BrushErosionProbe.tscn):
## 60 iterations at 0.09 cut a mean 13 m with a max of 42 m, and the hillslope term is turned DOWN to
## 0.02 because at the shipped 0.15 it smooths the channels away faster than they cut.
## LIVE, deliberately, even though the shipped default is Frozen. A gate that measures what the SOLVER
## does must not measure the cache: with the default, changing `area_exponent` or `iterations` correctly
## leaves the cached solve in place and raises a stale warning, and CA's and CE's controls would both
## read "nothing moved" for entirely the right reason. Gate BY is the one that sets Frozen, and it sets
## it explicitly.
func _erosion(p_iterations: int, p_rate: float) -> Pasture3DModErosion:
	var m := Pasture3DModErosion.new()
	m.evaluation = Pasture3DBrushModifier.Evaluation.LIVE
	m.label = "Erosion"
	m.iterations = p_iterations
	m.erosion_rate = p_rate
	m.hillslope_diffusion = 0.02
	m.publish_fields = true
	return m


## A Relief modifier gated on FLOW — "only where a real catchment drains through". The band starts well
## above the 1 m² a cell that drains only itself reports, so an unpublished field reads as excluded.
func _flow_gated(p_strength: float, p_sel_strength: float) -> Pasture3DModRelief:
	var mat := Pasture3DReliefFractal.new()
	mat.style = Pasture3DReliefFractal.Style.CRAGGY
	mat.feature_size = 7.0
	mat.seed = 21
	var sel := Pasture3DReliefSelector.new()
	sel.filter_type = Pasture3DReliefSelector.FilterType.FLOW
	# Calibrated, not guessed: on this fixture the drainage field runs to about 600 m² with a 90th
	# percentile near 46, so a band starting at 60 catches roughly the channelised tenth. The first
	# version of this gate asked for 2000 m² — above anything the field contains — and measured 0%.
	sel.range_min = 60.0
	sel.range_max = 1.0e9
	sel.falloff_low = 40.0
	sel.falloff_high = 0.0
	sel.strength = p_sel_strength
	mat.selector = sel
	var m := Pasture3DModRelief.new()
	m.label = "Channel detail"
	m.material = mat
	m.strength = p_strength
	return m


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
	mound.height = 55.0
	# ADD, not the MAX default: at these sites the demo terrain is already tall, and MAX clamps away
	# exactly the parts of a modifier's output a gate needs to see. Under ADD every metre the stack
	# stamps reaches the probe.
	mound.blend_mode = Pasture3DMound.BlendMode.ADD
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	c.add_point(Vector3(-HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, HALF))
	c.add_point(Vector3(-HALF, 0.0, HALF))
	c.closed = true
	path.curve = c
	mound.add_child(path)
	return mound


## Probe points on the terrain's own vertex lattice, inset so none straddles the rim.
func _lattice(p_centre: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var step := _vs * PROBE_STRIDE
	var reach := HALF - _vs * 3.0
	var x := -reach
	while x <= reach:
		var z := -reach
		while z <= reach:
			out.append(Vector3(snappedf(p_centre.x + x, _vs), 0.0, snappedf(p_centre.z + z, _vs)))
			z += step
		x += step
	return out


func _bake(p_mound, p_probes: Array[Vector3]) -> Array[float]:
	p_mound._refresh_owner(p_mound._layer_owner, false, [])
	return _snapshot(p_probes)


# ---- measurement -----------------------------------------------------------------------------------


## The brush's own contribution at each probe: the baked height minus the composite of the layers BELOW
## it. Under an ADD blend this is exactly what the layer stores.
func _deltas(p_mound, p_baked: Array[float], p_probes: Array[Vector3]) -> Array[float]:
	var out: Array[float] = []
	for i in range(p_probes.size()):
		out.append(p_baked[i] - _below(p_mound, p_probes[i]))
	return out


## Peak-to-trough of the ground BELOW the brush layer over the probes — how sloped the site is.
func _ground_relief(p_mound, p_probes: Array[Vector3]) -> float:
	var lo := INF
	var hi := -INF
	for p in p_probes:
		var h: float = _below(p_mound, p)
		if is_finite(h):
			lo = minf(lo, h)
			hi = maxf(hi, h)
	return hi - lo if hi > -INF else 0.0


## Fraction of probes where the second bake departs from the first by more than a hair — "where did this
## modifier actually land".
func _covered_fraction(p_base: Array[float], p_with: Array[float]) -> float:
	var n := 0
	var hit := 0
	for i in range(mini(p_base.size(), p_with.size())):
		if not (is_finite(p_base[i]) and is_finite(p_with[i])):
			continue
		n += 1
		if absf(p_with[i] - p_base[i]) > 0.05:
			hit += 1
	return float(hit) / float(n) if n > 0 else 0.0


## Per-probe metres removed, floored at 0 — deposition is not a cut.
func _cut_array(p_before: Array[float], p_after: Array[float]) -> Array[float]:
	var out: Array[float] = []
	for i in range(mini(p_before.size(), p_after.size())):
		var ok := is_finite(p_before[i]) and is_finite(p_after[i])
		out.append(maxf(p_before[i] - p_after[i], 0.0) if ok else 0.0)
	return out


## Mean metres removed across the probes.
func _mean_cut(p_before: Array[float], p_after: Array[float]) -> float:
	var cut := _cut_array(p_before, p_after)
	var s := 0.0
	for c in cut:
		s += c
	return s / float(cut.size()) if cut.size() > 0 else 0.0


## Share of the total carried by the largest `p_frac` of the values — 0.1 for a uniform field, much more
## for a heavy-tailed one.
func _top_share(p_vals: Array[float], p_frac: float) -> float:
	var sorted: Array[float] = p_vals.duplicate()
	sorted.sort()
	sorted.reverse()
	var total := 0.0
	for v in sorted:
		total += v
	if total <= 0.0:
		return 0.0
	var k := maxi(1, int(round(sorted.size() * p_frac)))
	var top := 0.0
	for i in range(k):
		top += sorted[i]
	return top / total


func _first_difference(p_a: Array[float], p_b: Array[float]) -> int:
	for i in range(mini(p_a.size(), p_b.size())):
		var same := p_a[i] == p_b[i] or (not is_finite(p_a[i]) and not is_finite(p_b[i]))
		if not same:
			return i
	return -1


func _max_abs_diff(p_a: Array[float], p_b: Array[float]) -> float:
	var worst := 0.0
	for i in range(mini(p_a.size(), p_b.size())):
		if is_finite(p_a[i]) and is_finite(p_b[i]):
			worst = maxf(worst, absf(p_a[i] - p_b[i]))
	return worst


func _snapshot(p_points: Array[Vector3]) -> Array[float]:
	var out: Array[float] = []
	for p in p_points:
		out.append(_height(p))
	return out


func _height(p_at: Vector3) -> float:
	return _terrain.data.get_height(Vector3(p_at.x, 0.0, p_at.z))


## The composite of the layers UNDER the brush's own — what it stamps against, and what an ADD blend's
## stored delta is measured from. The brush already knows how to ask; borrowing its method is what keeps
## the gate and the bake reading the same surface.
func _below(p_mound, p_at: Vector3) -> float:
	return p_mound._base_height_below(Vector3(p_at.x, 0.0, p_at.z))
