# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# §11 / §20.6 — THE PROFILING PASS. Run with the user's explicit go-ahead (2026-08-19); §11 and §14 both
# say benchmarks need it.
#
# Two questions have blocked phase 7 since the spec was drafted, and neither has ever been measured:
#
#   Q1 (§20.6) — DOES THE COMMIT DOMINATE A FULL-RESOLUTION BUILD? Phase 7 moves the SOLVE onto a worker
#                thread. `clear_layer_in_area`, `composite_area` and `update_maps` stay on the main
#                thread whatever happens. If they are most of the wall clock, phase 7 buys much less than
#                it looks like.
#   Q2 (§11)   — DOES DEPRESSION FILLING DOMINATE THE SOLVE? It is the one O(n log n) step in an
#                otherwise O(n) solver and it runs every iteration. If it dominates, the fix is
#                `fill_every` or an O(n) priority-flood, not a thread.
#
# HOW THIS AVOIDS MEASURING NOTHING:
#   * every number is the MINIMUM of several runs, with the spread printed beside it. A difference
#     smaller than the spread is reported as BELOW THE NOISE FLOOR rather than as an answer;
#   * Q1's commit is the SHIPPED `_commit`, called on a real node against a real layer — not a
#     reconstruction of it — and its total is checked against the real `simulate_now` wall clock, so a
#     breakdown that fails to account for the build is caught rather than believed;
#   * Q2 estimates the cost of one network rebuild TWICE by independent routes — from the fill_every
#     sweep and from a zero-iteration solve — and prints both. Two routes disagreeing means the model of
#     where the time goes is wrong.
#
# NOTHING IS SAVED. Bakes write into the terrain's in-memory layer; demo/data on disk is only touched by
# an explicit save, which nothing here calls.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/SimProfile.tscn
extends Node

const DEMO_DATA := "res://demo/data"

## The spec's own two cases (§11's incidental table), so these numbers can be read against it.
const SMALL := {"name": "small", "at": Vector3(300.0, 0.0, 300.0), "half": 60.0, "margin": 40.0}
const LARGE := {"name": "large", "at": Vector3(500.0, 0.0, 500.0), "half": 250.0, "margin": 128.0}

const ITERATIONS := 30
const REPS_SMALL := 5
const REPS_LARGE := 3

var _root: Node3D
var _terrain
var _data


func _ready() -> void:
	print("\n=== §11 / §20.6 profiling pass — solve vs commit, and the cost of the depression fill ===\n")
	print("Wall clock on whatever else this machine was running. Every figure is a MINIMUM of N runs;")
	print("the spread beside it is max-min across those runs and is the noise floor for that row.\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_data = _terrain.data
	if _data == null or not _data.has_method("erode_heightfield"):
		print("!! this build has no solver; nothing to profile")
		get_tree().quit(1)
		return

	var small := _q1_solve_vs_commit(SMALL, REPS_SMALL)
	var large := _q1_solve_vs_commit(LARGE, REPS_LARGE)
	_q1_verdict(small, large)
	_q2_fill_share(LARGE, REPS_LARGE)
	_q3_flood_queue(LARGE, REPS_LARGE)

	print("\n=== end of profiling pass ===\n")
	get_tree().quit(0)


# --- Q1: where does a build's wall clock actually go? ----------------------------------------------

func _q1_solve_vs_commit(p_case: Dictionary, p_reps: int) -> Dictionary:
	print("[Q1/%s] %.0f m loop + %.0f m margin, %d iterations at build resolution" % [
			p_case["name"], p_case["half"] * 2.0, p_case["margin"], ITERATIONS])
	var mgr := _make_manager(p_case)
	if mgr == null:
		print("    !! no terrain here; skipping this case\n")
		return {}

	var plan: Dictionary = mgr.plan_clusters(1)
	var groups: Array = plan.get("clusters", [])
	if not bool(plan.get("ok", false)) or groups.size() != 1:
		print("    !! expected one in-budget cluster, got %d (%s); skipping\n" % [
				groups.size(), plan.get("reason", "")])
		return {}
	var cl: Dictionary = groups[0]
	var tw: int = cl["tw"]
	var th: int = cl["th"]
	var sw: int = cl["sw"]
	var sh: int = cl["sh"]
	print("    terrain grid %dx%d (%d cells), sim grid %dx%d (%d cells) at %.2f m" % [
			tw, th, tw * th, sw, sh, sw * sh, float(cl["cell"])])

	# THE REAL BUILD, start to finish, through the shipped entry point. This is the number the rows below
	# have to account for.
	var totals: Array[float] = []
	for i in range(p_reps):
		var t0 := Time.get_ticks_usec()
		var rep: Dictionary = mgr.simulate_now(1, false)
		totals.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		if not bool(rep.get("ok", false)):
			print("    !! the build failed; nothing to profile\n")
			return {}
	var t_total := _min(totals)

	# THE COMMIT, alone: the shipped `_commit`, on the same node, against the same layer, with a block of
	# the size the build just wrote. Not a reconstruction of the commit — the commit.
	var layer_id: int = mgr._ensure_layer_for(mgr._layer_owner, true)
	var write := PackedFloat32Array()
	write.resize(tw * th)
	write.fill(0.01)
	var box := AABB()
	for a: AABB in mgr._own_footprints():
		box = a if box.size == Vector3.ZERO else box.merge(a)
	var block := {"spline_id": 0, "box": box, "min_x": cl["min_x"], "min_z": cl["min_z"],
			"gw": tw, "gh": th, "write": write}
	var commits: Array[float] = []
	for i in range(p_reps):
		var t0 := Time.get_ticks_usec()
		mgr._commit([block], layer_id, false, "Profile")
		commits.append(float(Time.get_ticks_usec() - t0) / 1000.0)
	var t_commit := _min(commits)
	var t_commit_worst := _max(commits)

	# The commit's own four stages, so "the commit dominates" can name WHICH part if it does.
	var clip: AABB = mgr._snap_aabb_to_tiles(box, mgr._layer_tile_world(layer_id))
	var stages := {}
	for k in ["clear_layer_in_area", "apply_sim_block", "composite_area", "update_maps"]:
		var runs: Array[float] = []
		for i in range(p_reps):
			var t0 := Time.get_ticks_usec()
			match k:
				"clear_layer_in_area":
					_data.clear_layer_in_area(layer_id, clip)
				"apply_sim_block":
					_data.apply_sim_block(layer_id, cl["min_x"], cl["min_z"],
							_terrain.vertex_spacing, tw, th, write, mgr.BLEND_ADD)
				"composite_area":
					_data.composite_area(clip, false)
				"update_maps":
					_data.update_maps(mgr._map_type(), false, false)
			runs.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		# MIN AND MAX both, because these are not repeatable in the way a solve is: `clear_layer_in_area`
		# on an already-clear region costs almost nothing, so the minimum of N runs is the cost of the
		# calls after the first, not the cost of the one a real build pays. The verdict below is taken
		# against the MAXIMUM for exactly that reason.
		stages[k] = [_min(runs), _max(runs)]

	var t_rest := t_total - t_commit
	print("    FULL BUILD (simulate_now):    %9.1f ms   (spread %.1f over %d runs)" % [
			t_total, _spread(totals), p_reps])
	print("    the commit alone (_commit):   %9.1f ms   (spread %.1f) = %.1f%% of the build" % [
			t_commit, _spread(commits), t_commit / t_total * 100.0])
	print("    everything else (solve etc):  %9.1f ms                = %.1f%% of the build" % [
			t_rest, t_rest / t_total * 100.0])
	for k in ["clear_layer_in_area", "apply_sim_block", "composite_area", "update_maps"]:
		print("        %-22s  min %8.3f  max %8.3f ms" % [k, stages[k][0], stages[k][1]])
	var named := 0.0
	for k in stages:
		named += float(stages[k][1])
	print("      those four sum to %.1f ms at their WORST, of a %.1f ms worst-case commit (%.0f%%). The rest" % [
			named, t_commit_worst, named / maxf(t_commit_worst, 0.001) * 100.0])
	print("      is the layer-mate repaint, the undo snapshot and gizmos — none of which a thread moves either.")
	# The verdict has to survive the least favourable reading, or "the commit is negligible" is an artefact
	# of taking minima. Worst commit against BEST build is the hardest case the commit can be given here.
	print("    WORST CASE the slowest commit against the fastest build: %.1f / %.1f ms = %.2f%%" % [
			t_commit_worst, t_total, t_commit_worst / t_total * 100.0])
	print("")
	return {"name": p_case["name"], "total": t_total, "commit": t_commit, "rest": t_rest,
			"cells": sw * sh, "spread": _spread(totals)}


func _q1_verdict(p_small: Dictionary, p_large: Dictionary) -> void:
	if p_small.is_empty() or p_large.is_empty():
		return
	print("[Q1] verdict — does the commit dominate a full-resolution build?")
	for c in [p_small, p_large]:
		print("    %-6s %7d sim cells: commit %5.1f%%, everything else %5.1f%%" % [
				c["name"], c["cells"], float(c["commit"]) / float(c["total"]) * 100.0,
				float(c["rest"]) / float(c["total"]) * 100.0])
	# The control that makes this more than one number: the two cases must SCALE DIFFERENTLY. The commit
	# is dominated by fixed per-tile work, the solve by cell count — so if the commit's share does not
	# fall as the grid grows, the split is not measuring what it claims to.
	var s_share: float = float(p_small["commit"]) / float(p_small["total"])
	var l_share: float = float(p_large["commit"]) / float(p_large["total"])
	print("    CONTROL the commit's share must FALL as the grid grows (%dx the cells here):" % (
			int(p_large["cells"]) / maxi(int(p_small["cells"]), 1)))
	print("      %.1f%% -> %.1f%%  %s" % [s_share * 100.0, l_share * 100.0,
			"as expected" if l_share < s_share
			else "NOT as expected — re-read the split before trusting it"])
	print("")


# --- Q2: does the depression fill dominate the solve? ----------------------------------------------
#
# `fill_every` freezes the WHOLE network (fill + route + accumulate) for k iterations, so the sweep below
# measures fill+route together — which is the right unit, because "re-fill every k iterations" is exactly
# what §11 proposes as the first fix. `fill_depressions = false` then separates the priority queue from
# the routing that would happen anyway.
func _q2_fill_share(p_case: Dictionary, p_reps: int) -> void:
	print("[Q2] %.0f m loop, %d iterations — where does the SOLVE's time go?" % [
			p_case["half"] * 2.0, ITERATIONS])
	var mgr := _make_manager(p_case)
	if mgr == null:
		print("    !! no terrain here; skipping\n")
		return
	var plan: Dictionary = mgr.plan_clusters(1)
	var groups: Array = plan.get("clusters", [])
	if not bool(plan.get("ok", false)) or groups.size() != 1:
		print("    !! expected one in-budget cluster; skipping\n")
		return
	var cl: Dictionary = groups[0]
	var sw: int = cl["sw"]
	var sh: int = cl["sh"]
	var layer_id: int = mgr._ensure_layer_for(mgr._layer_owner, true)
	var below: PackedFloat32Array = _data.composite_height_below(
			layer_id, cl["min_x"], cl["min_z"], _terrain.vertex_spacing, cl["tw"], cl["th"])
	var z0: PackedFloat32Array = _data.resample_grid(below, cl["tw"], cl["th"], sw, sh)
	print("    sim grid %dx%d (%d cells) at %.2f m" % [sw, sh, sw * sh, float(cl["cell"])])

	var base := {"gw": sw, "gh": sh, "cell_size": cl["cell"], "time_step": 1.0,
			"iterations": ITERATIONS, "erosion_rate": 0.15, "area_exponent": 0.45, "diffusion": 0.15}
	var labels := ["A shipped (fill on, every iteration)",
			"B network built once (fill_every=%d)" % ITERATIONS,
			"C fill OFF, routed every iteration",
			"D one network build only (0 iters)"]
	var configs := [{"fill_depressions": true, "fill_every": 1},
			{"fill_depressions": true, "fill_every": ITERATIONS},
			{"fill_depressions": false, "fill_every": 1},
			{"fill_depressions": true, "fill_every": 1, "iterations": 0}]
	var mins: Array[float] = []
	var spreads: Array[float] = []
	for i in range(labels.size()):
		var params: Dictionary = base.duplicate()
		params.merge(configs[i] as Dictionary, true)
		var runs: Array[float] = []
		for r in range(p_reps):
			var t0 := Time.get_ticks_usec()
			var res: Dictionary = _data.erode_heightfield(z0, params, PackedFloat32Array())
			runs.append(float(Time.get_ticks_usec() - t0) / 1000.0)
			if not bool(res.get("ok", false)):
				print("    !! %s did not solve" % labels[i])
				return
		mins.append(_min(runs))
		spreads.append(_spread(runs))
		print("    %-40s %9.1f ms   (spread %.1f)" % [labels[i], _min(runs), _spread(runs)])

	var a := mins[0]
	var b := mins[1]
	var c := mins[2]
	var d := mins[3]
	var noise := 0.0
	for s in spreads:
		noise = maxf(noise, s)

	# Two INDEPENDENT estimates of the same quantity — the cost of one fill+route+accumulate rebuild.
	# They must agree, or the model of where the time goes is wrong and none of the shares below mean
	# anything. D includes one rebuild plus fixed setup, so it is an UPPER bound on the sweep's figure.
	var per_rebuild := (a - b) / float(ITERATIONS - 1)
	print("    one network rebuild costs, by two independent routes:")
	print("      from the fill_every sweep  (A-B)/%d = %8.2f ms" % [ITERATIONS - 1, per_rebuild])
	print("      from the 0-iteration solve       D = %8.2f ms  (upper bound: includes fixed setup)" % d)
	print("      %s" % ("consistent — the shares below can be read" if per_rebuild > 0.0 and per_rebuild <= d * 1.5
			else "!! THESE DISAGREE — do not trust the shares below"))

	print("    shares of the shipped solve (A = %.1f ms):" % a)
	print("      fill + route + accumulate, all %d rebuilds: %8.1f ms = %5.1f%%" % [
			ITERATIONS, a - b + per_rebuild, (a - b + per_rebuild) / a * 100.0])
	print("      the priority-flood FILL specifically (A-C): %8.1f ms = %5.1f%%" % [
			a - c, (a - c) / a * 100.0])
	print("      incision + diffusion (the remainder):       %8.1f ms = %5.1f%%" % [
			b - per_rebuild, (b - per_rebuild) / a * 100.0])
	if absf(a - c) < noise:
		print("    !! A and C differ by less than the noise floor (%.1f ms): the FILL's own cost is BELOW" % noise)
		print("       what this measurement resolves — which is itself an answer to Q2.")
	if absf(a - b) < noise:
		print("    !! A and B differ by less than the noise floor (%.1f ms): fill_every would buy nothing." % noise)
	print("    NOTE the shipped path could not take B's full saving anyway: the manager solves in chunks of")
	print("    CHUNK_ITERATIONS = 5, and every erode_heightfield call rebuilds the network at its own")
	print("    iteration 0. So %d iterations already means at least %d rebuilds, never 1." % [
			ITERATIONS, int(ceil(float(ITERATIONS) / 5.0))])
	# The number that actually matters to a decision: what the ALREADY IMPLEMENTED escape hatch buys at
	# the best setting the chunking permits. Projected from the two measured points, not measured — say so.
	var floor_rebuilds := int(ceil(float(ITERATIONS) / 5.0))
	var projected := b + per_rebuild * float(floor_rebuilds - 1)
	print("    PROJECTED from A and B (not measured directly): fill_every = 5, chunk-aligned, would leave")
	print("    %d rebuilds and cost about %.0f ms against the shipped %.0f ms — a %.1fx wall-clock saving," % [
			floor_rebuilds, projected, a, a / maxf(projected, 0.001)])
	print("    for a surface that is NOT the same one (the network is stale for 4 iterations in 5).")
	print("")


# --- Q3: what the monotone bucket queue actually bought --------------------------------------------
#
# The optimisation Q2 pointed at. `legacy_flood` runs the binary heap the solver shipped with; the
# default runs the bucket queue that replaced it. Gate BI has already established the two produce
# bitwise identical output on five fixtures, so this is purely a question of time.
func _q3_flood_queue(p_case: Dictionary, p_reps: int) -> void:
	print("[Q3] %.0f m loop, %d iterations — the new flood queue against the heap it replaced" % [
			p_case["half"] * 2.0, ITERATIONS])
	var mgr := _make_manager(p_case)
	if mgr == null:
		print("    !! no terrain here; skipping\n")
		return
	var plan: Dictionary = mgr.plan_clusters(1)
	var groups: Array = plan.get("clusters", [])
	if not bool(plan.get("ok", false)) or groups.size() != 1:
		print("    !! expected one in-budget cluster; skipping\n")
		return
	var cl: Dictionary = groups[0]
	var sw: int = cl["sw"]
	var sh: int = cl["sh"]
	var layer_id: int = mgr._ensure_layer_for(mgr._layer_owner, true)
	var below: PackedFloat32Array = _data.composite_height_below(
			layer_id, cl["min_x"], cl["min_z"], _terrain.vertex_spacing, cl["tw"], cl["th"])
	var z0: PackedFloat32Array = _data.resample_grid(below, cl["tw"], cl["th"], sw, sh)
	var base := {"gw": sw, "gh": sh, "cell_size": cl["cell"], "time_step": 1.0,
			"iterations": ITERATIONS, "erosion_rate": 0.15, "area_exponent": 0.45, "diffusion": 0.15}

	var res := {}
	for legacy in [true, false]:
		var params: Dictionary = base.duplicate()
		params["legacy_flood"] = legacy
		var runs: Array[float] = []
		for r in range(p_reps):
			var t0 := Time.get_ticks_usec()
			var out: Dictionary = _data.erode_heightfield(z0, params, PackedFloat32Array())
			runs.append(float(Time.get_ticks_usec() - t0) / 1000.0)
			if not bool(out.get("ok", false)):
				print("    !! the solve failed")
				return
		res[legacy] = [_min(runs), _spread(runs)]
		print("    %-40s %9.1f ms   (spread %.1f)" % [
				"the binary heap (legacy_flood)" if legacy else "the monotone bucket queue (shipped)",
				_min(runs), _spread(runs)])

	var old_ms: float = res[true][0]
	var new_ms: float = res[false][0]
	var noise: float = maxf(res[true][1], res[false][1])
	print("    solve: %.1f -> %.1f ms, a %.2fx saving (%.0f ms off every build of this size)" % [
			old_ms, new_ms, old_ms / maxf(new_ms, 0.001), old_ms - new_ms])
	if absf(old_ms - new_ms) < noise:
		print("    !! the difference is inside the noise floor (%.1f ms): this bought nothing measurable." % noise)
	# The whole-build number, since the solve is not all a user waits for. Re-measured rather than
	# inferred: a saving in the solver that does not show up in `simulate_now` did not happen.
	var builds: Array[float] = []
	for r in range(p_reps):
		var t0 := Time.get_ticks_usec()
		var rep: Dictionary = mgr.simulate_now(1, false)
		builds.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		if not bool(rep.get("ok", false)):
			return
	print("    the same as a FULL BUILD through simulate_now: %.1f ms (spread %.1f) — compare the" % [
			_min(builds), _spread(builds)])
	print("    3436.8 ms this case measured before the change (§11's profiling table).")
	print("")


# --- helpers ---------------------------------------------------------------------------------------

func _make_manager(p_case: Dictionary) -> Pasture3DSimManager:
	var at: Vector3 = p_case["at"]
	var half: float = p_case["half"]
	for d in [Vector3(-half, 0, -half), Vector3(half, 0, -half), Vector3(half, 0, half),
			Vector3(-half, 0, half), Vector3.ZERO]:
		if not is_finite(_data.get_height(at + d)):
			return null
	var m := Pasture3DSimManager.new()
	m.name = "P_%s" % p_case["name"]
	_root.add_child(m)
	m.terrain = _terrain
	m.global_position = at
	m.snap_to_surface = false
	m.catchment_margin = p_case["margin"]
	m._layer_owner = "pasture3d_brush:Profile_%s" % p_case["name"]
	var s := Pasture3DSim.new()
	s.name = "Solve"
	m.add_child(s)
	s.terrain = _terrain
	s.snap_to_surface = false
	s.iterations = ITERATIONS
	s.erosion_rate = 0.15
	s.hillslope_diffusion = 0.15
	s.falloff_width = 12.0
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	for p in [Vector3(-half, 0, -half), Vector3(half, 0, -half), Vector3(half, 0, half),
			Vector3(-half, 0, half)]:
		c.add_point(p)
	c.closed = true
	path.curve = c
	s.add_child(path)
	return m


func _min(p_a: Array[float]) -> float:
	var m := INF
	for v in p_a:
		m = minf(m, v)
	return 0.0 if not is_finite(m) else m


func _max(p_a: Array[float]) -> float:
	var m := -INF
	for v in p_a:
		m = maxf(m, v)
	return 0.0 if not is_finite(m) else m


func _spread(p_a: Array[float]) -> float:
	var lo := INF
	var hi := -INF
	for v in p_a:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return 0.0 if not is_finite(lo) else hi - lo
