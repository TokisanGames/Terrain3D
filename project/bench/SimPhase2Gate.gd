# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Phase 2 gates P-X for Pasture3DSim's Pasture3DSimResult masks (PASTURE3D_SIM_NODE_SPEC.md §14).
#
# Same two families as SimPhase1Gate, and the same discipline: every criterion carries a control that
# must FAIL if the thing it guards is absent, and every one asserts it measured something before it
# reports agreement.
#
#   Q, R, S, T, V, W  drive Pasture3DData.sim_result_build directly on synthetic solves — a Gaussian bump
#                     on a plain, a bowl, a noisy hillside — because channel derivation is arithmetic and
#                     does not need a bake in the way.
#   X                 drives the multi-loop merge on two hand-built parts, where the precedence rule's
#                     answer is known by construction.
#   P, U              drive a real Pasture3DSim on the demo terrain, because "the result is at SIM
#                     resolution over the SIMULATED area" is a claim about the node's bookkeeping.
#
# WHY THE DEPOSITION GATES LOOK OVERBUILT. §8.2 says up front that deposition is nearly empty in phase 2:
# detachment-limited stream power removes material without transporting it, so the only deposition is
# hillslope diffusion into concavities. "It has some non-zero cells" therefore passes on the erosion
# channel with a flipped sign, on float noise, on lake_depth pasted into the wrong slot, and on correct
# values written to the wrong grid — every one a plausible slip in a phase that is almost entirely
# plumbing. So the deposition channel is pinned from four directions: its sign relationship to erosion
# (Q), an EXACT zero when diffusion is off (R), a closed-form volume (S), and where it lands (T).
#
# NOTHING IS SAVED. The node gates bake into the terrain's in-memory layer and their Sim Results are
# created without a file, so nothing is written to demo/data or anywhere else.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/SimPhase2Gate.tscn
extends Node

const DEMO_DATA := "res://demo/data"

## Synthetic grid, matching SimPhase1Gate so the two sets of numbers are directly comparable.
const SG := 128
const SCELL := 4.0
const BASE_Z := 200.0

## The pure-diffusion fixture behind gates S and T: a Gaussian bump of amplitude BUMP_H and width
## BUMP_SIGMA on a flat plain, at an ASYMMETRIC cell so a transposed index cannot pass, and far enough
## from the boundary that the fixed edge absorbs a negligible share of the volume (BUMP_Z / sigma1 is
## about 3.3, so ~0.4% of the material ever reaches it).
##
## With erosion_rate 0 the solve is exactly the heat equation, so the deposited volume has a closed form
## and the gate does not have to guess a threshold by running it once. See _gate_s_volume.
const BUMP_IX := 48
const BUMP_IZ := 40
const BUMP_H := 20.0
const BUMP_SIGMA := 32.0 # metres = 8 cells
const BUMP_D := 32.0 # m² per iteration
const BUMP_ITERS := 20
## The plain this bump sits on is at zero, NOT at BASE_Z, and that matters for gate T. At 200 m the
## Gaussian's far tail underflows float32 — 200.0 + 6.8e-8 is 200.0 — so the initial surface reads as
## exactly flat out there and its Laplacian reads as exactly 0, while the diffusion pass still moves
## real material onto those cells. T then measures 0.58% of the deposited volume landing on "non-concave"
## ground and reports a physics violation that is entirely the fixture's float precision. At zero the
## tail stays representable and the curvature is resolvable everywhere the deposition is.
const BUMP_BASE := 0.0

## Node-gate sites, inside the loaded demo regions and far enough apart that their tile-snapped clear
## boxes cannot touch.
const SITE_EXTENT := Vector3(300.0, 0.0, 300.0)
const SITE_REGISTER := Vector3(700.0, 0.0, 300.0)
const LOOP_HALF := 60.0
const NODE_MARGIN := 40.0
const NODE_FALLOFF := 16.0

var _fail := 0
var _root: Node3D
var _terrain
var _data


func _ready() -> void:
	print("\n=== Pasture3DSim phase 2 (spec §14 gates P-X: the SimResult masks) ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_data = _terrain.data
	if _data == null or not _data.has_method("sim_result_build"):
		_fail += 1
		print("!! this build has no sim_result_build — phase 2 is unbuilt, not failing")
		_done()
		return

	_gate_q_two_signs()
	_gate_r_exact_zero()
	_gate_s_volume()
	_gate_t_concavity()
	_gate_v_log_flow()
	_gate_w_wetness()
	_gate_x_merge()
	_gate_p_extent()
	_gate_u_register()

	_done()


func _done() -> void:
	print("\n=== %s (%d failures) ===\n" % ["SIM PHASE 2 PASS" if _fail == 0 else "SIM PHASE 2 FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- Q: erosion and deposition are the two signs of ONE field --------------------------------------
# §8.2's "negative delta" and "positive delta" are the two halves of the NET z_final - z_initial, not two
# independently accumulated fields. Two things follow and both are checkable exactly: no cell may carry
# both, and their sum must reconstruct the net delta bit for bit.
#
# This is the criterion that catches a mis-indexed or duplicated channel — the failure mode that a "the
# channel has some non-zero cells" check waves straight through.
# CONTROL: the same checker run on a deliberately duplicated pair (deposition := -erosion), which is what
# a copy-paste slip in the split would produce. It must report both faults.
func _gate_q_two_signs() -> void:
	print("[Q] erosion and deposition are the two signs of one field:")
	var z0 := _noisy_slope()
	var res := _solve(z0, {"iterations": 40, "erosion_rate": 0.2, "area_exponent": 0.45,
			"diffusion": 0.5, "want_diagnostics": true})
	if res.is_empty():
		return
	var ch := _build(z0, res["z"], res["flow"], res["lake_depth"])
	if ch.is_empty():
		return
	var ero: PackedFloat32Array = ch["erosion"]
	var dep: PackedFloat32Array = ch["deposition"]
	var delta := _delta(z0, res["z"])
	var f := _split_faults(ero, dep, delta)
	print("    %d of %d cells carry BOTH signs (want 0); reconstruction error max %.9f m (want 0)" % [
			f[0], ero.size(), f[1]])
	print("    the fixture really has both: %d cells eroded, %d deposited" % [f[2], f[3]])
	if f[2] < 100 or f[3] < 100:
		_fail += 1
		print("    !! one of the halves is empty; Q would pass on a field with only one sign in it")
	if f[0] != 0:
		_fail += 1
		print("    !! a cell is both eroding and depositing; the two channels are not one field")
	if f[1] != 0.0:
		_fail += 1
		print("    !! erosion + deposition does not reconstruct the net delta")

	# CONTROL — a duplicated channel, which is what a wrong index in the split looks like.
	var bad := PackedFloat32Array()
	bad.resize(ero.size())
	for i in range(ero.size()):
		bad[i] = -ero[i] if ero[i] < 0.0 else dep[i]
	var bf := _split_faults(ero, bad, delta)
	print("    CONTROL deposition := |erosion|: %d cells carry both (want > 0), recon error %.4f m (want > 0)" % [
			bf[0], bf[1]])
	if bf[0] == 0 or bf[1] == 0.0:
		_fail += 1
		print("    !! a duplicated channel passed the checker; Q is not measuring the split")


## [both_signs, max_reconstruction_error, eroded_cells, deposited_cells] for a channel pair.
func _split_faults(p_ero: PackedFloat32Array, p_dep: PackedFloat32Array, p_delta: PackedFloat32Array) -> Array:
	var both := 0
	var err := 0.0
	var n_ero := 0
	var n_dep := 0
	for i in range(p_ero.size()):
		if p_ero[i] != 0.0 and p_dep[i] != 0.0:
			both += 1
		if p_ero[i] != 0.0:
			n_ero += 1
		if p_dep[i] != 0.0:
			n_dep += 1
		err = maxf(err, absf((p_ero[i] + p_dep[i]) - p_delta[i]))
	return [both, err, n_ero, n_dep]


# --- R: with diffusion off, deposition is IDENTICALLY zero -------------------------------------------
# Not "small" — exactly 0.0, on every cell. The claim rests entirely on incision being monotone by
# construction, which it is because of the two §4.3 guards: a submerged cell does not incise, and a cell
# whose receiver is not below it in the real surface is skipped. Gate K measures that on the height;
# this measures that the DEPOSITION CHANNEL inherits it.
#
# WRITE THIS DEPENDENCY DOWN, because §15's sediment-transport extension breaks it: a transporting
# solver deposits without any diffusion at all, and this control would then be measuring nothing while
# still passing. If that extension lands, R must be re-derived, not re-tuned.
# CONTROL: diffusion on. Deposition must appear, or an exact zero proves nothing.
func _gate_r_exact_zero() -> void:
	print("\n[R] with hillslope diffusion off, deposition is exactly zero:")
	var z0 := _noisy_slope()
	var res := _solve(z0, {"iterations": 40, "erosion_rate": 0.2, "area_exponent": 0.45,
			"diffusion": 0.0, "want_diagnostics": true})
	if res.is_empty():
		return
	var ch := _build(z0, res["z"], res["flow"], res["lake_depth"])
	if ch.is_empty():
		return
	var dep: PackedFloat32Array = ch["deposition"]
	var ero: PackedFloat32Array = ch["erosion"]
	var n_dep := 0
	var max_dep := 0.0
	for v in dep:
		if v != 0.0:
			n_dep += 1
			max_dep = maxf(max_dep, v)
	print("    %d of %d cells deposited (want exactly 0); max %+.6f m" % [n_dep, dep.size(), max_dep])
	print("    deepest incision %.3f m (so the solve did do something)" % -_min_of(ero))
	if -_min_of(ero) < 1.0:
		_fail += 1
		print("    !! nothing eroded, so 'no deposition' is trivially true")
	if n_dep != 0:
		_fail += 1
		print("    !! detachment-limited stream power deposited material with diffusion off")

	# CONTROL
	var res2 := _solve(z0, {"iterations": 40, "erosion_rate": 0.2, "area_exponent": 0.45,
			"diffusion": 4.0, "want_diagnostics": true})
	if res2.is_empty():
		return
	var ch2 := _build(z0, res2["z"], res2["flow"], res2["lake_depth"])
	if ch2.is_empty():
		return
	var n2 := 0
	for v: float in ch2["deposition"]:
		if v != 0.0:
			n2 += 1
	print("    CONTROL diffusion on: %d cells deposited (want > 0)" % n2)
	if n2 == 0:
		_fail += 1
		print("    !! diffusion deposited nothing; the exact-zero check would pass either way")


# --- S: the deposited volume matches a closed-form answer --------------------------------------------
# A threshold picked by running the thing once is a guess about the implementation, not a test of it. So
# the fixture is chosen to HAVE an analytic answer: a Gaussian bump on a flat plain with erosion_rate 0,
# where the solve reduces exactly to the heat equation and diffusing a Gaussian keeps it Gaussian.
#
#   sigma1^2 = sigma0^2 + 2*D*T            (D per iteration, T = iterations)
#   V        = 2*pi*h0*sigma0^2            total volume, conserved
#   r*^2     = 2*ln(sigma1^2/sigma0^2) * sigma0^2*sigma1^2 / (sigma1^2 - sigma0^2)
#   V+       = V * (exp(-r*^2/2 sigma1^2) - exp(-r*^2/2 sigma0^2))
#
# r* is where the two Gaussians cross, i.e. the inner edge of the deposited ring. TWO criteria fall out.
# The volume itself is one. The other is conservation — with the bump far from the boundary almost
# nothing leaves the domain, so the deposited volume must match the eroded volume, and THAT is what
# catches a sign error or a factor of two that a single magnitude check would swallow.
# CONTROLS: the same fixture with D = 0 (deposits nothing, so the measurement is really reading the
# diffusion), and the criterion re-run against a doubled field, which must fail — otherwise the
# tolerance is loose enough to accept anything.
func _gate_s_volume() -> void:
	print("\n[S] the deposited volume matches the analytic Gaussian-diffusion figure:")
	var s0_2 := BUMP_SIGMA * BUMP_SIGMA
	var s1_2 := s0_2 + 2.0 * BUMP_D * float(BUMP_ITERS)
	var vol := 2.0 * PI * BUMP_H * s0_2
	var rstar2 := 2.0 * log(s1_2 / s0_2) * s0_2 * s1_2 / (s1_2 - s0_2)
	var want := vol * (exp(-rstar2 / (2.0 * s1_2)) - exp(-rstar2 / (2.0 * s0_2)))
	print("    fixture: h0 %.1f m, sigma0 %.1f m, D %.1f x %d iterations -> sigma1 %.1f m, r* %.1f m" % [
			BUMP_H, BUMP_SIGMA, BUMP_D, BUMP_ITERS, sqrt(s1_2), sqrt(rstar2)])

	var z0 := _bump_field()
	var got_vol := _volume_above(z0)
	print("    the sampled bump really is the Gaussian: volume %.0f m3 vs analytic %.0f (%.2f%%)" % [
			got_vol, vol, 100.0 * absf(got_vol - vol) / vol])
	if absf(got_vol - vol) / vol > 0.02:
		_fail += 1
		print("    !! the fixture is not the Gaussian the closed form describes; S is comparing two things")

	var ch := _diffuse_channels(BUMP_D)
	if ch.is_empty():
		return
	var dep_v := _sum_volume(ch["deposition"])
	var ero_v := -_sum_volume(ch["erosion"])
	print("    deposited %.0f m3 vs analytic %.0f m3 (%+.2f%%, tol 3%%)" % [
			dep_v, want, 100.0 * (dep_v - want) / want])
	print("    conservation: eroded %.0f m3 vs deposited %.0f m3 (%+.2f%%, tol 2%%)" % [
			ero_v, dep_v, 100.0 * (dep_v - ero_v) / ero_v])
	if dep_v <= 0.0:
		_fail += 1
		print("    !! nothing was deposited; there is no volume to compare")
		return
	if absf(dep_v - want) / want > 0.03:
		_fail += 1
		print("    !! the deposited volume does not match the closed form")
	if absf(dep_v - ero_v) / ero_v > 0.02:
		_fail += 1
		print("    !! volume is not conserved; a sign or a factor is wrong somewhere in the split")

	# CONTROL — no diffusion, same fixture. The material has nowhere to go.
	var flat := _diffuse_channels(0.0)
	if not flat.is_empty():
		var flat_v := _sum_volume(flat["deposition"])
		print("    CONTROL D=0 on the same bump: deposited %.6f m3 (want exactly 0)" % flat_v)
		if flat_v != 0.0:
			_fail += 1
			print("    !! the bump deposited without diffusion; S is not reading the diffusion pass")

	# CONTROL — the same criterion against a field twice as large. If a doubling still passes, the
	# tolerance is decoration.
	print("    CONTROL doubled field: %+.2f%% off the closed form (want outside 3%%)" % [
			100.0 * (2.0 * dep_v - want) / want])
	if absf(2.0 * dep_v - want) / want <= 0.03:
		_fail += 1
		print("    !! a doubled deposition field still matched; the tolerance cannot see a factor of two")


# --- T: deposition lands in the concavities ----------------------------------------------------------
# Volume says how much, not where, and a channel written to the wrong grid can have exactly the right
# volume. Diffusion moves material down the curvature gradient, so deposited cells must sit where the
# INITIAL surface is concave — and, on this fixture, nowhere near the convex crown of the bump.
#
# Three criteria. The strong one is a statement with no tolerance in it: diffusion moves material DOWN
# the curvature gradient, so every cubic metre deposited must land where the initial Laplacian is
# strictly positive. The share of the deposited volume sitting on non-concave ground is therefore 0, and
# the strongly convex crown — where the material came from — deposits exactly nothing. The third is the
# centroid, which is what would catch a transposed or offset grid.
#
# The raw Pearson correlation is reported and gated only weakly, on purpose: it is diluted by the ~15 000
# plain cells where both fields are zero, and the deposited ring and the Laplacian's positive lobe peak
# at different radii, so its natural value here is around +0.33 and any tighter bar would be a number
# picked to fit this fixture rather than a claim about the physics.
# CONTROL: every test re-run against the Laplacian rolled half a domain. A displaced curvature field puts
# most of the deposited volume on "convex" ground and correlates at zero — which is what separates
# co-location from two blobby fields happening to overlap.
func _gate_t_concavity() -> void:
	print("\n[T] deposition lands in concavities of the initial surface:")
	var ch := _diffuse_channels(BUMP_D)
	if ch.is_empty():
		return
	var dep: PackedFloat32Array = ch["deposition"]
	var lap := _laplacian(_bump_field())
	var rolled := _roll(lap, SG / 2, SG / 2)
	var r := _pearson(dep, lap)
	var r_roll := _pearson(dep, rolled)

	var share := _volume_share_where_not_concave(dep, lap)
	print("    %.4f%% of the deposited volume sits on non-concave ground (want < 0.1%%)" % [100.0 * share])
	if share >= 0.001:
		_fail += 1
		print("    !! material was deposited on convex ground; diffusion cannot do that")

	var peak := _min_of(lap)
	var crown := _mean_where_below(dep, lap, 0.10 * peak)
	print("    the crown (curvature past a tenth of the peak %.5f) deposited a mean of %+.9f m (want 0)" % [
			peak, crown])
	if peak >= 0.0:
		_fail += 1
		print("    !! the fixture has no convex ground at all; there is nothing for the crown test to read")
	if crown != 0.0:
		_fail += 1
		print("    !! the bump's own crown gained material")

	var c := _centroid(dep)
	print("    deposition centroid at cell (%.2f, %.2f); the bump is at (%d, %d), tol 1.5" % [
			c[0], c[1], BUMP_IX, BUMP_IZ])
	if absf(c[0] - float(BUMP_IX)) > 1.5 or absf(c[1] - float(BUMP_IZ)) > 1.5:
		_fail += 1
		print("    !! the deposition is not where the bump is; the grid is offset or transposed")
	print("    correlation with the initial Laplacian %+.3f (weak bar: > 0.20)" % r)
	if r <= 0.20:
		_fail += 1
		print("    !! deposition does not follow curvature even loosely")

	# CONTROL
	var roll_share := _volume_share_where_not_concave(dep, rolled)
	print("    CONTROL Laplacian rolled half a domain: %.2f%% of the volume on non-concave ground" % [
			100.0 * roll_share])
	print("    CONTROL rolled correlation %+.3f (want near 0, and far below %+.3f)" % [r_roll, r])
	# The bar is the criterion's OWN threshold: a displaced curvature field must fail the test the real
	# one passed. It fails it by about 75x here and not by more, because on this fixture the initial
	# surface is concave nearly everywhere outside the bump's crown — so a sign test lands on concave
	# ground even when it is pointed at the wrong place. That is why the crown, the centroid and the
	# correlation are all criteria too, and not decoration around this one.
	if roll_share <= 0.001:
		_fail += 1
		print("    !! a displaced curvature field passes the same test; the share test is reading the")
		print("       fixture's shape, not where the material went")
	if absf(r_roll) >= 0.15:
		_fail += 1
		print("    !! a displaced curvature field correlates just as well; T is not measuring location")


# --- V: `flow` is stored log-scaled, and un-logs back to drainage area --------------------------------
# §8.2 stores flow as log(area) because the range spans decades, which means every consumer has to invert
# it. This gate pins the convention at BOTH ends: exp() of the stored channel, summed over the outlets,
# must be the domain area — gate C's conservation, carried through the log round trip.
# CONTROL: the same sum without the exp. It must be wildly short, because that is exactly the mistake a
# phase-3 selector will make if the convention is not documented and gated.
func _gate_v_log_flow() -> void:
	print("\n[V] `flow` is log-scaled and un-logs to drainage area (m2):")
	var z := _plane_with_bowl(0.1, 20.0, 24.0)
	var res := _solve(z, {"iterations": 0, "want_diagnostics": true})
	if res.is_empty():
		return
	var ch := _build(z, res["z"], res["flow"], res["lake_depth"])
	if ch.is_empty():
		return
	var stored: PackedFloat32Array = ch["flow"]
	var recv: PackedInt32Array = res["receiver"]
	var domain := float(SG * SG) * SCELL * SCELL
	var lin := 0.0
	var logsum := 0.0
	for i in range(SG * SG):
		if recv[i] == i:
			lin += exp(stored[i])
			logsum += stored[i]
	var biggest := exp(_max_of(stored))
	print("    Σ exp(flow) at the outlets %.1f m2 vs domain %.1f m2 (rel err %.7f, tol 1e-4)" % [
			lin, domain, absf(lin - domain) / domain])
	print("    largest catchment %.0f m2 = %.3f of the domain (accumulation really happened)" % [
			biggest, biggest / domain])
	if biggest < 20.0 * SCELL * SCELL:
		_fail += 1
		print("    !! nothing accumulated; V would pass on a field of floors")
	if absf(lin - domain) / domain > 1.0e-4:
		_fail += 1
		print("    !! the log round trip does not conserve drainage area")

	# CONTROL
	print("    CONTROL flow read as if it were linear: Σ %.1f m2 (rel err %.3f, want > 0.5)" % [
			logsum, absf(logsum - domain) / domain])
	if absf(logsum - domain) / domain <= 0.5:
		_fail += 1
		print("    !! reading the channel linearly gave the same answer; the values are not log-scaled")


# --- W: `wetness` is the depression fill, in the right slot ------------------------------------------
# Gate B measures lake_depth coming out of the solver; this measures that it reaches the RESOURCE, in
# metres, in the wetness channel and not in one of the others. A zero-iteration solve over a bowl is the
# fixture that separates them completely: nothing incises, so erosion and deposition must be identically
# zero while wetness is 25 m deep. A lake_depth pasted into the wrong slot fails that immediately.
# CONTROL: the same plane with no bowl. Nothing fills, so a run of zeros reads as "measured nothing".
func _gate_w_wetness() -> void:
	print("\n[W] `wetness` carries the depression fill, and only it:")
	var slope := 0.1
	var radius := 30.0
	var depth := 28.0
	var expect := depth - slope * radius
	var z := _plane_with_bowl(slope, depth, radius)
	var res := _solve(z, {"iterations": 0, "want_diagnostics": true})
	if res.is_empty():
		return
	var ch := _build(z, res["z"], res["flow"], res["lake_depth"])
	if ch.is_empty():
		return
	var wet: PackedFloat32Array = ch["wetness"]
	var centre := (SG / 2) * SG + (SG / 2)
	print("    wetness at the bowl centre %.3f m (want %.3f, tol 1.0)" % [wet[centre], expect])
	if absf(wet[centre] - expect) > 1.0:
		_fail += 1
		print("    !! the wetness channel does not hold the fill depth")
	var e_max := _max_abs(ch["erosion"])
	var d_max := _max_abs(ch["deposition"])
	print("    on the same zero-iteration solve, erosion max |%.9f| and deposition max |%.9f| (want 0, 0)" % [
			e_max, d_max])
	if e_max != 0.0 or d_max != 0.0:
		_fail += 1
		print("    !! a solve that moved no ground still wrote a height channel; the slots are crossed")

	# CONTROL
	var flat := _plane_with_bowl(slope, 0.0, radius)
	var res2 := _solve(flat, {"iterations": 0, "want_diagnostics": true})
	if res2.is_empty():
		return
	var ch2 := _build(flat, res2["z"], res2["flow"], res2["lake_depth"])
	if ch2.is_empty():
		return
	print("    CONTROL no basin: max wetness %.6f m (want ~0)" % _max_of(ch2["wetness"]))
	if _max_of(ch2["wetness"]) > 0.01:
		_fail += 1
		print("    !! a basin-free plane still came back wet; wetness is not measuring depressions")


# --- X: several loops merge by the documented precedence rule ----------------------------------------
# §2 says one SimResult per Sim node, so a Sim with several loops has to merge them, and where two loops'
# SIMULATED areas overlap the answer is genuinely ambiguous — both solved that ground, independently and
# to different answers (§5's seam warning). The rule: a cell inside a loop's WRITE area beats a cell
# another loop merely simulated as catchment margin; ties go to the earlier loop.
#
# Two parts of known constant value, overlapping by their margins, so every cell's correct answer is
# known by construction and a merge that silently took the last part, or averaged, or dropped the
# overlap, produces a different number in a place the gate names.
# CONTROL: the parts placed so they do NOT overlap. The seam cell must then come from the part that
# actually covers it, which is what shows the criterion can tell the two parts apart at all.
func _gate_x_merge() -> void:
	print("\n[X] several loops merge by the write-beats-margin precedence rule:")
	# Two 33-cell parts, 4 m cells: A spans world X 0..128, B spans X 96..224 (an 8-cell overlap).
	# A writes only X 0..96, B writes only X 128..224 — so the overlap band is margin for BOTH, and the
	# tie must go to A.
	var a := _const_part(0.0, -1.0, 3.0, 0.0, 96.0)
	var b := _const_part(96.0, -2.0, 5.0, 128.0, 224.0)
	var target := {"min_x": 0.0, "min_z": 0.0, "cell_size": SCELL, "width": 57, "height": 33}
	var out: Dictionary = _data.sim_result_build([a, b], target)
	if not bool(out.get("ok", false)):
		_fail += 1
		print("    !! the merge rejected two parts")
		return
	var ero: PackedFloat32Array = out["erosion"]
	var wet: PackedFloat32Array = out["wetness"]
	var row := 16 * 57
	# Column 5 (X=20) is A's write area; column 45 (X=180) is B's; column 27 (X=108) is margin for both.
	var in_a: float = ero[row + 5]
	var in_b: float = ero[row + 45]
	var tie: float = ero[row + 27]
	print("    A's write area %.3f (want -1) | B's write area %.3f (want -2) | shared margin %.3f (want -1)" % [
			in_a, in_b, tie])
	if absf(in_a + 1.0) > 1.0e-4 or absf(in_b + 2.0) > 1.0e-4:
		_fail += 1
		print("    !! a loop's own write area did not take that loop's value")
	if absf(tie + 1.0) > 1.0e-4:
		_fail += 1
		print("    !! the margin-only overlap did not go to the earlier loop")
	print("    wetness follows the same claim: %.3f | %.3f | %.3f (want 3, 5, 3)" % [
			wet[row + 5], wet[row + 45], wet[row + 27]])
	if absf(wet[row + 5] - 3.0) > 1.0e-4 or absf(wet[row + 45] - 5.0) > 1.0e-4 or absf(wet[row + 27] - 3.0) > 1.0e-4:
		_fail += 1
		print("    !! the four channels did not come from the same loop at the same cell")

	# CONTROL — B alone must fill B's half with B's value, so the gate can tell the parts apart.
	var only_b: Dictionary = _data.sim_result_build([b], target)
	if not bool(only_b.get("ok", false)):
		_fail += 1
		print("    !! the single-part merge failed")
		return
	var solo: PackedFloat32Array = only_b["erosion"]
	print("    CONTROL B alone: shared margin %.3f (want -2, i.e. A really was winning it above)" % solo[row + 27])
	if absf(solo[row + 27] + 2.0) > 1.0e-4:
		_fail += 1
		print("    !! the gate cannot distinguish the two parts, so the precedence result means nothing")


## One merge part of constant delta and constant wetness, 33x33 cells from `p_x0`, with an explicit
## write rect. `flow` is left at 1 m² so the log channel stays out of the way.
func _const_part(p_x0: float, p_delta: float, p_wet: float, p_wx0: float, p_wx1: float) -> Dictionary:
	var n := 33 * 33
	var z0 := PackedFloat32Array()
	var z1 := PackedFloat32Array()
	var fl := PackedFloat32Array()
	var lk := PackedFloat32Array()
	z0.resize(n)
	z1.resize(n)
	fl.resize(n)
	lk.resize(n)
	z0.fill(BASE_Z)
	z1.fill(BASE_Z + p_delta)
	fl.fill(1.0)
	lk.fill(p_wet)
	return {"sw": 33, "sh": 33, "cell": SCELL, "min_x": p_x0, "min_z": 0.0,
			"z0": z0, "z1": z1, "flow": fl, "lake": lk,
			"write_min_x": p_wx0, "write_max_x": p_wx1, "write_min_z": 0.0, "write_max_z": 128.0}


# --- P: the result is the SIM grid over the SIMULATED area -------------------------------------------
# §8.2 is explicit that cell_size is "sim resolution, NOT necessarily terrain vertex_spacing", and §5's
# margin means the simulated area is bigger than the loop. Those are two independent ways to get this
# wrong, and both produce a mask that is non-zero and roughly in the right place.
#
# The fixture forces the two grids apart on BOTH axes at once — a 40 m catchment margin so the extents
# differ, and Preview resolution 2 so the cell sizes differ — because at margin 0 and resolution 1 the
# sim grid and the write grid coincide and every assertion below would pass on either.
# CONTROL: the write grid's own origin, cell size and dimensions, printed beside the result's. They must
# differ; if they do not, the fixture has stopped separating the two and the gate is measuring nothing.
func _gate_p_extent() -> void:
	print("\n[P] the masks are at sim resolution over the simulated area, not the write grid:")
	# Diffusion well above the shipped 0.15, and NOT to make the numbers nicer: on this small, steep demo
	# loop at the default the deposition channel comes back identically zero — incision wins everywhere,
	# which is §8.2's "the channel is real but small" showing up in the flesh. A fixture that cannot
	# distinguish an empty channel from a missing one is no use for asserting all four are alive.
	var sim = _make_sim("ExtentGate", SITE_EXTENT, 2.0)
	if sim == null:
		return
	var vs: float = _terrain.vertex_spacing
	var path: Path3D = sim._get_splines()[0]
	var wb: Array = sim._snapped_bounds(sim._spline_footprint_aabb(path), vs)
	var gw := int(round((wb[1] - wb[0]) / vs)) + 1

	var report: Dictionary = sim.simulate_now(2, false) # Preview resolution, so cell_size != vs
	if not bool(report.get("ok", false)):
		_fail += 1
		print("    !! the simulation did not run: %s" % report.get("reason", "?"))
		return
	var r: Pasture3DSimResult = sim.sim_result
	if r == null or not r.is_valid():
		_fail += 1
		print("    !! no valid Pasture3DSimResult was written")
		return
	var b := r.world_bounds()
	print("    result: %dx%d @ %.3f m, X %.1f..%.1f" % [r.width, r.height, r.cell_size, b[0], b[1]])
	print("    write grid for comparison: %d wide @ %.3f m, X %.1f..%.1f" % [gw, vs, wb[0], wb[1]])

	if r.flow.size() != r.width * r.height or r.erosion.size() != r.width * r.height \
			or r.deposition.size() != r.width * r.height or r.wetness.size() != r.width * r.height:
		_fail += 1
		print("    !! the four channels are not all width*height long")
	# Resolution: the sim grid's cell comes out of the grid dimensions (§6), so it is vs*scale to within
	# the rounding of one cell over the whole span — not exactly.
	if absf(r.cell_size - vs * 2.0) > 0.1 * vs * 2.0:
		_fail += 1
		print("    !! cell_size is not the sim resolution (%.3f, expected about %.3f)" % [r.cell_size, vs * 2.0])
	# Extent: the simulated area is the loop grown by the catchment margin.
	if b[0] > wb[0] - NODE_MARGIN + vs or b[1] < wb[1] + NODE_MARGIN - vs:
		_fail += 1
		print("    !! the extent does not cover the loop plus its catchment margin")
	if absf(b[0] + r.cell_size * float(r.width - 1) - b[1]) > 1.0e-3:
		_fail += 1
		print("    !! min_x, cell_size and width do not describe the same rect")

	# The channels are alive. Not a substitute for Q-W, but a mask of zeros must not reach here quietly.
	var deepest := -_min_of(r.erosion)
	var risen := _max_of(r.deposition)
	var biggest := exp(_max_of(r.flow))
	print("    channels: deepest incision %.2f m | max deposition %.2f m | largest catchment %.0f m2" % [
			deepest, risen, biggest])
	if deepest < 0.1 or risen <= 0.0 or biggest < 100.0:
		_fail += 1
		print("    !! one of the channels is empty on a solve that moved the ground")
	print("    source: preview %s, 1/%d, %d iterations, K %.3f, D %.3f, margin %.0f m" % [
			r.source_preview, r.source_resolution, r.source_iterations, r.source_erosion_rate,
			r.source_diffusion, r.source_catchment_margin])
	if not r.source_preview or r.source_resolution != 2 or r.source_area_hash == "":
		_fail += 1
		print("    !! the source parameters do not describe the solve that just ran")

	# CONTROL — the same node at BUILD resolution with no margin. The two grids coincide there, so every
	# criterion above passes either way; the point is to show the fixture above really was separating them.
	sim.catchment_margin = 0.0
	if bool(sim.simulate_now(1, false).get("ok", false)):
		var r2: Pasture3DSimResult = sim.sim_result
		var b2 := r2.world_bounds()
		print("    CONTROL margin 0 at build resolution: %dx%d @ %.3f m, X %.1f..%.1f (want == the write grid)" % [
				r2.width, r2.height, r2.cell_size, b2[0], b2[1]])
		if r2.width != gw or absf(r2.cell_size - vs) > 1.0e-4 or absf(b2[0] - wb[0]) > 1.0e-4:
			_fail += 1
			print("    !! with no margin and no downscale the masks still do not match the write grid,")
			print("       so the fixture's disagreement above was not the margin and the resolution")
		if r2.source_preview:
			_fail += 1
			print("    !! a build-resolution run was recorded as a preview")
	sim.clear_simulation()
	print("    after Clear Simulation the masks are empty: %s" % sim.sim_result.describe())
	if sim.sim_result.is_valid():
		_fail += 1
		print("    !! the masks outlived the erosion they describe")


# --- U: the masks register with the terrain in world space -------------------------------------------
# This is the criterion that catches a channel built from the masked, upsampled WRITE grid instead of the
# sim-resolution field. That mistake produces a mask which is non-zero, roughly in the right places, and
# passes every magnitude criterion in this file — it is wrong only in extent and resolution.
#
# So: look the result up THROUGH ITS OWN min_x / min_z / cell_size at world positions where the loop's
# falloff mask is exactly 1, and compare against the height the layer actually gained there. Inside the
# unfeathered interior those are the same number, and an extent that is off by a margin is not.
# CONTROL: the same lookup displaced by one catchment margin. It must disagree, or the comparison is
# insensitive to where the grid thinks it is.
func _gate_u_register() -> void:
	print("\n[U] the masks register with the terrain through their own extent:")
	var sim = _make_sim("RegisterGate", SITE_REGISTER)
	if sim == null:
		return
	var vs: float = _terrain.vertex_spacing
	var probes: Array[Vector3] = []
	for i in range(-2, 3):
		for j in range(-2, 3):
			probes.append(Vector3(snappedf(SITE_REGISTER.x + i * 18.0, vs), 0.0,
					snappedf(SITE_REGISTER.z + j * 18.0, vs)))
	var before := _snapshot(probes)
	if not bool(sim.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the simulation did not run")
		return
	var after := _snapshot(probes)
	var r: Pasture3DSimResult = sim.sim_result
	if r == null or not r.is_valid():
		_fail += 1
		print("    !! no valid Pasture3DSimResult was written")
		return

	var moved := 0.0
	var worst := 0.0
	var worst_shifted := 0.0
	for i in range(probes.size()):
		var terrain_delta: float = after[i] - before[i]
		moved = maxf(moved, absf(terrain_delta))
		worst = maxf(worst, absf(r.net_delta_at(probes[i]) - terrain_delta))
		var off := probes[i] + Vector3(NODE_MARGIN, 0.0, NODE_MARGIN)
		worst_shifted = maxf(worst_shifted, absf(r.net_delta_at(off) - terrain_delta))
	print("    %d probes, largest height change %.3f m" % [probes.size(), moved])
	print("    worst |mask - terrain| %.4f m (tol 0.05)" % worst)
	if moved < 0.2:
		_fail += 1
		print("    !! the ground barely moved, so agreement here means nothing")
	if worst > 0.05:
		_fail += 1
		print("    !! the masks do not line up with the erosion that was written")

	# CONTROL
	print("    CONTROL lookup displaced by one margin (%.0f m): worst %.4f m (want > 0.25)" % [
			NODE_MARGIN, worst_shifted])
	if worst_shifted <= 0.25:
		_fail += 1
		print("    !! a displaced lookup agrees just as well; U cannot see a mis-placed extent")
	sim.clear_simulation()


# --- synthetic fields ---------------------------------------------------------------------------------

## A flat plain at BUMP_BASE with one Gaussian bump. The closed forms in gate S describe exactly this.
func _bump_field() -> PackedFloat32Array:
	var z := PackedFloat32Array()
	z.resize(SG * SG)
	var cx := float(BUMP_IX) * SCELL
	var cz := float(BUMP_IZ) * SCELL
	var two_s2 := 2.0 * BUMP_SIGMA * BUMP_SIGMA
	for iz in range(SG):
		for ix in range(SG):
			var dx := ix * SCELL - cx
			var dz := iz * SCELL - cz
			z[iz * SG + ix] = BUMP_BASE + BUMP_H * exp(-(dx * dx + dz * dz) / two_s2)
	return z


## Same plane-with-bowl fixture SimPhase1Gate uses, so B/C and V/W measure the same ground.
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


## Solve the bump fixture with erosion off and diffusion `p_d`, and derive the channels.
func _diffuse_channels(p_d: float) -> Dictionary:
	var z0 := _bump_field()
	var res := _solve(z0, {"iterations": BUMP_ITERS, "erosion_rate": 0.0, "area_exponent": 0.45,
			"diffusion": p_d, "want_diagnostics": true})
	if res.is_empty():
		return {}
	return _build(z0, res["z"], res["flow"], res["lake_depth"])


# --- helpers ------------------------------------------------------------------------------------------

## Run the solver over the SG x SG synthetic grid, as SimPhase1Gate does.
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


## Derive the four channels for one solve, on the solve's own grid — the single-loop case the node
## takes, so the gates measure the shipped path rather than a merge nobody runs.
func _build(p_z0: PackedFloat32Array, p_z1: PackedFloat32Array, p_flow: PackedFloat32Array,
		p_lake: PackedFloat32Array) -> Dictionary:
	var part := {"sw": SG, "sh": SG, "cell": SCELL, "min_x": 0.0, "min_z": 0.0,
			"z0": p_z0, "z1": p_z1, "flow": p_flow, "lake": p_lake,
			"write_min_x": 0.0, "write_max_x": SCELL * float(SG - 1),
			"write_min_z": 0.0, "write_max_z": SCELL * float(SG - 1)}
	var target := {"min_x": 0.0, "min_z": 0.0, "cell_size": SCELL, "width": SG, "height": SG}
	var out: Dictionary = _data.sim_result_build([part], target)
	if not bool(out.get("ok", false)):
		_fail += 1
		print("    !! sim_result_build rejected the part")
		return {}
	return out


## Discrete Laplacian of a field, interior only (the border is left at 0 and excluded everywhere it
## matters by the fixture keeping its bump far from the edge).
func _laplacian(p_z: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_z.size())
	for iz in range(1, SG - 1):
		for ix in range(1, SG - 1):
			var i := iz * SG + ix
			out[i] = (p_z[i + 1] + p_z[i - 1] + p_z[i + SG] + p_z[i - SG] - 4.0 * p_z[i]) / (SCELL * SCELL)
	return out


## A field shifted cyclically. Used as a control: a displaced copy of a signal must stop correlating.
func _roll(p_a: PackedFloat32Array, p_dx: int, p_dz: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_a.size())
	for iz in range(SG):
		for ix in range(SG):
			out[iz * SG + ix] = p_a[((iz + p_dz) % SG) * SG + ((ix + p_dx) % SG)]
	return out


## Mean of `p_values` over the cells where `p_key` is at or below `p_cut`.
func _mean_where_below(p_values: PackedFloat32Array, p_key: PackedFloat32Array, p_cut: float) -> float:
	var total := 0.0
	var n := 0
	for i in range(p_values.size()):
		if p_key[i] <= p_cut:
			total += p_values[i]
			n += 1
	return total / maxf(float(n), 1.0)


## Share of the total in `p_values` that sits on cells where `p_key` is NOT strictly positive — i.e. the
## fraction of the deposited volume that landed somewhere diffusion could not have put it.
func _volume_share_where_not_concave(p_values: PackedFloat32Array, p_key: PackedFloat32Array) -> float:
	var bad := 0.0
	var all := 0.0
	for i in range(p_values.size()):
		all += p_values[i]
		if p_key[i] <= 0.0:
			bad += p_values[i]
	return bad / maxf(all, 1.0e-12)


## Weighted centroid of a non-negative field, in cell coordinates: [x, z].
func _centroid(p_a: PackedFloat32Array) -> Array:
	var sx := 0.0
	var sz := 0.0
	var sw := 0.0
	for iz in range(SG):
		for ix in range(SG):
			var w: float = p_a[iz * SG + ix]
			if w <= 0.0:
				continue
			sx += w * float(ix)
			sz += w * float(iz)
			sw += w
	if sw <= 0.0:
		return [-1.0, -1.0]
	return [sx / sw, sz / sw]


## Volume of the bump fixture above its plain, m³.
func _volume_above(p_z: PackedFloat32Array) -> float:
	var v := 0.0
	for h in p_z:
		v += maxf(h - BUMP_BASE, 0.0)
	return v * SCELL * SCELL


## Σ of a channel as a volume, m³.
func _sum_volume(p_a: PackedFloat32Array) -> float:
	var v := 0.0
	for x in p_a:
		v += x
	return v * SCELL * SCELL


func _delta(p_before: PackedFloat32Array, p_after: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_before.size())
	for i in range(p_before.size()):
		out[i] = p_after[i] - p_before[i]
	return out


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


func _max_of(p_a: PackedFloat32Array) -> float:
	var m := -INF
	for v in p_a:
		if v > m:
			m = v
	return m


func _min_of(p_a: PackedFloat32Array) -> float:
	var m := INF
	for v in p_a:
		if v < m:
			m = v
	return m


func _max_abs(p_a: PackedFloat32Array) -> float:
	var m := 0.0
	for v in p_a:
		m = maxf(m, absf(v))
	return m


# --- node fixtures --------------------------------------------------------------------------------

## A Pasture3DSim with a square loop at `p_at`, at the shipped defaults. Its Sim Result is left
## unassigned so the node creates one WITHOUT a file — nothing here is ever written to disk.
func _make_sim(p_name: String, p_at: Vector3, p_diffusion: float = 0.15):
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
	sim.hillslope_diffusion = p_diffusion
	sim.falloff_width = NODE_FALLOFF
	sim.snap_to_surface = false
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
