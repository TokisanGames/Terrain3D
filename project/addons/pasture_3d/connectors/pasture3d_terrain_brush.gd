# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DTerrainBrush — shared base for the spline-driven landscape brushes
# (Pasture3DMound / Pasture3DRidge / Pasture3DTrough). See PASTURE3D_LANDSCAPE_TOOLS_SPEC.md and
# PASTURE3D_TOOL_LAYER_ASSIGNMENT_SPEC.md.
#
# A brush node paints N child Path3D splines into ONE reserved, non-destructive height layer. Tools
# bind to a layer BY NAME: the layer owner_id is "pasture3d_brush:<name>", so two tools that target
# the same name share one layer automatically (create_owned_layer is idempotent by owner). A refresh
# is layer-granular — it repaints every tool bound to the layer — so co-located tools survive each
# other's edits, and re-running is idempotent. Binding is by owner_id, so renaming the layer in the
# Layers dock never breaks the tools pointing at it (the inspector dropdown shows the live name).
#
# GDScript-only: it calls the already-bound C++ Tool API (create_owned_layer / set_height_on_layer /
# add_height_on_layer / clear_layer_in_area / composite_region / update_maps), so no engine rebuild is
# required. On a build without that API it falls back to destructive set_height (works, not idempotent).
@tool
@icon("res://addons/pasture_3d/icons/brush_terrain.svg")
class_name Pasture3DTerrainBrush
extends Node3D

## Map type / blend-mode indices, matching Pasture3DData.MapType and Pasture3DLayer.BlendMode.
## Hardcoded as ints so this script does not hard-depend on the enum bindings.
const PASTURE_3D_MAPTYPE_HEIGHT: int = 0  # Pasture3DData.MapType.TYPE_HEIGHT
const PASTURE_3D_MAPTYPE_CONTROL: int = 1 # Pasture3DData.MapType.TYPE_CONTROL
const PASTURE_3D_MAPTYPE_COLOR: int = 2   # Pasture3DData.MapType.TYPE_COLOR
const BLEND_REPLACE: int = 0 # Pasture3DLayer.BlendMode.REPLACE
const BLEND_ADD: int = 1     # Pasture3DLayer.BlendMode.ADD
const BLEND_MAX: int = 2     # Pasture3DLayer.BlendMode.MAX
const BLEND_MIN: int = 3     # Pasture3DLayer.BlendMode.MIN

## owner_id namespace marking a layer as a brush tool layer (vs hand layers / road-connector layers).
## This brush's contribution to the terrain has been rebaked and pushed to the GPU.
##
## Exists for water. A Pasture3DStream reads its surface height out of the BANKS -- terrain
## heights, not the spline -- so a Trough edit silently invalidates every stream on it, and
## before this there was no signal on a brush at all to notice by. Anything else deriving
## geometry from baked height has the same problem and can use the same hook.
##
## Emitted on every tool the bake touched, not only the one whose edit triggered it: a bake
## repaints all of its layer-mates (see _refresh_owner), so a stream fed by a Trough that
## was repainted as somebody else's sibling has to hear about it too.
signal baked

const BRUSH_OWNER_PREFIX: String = "pasture3d_brush:"
## Group every brush node joins so siblings can find each other for layer-granular refresh.
const BRUSH_GROUP: StringName = &"pasture3d_brush"

## Mark a child a brush adds to ITSELF for presentation or bookkeeping — never a spline, never part of
## the footprint. Adding or removing one must not schedule a re-bake: `_on_child_changed` treats any new
## child as a structural edit, which for Pasture3DSim means the refresh cycle clears its footprint and
## the erosion silently leaves the layer. The nameplate is exempted by identity below; anything else
## (Sim's Generated folder, its water-feature overlay) says so with this.
const INTERNAL_CHILD_META: StringName = &"_brush_internal_child"

# Debounce for auto-refresh while dragging spline handles (seconds).
const REFRESH_DELAY: float = 0.1

## The Pasture3D terrain this brush paints into.
@export var terrain: Pasture3D:
	set(value):
		# Leaving a terrain (reparent or an inspector re-assignment): lift our contribution off the old
		# one first — otherwise our baked footprint is stranded on it. `terrain` still holds the old
		# value here, so the detach resolves the old terrain's layer.
		if Engine.is_editor_hint() and value != terrain and is_instance_valid(terrain) and terrain.data != null:
			_detach_from_current()
		terrain = value
		update_configuration_warnings()
		# Rebuild dynamic property hints (e.g. the material/texture dropdown) now that a terrain — and
		# thus its texture list — is known, so they populate without needing to reselect the node.
		notify_property_list_changed()
		_schedule_refresh()

## Re-paint automatically while editing the splines / moving the node.
@export var auto_refresh: bool = true

## Print a per-bake timing breakdown (clear / snap / paint / GPU push, in µs) to Output while editing
## this brush. Diagnostic for the partial-redraw bottleneck — leave off in normal use.
@export var log_bake_timing: bool = false

## Force the GDScript reference rasteriser even when the native C++ one is available. For A/B correctness
## checks (toggle and compare shape + timing on the same brush). Leave off in normal use.
@export var force_gdscript_raster: bool = false

@export_tool_button("Refresh") var _refresh_btn = _refresh_button
@export_tool_button("Add Spline") var _add_spline_btn = add_spline
## Fill this brush's closed spline(s) with a Pasture3DPool — the one-press path from "I carved a
## basin" to "there is water in it". Asks first if this brush RAISES terrain, because water authored
## inside a landform is water you cannot see. See PASTURE3D_WATER_BODIES_SPEC.md §7.8.
@export_tool_button("Add Water") var _add_water_btn = add_pool
## Create a brand-new tool layer named after this node and assign this node to it.
@export_tool_button("Add New Layer") var _add_layer_btn = add_new_layer
## Show/hide the floating "Name — Layer" nameplate over EVERY brush at once (an editor-only label that
## makes brushes easy to find/select in a busy scene). The selected brush always shows its own.
@export_tool_button("Toggle Labels") var _toggle_labels_btn = _toggle_all_labels
## Show/hide the in/out curve-tangent handles for EVERY loop point at once. Off by default — only the
## selected point shows its tangents — to keep dense loops readable.
@export_tool_button("Toggle Tangents") var _toggle_tangents_btn = _toggle_all_tangents

@export_group("Surface")
## Keep this brush's spline points glued to the terrain surface while editing (their Y follows the
## ground). Leave off for free vertical control. See PASTURE3D_SPLINE_SURFACE_SNAP_SPEC.md.
@export var snap_to_surface: bool = true:
	set(v):
		snap_to_surface = v
		_schedule_refresh()
## Metres above the surface to sit the snapped points at (0 = on the surface). A small lift keeps the
## loop visible above the brush falloff while still tracking the terrain.
@export var surface_offset: float = 1.0:
	set(v):
		surface_offset = v
		if snap_to_surface:
			_schedule_refresh()
## Drop every spline point onto the terrain once, now (works whether or not snap_to_surface is on).
@export_tool_button("Snap Points to Surface") var _snap_btn = snap_points_to_surface

## Stable binding to a tool layer = its owner_id ("pasture3d_brush:<name>"). Persisted (hidden); shown
## in the inspector via the `tool_layer` dropdown (which displays the layer's live name). Empty until
## _ready defaults it to the subclass layer name, so a fresh tool auto-attaches to e.g. "Mounds".
var _layer_owner: String = ""

var _layer_id: int = -1               # Reserved layer index for the current paint; -1 = destructive fallback
var _blend: int = BLEND_REPLACE       # Blend mode used by _paint_height for the current paint
var _last_paint_aabb: Dictionary = {} # spline instance_id -> world AABB last painted (idempotent clear)
var _timer: SceneTreeTimer = null
var _dirty: bool = false
var _full_dirty: bool = false   # A queued refresh needs the whole layer (param/transform/structural change)
var _dirty_splines: Dictionary = {} # Path3D instance_id -> true: splines whose curve changed (partial redraw)
var _moved_node: bool = false   # A queued refresh is a node-transform move (dirty-rect, but re-snap all points)
var _last_baked_xform: Transform3D = Transform3D() # Global xform baked into the terrain; guards no-op transform refreshes (tab-switch churn)
var _clip_aabb: AABB = AABB()   # When non-empty, _paint_* writes only cells inside this world box (dirty-rect)
var _defer_composite: bool = false # When true, _paint_* write samples without compositing (caller composites the box once)
var _curve_cache: Dictionary = {}   # spline instance_id -> flat [pos, in, out] triples at last bake
var _stamp_cache: Dictionary = {}   # spline instance_id -> { key, min_x, min_z, vs, gw, gh, vals, bounds }
var _suspend_auto: bool = false # Blocks auto-refresh while we mutate curves programmatically (undo)
var _ready_done: bool = false   # True once _ready ran — gates re-parent auto-assign off scene-load
var _tree_settling: bool = false # True during the node's own tree enter/exit churn (tab switch) — suppresses no-op child-refresh

## Editor-only floating nameplate (internal child → never saved, hidden from the Scene dock).
var _name_label: Label3D = null
## Shared across every brush: the "Toggle Labels" button flips this so all nameplates show/hide together.
static var _show_all_labels: bool = false
## Shared across every brush: the "Toggle Tangents" button flips this so the gizmo (brush_gizmo.gd) draws
## every loop point's tangent handles instead of just the selected point's.
static var _show_all_tangents: bool = false


func _init() -> void:
	# Per-subclass default for the surface-snap toggle. Runs before scene deserialization, so a value
	# stored in a scene still overrides it; new nodes get the subclass default (line brushes default OFF).
	snap_to_surface = _default_snap_to_surface()


func _ready() -> void:
	if _layer_owner == "":
		_layer_owner = BRUSH_OWNER_PREFIX + _default_layer_name()
	add_to_group(BRUSH_GROUP)
	set_notify_transform(true)
	if not child_entered_tree.is_connected(_on_child_changed):
		child_entered_tree.connect(_on_child_changed)
	if not child_exiting_tree.is_connected(_on_child_changed):
		child_exiting_tree.connect(_on_child_changed)
	for s in _get_splines():
		_connect_spline(s)
	# Convenience: when a brush is first added under a Pasture3D (at any depth), auto-target it — but
	# never clobber a terrain the user picked, and only in the editor.
	if Engine.is_editor_hint() and terrain == null:
		var anc := _terrain_ancestor()
		if anc != null:
			terrain = anc
	# Baseline the footprint cache to the loaded poses (without painting) so the first edit of the
	# session clears where a spline WAS, not just where it ends up — no stale flattening trail.
	_seed_cache()
	# Baseline the baked-transform guard to the loaded pose so a tab-switch TRANSFORM_CHANGED that
	# re-notifies the SAME transform is recognised as a no-op (see _schedule_transform_refresh).
	_last_baked_xform = global_transform
	_ready_done = true
	# A freshly added/duplicated brush may have made an existing brush's curve newly shared — refresh all.
	_refresh_group_warnings()
	# A scene saved with a preview toggle on should show its overlay on load, not on the next edit.
	_queue_mask_preview()
	# Most shape properties are plain @export (no setter), so they wouldn't auto-refresh on inspector edit.
	# Hook the inspector's property_edited signal instead (gated to the selected brush) — one hook covers
	# every brush's every property without per-property setters.
	if Engine.is_editor_hint():
		_connect_inspector_refresh()
		_ensure_label()
		var sel := EditorInterface.get_selection()
		if not sel.selection_changed.is_connected(_on_editor_selection_changed):
			sel.selection_changed.connect(_on_editor_selection_changed)
		if not renamed.is_connected(_update_label_text):
			renamed.connect(_update_label_text)


# ---- The worker ------------------------------------------------------------------------------------
#
# Hoisted up from Pasture3DSimBase when the brush's own erosion modifier needed it too
# (PASTURE3D_BRUSH_EROSION_SPEC.md §14). TWO USERS, ONE IMPLEMENTATION: a Pasture3DSim solving its loops
# and a Mound solving its Pasture3DNodeErosion are the same problem — a long PURE computation that must
# not block the editor — and the parts that are hard to get right (the join on teardown, the one-way
# cancel flag) are identical for both. What each user brings is its own CHUNK callable, and nothing else.
#
# ---- §20's original note, which is still the thing that makes it safe ----------------------------
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

# ---- The deferred erosion solve (PASTURE3D_BRUSH_EROSION_SPEC.md §14) -----------------------------
#
# A Pasture3DNodeErosion is the one modifier whose cost is measured in SECONDS, and it ran on the main
# thread inside the rasteriser — so a bake that had to solve froze the editor for the length of the
# solve, with no progress and no way out. On a kilometre-scale Mound that is tens of seconds of a window
# that does not repaint.
#
# THE SOLVE CANNOT SIMPLY MOVE TO A WORKER, because it does not sit at the top of anything: it is one
# step in the middle of a rasteriser that is a single synchronous C++ call, and there is no `await` to be
# had inside `stamp_mound_loop`. Restructuring the rasteriser around a coroutine would put a thread
# boundary through the middle of the terrain writes, which is the one place it must not go.
#
# SO THE BAKE HAPPENS TWICE, and the solve happens between them:
#
#   1. Bake with `_erosion_defer` set. The erosion step does NOT solve: it hands the surface it WOULD
#      have solved back through its `out` slot and leaves the grid alone, so the pass is an ordinary
#      cheap bake and the viewport shows the brush's un-eroded shape.
#   2. Solve every captured surface on a WorkerThreadPool task — ONE call per grid — while the main
#      thread yields frames, so the editor stays live throughout. Store each result in the modifier's
#      own frozen cache, under the key pass 1 computed.
#   3. Bake again. Every erosion step now finds a cache whose key MATCHES and serves it, which is a
#      memcpy. Nothing else in the stack knows a thread was involved.
#
# WHY THE KEY MATCHES, which is the whole reason this is sound rather than hopeful. The key is a hash of
# the exact surface handed to the solver, and that surface is `basey + vals` at the erosion step's own
# position: `basey` is the ground BELOW this brush's layer, and `vals` is what the modifiers ABOVE the
# erosion produced. Neither depends on whether the erosion ran. So pass 3 hands the solver the same grid
# pass 1 did, byte for byte, and the cache hits. This is the same convergence argument the seed-surface
# capture makes, and it fails in the same single way — something upstream changing BETWEEN the two
# passes — which is a re-bake, not a wrong answer.
#
# WHAT THIS COSTS is one extra cheap bake, and only on a bake that would have solved anyway: a pass-1
# bake that finds every cache already matching produces no pending work and returns before pass 3.
#
# ---- WHY THE SOLVE IS NOT CHUNKED, which was tried first ----------------------------------------
#
# A Pasture3DSim advances its solve CHUNK_ITERATIONS at a time so cancel and progress have somewhere to
# land, and §4.5 says that is free: the solver is stateless between calls, so N chunks of k iterations is
# one call of N·k. THE SOLVER IS STATELESS. THE ROUND TRIP IS NOT. `erode_heightfield` takes and returns
# a PackedFloat32Array, so every chunk boundary rounds the working surface through float32, and the D8
# receiver choice downstream of that is a comparison between neighbours — a rounding that flips one tie
# moves a channel, and the next iterations deepen it.
#
# MEASURED, on gate DC's fixture: twelve chunks of five iterations against one call of sixty differed by
# 9.59 m at worst, on a fixture whose mean cut is 59 m. The same gate with the chunk size raised to the
# full iteration count reads 0.00000000 m. So the brush solves in ONE call and gets its progress from a
# counter inside the solver's own loop instead (`Pasture3DData.erosion_progress`).
#
# THE PRICE IS CANCEL GRANULARITY: a solve can only be abandoned between grids, so a single-loop brush
# cannot be cancelled mid-solve. That is the right trade — the editor stays interactive either way, and
# the alternative buys a Cancel button by changing the terrain the button was going to produce.
#
# THIS ALSO SAYS SOMETHING ABOUT THE SIM, which does chunk: a chunked Sim solve is not bitwise the same
# as an unchunked one, and §4.5 claims it is. Nothing here depends on that and it has not been chased.
#
# FROZEN ONLY, deliberately. A Live modifier has no cache to deliver a deferred answer INTO, and Live is
# documented as the setting for a brush small enough to watch solve. One rule per Evaluation mode.

## Take the deferred path where `Engine.is_editor_hint()` is false. A gate's only way in: the driver
## exists so the EDITOR stays live, and a headless run has no editor to be live — but the answer it
## produces has to be the same one, and that is exactly what a gate must be able to ask. Mirrors
## `force_gdscript_raster`, which is there for the same reason.
var force_deferred_erosion: bool = false

## Set for the duration of pass 1. Read by `_compile_modifiers`, which passes it to both rasterisers.
var _erosion_defer: bool = false

## Suppress every erosion step outright, frozen or Live, for one bake. `_erosion_defer` only reaches the
## FROZEN ones, because only they have a cache to deliver a deferred answer into; this is the stronger
## thing the manager's Clear Simulation On All Brushes needs — the layer holding the shape the brushes
## make BEFORE they erode, whatever each modifier's Evaluation happens to be.
var _erosion_suppress: bool = false
## What pass 1 asked to have solved: one entry per erosion modifier per bake grid.
var _pending_erosion: Array = []

## §9.9, the growth half of the same driver. A Pasture3DReliefDLA grows a cluster on a 512² grid in
## GDScript, which is seconds, and it grows it INSIDE compile() — so it has exactly the erosion
## modifier's problem and takes exactly the erosion modifier's cure. Set for the duration of a growth
## pass; read by `_compile_modifiers`, which offers it to every relief material it compiles.
var _growth_defer: bool = false
## Materials that took the offer up, deduplicated: one entry per MATERIAL, not per bake grid, because a
## grown field belongs to the material and a brush with four loops must not grow the same mountain four
## times.
var _pending_growth: Array = []
## Deferred driver support for Pasture3DNodeGraph (evaluates graphs off-thread).
var _graph_defer: bool = false
var _pending_graph: Array = []
## Guards the three-pass driver against re-entry — a refresh scheduled by pass 1 must not start a second
## driver on top of this one. `_running` is not enough: a Pasture3DSim uses that for its own solve.
var _erosion_running: bool = false


## Run `p_states` to completion on a worker, yielding frames here until it finishes. Returns false when
## the run was abandoned — cancelled, or the node left the tree — in which case the caller must _abort.
##
## §20.3: the chunking stays on the worker, so Cancel still lands on a chunk boundary and §4.5's "N chunks
## of k iterations is the same solve as one call of N·k" carries over untouched. An atomic cancel flag
## checked inside the C++ iteration loop would be a new C++ contract bought for nothing.
## `p_chunk` advances one state and returns true when that state is finished, and every caller passes its
## own. There is no default: a Sim's state is a loop and the brush's is an erosion grid, and the two have
## nothing in common but the word "state" — a single `_solve_chunk` virtual serving both would be a
## dispatcher on which subclass it happened to be, declared on a base class that should not know.
func _solve_on_worker(p_states: Array, p_label: String, p_progress: Callable,
		p_chunk: Callable) -> bool:
	_task_id = WorkerThreadPool.add_task(_worker_body.bind(p_states, p_chunk), true, p_label)
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
## warning (§20.4). It reads `_cancel` and calls the chunk, and that is deliberately all it does.
func _worker_body(p_states: Array, p_chunk: Callable) -> void:
	for st in p_states:
		while not p_chunk.call(st):
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
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		_schedule_transform_refresh()
	elif what == NOTIFICATION_ENTER_TREE:
		# Re-join the group on every enter (a reparent exits + re-enters the tree, and _ready only runs
		# once) so layer-sharing keeps seeing this brush after it has been moved.
		add_to_group(BRUSH_GROUP)
		# A tab switch re-attaches the whole scene: our child splines re-enter the tree and fire
		# child_entered_tree, which _on_child_changed would treat as a structural edit and full-bake the
		# layer (the multi-second scene-tab-switch freeze). This ENTER_TREE fires BEFORE those child
		# signals, so flag the churn now and clear it after the frame settles. Gate on _ready_done so this
		# only suppresses RE-entries (tab switch / reparent, already baked) — a fresh duplicate/paste/open
		# has _ready_done == false and still bakes its new footprint normally.
		if _ready_done:
			_tree_settling = true
			_clear_tree_settling.call_deferred()
	elif what == NOTIFICATION_EXIT_TREE:
		remove_from_group(BRUSH_GROUP)
		# Before anything else: the task is holding this node's arrays.
		_join_worker()
		_clear_mask_preview() # §18.5: a preview owned by a node that has left the scene is orphaned
	elif what == NOTIFICATION_PREDELETE:
		_join_worker()
		# Freed while still attached (e.g. queue_free in the editor): lift our contribution off the layer
		# so we don't strand a baked footprint. The is_inside_tree() guard inside _detach_from_current
		# makes a node already removed from the tree (editor delete keeps it in undo history; placement
		# undo removes it explicitly) a safe no-op, and reparent — which frees nothing — never reaches here.
		if Engine.is_editor_hint() and is_inside_tree() and is_configured():
			_clear_mask_preview()
			_detach_from_current()
	elif what == NOTIFICATION_PARENTED:
		# Re-parented under a different terrain after creation → follow it. Deferred so the reparent has
		# fully settled (node back in the tree) before we detach/rebind. _ready_done gates this so it
		# never fires during initial scene load (PARENTED precedes _ready then).
		if Engine.is_editor_hint() and _ready_done:
			_auto_assign_terrain.call_deferred()


## Follow a reparent: bind to the nearest Pasture3D ancestor (the setter detaches from the old one).
## Moving the brush out from under any terrain leaves its current target as-is rather than clearing it.
func _auto_assign_terrain() -> void:
	if not Engine.is_editor_hint() or not _ready_done or not is_inside_tree():
		return
	var anc := _terrain_ancestor()
	if anc != null and terrain != anc:
		terrain = anc


## ---- THE BRUSH AS GRAPH GEOMETRY (§8.1) --------------------------------------------------------------
##
## A brush already owns an outline. Before this, a graph that wanted to mask the region a Mound shapes had
## to have that region drawn a SECOND time as a Plow — two splines meaning one thing, which drift apart the
## moment either is edited and give no sign that they have. `graph_shape_path` hands the brush's own
## outline to the graph as a closed PATH, so the shape is authored once.
##
## Deliberately NOT named `graph_path`: Pasture3DRoadBrush overrides that with its road centreline, and
## the two are different questions. A road's `graph_path` is a solved alignment with a vertical profile; a
## shape's is an outline with neither. Sharing the name would make a road brush answer the outline
## question with a centreline, which is exactly the closed-vs-open confusion §8.1 exists to prevent.


## How many outlines this brush can offer, one per spline.
func graph_shape_count() -> int:
	return _get_splines().size()


## This brush's name for graph nodes to hold, relative to its terrain. Mirrors Pasture3DRoadBrush.road_key
## — derived, never stored, so renaming a brush renames its key and a stale key resolves to nothing rather
## than to the wrong brush.
func shape_key() -> String:
	var anc := _terrain_ancestor()
	if anc == null:
		return str(get_path())
	return str(anc.get_path_to(self))


## Spline `p_index` as a PATH in world XZ, closed iff the brush treats it as a ring.
##
## The Y of every control point is DROPPED, not carried into `heights`. A shape source exists to say WHERE,
## and the closed-path rule (§8.1) is even-odd winding over XZ, which never reads a height. Handing over the
## spline's Y would offer a vertical profile that no consumer honours and that would go stale silently the
## first time the brush re-seats its points on the surface.
##
## The ring is left OPEN here even when `closed` is true: closing it is `path_close_ring`'s job, in exactly
## one place, so the CPU query, the mask and the oracle cannot each decide differently whether the last
## vertex repeats the first.
func graph_shape_path(p_index: int = 0) -> Pasture3DGraphPath:
	var path := Pasture3DGraphPath.new()
	path.source_label = shape_key()
	var splines := _get_splines()
	if p_index < 0 or p_index >= splines.size():
		return path
	var sp: Path3D = splines[p_index]
	var c: Curve3D = sp.curve if is_instance_valid(sp) else null
	if c == null or c.point_count < 2:
		return path
	var pts := PackedVector2Array()
	var xf := sp.global_transform if sp.is_inside_tree() else sp.transform
	for i in range(c.point_count):
		var w := xf * c.get_point_position(i)
		pts.append(Vector2(w.x, w.z))
	path.points = pts
	path.closed = _is_closed()
	return path


## Nearest Pasture3D ancestor (direct parent first), or null. Drives the auto-terrain assignment.
func _terrain_ancestor() -> Pasture3D:
	var n := get_parent()
	while n != null:
		if n is Pasture3D:
			return n
		n = n.get_parent()
	return null


## Lift our contribution off the CURRENT terrain's tool layer, repainting any layer-mates so we don't
## punch a hole in their overlapping footprints. Used before switching terrains. Excludes self from the
## repaint by blanking _layer_owner for the duration (mirrors how _rebind excludes a departing tool).
func _detach_from_current() -> void:
	if not is_configured() or not is_inside_tree():
		return
	var saved_owner := _layer_owner
	_layer_owner = ""
	_refresh_owner(saved_owner, false, _own_footprints())
	_layer_owner = saved_owner
	_last_paint_aabb.clear()
	_stamp_cache.clear()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings: PackedStringArray = []
	if not is_instance_valid(terrain):
		warnings.append("Assign a Pasture3D terrain for this brush to paint into.")
	elif not terrain.data or terrain.data.region_locations.size() == 0:
		warnings.append("The Pasture3D terrain has no regions yet — add regions in Pasture3D first.")
	if _get_splines().is_empty() and _wants_own_splines():
		warnings.append("Add at least one spline (press Add Spline, or add a Path3D child).")
	warnings.append_array(_mask_preview_warnings())
	warnings.append_array(_modifier_warnings())
	var shared := _shared_curve_spline_names()
	if not shared.is_empty():
		warnings.append(("These splines share a Curve3D with another spline, so editing one edits "
			+ "(and re-bakes) them all: %s. Select each Path3D and use the Curve property's dropdown "
			+ "→ Make Unique.") % ", ".join(shared))
	return warnings


## Does a brush of this kind draw its own area? True for every stamp brush and for a standalone Sim.
##
## FALSE for Pasture3DSimManager, whose loops live on its child passes (§19.2) — a manager with no spline
## of its own is correctly configured, and telling the user to add one sends them to make a Path3D that
## nothing will ever read. Also hides the Add Spline / Add Water buttons there.
func _wants_own_splines() -> bool:
	return true


## Names of this brush's child splines whose Curve3D is also referenced by another spline anywhere in the
## scene's brushes. Duplicating a brush copies the child Path3D but SHARES its Curve3D by reference, so a
## single edit drives every clone's bake — a silent performance trap. Counts curve instances across every
## brush in the group, then flags ours that appear more than once.
func _shared_curve_spline_names() -> PackedStringArray:
	var out := PackedStringArray()
	if not is_inside_tree():
		return out
	var counts := {}
	for n in get_tree().get_nodes_in_group(BRUSH_GROUP):
		if n is Pasture3DTerrainBrush:
			for s in n._get_splines():
				if s.curve != null:
					var id: int = s.curve.get_instance_id()
					counts[id] = int(counts.get(id, 0)) + 1
	for s in _get_splines():
		if s.curve != null and int(counts.get(s.curve.get_instance_id(), 0)) > 1:
			out.append(String(s.name))
	return out


func is_configured() -> bool:
	return is_instance_valid(terrain) and terrain.data != null


## Splines = direct Path3D children. (A NodePath-list override could be added later.)
func _get_splines() -> Array:
	var out: Array = []
	for c in get_children():
		if c is Path3D:
			out.append(c)
	return out


func _connect_spline(path: Path3D) -> void:
	# React to the Path3D swapping its Curve3D resource itself (Make Unique / assigning a new curve) so we
	# rebind to the new curve and the shared-curve warning re-evaluates. Idempotent (bound Callable compares
	# equal). Connected even when curve is null so a later assignment is caught.
	var pc := _on_path_curve_changed.bind(path)
	if not path.curve_changed.is_connected(pc):
		path.curve_changed.connect(pc)
	if path.curve == null:
		return
	# Bind the owning Path3D so a curve edit schedules a per-spline (dirty-rect) redraw, not a whole-layer
	# one. The bound Callable compares equal across calls (same method + bind), so this stays idempotent.
	var cb := _schedule_spline_refresh.bind(path)
	if not path.curve.changed.is_connected(cb):
		path.curve.changed.connect(cb)


## The Path3D swapped its Curve3D resource (e.g. Make Unique). Rebind to the new curve's change signal,
## re-evaluate the shared-curve warnings across all brushes, and re-bake so the swap takes effect.
func _on_path_curve_changed(path: Path3D) -> void:
	if not is_instance_valid(path):
		return
	_connect_spline(path)
	_refresh_group_warnings()
	_schedule_spline_refresh(path)


func _clear_tree_settling() -> void:
	_tree_settling = false


func _on_child_changed(node: Node) -> void:
	if node == _name_label or node.has_meta(INTERNAL_CHILD_META):
		return # presentation/bookkeeping children are not splines and must not trigger a refresh
	if _tree_settling:
		# Child splines entering/leaving the tree because the whole scene (re)attached — not a real
		# structural edit. The baked terrain data is already correct; skip the redundant full bake.
		return
	if node is Path3D:
		_connect_spline(node)
	# Broadcast, not just self: adding/removing a spline can make another brush's curve newly (non-)shared.
	_refresh_group_warnings()
	_schedule_refresh()


## Ask every brush in the scene to re-evaluate its configuration warnings, so the shared-curve warning
## appears/clears on ALL affected brushes at once (e.g. both the duplicate and its original) rather than
## only the one being edited. No-op outside the editor.
func _refresh_group_warnings() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	for n in get_tree().get_nodes_in_group(BRUSH_GROUP):
		if n is Pasture3DTerrainBrush:
			n.update_configuration_warnings()


## Connect (idempotently) to the editor inspector's property_edited signal so editing a shape property
## re-bakes. EditorInterface is a @tool-accessible singleton in Godot 4.2+. Safe no-op if unavailable.
func _connect_inspector_refresh() -> void:
	if not Engine.is_editor_hint():
		return
	var inspector := EditorInterface.get_inspector()
	if inspector and not inspector.property_edited.is_connected(_on_inspector_property_edited):
		inspector.property_edited.connect(_on_inspector_property_edited)


## A property was edited in the inspector. Re-bake only when THIS brush is the one being edited (the
## signal is global; get_edited_object() disambiguates). Spline edits go through curve.changed instead.
func _on_inspector_property_edited(_property: StringName) -> void:
	if not is_inside_tree():
		return
	var inspector := EditorInterface.get_inspector()
	if inspector and inspector.get_edited_object() == self:
		for s in _get_splines():
			_dirty_splines[s.get_instance_id()] = true
		_schedule_refresh()


## ---- Inspector: the tool-layer dropdown (bind by owner_id, display live name) ----

func _get_property_list() -> Array[Dictionary]:
	var props: Array[Dictionary] = []
	# The real binding: persisted, hidden from the inspector (shown via `tool_layer`).
	props.append({"name": "_layer_owner", "type": TYPE_STRING, "usage": PROPERTY_USAGE_STORAGE})
	props.append({"name": "Layer", "type": TYPE_NIL, "usage": PROPERTY_USAGE_GROUP, "hint_string": ""})
	var names := _brush_layer_names()
	var cur := _layer_display_name()
	if not names.has(cur):
		names.append(cur)
	props.append({
		"name": "tool_layer",
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": ",".join(names),
		"usage": PROPERTY_USAGE_EDITOR,
	})
	# The modifier stack (PASTURE3D_BRUSH_EROSION_SPEC.md §6), on the hosts whose rasteriser runs it.
	# Declared here rather than as an @export for the reason in the comment above: a dynamic property lands
	# AFTER the script's own exports, which is where a pipeline belongs — below the shape properties it
	# consumes, not above them.
	if _supports_modifiers():
		props.append({"name": "Modifiers", "type": TYPE_NIL, "usage": PROPERTY_USAGE_GROUP,
				"hint_string": ""})
		# A stack-wide setting, so it sits at the top of the group, above the ordered list it applies to.
		# Declared here rather than as an @export for the same reason `modifiers` is (see its note): only a
		# host that actually runs the stack should show it.
		props.append({
			"name": "modifier_margin",
			"type": TYPE_FLOAT,
			"hint": PROPERTY_HINT_RANGE,
			"hint_string": "0,200,0.5,or_greater,suffix:m",
			"usage": PROPERTY_USAGE_DEFAULT,
		})
		props.append({
			"name": "modifiers",
			"type": TYPE_ARRAY,
			"hint": PROPERTY_HINT_TYPE_STRING,
			"hint_string": "%d/%d:Pasture3DNode" % [TYPE_OBJECT, PROPERTY_HINT_RESOURCE_TYPE],
			"usage": PROPERTY_USAGE_DEFAULT,
		})
	# §18.6: the mask overlay and the selector it shows. Both are declared HERE rather than as plain
	# @export on the subclasses so they sit together under one group — a dynamic property appended by
	# `_get_property_list` always lands after the script's own exports, so a toggle declared beside
	# `relief` and a dropdown declared here would end up in different sections of the inspector, which is
	# exactly where the first build put them.
	#
	# Only offered when this brush has a relief material. `Pasture3DSim` has none, and its own mask stacks
	# multiply into one field that IS what the bake applies, so there is nothing to choose there — its
	# `mask_preview` stays a plain export and this block never runs for it.
	var relief = _preview_relief_material()
	if relief != null:
		props.append({"name": "Mask Preview", "type": TYPE_NIL, "usage": PROPERTY_USAGE_GROUP,
				"hint_string": "mask_preview"})
		props.append({"name": "mask_preview", "type": TYPE_BOOL, "usage": PROPERTY_USAGE_EDITOR})
		var labels := PackedStringArray()
		for e in _preview_selector_sources(relief):
			labels.append(String(e[0]).replace(",", " ").replace(":", " "))
		props.append({
			"name": "mask_preview_source",
			"type": TYPE_INT,
			"hint": PROPERTY_HINT_ENUM,
			"hint_string": ",".join(labels),
			"usage": PROPERTY_USAGE_EDITOR,
		})
	return props


func _get(property: StringName) -> Variant:
	if property == &"tool_layer":
		return _layer_display_name()
	if property == &"mask_preview_source":
		return _mask_preview_layer + 1
	if property == &"mask_preview" and _preview_relief_material() != null:
		return _mask_preview_on
	return null


func _set(property: StringName, value: Variant) -> bool:
	if property == &"tool_layer":
		_assign_layer_by_name(str(value))
		return true
	if property == &"mask_preview_source":
		_mask_preview_layer = int(value) - 1
		_update_mask_preview()
		update_configuration_warnings()
		return true
	if property == &"mask_preview" and _preview_relief_material() != null:
		_mask_preview_on = bool(value)
		_update_mask_preview()
		update_configuration_warnings()
		return true
	return false


## Point this tool at the brush layer whose live name is `display_name` (or a new owner for that name).
func _assign_layer_by_name(display_name: String) -> void:
	var owner := _owner_for_layer_name(display_name)
	if owner == "":
		owner = BRUSH_OWNER_PREFIX + display_name
	_set_layer_owner(owner)


## Create a new tool layer named after this node and assign this node to it (de-duplicated so it is
## always a fresh layer rather than silently joining an existing same-named one).
func add_new_layer() -> void:
	_set_layer_owner(BRUSH_OWNER_PREFIX + _unique_brush_layer_name(name))


## Re-bind to a different tool layer: lift our contribution off the old layer, then bake into the new.
func _set_layer_owner(owner: String) -> void:
	if owner == _layer_owner:
		return
	var old := _layer_owner
	_layer_owner = owner
	notify_property_list_changed()
	update_configuration_warnings()
	_update_label_text() # nameplate shows the layer name → keep it current on a re-bind
	if Engine.is_editor_hint() and is_inside_tree() and is_configured():
		_rebind(old)


func _rebind(old_owner: String) -> void:
	# Clear our footprint off the OLD layer (we're no longer one of its tools) and repaint whoever is
	# left on it, then bake into the new layer.
	if old_owner != "":
		_refresh_owner(old_owner, false, _own_footprints())
	_last_paint_aabb.clear()
	refresh()


## ---- Refresh scheduling (debounced; defers while a handle is being dragged) ----

## True when auto-refresh may queue work: not mid-programmatic-edit, enabled, in the editor and tree.
func _can_auto_refresh() -> bool:
	return not _suspend_auto and auto_refresh and Engine.is_editor_hint() and is_inside_tree()


## Whole-layer refresh scheduler — for param / transform / structural changes (anything that isn't a
## single spline's curve edit). Marks the queued bake as needing a full repaint.
func _schedule_refresh() -> void:
	if not _can_auto_refresh():
		return
	_full_dirty = true
	_arm_refresh_timer()


## Node-transform scheduler — the whole brush moved/rotated/scaled. Every child spline shifts together,
## so only this node's old∪new footprint is affected: take the dirty-rect path (clip to that box, repaint
## just the overlapping layer-mates) instead of redrawing the entire layer (the many-brushes-on-one-layer
## slowdown). The points didn't move in local space, so flag a full re-snap of this node's points.
func _schedule_transform_refresh() -> void:
	if not _can_auto_refresh() or not _ready_done:
		return
	# A tab switch re-attaches the scene and re-notifies TRANSFORM_CHANGED with an IDENTICAL transform
	# (the terrain also resets its own transform to identity on enter, propagating to children). That is
	# not a real move — re-baking here is a scene-tab-switch freeze. Skip it.
	if global_transform.is_equal_approx(_last_baked_xform):
		return
	for s in _get_splines():
		_dirty_splines[s.get_instance_id()] = true
	_moved_node = true
	_arm_refresh_timer()


## Per-spline scheduler — a single child curve changed, so only its footprint needs reworking. Records
## which spline moved; the bake takes the dirty-rect path unless a full refresh was also queued.
func _schedule_spline_refresh(path: Path3D) -> void:
	if not _can_auto_refresh():
		return
	if is_instance_valid(path):
		_dirty_splines[path.get_instance_id()] = true
	_arm_refresh_timer()


func _arm_refresh_timer() -> void:
	_dirty = true
	if is_instance_valid(_timer):
		return
	# Never arm a timer while detached (scene load / tree churn): the timer would fire and bake a node
	# that isn't in the tree, spamming node_3d.cpp:649 transform errors and re-baking pointlessly. Also
	# avoids calling the node's get_tree() when detached (which spams node.h:559). is_inside_tree() is
	# the cheap, non-erroring check; the next real edit re-arms once we're settled back in the tree.
	if not is_inside_tree():
		return
	_timer = get_tree().create_timer(REFRESH_DELAY)
	_timer.timeout.connect(_on_refresh_timer)


func _on_refresh_timer() -> void:
	_timer = null
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		# Still dragging — repaint once on release rather than every frame (keep accumulated dirty state).
		_arm_refresh_timer()
		return
	if not _dirty:
		return
	# §14. A deferred solve is in flight and the main thread is yielding frames — which is exactly when a
	# timer gets to fire. Baking now would find no cache and solve SYNCHRONOUSLY, putting back the freeze
	# the driver exists to remove, on top of a bake the driver is about to redo anyway. Keep the dirty
	# state and come back after it lands.
	if _erosion_running:
		_arm_refresh_timer()
		return
	_dirty = false
	# Snapshot + clear the queued dirty state up front so a refresh that re-enters scheduling is coherent.
	var full := _full_dirty
	var splines := _dirty_splines
	var moved_node := _moved_node
	_full_dirty = false
	_dirty_splines = {}
	_moved_node = false
	if not Engine.is_editor_hint() or not is_configured():
		return
	var bake: Callable = (_refresh_owner.bind(_layer_owner, false, []) if full or splines.is_empty()
			else _refresh_owner_rect.bind(_layer_owner, splines, moved_node))
	# §14. Both bake paths go through the same driver, because either can be the one that has no cache
	# yet: dragging a spline on a freshly created Mound reaches the dirty-rect path first.
	if _wants_deferred_bake():
		await _bake_deferred(bake, _layer_owner, false)
	else:
		bake.call()
	# Record the transform this bake reflects, so a later no-op TRANSFORM_CHANGED (tab switch) is skipped.
	_last_baked_xform = global_transform


## ---- The paint cycle (layer-granular: repaint every tool bound to the layer) ----

## The Refresh button. Records an undoable action so Ctrl+Z reverts the bake — needed for the
## auto_refresh-off / manual-bake workflow (and harmless when auto_refresh is on). Auto-refresh and
## property-driven repaints DON'T record their own action: their undoable cause (the spline gizmo edit
## or the inspector property change) re-triggers auto-refresh on undo, so the terrain follows.
func _refresh_button() -> void:
	refresh(true)


func refresh(record_undo: bool = false) -> void:
	if not Engine.is_editor_hint() or not is_configured():
		return
	if _wants_deferred_bake():
		await _bake_deferred(_refresh_owner.bind(_layer_owner, false, []), _layer_owner, record_undo)
		return
	_refresh_owner(_layer_owner, record_undo, [])


## Force every child spline to repaint and re-evaluate modifiers immediately.
func force_bake_modifiers() -> void:
	if not Engine.is_editor_hint() or not is_configured():
		return
	for s in _get_splines():
		if is_instance_valid(s):
			_dirty_splines[s.get_instance_id()] = true
	_stamp_cache.clear()
	refresh(false)


## Refresh a whole tool layer: clear every bound tool's footprints (+ any extras), repaint every bound
## tool's splines, then one GPU push. Sharing means editing one tool must repaint its layer-mates so an
## overlapping mate isn't left wiped (the road-connector partial-refresh hazard); with the O(cells)
## rasteriser each bake is cheap. `extra_clears` lets a rebind also drop a departing tool's footprint.
func _refresh_owner(owner: String, record_undo: bool, extra_clears: Array) -> void:
	if not is_configured():
		return
	var sibs := _tools_on_owner(owner)
	var layer_id := _ensure_layer_for(owner, owner == _layer_owner)
	var can_undo := record_undo and _layers_api_available() and layer_id >= 0
	var ur: EditorUndoRedoManager = _editor_undo() if can_undo else null
	var before: Dictionary = _snapshot_owner(owner) if (ur != null) else {}

	# Targeted GPU push (only the regions this bake touches) for the common refresh/placement/edit paths —
	# this is what removed the multi-second freeze when placing a brush. The DETACH/rebind paths (undo,
	# terrain-change, predelete) pass a non-empty extra_clears: those repaint the WHOLE layer's worth of
	# tools and rely on the all-regions rebuild to refresh every region's GPU slice — the targeted per-region
	# push left distant tools visually stale ("cut off") on undo, so they keep the original full push.
	var targeted_push := layer_id >= 0 and extra_clears.is_empty()
	if layer_id >= 0:
		if targeted_push:
			# Clean edited-flag slate so the targeted push uploads EXACTLY the regions this bake touches
			# (the clear/paint/composite below re-flag them via composite_region). Mirrors the dirty-rect path.
			_clear_region_edited_flags()
		var blend := _layer_blend_for(layer_id)
		# Union of everything this bake will write, so the deferred composite below covers all of it.
		var painted_box := AABB()
		for box: AABB in extra_clears:
			if box.size != Vector3.ZERO:
				terrain.data.clear_layer_in_area(layer_id, box)
				painted_box = box if painted_box.size == Vector3.ZERO else painted_box.merge(box)
		for s in sibs:
			for box: AABB in s._own_footprints():
				if box.size != Vector3.ZERO:
					terrain.data.clear_layer_in_area(layer_id, box)
					painted_box = box if painted_box.size == Vector3.ZERO else painted_box.merge(box)
			s._last_paint_aabb.clear()
		# (B) Snap AFTER the clear: with this tool's influence removed and the region recomposited,
		# get_height reads the BASE the points should sit on — not the tool's own ridge — so points
		# can't climb their own contribution on each refresh. Snapping moves Y only, so the footprints
		# just cleared (XZ) stay valid, and unchanged points are skipped (idempotent).
		for s in sibs:
			s._layer_id = layer_id # set before snap reads the below-layer height
			if s.snap_to_surface:
				s._apply_surface_snap()
		# Defer the composite exactly as the dirty-rect path does. Without this the rasteriser takes its
		# per-cell write path and calls composite_region on a 1x1 rect FOR EVERY CELL
		# ([pasture_3d_brush_raster.cpp:362](src/pasture_3d_brush_raster.cpp:362)) — an Image allocation, a
		# get_data, a set_data and a blit_rect each time — which also disables the batched raw-tile apply.
		# That is O(cells) heap traffic and was the whole cost of a large bake: a 2 km pond spent 13.3 s
		# here, ~3.4 us per cell, against 34 ms for a 100 m one. See PASTURE3D_POND_LARGE_LAKE_SPEC.md §3.
		#
		# Safe because it makes the full refresh behave like the dirty-rect refresh, which has shipped this
		# way since Round 2: brushes read the ground BELOW their own layer (composite_height_below), which
		# does not depend on this layer being composited, and two tools on one layer are combined by
		# _stamp_write's same-layer blend rather than by reading each other back through get_height.
		for s in sibs:
			s._defer_composite = true
		for s in sibs:
			s._paint_into(layer_id, blend)
		for s in sibs:
			s._defer_composite = false
		if painted_box.size != Vector3.ZERO:
			terrain.data.composite_area(painted_box, false)
	else:
		# Fallback: no layers Tool API → destructive writes (no own-layer to clear). Snap against the
		# live surface as a best effort; the non-destructive path above is the supported one.
		for s in sibs:
			s._layer_id = layer_id # set before snap reads the below-layer height
			if s.snap_to_surface:
				s._apply_surface_snap()
		for s in sibs:
			s._paint_into(-1, _get_blend_mode())

	# GPU push — targeted (edited-regions-only) for placement/edit, full all-regions for detach/rebind and
	# the destructive fallback (see targeted_push above).
	if targeted_push:
		terrain.data.update_maps(_map_type(), false, false)
	else:
		terrain.data.update_maps(_map_type())
	update_gizmos() # re-float the origin marker onto the new surface height

	if ur != null:
		var after := _snapshot_owner(owner)
		ur.create_action("Pasture3D %s Bake" % _spline_basename())
		ur.add_do_method(self, "_restore_owner", owner, after)
		ur.add_undo_method(self, "_restore_owner", owner, before)
		ur.commit_action(false)

	# After the GPU push, so a listener that reads get_height() sees this bake and not the
	# previous one.
	_emit_baked(sibs)
	# §18.5: the preview is built from the surface below this layer, which this bake may have moved.
	for s in sibs:
		s._queue_mask_preview()


## True when a bake from here might have to BUILD something expensive rather than serve it — solve an
## erosion modifier, or grow a DLA's cluster — and so should go through the deferred driver instead of
## freezing the editor for the length of it.
##
## Deliberately optimistic: it does not try to predict whether the caches will hit, because the only
## honest way to know is to hash the surface (or the growth inputs), which means baking. Pass 1 answers
## it for real — a bake that finds everything already built produces no pending work and the driver
## returns after one pass.
func _wants_deferred_bake() -> bool:
	if not (Engine.is_editor_hint() or force_deferred_erosion):
		return false
	if _erosion_running or _task_id != -1:
		return false
	if not is_inside_tree():
		return false # `_solve_on_worker` yields on the scene tree, and a detached node has none
	for s in _tools_on_owner(_layer_owner):
		if not is_instance_valid(s):
			continue
		for m in s.erosion_modifiers():
			if m.evaluation == Pasture3DNode.Evaluation.FROZEN:
				return true
		if s._has_growing_relief():
			return true
		if s._has_graph_modifier():
			return true
	return false


## True when any relief modifier here carries a material with an expensive build in it (a DLA, at any
## depth in a stack). Asked before the bake, so it answers "could this need growing", not "does it now".
func _has_growing_relief() -> bool:
	if not _supports_modifiers():
		return false
	for m in modifiers:
		if m is Pasture3DNodeRelief and m.enabled and m.material != null and m.material.has_growth():
			return true
	return false


## True when any active modifier here is a Pasture3DNodeGraph that requires deferred solving.
func _has_graph_modifier() -> bool:
	if not _supports_modifiers():
		return false
	for m in modifiers:
		if m is Pasture3DNodeGraph and m.is_active():
			if m.evaluation == Pasture3DNode.Evaluation.FROZEN and m.has_cache():
				continue
			return true
	return false


## Bake, solve off the main thread, bake again. `p_bake` is the ordinary synchronous bake with its
## arguments already bound, so the dirty-rect path and the whole-layer path share this driver and neither
## of them learns anything about threads.
##
## Records the undo action ITSELF, around all three passes: `_refresh_owner`'s own snapshot pair would
## take "before" from pass 3, which is the un-eroded terrain pass 1 left — so Ctrl+Z would restore the
## intermediate state rather than the one the user was looking at.
func _bake_deferred(p_bake: Callable, p_owner: String, p_record_undo: bool) -> void:
	if _erosion_running:
		return
	_erosion_running = true
	var can_undo := p_record_undo and _layers_api_available()
	var before: Dictionary = _snapshot_owner(p_owner) if can_undo else {}

	# ---- Phase A: grow every outstanding relief field & collect graph solves
	var pending_erosion: Array = []
	var pending_graph: Array = []
	for _round in range(GROWTH_ROUNDS):
		_pending_erosion = []
		_pending_growth = []
		_pending_graph = []
		_erosion_defer = true
		_growth_defer = true
		_graph_defer = true
		p_bake.call()
		_erosion_defer = false
		_growth_defer = false
		_graph_defer = false
		pending_erosion = _pending_erosion
		pending_graph = _pending_graph
		_pending_erosion = []
		_pending_graph = []
		var grows := _dedup_growth(_pending_growth)
		_pending_growth = []
		if grows.is_empty():
			break
		if not await _grow_pending(grows):
			_erosion_running = false
			_commit_deferred_undo(p_owner, before, can_undo)
			print("%s: growth cancelled — the brush is showing the mountain it already had." % name)
			return

	# ---- Phase B: solve pending graphs on worker thread
	if not pending_graph.is_empty():
		var ok_graph := await _solve_graph_pending(pending_graph)
		if ok_graph:
			for st: Dictionary in pending_graph:
				if st.has("zo"):
					(st["mod"] as Pasture3DNodeGraph).store_cache(st["extent"], {
						"key": st["key"],
						"grid": st["zo"],
					})

	# ---- Phase C: the erosion solve, against the surface phase A & B finished.
	if pending_erosion.is_empty():
		if not pending_graph.is_empty():
			p_bake.call()
		_erosion_running = false
		_commit_deferred_undo(p_owner, before, can_undo)
		return

	var ok := await _solve_erosion_pending(pending_erosion)
	if ok:
		for st: Dictionary in pending_erosion:
			_store_solved_erosion(st)
	p_bake.call()
	_erosion_running = false
	_commit_deferred_undo(p_owner, before, can_undo)
	if not ok:
		# The layer holds the UN-ERODED shape now, which is what pass 1 painted. Said out loud rather
		# than left to be discovered: a cancelled solve that quietly looked like a finished one would be
		# the worst outcome of the whole feature.
		print("%s: erosion cancelled — the brush is showing its un-eroded shape. Bake again to solve."
				% name)


## One action over the whole three-pass bake, or none when there was nothing undoable to record.
func _commit_deferred_undo(p_owner: String, p_before: Dictionary, p_can_undo: bool) -> void:
	if not p_can_undo:
		return
	var ur: EditorUndoRedoManager = _editor_undo()
	if ur == null:
		return
	var after := _snapshot_owner(p_owner)
	ur.create_action("Pasture3D %s Bake" % _spline_basename())
	ur.add_do_method(self, "_restore_owner", p_owner, after)
	ur.add_undo_method(self, "_restore_owner", p_owner, p_before)
	ur.commit_action(false)


## How many grow-then-bake rounds the driver's phase A will run before giving up on reaching a steady
## state. Two is enough for everything that exists — one to grow, one to discover nothing more is asked —
## and a seeded DLA under a second seeded DLA would want three. The cap is here so a material that never
## reported itself satisfied would produce a slow bake rather than an editor that never comes back.
const GROWTH_ROUNDS := 4


## One entry per MATERIAL. `collect_growth` is called once per bake grid, so a brush with four loops asks
## four times for the one mountain its material holds — and a grown field belongs to the material, not to
## the grid it was asked for on.
func _dedup_growth(p_requests: Array) -> Array:
	var seen := {}
	var out: Array = []
	for m in p_requests:
		if m == null or seen.has(m):
			continue
		seen[m] = true
		out.append(m)
	return out


## Grow every outstanding relief field on a worker, yielding frames here. Returns false when it was
## cancelled or the node stopped being a valid thing to write into.
func _grow_pending(p_mats: Array) -> bool:
	var states: Array = []
	for m in p_mats:
		states.append({"mat": m, "done": 0})
	print("%s: growing %d relief field(s) — the mountain appears when it lands…" % [name, states.size()])
	var t0 := Time.get_ticks_msec()
	_cancel = false
	_running = true
	var last_bucket := -1
	var ok: bool = await _solve_on_worker(states, "%s: growing relief" % name,
			func() -> void:
				# WHICH ONE and HOW LONG, on a five-second heartbeat. A percentage is not available and
				# would have to be invented: a DLA's growth is a particle walk with no iteration counter
				# to read, unlike the erosion solver, which bumps one from inside its own loop. A made-up
				# bar that jumps from 0 to 100 tells the user less than the truth does.
				var done := 0
				for st: Dictionary in states:
					done += int(st["done"])
				var secs := (Time.get_ticks_msec() - t0) / 1000
				if secs / 5 == last_bucket / 5:
					return
				last_bucket = secs
				print("%s: growing relief field %d of %d (%ds)" % [name, mini(done + 1, states.size()),
						states.size(), secs]),
			_grow_one)
	_running = false
	if not ok:
		return false
	# MAIN THREAD, and the only place a grown field is written back. Skips a state the worker never
	# reached, which cancellation above has already returned on — belt and braces against a partial run
	# being filed as a complete one.
	var grown := 0
	for st: Dictionary in states:
		if not st.has("field"):
			continue
		(st["mat"] as Pasture3DReliefMaterial).store_growth(st)
		grown += 1
	print("%s: grew %d relief field(s), %d ms." % [name, grown, Time.get_ticks_msec() - t0])
	return true


## Grow one material, in ONE call. RUNS ON A POOL THREAD: `grow_into` writes into the state dictionary
## and never into the material, so nothing here races a compile on the main thread.
func _grow_one(p_state: Dictionary) -> bool:
	if int(p_state["done"]) > 0:
		return true
	(p_state["mat"] as Pasture3DReliefMaterial).grow_into(p_state)
	p_state["done"] = 1
	return true


## Run every pending terrain graph solve on a worker, yielding frames here.
func _solve_graph_pending(p_pending: Array) -> bool:
	print("%s: evaluating terrain graph on %d grid(s)…" % [name, p_pending.size()])
	var t0 := Time.get_ticks_msec()
	_cancel = false
	_running = true
	var ok: bool = await _solve_on_worker(p_pending, "%s: evaluating graph" % name,
			Callable(), _graph_solve_one)
	_running = false
	if ok:
		print("%s: evaluated %d terrain graph grid(s), %d ms." % [name, p_pending.size(), Time.get_ticks_msec() - t0])
	return ok


func _graph_solve_one(p_state: Dictionary) -> bool:
	if int(p_state.get("done", 0)) > 0:
		return true
	var g: Pasture3DTerrainGraph = p_state["graph"]
	p_state["zo"] = g.evaluate(p_state["gw"], p_state["gh"], p_state["rect"], null, p_state["z"])
	p_state["done"] = 1
	return true


## Drop every relief material's grown field, so the next bake grows it again. The relief counterpart to
## `clear_erosion_caches`, and what Bake All Brushes needs for the same reason: a DLA defaults to FROZEN,
## so a bake that did not clear first would serve the mountain it already had and the button would appear
## to do nothing. Returns how many were cleared.
func clear_relief_growth() -> int:
	var n := 0
	if not _supports_modifiers():
		return n
	for m in modifiers:
		if m is Pasture3DNodeRelief and m.material != null:
			n += m.material.clear_growth()
	return n


## Run every pending solve on a worker, yielding frames here. Returns false when it was cancelled or the
## node stopped being a valid thing to write into.
func _solve_erosion_pending(p_pending: Array) -> bool:
	var cells := 0
	var iters := 0
	for st: Dictionary in p_pending:
		cells += int(st["gw"]) * int(st["gh"])
		iters += int(st["iterations"])
	print("%s: solving erosion on %d grid(s), %d cells, %d iteration(s)…"
			% [name, p_pending.size(), cells, iters])
	var t0 := Time.get_ticks_msec()
	_cancel = false
	_running = true
	var last_pct := -1
	var ok: bool = await _solve_on_worker(p_pending, "%s: eroding" % name,
			func() -> void:
				# Two sources, because neither is enough alone: the finished states contribute whole
				# iteration counts, and the one in flight contributes a counter the SOLVER bumps from
				# inside its own loop. Clamped, because right after a grid finishes both briefly claim
				# the same iterations and a percentage that goes past 100 reads as a bug.
				var done := 0
				for st: Dictionary in p_pending:
					done += int(st["done"])
				var cur: Vector2i = terrain.data.erosion_progress()
				done = mini(done + cur.x, iters)
				var pct := int(100.0 * float(done) / float(maxi(iters, 1)))
				# Bucketed, not per frame. The Sim prints every frame it yields, which on a long solve
				# buries everything else in the Output panel; a line that repeats is a line nobody reads.
				if pct / 5 == last_pct / 5:
					return
				last_pct = pct
				print("%s: eroding %d%% (%d of %d iterations)" % [name, pct, done, iters]),
			_erosion_solve_one)
	_running = false
	if not ok:
		return false
	var failed := 0
	for st: Dictionary in p_pending:
		if bool(st["failed"]):
			failed += 1
	if failed > 0:
		push_warning(("%s: the erosion solver rejected %d of %d grid(s), so those were left un-eroded. "
			+ "Nothing was silently half-solved.") % [name, failed, p_pending.size()])
	print("%s: eroded %d grid(s), %d cells, %d ms." % [name, p_pending.size() - failed, cells,
			Time.get_ticks_msec() - t0])
	return true


## Solve one pending grid, in ONE call — see the driver's header for why it is not chunked.
##
## RUNS ON A POOL THREAD: it may touch nothing but its own state dictionary and
## `terrain.data.erode_heightfield`, which copies its arguments into std::vectors and copies the result
## back out. Returns true always, because one call is the whole solve; the shape is `_solve_on_worker`'s.
func _erosion_solve_one(p_state: Dictionary) -> bool:
	if bool(p_state["failed"]) or int(p_state["done"]) > 0:
		return true
	var params: Dictionary = (p_state["params"] as Dictionary).duplicate()
	params["gw"] = p_state["gw"]
	params["gh"] = p_state["gh"]
	params["cell_size"] = terrain.vertex_spacing
	params["time_step"] = 1.0
	params["iterations"] = p_state["iterations"]
	params["want_diagnostics"] = p_state["want_diagnostics"]
	var res: Dictionary = terrain.data.erode_heightfield(p_state["z"], params,
			params.get("erodability_lut", PackedFloat32Array()))
	if not bool(res.get("ok", false)):
		p_state["failed"] = true
		p_state["done"] = p_state["iterations"]
		return true
	p_state["z"] = res["z"]
	p_state["res"] = res
	p_state["done"] = p_state["iterations"]
	return true


## Put one finished solve into its modifier's frozen cache, in exactly the shape a cache HIT expects.
##
## The four channels are computed here rather than taken from the solver because two of them are not the
## solver's to give: erosion and deposition are the difference between the surface that went in and the
## one that came out, over the WHOLE solve rather than the last chunk. Same conversions
## `_publish_erosion_fields` makes — positive metres removed, positive metres gained — so a FLOW or
## EROSION band means the same thing whether it was solved on this thread or that one.
func _store_solved_erosion(p_state: Dictionary) -> void:
	if bool(p_state["failed"]):
		return
	var m: Pasture3DNodeErosion = p_state["mod"]
	var z0: PackedFloat32Array = p_state["z0"]
	var zo: PackedFloat32Array = p_state["z"]
	var entry := {"key": int(p_state["key"]), "grid": zo,
			"flow": PackedFloat32Array(), "ero": PackedFloat32Array(),
			"dep": PackedFloat32Array(), "wet": PackedFloat32Array()}
	var res: Dictionary = p_state["res"]
	var n := zo.size()
	var flow: PackedFloat32Array = res.get("flow", PackedFloat32Array())
	var wet: PackedFloat32Array = res.get("lake_depth", PackedFloat32Array())
	if m.publish_fields and flow.size() == n and wet.size() == n:
		var ero := PackedFloat32Array()
		var dep := PackedFloat32Array()
		ero.resize(n)
		dep.resize(n)
		for i in range(n):
			var d: float = zo[i] - z0[i]
			if not is_finite(d):
				d = 0.0
			ero[i] = maxf(-d, 0.0)
			dep[i] = maxf(d, 0.0)
		entry["flow"] = flow
		entry["ero"] = ero
		entry["dep"] = dep
		entry["wet"] = wet
	m.store_cache(String(p_state["extent"]), entry)


## Bake this brush's layer with every erosion modifier suppressed, so the layer holds the shape the
## brushes on it make BEFORE they erode, and drop the frozen solves that were holding the old answer.
##
## This is pass 1 of the deferred driver with the captured surfaces thrown away instead of solved — the
## same bake, minus the two steps that put the erosion back. Returns how many frozen solves it dropped.
##
## NOT a state the brush remembers: the next ordinary bake solves again. That is deliberate and it is what
## makes the button safe to press — it takes the erosion off what is on the ground right now, and Bake
## All Brushes (or any refresh) puts it back. A persistent "eroded: off" would be a second, invisible copy
## of the `enabled` checkbox that is already on every modifier.
func bake_without_erosion(p_owner: String) -> int:
	var dropped := clear_erosion_caches()
	_pending_erosion = []
	_erosion_suppress = true
	_refresh_owner(p_owner, false, [])
	_erosion_suppress = false
	# Whatever pass 1 captured is discarded here, unsolved. That IS the clear.
	_pending_erosion = []
	return dropped


## Abandon a deferred solve in flight. The layer is left holding pass 1's un-eroded shape, and
## `_bake_deferred` says so.
func cancel_erosion() -> void:
	if _erosion_running:
		_cancel = true


## Dirty-rect refresh (Stage 1 partial redraw): one or more of THIS node's splines moved. Rework only the
## box they touched instead of the whole layer. The box = ∪ of each changed spline's previous∪current
## footprint; we clear just that box, then repaint every tool on the layer whose footprint intersects it,
## with each paint CLIPPED to the box. Tools/splines outside the box are untouched. Repainting overlapping
## layer-mates inside the box (not just the moved spline) is what keeps shared cells correct — the same
## reason the full refresh repaints mates. Auto-refresh only (no undo action; the gizmo edit is the
## undoable cause). Falls back to a full refresh when there's no layers Tool API or nothing locatable.
func _refresh_owner_rect(owner: String, changed_ids: Dictionary, snap_all: bool = false) -> void:
	if not is_configured():
		return
	var layer_id := _ensure_layer_for(owner, owner == _layer_owner)
	if layer_id < 0:
		# Destructive fallback has no per-area clear — the whole-layer path is the only correct option.
		_refresh_owner(owner, false, [])
		return
	_layer_id = layer_id # set before the snap below reads it (paint sets it again per tool)

	# Union the previous (cached) and current footprint of changed sections into one world box.
	#
	# The previous box goes to `_spline_dirty_aabb` rather than being merged here, because only IT knows
	# whether it needed it: the partial-section path re-derives its own previous component from
	# `_curve_cache` and must stay narrow, while the whole-spline fallback has no way to know where the
	# brush was and would otherwise leave the old cut uncleared. See the note on that function.
	var dirty := AABB()
	var have := false
	for sid in changed_ids:
		var path := _find_spline_by_id(sid)
		var prev: AABB = _last_paint_aabb.get(sid, AABB())
		if path != null:
			var moved := _moved_point_indices(path) if not snap_all else PackedInt32Array()
			var curr := _spline_dirty_aabb(path, moved, prev)
			if curr.size != Vector3.ZERO:
				dirty = curr if not have else dirty.merge(curr)
				have = true
		elif prev.size != Vector3.ZERO:
			dirty = prev if not have else dirty.merge(prev)
			have = true
	if not have:
		# Splines vanished (e.g. removed) — let the full path reconcile the layer.
		_refresh_owner(owner, false, [])
		return

	# CRITICAL: clear_layer_in_area drops WHOLE tiles (tile_size verts) that the box touches, so the area
	# actually cleared is the box grown out to tile boundaries — larger than `dirty`. Clip the repaint to
	# that SAME grown box, or a neighbour's samples in a dropped tile outside `dirty` are erased and never
	# repainted (the far-away "cut"). Tile boundaries sit at world multiples of tile_size * vertex_spacing.
	var clip_box := _snap_aabb_to_tiles(dirty, _layer_tile_world(layer_id))

	var blend := _layer_blend_for(layer_id)
	var t_start := Time.get_ticks_usec()
	# Start from a clean edited-flag slate so the targeted update_maps below uploads EXACTLY the regions
	# this bake touches. composite_region sets is_edited but update_maps never clears it, so without this
	# every later partial would re-push every region edited this session (the far-spline slowdown).
	_clear_region_edited_flags()
	# Clear the dropped tiles AND composite the (tile-bounded) box back to base. This composite is required
	# before painting: the rasterisers read get_height per cell for relative_to_terrain / follow_spline_height,
	# so they must see the cleared base (not this tool's own previous dome) or the feature climbs each edit.
	terrain.data.clear_layer_in_area(layer_id, clip_box)
	var t_clear := Time.get_ticks_usec()
	# Re-seat ONLY the points the user actually moved, against the freshly-cleared base inside the box.
	# Snapping every point here is the snap-to-self regression: an unmoved point elsewhere reads terrain
	# the box clear didn't touch (its own ridge) and climbs. A whole-spline / node move instead takes the
	# full-refresh path, which clears everything first and re-snaps all points. Snap is world-Y only, so
	# the XZ box just cleared stays valid.
	if snap_to_surface:
		for sid in changed_ids:
			var sp := _find_spline_by_id(sid)
			if sp != null:
				# A node move shifts every point's world XZ but leaves the local curve unchanged, so the
				# moved-point diff finds nothing — re-snap all points against the freshly-cleared base.
				var idxs := _all_point_indices(sp) if snap_all else _moved_point_indices(sp)
				_apply_surface_snap_points(sp, idxs)
	var t_snap := Time.get_ticks_usec()
	var painted := 0
	for s in _tools_on_owner(owner):
		if not s._overlaps_box(clip_box):
			continue
		s._clip_aabb = clip_box
		s._defer_composite = true # write samples only; we composite the whole box once below
		s._paint_into(layer_id, blend)
		s._defer_composite = false
		s._clip_aabb = AABB()
		painted += 1
	var t_paint := Time.get_ticks_usec()
	# Composite the whole footprint ONCE instead of per painted pixel — the big win for large edits.
	terrain.data.composite_area(clip_box, false)
	var t_composite := Time.get_ticks_usec()
	# Remember the (possibly snapped) point layout so the next edit only re-snaps what changes again.
	for sid in changed_ids:
		var cp := _find_spline_by_id(sid)
		if cp != null:
			_update_curve_cache(cp)
	# Push only the regions this bake actually edited. (The bound default is all_regions=TRUE, which
	# rebuilds the whole height texture array from every region — the reason a far-away spline was slow.)
	terrain.data.update_maps(_map_type(), false, false)
	update_gizmos() # re-float the origin marker onto the new surface height
	# Only the tools that were actually repainted inside the box: the rest of the layer's
	# height is untouched, so waking their listeners would be a rebuild for nothing.
	_emit_baked(_tools_on_owner(owner).filter(func(s): return s._overlaps_box(clip_box)))
	# §18: a spline drag takes THIS path, not the full refresh, and moving the loop moves the preview's
	# area mask — so the overlay has to follow the handle rather than waiting for the next full bake.
	_queue_mask_preview()
	if log_bake_timing:
		_log_bake_timing(clip_box, painted, t_start, t_clear, t_snap, t_paint, t_composite, Time.get_ticks_usec())


## Emit `baked` on each tool in p_tools. Guarded per tool because this reaches across nodes:
## a layer-mate that has left the tree between the bake starting and finishing must not take
## the whole bake down with it.
func _emit_baked(p_tools) -> void:
	for s in p_tools:
		if s != null and is_instance_valid(s):
			s.baked.emit()


## Clear the per-region "edited" GPU-push flag on every active region. update_maps(all_regions=false)
## pushes flagged regions but doesn't reset the flag, so the dirty-rect bake clears the slate first and
## lets its own clear/paint re-flag exactly what it touched. Safe to clear globally: the brush's undo uses
## layer-tile snapshots (not this flag), and the editor's sculpt brush sets+clears it within one operation.
func _clear_region_edited_flags() -> void:
	if not terrain or not terrain.data or not terrain.data.has_method("get_region_locations") \
			or not terrain.data.has_method("get_region"):
		return
	for loc in terrain.data.get_region_locations():
		var r = terrain.data.get_region(loc)
		if r and r.has_method("set_edited"):
			r.set_edited(false)


## Print the partial-bake timing breakdown to Output (enabled by log_bake_timing). Splits the µs spent in
## the layer clear (now a tile-bounded recomposite), point snap + rasterise, the per-cell sample writes,
## the single box composite, and the GPU push, plus the box size and how many regions the box spans.
func _log_bake_timing(box: AABB, painted: int, t_start: int, t_clear: int, t_snap: int, t_paint: int, t_composite: int, t_push: int) -> void:
	var region_span := 1
	if terrain and terrain.data and terrain.data.has_method("get_region_location"):
		var rl0: Vector2i = terrain.data.get_region_location(box.position)
		var rl1: Vector2i = terrain.data.get_region_location(box.position + box.size)
		region_span = (absi(rl1.x - rl0.x) + 1) * (absi(rl1.y - rl0.y) + 1)
	print("[Pasture3D bake] %s | total %d us = clear %d + snap %d + paint %d + composite %d + push %d | box %.0fx%.0fm, %d region(s), %d tool(s)" % [
		name, t_push - t_start, t_clear - t_start, t_snap - t_clear, t_paint - t_snap, t_composite - t_paint, t_push - t_composite,
		box.size.x, box.size.z, region_span, painted])


## A direct Path3D child of this node by instance id, or null (e.g. it was removed before the bake ran).
func _find_spline_by_id(id: int) -> Path3D:
	for c in get_children():
		if c is Path3D and c.get_instance_id() == id:
			return c
	return null


## True if any of this node's spline footprints overlaps `box` (XZ; footprint Y spans are nominal). Drives
## which layer-mates a dirty-rect refresh must repaint.
func _overlaps_box(box: AABB) -> bool:
	for s in _get_splines():
		var fp := _spline_footprint_aabb(s)
		if fp.size != Vector3.ZERO and fp.intersects(box):
			return true
	return false


## Grow a world box outward in XZ to the layer's tile grid (multiples of `step`), so it coincides exactly
## with the set of tiles clear_layer_in_area will drop. Y (the nominal footprint span) is left untouched.
func _snap_aabb_to_tiles(box: AABB, step: float) -> AABB:
	if step <= 0.0:
		return box
	var min_x := floorf(box.position.x / step) * step
	var min_z := floorf(box.position.z / step) * step
	var max_x := ceilf((box.position.x + box.size.x) / step) * step
	var max_z := ceilf((box.position.z + box.size.z) / step) * step
	return AABB(Vector3(min_x, box.position.y, min_z), Vector3(max_x - min_x, box.size.y, max_z - min_z))


## World size of one layer tile edge = tile_size (verts) * vertex_spacing. Tile boundaries land on world
## multiples of this (region_size is a multiple of tile_size, so the grid is global with no half-offset).
func _layer_tile_world(layer_id: int) -> float:
	var vs: float = terrain.vertex_spacing if terrain else 1.0
	var layer := _layer_at(layer_id)
	var ts := 64
	if layer and layer.has_method("get_tile_size"):
		ts = layer.get_tile_size()
	return float(ts) * vs


## Paint this node's splines into the given layer (-1 = destructive). Records the per-spline footprint
## cache. Driven by _refresh_owner for self and every layer-mate.
func _paint_into(layer_id: int, blend: int) -> void:
	_layer_id = layer_id
	_blend = blend
	var clipping := _clip_aabb.size != Vector3.ZERO
	for path in _get_splines():
		if not _spline_paintable(path):
			continue
		# Dirty-rect repaint: a spline that doesn't touch the box contributes nothing inside it — skip its
		# whole rasterise (its cached footprint outside the box is untouched and stays valid).
		if clipping and not _spline_footprint_aabb(path).intersects(_clip_aabb):
			continue
		var sid: int = path.get_instance_id()
		var skey: int = _compute_stamp_key(path)
		var sc: Dictionary = _stamp_cache.get(sid, {})
		if layer_id >= 0 and not sc.is_empty() and not _dirty_splines.has(sid) and int(sc.get("key", 0)) == skey:
			terrain.data.apply_sim_block(layer_id, sc["min_x"], sc["min_z"], sc["vs"], sc["gw"], sc["gh"], sc["vals"], blend)
			_last_paint_aabb[sid] = sc["bounds"]
			continue
		_paint_spline(path)
		if layer_id >= 0:
			_last_paint_aabb[path.get_instance_id()] = _spline_footprint_aabb(path)


## ---- Brush Stamp Caching ----

func _compute_stamp_key(path: Path3D) -> int:
	if not is_instance_valid(path) or path.curve == null:
		return 0
	return hash([
		global_transform,
		path.curve.get_baked_points(),
		_brush_param_signature(),
		_modifier_signature()
	])


func _brush_param_signature() -> Array:
	# `modifier_margin` changes the grid extent, so a cached stamp keyed without it would be reused at the
	# wrong size after a margin edit (the setter also clears the cache; this covers the undo/redo path).
	return [snap_to_surface, surface_offset, force_gdscript_raster, _effective_modifier_margin()]


func _modifier_signature() -> Array:
	var sig := []
	if _supports_modifiers():
		for m in modifiers:
			if m != null and m.is_active():
				var ck: int = m.content_key() if m.has_method("content_key") else 0
				sig.append([m.display_name(), m.to_params(), ck])
	return sig


func _store_stamp_cache(path: Path3D, p_key: int, p_min_x: float, p_min_z: float, p_vs: float, p_gw: int, p_gh: int, p_vals: PackedFloat32Array, p_bounds: AABB) -> void:
	if not is_instance_valid(path) or p_vals.is_empty():
		return
	_stamp_cache[path.get_instance_id()] = {
		"key": p_key,
		"min_x": p_min_x,
		"min_z": p_min_z,
		"vs": p_vs,
		"gw": p_gw,
		"gh": p_gh,
		"vals": p_vals,
		"bounds": p_bounds,
	}


func clear_stamp_cache() -> void:
	_stamp_cache.clear()


## Generate a 2D preview height grid [grid, w, h, rect] representing this brush's base spline shape.
func generate_preview_surface(w: int, h: int) -> Array:
	return []


## Every brush node bound to `owner` (same terrain). Includes self when `owner` is our binding.
func _tools_on_owner(owner: String) -> Array:
	var out: Array = []
	if is_inside_tree():
		for n in get_tree().get_nodes_in_group(BRUSH_GROUP):
			if n is Pasture3DTerrainBrush and is_instance_valid(n) and n.terrain == terrain and n._layer_owner == owner:
				out.append(n)
	if owner == _layer_owner and not out.has(self):
		out.append(self)
	return out


## Our current + previously-cached spline footprints (cleared off a layer before repaint / on rebind).
func _own_footprints() -> Array:
	var out: Array = []
	for s in _get_splines():
		var a := _spline_footprint_aabb(s)
		if a.size != Vector3.ZERO:
			out.append(a)
	for sid in _last_paint_aabb:
		var b: AABB = _last_paint_aabb[sid]
		if b.size != Vector3.ZERO:
			out.append(b)
	return out


## ---- Mask preview (PASTURE3D_SIM_NODE_SPEC.md §18) ----
##
## A red overlay on the terrain showing the weight a Pasture3DTerrainMask stack would apply, live, so a
## band is tuned by eye against the ground instead of by baking and inspecting. Shared here rather than on
## Pasture3DSim because the same selector resource gates the Plow's and Mound's relief materials.
##
## The rule the whole feature rests on: the preview calls `selector_mask_field`, the SAME function the bake
## calls. A GDScript approximation, a coarser field or a different source surface would mean tuning against
## a mask that will never run, which is worse than no preview at all.

## Per-axis cap on the preview texture. Beyond this the field is coarsened and `_show_mask_preview` says
## so — §18.3 asks for build resolution and means it, so the coarsening is reported rather than silent.
const MASK_PREVIEW_MAX: int = 1024
## Half-cell widening so world→uv lands on texel CENTRES. The grid is corner-aligned (§6), so without it
## the outermost row samples half a texel outside itself.
const MASK_PREVIEW_COLOR := Color(0.95, 0.15, 0.1, 0.65)

## The texture and world rect currently handed to the material, kept so the preview can be inspected
## (gate AS reads them) and so a rebuild can tell whether anything changed. Plain vars, NOT metadata and
## NOT exported: metadata is serialised with the scene, and an ImageTexture of a sim grid in a .tscn is
## megabytes of base64 for something that is rebuilt on demand anyway.
var _mask_preview_texture: ImageTexture = null
var _mask_preview_rect: Vector4 = Vector4()
## Which selector `mask_preview` shows: -1 = the relief material's own, 0..N-1 = that stack layer's.
## Persisted but hidden; the inspector shows it as the `Mask Preview Source` dropdown, whose entries are
## rebuilt from the live material so a layer added to the stack appears without reselecting the node.
@export_storage var _mask_preview_layer: int = -1
## The overlay toggle for brushes with a relief material, surfaced as `mask_preview` in the group above.
## Pasture3DSim keeps its own exported enum and never reads this.
@export_storage var _mask_preview_on: bool = false

## The selector `mask_preview` is currently pointed at, or null.
func _preview_selector(p_relief) -> Pasture3DTerrainMask:
	var sources := _preview_selector_sources(p_relief)
	var idx := _mask_preview_layer + 1
	if idx < 0 or idx >= sources.size():
		return null
	return sources[idx][1]


## Set between a change arriving and the deferred rebuild running, so a dozen property edits in one frame
## cost one rebuild. A slider drag emits roughly one change per frame, so this coalesces the burst
## without adding latency — a debounce TIMER would, and "live" is the whole point.
var _mask_preview_queued: bool = false


## Ask for a rebuild at the end of this frame. Connected to every selector's `changed`, so editing a band
## edge redraws the overlay as you drag it.
func _queue_mask_preview() -> void:
	if _mask_preview_queued:
		return
	_mask_preview_queued = true
	_run_queued_mask_preview.call_deferred()


func _run_queued_mask_preview() -> void:
	_mask_preview_queued = false
	_update_mask_preview()


## Connect (or disconnect) `changed` on every selector in a stack. A Pasture3DTerrainMask is a
## Resource, so editing Range Min in the inspector mutates it in place and fires `changed` — the node
## never hears about it otherwise, which is why the first build of §18 only updated when the toggle was
## flipped. Idempotent: a bound Callable compares equal across calls.
func _bind_mask_preview_signals(p_list: Array, p_connect: bool) -> void:
	for s in p_list:
		if s == null or not (s is Resource):
			continue
		if p_connect:
			if not s.changed.is_connected(_queue_mask_preview):
				s.changed.connect(_queue_mask_preview)
		elif s.changed.is_connected(_queue_mask_preview):
			s.changed.disconnect(_queue_mask_preview)


## Build the weight field for `p_selectors` over `p_box` (a world AABB) and hand it to the terrain
## material. Returns a one-line report, or "" when there was nothing to show.
##
## `p_sim` is the flattened Pasture3DSimResult the sim Filter Types read, or {}.
func _show_mask_preview(p_selectors: PackedFloat32Array, p_box: AABB, p_sim: Dictionary) -> String:
	if not is_configured() or p_selectors.is_empty() or p_box.size == Vector3.ZERO:
		_clear_mask_preview()
		return ""
	var mat = terrain.material
	if mat == null or not mat.has_method("set_mask_preview"):
		return "" # a build without the §18 material API; the toggle simply does nothing
	var vs: float = terrain.vertex_spacing
	var b := _snapped_bounds(p_box, vs)
	var cell := vs
	var gw := int(round((b[1] - b[0]) / cell)) + 1
	var gh := int(round((b[3] - b[2]) / cell)) + 1
	var note := ""
	if maxi(gw, gh) > MASK_PREVIEW_MAX:
		# Coarsen, and say so. A preview at a resolution the build will not use gates differently (§17.5),
		# so the one thing that must not happen is coarsening in silence.
		var s := float(maxi(gw, gh)) / float(MASK_PREVIEW_MAX)
		cell = vs * s
		gw = int(round((b[1] - b[0]) / cell)) + 1
		gh = int(round((b[3] - b[2]) / cell)) + 1
		note = " (COARSENED to %.2f m per cell, %.1fx the build's — slope and curvature bands will read differently)" % [cell, s]
	if gw < 2 or gh < 2:
		_clear_mask_preview()
		return ""

	# RESOLVE, never create. A preview that quietly adds a layer to the stack is not "leaves nothing
	# behind" — a brush that has never baked would grow one just by being looked at.
	#
	# When there is no layer yet, "below" is the WHOLE stack, not nothing: this brush will be appended at
	# the top on its first bake, so everything currently in the stack is what it will sit on. Passing -1
	# would make composite_height_below return all-NaN and the preview would come back blank on exactly
	# the brushes a first-time user is most likely to be looking at.
	var layer_id: int = terrain.data.find_layer_by_owner(_layer_owner)
	if layer_id < 0:
		var stack = terrain.data.get_layer_stack()
		layer_id = stack.get_layer_count() if stack != null else -1
	var below: PackedFloat32Array = _preview_below(layer_id, b[0], b[2], cell, gw, gh)
	if below.size() != gw * gh:
		_clear_mask_preview()
		return ""
	# Clip to where this brush actually acts. The selector weight is defined over the whole grid, but the
	# brush only applies it inside its own loop — so showing the raw weight paints the footprint RECTANGLE
	# and overstates the affected area, corners included. That is what the first editor test of this
	# feature reported, and it is a defect in the preview rather than in the mask.
	#
	# Handed to the field builder rather than multiplied in afterwards: a GDScript loop over the grid is
	# O(cells) interpreted, and this whole function runs on every frame of a slider drag.
	var field: PackedFloat32Array = terrain.data.selector_mask_field(below, {
			"gw": gw, "gh": gh, "cell_size": cell, "min_x": b[0], "min_z": b[2],
			"area_mask": _preview_area_mask(b[0], b[2], cell, gw, gh),
		}, p_selectors, p_sim)
	if field.size() != gw * gh:
		_clear_mask_preview()
		return ""

	# FORMAT_RF is one little-endian float32 per texel, which is exactly what a PackedFloat32Array already
	# is — so this is a memcpy, not gw*gh set_pixel calls. At the 1024 cap that is the difference between
	# a live preview and a slideshow.
	var img := Image.create_from_data(gw, gh, false, Image.FORMAT_RF, field.to_byte_array())
	# Half-cell widened so world→uv lands on texel CENTRES: the grid is corner-aligned, so sample (0,0)
	# sits at world (b[0], b[2]) and must map to uv 0.5/gw, not 0.
	var rect := Vector4(b[0] - cell * 0.5, b[2] - cell * 0.5, float(gw) * cell, float(gh) * cell)
	_mask_preview_texture = ImageTexture.create_from_image(img)
	_mask_preview_rect = rect
	mat.set_mask_preview(get_instance_id(), _mask_preview_texture, rect, MASK_PREVIEW_COLOR)
	return "mask preview: %dx%d cells at %.2f m over X %.0f..%.0f Z %.0f..%.0f%s" % [
			gw, gh, cell, b[0], b[1], b[2], b[3], note]


## The surface the preview evaluates its band against. The ground UNDER this brush's layer, which for
## every brush that stamps once is exactly the ground its bake will read.
##
## Overridable because §19.5's pass chain breaks that identity: pass N of a manager reads what pass N-1
## produced, not the pre-chain ground, and previewing a Slope band against a surface the chain has since
## cut by tens of metres is §21.8's D3. `Pasture3DSim` overrides this; nothing else needs to.
func _preview_below(p_layer_id: int, p_min_x: float, p_min_z: float, p_cell: float,
		p_gw: int, p_gh: int) -> PackedFloat32Array:
	return terrain.data.composite_height_below(p_layer_id, p_min_x, p_min_z, p_cell, p_gw, p_gh)


## Take the preview down, if this node still owns it. A no-op when another brush has claimed it since —
## a node cleaning up after itself must never blank somebody else's view.
func _clear_mask_preview() -> void:
	_mask_preview_texture = null
	_mask_preview_rect = Vector4()
	if not is_instance_valid(terrain):
		return
	var mat = terrain.material
	if mat != null and mat.has_method("clear_mask_preview"):
		mat.clear_mask_preview(get_instance_id())


## Why the mask overlay is showing nothing, when it is switched on and should be.
##
## Exists because the first build simply drew nothing when the chosen source had no selector — a toggle
## that does nothing with no explanation is indistinguishable from a broken one, which is the same
## defect Preview Water Features shipped with in phase 4. If the overlay is off, say why.
func _mask_preview_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	var relief = _preview_relief_material()
	if relief == null or not _mask_preview_on:
		return out
	var sources := _preview_selector_sources(relief)
	var idx := _mask_preview_layer + 1
	if idx < 0 or idx >= sources.size():
		out.append(("Mask Preview is on but Mask Preview Source points at a layer that no longer exists. "
			+ "Pick another source."))
		return out
	# The dropdown deliberately follows the first Relief modifier that HAS a material, not the first
	# active one, so that the property list does not move when a slider does (see `_preview_relief_material`
	# on Pasture3DMound). The cost is that the overlay can be showing a modifier that stamps nothing, and
	# an overlay whose relief is invisible on the terrain is exactly the confusion this warning family
	# exists to prevent.
	var previewed = _preview_relief_modifier()
	if previewed != null and not previewed.is_active():
		out.append(("Mask Preview is showing '%s', which is not stamping right now — %s. The overlay is "
			+ "where its selector WOULD put relief.") % [previewed.display_name(),
			"it is disabled" if not previewed.enabled else "its Strength is 0 m"])
	if sources[idx][1] == null:
		var others := PackedStringArray()
		for i in range(sources.size()):
			if i != idx and sources[i][1] != null:
				others.append(String(sources[i][0]))
		out.append(("Mask Preview is on but '%s' has no Selector, so there is nothing to show.%s")
			% [sources[idx][0], (" These do: %s." % ", ".join(others)) if not others.is_empty() else ""])
	# One level deep (§18.6): a layer that is itself a stack contributes its own selector, not its
	# children's, and a nested selector is not reachable from this dropdown at all.
	# TESTED BY CLASS, NOT BY PROPERTY NAME. `Pasture3DReliefStrata.layers` is an INT — the number of
	# bands — and duck-typing on the name read it as a stack's Array, which threw on every inspector
	# rebuild for any brush carrying a Strata material.
	if relief is Pasture3DReliefStack:
		var nested := PackedStringArray()
		for i in range((relief as Pasture3DReliefStack).layers.size()):
			var m = (relief as Pasture3DReliefStack).layers[i]
			if m is Pasture3DReliefStack and not (m as Pasture3DReliefStack).layers.is_empty():
				nested.append("Layer %d" % i)
		if not nested.is_empty():
			out.append(("Mask Preview lists one level of this stack. %s %s nested stack(s), whose own "
				+ "layers' selectors cannot be previewed — flatten them, or move the selector you want to "
				+ "see up a level.") % [", ".join(nested), "is a" if nested.size() == 1 else "are"])
	return out


## The relief material whose selector this brush can preview, or null.
##
## Every brush that has relief now keeps it in the modifier stack, so this scans `modifiers` HERE rather
## than being overridden per subclass. It used to return null and rely on subclasses; only Mound was ever
## given the override, so Plow — named in this very comment as one of the two — silently offered no Mask
## Preview dropdown at all. `Pasture3DSim` is on a different base and never reaches this.
##
## §18.6: the material whose selectors the Mask Preview Source dropdown lists — the first Relief modifier
## in the stack WITH A MATERIAL ASSIGNED. The overlay shows one material's selectors, and a stack with two
## of them has to pick; first is the honest pick, because it is the one whose gating decides what
## everything after it lands on.
##
## NOT `is_active()`, which was the first build and was wrong twice over. `is_active()` is false at
## `strength == 0`, so this dropdown — and therefore the node's whole property list — was A FUNCTION OF A
## SLIDER: dragging Strength up from 0 made the Mask Preview group appear, which rebuilt the inspector,
## which collapsed the modifier being edited, under the cursor. Toggling `enabled` did the same. See
## `_inspector_rebuild_signature`.
##
## It is also the better rule on its own terms: the preview exists to show WHERE a selector would put
## things, which is exactly what you want to look at before you decide how many metres to ask for.
## `_mask_preview_warnings` says so when the previewed modifier is not currently stamping.
func _preview_relief_material():
	for m in modifiers:
		if m is Pasture3DNodeRelief and m.material != null:
			return m.material
	return null


## The modifier `_preview_relief_material` took its material from, on hosts that keep relief in a stack.
## Null on hosts whose relief is a plain property — there is nothing there that can be switched off
## independently of the material being assigned.
func _preview_relief_modifier():
	for m in modifiers:
		if m is Pasture3DNodeRelief and m.material != null:
			return m
	return null


## Selectors a relief material offers for preview: the material's own first, then one per stack layer.
## Returns an Array of [label, Pasture3DTerrainMask-or-null], index 0 being the material's own.
##
## ONE level deep. A layer that is itself a `Pasture3DReliefStack` contributes its own selector and not
## its children's — listing a whole tree would need a path rather than an index, and the configuration
## warning says so rather than letting a nested selector look reachable.
## Each entry is `[label, selector-or-null, structural tag]`. The LABEL is cosmetic and may carry a
## `resource_name`; the TAG deliberately may not — see `_inspector_rebuild_signature`.
func _preview_selector_sources(p_relief) -> Array:
	var out: Array = [["Material Selector", p_relief.selector if p_relief != null else null,
			_relief_class_tag(p_relief)]]
	# See the note in `_mask_preview_warnings`: only a Stack has an ARRAY called `layers`, and a Strata
	# material's `layers` is the band count.
	if not (p_relief is Pasture3DReliefStack):
		return out
	var layers: Array = (p_relief as Pasture3DReliefStack).layers
	for i in range(layers.size()):
		var m = layers[i]
		# NO COLON in the label. `,` and `:` are both structural in a PROPERTY_HINT_ENUM hint string —
		# `:` assigns an explicit integer value — so "Layer 0: Fractal" made Godot read the whole list as
		# one broken entry and the dropdown offered nothing to choose between.
		out.append(["Layer %d (%s)" % [i, _relief_type_name(m)], m.selector if m != null else null,
				_relief_class_tag(m)])
	return out


## A layer's class alone, with no `resource_name` in it. The structural half of `_relief_type_name`,
## split out because the inspector-rebuild signature must not move when someone types a name.
func _relief_class_tag(p_material) -> String:
	if p_material == null:
		return "(empty)"
	var scr: Script = p_material.get_script()
	if scr != null and scr.has_method("get_global_name"):
		var n := String(scr.get_global_name())
		if n != "":
			return n.trim_prefix("Pasture3DRelief")
	return "Layer"


## A layer's class name for the dropdown ("Pasture3DReliefFractal" → "Fractal"), falling back to its
## resource name and then to nothing. Cosmetic: the index is what identifies the layer.
func _relief_type_name(p_material) -> String:
	if p_material == null:
		return "(empty)"
	if p_material.resource_name != "":
		return p_material.resource_name
	var scr: Script = p_material.get_script()
	if scr != null and scr.has_method("get_global_name"):
		var n := String(scr.get_global_name())
		if n != "":
			return n.trim_prefix("Pasture3DRelief")
	return "Layer"


## §18.6: preview one selector from a relief material over this brush's footprint. Pass null to drop it.
##
## `Pasture3DReliefMaterial.selector` gates every op the material emits and is index 0. A stack's
## per-LAYER selectors gate only their own layer's ops, so they cannot be combined into one honest field —
## but they are where a stack gets its power, so `mask_preview_source` picks WHICH one to look at instead
## of pretending a composite exists.
func _update_relief_mask_preview(p_relief) -> void:
	var sel := PackedFloat32Array()
	var sim: Dictionary = {}
	var chosen: Pasture3DTerrainMask = _preview_selector(p_relief)
	if chosen != null:
		sel.append_array(PackedFloat32Array(chosen.to_params()))
		# §21.8 D1: resolved the way the BAKE resolves it — `_relief_sim_result`, the first non-null
		# result anywhere in the stack — and NOT from `chosen.sim_result`. The bake hands the whole
		# compiled program one dict (see `_sim_result_for`), so a stack that carries its result on layer 0
		# gates layer 1 correctly and used to preview it blank. One resolver, one answer, by construction.
		if chosen.is_sim_filter_type():
			sim = _sim_result_dict(_relief_sim_result(p_relief))
	if sel.is_empty():
		_clear_mask_preview()
		return
	var box := AABB()
	var have := false
	for s in _get_splines():
		if not _spline_paintable(s):
			continue
		var a := _spline_footprint_aabb(s)
		box = a if not have else box.merge(a)
		have = true
	if not have:
		_clear_mask_preview()
		return
	var note := _show_mask_preview(sel, box, sim)
	if note != "":
		print("Pasture3D brush '%s': %s." % [name, note])


## Where this brush actually acts, as a 0..1 field over the preview grid — multiplied into the previewed
## weight so red never appears where nothing will happen.
##
## The default is the loop POLYGON, a hard edge: inside 1, outside 0. Deliberately not a reimplementation
## of each subclass's falloff ramp — Mound alone has two flank modes and a curve, and a second copy of
## that arithmetic would drift from the real one and quietly start lying, which is the failure this whole
## feature exists to avoid. A subclass whose exact area mask is already reachable overrides this and gets
## the soft edge for free; `Pasture3DSim` does.
##
## So on a stamp brush the red shows WHERE the mask applies, not how strongly the brush feathers there.
func _preview_area_mask(p_min_x: float, p_min_z: float, p_cell: float, p_gw: int, p_gh: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_gw * p_gh)
	var any := false
	for s in _get_splines():
		if not _spline_paintable(s):
			continue
		var poly := PackedVector2Array()
		for p in _baked_world_points(s):
			poly.append(Vector2(p.x, p.z))
		if poly.size() < 3:
			continue
		var sdf: Array = _signed_distance_field(poly, p_min_x, p_min_z, p_cell, p_gw, p_gh)
		var f: PackedFloat32Array = sdf[0]
		for i in range(p_gw * p_gh):
			if f[i] > 0.0:
				out[i] = 1.0
		any = true
	return out if any else PackedFloat32Array()


## Rebuild (or drop) this node's mask preview after anything that could have moved the ground under it
## — the field comes from `composite_height_below`, so a bake invalidates it.
##
## Rebuilding rather than clearing on purpose: §18.5 requires the preview never be stale, and a preview
## that vanishes every time you press Simulate reads as broken. Both are satisfied by recomputing it.
##
## This used to be a no-op that each brush with a toggle overrode. Only Mound ever did, so on Plow the
## Mask Preview toggle set a flag and nothing else happened — a dead switch, which is precisely the defect
## §18.6 exists to prevent. Now that `_preview_relief_material` scans the modifier stack here, the body is
## the same for every relief brush and lives once. A host whose preview is not a relief selector
## (`Pasture3DSim`, whose masks multiply into one field) still overrides.
func _update_mask_preview() -> void:
	_update_relief_mask_preview(_preview_relief_material() if _mask_preview_on else null)


## True when the terrain material is currently showing THIS node's preview. The material cannot call a
## node back, so a brush that has been out-bid finds out by asking.
func _owns_mask_preview() -> bool:
	if not is_instance_valid(terrain):
		return false
	var mat = terrain.material
	if mat == null or not mat.has_method("get_mask_preview_owner"):
		return false
	return int(mat.get_mask_preview_owner()) == get_instance_id()


## ---- Layer resolution / identity ----

func _layers_api_available() -> bool:
	return terrain != null and terrain.data != null \
		and terrain.data.has_method("create_owned_layer") and terrain.data.has_method("find_layer_by_owner") \
		and terrain.data.has_method("get_layer_stack") and terrain.data.has_method("composite_region")


## Resolve (or create) the tool layer for `owner`. When `sync_blend`, push this node's blend_mode onto
## the layer so changing blend_mode re-bakes (a shared layer has one blend — last refresher wins).
## Returns the layer index, or -1 on builds/terrains without the layers Tool API (destructive fallback).
func _ensure_layer_for(owner: String, sync_blend: bool) -> int:
	if not terrain or not terrain.data:
		return -1
	var mt := _map_type()
	var nm := owner.trim_prefix(BRUSH_OWNER_PREFIX)
	var id: int = -1
	if terrain.data.has_method("create_owned_layer_typed"):
		id = terrain.data.create_owned_layer_typed(owner, nm, _get_blend_mode(), mt)
	elif mt == PASTURE_3D_MAPTYPE_HEIGHT and terrain.data.has_method("create_owned_layer"):
		id = terrain.data.create_owned_layer(owner, nm, _get_blend_mode())
	if id < 0:
		return -1
	var layer := _layer_at(id)
	# Owner is keyed by name only, so a same-named layer of another map type would be reused — warn.
	if layer and layer.has_method("get_map_type") and layer.get_map_type() != mt:
		push_warning("Pasture3D brush '%s': layer '%s' already exists with a different map type — give this tool a unique layer name." % [name, nm])
	if sync_blend and layer and layer.has_method("get_blend_mode") and layer.get_blend_mode() != _get_blend_mode():
		layer.set_blend_mode(_get_blend_mode())
	return id


func _layer_at(id: int) -> Pasture3DLayer:
	if not terrain or not terrain.data or not terrain.data.has_method("get_layer_stack"):
		return null
	var stack = terrain.data.get_layer_stack()
	return stack.get_layer(id) if stack else null


func _layer_blend_for(id: int) -> int:
	var layer := _layer_at(id)
	return layer.get_blend_mode() if layer else _get_blend_mode()


func _resolve_layer_for(owner: String) -> Pasture3DLayer:
	if not terrain or not terrain.data or not terrain.data.has_method("find_layer_by_owner"):
		return null
	var idx: int = terrain.data.find_layer_by_owner(owner)
	return _layer_at(idx) if idx >= 0 else null


## Every reserved brush tool layer in the stack (owner in the brush namespace).
func _brush_layers() -> Array:
	var out: Array = []
	if not terrain or not terrain.data or not terrain.data.has_method("get_layer_stack"):
		return out
	var stack = terrain.data.get_layer_stack()
	if not stack:
		return out
	for i in range(stack.get_layer_count()):
		var l = stack.get_layer(i)
		# Scope to brush layers of THIS tool's map type so sharing / the dropdown / de-dup don't mix
		# height and control layers (their owners are name-keyed only).
		if l and l.is_reserved() and l.get_owner_id().begins_with(BRUSH_OWNER_PREFIX) and l.get_map_type() == _map_type():
			out.append(l)
	return out


func _brush_layer_names() -> PackedStringArray:
	var out := PackedStringArray()
	for l in _brush_layers():
		out.append(l.get_layer_name())
	return out


func _owner_for_layer_name(display_name: String) -> String:
	for l in _brush_layers():
		if l.get_layer_name() == display_name:
			return l.get_owner_id()
	return ""


## Live display name of the layer we're bound to, or our owner slug if it doesn't exist yet.
func _layer_display_name() -> String:
	for l in _brush_layers():
		if l.get_owner_id() == _layer_owner:
			return l.get_layer_name()
	return _layer_owner.trim_prefix(BRUSH_OWNER_PREFIX)


## Editor-only floating nameplate
##
## A billboarded Label3D added as an INTERNAL child: it isn't saved with the scene and never shows in
## the Scene dock, but it draws in the viewport so brushes are easy to find. The clickable origin marker
## (Pasture3DBrushGizmo) handles selection; this just shows "Name — Layer".


func _ensure_label() -> void:
	if not Engine.is_editor_hint() or is_instance_valid(_name_label):
		return
	_name_label = Label3D.new()
	_name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_name_label.fixed_size = true        # constant on-screen size regardless of camera distance
	_name_label.no_depth_test = true     # readable even when the brush is below the surface
	_name_label.pixel_size = 0.0007
	_name_label.font_size = 64
	_name_label.outline_size = 16
	var lc := _label_colors()
	_name_label.modulate = lc[0]
	_name_label.outline_modulate = lc[1]
	_name_label.render_priority = 20
	_name_label.outline_render_priority = 19
	_name_label.position = Vector3(0.0, 2.0, 0.0) # float just above the origin marker
	add_child(_name_label, false, Node.INTERNAL_MODE_BACK)
	_update_label_text()
	_update_label_visibility()


func _update_label_text() -> void:
	if not is_instance_valid(_name_label):
		return
	_name_label.text = "%s — %s" % [name, _layer_display_name()]


## Colour of this brush's ORIGIN MARKER in the viewport. Light neon purple by default — it stands out
## against terrain greens, browns, yellows and ochres. A family of brushes that has to be told apart at a
## glance overrides it; `Pasture3DSimBase` does, because an erosion pass is the one thing in a scene you
## want to find without reading nameplates.
##
## Declared on the brush rather than in the gizmo plugin so the node owns the decision, and so the plugin
## does not have to carry a list of which class gets which colour.
func _gizmo_color() -> Color:
	return Color(0.74, 0.42, 1.0)


## Nameplate `[fill, outline]`. Warm white on black by default: the label sits over terrain of every
## brightness, so the pair matters more than either colour alone — a dark fill needs a light outline to
## survive a dark hillside, and vice versa.
func _label_colors() -> Array:
	return [Color(1.0, 0.96, 0.85), Color(0.0, 0.0, 0.0, 0.85)]


## Editor selection changed: update the nameplate, and redraw the gizmo so the loop-point handles
## appear/disappear with selection (handles are only added when this brush itself is selected).
func _on_editor_selection_changed() -> void:
	_update_label_visibility()
	update_gizmos()


func _update_label_visibility() -> void:
	if not is_instance_valid(_name_label):
		return
	_name_label.visible = _show_all_labels or _brush_is_selected()
	if _name_label.visible:
		_update_label_text() # refresh in case the node was renamed or the layer relabelled


## This brush, or one of its child splines, is the current editor selection.
func _brush_is_selected() -> bool:
	if not Engine.is_editor_hint():
		return false
	for n in EditorInterface.get_selection().get_selected_nodes():
		if n == self or (n is Node and is_ancestor_of(n)):
			return true
	return false


## "Toggle Labels" button: flip the shared flag and refresh every brush's nameplate at once.
func _toggle_all_labels() -> void:
	_show_all_labels = not _show_all_labels
	if is_inside_tree():
		get_tree().call_group(BRUSH_GROUP, "_update_label_visibility")


## "Toggle Tangents" button: flip the shared flag and redraw every brush's gizmo so all loops' tangent
## handles show/hide together (otherwise only the selected point's tangents are drawn).
func _toggle_all_tangents() -> void:
	_show_all_tangents = not _show_all_tangents
	if is_inside_tree():
		get_tree().call_group(BRUSH_GROUP, "update_gizmos")


func _unique_brush_layer_name(base: String) -> String:
	var names := _brush_layer_names()
	if not names.has(base):
		return base
	var i := 2
	while names.has("%s %d" % [base, i]):
		i += 1
	return "%s %d" % [base, i]


## Write one terrain sample. MAX/MIN/REPLACE author the absolute target surface (the layer's blend
## clamps it against what's beneath); ADD applies the signed delta. The per-pixel shape/taper is baked
## into `target`/`delta` by the subclass, so weight stays 1 (the rim eases as target → base). Falls
## back to destructive set_height when no reserved layer is available.
## True when `p` is inside the active dirty-rect clip box (XZ), or always when no clip is set. Lets a
## partial redraw rasterise a spline's full field (needed for correct distances) but only WRITE in the box.
## Max edge is EXCLUSIVE to match the tile-clear's half-open pixel span [min, max): the vertex line on the
## max boundary lives in the next (un-dropped) tile, so painting it would double-add for ADD-blend brushes.
func _clip_contains(p: Vector3) -> bool:
	if _clip_aabb.size == Vector3.ZERO:
		return true
	var lo := _clip_aabb.position
	var hi := lo + _clip_aabb.size
	return p.x >= lo.x and p.x < hi.x and p.z >= lo.z and p.z < hi.z


func _paint_height(world_pos: Vector3, target: float, delta: float) -> void:
	if not _clip_contains(world_pos):
		return
	if _layer_id < 0:
		terrain.data.set_height(world_pos, target)
		return
	var comp := not _defer_composite
	if _blend == BLEND_ADD:
		terrain.data.add_height_on_layer(_layer_id, world_pos, delta, 1.0, comp)
	else:
		# REPLACE here (last write wins). The native rasteriser combines overlapping same-layer tools by
		# blend mode (MAX/MIN) in _stamp_write; this GDScript fallback is the A/B oracle for a SINGLE
		# brush, where each pixel is written once so the distinction doesn't arise.
		terrain.data.set_height_on_layer(_layer_id, world_pos, target, 1.0, comp)


## Write a packed control value (texture ids + blend + uv) into the layer. Falls back to the
## destructive set_control path internally when _layer_id is invalid (set_control_on_layer handles it).
func _paint_control(world_pos: Vector3, control: int, weight: float) -> void:
	if not _clip_contains(world_pos):
		return
	terrain.data.set_control_on_layer(_layer_id, world_pos, control, weight, not _defer_composite)


## Write an albedo+coverage colour into the layer (alpha-over composite).
func _paint_color(world_pos: Vector3, color: Color, weight: float) -> void:
	if not _clip_contains(world_pos):
		return
	terrain.data.set_color_on_layer(_layer_id, world_pos, color, weight, not _defer_composite)


func _seed_cache() -> void:
	for s in _get_splines():
		var a := _spline_footprint_aabb(s)
		if a.size != Vector3.ZERO:
			_last_paint_aabb[s.get_instance_id()] = a
		_curve_cache[s.get_instance_id()] = _curve_point_array(s)


## ---- Undo / redo (editor only) ----

## The editor's shared undo manager, or null outside the editor / when unavailable.
func _editor_undo() -> EditorUndoRedoManager:
	if not Engine.is_editor_hint():
		return null
	return EditorInterface.get_editor_undo_redo()


## Deep snapshot of a tool layer's tiles (empty Dictionary if no layer yet = the initial state).
func _snapshot_owner(owner: String) -> Dictionary:
	var layer := _resolve_layer_for(owner)
	return _copy_tiles(layer.get_tiles()) if layer else {}


## Restore a tile snapshot into a tool layer, then recomposite + push to GPU. Registered as the do/undo
## method of the bake action; re-resolves the layer by owner each call. Recomposites the UNION of the
## regions the layer covered before and after the swap — recompositing only the layer's current regions
## would leave a region the restore *emptied* still showing the old contribution.
func _restore_owner(owner: String, snapshot: Dictionary) -> void:
	var layer := _resolve_layer_for(owner)
	if not layer or not terrain.data.has_method("composite_region"):
		return
	var regions := {}
	for loc in layer.get_tiles():
		regions[loc] = true
	for loc in snapshot:
		regions[loc] = true
	layer.set_tiles(_copy_tiles(snapshot))
	for loc in regions:
		terrain.data.composite_region(loc, Rect2i(), false)
	# Full all-regions push: this is a bake undo/redo restore (a whole-layer state swap), the same risk
	# class as the detach path — a targeted per-region push left distant regions visually stale on undo.
	terrain.data.update_maps(_map_type())


## ---- Placement undo (Place Brush tool): rect-scoped live detach ----
##
## Undoing a placement must NOT use the full live-repaint detach (_detach_from_current): that clears+repaints
## every layer-mate and re-snaps their curve points (a non-undoable mutation of OTHER brushes), and
## recomposites whole regions — which on undo could move sibling mounds, paint stray areas, or leave a region
## stale. It also must NOT do a whole-layer set_tiles + full recomposite (an earlier snapshot-restore did
## exactly that), which exposed a pre-existing drift between the raw layer tiles and the incrementally-
## composited heightmap, stacking corner mounds into a spike. detach_placement() below is the answer: it
## reverses the placement bake within only this brush's own footprint box.

## Placement undo, the robust path: clear ONLY this brush's own footprint and repaint the layer-mates that
## overlap it — the same clipped clear/paint/composite the rect placement bake uses, just with self excluded
## and no point re-snap. This is placement run in reverse. Crucially it does NOT do a whole-layer set_tiles +
## full recomposite, which would expose a pre-existing drift between the raw layer tiles and the incrementally-
## composited heightmap — overlapping mounds at a region corner would stack into a spike and others vanish on
## undo. Touching only this brush's box keeps undo byte-consistent with how placement composited, so neighbours
## are untouched and no other region is recomposited. Returns false (nothing baked) only when unconfigured or
## this brush had no footprint, so the caller can still remove it.
func detach_placement() -> bool:
	if not Engine.is_editor_hint() or not is_configured():
		return false
	var owner := _layer_owner
	var layer_id := _ensure_layer_for(owner, false)
	if layer_id < 0:
		return false
	# Union of THIS brush's own spline footprints = the area its placement could have touched.
	var box := AABB()
	var have := false
	for s in _get_splines():
		var a := _spline_footprint_aabb(s)
		if a.size != Vector3.ZERO:
			box = a if not have else box.merge(a)
			have = true
	if not have:
		return false
	var clip_box := _snap_aabb_to_tiles(box, _layer_tile_world(layer_id))
	# Clean edited-flag slate so the targeted push uploads exactly the regions this clear/repaint touches.
	_clear_region_edited_flags()
	# Drop the whole box (self + any mate samples in it), then repaint ONLY the mates back into it. Self is
	# excluded, so its contribution is gone; mates are repainted from their unchanged curves (no snap).
	terrain.data.clear_layer_in_area(layer_id, clip_box)
	var blend := _layer_blend_for(layer_id)
	for s in _tools_on_owner(owner):
		if s == self or not s._overlaps_box(clip_box):
			continue
		s._clip_aabb = clip_box
		s._defer_composite = true
		s._paint_into(layer_id, blend)
		s._defer_composite = false
		s._clip_aabb = AABB()
	terrain.data.composite_area(clip_box, false)
	terrain.data.update_maps(_map_type(), false, false)
	_last_paint_aabb.clear()
	return true


## Deep copy of the {region_loc -> {tile_coord -> Image}} tile structure. get_tiles/set_tiles share
## the live Images by reference, so we copy each one (copy_from) to keep snapshots immutable.
func _copy_tiles(tiles: Dictionary) -> Dictionary:
	var out := {}
	for loc in tiles:
		var inner: Dictionary = tiles[loc]
		var inner_copy := {}
		for coord in inner:
			var img: Image = inner[coord]
			if img:
				var c := Image.new()
				c.copy_from(img)
				inner_copy[coord] = c
			else:
				inner_copy[coord] = null
		out[loc] = inner_copy
	return out


## Apply a batch of curve-point edits then repaint, as one undo step. `points` = Array of
## [curve: Curve3D, index: int, position: Vector3]. Auto-refresh is suspended during the edits so the
## programmatic set_point_position calls don't queue a second (un-undoable) repaint; we repaint once
## here. Used as the do/undo method of curve operations like Make Descend so the curve change AND the
## terrain following it live in a single, auto_refresh-independent undo action.
func _set_curve_points_and_repaint(points: Array) -> void:
	_suspend_auto = true
	for e in points:
		var c: Curve3D = e[0]
		if c:
			c.set_point_position(e[1], e[2])
	_suspend_auto = false
	if Engine.is_editor_hint() and is_configured():
		refresh()


## ---- Surface snapping (PASTURE3D_SPLINE_SURFACE_SNAP_SPEC.md) ----

## (A) Snap every control point of every child spline onto the terrain (+ surface_offset), as ONE
## undoable action. On-demand via the inspector button; reuses the Make Descend do/undo helper.
func snap_points_to_surface() -> void:
	if not is_configured():
		return
	var edits := _surface_snap_edits()
	var new_pts: Array = edits[1]
	if new_pts.is_empty():
		return
	var ur := _editor_undo()
	if ur:
		ur.create_action("Pasture3D Snap %s to Surface" % _spline_basename())
		ur.add_do_method(self, "_set_curve_points_and_repaint", new_pts)
		ur.add_undo_method(self, "_set_curve_points_and_repaint", edits[0])
		ur.commit_action()
	else:
		_set_curve_points_and_repaint(new_pts)


## (B) Snap points to the surface in place, with no undo action of its own — it runs inside an
## auto-refresh whose undoable cause is the user's gizmo edit. Guarded so the writes don't recurse.
func _apply_surface_snap() -> void:
	if not is_configured():
		return
	var new_pts: Array = _surface_snap_edits()[1]
	if new_pts.is_empty():
		return
	_suspend_auto = true
	for e in new_pts:
		e[0].set_point_position(e[1], e[2])
	_suspend_auto = false


## Snap a specific set of a single spline's points onto the surface (world Y only), in place, no undo
## action. The dirty-rect path uses this to re-seat ONLY the points the user moved — against the base
## inside the freshly-cleared box — instead of re-snapping the whole spline (the snap-to-self regression).
func _apply_surface_snap_points(path: Path3D, indices: PackedInt32Array) -> void:
	if not is_configured() or indices.is_empty():
		return
	var c: Curve3D = path.curve
	if c == null:
		return
	var xf: Transform3D = path.global_transform
	var inv := xf.affine_inverse()
	_suspend_auto = true
	for idx in indices:
		if idx < 0 or idx >= c.point_count:
			continue
		var local := c.get_point_position(idx)
		var world: Vector3 = xf * local
		var h: float = _base_height_below(Vector3(world.x, 0.0, world.z))
		if not is_finite(h):
			continue
		world.y = h + surface_offset
		var new_local: Vector3 = inv * world
		if not new_local.is_equal_approx(local):
			c.set_point_position(idx, new_local)
	_suspend_auto = false


## Local point positions of a spline's curve, for moved-point detection.
## ---- WHY THE TANGENTS ARE IN HERE ----
##
## Flat [position, in, out] TRIPLES, one per curve point, in point order — not one vector per point.
##
## The dirty-rect diff is this array's only consumer, and a tangent-only edit MUST be visible to it. A
## curve whose handles moved and whose positions did not used to diff as "nothing moved": every
## double-click smooth/sharpen and every tangent-handle drag returned an EMPTY moved-index list, which
## sent `_spline_dirty_aabb` down its whole-spline fallback and repainted the entire footprint plus
## every overlapping layer-mate. That is why dragging a point was fast and double-clicking the same
## point stalled the editor, and why it scaled with spline length rather than with the edit.
##
## Both readers (`_moved_point_indices`, `_spline_dirty_aabb`'s previous-position expansion) index in
## strides of 3. A reader that assumes one-vector-per-point produces a WRONG BOX, not an error.
func _curve_point_array(path: Path3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	var c: Curve3D = path.curve if is_instance_valid(path) else null
	if c == null:
		return out
	out.resize(c.point_count * 3)
	for i in range(c.point_count):
		out[i * 3] = c.get_point_position(i)
		out[i * 3 + 1] = c.get_point_in(i)
		out[i * 3 + 2] = c.get_point_out(i)
	return out


## True when point `p_i` of `p_cur` differs from point `p_j` of `p_prev` in position or in either
## tangent. Both arrays are `_curve_point_array` triples.
static func _curve_point_differs(p_cur: PackedVector3Array, p_i: int,
		p_prev: PackedVector3Array, p_j: int) -> bool:
	for k in 3:
		if not p_cur[p_i * 3 + k].is_equal_approx(p_prev[p_j * 3 + k]):
			return true
	return false


## Indices of `path`'s curve points that moved since the last bake (vs `_curve_cache`). Returns EVERY
## index when the point count changed (add/remove/insert) or there's no cache yet — so the dirty-rect
## snap falls back to re-seating the whole spline in those cases rather than guessing.
func _moved_point_indices(path: Path3D) -> PackedInt32Array:
	var out := PackedInt32Array()
	# Both arrays are [position, in, out] triples — see `_curve_point_array`. Counts are in POINTS.
	var cur := _curve_point_array(path)
	var prev: PackedVector3Array = _curve_cache.get(path.get_instance_id(), PackedVector3Array())
	var n_cur := cur.size() / 3
	var n_prev := prev.size() / 3
	if prev.is_empty():
		for i in range(n_cur):
			out.append(i)
		return out

	# Case 1: Point inserted (n_cur == n_prev + 1)
	if n_cur == n_prev + 1:
		var ins_idx := n_prev
		for i in n_prev:
			if _curve_point_differs(cur, i, prev, i):
				ins_idx = i
				break
		out.append(ins_idx)
		return out

	# Case 2: Point removed (n_cur == n_prev - 1)
	if n_cur == n_prev - 1 and n_cur > 0:
		var rem_idx := n_cur
		for i in n_cur:
			if _curve_point_differs(cur, i, prev, i):
				rem_idx = i
				break
		out.append(rem_idx)
		return out

	# Case 3: Arbitrary count change
	if n_prev != n_cur:
		for i in range(n_cur):
			out.append(i)
		return out

	# Case 4: Same count — a point counts as moved when its POSITION or either TANGENT changed. The
	# tangents are the difference between a narrow repaint and a whole-spline one for every smooth /
	# sharpen / handle drag; see `_curve_point_array`.
	for i in range(n_cur):
		if _curve_point_differs(cur, i, prev, i):
			out.append(i)
	return out


## ---- Editor loop-point editing (driven by the plugin's 3D input when this brush is selected) ----

## The loop point nearest `screen_pos` within `radius` px → [Path3D, point_index], or [null, -1].
##
## POSITIONS ONLY, and no longer an input picker. The editor's click paths all go through the gizmo's
## `Pasture3DBrushHandles.pick_handle_at` — one traversal, one radius, tangent-aware. This survives as
## the first cheap test inside `pick_brush_screen_distance` ("is the cursor on this brush at all"),
## which is a distance query and not a handle pick. Do not route a click back through it.
func pick_point_screen(camera: Camera3D, screen_pos: Vector2, radius: float) -> Array:
	var best: Array = [null, -1]
	var best_d := radius
	for s in _get_splines():
		if s.curve == null:
			continue
		for i in s.curve.point_count:
			var wp: Vector3 = s.to_global(s.curve.get_point_position(i))
			if camera.is_position_behind(wp):
				continue
			var d := camera.unproject_position(wp).distance_to(screen_pos)
			if d < best_d:
				best_d = d
				best = [s, i]
	return best


## Distance in screen pixels from `screen_pos` to this brush, or INF if not within `margin_px`.
func pick_brush_screen_distance(camera: Camera3D, screen_pos: Vector2, margin_px: float = 24.0) -> float:
	var best_d := INF
	var pt_hit := pick_point_screen(camera, screen_pos, margin_px)
	if pt_hit[0] != null:
		return 0.0

	for s in _get_splines():
		if s == null or s.curve == null:
			continue
		var pts: PackedVector3Array = s.curve.get_baked_points()
		if pts.size() < 2:
			continue
		for i in range(pts.size() - 1):
			var w1: Vector3 = s.to_global(pts[i])
			var w2: Vector3 = s.to_global(pts[i + 1])
			# EITHER endpoint, not both — see the note in Pasture3DRoadBrush.pick_road_screen_distance.
			# unproject_position mirrors a point behind the near plane, so a segment straddling the camera
			# plane is measured against a screen segment that does not exist.
			if camera.is_position_behind(w1) or camera.is_position_behind(w2):
				continue
			var s1 := camera.unproject_position(w1)
			var s2 := camera.unproject_position(w2)
			var p := Geometry2D.get_closest_point_to_segment(screen_pos, s1, s2)
			var d := screen_pos.distance_to(p)
			if d <= margin_px and d < best_d:
				best_d = d

	if not camera.is_position_behind(global_position):
		var od: float = camera.unproject_position(global_position).distance_to(screen_pos)
		if od <= margin_px and od < best_d:
			best_d = od

	return best_d


## Insert a point at `world` on the nearest loop's nearest segment (undoable). The curve change drives
## the rebake. Used by Ctrl-click add.
func editor_add_point(world: Vector3) -> void:
	var best_path: Path3D = null
	var best_d := INF
	for s in _get_splines():
		if s.curve == null:
			continue
		for i in s.curve.point_count:
			var d: float = s.to_global(s.curve.get_point_position(i)).distance_squared_to(world)
			if d < best_d:
				best_d = d
				best_path = s
	if best_path == null:
		return
	var idx := _nearest_segment_index(best_path, world)
	var local := best_path.to_local(world)
	# Keep the new point on the existing crest/bed line instead of diving to the terrain hit far below
	# (e.g. a tall follow-spline crest): an end-extension inherits the endpoint's height, a mid insert
	# interpolates between its two neighbours along the segment. Snap-to-surface brushes intentionally
	# sit on the ground, so only do this when snapping is off.
	if not snap_to_surface:
		var c := best_path.curve
		var n := c.point_count
		var closed := _is_closed()
		if n > 0:
			if not closed and idx <= 0:
				local.y = c.get_point_position(0).y # prepend → match the first point
			elif not closed and idx >= n:
				local.y = c.get_point_position(n - 1).y # append → match the last point
			else:
				# Between point idx-1 and idx (wrapping for a closed ring): interpolate the height
				# along that segment in the XZ plane so the point lands on the existing line.
				var a := c.get_point_position((idx - 1 + n) % n)
				var b := c.get_point_position(idx % n)
				var ab := b - a
				var t := 0.0
				var denom := ab.x * ab.x + ab.z * ab.z
				if denom > 1e-9:
					t = clampf(((local.x - a.x) * ab.x + (local.z - a.z) * ab.z) / denom, 0.0, 1.0)
				local.y = lerpf(a.y, b.y, t)
	var ur := _editor_undo()
	if ur:
		ur.create_action("Add %s Point" % _spline_basename())
		ur.add_do_method(best_path.curve, "add_point", local, Vector3.ZERO, Vector3.ZERO, idx)
		ur.add_undo_method(best_path.curve, "remove_point", idx)
		ur.commit_action()
	else:
		best_path.curve.add_point(local, Vector3.ZERO, Vector3.ZERO, idx)
	update_gizmos() # show the new point marker right away


## Remove a loop point (undoable), refusing to drop below the brush's minimum. Used by right-click.
func editor_remove_point(path: Path3D, idx: int) -> void:
	if path == null or path.curve == null or idx < 0 or idx >= path.curve.point_count:
		return
	if path.curve.point_count <= _min_points():
		push_warning("Pasture3D: a %s needs at least %d points." % [_spline_basename(), _min_points()])
		return
	var pos := path.curve.get_point_position(idx)
	var ur := _editor_undo()
	if ur:
		ur.create_action("Remove %s Point" % _spline_basename())
		ur.add_do_method(path.curve, "remove_point", idx)
		ur.add_undo_method(path.curve, "add_point", pos, Vector3.ZERO, Vector3.ZERO, idx)
		ur.commit_action()
	else:
		path.curve.remove_point(idx)
	update_gizmos() # drop the removed point's marker right away


## Toggle a loop point between a smooth curve and a sharp corner (double-click). Smoothing seeds
## mirrored in/out tangents from the neighbour direction; a second toggle zeroes them back to a corner.
## Undoable. Used by the brush gizmo.
func editor_smooth_point(path: Path3D, idx: int) -> void:
	if path == null or path.curve == null or idx < 0 or idx >= path.curve.point_count:
		return
	var c := path.curve
	var old_in := c.get_point_in(idx)
	var old_out := c.get_point_out(idx)
	var new_in := Vector3.ZERO
	var new_out := Vector3.ZERO
	var smoothing := old_in.length() <= 0.02 and old_out.length() <= 0.02
	if smoothing:
		new_out = _smooth_handle(path, idx)
		new_in = -new_out
	var ur := _editor_undo()
	if ur:
		ur.create_action("Smooth Loop Point" if smoothing else "Sharpen Loop Point")
		ur.add_do_method(self, "editor_set_point_tangents", path, idx, new_in, new_out)
		ur.add_undo_method(self, "editor_set_point_tangents", path, idx, old_in, old_out)
		ur.commit_action()
	else:
		editor_set_point_tangents(path, idx, new_in, new_out)
	update_gizmos()


## Zero ONE tangent of a loop point (undoable) — double-clicking a shown in/out handle sharpens that
## side only, leaving the other alone. `kind` is 1 for the in-handle, 2 for the out-handle, matching the
## gizmo's subgizmo encoding. A double-click on the POINT still toggles both (`editor_smooth_point`).
func editor_zero_tangent(path: Path3D, idx: int, kind: int) -> void:
	if path == null or path.curve == null or idx < 0 or idx >= path.curve.point_count:
		return
	if kind != 1 and kind != 2:
		return
	var c := path.curve
	var old_in := c.get_point_in(idx)
	var old_out := c.get_point_out(idx)
	if (old_in if kind == 1 else old_out).length() <= 0.02:
		return # already a corner on that side — nothing to undo and nothing to re-bake
	var new_in := Vector3.ZERO if kind == 1 else old_in
	var new_out := Vector3.ZERO if kind == 2 else old_out
	var ur := _editor_undo()
	if ur:
		ur.create_action("Sharpen Loop Handle")
		ur.add_do_method(self, "editor_set_point_tangents", path, idx, new_in, new_out)
		ur.add_undo_method(self, "editor_set_point_tangents", path, idx, old_in, old_out)
		ur.commit_action()
	else:
		editor_set_point_tangents(path, idx, new_in, new_out)
	update_gizmos()


## Set BOTH tangents of one curve point in a single mutation. Registered as one do/undo method rather
## than a pair of `set_point_in` / `set_point_out` calls so the toggle is one undo step and one
## `changed` emission — the refresh debounce collapses the pair today, but a future non-debounced
## caller would otherwise bake twice for one gesture.
func editor_set_point_tangents(path: Path3D, idx: int, p_in: Vector3, p_out: Vector3) -> void:
	if path == null or path.curve == null or idx < 0 or idx >= path.curve.point_count:
		return
	path.curve.set_point_in(idx, p_in)
	path.curve.set_point_out(idx, p_out)


## A mirrored tangent handle (path-local) for smoothing a point: along the previous→next direction,
## scaled to a quarter of the shorter adjacent segment so the curve is gentle and doesn't overshoot.
func _smooth_handle(path: Path3D, idx: int) -> Vector3:
	var c := path.curve
	var n := c.point_count
	var p := c.get_point_position(idx)
	var closed := _is_closed()
	var prev_i := idx - 1
	if prev_i < 0:
		prev_i = (n - 1) if closed else idx
	var next_i := idx + 1
	if next_i >= n:
		next_i = 0 if closed else idx
	var prev_p := c.get_point_position(prev_i)
	var next_p := c.get_point_position(next_i)
	var dir := next_p - prev_p
	if dir.length() < 0.001:
		return Vector3.ZERO
	var s1 := (next_p - p).length()
	var s2 := (p - prev_p).length()
	var seg := minf(s1, s2) if (s1 > 0.001 and s2 > 0.001) else maxf(s1, s2)
	return dir.normalized() * (seg * 0.25)


## Insertion index so a new point lands on the loop segment nearest `world`. Closed loops (min ≥ 3
## points: Mound/Plow/Splat) also test the wrap segment so a point can be added between last and first.
func _nearest_segment_index(path: Path3D, world: Vector3) -> int:
	var c := path.curve
	var n := c.point_count
	if n < 2:
		return n
	var closed := _is_closed()
	var segs := n if closed else n - 1
	var best_i := n # default: append
	var best_d := INF
	for i in range(segs):
		var a: Vector3 = path.to_global(c.get_point_position(i))
		var b: Vector3 = path.to_global(c.get_point_position((i + 1) % n))
		var ab := b - a
		var t := 0.0
		var denom := ab.length_squared()
		if denom > 1e-9:
			t = (world - a).dot(ab) / denom
		# Open splines can grow at their ends: let the first segment project before its start
		# and the last segment past its end, so a click beyond an endpoint prepends / appends a
		# point instead of always inserting between two existing ones.
		var lo := 0.0
		var hi := 1.0
		if not closed:
			if i == 0:
				lo = -INF
			if i == segs - 1:
				hi = INF
		t = clampf(t, lo, hi)
		var d := world.distance_to(a + ab * t)
		if d < best_d:
			best_d = d
			if not closed and i == 0 and t < 0.0:
				best_i = 0 # prepend before the first point
			elif not closed and i == segs - 1 and t > 1.0:
				best_i = n # append after the last point
			else:
				best_i = i + 1 # insert between point i and i+1
	return best_i


## Every point index of a spline (for re-snapping all points after a whole-node move).
func _all_point_indices(path: Path3D) -> PackedInt32Array:
	var out := PackedInt32Array()
	if path.curve != null:
		for i in range(path.curve.point_count):
			out.append(i)
	return out


## Record a spline's current point layout as the new baseline for moved-point detection.
func _update_curve_cache(path: Path3D) -> void:
	if is_instance_valid(path):
		_curve_cache[path.get_instance_id()] = _curve_point_array(path)


## Compute the snap edits for every child spline: [old_points, new_points], each an Array of
## [curve, index, local_position]. Snaps in world space (so a transformed brush/Path3D still works);
## points with no region beneath them (get_height returns NaN) are skipped.
func _surface_snap_edits() -> Array:
	var old_pts: Array = []
	var new_pts: Array = []
	for path in _get_splines():
		var c: Curve3D = path.curve
		if c == null:
			continue
		var xf: Transform3D = path.global_transform
		var inv := xf.affine_inverse()
		for i in range(c.point_count):
			var local := c.get_point_position(i)
			var world: Vector3 = xf * local
			var h: float = _base_height_below(Vector3(world.x, 0.0, world.z))
			if not is_finite(h):
				continue
			world.y = h + surface_offset
			var new_local: Vector3 = inv * world
			if new_local.is_equal_approx(local):
				continue
			old_pts.append([c, i, local])
			new_pts.append([c, i, new_local])
	return [old_pts, new_pts]


## ---- Add Spline button ----

func add_spline() -> void:
	_new_spline()
	refresh()


## Create + attach a starter spline (no bake). Split out of add_spline so placement can build the spline
## and then run a rect-scoped bake (see place_bake) instead of the full refresh add_spline does.
func _new_spline() -> Path3D:
	var path := Path3D.new()
	path.name = "%s%d" % [_spline_basename(), _get_splines().size() + 1]
	path.curve = _make_starter_curve()
	# Closed-fill brushes (Mound/Plow/Splat) author a polygon, so their spline node is a closed Curve3D
	# from the start — the native Path3D gizmo then draws the last→first segment and editing stays coherent
	# (no duplicated wrap point). Ridge/Trough stay open. Curve3D.closed is Godot 4.x native.
	if path.curve and _is_closed():
		path.curve.closed = true
	add_child(path)
	# Reparent under the edited scene so the new node persists when the scene is saved.
	if Engine.is_editor_hint() and is_inside_tree():
		var root := get_tree().edited_scene_root
		if root:
			path.owner = root
	_connect_spline(path)
	return path


## Initial-placement bake (Place Brush tool). Bakes ONLY this freshly-placed brush via the dirty-rect path,
## scoped to its own splines, so it does NOT clear + re-snap + repaint every layer-mate the way the full
## refresh does. That sibling re-snap (_refresh_owner lines ~536) mutates OTHER brushes' curve points, a
## side effect the placement-undo tile snapshot can't revert — undoing a placement would otherwise corrupt
## neighbouring mounds. The rect path clears only the new brush's footprint box and repaints any siblings
## inside it from their UNCHANGED curves, so undo (set_tiles of the pre-placement snapshot) reverts cleanly.
## snap_all is true: a just-placed brush snaps all of its own points to the surface.
func place_bake() -> void:
	if not Engine.is_editor_hint() or not is_configured():
		return
	if _get_splines().is_empty():
		_new_spline()
	var ids := {}
	for s in _get_splines():
		ids[s.get_instance_id()] = true
	if ids.is_empty():
		return
	_refresh_owner_rect(_layer_owner, ids, true)


## ---- Add Water button (PASTURE3D_WATER_BODIES_SPEC.md §7.8) ----
##
## The whole point of the water work: a brush already knows the shape of the basin it carved, so
## filling it should not be a modelling job. One press per brush, one undo step, and the resulting
## Pasture3DPool is bound to the brush's Path3D — not a copy of its curve — so moving the brush or
## dragging a loop point moves the water with it.

## The water connectors, loaded by path rather than referenced as `Pasture3DPool` /
## `Pasture3DStream`. A class_name reference is a PARSE-time dependency: a syntax error in pool.gd —
## or an install without it — would stop this file compiling and take every brush in the scene down
## with it, which is exactly how the Phase 1 DLL failure presented. By path, missing water is a
## failed button press.
const POOL_SCRIPT := "res://addons/pasture_3d/connectors/pasture3d_pool.gd"
const STREAM_SCRIPT := "res://addons/pasture_3d/connectors/pasture3d_stream.gd"
## Group both of them join (mirrors Pasture3DWaterBody.POOL_GROUP), for the same reason. Named for
## the pool because it predates the split and is written into saved scenes.
const POOL_GROUP: StringName = &"pasture3d_pool"
## Group Pasture3DPoolManager joins (mirrors Pasture3DPoolManager::MANAGER_GROUP).
const WATER_MANAGER_GROUP: StringName = &"pasture3d_water_manager"
## Loop span (metres) below which a new pool is seeded with the pond profile instead of the lake
## one. A pond and a lake are different sea states, not one scaled — a 10 m pond carrying 25 m
## waves looks wrong before the user has touched anything. A starting point only: nothing
## re-derives it, so resizing the loop later never moves the profile out from under the user.
const POND_MAX_SPAN: float = 40.0
## The river preset. Not one of Pasture3DPool's Lake/Pond enum entries, because it is not
## drop-anywhere: it reads a flow direction out of ARRAY_COLOR that only a ribbon mesh writes.
const RIVER_MATERIAL := "res://addons/pasture_3d/extras/shaders/water/M_water_river.tres"

## The Add Water confirmation currently on screen for this brush, if any. See _prompt_add_pool.
var _pool_dialog: ConfirmationDialog = null


## The Add Water button.
##
## Returns the Pasture3DPool nodes created. An EMPTY return with a dialog on screen is the
## raise-brush path (§7.8): the press asks first and "Add Anyway" calls add_pool_now(). It asks
## rather than refuses, because a raised pool on a plateau is a real thing to author and the tool
## should make sure the user knows, not claim to know better.
func add_pool() -> Array:
	if not is_inside_tree():
		return []
	if brush_raises() and _prompt_add_pool():
		return []
	return add_pool_now()


## Create the pools, unconditionally — the no-raise path and the dialog's "Add Anyway" both land
## here. Idempotent per spline: pressing twice on a three-spline brush gives three pools, not six.
func add_pool_now() -> Array:
	if not is_inside_tree():
		return []
	var parent := get_parent()
	if parent == null:
		push_warning("Pasture3D: '%s' has no parent to add water beside." % name)
		return []
	if not ClassDB.class_exists("Pasture3DPoolManager"):
		push_error("Pasture3D: the water classes are missing from this build — cannot add water.")
		return []

	var targets: Array[Path3D] = []
	var skipped := PackedStringArray()
	for s in _get_splines():
		if pool_for_spline(s) != null:
			continue
		# The CURVE decides which kind of water this is, not the brush class: closed fills as a
		# lake, open becomes a river ribbon (§7.3). A Mound whose loop the user opened is a river,
		# and a Trough they closed is a moat, without either of them saying so anywhere else.
		var pts: int = s.curve.point_count if s.curve != null else 0
		var closed: bool = s.curve != null and s.curve.closed
		if pts < 2 or (closed and pts < 3):
			skipped.append(String(s.name))
			continue
		targets.append(s)
	if not skipped.is_empty():
		push_warning(("Pasture3D: no water added to %s — a loop needs at least 3 points and a "
			+ "river at least 2.") % ", ".join(skipped))
	if targets.is_empty():
		return []

	# Built before the pools so each one can be handed its manager directly, and so the whole
	# press — manager included — is a single undo step.
	var manager := find_pool_manager()
	var new_manager: Node = null
	if manager == null:
		new_manager = ClassDB.instantiate("Pasture3DPoolManager")
		new_manager.name = "Pasture3DPoolManager"
		manager = new_manager

	var pools: Array = []
	for s in targets:
		var p := _build_pool_for(s, manager)
		if p != null:
			pools.append(p)
	if pools.is_empty():
		return []

	var root := _water_scene_root()
	var ur := _editor_undo()
	if ur:
		ur.create_action("Add Water to %s" % name)
		ur.add_do_method(self, "_apply_add_water", pools, parent, root, new_manager)
		ur.add_undo_method(self, "_revert_add_water", pools, parent, new_manager)
		# The undo action owns the nodes while they are out of the tree, so redo re-adds these
		# same pools rather than silently rebuilding different ones.
		for p in pools:
			ur.add_do_reference(p)
		if new_manager != null:
			ur.add_do_reference(new_manager)
		ur.commit_action() # executes the do-method
	else:
		# No editor undo manager: a script driving the brush, or a headless run.
		_apply_add_water(pools, parent, root, new_manager)

	if Engine.is_editor_hint() and not pools.is_empty():
		var sel := EditorInterface.get_selection()
		sel.clear()
		sel.add_node(pools[0])
	return pools


## Put the press's nodes into the scene.
##
## One method rather than a pile of add_do_method steps, so the action has an explicit inverse
## instead of an implicit one — and so the revert can be exercised without an editor, since
## EditorUndoRedoManager does not exist in a headless run and an untestable undo is an undo that
## is wrong the first time someone presses Ctrl+Z.
##
## The manager goes in FIRST: pools register with it on entering the tree, and one that arrives to
## an empty scene registers with nothing.
func _apply_add_water(p_pools: Array, p_parent: Node, p_root: Node, p_new_manager: Node) -> void:
	if p_new_manager != null and is_instance_valid(p_new_manager) and p_new_manager.get_parent() == null:
		p_root.add_child(p_new_manager)
		p_new_manager.owner = p_root
	for p in p_pools:
		if not is_instance_valid(p) or p.get_parent() != null:
			continue
		p_parent.add_child(p)
		p.owner = p_root
		# Seeding the level reads global transforms, so it happens once the node is in the tree
		# and not on the detached one, where global_position is meaningless.
		p.fit_to_curve()


## Exact inverse of _apply_add_water. The nodes leave the tree but stay alive — the undo action
## holds them — so redo re-adds the same instances. Pools leave BEFORE the manager, so each one
## unregisters from a registry that still exists.
func _revert_add_water(p_pools: Array, p_parent: Node, p_new_manager: Node) -> void:
	for p in p_pools:
		if is_instance_valid(p) and p.get_parent() == p_parent:
			p_parent.remove_child(p)
	if p_new_manager != null and is_instance_valid(p_new_manager) and p_new_manager.get_parent() != null:
		p_new_manager.get_parent().remove_child(p_new_manager)


## The Pasture3DPool already filled from `path`, or null. What makes the button idempotent.
func pool_for_spline(path: Path3D) -> Node:
	if not is_inside_tree() or path == null:
		return null
	for n in get_tree().get_nodes_in_group(POOL_GROUP):
		if is_instance_valid(n) and n.get("source_spline") == path:
			return n
	return null


## The scene's water manager, or null. One per scene is the normal case; the first is the active
## one, which is the same rule Pasture3DPool and the C++ side use.
func find_pool_manager() -> Node:
	if not is_inside_tree():
		return null
	var found := get_tree().get_nodes_in_group(WATER_MANAGER_GROUP)
	return found[0] if not found.is_empty() else null


## True when this brush pushes terrain UP, so water authored in its loop would be buried inside the
## landform. The check is on the brush's EFFECTIVE sign and not its class, because every raise brush
## can be configured to carve and every carve brush to raise (§7.8). Public because Pasture3DPool
## re-asks it in its configuration warnings — changing a brush's blend mode AFTER the water exists
## is the case a creation-time dialog alone would miss, and it is the more likely one.
func brush_raises() -> bool:
	# A brush that does not write height cannot bury anything. Pasture3DSplat paints control/colour,
	# so it is silent here by construction rather than by being named in a list.
	if _map_type() != PASTURE_3D_MAPTYPE_HEIGHT:
		return false
	var blend := _get_blend_mode()
	if blend != BLEND_ADD and blend != BLEND_MAX:
		return false
	return not _raise_inverted()


## Whether this brush's stamp is flipped, so an ADD/MAX blend carves rather than raises. Subclasses
## whose inversion lives somewhere other than an `invert` property override this (Pasture3DPlow).
func _raise_inverted() -> bool:
	return get("invert") == true


## The `fill_offset` a pool created by this brush should start with, or NAN for "leave the default".
##
## On the base class because a brush that carves knows how deep its basin is and the water body does
## not — but only Pasture3DPond overrides it (see PASTURE3D_POND_WATER_OFFSET_SPEC.md §5). Giving
## every brush a water-level dial is a bigger decision; the hook is here for whoever makes it, the
## same way _region_coverage() is.
##
## NAN rather than -0.5 keeps the default in ONE place — Pasture3DWaterBody's own property — so a
## brush with no opinion cannot pin a stale default by restating it.
func _pool_fill_offset() -> float:
	return NAN


## Human-readable blend mode, for the dialog and the warning. Reads the subclass's own enum names so
## a brush that adds a mode does not need this updated.
func _blend_mode_name() -> String:
	const NAMES := ["REPLACE", "ADD", "MAX", "MIN"]
	var b := _get_blend_mode()
	return NAMES[b] if b >= 0 and b < NAMES.size() else str(b)


## Put the raise-brush confirmation on screen. Returns false when there is nothing to host it, in
## which case add_pool() proceeds: the dialog is a prompt, not a permission gate, and the created
## pool carries the same warning permanently (Pasture3DPool._get_configuration_warnings).
func _prompt_add_pool() -> bool:
	var host := _dialog_host()
	if host == null:
		return false
	# A second press while the first prompt is still up must re-raise that one, not stack another.
	# Godot refuses a second exclusive child of the same window outright ("the parent window
	# already has another exclusive child") and logs an error, so this is not merely tidiness.
	if is_instance_valid(_pool_dialog):
		_pool_dialog.grab_focus()
		return true
	var dlg := ConfirmationDialog.new()
	dlg.title = "Water inside a landform"
	dlg.dialog_text = ("'%s' raises terrain (blend_mode = %s).\n\nWater placed here will sit inside "
		+ "the landform and be hidden.\n\nAdd it anyway?") % [name, _blend_mode_name()]
	dlg.ok_button_text = "Add Anyway"
	dlg.cancel_button_text = "Cancel"
	dlg.confirmed.connect(add_pool_now)
	# One cleanup path, not one per way of dismissing: confirm hides the dialog too, so freeing on
	# "became invisible" covers OK, Cancel and Escape without double-freeing on any of them.
	dlg.visibility_changed.connect(func() -> void:
		if not dlg.visible:
			_pool_dialog = null
			dlg.queue_free())
	_pool_dialog = dlg
	host.add_child(dlg)
	dlg.popup_centered()
	return true


## Where a modal goes: the editor's own base control in-editor, the window root otherwise.
func _dialog_host() -> Node:
	if Engine.is_editor_hint():
		return EditorInterface.get_base_control()
	return get_tree().root if is_inside_tree() else null


## Where a newly created manager is parented, and what the new nodes are owned by so they persist
## when the scene is saved.
func _water_scene_root() -> Node:
	var root: Node = get_tree().edited_scene_root
	if root == null:
		root = get_tree().current_scene
	if root == null:
		root = get_parent()
	return root


## The water for `p_spline`, detached (the caller adds it inside the undo action).
##
## THE CURVE PICKS THE CLASS. A closed loop is a Pasture3DPool and an open channel is a
## Pasture3DStream, decided here, once, at creation. That used to be decided on every rebuild by
## the one node that could be either — so a Mound whose loop the user opened silently became a
## river, and a Trough they closed became a moat. It still does become one, but now it takes the
## Convert to Stream button rather than happening under them, and the class in the Scene dock says
## which kind of water it is.
func _build_pool_for(p_spline: Path3D, p_manager: Node) -> Node:
	var is_river: bool = p_spline.curve != null and not p_spline.curve.closed
	var path := STREAM_SCRIPT if is_river else POOL_SCRIPT
	var script: GDScript = load(path)
	if script == null:
		push_error("Pasture3D: could not load %s — cannot add water." % path)
		return null
	var pool: Node = script.new()
	pool.name = _pool_name_for(p_spline, is_river)
	pool.source_spline = p_spline
	# Above the is_river branch so it seeds BOTH kinds. A stream's fill_offset is only its
	# no-terrain fallback, but at creation there is nothing else to seed that fallback from, so the
	# brush's number is the best available answer. (Pushing it LATER is a different question — by
	# then the banks are answering; see Pasture3DPond._apply_water_offset.)
	#
	# Before the node is in the tree, which is where it has to be: _apply_add_water calls
	# fit_to_curve() on insertion and that reads fill_offset, so the seeded level comes out right
	# first time rather than needing a second press.
	var seed_fill := _pool_fill_offset()
	if is_finite(seed_fill):
		pool.fill_offset = seed_fill
	if is_river:
		# A river gets the river profile and the river shader, and its width comes from the channel
		# the brush carved — a Trough already knows how wide its bed is, so asking the user again
		# would be asking them to repeat themselves.
		pool.wave_profile = _seed_river_profile(p_manager)
		pool.water_preset = 0 # River: a stream's presets are River / Custom, in that order
		pool.material = load(RIVER_MATERIAL)
		var bed = get("bed_half_width")
		if bed != null:
			pool.ribbon_half_width = float(bed)
		if p_manager != null:
			pool.manager = p_manager
		return pool
	pool.wave_profile = _seed_profile_for(p_spline, p_manager)
	# Match the material to the sea state rather than leaving a pond on the lake preset: the pond
	# variant is a genuinely cheaper shader, not the lake one tinted differently.
	pool.water_preset = 1 if pool.wave_profile == &"pond_still" else 0
	if p_manager != null:
		pool.manager = p_manager
	return pool


## "<BrushName>Water" for a pool, "<BrushName>Stream" for a river, numbered per spline on a
## multi-spline brush so the pairing stays readable.
##
## The suffix follows the class because the Scene dock is where you look first: a Trough with a
## "TroughWater" beside it says nothing about which of the two kinds of water it is, and the two
## behave differently enough — one has banks and a flow direction, the other a level you drag —
## that the name is worth spending.
func _pool_name_for(p_spline: Path3D, p_is_river: bool) -> String:
	var suffix := "Stream" if p_is_river else "Water"
	var splines := _get_splines()
	if splines.size() <= 1:
		return "%s%s" % [name, suffix]
	return "%s%s%d" % [name, suffix, splines.find(p_spline) + 1]


## Starting profile for a new pool, chosen from the loop's size (§7.8 step 6). Falls back to
## whatever the manager does have if the wanted name is not on it, so a manager the user has
## re-profiled still produces water rather than a warning.
func _seed_profile_for(p_spline: Path3D, p_manager: Node) -> StringName:
	var span := _spline_span(p_spline)
	var want: StringName = &"lake_calm" if span >= POND_MAX_SPAN else &"pond_still"
	if p_manager == null or not p_manager.has_method("has_profile"):
		return want
	if p_manager.has_profile(want):
		return want
	return _closest_profile_for(span, p_manager, want)


## The best available profile for a body this wide, when the wanted one is not on the manager.
##
## NOT simply the first: on a manager re-profiled to, say, [ocean_default, river_flow], "first" hands
## a 150 m lake the OCEAN — 4.9 m of crest-to-trough swell in a basin a few metres deep. That is what
## happens in practice, because ocean_default is first in the shipped order.
##
## The rule is physical rather than a heuristic: a wave longer than the body is wide cannot fit in
## it. So take the LONGEST profile whose longest wave still fits across the loop, and if nothing
## fits, the shortest available — the closest anyone can get with what the manager actually has.
func _closest_profile_for(p_span: float, p_manager: Node, p_want: StringName) -> StringName:
	var names: PackedStringArray = p_manager.get_profile_names()
	if names.is_empty():
		return p_want
	var budget := p_span * 0.5
	var best := ""
	var best_len := -INF
	var shortest := ""
	var shortest_len := INF
	for n in names:
		var profile = p_manager.get_profile(n)
		if profile == null:
			continue
		var l: float = profile.length_max
		if l < shortest_len:
			shortest_len = l
			shortest = n
		if l <= budget and l > best_len:
			best_len = l
			best = n
	if best != "":
		return StringName(best)
	return StringName(shortest) if shortest != "" else StringName(names[0])


## The starting profile for a river. `river_flow` if the manager has it, else the shortest-waved
## profile it does have — a channel a few metres across must not be handed ocean swell.
func _seed_river_profile(p_manager: Node) -> StringName:
	if p_manager == null or not p_manager.has_method("has_profile"):
		return &"river_flow"
	if p_manager.has_profile(&"river_flow"):
		return &"river_flow"
	return _closest_profile_for(0.0, p_manager, &"river_flow")


## The larger XZ extent of a spline's loop, in metres. Taken from the footprint box with the
## brush's lateral padding removed, so it measures the loop the user drew and not its skirt.
func _spline_span(p_spline: Path3D) -> float:
	var box := _spline_footprint_aabb(p_spline)
	if box.size == Vector3.ZERO:
		return 0.0
	var pad := _total_padding() * 2.0
	return maxf(maxf(box.size.x - pad, box.size.z - pad), 0.0)


## ---- Geometry helpers (shared) ----

## Curve baked to a world-space polyline (Path3D transform applied).
func _baked_world_points(path: Path3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	if path.curve == null:
		return out
	var xf := path.global_transform
	for p in path.curve.get_baked_points():
		out.append(xf * p)
	return out


## World footprint of a spline: XZ bounds of its baked points padded by the brush's lateral reach.
## Y is given a wide nominal span; clear_layer_in_area uses XZ only.
func _spline_footprint_aabb(path: Path3D) -> AABB:
	var pts := _baked_world_points(path)
	if pts.is_empty():
		return AABB()
	var mn := Vector2(pts[0].x, pts[0].z)
	var mx := mn
	for p in pts:
		mn.x = minf(mn.x, p.x)
		mn.y = minf(mn.y, p.z)
		mx.x = maxf(mx.x, p.x)
		mx.y = maxf(mx.y, p.z)
	var pad := _total_padding()
	mn -= Vector2(pad, pad)
	mx += Vector2(pad, pad)
	return AABB(Vector3(mn.x, -10000.0, mn.y), Vector3(mx.x - mn.x, 20000.0, mx.y - mn.y))


## World footprint of only the changed sections of a spline (for fine-grained dirty-rect updates).
## When all points moved, or when point count changed, returns the whole spline footprint UNIONED with
## `p_prev_painted`. When only a subset of control points moved, bounds the curve spans surrounding those
## points in both current and previous cached positions.
##
## ---- WHY THE FALLBACK NEEDS THE PREVIOUSLY PAINTED BOX AND THE PARTIAL PATH DOES NOT ----
##
## The partial path re-derives where the spline WAS from `_curve_cache`, so it carries its own previous
## component and stays narrow — that is the whole 93x win, and unioning the last painted footprint into it
## would give the win straight back.
##
## The fallback path cannot do that. It is taken when nothing is known about which part moved, and the
## case that reaches it constantly is a NODE MOVE: `_moved_point_indices` compares LOCAL curve positions,
## which a node move leaves identical, so `_refresh_owner_rect` forces `moved_indices` empty via
## `snap_all` and lands here. `_curve_cache` cannot help either — its local positions transformed by the
## node's CURRENT transform give the new location, not the old one. So the last painted box is the only
## surviving record of where the terrain still holds this brush's cut, and without it the box clear only
## covers the new position: the brush paints correctly at its destination and leaves a full uncleared
## GHOST of itself behind, with no undo action recorded because the rect path is auto-refresh only.
func _spline_dirty_aabb(path: Path3D, moved_indices: PackedInt32Array,
		p_prev_painted: AABB = AABB()) -> AABB:
	if not is_instance_valid(path) or path.curve == null:
		return AABB()
	var n_pts := path.curve.point_count
	if moved_indices.is_empty() or moved_indices.size() >= n_pts or n_pts < 2:
		var whole := _spline_footprint_aabb(path)
		# Neither may be merged blind: AABB.merge on a zero-size box drags the result out to the world
		# origin, which would clear half the terrain. A curve emptied of its points gives a zero `whole`
		# and the previous box is then the only thing worth clearing.
		if p_prev_painted.size == Vector3.ZERO:
			return whole
		if whole.size == Vector3.ZERO:
			return p_prev_painted
		return whole.merge(p_prev_painted)

	var pad := _total_padding()
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)

	# Expand bounds from current points touching changed spans
	for idx in moved_indices:
		var i0 := maxi(idx - 1, 0)
		var i1 := mini(idx + 1, n_pts - 1)
		for k in range(i0, i1 + 1):
			var wp := path.to_global(path.curve.get_point_position(k))
			mn.x = minf(mn.x, wp.x)
			mn.y = minf(mn.y, wp.z)
			mx.x = maxf(mx.x, wp.x)
			mx.y = maxf(mx.y, wp.z)
			var in_pos := path.to_global(path.curve.get_point_position(k) + path.curve.get_point_in(k))
			var out_pos := path.to_global(path.curve.get_point_position(k) + path.curve.get_point_out(k))
			mn.x = minf(mn.x, minf(in_pos.x, out_pos.x))
			mn.y = minf(mn.y, minf(in_pos.z, out_pos.z))
			mx.x = maxf(mx.x, maxf(in_pos.x, out_pos.x))
			mx.y = maxf(mx.y, maxf(in_pos.z, out_pos.z))

	# Also expand bounds from the PREVIOUS cached position AND TANGENTS of those same control points.
	# The cache holds [position, in, out] triples (see `_curve_point_array`), so the stride is 3 and the
	# bound is in points. The tangents belong here for the same reason as above and for one more: a
	# tangent that SHRANK reaches further in the old curve than in the new one, so leaving it out clears
	# less than was painted and strands the old cut.
	var prev: PackedVector3Array = _curve_cache.get(path.get_instance_id(), PackedVector3Array())
	if not prev.is_empty():
		var n_prev := prev.size() / 3
		for idx in moved_indices:
			var i0 := maxi(idx - 1, 0)
			var i1 := mini(idx + 1, n_prev - 1)
			for k in range(i0, i1 + 1):
				var pp: Vector3 = prev[k * 3]
				for corner in [pp, pp + prev[k * 3 + 1], pp + prev[k * 3 + 2]]:
					var wp := path.to_global(corner)
					mn.x = minf(mn.x, wp.x)
					mn.y = minf(mn.y, wp.z)
					mx.x = maxf(mx.x, wp.x)
					mx.y = maxf(mx.y, wp.z)

	if mn.x == INF:
		return _spline_footprint_aabb(path)

	mn -= Vector2(pad, pad)
	mx += Vector2(pad, pad)
	return AABB(Vector3(mn.x, -10000.0, mn.y), Vector3(mx.x - mn.x, 20000.0, mx.y - mn.y))


## Snap a footprint AABB to the terrain grid → [min_x, max_x, min_z, max_z] (world XZ).
func _snapped_bounds(aabb: AABB, vs: float) -> Array:
	var min_x := floorf(aabb.position.x / vs) * vs
	var min_z := floorf(aabb.position.z / vs) * vs
	var max_x := ceilf((aabb.position.x + aabb.size.x) / vs) * vs
	var max_z := ceilf((aabb.position.z + aabb.size.z) / vs) * vs
	return [min_x, max_x, min_z, max_z]


## Increasing 0→1 ramp from an optional Curve, defaulting to smoothstep.
func _ramp(c: Curve, x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	if c:
		return c.sample_baked(x)
	return smoothstep(0.0, 1.0, x)


## Crest cross-section: 1 at the centre (t=0) falling to 0 at the edge (t=1). Default = rounded cosine.
func _cross(c: Curve, t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	if c:
		return c.sample_baked(t)
	return 0.5 + 0.5 * cos(t * PI)


## Number of samples in a profile LUT handed to the native rasteriser.
const RAMP_LUT_N: int = 256

## Bake `_ramp(c, x)` to a LUT so the native rasteriser evaluates the SAME ramp (curve or smoothstep
## default) without per-cell GDScript callbacks. Always full (never empty) so C++ just interpolates.
func _ramp_lut(c: Curve) -> PackedFloat32Array:
	var lut := PackedFloat32Array()
	lut.resize(RAMP_LUT_N)
	for i in range(RAMP_LUT_N):
		lut[i] = _ramp(c, float(i) / float(RAMP_LUT_N - 1))
	return lut


## NaN-aware separable 3-tap Gaussian blur of a packed grid (returns the blurred copy — PackedFloat32Array
## is copy-on-write, so callers must reassign: `vals = _blur_grid(vals, gw, gh, passes)`). Cells holding NAN
## are skipped (no contribution) so the blur never bleeds a feature past its footprint. No-op (returns the
## input untouched) when passes <= 0 — an unused smoother costs nothing. Mirrors the C++ nan_blur exactly
## so the GDScript reference stays an exact A/B oracle of the native path.
func _blur_grid(vals: PackedFloat32Array, gw: int, gh: int, passes: int) -> PackedFloat32Array:
	if passes <= 0:
		return vals
	var tmp := PackedFloat32Array()
	tmp.resize(gw * gh)
	for _pass in range(passes):
		# Horizontal: vals -> tmp
		for iz in range(gh):
			var row := iz * gw
			for ix in range(gw):
				var v: float = vals[row + ix]
				if not is_finite(v):
					tmp[row + ix] = NAN
					continue
				var s := 0.5 * v
				var wt := 0.5
				if ix > 0 and is_finite(vals[row + ix - 1]): s += 0.25 * vals[row + ix - 1]; wt += 0.25
				if ix < gw - 1 and is_finite(vals[row + ix + 1]): s += 0.25 * vals[row + ix + 1]; wt += 0.25
				tmp[row + ix] = s / wt
		# Vertical: tmp -> vals
		for iz in range(gh):
			var row := iz * gw
			for ix in range(gw):
				var v: float = tmp[row + ix]
				if not is_finite(v):
					vals[row + ix] = NAN
					continue
				var s := 0.5 * v
				var wt := 0.5
				if iz > 0 and is_finite(tmp[(iz - 1) * gw + ix]): s += 0.25 * tmp[(iz - 1) * gw + ix]; wt += 0.25
				if iz < gh - 1 and is_finite(tmp[(iz + 1) * gw + ix]): s += 0.25 * tmp[(iz + 1) * gw + ix]; wt += 0.25
				vals[row + ix] = s / wt
	return vals


## Bake `_cross(c, t)` to a LUT (cosine default) for the polyline rasterisers.
func _cross_lut(c: Curve) -> PackedFloat32Array:
	var lut := PackedFloat32Array()
	lut.resize(RAMP_LUT_N)
	for i in range(RAMP_LUT_N):
		lut[i] = _cross(c, float(i) / float(RAMP_LUT_N - 1))
	return lut


## Ridge cross-section, corrected convention: 1 at the centre (d=0) → 0 at the skirt edge (d=1), but a
## custom Curve is read edge→centre (sampled at 1-d) so an INCREASING curve makes a natural peaked ridge,
## consistent with Trough's bank_profile. Default (no curve) = rounded cosine — identical to the old
## behaviour (cosine is symmetric), so default-shaped ridges are unchanged; only custom-curve ridges flip.
func _ridge_cross(c: Curve, d: float) -> float:
	d = clampf(d, 0.0, 1.0)
	if c:
		return c.sample_baked(1.0 - d)
	return 0.5 + 0.5 * cos(d * PI)


func _ridge_cross_lut(c: Curve) -> PackedFloat32Array:
	var lut := PackedFloat32Array()
	lut.resize(RAMP_LUT_N)
	for i in range(RAMP_LUT_N):
		lut[i] = _ridge_cross(c, float(i) / float(RAMP_LUT_N - 1))
	return lut


## True when the native C++ rasteriser for `method` is available (post-Round-2 build). Falls back to the
## GDScript reference loop otherwise.
func _native_raster(method: String) -> bool:
	return not force_gdscript_raster and not _stack_forces_gdscript() \
			and terrain != null and terrain.data != null and terrain.data.has_method(method)


## True when the stack carries an op the native rasteriser cannot run, so the whole stamp must take the
## GDScript path. The native side now runs a Pasture3DNodeGraph (a BrushModStep::GRAPH in
## pasture_3d_brush_raster.cpp) as long as every node in the graph is one it implements — so a graph forces
## GDScript ONLY when it uses an op the native whole-graph evaluator does not know
## (`graph.native_supported()`), which would otherwise be silently dropped. See
## PASTURE3D_TERRAIN_GRAPH_SPEC.md (native grid-pass interleave).
func _stack_forces_gdscript() -> bool:
	if not _supports_modifiers():
		return false
	for m in modifiers:
		if m != null and m.is_active() and m.op() == &"graph":
			if m.graph == null or not m.graph.native_supported():
				return true
		# A road grader takes the GDScript path when the native stamp_road_line is absent, and also when
		# it is not the whole answer for this stack — see _road_native_is_complete().
		if m != null and m.is_active() and m.op() == &"road":
			if terrain == null or terrain.data == null or not terrain.data.has_method("stamp_road_line"):
				return true
			if not _road_native_is_complete():
				return true
	return false


## True when the native stamp_road_line is a COMPLETE answer for this stack: exactly one active modifier
## and it is the road grader.
##
## stamp_road_line writes the graded surface into the layer itself and returns; it has no way to compose
## with a second modifier, because the second modifier expects an amplitude/profile grid to transform and
## the native road path never materialises one. So a stack with anything else in it goes back to GDScript
## in its entirety, which is slower and correct, rather than the extra modifier being dropped in silence.
##
## Dropping it silently is exactly the failure the comment removed from _stack_forces_gdscript warned
## about: the brush paints, nothing errors, and the noise or erosion step the user added simply has no
## effect with nothing said about why.
##
## This is the ONE place the question is answered. _paint_flat_footprint gates its fast path on it too,
## so the decision to take the native branch and the decision to allow it cannot drift apart.
func _road_native_is_complete() -> bool:
	var active := 0
	var road := 0
	for m in modifiers:
		if m != null and m.is_active():
			active += 1
			if m.op() == &"road":
				road += 1
	return active == 1 and road == 1


## Grid of the height of layers BELOW this brush's own, over the spline grid (origin min_x/min_z, step vs,
## gw*gh). The native rasterisers sample this instead of the full terrain so features don't climb each
## other / their own layer. Empty when there's no lower layer or the API is absent → the rasteriser then
## falls back to the live height (only where no lower layer covers, i.e. no terrain → nothing painted).
func _base_below_grid(min_x: float, min_z: float, vs: float, gw: int, gh: int) -> PackedFloat32Array:
	if _layer_id > 0 and terrain.data.has_method("composite_height_below"):
		return terrain.data.composite_height_below(_layer_id, min_x, min_z, vs, gw, gh)
	return PackedFloat32Array()


## Height of the layers below this brush's, at a world position (snap + the GDScript fallback rasteriser).
## Falls back to the full composited height where no lower layer covers (or the API is absent).
func _base_height_below(pos: Vector3) -> float:
	if _layer_id > 0 and terrain.data.has_method("get_height_below"):
		var h: float = terrain.data.get_height_below(_layer_id, pos)
		if is_finite(h):
			return h
	return terrain.data.get_height(pos)


## Regions this brush's splines reach into that do not exist, and the total it spans.
## Returns [missing, spanned].
##
## Both native write paths drop cells with no region under them and neither says so
## ([pasture_3d_brush_raster.cpp:343](src/pasture_3d_brush_raster.cpp:343), and the matching skip in
## `_apply_stamp_block`). That is the right behaviour — a brush must not invent terrain — but at scale
## it is silent data loss: at the 256 m default a 2 km loop spans 121 regions, so a big water body
## reaching past the edge of the built world carves only the part that happens to be covered, and looks
## like a brush that half-works. Counting them is what lets a subclass say so.
##
## XZ only, like every other footprint test here. Returns [0, 0] when there is nothing to measure, so a
## caller can treat "no splines" and "fully covered" the same way.
func _region_coverage() -> Array:
	if terrain == null or terrain.data == null or not is_inside_tree():
		return [0, 0]
	if not terrain.data.has_method("has_regionp"):
		return [0, 0]
	var rs: float = float(terrain.region_size) * terrain.vertex_spacing
	if rs <= 0.0:
		return [0, 0]
	var seen := {}
	var missing := 0
	for s in _get_splines():
		var a := _spline_footprint_aabb(s)
		if a.size == Vector3.ZERO:
			continue
		var rx0 := int(floor(a.position.x / rs))
		var rx1 := int(floor((a.position.x + a.size.x) / rs))
		var rz0 := int(floor(a.position.z / rs))
		var rz1 := int(floor((a.position.z + a.size.z) / rs))
		for rx in range(rx0, rx1 + 1):
			for rz in range(rz0, rz1 + 1):
				var key := Vector2i(rx, rz)
				if seen.has(key):
					continue
				seen[key] = true
				if not terrain.data.has_regionp(Vector3((rx + 0.5) * rs, 0.0, (rz + 0.5) * rs)):
					missing += 1
	return [missing, seen.size()]


## ---- Relief material support (PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md, PASTURE3D_MOUND_RELIEF_SPEC.md) ----
##
## Shared by every brush that can stamp a Pasture3DReliefMaterial. These lived on Pasture3DPlow until
## Pasture3DMound became the second host; nothing here reads a plow-specific member, and the three that
## need a material take it as an argument rather than reaching for an `relief` property the base has no
## business knowing about.

## Samples per cycle a periodic feature needs before meshing and LOD stop resolving it. Four is the
## practical floor: two is Nyquist, which reconstructs a frequency but not a recognisable profile.
const PERIOD_SAMPLES_MIN := 4.0


## True when the compiled program reads the ground beneath it — any gated op, or any SCREE. The terrain
## field grids cost O(cells) to build, so a material that ignores them must not pay for them.
func _needs_terrain_fields(ops: PackedInt32Array) -> bool:
	for i in range(ops.size() / Pasture3DReliefMaterial.OP_STRIDE):
		var o := i * Pasture3DReliefMaterial.OP_STRIDE
		if ops[o + 2] >= 0 or ops[o] == Pasture3DReliefMaterial.Op.SCREE:
			return true
		# A GROUND_ALTITUDE band reads `alt` out of the below-layer set, so it needs the fields even
		# though it carries no selector.
		if _band_source_of(ops, i) == Pasture3DReliefMaterial.BandSource.GROUND_ALTITUDE:
			return true
	return false


## True when this brush generates a shape of its own that a selector or a band op can read — a Mound's
## dome, and later a Ridge's crest section. False on the hosts whose output IS their shape (Plow, Splat)
## and on Sim, which is a transform over a surface rather than a landform.
##
## Overridden rather than sniffed from the class so a new landform host opts in deliberately: the field
## has to be BUILT by that host's rasteriser, and a host that answers yes without building it would gate
## everything to zero with no warning at all — the exact failure this method exists to report.
func _offers_host_profile() -> bool:
	return false


## The BandSource a PROFILE band op carries, or ACCUMULATOR for every op that is not one. One place that
## knows the flag packing, so the two predicates below and any future reader cannot disagree about it.
func _band_source_of(ops: PackedInt32Array, i: int) -> int:
	var o := i * Pasture3DReliefMaterial.OP_STRIDE
	if (ops[o] != Pasture3DReliefMaterial.Op.TERRACE
			and ops[o] != Pasture3DReliefMaterial.Op.STRATIFY):
		return Pasture3DReliefMaterial.BandSource.ACCUMULATOR
	return ((ops[o + 3] & Pasture3DReliefMaterial.FLAG_BAND_MASK)
			>> Pasture3DReliefMaterial.FLAG_BAND_SHIFT)


## True when the compiled program reads the HOST BRUSH'S OWN generated profile — either through a selector
## whose Field Source is Host Profile, or through a TERRACE / STRATIFY banding it.
##
## Only landform brushes can answer yes; a Pasture3DPlow never builds the field, so a program asking for it
## there reads a defined zero and the brush warns. Kept beside _needs_terrain_fields because the two are
## the same kind of question over the same program, and a caller almost always asks both.
func _needs_host_fields(ops: PackedInt32Array, op_selectors: PackedFloat32Array) -> bool:
	var stride := Pasture3DReliefMaterial.SELECTOR_STRIDE
	for i in range(ops.size() / Pasture3DReliefMaterial.OP_STRIDE):
		var o := i * Pasture3DReliefMaterial.OP_STRIDE
		# BOTH gate slots. A material selector landing in the second one (spec §16.3) reads the host
		# profile exactly as it would in the first, and a predicate that only looked at the first would
		# leave the field unbuilt — which gates everything to zero with no warning, the failure
		# _offers_host_profile exists to make loud.
		for slot in [2, Pasture3DReliefMaterial.OP_GATE_2]:
			var sid := ops[o + slot]
			if sid < 0:
				continue
			var b := sid * stride + Pasture3DReliefMaterial.SELECTOR_FIELD_SOURCE
			if (b < op_selectors.size()
					and int(op_selectors[b]) == Pasture3DTerrainMask.FieldSource.HOST_PROFILE):
				return true
		if _band_source_of(ops, i) == Pasture3DReliefMaterial.BandSource.HOST_PROFILE:
			return true
	return false



# ---------------------------------------------------------------------------------------------------
# The modifier stack (PASTURE3D_BRUSH_EROSION_SPEC.md §6). An ordered, saveable list of operations
# applied to this brush's OWN output grid, after its profile is rasterised and before that grid is
# composited into the terrain layer.
#
# See Pasture3DNode's header for the POINT / FIELD split the whole thing rests on. This half is
# the host side: compile the list once per bake, and — on the GDScript oracle path — run it.
# ---------------------------------------------------------------------------------------------------

## The stack. Declared as a plain var and surfaced through `_get_property_list` rather than as an
## `@export`, so it lands at the BOTTOM of the inspector, after the subclass's own shape properties. A
## pipeline reads in order, and the order it reads in should be the order it runs in — a base-class
## `@export` would have put it above every property it consumes.
var modifiers: Array[Pasture3DNode] = []:
	set(v):
		_bind_modifiers(modifiers, false)
		modifiers = v
		_bind_modifiers(modifiers, true)
		# Unconditional here, unlike `_on_modifier_changed`: the list itself changed length or contents,
		# so the rows and the Mask Preview Source dropdown both have to be rebuilt anyway.
		_stack_names_cache = _stack_names()
		_stack_ui_signature = _inspector_rebuild_signature()
		notify_property_list_changed()
		_queue_mask_preview()
		_schedule_refresh()
		update_configuration_warnings()

## Extra metres of terrain drawn into the working grid around each loop, so the modifier stack has ground
## OFF the loop to work on. The brush's own profile still stops at the loop edge (§6.8's NaN outside is
## unchanged there); this only widens the grid on every side and seeds the widened band with the REAL
## surface below. Its reason for existing is erosion: with a margin, the sediment an Erosion modifier
## carries off the flanks has somewhere to deposit, forming a skirt that blends the brush into the
## surrounding landscape instead of ending in the hard cut §6.8 leaves. 0 keeps the historical footprint
## (loop + `_padding()`'s ~2 m technical pad) and the exact no-margin, drainage-divide behaviour §6.8
## measured. Surfaced through `_get_property_list` (Modifiers group) so it only shows on hosts that run the
## stack. See PASTURE3D_BRUSH_EROSION_SPEC.md §6.8.
## Below this movement (metres) a margin cell counts as untouched by the stack and goes back to being a
## no-write, so an unworked skirt zone does not stamp the base surface across the widened box.
const MODIFIER_MARGIN_EPS := 0.001

var modifier_margin: float = 0.0:
	set(v):
		v = maxf(v, 0.0)
		if v == modifier_margin:
			return
		modifier_margin = v
		# The footprint AABB — and so the grid extent — just changed, which makes every cached stamp the
		# wrong size to reuse. Drop them and take the full-repaint path.
		_stamp_cache.clear()
		_schedule_refresh()

## Last Mask Preview Source list, and last set of modifier names. Not exported — they are comparison
## caches, and a stale one after a scene load costs at most one extra rebuild.
var _stack_ui_signature: PackedStringArray = PackedStringArray()
var _stack_names_cache: PackedStringArray = PackedStringArray()


## True when this brush's rasteriser actually RUNS the stack. False hides the property entirely rather
## than shipping a slot that silently does nothing — the same reason `_offers_host_profile` is an
## opt-in override and not a class sniff.
##
## Phase 3a wires exactly one host: Pasture3DMound. The others keep their own noise / relief / smoothing
## properties until their rasterisers are converted, which is a separate piece of work with its own gates
## (§6.6 — Pasture3DPlow in particular cannot lose `relief` without losing its Source enum).
func _supports_modifiers() -> bool:
	return false


func _has_relief_modifier() -> bool:
	for m in modifiers:
		if m is Pasture3DNodeRelief and m.is_active():
			return true
	return false


## Connect or disconnect every modifier's `changed`, so editing one re-bakes. Nested resources do not
## propagate `changed` on their own; each modifier forwards its own children's (a Relief modifier's
## material, a Noise modifier's FastNoiseLite) through `_touch`.
func _bind_modifiers(p_list: Array, p_connect: bool) -> void:
	for m in p_list:
		if m == null:
			continue
		var live: bool = m.changed.is_connected(_on_modifier_changed)
		if p_connect and not live:
			m.changed.connect(_on_modifier_changed)
		elif not p_connect and live:
			m.changed.disconnect(_on_modifier_changed)


func _on_modifier_changed() -> void:
	# A RENAME IS NOT A CHANGE TO THE BRUSH, and it arrives one keystroke at a time.
	#
	# `Resource.set_name` emits `changed` like every other setter, so typing into a modifier's `label`
	# fires this handler once per character. Two things must not happen then. A re-bake would raster the
	# whole brush per keystroke; and `notify_property_list_changed()` would tear down the very text field
	# being typed into, so the field closed after the first character. Both are answered by leaving early.
	var names := _stack_names()
	if names != _stack_names_cache:
		_stack_names_cache = names
		update_configuration_warnings() # warnings name the modifier they are about
		return

	# NOT an unconditional notify_property_list_changed() either. A rebuild COLLAPSES every expanded
	# sub-resource, so dragging one slider inside a modifier folded the modifier shut under the cursor,
	# once per step. Only ONE thing the inspector shows is derived from the stack rather than stored in
	# it — the Mask Preview Source dropdown, whose entries come from the first Relief modifier's material
	# — so only a change to THAT is worth a rebuild.
	#
	# And only to its STRUCTURE. See `_inspector_rebuild_signature`: the signature deliberately excludes
	# every value and every name, because both are edited continuously and a rebuild mid-edit is the bug
	# this guard exists for. The row labels are derived too and are deliberately not on the list either —
	# the inspector re-reads `resource_name` on its own refresh, and forcing it would cost the text field
	# its focus.
	var now := _inspector_rebuild_signature()
	if now != _stack_ui_signature:
		_stack_ui_signature = now
		notify_property_list_changed()
	for s in _get_splines():
		if is_instance_valid(s):
			_dirty_splines[s.get_instance_id()] = true
	_queue_mask_preview()
	_arm_refresh_timer()
	update_configuration_warnings()


## Each modifier's row name, in order. Compared against `_stack_names_cache` to recognise a `changed`
## that carried nothing but a rename.
func _stack_names() -> PackedStringArray:
	var out := PackedStringArray()
	for m in modifiers:
		out.append("" if m == null else m.resource_name)
	return out


## What the derived half of `_get_property_list` actually depends on — STRUCTURE ONLY. Compared before
## and after a modifier's `changed` to decide whether the inspector has to be rebuilt.
##
## THE RULE THIS ENFORCES: a property list must never be a function of a value or of a name. Both are
## edited CONTINUOUSLY — a slider sweeps, a text field arrives one character at a time — and every
## rebuild collapses every expanded sub-resource under the cursor. So this holds only discrete facts:
## whether there is a preview material at all, what class each dropdown entry is, and whether that entry
## carries a selector. Strengths, `enabled`, and every `resource_name` are excluded by construction.
##
## The cost is that a RENAMED relief layer keeps its old text in the Mask Preview Source dropdown until
## something else rebuilds the inspector. The dropdown resolves BY INDEX, so nothing reads the wrong
## selector — the label is stale, not wrong. Gates CT and CU (bench/InspectorStabilityGate.tscn).
func _inspector_rebuild_signature() -> PackedStringArray:
	var out := PackedStringArray()
	var relief = _preview_relief_material()
	if relief == null:
		return out
	for e in _preview_selector_sources(relief):
		out.append("%s%s" % [e[2], "+" if e[1] != null else "-"])
	return out


## The erosion modifiers in this brush's stack, in stack order. Empty on a brush whose rasteriser does
## not run the stack, and empty for a stack that has none — both of which are the same answer to the only
## question the registry asks: "is there a solve here worth re-running?"
##
## `enabled` rather than `is_active()`, deliberately. `is_active()` is false at a zero erosion rate, which
## is a modifier being tuned, not a modifier that is not there — and a registry that quietly dropped a
## brush when its rate passed through 0 would be the same class of bug as a property list that follows a
## slider (see `_inspector_rebuild_signature`).
func erosion_modifiers() -> Array:
	var out: Array = []
	if not _supports_modifiers():
		return out
	for m in modifiers:
		if m is Pasture3DNodeErosion and m.enabled:
			out.append(m)
	return out


## Drop every erosion modifier's cached solve, so the next bake re-solves against the current surface.
## This is what "Bake All Brushes" does before it bakes: erosion defaults to FROZEN (§6.3), so a bake that
## did not clear first would serve the cached answer and the button would appear to do nothing on exactly
## the brushes it exists for. Returns how many were cleared.
func clear_erosion_caches() -> int:
	var n := 0
	for m in erosion_modifiers():
		m.clear_cache()
		n += 1
	return n


## Every active modifier's complaint, plus the one the stack itself can make.
func _modifier_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if not _supports_modifiers() or modifiers.is_empty():
		return w
	var sims := {}
	for m in modifiers:
		if m == null:
			continue
		w.append_array(m.modifier_warnings(self))
		if m is Pasture3DNodeRelief and m.is_active():
			var r := _relief_sim_result(m.material)
			if r != null:
				sims[r] = true
	# One bake resamples ONE Pasture3DSimResult onto its grid, so two relief modifiers pointing at
	# different results is not a thing this can honour. Say so rather than silently using the first: a
	# selector reading the wrong sim looks exactly like a selector whose band is mis-set.
	if sims.size() > 1:
		w.append(("Two Relief modifiers read different Sim Results. One bake can resample only one, "
			+ "so the first is used and the rest are ignored. Point them at the same result, or split "
			+ "them across two brushes."))
	return w


## Compile the stack once per bake — never per cell. Returns:
##   `list`         per-modifier param blocks for the native rasteriser, in stack order
##   `gd`           the same steps for the GDScript oracle, each carrying the modifier and its slice of
##                  the selector block
##   `op_selectors` the STACK-WIDE selector block: every relief modifier's block concatenated, with its
##                  ops' selector ids rebased into it
##   `need_fields` / `need_host` / `sim`
##
## The rebasing is the one piece of bookkeeping the stack adds. Selector ids are indices into a single
## flat block, and two materials each numbering their selectors from 0 would collide in the measured-field
## slots (`ReliefFields::sel_slot`) that are keyed by id. Concatenating and offsetting keeps ONE block, so
## the native evaluator, the measured-radius grids and the mask preview all keep indexing it the way they
## already do.
## `p_ex` / `p_ez` are the LOOP'S ORIENTED HALF-EXTENTS, in metres, and they are an input to the compile
## rather than something read off it: a relief material with a baked field (a DLA) grows that field to the
## loop's proportions, inside compile(). Hosts that have no oriented frame — or whose frame is a disc —
## leave them at 1.0, which reads as "isotropic". See Pasture3DReliefMaterial.set_host_frame.
func _compile_modifiers(p_extent: String = "", p_ex: float = 1.0, p_ez: float = 1.0) -> Dictionary:
	var out := {
		"list": [], "gd": [], "op_selectors": PackedFloat32Array(),
		"need_fields": false, "need_host": false, "sim": null, "count": 0,
	}
	if not _supports_modifiers():
		return out
	var stride := Pasture3DReliefMaterial.SELECTOR_STRIDE
	var sel := PackedFloat32Array()
	for m in modifiers:
		if m == null or not m.is_active():
			continue
		var blk: Dictionary = m.to_params()
		blk["op"] = m.op()
		var step := {"mod": m, "op": m.op(), "grid": m.needs_grid()}
		if m._supports_freezing():
			# `out` is a plain Dictionary handed BOTH ways: the rasteriser writes the solve into it and
			# `_commit_modifier_caches` reads it back after the bake. Dictionaries are reference types,
			# which is the whole reason a void rasteriser call can return a grid.
			var slot := {}
			var entry: Dictionary = m.cache_for(p_extent) if p_extent != "" else {}
			blk["frozen"] = m.evaluation == Pasture3DNode.Evaluation.FROZEN
			blk["cache_key"] = int(entry.get("key", 0))
			blk["cache"] = entry.get("grid", PackedFloat32Array())
			blk["cache_flow"] = entry.get("flow", PackedFloat32Array())
			blk["cache_ero"] = entry.get("ero", PackedFloat32Array())
			blk["cache_dep"] = entry.get("dep", PackedFloat32Array())
			blk["cache_wet"] = entry.get("wet", PackedFloat32Array())
			# §14. Pass 1 of the deferred driver: hand the surface back instead of solving it. Only
			# meaningful on a FROZEN step, because the cache is how the answer gets delivered.
			blk["defer"] = _erosion_suppress or (_erosion_defer and bool(blk["frozen"]))
			blk["out"] = slot
			step["out"] = slot
		if m is Pasture3DNodeGraph and m.graph != null:
			# The native rasteriser needs the whole-graph program (Pasture3DUtil.graph_eval_grid reads it),
			# the amount, and the two freeze inputs its key folds in — reads_input decides whether the input
			# surface is in the key. GDScript's _apply_graph_step ignores these; only the native path reads them.
			blk["graph_program"] = m.graph.compile_graph_program()
			blk["strength"] = m.strength
			blk["reads_input"] = m.graph.reads_input()
			blk["content_key"] = m.graph.content_key()
			blk["feather_mode"] = int(m.feather_mode)
			blk["custom_falloff_width"] = m.custom_falloff_width
			blk["custom_lut"] = _ramp_lut(m.custom_falloff_curve)
		if m is Pasture3DNodeRelief:
			m.material.set_host_frame(p_ex, p_ez)
			# §9.9. Offered on EVERY compile, never left set from a previous pass: the flag says what is
			# true of the bake in flight, and a material that had to remember which pass it was in would
			# be one cancelled driver away from refusing to grow for good.
			m.material.set_growth_deferred(_growth_defer)
			var prog: Array = m.material.compile()
			var ops: PackedInt32Array = prog[0]
			var mat_sel: PackedFloat32Array = prog[3]
			# A material still WAITING for its seed surface compiles to nothing, and that is exactly the
			# bake on which it has to be in the list: the capture is what gives it one. So an empty program
			# is only a no-op when nobody is listening for the surface.
			# Asked through the base-class virtual, not through has_method. The duck-typed version answered
			# "did this class implement it", which is false for a STACK holding a seeded DLA — so a stacked
			# DLA's Ridge Seeding compiled to nothing, was dropped here as a no-op, and never got a capture.
			var wants_seed: bool = m.material.wants_seed_surface()
			# Asked BEFORE the no-op test below, because a material that deferred its growth compiles to
			# nothing and IS dropped from this bake — correctly, it contributes nothing — and dropping the
			# request with it is how the driver would come to wait forever for a pass that never asks.
			m.material.collect_growth(_pending_growth)
			if ops.is_empty() and not wants_seed:
				continue # a material that compiles to nothing is not a step, it is a no-op
			# Ask the predicates BEFORE rebasing: both index the material's own selector block by the
			# ids its own ops carry, and after the rebase those ids point into the combined block.
			out["need_fields"] = bool(out["need_fields"]) or _needs_terrain_fields(ops)
			out["need_host"] = bool(out["need_host"]) or _needs_host_fields(ops, mat_sel)
			var base := int(sel.size() / stride)
			var rebased := ops.duplicate()
			for i in range(rebased.size() / Pasture3DReliefMaterial.OP_STRIDE):
				var o := i * Pasture3DReliefMaterial.OP_STRIDE
				if rebased[o + 2] >= 0:
					rebased[o + 2] += base
			sel.append_array(mat_sel)
			blk["ops"] = rebased
			blk["op_params"] = prog[1]
			blk["op_luts"] = prog[2]
			blk["op_fields"] = prog[4]
			blk["op_field_meta"] = prog[5]
			# A material that has to be BUILT from the stack above it asks for the working surface at its own
			# position in the list. `capture` splits the point run there, which costs one grid conversion --
			# only for a stack that has one, and only while it is switched on.
			if wants_seed:
				var slot := {}
				blk["capture"] = true
				blk["out"] = slot
				step["capture"] = true
				step["out"] = slot
			step["sel_base"] = base
			step["sel_count"] = int(mat_sel.size() / stride)
			if out["sim"] == null:
				out["sim"] = _relief_sim_result(m.material)
		out["list"].append(blk)
		out["gd"].append(step)
	out["op_selectors"] = sel
	out["count"] = out["list"].size()
	return out


## Identifies one bake grid, so a brush with several loops caches one frozen solve PER LOOP rather than
## thrashing a single slot between them.
func _extent_key(p_min_x: float, p_min_z: float, p_vs: float, p_gw: int, p_gh: int) -> String:
	return "%d,%d,%d,%d" % [roundi(p_min_x / p_vs), roundi(p_min_z / p_vs), p_gw, p_gh]


## Store what the bake solved, and record which modifiers served stale data. Called after BOTH paths,
## because both fill the same `out` dictionaries.
func _commit_modifier_caches(p_stack: Dictionary, p_extent: String, p_frame: Array = []) -> void:
	var reseeded := false
	for step in p_stack["gd"]:
		if not step.has("out"):
			continue
		var out: Dictionary = step["out"]
		var m = step["mod"]
		if out.has("surface") and not p_frame.is_empty():
			# The frame travels with the grid because the two are different rectangles: the grid is the
			# spline's axis-aligned bounding box, the field is the loop's ORIENTED rect, and on a rotated
			# loop a plain rescale between them would shear the ridges off their own crest lines.
			var surf := {"surface": out["surface"], "gw": out.get("gw", 0), "gh": out.get("gh", 0),
					"frame": p_frame}
			reseeded = m.material.set_seed_surface(surf) or reseeded
		if out.has("pending"):
			# §14 pass 1. Nothing was solved; the surface that WOULD have been is waiting here, with the
			# key it will be stored under. Recorded rather than solved because this is still the bake.
			if m is Pasture3DNodeErosion:
				_pending_erosion.append({
					"mod": m, "extent": p_extent,
					"z0": out["pending"], "z": out["pending"], "key": int(out["pending_key"]),
					"gw": int(out["pending_gw"]), "gh": int(out["pending_gh"]),
					"iterations": maxi(m.iterations, 1), "done": 0, "failed": false,
					"want_diagnostics": m.publish_fields, "res": {},
					"params": m.to_params(), "erod": PackedFloat32Array(),
				})
			elif m is Pasture3DNodeGraph and m.graph != null:
				_pending_graph.append({
					"mod": m,
					"graph": m.graph,
					"gw": int(out["pending_gw"]),
					"gh": int(out["pending_gh"]),
					"rect": out.get("pending_rect", m.last_rect),
					"z": out["pending"],
					"key": int(out["pending_key"]),
					"extent": p_extent,
					"done": 0,
				})
		if out.has("grid"):
			m.store_cache(p_extent, {
				"key": out["key"], "grid": out["grid"],
				"flow": out.get("flow", PackedFloat32Array()),
				"ero": out.get("ero", PackedFloat32Array()),
				"dep": out.get("dep", PackedFloat32Array()),
				"wet": out.get("wet", PackedFloat32Array()),
			})
		# Only an EROSION modifier has a staleness flag. Relief steps reach this loop too now that one of
		# them can ask for a surface, and asking them about staleness would be a crash rather than a
		# question with an answer.
		if m.has_method("set_stale"):
			m.set_stale(bool(out.get("stale", false)))
	# A material that had never seen a surface stamped NOTHING on this bake, and one whose surface moved
	# stamped the previous shape. Either way the answer is one more bake, which converges because the
	# captured surface EXCLUDES the material that reads it -- the second pass captures the same grid, the
	# hash matches, and nothing more is scheduled.
	if reseeded:
		_schedule_refresh()


## Run the compiled stack over the GDScript-side grids. The oracle for the native path in
## `Pasture3DData::stamp_mound_loop`, and the fallback on builds without the extension.
##
## `p_amp` is the brush's contribution in metres, NaN where it contributes nothing; `p_profile` its 0..1
## interior mask; `p_basey` the surface each cell is measured from. The first two are DOUBLE grids because
## the hard-coded pipeline kept both in double locals and only rounded once, at the store into `vals` —
## rounding either earlier would change every product they appear in and cost gate BW its claim.
## `p_basey` is float32 because it already is one: every source of it returns a C++ `float`. Returns the finished `vals` grid in
## the layer's own units — a delta under BLEND_ADD, an absolute target otherwise.
##
## WHY THERE ARE TWO REPRESENTATIONS. A point modifier adds metres to `p_amp`; a field modifier transforms
## the grid that will be written. Under a non-ADD blend those are different quantities (`vals = basey +
## amp`), so the runner tracks which one currently holds the truth and converts only when the next step
## needs the other. A stack of `Noise -> Relief -> Smooth` therefore converts exactly once, at the same
## point the hard-coded pipeline did — which is what lets gate BW ask for a BITWISE match rather than a
## tolerance.
func _run_modifier_stack(p_steps: Array, p_amp: PackedFloat64Array, p_profile: PackedFloat64Array,
		p_basey: PackedFloat32Array, p_ctx: Dictionary) -> PackedFloat32Array:
	var n: int = int(p_ctx["gw"]) * int(p_ctx["gh"])
	var add: bool = p_ctx["add"]
	p_ctx["basey"] = p_basey # a field modifier may need the absolute surface, not the delta

	# ---- The Modifier Margin, applied ONCE, HERE (PASTURE3D_BRUSH_EROSION_SPEC.md §6.8.1) --------------
	#
	# THIS IS THE WHOLE FEATURE, and it is deliberately at the stack BOUNDARY rather than inside any
	# modifier. The grid was already widened by `_total_padding()`; every cell in the widened band is a cell
	# the brush itself contributes nothing to (`amp` = NaN) but which HAS real ground under it (`basey`
	# finite). Materialising those cells as `amp = 0` — "the brush adds nothing here, but this cell is in
	# play" — hands the stack a working surface that simply extends past the loop onto the real terrain.
	#
	# Every modifier then gets the margin for free and none of them knows it exists: an Erosion step reads
	# an absolute surface with ground off the loop, so its sediment has somewhere to land instead of
	# draining out of §6.8's NaN outlet at the loop edge. That is the skirt. A modifier added later inherits
	# the same behaviour without being taught anything.
	#
	# THE MARGIN MOVES THE BRUSH'S RAMP OUTWARD — it does not add a second one.
	#
	# `profile` is the brush's 0..1 mask: 1 at the loop centre, falling to 0 AT THE RIM. The band's own
	# taper runs the other way, 1 at the rim falling to 0 at the band's outer edge. They are two masks with
	# opposite boundary values over one grid, and two wrong ways to reconcile them have now been measured:
	#
	#   Storing the band's taper INTO `profile` put a step of the modifier's full amplitude one cell outside
	#   every loop — a seam ringing the brush (0.97 of full amplitude on a 30 m falloff).
	#   Zeroing the band instead removed the seam and CROPPED the brush to its own footprint, which defeats
	#   the margin: the whole point is that the stack reaches past the loop.
	#
	# What the margin actually means is that the ramp starts further out. So `profile_ext` is the host's own
	# ramp evaluated at `signed_d + margin` — the identical curve, translated. It is 0 exactly at the band's
	# outer edge, rises through the band, and is already at full strength by the rim when the margin exceeds
	# the falloff. Monotone, continuous everywhere, equal to `profile` when the margin is 0, and it moves
	# smoothly as the margin is dragged rather than snapping when it leaves 0.
	#
	#   GENERATOR (Noise, Relief, a graph with no Input node) — `profile_ext`. It reaches into the band and
	#       fades at the band's outer edge instead of at the rim, which is the footprint expansion asked for.
	#   FILTER (Erosion, a graph that reads its input) — 1 across the loop, then `margin_feather` through
	#       the band. A filter transforms ground that is already there, so it applies fully over the brush
	#       and has only the band to taper through. The margin exists for these: it is the erosion skirt.
	#
	# The reverse conversion is at the other end of this function, and is the reason materialising is safe:
	# a margin cell the stack did not actually move goes back to NaN, so the widened footprint is never
	# flooded with base terrain. Only ground the stack WORKED is written.
	var margin_m := _effective_modifier_margin()
	var margin: bool = margin_m > 0.0
	var margin_mask := PackedByteArray()
	var margin_feather := PackedFloat64Array()
	if margin:
		margin_mask.resize(n)
		margin_feather.resize(n)
		var sdf: PackedFloat32Array = p_ctx.get("sdf", PackedFloat32Array())
		var edge_off: float = p_ctx.get("edge_offset", 0.0)
		var have_sdf := sdf.size() == n
		# The host evaluates its OWN ramp at `signed_d + margin` — only it knows the curve — and hands the
		# grid over. Absent (a host that runs the stack without a ramp) falls back to the un-shifted mask,
		# which crops rather than reaching: correct, just not the point of the feature.
		var ext: PackedFloat64Array = p_ctx.get("profile_ext", PackedFloat64Array())
		if ext.size() == n:
			for k in range(n):
				p_profile[k] = ext[k]
		for k in range(n):
			if is_finite(p_amp[k]) or not is_finite(p_basey[k]):
				continue
			p_amp[k] = 0.0
			margin_mask[k] = 1
			if not have_sdf:
				continue
			# Metres OUTSIDE the loop boundary (the signed field is positive inside), feathered to 0 at the
			# outer edge of the band so the skirt has somewhere to fade rather than a second hard rim.
			var d_out: float = -(sdf[k] + edge_off)
			if d_out < 0.0:
				continue
			margin_feather[k] = smoothstep(0.0, 1.0, 1.0 - clampf(d_out / margin_m, 0.0, 1.0))
	p_ctx["profile"] = p_profile # a generator feathers its whole-grid output by the interior profile
	p_ctx["margin_mask"] = margin_mask # which cells are the band (a FILTER graph masks differently there)
	p_ctx["margin_feather"] = margin_feather # and the taper it uses there

	var vals := PackedFloat32Array()
	vals.resize(n)
	var in_vals := false
	var i := 0
	while i < p_steps.size():
		var step: Dictionary = p_steps[i]
		if step.get("capture", false):
			# Mirrors the native path exactly: the brush's own contribution in metres, at THIS step's
			# position, handed back before the step runs.
			if in_vals:
				for k in range(n):
					var cv: float = vals[k]
					p_amp[k] = NAN if not is_finite(cv) else (cv if add else cv - p_basey[k])
				in_vals = false
			var surf := PackedFloat32Array()
			surf.resize(n)
			for k in range(n):
				surf[k] = p_amp[k]
			var slot: Dictionary = step["out"]
			slot["surface"] = surf
			slot["gw"] = p_ctx["gw"]
			slot["gh"] = p_ctx["gh"]
			step["capture"] = false
			continue
		if not step["grid"]:
			# Fold the maximal RUN of cell nodes into one pass over the grid, which is what makes
			# the common stack cost exactly one cell loop.
			# The run stops in front of a CAPTURE as well as in front of a grid node. Without that the
			# capture of a step sitting mid-run is never examined at all: the fold jumps straight past it,
			# and the material it was meant to feed waits for a surface that is never taken.
			var j := i + 1
			while (j < p_steps.size() and not p_steps[j]["grid"]
					and not p_steps[j].get("capture", false)):
				j += 1
			if in_vals:
				for k in range(n):
					var v: float = vals[k]
					p_amp[k] = NAN if not is_finite(v) else (v if add else v - p_basey[k])
				in_vals = false
			_apply_point_run(p_steps.slice(i, j), p_amp, p_profile, p_ctx)
			i = j
			continue
		if not in_vals:
			for k in range(n):
				var a: float = p_amp[k]
				vals[k] = NAN if not is_finite(a) else (a if add else p_basey[k] + a)
			in_vals = true
		vals = _apply_field_step(step, vals, p_ctx)
		i += 1
	if not in_vals:
		for k in range(n):
			var a: float = p_amp[k]
			vals[k] = NAN if not is_finite(a) else (a if add else p_basey[k] + a)

	# The other half of the margin (see the note at the top). A margin cell the stack MOVED keeps its value
	# and composites through the brush's own blend — under the default MAX that means deposition raises the
	# skirt and cuts are ignored. A margin cell it did not move goes back to being a no-write, so an
	# untouched skirt zone leaves the surrounding terrain exactly as it was.
	if margin:
		for k in range(n):
			if margin_mask[k] == 0 or not is_finite(vals[k]):
				continue
			var moved: float = vals[k] if add else (vals[k] - p_basey[k])
			if absf(moved) <= MODIFIER_MARGIN_EPS:
				vals[k] = NAN
	return vals


## One run of point modifiers, evaluated cell by cell so each cell pays one pass over the run rather than
## the grid paying one pass per modifier.
func _apply_point_run(p_run: Array, p_amp: PackedFloat64Array, p_profile: PackedFloat64Array,
		p_ctx: Dictionary) -> void:
	var gw: int = p_ctx["gw"]
	var gh: int = p_ctx["gh"]
	var min_x: float = p_ctx["min_x"]
	var min_z: float = p_ctx["min_z"]
	var vs: float = p_ctx["vs"]
	for iz in range(gh):
		var z := min_z + iz * vs
		var row := iz * gw
		for ix in range(gw):
			var fi := row + ix
			if not is_finite(p_amp[fi]):
				continue
			var x := min_x + ix * vs
			var profile: float = p_profile[fi]
			var acc: float = p_amp[fi]
			for step in p_run:
				var m = step["mod"]
				if step["op"] == &"noise":
					acc += m.strength * m.noise.get_noise_2d(x, z) * profile
				elif step["op"] == &"relief":
					acc += (m.strength * _eval_relief_step(step, x, z, fi, p_ctx)
							* profile * m.material.strength)
			p_amp[fi] = acc


## One relief modifier's material evaluated at one cell, with the field context the host built.
func _eval_relief_step(p_step: Dictionary, p_x: float, p_z: float, p_fi: int, p_ctx: Dictionary) -> float:
	var m: Pasture3DNodeRelief = p_step["mod"]
	var dx: float = p_x - float(p_ctx["fit_cx"])
	var dz: float = p_z - float(p_ctx["fit_cz"])
	var lx: float = dx * float(p_ctx["fit_cos"]) + dz * float(p_ctx["fit_sin"])
	var lz: float = -dx * float(p_ctx["fit_sin"]) + dz * float(p_ctx["fit_cos"])
	var inv_ex: float = p_ctx["inv_ex"]
	var inv_ez: float = p_ctx["inv_ez"]
	var f: Array = p_ctx["fields"]
	var s: Array = p_ctx["sim_fields"]
	var h: Array = p_ctx["host_fields"]
	var use_fields := not f.is_empty()
	var use_host := not h.is_empty()
	var f_alt := 0.0
	var f_slope := 0.0
	var f_curv := 0.0
	var f_gx := 0.0
	var f_gz := 0.0
	var f_flow := 0.0
	var f_ero := 0.0
	var f_dep := 0.0
	var f_wet := 0.0
	if use_fields:
		f_alt = f[0][p_fi]
		f_slope = f[1][p_fi]
		f_curv = f[2][p_fi]
		f_gx = f[3][p_fi]
		f_gz = f[4][p_fi]
		if not s.is_empty():
			f_flow = s[0][p_fi]
			f_ero = s[1][p_fi]
			f_dep = s[2][p_fi]
			f_wet = s[3][p_fi]
	var h_alt := 0.0
	var h_slope := 0.0
	var h_curv := 0.0
	var h_norm := 0.0
	if use_host:
		h_alt = h[0][p_fi]
		h_slope = h[1][p_fi]
		h_curv = h[2][p_fi]
		h_norm = h_alt / float(p_ctx["host_div"])
	# The measured grids are keyed by STACK-WIDE selector id; the material's own eval numbers its
	# selectors from 0, so hand it its own slice.
	var lo: int = p_step["sel_base"]
	var hi: int = lo + int(p_step["sel_count"])
	var measured: Array = p_ctx["measured"]
	var host_measured: Array = p_ctx["host_measured"]
	return m.material.eval(p_x, p_z, lx * inv_ex, lz * inv_ez, inv_ex, inv_ez,
			f_alt, f_slope, f_curv, f_gx, f_gz, f_flow, f_ero, f_dep, f_wet,
			measured.slice(lo, hi) if not measured.is_empty() else [],
			p_fi if (use_fields or use_host) else -1,
			h_alt, h_slope, h_curv, h_norm, use_host,
			host_measured.slice(lo, hi) if not host_measured.is_empty() else [])


## One grid node over the whole grid.
func _apply_field_step(p_step: Dictionary, p_vals: PackedFloat32Array,
		p_ctx: Dictionary) -> PackedFloat32Array:
	if p_step["op"] == &"smooth":
		return _blur_grid(p_vals, p_ctx["gw"], p_ctx["gh"], p_step["mod"].passes)
	if p_step["op"] == &"erosion":
		return _apply_erosion_step(p_step, p_vals, p_ctx)
	if p_step["op"] == &"graph":
		return _apply_graph_step(p_step, p_vals, p_ctx)
	if p_step["op"] == &"road":
		return _apply_road_step(p_step, p_vals, p_ctx)
	return p_vals


## One Pasture3DNodeRoad over the whole grid: solve the run's vertical alignment, then grade the working
## surface into the corridor around it.
##
## Like the erosion and graph steps this reads and writes an ABSOLUTE surface, so the working grid's
## delta is lifted before the grader sees it and dropped back after — the grader's whole job is stated in
## world heights (the road is at 412 m here), and a delta has no answer to that question.
##
## NaN passthrough is the grader's own contract rather than something applied here: cells outside the
## brush loop stay NaN through the kernel, so the road never invents ground the brush does not own.
func _apply_road_step(p_step: Dictionary, p_vals: PackedFloat32Array,
		p_ctx: Dictionary) -> PackedFloat32Array:
	var m: Pasture3DNodeRoad = p_step["mod"]
	if not (self is Pasture3DRoadBrush):
		return p_vals # warned about in modifier_warnings; silently doing nothing here would be worse
	var gw: int = p_ctx["gw"]
	var gh: int = p_ctx["gh"]
	var n := gw * gh
	var vs: float = p_ctx["vs"]
	var add: bool = p_ctx["add"]
	var basey: PackedFloat32Array = p_ctx["basey"]

	var z := PackedFloat32Array()
	z.resize(n)
	for i in range(n):
		var v: float = p_vals[i]
		z[i] = (basey[i] + v) if add else v

	var res: Dictionary = (self as Pasture3DRoadBrush).grade_surface(m, z, gw, gh,
			float(p_ctx["min_x"]), float(p_ctx["min_z"]), vs)
	if res.is_empty():
		return p_vals
	var graded: PackedFloat32Array = res["height"]

	var out := PackedFloat32Array()
	out.resize(n)
	for i in range(n):
		var g: float = graded[i]
		if not is_finite(g):
			out[i] = p_vals[i]
			continue
		out[i] = (g - basey[i]) if add else g
	return out


## One Pasture3DNodeGraph over the whole grid, as a FILTER (input → output paradigm): feed the graph the
## working surface entering this step (an Input node reads it), evaluate at THIS brush's exact per-cell
## world coords, and composite the graph's output back over the surface — feathered by the interior profile
## so the rim stays clean, scaled by Strength as an amount (0 = no change, 1 = full effect at the centre).
## A pure generator (no Input node) still runs: its output simply does not depend on the surface, so the
## graph replaces toward it. To ADD relief on top of the brush, wire Input → Blend(ADD) ← Noise → Output.
##
## Like the erosion step, the graph reads and writes an ABSOLUTE surface, so the working grid's delta (under
## ADD) is lifted to absolute before the graph sees it and dropped back after. The world mapping must match
## the cell loop's (`min_x + ix*vs`), NOT the graph's own cell-centre helper, or a graph baked through a
## brush would land half a cell off the terrain it sits on; a half-cell-shifted rect makes
## Pasture3DTerrainGraph.cell_to_world reproduce `min_x + ix*vs` exactly.
func _apply_graph_step(p_step: Dictionary, p_vals: PackedFloat32Array,
		p_ctx: Dictionary) -> PackedFloat32Array:
	var m: Pasture3DNodeGraph = p_step["mod"]
	var g: Pasture3DTerrainGraph = m.graph
	if g == null:
		return p_vals
	# A Road Source names a road and a Shape Source names a brush; the HOST resolves both, because a graph
	# is a Resource and cannot reach the scene. Done HERE rather than inside `evaluate` so the deferred
	# worker path gets a resolved graph too: that solve runs off the main thread and must not be walking
	# the scene tree looking for brushes while it does.
	#
	# Through Pasture3DGraphSources rather than calling the two resolvers directly, so that this site, the
	# preview and the inspector cannot end up resolving different sets — which would show as a graph that
	# previews correctly and bakes empty.
	Pasture3DGraphSources.resolve(g, self)
	var gw: int = p_ctx["gw"]
	var gh: int = p_ctx["gh"]
	var n := gw * gh
	var vs: float = p_ctx["vs"]
	var min_x: float = p_ctx["min_x"]
	var min_z: float = p_ctx["min_z"]
	var profile: PackedFloat64Array = p_ctx["profile"]
	var add: bool = p_ctx["add"]
	var basey: PackedFloat32Array = p_ctx["basey"]
	var amount := clampf(m.strength, 0.0, 1.0)

	# The absolute surface the graph reads and writes (§6.8, as the erosion step): the working grid holds a
	# delta under ADD. NaN outside the loop stays NaN — an Input node's Smooth is NaN-aware and every write
	# back below skips those cells. (A Modifier Margin has already turned the margin band into ordinary
	# finite ground before this step runs — see `_run_modifier_stack` — so there is nothing to do here.)
	var z := PackedFloat32Array()
	z.resize(n)
	for i in range(n):
		var v: float = p_vals[i]
		z[i] = (basey[i] + v) if add else v

	var rect := Rect2(min_x - 0.5 * vs, min_z - 0.5 * vs, float(gw) * vs, float(gh) * vs)
	m.last_input_surface = z.duplicate()
	m.last_rect = rect
	m.last_gw = gw
	m.last_gh = gh
	# A FILTER graph (an Input node feeds the output) depends on the surface, so the cache must key on it —
	# a drag changes the surface and the entry goes stale, exactly as the erosion cache does. A pure
	# generator is world-fixed, so its key is just the content revision and the cache serves across drags.
	var reads: bool = g.reads_input()

	# ---- HYBRID FEATHERING WITH MODIFIER MARGIN INTEGRATION ----
	# feather_mode on Pasture3DNodeGraph determines how the graph blends near the boundary:
	#   USE_BRUSH_MASK (default): feathers over the host brush's falloff_width and falloff_curve.
	#   CUSTOM: feathers over m.custom_falloff_width and m.custom_falloff_curve.
	#   OFF: applies at 100% across the whole loop interior (tapering only across modifier margin).
	var fmode: int = m.feather_mode if "feather_mode" in m else 0
	var custom_fw: float = maxf(m.custom_falloff_width, 0.001) if "custom_falloff_width" in m else 15.0
	var custom_curve: Curve = m.custom_falloff_curve if "custom_falloff_curve" in m else null
	var host_fw: Variant = p_ctx.get("falloff_width", get("falloff_width"))
	var brush_fw: float = maxf(float(host_fw if host_fw != null else 10.0), 0.001)
	var brush_curve: Curve = p_ctx.get("falloff_curve", get("falloff_curve")) as Curve
	var sdf: PackedFloat32Array = p_ctx.get("sdf", PackedFloat32Array())
	var edge_off: float = p_ctx.get("edge_offset", 0.0)
	var have_sdf := sdf.size() == n
	var mm: PackedByteArray = p_ctx.get("margin_mask", PackedByteArray())
	var mf: PackedFloat64Array = p_ctx.get("margin_feather", PackedFloat64Array())
	var have_mm := mm.size() == n and mf.size() == n

	var mask := PackedFloat64Array()
	mask.resize(n)
	for k in range(n):
		if have_mm and mm[k] == 1:
			mask[k] = mf[k]
			continue
		if have_sdf:
			var signed_d: float = sdf[k] + edge_off
			if signed_d <= 0.0:
				mask[k] = 0.0
			elif fmode == 2: # OFF
				mask[k] = 1.0
			elif fmode == 1: # CUSTOM
				var u := clampf(signed_d / custom_fw, 0.0, 1.0)
				mask[k] = _ramp(custom_curve, u)
			else: # USE_BRUSH_MASK
				var u := clampf(signed_d / brush_fw, 0.0, 1.0)
				mask[k] = _ramp(brush_curve, u)
		else:
			mask[k] = profile[k] if profile.size() == n else 1.0

	# ---- FROZEN cache (mirrors _apply_erosion_step §6.3) ----
	#
	# The cache holds the graph's ABSOLUTE output, keyed by extent. A MISS evaluates; a cached extent is
	# SERVED, and served ANYWAY when its key no longer matches (reported stale) rather than cleared mid-edit.
	# The output is composited per bake below, so Strength and the profile — which move with the footprint —
	# reuse a cached evaluation for free.
	var out_slot: Dictionary = p_step.get("out", {})
	var frozen: bool = m.evaluation == Pasture3DNode.Evaluation.FROZEN
	var extent: String = p_ctx.get("extent", "")
	var key: int = hash([g.content_key(), z]) if reads else g.content_key()
	var entry: Dictionary = m.cache_for(extent) if frozen and extent != "" else {}
	var zo: PackedFloat32Array = entry.get("grid", PackedFloat32Array())
	if zo.size() == n:
		_composite_graph(p_vals, z, zo, mask, amount, basey, add, n)
		out_slot["stale"] = int(entry.get("key", 0)) != key
		out_slot["served"] = true
		return p_vals

	# Deferred driver pass 1: queue the solve for worker thread and return current surface
	if (bool(p_step.get("defer", false)) or _graph_defer) and frozen:
		out_slot["pending"] = z.duplicate()
		out_slot["pending_key"] = key
		out_slot["pending_gw"] = gw
		out_slot["pending_gh"] = gh
		out_slot["pending_rect"] = rect
		out_slot["stale"] = false
		out_slot["served"] = true
		_pending_graph.append({
			"mod": m,
			"graph": g,
			"gw": gw,
			"gh": gh,
			"rect": rect,
			"z": z.duplicate(),
			"key": key,
			"extent": extent,
			"done": 0,
		})
		return p_vals

	# MISS: evaluate, handing the graph the absolute surface for its Input node.
	zo = g.evaluate(gw, gh, rect, null, z)
	_composite_graph(p_vals, z, zo, mask, amount, basey, add, n)
	if p_step.has("out"):
		out_slot["key"] = key
		out_slot["grid"] = zo
		out_slot["stale"] = false
		out_slot["served"] = false
	return p_vals


## Composite the graph's absolute output `p_zo` over the absolute input surface `p_z`, masked by `p_mask`
## and scaled by `p_amount` (0 = no change, 1 = full effect where the mask is 1), then
## write it back into the working grid in that grid's own units (a delta under ADD). Cells the brush does
## not contribute to (NaN) pass through untouched. `p_zo == p_z` (a bare Input → Output) is the identity.
func _composite_graph(p_vals: PackedFloat32Array, p_z: PackedFloat32Array, p_zo: PackedFloat32Array,
		p_mask: PackedFloat64Array, p_amount: float, p_basey: PackedFloat32Array,
		p_add: bool, p_n: int) -> void:
	for k in range(p_n):
		var v: float = p_vals[k]
		if not is_finite(v):
			continue
		var t: float = p_amount * p_mask[k]
		var abs_out: float = p_z[k] + (p_zo[k] - p_z[k]) * t
		p_vals[k] = (abs_out - p_basey[k]) if p_add else abs_out


## The erosion FIELD step: solve over the brush's own surface, and optionally publish the four channels
## the modifiers after it can gate on.
##
## The GDScript oracle and the native rasteriser call the SAME `erosion_solve` — GDScript through the
## `erode_heightfield` binding, C++ directly — so there is no second implementation of the solver to keep
## in step, and the A/B question here is only about the grids handed to it.
func _apply_erosion_step(p_step: Dictionary, p_vals: PackedFloat32Array,
		p_ctx: Dictionary) -> PackedFloat32Array:
	var m: Pasture3DNodeErosion = p_step["mod"]
	var gw: int = p_ctx["gw"]
	var gh: int = p_ctx["gh"]
	var n := gw * gh
	var add: bool = p_ctx["add"]
	var basey: PackedFloat32Array = p_ctx["basey"]

	# §6.8 fact 1: the solver needs an ABSOLUTE surface and the working grid holds a delta under ADD.
	# §6.8 fact 2: NaN outside the loop passes straight through and becomes the boundary condition —
	# `erosion_solve` turns non-finite input into a fixed outlet at the field minimum, which for a mound
	# is exactly right: the ground off the loop is where the mountain's water goes.
	#
	# A Modifier Margin does not appear here. It is applied ONCE at the stack boundary
	# (`_run_modifier_stack`), so by the time this step runs the margin band is already ordinary finite
	# ground in `p_vals` and this code cannot tell the difference. See `modifier_margin`.
	var z := PackedFloat32Array()
	z.resize(n)
	for i in range(n):
		var v: float = p_vals[i]
		z[i] = (basey[i] + v) if add else v

	# ---- FROZEN (§6.3), the same three-way split the rasteriser makes ----
	#
	# A MISSING cache solves (reopening a scene must not lose the erosion), a MATCHING one is served, and
	# a cache for a DIFFERENT surface is served AND reported stale — clearing on edit would throw away a
	# multi-second solve at the moment you were mid-comparison.
	#
	# The key is `hash()` of the exact surface handed to the solver, folded with the settings that
	# surface does not capture. Hashing the input rather than enumerating what fed it makes staleness
	# detection complete: the spline, the shape properties and every modifier above are all in there.
	# It deliberately does NOT match the native path's key — each path only compares keys it wrote
	# itself, and switching rasterisers costs one extra solve.
	var out: Dictionary = p_step.get("out", {})
	var frozen: bool = m.evaluation == Pasture3DNode.Evaluation.FROZEN
	var extent: String = p_ctx.get("extent", "")
	var key := hash([z, m.iterations, m.erosion_rate, m.area_exponent, m.hillslope_diffusion,
			m.deposition, m.erodability_range, m.publish_fields])
	var entry: Dictionary = m.cache_for(extent) if frozen and extent != "" else {}
	var cached: PackedFloat32Array = entry.get("grid", PackedFloat32Array())
	# A cached surface is not enough on its own: if a modifier BELOW this one now reads the published
	# channels and the entry does not carry them, the cache is unusable however well its key matches.
	# Adding a flow-gated modifier does not change the surface handed to the solver, so the key WOULD
	# still match and the new modifier would quietly read zeros.
	var want_channels: bool = m.publish_fields and not (p_ctx["fields"] as Array).is_empty()
	if want_channels and (entry.get("flow", PackedFloat32Array()) as PackedFloat32Array).size() != n:
		cached = PackedFloat32Array()
	if cached.size() == n:
		if m.publish_fields and entry.has("flow"):
			p_ctx["sim_fields"] = [entry["flow"], entry["ero"], entry["dep"], entry["wet"]]
		for i in range(n):
			if not is_finite(p_vals[i]):
				continue
			p_vals[i] = (cached[i] - basey[i]) if add else cached[i]
		out["stale"] = int(entry.get("key", 0)) != key
		out["served"] = true
		return p_vals

	# §14 pass 1: hand the surface out and leave the grid un-eroded. `out` is non-empty exactly when the
	# step is frozen and someone is listening, which is the same condition `defer` was compiled under.
	if bool(p_step.get("defer", false)) and p_step.has("out"):
		out["pending"] = z
		out["pending_key"] = key
		out["pending_gw"] = gw
		out["pending_gh"] = gh
		return p_vals

	var params: Dictionary = m.to_params()
	params["gw"] = gw
	params["gh"] = gh
	params["cell_size"] = p_ctx["vs"]
	params["time_step"] = 1.0
	# The four channels come out of the solver's diagnostics, so they cost nothing unless asked for.
	params["want_diagnostics"] = m.publish_fields
	var res: Dictionary = terrain.data.erode_heightfield(z, params,
			params.get("erodability_lut", PackedFloat32Array()))
	if not bool(res.get("ok", false)):
		push_warning(("%s '%s': the erosion solver rejected the %dx%d grid, so this modifier did "
			+ "nothing. Nothing was silently eroded.") % [get_class(), name, gw, gh])
		return p_vals
	var zo: PackedFloat32Array = res["z"]

	if m.publish_fields:
		_publish_erosion_fields(z, zo, res, p_ctx)

	# Write back only where the brush actually contributes. Every no-data cell came back as a real
	# number (the outlet level), and copying those in would paint the brush's footprint over the whole
	# bounding box.
	for i in range(n):
		if not is_finite(p_vals[i]):
			continue
		p_vals[i] = (zo[i] - basey[i]) if add else zo[i]

	# `p_step.has("out")`, NOT `out.is_empty()`. The slot arrives EMPTY — filling it is what this block is
	# for — so emptiness says nothing about whether anyone is listening. Asking the wrong one meant that
	# on a cache MISS the solve was never handed back, and so the oracle's frozen cache never filled at
	# all: a FROZEN modifier on `force_gdscript_raster` re-solved every bake and never raised a stale
	# warning. The native side has said this in a comment since it was written; only this copy asked the
	# other question.
	if p_step.has("out"):
		out["key"] = key
		out["grid"] = zo
		out["stale"] = false
		out["served"] = false
		var pub: Array = p_ctx["sim_fields"]
		if m.publish_fields and pub.size() == 4:
			out["flow"] = pub[0]
			out["ero"] = pub[1]
			out["dep"] = pub[2]
			out["wet"] = pub[3]
	return p_vals


## Put this solve's flow / erosion / deposition / wetness into the stack's field context, in the units
## and signs a Pasture3DTerrainMask expects — the same conversions `relief_fields_add_sim` makes on
## the way out of a Pasture3DSimResult, so a FLOW band means here exactly what it means there.
##
## POSITIONAL BY CONSTRUCTION (§6.4): this runs at the erosion modifier's own place in the list, so a
## modifier ABOVE it has already been evaluated against the defined zero and a modifier below it reads
## the real numbers. Nothing has to enforce the invariant because nothing can violate it.
func _publish_erosion_fields(p_before: PackedFloat32Array, p_after: PackedFloat32Array,
		p_res: Dictionary, p_ctx: Dictionary) -> void:
	var n := p_after.size()
	var flow: PackedFloat32Array = p_res.get("flow", PackedFloat32Array())
	var wet: PackedFloat32Array = p_res.get("lake_depth", PackedFloat32Array())
	if flow.size() != n or wet.size() != n:
		return # want_diagnostics was off, or the solver returned a short grid: publish nothing
	var ero := PackedFloat32Array()
	var dep := PackedFloat32Array()
	ero.resize(n)
	dep.resize(n)
	for i in range(n):
		# Erosion is reported POSITIVE metres removed and deposition positive metres gained, which is
		# what a band reads as "5 to 50 m stripped" rather than "-50 to -5".
		var d: float = p_after[i] - p_before[i]
		if not is_finite(d):
			d = 0.0
		ero[i] = maxf(-d, 0.0)
		dep[i] = maxf(d, 0.0)
	p_ctx["sim_fields"] = [flow, ero, dep, wet]


## Shortest repeat distance, in metres, over the ops that have one (DUNES wavelength, FURROWS spacing —
## both in param slot 1). 0 when the material has no periodic op. Fractal ops are excluded on purpose:
## their high octaves are *meant* to fall below the vertex spacing and simply stop contributing, whereas a
## periodic op set too fine produces nothing at all and reads as "the material is broken".
func _relief_finest_period(mat: Pasture3DReliefMaterial) -> float:
	if mat == null:
		return 0.0
	var prog: Array = mat.compile()
	var ops: PackedInt32Array = prog[0]
	var params: PackedFloat32Array = prog[1]
	var finest := 0.0
	for i in range(ops.size() / Pasture3DReliefMaterial.OP_STRIDE):
		var op := ops[i * Pasture3DReliefMaterial.OP_STRIDE]
		if op != Pasture3DReliefMaterial.Op.DUNES and op != Pasture3DReliefMaterial.Op.FURROWS:
			continue
		var period := params[i * Pasture3DReliefMaterial.PARAM_STRIDE + 1]
		if period > 0.0 and (finest <= 0.0 or period < finest):
			finest = period
	return finest


## The one Pasture3DSimResult this material's selectors read, or null. §9 puts the reference on the
## SELECTOR, not on the brush, so it is resolved from the compiled material tree. A bake takes ONE result;
## the first wins and the host warns by name (see _relief_sim_warnings).
func _relief_sim_result(mat: Pasture3DReliefMaterial) -> Pasture3DSimResult:
	if mat == null:
		return null
	for r in mat.sim_results():
		if r != null:
			return r
	return null


## True when every one of this brush's splines sits inside the result's extent. Drives the "the relief
## will stop at the edge of what was simulated" warning; XZ only, like every other footprint test here.
func _sim_result_covers_splines(r: Pasture3DSimResult) -> bool:
	if r == null or not r.is_valid() or not is_inside_tree():
		return true # nothing to say; the other warnings cover these cases
	var b := r.world_bounds()
	for s in _get_splines():
		var a := _spline_footprint_aabb(s)
		if a.size == Vector3.ZERO:
			continue
		if (a.position.x < b[0] or a.position.z < b[2]
				or a.position.x + a.size.x > b[1] or a.position.z + a.size.z > b[3]):
			return false
	return true


## The shared half of a relief host's configuration warnings: the material's own complaint, the sim-result
## diagnostics, and the periodic-resolution guard. Hosts append whatever their own mapping surface needs.
##
## Silent garbage from a missing sim result would be very hard to diagnose, so an unassigned or unbuilt
## result is said out loud rather than gating to 0 quietly — "the material stamped nothing" and "the mask
## is missing" look identical on the terrain and have completely different fixes.
func _relief_warnings(mat: Pasture3DReliefMaterial) -> PackedStringArray:
	var warnings := PackedStringArray()
	if mat == null:
		return warnings
	var w := mat._configuration_warning()
	if not w.is_empty():
		warnings.append(w)
	# Host Profile on a host that has none. Said out loud for the same reason the missing sim result is:
	# the field reads a defined 0, which produces relief that is uniformly gated out or a single unbroken
	# band, and "gated to nothing" is indistinguishable from "material is broken" by looking at it.
	if mat.wants_host_profile() and not _offers_host_profile():
		warnings.append(("A relief selector or Band Source reads the Host Profile, but a %s has no "
			+ "generated profile of its own — its shape IS its output. That field reads zero everywhere, "
			+ "so the gate excludes everything (or the bands collapse onto one). Use Below Layer here, or "
			+ "move the material to a Pasture3DMound.") % get_class())
	if mat.wants_sim_result():
		var distinct: Array = []
		for r in mat.sim_results():
			if r != null and not distinct.has(r):
				distinct.append(r)
		if distinct.is_empty():
			warnings.append(("A relief selector reads the erosion sim (Flow / Erosion / Deposition / "
				+ "Wetness) but no Sim Result is assigned to it, so it gates to zero everywhere. Point "
				+ "the selector at the Sim Result of the Pasture3DSim that eroded this ground."))
		else:
			var first: Pasture3DSimResult = distinct[0]
			if not first.is_valid():
				warnings.append(("The Sim Result a relief selector reads is empty — the Sim has not been "
					+ "run, or its simulation was cleared. Press Simulate on it."))
			elif not _sim_result_covers_splines(first):
				warnings.append(("The Sim Result a relief selector reads does not cover this brush's whole "
					+ "area. Outside it the gate reads zero, so the relief will stop at the edge of what "
					+ "was simulated."))
			if distinct.size() > 1:
				warnings.append(("This material's selectors read %d different Sim Results; only the first "
					+ "is used, so the others gate on the wrong sim's channels. Give the layers one Sim "
					+ "Result, or split them across brushes.") % distinct.size())
	# §21.5: an inverted band gates NOTHING through, on every Kind, and nothing about that is visible —
	# the evaluator's min(rise, fall) is 0 everywhere and the material simply never appears. Said out loud
	# for the same reason the Sim says it about River Width Min.
	var inverted := 0
	for s in mat.selectors():
		if s != null and s.is_inverted_band():
			inverted += 1
	if inverted > 0:
		warnings.append(("%d relief selector(s) have Range Min above Range Max, so the band is inverted and "
			+ "passes nothing anywhere — the material will not appear at all. Swap the two values.")
			% inverted)
	var finest := _relief_finest_period(mat)
	if finest > 0.0 and is_instance_valid(terrain):
		var limit := terrain.vertex_spacing * PERIOD_SAMPLES_MIN
		if finest < limit:
			warnings.append(("This Relief Material has a repeating feature every %.1f m, but the terrain "
				+ "samples height every %.1f m — under about %.1f m a cycle has too few vertices to "
				+ "survive meshing and will barely show. Increase the spacing / wavelength, or lower the "
				+ "terrain's Vertex Spacing.") % [finest, terrain.vertex_spacing, limit])
	return warnings


## Flatten a Pasture3DSimResult to the dictionary the native rasterisers take. C++ cannot see the GDScript
## class, and the extent has to travel with the data because the result is at SIM resolution over the
## SIMULATED area and shares no grid with the bake. Empty when there is nothing valid to send.
func _sim_result_dict(r: Pasture3DSimResult) -> Dictionary:
	if r == null or not r.is_valid():
		return {}
	return {"min_x": r.min_x, "min_z": r.min_z, "cell_size": r.cell_size,
			"width": r.width, "height": r.height, "flow": r.flow, "erosion": r.erosion,
			"deposition": r.deposition, "wetness": r.wetness}


## The sim channels resampled onto the bake grid, in the units a selector band is written in.
## Returns [flow_m2, erosion_m, deposition_m, wetness_m], each gw*gh. MUST agree with
## relief_fields_add_sim in C++ — the parity gate compares the two paths' finished height.
##
## Outside the result's extent every channel is its defined 0 (§9): nothing is invented, and nothing is
## smeared outwards from the edge. Note flow's 0 is 0 m² here rather than the resource's 1 m² floor;
## no band an artist would write distinguishes the two, and 0 is the honest "no data" value.
func _sim_fields(r: Pasture3DSimResult, min_x: float, min_z: float, vs: float, gw: int, gh: int) -> Array:
	var n := gw * gh
	var flow := PackedFloat32Array()
	var ero := PackedFloat32Array()
	var dep := PackedFloat32Array()
	var wet := PackedFloat32Array()
	flow.resize(n)
	ero.resize(n)
	dep.resize(n)
	wet.resize(n)
	if r == null or not r.is_valid():
		return [flow, ero, dep, wet]
	for iz in range(gh):
		var row := iz * gw
		var z := min_z + iz * vs
		for ix in range(gw):
			var p := Vector3(min_x + ix * vs, 0.0, z)
			if not r.covers(p):
				continue
			# The two unit conversions: exp() the log-scaled flow, and flip erosion to a positive depth.
			flow[row + ix] = exp(r.sample(Pasture3DSimResult.Channel.FLOW, p))
			ero[row + ix] = maxf(-r.sample(Pasture3DSimResult.Channel.EROSION, p), 0.0)
			dep[row + ix] = maxf(r.sample(Pasture3DSimResult.Channel.DEPOSITION, p), 0.0)
			wet[row + ix] = maxf(r.sample(Pasture3DSimResult.Channel.WETNESS, p), 0.0)
	return [flow, ero, dep, wet]


## Per-cell description of the ground BELOW this brush's layer, over the bake grid: height, steepness in
## degrees, curvature (METRES this cell sits below the ring of its four neighbours — positive is a hollow,
## negative a ridge, §21.6) and the height gradient. Returns [alt, slope_deg, curv, gx, gz], each gw*gh.
##
## The source is `composite_height_below`, NOT the finished terrain: reading the final composite would
## feed this brush's own relief into its own mask and drift on every re-bake. Where no lower layer covers
## a cell, that grid holds NaN and we fall back to the live height, which is what the rasterisers already
## do for base_y. Derivatives use central differences with clamped edges.
func _terrain_fields(min_x: float, min_z: float, vs: float, gw: int, gh: int) -> Array:
	var n := gw * gh
	var alt := PackedFloat32Array()
	alt.resize(n)
	var below := _base_below_grid(min_x, min_z, vs, gw, gh)
	var has_below := below.size() == n
	for iz in range(gh):
		var row := iz * gw
		for ix in range(gw):
			var h: float = below[row + ix] if has_below else NAN
			if not is_finite(h):
				h = terrain.data.get_height(Vector3(min_x + ix * vs, 0.0, min_z + iz * vs))
			alt[row + ix] = h if is_finite(h) else 0.0
	return _derive_fields(alt, vs, gw, gh)


## Slope / curvature / gradients from ANY altitude grid, in that grid's own units. Split out of
## _terrain_fields so the host-profile set (_host_profile_fields) is derived by the same arithmetic as the
## below-layer one — two copies of this would be a silent way for the two field sets to stop being
## comparable, and a selector's whole job is to compare them.
##
## Mirrors relief_fields_build in C++, which is the path an actual bake takes; this one is the oracle.
func _derive_fields(alt: PackedFloat32Array, vs: float, gw: int, gh: int) -> Array:
	var n := gw * gh
	var slope := PackedFloat32Array()
	slope.resize(n)
	var curv := PackedFloat32Array()
	curv.resize(n)
	var gxs := PackedFloat32Array()
	gxs.resize(n)
	var gzs := PackedFloat32Array()
	gzs.resize(n)
	var inv2 := 1.0 / (2.0 * vs)
	for iz in range(gh):
		var row := iz * gw
		var zm := maxi(iz - 1, 0) * gw
		var zp := mini(iz + 1, gh - 1) * gw
		for ix in range(gw):
			var xm := maxi(ix - 1, 0)
			var xp := mini(ix + 1, gw - 1)
			var c := alt[row + ix]
			var gx := (alt[row + xp] - alt[row + xm]) * inv2
			var gz := (alt[zp + ix] - alt[zm + ix]) * inv2
			gxs[row + ix] = gx
			gzs[row + ix] = gz
			slope[row + ix] = rad_to_deg(atan(sqrt(gx * gx + gz * gz)))
			# §21.6: METRES of deviation — the one-cell ring's mean height minus this cell's. The old form
			# divided by vs² instead of 4, so the same hollow read 16x smaller on a 4x coarser grid.
			curv[row + ix] = (alt[row + xp] + alt[row + xm] + alt[zp + ix] + alt[zm + ix]
					- 4.0 * c) * 0.25
	return [alt, slope, curv, gxs, gzs]


## The wider slope / curvature grids a selector's `measure_radius` asks for (§21.6), one entry per SELECTOR
## id: `[]` for a selector that left the radius at 0 — which reads the one-cell fields above, bit for bit
## what it read before this phase — and `[slope_grid, curv_grid]` otherwise. Selectors sharing a radius
## share one pair of grids, so N slope bands over 20 m cost one build.
##
## MUST agree with relief_fields_add_measured in C++, which is the path an actual bake takes; this one is
## the oracle. `alt` is _terrain_fields' first return, so the two measurements are of the same ground.
func _measured_fields(alt: PackedFloat32Array, curv_base: PackedFloat32Array,
		op_selectors: PackedFloat32Array, vs: float, gw: int, gh: int,
		field_source: int = Pasture3DTerrainMask.FieldSource.BELOW_LAYER) -> Array:
	var stride := Pasture3DReliefMaterial.SELECTOR_STRIDE
	var n_sel := op_selectors.size() / stride
	var out: Array = []
	out.resize(n_sel)
	out.fill([])
	if n_sel < 1:
		return out
	var by_radius := {}
	for s in range(n_sel):
		var b := s * stride
		var r := op_selectors[b + Pasture3DReliefMaterial.SELECTOR_RADIUS]
		if not (r > 0.0):
			continue # 0 = one cell = the base fields; NaN lands here too
		# This radius belongs to the OTHER field set — a host-source selector must not make the
		# below-layer set build a pair it will never read, and vice versa.
		if int(op_selectors[b + Pasture3DReliefMaterial.SELECTOR_FIELD_SOURCE]) != field_source:
			continue
		if not by_radius.has(r):
			by_radius[r] = _measure_at(alt, curv_base, r, vs, gw, gh)
		out[s] = by_radius[r]
	return out


## One [slope_grid, curv_grid] pair measured over `r` metres. Slope is the same central difference the
## one-cell field takes, over ±R cells instead of ±1; curvature is the mean of the ring of cells at radius
## r, minus the centre. Both clamp at the grid edge, as every derivative here does.
func _measure_at(alt: PackedFloat32Array, curv_base: PackedFloat32Array, r: float,
		vs: float, gw: int, gh: int) -> Array:
	var n := gw * gh
	var slope := PackedFloat32Array()
	slope.resize(n)
	var curv := PackedFloat32Array()
	curv.resize(n)
	var rc := maxi(1, int(round(r / vs)))
	var inv2 := 1.0 / (2.0 * float(rc) * vs)
	# The ring, built once. At r = vs it is the 4 axial and 4 diagonal neighbours — close to, and
	# deliberately not identical to, the one-cell field: `measure_radius = 0` is the preserved path.
	var rr := maxi(1, int(ceil(r / vs)))
	var ring_dx := PackedInt32Array()
	var ring_dz := PackedInt32Array()
	for dz in range(-rr, rr + 1):
		for dx in range(-rr, rr + 1):
			if absf(sqrt(float(dx * dx + dz * dz)) * vs - r) <= vs * 0.5:
				ring_dx.append(dx)
				ring_dz.append(dz)
	var inv_ring := 0.0 if ring_dx.is_empty() else 1.0 / float(ring_dx.size())
	for iz in range(gh):
		var row := iz * gw
		var zm := maxi(iz - rc, 0) * gw
		var zp := mini(iz + rc, gh - 1) * gw
		for ix in range(gw):
			var xm := maxi(ix - rc, 0)
			var xp := mini(ix + rc, gw - 1)
			var gx := (alt[row + xp] - alt[row + xm]) * inv2
			var gz := (alt[zp + ix] - alt[zm + ix]) * inv2
			slope[row + ix] = rad_to_deg(atan(sqrt(gx * gx + gz * gz)))
			if ring_dx.is_empty():
				# A radius under half a cell has no ring; the one-cell field IS the answer there.
				curv[row + ix] = curv_base[row + ix]
				continue
			var acc := 0.0
			for i in range(ring_dx.size()):
				var sx := clampi(ix + ring_dx[i], 0, gw - 1)
				var sz := clampi(iz + ring_dz[i], 0, gh - 1)
				acc += alt[sz * gw + sx]
			curv[row + ix] = acc * inv_ring - alt[row + ix]
	return [slope, curv]


## Oriented frame of the loop: [cx, cz, cos, sin, ex, ez] — centre, the unit X axis of the minimum-area
## enclosing rectangle, and its half-extents. FIT maps the source onto this rect, so the relief follows
## the loop's rotation instead of the world axes; every mode uses it for the normalised nu,nv that radial
## ops read. Computed once per bake from the already-decimated polygon (the hull of a decimated loop is
## small, so the O(h²) rotating-callipers sweep is cheap). Degenerate loops fall back to axis-aligned bounds.
func _loop_frame(poly: PackedVector2Array) -> Array:
	var hull := Geometry2D.convex_hull(poly)
	# convex_hull repeats the first point as the last; drop it so edges aren't double-counted.
	if hull.size() > 1 and hull[0].is_equal_approx(hull[hull.size() - 1]):
		hull.remove_at(hull.size() - 1)
	if hull.size() >= 3:
		var best_area := INF
		var best: Array = []
		for i in range(hull.size()):
			var e: Vector2 = hull[(i + 1) % hull.size()] - hull[i]
			var elen := e.length()
			if elen < 0.000001:
				continue
			var ux := e / elen
			var uy := Vector2(-ux.y, ux.x)
			var min_u := INF
			var max_u := -INF
			var min_v := INF
			var max_v := -INF
			for p in hull:
				var du := p.dot(ux)
				var dv := p.dot(uy)
				min_u = minf(min_u, du)
				max_u = maxf(max_u, du)
				min_v = minf(min_v, dv)
				max_v = maxf(max_v, dv)
			var area := (max_u - min_u) * (max_v - min_v)
			if area < best_area:
				best_area = area
				var centre: Vector2 = ux * ((min_u + max_u) * 0.5) + uy * ((min_v + max_v) * 0.5)
				best = [centre.x, centre.y, ux.x, ux.y, (max_u - min_u) * 0.5, (max_v - min_v) * 0.5]
		if not best.is_empty() and best[4] > 0.001 and best[5] > 0.001:
			return best
	# Fallback: axis-aligned bounds of the polygon.
	var mn := poly[0]
	var mx := poly[0]
	for p in poly:
		mn.x = minf(mn.x, p.x)
		mn.y = minf(mn.y, p.y)
		mx.x = maxf(mx.x, p.x)
		mx.y = maxf(mx.y, p.y)
	return [(mn.x + mx.x) * 0.5, (mn.y + mx.y) * 0.5, 1.0, 0.0,
			maxf((mx.x - mn.x) * 0.5, 0.001), maxf((mx.y - mn.y) * 0.5, 0.001)]


## ---- Rasterisation acceleration (PASTURE3D_LANDSCAPE_TOOLS_SPEC.md §9 performance) ----
##
## Curve3D bakes at ~0.2 m, so a simple loop becomes 1000s of edges — 5× finer than the 1 m terrain
## grid and the source of the O(cells × edges) freeze. Decimate the baked polyline down to roughly the
## terrain resolution before rasterising; the chamfer distance field below then runs in O(cells).

## Sample _base_height_below at each spline point. O(npts) — cheap alternative to _base_below_grid
## for computing ground_ref in C++ via per-segment linear interpolation (a_ground + t*(b_ground-a_ground)).
func _below_pts(pts: PackedVector3Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(pts.size())
	for i in range(pts.size()):
		out[i] = _base_height_below(pts[i])
	return out


## 3-D version of _decimate for ridge/trough open polylines (preserves XYZ for height).
func _decimate3(pts: PackedVector3Array, step: float) -> PackedVector3Array:
	var n := pts.size()
	if n < 3:
		return pts
	var out := PackedVector3Array()
	out.append(pts[0])
	var acc := 0.0
	for i in range(1, n):
		var d := Vector2(pts[i].x - pts[i - 1].x, pts[i].z - pts[i - 1].z).length()
		acc += d
		if acc >= step:
			out.append(pts[i])
			acc = 0.0
	if out[out.size() - 1] != pts[n - 1]:
		out.append(pts[n - 1])
	return out


## Decimate a world-space point list, keeping a point about every `step` metres (drops the dense
## in-between bakes). Used for both closed loops (Mound) and open polylines (Ridge/Trough).
func _decimate(pts: PackedVector2Array, step: float) -> PackedVector2Array:
	var n := pts.size()
	if n < 3:
		return pts
	var out := PackedVector2Array()
	out.append(pts[0])
	var acc := 0.0
	for i in range(1, n):
		acc += pts[i].distance_to(pts[i - 1])
		if acc >= step:
			out.append(pts[i])
			acc = 0.0
	# Always keep the final point so an open polyline reaches its real end.
	if out[out.size() - 1] != pts[n - 1]:
		out.append(pts[n - 1])
	return out


## Two-pass chamfer distance transform, in place. Each cell ends up holding (approximately) the
## Euclidean distance to the nearest zero-seeded cell, in metres (orthogonal step `a`, diagonal `b`).
## O(cells) — replaces the per-pixel-per-edge distance loop. (Refs: chamfer DT / SDF literature.)
func _chamfer(arr: PackedFloat32Array, gw: int, gh: int, a: float, b: float) -> void:
	for iz in range(gh):
		var row := iz * gw
		for ix in range(gw):
			var i := row + ix
			var d := arr[i]
			if iz > 0:
				var up := i - gw
				if arr[up] + a < d:
					d = arr[up] + a
				if ix > 0 and arr[up - 1] + b < d:
					d = arr[up - 1] + b
				if ix < gw - 1 and arr[up + 1] + b < d:
					d = arr[up + 1] + b
			if ix > 0 and arr[i - 1] + a < d:
				d = arr[i - 1] + a
			arr[i] = d
	for iz in range(gh - 1, -1, -1):
		var row := iz * gw
		for ix in range(gw - 1, -1, -1):
			var i := row + ix
			var d := arr[i]
			if iz < gh - 1:
				var dn := i + gw
				if arr[dn] + a < d:
					d = arr[dn] + a
				if ix < gw - 1 and arr[dn + 1] + b < d:
					d = arr[dn + 1] + b
				if ix > 0 and arr[dn - 1] + b < d:
					d = arr[dn - 1] + b
			if ix < gw - 1 and arr[i + 1] + a < d:
				d = arr[i + 1] + a
			arr[i] = d


## Signed distance field of a closed world polygon over a grid: positive inside, negative outside, in
## Exact analytic signed distance field of a closed world-space polygon over the grid. Positive inside,
## negative outside, in metres. Returns [PackedFloat32Array field, float max_inside_distance]. Inside is
## determined via exact scanline fill, and Euclidean boundary distances are evaluated analytically per cell,
## eliminating discrete chamfer discretization banding and octagonal facets.
func _signed_distance_field(poly: PackedVector2Array, min_x: float, min_z: float, vs: float, gw: int, gh: int) -> Array:
	var n := gw * gh
	var pc := poly.size()
	if pc < 3 or gw < 1 or gh < 1:
		return [Pasture3DGraphOps.zeros(n), 0.0]

	var inside := PackedByteArray()
	inside.resize(n)
	# Even-odd scanline fill (half-open edge rule avoids double-counting shared vertices).
	for iz in range(gh):
		var zc := min_z + iz * vs
		var xs := PackedFloat32Array()
		for e in range(pc):
			var pa := poly[e]
			var pb := poly[(e + 1) % pc]
			if (pa.y <= zc and pb.y > zc) or (pb.y <= zc and pa.y > zc):
				var tt := (zc - pa.y) / (pb.y - pa.y)
				xs.append(pa.x + tt * (pb.x - pa.x))
		xs.sort()
		var row := iz * gw
		var k := 0
		while k + 1 < xs.size():
			var ix0 := int(ceil((xs[k] - min_x) / vs))
			var ix1 := int(floor((xs[k + 1] - min_x) / vs))
			if ix0 < 0:
				ix0 = 0
			if ix1 > gw - 1:
				ix1 = gw - 1
			for ix in range(ix0, ix1 + 1):
				inside[row + ix] = 1
			k += 2

	# Precompute box-local polygon segments for fast analytic distance evaluation
	var seg_ax := PackedFloat32Array()
	var seg_ay := PackedFloat32Array()
	var seg_abx := PackedFloat32Array()
	var seg_aby := PackedFloat32Array()
	var seg_inv_len2 := PackedFloat32Array()
	var seg_min_x := PackedFloat32Array()
	var seg_min_y := PackedFloat32Array()
	var seg_max_x := PackedFloat32Array()
	var seg_max_y := PackedFloat32Array()
	seg_ax.resize(pc)
	seg_ay.resize(pc)
	seg_abx.resize(pc)
	seg_aby.resize(pc)
	seg_inv_len2.resize(pc)
	seg_min_x.resize(pc)
	seg_min_y.resize(pc)
	seg_max_x.resize(pc)
	seg_max_y.resize(pc)

	for e in range(pc):
		var pa := poly[e]
		var pb := poly[(e + 1) % pc]
		var ax := float(pa.x - min_x)
		var ay := float(pa.y - min_z)
		var bx := float(pb.x - min_x)
		var by := float(pb.y - min_z)
		var abx := bx - ax
		var aby := by - ay
		var len2 := abx * abx + aby * aby
		seg_ax[e] = ax
		seg_ay[e] = ay
		seg_abx[e] = abx
		seg_aby[e] = aby
		seg_inv_len2[e] = 1.0 / len2 if len2 > 1e-12 else 0.0
		seg_min_x[e] = minf(ax, bx)
		seg_max_x[e] = maxf(ax, bx)
		seg_min_y[e] = minf(ay, by)
		seg_max_y[e] = maxf(ay, by)

	var field := PackedFloat32Array()
	field.resize(n)
	var max_inside := 0.0

	# Exact analytic Euclidean distance per cell with spatial AABB pruning and neighbor warm-start
	var last_best_s := 0
	for iz in range(gh):
		var qy := float(iz * vs)
		var row := iz * gw
		for ix in range(gw):
			var qx := float(ix * vs)
			var i := row + ix

			# Warm-start with previous cell's closest segment
			var best_s := last_best_s
			var bqax := qx - seg_ax[best_s]
			var bqay := qy - seg_ay[best_s]
			var bt := clampf((bqax * seg_abx[best_s] + bqay * seg_aby[best_s]) * seg_inv_len2[best_s], 0.0, 1.0)
			var bdx := bqax - bt * seg_abx[best_s]
			var bdy := bqay - bt * seg_aby[best_s]
			var min_d2 := bdx * bdx + bdy * bdy

			for e in range(pc):
				if e == best_s:
					continue
				var cdx := maxf(0.0, maxf(seg_min_x[e] - qx, qx - seg_max_x[e]))
				var cdy := maxf(0.0, maxf(seg_min_y[e] - qy, qy - seg_max_y[e]))
				if cdx * cdx + cdy * cdy >= min_d2:
					continue

				var qax := qx - seg_ax[e]
				var qay := qy - seg_ay[e]
				var t := clampf((qax * seg_abx[e] + qay * seg_aby[e]) * seg_inv_len2[e], 0.0, 1.0)
				var dx := qax - t * seg_abx[e]
				var dy := qay - t * seg_aby[e]
				var d2 := dx * dx + dy * dy
				if d2 < min_d2:
					min_d2 = d2
					best_s = e

			last_best_s = best_s
			var d := sqrt(min_d2)
			if inside[i] == 1:
				field[i] = d
				if d > max_inside:
					max_inside = d
			else:
				field[i] = -d

	return [field, max_inside]


## EXACT closest-point-on-segment feature field of a world-space polyline (the GDScript reference oracle
## for the native stamp_ridge/trough_line field; mirrors its ds==1 path verbatim). For each cell within
## `reach` of the polyline, returns the nearest lateral distance, the spline crest/bed Y at the nearest
## point, the arc length to it, and the below-layer ground there (linearly interpolated from `below_pts`).
## Returns [lat, base_y, along, ground_ref, total]. Unreached cells keep lat=BIG, ground_ref=NAN. This is
## O(cells × segments) like the native ds==1 path — exact (no chamfer angular error, no seams), so it
## replaces _polyline_field + _smooth_arclength_fields for an exact A/B match with the C++ rasteriser.
func _exact_polyline_field(pts: PackedVector3Array, below_pts: PackedFloat32Array,
		min_x: float, min_z: float, vs: float, gw: int, gh: int, reach: float) -> Array:
	var n := gw * gh
	const BIG := 1.0e9
	var lat := PackedFloat32Array(); lat.resize(n); lat.fill(BIG)
	var base_y := PackedFloat32Array(); base_y.resize(n)
	var along := PackedFloat32Array(); along.resize(n)
	var ground_ref := PackedFloat32Array(); ground_ref.resize(n); ground_ref.fill(NAN)
	var has_below := below_pts.size() == pts.size()
	var arc := 0.0
	var npts := pts.size()
	for k in range(npts - 1):
		var a := pts[k]
		var b := pts[k + 1]
		var dx := b.x - a.x
		var dz := b.z - a.z
		var seg_len_sq := dx * dx + dz * dz
		var seg_len := sqrt(seg_len_sq)
		var ag := below_pts[k] if has_below else NAN
		var bg := below_pts[k + 1] if has_below else NAN
		var six0 := maxi(0, int(floor((minf(a.x, b.x) - reach - min_x) / vs)))
		var six1 := mini(gw - 1, int(ceil((maxf(a.x, b.x) + reach - min_x) / vs)))
		var siz0 := maxi(0, int(floor((minf(a.z, b.z) - reach - min_z) / vs)))
		var siz1 := mini(gh - 1, int(ceil((maxf(a.z, b.z) + reach - min_z) / vs)))
		for iz in range(siz0, siz1 + 1):
			var cz := min_z + iz * vs
			var row := iz * gw
			for ix in range(six0, six1 + 1):
				var cx := min_x + ix * vs
				var qx := cx - a.x
				var qz := cz - a.z
				var t := clampf((qx * dx + qz * dz) / seg_len_sq, 0.0, 1.0) if seg_len_sq > 1e-18 else 0.0
				var px := a.x + t * dx
				var pz := a.z + t * dz
				var d := sqrt((cx - px) * (cx - px) + (cz - pz) * (cz - pz))
				var i := row + ix
				if d < lat[i]:
					lat[i] = d
					base_y[i] = a.y + t * (b.y - a.y)
					along[i] = arc + t * seg_len
					ground_ref[i] = (ag + t * (bg - ag)) if has_below else NAN
		arc += seg_len
	return [lat, base_y, along, ground_ref, maxf(arc, 0.001)]


## ---- Virtuals for subclasses ----

func _get_blend_mode() -> int:
	return BLEND_REPLACE


## Map type this brush paints (TYPE_HEIGHT default; Pasture3DSplat returns TYPE_CONTROL). Drives the
## reserved layer's type, update_maps, and which brush layers this tool shares with.
func _map_type() -> int:
	return PASTURE_3D_MAPTYPE_HEIGHT


## Default tool-layer name for a fresh node of this type (e.g. "Mounds"). Used to build _layer_owner.
func _default_layer_name() -> String:
	return "Brush"


## Whether a fresh node of this brush starts with snap_to_surface on. Area brushes (Mound/Plow/Splat)
## want their loop glued to the ground; line brushes (Ridge/Trough) author vertical crest/bed shapes in
## 3D, so they default OFF. Applied in _init (scene-stored values still win).
func _default_snap_to_surface() -> bool:
	return true


func _padding() -> float:
	return 2.0


## The Modifier Margin actually in force: the exported metres, but only on a host that runs the stack (the
## property is hidden elsewhere and a stray stored value must not silently widen a brush that can't use it).
func _effective_modifier_margin() -> float:
	return maxf(modifier_margin, 0.0) if _supports_modifiers() else 0.0


## The lateral reach the footprint AABB is padded by on every side: the subclass's intrinsic `_padding()`
## (which keeps the SDF a cell or two clear of the grid edge) PLUS the Modifier Margin. Every footprint /
## span / grid-extent computation goes through this, so widening the margin widens the grid the modifier
## stack evaluates over — which is the whole point (see `modifier_margin`).
func _total_padding() -> float:
	return _padding() + _effective_modifier_margin()


func _spline_paintable(path: Path3D) -> bool:
	return path.curve != null and path.curve.point_count >= _min_points()


func _min_points() -> int:
	return 2


## Whether the loop wraps last-point-to-first (a closed ring). Closed-fill brushes (Mound/Plow/Splat,
## min ≥ 3 points) are always closed; the open polyline brushes (Ridge/Trough) override this with a
## runtime toggle. Drives loop-wrap in the gizmo (tangents, segment insertion) and the rasterizers.
func _is_closed() -> bool:
	return _min_points() >= 3


func _paint_spline(_path: Path3D) -> void:
	push_error("Pasture3DTerrainBrush._paint_spline must be overridden by a subclass.")


func _make_starter_curve() -> Curve3D:
	return Curve3D.new()


func _spline_basename() -> String:
	return "Spline"
