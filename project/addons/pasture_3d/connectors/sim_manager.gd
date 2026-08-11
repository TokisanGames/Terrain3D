# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DSimManager — child Pasture3DSim nodes as ORDERED PASSES over one shared grid.
# See PASTURE3D_SIM_NODE_SPEC.md §19.
#
# One read of composite_height_below, a chain z0 → pass₁ → … → z_N held in memory, each pass masked to its
# own loop, and ONE write of the total delta into ONE layer. Scene-dock order is stack order, top to
# bottom.
#
# WHY, and it is not layer sharing. Two Sims on one layer wiping each other (§19.1) is the symptom; the
# reason worth building this is §5's seam limitation, which says outright not to tile a large map from
# many small loops because neighbouring loops compute drainage independently and disagree at their shared
# edge. One grid means water routes continuously across what used to be a boundary. That is a documented
# limitation being deleted.
#
# PASSES IS THE PRIMARY READING. A pass whose loop spans everything is a global pass; two passes with
# disjoint loops are the side-by-side case; partial overlap is the blend the falloff already handles. The
# ordering is meaningful and pass 2 erodes pass 1's output — non-overlapping children are the degenerate
# case, not a second feature.
#
# THE COST RISK (§19.4), which is the part most likely to go wrong. A naive union of five loops spread
# across a scene solves a bounding box that is mostly ground nobody asked about. So: CLUSTER, never union
# blindly — connected components over margin-grown loop boxes, one grid per component — and when a cluster
# exceeds the cell budget, REFUSE IT BY NAME rather than coarsening. §6 measured that a coarser grid erodes
# DEEPER, so a manager that quietly dropped resolution would hand back a different landscape with no
# indication at all that it had.
#
# IDEMPOTENCY (§13) is preserved and is cleaner than a Sim's: one read below this node's own layer, a
# deterministic chain, one write into that layer. Nothing in the chain reads the finished composite.
@tool
@icon("res://addons/pasture_3d/icons/brush_sim.svg")
class_name Pasture3DSimManager
extends Pasture3DSimBase

## Iterations solved between yields back to the editor, matching Pasture3DSim. A chain yields between
## chunks of the CURRENT pass, so a ten-pass build is no less cancellable than a one-pass one.
const CHUNK_ITERATIONS: int = 5
## Smallest cluster grid worth solving. Below this the boundary IS the domain and nothing routes.
const MIN_SIM_CELLS: int = 8
## Ceiling on the merged Pasture3DSimResult grid across clusters (§8.2's rule, applied to clusters rather
## than to one node's loops). Distinct from `max_cluster_cells`, which caps what is SOLVED: this one caps
## an output that is resampled anyway, and coarsening it is lossy but not wrong.
const RESULT_MAX_CELLS: int = 4194304

@export_group("Area")
## Metres of upstream catchment simulated OUTSIDE the loops (§5). MANAGER-WIDE, not per pass, and that is
## not arbitrary: the margin is half of what defines the shared grid, and the grid is shared (§19.3).
##
## It is also the clustering distance. Two loops whose margin-grown boxes overlap become ONE grid with
## continuous drainage between them; two that do not stay two independent solves. Raising this is
## therefore how you ask for a seam to be deleted — and how you accidentally ask for one enormous grid.
@export_range(0.0, 1024.0, 1.0, "or_greater") var catchment_margin: float = 128.0:
	set(v):
		catchment_margin = maxf(v, 0.0)
		update_configuration_warnings()

@export_group("Resolution")
## Cell size divisor for the Preview button, relative to the terrain's vertex spacing (§6). Manager-wide,
## for the same reason the margin is. Preview is a good guide to WHERE the valleys go and a poor one to
## HOW DEEP — and under a chain that compounds, because every pass reads the previous pass's depth.
@export_range(1, 16) var preview_resolution: int = 4:
	set(v):
		preview_resolution = maxi(v, 1)
## Cell size divisor for the Simulate button. 1 = solve at the terrain's own resolution.
@export_range(1, 16) var build_resolution: int = 1:
	set(v):
		build_resolution = maxi(v, 1)

@export_group("Budget")
## Largest grid, in cells, this manager will solve for ONE cluster. A cluster over the budget is REFUSED
## and named — the build stops and nothing is written (§19.4).
##
## It does not coarsen, deliberately. §6 measured that a coarser grid erodes deeper, so silently dropping
## resolution to fit would return a different landscape with nothing on screen to say so. The fixes are
## real ones: lower Build Resolution yourself and know that you did, shrink the margin so the cluster
## splits, or move the loops apart.
@export_range(65536, 67108864) var max_cluster_cells: int = 4194304:
	set(v):
		max_cluster_cells = maxi(v, 4096)
		update_configuration_warnings()

@export_group("Masks")
## Where this manager writes its drainage masks (§8.2/§19.6): flow, erosion, deposition and wetness over
## the simulated area at sim resolution, built from the FINAL surface of the chain.
##
## ONE result for the whole manager, which retires a real phase-3 limitation: a Plow spanning what used to
## be two Sims can reference this instead of having to pick one of their results. Child Sims' own Sim
## Result properties are ignored while they are passes.
##
## SAVE IT TO A .res: an unsaved resource is stored inside the scene file, and these are megabytes.
@export var sim_result: Pasture3DSimResult:
	set(v):
		sim_result = v
		update_configuration_warnings()
## Give the masks a .res of their own next to your terrain data, so a Plow's or Mound's relief selector
## can point at a FILE. Until they have one they live inside this scene, where nothing else can reach them.
@export_tool_button("Save Masks") var _save_masks_btn = save_masks

@export_group("Water Features")
## §19.6 — ONE extraction over the whole simulated area, so a river crossing what used to be a boundary
## between two Sims comes out as one Trough and a lake spanning it as one Pond. These thresholds are
## manager-wide because the extraction is.
@export_range(100.0, 1000000.0, 100.0, "or_greater") var river_area_threshold: float = 5000.0
@export_range(0.0, 500.0, 1.0, "or_greater") var min_river_length: float = 40.0
@export_range(0.1, 32.0, 0.1, "or_greater") var curve_tolerance: float = 2.0
@export_range(0.0, 20.0, 0.05, "or_greater") var lake_depth_threshold: float = 0.5
@export_range(0.0, 100000.0, 10.0, "or_greater") var min_lake_area: float = 400.0
@export_range(1.0, 200.0, 0.5, "or_greater") var river_width_max: float = 14.0
@export_range(0.5, 100.0, 0.5, "or_greater") var river_width_min: float = 3.0
@export_range(0.0, 20.0, 0.05, "or_greater") var river_carve_depth: float = 0.25

@export_group("Bake")
## Solve the whole chain at Preview Resolution and write. Same layer as the build, so it is visible in
## the viewport and directly comparable — just coarser.
@export_tool_button("Preview") var _preview_btn = preview_simulation
## Solve the whole chain at Build Resolution and write. The final commit.
@export_tool_button("Simulate") var _simulate_btn = run_simulation
## Report the clusters the current loops and margin would solve, and what they would cost, without
## solving anything. The cheap way to find out that two areas you thought were independent have merged
## into one grid — or that one is over budget — before waiting for a build to say so.
@export_tool_button("Plan Clusters") var _plan_btn = print_plan
## Empty the layer under every pass's loops, restoring the ground beneath.
@export_tool_button("Clear Simulation") var _clear_sim_btn = clear_simulation
## Abandon a solve in progress. The layer is left exactly as it was — nothing is written.
@export_tool_button("Cancel") var _cancel_btn = cancel_simulation
## Count the rivers and lakes the current thresholds would produce, without creating anything.
@export_tool_button("Preview Water Features") var _preview_water_btn = preview_water_features
## Replace this manager's generated Ponds and Troughs with a fresh set from the current thresholds.
@export_tool_button("Add Brushes") var _add_brushes_btn = add_brushes
## Remove every brush this manager generated, edited or not.
@export_tool_button("Clear Brushes") var _clear_brushes_btn = clear_brushes

## Footprint hash recorded at the last successful bake (loops, margin, and the pass ORDER — reordering
## the children changes the result, so it has to invalidate the bake).
@export_storage var _baked_hash: String = ""
## True when the bake in the layer came from Preview rather than Simulate.
@export_storage var _baked_preview: bool = false

var _running: bool = false
var _cancel: bool = false
## Diffusion sub-steps the last solve actually used, across every pass (the worst case, since one pass
## hitting the ceiling is enough to under-smooth the chain).
var _last_substeps: int = 0

## §19.8 gates AH and AL: when set, every pass's input and output surface is kept so a gate can assert
## that pass 2's input IS pass 1's output, bitwise, and that a mask was evaluated against it. Off by
## default — it holds two full grids per pass alive for the life of the node.
var capture_chain: bool = false
## [{cluster, pass, name, z_in, z_out, mask_field}] in execution order, from the last solve.
var last_chain: Array = []


# ---- Pasture3DSimBase hooks -----------------------------------------------------------------------

func _sim_label() -> String:
	return "Pasture3DSimManager '%s'" % name


func _water_config() -> Dictionary:
	return {
		"river_area_threshold": river_area_threshold, "min_river_length": min_river_length,
		"curve_tolerance": curve_tolerance, "lake_depth_threshold": lake_depth_threshold,
		"min_lake_area": min_lake_area, "river_width_max": river_width_max,
		"river_width_min": river_width_min, "river_carve_depth": river_carve_depth,
	}


func _sim_result_res() -> Pasture3DSimResult:
	return sim_result


func _set_sim_result_res(p_r: Pasture3DSimResult) -> void:
	sim_result = p_r


## Every pass's loops, each grown by that pass's own edge offset. The write area of a manager is the union
## of its passes' write areas, which is what makes §19.6's "one Trough instead of two" fall out of the
## existing clip rather than needing a special case.
func _write_polygons() -> Array:
	var out: Array = []
	if not is_configured():
		return out
	for p: Pasture3DSim in passes():
		for s in p._get_splines():
			if not p._spline_paintable(s):
				continue
			var poly := _polygon_xz(s)
			if poly.size() < 3:
				continue
			out.append_array(_offset_polygon(poly, p.edge_offset))
	return out


# ---- Pasture3DTerrainBrush hooks -------------------------------------------------------------------
#
# A manager has no splines of its own: its footprint is its passes'. Both overrides below exist because
# the base class asks "where does this node reach" for the layer clear, for the dirty-rect repaint of
# layer-mates, and for its own auto-refresh — and every one of those answers has to include the children,
# or the commit would clear a box that does not contain the erosion it is about to write.

func _own_footprints() -> Array:
	var out: Array = []
	for p: Pasture3DSim in passes():
		for s in p._get_splines():
			var a := p._spline_footprint_aabb(s)
			if a.size != Vector3.ZERO:
				out.append(a)
	for sid in _last_paint_aabb:
		var b: AABB = _last_paint_aabb[sid]
		if b.size != Vector3.ZERO:
			out.append(b)
	return out


func _overlaps_box(p_box: AABB) -> bool:
	for a: AABB in _own_footprints():
		if a.intersects(p_box):
			return true
	return false


## §19.2: the loops belong to the passes. A manager with no spline of its own is correctly configured, so
## it must not be told to add one — and the two buttons that would build one are hidden rather than left
## to produce a Path3D nothing reads.
func _wants_own_splines() -> bool:
	return false


func _validate_property(p_property: Dictionary) -> void:
	if p_property.name in ["_add_spline_btn", "_add_water_btn"]:
		p_property.usage = PROPERTY_USAGE_NONE


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := super()
	var ps := passes()
	if ps.is_empty():
		warnings.append(("This manager has no passes. Add Pasture3DSim children — each one is a pass, and "
			+ "the order they appear in here is the order they run in."))
		return warnings
	if _baked_hash == "":
		warnings.append("No simulation in the layer — press Simulate.")
	elif _baked_hash != _area_hash():
		warnings.append(("The passes have changed since the last simulation — a loop moved, the margin "
			+ "changed, or the children were reordered — so the erosion in the layer no longer matches. "
			+ "Press Simulate again."))
	elif _baked_preview:
		warnings.append(("The erosion in the layer is a PREVIEW (1/%d resolution), not a build. Press "
			+ "Simulate to commit it at full resolution.") % preview_resolution)
	var loopless: Array = []
	for p: Pasture3DSim in ps:
		if p._get_splines().filter(func(s): return p._spline_paintable(s)).is_empty():
			loopless.append(p.name)
	if not loopless.is_empty():
		warnings.append("These passes have no usable loop and contribute nothing: %s." % ", ".join(loopless))
	var plan := plan_clusters(build_resolution)
	if not bool(plan["ok"]):
		warnings.append(plan["reason"])
	elif int(plan["clusters"].size()) > 1:
		# Not a fault — but "why is there still a seam between these two areas" is the question this
		# design most invites, and the answer is always this number.
		warnings.append(("These %d passes solve as %d separate grids, so drainage is NOT continuous "
			+ "between them. Raise Catchment Margin until their boxes overlap, or move them together, if "
			+ "you meant them to share a watershed.") % [ps.size(), plan["clusters"].size()])
	var layer := _resolve_layer_for(_layer_owner)
	if layer != null and layer.has_method("get_blend_mode") and layer.get_blend_mode() != BLEND_ADD:
		warnings.append(("The '%s' layer's blend mode is not Add, so this manager's delta will overwrite "
			+ "rather than erode. Give it its own layer, or set that layer back to Add.") % layer.get_layer_name())
	if _last_substeps >= 64:
		warnings.append(("At least one pass's Hillslope Diffusion is large enough that the explicit "
			+ "diffusion pass hit its sub-step ceiling, so less smoothing was applied than asked for."))
	warnings.append_array(_result_warnings(_baked_hash))
	if _water_preview != "":
		warnings.append("Water features: %s." % _water_preview)
	if river_width_min > river_width_max:
		warnings.append("River Width Min is greater than River Width Max, so every generated river "
			+ "comes out at the maximum width.")
	var mate := _standalone_sim_on_layer()
	if mate != "":
		warnings.append(("The standalone Sim '%s' shares this manager's layer and is close enough that "
			+ "baking either clears the other's erosion. Give it its own layer — or make it a pass by "
			+ "dragging it under this manager.") % mate)
	return warnings


## A Pasture3DSim that is NOT one of our passes but writes to our layer, close enough that the two clear
## each other. The manager removes the two-writers problem among its own children; it cannot remove it for
## a stranger, so it says so in the same terms §19.1 does.
func _standalone_sim_on_layer() -> String:
	if not is_inside_tree() or not is_configured():
		return ""
	if _resolve_layer_for(_layer_owner) == null:
		return ""
	var step := _layer_tile_world(_layer_id)
	var mine := AABB()
	var have := false
	for a: AABB in _own_footprints():
		mine = a if not have else mine.merge(a)
		have = true
	if not have:
		return ""
	mine = _snap_aabb_to_tiles(mine, step)
	for s in _tools_on_owner(_layer_owner):
		if s == self or not (s is Pasture3DSim) or s.manager() == self:
			continue
		for b: AABB in s._own_footprints():
			if _snap_aabb_to_tiles(b, step).intersects(mine):
				return s.name
	return ""


# ---- The passes -----------------------------------------------------------------------------------

## The chain, in scene-dock order. Direct Pasture3DSim children only: a Sim nested two levels down is
## somebody's organisational choice, and silently promoting it to a pass would make the stack order in the
## dock stop matching the stack order that runs.
func passes() -> Array:
	var out: Array = []
	for c in get_children():
		if c is Pasture3DSim:
			out.append(c)
	return out


func pass_index_of(p_sim: Pasture3DSim) -> int:
	return passes().find(p_sim)


# ---- Clustering (spec §19.4) ----------------------------------------------------------------------

## Group the passes' loops into clusters and size each one's grid, WITHOUT solving anything.
##
## The clustering unit is the LOOP, not the pass. A pass with two loops a kilometre apart belongs to two
## clusters and runs once in each — §19.4's "a pass whose loop reaches into several clusters runs once per
## cluster" — and clustering by node would have forced those two loops into one enormous box, which is the
## exact cost blow-up this function exists to prevent.
##
## Returns {ok, reason, clusters: [{passes, loops, box, min_x, min_z, cell, sw, sh, tw, th, cells}]}.
## `ok` is false when any cluster is over budget: §19.4 refuses, and refusing one cluster while building
## the others would commit a landscape missing part of its chain and call it a success.
func plan_clusters(p_scale: int = 1) -> Dictionary:
	var out := {"ok": false, "reason": "", "clusters": []}
	if not is_configured():
		out["reason"] = "no Pasture3D terrain assigned"
		return out
	var vs: float = terrain.vertex_spacing
	var scale := maxi(p_scale, 1)

	# Every usable loop, with the pass that owns it and its margin-grown box.
	var loops: Array = []
	for p: Pasture3DSim in passes():
		for s in p._get_splines():
			if not p._spline_paintable(s):
				continue
			loops.append({"pass": p, "spline": s,
					"box": p._spline_footprint_aabb(s).grow(catchment_margin)})
	if loops.is_empty():
		out["reason"] = "no pass has a loop with at least 3 points"
		return out

	# Connected components over box overlap. Union-find would be asymptotically nicer; the count here is
	# the number of loops in a scene, so the naive merge is both faster in practice and easier to read.
	var groups: Array = []
	for l: Dictionary in loops:
		var box: AABB = l["box"]
		var hit: Array = []
		for gi in range(groups.size()):
			if (groups[gi]["box"] as AABB).intersects(box):
				hit.append(gi)
		if hit.is_empty():
			groups.append({"box": box, "loops": [l]})
			continue
		# Adding one loop can BRIDGE groups that did not touch each other before, so every group it
		# reaches has to fold into one. Missing this is how a "cluster" quietly stays two grids that
		# overlap, which would solve the same ground twice and disagree with itself where they meet.
		var keep: Dictionary = groups[hit[0]]
		keep["box"] = (keep["box"] as AABB).merge(box)
		keep["loops"].append(l)
		for k in range(hit.size() - 1, 0, -1):
			var g: Dictionary = groups[hit[k]]
			keep["box"] = (keep["box"] as AABB).merge(g["box"])
			keep["loops"].append_array(g["loops"])
			groups.remove_at(hit[k])

	var over: Array = []
	for g: Dictionary in groups:
		var sb := _snapped_bounds(g["box"], vs)
		var tw := int(round((sb[1] - sb[0]) / vs)) + 1
		var th := int(round((sb[3] - sb[2]) / vs)) + 1
		var sw := mini(maxi(int(floor(float(tw - 1) / float(scale))) + 1, MIN_SIM_CELLS), tw)
		var sh := mini(maxi(int(floor(float(th - 1) / float(scale))) + 1, MIN_SIM_CELLS), th)
		# Square cells, as the solver assumes (D8 diagonal lengths, the Laplacian's 1/Δx²). The two axes
		# differ only by the rounding above, so take the mean — the same rule Pasture3DSim uses.
		var cell := (float(tw - 1) / float(maxi(sw - 1, 1)) + float(th - 1) / float(maxi(sh - 1, 1))) * 0.5 * vs
		# The pass list, in STACK order, restricted to the passes with a loop in this cluster.
		var members: Array = []
		for p: Pasture3DSim in passes():
			var mine: Array = []
			for l: Dictionary in g["loops"]:
				if l["pass"] == p:
					mine.append(l["spline"])
			if not mine.is_empty():
				members.append({"pass": p, "splines": mine})
		var cl := {"passes": members, "loops": g["loops"], "box": g["box"],
				"min_x": sb[0], "max_x": sb[1], "min_z": sb[2], "max_z": sb[3],
				"cell": cell, "sw": sw, "sh": sh, "tw": tw, "th": th, "cells": sw * sh}
		if sw * sh > max_cluster_cells:
			over.append(cl)
		out["clusters"].append(cl)

	if not over.is_empty():
		var names: Array = []
		for cl: Dictionary in over:
			var pn: Array = []
			for m: Dictionary in cl["passes"]:
				pn.append(m["pass"].name)
			names.append("[%s] at %.0f x %.0f m needs %d x %d = %d cells" % [
					", ".join(pn), cl["max_x"] - cl["min_x"], cl["max_z"] - cl["min_z"],
					cl["sw"], cl["sh"], cl["cells"]])
		out["reason"] = (("REFUSED: %d cluster(s) exceed the %d-cell budget: %s. Nothing was simulated. "
			+ "This is NOT coarsened on purpose — a coarser grid erodes deeper (§6), so dropping "
			+ "resolution to fit would hand back a different landscape with nothing to say so. Split the "
			+ "cluster by lowering Catchment Margin or moving the loops apart, raise Build Resolution's "
			+ "divisor yourself, or raise Max Cluster Cells if the memory is really there.")
			% [over.size(), max_cluster_cells, "; ".join(names)])
		return out
	out["ok"] = true
	return out


## Plan Clusters: print what the current configuration would solve. Returns the plan.
func print_plan() -> Dictionary:
	var plan := plan_clusters(build_resolution)
	if not bool(plan["ok"]):
		push_warning("%s: %s" % [_sim_label(), plan["reason"]])
		return plan
	var total := 0
	print("%s: %d cluster(s) at build resolution 1/%d:" % [_sim_label(), plan["clusters"].size(), build_resolution])
	for cl: Dictionary in plan["clusters"]:
		var pn: Array = []
		for m: Dictionary in cl["passes"]:
			pn.append(m["pass"].name)
		total += int(cl["cells"])
		print("    %d x %d cells at %.2f m over %.0f x %.0f m — passes: %s" % [
				cl["sw"], cl["sh"], cl["cell"], cl["max_x"] - cl["min_x"], cl["max_z"] - cl["min_z"],
				" -> ".join(pn)])
	print("    %d cells total, budget %d per cluster." % [total, max_cluster_cells])
	return plan


# ---- The buttons ----------------------------------------------------------------------------------

func preview_simulation() -> void:
	await _simulate_interactive(preview_resolution, true)


func run_simulation() -> void:
	await _simulate_interactive(build_resolution, false)


## Clear Simulation: empty every pass's footprint out of the layer, restoring the ground below.
func clear_simulation() -> void:
	if not is_configured():
		return
	var layer_id := _ensure_layer_for(_layer_owner, true)
	if layer_id <= 0:
		push_warning("%s: no reserved layer to clear." % _sim_label())
		return
	_commit([], layer_id, true, "Clear")
	_baked_hash = ""
	_baked_preview = false
	_empty_result()
	update_configuration_warnings()


func cancel_simulation() -> void:
	if _running:
		_cancel = true
		print("%s: cancelling..." % _sim_label())


# ---- The bake (spec §19.2) ------------------------------------------------------------------------
#
# Same shape as Pasture3DSim's: solve everything, THEN commit once. The state machine (_begin /
# _solve_chunk / _finish) is what lets `simulate_now` run straight through for scripts and gates while
# `_simulate_interactive` yields a frame between chunks for the editor — one implementation, two drivers,
# and neither is a coroutine the other has to be.
#
# The unit of work here is a CLUSTER rather than a loop, and a cluster carries a cursor through its own
# pass list. `_solve_chunk` advances the current pass by CHUNK_ITERATIONS, and when a pass finishes it is
# folded into the chain and the cursor moves on.

## Solve and write, running straight through with no frame yields. The entry point for scripts and gates.
## Returns {ok, reason, clusters, passes, cells, msec, substeps, masks}.
func simulate_now(p_scale: int = 1, p_record_undo: bool = false) -> Dictionary:
	var ctx := _begin(p_scale, p_record_undo, p_scale != build_resolution)
	if not bool(ctx["ok"]):
		return ctx["report"]
	for cl in ctx["clusters"]:
		while not _solve_chunk(cl):
			pass
	return _finish(ctx)


func _simulate_interactive(p_scale: int, p_is_preview: bool) -> void:
	var ctx := _begin(p_scale, true, p_is_preview)
	if not bool(ctx["ok"]):
		return
	var total := 0
	for cl in ctx["clusters"]:
		total += int(cl["total_iterations"])
	total = maxi(total, 1)
	for cl in ctx["clusters"]:
		while not _solve_chunk(cl):
			if _cancel:
				_abort(ctx)
				return
			if not is_inside_tree() or not is_configured():
				_abort(ctx)
				return
			var done := 0
			for c in ctx["clusters"]:
				done += int(c["iterations_done"])
			print("%s: %d%%" % [_sim_label(), int(100.0 * float(done) / float(total))])
			await get_tree().process_frame
	if _cancel:
		_abort(ctx)
		return
	_finish(ctx)


## Validate, resolve the layer, plan the clusters and read each one's starting surface. `ok` false means
## nothing was done and `report.reason` says why.
func _begin(p_scale: int, p_record_undo: bool, p_is_preview: bool) -> Dictionary:
	var report := {"ok": false, "reason": "", "clusters": 0, "passes": 0, "cells": 0, "msec": 0,
			"substeps": 0, "masks": ""}
	var fail := {"ok": false, "report": report}
	if _running:
		report["reason"] = "a solve is already running"
		return fail
	if not is_configured():
		report["reason"] = "no Pasture3D terrain assigned"
		return fail
	if passes().is_empty():
		report["reason"] = "this manager has no Pasture3DSim children to run as passes"
		push_warning("%s: %s." % [_sim_label(), report["reason"]])
		return fail
	var layer_id := _ensure_layer_for(_layer_owner, true)
	if layer_id <= 0:
		# Same as a Sim: the chain reads the surface BELOW this node's layer to stay idempotent (§13), and
		# without a layer stack there is no "below" to read. There is no destructive fallback.
		report["reason"] = "the layers Tool API is unavailable, and there is no destructive fallback"
		push_warning("%s: %s." % [_sim_label(), report["reason"]])
		return fail

	var scale := maxi(p_scale, 1)
	var plan := plan_clusters(scale)
	if not bool(plan["ok"]):
		report["reason"] = plan["reason"]
		push_warning("%s: %s" % [_sim_label(), report["reason"]])
		return fail

	var clusters: Array = []
	for cl: Dictionary in plan["clusters"]:
		var st := _prepare_cluster(cl, layer_id)
		if not st.is_empty():
			clusters.append(st)
	if clusters.is_empty():
		report["reason"] = "no terrain regions under any pass's loops"
		push_warning("%s: %s." % [_sim_label(), report["reason"]])
		return fail

	_running = true
	_cancel = false
	last_chain = []
	return {"ok": true, "report": report, "clusters": clusters, "layer_id": layer_id,
			"is_preview": p_is_preview, "record_undo": p_record_undo, "scale": scale,
			"t0": Time.get_ticks_msec()}


## One cluster's solve state: the shared grid, the ONE below-layer read that seeds the chain (§19.2 step
## 1), and the pass cursor. Returns {} when there is nothing solvable there.
##
## Idempotency (§13) lives in one line here, exactly as it does in a Sim: `z0` is composite_height_below,
## the surface beneath THIS node's layer. Every pass in the chain is a deterministic function of it, which
## is why per-pass mask re-evaluation (§19.5) is not the drift bug even though it looks like one.
func _prepare_cluster(p_cl: Dictionary, p_layer_id: int) -> Dictionary:
	var vs: float = terrain.vertex_spacing
	var tw: int = p_cl["tw"]
	var th: int = p_cl["th"]
	var sw: int = p_cl["sw"]
	var sh: int = p_cl["sh"]
	if sw < 3 or sh < 3:
		return {}
	var below: PackedFloat32Array = terrain.data.composite_height_below(
			p_layer_id, p_cl["min_x"], p_cl["min_z"], vs, tw, th)
	if below.size() != tw * th:
		return {}
	var z0: PackedFloat32Array = terrain.data.resample_grid(below, tw, th, sw, sh)
	if z0.size() != sw * sh:
		return {}
	var total := 0
	for m: Dictionary in p_cl["passes"]:
		total += maxi((m["pass"] as Pasture3DSim).iterations, 1)
	var st := p_cl.duplicate()
	st["layer_id"] = p_layer_id
	st["vs"] = vs
	st["z0"] = z0
	st["z"] = z0            # the chain's running surface
	st["z_solved"] = PackedFloat32Array()
	st["step"] = 0          # which pass is running
	st["done"] = 0          # iterations completed within it
	st["started"] = false
	st["iterations_done"] = 0
	st["total_iterations"] = maxi(total, 1)
	st["fields"] = {}       # the previous pass's live sim channels (§19.5); empty for pass 1
	st["failed"] = false
	return st


## Advance one cluster by up to CHUNK_ITERATIONS of its current pass. Returns true when the whole chain
## for that cluster is finished (or has failed).
func _solve_chunk(p_st: Dictionary) -> bool:
	if bool(p_st["failed"]):
		return true
	var members: Array = p_st["passes"]
	if int(p_st["step"]) >= members.size():
		return true
	var member: Dictionary = members[int(p_st["step"])]
	var sim: Pasture3DSim = member["pass"]
	var iters: int = maxi(sim.iterations, 1)

	if not bool(p_st["started"]):
		if not _start_pass(p_st, member):
			return true
		p_st["started"] = true
		# §19.8 AH: the surface the SOLVER was handed, captured here rather than in _start_pass because
		# here it cannot be anything else. A capture taken off the chain bookkeeping is a record of what
		# the chain intended, and a break test proved the difference: with every pass re-seeded from z0 —
		# the chain disconnected outright — the bookkeeping capture still showed a bitwise handover and AH
		# passed. This is what erode_heightfield actually receives.
		if capture_chain and not last_chain.is_empty():
			last_chain[-1]["z_seed"] = (p_st["z_solved"] as PackedFloat32Array).duplicate()

	var chunk := mini(CHUNK_ITERATIONS, iters - int(p_st["done"]))
	var params: Dictionary = p_st["params"]
	params["iterations"] = chunk
	var res: Dictionary = terrain.data.erode_heightfield(p_st["z_solved"], params, p_st["erod"])
	if not bool(res.get("ok", false)):
		push_warning(("%s: the solver rejected pass '%s' on the %dx%d cluster grid — most likely no "
			+ "terrain regions under it.") % [_sim_label(), sim.name, int(p_st["sw"]), int(p_st["sh"])])
		p_st["failed"] = true
		return true
	p_st["z_solved"] = res["z"]
	_last_substeps = maxi(_last_substeps, int(res.get("diffusion_substeps", 0)))
	p_st["done"] = int(p_st["done"]) + chunk
	p_st["iterations_done"] = int(p_st["iterations_done"]) + chunk
	if int(p_st["done"]) < iters:
		return false

	_finish_pass(p_st, member)
	p_st["step"] = int(p_st["step"]) + 1
	p_st["done"] = 0
	p_st["started"] = false
	return int(p_st["step"]) >= members.size()


## Set one pass up against the surface the chain has reached: its erodability field, its erosion mask
## evaluated HERE and NOW (§19.5), and the solver parameters that are its own (§19.3).
func _start_pass(p_st: Dictionary, p_member: Dictionary) -> bool:
	var sim: Pasture3DSim = p_member["pass"]
	var sw: int = p_st["sw"]
	var sh: int = p_st["sh"]
	var z_in: PackedFloat32Array = p_st["z"]
	var erod: Array = sim._erodability_lut()
	var e_field: PackedFloat32Array = erod[0]
	var e_w := int(erod[1])
	var e_h := int(erod[2])
	var e_lo: float = sim.erodability_range.x
	var e_hi: float = sim.erodability_range.y

	# §19.5 — THE REASON TO CHAIN. The mask is evaluated against this pass's INPUT surface, not once up
	# front against z0, so a CURVATURE mask on pass 2 sees the hollows pass 1 just cut. `p_st["fields"]` is
	# the previous pass's live flow / erosion / deposition / wetness, from the routing pass _finish_pass
	# ran over its output — not a .res on disk, and not this node's own output, so it is not the §13 drift
	# class. Pass 1 has no predecessor and its sim Filter Types read a defined 0 everywhere (the child warns).
	var sel := sim._selector_block(sim.erosion_mask)
	if not sel.is_empty():
		var field: PackedFloat32Array = terrain.data.selector_mask_field(z_in, {
				"gw": sw, "gh": sh, "cell_size": p_st["cell"],
				"min_x": p_st["min_x"], "min_z": p_st["min_z"],
				"erodability_lut": e_field, "erodability_w": e_w, "erodability_h": e_h,
				"erodability_min": e_lo, "erodability_max": e_hi,
			}, sel, p_st["fields"])
		if field.size() == sw * sh:
			e_field = field
			e_w = sw
			e_h = sh
			e_lo = 0.0
			e_hi = 1.0
		else:
			push_warning(("%s: the erosion mask for pass '%s' could not be built, so it eroded UNMASKED. "
				+ "Nothing was silently gated.") % [_sim_label(), sim.name])
	p_st["erod"] = e_field
	p_st["params"] = {
		"gw": sw, "gh": sh, "cell_size": p_st["cell"],
		"time_step": 1.0,
		"erosion_rate": sim.erosion_rate,
		"area_exponent": sim.area_exponent,
		"diffusion": sim.hillslope_diffusion,
		"erodability_min": e_lo, "erodability_max": e_hi,
		"erodability_w": e_w, "erodability_h": e_h,
	}
	p_st["z_solved"] = z_in
	if capture_chain:
		last_chain.append({"cluster": p_st["min_x"], "pass": int(p_st["step"]), "name": sim.name,
				"z_in": z_in.duplicate(), "z_out": PackedFloat32Array(),
				"mask": e_field.duplicate() if e_field.size() == sw * sh else PackedFloat32Array()})
	return true


## Fold a finished pass into the chain (§19.2 step 3) and, if a later pass needs them, route its output
## once for the live fields §19.5 hands forward.
func _finish_pass(p_st: Dictionary, p_member: Dictionary) -> void:
	var sim: Pasture3DSim = p_member["pass"]
	var sw: int = p_st["sw"]
	var sh: int = p_st["sh"]
	var gate_params := {
		"sw": sw, "sh": sh, "gw": sw, "gh": sh,
		"sim_min_x": p_st["min_x"], "sim_min_z": p_st["min_z"], "sim_cell": p_st["cell"],
		"min_x": p_st["min_x"], "min_z": p_st["min_z"], "vs": p_st["cell"],
		"edge_offset": sim.edge_offset, "falloff_width": maxf(sim.falloff_width, 0.001),
	}
	# §17.3's write mask, read off this pass's INPUT surface for the same reason a standalone Sim reads it
	# off the below-layer surface: gating on the ground you started from is what "only the north face"
	# means, and a mask read off the solve would move with its own output.
	var wsel := sim._selector_block(sim.write_mask)
	if not wsel.is_empty():
		var wfield: PackedFloat32Array = terrain.data.selector_mask_field(p_st["z"], {
				"gw": sw, "gh": sh, "cell_size": p_st["cell"],
				"min_x": p_st["min_x"], "min_z": p_st["min_z"],
			}, wsel, p_st["fields"])
		if wfield.size() == sw * sh:
			gate_params["write_mask"] = wfield
		else:
			push_warning(("%s: the write mask for pass '%s' could not be built, so its whole solved delta "
				+ "was folded in.") % [_sim_label(), sim.name])

	var ones := PackedFloat32Array()
	ones.resize(sw * sh)
	ones.fill(1.0)
	var ramp := _ramp_lut(sim.falloff_curve)
	var z: PackedFloat32Array = p_st["z"]
	var z_solved: PackedFloat32Array = p_st["z_solved"]
	for s in p_member["splines"]:
		var poly := _polygon_xz(s)
		if poly.size() < 3:
			continue
		# The pass's own loop mask AT SIM RESOLUTION: `sim_mask_deltas` fed a field of ones returns the
		# mask itself — edge offset, falloff width, falloff curve and write mask included — with the sim
		# grid standing in for the write grid so no resampling happens. The bake's own masker, not a
		# reimplementation of it.
		var gate: PackedFloat32Array = terrain.data.sim_mask_deltas(ones, poly, gate_params, ramp)
		if gate.size() != sw * sh:
			push_warning(("%s: the loop mask for pass '%s' could not be rasterised; that loop contributed "
				+ "nothing.") % [_sim_label(), sim.name])
			continue
		z = terrain.data.sim_chain_blend(z, z_solved, gate)
	p_st["z"] = z
	if capture_chain and not last_chain.is_empty():
		last_chain[-1]["z_out"] = z.duplicate()

	# The live fields for the NEXT pass, but only when a later pass actually asks for them: routing the
	# surface is a fill+route per pass, and most chains gate on slope and altitude rather than on flow.
	if _later_pass_wants_fields(p_st):
		p_st["fields"] = _live_fields(p_st)


## Does any pass after the current one use a sim Filter Type in either mask stack? If not, the routing
## pass is a fill+route bought for nothing.
func _later_pass_wants_fields(p_st: Dictionary) -> bool:
	var members: Array = p_st["passes"]
	for i in range(int(p_st["step"]) + 1, members.size()):
		var sim: Pasture3DSim = members[i]["pass"]
		for stack in [sim.erosion_mask, sim.write_mask]:
			for s: Pasture3DReliefSelector in stack:
				if s != null and s.is_sim_filter_type():
					return true
	return false


## Route and fill the chain's current surface for its drainage area and standing water, then split the
## net delta into the four §8.2 channels over the cluster grid.
##
## Built through `sim_result_build` rather than by hand so the LIVE fields a mask reads and the FINAL
## fields written to the .res come out of one piece of code with one set of conventions — `flow` is
## log-scaled at both ends, and erosion/deposition are the two signs of one net field at both ends. Two
## implementations of that would eventually disagree, and the disagreement would show up as a mask that
## gates differently from the .res describing the same ground.
func _live_fields(p_st: Dictionary) -> Dictionary:
	var diag := _diagnose(p_st, p_st["z"])
	if diag.is_empty():
		return {}
	var target := {"min_x": p_st["min_x"], "min_z": p_st["min_z"], "cell_size": p_st["cell"],
			"width": p_st["sw"], "height": p_st["sh"]}
	var built: Dictionary = terrain.data.sim_result_build([_result_part(p_st, diag)], target)
	if not bool(built.get("ok", false)):
		return {}
	var out := target.duplicate()
	out["flow"] = built["flow"]
	out["erosion"] = built["erosion"]
	out["deposition"] = built["deposition"]
	out["wetness"] = built["wetness"]
	return out


## One `sim_result_build` part for a cluster. The whole cluster counts as write area: the merge's
## "write beats margin" precedence exists to arbitrate between two loops that solved the same ground to
## different answers, and inside one cluster there is only ever one answer.
func _result_part(p_st: Dictionary, p_diag: Dictionary) -> Dictionary:
	return {
		"sw": p_st["sw"], "sh": p_st["sh"], "cell": p_st["cell"],
		"min_x": p_st["min_x"], "min_z": p_st["min_z"],
		"z0": p_st["z0"], "z1": p_st["z"], "flow": p_diag["flow"], "lake": p_diag["lake"],
		"write_min_x": p_st["min_x"], "write_max_x": p_st["max_x"],
		"write_min_z": p_st["min_z"], "write_max_z": p_st["max_z"],
	}


## The zero-iteration routing pass (§8.2): fills, routes and accumulates over `p_z`, returning it
## untouched. Used both between passes and once at the end, so the fields always describe the surface they
## are shipped beside rather than the one before the last iteration.
func _diagnose(p_st: Dictionary, p_z: PackedFloat32Array) -> Dictionary:
	var params := {
		"gw": p_st["sw"], "gh": p_st["sh"], "cell_size": p_st["cell"],
		"time_step": 1.0, "iterations": 0, "want_diagnostics": true,
		"erosion_rate": 0.0, "area_exponent": 0.45, "diffusion": 0.0,
	}
	var res: Dictionary = terrain.data.erode_heightfield(p_z, params, PackedFloat32Array())
	if not bool(res.get("ok", false)):
		push_warning("%s: the diagnostics pass failed; this cluster contributes no masks." % _sim_label())
		return {}
	return {"flow": res["flow"], "lake": res["lake_depth"]}


## Turn every finished cluster into its write block and commit them all as ONE action (§19.2 step 4).
func _finish(p_ctx: Dictionary) -> Dictionary:
	var report: Dictionary = p_ctx["report"]
	var solved: Array = []
	var parts: Array = []
	var states: Array = []
	var cells := 0
	var pass_runs := 0
	for st in p_ctx["clusters"]:
		if bool(st["failed"]):
			continue
		var block := _cluster_write(st)
		if block.is_empty():
			continue
		cells += int(st["sw"]) * int(st["sh"])
		pass_runs += (st["passes"] as Array).size()
		solved.append(block)
		var diag := _diagnose(st, st["z"])
		if not diag.is_empty():
			parts.append(_result_part(st, diag))
			states.append(st)
	_running = false
	if solved.is_empty():
		report["reason"] = "the chain produced an empty delta for every cluster"
		push_warning("%s: %s." % [_sim_label(), report["reason"]])
		return report

	var is_preview: bool = p_ctx["is_preview"]
	_commit(solved, int(p_ctx["layer_id"]), bool(p_ctx["record_undo"]),
			"Preview" if is_preview else "Simulate")
	_baked_hash = _area_hash()
	_baked_preview = is_preview
	report["masks"] = _write_result(parts, states, is_preview, int(p_ctx["scale"]))
	update_configuration_warnings()
	report["ok"] = true
	report["clusters"] = solved.size()
	report["passes"] = pass_runs
	report["cells"] = cells
	report["msec"] = Time.get_ticks_msec() - int(p_ctx["t0"])
	report["substeps"] = _last_substeps
	print("%s: %s %d cluster(s), %d pass run(s), %d sim cells, %d ms.%s" % [
			_sim_label(), "previewed" if is_preview else "simulated", solved.size(), pass_runs, cells,
			report["msec"], "\n  " + str(report["masks"]) if report["masks"] != "" else ""])
	return report


## One cluster's total delta on the terrain grid, ready for apply_sim_block. The write grid is the
## cluster's own snapped box at terrain resolution — the same rect the below-layer read came from, so the
## two are corner-aligned by construction and a 1x build resamples to a bitwise copy.
func _cluster_write(p_st: Dictionary) -> Dictionary:
	var write: PackedFloat32Array = terrain.data.sim_chain_write(p_st["z0"], p_st["z"], {
			"sw": p_st["sw"], "sh": p_st["sh"], "gw": p_st["tw"], "gh": p_st["th"],
			"sim_min_x": p_st["min_x"], "sim_min_z": p_st["min_z"], "sim_cell": p_st["cell"],
			"min_x": p_st["min_x"], "min_z": p_st["min_z"], "vs": p_st["vs"],
		})
	if write.size() != int(p_st["tw"]) * int(p_st["th"]):
		return {}
	var box := AABB()
	var have := false
	for l: Dictionary in p_st["loops"]:
		var a: AABB = (l["pass"] as Pasture3DSim)._spline_footprint_aabb(l["spline"])
		box = a if not have else box.merge(a)
		have = true
	# Keyed by the cluster's first loop, because _last_paint_aabb is a per-spline footprint cache and one
	# cluster is one write. The box is the union of its loops, so a later clear still covers all of them.
	return {"spline_id": (p_st["loops"][0]["spline"] as Path3D).get_instance_id(),
			"box": box if have else AABB(),
			"min_x": p_st["min_x"], "min_z": p_st["min_z"],
			"gw": p_st["tw"], "gh": p_st["th"], "write": write}


## Build the four §8.2 channels from every cluster and store them in `sim_result`.
##
## §19.6 asks for one result PER CLUSTER; this node has one `sim_result` slot, so several clusters are
## merged onto one grid through the same "several loops" path a Sim already uses — union box, mean cell
## size, coarsened with a warning past RESULT_MAX_CELLS. That keeps one resource for a selector to point
## at, which is what makes the phase-3 limitation §19.6 retires actually retired. The single-cluster case,
## which is the one the design is really about, is bit-exact with no resampling at all.
func _write_result(p_parts: Array, p_states: Array, p_is_preview: bool, p_scale: int) -> String:
	_clear_water_overlay()
	if p_parts.is_empty():
		return ""
	var target := _result_target(p_states)
	var built: Dictionary = terrain.data.sim_result_build(p_parts, target)
	if not bool(built.get("ok", false)):
		push_warning("%s: the masks could not be built for this bake." % _sim_label())
		return ""
	var r := sim_result
	if r == null:
		r = Pasture3DSimResult.new()
		sim_result = r
	r.min_x = target["min_x"]
	r.min_z = target["min_z"]
	r.cell_size = target["cell_size"]
	r.width = target["width"]
	r.height = target["height"]
	r.flow = built["flow"]
	r.erosion = built["erosion"]
	r.deposition = built["deposition"]
	r.wetness = built["wetness"]
	r.source_node = name
	r.source_preview = p_is_preview
	r.source_resolution = p_scale
	# §8.2 decision 6 records ONE value per solver setting, and a chain has one per pass. Rather than
	# inventing a sentinel — a negative rate meaning "several", which was the first attempt and is exactly
	# the kind of undocumented convention §8.2's own `flow` note exists to warn about — these record what
	# is true of the chain as a whole: iterations SUM, because the passes ran in sequence over one grid,
	# and the rates are the strongest any pass used. `source_node` names the manager, so a reader who needs
	# the per-pass settings knows where to find them.
	var it := 0
	var hi := 0.0
	var dhi := 0.0
	var ex := 0.0
	for st: Dictionary in p_states:
		for m: Dictionary in st["passes"]:
			var sim: Pasture3DSim = m["pass"]
			it += maxi(sim.iterations, 1)
			hi = maxf(hi, sim.erosion_rate)
			dhi = maxf(dhi, sim.hillslope_diffusion)
			ex = maxf(ex, sim.area_exponent)
	r.source_iterations = it
	r.source_erosion_rate = hi
	r.source_area_exponent = ex
	r.source_diffusion = dhi
	r.source_catchment_margin = catchment_margin
	r.source_area_hash = _area_hash()
	r.source_time = Time.get_datetime_string_from_system(true, true)
	r.source_loops = int(built.get("parts", p_parts.size()))
	r.emit_changed()
	_save_result(r)
	return r.describe()


## The grid the clusters' masks are merged onto. One cluster gets its own grid verbatim.
func _result_target(p_states: Array) -> Dictionary:
	if p_states.size() == 1:
		var st: Dictionary = p_states[0]
		return {"min_x": st["min_x"], "min_z": st["min_z"], "cell_size": st["cell"],
				"width": st["sw"], "height": st["sh"]}
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	var cell := 0.0
	for st: Dictionary in p_states:
		min_x = minf(min_x, st["min_x"])
		max_x = maxf(max_x, st["max_x"])
		min_z = minf(min_z, st["min_z"])
		max_z = maxf(max_z, st["max_z"])
		cell += float(st["cell"])
	cell = maxf(cell / float(p_states.size()), 0.001)
	var w := int(round((max_x - min_x) / cell)) + 1
	var h := int(round((max_z - min_z) / cell)) + 1
	if w * h > RESULT_MAX_CELLS:
		var s := sqrt(float(w) * float(h) / float(RESULT_MAX_CELLS))
		cell *= s
		w = int(round((max_x - min_x) / cell)) + 1
		h = int(round((max_z - min_z) / cell)) + 1
		push_warning(("%s: the %d clusters span too large a box to hold their masks at sim resolution, so "
			+ "the Sim Result is %.2f m per cell (%.1fx coarser than the solve). The SOLVE was not "
			+ "coarsened — only this output.") % [_sim_label(), p_states.size(), cell, s])
	return {"min_x": min_x, "min_z": min_z, "cell_size": cell, "width": w, "height": h}


func _abort(p_ctx: Dictionary) -> void:
	_running = false
	_cancel = false
	p_ctx["report"]["reason"] = "cancelled"
	print("%s: cancelled; the layer was not touched." % _sim_label())


## Hash of every pass's loops IN ORDER, plus the margin. The order is in it because reordering the
## children reorders the chain and gives a different landscape (gate AH), which a hash over an unordered
## set of footprints would call unchanged.
func _area_hash() -> String:
	if not is_inside_tree():
		return _baked_hash
	var acc := PackedFloat32Array()
	var names := ""
	for p: Pasture3DSim in passes():
		names += p.name + "|"
		for s in p._get_splines():
			for pt in p._baked_world_points(s):
				acc.append(snappedf(pt.x, 0.01))
				acc.append(snappedf(pt.z, 0.01))
	acc.append(snappedf(catchment_margin, 0.01))
	return "%s:%s" % [hash(names), hash(acc)]
