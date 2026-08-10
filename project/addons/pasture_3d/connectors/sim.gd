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
# It has a SECOND output: a Pasture3DSimResult holding flow, erosion, deposition and wetness over the
# simulated area at sim resolution (§8.2), rewritten on every Preview and Simulate so it always matches
# the erosion in the layer. Nothing in the solve ever reads it back — Sim's input is always the surface
# below its own layer, which is what keeps a re-run idempotent (§13).
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
## Ceiling on the merged Pasture3DSimResult grid when a Sim has SEVERAL loops (§8.2). One loop always
## gets its own grid verbatim — that memory was already allocated to solve it. Several loops far apart
## span a union box far larger than what was solved, and four float channels over it would be the
## largest thing this node ever allocates, so the merge coarsens to fit and says so.
const RESULT_MAX_CELLS: int = 4194304

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

@export_group("Masking")
## Where this Sim is allowed to erode, gated on what the ground is already doing (§17). The same
## Pasture3DReliefSelector the Plow and Mound relief materials use, so a `SLOPE 30-90` band means here
## exactly what it means there: steepness in degrees, altitude in metres, curvature, or one of the four
## sim channels out of another Sim's masks.
##
## Selectors MULTIPLY. Two of them gate the intersection — "steep AND above the treeline" — and one with
## Strength 0 drops out of the product, so it is a free way to disable one without deleting it. The result
## multiplies the Erodability Map as well, if there is one, rather than replacing it.
##
## This gates the SOLVE: masked-out ground still routes water and still receives sediment, it just resists
## incision. Empty = erode everywhere, exactly as before this existed.
@export var erosion_mask: Array[Pasture3DReliefSelector] = []:
	set(v):
		erosion_mask = v
		update_configuration_warnings()
		_update_mask_preview()
## Where this Sim is allowed to WRITE what it solved (§17.3). Read the same way as Erosion Mask, and the
## difference matters: this one does not touch the solve at all, so the drainage network is computed over
## the whole area and stays continuous — only the delta that reaches the layer is gated.
##
## That is how you keep the gullies on one face of a hill without the water re-routing around the part you
## excluded. Multiplies the loop's own edge falloff. Empty = write everything inside the loop.
@export var write_mask: Array[Pasture3DReliefSelector] = []:
	set(v):
		write_mask = v
		update_configuration_warnings()
		_update_mask_preview()
## Tint the terrain red where the chosen mask passes, live, so a band can be tuned by eye instead of by
## simulating and inspecting (§18). The overlay is editor-only and writes nothing — turning it off leaves
## no trace.
##
## An enum rather than two checkboxes because there is ONE set of preview uniforms on the terrain
## material: only one mask, on one brush, can be shown at a time. Turning this on anywhere takes the
## overlay away from whatever had it.
@export_enum("Off", "Erosion Mask", "Write Mask") var mask_preview: int = 0:
	set(v):
		mask_preview = v
		_update_mask_preview()

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

@export_group("Masks")
## Where this Sim writes its drainage masks (§8.2): flow, erosion, deposition and wetness, over the
## SIMULATED area (the loop plus its catchment margin) at SIM resolution. Rewritten on every Preview and
## every Simulate, so it always describes the erosion currently in the layer.
##
## Leave it empty and one is created on the first bake. SAVE IT TO A .res: an unsaved resource is stored
## inside the scene file, and these are megabytes of float data. Phase 3's selector Kinds read this
## resource, so it is also the thing you point them at.
@export var sim_result: Pasture3DSimResult:
	set(v):
		sim_result = v
		update_configuration_warnings()

@export_group("Water Features")
## Upstream catchment a cell must drain before it counts as a river, in SQUARE METRES (§10.1). An area
## rather than an arbitrary flow number: "everything with more than half a hectare above it" is a
## statement about the landscape, and it means the same thing at any sim resolution.
##
## Lower it for a denser network of small streams; raise it to keep only the trunk valleys.
@export_range(100.0, 1000000.0, 100.0, "or_greater") var river_area_threshold: float = 5000.0
## Segments shorter than this are dropped, in metres. A drainage network has a great many one-cell stubs
## where two channels meet, and every one of them would otherwise become a Trough.
@export_range(0.0, 500.0, 1.0, "or_greater") var min_river_length: float = 40.0
## How far a simplified spline may stray from the traced channel, in metres. The raw path is one point
## per cell, which is far more than a Curve3D needs and unusable to edit by hand.
@export_range(0.1, 32.0, 0.1, "or_greater") var curve_tolerance: float = 2.0
## Standing water shallower than this is not a lake, in metres. The depression fill leaves a film over
## any cell that is even slightly below its outlet, and without a floor every one becomes a Pond.
@export_range(0.0, 20.0, 0.05, "or_greater") var lake_depth_threshold: float = 0.5
## Smallest basin worth a Pond, in square metres.
@export_range(0.0, 100000.0, 10.0, "or_greater") var min_lake_area: float = 400.0
## Width of the biggest generated river, in metres. Every segment is scaled from this by the square root
## of its catchment (§10.1), so tributaries come out narrower than the trunk they join.
@export_range(1.0, 200.0, 0.5, "or_greater") var river_width_max: float = 14.0
## Width of the smallest, in metres — the floor of that scaling, so a headwater stream is still a stream.
@export_range(0.5, 100.0, 0.5, "or_greater") var river_width_min: float = 3.0
## How deep a generated Trough cuts, in metres. Near zero on purpose (§10.3): the sim ALREADY carved the
## channel, so the Trough is here to host the water surface and give you an editable spline. Raise it
## only if you want the river cut deeper than the erosion left it.
@export_range(0.0, 20.0, 0.05, "or_greater") var river_carve_depth: float = 0.25

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
## Count the rivers and lakes the current thresholds would produce, without creating anything (§10.4).
@export_tool_button("Preview Water Features") var _preview_water_btn = preview_water_features
## Replace this Sim's generated Ponds and Troughs with a fresh set from the current thresholds.
@export_tool_button("Add Brushes") var _add_brushes_btn = add_brushes
## Remove every brush this Sim generated, edited or not.
@export_tool_button("Clear Brushes") var _clear_brushes_btn = clear_brushes

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
	warnings.append_array(_mask_warnings(erosion_mask, "Erosion Mask"))
	warnings.append_array(_mask_warnings(write_mask, "Write Mask"))
	var layer := _resolve_layer_for(_layer_owner)
	if layer != null and layer.has_method("get_blend_mode") and layer.get_blend_mode() != BLEND_ADD:
		warnings.append(("The '%s' layer's blend mode is not Add, so this Sim's delta will overwrite "
			+ "rather than erode. Give Sim its own layer, or set that layer back to Add.") % layer.get_layer_name())
	if _last_substeps >= 64:
		warnings.append(("Hillslope Diffusion is large enough that the explicit diffusion pass hit its "
			+ "sub-step ceiling, so less smoothing was applied than asked for. Lower it, or simulate at "
			+ "a coarser resolution."))
	if sim_result != null:
		# An unsaved Resource is serialised INTO the scene file. For four float channels over a sim grid
		# that is megabytes of base64 in a .tscn, and it stops the masks being diffable or deletable
		# separately, which is the whole point of §2's "one .res per Sim node".
		if sim_result.resource_path == "" or sim_result.resource_path.contains("::"):
			warnings.append(("The Sim Result masks have no file of their own, so they will be saved "
				+ "inside this scene — megabytes of float data. Save the resource to a .res next to your "
				+ "terrain data."))
		elif sim_result.source_area_hash != "" and _baked_hash != "" and sim_result.source_area_hash != _baked_hash:
			warnings.append(("The Sim Result masks were not written by this Sim's last bake, so they "
				+ "describe a different area. Press Simulate to rewrite them."))
	# §15 open question 7: two Sims sharing a layer wipe each other, because baking one clears the shared
	# layer's tiles under its box and a Sim cannot be repainted from its spline (§12). The check needs the
	# TILE-snapped box, not the loops — the clear drops whole tiles, so two loops 40 m apart still collide.
	if _water_preview != "":
		warnings.append("Water features: %s." % _water_preview)
	if river_width_min > river_width_max:
		warnings.append("River Width Min is greater than River Width Max, so every generated river "
			+ "comes out at the maximum width.")
	var mate := _overlapping_sim_on_layer()
	if mate != "":
		warnings.append(("The Sim '%s' shares this Sim's layer and its area is close enough that baking "
			+ "either one clears the other's erosion (whole layer tiles are dropped, so 'close' means "
			+ "within about a tile, not merely overlapping). Give each Sim its own layer.") % mate)
	return warnings


## Name of another Pasture3DSim on the same layer whose tile-snapped footprint touches ours, or "".
func _overlapping_sim_on_layer() -> String:
	if not is_inside_tree() or not is_configured():
		return ""
	var layer := _resolve_layer_for(_layer_owner)
	if layer == null:
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
		if s == self or not (s is Pasture3DSim):
			continue
		for b: AABB in s._own_footprints():
			if _snap_aabb_to_tiles(b, step).intersects(mine):
				return s.name
	return ""


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
	# The masks describe the erosion that was in the layer, and there is none now. Emptying them (and
	# the .res, if they have one) is the point: a mask file left describing erosion the terrain no
	# longer has is exactly the silent staleness §8.2 exists to avoid. NOTE the height clear is undoable
	# and this is not — Ctrl+Z brings the erosion back and leaves the masks empty, which the "not written
	# by this Sim's last bake" warning then reports.
	_empty_result()
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
	var report := {"ok": false, "reason": "", "areas": 0, "cells": 0, "msec": 0, "substeps": 0, "masks": ""}
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
			"is_preview": p_is_preview, "record_undo": p_record_undo, "scale": maxi(p_scale, 1),
			"t0": Time.get_ticks_msec()}


## Mask, upsample and write every solved loop, then record the bake. Returns the report.
func _finish(p_ctx: Dictionary) -> Dictionary:
	var report: Dictionary = p_ctx["report"]
	var solved: Array = []
	var written: Array = []
	var cells := 0
	for st in p_ctx["states"]:
		var one := _finish_solve(st)
		if one.is_empty():
			continue
		cells += int(st["sw"]) * int(st["sh"])
		solved.append(one)
		written.append(st)
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
	# The masks go last, so they can record the hash of the bake that just landed. A Preview overwrites a
	# build's masks exactly as it overwrites a build's height — the result always describes what is in the
	# layer — and source_preview is how a reader tells which it got.
	report["masks"] = _write_result(written, is_preview, int(p_ctx["scale"]))
	update_configuration_warnings()
	report["ok"] = true
	report["areas"] = solved.size()
	report["cells"] = cells
	report["msec"] = Time.get_ticks_msec() - int(p_ctx["t0"])
	report["substeps"] = _last_substeps
	print("Pasture3DSim '%s': %s %d area(s), %d sim cells, %d ms.%s" % [
			name, "previewed" if is_preview else "simulated", solved.size(), cells, report["msec"],
			"\n  " + str(report["masks"]) if report["masks"] != "" else ""])
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
	var e_field: PackedFloat32Array = erod[0]
	var e_w := int(erod[1])
	var e_h := int(erod[2])
	var e_lo := erodability_range.x
	var e_hi := erodability_range.y
	# §17: with a mask stack present, the WHOLE per-cell field — the texture mapped through the range,
	# times the selector product — is composed in C++ at sim resolution and handed to the solver already
	# mapped, so the range travelling with it becomes the identity. With an empty stack the texture path
	# below is untouched, which is what keeps an unmasked Sim bitwise identical to phase 4 and what makes
	# "clear the masks" a usable control for every §17.8 criterion.
	var sel := _selector_block(erosion_mask)
	if not sel.is_empty():
		var field: PackedFloat32Array = terrain.data.selector_mask_field(z0, {
				"gw": sw, "gh": sh, "cell_size": sim_cell, "min_x": sb[0], "min_z": sb[2],
				"erodability_lut": e_field, "erodability_w": e_w, "erodability_h": e_h,
				"erodability_min": e_lo, "erodability_max": e_hi,
			}, sel, _mask_sim_dict(erosion_mask))
		if field.size() == sw * sh:
			e_field = field
			e_w = sw
			e_h = sh
			e_lo = 0.0
			e_hi = 1.0
		else:
			push_warning(("Pasture3DSim '%s': the erosion mask field could not be built for this area, so "
				+ "it eroded UNMASKED. Nothing was silently gated.") % name)
	return {
		"path": p_path, "poly": poly, "layer_id": p_layer_id, "vs": vs,
		"wb": wb, "sb": sb, "gw": gw, "gh": gh, "sw": sw, "sh": sh, "sim_cell": sim_cell,
		"z0": z0, "z": z0, "erod": e_field, "done": 0, "failed": false,
		"params": {
			"gw": sw, "gh": sh, "cell_size": sim_cell,
			"time_step": 1.0,
			"erosion_rate": erosion_rate,
			"area_exponent": area_exponent,
			"diffusion": hillslope_diffusion,
			"erodability_min": e_lo,
			"erodability_max": e_hi,
			"erodability_w": e_w, "erodability_h": e_h,
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
	# NOTE want_diagnostics is deliberately never set here. It copies five full-grid arrays out of the
	# solver, and a chunked build would pay that on every chunk for four fields it throws away. The
	# masks come from one routing-only pass over the FINAL surface instead — see _finish_solve.
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
	_diagnose(p_state)
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
	# §17.3: the write mask reads the SAME below-layer surface the erosion mask does, not the eroded
	# result. Gating on the ground you started from is what an artist means by "only the north face", and
	# it is what keeps the gate idempotent — a mask read off the solve would move with its own output.
	var wsel := _selector_block(write_mask)
	if not wsel.is_empty():
		var wfield: PackedFloat32Array = terrain.data.selector_mask_field(p_state["z0"], {
				"gw": p_state["sw"], "gh": p_state["sh"], "cell_size": p_state["sim_cell"],
				"min_x": sb[0], "min_z": sb[2],
			}, wsel, _mask_sim_dict(write_mask))
		if wfield.size() == int(p_state["sw"]) * int(p_state["sh"]):
			mask_params["write_mask"] = wfield
		else:
			push_warning(("Pasture3DSim '%s': the write mask field could not be built for this area, so "
				+ "the whole solved delta was written.") % name)
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


## Route and fill the FINAL surface once more, for its drainage area and standing water (§8.2).
##
## Deliberately a separate zero-iteration pass rather than diagnostics off the last solve chunk. The
## solver's flow and lake_depth are built at the TOP of an iteration, so taking them from the last chunk
## would describe the network of the surface before that iteration's incision and diffusion — a mask
## that is one iteration out of step with the height it is shipped beside. `iterations: 0` is exactly the
## routing-only mode the solver already has: it fills, routes and accumulates, and returns z untouched.
## Costs one fill+route (a thirtieth of a default solve) and leaves the chunked path free of diagnostics.
func _diagnose(p_state: Dictionary) -> bool:
	var params: Dictionary = p_state["params"].duplicate()
	params["iterations"] = 0
	params["want_diagnostics"] = true
	var res: Dictionary = terrain.data.erode_heightfield(p_state["z"], params, p_state["erod"])
	if not bool(res.get("ok", false)):
		push_warning("Pasture3DSim '%s': the diagnostics pass failed; this area contributes no masks." % name)
		return false
	p_state["flow"] = res["flow"]
	p_state["lake"] = res["lake_depth"]
	return true


## The grid the masks are merged onto (§8.2).
##
## ONE loop — the overwhelmingly common case — gets its own sim grid verbatim, so the result is the field
## the solver produced with no resampling at all. SEVERAL loops get the union of their simulated boxes at
## the mean sim cell size, and each loop is resampled onto it; where two loops overlap, a cell inside a
## loop's write area beats one that another loop merely simulated as margin (the C++ side's precedence
## rule). Coarsened if the union would be larger than RESULT_MAX_CELLS, which two distant loops can
## easily ask for.
func _result_target(p_states: Array) -> Dictionary:
	if p_states.size() == 1:
		var st: Dictionary = p_states[0]
		var sb1: Array = st["sb"]
		return {"min_x": sb1[0], "min_z": sb1[2], "cell_size": st["sim_cell"],
				"width": st["sw"], "height": st["sh"]}
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	var cell := 0.0
	for st: Dictionary in p_states:
		var sb: Array = st["sb"]
		min_x = minf(min_x, sb[0])
		max_x = maxf(max_x, sb[1])
		min_z = minf(min_z, sb[2])
		max_z = maxf(max_z, sb[3])
		cell += float(st["sim_cell"])
	cell = maxf(cell / float(p_states.size()), 0.001)
	var w := int(round((max_x - min_x) / cell)) + 1
	var h := int(round((max_z - min_z) / cell)) + 1
	if w * h > RESULT_MAX_CELLS:
		var s := sqrt(float(w) * float(h) / float(RESULT_MAX_CELLS))
		cell *= s
		w = int(round((max_x - min_x) / cell)) + 1
		h = int(round((max_z - min_z) / cell)) + 1
		push_warning(("Pasture3DSim '%s': the %d loops span too large a box to hold their masks at sim "
			+ "resolution, so the Sim Result is %.2f m per cell (%.1fx coarser than the solve). Use one "
			+ "Sim node per area if the masks need to be sharp.") % [name, p_states.size(), cell, s])
	return {"min_x": min_x, "min_z": min_z, "cell_size": cell, "width": w, "height": h}


## Build the four §8.2 channels from every solved loop and store them in `sim_result`, creating the
## resource if there is none and saving it when it has a file of its own. Returns a one-line description
## for the bake report, or "" when nothing was written.
##
## What goes in is the UNMASKED sim-resolution field: the loop's falloff and the write mask are not
## applied. The masks describe the SIMULATION, not the write — the catchment margin's flow and incision
## are real numbers about real water, and they are what a selector near the loop rim needs. Multiplying
## the falloff into them would bake the ramp's shape into data phase 3 reads as geology.
func _write_result(p_states: Array, p_is_preview: bool, p_scale: int) -> String:
	# A new solve moves the channels, so any overlay on screen now describes the previous one.
	_clear_water_overlay()
	var parts: Array = []
	for st: Dictionary in p_states:
		if not st.has("flow"):
			continue
		var sb: Array = st["sb"]
		var wb: Array = st["wb"]
		parts.append({
			"sw": st["sw"], "sh": st["sh"], "cell": st["sim_cell"],
			"min_x": sb[0], "min_z": sb[2],
			"z0": st["z0"], "z1": st["z"], "flow": st["flow"], "lake": st["lake"],
			"write_min_x": wb[0], "write_max_x": wb[1], "write_min_z": wb[2], "write_max_z": wb[3],
		})
	if parts.is_empty():
		return ""
	var target := _result_target(p_states)
	var built: Dictionary = terrain.data.sim_result_build(parts, target)
	if not bool(built.get("ok", false)):
		push_warning("Pasture3DSim '%s': the masks could not be built for this bake." % name)
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
	r.source_iterations = iterations
	r.source_erosion_rate = erosion_rate
	r.source_area_exponent = area_exponent
	r.source_diffusion = hillslope_diffusion
	r.source_catchment_margin = catchment_margin
	r.source_area_hash = _area_hash()
	r.source_time = Time.get_datetime_string_from_system(true, true)
	r.source_loops = int(built.get("parts", parts.size()))
	r.emit_changed()
	_save_result(r)
	return r.describe()


## Empty the masks in place, so a mask can never outlive the erosion it describes (Clear Simulation).
func _empty_result() -> void:
	_clear_water_overlay()
	if sim_result == null:
		return
	sim_result.width = 0
	sim_result.height = 0
	sim_result.flow = PackedFloat32Array()
	sim_result.erosion = PackedFloat32Array()
	sim_result.deposition = PackedFloat32Array()
	sim_result.wetness = PackedFloat32Array()
	sim_result.source_area_hash = ""
	sim_result.source_loops = 0
	sim_result.source_time = Time.get_datetime_string_from_system(true, true)
	sim_result.emit_changed()
	_save_result(sim_result)


## Write the masks back to their own .res, if they have one. A resource with no path (or a path inside a
## scene, "…::N") is left alone — the scene serialiser owns it, and the node warns about that separately.
func _save_result(p_result: Pasture3DSimResult) -> void:
	var path: String = p_result.resource_path
	if path == "" or path.contains("::"):
		return
	var err := ResourceSaver.save(p_result, path)
	if err != OK:
		push_warning("Pasture3DSim '%s': could not save the masks to %s (error %d)." % [name, path, err])
	else:
		print("Pasture3DSim '%s': masks written to %s." % [name, path])


# ---- Water features (spec §10) --------------------------------------------------------------------
#
# The workflow: iterate on the sim, like the result, one click makes editable Ponds and Troughs, need to
# re-sim, clear them, repeat. Authored ponds and rivers are never touched.
#
# Extraction runs off the MASKS, not off a live solve, so Add Brushes works whenever — after a reload,
# without re-simulating, and without the multi-second cost of the solver. The eroded surface is
# reconstructed exactly (see _eroded_surface), routed once in C++, and the drainage tree that comes out
# is the same forest the sim built.

## Marker meta every generated node carries. §10.4 asks for a stored-but-hidden flag; metadata IS that,
## and it needs no new exported property on Trough or Pond — which matters, because those two are
## ordinary brushes that know nothing about the sim and should stay that way.
const GENERATED_META := "_generated_by_sim"

## Where a freshly built brush belongs, in WORLD space, stamped by _make_trough / _make_pond and consumed
## by the first _attach_generated. The extractor works in world coordinates but a Curve3D's points are
## LOCAL to its Path3D, so a generated brush parented under a Sim that is not at the origin lands offset
## by the Sim's transform unless something places it. This is that something.
##
## One-shot on purpose: it is removed the moment it is used, so the undo/redo re-attach path — which runs
## the same _attach_generated over the same node instance — leaves a brush the user has since dragged
## exactly where they dragged it.
const PLACE_META := "_generated_place_at"

## Read-only summary from the last Preview Water Features, shown as a configuration warning.
@export_storage var _water_preview: String = ""

## The overlay Preview Water Features draws. Held rather than looked up so it can never be confused with
## a user's own child, and rebuilt from scratch on every press.
var _water_overlay: MeshInstance3D = null


## Preview: show what the current thresholds would produce, and create nothing (§10.4).
##
## "Create nothing" means create no BRUSHES. It drew nothing at all in its first version, which made the
## button indistinguishable from a broken one: the only feedback was a line in the Output dock and a
## configuration-warning string, neither of which is where you are looking while tuning a threshold. The
## overlay below is what makes this a preview rather than a report — thresholds are the one part of this
## workflow you tune by eye, and the whole reason for the button is to do that without generating and
## deleting brushes each time.
func preview_water_features() -> Dictionary:
	_clear_water_overlay()
	var w := extract_water()
	if not bool(w.get("ok", false)):
		_water_preview = ""
		push_warning("Pasture3DSim '%s': %s." % [name, w.get("reason", "extraction failed")])
		update_configuration_warnings()
		return w
	var rivers: Array = w["rivers"]
	var lakes: Array = w["lakes"]
	_draw_water_overlay(rivers, lakes)
	_water_preview = "%d lake(s), %d river segment(s) at the current thresholds" % [lakes.size(), rivers.size()]
	print("Pasture3DSim '%s': %s (%d channel cells, %d flooded cells)." % [
			name, _water_preview, int(w.get("channel_cells", 0)), int(w.get("lake_cells", 0))])
	update_configuration_warnings()
	return w


## Marker on the overlay node, so a script reload that drops `_water_overlay` cannot leave an orphan
## line network in the scene that nothing owns and no button can remove.
const OVERLAY_META := "_sim_water_overlay"
## Rivers read as flowing water, lakes as standing water. Both are lifted clear of the ground: the line
## describing a channel the sim just carved would otherwise z-fight with the channel itself.
const OVERLAY_RIVER := Color(0.25, 0.72, 1.0)
const OVERLAY_LAKE := Color(0.35, 1.0, 0.70)
const OVERLAY_LIFT := 0.4


## Remove the preview overlay, by marker rather than by the held reference alone.
func _clear_water_overlay() -> void:
	_water_overlay = null
	for c in get_children():
		if c.has_meta(OVERLAY_META):
			remove_child(c)
			c.queue_free()


## One unshaded line strip per river link and per shoreline, in this node's local space (the overlay is
## our child, so it inherits our transform — the same conversion the generated brushes need, done here
## against `global_transform` instead of at attach time).
##
## Deliberately not owned by the edited scene: it must never save, never appear in the Scene dock, and
## never survive a reload as something the user has to find and delete.
func _draw_water_overlay(p_rivers: Array, p_lakes: Array) -> void:
	if p_rivers.is_empty() and p_lakes.is_empty():
		return
	var mesh := ImmediateMesh.new()
	var inv := global_transform.affine_inverse()
	for seg: Dictionary in p_rivers:
		_overlay_line(mesh, seg["points"], inv, OVERLAY_RIVER, false)
	for lake: Dictionary in p_lakes:
		_overlay_line(mesh, lake["contour"], inv, OVERLAY_LAKE, true)
	if mesh.get_surface_count() == 0:
		return
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = true # the whole network at once, including the parts behind a ridge
	mat.disable_fog = true
	_water_overlay = MeshInstance3D.new()
	_water_overlay.name = "WaterPreview"
	_water_overlay.set_meta(OVERLAY_META, true)
	_water_overlay.set_meta(INTERNAL_CHILD_META, true) # a preview must never re-bake the layer
	_water_overlay.mesh = mesh
	_water_overlay.material_override = mat
	add_child(_water_overlay)


func _overlay_line(p_mesh: ImmediateMesh, p_pts: PackedVector3Array, p_inv: Transform3D,
		p_color: Color, p_closed: bool) -> void:
	if p_pts.size() < 2:
		return
	var lift := Vector3(0.0, OVERLAY_LIFT, 0.0)
	p_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	p_mesh.surface_set_color(p_color)
	for p in p_pts:
		p_mesh.surface_add_vertex(p_inv * (p + lift))
	if p_closed:
		p_mesh.surface_add_vertex(p_inv * (p_pts[0] + lift))
	p_mesh.surface_end()


## Trace the drainage tree and the depression fill into polylines and shorelines. Pure analysis — this
## creates no nodes and touches no layer. Returns the C++ payload plus `ok` / `reason`.
func extract_water() -> Dictionary:
	var fail := {"ok": false, "reason": "", "rivers": [], "lakes": []}
	if not is_configured():
		fail["reason"] = "no Pasture3D terrain assigned"
		return fail
	var surf := _eroded_surface()
	if not bool(surf["ok"]):
		fail["reason"] = surf["reason"]
		return fail
	var res: Dictionary = terrain.data.sim_extract_water(surf["z"], {
		"gw": surf["gw"], "gh": surf["gh"], "cell_size": surf["cell"],
		"min_x": surf["min_x"], "min_z": surf["min_z"],
		"river_area_threshold": river_area_threshold,
		"min_river_length": min_river_length,
		"curve_tolerance": curve_tolerance,
		"lake_depth_threshold": lake_depth_threshold,
		"min_lake_area": min_lake_area,
		"lake_depth_percentile": 0.9,
	})
	if not bool(res.get("ok", false)):
		fail["reason"] = "the extractor rejected the %dx%d grid" % [int(surf["gw"]), int(surf["gh"])]
		return fail
	res["reason"] = ""
	return _clip_to_write_area(res)


## Cut the extracted network down to the area this Sim actually WRITES.
##
## §5 is simulate wide, write narrow: the solve runs over the loop plus its catchment margin so the
## channels near the rim are fed by real upstream area, and §8.2 stores the masks over that whole
## simulated extent. Extraction reads the masks, so without this it happily returns rivers and lakes out
## in the margin — drainage that is real in the solve and *absent from the terrain*, because the margin
## was never written. A Trough there carves virgin ground outside the area the user drew, which is how
## this was found.
##
## Rivers are TRIMMED at the boundary rather than dropped, so a trunk leaving the area still reaches the
## edge, and each surviving run is re-tested against `min_river_length` — a clipped stub is still a stub.
## Lakes must be entirely inside: a Pond is one closed loop with no way to express a clipped shore, and
## half a lake carved past the boundary is the exact thing this function exists to prevent.
func _clip_to_write_area(p_w: Dictionary) -> Dictionary:
	var polys := _write_polygons()
	if polys.is_empty():
		return p_w
	var rivers: Array = []
	for seg: Dictionary in (p_w.get("rivers", []) as Array):
		rivers.append_array(_clip_polyline(seg["points"], seg["areas"], polys))
	var lakes: Array = []
	for lake: Dictionary in (p_w.get("lakes", []) as Array):
		if _contour_inside(lake["contour"], polys):
			lakes.append(lake)
	p_w["rivers_before_clip"] = (p_w.get("rivers", []) as Array).size()
	p_w["lakes_before_clip"] = (p_w.get("lakes", []) as Array).size()
	p_w["rivers"] = rivers
	p_w["lakes"] = lakes
	return p_w


## This Sim's loops as world-XZ polygons — the same ones the bake masks with, grown by `edge_offset` so
## the clip follows the written edge and not the spline when those differ.
func _write_polygons() -> Array:
	var out: Array = []
	for s in _get_splines():
		var poly := _polygon_xz(s)
		if poly.size() < 3:
			continue
		if is_zero_approx(edge_offset):
			out.append(poly)
		else:
			out.append_array(Geometry2D.offset_polygon(poly, edge_offset))
	return out


func _inside_write_area(p_polys: Array, p_p: Vector3) -> bool:
	var v := Vector2(p_p.x, p_p.z)
	for poly: PackedVector2Array in p_polys:
		if Geometry2D.is_point_in_polygon(v, poly):
			return true
	return false


func _contour_inside(p_contour: PackedVector3Array, p_polys: Array) -> bool:
	for p in p_contour:
		if not _inside_write_area(p_polys, p):
			return false
	return true


## Split one extracted link into the runs of it that lie inside the write area, each still carrying its
## own upstream-area samples so the width curve survives the cut.
func _clip_polyline(p_pts: PackedVector3Array, p_areas: PackedFloat32Array, p_polys: Array) -> Array:
	var out: Array = []
	var cur := PackedVector3Array()
	var cur_a := PackedFloat32Array()
	var prev_in := false
	var prev_a := 0.0
	for i in range(p_pts.size()):
		var p: Vector3 = p_pts[i]
		var a: float = p_areas[i] if i < p_areas.size() else 0.0
		var here := _inside_write_area(p_polys, p)
		if i > 0 and here != prev_in:
			# The crossing itself, so a river reaches the edge instead of stopping at the last vertex the
			# simplification happened to leave inside.
			var t := _boundary_t(p_polys, p_pts[i - 1], p)
			cur.append(p_pts[i - 1].lerp(p, t))
			cur_a.append(lerpf(prev_a, a, t))
		if here:
			cur.append(p)
			cur_a.append(a)
		elif prev_in:
			_flush_run(out, cur, cur_a)
			cur = PackedVector3Array()
			cur_a = PackedFloat32Array()
		prev_in = here
		prev_a = a
	_flush_run(out, cur, cur_a)
	return out


func _flush_run(p_out: Array, p_pts: PackedVector3Array, p_areas: PackedFloat32Array) -> void:
	if p_pts.size() < 2:
		return
	var length := 0.0
	for i in range(1, p_pts.size()):
		length += Vector2(p_pts[i].x, p_pts[i].z).distance_to(Vector2(p_pts[i - 1].x, p_pts[i - 1].z))
	if length < min_river_length:
		return
	p_out.append({"points": p_pts, "areas": p_areas, "length": length})


## Where along a→b the write boundary is crossed, as a 0..1 parameter. Falls back to the inside end when
## no edge intersection is found, which keeps a numerical miss conservative rather than letting a river
## run past the boundary.
func _boundary_t(p_polys: Array, p_a: Vector3, p_b: Vector3) -> float:
	var a2 := Vector2(p_a.x, p_a.z)
	var b2 := Vector2(p_b.x, p_b.z)
	var span := a2.distance_to(b2)
	if span <= 0.0:
		return 0.0
	var best := INF
	for poly: PackedVector2Array in p_polys:
		var n := poly.size()
		for i in range(n):
			var hit = Geometry2D.segment_intersects_segment(a2, b2, poly[i], poly[(i + 1) % n])
			if hit != null:
				best = minf(best, a2.distance_to(hit) / span)
	if best == INF:
		return 0.0 if _inside_write_area(p_polys, p_a) else 1.0
	return clampf(best, 0.0, 1.0)


## The surface the sim left, at sim resolution over the simulated area.
##
## Reconstructed rather than stored: the masks already hold the NET delta (§8.2), and the sim's input was
## the surface below its own layer, so `below + (erosion + deposition)` is exactly the elevation the
## solver finished with — bit for bit, with no fifth channel and no re-solve. It is also independent of
## anything ABOVE Sim's layer, so a flow-gated relief material stamped on top does not move the rivers.
##
## What it IS sensitive to is a change to a layer BELOW Sim's, which moves `below` without moving the
## masks. That invalidates the erosion just as much as it invalidates this, and pressing Simulate fixes
## both; the area-hash warning is the closest thing to a guard, and it does not catch that case.
func _eroded_surface() -> Dictionary:
	var fail := {"ok": false, "reason": ""}
	var r := sim_result
	if r == null or not r.is_valid():
		fail["reason"] = "there are no masks — press Simulate first"
		return fail
	var layer_id := _ensure_layer_for(_layer_owner, true)
	if layer_id <= 0:
		fail["reason"] = "the layers Tool API is unavailable"
		return fail
	var vs: float = terrain.vertex_spacing
	var max_x: float = r.min_x + r.cell_size * float(r.width - 1)
	var max_z: float = r.min_z + r.cell_size * float(r.height - 1)
	var tw := int(round((max_x - r.min_x) / vs)) + 1
	var th := int(round((max_z - r.min_z) / vs)) + 1
	if tw < 2 or th < 2:
		fail["reason"] = "the masks describe a degenerate area"
		return fail
	var below: PackedFloat32Array = terrain.data.composite_height_below(layer_id, r.min_x, r.min_z, vs, tw, th)
	if below.size() != tw * th:
		fail["reason"] = "no terrain regions under the simulated area"
		return fail
	var z: PackedFloat32Array = terrain.data.resample_grid(below, tw, th, r.width, r.height)
	if z.size() != r.width * r.height:
		fail["reason"] = "the below-layer surface did not resample onto the mask grid"
		return fail
	for i in range(z.size()):
		z[i] = z[i] + r.erosion[i] + r.deposition[i]
	return {"ok": true, "reason": "", "z": z, "gw": r.width, "gh": r.height,
			"cell": r.cell_size, "min_x": r.min_x, "min_z": r.min_z}


## Add Brushes: replace this Sim's generated set with a fresh one, as ONE undoable action (§10.4).
func add_brushes() -> Dictionary:
	return add_brushes_now(true)


## The scripted entry point, so gates and tools get a report Dictionary back:
## {ok, reason, rivers, lakes, removed}.
func add_brushes_now(p_record_undo: bool = false) -> Dictionary:
	var report := {"ok": false, "reason": "", "rivers": 0, "lakes": 0, "removed": 0}
	_clear_water_overlay() # the real brushes are about to say the same thing
	var w := extract_water()
	if not bool(w.get("ok", false)):
		report["reason"] = w.get("reason", "extraction failed")
		push_warning("Pasture3DSim '%s': %s." % [name, report["reason"]])
		return report
	var rivers: Array = w["rivers"]
	var lakes: Array = w["lakes"]
	if rivers.is_empty() and lakes.is_empty():
		report["reason"] = "the current thresholds produced no rivers and no lakes"
		push_warning("Pasture3DSim '%s': %s." % [name, report["reason"]])
		return report

	var old := collect_generated()
	# Built, not yet parented: everything that can fail should fail before the tree is touched, so a
	# half-built set never lands in the scene.
	var fresh: Array = []
	var widest := 0.0
	for seg: Dictionary in rivers:
		var areas: PackedFloat32Array = seg["areas"]
		for a in areas:
			widest = maxf(widest, sqrt(maxf(a, 0.0)))
	for seg: Dictionary in rivers:
		var t := _make_trough(seg, widest)
		if t != null:
			fresh.append(t)
	for lake: Dictionary in lakes:
		var p := _make_pond(lake)
		if p != null:
			fresh.append(p)
	if fresh.is_empty():
		report["reason"] = "every extracted feature was rejected when building its brush"
		push_warning("Pasture3DSim '%s': %s." % [name, report["reason"]])
		return report

	var ur: EditorUndoRedoManager = _editor_undo() if p_record_undo else null
	if ur != null:
		ur.create_action("Pasture3D Sim Add Brushes", UndoRedo.MERGE_DISABLE, self)
		for n in fresh:
			ur.add_do_reference(n)
		for n in old:
			ur.add_undo_reference(n)
		ur.add_do_method(self, "_apply_generated", old, fresh)
		ur.add_undo_method(self, "_apply_generated", fresh, old)
		ur.commit_action(true)
	else:
		_apply_generated(old, fresh)
	report["ok"] = true
	report["rivers"] = rivers.size()
	report["lakes"] = lakes.size()
	report["removed"] = old.size()
	_water_preview = "%d lake(s), %d river segment(s) generated" % [lakes.size(), rivers.size()]
	update_configuration_warnings()
	print("Pasture3DSim '%s': generated %d river segment(s) and %d lake(s), replacing %d." % [
			name, rivers.size(), lakes.size(), old.size()])
	return report


## Clear Brushes: remove every brush this Sim generated, edited or not, in one undo step (§10.4).
func clear_brushes() -> int:
	return clear_brushes_now(true)


func clear_brushes_now(p_record_undo: bool = false) -> int:
	_clear_water_overlay()
	var old := collect_generated()
	if old.is_empty():
		print("Pasture3DSim '%s': there are no generated brushes to clear." % name)
		return 0
	print("Pasture3DSim '%s': clearing %d generated brush(es)." % [name, old.size()])
	var ur: EditorUndoRedoManager = _editor_undo() if p_record_undo else null
	if ur != null:
		ur.create_action("Pasture3D Sim Clear Brushes", UndoRedo.MERGE_DISABLE, self)
		for n in old:
			ur.add_undo_reference(n)
		ur.add_do_method(self, "_apply_generated", old, [])
		ur.add_undo_method(self, "_apply_generated", [], old)
		ur.commit_action(true)
	else:
		_apply_generated(old, [])
	_water_preview = ""
	update_configuration_warnings()
	return old.size()


## Detach `p_remove` and attach `p_add`. The single do/undo body, so redo and undo are literally the
## same code with the two lists swapped and cannot drift apart.
func _apply_generated(p_remove: Array, p_add: Array) -> void:
	for n in p_remove:
		if is_instance_valid(n):
			_detach_generated(n)
	for n in p_add:
		if is_instance_valid(n):
			_attach_generated(n)


## Every brush this Sim generated, found by the marker rather than by name or by parent (§10.4): a
## rename must not orphan a brush, and neither must dragging it out of the Generated folder to somewhere
## more convenient. Depth-first over this Sim's whole subtree.
func collect_generated() -> Array:
	var out: Array = []
	var stack: Array = get_children()
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if n is Pasture3DTerrainBrush and n.has_meta(GENERATED_META):
			out.append(n)
	return out


## The folder generated brushes live in. Found by marker, created on demand; a user who renames it keeps
## it, and a user who deletes it gets a new one.
func _generated_root() -> Node3D:
	for c in get_children():
		if c is Node3D and c.has_meta(GENERATED_META) and not (c is Pasture3DTerrainBrush):
			c.set_meta(INTERNAL_CHILD_META, true) # a folder saved before the marker existed
			return c
	var root := Node3D.new()
	root.name = "Generated"
	root.set_meta(GENERATED_META, true)
	# Not a spline and not part of our footprint — see INTERNAL_CHILD_META. Without it, creating this
	# folder counts as a structural edit of the Sim, the base class schedules a refresh, and the refresh
	# clears the very erosion the brushes were extracted from (§12).
	root.set_meta(INTERNAL_CHILD_META, true)
	add_child(root, true)
	_own_scene(root)
	return root


func _attach_generated(p_node: Node3D) -> void:
	if p_node.get_parent() == null:
		_generated_root().add_child(p_node, true)
		_own_scene(p_node)
	# Placement, BEFORE the terrain is assigned and anything bakes: a brush moved after its first bake
	# would paint once in the wrong place. Consumed here (see PLACE_META), so this runs for a fresh brush
	# and never for one coming back through undo.
	if p_node.has_meta(PLACE_META):
		var origin: Vector3 = p_node.get_meta(PLACE_META)
		p_node.remove_meta(PLACE_META)
		var parent := p_node.get_parent() as Node3D
		var world := Transform3D(Basis(), origin)
		# Against the parent's transform rather than the global_transform setter, so it is correct for a
		# Sim that is rotated or scaled and does not depend on the node being inside the tree.
		p_node.transform = (parent.global_transform.affine_inverse() * world) if parent != null else world
	p_node.set("_suspend_auto", true)
	if p_node.get("terrain") != terrain:
		p_node.set("terrain", terrain)
	# Its own layer, so clearing the generated set can never disturb authored work and the whole set
	# gets one visibility toggle (§10.3).
	p_node._assign_layer_by_name("Generated Lakes" if p_node is Pasture3DPond else "Generated Rivers")
	p_node.set("_suspend_auto", false)
	p_node.refresh()
	if p_node is Pasture3DTrough:
		p_node.make_descend() # residual non-monotonic Y from sampling a noisy surface (§10.1)
	# §10.3 — water comes from the existing pool path, for BOTH kinds and synchronously. A Pond would
	# seed its own on the next idle frame (auto_add_water), which is one frame in which Add Brushes has
	# produced a dry lake; _make_pond turns that off and we press the same button here instead. One path,
	# no deferred surprise, and the result of pressing the button is complete when it returns.
	p_node.add_pool_now()


func _detach_generated(p_node: Node3D) -> void:
	if p_node.has_method("detach_placement"):
		p_node.call("detach_placement")
	elif p_node.has_method("_detach_from_current"):
		p_node.call("_detach_from_current")
	var p := p_node.get_parent()
	if p != null:
		p.remove_child(p_node)


## Own a generated node by the edited scene, so it saves with the scene. No-op outside the editor, which
## is what lets the bench gates build the same nodes without a scene root.
func _own_scene(p_node: Node) -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	var root := get_tree().edited_scene_root
	if root != null:
		p_node.owner = root


## One Trough per river link (§10.1). `p_widest` is the largest sqrt(area) across the whole network, so
## every segment's width_curve is on one shared scale and a tributary really does come out narrower than
## the trunk it joins.
func _make_trough(p_seg: Dictionary, p_widest: float) -> Pasture3DTrough:
	var pts: PackedVector3Array = p_seg["points"]
	var areas: PackedFloat32Array = p_seg["areas"]
	if pts.size() < 2:
		return null
	var t := Pasture3DTrough.new()
	t.name = "River"
	t.set_meta(GENERATED_META, true)
	t.snap_to_surface = false # the Y comes from the eroded surface, not from a re-snap
	t.depth = river_carve_depth
	t.bed_half_width = maxf(river_width_max, 0.1) * 0.5
	t.width_curve = _width_curve(areas, p_widest)
	# World points, stored relative to where the node will sit — see PLACE_META.
	var origin := _centroid(pts)
	t.set_meta(PLACE_META, origin)
	var path := Path3D.new()
	path.name = "Bed1"
	var c := Curve3D.new()
	for p in pts:
		c.add_point(p - origin)
	path.curve = c
	t.add_child(path)
	return t


## Centre of a run of world points, used as the origin a generated brush is placed at. Not the first
## point: the node's gizmo should land ON the feature, so grabbing a generated river to nudge it works
## the same way grabbing an authored one does.
func _centroid(p_pts: PackedVector3Array) -> Vector3:
	if p_pts.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for p in p_pts:
		sum += p
	return sum / float(p_pts.size())


## Width along the segment, as a 0..1 multiplier on bed_half_width. Rivers widen with the square root of
## their catchment (§10.1), floored at river_width_min so a headwater is still visible.
func _width_curve(p_areas: PackedFloat32Array, p_widest: float) -> Curve:
	var c := Curve.new()
	c.min_value = 0.0
	c.max_value = 1.0
	var floor_ratio := clampf(river_width_min / maxf(river_width_max, 0.001), 0.01, 1.0)
	var n := p_areas.size()
	var widest := maxf(p_widest, 0.001)
	for i in range(n):
		var t := float(i) / float(maxi(n - 1, 1))
		var frac := sqrt(maxf(p_areas[i], 0.0)) / widest
		c.add_point(Vector2(t, clampf(frac, floor_ratio, 1.0)))
	return c


## One Pond per lake (§10.2). A Pond is an inverted Mound, so `height` is how far it carves DOWN.
func _make_pond(p_lake: Dictionary) -> Pasture3DPond:
	var contour: PackedVector3Array = p_lake["contour"]
	if contour.size() < 3:
		return null
	var p := Pasture3DPond.new()
	p.name = "Lake"
	p.set_meta(GENERATED_META, true)
	p.auto_add_loop = false # we supply the shoreline; do not let it seed a square starter loop over ours
	p.auto_add_water = false # _attach_generated fills it synchronously instead — see there
	p.snap_to_surface = false
	p.height = maxf(float(p_lake["depth"]), 0.05)
	var origin := _centroid(contour)
	p.set_meta(PLACE_META, origin)
	var path := Path3D.new()
	path.name = "Loop1"
	var c := Curve3D.new()
	for v in contour:
		c.add_point(v - origin)
	c.closed = true
	path.curve = c
	p.add_child(path)
	return p


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


## §18: Sim's area mask is EXACT, because the bake's own masker is reachable. `sim_mask_deltas` fed a
## delta of all-ones returns the loop mask itself — edge offset, falloff width and falloff curve included,
## NaN outside — so the overlay feathers exactly where the erosion will. The base class's polygon clip is
## the fallback for brushes whose falloff is only reachable from inside the C++ rasteriser.
func _preview_area_mask(p_min_x: float, p_min_z: float, p_cell: float, p_gw: int, p_gh: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_gw * p_gh)
	var ones := PackedFloat32Array()
	ones.resize(p_gw * p_gh)
	ones.fill(1.0)
	var any := false
	for s in _get_splines():
		if not _spline_paintable(s):
			continue
		var poly := _polygon_xz(s)
		if poly.size() < 3:
			continue
		var m: PackedFloat32Array = terrain.data.sim_mask_deltas(ones, poly, {
				"sw": p_gw, "sh": p_gh, "gw": p_gw, "gh": p_gh,
				"sim_min_x": p_min_x, "sim_min_z": p_min_z, "sim_cell": p_cell,
				"min_x": p_min_x, "min_z": p_min_z, "vs": p_cell,
				"edge_offset": edge_offset, "falloff_width": maxf(falloff_width, 0.001),
			}, _ramp_lut(falloff_curve))
		if m.size() != p_gw * p_gh:
			continue
		for i in range(p_gw * p_gh):
			if is_finite(m[i]):
				out[i] = maxf(out[i], clampf(m[i], 0.0, 1.0)) # several loops: the strongest wins
		any = true
	return out if any else PackedFloat32Array()


## §18: build or drop this Sim's mask overlay. Over the SIMULATED area — the loops grown by the catchment
## margin — because that is the grid the mask is evaluated on at bake time, margin included. Showing only
## the write area would hide the part of the mask that decides how the channels arrive at the rim.
func _update_mask_preview() -> void:
	var stack: Array = erosion_mask if mask_preview == 1 else (write_mask if mask_preview == 2 else [])
	var sel := _selector_block(stack)
	if sel.is_empty():
		_clear_mask_preview()
		return
	var box := AABB()
	var have := false
	for s in _get_splines():
		if not _spline_paintable(s):
			continue
		var a := _spline_footprint_aabb(s).grow(maxf(catchment_margin, 0.0))
		box = a if not have else box.merge(a)
		have = true
	if not have:
		_clear_mask_preview()
		return
	var note := _show_mask_preview(sel, box, _mask_sim_dict(stack))
	if note != "":
		print("Pasture3DSim '%s': %s." % [name, note])


## §17: a mask stack flattened to the stride-8 selector blocks the C++ evaluator reads. Nulls and
## self-referencing selectors are dropped here rather than filtered downstream, so exactly one place
## decides what a stack contributes and the warning below describes the same set.
func _selector_block(p_list: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for s: Pasture3DReliefSelector in p_list:
		if s == null or _self_references(s):
			continue
		out.append_array(PackedFloat32Array(s.to_params()))
	return out


## A sim-Kind selector pointed at THIS Sim's own masks is reading this node's own output — the drift class
## `composite_height_below` exists to prevent (§13). The masks describe the erosion already in the layer,
## so the gate would key on the previous run and the two would chase each other. Pointed at ANOTHER Sim's
## result it is legitimate and useful, so this refuses the one case and not the Kind.
##
## Phase 6's pass chain makes the interesting version work properly: masking pass 2 on pass 1's live flow
## field is not self-reference, because pass 1's fields are a deterministic function of the same
## below-layer read. The warning says which one is missing rather than implying the idea is illegal.
func _self_references(p_sel: Pasture3DReliefSelector) -> bool:
	return p_sel.is_sim_kind() and p_sel.sim_result != null and p_sel.sim_result == sim_result


## The Pasture3DSimResult a stack's sim Kinds read, flattened for C++, or {}. ONE result per stack: two
## selectors pointed at different Sims would need two sets of four resampled grids, so the first wins and
## `_mask_warnings` says so rather than letting the second look like it is doing something.
func _mask_sim_dict(p_list: Array) -> Dictionary:
	for s: Pasture3DReliefSelector in p_list:
		if s != null and s.is_sim_kind() and s.sim_result != null and not _self_references(s):
			return _sim_result_dict(s.sim_result)
	return {}


## Everything that can be wrong with one mask stack. `p_label` names it, because "a selector" is useless
## advice when the node has two stacks.
func _mask_warnings(p_list: Array, p_label: String) -> PackedStringArray:
	var out := PackedStringArray()
	var selves := 0
	var dangling := 0
	var results: Array = []
	for s: Pasture3DReliefSelector in p_list:
		if s == null:
			continue
		if _self_references(s):
			selves += 1
			continue
		if s.is_sim_kind():
			if s.sim_result == null:
				dangling += 1
			elif not results.has(s.sim_result):
				results.append(s.sim_result)
	if selves > 0:
		out.append(("%s: %d selector(s) read THIS Sim's own Sim Result, which is this node's own output — "
			+ "the mask would gate on the previous run and drift every re-run. They are ignored. Point "
			+ "them at another Sim's result, or wait for the pass chain, where a later pass can key on an "
			+ "earlier one's flow.") % [p_label, selves])
	if dangling > 0:
		out.append(("%s: %d selector(s) use a sim Kind with no Sim Result assigned, so they read a defined "
			+ "0 everywhere and gate nothing. Assign the result of the Sim that eroded this ground.")
			% [p_label, dangling])
	if results.size() > 1:
		out.append(("%s: selectors point at %d different Sim Results; only '%s' is read. Split them across "
			+ "the two mask stacks, or use one result.") % [p_label, results.size(), results[0].resource_path
			if results[0].resource_path != "" else "the first"])
	return out


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
