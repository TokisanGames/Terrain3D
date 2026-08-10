# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Phase 1 gates A-K for Pasture3DSim (PASTURE3D_SIM_NODE_SPEC.md §14).
#
# Two families:
#   A-F, I-K  drive the solver DIRECTLY (Pasture3DData.erode_heightfield) on synthetic fields — a bowl,
#             a tilted plane, a dome. The solver is a pure function of a heightfield precisely so these
#             can measure it without a bake in the way.
#   G, H      drive a real Pasture3DSim node on the demo terrain, because masking and idempotency are
#             claims about the LAYER, not about the maths.
#
# Every criterion carries a control that must fail if the thing it guards is absent, and every one
# asserts it measured something before it reports agreement — a gate that passes on a field of zeros is
# not a gate. Two of the phase-1 criteria (E, J) were vacuous until their controls were written.
#
# NOTHING IS SAVED. Bakes write into the terrain's in-memory layer; demo/data on disk is only touched
# by an explicit save, which nothing here calls.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/SimPhase1Gate.tscn
extends Node

const DEMO_DATA := "res://demo/data"

## Synthetic grid for the solver gates. 128² = 16k cells: big enough for a network to organise, small
## enough that all of A-K runs in a couple of seconds.
const SG := 128
const SCELL := 4.0

## Node-gate sites, inside the loaded demo regions (X 0..1024, Z -2048..1024) and far enough apart that
## their tile-snapped clear boxes cannot touch. PondCarveCheck / PlowReliefCheck proved this band.
const SITE_MASK := Vector3(300.0, 0.0, 300.0)
const SITE_IDEMPOTENT := Vector3(700.0, 0.0, 300.0)
const SITE_PREVIEW := Vector3(500.0, 0.0, 620.0)
## The (rate, diffusion, iterations) triple that bench/SimFieldProbe.tscn's hillshade sweep showed
## produces a recognisable valley network on the rolling fixture: branching channels with sharp
## interfluves. Ten times the rate grades the whole hillside flat; a quarter of it leaves the fixture's
## own noise still dominant. E, J and K all run here so they measure the solver where it is doing the
## job it exists for, not at a setting nobody would ship.
const EROSIVE := {"iterations": 40, "erosion_rate": 0.2, "area_exponent": 0.45, "diffusion": 0.5}

## Node-gate loop half-extent and margin. Deliberately small: G and H test plumbing, not landscapes.
const LOOP_HALF := 60.0
const NODE_MARGIN := 40.0

var _fail := 0
var _root: Node3D
var _terrain
var _data


func _ready() -> void:
	print("\n=== Pasture3DSim phase 1 (spec §14 gates A-K) ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_data = _terrain.data
	if _data == null or not _data.has_method("erode_heightfield"):
		_fail += 1
		print("!! this build has no erode_heightfield — the whole phase is unbuilt, not failing")
		_done()
		return

	_gate_a_forest()
	_gate_b_fill_depth()
	_gate_c_area_conservative()
	_gate_d_incision_law()
	_gate_e_dendritic()
	_gate_f_erodability()
	_gate_g_boundary()
	_gate_h_idempotent()
	_gate_i_deterministic()
	_gate_j_preview_vs_build()
	_gate_k_monotone()

	_done()


func _done() -> void:
	print("\n=== %s (%d failures) ===\n" % ["SIM PHASE 1 PASS" if _fail == 0 else "SIM PHASE 1 FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- A: the router is a valid forest --------------------------------------------------------------
# Every cell has exactly one receiver, no path cycles, and every path ends on the domain boundary.
# CONTROL: skip the depression fill. A pit floor then has no downhill neighbour at all, so it becomes
# a root that is not a boundary cell — which is precisely what "valid forest" excludes.
func _gate_a_forest() -> void:
	print("[A] the router is a valid forest (filled surface, D8 receivers):")
	var z := _plane_with_bowl(0.1, 28.0, 30.0)
	var filled := _solve(z, {"iterations": 0, "want_diagnostics": true})
	if filled.is_empty():
		return
	var pit_depth: float = _max_of(filled["lake_depth"])
	print("    the fixture really has a pit: max fill depth %.2f m" % pit_depth)
	if pit_depth < 5.0:
		_fail += 1
		print("    !! the bowl fixture is flat; A would pass on a field with nothing to trap")
		return

	var bad := _forest_faults(filled)
	print("    filled:   %d orphan roots, %d non-terminating walks, stack %d of %d cells" % [
			bad[0], bad[1], bad[2], SG * SG])
	if bad[0] != 0 or bad[1] != 0 or bad[2] != SG * SG:
		_fail += 1
		print("    !! the routing forest is not valid")

	# CONTROL
	var raw := _solve(z, {"iterations": 0, "want_diagnostics": true, "fill_depressions": false})
	if raw.is_empty():
		return
	var bad_raw := _forest_faults(raw)
	print("    CONTROL unfilled: %d orphan roots (want > 0), stack %d" % [bad_raw[0], bad_raw[2]])
	if bad_raw[0] == 0:
		_fail += 1
		print("    !! removing the depression fill produced no orphans; the gate cannot see a broken forest")


## [orphan_roots, non_terminating_walks, stack_size] for a diagnostics dictionary. An orphan root is a
## cell that receives itself without being on the boundary — a pit with nowhere to drain.
func _forest_faults(p_res: Dictionary) -> Array:
	var recv: PackedInt32Array = p_res["receiver"]
	var bnd: PackedByteArray = p_res["boundary"]
	var stack: PackedInt32Array = p_res["stack"]
	var n := SG * SG
	var orphans := 0
	for i in range(n):
		if recv[i] == i and bnd[i] == 0:
			orphans += 1
	# Walk from a spread of interior cells; every path must reach a boundary cell inside n steps (a
	# cycle would spin until the cap, which counts as non-terminating).
	var stuck := 0
	var walked := 0
	for iz in range(1, SG - 1, 7):
		for ix in range(1, SG - 1, 7):
			var i := iz * SG + ix
			walked += 1
			var steps := 0
			while bnd[i] == 0 and steps < n:
				var r := recv[i]
				if r == i:
					break
				i = r
				steps += 1
			if bnd[i] == 0:
				stuck += 1
	if walked == 0:
		stuck = -1 # measured nothing; surfaces as a failure below
	return [orphans, stuck, stack.size()]


# --- B: depression fill equals basin depth ---------------------------------------------------------
# A bowl of depth D cut into a plane of slope s spills over its downhill rim, so the standing water at
# the centre is D - s*R deep, not D. Measuring against the analytic spill level rather than D is the
# whole point: a fill that simply flooded to the bowl's own rim height would pass a D-only check.
# CONTROL: the same plane with no bowl fills to nothing, so a run of zeros reads as "measured nothing".
func _gate_b_fill_depth() -> void:
	print("\n[B] depression fill == basin depth (analytic spill level):")
	var slope := 0.1
	var radius := 30.0
	var depth := 28.0
	var expect := depth - slope * radius
	var z := _plane_with_bowl(slope, depth, radius)
	var res := _solve(z, {"iterations": 0, "want_diagnostics": true})
	if res.is_empty():
		return
	var lake: PackedFloat32Array = res["lake_depth"]
	var centre := (SG / 2) * SG + (SG / 2)
	print("    lake_depth at the bowl centre: %.3f m (want %.3f, tol 1.0)" % [lake[centre], expect])
	if absf(lake[centre] - expect) > 1.0:
		_fail += 1
		print("    !! the fill level does not match the bowl's spill point")

	# CONTROL
	var flat := _plane_with_bowl(slope, 0.0, radius)
	var res2 := _solve(flat, {"iterations": 0, "want_diagnostics": true})
	if res2.is_empty():
		return
	var max_flat: float = _max_of(res2["lake_depth"])
	print("    CONTROL no basin: max lake_depth %.5f m (want ~0)" % max_flat)
	if max_flat > 0.01:
		_fail += 1
		print("    !! a basin-free plane still filled; lake_depth is not measuring depressions")


# --- C: drainage area is conservative --------------------------------------------------------------
# Everything that falls on the domain leaves through an outlet, so the areas accumulated at the roots
# must sum to exactly the domain area.
# CONTROL: accumulate the tree in the wrong direction. Each cell then hands its area upward before its
# own donors have contributed, and the outlet totals fall far short.
func _gate_c_area_conservative() -> void:
	print("\n[C] drainage area is conservative (Σ area at the outlets == domain area):")
	var z := _plane_with_bowl(0.1, 20.0, 24.0)
	var res := _solve(z, {"iterations": 0, "want_diagnostics": true})
	if res.is_empty():
		return
	var domain := float(SG * SG) * SCELL * SCELL
	var total := _outlet_total(res)
	var max_a: float = _max_of(res["flow"])
	print("    Σ at outlets %.1f m² vs domain %.1f m² (rel err %.9f)" % [
			total, domain, absf(total - domain) / domain])
	print("    largest single-cell area %.1f m² = %.1f cells (accumulation really happened)" % [
			max_a, max_a / (SCELL * SCELL)])
	if max_a <= 10.0 * SCELL * SCELL:
		_fail += 1
		print("    !! no accumulation to conserve; C would pass on a field where nothing flows")
	if absf(total - domain) / domain > 1.0e-4:
		_fail += 1
		print("    !! drainage area is not conserved")

	# CONTROL
	var bad := _solve(z, {"iterations": 0, "want_diagnostics": true, "break_stack_order": true})
	if bad.is_empty():
		return
	var bad_total := _outlet_total(bad)
	print("    CONTROL wrong traversal order: Σ %.1f m² (rel err %.3f, want large)" % [
			bad_total, absf(bad_total - domain) / domain])
	if absf(bad_total - domain) / domain < 0.01:
		_fail += 1
		print("    !! breaking the topological order changed nothing; the gate is not reading the order")


func _outlet_total(p_res: Dictionary) -> float:
	var recv: PackedInt32Array = p_res["receiver"]
	var flow: PackedFloat32Array = p_res["flow"]
	var total := 0.0
	for i in range(SG * SG):
		if recv[i] == i:
			total += flow[i]
	return total


# --- D: incision follows the stream-power law -------------------------------------------------------
# On a uniformly tilted plane, flow runs in parallel columns, so the cell in row j carries exactly j
# cells of upstream area. Doubling j must therefore multiply the incision by 2^m.
# CONTROL: K = 0 removes incision everywhere, so the ratio has nothing to measure.
func _gate_d_incision_law() -> void:
	print("\n[D] incision scales with A^m (parallel flow on a tilted plane):")
	var m := 0.45
	var z := _tilted_plane(1.0)
	# The rate has to sit in a window at BOTH ends. Too large and one row's incision perturbs the next
	# row's drop, so the analytic small-K ratio 2^m stops applying; too small and the incision falls
	# under the float32 resolution of a ~200 m elevation and both rows round to the same value — which
	# is exactly how this gate first read a ratio of exactly 1.0000 with nothing wrong with the solver.
	var p := {"iterations": 1, "erosion_rate": 1.0e-3, "area_exponent": m, "diffusion": 0.0}
	var res := _solve(z, p)
	if res.is_empty():
		return
	var zo: PackedFloat32Array = res["z"]
	var col := SG / 2
	var inc_10 := _row_incision(z, zo, 10, col)
	var inc_20 := _row_incision(z, zo, 20, col)
	var ratio := inc_20 / maxf(inc_10, 1.0e-12)
	print("    incision at 10 cells upstream %.7f m, at 20 cells %.7f m" % [inc_10, inc_20])
	print("    ratio %.4f (want 2^%.2f = %.4f, tol 0.05)" % [ratio, m, pow(2.0, m)])
	if inc_10 <= 0.0:
		_fail += 1
		print("    !! nothing incised; the ratio would be meaningless")
	elif absf(ratio - pow(2.0, m)) > 0.05:
		_fail += 1
		print("    !! incision does not follow A^m")

	# CONTROL
	var zero := _solve(z, {"iterations": 1, "erosion_rate": 0.0, "area_exponent": m, "diffusion": 0.0})
	if zero.is_empty():
		return
	var c10 := _row_incision(z, zero["z"], 10, col)
	print("    CONTROL K=0: incision %.7f m (want exactly 0)" % c10)
	if c10 != 0.0:
		_fail += 1
		print("    !! K=0 still incised; the probe is not reading this solve's output")


func _row_incision(p_before: PackedFloat32Array, p_after: PackedFloat32Array, p_row: int, p_col: int) -> float:
	var i := p_row * SG + p_col
	return p_before[i] - p_after[i]


# --- E: networks are dendritic ----------------------------------------------------------------------
# Two claims, because either one alone is satisfiable by an accident.
#
#   E1 HEAVY TAIL (the spec's criterion). Drainage area concentrates: one cell drains a large share of
#      the domain, which is only possible if tributaries have joined into trunks.
#   E2 FLUVIALLY GRADED. The eroded surface obeys the slope-area scaling S ~ A^-m that stream power
#      drives it towards: regress log(slope) on log(area) and the exponent must be clearly negative.
#      This is the textbook signature of a fluvial landscape, and it is what separates "a valley
#      network was carved" from "the whole area was lowered".
#
# CONTROLS. E1 takes the spec's: a UNIFORM tilted plane, one iteration, where flow is strictly parallel
# so no cell drains more than its own column. E2 takes TWO, because it needs both halves — the same
# uniform plane (nothing to grade), and the fixture BEFORE erosion (its channels follow the noise's low
# ground already, so the gate has to show the scaling is not simply inherited from the fixture).
#
# TWO earlier versions of E2 were vacuous, and how they failed is worth keeping written down. The first
# measured the GROWTH of the largest catchment — but a noisy hillside already carries a random
# confluence network before a single iteration runs (0.47 of the domain in one trunk on this fixture),
# so the growth was x1.01 and the statistic was reading the fixture, not the solver. The second
# compared mean incision in channel cells against ridge cells and came out NEGATIVE: with no uplift the
# HILLSLOPES start furthest above their graded profile and so lose the most material, which says
# nothing about whether a valley exists. Both reported "no valleys" on a run whose hillshade is
# unmistakably a dendritic valley network (bench/SimFieldProbe.tscn writes that image).
func _gate_e_dendritic() -> void:
	print("\n[E] the network is dendritic (heavy-tailed area; a fluvially graded surface):")
	var z := _noisy_slope()
	var before := _solve(z, EROSIVE.merged({"iterations": 0, "want_diagnostics": true}, true))
	var after := _solve(z, EROSIVE.merged({"want_diagnostics": true}, true))
	if before.is_empty() or after.is_empty():
		return
	var domain := float(SG * SG) * SCELL * SCELL
	var share: float = _max_of(after["flow"]) / domain
	var beta_before := _slope_area_exponent(z, before)
	var beta_after := _slope_area_exponent(after["z"], after)
	print("    E1 largest catchment = %.4f of the domain (want > 0.05; one column would be %.4f)" % [
			share, 1.0 / float(SG)])
	print("    E2 slope-area exponent: %+.3f before -> %+.3f after (want < -0.20; theory is -m = %.2f)" % [
			beta_before, beta_after, -float(EROSIVE["area_exponent"])])
	if share <= 0.05:
		_fail += 1
		print("    !! no trunk: the largest catchment is barely more than a single column")
	if beta_after >= -0.20:
		_fail += 1
		print("    !! the surface is not graded to the drainage network; this is a lowering, not valleys")
	if absf(beta_before) >= 0.05:
		_fail += 1
		print("    !! the fixture already obeyed the scaling before erosion; E2 is reading the fixture")

	# CONTROL
	var flat := _tilted_plane(1.0)
	var cres := _solve(flat, EROSIVE.merged({"iterations": 1, "want_diagnostics": true}, true))
	if cres.is_empty():
		return
	var c_share: float = _max_of(cres["flow"]) / domain
	var c_beta := _slope_area_exponent(cres["z"], cres)
	print("    CONTROL uniform plane, 1 iteration: share %.4f (want ~%.4f), exponent %+.3f (want ~0)" % [
			c_share, 1.0 / float(SG), c_beta])
	if c_share > 0.02:
		_fail += 1
		print("    !! parallel flow on a plane still concentrated; E1 is not measuring confluence")
	if c_beta <= -0.05:
		_fail += 1
		print("    !! a plane with no channels still measured as graded; E2 is not measuring the scaling")


## Least-squares slope of log(local gradient) against log(drainage area) over the interior cells.
##
## Stream power drives a landscape towards S = (U/K)^(1/n) * A^(-m/n), so with n = 1 the exponent
## approaches -m. Zero means slope and catchment size are unrelated, which is what a noise field looks
## like. Cells with no measurable gradient are skipped rather than clamped: log(0) would otherwise be
## the whole answer.
func _slope_area_exponent(p_z: PackedFloat32Array, p_res: Dictionary) -> float:
	var flow: PackedFloat32Array = p_res["flow"]
	var bnd: PackedByteArray = p_res["boundary"]
	var xs := PackedFloat32Array()
	var ys := PackedFloat32Array()
	for iz in range(1, SG - 1):
		for ix in range(1, SG - 1):
			var i := iz * SG + ix
			if bnd[i] != 0 or flow[i] <= 0.0:
				continue
			var gx: float = (p_z[i + 1] - p_z[i - 1]) / (2.0 * SCELL)
			var gz: float = (p_z[i + SG] - p_z[i - SG]) / (2.0 * SCELL)
			var grad := sqrt(gx * gx + gz * gz)
			if grad < 1.0e-6:
				continue
			xs.append(log(flow[i]))
			ys.append(log(grad))
	if xs.size() < 100:
		return 0.0
	var n := float(xs.size())
	var mx := 0.0
	var my := 0.0
	for i in range(xs.size()):
		mx += xs[i]
		my += ys[i]
	mx /= n
	my /= n
	var sxy := 0.0
	var sxx := 0.0
	for i in range(xs.size()):
		var dx := xs[i] - mx
		sxy += dx * (ys[i] - my)
		sxx += dx * dx
	return sxy / maxf(sxx, 1.0e-9)


# --- F: erodability varies erosion spatially --------------------------------------------------------
# Vertical stripes: the left half of the map maps to the soft end of Erodability Range, the right half
# to the hard end. Flow runs down +Z, so the two halves are statistically identical topography and any
# difference in how much they lower is the map's doing.
# CONTROL: a uniform map. Both halves must then erode the same, which is what separates "the mask works"
# from "the sim ran".
func _gate_f_erodability() -> void:
	print("\n[F] erodability varies erosion spatially (soft stripe vs hard stripe):")
	var z := _tilted_plane(1.0)
	var p := {"iterations": 12, "erosion_rate": 0.004, "area_exponent": 0.45, "diffusion": 0.0,
			"erodability_min": 0.25, "erodability_max": 2.0, "erodability_w": 2, "erodability_h": 2}
	var striped := PackedFloat32Array([0.0, 1.0, 0.0, 1.0]) # left column 0 (hard), right column 1 (soft)
	var res := _solve(z, p, striped)
	if res.is_empty():
		return
	var hard := _mean_incision(z, res["z"], 0, SG / 4)
	var soft := _mean_incision(z, res["z"], 3 * SG / 4, SG - 1)
	print("    mean incision  hard band %.4f m | soft band %.4f m (x%.2f)" % [
			hard, soft, soft / maxf(hard, 1.0e-12)])
	if hard <= 0.0 or soft <= 0.0:
		_fail += 1
		print("    !! one of the bands did not erode at all; the comparison measured nothing")
	elif soft / hard < 2.0:
		_fail += 1
		print("    !! the soft band did not erode measurably more; the erodability map is not reaching K")

	# CONTROL
	var uniform := PackedFloat32Array([0.5, 0.5, 0.5, 0.5])
	var res2 := _solve(z, p, uniform)
	if res2.is_empty():
		return
	var u_left := _mean_incision(z, res2["z"], 0, SG / 4)
	var u_right := _mean_incision(z, res2["z"], 3 * SG / 4, SG - 1)
	print("    CONTROL uniform map: left %.4f | right %.4f (ratio %.3f, want ~1)" % [
			u_left, u_right, u_right / maxf(u_left, 1.0e-12)])
	if absf(u_right / maxf(u_left, 1.0e-12) - 1.0) > 0.15:
		_fail += 1
		print("    !! a uniform map still eroded the halves differently; F was reading the topography")


## Mean lowering over a column band, excluding the fixed boundary rows.
func _mean_incision(p_before: PackedFloat32Array, p_after: PackedFloat32Array, p_x0: int, p_x1: int) -> float:
	var total := 0.0
	var n := 0
	for iz in range(1, SG - 1):
		for ix in range(maxi(p_x0, 1), mini(p_x1, SG - 2) + 1):
			var i := iz * SG + ix
			total += p_before[i] - p_after[i]
			n += 1
	return total / maxf(float(n), 1.0)


# --- G: the boundary is clean -----------------------------------------------------------------------
# The catchment margin is simulated over and never written. Outside the loop the layer must hold
# nothing at all, so the composited height is bit-for-bit the ground that was there.
# CONTROL: bypass the mask — write the same delta grid over the whole margin through apply_sim_block
# directly. The outside probe must then move, proving the probe can see a leak when there is one.
func _gate_g_boundary() -> void:
	print("\n[G] the delta stops at the loop (the catchment margin is never written):")
	var sim = _make_sim("MaskGate", SITE_MASK)
	if sim == null:
		return
	var inside := SITE_MASK
	var outside := SITE_MASK + Vector3(LOOP_HALF + 20.0, 0.0, 0.0) # past the loop, inside the margin
	var base: Array[float] = [_height(inside), _height(outside)]

	var report: Dictionary = sim.simulate_now(1, false)
	if not bool(report.get("ok", false)):
		_fail += 1
		print("    !! the simulation did not run: %s" % report.get("reason", "?"))
		return
	var d_in := _height(inside) - base[0]
	var d_out := _height(outside) - base[1]
	print("    inside delta  %+.4f m | outside delta %+.6f m (want exactly 0 outside)" % [d_in, d_out])
	if absf(d_in) < 0.05:
		_fail += 1
		print("    !! nothing eroded inside the loop; there is no boundary to test")
	if d_out != 0.0:
		_fail += 1
		print("    !! the erosion leaked past the loop into the catchment margin")

	# CONTROL — the same write path with no mask at all.
	var layer_id: int = sim._ensure_layer_for(sim._layer_owner, true)
	var vs: float = _terrain.vertex_spacing
	var box: AABB = sim._spline_footprint_aabb(sim._get_splines()[0]).grow(NODE_MARGIN)
	var b: Array = sim._snapped_bounds(box, vs)
	var gw := int(round((b[1] - b[0]) / vs)) + 1
	var gh := int(round((b[3] - b[2]) / vs)) + 1
	var flat := PackedFloat32Array()
	flat.resize(gw * gh)
	flat.fill(-1.0)
	_data.apply_sim_block(layer_id, b[0], b[2], vs, gw, gh, flat, 1)
	_data.composite_area(sim._snap_aabb_to_tiles(box, sim._layer_tile_world(layer_id)), false)
	_data.update_maps(0)
	var leak := _height(outside) - base[1]
	print("    CONTROL unmasked write: outside delta %+.4f m (want non-zero)" % leak)
	if absf(leak) < 0.5:
		_fail += 1
		print("    !! bypassing the mask changed nothing outside; the probe cannot detect a leak")
	sim.clear_simulation()

	# CONTROL — a null solve. With K = 0 and D = 0 the solver returns its input untouched, so the delta
	# is identically zero and the write path must leave the layer completely alone, INSIDE the loop too.
	#
	# This is the criterion that caught the real bug in this pipeline: sim_mask_deltas was writing the
	# post-solve ELEVATION instead of the elevation minus its baseline, so every run stamped absolute
	# heights (a 173 m "delta" on a null solve) into an ADD-blend layer. Every other gate still passed —
	# they all assert that something moved, and something certainly had.
	sim.erosion_rate = 0.0
	sim.hillslope_diffusion = 0.0
	if not bool(sim.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the null solve did not run")
		return
	var null_in := _height(inside) - base[0]
	var null_out := _height(outside) - base[1]
	print("    CONTROL K=0, D=0: inside %+.6f m | outside %+.6f m (want exactly 0, 0)" % [null_in, null_out])
	if null_in != 0.0 or null_out != 0.0:
		_fail += 1
		print("    !! a solve that changed nothing still wrote to the layer")
	sim.clear_simulation()


# --- H: idempotent -----------------------------------------------------------------------------------
# Re-running with identical parameters must reproduce the surface exactly, because the initial elevation
# comes from composite_height_below — the ground UNDER Sim's own layer — and never from the composite
# Sim has already written into.
# CONTROL: seed the solve from the full composite instead, with the previous bake still in the layer.
# That is the ordering mistake the spec warns about, and it must visibly creep.
func _gate_h_idempotent() -> void:
	print("\n[H] re-running reproduces the surface (initial z comes from below Sim's layer):")
	var sim = _make_sim("IdempotentGate", SITE_IDEMPOTENT)
	if sim == null:
		return
	var probes: Array[Vector3] = []
	for i in range(-2, 3):
		for j in range(-2, 3):
			probes.append(SITE_IDEMPOTENT + Vector3(i * 12.0, 0.0, j * 12.0))
	var base := _snapshot(probes)

	if not bool(sim.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the first simulation did not run")
		return
	var run1 := _snapshot(probes)
	var moved := _max_abs_diff(run1, base)
	print("    the first run really moved the ground: max |delta| %.4f m" % moved)
	if moved < 0.05:
		_fail += 1
		print("    !! nothing was baked, so H would pass by comparing two untouched surfaces")
		return

	sim.simulate_now(1, false)
	var run2 := _snapshot(probes)
	var drift := _max_abs_diff(run2, run1)
	print("    re-run drift: max %.6f m (tol 1e-3)" % drift)
	if drift > 1.0e-3:
		_fail += 1
		print("    !! the bake is not idempotent; Sim is eroding its own output")

	# CONTROL — the wrong source, twice.
	var c1 := _wrong_source_run(sim, probes)
	var c2 := _wrong_source_run(sim, probes)
	if c1.is_empty() or c2.is_empty():
		_fail += 1
		print("    !! the control could not run; H has no evidence that drift is detectable")
	else:
		var c_drift := _max_abs_diff(c2, c1)
		print("    CONTROL seeded from the full composite: drift %.6f m (want > 1e-3)" % c_drift)
		if c_drift <= 1.0e-3:
			_fail += 1
			print("    !! reading the composite did not drift; the drift check is not sensitive")
	sim.clear_simulation()


## One pass of the WRONG pipeline: read the initial surface from the finished composite (which already
## holds the previous bake) BEFORE clearing, then solve, mask and write. Returns the probe heights.
func _wrong_source_run(p_sim, p_probes: Array[Vector3]) -> Array[float]:
	var empty: Array[float] = []
	var vs: float = _terrain.vertex_spacing
	var splines: Array = p_sim._get_splines()
	if splines.is_empty():
		return empty
	var path: Path3D = splines[0]
	var layer_id: int = p_sim._ensure_layer_for(p_sim._layer_owner, true)
	if layer_id <= 0:
		return empty
	var wb: Array = p_sim._snapped_bounds(p_sim._spline_footprint_aabb(path), vs)
	var sb: Array = p_sim._snapped_bounds(p_sim._spline_footprint_aabb(path).grow(NODE_MARGIN), vs)
	var gw := int(round((wb[1] - wb[0]) / vs)) + 1
	var gh := int(round((wb[3] - wb[2]) / vs)) + 1
	var tw := int(round((sb[1] - sb[0]) / vs)) + 1
	var th := int(round((sb[3] - sb[2]) / vs)) + 1
	# THE BUG, on purpose: the live composite, read while the previous bake is still in the layer.
	var z0 := PackedFloat32Array()
	z0.resize(tw * th)
	for iz in range(th):
		for ix in range(tw):
			z0[iz * tw + ix] = _data.get_height(Vector3(sb[0] + ix * vs, 0.0, sb[2] + iz * vs))
	var res: Dictionary = _data.erode_heightfield(z0, {
			"gw": tw, "gh": th, "cell_size": vs, "iterations": p_sim.iterations,
			"erosion_rate": p_sim.erosion_rate, "area_exponent": p_sim.area_exponent,
			"diffusion": p_sim.hillslope_diffusion})
	if not bool(res.get("ok", false)):
		return empty
	var poly: PackedVector2Array = p_sim._polygon_xz(path)
	var write: PackedFloat32Array = _data.sim_mask_deltas(res["z"], poly, {
			"sw": tw, "sh": th, "gw": gw, "gh": gh,
			"sim_min_x": sb[0], "sim_min_z": sb[2], "sim_cell": vs,
			"min_x": wb[0], "min_z": wb[2], "vs": vs,
			"edge_offset": p_sim.edge_offset, "falloff_width": p_sim.falloff_width,
			"baseline": z0}, p_sim._ramp_lut(p_sim.falloff_curve))
	var clip: AABB = p_sim._snap_aabb_to_tiles(p_sim._spline_footprint_aabb(path), p_sim._layer_tile_world(layer_id))
	_data.clear_layer_in_area(layer_id, clip)
	_data.apply_sim_block(layer_id, wb[0], wb[2], vs, gw, gh, write, 1)
	_data.composite_area(clip, false)
	_data.update_maps(0)
	return _snapshot(p_probes)


# --- I: deterministic ---------------------------------------------------------------------------------
# Two runs with identical parameters must be bitwise identical: no hash-ordered iteration, no
# elevation tie broken by whatever the heap felt like.
# CONTROL: perturb one cell by a millimetre. The comparison must then report a difference — otherwise
# "bitwise identical" is a claim about the comparator, not about the solver.
func _gate_i_deterministic() -> void:
	print("\n[I] two runs with the same parameters are bitwise identical:")
	var z := _noisy_slope()
	var p := EROSIVE.merged({"want_diagnostics": true}, true)
	var a := _solve(z, p)
	var b := _solve(z, p)
	if a.is_empty() or b.is_empty():
		return
	var za: PackedFloat32Array = a["z"]
	var zb: PackedFloat32Array = b["z"]
	var diff := 0
	for i in range(za.size()):
		if za[i] != zb[i]:
			diff += 1
	var stack_diff := 0
	var sa: PackedInt32Array = a["stack"]
	var sb2: PackedInt32Array = b["stack"]
	for i in range(sa.size()):
		if sa[i] != sb2[i]:
			stack_diff += 1
	print("    %d of %d elevations differ, %d of %d stack entries differ (want 0, 0)" % [
			diff, za.size(), stack_diff, sa.size()])
	if diff != 0 or stack_diff != 0:
		_fail += 1
		print("    !! the solve is not deterministic")

	# CONTROL
	var z2 := z.duplicate()
	z2[(SG / 2) * SG + (SG / 2)] += 0.001
	var c := _solve(z2, p)
	if c.is_empty():
		return
	var zc: PackedFloat32Array = c["z"]
	var cdiff := 0
	for i in range(za.size()):
		if za[i] != zc[i]:
			cdiff += 1
	print("    CONTROL one cell nudged by 1 mm: %d elevations differ (want > 0)" % cdiff)
	if cdiff == 0:
		_fail += 1
		print("    !! the comparison cannot see a difference, so 'identical' means nothing here")


# --- J: preview agrees with build on large-scale structure -------------------------------------------
# §6 makes a careful claim and this gate must test THAT claim: a coarse D8 grid finds slightly
# different channels, so a preview is REPRESENTATIVE of a build, not identical to it. The measurable
# form of "the large-scale structure agrees" is the spatial correlation of the two delta fields after a
# low-pass, and it must be high at the stated feature scale.
# CONTROL: the same correlation at full resolution. It must be clearly lower - otherwise the low-pass
# was a no-op and the gate was quietly asserting something it never measured.
#
# Correlation and NOT relative RMS, which is what the first version used. The preview also erodes
# DEEPER than the build, so RMS(a-b)/RMS(a) sat near 1.0 at every scale and reported total
# disagreement while the correlation was in fact climbing from 0.74 to 0.95: it was measuring the
# magnitude gap and calling it a structural one.
func _gate_j_preview_vs_build() -> void:
	print("\n[J] the preview agrees with the build on large-scale structure:")
	var z := _noisy_slope()
	var build := _solve(z, EROSIVE)
	if build.is_empty():
		return
	var d_build := _delta(z, build["z"])

	# The preview: the SAME field downsampled 4x, solved on the coarse grid, upsampled back - exactly
	# what Pasture3DSim.preview_simulation does.
	var coarse_n := (SG - 1) / 4 + 1
	var z_coarse: PackedFloat32Array = _data.resample_grid(z, SG, SG, coarse_n, coarse_n)
	var pc := EROSIVE.duplicate()
	pc["gw"] = coarse_n
	pc["gh"] = coarse_n
	pc["cell_size"] = SCELL * float(SG - 1) / float(coarse_n - 1)
	var prev: Dictionary = _data.erode_heightfield(z_coarse, pc, PackedFloat32Array())
	if not bool(prev.get("ok", false)):
		_fail += 1
		print("    !! the coarse solve failed")
		return
	var d_coarse := _delta(z_coarse, prev["z"])
	var d_prev: PackedFloat32Array = _data.resample_grid(d_coarse, coarse_n, coarse_n, SG, SG)

	print("    build delta RMS %.3f m | preview delta RMS %.3f m (x%.2f - see the spec's §6 note)" % [
			_rms(d_build), _rms(d_prev), _rms(d_prev) / maxf(_rms(d_build), 1.0e-9)])
	if _rms(d_build) < 0.01 or _rms(d_prev) < 0.01:
		_fail += 1
		print("    !! one of the runs eroded nothing; J would pass by comparing a field of zeros")
		return

	print("    correlation by feature scale:")
	var corr := {}
	for div: int in [1, 2, 4, 8, 16]:
		var m: int = (SG - 1) / div + 1
		var lb: PackedFloat32Array = _data.resample_grid(d_build, SG, SG, m, m)
		var lp: PackedFloat32Array = _data.resample_grid(d_prev, SG, SG, m, m)
		corr[div] = _pearson(lb, lp)
		print("      1/%-2d (%3d cells, %5.0f m features): %.3f" % [div, m, SCELL * div, corr[div]])
	var low: float = corr[8]
	var full: float = corr[1]
	print("    criterion: 1/8 (%.0f m features) correlation %.3f, want > 0.75" % [SCELL * 8.0, low])
	if low <= 0.75:
		_fail += 1
		print("    !! the preview does not reproduce the build's large-scale structure")

	# The NODE's own preview path, which the solver-level comparison above does not touch: Preview has to
	# actually solve on a coarser grid and still write through the same mask. A preview that silently
	# fell back to build resolution would reproduce the build perfectly and tell us nothing.
	var sim = _make_sim("PreviewGate", SITE_PREVIEW)
	if sim != null:
		var probe := SITE_PREVIEW
		var base := _height(probe)
		var b_rep: Dictionary = sim.simulate_now(1, false)
		var node_build := _height(probe) - base
		var p_rep: Dictionary = sim.simulate_now(4, false)
		var node_prev := _height(probe) - base
		var b_cells := int(b_rep.get("cells", 0))
		var p_cells := int(p_rep.get("cells", 0))
		print("    node: build solved %d cells in %d ms, preview %d cells in %d ms (%.1fx fewer)" % [
				b_cells, int(b_rep.get("msec", 0)), p_cells, int(p_rep.get("msec", 0)),
				float(b_cells) / maxf(float(p_cells), 1.0)])
		print("    node: delta at the loop centre, build %+.3f m vs preview %+.3f m" % [
				node_build, node_prev])
		if p_cells >= b_cells / 4:
			_fail += 1
			print("    !! Preview did not solve on a coarser grid; it is doing a build under another name")
		if absf(node_build) < 0.05 or absf(node_prev) < 0.05:
			_fail += 1
			print("    !! one of the node runs moved nothing at the probe; this comparison measured nothing")
		sim.clear_simulation()

	# CONTROL — the HIGH-pass residual, which is the content §6 says the two runs do NOT share. A plain
	# full-resolution comparison is not the control: it still contains all of the low frequencies, so it
	# scored 0.859 against the low-pass's 0.882 and proved nothing either way.
	var hp_build := _high_pass(d_build)
	var hp_prev := _high_pass(d_prev)
	var hp := _pearson(hp_build, hp_prev)
	print("    CONTROL high-pass (finer than %.0f m) correlation %.3f, full-field %.3f" % [
			SCELL * 8.0, hp, full])
	if hp >= low - 0.15:
		_fail += 1
		print("    !! the channel-scale detail agrees as well as the large-scale structure; the low-pass")
		print("       measured nothing, and J is not testing the claim §6 actually makes")


## What is left of a field after its structure coarser than 1/8 of the grid is removed.
func _high_pass(p_a: PackedFloat32Array) -> PackedFloat32Array:
	var m: int = (SG - 1) / 8 + 1
	var coarse: PackedFloat32Array = _data.resample_grid(p_a, SG, SG, m, m)
	var trend: PackedFloat32Array = _data.resample_grid(coarse, m, m, SG, SG)
	var out := PackedFloat32Array()
	out.resize(p_a.size())
	for i in range(p_a.size()):
		out[i] = p_a[i] - trend[i]
	return out


## Pearson correlation of two equally sized fields.
func _pearson(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return 0.0
	var n := float(p_a.size())
	var ma := 0.0
	var mb := 0.0
	for i in range(p_a.size()):
		ma += p_a[i]
		mb += p_b[i]
	ma /= n
	mb /= n
	var sab := 0.0
	var saa := 0.0
	var sbb := 0.0
	for i in range(p_a.size()):
		var da := p_a[i] - ma
		var db := p_b[i] - mb
		sab += da * db
		saa += da * da
		sbb += db * db
	return sab / maxf(sqrt(saa * sbb), 1.0e-9)


# --- K: erosion is monotone where diffusion is off ---------------------------------------------------
# Detachment-limited stream power removes material and never adds any, so with D = 0 no cell may rise.
# CONTROL: turn diffusion on. Some cells must then rise — that is the only deposition this model has,
# and if none appear the gate is not sensitive to the thing it measures.
func _gate_k_monotone() -> void:
	print("\n[K] with diffusion off, no cell rises:")
	var z := _noisy_slope()
	var p := EROSIVE.merged({"diffusion": 0.0}, true)
	var res := _solve(z, p)
	if res.is_empty():
		return
	var zo: PackedFloat32Array = res["z"]
	var risen := 0
	var max_rise := 0.0
	var max_fall := 0.0
	for i in range(z.size()):
		var d := zo[i] - z[i]
		if d > 0.0:
			risen += 1
			max_rise = maxf(max_rise, d)
		max_fall = minf(max_fall, d)
	print("    %d cells rose (max %+.6f m); deepest incision %.4f m" % [risen, max_rise, -max_fall])
	if max_fall > -0.01:
		_fail += 1
		print("    !! nothing was eroded, so 'no cell rose' is trivially true")
	if risen != 0:
		_fail += 1
		print("    !! detachment-limited stream power added material somewhere")

	# CONTROL
	var pd := p.duplicate()
	pd["diffusion"] = 4.0
	var res2 := _solve(z, pd)
	if res2.is_empty():
		return
	var zd: PackedFloat32Array = res2["z"]
	var risen_d := 0
	for i in range(z.size()):
		if zd[i] > z[i]:
			risen_d += 1
	print("    CONTROL diffusion on: %d cells rose (want > 0)" % risen_d)
	if risen_d == 0:
		_fail += 1
		print("    !! diffusion deposited nothing; the monotonicity check would pass either way")


# --- synthetic fields -------------------------------------------------------------------------------

## A plane falling in +X at `p_slope` m/m, with a paraboloid bowl of depth `p_depth` and radius
## `p_radius` at the centre. The bowl meets the plane exactly at its rim, so the spill level is
## analytic: the plane's height at the downhill rim.
func _plane_with_bowl(p_slope: float, p_depth: float, p_radius: float) -> PackedFloat32Array:
	var z := PackedFloat32Array()
	z.resize(SG * SG)
	var cx := float(SG / 2) * SCELL
	var cz := float(SG / 2) * SCELL
	for iz in range(SG):
		for ix in range(SG):
			var x := ix * SCELL
			var v := 400.0 - p_slope * x
			if p_depth > 0.0:
				var r := Vector2(x - cx, iz * SCELL - cz).length()
				if r < p_radius:
					var t := r / p_radius
					v -= p_depth * (1.0 - t * t)
			z[iz * SG + ix] = v
	return z


## A plane falling in +Z only, so D8 routes every interior cell straight down its own column and the
## upstream area at row j is exactly j cells. `p_drop` is the fall per row, in metres.
## Base elevation for the synthetic fields. Kept low on purpose: gate D measures millimetre incisions,
## and float32 spacing at 2000 m is 1e-4, which would swallow them.
const BASE_Z := 200.0


func _tilted_plane(p_drop: float) -> PackedFloat32Array:
	var z := PackedFloat32Array()
	z.resize(SG * SG)
	for iz in range(SG):
		var v := BASE_Z - p_drop * iz
		for ix in range(SG):
			z[iz * SG + ix] = v
	return z


## A noisy hillside: a plane falling in +Z with coherent fractal relief on it, draining to the far edge.
##
## NOT a dome, and not by accident. A radial cone quantises its flow into eight D8 spokes, so one cell
## already drains a tenth of the domain before a single iteration runs — a fixture that hands the
## dendritic gate most of its answer for free. On a plane, flow starts almost parallel (one cell drains
## one column), so any concentration measured afterwards is concentration the SOLVER produced.
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


# --- helpers ------------------------------------------------------------------------------------------

## Run the solver over the SG x SG synthetic grid. Fills in the grid dimensions so a gate only writes
## the parameters it is actually testing. Returns {} (and fails the run) when the solver rejects it.
func _solve(p_z: PackedFloat32Array, p_params: Dictionary, p_erod := PackedFloat32Array()) -> Dictionary:
	var params := p_params.duplicate()
	params["gw"] = SG
	params["gh"] = SG
	params["cell_size"] = SCELL
	var res: Dictionary = _data.erode_heightfield(p_z, params, p_erod)
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


func _rms(p_a: PackedFloat32Array) -> float:
	var s := 0.0
	for v in p_a:
		s += v * v
	return sqrt(s / maxf(float(p_a.size()), 1.0))


## RMS(a - b) / RMS(a) — how much of the reference signal the second field fails to reproduce.
func _relative_rms(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var d := PackedFloat32Array()
	d.resize(p_a.size())
	for i in range(p_a.size()):
		d[i] = p_a[i] - p_b[i]
	return _rms(d) / maxf(_rms(p_a), 1.0e-9)


func _max_of(p_a: PackedFloat32Array) -> float:
	var m := -INF
	for v in p_a:
		if v > m:
			m = v
	return m


func _max_abs_diff(p_a: Array[float], p_b: Array[float]) -> float:
	var m := 0.0
	for i in range(p_a.size()):
		if is_finite(p_a[i]) and is_finite(p_b[i]):
			m = maxf(m, absf(p_a[i] - p_b[i]))
	return m


# --- node fixtures --------------------------------------------------------------------------------

## A Pasture3DSim with a square loop at `p_at`, parented under the terrain's root. Returns null (and
## fails the run) when there is no terrain there, so a mis-placed site reads as a fixture bug.
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
	# The shipped defaults, which bench/SimFieldProbe.tscn calibrated against the demo terrain's own
	# hillshade. A weaker setting made G and H measure a 5 mm delta and report, correctly, that they had
	# measured nothing — which is what those assertions are for.
	sim.iterations = 30
	sim.erosion_rate = 0.1
	sim.hillslope_diffusion = 0.15
	sim.falloff_width = 16.0
	sim.snap_to_surface = false # keep the loop where the gate put it; Y is irrelevant to a Sim area
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


func _snapshot(p_points: Array[Vector3]) -> Array[float]:
	var out: Array[float] = []
	for p in p_points:
		out.append(_height(p))
	return out


func _height(p_at: Vector3) -> float:
	return _data.get_height(Vector3(p_at.x, 0.0, p_at.z))
