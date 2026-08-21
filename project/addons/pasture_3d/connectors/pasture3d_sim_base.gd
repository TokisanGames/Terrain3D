# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DSimBase — the half of the Sim that does not care whether it solved one loop or a chain of
# passes. See PASTURE3D_SIM_NODE_SPEC.md.
#
# Phase 6 (§19) gave the Sim a second front end: Pasture3DSimManager, which chains its child Sims over one
# shared grid and commits ONE delta. Everything downstream of "there is now a Pasture3DSimResult and an
# eroded surface" is identical for both — §10's water extraction, the generated Ponds and Troughs, the
# layer commit, the .res bookkeeping — so it lives here rather than being duplicated or, worse, reachable
# only from the node that happened to implement it first.
#
# WHAT IS NOT HERE: anything that is a solve. The grid, the margin, the masks, the chain and the solver
# parameters belong to Pasture3DSim and Pasture3DSimManager respectively, because §19.3's whole point is
# that they split those differently.
#
# THE SUBCLASS HOOKS, and why they are hooks rather than properties on this class. Godot lists a base
# script's exports BEFORE a derived script's, so moving `sim_result` and the water thresholds up here
# would push Pasture3DSim's Simulation group below its own outputs — a visible change to a node §19.7
# promises stays unchanged. The exports therefore stay on the subclasses and this class reads them
# through four small hooks:
#
#   _water_config()      the §10 thresholds, as one Dictionary
#   _sim_result_res()    the Pasture3DSimResult this node owns, and _set_sim_result_res() to create one
#   _write_polygons()    the world-XZ polygons this node actually WRITES inside — its own loops for a
#                        Sim, its children's for a manager
#   _sim_label()         "Pasture3DSim 'Name'" / "Pasture3DSimManager 'Name'", for every message below
@tool
class_name Pasture3DSimBase
extends Pasture3DTerrainBrush


# ---- Subclass hooks -------------------------------------------------------------------------------

## The §10 water-feature thresholds: river_area_threshold, min_river_length, curve_tolerance,
## lake_depth_threshold, min_lake_area, river_width_max, river_width_min, river_carve_depth.
func _water_config() -> Dictionary:
	return {}


func _sim_result_res() -> Pasture3DSimResult:
	return null


func _set_sim_result_res(_r: Pasture3DSimResult) -> void:
	pass


## World-XZ polygons of the area this node writes into. Extraction is clipped to these (§10.4).
func _write_polygons() -> Array:
	return []


## How this node names itself in warnings and Output lines. Overridden rather than derived from the
## script's global name so the strings Pasture3DSim already prints stay byte-identical.
func _sim_label() -> String:
	return "Pasture3DSim '%s'" % name


# ---- Pasture3DTerrainBrush hooks shared by both front ends -----------------------------------------

func _default_layer_name() -> String:
	return "Erosion"


func _get_blend_mode() -> int:
	return BLEND_ADD # a signed delta, never an absolute surface


## §12: NO-OP, deliberately. Neither front end may run on the auto-refresh path — a solve is seconds of
## work and re-running it on every spline-handle drag is exactly the editor freeze this repo has a spec
## about.
func _paint_spline(_path: Path3D) -> void:
	pass


## Erosion removes material, so the Add Water prompt must not treat an ADD blend here as raising terrain.
func _raise_inverted() -> bool:
	return true


# ---- Inputs ---------------------------------------------------------------------------------------

## Loop projected to world XZ and decimated to ~terrain resolution (same as Plow/Mound: the raw Curve3D
## bake is ~5x finer than the grid and would only make the mask's scanline fill slower).
func _polygon_xz(p_path: Path3D) -> PackedVector2Array:
	var raw := PackedVector2Array()
	for p in _baked_world_points(p_path):
		raw.append(Vector2(p.x, p.z))
	return _decimate(raw, maxf(terrain.vertex_spacing, 0.25))


## A polygon grown (or shrunk) by an edge offset, matching what the bake's masker did with the same
## number. Several polygons can come back out of one, which is why this returns an Array.
func _offset_polygon(p_poly: PackedVector2Array, p_edge_offset: float) -> Array:
	if is_zero_approx(p_edge_offset):
		return [p_poly]
	return Geometry2D.offset_polygon(p_poly, p_edge_offset)


# ---- The worker (spec §20) ------------------------------------------------------------------------
#
# §20.2's third driver. `_begin` / `_solve_chunk` / `_finish` was built as a state machine so there could
# be two drivers over identical work — straight through for gates, frame-yielding for the button. A
# THREADED driver fits the same seam, which is why this phase adds no restructuring: the pure half of the
# solve moves to a WorkerThreadPool task and the terrain-touching half stays exactly where it was.
#
# Both front ends share this because their solve loops are the same shape — a list of independent states,
# each advanced by `_solve_chunk` until it reports done. Pasture3DSim's states are loops; the manager's
# are clusters.
#
# WHAT MAKES THIS SAFE is not this function. It is that `_solve_chunk` reads nothing the main thread owns:
# every `terrain.data.*` call in it copies its arguments into std::vectors and copies results back out,
# and the three GDScript reads that did touch shared state — the erodability image, the falloff Curve and
# the loop polygons — were hoisted into `_begin` first. Warnings are collected rather than pushed. That
# work is the phase; this is the plumbing.

## A solve is running. Blocks a second press and lets Cancel find something to cancel. Lives here
## rather than on each front end because `_join_worker` and `_solve_on_worker` both need them, and
## two copies of a cancel flag is one copy too many.
var _running: bool = false
## Read by the worker at every chunk boundary, written only by the main thread. A monotonic
## one-way flag, which is why a plain bool is enough and a Mutex would be ceremony.
var _cancel: bool = false
## The pool task's id while a solve is in flight, -1 otherwise. Also the flag `_join_worker` keys on.
var _task_id: int = -1


## Run `p_states` to completion on a worker, yielding frames here until it finishes. Returns false when
## the run was abandoned — cancelled, or the node left the tree — in which case the caller must _abort.
##
## §20.3: the chunking stays on the worker, so Cancel still lands on a chunk boundary and §4.5's "N chunks
## of k iterations is the same solve as one call of N·k" carries over untouched. An atomic cancel flag
## checked inside the C++ iteration loop would be a new C++ contract bought for nothing.
func _solve_on_worker(p_states: Array, p_label: String, p_progress: Callable) -> bool:
	_task_id = WorkerThreadPool.add_task(_worker_body.bind(p_states), true, p_label)
	while not WorkerThreadPool.is_task_completed(_task_id):
		# Teardown is watched from HERE rather than from the worker: `is_inside_tree` is a scene-tree
		# query and the worker must not make one. The worker only ever READS `_cancel`.
		if not is_inside_tree() or not is_configured():
			_cancel = true
		if p_progress.is_valid():
			p_progress.call()
		await get_tree().process_frame
	# Always join, even when cancelled: `is_task_completed` false plus a cancel flag still leaves a task
	# holding this node's arrays, and freeing the node under it is the crash §20.4 is about.
	WorkerThreadPool.wait_for_task_completion(_task_id)
	_task_id = -1
	return not _cancel


## The task body. Runs on a pool thread — nothing in here may touch the tree, the servers, or push a
## warning (§20.4). It reads `_cancel` and calls `_solve_chunk`, and that is deliberately all it does.
func _worker_body(p_states: Array) -> void:
	for st in p_states:
		while not _solve_chunk(st):
			if _cancel:
				return


## Join any live worker before this node stops being a valid thing for it to write into. Called from both
## teardown paths; safe to call when nothing is running.
##
## §20.4 lists this as "the part that will bite", and it is: every one of these is reachable in an editor
## and none exists on the synchronous path. The node leaving the tree, the scene closing, the editor
## reloading a @tool script — all of them free the arrays the task is halfway through.
func _join_worker() -> void:
	if _task_id == -1:
		return
	_cancel = true
	WorkerThreadPool.wait_for_task_completion(_task_id)
	_task_id = -1
	_running = false


func _notification(what: int) -> void:
	super(what)
	if what == NOTIFICATION_EXIT_TREE or what == NOTIFICATION_PREDELETE:
		_join_worker()


## Overridden by both front ends: advance one solve state, returning true when it is finished. Declared
## here so `_worker_body` is not calling into thin air.
func _solve_chunk(_p_state: Dictionary) -> bool:
	return true


# ---- The layer commit -----------------------------------------------------------------------------

## Write solved delta blocks into the layer, as one undoable action.
##
## Mirrors the base class's dirty-rect bake (clear the box, repaint the layer-mates inside it, composite
## once, push only the touched regions) with our own contribution written through apply_sim_block instead
## of _paint_spline. An empty `p_solved` is Clear Simulation: same path, nothing of ours added.
##
## Each entry of `p_solved` is {spline_id, box, min_x, min_z, gw, gh, write} — one loop for a Sim, one
## CLUSTER for a manager (§19.2's "one write"). The two are the same shape on purpose: the commit does not
## know which front end filled it, and `spline_id` is only ever a key into the footprint cache.
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


# ---- Pasture3DSimResult bookkeeping (spec §8.2) ---------------------------------------------------

## Empty the masks in place, so a mask can never outlive the erosion it describes (Clear Simulation).
func _empty_result() -> void:
	_clear_water_overlay()
	var r := _sim_result_res()
	if r == null:
		return
	r.width = 0
	r.height = 0
	r.flow = PackedFloat32Array()
	r.erosion = PackedFloat32Array()
	r.deposition = PackedFloat32Array()
	r.wetness = PackedFloat32Array()
	r.source_area_hash = ""
	r.source_loops = 0
	r.source_time = Time.get_datetime_string_from_system(true, true)
	r.emit_changed()
	_save_result(r)


## Give the Sim Result a file of its own and write it, so a relief selector can point at a FILE rather
## than at a resource buried in a scene (§8.2). Returns the path written, or "".
##
## The Inspector could already do this — the resource slot's dropdown has Save As — but nothing said so,
## the slot is EMPTY until the first bake so there is nothing to right-click, and the warning that fires
## afterwards described the destination without naming the gesture. This is the discoverable route.
##
## It never picks a path in silence. With no file yet it derives one from the terrain's own data directory,
## takes the path over so every later Preview and Simulate rewrites it automatically, and prints where it
## went. With a file already, it just rewrites that.
func save_masks() -> String:
	var dir := "res://"
	if is_configured() and String(terrain.data_directory) != "":
		dir = String(terrain.data_directory)
	var path := save_masks_to(_sim_result_res(), _sim_label(), dir, String(name))
	if path != "":
		update_configuration_warnings()
	return path


## Save Masks, as a function of its inputs rather than of `self`.
##
## §21.3 gives every PASS a Save Masks button of its own, and a Pasture3DSimPass is a Node3D — it cannot
## inherit this class, which is a Pasture3DTerrainBrush. Sharing the implementation therefore means
## sharing it as a static, and that is worth more than the tidiness: "the button writes a .res, takes the
## path over so later bakes keep it current, and prints where it went" is behaviour a user will expect to
## be identical on a manager, a pass and a container, and three copies would eventually stop being.
static func save_masks_to(p_r: Pasture3DSimResult, p_label: String, p_dir: String, p_base: String) -> String:
	if p_r == null or not p_r.is_valid():
		push_warning(("%s: there are no masks to save yet — press Simulate (or Preview) first, then this "
			+ "button.") % p_label)
		return ""
	var path: String = p_r.resource_path
	if path == "" or path.contains("::"):
		path = "%s/%s_masks.res" % [p_dir.trim_suffix("/"), p_base.to_snake_case()]
		# So the node stops treating them as scene-embedded and _save_result keeps them current from here.
		p_r.take_over_path(path)
	var err := ResourceSaver.save(p_r, path)
	if err != OK:
		push_warning("%s: could not save the masks to %s (error %d)." % [p_label, path, err])
		return ""
	print(("%s: masks saved to %s. Point a relief selector's Sim Result at that file — on a Plow or Mound, "
		+ "not on a pass.") % [p_label, path])
	return path


## Write the masks back to their own .res, if they have one. A resource with no path (or a path inside a
## scene, "…::N") is left alone — the scene serialiser owns it, and the node warns about that separately.
func _save_result(p_result: Pasture3DSimResult) -> void:
	save_result_file(p_result, _sim_label())


static func save_result_file(p_result: Pasture3DSimResult, p_label: String) -> void:
	var path: String = p_result.resource_path
	if path == "" or path.contains("::"):
		return
	var err := ResourceSaver.save(p_result, path)
	if err != OK:
		push_warning("%s: could not save the masks to %s (error %d)." % [p_label, path, err])
	else:
		print("%s: masks written to %s." % [p_label, path])


## Everything the "Sim Result" export can be wrong about, shared because both front ends own one.
func _result_warnings(p_baked_hash: String) -> PackedStringArray:
	return result_warnings_for(_sim_result_res(), p_baked_hash)


## The same two warnings, reachable from a Pasture3DSimPass — see save_masks_to for why this is a static.
static func result_warnings_for(p_r: Pasture3DSimResult, p_baked_hash: String) -> PackedStringArray:
	var out := PackedStringArray()
	var r := p_r
	if r == null:
		return out
	# An unsaved Resource is serialised INTO the scene file. For four float channels over a sim grid
	# that is megabytes of base64 in a .tscn, and it stops the masks being diffable or deletable
	# separately, which is the whole point of §2's "one .res per Sim node".
	if r.resource_path == "" or r.resource_path.contains("::"):
		out.append(("The Sim Result masks have no file of their own, so they will be saved inside this "
			+ "scene — megabytes of float data, and nothing a relief selector in another scene can point "
			+ "at. Press Save Masks (under Sim Result), or use the resource slot's dropdown → Save As."))
	elif r.source_area_hash != "" and p_baked_hash != "" and r.source_area_hash != p_baked_hash:
		out.append(("The Sim Result masks were not written by this node's last bake, so they describe a "
			+ "different area. Press Simulate to rewrite them."))
	return out


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
		push_warning("%s: %s." % [_sim_label(), w.get("reason", "extraction failed")])
		update_configuration_warnings()
		return w
	var rivers: Array = w["rivers"]
	var lakes: Array = w["lakes"]
	_draw_water_overlay(rivers, lakes)
	_water_preview = "%d lake(s), %d river segment(s) at the current thresholds" % [lakes.size(), rivers.size()]
	print("%s: %s (%d channel cells, %d flooded cells)." % [
			_sim_label(), _water_preview, int(w.get("channel_cells", 0)), int(w.get("lake_cells", 0))])
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
	var cfg := _water_config()
	var res: Dictionary = terrain.data.sim_extract_water(surf["z"], {
		"gw": surf["gw"], "gh": surf["gh"], "cell_size": surf["cell"],
		"min_x": surf["min_x"], "min_z": surf["min_z"],
		"river_area_threshold": cfg["river_area_threshold"],
		"min_river_length": cfg["min_river_length"],
		"curve_tolerance": cfg["curve_tolerance"],
		"lake_depth_threshold": cfg["lake_depth_threshold"],
		"min_lake_area": cfg["min_lake_area"],
		"lake_depth_percentile": 0.9,
	})
	if not bool(res.get("ok", false)):
		fail["reason"] = "the extractor rejected the %dx%d grid" % [int(surf["gw"]), int(surf["gh"])]
		return fail
	res["reason"] = ""
	return _clip_to_write_area(res)


## Cut the extracted network down to the area this node actually WRITES.
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
##
## §19.6: under a manager the polygons are every pass's loops, so a river crossing what used to be a
## boundary between two Sims is inside ONE write area and survives as one run instead of two.
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
	if length < float(_water_config()["min_river_length"]):
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
## anything ABOVE the layer, so a flow-gated relief material stamped on top does not move the rivers.
##
## What it IS sensitive to is a change to a layer BELOW ours, which moves `below` without moving the
## masks. That invalidates the erosion just as much as it invalidates this, and pressing Simulate fixes
## both; the area-hash warning is the closest thing to a guard, and it does not catch that case.
func _eroded_surface() -> Dictionary:
	var fail := {"ok": false, "reason": ""}
	var r := _sim_result_res()
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


## Add Brushes: replace this node's generated set with a fresh one, as ONE undoable action (§10.4).
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
		push_warning("%s: %s." % [_sim_label(), report["reason"]])
		return report
	var rivers: Array = w["rivers"]
	var lakes: Array = w["lakes"]
	if rivers.is_empty() and lakes.is_empty():
		report["reason"] = "the current thresholds produced no rivers and no lakes"
		push_warning("%s: %s." % [_sim_label(), report["reason"]])
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
		push_warning("%s: %s." % [_sim_label(), report["reason"]])
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
	print("%s: generated %d river segment(s) and %d lake(s), replacing %d." % [
			_sim_label(), rivers.size(), lakes.size(), old.size()])
	return report


## Clear Brushes: remove every brush this node generated, edited or not, in one undo step (§10.4).
func clear_brushes() -> int:
	return clear_brushes_now(true)


func clear_brushes_now(p_record_undo: bool = false) -> int:
	_clear_water_overlay()
	var old := collect_generated()
	if old.is_empty():
		print("%s: there are no generated brushes to clear." % _sim_label())
		return 0
	print("%s: clearing %d generated brush(es)." % [_sim_label(), old.size()])
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


## Every brush this node generated, found by the marker rather than by name or by parent (§10.4): a
## rename must not orphan a brush, and neither must dragging it out of the Generated folder to somewhere
## more convenient. Depth-first over this node's whole subtree.
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
	# folder counts as a structural edit, the base class schedules a refresh, and the refresh clears the
	# very erosion the brushes were extracted from (§12).
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
		# node that is rotated or scaled and does not depend on being inside the tree.
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
	var cfg := _water_config()
	var t := Pasture3DTrough.new()
	t.name = "River"
	t.set_meta(GENERATED_META, true)
	t.snap_to_surface = false # the Y comes from the eroded surface, not from a re-snap
	t.depth = cfg["river_carve_depth"]
	t.bed_half_width = maxf(float(cfg["river_width_max"]), 0.1) * 0.5
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
	var cfg := _water_config()
	var c := Curve.new()
	c.min_value = 0.0
	c.max_value = 1.0
	var floor_ratio := clampf(float(cfg["river_width_min"]) / maxf(float(cfg["river_width_max"]), 0.001), 0.01, 1.0)
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


## Dark blue for the whole erosion family (§: reported from use). The default neon purple washes out
## against the pale blue-grey a wet or checkered terrain renders as, which is exactly the terrain a sim
## is usually being aimed at. Dark blue survives that AND a dry ochre hillside, and it separates the
## erosion passes from every stamping brush in a crowded scene at a glance.
const EROSION_COLOR := Color(0.13, 0.30, 0.80)


func _gizmo_color() -> Color:
	return EROSION_COLOR


## Nameplate: the same blue, but outlined in near-white rather than black — a dark fill on a black
## outline is a smudge at distance, which is the readability half of the complaint.
func _label_colors() -> Array:
	return [EROSION_COLOR, Color(0.96, 0.97, 1.0, 0.9)]


# ---- The erodability LUT, shared by every host that erodes -----------------------------------------

## Resolution cap for an erodability map. Rock hardness is a broad spatial field; more than this per axis
## buys nothing and costs a bigger per-bake image read. Mirrors Pasture3DPlow's height LUT cap.
const ERODABILITY_LUT_MAX: int = 256


## A hardness texture as the `[0,1]` LUT `erosion_solve` reads: `[data, w, h, reason]`, where a non-empty
## `reason` explains why the map could not be used and the LUT is empty (uniform erodability).
##
## Static and living HERE — on the base of the erosion family — because two unrelated hosts now need it:
## `Pasture3DSim` and `Pasture3DModErosion`. The callers keep their own warning wording, because a node
## and a modifier name themselves differently; what must not be duplicated is the LUT itself, since the
## solver's remap depends on how the luminance was sampled and downscaled.
static func erodability_lut(p_map: Texture2D) -> Array:
	var empty: Array = [PackedFloat32Array(), 0, 0, ""]
	if p_map == null:
		return empty
	var img := p_map.get_image()
	if img == null:
		return [PackedFloat32Array(), 0, 0, "it has no image data"]
	img = img.duplicate() # never mutate the shared resource image
	if img.is_compressed() and img.decompress() != OK:
		return [PackedFloat32Array(), 0, 0, "it could not be decompressed"]
	if img.has_mipmaps():
		img.clear_mipmaps()
	var w := img.get_width()
	var h := img.get_height()
	if maxi(w, h) > ERODABILITY_LUT_MAX:
		var sc := float(ERODABILITY_LUT_MAX) / float(maxi(w, h))
		w = maxi(1, int(round(w * sc)))
		h = maxi(1, int(round(h * sc)))
		img.resize(w, h, Image.INTERPOLATE_BILINEAR)
	if w < 2 or h < 2:
		return [PackedFloat32Array(), 0, 0, "it is smaller than 2x2 after downscaling"]
	var data := PackedFloat32Array()
	data.resize(w * h)
	for y in range(h):
		var row := y * w
		for x in range(w):
			data[row + x] = img.get_pixel(x, y).get_luminance()
	return [data, w, h, ""]
