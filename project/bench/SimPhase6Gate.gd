# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Phase 6 gates AH-AN for Pasture3DSimManager, the pass chain (PASTURE3D_SIM_NODE_SPEC.md §19.8).
#
# Every criterion here is a claim about the NODE — there is no "drive the arithmetic directly" family,
# because a pass chain over a clustered grid IS the plumbing. So the gates build real managers on the demo
# terrain and read the result back through the layer and the Sim Result.
#
# THE FIXTURE IS SYNTHETIC, AND THAT IS THE POINT (AI, AJ, AK). Those three depend on there being real
# drainage across the boundary between two adjacent loops, and "the demo terrain probably slopes that way
# here" is not a fixture. So the gate writes its own surface — a tilted plane with coherent noise and one
# basin straddling the seam — into a REPLACE layer BELOW every manager's layer, and then asserts the
# property directly: what fraction of the seam column drains from A into B, measured by the gate's own
# steepest-descent search over its own analytic surface. That number is reported whether or not the
# criteria pass, so a green AJ can never be a green fixture.
#
# THE GATE COMPUTES ITS OWN REFERENCES. Curvature for AL is central differences written here. The expected
# drainage areas for AJ are derived from the geometry (mean upslope area over a column of a tilted plane
# is the distance to the upstream boundary), not read back out of a solve. Nothing asks the code under
# test what the right answer is.
#
# NOTHING IS SAVED. Bakes write into the terrain's in-memory layers; demo/data on disk is only touched by
# an explicit save, which nothing here calls.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/SimPhase6Gate.tscn
extends Node

const DEMO_DATA := "res://demo/data"

# --- The synthetic fixture (AI, AJ, AK) ------------------------------------------------------------
#
# A plane falling in +X, so water runs from loop A into loop B across the seam they share. The tilt
# dominates the noise everywhere (0.15 against a noise gradient of at most ~0.08), which is what makes the
# A→B drainage a property of the fixture rather than a hope about it — and it is still checked.
const FX_X0 := 160.0
const FX_X1 := 624.0
const FX_Z0 := 160.0
const FX_Z1 := 480.0
const FX_TOP := 400.0
const FX_TILT := 0.15
const FX_NOISE := 6.0
const FX_NOISE_FREQ := 0.008
## The shared edge. Loop A is upstream of it (lower X = higher ground), loop B downstream.
const SEAM := 392.0
const LOOP_X0 := 200.0
const LOOP_X1 := 584.0
const LOOP_Z0 := 200.0
const LOOP_Z1 := 440.0
## The two loops OVERLAP across the seam by this much, 20 m either side of it.
##
## Abutting loops were the first fixture and they were wrong — measurably. Each pass is masked to its own
## loop through its own falloff (§19.2 step 3), so two loops that merely touch leave a band at the join
## where NEITHER pass's gate reaches 1 and the original ground stands proud as a low ridge. The solve is
## still one grid, but the routing pass over the WRITTEN surface then finds a drainage divide sitting on
## the join: the first run of AJ measured 546 m² arriving at the seam and 13 m² leaving it.
##
## That is not a defect in the chain, it is §5's own advice — "overlap generously and let the falloff
## blend" — applying to passes exactly as it applied to Sims. The fixture overlaps.
const LOOP_OVERLAP := 20.0
## One closed basin sitting ON the seam, so a lake spans what used to be a boundary (AK).
##
## Deep and NARROW, and both halves of that were learned the hard way. Deep because the sim CUTS OUTLETS:
## a 32 m basin was breached inside 25 iterations and the depression fill then found nothing to flood, so
## AK had no lake to be one Pond of. Narrow because a basin's own rim gradient overwhelms the 0.15 tilt out
## to roughly the radius where D·(r/R²)·exp(−r²/2R²) falls back to it — about 60 m at these numbers — and
## everything inside that radius drains INTO the basin rather than across the seam. Widening it to survive
## the erosion would have eaten the very property the fixture exists to have.
const BASIN_X := 392.0
const BASIN_Z := 390.0
const BASIN_R := 20.0
const BASIN_D := 120.0
## Small on purpose. The margin is what an independent Sim gets INSTEAD of its neighbour's catchment, so a
## generous one would hide the very seam AJ is about.
const SEAM_MARGIN := 24.0
## Where the fixture's drainage direction is spot-checked: 80 m clear of the basin.
const FLOW_LINE_Z0 := 200.0
const FLOW_LINE_Z1 := 300.0

# --- Sites for the chain gates, each on its own layer owner so their clear boxes cannot interact ------
const SITE_CHAIN := Vector3(300.0, 0.0, 700.0)
const SITE_MASKS := Vector3(700.0, 0.0, 700.0)
const SITE_IDEMPOTENT := Vector3(520.0, 0.0, 700.0)
const SITE_WIPE := Vector3(150.0, 0.0, 520.0)
const LOOP_HALF := 60.0
const CHAIN_MARGIN := 32.0

## Mirrors Pasture3DReliefSelector.FilterType.
const K_CURVATURE := 2
## AL's hollow band, in §21.6's units: metres this cell sits below its four neighbours. 0.075 m at the
## fixture's 1 m sim cell is the 0.3 1/m Laplacian this gate was written against.
const CURV_BAND := 0.075

var _fail := 0
var _root: Node3D
var _terrain
var _data
var _fixture_noise: FastNoiseLite
var _fixture_layer := -1


func _ready() -> void:
	print("\n=== Pasture3DSimManager phase 6 (spec §19.8 gates AH-AN) ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_data = _terrain.data
	if _data == null or not _data.has_method("sim_chain_blend"):
		_fail += 1
		print("!! this build has no sim_chain_blend — phase 6 is unbuilt, not failing")
		_done()
		return

	_build_fixture()
	_gate_an_clustering()
	_gate_ah_chain_feeds_forward()
	_gate_al_masks_per_pass()
	_gate_am_idempotent()
	_gate_ai_one_writer()
	_gate_aj_ak_seam()

	_done()


func _done() -> void:
	print("\n=== %s (%d failures) ===\n" % ["SIM PHASE 6 PASS" if _fail == 0 else "SIM PHASE 6 FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- The fixture ------------------------------------------------------------------------------------

## The surface AI/AJ/AK run on, as a formula. This is the gate's own definition of the ground: it is what
## gets written into the terrain, what the write is verified against, and what the drainage-direction
## assertion below is computed from. One definition, so "the fixture is a tilted plane" cannot quietly
## stop being true of the thing actually solved.
func _fixture_height(p_x: float, p_z: float) -> float:
	var h := FX_TOP - FX_TILT * (p_x - FX_X0)
	h += FX_NOISE * _fixture_noise.get_noise_2d(p_x, p_z)
	var dx := p_x - BASIN_X
	var dz := p_z - BASIN_Z
	h -= BASIN_D * exp(-(dx * dx + dz * dz) / (2.0 * BASIN_R * BASIN_R))
	return h


## Stamp the fixture into a REPLACE layer created BEFORE any manager's, so it sits below every one of them
## and `composite_height_below(manager_layer)` reads it. An ADD layer would have left the demo terrain's
## own relief mixed in and made "the tilt dominates" a claim about ground the gate does not control.
func _build_fixture() -> void:
	print("[fixture] a tilted plane with noise and one seam-straddling basin, in a REPLACE layer:")
	_fixture_noise = FastNoiseLite.new()
	_fixture_noise.seed = 20260810
	_fixture_noise.frequency = FX_NOISE_FREQ
	_fixture_noise.fractal_octaves = 3

	var holder := Pasture3DSim.new()
	holder.name = "FixtureHolder"
	_root.add_child(holder)
	holder.terrain = _terrain
	holder._layer_owner = "pasture3d_brush:Phase6Base"
	_fixture_layer = holder._ensure_layer_for(holder._layer_owner, false)
	if _fixture_layer <= 0:
		_fail += 1
		print("    !! could not reserve the fixture layer; AI/AJ/AK have no ground to stand on")
		return
	var layer = holder._layer_at(_fixture_layer)
	layer.set_blend_mode(0) # REPLACE: the fixture IS the surface, not a bump on the demo terrain

	var gw := int(FX_X1 - FX_X0) + 1
	var gh := int(FX_Z1 - FX_Z0) + 1
	var vals := PackedFloat32Array()
	vals.resize(gw * gh)
	for iz in range(gh):
		var z := FX_Z0 + float(iz)
		for ix in range(gw):
			vals[iz * gw + ix] = _fixture_height(FX_X0 + float(ix), z)
	_data.apply_sim_block(_fixture_layer, FX_X0, FX_Z0, 1.0, gw, gh, vals, 0)
	var box := AABB(Vector3(FX_X0 - 4.0, -10000.0, FX_Z0 - 4.0),
			Vector3(FX_X1 - FX_X0 + 8.0, 20000.0, FX_Z1 - FX_Z0 + 8.0))
	_data.composite_area(box, false)
	_data.update_maps(0, false, false)

	# Did it land? A fixture written into a layer that does not composite would leave every criterion
	# below measuring the demo terrain instead, and passing or failing for reasons nothing here controls.
	var worst := 0.0
	for z in [FX_Z0 + 20.0, 256.0, BASIN_Z, FX_Z1 - 20.0]:
		for x in [FX_X0 + 20.0, 300.0, SEAM, 500.0, FX_X1 - 20.0]:
			worst = maxf(worst, absf(_data.get_height(Vector3(x, 0.0, z)) - _fixture_height(x, z)))
	print("    written %d x %d m; worst |terrain - formula| over 20 probes: %.6f m" % [gw, gh, worst])
	if worst > 0.01:
		_fail += 1
		print("    !! the fixture did not composite; AI/AJ/AK would measure the demo terrain instead")
		return

	# THE PROPERTY AI/AJ/AK DEPEND ON, asserted rather than inferred: does loop A actually drain into
	# loop B? Steepest descent over the gate's own surface at every cell of the seam column.
	#
	# Reported twice. The whole column includes the basin, whose own catchment legitimately runs INWARD
	# rather than downstream, so that figure is a description of the fixture. The band AJ actually measures
	# on excludes the basin, and THAT is the number the criterion depends on.
	var whole := _drains_into_b(LOOP_Z0, LOOP_Z1)
	var band := _drains_into_b(FLOW_LINE_Z0, FLOW_LINE_Z1)
	print("    cross-boundary drainage at x=%.0f: %.1f%% of the whole seam column runs into loop B, and "
			% [SEAM, whole] + "%.1f%% of the Z %.0f..%.0f band clear of the basin (whose own catchment "
			% [band, FLOW_LINE_Z0, FLOW_LINE_Z1] + "drains inward by design)")
	if band < 99.0:
		_fail += 1
		print("    !! the fixture has no consistent cross-boundary drainage, so AI/AJ/AK are empty")
	if whole < 45.0:
		_fail += 1
		print("    !! the basin has grown until it dominates the seam, and the tilt no longer decides "
			+ "where the water goes")


## Percentage of the seam column over [p_z0, p_z1] whose steepest descent runs into loop B (+X), computed
## from the gate's own analytic surface rather than from anything the extension produced.
func _drains_into_b(p_z0: float, p_z1: float) -> float:
	var into_b := 0
	var total := 0
	for iz in range(int(p_z0), int(p_z1) + 1):
		var z := float(iz)
		var best := 0.0
		var best_dx := 0
		for dx in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				if dx == 0 and dz == 0:
					continue
				var drop := _fixture_height(SEAM, z) - _fixture_height(SEAM + dx, z + dz)
				drop /= sqrt(float(dx * dx + dz * dz))
				if drop > best:
					best = drop
					best_dx = dx
		total += 1
		if best_dx > 0:
			into_b += 1
	return 100.0 * float(into_b) / float(maxi(total, 1))


# --- AN: clustering, and the budget refuses ---------------------------------------------------------
# Two loops further apart than their margins must solve as TWO grids; moved within a margin, ONE. The
# criterion is the grid COUNT changing across the move — a manager that always unions and one that always
# splits both pass a single-configuration test, so a single configuration is not a test.
#
# Then the budget: a cluster over it must be REFUSED BY NAME and nothing written. §19.4 is explicit that
# this must not coarsen, because §6 measured that a coarser grid erodes deeper — so the second half checks
# that the refused plan still reports the FULL grid, not a smaller one it quietly settled for.
func _gate_an_clustering() -> void:
	print("\n[AN] clustering by margin, and a cell budget that refuses:")
	var mgr := _make_manager("AN", Vector3(300.0, 0.0, 150.0))
	mgr.catchment_margin = 40.0
	var far := _add_pass(mgr, "Far", Vector3(-160.0, 0.0, 0.0), 40.0)
	var near := _add_pass(mgr, "Near", Vector3(160.0, 0.0, 0.0), 40.0)
	if far == null or near == null:
		return
	# Loop half-width 40, centres 320 m apart, so 240 m of daylight between the loop edges. Grown by 40
	# either side that is still 160 m short of touching.
	var apart := mgr.plan_clusters(1)
	print("    loop edges 240 m apart, margin 40 m -> %d cluster(s)" % apart["clusters"].size())

	# Now inside each other's margins: centres 120 m apart leaves 40 m between the edges, and 40 m of
	# margin on each side closes it with 40 m to spare.
	near.position = Vector3(-40.0, 0.0, 0.0)
	var together := mgr.plan_clusters(1)
	print("    moved to 40 m apart, same margin    -> %d cluster(s)" % together["clusters"].size())
	if int(apart["clusters"].size()) != 2:
		_fail += 1
		print("    !! two loops beyond each other's margins did not stay two grids")
	if int(together["clusters"].size()) != 1:
		_fail += 1
		print("    !! two loops inside each other's margins did not merge into one grid")
	if int(apart["clusters"].size()) == int(together["clusters"].size()):
		_fail += 1
		print("    !! the cluster count did not change across the move, so this measures nothing")

	# CONTROL on the merged grid: it must be BIGGER than either loop alone, or "merged" is a label on
	# two grids that still solve separately.
	if int(together["clusters"].size()) == 1:
		var cl: Dictionary = together["clusters"][0]
		var span: float = cl["max_x"] - cl["min_x"]
		print("    CONTROL the merged grid spans %.0f m in X (one loop + its margins is %.0f m)" % [
				span, 80.0 + 80.0])
		if span < 200.0:
			_fail += 1
			print("    !! the merged cluster is not wide enough to contain both loops")
		if (cl["passes"] as Array).size() != 2:
			_fail += 1
			print("    !! the merged cluster does not list both passes, so only one would run on it")
	if together["clusters"].is_empty():
		return

	# The budget. Set below what the merged cluster actually needs — a fixed number would either be
	# unreachable or trivially exceeded as the fixture moves, and the point is the refusal, not the size.
	var full: Dictionary = together["clusters"][0]
	mgr.max_cluster_cells = int(full["cells"]) / 2
	var refused := mgr.plan_clusters(1)
	var named := String(refused["reason"]).contains("Far") and String(refused["reason"]).contains("Near")
	print("    budget %d cells against a %d x %d = %d cell cluster: ok=%s, names the passes=%s" % [
			mgr.max_cluster_cells, full["sw"], full["sh"], full["cells"], refused["ok"], named])
	if bool(refused["ok"]):
		_fail += 1
		print("    !! an over-budget cluster was accepted")
	if not named:
		_fail += 1
		print("    !! the refusal does not name the cluster, so there is nothing to act on")
	# CONTROL: it refused, it did not coarsen.
	if not refused["clusters"].is_empty():
		var still: Dictionary = refused["clusters"][0]
		print("    CONTROL the refused plan still reports %d x %d cells (want the same %d x %d)" % [
				still["sw"], still["sh"], full["sw"], full["sh"]])
		if int(still["sw"]) != int(full["sw"]) or int(still["sh"]) != int(full["sh"]):
			_fail += 1
			print("    !! the over-budget cluster was COARSENED rather than refused")
	var before := _snapshot(_probe_ring(Vector3(300.0, 0.0, 150.0)))
	var report: Dictionary = mgr.simulate_now(1, false)
	var moved := _max_abs_diff(before, _snapshot(_probe_ring(Vector3(300.0, 0.0, 150.0))))
	print("    a refused build: ok=%s, surface moved %.6f m (want exactly 0)" % [report["ok"], moved])
	if bool(report["ok"]) or moved != 0.0:
		_fail += 1
		print("    !! the refusal still wrote to the terrain")
	mgr.max_cluster_cells = 4194304


# --- AH: the chain feeds forward --------------------------------------------------------------------
# Pass 2's input surface must be BITWISE pass 1's output, and the committed delta must be z_N - z0.
#
# CONTROL: reverse the pass order. The result must differ — if it does not, the passes are being summed
# independently and the chain is decorative. The two passes are given different rates, different diffusion
# and different loops precisely so that order CAN matter; identical passes would make the control vacuous
# no matter how the chain is wired.
func _gate_ah_chain_feeds_forward() -> void:
	print("\n[AH] the chain feeds forward, and the write is z_N - z0:")
	var mgr := _make_manager("AH", SITE_CHAIN)
	var p1 := _add_pass(mgr, "Incise", Vector3.ZERO, LOOP_HALF)
	var p2 := _add_pass(mgr, "Smooth", Vector3(20.0, 0.0, 0.0), LOOP_HALF * 0.7)
	if p1 == null or p2 == null:
		return
	p1.erosion_rate = 0.25
	p1.hillslope_diffusion = 0.05
	p1.iterations = 25
	p2.erosion_rate = 0.02
	p2.hillslope_diffusion = 1.2
	p2.iterations = 15
	mgr.capture_chain = true
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the chain did not run")
		return
	var chain: Array = mgr.last_chain
	if chain.size() != 2:
		_fail += 1
		print("    !! captured %d pass(es), wanted 2" % chain.size())
		return

	var z0: PackedFloat32Array = chain[0]["z_in"]
	var z1: PackedFloat32Array = chain[0]["z_out"]
	var zn: PackedFloat32Array = chain[1]["z_out"]
	# The surface handed to the SOLVER for pass 2, not the surface the chain's bookkeeping says it handed
	# over. Those are the same thing in a correct implementation and different in a broken one: seeding
	# every pass from z0 — the chain cut outright — left the bookkeeping capture intact and AH green.
	var z1_seed: PackedFloat32Array = chain[1].get("z_seed", PackedFloat32Array())
	if z1_seed.size() != z1.size():
		_fail += 1
		print("    !! pass 2's solver input was not captured, so there is nothing to compare")
		return
	var mismatch := 0
	for i in range(z1.size()):
		if z1[i] != z1_seed[i]:
			mismatch += 1
	print("    what pass 2's solver was handed vs pass 1's output: %d of %d cells differ (want 0, bitwise)"
			% [mismatch, z1.size()])
	if mismatch != 0:
		_fail += 1
		print("    !! pass 2 did not start from pass 1's output")

	# The handover has to carry something, or "bitwise identical" is a statement about two copies of z0.
	var pass1_moved := _max_abs_packed(_sub(z0, z1))
	var pass2_moved := _max_abs_packed(_sub(z1, zn))
	print("    pass 1 moved the chain %.4f m; pass 2 then moved it a further %.4f m" % [
			pass1_moved, pass2_moved])
	if pass1_moved < 0.05 or pass2_moved < 0.05:
		_fail += 1
		print("    !! a pass did nothing, so the feed-forward carries no information")

	# The committed delta. At build resolution the sim grid and the write grid coincide, so the layer's
	# contribution at a world point must equal z_N - z0 at that same cell, exactly.
	var cl: Dictionary = mgr.plan_clusters(1)["clusters"][0]
	var worst := 0.0
	var checked := 0
	for dz in range(-40, 41, 10):
		for dx in range(-40, 41, 10):
			var p := SITE_CHAIN + Vector3(float(dx), 0.0, float(dz))
			var ix := int(round(p.x - float(cl["min_x"])))
			var iz := int(round(p.z - float(cl["min_z"])))
			if ix < 0 or iz < 0 or ix >= int(cl["sw"]) or iz >= int(cl["sh"]):
				continue
			var want: float = zn[iz * int(cl["sw"]) + ix] - z0[iz * int(cl["sw"]) + ix]
			var got: float = _data.get_height(p) - _height_below(mgr, p)
			worst = maxf(worst, absf(want - got))
			checked += 1
	print("    committed delta vs z_N - z0 over %d probes: worst |difference| %.6f m" % [checked, worst])
	if checked < 20:
		_fail += 1
		print("    !! too few probes landed on the cluster grid to say anything")
	if worst > 1.0e-3:
		_fail += 1
		print("    !! what reached the layer is not the chain's total delta")

	# CONTROL: reverse the order.
	var probes := _probe_ring(SITE_CHAIN)
	var forward := _snapshot(probes)
	mgr.move_child(p2, 0)
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the reversed chain did not run")
		return
	var reversed := _max_abs_diff(forward, _snapshot(probes))
	print("    CONTROL passes reversed: the surface moved %.4f m (want > 0.05)" % reversed)
	if reversed <= 0.05:
		_fail += 1
		print("    !! reversing the passes changed nothing, so they are being summed, not chained")


# --- AL: masks re-evaluate per pass -----------------------------------------------------------------
# A CURVATURE mask on pass 2 must gate on the hollows pass 1 cut, not on the original ground.
#
# The gate computes curvature itself, twice — once over z0 and once over pass 1's output — and forms the
# cell set each would select. The mask pass 2 ACTUALLY used is captured from the chain. It must agree with
# the second and disagree with the first.
#
# CONTROL: evaluate the same selector once, up front, against z0. That set must be measurably different —
# and the two predictions must differ from each other in the first place, or the criterion is empty
# whatever the implementation does.
func _gate_al_masks_per_pass() -> void:
	print("\n[AL] the pass-2 mask is evaluated against pass 1's output, not against z0:")
	var mgr := _make_manager("AL", SITE_MASKS)
	var p1 := _add_pass(mgr, "Cut", Vector3.ZERO, LOOP_HALF)
	var p2 := _add_pass(mgr, "Fill", Vector3.ZERO, LOOP_HALF)
	if p1 == null or p2 == null:
		return
	p1.erosion_rate = 0.35
	p1.hillslope_diffusion = 0.02
	p1.iterations = 40
	p2.erosion_rate = 0.05
	p2.iterations = 5
	# Concave ground only: curvature is positive in a hollow, and pass 1's gullies are hollows that were
	# not there before — which is the whole idiom §19.5 exists for.
	#
	# The band is 0.075 rather than the 0.3 this gate shipped with because §21.6 changed the unit from the
	# 1/m Laplacian to METRES of deviation over one cell, and at this fixture's 1 m sim cell the two differ
	# by exactly 4. Same ground, same cells: only the number the artist would type has moved.
	var band := _sel(K_CURVATURE, CURV_BAND, 100.0)
	p2.erosion_mask = [band] as Array[Pasture3DReliefSelector]
	mgr.capture_chain = true
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the chain did not run")
		return
	var chain: Array = mgr.last_chain
	if chain.size() != 2 or (chain[1]["mask"] as PackedFloat32Array).is_empty():
		_fail += 1
		print("    !! pass 2 captured no mask field")
		return
	var cl: Dictionary = mgr.plan_clusters(1)["clusters"][0]
	var w: int = cl["sw"]
	var h: int = cl["sh"]
	var cell: float = cl["cell"]
	var z0: PackedFloat32Array = chain[0]["z_in"]
	var z1: PackedFloat32Array = chain[1]["z_in"]
	var actual: PackedFloat32Array = chain[1]["mask"]

	var want_z1 := _cells_above(_curvature(z1, w, h, cell), CURV_BAND)
	var want_z0 := _cells_above(_curvature(z0, w, h, cell), CURV_BAND)
	var got := _cells_above(actual, 0.5)
	print("    the gate's own curvature band: %d cells over z0, %d over pass 1's output" % [
			want_z0.size(), want_z1.size()])
	# FIXTURE CHECK: if pass 1 did not change what the band selects, AL cannot tell the two apart.
	var self_overlap := _overlap(want_z1, want_z0)
	print("    fixture: only %.1f%% of the post-pass-1 band was already in the pre-pass-1 band" % [
			100.0 * self_overlap])
	if want_z1.size() < 200 or want_z0.size() < 200:
		_fail += 1
		print("    !! one of the two bands is nearly empty, so the comparison is meaningless")
		return
	if self_overlap > 0.8:
		_fail += 1
		print("    !! pass 1 barely moved the curvature band; AL is comparing two of the same thing")
		return

	var to_z1 := _overlap(got, want_z1)
	var to_z0 := _overlap(got, want_z0)
	print("    the mask pass 2 USED: %.1f%% of its passing cells are in the post-pass-1 band, "
			% [100.0 * to_z1] + "%.1f%% in the pre-pass-1 band" % [100.0 * to_z0])
	if to_z1 < 0.9:
		_fail += 1
		print("    !! pass 2's mask does not follow the surface pass 1 left")
	if to_z1 <= to_z0:
		_fail += 1
		print("    !! pass 2's mask matches the ORIGINAL ground at least as well, so it was evaluated once "
			+ "up front")

	# CONTROL: the same selector evaluated once against z0, which is what "not re-evaluated" would mean.
	var once: PackedFloat32Array = _data.selector_mask_field(z0, {
			"gw": w, "gh": h, "cell_size": cell, "min_x": cl["min_x"], "min_z": cl["min_z"],
		}, PackedFloat32Array(band.to_params()), {})
	var once_cells := _cells_above(once, 0.5)
	var agree := _overlap(got, once_cells)
	print("    CONTROL evaluated once against z0: %d cells, %.1f%% of the real mask's cells (want < 90%%)"
			% [once_cells.size(), 100.0 * agree])
	if agree >= 0.9:
		_fail += 1
		print("    !! evaluating up front gives the same mask, so re-evaluation is unobservable here")


# --- AM: the chain is idempotent --------------------------------------------------------------------
# Gate H against the manager: a re-run must reproduce the surface to 0.000000 m.
#
# CONTROL is H's own — the same two-pass chain seeded from the FINISHED COMPOSITE, with the previous bake
# still in the layer. That is the drift class `composite_height_below` exists to prevent, and per-pass
# mask re-evaluation (§19.5) looks exactly like it until this measurement says otherwise.
func _gate_am_idempotent() -> void:
	print("\n[AM] re-running the chain reproduces the surface (gate H against the manager):")
	var mgr := _make_manager("AM", SITE_IDEMPOTENT)
	var p1 := _add_pass(mgr, "One", Vector3.ZERO, LOOP_HALF)
	var p2 := _add_pass(mgr, "Two", Vector3(15.0, 0.0, 15.0), LOOP_HALF * 0.8)
	if p1 == null or p2 == null:
		return
	p1.erosion_rate = 0.2
	p1.iterations = 25
	p2.erosion_rate = 0.1
	p2.hillslope_diffusion = 0.4
	p2.iterations = 15
	# A mask on pass 2, so the re-evaluation §19.5 adds is inside what is being called idempotent.
	p2.erosion_mask = [_sel(K_CURVATURE, 0.0025, 100.0)] as Array[Pasture3DReliefSelector] # §21.6 units
	var probes := _probe_ring(SITE_IDEMPOTENT)
	var base := _snapshot(probes)
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the first chain did not run")
		return
	var run1 := _snapshot(probes)
	var moved := _max_abs_diff(run1, base)
	print("    the first run really moved the ground: max |delta| %.4f m" % moved)
	if moved < 0.05:
		_fail += 1
		print("    !! nothing was baked, so AM would compare two untouched surfaces")
		return
	mgr.simulate_now(1, false)
	var drift := _max_abs_diff(_snapshot(probes), run1)
	print("    re-run drift: %.9f m (want exactly 0)" % drift)
	if drift != 0.0:
		_fail += 1
		print("    !! the chain drifts on re-run; something in it is reading the finished composite")

	var c1 := _wrong_source_chain(mgr, probes)
	var c2 := _wrong_source_chain(mgr, probes)
	if c1.is_empty() or c2.is_empty():
		_fail += 1
		print("    !! the control could not run; AM has no evidence drift is detectable")
	else:
		var c_drift := _max_abs_diff(c2, c1)
		print("    CONTROL the same chain seeded from the full composite: drift %.6f m (want > 1e-3)"
				% c_drift)
		if c_drift <= 1.0e-3:
			_fail += 1
			print("    !! reading the composite did not drift, so the zero above proves nothing")
	mgr.clear_simulation()


# --- AI: one writer ---------------------------------------------------------------------------------
# After a manager build exactly one layer holds a delta, and no pass has reserved a layer of its own.
#
# CONTROL: two of today's standalone Sims on ONE shared layer, which must show the mutual wipe §19.1
# describes. Without it, "the manager does not wipe" is a claim about a collision that may never have been
# possible at these positions in the first place.
func _gate_ai_one_writer() -> void:
	print("\n[AI] one writer: the manager's layer, and no pass has one of its own:")
	var mgr := _make_manager("AI", Vector3.ZERO)
	mgr.catchment_margin = SEAM_MARGIN
	var a := _add_rect_pass(mgr, "Upstream", LOOP_X0, SEAM + LOOP_OVERLAP, LOOP_Z0, LOOP_Z1)
	var b := _add_rect_pass(mgr, "Downstream", SEAM - LOOP_OVERLAP, LOOP_X1, LOOP_Z0, LOOP_Z1)
	if a == null or b == null:
		return
	var probes := _seam_probes()
	var base := _snapshot(probes)
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the manager build failed")
		return
	var moved := _max_abs_diff(base, _snapshot(probes))
	print("    the build moved the ground: max |delta| %.4f m" % moved)
	if moved < 0.05:
		_fail += 1
		print("    !! nothing was written, so 'exactly one layer holds it' is trivially true")
		return
	# Poke the passes down the path a spline-handle drag takes. This is what makes the criterion bite:
	# with nothing but `simulate_now` run against them, no pass ever reaches `_ensure_layer_for` at all, so
	# "no pass reserved a layer" was true whether or not anything prevented it — deleting the guard that
	# prevents it left AI green. `_refresh_owner` is the body `refresh()` runs (which early-returns outside
	# the editor, hence the direct call), and it asks for a layer for its owner before doing anything else.
	for p: Pasture3DSim in [a, b]:
		p._refresh_owner(p._layer_owner, false, [])
	var a_layer: int = _data.find_layer_by_owner(a._layer_owner)
	var b_layer: int = _data.find_layer_by_owner(b._layer_owner)
	var m_layer: int = _data.find_layer_by_owner(mgr._layer_owner)
	print("    after an auto-refresh on each pass — layers: manager=%d, pass '%s'=%d, pass '%s'=%d "
			% [m_layer, a.name, a_layer, b.name, b_layer] + "(want the passes at -1)")
	if m_layer < 0:
		_fail += 1
		print("    !! the manager has no layer, so nothing was committed anywhere")
	if a_layer >= 0 or b_layer >= 0:
		_fail += 1
		print("    !! a pass reserved a layer of its own; there are two writers again")
	# And the delta really is in the manager's layer, not somewhere else that happens to look right.
	var in_mine := 0.0
	for p in probes:
		in_mine = maxf(in_mine, absf(_data.get_height(p) - _height_below(mgr, p)))
	print("    the manager's own layer contributes: max %.4f m of the %.4f m that moved" % [in_mine, moved])
	if in_mine < moved * 0.5:
		_fail += 1
		print("    !! most of the change is not in the manager's layer")

	# ONE WRITER also means one WRITE AREA: §19.2 step 3 masks every pass to its own loop, so the catchment
	# margin is simulated over and never written — gate G's claim, re-earned by the chain. Without this
	# nothing here would notice a manager that folded each pass in unmasked, which is the one part of §19.2
	# that a "the total delta is z_N − z0" check cannot see (both are still true of an unmasked chain).
	var margin_probes: Array[Vector3] = []
	for z in [260.0, 320.0, 380.0]:
		margin_probes.append(Vector3(LOOP_X0 - 12.0, 0.0, z))   # inside the 24 m margin, outside every loop
		margin_probes.append(Vector3(LOOP_X1 + 12.0, 0.0, z))
	var leaked := 0.0
	for p in margin_probes:
		leaked = maxf(leaked, absf(_data.get_height(p) - _fixture_height(p.x, p.z)))
	print("    the catchment margin, simulated but never written: max %.6f m from the untouched fixture "
			% leaked + "(want ~0 against the %.4f m written inside)" % moved)
	if leaked > 0.01:
		_fail += 1
		print("    !! the chain wrote outside its passes' loops, so a pass is not masked to its own loop")

	# CONTROL: two standalone Sims sharing a layer, close enough that their tile-snapped clears collide.
	#
	# The probes matter as much as the layout. They sit inside Sim 1's loop, OUTSIDE Sim 2's loop, and
	# inside the whole layer tiles Sim 2's bake drops — which is precisely the geometry §19.1 describes
	# ("close means within about a tile, not merely overlapping"). Probing inside Sim 2's loop would have
	# measured Sim 2's own erosion arriving and called it survival; probing outside the tile boundary would
	# have measured ground the clear never reached and called it a wipe that did not happen. The first run
	# of this control did the second of those and reported no wipe at all.
	print("    CONTROL two standalone Sims on one shared layer:")
	var s1 := _make_standalone("Wipe1", SITE_WIPE)
	var s2 := _make_standalone("Wipe2", SITE_WIPE + Vector3(130.0, 0.0, 0.0))
	if s1 == null or s2 == null:
		return
	s1.falloff_width = 4.0
	s2.falloff_width = 4.0
	s1._layer_owner = "pasture3d_brush:Erosion_Shared"
	s2._layer_owner = "pasture3d_brush:Erosion_Shared"
	var w_probes: Array[Vector3] = []
	for x in [194.0, 198.0, 202.0, 206.0]:
		for z in [500.0, 520.0, 540.0]:
			w_probes.append(Vector3(x, 0.0, z))
	var w_base := _snapshot(w_probes)
	s1.simulate_now(1, false)
	var after_s1 := _snapshot(w_probes)
	var s1_moved := _max_abs_diff(w_base, after_s1)
	s2.simulate_now(1, false)
	var s1_left := _max_abs_diff(w_base, _snapshot(w_probes))
	# The probes must be outside Sim 2's own write area, or "what remains" is really "what Sim 2 added".
	var inside_s2 := s2._inside_write_area(s2._write_polygons(), w_probes[0])
	print("      probes at X 194..206: inside Sim 1's loop, inside Sim 2's tile clear, inside Sim 2's "
			+ "own loop = %s (want false)" % inside_s2)
	if inside_s2:
		_fail += 1
		print("      !! the probes are inside Sim 2's loop, so this cannot tell a wipe from a re-bake")
	print("      Sim 1 eroded there by %.4f m; after Sim 2 baked, %.4f m of it remains" % [
			s1_moved, s1_left])
	if s1_moved < 0.05:
		_fail += 1
		print("      !! the control's first Sim did not erode, so there was nothing to wipe")
	elif s1_left > s1_moved * 0.25:
		_fail += 1
		print("      !! the two standalone Sims did NOT wipe each other, so the fixture never had the "
			+ "collision the manager claims to fix")


# --- AJ / AK: the seam is gone, and features cross it intact ----------------------------------------
# Two adjacent loops whose catchments cross their shared edge. Under one manager the drainage area is
# continuous across the boundary; as independent Sims it is not — and the expected numbers on both sides
# come from the geometry, not from a solve.
#
# For a plane tilted in +X, the MEAN upstream drainage area over a cross-slope column at x is the distance
# from x back to the upstream edge of whatever grid solved it, times the cell area per unit width. So the
# manager should read about (x - cluster_min_x) m² and independent Sim B about (x - (SEAM - margin)) m².
# The gate prints both predictions beside both measurements.
func _gate_aj_ak_seam() -> void:
	print("\n[AJ] one grid, so drainage runs across what used to be a boundary:")
	var mgr := _make_manager("AJ", Vector3.ZERO)
	mgr.catchment_margin = SEAM_MARGIN
	mgr.river_area_threshold = 1500.0
	mgr.min_river_length = 20.0
	mgr.lake_depth_threshold = 0.5
	mgr.min_lake_area = 400.0
	var a := _add_rect_pass(mgr, "Up", LOOP_X0, SEAM + LOOP_OVERLAP, LOOP_Z0, LOOP_Z1)
	var b := _add_rect_pass(mgr, "Down", SEAM - LOOP_OVERLAP, LOOP_X1, LOOP_Z0, LOOP_Z1)
	if a == null or b == null:
		return
	var plan := mgr.plan_clusters(1)
	if int(plan["clusters"].size()) != 1:
		_fail += 1
		print("    !! the two adjacent loops did not cluster into one grid; there is no seam to delete")
		return
	var cl: Dictionary = plan["clusters"][0]
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the manager build failed")
		return
	var probe_x := SEAM + 10.0
	var m_before := _max_flow(mgr.sim_result, SEAM - 10.0)
	var m_after := _max_flow(mgr.sim_result, probe_x)

	# The same two areas as independent Sims, each with the same margin and the same loops.
	var s_a := _make_standalone_rect("SoloUp", LOOP_X0, SEAM + LOOP_OVERLAP, LOOP_Z0, LOOP_Z1, SEAM_MARGIN)
	var s_b := _make_standalone_rect("SoloDown", SEAM - LOOP_OVERLAP, LOOP_X1, LOOP_Z0, LOOP_Z1, SEAM_MARGIN)
	if s_a == null or s_b == null:
		return
	for s in [s_a, s_b]:
		s.river_area_threshold = 1500.0
		s.min_river_length = 20.0
		s.lake_depth_threshold = 0.5
		s.min_lake_area = 400.0
	s_a.simulate_now(1, false)
	s_b.simulate_now(1, false)
	var i_before := _max_flow(s_a.sim_result, SEAM - 10.0)
	var i_after := _max_flow(s_b.sim_result, probe_x)

	# THE REFERENCE, computed from geometry rather than from a solve. For ground tilted in +X, the upstream
	# catchment of a column is everything between it and the upstream edge of whatever grid solved it, so
	# the RATIO of the two measurements is fixed by where those two edges are. The absolute means are
	# larger than the flat-plane figure because flow converges into the measured band from outside it — but
	# both runs converge alike, so the ratio survives what the absolute number does not.
	var solo_bound := _upstream_bound(s_b.sim_result, probe_x)
	var mgr_bound := _upstream_bound(mgr.sim_result, probe_x)
	print("    trunk catchment crossing x=%.0f (just past the seam): manager %.0f m², independent %.0f m²"
			% [probe_x, m_after, i_after])
	print("    the ceilings their grids impose there: manager %.0f m² (edge at x=%.0f), independent "
			% [mgr_bound, mgr.sim_result.min_x] + "%.0f m² (edge at x=%.0f)"
			% [solo_bound, s_b.sim_result.min_x])
	print("    continuity across the seam (x=%.0f -> x=%.0f): manager %.2f, independent %.2f" % [
			SEAM - 10.0, probe_x, m_after / maxf(m_before, 1.0), i_after / maxf(i_before, 1.0)])
	if m_before < 1000.0:
		_fail += 1
		print("    !! only %.0f m² of catchment arrives at the seam at all; the fixture is not draining "
			% m_before + "A->B and AJ has nothing to measure")
		return
	# The ceiling comparison is REPORTED, not asserted, and the reason is worth writing down. "The manager
	# exceeds what an independent grid could hold" would be assumption-free — but it demands that ONE trunk
	# carry more than (402−345)/(402−173) = 25% of the whole domain's upstream area, and how much of a
	# domain a single trunk collects is a fact about how many parallel channels the fixture happens to grow,
	# not about the manager. It landed 262 m² short of a 16 815 m² ceiling. Tightening the fixture until it
	# cleared would have been tuning the gate to its answer.
	print("    (the ceiling is loose: clearing it would need one trunk to carry %.0f%% of the whole "
			% (100.0 * solo_bound / maxf(mgr_bound, 1.0)) + "domain, which is a property of the channel "
			+ "network, not of the manager — reported, not asserted)")
	if i_after > solo_bound:
		_fail += 1
		print("    !! the independent Sim reports more catchment than its own grid contains, so these "
			+ "numbers are not what they are being read as")
	if m_after / maxf(m_before, 1.0) < 0.8:
		_fail += 1
		print("    !! the manager's trunk catchment DROPS across the seam, so the grid is not really shared")
	# CONTROL: the same two areas as independent Sims must show the discontinuity. The fixture drains
	# +X across the seam at 100% (asserted above), so a field that loses three quarters of its catchment
	# there is demonstrably wrong about ground the manager gets right.
	if i_after / maxf(i_before, 1.0) > 0.5:
		_fail += 1
		print("    !! the independent Sims agree across the boundary too, so the fixture has no seam and "
			+ "the claim is empty")
	if m_after < i_after * 2.0:
		_fail += 1
		print("    !! the manager did not give loop B materially more catchment than it had alone")

	# --- AK ---------------------------------------------------------------------------------------
	#
	# Extraction is clipped to the write area (§10.4), so the boundary that matters is each node's own
	# write edge — x = 412 for the upstream Sim, x = 372 for the downstream one. A run reaching both the
	# X 352..367 and the X 417..432 window has crossed BOTH of those edges, which only the manager, whose
	# write area is the union of every pass's loops, can return in one piece.
	#
	# The lake is the same thing from the other side: its shoreline leaves both single loops, so each
	# independent Sim DROPS it (a Pond is one closed loop with no way to express a clipped shore). The
	# control therefore has to show the lake was there BEFORE the clip, or "they did not produce it" would
	# be a statement about a basin that never flooded.
	print("\n[AK] features cross the former boundary intact:")
	var mw := mgr.extract_water()
	if not bool(mw.get("ok", false)):
		_fail += 1
		print("    !! the manager's extraction failed: %s" % mw.get("reason", ""))
		return
	var m_span := _runs_spanning_seam(mw["rivers"])
	var m_lakes := _basin_lakes(mw["lakes"])
	print("    manager: %d river run(s), %d of them reaching both X %.0f..%.0f and X %.0f..%.0f; "
			% [(mw["rivers"] as Array).size(), m_span, SEAM - 40.0, SEAM - 25.0, SEAM + 25.0, SEAM + 40.0]
			+ "%d lake(s), %d on the basin" % [(mw["lakes"] as Array).size(), m_lakes])
	for lake: Dictionary in (mw["lakes"] as Array):
		var c: PackedVector3Array = lake["contour"]
		var mid := Vector3.ZERO
		for p in c:
			mid += p
		mid /= maxf(float(c.size()), 1.0)
		print("      lake at (%.0f, %.0f), %.0f m², %.2f m deep (the basin is at (%.0f, %.0f))" % [
				mid.x, mid.z, lake["area"], lake["depth"], BASIN_X, BASIN_Z])
	if m_span < 1:
		_fail += 1
		print("    !! no river came back as one run across the former boundary")
	if m_lakes != 1:
		_fail += 1
		print("    !! the basin straddling the seam did not come out as exactly one Pond")

	var wa := s_a.extract_water()
	var wb := s_b.extract_water()
	var i_span := 0
	var i_lakes := 0
	var i_rivers := 0
	var i_pre_rivers := 0
	var i_pre_lakes := 0
	for w in [wa, wb]:
		if bool(w.get("ok", false)):
			i_rivers += (w["rivers"] as Array).size()
			i_span += _runs_spanning_seam(w["rivers"])
			i_lakes += _basin_lakes(w["lakes"])
			i_pre_rivers += int(w.get("rivers_before_clip", 0))
			i_pre_lakes += int(w.get("lakes_before_clip", 0))
	print("    CONTROL independent: %d river run(s) after clipping (%d before), %d reaching both windows; "
			% [i_rivers, i_pre_rivers, i_span] + "%d Pond(s) on the basin (%d lakes before clipping)"
			% [i_lakes, i_pre_lakes])
	if i_pre_rivers < 1 or i_pre_lakes < 1:
		_fail += 1
		print("    !! the independent Sims found no channels or no lakes even before clipping, so this "
			+ "control cannot show the clip cutting anything")
	if i_span > 0:
		_fail += 1
		print("    !! an independent Sim returned a run crossing its own write edge, so the windows are "
			+ "not measuring the clip the manager widens")
	if i_lakes > 0:
		_fail += 1
		print("    !! an independent Sim kept the shared basin, so 'one Pond' has nothing to be better than")
	if i_lakes == 0 and m_lakes == 1:
		print("      (the independents do not HALVE the lake, they lose it: a shore leaving the write area "
			+ "is dropped whole, so the basin vanishes from both. §19.8 predicted two half-Ponds.)")


# --- fixtures ---------------------------------------------------------------------------------------

func _make_manager(p_name: String, p_at: Vector3) -> Pasture3DSimManager:
	var m := Pasture3DSimManager.new()
	m.name = "M_" + p_name
	_root.add_child(m)
	m.terrain = _terrain
	m.global_position = p_at
	m.snap_to_surface = false
	m.catchment_margin = CHAIN_MARGIN
	m._layer_owner = "pasture3d_brush:Erosion_%s" % p_name
	return m


## One pass: a square loop of half-width `p_half`, offset from the manager's origin.
func _add_pass(p_mgr: Pasture3DSimManager, p_name: String, p_offset: Vector3, p_half: float) -> Pasture3DSim:
	var s := Pasture3DSim.new()
	s.name = p_name
	p_mgr.add_child(s)
	s.terrain = _terrain
	s.snap_to_surface = false
	s.position = p_offset
	s.falloff_width = 12.0
	s.iterations = 20
	s.erosion_rate = 0.15
	s.hillslope_diffusion = 0.15
	_add_square(s, p_half)
	if not is_finite(_data.get_height(p_mgr.global_position + p_offset)):
		_fail += 1
		print("    !! no terrain at %s; the fixture is outside demo/data" % (p_mgr.global_position + p_offset))
		return null
	return s


## A pass whose loop is an axis-aligned world rect — the AI/AJ/AK layout, where the two loops share an
## edge exactly and the seam has to be a world coordinate rather than an offset.
func _add_rect_pass(p_mgr: Pasture3DSimManager, p_name: String, p_x0: float, p_x1: float,
		p_z0: float, p_z1: float) -> Pasture3DSim:
	var s := Pasture3DSim.new()
	s.name = p_name
	p_mgr.add_child(s)
	s.terrain = _terrain
	s.snap_to_surface = false
	s.global_position = Vector3.ZERO
	s.falloff_width = 8.0
	s.iterations = 25
	s.erosion_rate = 0.2
	s.hillslope_diffusion = 0.1
	_add_rect(s, p_x0, p_x1, p_z0, p_z1)
	return s


func _make_standalone(p_name: String, p_at: Vector3) -> Pasture3DSim:
	if not is_finite(_data.get_height(p_at)):
		_fail += 1
		print("    !! no terrain at %s" % p_at)
		return null
	var s := Pasture3DSim.new()
	s.name = p_name
	_root.add_child(s)
	s.terrain = _terrain
	s.global_position = p_at
	s.snap_to_surface = false
	s.catchment_margin = CHAIN_MARGIN
	s.falloff_width = 12.0
	s.iterations = 20
	s.erosion_rate = 0.15
	s._layer_owner = "pasture3d_brush:Erosion_%s" % p_name
	_add_square(s, LOOP_HALF)
	return s


func _make_standalone_rect(p_name: String, p_x0: float, p_x1: float, p_z0: float, p_z1: float,
		p_margin: float) -> Pasture3DSim:
	var s := Pasture3DSim.new()
	s.name = p_name
	_root.add_child(s)
	s.terrain = _terrain
	s.global_position = Vector3.ZERO
	s.snap_to_surface = false
	s.catchment_margin = p_margin
	s.falloff_width = 8.0
	s.iterations = 25
	s.erosion_rate = 0.2
	s.hillslope_diffusion = 0.1
	s._layer_owner = "pasture3d_brush:Erosion_%s" % p_name
	_add_rect(s, p_x0, p_x1, p_z0, p_z1)
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


func _add_rect(p_sim: Pasture3DSim, p_x0: float, p_x1: float, p_z0: float, p_z1: float) -> void:
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	c.add_point(Vector3(p_x0, 0.0, p_z0))
	c.add_point(Vector3(p_x1, 0.0, p_z0))
	c.add_point(Vector3(p_x1, 0.0, p_z1))
	c.add_point(Vector3(p_x0, 0.0, p_z1))
	c.closed = true
	path.curve = c
	p_sim.add_child(path)


func _sel(p_kind: int, p_lo: float, p_hi: float) -> Pasture3DReliefSelector:
	var s := Pasture3DReliefSelector.new()
	s.filter_type = p_kind # first — a filter type change re-defaults an untouched band (§21.5)
	s.range_min = p_lo
	s.range_max = p_hi
	s.falloff_low = 0.0
	s.falloff_high = 0.0
	s.invert = false
	s.strength = 1.0
	s.measure_radius = 0.0 # this gate computes its own ONE-CELL curvature; CURVATURE's preset sets 8 m
	return s


# --- AM's control: the same chain, seeded from the wrong surface -------------------------------------

## One run of the WRONG pipeline: read the chain's initial surface from the FINISHED COMPOSITE (which
## already holds the previous bake) instead of from below the manager's own layer, then run the same two
## passes with the same gates and write. Mirrors SimPhase1Gate's `_wrong_source_run`, extended to a chain.
func _wrong_source_chain(p_mgr: Pasture3DSimManager, p_probes: Array[Vector3]) -> Array[float]:
	var empty: Array[float] = []
	var plan := p_mgr.plan_clusters(1)
	if not bool(plan["ok"]) or plan["clusters"].is_empty():
		return empty
	var cl: Dictionary = plan["clusters"][0]
	var layer_id: int = p_mgr._ensure_layer_for(p_mgr._layer_owner, true)
	if layer_id <= 0:
		return empty
	var w: int = cl["sw"]
	var h: int = cl["sh"]
	var min_x: float = cl["min_x"]
	var min_z: float = cl["min_z"]
	# THE BUG, on purpose.
	var z0 := PackedFloat32Array()
	z0.resize(w * h)
	for iz in range(h):
		for ix in range(w):
			z0[iz * w + ix] = _data.get_height(Vector3(min_x + ix * float(cl["cell"]), 0.0,
					min_z + iz * float(cl["cell"])))
	var z := z0
	var ones := PackedFloat32Array()
	ones.resize(w * h)
	ones.fill(1.0)
	for m: Dictionary in cl["passes"]:
		var sim: Pasture3DSim = m["pass"]
		var res: Dictionary = _data.erode_heightfield(z, {
				"gw": w, "gh": h, "cell_size": cl["cell"], "time_step": 1.0,
				"iterations": sim.iterations, "erosion_rate": sim.erosion_rate,
				"area_exponent": sim.area_exponent, "diffusion": sim.hillslope_diffusion},
				PackedFloat32Array())
		if not bool(res.get("ok", false)):
			return empty
		for s in m["splines"]:
			var poly: PackedVector2Array = p_mgr._polygon_xz(s)
			var gate: PackedFloat32Array = _data.sim_mask_deltas(ones, poly, {
					"sw": w, "sh": h, "gw": w, "gh": h,
					"sim_min_x": min_x, "sim_min_z": min_z, "sim_cell": cl["cell"],
					"min_x": min_x, "min_z": min_z, "vs": cl["cell"],
					"edge_offset": sim.edge_offset, "falloff_width": sim.falloff_width},
					p_mgr._ramp_lut(sim.falloff_curve))
			if gate.size() == w * h:
				z = _data.sim_chain_blend(z, res["z"], gate)
	var write: PackedFloat32Array = _data.sim_chain_write(z0, z, {
			"sw": w, "sh": h, "gw": cl["tw"], "gh": cl["th"],
			"sim_min_x": min_x, "sim_min_z": min_z, "sim_cell": cl["cell"],
			"min_x": min_x, "min_z": min_z, "vs": _terrain.vertex_spacing})
	var box := AABB(Vector3(min_x, -10000.0, min_z),
			Vector3(float(cl["max_x"] - min_x), 20000.0, float(cl["max_z"] - min_z)))
	var clip: AABB = p_mgr._snap_aabb_to_tiles(box, p_mgr._layer_tile_world(layer_id))
	_data.clear_layer_in_area(layer_id, clip)
	_data.apply_sim_block(layer_id, min_x, min_z, _terrain.vertex_spacing, cl["tw"], cl["th"], write, 1)
	_data.composite_area(clip, false)
	_data.update_maps(0, false, false)
	return _snapshot(p_probes)


# --- the gate's own reference fields -----------------------------------------------------------------
#
# Central differences over the cell size, clamped at the edges — a SECOND implementation of what
# relief_fields_build does. If this called into the extension the gate would be asking the code under test
# what the right answer is.

func _curvature(p_z: PackedFloat32Array, p_w: int, p_h: int, p_cell: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_w * p_h)
	# §21.6 units: METRES of deviation over one cell — the ring mean minus the centre — not the 1/m
	# Laplacian this gate was written against. The band constants below moved with it.
	for iz in range(p_h):
		var row := iz * p_w
		var zm := maxi(iz - 1, 0) * p_w
		var zp := mini(iz + 1, p_h - 1) * p_w
		for ix in range(p_w):
			var xm := maxi(ix - 1, 0)
			var xp := mini(ix + 1, p_w - 1)
			out[row + ix] = (p_z[row + xp] + p_z[row + xm] + p_z[zp + ix] + p_z[zm + ix]
					- 4.0 * p_z[row + ix]) * 0.25
	return out


# --- helpers ----------------------------------------------------------------------------------------

## The LARGEST upstream drainage area crossing a full cross-slope column of a result, in m² — the trunk
## channel's catchment where it passes that X.
##
## Three statistics were tried here and the first two were wrong in instructive ways. A MEAN over part of
## the column measures whether the sampling landed on a channel: drainage area is violently concentrated,
## and it read 24 m² on one side of the seam and 1267 m² on the other. The SUM over the whole column looks
## like a conserved quantity and is not — a channel meandering in X crosses the same column several times
## and its whole accumulated area is counted at each crossing, inflating the two runs by 2.4x and 4.4x and
## destroying the ratio it was supposed to predict. The MEDIAN has a closed form on a tilted plane, but the
## surface being routed is the ERODED one, and on dissected ground the median cell sits near a local divide
## and reads 8 m² whatever is upstream.
##
## The maximum needs none of that. It is one cell's value, it is what "how much catchment arrives here"
## means, and it supports an assumption-free test: a grid whose upstream edge is at X0 cannot route more
## than (x − X0) × width through x, so a manager reading MORE than an independent Sim's entire upstream
## extent could hold is carrying water that Sim's grid never had.
func _max_flow(p_result: Pasture3DSimResult, p_x: float) -> float:
	if p_result == null or not p_result.is_valid():
		return 0.0
	var best := 0.0
	for iz in range(p_result.height):
		best = maxf(best, p_result.drainage_area_at(
				Vector3(p_x, 0.0, p_result.min_z + float(iz) * p_result.cell_size)))
	return best


## Everything upstream of `p_x` inside a result's own extent, in m². The hard ceiling on what any channel
## crossing that column can possibly be draining.
func _upstream_bound(p_result: Pasture3DSimResult, p_x: float) -> float:
	if p_result == null or not p_result.is_valid():
		return 0.0
	return maxf(p_x - p_result.min_x, 0.0) * float(p_result.height) * p_result.cell_size


## River runs with points in BOTH of two X windows straddling the seam.
##
## The windows are chosen so that only a manager can reach both: the upstream window sits inside loop A but
## upstream of loop B's write edge, and the downstream window inside loop B but past loop A's. An
## independent Sim is clipped to its own write area (§10.4), so its runs are cut before they reach the far
## window however far the real channel goes — which is exactly "two Troughs where there should be one".
##
## Not "the longest segment", which was the first attempt and measures the wrong thing: extraction returns
## one polyline per link BETWEEN CONFLUENCES (§10.1), so even an unbroken trunk arrives pre-split and both
## runs reported the same 141 m.
func _runs_spanning_seam(p_rivers: Array) -> int:
	var n := 0
	for seg: Dictionary in p_rivers:
		var up := false
		var down := false
		for p: Vector3 in (seg["points"] as PackedVector3Array):
			if p.x >= SEAM - 40.0 and p.x <= SEAM - 25.0:
				up = true
			elif p.x >= SEAM + 25.0 and p.x <= SEAM + 40.0:
				down = true
		if up and down:
			n += 1
	return n


## Lakes whose shoreline sits on the seam basin, wherever their contour reaches.
func _basin_lakes(p_lakes: Array) -> int:
	var n := 0
	for lake: Dictionary in p_lakes:
		var c: PackedVector3Array = lake["contour"]
		if c.is_empty():
			continue
		var mid := Vector3.ZERO
		for p in c:
			mid += p
		mid /= float(c.size())
		if absf(mid.x - BASIN_X) < 60.0 and absf(mid.z - BASIN_Z) < 60.0:
			n += 1
	return n






## The composite height below a node's own layer at a world point — what its bake read, so the difference
## against get_height is exactly that node's own contribution.
func _height_below(p_node, p_at: Vector3) -> float:
	var layer_id: int = _data.find_layer_by_owner(p_node._layer_owner)
	if layer_id <= 0:
		return _data.get_height(p_at)
	var g: PackedFloat32Array = _data.composite_height_below(layer_id, p_at.x, p_at.z, 1.0, 1, 1)
	return g[0] if g.size() == 1 else NAN


func _cells_above(p_a: PackedFloat32Array, p_at_least: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in range(p_a.size()):
		if p_a[i] >= p_at_least:
			out.append(i)
	return out


## |A ∩ B| / |A| — how much of the passing set really belongs to the reference set.
func _overlap(p_a: PackedInt32Array, p_b: PackedInt32Array) -> float:
	if p_a.is_empty():
		return 0.0
	var want := {}
	for i in p_b:
		want[i] = true
	var hit := 0
	for i in p_a:
		if want.has(i):
			hit += 1
	return float(hit) / float(p_a.size())


func _sub(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_a.size())
	for i in range(p_a.size()):
		out[i] = p_b[i] - p_a[i]
	return out


func _max_abs_packed(p_a: PackedFloat32Array) -> float:
	var m := 0.0
	for v in p_a:
		if is_finite(v):
			m = maxf(m, absf(v))
	return m


func _probe_ring(p_at: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for dz in [-30.0, -10.0, 10.0, 30.0]:
		for dx in [-30.0, -10.0, 10.0, 30.0]:
			out.append(p_at + Vector3(dx, 0.0, dz))
	return out


## Probes spread across both fixture loops, well inside their falloff bands.
func _seam_probes() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for x in [230.0, 300.0, 360.0, 420.0, 490.0, 555.0]:
		for z in [240.0, 300.0, 350.0]:
			out.append(Vector3(x, 0.0, z))
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
