# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Phase 1 gates for Pasture3DPlow Source = RELIEF (PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md §13).
#
# Every gate measures a HEIGHT DELTA at probe points, never a configuration flag: "the material compiles"
# and "the ground moved" are different claims, and the second is the one that ships. Each gate carries a
# control that must fail if the bake path is dead, so a run of zeros reports "measured nothing" rather
# than passing.
#
# Baselines are snapshotted BEFORE the brush's first bake and reused for every later comparison at the
# same site, so a delta is always against untouched ground rather than against a previous stamp.
#
# refresh() early-returns outside the editor (Engine.is_editor_hint()), so this drives _refresh_owner --
# the function refresh() calls once past that guard -- exactly as PondCarveCheck does.
#
# NOTHING IS SAVED. Bakes write into the terrain's in-memory layer; demo/data on disk is only touched by
# an explicit save, which nothing here calls.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/PlowReliefCheck.tscn
extends Node

const DEMO_DATA := "res://demo/data"
## Probe sites, all inside the loaded demo regions (PondCarveCheck proved the first three).
const SITE_NOISE := Vector3(180.0, 0.0, 100.0)
const SITE_FRACTAL := Vector3(380.0, 0.0, 100.0)
const SITE_CRATER := Vector3(180.0, 0.0, 300.0)
const SITE_PARITY := Vector3(380.0, 0.0, 300.0)
## Phase 2 sites. Demo regions are (0,-1), (0,-2), (0,0) at 1024 verts / 1 m, so world X 0..1024 and
## Z -2048..1024 are covered; all of these were probed finite before being written down.
const SITE_SCATTER := Vector3(580.0, 0.0, 100.0)
const SITE_OPS := Vector3(580.0, 0.0, 300.0)
const SITE_TEX := Vector3(180.0, 0.0, 500.0)
## Phase 3 sites.
const SITE_SELECTOR := Vector3(780.0, 0.0, 100.0)
const SITE_SCREE := Vector3(780.0, 0.0, 320.0)
const SITE_P3PARITY := Vector3(780.0, 0.0, 540.0)
## Chosen for having genuinely flat ground (the other sites are almost all steep) while staying clear of
## the region edge at X = 1024, where get_height returns NaN.
const SITE_PROFILE_GATE := Vector3(960.0, 0.0, 700.0)
## A probe counts as steep / flat for the binned selector gates at these slopes, in degrees.
const STEEP_DEG := 30.0
const FLAT_DEG := 10.0
const DEMO_HEIGHT_TEX := "res://demo/assets/textures/noise_test_alb.png"
const PRESET_DIR := "res://demo/data/relief"
const PARITY_TOL := 1.0e-4

var _fail := 0
## Counts ONLY the gates that carry it. A GDScript runtime error abandons a function without incrementing
## `_fail`, so a suite that counts failures alone can report a clean pass having measured nothing — the
## house rule from bench/OceanBench.gd. Gates A-N predate it and are not retrofitted here; bringing them
## up is its own change, and a counter that covers half a suite must say which half or it is worse than
## none. O and P below are the half it covers.
const COUNTED_GATES := 3
var _completed := 0
var _root: Node3D
var _terrain


func _ready() -> void:
	print("\n=== Pasture3DPlow Source = RELIEF (phase 1) ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA

	_gate_f_declared_default()
	_gate_a_noise_regression()
	_gate_b_fractal()
	_gate_c_crater_fit()
	_gate_d_parity()
	_gate_e_scatter()
	_gate_g_phase2_ops()
	_gate_h_fit_texture()
	_gate_i_presets()
	_gate_j_period_guard()
	_gate_k_slope_selector()
	_gate_l_scree()
	_gate_m_phase3_parity()
	_gate_n_profile_ops_are_gated()
	_gate_o_blend_is_hidden()
	_gate_p_stack_forwards_warnings()
	_gate_q_second_gate()

	if _completed != COUNTED_GATES:
		_fail += 1
		print("\n!! only %d of the %d counted gates ran to completion; the rest hit a runtime error"
				% [_completed, COUNTED_GATES])
	print("\n=== %s (%d failures) ===\n" % ["PLOW RELIEF PASS" if _fail == 0 else "PLOW RELIEF FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- F: the migration guarantee ------------------------------------------------------------------
# A scene saved before RELIEF existed omits `source` entirely, so the DECLARED default is what those
# nodes load as. If this ever reports RELIEF, every pre-existing Plow in every user scene silently
# changed source on load. See spec §11.
func _gate_f_declared_default() -> void:
	print("[F] the declared default is still NOISE (pre-existing scenes omit `source`):")
	var fresh := Pasture3DPlow.new()
	print("    Pasture3DPlow.new().source = %d (want %d = NOISE)" % [
			fresh.source, Pasture3DPlow.Source.NOISE])
	if fresh.source != Pasture3DPlow.Source.NOISE:
		_fail += 1
		print("    !! the declared default moved; every legacy scene's Plow just changed source on load")
	fresh.free()


# --- A: the existing sources still bake ----------------------------------------------------------
# Not the full byte-compare baseline the spec asks for, but it is the live regression signal: if adding
# the RELIEF branch broke the shared cell loop, NOISE stops moving the ground.
func _gate_a_noise_regression() -> void:
	print("\n[A] Source = NOISE still deforms (regression on the shared cell loop):")
	var probes: Array[Vector3] = [SITE_NOISE]
	var plow = _make_plow("NoiseRegression", SITE_NOISE, 30.0, 30.0)
	if plow == null:
		return
	plow.source = Pasture3DPlow.Source.NOISE
	var n := FastNoiseLite.new()
	n.frequency = 0.02
	plow.noise = n
	plow.height_scale = 12.0

	var base := _snapshot(probes)
	plow._refresh_owner(plow._layer_owner, false, [])
	var d := _height(SITE_NOISE) - base[0]
	print("    delta at centre: %+.4f m" % d)
	if absf(d) < 0.05:
		_fail += 1
		print("    !! NOISE stopped deforming; the RELIEF branch broke the shared cell loop")


# --- B: fractal relief under TILE ----------------------------------------------------------------
func _gate_b_fractal() -> void:
	print("\n[B] Source = RELIEF, Pasture3DReliefFractal, Mapping = TILE:")
	var inside := SITE_FRACTAL
	var outside := SITE_FRACTAL + Vector3(70.0, 0.0, 0.0) # well beyond the 40 m half-loop
	var probes: Array[Vector3] = [inside, outside]
	var plow = _make_plow("Fractal", SITE_FRACTAL, 40.0, 40.0)
	if plow == null:
		return
	var mat := Pasture3DReliefFractal.new()
	mat.style = Pasture3DReliefFractal.Style.CRAGGY
	mat.feature_size = 24.0
	mat.octaves = 4
	plow.source = Pasture3DPlow.Source.RELIEF
	plow.mapping = Pasture3DPlow.Mapping.TILE
	plow.relief = mat
	plow.height_scale = 10.0

	var base := _snapshot(probes)
	plow._refresh_owner(plow._layer_owner, false, [])
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
		print("    !! the stamp leaked past the loop")

	# Idempotency: re-baking must land on the same surface, not stack a second copy of the relief.
	var h1 := _height(inside)
	plow._refresh_owner(plow._layer_owner, false, [])
	var h2 := _height(inside)
	print("    re-bake: %.4f -> %.4f (drift %+.5f)" % [h1, h2, h2 - h1])
	if absf(h2 - h1) > 1.0e-3:
		_fail += 1
		print("    !! the bake is not idempotent; the relief climbs its own layer")

	# CONTROL -- strength 0 must return the ground to its baseline. Without this, a gate that measured
	# nothing at all would be indistinguishable from one that measured correctly.
	mat.strength = 0.0
	plow._refresh_owner(plow._layer_owner, false, [])
	var d_zero := _height(inside) - base[0]
	print("    CONTROL strength=0 delta: %+.5f m (want ~0)" % d_zero)
	if absf(d_zero) > 0.01:
		_fail += 1
		print("    !! strength=0 still deformed; the probe is not reading this brush's output")


# --- C: a single crater, oriented by the loop -----------------------------------------------------
# The loop is deliberately ELONGATED. Under FIT the crater is an ellipse in the loop's own axes, so at
# equal metric distance from the centre the long axis sits deeper in the bowl than the short axis. Swap
# the loop's extents and that relationship must invert -- which an AABB-framed implementation cannot do.
func _gate_c_crater_fit() -> void:
	print("\n[C] Source = RELIEF, Pasture3DReliefCrater, Mapping = FIT:")
	var probe := 18.0
	var along := SITE_CRATER + Vector3(probe, 0.0, 0.0) # the loop's long axis
	var across := SITE_CRATER + Vector3(0.0, 0.0, probe) # the loop's short axis
	var probes: Array[Vector3] = [SITE_CRATER, along, across]
	var plow = _make_plow("Crater", SITE_CRATER, 60.0, 22.0)
	if plow == null:
		return
	var mat := Pasture3DReliefCrater.new()
	mat.floor_depth = 0.8
	mat.rim_height = 0.2
	plow.source = Pasture3DPlow.Source.RELIEF
	plow.mapping = Pasture3DPlow.Mapping.FIT
	plow.relief = mat
	plow.height_scale = 10.0
	plow.falloff_width = 6.0

	var base := _snapshot(probes)
	plow._refresh_owner(plow._layer_owner, false, [])
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
		print("    !! the crater is not elongated with the loop; FIT ignored the oriented frame")

	# A crater lowers ground, so the Add Water prompt must not treat this brush as raising.
	print("    _raise_inverted() = %s (want true -- a crater digs)" % plow._raise_inverted())
	if not plow._raise_inverted():
		_fail += 1
		print("    !! Add Water would not recognise this brush as digging")

	# CONTROL -- swap the loop's extents so the long axis is now Z. Measured against the SAME baseline,
	# the two probes must trade places. If they do not, the frame is axis-aligned and the result above
	# was a coincidence of where the probes happen to sit.
	_set_loop(plow, 22.0, 60.0)
	plow._refresh_owner(plow._layer_owner, false, [])
	var r_along := _height(along) - base[1]
	var r_across := _height(across) - base[2]
	print("    CONTROL swapped -- X probe %+.4f | Z probe %+.4f (must invert)" % [r_along, r_across])
	if r_along <= r_across:
		_fail += 1
		print("    !! swapping the loop's axes did not reorient the crater")


# --- D: the native path matches the GDScript oracle -----------------------------------------------
func _gate_d_parity() -> void:
	print("\n[D] native rasteriser vs the GDScript oracle (tolerance %.6f m):" % PARITY_TOL)
	var probes: Array[Vector3] = []
	for i in range(-2, 3):
		for j in range(-2, 3):
			probes.append(SITE_PARITY + Vector3(i * 7.0, 0.0, j * 7.0))
	var plow = _make_plow("Parity", SITE_PARITY, 36.0, 36.0)
	if plow == null:
		return
	# A stack with a domain warp exercises the DOMAIN op (which rewrites the sample point for the ops
	# after it) and multi-op accumulation -- the two places the two implementations can drift apart.
	var stack := Pasture3DReliefStack.new()
	var shape := Pasture3DReliefFractal.new()
	shape.style = Pasture3DReliefFractal.Style.HILLS
	shape.feature_size = 48.0
	shape.warp_amount = 8.0
	var detail := Pasture3DReliefFractal.new()
	detail.style = Pasture3DReliefFractal.Style.CRAGGY
	detail.feature_size = 11.0
	detail.amplitude = 0.4
	detail.sharpness = 1.6
	detail.seed = 99
	stack.layers = [shape, detail]
	plow.source = Pasture3DPlow.Source.RELIEF
	plow.relief = stack
	plow.height_scale = 9.0

	var base := _snapshot(probes)

	plow.force_gdscript_raster = false
	plow._refresh_owner(plow._layer_owner, false, [])
	var native := _snapshot(probes)

	plow.force_gdscript_raster = true
	plow._refresh_owner(plow._layer_owner, false, [])
	var worst := 0.0
	var spread := 0.0
	for i in range(probes.size()):
		var g := _height(probes[i])
		worst = maxf(worst, absf(g - native[i]))
		spread = maxf(spread, absf(g - base[i]))
	print("    %d probes | worst |native - gdscript| = %.8f m" % [probes.size(), worst])
	if worst > PARITY_TOL:
		_fail += 1
		print("    !! the two paths disagree; one of the op implementations drifted")

	# CONTROL -- the probes must actually be sitting on relief. Two paths that both wrote nothing agree
	# perfectly, and that agreement would mean nothing.
	print("    CONTROL max |relief| across probes: %.4f m (must be well above the tolerance)" % spread)
	if spread < 0.1:
		_fail += 1
		print("    !! the probes measured flat ground, so the parity result is vacuous")


# --- E: SCATTER places a deterministic field ------------------------------------------------------
func _gate_e_scatter() -> void:
	print("\n[E] Mapping = SCATTER, a deterministic crater field:")
	var probes: Array[Vector3] = []
	for i in range(-3, 4):
		for j in range(-3, 4):
			probes.append(SITE_SCATTER + Vector3(i * 9.0, 0.0, j * 9.0))
	var plow = _make_plow("Scatter", SITE_SCATTER, 45.0, 45.0)
	if plow == null:
		return
	var mat := Pasture3DReliefCrater.new()
	mat.floor_depth = 0.8
	mat.rim_height = 0.2
	plow.source = Pasture3DPlow.Source.RELIEF
	plow.mapping = Pasture3DPlow.Mapping.SCATTER
	plow.relief = mat
	plow.height_scale = 10.0
	plow.scatter_count = 9
	plow.scatter_seed = 1234
	plow.scatter_radius_min = 6.0
	plow.scatter_radius_max = 12.0

	var base := _snapshot(probes)
	plow._refresh_owner(plow._layer_owner, false, [])
	var run1 := _snapshot(probes)
	print("    instances short by %d of %d" % [plow._scatter_shortfall, plow.scatter_count])
	if plow._scatter_shortfall > 0:
		_fail += 1
		print("    !! placement ran out of attempts; the field is thinner than requested")

	var relief_max := 0.0
	for i in range(probes.size()):
		relief_max = maxf(relief_max, absf(run1[i] - base[i]))
	print("    max |relief| across probes: %.4f m" % relief_max)
	if relief_max < 0.5:
		_fail += 1
		print("    !! scatter stamped nothing; every later comparison here would be vacuous")

	# Same seed must reproduce the field exactly, or a scene re-bakes into a different landscape.
	plow._refresh_owner(plow._layer_owner, false, [])
	var same := 0.0
	for i in range(probes.size()):
		same = maxf(same, absf(_height(probes[i]) - run1[i]))
	print("    same seed, re-bake: worst drift %.8f m" % same)
	if same > 1.0e-4:
		_fail += 1
		print("    !! placement is not deterministic; the same scene bakes differently each time")

	# CONTROL -- a different seed must produce a DIFFERENT field. If it does not, the seed is not wired
	# and the determinism result above is just "nothing ever changes".
	plow.scatter_seed = 4321
	plow._refresh_owner(plow._layer_owner, false, [])
	var differs := 0.0
	var relief2 := 0.0
	for i in range(probes.size()):
		var h := _height(probes[i])
		differs = maxf(differs, absf(h - run1[i]))
		relief2 = maxf(relief2, absf(h - base[i]))
	print("    CONTROL different seed: worst change %.4f m, own relief %.4f m" % [differs, relief2])
	if differs < 0.5:
		_fail += 1
		print("    !! changing the seed changed nothing; scatter_seed is not reaching placement")
	# The second field must itself be a field. Otherwise "it changed" could just mean placement failed
	# and the ground went back to flat -- which would satisfy the check above for the wrong reason.
	if relief2 < 0.5:
		_fail += 1
		print("    !! the reseeded field stamped nothing; the change above is placement failing, not moving")


# --- G: the phase-2 ops agree between the two paths -----------------------------------------------
func _gate_g_phase2_ops() -> void:
	print("\n[G] phase-2 ops (Strata, Terraces, Dunes, Furrows) native vs oracle:")
	var probes: Array[Vector3] = []
	for i in range(-2, 3):
		for j in range(-2, 3):
			probes.append(SITE_OPS + Vector3(i * 8.0, 0.0, j * 8.0))
	var plow = _make_plow("Phase2Ops", SITE_OPS, 40.0, 40.0)
	if plow == null:
		return
	# One stack exercising every new op at once: STRATIFY and TERRACE are PROFILE ops that remap the
	# running accumulator, DUNES and FURROWS are generators, and each carries its own noise field.
	var stack := Pasture3DReliefStack.new()
	var strata := Pasture3DReliefStrata.new()
	strata.seed = 7
	var dunes := Pasture3DReliefDunes.new()
	dunes.amplitude = 0.35
	dunes.blend = Pasture3DReliefMaterial.Blend.ADD
	dunes.seed = 8
	var furrows := Pasture3DReliefFurrows.new()
	furrows.amplitude = 0.15
	furrows.spacing = 5.0
	furrows.blend = Pasture3DReliefMaterial.Blend.ADD
	var terraces := Pasture3DReliefTerraces.new()
	terraces.base_amount = 0.0 # terrace what the layers below produced, do not add a shape
	terraces.steps = 7
	stack.layers = [strata, dunes, furrows, terraces]
	plow.source = Pasture3DPlow.Source.RELIEF
	plow.relief = stack
	plow.height_scale = 8.0

	var base := _snapshot(probes)
	plow.force_gdscript_raster = false
	plow._refresh_owner(plow._layer_owner, false, [])
	var native := _snapshot(probes)
	plow.force_gdscript_raster = true
	plow._refresh_owner(plow._layer_owner, false, [])
	var worst := 0.0
	var spread := 0.0
	for i in range(probes.size()):
		var g := _height(probes[i])
		worst = maxf(worst, absf(g - native[i]))
		spread = maxf(spread, absf(g - base[i]))
	print("    %d probes | worst |native - gdscript| = %.8f m" % [probes.size(), worst])
	if worst > PARITY_TOL:
		_fail += 1
		print("    !! a phase-2 op drifted between the two implementations")
	print("    CONTROL max |relief| across probes: %.4f m" % spread)
	if spread < 0.1:
		_fail += 1
		print("    !! the probes measured flat ground, so the parity result is vacuous")



# --- H: FIT maps a height TEXTURE once onto the loop ----------------------------------------------
# Spec §6 promises FIT for the LUT sources too, not just RELIEF. The failure mode is silent: the branch
# just keeps tiling and the loop's shape is ignored.
func _gate_h_fit_texture() -> void:
	print("\n[H] Mapping = FIT applies to Source = TEXTURE, not just RELIEF:")
	var tex: Texture2D = load(DEMO_HEIGHT_TEX)
	if tex == null:
		_fail += 1
		print("    !! could not load %s; the fixture is broken" % DEMO_HEIGHT_TEX)
		return
	var probes: Array[Vector3] = []
	for i in range(-2, 3):
		for j in range(-2, 3):
			probes.append(SITE_TEX + Vector3(i * 6.0, 0.0, j * 6.0))
	var plow = _make_plow("FitTexture", SITE_TEX, 48.0, 20.0)
	if plow == null:
		return
	plow.source = Pasture3DPlow.Source.TEXTURE
	plow.height_texture = tex
	plow.height_scale = 10.0
	plow.tile_size = 24.0

	plow.mapping = Pasture3DPlow.Mapping.TILE
	plow._refresh_owner(plow._layer_owner, false, [])
	var tiled := _snapshot(probes)
	plow.mapping = Pasture3DPlow.Mapping.FIT
	plow._refresh_owner(plow._layer_owner, false, [])
	var fitted := _snapshot(probes)
	var diff := 0.0
	for i in range(probes.size()):
		diff = maxf(diff, absf(fitted[i] - tiled[i]))
	print("    max |FIT - TILE| = %.4f m (must be nonzero)" % diff)
	if diff < 0.01:
		_fail += 1
		print("    !! FIT and TILE produced the same stamp; the LUT branch still always tiles")

	# CONTROL -- under TILE the sample depends only on world XZ, so reshaping the loop must NOT change
	# the interior. Under FIT it must. That pair is what proves FIT is reading the oriented frame.
	_set_loop(plow, 20.0, 48.0)
	plow._refresh_owner(plow._layer_owner, false, [])
	var fit_reshaped := _snapshot(probes)
	var fit_change := 0.0
	for i in range(probes.size()):
		fit_change = maxf(fit_change, absf(fit_reshaped[i] - fitted[i]))
	plow.mapping = Pasture3DPlow.Mapping.TILE
	plow._refresh_owner(plow._layer_owner, false, [])
	var tile_change := 0.0
	for i in range(probes.size()):
		tile_change = maxf(tile_change, absf(_height(probes[i]) - tiled[i]))
	print("    reshaping the loop -- FIT changes by %.4f m, TILE by %.4f m" % [fit_change, tile_change])
	if fit_change < 0.01:
		_fail += 1
		print("    !! FIT ignored the loop's shape")
	# TILE is not expected to be perfectly still here -- reshaping the loop also reshapes the falloff
	# MASK, which moves the probes near the edges either way. What must hold is that FIT responds much
	# more strongly, because only FIT re-maps the image itself. Without this ratio the check above would
	# pass on the mask movement alone.
	if fit_change < tile_change * 3.0:
		_fail += 1
		print(("    !! FIT moved no more than the mask alone (%.4f vs %.4f); the loop's shape is only "
			+ "reaching the falloff, not the sampling") % [fit_change, tile_change])


# --- I: the shipped presets load and produce relief -----------------------------------------------
func _gate_i_presets() -> void:
	print("\n[I] shipped presets compile and are not flat:")
	var dir := DirAccess.open(PRESET_DIR)
	if dir == null:
		_fail += 1
		print("    !! %s is missing" % PRESET_DIR)
		return
	var names := dir.get_files()
	if names.is_empty():
		_fail += 1
		print("    !! no presets found; nothing was measured")
		return
	for n in names:
		if not n.ends_with(".tres"):
			continue
		var mat = load("%s/%s" % [PRESET_DIR, n])
		if mat == null or not (mat is Pasture3DReliefMaterial):
			_fail += 1
			print("    %-26s !! did not load as a Pasture3DReliefMaterial" % n)
			continue
		var prog: Array = mat.compile()
		var ops: PackedInt32Array = prog[0]
		# Sample a spread of points; a material that returns one constant everywhere is misconfigured.
		# The ground varies across the sweep too — slope from flat to vertical, curvature from ridge to
		# hollow — because a terrain-gated preset evaluated on permanently flat ground reads as constant
		# and would be failed here for doing exactly what it was configured to do.
		#
		# The four SIM inputs vary for exactly the same reason (PASTURE3D_SIM_NODE_SPEC.md §9). A preset
		# gated on FLOW and swept at a constant zero catchment is gated out at every sample, reads as
		# constant, and gets failed for working. The catchment range is deliberately wide — decades, as
		# drainage area is — so a band anywhere from a gully to a trunk valley is crossed.
		var lo := INF
		var hi := -INF
		for i in range(24):
			var a := i * 13.7
			var t := float(i) / 23.0
			var val: float = mat.eval(a, a * 0.6, (a / 60.0) - 1.0, (a / 90.0) - 1.0,
					1.0 / 30.0, 1.0 / 30.0,
					t * 200.0,        # altitude 0 -> 200 m
					t * 80.0,         # slope 0 -> 80 deg
					t * 2.0 - 1.0,    # curvature ridge -> hollow
					t - 0.5, 0.5 - t, # gradient
					pow(10.0, t * 5.0), # flow 1 -> 100 000 m2 of catchment
					t * 40.0,         # erosion 0 -> 40 m removed
					t * 4.0,          # deposition 0 -> 4 m gained
					t * 6.0)          # wetness 0 -> 6 m of standing water
			lo = minf(lo, val)
			hi = maxf(hi, val)
		var span := hi - lo
		print("    %-26s %2d ops, output span %.4f" % [n, ops.size() / 4, span])
		if ops.is_empty():
			_fail += 1
			print("      !! compiled to an empty program")
		elif span < 0.01:
			_fail += 1
			print("      !! output is effectively constant; this preset would stamp nothing")


# --- J: the too-fine-to-render guard --------------------------------------------------------------
# Reported from the editor: Furrows at the old 4 m default were invisible, because a cycle only got four
# 1 m samples and meshing ate it. The defaults moved, but a user can still dial the spacing back down, so
# the brush warns. This gate exists because that warning is the only thing standing between someone and
# twenty minutes wondering why a material does nothing.
func _gate_j_period_guard() -> void:
	print("\n[J] the brush warns when a periodic feature is finer than the terrain can resolve:")
	var plow = _make_plow("PeriodGuard", SITE_FRACTAL, 30.0, 30.0)
	if plow == null:
		return
	var mat := Pasture3DReliefFurrows.new()
	plow.source = Pasture3DPlow.Source.RELIEF
	plow.relief = mat

	# The shipped default must be legible on a 1 m terrain, or every new Furrows starts broken.
	mat.spacing = Pasture3DReliefFurrows.new().spacing
	var clean := _has_period_warning(plow)
	print("    default spacing %.1f m on a %.1f m terrain: warns = %s (want false)" % [
			mat.spacing, _terrain.vertex_spacing, clean])
	if clean:
		_fail += 1
		print("    !! the shipped default trips its own warning")

	# CONTROL -- drop below the limit and the warning MUST appear. Without this the check above passes
	# just as well on a guard that never fires at all.
	mat.spacing = _terrain.vertex_spacing * 2.0
	var warned := _has_period_warning(plow)
	print("    spacing %.1f m: warns = %s (want true)" % [mat.spacing, warned])
	if not warned:
		_fail += 1
		print("    !! CONTROL failed: the guard never fires, so the clean result above means nothing")

	# A material with no periodic op at all must not be flagged — fractal octaves are MEANT to run past
	# the vertex spacing and simply stop contributing.
	plow.relief = Pasture3DReliefFractal.new()
	var fractal_warned := _has_period_warning(plow)
	print("    a fractal material warns = %s (want false)" % fractal_warned)
	if fractal_warned:
		_fail += 1
		print("    !! fractals are being flagged; their fine octaves are expected, not a mistake")


func _has_period_warning(p_plow) -> bool:
	for w in p_plow._get_configuration_warnings():
		if String(w).contains("too few"):
			return true
	return false


# --- K: a slope selector confines relief to steep ground ------------------------------------------
# Rather than hand-picking one flat and one steep probe (which invites a lucky result), this bins a grid
# of probes by the terrain's own slope and compares the two populations. The gate needs both bins to be
# populated, so a uniformly flat or uniformly steep site reports as a fixture bug rather than a pass.
func _gate_k_slope_selector() -> void:
	print("\n[K] a SLOPE selector confines relief to steep ground:")
	var probes: Array[Vector3] = []
	for i in range(-7, 8):
		for j in range(-7, 8):
			probes.append(SITE_SELECTOR + Vector3(i * 10.0, 0.0, j * 10.0))
	var plow = _make_plow("SlopeSel", SITE_SELECTOR, 80.0, 80.0)
	if plow == null:
		return

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
	plow.source = Pasture3DPlow.Source.RELIEF
	plow.relief = mat
	plow.height_scale = 8.0

	var base := _snapshot(probes)
	plow._refresh_owner(plow._layer_owner, false, [])
	var gated_steep := _mean_abs_delta(probes, base, slopes, STEEP_DEG, true)
	var gated_flat := _mean_abs_delta(probes, base, slopes, FLAT_DEG, false)
	print("    gated:   mean |relief| steep %.4f m | flat %.4f m" % [gated_steep, gated_flat])
	if gated_steep < 0.2:
		_fail += 1
		print("    !! the gated material stamped nothing even on steep ground")
	if gated_flat > gated_steep * 0.35:
		_fail += 1
		print("    !! flat ground got comparable relief; the selector is not gating")

	# THE phase-3 correctness claim: a selector reads the layers BELOW this brush, never the finished
	# terrain. If it read the composite, the relief it just wrote would change the slope it reads next
	# time, and the bake would drift on every refresh instead of landing in the same place.
	var before := _snapshot(probes)
	plow._refresh_owner(plow._layer_owner, false, [])
	var drift := 0.0
	for i in range(probes.size()):
		drift = maxf(drift, absf(_height(probes[i]) - before[i]))
	print("    re-bake drift with a slope-gated material: %.8f m" % drift)
	if drift > 1.0e-3:
		_fail += 1
		print("    !! the brush is gating on its own output; the bake will drift every refresh")

	# CONTROL -- strength 0 means "no gating", so the SAME material must now cover flat ground too. This
	# is what rules out the alternative explanation for the result above: that the fractal simply happens
	# to be near zero wherever the flat probes sit.
	sel.strength = 0.0
	plow._refresh_owner(plow._layer_owner, false, [])
	var open_steep := _mean_abs_delta(probes, base, slopes, STEEP_DEG, true)
	var open_flat := _mean_abs_delta(probes, base, slopes, FLAT_DEG, false)
	print("    CONTROL ungated: mean |relief| steep %.4f m | flat %.4f m" % [open_steep, open_flat])
	if open_flat < gated_flat * 2.0 or open_flat < 0.2:
		_fail += 1
		print("    !! ungating did not bring flat ground back; the gated result proves nothing")


# --- L: SCREE reads the ground it sits on ---------------------------------------------------------
func _gate_l_scree() -> void:
	print("\n[L] Pasture3DReliefScree responds to slope and gradient:")
	var probes: Array[Vector3] = []
	for i in range(-6, 7):
		for j in range(-6, 7):
			probes.append(SITE_SCREE + Vector3(i * 10.0, 0.0, j * 10.0))
	var plow = _make_plow("Scree", SITE_SCREE, 70.0, 70.0)
	if plow == null:
		return
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
	print("    of %d probes: %d steep, %d flat" % [probes.size(), steep, flat])
	if steep < 5 or flat < 5:
		_fail += 1
		print("    !! the site does not span both slope bands; this gate cannot measure anything here")
		return

	var mat := Pasture3DReliefScree.new()
	mat.amplitude = 0.5
	mat.toe_deposition = 0.4
	mat.downslope_streak = 0.0
	plow.source = Pasture3DPlow.Source.RELIEF
	plow.relief = mat
	plow.height_scale = 8.0

	var base := _snapshot(probes)
	plow._refresh_owner(plow._layer_owner, false, [])
	var on_steep := _mean_abs_delta(probes, base, slopes, STEEP_DEG, true)
	var on_flat := _mean_abs_delta(probes, base, slopes, FLAT_DEG, false)
	var unstreaked := _snapshot(probes)
	print("    mean |relief| steep %.4f m | flat %.4f m" % [on_steep, on_flat])
	if on_steep < 0.1:
		_fail += 1
		print("    !! scree stamped nothing on steep ground")
	if on_flat > on_steep * 0.5:
		_fail += 1
		print("    !! scree is covering flat ground; its built-in slope gate is not applying")

	# The downslope streak offsets the grain sample along the height gradient. If changing it moves
	# nothing, the op is not reading the gradient at all and is just slope-gated noise.
	mat.downslope_streak = 10.0
	plow._refresh_owner(plow._layer_owner, false, [])
	var streak_change := 0.0
	for i in range(probes.size()):
		streak_change = maxf(streak_change, absf(_height(probes[i]) - unstreaked[i]))
	print("    downslope streak 0 -> 10 m changes output by %.4f m" % streak_change)
	if streak_change < 0.05:
		_fail += 1
		print("    !! the streak did nothing; SCREE is not reading the terrain gradient")

	# CONTROL -- open the slope gate and flat ground must fill in, proving the earlier split came from
	# the gate rather than from where the grain noise happens to land.
	mat.min_slope_degrees = 0.0
	mat.slope_falloff_degrees = 0.0
	plow._refresh_owner(plow._layer_owner, false, [])
	var open_flat := _mean_abs_delta(probes, base, slopes, FLAT_DEG, false)
	print("    CONTROL gate opened: mean |relief| flat %.4f m (was %.4f)" % [open_flat, on_flat])
	if open_flat < on_flat * 2.0 or open_flat < 0.1:
		_fail += 1
		print("    !! opening the gate changed nothing; the slope split above proves nothing")


# --- M: parity with selectors and SCREE active ----------------------------------------------------
func _gate_m_phase3_parity() -> void:
	print("\n[M] native vs oracle with selectors and SCREE active:")
	var probes: Array[Vector3] = []
	for i in range(-3, 4):
		for j in range(-3, 4):
			probes.append(SITE_P3PARITY + Vector3(i * 9.0, 0.0, j * 9.0))
	var plow = _make_plow("Phase3Parity", SITE_P3PARITY, 45.0, 45.0)
	if plow == null:
		return
	var stack := Pasture3DReliefStack.new()
	# Two DIFFERENT selectors in one program, so the stack's selector-id remapping is exercised: if the
	# offsets were wrong, one layer would silently read the other's gate.
	var rock := Pasture3DReliefFractal.new()
	rock.style = Pasture3DReliefFractal.Style.CRAGGY
	rock.feature_size = 22.0
	var high := Pasture3DReliefSelector.new()
	high.filter_type = Pasture3DReliefSelector.FilterType.ALTITUDE
	high.range_min = -10000.0
	high.range_max = 10000.0
	rock.selector = high
	var scree := Pasture3DReliefScree.new()
	scree.amplitude = 0.3
	scree.downslope_streak = 6.0
	scree.blend = Pasture3DReliefMaterial.Blend.ADD
	# A third layer gated over a MEASURE RADIUS (§21.6). Without it this parity claim stops covering the
	# selector path from the moment a band asks for one: the wider slope grid is built by _measured_fields
	# in GDScript and by relief_fields_add_measured in C++, which are two implementations of one stencil
	# and exactly the pair L6 exists to keep honest. The band is deliberately partial — a slope gate over
	# 12 m that passes some of this hillside and not all of it.
	var wide := Pasture3DReliefFractal.new()
	wide.style = Pasture3DReliefFractal.Style.HILLS
	wide.feature_size = 30.0
	wide.blend = Pasture3DReliefMaterial.Blend.ADD
	var over12 := Pasture3DReliefSelector.new()
	over12.filter_type = Pasture3DReliefSelector.FilterType.SLOPE
	over12.range_min = 18.0
	over12.range_max = 90.0
	over12.falloff_low = 6.0
	over12.falloff_high = 0.0
	over12.measure_radius = 12.0
	wide.selector = over12
	stack.layers = [rock, scree, wide]
	plow.source = Pasture3DPlow.Source.RELIEF
	plow.relief = stack
	plow.height_scale = 8.0

	var base := _snapshot(probes)
	plow.force_gdscript_raster = false
	plow._refresh_owner(plow._layer_owner, false, [])
	var native := _snapshot(probes)
	plow.force_gdscript_raster = true
	plow._refresh_owner(plow._layer_owner, false, [])
	var worst := 0.0
	var spread := 0.0
	for i in range(probes.size()):
		var g := _height(probes[i])
		worst = maxf(worst, absf(g - native[i]))
		spread = maxf(spread, absf(g - base[i]))
	print("    %d probes | worst |native - gdscript| = %.8f m" % [probes.size(), worst])
	if worst > PARITY_TOL:
		_fail += 1
		print("    !! the terrain fields or selectors differ between the two implementations")
	print("    CONTROL max |relief| across probes: %.4f m" % spread)
	if spread < 0.1:
		_fail += 1
		print("    !! the probes measured flat ground, so the parity result is vacuous")

	# FIXTURE CHECK for the measure_radius layer: drop the radius to 0 and the SAME material must stamp
	# something measurably different. Without this the parity number above would still read 0.00000000
	# with the radius never reaching either path — two implementations agreeing on a parameter neither of
	# them used (§21.6).
	over12.measure_radius = 0.0
	plow.force_gdscript_raster = false
	plow._refresh_owner(plow._layer_owner, false, [])
	var radius_delta := 0.0
	for i in range(probes.size()):
		radius_delta = maxf(radius_delta, absf(_height(probes[i]) - native[i]))
	print("    CONTROL the same bake with measure_radius 0 instead of 12 m: max |difference| %.4f m"
			% radius_delta)
	if radius_delta < 1.0e-3:
		_fail += 1
		print("    !! the radius changed nothing here, so M's parity claim never exercised it")
	over12.measure_radius = 12.0


# --- N: a gated-out area is left completely alone, PROFILE ops included --------------------------
# Reported from the editor. Selectors originally gated only GENERATOR ops, on the reasoning that gating a
# remap would create a discontinuity. That was wrong twice over: the right semantics is to LERP between
# the un-remapped and remapped accumulator (smooth), and without it a material like Strata gated its
# fractal base to zero and then ran STRATIFY on that zero — whose tilted band function is NOT zero. A
# fully excluded hillside still came out stepped, by up to 0.43 of the height scale.
func _gate_n_profile_ops_are_gated() -> void:
	print("\n[N] a fully gated-out area is untouched, PROFILE ops included:")
	var mat := Pasture3DReliefStrata.new()
	mat.layers = 14
	mat.hardness = 0.75
	mat.dip = 0.25
	var sel := Pasture3DReliefSelector.new()
	sel.filter_type = Pasture3DReliefSelector.FilterType.SLOPE
	sel.range_min = 25.0
	sel.range_max = 90.0
	sel.falloff_low = 10.0
	mat.selector = sel

	# Direct evaluation on dead-flat ground: every op must contribute nothing, at every position.
	var worst := 0.0
	for i in range(32):
		var a := i * 37.0
		worst = maxf(worst, absf(mat.eval(a, a * 0.5, 0.0, 0.0, 0.01, 0.01, 50.0, 0.0, 0.0, 0.0, 0.0)))
	print("    Strata + slope gate, evaluated on flat ground: worst |output| = %.6f" % worst)
	if worst > 1.0e-4:
		_fail += 1
		print("    !! a gated-out area still gets relief; a PROFILE op is escaping the selector")

	# CONTROL -- the same material on steep ground must produce plenty. Otherwise "it output nothing" is
	# just a broken material rather than a working gate.
	var steep := 0.0
	for i in range(32):
		var a := i * 37.0
		steep = maxf(steep, absf(mat.eval(a, a * 0.5, 0.0, 0.0, 0.01, 0.01, 50.0, 60.0, 0.0, 0.0, 0.0)))
	print("    CONTROL same material on steep ground: worst |output| = %.4f" % steep)
	if steep < 0.1:
		_fail += 1
		print("    !! the material produces nothing anywhere; the flat result above is meaningless")

	# And the same thing through a real bake, so the fix is verified end to end rather than only in the
	# oracle. Probes are restricted to flat ground, where the gate should exclude everything.
	var probes: Array[Vector3] = []
	for i in range(-4, 5):
		for j in range(-4, 5):
			probes.append(SITE_PROFILE_GATE + Vector3(i * 10.0, 0.0, j * 10.0))
	var plow = _make_plow("ProfileGate", SITE_PROFILE_GATE, 50.0, 50.0)
	if plow == null:
		return
	var slopes: Array[float] = []
	var flat := 0
	for p in probes:
		var s := _slope_at(p)
		slopes.append(s)
		if s <= FLAT_DEG:
			flat += 1
	if flat < 5:
		_fail += 1
		print("    !! no flat probes at this site; the baked half of this gate measured nothing")
		return
	plow.source = Pasture3DPlow.Source.RELIEF
	plow.relief = mat
	plow.height_scale = 8.0
	var base := _snapshot(probes)
	plow._refresh_owner(plow._layer_owner, false, [])
	var baked_flat := _mean_abs_delta(probes, base, slopes, FLAT_DEG, false)
	print("    baked: mean |relief| on %d flat probes = %.6f m" % [flat, baked_flat])
	if baked_flat > 0.01:
		_fail += 1
		print("    !! the bake still moved gated-out flat ground")


## Mean |height change| over the probes on one side of a slope threshold.
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


## Terrain steepness in degrees at a point, from central differences of the live height. Independent of
## the brush's own field derivation on purpose — a gate that reused it could not catch it being wrong.
func _slope_at(p_at: Vector3) -> float:
	var d := 1.0
	var gx := (_height(p_at + Vector3(d, 0, 0)) - _height(p_at - Vector3(d, 0, 0))) / (2.0 * d)
	var gz := (_height(p_at + Vector3(0, 0, d)) - _height(p_at - Vector3(0, 0, d))) / (2.0 * d)
	if not (is_finite(gx) and is_finite(gz)):
		return 0.0
	return rad_to_deg(atan(sqrt(gx * gx + gz * gz)))


# --- fixture helpers -------------------------------------------------------------------------------

## A plow with a rectangular loop, parented under the terrain's root. Returns null (and fails the run)
## when the site has no terrain under it, so a mis-placed probe reports as a fixture bug, not a pass.
func _make_plow(p_name: String, p_at: Vector3, p_hx: float, p_hz: float):
	if not is_finite(_height(p_at)):
		_fail += 1
		print("    !! no terrain at %s; the fixture is outside demo/data" % p_at)
		return null
	var plow := Pasture3DPlow.new()
	plow.name = p_name
	_root.add_child(plow)
	plow.terrain = _terrain
	plow.global_position = p_at
	_set_loop(plow, p_hx, p_hz)
	return plow


func _set_loop(p_plow, p_hx: float, p_hz: float) -> void:
	for c in p_plow.get_children():
		if c is Path3D:
			p_plow.remove_child(c)
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
	p_plow.add_child(path)


func _snapshot(p_points: Array[Vector3]) -> Array[float]:
	var out: Array[float] = []
	for p in p_points:
		out.append(_height(p))
	return out


func _height(p_at: Vector3) -> float:
	return _terrain.data.get_height(Vector3(p_at.x, 0.0, p_at.z))


# --- O: `blend` is hidden on a material that cannot use it ----------------------------------------
#
# Spec §16.1. Outside a Pasture3DReliefStack, `blend` does nothing at all: a host evaluates one material
# into an accumulator that starts at 0 and adds the result, and no setting of it changes a byte. The base
# hides it for that reason, and three subclasses overrode `_validate_property` without calling `super`,
# which repealed the rule on exactly those three -- GDScript resolves a virtual to the most-derived
# implementation and stops.
#
# MEASURED AS INSPECTOR VISIBILITY, not by reading the source for `super`. A grep-shaped gate passes on
# code that calls super and then undoes it, and fails on a subclass that solves the problem some other
# way. What has to be true is what the artist sees.
#
# The catalogue is enumerated rather than sampled, so a NEW material that forgets is caught the day it is
# added rather than the day someone wonders why the control is there.
#
# CONTROL. The same instances, put into a stack, must show it. Without that "hidden everywhere" is also
# what a gate reports when `blend` has been renamed out of the property list entirely, or when the
# visibility bit is read the wrong way round -- both of which pass the criterion while measuring nothing.
func _gate_o_blend_is_hidden() -> void:
	print("\n[O] `blend` is hidden on a material that is not in a stack (spec 16.1):")
	var cases: Array[Pasture3DReliefMaterial] = [
		Pasture3DReliefFractal.new(), Pasture3DReliefTerraces.new(), Pasture3DReliefStrata.new(),
		Pasture3DReliefDunes.new(), Pasture3DReliefFurrows.new(), Pasture3DReliefCrater.new(),
		Pasture3DReliefScree.new(), Pasture3DReliefDLA.new(), Pasture3DReliefStack.new(),
	]
	var loose := 0
	for m in cases:
		if _blend_visible(m):
			loose += 1
			_fail += 1
			print("    !! %s shows Blend while not in a stack, where it cannot act" % _cls(m))
	print("    %d of %d materials hide it outside a stack" % [cases.size() - loose, cases.size()])

	# CONTROL: one stack holding every one of them, which must un-hide it on all of them.
	var host := Pasture3DReliefStack.new()
	var l: Array[Pasture3DReliefMaterial] = []
	for m in cases:
		l.append(m)
	host.layers = l
	var shown := 0
	for m in cases:
		if _blend_visible(m):
			shown += 1
	print("    CONTROL the same instances as layers of a stack: %d of %d show it" % [shown, cases.size()])
	if shown != cases.size():
		_fail += 1
		print("    !! Blend does not appear even where it acts, so the criterion above measured nothing")
	_completed += 1


## Is `blend` in this material's EDITOR property list? Read from get_property_list, which is what the
## inspector itself walks, rather than from _validate_property directly -- the bug being gated is that the
## engine never calls the base implementation, and calling it by hand would step around exactly that.
func _blend_visible(m: Pasture3DReliefMaterial) -> bool:
	for prop in m.get_property_list():
		if prop.get("name", "") == "blend":
			return (int(prop.get("usage", 0)) & PROPERTY_USAGE_EDITOR) != 0
	return false


func _cls(m: Object) -> String:
	var sc: Script = m.get_script()
	return String(sc.get_global_name()) if sc != null else m.get_class()


# --- P: a stack forwards its layers' configuration warnings ---------------------------------------
#
# Spec §16.2. `_configuration_warning()` was the last accessor Pasture3DReliefStack did not pass down, so
# every complaint every material knows how to make vanished the moment it became a layer. The host reads
# one string off the top-level material (Pasture3DTerrainBrush._relief_warnings) and never walks the tree
# itself, so a silent stack is a silent inspector.
#
# THREE CLAIMS, because the fix has three parts. The complaint arrives; it NAMES the layer, which is what
# makes it actionable in a stack of four; and ALL of them arrive, because returning the first would be the
# same hidden-complaint failure with a smaller radius.
#
# CONTROL, and it is the one that matters: a stack of HEALTHY layers must say nothing. A stack that
# concatenated its layers unconditionally, or one that warned about its own structure on every call, would
# satisfy every claim above while telling the artist nothing they can act on.
#
# SECOND CONTROL: the same broken layer standing ALONE must say the same thing. If it does not, this gate
# is measuring a sentence the stack invented rather than one it forwarded.
func _gate_p_stack_forwards_warnings() -> void:
	print("\n[P] a stack reports its layers' complaints (spec 16.2):")
	var broken := Pasture3DReliefTerraces.new()
	broken.hardness = 0.0
	broken.resource_name = "Benches"
	var also_broken := Pasture3DReliefFractal.new()
	also_broken.amplitude = 0.0
	var healthy := Pasture3DReliefDunes.new()

	var alone := broken._configuration_warning()
	print("    the layer standing alone says: %s" % _oneline(alone))
	if alone.is_empty():
		_fail += 1
		print("    !! the fixture does not complain on its own, so P has nothing to forward")
		_completed += 1
		return

	var stack := Pasture3DReliefStack.new()
	var l: Array[Pasture3DReliefMaterial] = [healthy, broken, also_broken]
	stack.layers = l
	var got := stack._configuration_warning()
	print("    the stack says: %s" % _oneline(got))
	if not got.contains(alone):
		_fail += 1
		print("    !! the layer's own complaint did not survive the forward")
	if not got.contains("Benches"):
		_fail += 1
		print("    !! the complaint does not name the layer it is about")
	if got.split("\n").size() < 2:
		_fail += 1
		print("    !! only one of the two broken layers was reported")

	# The nesting claim: a stack inside a stack still reaches the leaf.
	var outer := Pasture3DReliefStack.new()
	var l2: Array[Pasture3DReliefMaterial] = [stack]
	outer.layers = l2
	print("    nested one level deeper: %s" % _oneline(outer._configuration_warning()))
	if not outer._configuration_warning().contains(alone):
		_fail += 1
		print("    !! the forward stops at the first level, so a stack of stacks is still silent")

	# CONTROL. A stack of healthy layers says nothing at all.
	var quiet := Pasture3DReliefStack.new()
	var l3: Array[Pasture3DReliefMaterial] = [healthy, Pasture3DReliefFurrows.new()]
	quiet.layers = l3
	print("    CONTROL a stack of healthy layers says: %s" % _oneline(quiet._configuration_warning()))
	if not quiet._configuration_warning().is_empty():
		_fail += 1
		print("    !! a healthy stack complains too, so the criterion above passes on anything")
	_completed += 1


## Warnings are multi-line now; the log stays one line per fact.
func _oneline(s: String) -> String:
	return "(nothing)" if s.is_empty() else "\"%s\"" % s.replace("\n", " | ")


# --- Q: a material's own selector reaches an op that gates itself ---------------------------------
#
# Spec §16.3. SCREE emits its op already carrying a slope band, so the material works out of the box.
# compile() used to assign the material's `selector` only to ops holding NO_SELECTOR, and SCREE's is never
# empty -- so the property was inert on the one material that gates itself, with no way round it: a
# stack's selector reaches the same test and skips the same op. The op now carries TWO gate slots and is
# scaled by their product.
#
# MEASURED ON THE OP'S OUTPUT, at a cell the assigned band must exclude and the built-in band must pass.
# That combination is the whole point -- a cell excluded by BOTH would go to zero under any wiring at all,
# including the broken one, and would prove nothing.
#
# THREE CONTROLS, because "the output went to zero" has three uninteresting causes.
#   1. The same band on a material whose op carries NO gate of its own (Fractal), which must also gate out
#      -- that is what says the band itself works and the fixture is not simply misconfigured.
#   2. The same Scree with NO selector assigned, which must be non-zero at that cell -- otherwise the
#      built-in slope gate was closing it and the assigned band is irrelevant.
#   3. The built-in gate must still act: a cell the assigned band PASSES and the slope band rejects must
#      still be zero. Without it, "the two multiply" would also be satisfied by an implementation that
#      threw the op's own gate away and kept the material's, which is the previous bug inverted.
func _gate_q_second_gate() -> void:
	print("\n[Q] an assigned selector narrows an op that gates itself (spec 16.3):")
	# A steep cell (60 deg) at 0 m, and an ALTITUDE band of 500-600 m that must exclude it.
	var steep_low := func(m: Pasture3DReliefMaterial) -> float:
		return m.eval(30.0, 30.0, 0.2, 0.2, 1.0, 1.0, 0.0, 60.0)
	# A steep cell at 550 m, which the same band PASSES.
	var steep_high := func(m: Pasture3DReliefMaterial) -> float:
		return m.eval(30.0, 30.0, 0.2, 0.2, 1.0, 1.0, 550.0, 60.0)
	# A FLAT cell at 550 m: the band passes, Scree's own slope gate must not.
	var flat_high := func(m: Pasture3DReliefMaterial) -> float:
		return m.eval(30.0, 30.0, 0.2, 0.2, 1.0, 1.0, 550.0, 2.0)

	var bare := Pasture3DReliefScree.new()
	var gated := Pasture3DReliefScree.new()
	gated.selector = _altitude_band(500.0, 600.0)

	var ungated_v: float = steep_low.call(bare)
	var gated_v: float = steep_low.call(gated)
	print("    steep, 0 m (band EXCLUDES): ungated %.6f -> with a 500-600 m band %.6f"
			% [ungated_v, gated_v])
	if is_zero_approx(ungated_v):
		_fail += 1
		print("    !! the ungated Scree is already zero here; Q measured nothing")
	elif not is_zero_approx(gated_v):
		_fail += 1
		print("    !! the assigned selector did not reach the op, so `selector` is still inert on Scree")

	var pass_v: float = steep_high.call(gated)
	print("    steep, 550 m (band PASSES): %.6f" % pass_v)
	if is_zero_approx(pass_v):
		_fail += 1
		print("    !! the band excludes everywhere, so the zero above is not evidence of anything")

	# CONTROL 3: the op's OWN gate must survive. Flat ground, inside the altitude band.
	var own_v: float = flat_high.call(gated)
	print("    CONTROL flat, 550 m (band passes, SLOPE gate rejects): %.6f" % own_v)
	if not is_zero_approx(own_v):
		_fail += 1
		print("    !! the op's own slope gate was dropped; the two must MULTIPLY, not replace")

	# CONTROL 1: the same band on an op that carries no gate of its own.
	var f_bare := Pasture3DReliefFractal.new()
	var f_gated := Pasture3DReliefFractal.new()
	f_gated.selector = _altitude_band(500.0, 600.0)
	var fb: float = steep_low.call(f_bare)
	var fg: float = steep_low.call(f_gated)
	print("    CONTROL the same band on a Fractal (no gate of its own): %.6f -> %.6f" % [fb, fg])
	if is_zero_approx(fb) or not is_zero_approx(fg):
		_fail += 1
		print("    !! the band does not work on an ungated op either, so the fixture is wrong")

	# And the stack path, since that is where the ids get rebased and a wrong offset reads another
	# material's band. One layer either side, so the Scree's ids are not at 0.
	var stacked := Pasture3DReliefStack.new()
	var inner := Pasture3DReliefScree.new()
	inner.selector = _altitude_band(500.0, 600.0)
	var l: Array[Pasture3DReliefMaterial] = [_screen_layer(), inner]
	stacked.layers = l
	var s_low: float = steep_low.call(stacked)
	var s_high: float = steep_high.call(stacked)
	print("    in a stack behind another gated layer: excluded %.6f, passed %.6f" % [s_low, s_high])
	if not is_equal_approx(s_low, s_high):
		print("    (the Scree layer contributes %.6f of the difference)" % absf(s_high - s_low))
	if is_equal_approx(s_low, s_high):
		_fail += 1
		print("    !! the band does nothing inside a stack, so the second slot is not being rebased")
	_completed += 1


## A gated layer to sit in front of the Scree in Q's stack, so the Scree's selector ids are not 0 and a
## missing rebase shows up as reading the WRONG band rather than as reading none.
func _screen_layer() -> Pasture3DReliefFractal:
	var f := Pasture3DReliefFractal.new()
	f.seed = 91
	f.selector = _altitude_band(-10000.0, 10000.0) # passes everywhere; it is here to consume ids
	return f


func _altitude_band(p_lo: float, p_hi: float) -> Pasture3DReliefSelector:
	var s := Pasture3DReliefSelector.new()
	s.filter_type = Pasture3DReliefSelector.FilterType.ALTITUDE
	s.range_min = p_lo
	s.range_max = p_hi
	s.falloff_low = 0.0
	s.falloff_high = 0.0
	s.strength = 1.0
	return s
