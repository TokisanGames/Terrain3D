# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gates BR–BV for SEDIMENT TRANSPORT — phase 2 of PASTURE3D_BRUSH_EROSION_SPEC.md §5.
#
# The solver was detachment-limited: it removed material and never put it back, so
# Pasture3DSimResult.deposition was a near-empty channel and the landscape read as CUT rather than
# weathered. This phase adds Yuan et al. 2019's deposition term (G), which keeps the implicit, O(N),
# unconditionally stable structure the whole design rests on but makes each step a Gauss-Seidel
# iteration rather than one downstream sweep.
#
# These drive the solver DIRECTLY (Pasture3DData.erode_heightfield) on synthetic fields, the way
# SimPhase1Gate's A–F do — it is a pure function of a heightfield precisely so this is possible.
#
# TWO EXISTING GATES ARE SCOPED, NOT BROKEN, BY THIS PHASE. Gate R ("with hillslope_diffusion = 0,
# deposition is IDENTICALLY zero") and gate K ("with D = 0, no cell rises") are both still true at
# G = 0, which is the default and what every existing scene runs at — so SimPhase1Gate and
# SimPhase2Gate pass untouched. They are false at G > 0 BY DESIGN: a transporting solver deposits with
# no diffusion at all, and deposition raises ground. BR below is gate R's claim re-derived for the
# transporting case, and it keeps R's exact-zero as its own control.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/SedimentGate.tscn
extends Node

const DEMO_DATA := "res://demo/data"

## Synthetic grid. 128² at 4 m, matching SimPhase1Gate so the two suites' numbers are comparable.
const SG := 128
const SCELL := 4.0
const BASE_Z := 200.0

## The row where the steep upper slope grades into the near-flat plain. Erosion happens above it,
## deposition below it — which is the whole reason this fixture exists rather than a uniform plane.
const BREAK_ROW := 56

## Settings that visibly erode this fixture, from the same reasoning as SimPhase1Gate's EROSIVE.
const ERODE := {"iterations": 30, "erosion_rate": 0.2, "area_exponent": 0.45, "diffusion": 0.0}

var _fail := 0
var _root: Node3D
var _terrain
var _data


func _ready() -> void:
	print("\n=== Sediment transport (gates BR-BV) ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_data = _terrain.data
	if _data == null or not _data.has_method("erode_heightfield"):
		_fail += 1
		print("!! no erode_heightfield on Pasture3DData; the extension is stale")
		get_tree().quit(1)
		return

	_gate_br_deposits_without_diffusion()
	_gate_bs_g_zero_is_the_old_solver()
	_gate_bt_bounded_by_erosion()
	_gate_bu_convergence_and_the_cap()
	_gate_bv_cost(false) # PERF GATE — off by default, see the function

	print("\n=== %s (%d failures) ===\n" % ["SEDIMENT PASS" if _fail == 0 else "SEDIMENT FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- BR: deposition happens, with diffusion switched off entirely ------------------------------------
#
# Gate R's replacement. Before this phase the ONLY thing that could raise ground was hillslope diffusion
# filling a concavity, so with D = 0 the deposition channel was exactly zero — R asserted that, and it
# was a true and useful statement about a solver that could not transport.
#
# The claim now is the opposite one, and it has to be measured where the physics says it should happen:
# BELOW the slope break, where a channel leaves steep ground and can no longer carry what it is holding.
func _gate_br_deposits_without_diffusion() -> void:
	print("[BR] material is redeposited with hillslope diffusion at zero:")
	var z0 := _slope_break()
	var p := ERODE.duplicate()
	p["deposition"] = 0.5
	var res := _solve(z0, p)
	if res.is_empty():
		return
	var d := _delta(z0, res["z"])
	var up := _sum_positive(d, 0, BREAK_ROW)
	var down := _sum_positive(d, BREAK_ROW, SG)
	var risen := _count_risen(d)
	print("    G = 0.50, diffusion = 0: %d cells gained material" % risen)
	print("    deposited volume: %.2f m above the break, %.2f m below it" % [up, down])
	if risen < 1:
		_fail += 1
		print("    !! nothing was deposited anywhere; the transport term is not running")
	elif down <= up:
		_fail += 1
		print("    !! deposition is not concentrated below the slope break, which is the one place the")
		print("       physics says a channel must drop its load — this is not sediment transport")

	# CONTROL — gate R, preserved. At G = 0 the same fixture with the same D = 0 must deposit
	# IDENTICALLY nothing. Not "a little": 0.0 on every cell.
	var p0 := ERODE.duplicate()
	p0["deposition"] = 0.0
	var res0 := _solve(z0, p0)
	if res0.is_empty():
		return
	var d0 := _delta(z0, res0["z"])
	var risen0 := _count_risen(d0)
	print("    CONTROL G = 0 on the same fixture: %d cells gained material (gate R, must be 0)" % risen0)
	if risen0 != 0:
		_fail += 1
		print("    !! the detachment-limited path is depositing, so BR's measurement is not about G")
	# And the fixture must actually be eroding, or "deposited below the break" is about nothing.
	var eroded := _sum_negative(d0, 0, SG)
	print("    CONTROL the fixture erodes at all: %.2f m removed at G = 0" % eroded)
	if eroded < 1.0:
		_fail += 1
		print("    !! the fixture barely erodes; there is no sediment for the transport term to move")


# --- BS: G = 0 is the solver Pasture3D already shipped ----------------------------------------------
#
# Every scene ever built runs at the default, so the detachment-limited path has to be untouched — not
# "close". The strongest thing measurable from inside is that the new machinery never even engages:
# `deposition_sweeps` is the solver reporting how many Gauss-Seidel sweeps it ran, and at G = 0 it must
# be 0, meaning the iteration was not entered at all and the single-sweep code path ran.
func _gate_bs_g_zero_is_the_old_solver() -> void:
	print("\n[BS] G = 0 does not enter the iterative path, and stays deterministic:")
	var z0 := _slope_break()
	var p0 := ERODE.duplicate()
	p0["deposition"] = 0.0
	var a := _solve(z0, p0)
	var b := _solve(z0, p0)
	if a.is_empty() or b.is_empty():
		return
	var sweeps0 := int(a.get("deposition_sweeps", -1))
	var same := _bitwise_same(a["z"], b["z"])
	print("    G = 0: %d Gauss-Seidel sweeps (want 0), two runs bitwise identical = %s"
			% [sweeps0, str(same)])
	if sweeps0 != 0:
		_fail += 1
		print("    !! the iterative path ran at G = 0; the detachment-limited solver is not untouched")
	if not same:
		_fail += 1
		print("    !! two identical G = 0 runs differ; determinism (gate I) is broken")

	# A params dict with NO deposition key at all must behave exactly as one with 0.0 — that is what
	# every already-authored scene sends.
	var p_absent := ERODE.duplicate()
	var c := _solve(z0, p_absent)
	if c.is_empty():
		return
	print("    an absent `deposition` key matches an explicit 0: %s"
			% str(_bitwise_same(a["z"], c["z"])))
	if not _bitwise_same(a["z"], c["z"]):
		_fail += 1
		print("    !! the default is not 0; every existing scene just changed shape")

	# CONTROL — G > 0 must run sweeps AND produce a different surface. Without this, a solver that
	# ignored `deposition` entirely would pass everything above.
	var p1 := ERODE.duplicate()
	p1["deposition"] = 0.5
	var e := _solve(z0, p1)
	if e.is_empty():
		return
	var sweeps1 := int(e.get("deposition_sweeps", -1))
	var moved := _max_abs_diff(a["z"], e["z"])
	print("    CONTROL G = 0.5: %d sweeps, and the surface differs by %.4f m" % [sweeps1, moved])
	if sweeps1 < 1 or moved < 0.1:
		_fail += 1
		print("    !! G is not doing anything, so every agreement above is vacuous")


# --- BT: G puts material back, and cannot put back more than it took --------------------------------
#
# The honest conservation statement for this model, and it has to be made on the right quantity.
#
# EVERYTHING HERE IS A NET DELTA over the whole solve, because that is what §8.2 decision 3 defines
# `erosion` and `deposition` to be: the two signs of one field, `z_final - z_initial`. A channel cell
# that gains 0.3 m and loses 0.5 m in the same step reports as erosion, so NET deposition badly
# understates GROSS transport — it comes out around 1 % here while the material actually being moved is
# tens of per cent. That is §15.8's open question ("should deposition accumulate rather than net?"),
# and it is a property of the channel definition, not of this solver.
#
# So the strong, unambiguous signal is the OTHER column: net erosion must FALL as G rises, because
# material is being put back where it was taken from. That is large, monotone, and impossible to fake.
func _gate_bt_bounded_by_erosion() -> void:
	print("\n[BT] G puts material back, and never more than it took:")
	var z0 := _slope_break()
	var gs: Array[float] = [0.0, 0.25, 0.5, 0.75]
	var eros: Array[float] = []
	var deps: Array[float] = []
	for g in gs:
		var p := ERODE.duplicate()
		p["deposition"] = g
		var res := _solve(z0, p)
		if res.is_empty():
			return
		var d := _delta(z0, res["z"])
		var dep := _sum_positive(d, 0, SG)
		var ero := _sum_negative(d, 0, SG)
		eros.append(ero)
		deps.append(dep)
		print("    G = %.2f: net erosion %.1f m, net deposition %.1f m" % [g, ero, dep])
		if dep > ero:
			_fail += 1
			print("    !! more was deposited than was ever eroded; the transport term is creating mass")

	if deps[0] != 0.0:
		_fail += 1
		print("    !! G = 0 deposited something; the detachment-limited path is not detachment-limited")

	# THE CRITERION: more deposition, less net erosion, both strictly monotone in G.
	var ero_falling := true
	var dep_rising := true
	for i in range(1, gs.size()):
		if eros[i] >= eros[i - 1]:
			ero_falling = false
		if deps[i] <= deps[i - 1]:
			dep_rising = false
	var cut: float = 1.0 - eros[eros.size() - 1] / eros[0]
	print("    net erosion falls monotonically: %s (by %.0f%% from G=0 to G=0.75)"
			% [str(ero_falling), cut * 100.0])
	print("    net deposition rises monotonically: %s (%.1f m -> %.1f m)"
			% [str(dep_rising), deps[0], deps[deps.size() - 1]])
	if not ero_falling:
		_fail += 1
		print("    !! net erosion does not fall as G rises, so material is not being put back")
	if not dep_rising:
		_fail += 1
		print("    !! net deposition does not track G, so G is not the deposition coefficient")

	# CONTROL — the sweep must span a real range, or "monotonic" is four near-equal numbers in a row.
	print("    CONTROL net erosion spans %.0f%% across the sweep (must be well above 0)" % (cut * 100.0))
	if cut < 0.05:
		_fail += 1
		print("    !! G barely changes how much is removed; monotonicity here is measuring noise")


# --- BU: convergence degrades with G, is reported, and is capped ------------------------------------
#
# The published caveat, and the reason the sweep count is reported at all: the Gauss-Seidel iteration
# converges in about one sweep near G = 0 and twenty near G = 1. An artist who asks for something the
# solver cannot deliver in bounded time has to be TOLD, not silently handed something else — the same
# rule §4.4's diffusion sub-stepping already follows.
func _gate_bu_convergence_and_the_cap() -> void:
	print("\n[BU] the sweep count tracks G, is reported, and is bounded:")
	var z0 := _slope_break()
	var counts: Array[int] = []
	var gs: Array[float] = [0.1, 0.4, 0.7, 0.95]
	for g in gs:
		var p := ERODE.duplicate()
		p["deposition"] = g
		var res := _solve(z0, p)
		if res.is_empty():
			return
		var n := int(res.get("deposition_sweeps", -1))
		counts.append(n)
		print("    G = %.2f: %d sweeps, capped = %s" % [g, n, str(bool(res.get("deposition_capped", false)))])
		if n < 1:
			_fail += 1
			print("    !! no sweeps reported at G > 0; the count is not being plumbed out")
		if n > 50:
			_fail += 1
			print("    !! the sweep count exceeded the ceiling, so the ceiling is not a ceiling")

	# The criterion: cost rises with G. Not strictly per-step — the fixture can converge in the same
	# count over two neighbouring values — but the ends must differ, which is the published behaviour.
	print("    sweeps at G=0.10 -> G=0.95: %d -> %d" % [counts[0], counts[counts.size() - 1]])
	if counts[counts.size() - 1] <= counts[0]:
		_fail += 1
		print("    !! high G is no more expensive than low G, which contradicts the scheme — the")
		print("       iteration is probably terminating on something other than convergence")

	# CONTROL — a moderate G must converge UNDER the ceiling and report capped = false. A cap that is
	# always hit is not a cap, and a `capped` flag that is always true tells nobody anything.
	var p_mid := ERODE.duplicate()
	p_mid["deposition"] = 0.3
	var mid := _solve(z0, p_mid)
	if mid.is_empty():
		return
	var capped := bool(mid.get("deposition_capped", false))
	print("    CONTROL G = 0.30 converges under the ceiling: capped = %s (want false)" % str(capped))
	if capped:
		_fail += 1
		print("    !! even a moderate G hits the ceiling; the ceiling is too low to be useful")


# --- BV: cost stays close to linear in cell count ----------------------------------------------------
#
# PERF GATE — OFF BY DEFAULT. Benchmarks on this machine need the user's go-ahead before running
# (another engine shares the box), so this is called with `false` and prints what it would do.
func _gate_bv_cost(p_run: bool) -> void:
	print("\n[BV] cost against grid size — PERF GATE")
	if not p_run:
		print("    SKIPPED. Perf gates need the user's go-ahead on this machine. Enable by calling")
		print("    _gate_bv_cost(true): it solves 64/128/256 grids at fixed G and reports ms per cell,")
		print("    with the control that raising G toward the transport-limited end must visibly")
		print("    degrade convergence — if it does not, the timing is not measuring the iteration.")
		return
	var sizes: Array[int] = [64, 128, 256]
	for s in sizes:
		var z0 := _slope_break_at(s)
		var p := ERODE.duplicate()
		p["deposition"] = 0.5
		p["gw"] = s
		p["gh"] = s
		p["cell_size"] = SCELL
		var t0 := Time.get_ticks_usec()
		var res: Dictionary = _data.erode_heightfield(z0, p, PackedFloat32Array())
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		print("    %d^2 = %d cells: %.1f ms (%.4f us/cell), %d sweeps"
				% [s, s * s, ms, ms * 1000.0 / float(s * s), int(res.get("deposition_sweeps", 0))])


# --- fixtures and helpers ---------------------------------------------------------------------------

## A steep upper slope grading into a near-flat plain at BREAK_ROW, draining in +Z.
##
## The slope break is the point: a channel carrying its load off steep ground onto a shallow gradient is
## exactly where a real one drops it, so this fixture has a place deposition MUST appear and a place it
## must not. A uniform plane would erode and transport but give the gate nowhere to look.
##
## The lower half is not perfectly flat — a dead-flat region is one enormous depression-fill and the
## routing through it says more about the flood than about transport.
func _slope_break() -> PackedFloat32Array:
	return _slope_break_at(SG)


func _slope_break_at(p_n: int) -> PackedFloat32Array:
	var z := PackedFloat32Array()
	z.resize(p_n * p_n)
	var brk := int(float(BREAK_ROW) / float(SG) * float(p_n))
	var steep := 1.2 # metres of fall per row above the break
	var shallow := 0.05 # and below it
	# Coherent relief on top, so flow organises into channels instead of marching down in columns.
	var n := FastNoiseLite.new()
	n.seed = 4242
	n.frequency = 0.004
	n.fractal_octaves = 3
	for iz in range(p_n):
		var v: float = BASE_Z + (steep * float(brk - iz) if iz < brk else shallow * float(brk - iz))
		for ix in range(p_n):
			z[iz * p_n + ix] = v + n.get_noise_2d(float(ix) * SCELL, float(iz) * SCELL) * 6.0
	return z


func _solve(p_z: PackedFloat32Array, p_params: Dictionary) -> Dictionary:
	var params := p_params.duplicate()
	params["gw"] = SG
	params["gh"] = SG
	params["cell_size"] = SCELL
	var res: Dictionary = _data.erode_heightfield(p_z, params, PackedFloat32Array())
	if not bool(res.get("ok", false)):
		_fail += 1
		print("    !! the solver rejected the %dx%d grid" % [SG, SG])
		return {}
	return res


func _delta(p_before: PackedFloat32Array, p_after: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_before.size())
	for i in range(p_before.size()):
		out[i] = p_after[i] - p_before[i]
	return out


## Total metres GAINED over rows [from, to). Deposition, as §8.2 decision 3 defines it.
func _sum_positive(p_d: PackedFloat32Array, p_from: int, p_to: int) -> float:
	var s := 0.0
	for iz in range(p_from, p_to):
		for ix in range(SG):
			var v := p_d[iz * SG + ix]
			if is_finite(v) and v > 0.0:
				s += v
	return s


## Total metres REMOVED over rows [from, to), as a positive number.
func _sum_negative(p_d: PackedFloat32Array, p_from: int, p_to: int) -> float:
	var s := 0.0
	for iz in range(p_from, p_to):
		for ix in range(SG):
			var v := p_d[iz * SG + ix]
			if is_finite(v) and v < 0.0:
				s -= v
	return s


## Cells that gained more than a float32 rounding's worth. The threshold is not cosmetic: at 200 m the
## float32 spacing is ~1.5e-5, so anything under that is the storage, not the solver.
func _count_risen(p_d: PackedFloat32Array) -> int:
	var n := 0
	for v in p_d:
		if is_finite(v) and v > 1.0e-4:
			n += 1
	return n


func _bitwise_same(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> bool:
	if p_a.size() != p_b.size():
		return false
	return p_a.to_byte_array() == p_b.to_byte_array()


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var worst := 0.0
	for i in range(mini(p_a.size(), p_b.size())):
		if is_finite(p_a[i]) and is_finite(p_b[i]):
			worst = maxf(worst, absf(p_a[i] - p_b[i]))
	return worst
