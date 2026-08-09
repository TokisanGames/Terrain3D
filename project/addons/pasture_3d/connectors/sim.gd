# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DSim — closed-loop area brush that ERODES the terrain inside its loop into a coherent
# landscape: dendritic valley networks, watersheds, ridgelines. See PASTURE3D_SIM_NODE_SPEC.md.
#
# It is a TRANSFORM, not a relief source (spec §2): it reads the surface beneath its own layer, runs a
# stream-power landscape-evolution solve over it, and writes the difference back as an ADD delta into a
# reserved "Erosion" layer. Relief materials generate fine surface texture; Sim does the thing they
# structurally cannot — large-scale drainage structure — so the two compose.
#
# The solver is Braun & Willett 2013's implicit, O(n), unconditionally stable stream-power scheme over a
# priority-flood-filled D8 routing, plus hillslope diffusion. It lives in C++ (pasture_3d_erosion.cpp);
# this file is the area, resolution, mask and layer plumbing around it. NOT the Mei pipe model — spec §1
# records at length why, and the pipe model is the wrong answer for large-surface realism.
#
# EXPLICIT BAKE ONLY (§12). `_paint_spline()` is a no-op, so Sim never runs on the brush auto-refresh
# path: moving a loop point re-runs the base class's CLEAR and empties the layer without re-simulating.
# That is deliberate, and the "area changed since the last simulation" warning is what stops it reading
# as a bug.
@tool
@icon("res://addons/pasture_3d/icons/brush_sim.svg")
class_name Pasture3DSim
extends Pasture3DTerrainBrush

## Iterations solved between yields back to the editor, so a long build stays responsive and
## cancellable. The network reorganises between iterations (§4.5), so chunking changes nothing about
## the result — chunk boundaries are just where we let go of the CPU.
const CHUNK_ITERATIONS: int = 5
## Resolution cap for the erodability map, mirroring Pasture3DPlow's height LUT. Rock hardness is a
## broad spatial field; more than this per axis buys nothing and costs a bigger per-bake image read.
const ERODABILITY_LUT_MAX: int = 256
## Smallest sim grid worth solving. Below this the boundary IS the domain and nothing routes.
const MIN_SIM_CELLS: int = 8

@export_group("Simulation")
## How many solve iterations. The drainage network REORGANISES between iterations, and that progressive
## capture is what produces dendritic structure — so 30 iterations is not one big step, and lowering
## this trades branching detail for time.
@export_range(1, 200) var iterations: int = 30:
	set(v):
		iterations = maxi(v, 1)
		update_configuration_warnings()
## K in the stream-power law (§4.3): how fast channels cut, per iteration. Incision follows upstream
## drainage area AND local slope, so this deepens the valley network rather than lowering the area
## evenly — a smooth plateau barely moves while the escarpment beside it grows gullies.
##
## NOT scale-free: the cut per iteration is K·A^m·slope, so an area with a much larger catchment erodes
## much harder at the same setting. Use Preview after any large change of area or margin.
@export_range(0.0, 1.0, 0.001, "or_greater") var erosion_rate: float = 0.08
## m in the stream-power law: how strongly incision follows catchment size. 0.45 is the literature
## value. Lower flattens the difference between a gully and a trunk valley; higher exaggerates it.
@export_range(0.0, 1.0, 0.01) var area_exponent: float = 0.45
## Hillslope diffusion D (§4.4), m² per iteration. Rounds ridges, cuts talus slopes, and supplies the
## only deposition this model has. At 0 the output is recognisably knife-edged; too much and it fills
## the channels incision cut faster than they are cut, and the area comes back SMOOTHER than it went in.
##
## Rule of thumb: it erases detail finer than roughly 7.5·√(D · Iterations) metres — so 0.15 over 30
## iterations smooths below about 16 m. The ratio against Erosion Rate is what sets how far apart the
## gullies end up.
@export_range(0.0, 10.0, 0.01, "or_greater") var hillslope_diffusion: float = 0.15

@export_group("Erodability")
## Rock softness across the area (§7): white erodes at Erodability Range's max, black at its min.
## Sampled once across the whole simulated area, the loop's oriented bounds included. Null = uniform.
@export var erodability_map: Texture2D:
	set(v):
		erodability_map = v
		update_configuration_warnings()
## What the map's 0 and 1 mean as a multiplier on the erosion rate. The default spans a factor of 8,
## which is enough for a resistant sill to visibly turn a river.
@export var erodability_range: Vector2 = Vector2(0.25, 2.0)

@export_group("Area")
## Metres of upstream catchment simulated OUTSIDE the loop (§5). Water arrives from upslope, and a loop
## boundary cuts off the catchment feeding it, so the solve runs wide and writes narrow. Cost is
## QUADRATIC in this — doubling it roughly quadruples the solve.
@export_range(0.0, 1024.0, 1.0, "or_greater") var catchment_margin: float = 128.0
## Metres from the loop edge inward over which the erosion delta fades to zero, so the eroded area
## meets untouched ground without a step.
@export var falloff_width: float = 24.0
## Optional 0→1 falloff shape (default = smoothstep).
@export var falloff_curve: Curve
## Expand (+) / contract (−) the written area off the spline, in metres.
@export var edge_offset: float = 0.0

@export_group("Resolution")
## Cell size divisor for the Preview button, relative to the terrain's vertex spacing (§6). 4 is ~16x
## cheaper than a build and is for tuning erodability, rate and iteration count — the preview is
## representative of the large-scale structure, not identical to the build.
@export_range(1, 16) var preview_resolution: int = 4:
	set(v):
		preview_resolution = maxi(v, 1)
## Cell size divisor for the Simulate button. 1 = solve at the terrain's own resolution.
@export_range(1, 16) var build_resolution: int = 1:
	set(v):
		build_resolution = maxi(v, 1)

@export_group("Bake")
## Solve at Preview Resolution and write the result. Same layer as the build, so it is visible in the
## viewport and directly comparable — just coarser.
@export_tool_button("Preview") var _preview_btn = preview_simulation
## Solve at Build Resolution and write the result. The final commit.
@export_tool_button("Simulate") var _simulate_btn = run_simulation
## Empty the Erosion layer under this node's loops, restoring the ground beneath.
@export_tool_button("Clear Simulation") var _clear_sim_btn = clear_simulation
## Abandon a solve in progress. The layer is left exactly as it was — nothing is written.
@export_tool_button("Cancel") var _cancel_btn = cancel_simulation

## Footprint hash recorded at the last successful bake, so the node can tell the user their loop has
## moved since. Empty = there is no simulation in the layer (never run, cleared, or wiped by the base
## class's auto-refresh — see _paint_into).
@export_storage var _baked_hash: String = ""
## True when the bake in the layer came from Preview rather than Simulate. Surfaced as a warning: a
## preview that is never built is the easy mistake this workflow invites.
@export_storage var _baked_preview: bool = false

## A solve is running. Blocks a second press and lets Cancel find something to cancel.
var _running: bool = false
var _cancel: bool = false
## Diffusion sub-steps the last solve actually used (§4.4). Reported when it hit the ceiling, which is
## the only way an over-large diffusion setting is visible rather than silently clamped.
var _last_substeps: int = 0


# ---- Pasture3DTerrainBrush hooks (spec §13) ------------------------------------------------------

func _default_layer_name() -> String:
	return "Erosion"


func _get_blend_mode() -> int:
	return BLEND_ADD # Sim writes a signed delta, never an absolute surface


func _min_points() -> int:
	return 3


func _spline_basename() -> String:
	return "Area"


func _padding() -> float:
	return maxf(edge_offset, 0.0) + 2.0


## Sim removes material, so the Add Water prompt must not treat an ADD-blend Sim as raising terrain.
func _raise_inverted() -> bool:
	return true


## Starter shape: a closed square loop in local space (same as Plow/Mound). Larger than theirs — a Sim
## area smaller than its own catchment margin is mostly margin.
func _make_starter_curve() -> Curve3D:
	var c := Curve3D.new()
	var r := 100.0
	c.add_point(Vector3(-r, 0.0, -r))
	c.add_point(Vector3(r, 0.0, -r))
	c.add_point(Vector3(r, 0.0, r))
	c.add_point(Vector3(-r, 0.0, r))
	return c


## §12: NO-OP, deliberately. Sim must never run on the auto-refresh path — a solve is seconds of work
## and re-running it on every spline-handle drag is exactly the editor freeze this repo has a spec
## about. The base class's paint cycle still CLEARS our footprint first, though, so a refresh empties
## the layer; record that so the configuration warning explains where the erosion went.
func _paint_spline(_path: Path3D) -> void:
	pass


## Called by the base class for every tool on the layer during a refresh — including us. We paint
## nothing (above), but by the time this runs our footprint has already been cleared, so any recorded
## bake is gone from the layer.
func _paint_into(p_layer_id: int, p_blend: int) -> void:
	super(p_layer_id, p_blend)
	if _baked_hash != "" and Engine.is_editor_hint():
		_baked_hash = ""
		update_configuration_warnings.call_deferred()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := super()
	if _baked_hash == "":
		warnings.append(("No simulation in the layer — press Simulate. (Editing a loop point clears "
			+ "the erosion: Sim is an explicit bake and never re-solves on the auto-refresh path.)"))
	elif _baked_hash != _area_hash():
		warnings.append(("The area has changed since the last simulation, so the erosion in the layer "
			+ "no longer matches this loop. Press Simulate again."))
	elif _baked_preview:
		warnings.append(("The erosion in the layer is a PREVIEW (1/%d resolution), not a build. Press "
			+ "Simulate to commit it at full resolution.") % preview_resolution)
	if erodability_range.x <= 0.0 or erodability_range.y <= 0.0:
		warnings.append("Erodability Range must be positive at both ends; a 0 multiplier stops erosion entirely.")
	if erodability_map != null and is_instance_valid(terrain) and _get_splines().is_empty():
		warnings.append("An Erodability Map is assigned but this Sim has no area to map it onto — add a loop.")
	var layer := _resolve_layer_for(_layer_owner)
	if layer != null and layer.has_method("get_blend_mode") and layer.get_blend_mode() != BLEND_ADD:
		warnings.append(("The '%s' layer's blend mode is not Add, so this Sim's delta will overwrite "
			+ "rather than erode. Give Sim its own layer, or set that layer back to Add.") % layer.get_layer_name())
	if _last_substeps >= 64:
		warnings.append(("Hillslope Diffusion is large enough that the explicit diffusion pass hit its "
			+ "sub-step ceiling, so less smoothing was applied than asked for. Lower it, or simulate at "
			+ "a coarser resolution."))
	return warnings


# ---- The buttons (spec §12) -----------------------------------------------------------------------

## Preview: solve at `preview_resolution` and write. Undoable, same as a build.
func preview_simulation() -> void:
	await _simulate_interactive(preview_resolution, true)


## Simulate: solve at `build_resolution` and write. The final commit.
func run_simulation() -> void:
	await _simulate_interactive(build_resolution, false)


## Clear Simulation: empty this node's footprint out of the Erosion layer, restoring the ground below.
## One undo step. Layer-mates inside the box are repainted, so a Mound sharing the layer survives.
func clear_simulation() -> void:
	if not is_configured():
		return
	var layer_id := _ensure_layer_for(_layer_owner, true)
	if layer_id <= 0:
		push_warning("Pasture3DSim '%s': no reserved layer to clear." % name)
		return
	_commit([], layer_id, true, "Clear")
	_baked_hash = ""
	_baked_preview = false
	update_configuration_warnings()


## Cancel: ask a running solve to stop at its next chunk boundary. Nothing has been written yet at that
## point (the whole solve completes before the layer is touched), so the terrain is simply left alone.
func cancel_simulation() -> void:
	if _running:
		_cancel = true
		print("Pasture3DSim '%s': cancelling..." % name)


# ---- The bake -------------------------------------------------------------------------------------
#
# Solve every loop to completion, THEN commit all of them as one action. The order matters: the solve
# is the slow part and the write is milliseconds, so everything slow happens before the layer is
# touched. A cancel therefore never leaves a half-eroded layer, and the undo action wraps one atomic
# write rather than a sequence interrupted by frame yields.
#
# The solve is exposed as a small state machine (_begin / _solve_chunk / _finish) rather than one
# function with an `await` in it, so there are two drivers over identical work:
#
#   simulate_now()          straight through, NOT a coroutine, so scripts and the bench gates get their
#                           report back as a Dictionary instead of a signal
#   _simulate_interactive() a frame yield between chunks, so the editor stays responsive and Cancel has
#                           somewhere to land
#
# One `await` inside a shared implementation would have made BOTH paths coroutines — which is exactly
# what happened first, and it only surfaced when a caller held a typed Pasture3DSim reference.

## Solve at `p_scale` and write, running straight through with no frame yields. Returns the report:
## {ok, reason, areas, cells, msec, substeps}. The entry point for scripts and gates.
func simulate_now(p_scale: int = 1, p_record_undo: bool = false) -> Dictionary:
	var ctx := _begin(p_scale, p_record_undo, p_scale != build_resolution)
	if not bool(ctx["ok"]):
		return ctx["report"]
	for st in ctx["states"]:
		while not _solve_chunk(st):
			pass
	return _finish(ctx)


## The button path: the same solve, yielding a frame between chunks.
func _simulate_interactive(p_scale: int, p_is_preview: bool) -> void:
	var ctx := _begin(p_scale, true, p_is_preview)
	if not bool(ctx["ok"]):
		return
	var total: int = maxi(ctx["states"].size(), 1) * maxi(iterations, 1)
	var done := 0
	for st in ctx["states"]:
		while not _solve_chunk(st):
			done = int(st["done"])
			if _cancel:
				_abort(ctx)
				return
			if not is_inside_tree() or not is_configured():
				# The node left the tree mid-solve. Writing into a terrain we are no longer attached to
				# would bake a footprint nothing owns, so abandon instead.
				_abort(ctx)
				return
			print("Pasture3DSim '%s': %d%%" % [name, int(100.0 * float(done) / float(total))])
			await get_tree().process_frame
	if _cancel:
		_abort(ctx)
		return
	_finish(ctx)


## Validate, resolve the layer, and prepare one solve state per loop. `ok` false means nothing to do
## and `report.reason` says why.
func _begin(p_scale: int, p_record_undo: bool, p_is_preview: bool) -> Dictionary:
	var report := {"ok": false, "reason": "", "areas": 0, "cells": 0, "msec": 0, "substeps": 0}
	var fail := {"ok": false, "report": report}
	if _running:
		report["reason"] = "a solve is already running"
		return fail
	if not is_configured():
		report["reason"] = "no Pasture3D terrain assigned"
		return fail
	var paintable: Array = []
	for s in _get_splines():
		if _spline_paintable(s):
			paintable.append(s)
	if paintable.is_empty():
		report["reason"] = "no loop with at least %d points" % _min_points()
		return fail
	var layer_id := _ensure_layer_for(_layer_owner, true)
	if layer_id <= 0:
		# Unlike the stamp brushes, Sim has no destructive fallback: it reads the surface BELOW its own
		# layer to stay idempotent (§13), and without a layer stack there is no "below" to read.
		report["reason"] = "the layers Tool API is unavailable, and Sim has no destructive fallback"
		push_warning("Pasture3DSim '%s': %s." % [name, report["reason"]])
		return fail

	var states: Array = []
	for path in paintable:
		var st := _prepare_solve(path, layer_id, p_scale)
		if not st.is_empty():
			states.append(st)
	if states.is_empty():
		report["reason"] = "no terrain regions under the loop(s)"
		push_warning("Pasture3DSim '%s': %s." % [name, report["reason"]])
		return fail

	_running = true
	_cancel = false
	return {"ok": true, "report": report, "states": states, "layer_id": layer_id,
			"is_preview": p_is_preview, "record_undo": p_record_undo, "t0": Time.get_ticks_msec()}


## Mask, upsample and write every solved loop, then record the bake. Returns the report.
func _finish(p_ctx: Dictionary) -> Dictionary:
	var report: Dictionary = p_ctx["report"]
	var solved: Array = []
	var cells := 0
	for st in p_ctx["states"]:
		var one := _finish_solve(st)
		if one.is_empty():
			continue
		cells += int(st["sw"]) * int(st["sh"])
		solved.append(one)
	_running = false
	if solved.is_empty():
		report["reason"] = "the masked delta was empty for every loop"
		push_warning("Pasture3DSim '%s': %s." % [name, report["reason"]])
		return report

	var is_preview: bool = p_ctx["is_preview"]
	_commit(solved, int(p_ctx["layer_id"]), bool(p_ctx["record_undo"]),
			"Preview" if is_preview else "Simulate")
	_baked_hash = _area_hash()
	_baked_preview = is_preview
	update_configuration_warnings()
	report["ok"] = true
	report["areas"] = solved.size()
	report["cells"] = cells
	report["msec"] = Time.get_ticks_msec() - int(p_ctx["t0"])
	report["substeps"] = _last_substeps
	print("Pasture3DSim '%s': %s %d area(s), %d sim cells, %d ms." % [
			name, "previewed" if is_preview else "simulated", solved.size(), cells, report["msec"]])
	return report


## Give up on a solve in progress. Nothing has been written, so there is nothing to undo.
func _abort(p_ctx: Dictionary) -> void:
	_running = false
	_cancel = false
	p_ctx["report"]["reason"] = "cancelled"
	print("Pasture3DSim '%s': cancelled; the layer was not touched." % name)


## Build one loop's solve state: the sim grid, the initial elevation, and the solver parameters.
## Returns {} when there is nothing to solve there.
##
## Idempotency (§13) lives in ONE line here: the initial elevation comes from composite_height_below,
## the surface beneath Sim's own layer. Reading the finished composite would make Sim erode its own
## erosion and creep a little further every run — the same bug class the relief selectors avoid.
func _prepare_solve(p_path: Path3D, p_layer_id: int, p_scale: int) -> Dictionary:
	var vs: float = terrain.vertex_spacing
	var poly := _polygon_xz(p_path)
	if poly.size() < 3:
		return {}

	# Write grid: the loop's own footprint, at terrain resolution.
	var wb := _snapped_bounds(_spline_footprint_aabb(p_path), vs)
	var gw := int(round((wb[1] - wb[0]) / vs)) + 1
	var gh := int(round((wb[3] - wb[2]) / vs)) + 1
	if gw < 2 or gh < 2:
		return {}

	# Sim grid: the same box grown by the catchment margin (§5 — simulate wide, write narrow). Its outer
	# edge becomes the drainage outlet, so the channels near the loop rim are fed by real upstream area
	# instead of being starved by the boundary.
	var sim_box := _spline_footprint_aabb(p_path).grow(maxf(catchment_margin, 0.0))
	var sb := _snapped_bounds(sim_box, vs)
	var tw := int(round((sb[1] - sb[0]) / vs)) + 1
	var th := int(round((sb[3] - sb[2]) / vs)) + 1
	var below: PackedFloat32Array = terrain.data.composite_height_below(p_layer_id, sb[0], sb[2], vs, tw, th)
	if below.size() != tw * th:
		return {}

	# Downsample onto the sim grid, corner-aligned so both grids span the same world rect exactly. The
	# cell size therefore comes out of the grid dimensions rather than being assumed to be vs * scale.
	var scale := maxi(p_scale, 1)
	var sw := mini(maxi(int(floor(float(tw - 1) / float(scale))) + 1, MIN_SIM_CELLS), tw)
	var sh := mini(maxi(int(floor(float(th - 1) / float(scale))) + 1, MIN_SIM_CELLS), th)
	if sw < 3 or sh < 3:
		return {}
	# The solver assumes square cells (D8 diagonal lengths, the Laplacian's 1/Δx²). The two axes differ
	# only by the rounding above, so take the mean and keep the grid honest about it.
	var sim_cell := (float(tw - 1) / float(sw - 1) + float(th - 1) / float(sh - 1)) * 0.5 * vs
	var z0: PackedFloat32Array = terrain.data.resample_grid(below, tw, th, sw, sh)
	if z0.size() != sw * sh:
		return {}

	var erod := _erodability_lut()
	return {
		"path": p_path, "poly": poly, "layer_id": p_layer_id, "vs": vs,
		"wb": wb, "sb": sb, "gw": gw, "gh": gh, "sw": sw, "sh": sh, "sim_cell": sim_cell,
		"z0": z0, "z": z0, "erod": erod[0], "done": 0, "failed": false,
		"params": {
			"gw": sw, "gh": sh, "cell_size": sim_cell,
			"time_step": 1.0,
			"erosion_rate": erosion_rate,
			"area_exponent": area_exponent,
			"diffusion": hillslope_diffusion,
			"erodability_min": erodability_range.x,
			"erodability_max": erodability_range.y,
			"erodability_w": int(erod[1]), "erodability_h": int(erod[2]),
		},
	}


## Advance one solve by up to CHUNK_ITERATIONS. Returns true when the loop is finished (or has failed).
## The solver is stateless between calls — it takes z and returns z — so N chunks of k iterations is
## exactly the same solve as one call of N*k, and where the chunk boundaries fall changes nothing.
func _solve_chunk(p_state: Dictionary) -> bool:
	var done: int = p_state["done"]
	if done >= iterations or bool(p_state["failed"]):
		return true
	var chunk := mini(CHUNK_ITERATIONS, iterations - done)
	var params: Dictionary = p_state["params"]
	params["iterations"] = chunk
	var res: Dictionary = terrain.data.erode_heightfield(p_state["z"], params, p_state["erod"])
	if not bool(res.get("ok", false)):
		push_warning(("Pasture3DSim '%s': the solver rejected the %dx%d grid — most likely no terrain "
			+ "regions under the area.") % [name, int(p_state["sw"]), int(p_state["sh"])])
		p_state["failed"] = true
		return true
	p_state["z"] = res["z"]
	_last_substeps = int(res.get("diffusion_substeps", 0))
	p_state["done"] = done + chunk
	return p_state["done"] >= iterations


## Upsample one finished solve's delta back onto the terrain grid, through the loop's falloff mask.
## Outside the mask the result is NaN, which apply_sim_block skips entirely — so the catchment margin
## is simulated over and never written (gate G).
func _finish_solve(p_state: Dictionary) -> Dictionary:
	if bool(p_state["failed"]):
		return {}
	var wb: Array = p_state["wb"]
	var sb: Array = p_state["sb"]
	var gw: int = p_state["gw"]
	var gh: int = p_state["gh"]
	var mask_params := {
		"sw": p_state["sw"], "sh": p_state["sh"], "gw": gw, "gh": gh,
		"sim_min_x": sb[0], "sim_min_z": sb[2], "sim_cell": p_state["sim_cell"],
		"min_x": wb[0], "min_z": wb[2], "vs": p_state["vs"],
		"edge_offset": edge_offset, "falloff_width": maxf(falloff_width, 0.001),
		"baseline": p_state["z0"],
	}
	var write: PackedFloat32Array = terrain.data.sim_mask_deltas(
			p_state["z"], p_state["poly"], mask_params, _ramp_lut(falloff_curve))
	if write.size() != gw * gh:
		return {}
	var path: Path3D = p_state["path"]
	return {
		"spline_id": path.get_instance_id(),
		"box": _spline_footprint_aabb(path),
		"min_x": wb[0], "min_z": wb[2], "gw": gw, "gh": gh,
		"write": write,
	}


## Write the solved deltas into the layer, as one undoable action.
##
## Mirrors the base class's dirty-rect bake (clear the box, repaint the layer-mates inside it, composite
## once, push only the touched regions) with our own contribution written through apply_sim_block
## instead of _paint_spline. An empty `p_solved` is Clear Simulation: same path, nothing of ours added.
func _commit(p_solved: Array, p_layer_id: int, p_record_undo: bool, p_action: String) -> void:
	var vs: float = terrain.vertex_spacing
	# The box: every loop we own, current and previously baked, so a shrunken loop still clears where it
	# used to reach. Grown to whole layer tiles because clear_layer_in_area drops whole tiles.
	var box := AABB()
	var have := false
	for a: AABB in _own_footprints():
		box = a if not have else box.merge(a)
		have = true
	if not have:
		return
	var clip_box := _snap_aabb_to_tiles(box, _layer_tile_world(p_layer_id))

	var ur: EditorUndoRedoManager = _editor_undo() if p_record_undo else null
	var before: Dictionary = _snapshot_owner(_layer_owner) if ur != null else {}

	_clear_region_edited_flags()
	terrain.data.clear_layer_in_area(p_layer_id, clip_box)
	# Layer-mates first: a Mound sharing the Erosion layer must survive our clear. They paint deferred
	# and clipped, exactly as they do in the base class's partial bake.
	var blend := _layer_blend_for(p_layer_id)
	for s in _tools_on_owner(_layer_owner):
		if s == self or not s._overlaps_box(clip_box):
			continue
		s._clip_aabb = clip_box
		s._defer_composite = true
		s._paint_into(p_layer_id, blend)
		s._defer_composite = false
		s._clip_aabb = AABB()
	_last_paint_aabb.clear()
	for e in p_solved:
		terrain.data.apply_sim_block(p_layer_id, e["min_x"], e["min_z"], vs, e["gw"], e["gh"], e["write"], BLEND_ADD)
		_last_paint_aabb[e["spline_id"]] = e["box"]
	terrain.data.composite_area(clip_box, false)
	terrain.data.update_maps(_map_type(), false, false)
	update_gizmos()

	if ur != null:
		var after := _snapshot_owner(_layer_owner)
		ur.create_action("Pasture3D Sim %s" % p_action)
		ur.add_do_method(self, "_restore_owner", _layer_owner, after)
		ur.add_undo_method(self, "_restore_owner", _layer_owner, before)
		ur.commit_action(false)

	_emit_baked(_tools_on_owner(_layer_owner).filter(func(s): return s._overlaps_box(clip_box)))


# ---- Inputs ---------------------------------------------------------------------------------------

## Loop projected to world XZ and decimated to ~terrain resolution (same as Plow/Mound: the raw Curve3D
## bake is ~5x finer than the grid and would only make the mask's scanline fill slower).
func _polygon_xz(p_path: Path3D) -> PackedVector2Array:
	var raw := PackedVector2Array()
	for p in _baked_world_points(p_path):
		raw.append(Vector2(p.x, p.z))
	return _decimate(raw, maxf(terrain.vertex_spacing, 0.25))


## The erodability map as a [0,1] LUT: [PackedFloat32Array data, w, h]. [empty, 0, 0] when no map is
## assigned, which the solver reads as uniform 1.0. Capped in resolution like Plow's height LUT.
func _erodability_lut() -> Array:
	var empty: Array = [PackedFloat32Array(), 0, 0]
	if erodability_map == null:
		return empty
	var img := erodability_map.get_image()
	if img == null:
		push_warning("Pasture3DSim '%s': the Erodability Map has no image data; using uniform erodability." % name)
		return empty
	img = img.duplicate() # never mutate the shared resource image
	if img.is_compressed() and img.decompress() != OK:
		push_warning("Pasture3DSim '%s': could not decompress the Erodability Map; using uniform erodability." % name)
		return empty
	if img.has_mipmaps():
		img.clear_mipmaps()
	var w := img.get_width()
	var h := img.get_height()
	if maxi(w, h) > ERODABILITY_LUT_MAX:
		var s := float(ERODABILITY_LUT_MAX) / float(maxi(w, h))
		w = maxi(1, int(round(w * s)))
		h = maxi(1, int(round(h * s)))
		img.resize(w, h, Image.INTERPOLATE_BILINEAR)
	if w < 2 or h < 2:
		return empty
	var data := PackedFloat32Array()
	data.resize(w * h)
	for y in range(h):
		var row := y * w
		for x in range(w):
			data[row + x] = img.get_pixel(x, y).get_luminance()
	return [data, w, h]


## Hash of every loop's world footprint (§12). Compared against the one recorded at bake time so the
## node can say "the area changed since the last simulation" instead of showing stale erosion silently.
## Rounded to a centimetre: float noise in a Curve3D bake must not read as the user having moved a point.
func _area_hash() -> String:
	if not is_inside_tree():
		return _baked_hash
	var acc := PackedFloat32Array()
	for s in _get_splines():
		for p in _baked_world_points(s):
			acc.append(snappedf(p.x, 0.01))
			acc.append(snappedf(p.z, 0.01))
	acc.append(snappedf(catchment_margin, 0.01)) # changes what was simulated, not just where it landed
	return str(hash(acc))
