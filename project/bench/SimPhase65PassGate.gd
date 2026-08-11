# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Phase 6.5 gates AZ-BD — the pass CONTAINER half (PASTURE3D_SIM_NODE_SPEC.md §21.9).
# The selector half (BE-BH) is in SimPhase65SelectorGate.tscn; a manager fixture has nothing to do with a
# selector band, which is why they are two scenes.
#
# WHAT IS BEING CLAIMED, and how each claim is made falsifiable:
#
#   AZ  every member of a container is handed the identical input surface, and none sees another's output
#   BA  a container is order-independent; the manager's own pass list is NOT
#   BB  the masks stored on pass N describe the surface after N — not after N-1, not after the chain
#   BC  build-through truncates and changes nothing else
#   BD  a bare Sim under a manager is still a pass of one, bit for bit
#
# THE GATE COMPUTES ITS OWN REFERENCES. BB's reference for "the surface after pass 1" is a SEPARATE
# truncated bake read back out of the terrain through get_height — not the chain's own capture, and not
# the resource under test. BD's reference for "a pass of one" is `sim_chain_blend`, the phase-6 primitive
# this phase did not touch, driven directly with a fixture that includes negative zero and NaN.
#
# EVERY CRITERION HAS A CONTROL THAT MUST FAIL, and several of them are the same configuration wired the
# other way — a container versus a two-pass chain over the identical ground — so a green result cannot come
# from the two arrangements being the same arrangement.
#
# NOTHING IS SAVED. Bakes write into the terrain's in-memory layers; demo/data on disk is only touched by
# an explicit save, which nothing here calls.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/SimPhase65PassGate.tscn
extends Node

const DEMO_DATA := "res://demo/data"

# --- Sites, each with its own layer owner so their clear boxes cannot interact --------------------------
const SITE_AZ := Vector3(300.0, 0.0, 700.0)
const SITE_BA := Vector3(700.0, 0.0, 700.0)
const SITE_BB := Vector3(520.0, 0.0, 700.0)
const SITE_BC := Vector3(150.0, 0.0, 520.0)
const SITE_BD := Vector3(300.0, 0.0, 150.0)
const LOOP_HALF := 60.0
const CHAIN_MARGIN := 32.0

## Height agreement that counts as "the same surface" for a criterion that is about bit-exactness. Kept as
## an exact 0.0 comparison everywhere it is claimed; this is only the tolerance for the mask/terrain
## comparison in BB, where a sim-resolution field is sampled bilinearly against a terrain-grid height.
const MASK_TOL := 0.05

var _fail := 0
var _root: Node3D
var _terrain
var _data


func _ready() -> void:
	print("\n=== Pasture3DSimPass phase 6.5 (spec §21.9 gates AZ-BD) ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_data = _terrain.data
	if _data == null or not _data.has_method("sim_pass_accumulate"):
		_fail += 1
		print("!! this build has no sim_pass_accumulate — the container half is unbuilt, not failing")
		_done()
		return

	_gate_bd_arithmetic()
	_gate_az_same_input()
	_gate_ba_order_independent()
	_gate_bb_per_pass_masks()
	_gate_bc_build_through()
	_gate_bd_pass_of_one()

	_done()


func _done() -> void:
	print("\n=== %s (%d failures) ===\n" % ["SIM PHASE 6.5 PASS PASS" if _fail == 0 else "SIM PHASE 6.5 PASS FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- BD part 1: the fold, against the phase-6 primitive it must reproduce ----------------------------
#
# `sim_chain_blend` is what phase 6 folded every pass in with, and this phase did not touch it. So the
# claim "a pass of one is still phase 6" is testable WITHOUT running phase 6: drive both paths over one
# fixture and compare bytes.
#
# The fixture is built to hit the corners that a numerically-equal-but-not-identical implementation gets
# wrong: a NaN gate (outside the loop), a NaN height (no data), a delta of exactly zero, and NEGATIVE ZERO,
# which is where an accumulator that tests for 0 instead of carrying an untouched sentinel diverges.
func _gate_bd_arithmetic() -> void:
	print("\n[BD.1] one member is bitwise the phase-6 fold:")
	var n := 96
	var before := PackedFloat32Array()
	var after := PackedFloat32Array()
	var gate := PackedFloat32Array()
	before.resize(n)
	after.resize(n)
	gate.resize(n)
	var corners := 0
	# Built from its bit pattern, because every arithmetic route to it is folded away: GDScript turns both
	# the literal `-0.0` and `0.0 * -1.0` into positive zero, which quietly removed this corner from the
	# fixture twice before the assertion below caught it.
	var bits := PackedByteArray()
	bits.resize(4)
	bits.encode_u32(0, 0x80000000)
	var neg := bits.decode_float(0)
	for i in range(n):
		var h := 120.0 + 37.0 * sin(float(i) * 0.7) + float(i) * 0.013
		before[i] = h
		after[i] = h - 0.001 * float(i) - 0.4 * cos(float(i) * 0.31)
		gate[i] = clampf(float(i % 11) / 10.0, 0.0, 1.0)
		match i % 16:
			3:
				gate[i] = NAN         # outside this member's loop
				corners += 1
			5:
				# The sign-of-zero corner, WITH A LIVE GATE and a delta of exactly zero — the one place an
				# accumulator that uses 0 for "untouched" instead of a sentinel of its own diverges from the
				# phase-6 fold. Built by multiplication because the literal `-0.0` is folded to +0.0.
				before[i] = neg
				after[i] = neg
				gate[i] = 0.8
				corners += 1
			7:
				before[i] = NAN       # no data under this cell
				corners += 1
			9:
				after[i] = NAN        # the solver had no answer here
				corners += 1
			11:
				gate[i] = 0.0         # gated out, and a stored negative zero underneath
				before[i] = neg
				corners += 1
	# The fixture asserts its own corner: a +0.0 here would make the whole negative-zero case vanish
	# silently, and it did on the first run — GDScript folds the literal `-0.0` to positive zero.
	var neg_zero := before.to_byte_array().decode_u32(5 * 4) == 0x80000000
	print("    the negative-zero cells really are negative zero: %s" % neg_zero)
	if not neg_zero:
		_fail += 1
		print("    !! the ±0 corner is not in the fixture, so the untouched-cell sentinel is untested")
	var blend: PackedFloat32Array = _data.sim_chain_blend(before, after, gate)
	var acc: PackedFloat64Array = _data.sim_pass_accumulate(PackedFloat64Array(), before, after, gate)
	var one: PackedFloat32Array = _data.sim_pass_commit(before, acc)
	print("    %d cells, %d of them corner cases (NaN gate, NaN height, NaN solve, ±0)" % [n, corners])
	if blend.size() != n or one.size() != n:
		_fail += 1
		print("    !! one of the two paths returned nothing (%d vs %d)" % [blend.size(), one.size()])
		return
	var same := _bitwise(blend, one)
	print("    accumulate+commit vs sim_chain_blend: bitwise identical=%s" % same)
	if not same:
		_fail += 1
		print("    !! a pass of one is not the phase-6 fold, so every phase-6 scene changed")
		_first_diff(blend, one)

	# CONTROL: a SECOND member must move the answer. Without this the comparison above is satisfied by an
	# accumulator that ignores its input entirely.
	var after2 := PackedFloat32Array()
	after2.resize(n)
	for i in range(n):
		after2[i] = before[i] - 1.75
	var acc2: PackedFloat64Array = _data.sim_pass_accumulate(acc, before, after2, gate)
	var two: PackedFloat32Array = _data.sim_pass_commit(before, acc2)
	var moved := _max_diff(one, two)
	print("    CONTROL a second member into the same accumulator moves it by %.6f m (want > 0)" % moved)
	if moved <= 0.0:
		_fail += 1
		print("    !! a second member changed nothing, so this test cannot tell the two paths apart")

	# CONTROL: the sum must be ORDER-INDEPENDENT at the arithmetic level too — this is what BA rests on.
	var rev: PackedFloat64Array = _data.sim_pass_accumulate(
			_data.sim_pass_accumulate(PackedFloat64Array(), before, after2, gate), before, after, gate)
	var two_rev: PackedFloat32Array = _data.sim_pass_commit(before, rev)
	var swap_diff := _max_diff(two, two_rev)
	print("    CONTROL adding the two members the other way round differs by %.9f m (want exactly 0)" % swap_diff)
	if swap_diff != 0.0:
		_fail += 1
		print("    !! the accumulator is order-dependent, so BA cannot hold")


# --- AZ: every member reads the same input surface ---------------------------------------------------
#
# Two members of one container, with deliberately different rates and diffusion so each MOVES the ground
# differently, and overlapping loops so their deltas have somewhere to disagree.
#
# CONTROL, and it is the same two Sims over the same ground: pull them out of the container and make them
# two PASSES. That IS "feed member 2 member 1's output", and the surface must change. If the two
# arrangements agreed, the container would not be composing anything.
func _gate_az_same_input() -> void:
	print("\n[AZ] every member of a pass reads the same input surface:")
	var mgr := _make_manager("AZ", SITE_AZ)
	var box := _add_container(mgr, "Both")
	var deep := _add_member(box, "Deep", Vector3(-25.0, 0.0, 0.0), LOOP_HALF)
	var wide := _add_member(box, "Wide", Vector3(25.0, 0.0, 0.0), LOOP_HALF)
	if deep == null or wide == null:
		return
	deep.erosion_rate = 0.30
	deep.hillslope_diffusion = 0.05
	deep.iterations = 25
	wide.erosion_rate = 0.02
	wide.hillslope_diffusion = 1.5
	wide.iterations = 20

	var probes := _probe_ring(SITE_AZ)
	var base := _snapshot(probes)
	mgr.capture_chain = true
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the container did not run")
		return
	var as_box := _snapshot(probes)
	var chain: Array = mgr.last_chain
	if chain.size() != 2:
		_fail += 1
		print("    !! captured %d member run(s), wanted 2 — is the fixture one cluster?" % chain.size())
		return

	# The surface each member's SOLVER was handed, not what the bookkeeping says was handed over.
	var seed_a: PackedFloat32Array = chain[0]["z_seed"]
	var seed_b: PackedFloat32Array = chain[1]["z_seed"]
	var identical := _bitwise(seed_a, seed_b)
	print("    the two members' solver input surfaces (%d cells each): bitwise identical=%s" % [
			seed_a.size(), identical])
	if not identical:
		_fail += 1
		print("    !! member 2 was handed a different surface, so this is a chain wearing a container's name")
		_first_diff(seed_a, seed_b)

	# And they must each MOVE the ground, or "they read the same input" is a claim about two no-ops.
	var moved_a := _max_diff(chain[0]["z_in"], chain[0]["z_out"])
	var moved_b := _max_diff(chain[0]["z_out"], chain[1]["z_out"])
	print("    member movement over the cluster: Deep %.3f m, Wide adds %.3f m" % [moved_a, moved_b])
	if moved_a < 0.5 or moved_b < 0.05:
		_fail += 1
		print("    !! a member barely moved the ground, so AZ is comparing two no-ops")

	# CONTROL: the same two Sims as two passes, so member 2 DOES see member 1's output.
	box.remove_child(wide)
	mgr.add_child(wide)
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the two-pass control did not run")
		return
	var as_chain := _snapshot(probes)
	var spread := _max_abs_diff(as_box, as_chain)
	print("    CONTROL the same two Sims as a 2-PASS chain differ from the container by %.4f m (want > 0)"
			% spread)
	if spread <= 0.0:
		_fail += 1
		print("    !! a container and a chain of the same two Sims gave the same landscape, so the "
			+ "container's shared-input rule is not doing anything")
	if _max_abs_diff(base, as_box) <= 0.0:
		_fail += 1
		print("    !! the container wrote nothing to the terrain at all")

	# §21.2's DECIDED per-member `enabled`: skipped BEFORE its solve, so a disabled member must be exactly
	# as absent as a deleted one — not merely quiet, and not a member whose delta is multiplied by zero.
	mgr.remove_child(wide)
	box.add_child(wide)
	wide.enabled = false
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the container with a disabled member did not run")
		return
	var disabled := _snapshot(probes)
	box.remove_child(wide)
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the container with the member deleted did not run")
		return
	var absent := _snapshot(probes)
	print("    disabling a member vs deleting it: %.9f m (want exactly 0); it changed the landscape by "
			% _max_abs_diff(disabled, absent) + "%.4f m (want > 0)" % _max_abs_diff(as_box, disabled))
	if _max_abs_diff(disabled, absent) != 0.0:
		_fail += 1
		print("    !! a disabled member is not the same as an absent one")
	if _max_abs_diff(as_box, disabled) <= 0.0:
		_fail += 1
		print("    !! disabling a member changed nothing, so the toggle is untested")
	box.add_child(wide) # back in the tree, so nothing is left parentless at exit


# --- BA: a pass is order-independent, a chain is not -------------------------------------------------
#
# Three overlapping members with different settings, shuffled in the dock. The surface must come back
# EXACTLY — 0.000000 m, compared as an equality and not a tolerance.
#
# CONTROL: gate AH's control re-run one level up. Shuffle the manager's own children and the landscape MUST
# change. If both were stable, "order-independent" would be a property of the fixture, not of the design.
func _gate_ba_order_independent() -> void:
	print("\n[BA] members are order-independent, passes are not:")
	var mgr := _make_manager("BA", SITE_BA)
	var box := _add_container(mgr, "Three")
	var a := _add_member(box, "A", Vector3(-30.0, 0.0, 0.0), LOOP_HALF)
	var b := _add_member(box, "B", Vector3(20.0, 0.0, -10.0), LOOP_HALF * 0.8)
	var c := _add_member(box, "C", Vector3(0.0, 0.0, 30.0), LOOP_HALF * 0.9)
	if a == null or b == null or c == null:
		return
	a.erosion_rate = 0.28
	a.hillslope_diffusion = 0.05
	b.erosion_rate = 0.04
	b.hillslope_diffusion = 1.2
	b.iterations = 25
	c.erosion_rate = 0.15
	c.hillslope_diffusion = 0.4
	c.iterations = 15

	var probes := _probe_ring(SITE_BA)
	var base := _snapshot(probes)
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the container did not run")
		return
	var first := _snapshot(probes)
	if _max_abs_diff(base, first) <= 0.0:
		_fail += 1
		print("    !! the container wrote nothing, so shuffling it cannot mean anything")
		return

	box.move_child(c, 0)
	box.move_child(a, 2)
	print("    member order A,B,C -> %s" % ", ".join(box.members().map(func(s): return s.name)))
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the shuffled container did not run")
		return
	var shuffled := _snapshot(probes)
	var drift := _max_abs_diff(first, shuffled)
	print("    shuffling the MEMBERS moved the surface by %.9f m (want exactly 0)" % drift)
	if drift != 0.0:
		_fail += 1
		print("    !! a pass is not order-independent, so its members are behaving like passes")

	# CONTROL: the same three Sims as three PASSES, shuffled the same way.
	for s in [a, b, c]:
		box.remove_child(s)
		mgr.add_child(s)
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the three-pass control did not run")
		return
	var chain_first := _snapshot(probes)
	mgr.move_child(mgr.passes()[2], 0)
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the reordered three-pass control did not run")
		return
	var chain_shuffled := _snapshot(probes)
	var chain_drift := _max_abs_diff(chain_first, chain_shuffled)
	print("    CONTROL shuffling the same three as PASSES moved it by %.6f m (want > 0)" % chain_drift)
	if chain_drift <= 0.0:
		_fail += 1
		print("    !! reordering the passes changed nothing either, so this fixture cannot tell a member "
			+ "from a pass and BA measures nothing")


# --- BB: per-pass masks describe that pass's own output ----------------------------------------------
#
# The reference is an independent measurement: build through pass 1 ONLY, and read the resulting heights
# back out of the terrain. That surface is what pass 1 produced, established without asking any result
# resource anything. Then run the full chain and check that pass 1's stored masks still describe it.
#
# CONTROL: the same comparison against pass 2's masks and against the manager's whole-chain masks, both of
# which must differ measurably — and the flow field must be non-trivial, or the three are all empty.
func _gate_bb_per_pass_masks() -> void:
	print("\n[BB] the masks on pass N describe the surface after N:")
	var mgr := _make_manager("BB", SITE_BB)
	# CONCENTRIC loops, pass 2 inside pass 1, and that is load-bearing rather than tidy. Truncating the
	# chain also shrinks the CLUSTER (which is what BC is about), so a pass 2 whose box reached outside
	# pass 1's would make the reference build solve pass 1 on a different grid — and the first run of this
	# gate duly measured a 0.13 m boundary difference and called it a mask error. Nesting the loops removes
	# the variable, and the plan check below refuses to let it come back.
	var p1 := _add_pass(mgr, "Incise", Vector3.ZERO, LOOP_HALF)
	var p2 := _add_pass(mgr, "Smooth", Vector3.ZERO, LOOP_HALF * 0.6)
	if p1 == null or p2 == null:
		return
	p1.erosion_rate = 0.30
	p1.hillslope_diffusion = 0.05
	p1.iterations = 25
	p2.erosion_rate = 0.03
	p2.hillslope_diffusion = 1.5
	p2.iterations = 20

	var cut := mgr.plan_clusters(1, 0)
	var whole := mgr.plan_clusters(1)
	var same_grid := _plan_cells(cut) == _plan_cells(whole) and _plan_span(cut) == _plan_span(whole)
	print("    the reference build solves the same grid as the full chain: %s (%d vs %d cells)" % [
			same_grid, _plan_cells(cut), _plan_cells(whole)])
	if not same_grid:
		_fail += 1
		print("    !! truncating changes the cluster here, so 'the surface after pass 1' is not the same "
			+ "surface in the two runs and this gate would be measuring the boundary, not the masks")

	var probes := _inner_probes(SITE_BB, 24.0)
	var base := _snapshot(probes)
	# THE REFERENCE, measured through the terrain and not through any resource.
	if not bool(mgr.simulate_now(1, false, 0).get("ok", false)):
		_fail += 1
		print("    !! the build-through to pass 1 did not run")
		return
	var after1 := _snapshot(probes)
	var ref: Array[float] = []
	for i in range(base.size()):
		ref.append(after1[i] - base[i])
	var ref_size := _max_mag(ref)
	print("    reference: a build-through to pass 1 alone moved the ground by up to %.3f m at %d probes"
			% [ref_size, probes.size()])
	if ref_size < 0.5:
		_fail += 1
		print("    !! pass 1 barely moved the ground, so nothing here is being compared")
		return

	var full := mgr.simulate_now(1, false)
	if not bool(full.get("ok", false)):
		_fail += 1
		print("    !! the full chain did not run")
		return
	var after_all := _snapshot(probes)
	var chain_delta: Array[float] = []
	for i in range(base.size()):
		chain_delta.append(after_all[i] - base[i])
	# The passes must visibly disagree, or BB's control has nothing to be different from (§21.9's note).
	var pass2_size := _max_abs_diff(after1, after_all)
	print("    pass 2 then moved it a further %.3f m, so the two passes visibly disagree" % pass2_size)
	if pass2_size < 0.05:
		_fail += 1
		print("    !! pass 2 did almost nothing, so 'after 1' and 'after the chain' are the same surface")

	var r1: Pasture3DSimResult = p1.sim_result
	var r2: Pasture3DSimResult = p2.sim_result
	if r1 == null or not r1.is_valid() or r2 == null or not r2.is_valid():
		_fail += 1
		print("    !! a pass has no masks after a build (pass1=%s, pass2=%s)" % [
				"none" if r1 == null else r1.describe(), "none" if r2 == null else r2.describe()])
		return
	print("    pass 1: %s" % r1.describe())
	print("    pass 2: %s" % r2.describe())

	# Is the flow field non-trivial? A cell that drains only itself reads FLOW_FLOOR_M2, and if that is all
	# there is then the comparisons below are between three empty grids.
	# Over the WHOLE grid, not at the probes: a probe can legitimately sit on a ridge, and 16 of those
	# would report a trivial field over a perfectly good drainage network.
	var log_max := 0.0
	var channels := 0
	for v in r1.flow:
		log_max = maxf(log_max, v)
		if v > log(500.0):
			channels += 1
	var biggest := exp(log_max)
	print("    CONTROL pass 1's flow: largest catchment %.0f m², %d cell(s) draining over 500 m² "
			% [biggest, channels] + "(a lone cell reads %.0f)" % Pasture3DSimResult.FLOW_FLOOR_M2)
	if biggest < 1000.0 or channels < 50:
		_fail += 1
		print("    !! pass 1's flow field is trivial, so 'these masks route the surface' is untested")

	var err1 := _mask_error(r1, probes, ref)
	var err2 := _mask_error(r2, probes, ref)
	var errm := _mask_error(mgr.sim_result, probes, ref)
	print("    |pass 1 masks − the measured after-pass-1 delta|: worst %.4f m (want < %.2f)" % [err1, MASK_TOL])
	print("    CONTROL the same reference against pass 2's masks: %.4f m, against the whole chain's: %.4f m"
			% [err2, errm])
	if err1 > MASK_TOL:
		_fail += 1
		print("    !! pass 1's stored masks do not describe the surface pass 1 actually produced")
	if err2 <= MASK_TOL:
		_fail += 1
		print("    !! pass 2's masks match pass 1's reference just as well, so the masks are not per-pass")
	if errm <= MASK_TOL:
		_fail += 1
		print("    !! the manager's whole-chain masks match pass 1's reference, so nothing is per-pass")

	# §21.3's staleness rule: the masks carry the hash of the bake that wrote them, and are never cleared.
	var stale_before: String = r1.source_area_hash
	p2.position += Vector3(15.0, 0.0, 0.0) # re-tune a pass; pass 1's stored masks now describe the past
	var still_there := r1.is_valid() and r1.source_area_hash == stale_before
	print("    CONTROL after moving pass 2, pass 1's masks are still present and still carry their old "
			+ "bake hash: %s" % still_there)
	if not still_there:
		_fail += 1
		print("    !! a stale downstream result was auto-cleared; §21.3 says it must warn instead")

	# §21.3's DECIDED opt-OUT: Store Masks off means a pass is not rewritten at all. The moved loop above
	# gives the next bake a different hash, so "was it rewritten" is readable rather than a guess about
	# timestamps.
	p2.store_masks = false
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the re-bake with Store Masks off did not run")
		return
	var fresh := mgr._baked_hash
	print("    CONTROL with Store Masks off, pass 2 keeps the old bake hash (%s) while pass 1 takes the "
			% (r2.source_area_hash != fresh) + "new one (%s)" % (r1.source_area_hash == fresh))
	if r2.source_area_hash == fresh:
		_fail += 1
		print("    !! Store Masks off still rewrote the masks, so the opt-out does nothing")
	if r1.source_area_hash != fresh:
		_fail += 1
		print("    !! the pass that DID want masks was not rewritten either, so this measures nothing")


## Worst |net delta from the masks − the independently measured delta| over the probes.
func _mask_error(p_r: Pasture3DSimResult, p_probes: Array[Vector3], p_ref: Array[float]) -> float:
	if p_r == null or not p_r.is_valid():
		return INF
	var worst := 0.0
	for i in range(p_probes.size()):
		worst = maxf(worst, absf(p_r.net_delta_at(p_probes[i]) - p_ref[i]))
	return worst


# --- BC: build-through truncates and nothing else ----------------------------------------------------
#
# Simulating to pass N must give BITWISE the same surface as a chain whose later passes have been DELETED
# — which includes the clustering: pass 3's loop here reaches outside the other two, so if truncation
# dropped only the solve and not the box, the grid would differ and the surfaces could not match.
#
# CONTROL: the full untruncated chain, which must differ. Otherwise the later passes were doing nothing
# and truncation is untestable on this fixture.
func _gate_bc_build_through() -> void:
	print("\n[BC] build-through truncates, and changes nothing else:")
	var mgr := _make_manager("BC", SITE_BC)
	var p1 := _add_pass(mgr, "One", Vector3(-25.0, 0.0, 0.0), LOOP_HALF)
	var p2 := _add_pass(mgr, "Two", Vector3(15.0, 0.0, 0.0), LOOP_HALF * 0.8)
	var p3 := _add_pass(mgr, "Three", Vector3(70.0, 0.0, 40.0), LOOP_HALF * 0.7)
	if p1 == null or p2 == null or p3 == null:
		return
	p1.erosion_rate = 0.28
	p1.hillslope_diffusion = 0.05
	p2.erosion_rate = 0.05
	p2.hillslope_diffusion = 1.0
	p3.erosion_rate = 0.20
	p3.hillslope_diffusion = 0.2

	# Does pass 3 actually extend the cluster? If not, this gate is not testing the box at all.
	var plan_all := mgr.plan_clusters(1)
	var plan_cut := mgr.plan_clusters(1, 1)
	var span_all := _plan_span(plan_all)
	var span_cut := _plan_span(plan_cut)
	print("    the whole chain plans %d cluster(s) spanning %.0f m; truncated to pass 2, %d spanning %.0f m"
			% [plan_all["clusters"].size(), span_all, plan_cut["clusters"].size(), span_cut])
	if span_cut >= span_all:
		_fail += 1
		print("    !! pass 3 does not extend the cluster, so truncation's effect on the GRID is untested")

	var probes := _probe_ring(SITE_BC)
	var base := _snapshot(probes)
	if not bool(mgr.simulate_now(1, false, 1).get("ok", false)):
		_fail += 1
		print("    !! the build-through to pass 2 did not run")
		return
	var truncated := _snapshot(probes)
	print("    build-through to pass 2 moved the ground by %.3f m; manager reports passes 1-%d of %d"
			% [_max_abs_diff(base, truncated), mgr._baked_upto + 1, mgr.passes().size()])
	if mgr._baked_upto != 1:
		_fail += 1
		print("    !! the manager did not record the truncation, so a partial bake reads as a finished one")
	var says_partial := false
	for w in mgr._get_configuration_warnings():
		if String(w).contains("passes 1-2 of 3"):
			says_partial = true
	print("    CONTROL the node says so on itself: %s" % says_partial)
	if not says_partial:
		_fail += 1
		print("    !! nothing on screen distinguishes a partial build from a finished landscape")

	# The same chain with pass 3 DELETED.
	mgr.remove_child(p3)
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the two-pass chain did not run")
		mgr.add_child(p3)
		return
	var deleted := _snapshot(probes)
	var gap := _max_abs_diff(truncated, deleted)
	print("    truncated-to-2 vs pass-3-deleted: %.9f m (want exactly 0)" % gap)
	if gap != 0.0:
		_fail += 1
		print("    !! build-through is not the same thing as deleting the later passes")

	# CONTROL: the untruncated chain must differ, or pass 3 was a no-op and this proves nothing.
	mgr.add_child(p3)
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the full three-pass chain did not run")
		return
	var whole := _snapshot(probes)
	var moved := _max_abs_diff(truncated, whole)
	print("    CONTROL the full three-pass chain differs from the truncated one by %.4f m (want > 0)" % moved)
	if moved <= 0.0:
		_fail += 1
		print("    !! pass 3 changed nothing, so there was no truncation to detect")
	if mgr._baked_upto != -1:
		_fail += 1
		print("    !! a full build after a partial one still reads as partial")


func _plan_cells(p_plan: Dictionary) -> int:
	var n := 0
	for cl: Dictionary in p_plan["clusters"]:
		n += int(cl["cells"])
	return n


func _plan_span(p_plan: Dictionary) -> float:
	var lo := INF
	var hi := -INF
	for cl: Dictionary in p_plan["clusters"]:
		lo = minf(lo, float(cl["min_x"]))
		hi = maxf(hi, float(cl["max_x"]))
	return 0.0 if lo == INF else hi - lo


# --- BD part 2: a bare Sim under a manager is still a pass of one -------------------------------------
#
# A phase-6 scene — two bare Sims as two passes — versus the same two Sims each wrapped in a container of
# one. Bitwise identical, or a container of one is a different feature and every existing scene changed
# the day this shipped.
func _gate_bd_pass_of_one() -> void:
	print("\n[BD.2] a bare Sim is a pass of one, and a container of one is not a different feature:")
	var mgr := _make_manager("BD", SITE_BD)
	var p1 := _add_pass(mgr, "First", Vector3(-20.0, 0.0, 0.0), LOOP_HALF)
	var p2 := _add_pass(mgr, "Second", Vector3(20.0, 0.0, 10.0), LOOP_HALF * 0.85)
	if p1 == null or p2 == null:
		return
	p1.erosion_rate = 0.26
	p1.hillslope_diffusion = 0.08
	p2.erosion_rate = 0.06
	p2.hillslope_diffusion = 0.9
	p2.iterations = 25

	var probes := _probe_ring(SITE_BD)
	var base := _snapshot(probes)
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the phase-6-shaped chain did not run")
		return
	var bare := _snapshot(probes)
	var wrote := _max_abs_diff(base, bare)
	print("    two bare Sims as two passes moved the ground by %.3f m" % wrote)
	if wrote <= 0.0:
		_fail += 1
		print("    !! the phase-6-shaped chain wrote nothing, so wrapping it proves nothing")
		return

	# Each Sim into its own container, in the same order.
	var boxes: Array = []
	for i in range(2):
		var sim: Pasture3DSim = [p1, p2][i]
		var box := _add_container(mgr, "Box%d" % (i + 1))
		mgr.remove_child(sim)
		box.add_child(sim)
		boxes.append(box)
	print("    wrapped as %s" % ", ".join(mgr.passes().map(func(p): return "%s(%s)" % [
			p.name, ",".join(p.members().map(func(s): return s.name)) if p is Pasture3DSimPass else "bare"])))
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the wrapped chain did not run")
		return
	var boxed := _snapshot(probes)
	var gap := _max_abs_diff(bare, boxed)
	print("    bare Sims vs containers of one: %.9f m (want exactly 0)" % gap)
	if gap != 0.0:
		_fail += 1
		print("    !! a container of one is a different feature, so existing scenes change on upgrade")

	# CONTROL: put both Sims in ONE container and the landscape must change — otherwise "identical" above
	# was measured over an arrangement that cannot express the difference.
	var solo: Pasture3DSimPass = boxes[1]
	var second: Pasture3DSim = solo.members()[0]
	solo.remove_child(second)
	(boxes[0] as Pasture3DSimPass).add_child(second)
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the one-container control did not run")
		return
	var merged := _max_abs_diff(bare, _snapshot(probes))
	print("    CONTROL both Sims in ONE container instead differs by %.4f m (want > 0)" % merged)
	if merged <= 0.0:
		_fail += 1
		print("    !! collapsing two passes into one pass changed nothing, so the wrapping test is vacuous")


# --- Fixtures ----------------------------------------------------------------------------------------

func _make_manager(p_name: String, p_at: Vector3) -> Pasture3DSimManager:
	var m := Pasture3DSimManager.new()
	m.name = "M_" + p_name
	_root.add_child(m)
	m.terrain = _terrain
	m.global_position = p_at
	m.snap_to_surface = false
	m.catchment_margin = CHAIN_MARGIN
	m._layer_owner = "pasture3d_brush:Erosion65_%s" % p_name
	return m


func _add_container(p_mgr: Pasture3DSimManager, p_name: String) -> Pasture3DSimPass:
	var box := Pasture3DSimPass.new()
	box.name = p_name
	p_mgr.add_child(box)
	return box


## A pass of one: a bare Sim under the manager, which is the phase-6 shape.
func _add_pass(p_mgr: Pasture3DSimManager, p_name: String, p_offset: Vector3, p_half: float) -> Pasture3DSim:
	return _make_sim(p_mgr, p_mgr, p_name, p_offset, p_half)


## A member: a Sim under a container. Same node, same settings — only the parent differs.
func _add_member(p_box: Pasture3DSimPass, p_name: String, p_offset: Vector3, p_half: float) -> Pasture3DSim:
	return _make_sim(p_box, p_box.manager(), p_name, p_offset, p_half)


func _make_sim(p_parent: Node, p_mgr: Pasture3DSimManager, p_name: String, p_offset: Vector3,
		p_half: float) -> Pasture3DSim:
	var s := Pasture3DSim.new()
	s.name = p_name
	p_parent.add_child(s)
	s.terrain = _terrain
	s.snap_to_surface = false
	s.position = p_offset
	s.falloff_width = 12.0
	s.iterations = 20
	s.erosion_rate = 0.15
	s.hillslope_diffusion = 0.15
	_add_square(s, p_half)
	var at := p_mgr.global_position + p_offset
	if not is_finite(_data.get_height(at)):
		_fail += 1
		print("    !! no terrain at %s; the fixture is outside demo/data" % at)
		return null
	return s


func _add_square(p_sim: Pasture3DSim, p_half: float) -> void:
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	c.add_point(Vector3(-p_half, 0.0, -p_half))
	c.add_point(Vector3(p_half, 0.0, -p_half))
	c.add_point(Vector3(p_half, 0.0, p_half))
	c.add_point(Vector3(-p_half, 0.0, p_half))
	c.closed = true
	path.curve = c
	p_sim.add_child(path)


# --- Reading the ground ------------------------------------------------------------------------------

func _probe_ring(p_at: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for dz in [-30.0, -10.0, 10.0, 30.0]:
		for dx in [-30.0, -10.0, 10.0, 30.0]:
			out.append(p_at + Vector3(dx, 0.0, dz))
	return out


## A tighter ring, well inside every loop's falloff band, for the mask comparison in BB.
func _inner_probes(p_at: Vector3, p_r: float) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for dz in [-p_r, -p_r * 0.4, p_r * 0.4, p_r]:
		for dx in [-p_r, -p_r * 0.4, p_r * 0.4, p_r]:
			out.append(p_at + Vector3(dx, 0.0, dz))
	return out


func _snapshot(p_points: Array[Vector3]) -> Array[float]:
	var out: Array[float] = []
	for p in p_points:
		out.append(_data.get_height(Vector3(p.x, 0.0, p.z)))
	return out


func _max_abs_diff(p_a: Array[float], p_b: Array[float]) -> float:
	var m := 0.0
	for i in range(p_a.size()):
		if is_finite(p_a[i]) and is_finite(p_b[i]):
			m = maxf(m, absf(p_a[i] - p_b[i]))
	return m


func _max_mag(p_a: Array[float]) -> float:
	var m := 0.0
	for v in p_a:
		if is_finite(v):
			m = maxf(m, absf(v))
	return m


## Worst |a − b| over two grids, ignoring cells either side has no answer for.
func _max_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var m := 0.0
	for i in range(mini(p_a.size(), p_b.size())):
		if is_finite(p_a[i]) and is_finite(p_b[i]):
			m = maxf(m, absf(p_a[i] - p_b[i]))
	return m


## Byte-for-byte, which is stronger than equality and is what "bitwise" in the criteria means: it
## separates a NaN from a NaN with a different payload, and −0.0 from +0.0.
func _bitwise(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> bool:
	return p_a.size() == p_b.size() and p_a.to_byte_array() == p_b.to_byte_array()


## Where two grids first differ, compared as BITS. Comparing as floats would report every NaN cell as a
## difference (NaN != NaN) and miss the ±0 cell entirely, which is the opposite of useful here.
func _first_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> void:
	var ba := p_a.to_byte_array()
	var bb := p_b.to_byte_array()
	for i in range(mini(p_a.size(), p_b.size())):
		var ua := ba.decode_u32(i * 4)
		var ub := bb.decode_u32(i * 4)
		if ua != ub:
			print("       first difference at cell %d: %s (0x%08X) vs %s (0x%08X)" % [
					i, p_a[i], ua, p_b[i], ub])
			return
	print("       the bytes agree up to the shorter length; the sizes must differ")
