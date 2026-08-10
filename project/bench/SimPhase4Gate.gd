# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Phase 4 gates M, N, O, Y, Z for Pasture3DSim (PASTURE3D_SIM_NODE_SPEC.md §14): river and lake
# extraction, and the generated Trough / Pond brushes.
#
#   N  confluences split into separate links       control: what a source-to-outlet walk would total
#   O  extraction is monotonic in the threshold    control: the counts must actually move across it
#   Y  a bowl yields one lake of the right size    control: no bowl -> no lakes; min_lake_area filters
#   Z  the eroded surface is reconstructed exactly control: reconstruct WITHOUT the delta -> it diverges
#   M  Clear removes exactly the generated set     control: a name-based collector destroys authored work
#
# N, O and Y drive Pasture3DData.sim_extract_water directly on synthetic fields whose answer is known by
# construction — a Y-shaped catchment has three links and a paraboloid bowl on a flat plain floods to a
# computable area and depth. M and Z drive a real Pasture3DSim on the demo terrain, because bookkeeping
# and surface reconstruction are claims about the node, not about the maths.
#
# Z is the one that guards the clever bit. Extraction does NOT re-solve and does not store a fifth
# channel: it rebuilds the eroded surface as (the surface below Sim's layer) + (erosion + deposition),
# which is exact by construction and free. If it were ever not exact, every river and every lake would
# move to a network that was never simulated, and nothing else here would notice.
#
# NOTHING IS SAVED. The gate builds brushes into the terrain's in-memory layers and its Sim Result is
# created without a file.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/SimPhase4Gate.tscn
extends Node

const DEMO_DATA := "res://demo/data"
const SG := 128
const SCELL := 4.0
const BASE_Z := 200.0

## The Y-catchment fixture: two tributaries meeting at the junction, then one trunk to the outlet.
const Y_LEFT := Vector2i(32, 12)
const Y_RIGHT := Vector2i(96, 12)
const Y_JOIN := Vector2i(64, 64)
const Y_OUT := Vector2i(64, 126)
const GROOVE_DEPTH := 12.0
const GROOVE_WIDTH := 7.0

## The lake fixture: a paraboloid bowl on a FLAT plain, so both answers are closed-form. On a tilted
## plain the water surface clips the slope and the flooded region stops being computable.
const BOWL_R := 60.0
const BOWL_DEPTH := 28.0

## Node-gate site. Chosen for having a large closed basin in it as well as escarpments: without one,
## Add Brushes produces only Troughs and the whole Pond half of §10 ships ungated. (bench/SimResultProbe
## found the basin — the demo terrain's own authored one, which the sim drains slightly rather than
## creates.)
const SITE_NODE := Vector3(512.0, 0.0, 200.0)
const SIM_HALF := 190.0
const SIM_MARGIN := 48.0

var _fail := 0
var _root: Node3D
var _terrain
var _data


func _ready() -> void:
	print("\n=== Pasture3DSim phase 4 (spec §14 gates M, N, O, Y, Z: water features) ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_data = _terrain.data
	if _data == null or not _data.has_method("sim_extract_water"):
		_fail += 1
		print("!! this build has no sim_extract_water — phase 4 is unbuilt, not failing")
		_done()
		return

	_gate_n_confluences()
	_gate_o_monotonic()
	_gate_y_lakes()
	_gate_z_reconstruction()
	_gate_m_clear()

	_done()


func _done() -> void:
	print("\n=== %s (%d failures) ===\n" % ["SIM PHASE 4 PASS" if _fail == 0 else "SIM PHASE 4 FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- N: confluences split -------------------------------------------------------------------------
# A Y-shaped catchment must come back as THREE links — left tributary, right tributary, trunk — not as
# two paths that both run the trunk. §10.1 is explicit about why: one polyline per source-to-outlet would
# overlap on every shared trunk and carve it once per tributary.
#
# The count alone is not enough, because three overlapping paths would also be three. So the criterion is
# also that the links PARTITION the channel: summed over the segments, the cell count must be the number
# of channel cells plus only the junction, which each of the three links touches.
# CONTROL: the total a source-to-outlet walk would have produced, computed from the measured trunk
# length. It must be clearly larger, or the partition test cannot tell the two schemes apart.
func _gate_n_confluences() -> void:
	print("[N] a Y-shaped catchment yields three links, not two overlapping paths:")
	var z := _y_catchment()
	var w := _extract(z, {"river_area_threshold": 4000.0, "min_river_length": 20.0,
			"curve_tolerance": 1.0})
	if w.is_empty():
		return
	var rivers: Array = w["rivers"]
	var channel_cells := int(w["channel_cells"])
	print("    %d channel cells -> %d link(s)" % [channel_cells, rivers.size()])
	for i in range(rivers.size()):
		var seg: Dictionary = rivers[i]
		var pts: PackedVector3Array = seg["points"]
		print("      link %d: %d cells, %.0f m, %d points after simplification, from (%.0f, %.0f) to (%.0f, %.0f)" % [
				i, int(seg["cells"]), float(seg["length"]), pts.size(),
				pts[0].x, pts[0].z, pts[pts.size() - 1].x, pts[pts.size() - 1].z])
	if channel_cells < 100:
		_fail += 1
		print("    !! the fixture carved almost no channel; N would be counting noise")
		return
	if rivers.size() != 3:
		_fail += 1
		print("    !! expected exactly 3 links from one confluence")
		return

	var total := 0
	var trunk := 0
	for seg: Dictionary in rivers:
		total += int(seg["cells"])
		trunk = maxi(trunk, 0)
	# The trunk is the link whose start is the junction: the one every tributary drains into. Identified
	# as the segment with the largest drainage area at its FIRST point.
	var best := -INF
	for seg: Dictionary in rivers:
		var areas: PackedFloat32Array = seg["areas"]
		if areas[0] > best:
			best = areas[0]
			trunk = int(seg["cells"])
	var overlap := total - channel_cells
	print("    cells across the links %d vs %d channel cells: %+d of overlap (want <= 4)" % [
			total, channel_cells, overlap])
	if overlap > 4:
		_fail += 1
		print("    !! the links overlap; this is not a partition of the channel network")

	# CONTROL
	var naive := channel_cells + trunk
	print("    CONTROL source-to-outlet would total %d cells (%+d of overlap), so the test can see it" % [
			naive, naive - channel_cells])
	if naive - channel_cells <= 4:
		_fail += 1
		print("    !! the trunk is too short for double-carving to be visible; N proves nothing here")


# --- O: extraction is monotonic in the threshold ---------------------------------------------------
# Raising the area a cell must drain before it counts as a river can only ever remove channel cells, so
# the channel set shrinks monotonically. The LINK count is not monotone for free — losing a tributary can
# merge two links into one, or split a trunk — so what must hold is that the channel cells never grow,
# and that the link count never grows either once the network only loses branches.
# CONTROL: the counts have to actually move across the sweep. A threshold range where nothing changes
# would satisfy monotonicity trivially.
func _gate_o_monotonic() -> void:
	print("\n[O] raising the river threshold never grows the network:")
	var z := _noisy_slope()
	var prev_cells := 1 << 30
	var prev_links := 1 << 30
	var counts: Array[int] = []
	var ok := true
	for thr: float in [1000.0, 2000.0, 4000.0, 8000.0, 16000.0, 32000.0]:
		var w := _extract(z, {"river_area_threshold": thr, "min_river_length": 20.0,
				"curve_tolerance": 1.0})
		if w.is_empty():
			return
		var cells := int(w["channel_cells"])
		var links: int = w["rivers"].size()
		counts.append(links)
		print("    threshold %8.0f m2 -> %5d channel cells, %3d link(s)" % [thr, cells, links])
		if cells > prev_cells:
			ok = false
			print("      !! the channel set GREW when the threshold rose")
		if links > prev_links:
			ok = false
			print("      !! the link count GREW when the threshold rose")
		prev_cells = cells
		prev_links = links
	if not ok:
		_fail += 1

	# CONTROL
	var moved: bool = counts[0] != counts[counts.size() - 1]
	print("    CONTROL the count moved across the sweep: %d -> %d (%s)" % [
			counts[0], counts[counts.size() - 1], "yes" if moved else "NO"])
	if not moved:
		_fail += 1
		print("    !! nothing changed over the whole sweep; monotonicity is trivially true here")


# --- Y: lakes come off the depression fill, at the right size and depth ----------------------------
# A paraboloid bowl on a FLAT plain has a closed-form answer for both numbers the Pond needs, which is
# the whole reason the fixture is not the tilted plane the other bowl gates use:
#
#   flooded area  = pi*R^2 * (1 - threshold/depth)     everything deeper than the cut-off
#   depth at p90  = 0.9 * depth                        the fill depth is linear in area fraction
#
# The second one is worth having because §10.2 asks for a high PERCENTILE rather than the maximum, so
# that one deep sinkhole cannot make a whole lake that deep — and a max would read 28 m here, not 25.2.
# CONTROLS: the same plain with no bowl, which must yield nothing; and min_lake_area raised above the
# bowl, which must filter it out.
func _gate_y_lakes() -> void:
	print("\n[Y] a bowl becomes one lake of the computable area and depth:")
	var thr := 0.5
	var want_area := PI * BOWL_R * BOWL_R * (1.0 - thr / BOWL_DEPTH)
	var want_depth := 0.9 * BOWL_DEPTH
	var z := _flat_bowl(BOWL_DEPTH, BOWL_R)
	var w := _extract(z, {"lake_depth_threshold": thr, "min_lake_area": 100.0,
			"curve_tolerance": 2.0, "river_area_threshold": 1.0e12})
	if w.is_empty():
		return
	var lakes: Array = w["lakes"]
	print("    %d lake(s) from %d flooded cells" % [lakes.size(), int(w["lake_cells"])])
	if lakes.size() != 1:
		_fail += 1
		print("    !! expected exactly one lake from one bowl")
		return
	var lake: Dictionary = lakes[0]
	var contour: PackedVector3Array = lake["contour"]
	print("    area %.0f m2 vs analytic %.0f (%+.1f%%, tol 8%%)" % [
			float(lake["area"]), want_area, 100.0 * (float(lake["area"]) - want_area) / want_area])
	print("    depth %.2f m vs analytic p90 %.2f (tol 2 m); the bowl's MAX is %.2f" % [
			float(lake["depth"]), want_depth, BOWL_DEPTH])
	print("    shoreline: %d points after simplification, level %.2f m" % [contour.size(), float(lake["level"])])
	if absf(float(lake["area"]) - want_area) / want_area > 0.08:
		_fail += 1
		print("    !! the flooded area does not match the bowl")
	if absf(float(lake["depth"]) - want_depth) > 2.0:
		_fail += 1
		print("    !! the lake depth is not the 90th percentile of the fill")
	if contour.size() < 8:
		_fail += 1
		print("    !! the shoreline is too coarse to be a pond loop")
	# The shoreline must enclose the bowl, not sit somewhere else on the plain.
	var cx := 0.0
	var cz := 0.0
	for p in contour:
		cx += p.x
		cz += p.z
	cx /= float(contour.size())
	cz /= float(contour.size())
	var want_c := float(SG / 2) * SCELL
	print("    shoreline centroid (%.1f, %.1f); the bowl is at (%.1f, %.1f), tol 8 m" % [cx, cz, want_c, want_c])
	if absf(cx - want_c) > 8.0 or absf(cz - want_c) > 8.0:
		_fail += 1
		print("    !! the shoreline is not around the bowl")

	# CONTROL — no bowl.
	var flat := _flat_bowl(0.0, BOWL_R)
	var w2 := _extract(flat, {"lake_depth_threshold": thr, "min_lake_area": 100.0,
			"river_area_threshold": 1.0e12})
	if not w2.is_empty():
		print("    CONTROL no bowl: %d lake(s), %d flooded cells (want 0, 0)" % [
				w2["lakes"].size(), int(w2["lake_cells"])])
		if w2["lakes"].size() != 0 or int(w2["lake_cells"]) != 0:
			_fail += 1
			print("    !! a plain with no basin still produced standing water")

	# CONTROL — the area filter.
	var w3 := _extract(z, {"lake_depth_threshold": thr, "min_lake_area": want_area * 2.0,
			"river_area_threshold": 1.0e12})
	if not w3.is_empty():
		print("    CONTROL min_lake_area above the bowl: %d lake(s) (want 0)" % w3["lakes"].size())
		if w3["lakes"].size() != 0:
			_fail += 1
			print("    !! the minimum-area filter does not reject a lake below it")


# --- Z: the eroded surface is reconstructed exactly -------------------------------------------------
# Extraction never re-solves and never stores the elevation. It rebuilds the surface the sim finished
# with as (the ground below Sim's layer) + (erosion + deposition), which is exact because those two
# channels ARE the net delta against that same ground (§8.2).
#
# Measured by routing the reconstruction and comparing its drainage area, cell for cell, against the
# `flow` channel the sim itself stored. Any error in the surface reorganises the network, and drainage
# area is the most sensitive thing to that reorganisation there is — a one-cell change of receiver moves
# a whole catchment.
# CONTROL: reconstruct WITHOUT adding the delta, i.e. route the un-eroded ground. That is the mistake
# this criterion exists to catch, and it must disagree loudly.
func _gate_z_reconstruction() -> void:
	print("\n[Z] the eroded surface is reconstructed exactly from the masks:")
	var sim = _make_sim("ReconSim")
	if sim == null:
		return
	if not bool(sim.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the simulation did not run")
		return
	var r: Pasture3DSimResult = sim.sim_result
	var surf: Dictionary = sim._eroded_surface()
	if not bool(surf["ok"]):
		_fail += 1
		print("    !! the surface could not be reconstructed: %s" % surf["reason"])
		return
	var rebuilt := _route_flow(surf["z"], int(surf["gw"]), int(surf["gh"]), float(surf["cell"]))
	if rebuilt.is_empty():
		return
	# Compared in LOG space, which is the space the channel is stored in. An absolute comparison of areas
	# fails on correct code: the stored value is a float32 logarithm, so exp()ing it back gives about 1e-7
	# of relative error, which on a 100 000 m2 trunk is 0.02 m2 and looks alarming while meaning nothing.
	# Routing is topological — a receiver either changed or it did not — so the real signal is enormous
	# when it exists and is at float precision when it does not.
	var worst := _worst_log_diff(rebuilt, r.flow)
	print("    worst |log(rebuilt area) - stored flow| = %.9f (tol 1e-4)" % worst)
	if worst > 1.0e-4:
		_fail += 1
		print("    !! the reconstructed surface routes differently from the one the sim solved")

	# CONTROL — the un-eroded ground, which is what a reconstruction that forgot the delta would route.
	var below: PackedFloat32Array = surf["z"].duplicate()
	for i in range(below.size()):
		below[i] = below[i] - r.erosion[i] - r.deposition[i]
	var control := _route_flow(below, int(surf["gw"]), int(surf["gh"]), float(surf["cell"]))
	if control.is_empty():
		return
	var c_worst := _worst_log_diff(control, r.flow)
	var c_diff := 0
	for i in range(control.size()):
		if absf(log(maxf(control[i], 1.0)) - r.flow[i]) > 1.0e-4:
			c_diff += 1
	print("    CONTROL routing the un-eroded ground: worst %.6f, %d of %d cells past the tolerance" % [
			c_worst, c_diff, control.size()])
	if c_worst <= 1.0e-4:
		_fail += 1
		print("    !! erosion barely changed the drainage, so an exact match proves nothing here")
	sim.clear_simulation()
	sim.queue_free()


# --- M: Clear removes exactly the generated set ----------------------------------------------------
# The workflow §10 is built around — iterate, generate, clear, re-sim — is only safe if Clear can tell
# a generated brush from an authored one. It identifies them by a stored marker, never by name, because
# a rename would orphan a generated brush and, far worse, an authored brush that happens to be called
# "River" would be destroyed.
#
# So the fixture is adversarial: the authored Pond and Trough are named exactly what the generator names
# its own, and they are parented INSIDE the Generated folder, which is where a user would drag them.
# CONTROL: the name-based predicate, run over the same tree. It must match the authored brushes — which
# is what makes the marker-based result meaningful rather than lucky.
func _gate_m_clear() -> void:
	print("\n[M] Clear removes exactly the generated set, and authored brushes survive:")
	var sim = _make_sim("ClearSim")
	if sim == null:
		return
	if not bool(sim.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the simulation did not run")
		return
	# Thresholds tuned to produce a handful of features rather than a hundred: every generated brush
	# bakes on attach, and this gate is about bookkeeping, not throughput.
	sim.river_area_threshold = 6000.0
	sim.min_river_length = 40.0
	sim.lake_depth_threshold = 0.5
	sim.min_lake_area = 500.0
	var rep: Dictionary = sim.add_brushes_now(false)
	if not bool(rep.get("ok", false)):
		_fail += 1
		print("    !! Add Brushes produced nothing: %s" % rep.get("reason", "?"))
		return
	var generated: Array = sim.collect_generated()
	print("    generated %d river segment(s) + %d lake(s) = %d brush(es)" % [
			int(rep["rivers"]), int(rep["lakes"]), generated.size()])
	if generated.size() < 2:
		_fail += 1
		print("    !! too few generated brushes to tell a selective clear from a total one")
		return
	# Both halves of §10, or half of it is untested: a Trough-only run says nothing about Ponds.
	if int(rep["rivers"]) < 1 or int(rep["lakes"]) < 1:
		_fail += 1
		print("    !! this site produced only one kind of feature; the other half of §10 is ungated here")
	_m_placement(sim, generated)
	_m_inside_write_area(sim, generated)
	_m_internal_children(sim)
	# §10.3: water comes from the existing pool path, so a generated river must arrive already wet.
	# Asked via pool_for_spline rather than by looking for a child, because add_pool_now parents the
	# pool beside the brush, not under it — which is exactly how an earlier version of this check came
	# back with "0 built water" while the teardown log was full of live water nodes.
	var made_water := _with_water(generated)
	print("    of those, %d arrived with water on their spline" % made_water)
	if made_water != generated.size():
		_fail += 1
		print("    !! a generated river has no water; the pool path did not run for it")

	# The adversarial pair: named exactly like the generated ones, parented in the same folder, and
	# carrying no marker.
	# Parented under the Sim rather than inside the Generated folder, and that is not a softening of the
	# fixture — it is the only way to make it bite. Godot refuses duplicate names among siblings, so an
	# authored "River" dropped next to a generated "River" is silently renamed and stops conflicting at
	# all. Under the Sim it keeps the exact name, which is what the name-based control needs, and it is
	# still inside the subtree collect_generated() walks.
	var authored_pond := Pasture3DPond.new()
	authored_pond.name = "Lake"
	authored_pond.auto_add_loop = false
	authored_pond.auto_add_water = false
	sim.add_child(authored_pond)
	authored_pond.terrain = _terrain
	var authored_trough := Pasture3DTrough.new()
	authored_trough.name = "River"
	sim.add_child(authored_trough)
	authored_trough.terrain = _terrain
	print("    added an authored Pond and Trough named exactly 'Lake' and 'River' under the Sim")
	# CONTROL for the water criterion: the authored Trough was never handed to the pool path, so it must
	# be dry. Without this, "every generated river has water" would also pass if every Trough anywhere
	# got water for some unrelated reason.
	var authored_wet := _with_water([authored_trough])
	print("    CONTROL the authored Trough's water: %d of 1 (want 0)" % authored_wet)
	if authored_wet != 0:
		_fail += 1
		print("    !! an untouched Trough already has water; the water check means nothing")

	# CONTROL — what a name-based collector would take. Run BEFORE the real clear, so it is describing
	# the same tree.
	var by_name := 0
	for n in _descendants(sim):
		if n is Pasture3DTerrainBrush and (n.name.begins_with("River") or n.name.begins_with("Lake")):
			by_name += 1
	var by_marker: int = sim.collect_generated().size()
	print("    CONTROL a name-based collector matches %d brush(es); the marker matches %d" % [
			by_name, by_marker])
	if by_name <= by_marker:
		_fail += 1
		print("    !! naming did not create a conflict, so M is not testing identification at all")

	var removed: int = sim.clear_brushes_now(false)
	var left: Array = sim.collect_generated()
	var pond_alive := is_instance_valid(authored_pond) and authored_pond.is_inside_tree()
	var trough_alive := is_instance_valid(authored_trough) and authored_trough.is_inside_tree()
	print("    cleared %d; %d generated brush(es) remain; authored Pond alive %s, Trough alive %s" % [
			removed, left.size(), pond_alive, trough_alive])
	if removed != by_marker:
		_fail += 1
		print("    !! Clear did not remove exactly the generated set")
	if not left.is_empty():
		_fail += 1
		print("    !! generated brushes survived the clear")
	if not pond_alive or not trough_alive:
		_fail += 1
		print("    !! an authored brush was destroyed; identification is going by name somewhere")
	sim.clear_simulation()


# M, placement: a generated brush must sit ON the feature it was extracted from.
#
# The extractor answers in WORLD coordinates and a Curve3D's points are LOCAL to their Path3D, so a Sim
# anywhere but the origin displaces every brush it generates by its own transform. This gate's site is
# (512, 0, 200) and the first version of it passed with all five brushes 550 m away: counts, markers,
# water and even the layer assignment are all invariant to position, so nothing here was looking.
#
# Two criteria, because they fail differently: the NODE must be at the feature's centre (all three axes,
# unaffected by the descend pass), and the node's spline must retrace the extracted polyline in XZ. Y is
# left out of the second one on purpose — _attach_generated runs make_descend on a Trough, which is
# entitled to move a point's height and not its position.
#
# CONTROL for both: the same measurement against the RAW local points, which is exactly what an unplaced
# brush produces. It must be hundreds of metres out, or the site is at the origin and neither criterion
# is testing anything.
func _m_placement(p_sim, p_generated: Array) -> void:
	var w: Dictionary = p_sim.extract_water()
	var feats: Array = []
	for seg: Dictionary in (w.get("rivers", []) as Array):
		feats.append({"pts": seg["points"], "pond": false})
	for lake: Dictionary in (w.get("lakes", []) as Array):
		feats.append({"pts": lake["contour"], "pond": true})
	if feats.is_empty():
		_fail += 1
		print("    !! re-extraction produced nothing, so placement is unmeasured")
		return

	var worst_origin := 0.0
	var control_origin := 0.0
	for f in feats:
		var c: Vector3 = _centroid_of(f["pts"])
		var best := INF
		for b in p_generated:
			if (b is Pasture3DPond) != bool(f["pond"]):
				continue
			best = minf(best, b.global_position.distance_to(c))
		if best == INF:
			_fail += 1
			print("    !! no generated brush of the right kind for a feature at %s" % c)
			return
		worst_origin = maxf(worst_origin, best)
		# What the unplaced code produced: the brush inherits the Generated folder's transform, i.e. it
		# sits at the Sim.
		control_origin = maxf(control_origin, p_sim.global_position.distance_to(c))

	var worst_pt := 0.0
	var control_pt := 0.0
	var compared := 0
	for b in p_generated:
		for s in b._get_splines():
			var c3: Curve3D = s.curve
			if c3 == null:
				continue
			for i in range(c3.point_count):
				var lp: Vector3 = c3.get_point_position(i)
				compared += 1
				worst_pt = maxf(worst_pt, _xz_to_nearest(s.to_global(lp), feats, b is Pasture3DPond))
				control_pt = maxf(control_pt, _xz_to_nearest(lp, feats, b is Pasture3DPond))
	if compared == 0:
		_fail += 1
		print("    !! no spline points were compared; placement is unmeasured")
		return

	print("    placement: node origin off by at most %.4f m; %d spline point(s) retrace the channel to %.4f m in XZ" % [
			worst_origin, compared, worst_pt])
	print("    CONTROL the same points read as if unplaced: origin %.1f m, spline %.1f m out" % [
			control_origin, control_pt])
	if worst_origin > 0.01:
		_fail += 1
		print("    !! a generated brush is not at its feature's centre")
	if worst_pt > 0.05:
		_fail += 1
		print("    !! a generated spline does not lie on the channel it came from")
	if control_origin < 100.0 or control_pt < 100.0:
		_fail += 1
		print("    !! the unplaced control is not displaced, so this site cannot detect a placement bug")


# M, write area: a generated brush must lie inside the loop, not out in the catchment margin.
#
# §5 simulates wide and writes narrow, and §8.2 keeps the masks over the whole SIMULATED extent — so the
# extractor sees drainage the terrain does not have, out in the margin where nothing was written. Left
# unclipped it generated rivers and a lake outside the area the user drew, over ground the sim never
# touched. Every criterion in M was blind to this too: a brush in the margin is still generated, still
# marked, still wet, and still placed exactly on the (unwritten) channel it came from.
#
# CONTROL: the raw extraction with the clip disabled. It must put points outside the loop, or this site
# has no margin drainage and the criterion is measuring an empty claim.
func _m_inside_write_area(p_sim, p_generated: Array) -> void:
	var polys: Array = p_sim._write_polygons()
	if polys.is_empty():
		_fail += 1
		print("    !! the Sim has no write polygon, so containment is unmeasured")
		return
	var outside := 0
	var checked := 0
	for b in p_generated:
		for s in b._get_splines():
			var c3: Curve3D = s.curve
			if c3 == null:
				continue
			for i in range(c3.point_count):
				checked += 1
				if not _inside_polys(polys, s.to_global(c3.get_point_position(i))):
					outside += 1

	# CONTROL — what the extractor offers before the clip.
	var raw: Dictionary = p_sim.extract_water()
	var raw_outside := 0
	var raw_total := 0
	for key in ["rivers", "lakes"]:
		for f: Dictionary in (raw.get(key, []) as Array):
			var pts: PackedVector3Array = f["points"] if key == "rivers" else f["contour"]
			for p in pts:
				raw_total += 1
				if not _inside_polys(polys, p):
					raw_outside += 1
	var pre_r: int = int(raw.get("rivers_before_clip", 0))
	var pre_l: int = int(raw.get("lakes_before_clip", 0))
	print("    write area: %d of %d generated spline point(s) outside the loop; the clip kept %d of %d river(s) and %d of %d lake(s)" % [
			outside, checked, (raw.get("rivers", []) as Array).size(), pre_r,
			(raw.get("lakes", []) as Array).size(), pre_l])
	print("    CONTROL before the clip: %d of %d extracted feature(s) reached outside; %d point(s) survive the clip outside" % [
			pre_r + pre_l - (raw.get("rivers", []) as Array).size() - (raw.get("lakes", []) as Array).size(),
			pre_r + pre_l, raw_outside])
	if checked == 0:
		_fail += 1
		print("    !! no spline points were checked; containment is unmeasured")
	if outside > 0:
		_fail += 1
		print("    !! a generated brush reaches outside the area the Sim writes")
	if raw_outside > 0:
		_fail += 1
		print("    !! the clipped extraction still contains points outside the loop")
	if pre_r + pre_l <= (raw.get("rivers", []) as Array).size() + (raw.get("lakes", []) as Array).size():
		_fail += 1
		print("    !! the clip removed nothing here, so this site cannot detect margin drainage")


# M, internal children: everything the Sim parents to ITSELF must be exempt from the structural-edit
# refresh.
#
# Pasture3DTerrainBrush treats any new child as a structural edit and schedules a full refresh, and a
# refresh of a Sim CLEARS its footprint (§12) — so the Generated folder appearing would delete the very
# erosion its brushes were extracted from. What this gate can check is the marker, with the Sim's own
# Area1 spline as the control: a spline must NOT be exempt, or the exemption is blanket and the base
# class has stopped noticing real edits.
#
# The consequence itself is editor-only — _can_auto_refresh() is false outside the editor, so headless
# neither the bug nor the fix can be observed, and a criterion phrased over _full_dirty would read the
# same for a marked and an unmarked child. This is the mechanism, not the symptom, and it says so.
func _m_internal_children(p_sim) -> void:
	var meta: StringName = Pasture3DTerrainBrush.INTERNAL_CHILD_META
	# Press Preview Water Features so the overlay is one of the children under test. It is also the only
	# assertion anywhere that the button draws something: its first version created nothing at all and
	# reported only to the Output dock, which is indistinguishable from a button that does not work.
	var pv: Dictionary = p_sim.preview_water_features()
	var overlay: MeshInstance3D = p_sim.get_node_or_null("WaterPreview")
	var want: int = (pv.get("rivers", []) as Array).size() + (pv.get("lakes", []) as Array).size()
	var drawn: int = overlay.mesh.get_surface_count() if overlay != null and overlay.mesh != null else 0
	print("    Preview Water Features drew %d line strip(s) for %d extracted feature(s)" % [drawn, want])
	if want == 0:
		_fail += 1
		print("    !! nothing was extracted, so the overlay is unmeasured")
	elif drawn != want:
		_fail += 1
		print("    !! the overlay does not describe the features the preview reported")

	var unmarked: Array = []
	var splines := 0
	for c in p_sim.get_children():
		if c == p_sim._name_label:
			continue # exempted by identity in the base class, not by the marker
		if c is Path3D:
			splines += 1
			if c.has_meta(meta):
				_fail += 1
				print("    !! spline '%s' is exempt from the refresh; the exemption is blanket" % c.name)
			continue
		if not c.has_meta(meta):
			unmarked.append(String(c.name))
	print("    direct children of the Sim: %d spline(s) unmarked (correct), %d other unmarked" % [
			splines, unmarked.size()])
	if splines == 0:
		_fail += 1
		print("    !! no spline to act as the control, so the exemption test is vacuous")
	if not unmarked.is_empty():
		_fail += 1
		print("    !! these will re-bake the layer when they appear: %s" % ", ".join(unmarked))


## Containment answered with Godot's own predicate rather than the Sim's helper: a gate that asks the
## code under test whether it is right cannot fail when that helper is the thing that is wrong.
func _inside_polys(p_polys: Array, p_p: Vector3) -> bool:
	var v := Vector2(p_p.x, p_p.z)
	for poly: PackedVector2Array in p_polys:
		if Geometry2D.is_point_in_polygon(v, poly):
			return true
	return false


func _centroid_of(p_pts: PackedVector3Array) -> Vector3:
	if p_pts.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for p in p_pts:
		sum += p
	return sum / float(p_pts.size())


## Closest XZ distance from `p_p` to any extracted point of the matching feature kind.
func _xz_to_nearest(p_p: Vector3, p_feats: Array, p_pond: bool) -> float:
	var best := INF
	var here := Vector2(p_p.x, p_p.z)
	for f in p_feats:
		if bool(f["pond"]) != p_pond:
			continue
		for q: Vector3 in (f["pts"] as PackedVector3Array):
			best = minf(best, here.distance_to(Vector2(q.x, q.z)))
	return 0.0 if best == INF else best


# --- synthetic fields -------------------------------------------------------------------------------

## Two tributaries meeting at Y_JOIN and one trunk to the outlet, cut into a plane falling in +Z. The
## grooves are a smooth V so D8 has one unambiguous line to follow down each of them.
func _y_catchment() -> PackedFloat32Array:
	var z := PackedFloat32Array()
	z.resize(SG * SG)
	var segs := [[Y_LEFT, Y_JOIN], [Y_RIGHT, Y_JOIN], [Y_JOIN, Y_OUT]]
	for iz in range(SG):
		for ix in range(SG):
			var p := Vector2(ix, iz)
			var d := INF
			for s in segs:
				d = minf(d, _dist_to_segment(p, Vector2(s[0].x, s[0].y), Vector2(s[1].x, s[1].y)))
			var groove := GROOVE_DEPTH * exp(-(d * SCELL) * (d * SCELL) / (GROOVE_WIDTH * GROOVE_WIDTH))
			z[iz * SG + ix] = BASE_Z - 0.05 * iz * SCELL - groove
	return z


func _dist_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 1.0e-9:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


## A paraboloid bowl in a perfectly FLAT plain. Flat is the point: the fill level is then the plain
## itself, so the flooded area and the depth distribution are both closed-form.
func _flat_bowl(p_depth: float, p_radius: float) -> PackedFloat32Array:
	var z := PackedFloat32Array()
	z.resize(SG * SG)
	var c := float(SG / 2) * SCELL
	for iz in range(SG):
		for ix in range(SG):
			var v := BASE_Z
			if p_depth > 0.0:
				var r := Vector2(ix * SCELL - c, iz * SCELL - c).length()
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


# --- helpers ------------------------------------------------------------------------------------------

## Extract over the SG x SG synthetic grid, filling in the grid so a gate writes only the thresholds it
## is testing. Returns {} (and fails the run) when the extractor rejects it.
func _extract(p_z: PackedFloat32Array, p_params: Dictionary) -> Dictionary:
	var params := p_params.duplicate()
	params["gw"] = SG
	params["gh"] = SG
	params["cell_size"] = SCELL
	params["min_x"] = 0.0
	params["min_z"] = 0.0
	var res: Dictionary = _data.sim_extract_water(p_z, params)
	if not bool(res.get("ok", false)):
		_fail += 1
		print("    !! the extractor rejected the %dx%d grid" % [SG, SG])
		return {}
	return res


## Drainage area over an arbitrary grid, via the solver's zero-iteration routing mode.
func _route_flow(p_z: PackedFloat32Array, p_gw: int, p_gh: int, p_cell: float) -> PackedFloat32Array:
	var res: Dictionary = _data.erode_heightfield(p_z, {"gw": p_gw, "gh": p_gh, "cell_size": p_cell,
			"iterations": 0, "want_diagnostics": true}, PackedFloat32Array())
	if not bool(res.get("ok", false)):
		_fail += 1
		print("    !! the router rejected the reconstructed %dx%d grid" % [p_gw, p_gh])
		return PackedFloat32Array()
	return res["flow"]


## How many of these brushes have a pool on at least one of their splines.
func _with_water(p_brushes: Array) -> int:
	var n := 0
	for b in p_brushes:
		for s in b._get_splines():
			if b.pool_for_spline(s) != null:
				n += 1
				break
	return n


## Worst difference between a freshly routed drainage area and a stored LOG-scaled flow channel, in log
## space — the units the channel is actually kept in.
func _worst_log_diff(p_area: PackedFloat32Array, p_stored: PackedFloat32Array) -> float:
	var worst := 0.0
	for i in range(mini(p_area.size(), p_stored.size())):
		worst = maxf(worst, absf(log(maxf(p_area[i], 1.0)) - p_stored[i]))
	return worst


func _descendants(p_node: Node) -> Array:
	var out: Array = []
	var stack: Array = p_node.get_children()
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		out.append(n)
	return out


func _make_sim(p_name: String):
	if not is_finite(_height(SITE_NODE)):
		_fail += 1
		print("    !! no terrain at %s; the fixture is outside demo/data" % SITE_NODE)
		return null
	var sim := Pasture3DSim.new()
	sim.name = p_name
	_root.add_child(sim)
	sim.terrain = _terrain
	sim.global_position = SITE_NODE
	sim.catchment_margin = SIM_MARGIN
	sim.iterations = 30
	sim.erosion_rate = 0.1
	sim.hillslope_diffusion = 0.15
	sim.falloff_width = 20.0
	sim.snap_to_surface = false
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	c.add_point(Vector3(-SIM_HALF, 0.0, -SIM_HALF))
	c.add_point(Vector3(SIM_HALF, 0.0, -SIM_HALF))
	c.add_point(Vector3(SIM_HALF, 0.0, SIM_HALF))
	c.add_point(Vector3(-SIM_HALF, 0.0, SIM_HALF))
	c.closed = true
	path.curve = c
	sim.add_child(path)
	return sim


func _height(p_at: Vector3) -> float:
	return _data.get_height(Vector3(p_at.x, 0.0, p_at.z))
