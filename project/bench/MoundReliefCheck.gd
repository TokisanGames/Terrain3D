# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gates for Pasture3DMound's Relief Material slot (PASTURE3D_MOUND_RELIEF_SPEC.md §8).
#
# Every gate measures a HEIGHT DELTA at probe points, never a configuration flag: "the material compiles"
# and "the ground moved" are different claims, and only the second ships. Each gate carries a control that
# must fail if the relief path is dead, so a run of zeros reports "measured nothing" rather than passing.
#
# Baselines are snapshotted BEFORE the brush's first bake and reused for every later comparison at the
# same site, so a delta is always against untouched ground rather than against a previous stamp.
#
# refresh() early-returns outside the editor (Engine.is_editor_hint()), so this drives _refresh_owner --
# the function refresh() calls once past that guard -- exactly as PlowReliefCheck does.
#
# NOTHING IS SAVED. Bakes write into the terrain's in-memory layer; demo/data on disk is only touched by
# an explicit save, which nothing here calls.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/MoundReliefCheck.tscn
extends Node

const DEMO_DATA := "res://demo/data"
## Probe sites, all inside the loaded demo regions. Demo regions are (0,-1), (0,-2), (0,0) at 1024 verts
## / 1 m, so world X 0..1024 and Z -2048..1024 are covered. Each was probed finite before being written
## down; _make_mound fails the run rather than returning null silently if that ever stops being true.
const SITE_LEGACY := Vector3(180.0, 0.0, 120.0)
const SITE_RELIEF := Vector3(380.0, 0.0, 120.0)
const SITE_COEXIST := Vector3(580.0, 0.0, 120.0)
const SITE_PARITY := Vector3(380.0, 0.0, 320.0)
const SITE_SELECTOR := Vector3(780.0, 0.0, 120.0)
const SITE_CRATER := Vector3(180.0, 0.0, 340.0)
## A probe counts as steep / flat for the binned selector gate at these slopes, in degrees.
const STEEP_DEG := 30.0
const FLAT_DEG := 10.0
const PARITY_TOL := 1.0e-4

var _fail := 0
var _root: Node3D
var _terrain


func _ready() -> void:
	print("\n=== Pasture3DMound Relief Material ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA

	_gate_a_legacy_mound_unchanged()
	_gate_b_relief_stamps()
	_gate_c_coexists_with_noise()
	_gate_d_parity()
	_gate_e_slope_selector()
	_gate_f_crater_follows_the_loop()

	print("\n=== %s (%d failures) ===\n" % ["MOUND RELIEF PASS" if _fail == 0 else "MOUND RELIEF FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- A: the migration guarantee ------------------------------------------------------------------
# The feature is off unless a material is assigned AND a strength is set, so every Mound in every
# pre-existing scene must bake exactly what it always did. Unlike the Plow's Source enum there is no
# declared default to move -- this gate exists to keep it that way.
func _gate_a_legacy_mound_unchanged() -> void:
	print("[A] a Mound with no relief assigned bakes unchanged:")
	var fresh := Pasture3DMound.new()
	print("    fresh Mound: relief = %s, relief_strength = %.1f (want <null>, 0.0)" % [
			fresh.relief, fresh.relief_strength])
	if fresh.relief != null or not is_zero_approx(fresh.relief_strength):
		_fail += 1
		print("    !! the relief slot is on by default; every legacy scene's Mound just changed shape")
	fresh.free()

	var probes: Array[Vector3] = [SITE_LEGACY]
	var mound = _make_mound("Legacy", SITE_LEGACY, 40.0, 40.0)
	if mound == null:
		return
	mound.height = 18.0
	var base := _snapshot(probes)
	mound._refresh_owner(mound._layer_owner, false, [])
	var plain := _height(SITE_LEGACY)
	print("    dome delta with no relief: %+.4f m" % (plain - base[0]))
	if absf(plain - base[0]) < 0.5:
		_fail += 1
		print("    !! the plain mound stopped deforming; the relief branch broke the shared cell loop")

	# Re-baking with the slot still empty must land on exactly the same surface.
	mound._refresh_owner(mound._layer_owner, false, [])
	var again := _height(SITE_LEGACY)
	print("    re-bake drift: %+.8f m" % (again - plain))
	if absf(again - plain) > 1.0e-4:
		_fail += 1
		print("    !! an empty relief slot is not a no-op")

	# CONTROL -- assigning a material and a strength MUST change the result. Without this, a gate that
	# measured a brush which cannot stamp relief at all would report the same clean numbers.
	var mat := Pasture3DReliefFractal.new()
	mat.style = Pasture3DReliefFractal.Style.CRAGGY
	mat.feature_size = 18.0
	mound.relief = mat
	mound.relief_strength = 4.0
	mound._refresh_owner(mound._layer_owner, false, [])
	var with_relief := _height(SITE_LEGACY)
	print("    CONTROL with relief assigned: %+.4f m from the plain dome" % (with_relief - plain))
	if absf(with_relief - plain) < 0.1:
		_fail += 1
		print("    !! assigning a relief material changed nothing; the unchanged result above is vacuous")


# --- B: relief stamps, stays inside the loop, and is idempotent -----------------------------------
func _gate_b_relief_stamps() -> void:
	print("\n[B] a Relief Material deforms the mound's surface:")
	var inside := SITE_RELIEF
	var outside := SITE_RELIEF + Vector3(70.0, 0.0, 0.0) # well beyond the 40 m half-loop
	var probes: Array[Vector3] = [inside, outside]
	var mound = _make_mound("Relief", SITE_RELIEF, 40.0, 40.0)
	if mound == null:
		return
	var mat := Pasture3DReliefFractal.new()
	mat.style = Pasture3DReliefFractal.Style.CRAGGY
	mat.feature_size = 22.0
	mat.octaves = 4
	# height 0 isolates the relief: the dome contributes nothing, so every delta below is the material's.
	# ADD rather than the default MAX, which is raise-only and would silently discard everything the
	# material carves -- measuring half a signed material and calling it a pass.
	mound.height = 0.0
	mound.blend_mode = Pasture3DMound.BlendMode.ADD
	mound.relief = mat
	mound.relief_strength = 6.0

	var base := _snapshot(probes)
	mound._refresh_owner(mound._layer_owner, false, [])
	var d_in := _height(inside) - base[0]
	var d_out := _height(outside) - base[1]
	print("    interior delta:     %+.4f m" % d_in)
	if absf(d_in) < 0.05:
		_fail += 1
		print("    !! the relief material did not move the ground")

	# The rim must feather back to the surrounds, or the stamp cuts a visible step into the terrain.
	print("    outside-loop delta: %+.4f m (want ~0)" % d_out)
	if absf(d_out) > 0.01:
		_fail += 1
		print("    !! the relief leaked past the loop; the interior profile is not masking it")

	# Idempotency: re-baking must land on the same surface, not stack a second copy of the relief.
	var h1 := _height(inside)
	mound._refresh_owner(mound._layer_owner, false, [])
	var h2 := _height(inside)
	print("    re-bake: %.4f -> %.4f (drift %+.8f)" % [h1, h2, h2 - h1])
	if absf(h2 - h1) > 1.0e-3:
		_fail += 1
		print("    !! the bake is not idempotent; the relief climbs its own layer")

	# CONTROL -- strength 0 must return the ground to its baseline. Without this, a gate that measured
	# nothing at all would be indistinguishable from one that measured correctly.
	mound.relief_strength = 0.0
	mound._refresh_owner(mound._layer_owner, false, [])
	var d_zero := _height(inside) - base[0]
	print("    CONTROL relief_strength=0 delta: %+.5f m (want ~0)" % d_zero)
	if absf(d_zero) > 0.01:
		_fail += 1
		print("    !! strength=0 still deformed; the probe is not reading this brush's relief")


# --- C: relief sits ALONGSIDE the noise field, it does not replace it -----------------------------
# The scope decision for this feature was "alongside, noise untouched". That is a claim about
# superposition, so it is measured as one: the height that adding relief contributes must be the same
# whether or not a noise field is also assigned. If relief had replaced the noise branch, (both - noise)
# would carry the noise term as well and the two columns would part company.
func _gate_c_coexists_with_noise() -> void:
	print("\n[C] relief and the FastNoiseLite field are both applied (superposition):")
	var probes: Array[Vector3] = []
	for i in range(-3, 4):
		for j in range(-3, 4):
			probes.append(SITE_COEXIST + Vector3(i * 8.0, 0.0, j * 8.0))
	var mound = _make_mound("Coexist", SITE_COEXIST, 40.0, 40.0)
	if mound == null:
		return
	mound.height = 10.0

	var n := FastNoiseLite.new()
	n.frequency = 0.03
	n.seed = 7
	var mat := Pasture3DReliefFractal.new()
	mat.style = Pasture3DReliefFractal.Style.CRAGGY
	mat.feature_size = 16.0

	var base := _snapshot(probes)

	# Four bakes: the dome alone, +noise, +relief, +both.
	mound._refresh_owner(mound._layer_owner, false, [])
	var dome := _snapshot(probes)

	mound.noise = n
	mound.noise_strength = 3.0
	mound._refresh_owner(mound._layer_owner, false, [])
	var with_noise := _snapshot(probes)

	mound.noise = null
	mound.noise_strength = 0.0
	mound.relief = mat
	mound.relief_strength = 5.0
	mound._refresh_owner(mound._layer_owner, false, [])
	var with_relief := _snapshot(probes)

	mound.noise = n
	mound.noise_strength = 3.0
	mound._refresh_owner(mound._layer_owner, false, [])
	var with_both := _snapshot(probes)

	# (both - noise) is relief's contribution on top of noise; (relief - dome) is it on its own.
	var worst := 0.0
	var relief_span := 0.0
	var noise_span := 0.0
	var counted := 0
	for i in range(probes.size()):
		var on_noise := with_both[i] - with_noise[i]
		var alone := with_relief[i] - dome[i]
		if not (is_finite(on_noise) and is_finite(alone)):
			continue
		counted += 1
		worst = maxf(worst, absf(on_noise - alone))
		relief_span = maxf(relief_span, absf(alone))
		noise_span = maxf(noise_span, absf(with_noise[i] - dome[i]))
	print("    %d of %d probes read finite" % [counted, probes.size()])
	if counted < probes.size() / 2:
		_fail += 1
		print("    !! most probes were off the loaded regions; this gate measured almost nothing")
		return
	print("    worst |relief-on-noise - relief-alone| = %.8f m" % worst)
	if worst > 1.0e-3:
		_fail += 1
		print("    !! relief and noise are not independent; one is overwriting the other")

	# CONTROL -- both terms must actually be present. Two contributions of zero superpose perfectly.
	print("    CONTROL spans: relief %.4f m | noise %.4f m (both must be well above 0)" % [
			relief_span, noise_span])
	if relief_span < 0.2:
		_fail += 1
		print("    !! the relief term is ~0, so the superposition result is vacuous")
	if noise_span < 0.2:
		_fail += 1
		print("    !! the noise term is ~0, so this never tested coexistence at all")


# --- D: the native rasteriser and the GDScript oracle agree ---------------------------------------
func _gate_d_parity() -> void:
	print("\n[D] native rasteriser vs the GDScript oracle (tolerance %.6f m):" % PARITY_TOL)
	var probes: Array[Vector3] = []
	for i in range(-2, 3):
		for j in range(-2, 3):
			probes.append(SITE_PARITY + Vector3(i * 7.0, 0.0, j * 7.0))
	var mound = _make_mound("Parity", SITE_PARITY, 36.0, 36.0)
	if mound == null:
		return
	# A stack with a domain warp exercises the DOMAIN op (which rewrites the sample point for the ops
	# after it) and multi-op accumulation -- the two places the two implementations can drift apart.
	var stack := Pasture3DReliefStack.new()
	var shape := Pasture3DReliefFractal.new()
	shape.style = Pasture3DReliefFractal.Style.HILLS
	shape.feature_size = 44.0
	shape.warp_amount = 8.0
	var detail := Pasture3DReliefFractal.new()
	detail.style = Pasture3DReliefFractal.Style.CRAGGY
	detail.feature_size = 11.0
	detail.amplitude = 0.4
	detail.sharpness = 1.6
	detail.seed = 99
	stack.layers = [shape, detail]
	# A non-zero dome AND noise, so parity covers the whole per-cell expression, not just the relief term.
	# Both are switched on AFTER the dome-only baseline below.
	mound.height = 12.0
	var n := FastNoiseLite.new()
	n.frequency = 0.02

	var base := _snapshot(probes)

	# BASELINE FIRST: the same brush with NO relief and NO noise. Mound normalises its dome on the SDF's
	# max_inside, which the Plow never uses, so this pairing has never been A/B compared before. Measuring
	# it separately is what tells a pre-existing divergence in the dome term apart from one this feature
	# introduced -- otherwise a single combined number gets blamed on whatever was added last.
	var dome_only := _parity_delta(mound, probes)
	print("    dome + falloff only, no relief:  worst |native - gdscript| = %.8f m" % dome_only)

	mound.noise = n
	mound.noise_strength = 2.0
	mound.relief = stack
	mound.relief_strength = 7.0
	var full := _parity_delta(mound, probes)
	print("    dome + noise + relief:           worst |native - gdscript| = %.8f m" % full)

	var spread := 0.0
	for i in range(probes.size()):
		spread = maxf(spread, absf(_height(probes[i]) - base[i]))

	# The claim this gate actually owns: adding relief must not widen the gap between the two paths.
	var added := full - dome_only
	print("    relief's own contribution to the gap: %+.8f m (tolerance %.6f)" % [added, PARITY_TOL])
	if added > PARITY_TOL:
		_fail += 1
		print("    !! the relief term itself diverges between C++ and GDScript")
	if dome_only > PARITY_TOL:
		print("    NOTE the dome/falloff term ALREADY diverges by %.8f m without any relief involved."
				% dome_only)
		print("         That is a pre-existing Mound A/B gap, not this feature's -- see the spec's §11.")

	# CONTROL -- the probes must actually be sitting on deformation. Two paths that both wrote nothing
	# agree perfectly, and that agreement would mean nothing.
	print("    CONTROL max |deformation| across probes: %.4f m (must be well above the tolerance)" % spread)
	if spread < 0.1:
		_fail += 1
		print("    !! the probes measured flat ground, so the parity result is vacuous")


## Bake the brush both ways at the same settings and return the worst per-probe disagreement.
func _parity_delta(p_mound, probes: Array[Vector3]) -> float:
	p_mound.force_gdscript_raster = false
	p_mound._refresh_owner(p_mound._layer_owner, false, [])
	var native := _snapshot(probes)
	p_mound.force_gdscript_raster = true
	p_mound._refresh_owner(p_mound._layer_owner, false, [])
	var worst := 0.0
	for i in range(probes.size()):
		var g := _height(probes[i])
		if is_finite(g) and is_finite(native[i]):
			worst = maxf(worst, absf(g - native[i]))
	p_mound.force_gdscript_raster = false
	return worst


# --- E: selectors read the layers BELOW this brush -------------------------------------------------
# The correctness claim inherited from the Plow's phase 3: a selector reads the ground beneath this
# brush's own layer, never the finished composite. If it read the composite, the relief it just wrote
# would change the slope it reads next time and the bake would creep on every refresh.
func _gate_e_slope_selector() -> void:
	print("\n[E] a SLOPE selector confines a Mound's relief to steep ground:")
	var probes: Array[Vector3] = []
	for i in range(-7, 8):
		for j in range(-7, 8):
			probes.append(SITE_SELECTOR + Vector3(i * 10.0, 0.0, j * 10.0))
	var mound = _make_mound("SlopeSel", SITE_SELECTOR, 80.0, 80.0)
	if mound == null:
		return

	# Binned on the UNTOUCHED ground, before any bake. height 0 keeps it that way, so the bins describe
	# the same surface the selector reads rather than one this brush has already reshaped.
	var slopes: Array[float] = []
	var steep := 0
	var flat := 0
	for p in probes:
		var s := _slope_at(p)
		slopes.append(s)
		if s >= STEEP_DEG:
			steep += 1
		elif s <= FLAT_DEG:
			flat += 1
	print("    of %d probes: %d steep (>=%.0f deg), %d flat (<=%.0f deg)" % [
			probes.size(), steep, STEEP_DEG, flat, FLAT_DEG])
	if steep < 5 or flat < 5:
		_fail += 1
		print("    !! the site does not span both slope bands; this gate cannot measure anything here")
		return

	var mat := Pasture3DReliefFractal.new()
	mat.style = Pasture3DReliefFractal.Style.CRAGGY
	mat.feature_size = 20.0
	var sel := Pasture3DReliefSelector.new()
	sel.filter_type = Pasture3DReliefSelector.FilterType.SLOPE
	sel.range_min = STEEP_DEG
	sel.range_max = 90.0
	sel.falloff_low = 8.0
	sel.falloff_high = 0.0
	mat.selector = sel
	mound.height = 0.0
	mound.blend_mode = Pasture3DMound.BlendMode.ADD # MAX would discard the material's carving half
	mound.relief = mat
	mound.relief_strength = 8.0

	var base := _snapshot(probes)
	mound._refresh_owner(mound._layer_owner, false, [])
	var gated_steep := _mean_abs_delta(probes, base, slopes, STEEP_DEG, true)
	var gated_flat := _mean_abs_delta(probes, base, slopes, FLAT_DEG, false)
	print("    gated:   mean |relief| steep %.4f m | flat %.4f m" % [gated_steep, gated_flat])
	if gated_steep < 0.2:
		_fail += 1
		print("    !! the gated material stamped nothing even on steep ground")
	if gated_flat > gated_steep * 0.35:
		_fail += 1
		print("    !! flat ground got comparable relief; the selector is not gating")

	var before := _snapshot(probes)
	mound._refresh_owner(mound._layer_owner, false, [])
	var drift := 0.0
	for i in range(probes.size()):
		drift = maxf(drift, absf(_height(probes[i]) - before[i]))
	print("    re-bake drift with a slope-gated material: %.8f m" % drift)
	if drift > 1.0e-3:
		_fail += 1
		print("    !! the brush is gating on its own output; the bake will drift every refresh")

	# CONTROL -- strength 0 means "no gating", so the SAME material must now cover flat ground too. This
	# rules out the alternative explanation for the result above: that the fractal simply happens to be
	# near zero wherever the flat probes sit.
	sel.strength = 0.0
	mound._refresh_owner(mound._layer_owner, false, [])
	var open_steep := _mean_abs_delta(probes, base, slopes, STEEP_DEG, true)
	var open_flat := _mean_abs_delta(probes, base, slopes, FLAT_DEG, false)
	print("    CONTROL ungated: mean |relief| steep %.4f m | flat %.4f m" % [open_steep, open_flat])
	# The steep column is EXPECTED to be byte-identical gated vs ungated: the band is [30, 90], so every
	# steep probe sits fully inside it and multiplies by 1.0. It is the flat column that carries the
	# claim. Said out loud because an unexplained identical pair is normally the signature of a criterion
	# that measured the ungated material twice.
	if not is_equal_approx(open_steep, gated_steep):
		print("    (steep moved when the gate opened, %.4f -> %.4f -- band edge, not a failure)" % [
				gated_steep, open_steep])
	if open_flat < gated_flat * 2.0 or open_flat < 0.2:
		_fail += 1
		print("    !! ungating did not bring flat ground back; the gated result proves nothing")


# --- F: radial ops are still sized and oriented by the loop ----------------------------------------
# Mound maps relief in TILE only, and the Plow's own warning says a Crater under TILE "repeats once per
# tile". That is not what the built evaluator does: nu,nv come from the loop's oriented frame in EVERY
# mapping mode, and only u,v change. This gate pins that down for Mound, because the TILE-only decision
# rests on it -- if it were false, craters would be unusable here.
#
# The loop is deliberately ELONGATED. The crater is an ellipse in the loop's own axes, so at equal metric
# distance from the centre the long axis sits deeper in the bowl than the short axis. Swap the loop's
# extents and that relationship must invert -- which an AABB-framed implementation cannot do.
func _gate_f_crater_follows_the_loop() -> void:
	print("\n[F] a Crater under Mound's TILE mapping is oriented by the loop:")
	var probe := 18.0
	var along := SITE_CRATER + Vector3(probe, 0.0, 0.0) # the loop's long axis
	var across := SITE_CRATER + Vector3(0.0, 0.0, probe) # the loop's short axis
	var probes: Array[Vector3] = [SITE_CRATER, along, across]
	var mound = _make_mound("Crater", SITE_CRATER, 60.0, 22.0)
	if mound == null:
		return
	var mat := Pasture3DReliefCrater.new()
	mat.floor_depth = 0.8
	mat.rim_height = 0.2
	mound.height = 0.0
	# A crater DIGS, and Mound's default blend is MAX (raise-only), which discards every negative sample.
	# Without this the gate measures only the crater's rim and reports "the crater did not dig".
	mound.blend_mode = Pasture3DMound.BlendMode.ADD
	mound.falloff_width = 6.0
	mound.relief = mat
	mound.relief_strength = 10.0

	var base := _snapshot(probes)
	mound._refresh_owner(mound._layer_owner, false, [])
	var d_centre := _height(SITE_CRATER) - base[0]
	print("    centre delta: %+.4f m (want strongly negative)" % d_centre)
	if d_centre > -1.0:
		_fail += 1
		print("    !! the crater did not dig")

	var d_along := _height(along) - base[1]
	var d_across := _height(across) - base[2]
	print("    at %.0f m out -- long axis %+.4f | short axis %+.4f" % [probe, d_along, d_across])
	if d_along >= d_across:
		_fail += 1
		print("    !! the crater is not elongated with the loop; TILE lost the oriented frame")

	# CONTROL -- swap the loop's extents so the long axis is now Z. Measured against the SAME baseline,
	# the two probes must trade places. If they do not, the frame is axis-aligned and the result above
	# was an accident of where the probes happened to sit.
	_set_loop(mound, 22.0, 60.0)
	mound._refresh_owner(mound._layer_owner, false, [])
	var s_along := _height(along) - base[1]
	var s_across := _height(across) - base[2]
	print("    CONTROL swapped -- long axis %+.4f | short axis %+.4f (must invert)" % [s_along, s_across])
	if s_along <= s_across:
		_fail += 1
		print("    !! swapping the loop did not swap the crater; the frame is not following the loop")


# --- helpers ---------------------------------------------------------------------------------------

func _mean_abs_delta(probes: Array[Vector3], base: Array[float], slopes: Array[float],
		threshold: float, want_steep: bool) -> float:
	var total := 0.0
	var n := 0
	for i in range(probes.size()):
		var steep_enough: bool = slopes[i] >= threshold
		if want_steep != steep_enough:
			continue
		if not want_steep and slopes[i] > threshold:
			continue
		var d := _height(probes[i]) - base[i]
		if not is_finite(d):
			continue # off the edge of the loaded regions; not a reading
		total += absf(d)
		n += 1
	return total / maxf(float(n), 1.0)


func _slope_at(p_at: Vector3) -> float:
	var d := 1.0
	var gx := (_height(p_at + Vector3(d, 0, 0)) - _height(p_at - Vector3(d, 0, 0))) / (2.0 * d)
	var gz := (_height(p_at + Vector3(0, 0, d)) - _height(p_at - Vector3(0, 0, d))) / (2.0 * d)
	if not (is_finite(gx) and is_finite(gz)):
		return 0.0
	return rad_to_deg(atan(sqrt(gx * gx + gz * gz)))


## A mound with a rectangular loop, parented under the terrain's root. Returns null (and fails the run)
## when the site has no terrain under it, so a mis-placed probe reports as a fixture bug, not a pass.
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
	_set_loop(mound, p_hx, p_hz)
	return mound


func _set_loop(p_mound, p_hx: float, p_hz: float) -> void:
	for c in p_mound.get_children():
		if c is Path3D:
			p_mound.remove_child(c)
			c.queue_free()
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	c.add_point(Vector3(-p_hx, 0.0, -p_hz))
	c.add_point(Vector3(p_hx, 0.0, -p_hz))
	c.add_point(Vector3(p_hx, 0.0, p_hz))
	c.add_point(Vector3(-p_hx, 0.0, p_hz))
	c.closed = true
	path.curve = c
	p_mound.add_child(path)


func _snapshot(p_points: Array[Vector3]) -> Array[float]:
	var out: Array[float] = []
	for p in p_points:
		out.append(_height(p))
	return out


func _height(p_at: Vector3) -> float:
	return _terrain.data.get_height(Vector3(p_at.x, 0.0, p_at.z))
