# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3D <-> godot-road-generator connector.
#
# Drop a RoadPastureConnector node into your scene, then assign a RoadManager
# (from the godot-road-generator addon) and a Pasture3D node. It flattens the
# Pasture3D heightmap under generated roads, and can carve holes under roads.
#
# REQUIRES the godot-road-generator addon to be installed and enabled:
#   https://github.com/TheDuckCow/godot-road-generator
# This is a bridge node and references RoadManager / RoadContainer / RoadSegment /
# RoadIntersection / RoadPoint. Only add it to scenes where road-generator is present.
#
# Adapted from road-generator's terrain3d_road_connector.gd. The flattening
# geometry is unchanged; only the terrain references are retargeted from
# Terrain3D to Pasture3D (a fork with a 1:1 data API). See
# PASTURE3D_ROAD_CONNECTOR_GUIDE.md for the full design notes.
@tool
class_name RoadPastureConnector
extends Node

enum Flatten_terrain_option {
	APPROXIMATE, ## Faster and supports falloff, but doesn't handle tilting well
	RAYCAST, ## Accurate and handles tilting, but doesn't have smooth falloth
	BOTH ## Apply the approximate method first, then the raycast method
}

## Road-generator scripts, resolved LAZILY rather than preloaded.
##
## A preload is a PARSE-TIME dependency, and this script carries a class_name -- so Godot parses it
## during every project scan whether or not any scene uses it. With road-generator absent that made
## a missing OPTIONAL addon into five parse errors on every single project load, in a plugin whose
## water, brushes and terrain have nothing to do with roads. Loading on demand costs one
## ResourceLoader.exists() per session and lets the file parse anywhere.
##
## RoadManager / RoadContainer / RoadIntersection / RoadPoint were global class_names from that same
## addon and are gone from the annotations below for the same reason. This file is duck-typed
## against road-generator now; see _is_segment() for the one place that matters.
const ROAD_SEGMENT_PATH := "res://addons/road-generator/nodes/road_segment.gd"
const INTERSECTION_NGON_PATH := "res://addons/road-generator/procgen/intersection_ngon.gd"

static var _road_segment_script: Script = null
static var _intersection_ngon_script: Script = null
static var _scripts_resolved: bool = false


## Load the road-generator scripts once per session. Both stay null when the addon is not
## installed, which is a supported state: every code path that would use them is behind
## is_configured(), and that needs a road_manager the user cannot assign without the addon.
static func _resolve_road_scripts() -> void:
	if _scripts_resolved:
		return
	_scripts_resolved = true
	if ResourceLoader.exists(ROAD_SEGMENT_PATH):
		_road_segment_script = load(ROAD_SEGMENT_PATH)
	if ResourceLoader.exists(INTERSECTION_NGON_PATH):
		_intersection_ngon_script = load(INTERSECTION_NGON_PATH)


static func segment_script() -> Script:
	_resolve_road_scripts()
	return _road_segment_script


static func intersection_ngon_script() -> Script:
	_resolve_road_scripts()
	return _intersection_ngon_script


## Was `node is RoadSegment` while the class was preloaded. is_instance_of against the loaded Script
## is EXACTLY that test, inheritance included -- not a duck-typed approximation of it.
func _is_segment(p_node) -> bool:
	var s := segment_script()
	return s != null and is_instance_of(p_node, s)


## Duck-typed, unlike _is_segment, and deliberately so: RoadIntersection was never preloaded here --
## it arrived as a global class_name from road-generator, so there is no path to load it from.
## `edge_points` is what separates an intersection from a segment in the refresh list, and it is
## checked FIRST, in the same order the old `is RoadIntersection` branch ran.
func _is_intersection(p_node) -> bool:
	return p_node != null and "edge_points" in p_node

## Map type indices, matching Pasture3DData.MapType (TYPE_HEIGHT = 0, TYPE_CONTROL = 1).
## Hardcoded as ints so this script does not hard-depend on the enum binding.
const PASTURE_3D_MAPTYPE_HEIGHT:int = 0 # Pasture3DData.MapType.TYPE_HEIGHT
const PASTURE_3D_MAPTYPE_CONTROL:int = 1 # Pasture3DData.MapType.TYPE_CONTROL

## Blend mode index, matching Pasture3DLayer.BlendMode (REPLACE = 0). The road authors absolute
## height; its edge falloff is expressed as coverage weight, so the composite feathers the shoulder
## into whatever is underneath (PASTURE3D_LAYERS_GUIDE.md §3.1, §11.2). Hardcoded to avoid an enum dep.
const PASTURE_3D_BLEND_REPLACE:int = 0 # Pasture3DLayer.BlendMode.REPLACE


## Reference to the Pasture3D instance, to be flattened
@export var terrain:Pasture3D:
	set(value):
		terrain = value
		configure_road_update_signal()
		if is_node_ready():
			_skip_scene_load = false
## Reference to the RoadManager instance, read only.
## Typed as Node rather than RoadManager so this file parses without road-generator installed; the
## inspector shows a Node picker instead of a filtered one, and everything below duck-types it.
@export var road_manager:Node:
	set(value):
		road_manager = value
		configure_road_update_signal()
		if is_node_ready():
			_skip_scene_load = false
## If enabled, auto refresh the terrain while manipulating roads.
@export var auto_refresh:bool = true:
	set(value):
		auto_refresh = value
		configure_road_update_signal()
## Vertical offset to help avoid z-fighting, negative values will sink the terrain underneath the road
@export var offset:float = -0.25
## Additional flattening to do beyond the edge of the road in meters
@export var edge_margin:float = 0.5
## The falloff to apply for height changes from the edge of the road.
## This falloff range begins beyond the edge of the road + edge margin
@export var edge_falloff:float = 2

@export var flatten_terrain_method :Flatten_terrain_option = Flatten_terrain_option.APPROXIMATE

## Name of the non-destructive height-map layer this connector owns and renders roads into. Roads are
## written here (not into the Base) so hand-sculpting underneath survives and re-running is idempotent.
## Falls back to direct (destructive) height writes on builds/terrains without the layers feature.
@export var target_layer_name := "Roads"

## Create data for new terrain tiles when necessary.[br][br]
##
## If disabled, roads will only adjust heights for pre-existing data tiles.
# TODO: Add in future when feasible
#@export var expand_boundaries:bool = true

## Layer/mask used for editor raycasting, can be different from the runtime collision layers
@export_flags_3d_physics var raycast_layer:int = 2

## Immediately level the terrain to match roads (Godot 4.4+; Pasture3D targets 4.6)
@export_tool_button("Refresh", "Callable") var refresh_action = do_full_refresh
@export_tool_button("Bake Holes", "Callable") var bake_holes_action = bake_holes

# If using Auto Refresh, how often to update the UI (lower values = heavier cpu use)
var refresh_timer: float = 0.05


var _pending_updates:Dictionary = {} # Hashset of RoadSegments to be updated; 4.4+ typing: RoadSegment,bool
var _next_refresh_parents:Array = [] # Array[Mesh]
var _container_unset_geo: Array = [] # RoadContainer, untyped so this parses without road-generator
var _timer:SceneTreeTimer
var _mutex:Mutex = Mutex.new()
var _skip_scene_load: bool = true # Also directly referecned by plugin to ensure top-level refresh works
var _layer_id: int = -1 # Index of our reserved "Roads" height layer; -1 = none / fall back to direct writes
var _hole_layer_id: int = -1 # Index of our reserved "Roads Holes" control layer; -1 = direct set_control_hole
# Per-segment record of the padded world AABB we last flattened, keyed by the stable point-pair id
# (RoadSegment.get_id_for_points, which survives a point-move since the RoadPoints persist). Lets a
# moved/edited road clear its PREVIOUS footprint too, so a large move leaves no stale flattening trail.
# Seeded at scene load (_seed_paint_cache) so even the first move of a session clears the old pose.
var _last_paint_aabb: Dictionary = {} # String sid -> AABB


func _ready() -> void:
	configure_road_update_signal()


func _enter_tree() -> void:
	if is_node_ready():
		configure_road_update_signal.call_deferred()


func _exit_tree() -> void:
	_disconnect_signals()
	_skip_scene_load = true


## Any raycasting must be done from this function in case physics are threaded
func _physics_process(_delta:float) -> void:
	if _next_refresh_parents:
		_mutex.lock()
		var _mesh_parents := _next_refresh_parents.duplicate(true)
		var _unset_geo := _container_unset_geo.duplicate(true)
		_next_refresh_parents = []
		_container_unset_geo = []
		_mutex.unlock()
		refresh_roads(_mesh_parents)
		# Restore the geo setting where temporarily turned on
		for _rc in _unset_geo:
			_rc.create_geo = false


func _get_configuration_warnings() -> PackedStringArray:
	var warnings: PackedStringArray = []
	if not is_instance_valid(road_manager):
		warnings.append("Road manager not assigned for terrain flattening")
	if not is_instance_valid(terrain):
		warnings.append("Pasture3D terrain not assigned for terrain flattening")
	elif not terrain.data or terrain.data.region_locations.size() == 0:
		warnings.append("No Pasture3D regions defined yet, add regions in Pasture3D first")
	return warnings


func is_configured() -> bool:
	var has_error:bool = false
	if not is_instance_valid(road_manager):
		push_warning("Road manager not assigned for terrain flattening")
		has_error = true
	if not is_instance_valid(terrain):
		push_warning("Pasture3D terrain not assigned for terrain flattening")
		has_error = true
	elif not terrain.data or terrain.data.region_locations.size() == 0:
		push_warning("No Pasture3D regions defined yet, add regions in Pasture3D first")
		has_error = true
	return not has_error


func configure_road_update_signal() -> void:
	if not Engine.is_editor_hint():
		# Don't run outside of an editor context
		return
	if not is_instance_valid(road_manager):
		return

	# Handle signals from each RoadContainer when there are updated segments
	if auto_refresh and not road_manager.on_road_updated.is_connected(_on_manager_road_updated):
		road_manager.on_road_updated.connect(_on_manager_road_updated)
	elif not auto_refresh and road_manager.on_road_updated.is_connected(_on_manager_road_updated):
		road_manager.on_road_updated.disconnect(_on_manager_road_updated)

	# Handle transforms on containers themelves
	if auto_refresh and not road_manager.on_container_transformed.is_connected(_on_container_transform):
		road_manager.on_container_transformed.connect(_on_container_transform)
	elif not auto_refresh and road_manager.on_container_transformed.is_connected(_on_container_transform):
		road_manager.on_container_transformed.disconnect(_on_container_transform)


## Disconnects signals so avoid excessive refreshing if scene tab is opened again in the editor
func _disconnect_signals() -> void:
	if is_instance_valid(road_manager) and road_manager.on_road_updated.is_connected(_on_manager_road_updated):
		road_manager.on_road_updated.disconnect(_on_manager_road_updated)
	if is_instance_valid(road_manager) and road_manager.on_container_transformed.is_connected(_on_container_transform):
		road_manager.on_container_transformed.disconnect(_on_container_transform)


func do_full_refresh() -> void:
	if not is_configured():
		return
	configure_road_update_signal()
	var restart_geo_off: Array = [] # RoadContainer
	var init_auto_refresh: bool = auto_refresh
	for _container in road_manager.get_containers():

		_mutex.lock()
		if not _container.create_geo:
			init_auto_refresh = false
			_container.create_geo = true
			_container.rebuild_segments(true)
			init_auto_refresh = init_auto_refresh
			restart_geo_off.append(_container)

		#var mesh_parents: Array = []
		_next_refresh_parents += _container.get_intersections()
		_next_refresh_parents += _container.get_segments() # Always add RoadSegments last
		_mutex.unlock()

## Removes mesh under roads as a baking process. Holes are carved into our reserved CONTROL layer
## (non-destructive, idempotent) when the layers feature is present, else into the base control map.
func bake_holes() -> void:
	if not is_configured():
		return

	# Resolve our reserved hole (control) layer and gather every segment up front.
	_ensure_hole_layer()
	var all_segs: Array = []
	for _container in road_manager.get_containers():
		all_segs += _container.get_segments()

	# Drop the previously baked holes so a re-bake is idempotent (clear + re-carve). No-op on the
	# destructive fallback path, where set_control_hole writes the base control map directly.
	if _hole_layer_id >= 0:
		var clear_aabb := _affected_aabb(all_segs)
		if clear_aabb.size != Vector3.ZERO:
			terrain.data.clear_layer_in_area(_hole_layer_id, clear_aabb)

	for _seg in all_segs:
		cull_terrain_via_roadsegment(_seg)

	terrain.data.update_maps(PASTURE_3D_MAPTYPE_CONTROL)


## Workaround helper to transform geo for intersection scenes or other
## scenarios where "create_geo" is turned off, by temporairly turning it on.
func _on_container_transform(container) -> void: # RoadContainer
	if not auto_refresh:
		return
	var did_set_geo := false
	if not container.create_geo:
		did_set_geo = true
		container.create_geo = true
		# This will trigger deferred updates which will have invalid instances,
		# but will be safely ignored
		container.rebuild_segments(true)
	# Must directly update terrain now on these segments, before they get
	# removed again when geo is turned off
	_mutex.lock()
	_next_refresh_parents += container.get_intersections()
	_next_refresh_parents += container.get_segments() # Always add RoadSegments last
	if did_set_geo:
		_container_unset_geo.append(container)
	_mutex.unlock()


func _on_manager_road_updated(segments: Array) -> void:
	if not road_manager or not terrain:
		return # one or the other is not defined
	if not road_manager.is_node_ready() or not terrain.is_node_ready():
		# Likely loading scene for the first time, and thus roads will be
		# generated but it's not expected to perform flattening
		return
	_schedule_refresh(segments)


## Accumulates road segments to be refreshed while an operation is in progress
func _schedule_refresh(segments: Array) -> void:
	if _skip_scene_load:
		_skip_scene_load = false
		# This first post-load update fires right after road-generator rebuilt the segments at their
		# saved poses but before any user edit — the ideal moment to seed the footprint cache so the
		# first real move can clear the road's loaded position (no stale trail). See _seed_paint_cache.
		_seed_paint_cache()
		return
	_mutex.lock()
	for _seg in segments:
		# Using a dictionary to accumulate updates to process
		_pending_updates[_seg] = true
	if not is_instance_valid(_timer):
		_timer = get_tree().create_timer(refresh_timer)
	else:
		pass
	if not _timer.timeout.is_connected(_refresh_scheduled_segments):
		_timer.timeout.connect(_refresh_scheduled_segments)
	_mutex.unlock()


func _refresh_scheduled_segments() -> void:
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		# updates may still be in progress, so just reset
		_mutex.lock()
		_timer = null
		call_deferred("_schedule_refresh", [])
		_mutex.unlock()
		return
	_mutex.lock()
	var _mesh_parents := _pending_updates.keys()
	_pending_updates.clear()
	_timer = null
	# Assigning to _next_refresh_parents effectively means the meshes will be
	# refreshed the next time the physics thread runs
	_next_refresh_parents += _mesh_parents
	_mutex.unlock()


## Non-destructive layer plumbing (PASTURE3D_LAYERS_GUIDE.md §8)

## Stable id identifying this connector's reserved layer across refreshes and reloads.
func _owner_id() -> String:
	return str(get_path())


## Resolve (or create) our reserved "Roads" layer. Returns true when a layer is available; false on
## plain terrains / older builds without the layers tool API, in which case writes fall back to the
## destructive set_height path so the connector keeps working unchanged.
func _ensure_layer() -> bool:
	_layer_id = -1
	if not terrain or not terrain.data:
		return false
	if not terrain.data.has_method("create_owned_layer"):
		return false # Layers feature unavailable: caller falls back to direct writes.
	_layer_id = terrain.data.create_owned_layer(_owner_id(), target_layer_name, PASTURE_3D_BLEND_REPLACE)
	return _layer_id >= 0


## Write an absolute road height. Routes into our reserved layer (weight feathers the shoulder via the
## REPLACE composite) when available, else writes the Base height map directly (legacy behaviour).
func _set_road_height(pos: Vector3, height: float, weight: float = 1.0) -> void:
	if _layer_id >= 0:
		terrain.data.set_height_on_layer(_layer_id, pos, height, weight)
	else:
		terrain.data.set_height(pos, height)


## Resolve (or create) our reserved "Roads Holes" CONTROL layer. Returns true when a control layer is
## available; false on plain terrains / builds without typed layers, where holes fall back to the
## destructive set_control_hole path so the connector keeps working unchanged.
func _ensure_hole_layer() -> bool:
	_hole_layer_id = -1
	if not terrain or not terrain.data:
		return false
	if not terrain.data.has_method("create_owned_layer_typed"):
		return false # Control layers unavailable: caller falls back to set_control_hole.
	# Separate owner id from the height "Roads" layer so each tool owns one layer per map type.
	_hole_layer_id = terrain.data.create_owned_layer_typed(
		_owner_id() + "#holes", target_layer_name + " Holes",
		PASTURE_3D_BLEND_REPLACE, PASTURE_3D_MAPTYPE_CONTROL)
	return _hole_layer_id >= 0


## Carve (or clear) a hole. Routes into our reserved control layer (non-destructive / idempotent) when
## available, else flips the hole bit on the base control map directly (legacy behaviour).
func _set_road_hole(pos: Vector3, hole: bool) -> void:
	if _hole_layer_id >= 0:
		terrain.data.set_hole_on_layer(_hole_layer_id, pos, hole)
	else:
		terrain.data.set_control_hole(pos, hole)


## Coverage weight for a shoulder falloff. factor in [0,1] from road edge (0) to falloff end (1).
## weight 1 keeps full road height, easing to 0 (full underlying terrain) — matches the old
## _lerp_smoothed_height(road_y, terrain_y, ease(factor,-1.5)) curve but without a get_height read.
func _falloff_weight(factor: float) -> float:
	return 1.0 - ease(clampf(factor, 0.0, 1.0), -1.5)


## World-space AABB (XZ) enclosing all road meshes being refreshed, padded by the shoulder influence.
## Used to clear the reserved layer's previous road pose before repainting (idempotent re-runs).
func _affected_aabb(mesh_parents: Array) -> AABB:
	var aabb := AABB()
	var has_any := false
	for _p in mesh_parents:
		if not is_instance_valid(_p):
			continue
		var node_aabb := AABB()
		var got := false
		var rm = _p.road_mesh if ("road_mesh" in _p) else null
		if is_instance_valid(rm) and rm is MeshInstance3D and rm.mesh != null:
			node_aabb = rm.global_transform * rm.get_aabb()
			got = true
		elif _p is Node3D:
			node_aabb = AABB(_p.global_position, Vector3.ZERO)
			got = true
		if not got:
			continue
		if not has_any:
			aabb = node_aabb
			has_any = true
		else:
			aabb = aabb.merge(node_aabb)
	if not has_any:
		return AABB()
	# Pad by the shoulder reach so falloff pixels (and any region they touch) are cleared too.
	var pad := Vector3(edge_margin + edge_falloff, 0, edge_margin + edge_falloff)
	aabb.position -= pad
	aabb.size += pad * 2.0
	return aabb


## XZ-plane AABB overlap test. The road footprints all live on the terrain plane but their meshes carry
## real Y extents, so a full AABB.intersects() would miss two roads at different elevations that overlap
## from above. We only care about the ground-plane footprint, so compare X and Z and ignore Y.
func _aabb_overlaps_xz(a: AABB, b: AABB) -> bool:
	var a_max := a.position + a.size
	var b_max := b.position + b.size
	if a_max.x < b.position.x or b_max.x < a.position.x:
		return false
	if a_max.z < b.position.z or b_max.z < a.position.z:
		return false
	return true


## Padded world-space AABB of a single segment's flattened footprint (mesh AABB + shoulder reach), matching
## the padding _affected_aabb uses. Returns an empty AABB for invalid / mesh-less segments.
func _segment_padded_aabb(seg) -> AABB:
	if not validate_segment(seg):
		return AABB()
	var rm = seg.road_mesh
	if not (is_instance_valid(rm) and rm is MeshInstance3D and rm.mesh != null):
		return AABB()
	var aabb: AABB = rm.global_transform * rm.get_aabb()
	var pad := Vector3(edge_margin + edge_falloff, 0, edge_margin + edge_falloff)
	aabb.position -= pad
	aabb.size += pad * 2.0
	return aabb


## Stable id for a segment, derived from its two RoadPoints (which persist across a point-move). Used to
## key the previous-footprint cache so a moved road can clear where it WAS, not just where it is now.
func _segment_id(seg) -> String:
	# A static method on road-generator's RoadSegment. Reached through the lazily loaded script
	# rather than the class name, for the parse-time reason at the top of this file.
	return segment_script().call("get_id_for_points", seg.start_point, seg.end_point)


## Append every road segment whose padded footprint overlaps `clear_aabb` (and isn't already queued) into
## `into`. Used so a partial refresh repaints neighbours whose data the clear is about to wipe. Cheap AABB
## math over all segments; runs only on the non-destructive layer path. Padding matches _affected_aabb so a
## segment whose shoulder falloff merely reaches into the cleared box is caught too.
func _add_segments_overlapping_aabb(clear_aabb: AABB, into: Array) -> void:
	if not is_instance_valid(road_manager):
		return
	for _container in road_manager.get_containers():
		if not is_instance_valid(_container):
			continue
		for _seg in _container.get_segments():
			if _seg in into:
				continue
			var seg_aabb := _segment_padded_aabb(_seg)
			if seg_aabb.size == Vector3.ZERO:
				continue
			if _aabb_overlaps_xz(clear_aabb, seg_aabb):
				into.append(_seg)


## True when `outer` contains `inner` on the XZ plane (ignoring Y, like _aabb_overlaps_xz).
func _aabb_encloses_xz(outer: AABB, inner: AABB) -> bool:
	var outer_max := outer.position + outer.size
	var inner_max := inner.position + inner.size
	return (inner.position.x >= outer.position.x and inner_max.x <= outer_max.x
		and inner.position.z >= outer.position.z and inner_max.z <= outer_max.z)


## Previous footprints (cached old poses) of the segments in `mesh_parents` that are NOT already covered by
## `current_aabb`. Returned as separate boxes (rather than one merged AABB) so we clear only the old pose,
## not the whole swath spanned between the old and new positions. Skips boxes the current clear already
## covers — so a plain refresh (old == new) and small nudges add no redundant clears.
func _previous_footprints(mesh_parents: Array, current_aabb: AABB) -> Array:
	var boxes: Array = []
	for _p in mesh_parents:
		if not _is_segment(_p) or not validate_segment(_p):
			continue
		var sid := _segment_id(_p)
		if not _last_paint_aabb.has(sid):
			continue
		var prev: AABB = _last_paint_aabb[sid]
		if prev.size == Vector3.ZERO or _aabb_encloses_xz(current_aabb, prev):
			continue
		boxes.append(prev)
	return boxes


## Record the current footprint of every existing segment into the previous-footprint cache WITHOUT
## clearing or painting. Called once at scene load (before any user edit) so the first move of a session
## can clear the road's loaded position. Overwrites are harmless — it just re-baselines to current poses.
func _seed_paint_cache() -> void:
	if not is_instance_valid(road_manager):
		return
	for _container in road_manager.get_containers():
		if not is_instance_valid(_container):
			continue
		for _seg in _container.get_segments():
			var aabb := _segment_padded_aabb(_seg)
			if aabb.size != Vector3.ZERO:
				_last_paint_aabb[_segment_id(_seg)] = aabb


## Refreshes all segments of road identified
##
## Order of segments should be first intersections if any, then road segments
## so that the combined flattening is proper.
func refresh_roads(mesh_parents: Array) -> void:
	if not is_configured():
		push_warning("Terrain-Road configuration invalid")
		return
	if not terrain.data:
		push_warning("No terrain data available (yet)")
		return
	if terrain.data.region_locations.size() == 0:
		push_warning("Refresh warning: No Pasture3D regions defined yet, add regions in Pasture3D first")

	# Resolve our reserved layer and drop the previous road pose so a moved/edited road leaves no stale
	# flattening behind (non-destructive + idempotent). No-op when falling back to direct writes.
	_ensure_layer()
	if _layer_id >= 0:
		mesh_parents = mesh_parents.duplicate()
		var clear_aabb := _affected_aabb(mesh_parents)
		if clear_aabb.size != Vector3.ZERO:
			# The clear box is the moved road's footprint padded by the shoulder reach, so it also covers
			# the sub-tiles of any *other* segment that overlaps it — typically the neighbour sharing the
			# moved RoadPoint. Clearing wipes their flattening too, but those segments aren't in the refresh
			# set, so they would be left erased until a full Refresh. Pull every overlapping segment into the
			# repaint set first; repainting is REPLACE/idempotent, so untouched neighbours are unharmed.
			_add_segments_overlapping_aabb(clear_aabb, mesh_parents)
			# Also clear where these roads were LAST painted (their cached previous footprints), so a large
			# move leaves no stale flattening trail at the old pose. Each old box is cleared on its own (not
			# merged into clear_aabb) to avoid wiping the whole swath between the old and new positions; for
			# each, pull in any neighbour overlapping it so roads that sat by the old pose are repainted too.
			var prev_boxes := _previous_footprints(mesh_parents, clear_aabb)
			for _box in prev_boxes:
				_add_segments_overlapping_aabb(_box, mesh_parents)
			terrain.data.clear_layer_in_area(_layer_id, clear_aabb)
			for _box in prev_boxes:
				terrain.data.clear_layer_in_area(_layer_id, _box)

	var skip_repeat_refreshes: Array = []

	var segs: Array = [] # RoadSegment

	# First flatten all road intersections and gather their adjacent segments
	for _seg in mesh_parents:
		if not is_instance_valid(_seg):
			# Will happen (at a minimum) when handling RoadContainers which have
			# create geo turned off AND auto_refresh is on; creates an extra
			# deferred call to here when those segments are temporarily added,
			# but will be invalid by the time this function actually runs as
			# they are destroyed right away after a direct call to this func
			continue
		if _is_intersection(_seg):
			var inter = _seg
			if inter.container.flatten_terrain and inter.flatten_terrain:
				flatten_terrain_via_intersection(inter)
				# Since the intersection flattening is a little too greedy,
				# must post-flatten the adjacent segments too, even if they
				# weren't scheduled
				var adj_segs = intersection_adjacent_segments(inter)
				segs += adj_segs
				# In case these segmetns were already in the list, avoid repeat
				# flattening them
				# TODO: handle case where one segment is directly connected to
				# two intersections
				skip_repeat_refreshes += inter.edge_points
			continue
		elif _is_segment(_seg):
			segs.append(_seg)

	# TODO: For improved undo/redo handling, implement something like this
	#var teditor = terrain.get_editor() # but, editor must have been opened once first
	#teditor.set_terrain(terrain)
	#teditor.start_operation(Vector3.ZERO)

	# Now flatten all accumulated segments
	for _seg in segs:
		if not is_instance_valid(_seg):
			continue
		# Was `_seg = _seg as RoadSegment` followed by a null check -- the cast was filtering
		# non-segments out of the accumulated list, which this does directly.
		if not _is_segment(_seg):
			continue
		if _seg in skip_repeat_refreshes:
			continue
		# check if this segment should be ignored
		if (
			not _seg.container.flatten_terrain
			or (not _seg.start_point.flatten_terrain and not _seg.end_point.flatten_terrain)
		):
			# print("Skipping ignored segment %s/%s" % [_seg.get_parent().name, _seg.name])
			# Flattening is off for this road now: its old footprint was just cleared and won't be
			# repainted, so drop its cache entry to stop merging a stale AABB on future refreshes.
			if _layer_id >= 0:
				_last_paint_aabb.erase(_segment_id(_seg))
			continue
		#print("Refreshing %s/%s" % [_seg.get_parent().name, _seg.name])
		match flatten_terrain_method:
			Flatten_terrain_option.APPROXIMATE:
				flatten_terrain_via_roadsegment_approx(_seg)
			Flatten_terrain_option.RAYCAST:
				flatten_terrain_via_roadsegment_raycast(_seg)
			Flatten_terrain_option.BOTH:
				flatten_terrain_via_roadsegment_approx(_seg)
				flatten_terrain_via_roadsegment_raycast(_seg)
			_:
				flatten_terrain_via_roadsegment_approx(_seg)
		skip_repeat_refreshes.append(_seg)
		# Remember where we just painted so the next move/edit of this road clears this pose too.
		if _layer_id >= 0:
			_last_paint_aabb[_segment_id(_seg)] = _segment_padded_aabb(_seg)

	terrain.data.update_maps(PASTURE_3D_MAPTYPE_HEIGHT) # set 2nd arg false to be optimal

	# TODO: For better undo/redo handling, implement something like this
	#teditor.stop_operation()
	#for _region in edited_regions:
	#region.set_edited(false)


## Flatten and Culling Methods
func flatten_terrain_via_roadsegment_raycast(segment) -> void: # RoadSegment
	if not validate_segment(segment):
		return

	# add extra width to the shoulders for the raycasting,
	# TODO: Account for alignment options
	var buffer = edge_margin

	var mesh: Mesh = segment.road_mesh.mesh
	if mesh == null:
		return

	# create new collision mesh for eventual raycasting
	# TODO: This MUST be done in the process_physics function to avoid errors
	# for users with physics processing on another thread.
	var space_states: Array[PhysicsDirectSpaceState3D] = []
	var revert_layers: Array = []
	for ch in segment.road_mesh.get_children():
		var sbody := ch as StaticBody3D # Set to null if casting fails
		if not sbody:
			continue
		# TODO: This may override the native assigned layers
		revert_layers.append([sbody, sbody.collision_layer, sbody.collision_mask])
		sbody.collision_layer = raycast_layer
		sbody.collision_mask = raycast_layer
		space_states.append(sbody.get_world_3d().direct_space_state)

	# Create a 2D Mask for segment to reduce 3D raycasts
	var curve: Curve3D = segment.curve
	var boundingCurve: Curve2D = curve_3d_to_2d(curve)
	var start_width: float = get_road_width(segment.start_point)
	var end_width: float = get_road_width(segment.end_point)
	var bounding_box_offset = Vector2(segment.start_point.global_position.x, segment.start_point.global_position.z)
	var bounding_polygon: PackedVector2Array = curve_2d_to_boundingbox(boundingCurve,start_width,end_width, bounding_box_offset)

	var vertex_spacing: float = terrain.vertex_spacing

	# Get global bounding box from mesh, expanded by affected smoothing radius
	var offsets := Vector3(buffer, 0, buffer)
	var aabb: AABB = segment.road_mesh.global_transform * segment.road_mesh.get_aabb()
	var aabb_min := aabb.position - offsets
	var aabb_max := aabb.position + aabb.size + offsets

	# Snap bounds to terrain grid
	var min := Vector3(aabb_min.x, 0, aabb_min.z).snapped(Vector3(vertex_spacing, 0, vertex_spacing))
	var max := Vector3(aabb_max.x, 0, aabb_max.z).snapped(Vector3(vertex_spacing, 0, vertex_spacing)) + Vector3(vertex_spacing, 0, vertex_spacing)

	# Cache the raycasts for missed hits to reduce the number of raycasts
	var recorded: Dictionary = {} # 4.4 typing: Dictionary[Vector2,float]
	var missed: Dictionary = {} # 4.4 typing: Dictionary[Vector2, bool]

	# iterate over the xz plane of the curve
	var x = min.x
	while x <= max.x:
		var z = min.z
		while z <= max.z:
			if not Geometry2D.is_point_in_polygon(Vector2(x,z), bounding_polygon):
				z+= vertex_spacing
				continue

			# create raycast to check the height at the (x,z) coords
			var height := get_road_height(x,z,aabb_min.y,aabb_max.y,space_states)
			if height.size() > 0:
				_set_road_height(Vector3(x, height[0], z), height[0] + offset)
				recorded[Vector2(x,z)] = height[0]
			else:
				missed[Vector2(x,z)] = true
				#print("Missed: ", Vector2(x,z))
			z += vertex_spacing
		x += vertex_spacing

	var neighbour_range:float = vertex_spacing * 10
	for _m in missed:
		var heights: Array[float] = []
		var neighbour = Vector2(_m.x+neighbour_range,_m.y)
		if recorded.has(neighbour): heights.append(recorded[neighbour])
		neighbour = Vector2(_m.x-neighbour_range,_m.y)
		if recorded.has(neighbour): heights.append(recorded[neighbour])
		neighbour = Vector2(_m.x,_m.y+neighbour_range)
		if recorded.has(neighbour): heights.append(recorded[neighbour])
		neighbour = Vector2(_m.x,_m.y-neighbour_range)
		if recorded.has(neighbour): heights.append(recorded[neighbour])
		if heights.size() > 0:
			_set_road_height(Vector3(_m.x, heights.min(), _m.y), heights[0] + offset)

	for _itemset in revert_layers:
		var sbody: StaticBody3D = _itemset[0]
		sbody.collision_layer = _itemset[1]
		sbody.collision_mask = _itemset[1]


## Returns the distance from a 2D point to a line segment (XZ plane).
func _distance_point_to_segment_2d(p: Vector2, a: Vector2, b: Vector2) -> float:
	var v := b - a
	var u := p - a
	var v_len_sq := v.length_squared()
	if is_zero_approx(v_len_sq):
		return p.distance_to(a)
	var t := clampf(u.dot(v) / v_len_sq, 0.0, 1.0)
	var closest := a + t * v
	return p.distance_to(closest)


## Returns the minimum distance from a 2D point to any edge of the polygon.
## Used for points outside the polygon to compute margin/falloff.
func _distance_to_polygon_boundary_2d(point: Vector2, polygon: PackedVector2Array) -> float:
	if polygon.size() < 2:
		return INF
	var min_dist := INF
	for i in range(polygon.size()):
		var a := polygon[i]
		var b := polygon[(i + 1) % polygon.size()]
		var d := _distance_point_to_segment_2d(point, a, b)
		if d < min_dist:
			min_dist = d
	return min_dist


func _flatten_curve(curve: Curve3D, normalization_value: float):
	if is_zero_approx(normalization_value):
		push_error("Division by zero imminent, curve flattening aborted")
		return

	for i in range(curve.point_count):
		var pos:Vector3 = curve.get_point_position(i)
		var pos_in:Vector3 = curve.get_point_in(i)
		var pos_out:Vector3 = curve.get_point_out(i)

		# Instead of setting pos.y to 0 we divide it by a large enough value so that it becomes effectively flat
		# This is necessary so we can retrieve the height at a later point.
		pos.y /= normalization_value
		pos_in.y /= normalization_value
		pos_out.y /= normalization_value

		curve.set_point_position(i,pos)
		curve.set_point_in(i,pos_in)
		curve.set_point_out(i,pos_out)


func flatten_terrain_via_intersection(inter) -> void: # RoadIntersection
	if not is_instance_valid(inter):
		return
	var ngon := intersection_ngon_script()
	if ngon == null or not is_instance_of(inter.settings, ngon):
		push_warning("Intersection flattening only supported for IntersectionNGon. Skipping.")
		return
	if not inter.edge_points.size():
		push_warning("Intersection has no edge points. Skipping terrain flatten.")
		return

	var center_global: Vector3 = inter.global_position
	var center_y: float = center_global.y + offset
	var vertex_spacing: float = terrain.vertex_spacing

	# Build triangle-fan boundary in world space: [side_l_0, side_r_0, side_l_1, side_r_1, ...]
	# This relies on the fact that edge_points should already be in a clockwise order
	var boundary_world: PackedVector2Array = PackedVector2Array()
	var edge_heights: Array[float] = [center_y]
	for edge in inter.edge_points:
		if not is_instance_valid(edge):
			continue
		var width: float = get_road_width(edge)
		var perp: Vector3 = edge.global_transform.basis.x.normalized()

		# TODO: Account for alignment offset once intersections do as well.
		var side_l: Vector3 = edge.global_position - perp * (width * 0.5)
		var side_r: Vector3 = edge.global_position + perp * (width * 0.5)
		if edge.get_prior_road_node(true) == inter:
			# Must insert in the clockwise order, so depends on RP orientation
			var tmp: Vector3 = side_l
			side_l = side_r
			side_r = tmp

		boundary_world.append(Vector2(side_l.x, side_l.z))
		boundary_world.append(Vector2(side_r.x, side_r.z))
		edge_heights.append(edge.global_position.y + offset)

	# Simplification for now to just use the lowest y-height amongst all points
	var min_height:float = edge_heights.min()
	if boundary_world.size() < 3:
		return

	# AABB from center and all boundary points, expanded by margin + falloff
	var aabb_min := center_global
	var aabb_max := center_global
	for i in range(boundary_world.size()):
		var v := Vector3(boundary_world[i].x, center_global.y, boundary_world[i].y)
		aabb_min = aabb_min.min(v)
		aabb_max = aabb_max.max(v)
	var offsets := Vector3(edge_margin + edge_falloff, 0.0, edge_margin + edge_falloff)
	aabb_min -= offsets
	aabb_max += offsets

	var min_xz := Vector3(aabb_min.x, 0.0, aabb_min.z).snapped(Vector3(vertex_spacing, 0.0, vertex_spacing))
	var max_xz := Vector3(aabb_max.x, 0.0, aabb_max.z).snapped(Vector3(vertex_spacing, 0.0, vertex_spacing)) + Vector3(vertex_spacing, 0.0, vertex_spacing)

	var x := min_xz.x
	while x <= max_xz.x:
		var z := min_xz.z
		while z <= max_xz.z:
			var pt_2d := Vector2(x, z)

			# TODO: Improve by finding the edge which this point is pointing towards,
			# interpolating the cloeset matching point along that edge,
			# then interpolate along to the center.
			# Instead, for now, we'll just pick the lowest point between them all
			var road_y: float = min_height

			var inside: bool = Geometry2D.is_point_in_polygon(pt_2d, boundary_world)
			var dist_to_boundary: float
			if inside:
				dist_to_boundary = 0.0
			else:
				dist_to_boundary = _distance_to_polygon_boundary_2d(pt_2d, boundary_world)

			if dist_to_boundary <= edge_margin:
				var terrain_pos := Vector3(x, road_y, z)
				_set_road_height(terrain_pos, road_y, 1.0)
			elif dist_to_boundary <= edge_margin + edge_falloff:
				var terrain_pos := Vector3(x, road_y, z)
				var factor: float = (dist_to_boundary - edge_margin) / edge_falloff
				# REPLACE-layer coverage weight feathers road_y into whatever is underneath; on the
				# legacy fallback path this reproduces the old lerp against the live terrain height.
				if _layer_id >= 0:
					_set_road_height(terrain_pos, road_y, _falloff_weight(factor))
				else:
					var reference_height: float = terrain.data.get_height(terrain_pos)
					_set_road_height(terrain_pos, _lerp_smoothed_height(road_y, reference_height, factor))

			z += vertex_spacing
		x += vertex_spacing


## Called after intersection flattening has completed, to avoid overlap
func intersection_adjacent_segments(inter) -> Array: # RoadIntersection
	var segs: Array = []
	for _edge in inter.edge_points:
		var rp = _edge # RoadPoint
		if rp.prior_seg:
			segs.append(rp.prior_seg)
		if rp.next_seg:
			segs.append(rp.next_seg)
	return segs


## Approximate method, will have issues with tilting
func flatten_terrain_via_roadsegment_approx(segment) -> void: # RoadSegment
	if not validate_segment(segment):
		return
	var mesh: Mesh = segment.road_mesh.mesh
	if mesh == null:
		return

	var curve: Curve3D = segment.curve
	var start_width: float = get_road_width(segment.start_point)
	var end_width: float = get_road_width(segment.end_point)
	var vertex_spacing: float = terrain.vertex_spacing

	# Creat the flattened version of the curve.
	# Check out the following Issue for more information why this is necessary: https://github.com/TheDuckCow/godot-road-generator/issues/322
	var flattened_curve: Curve3D = curve.duplicate(true)
	# The normalization factor is picked arbitrary here. The steeper the road, the bigger this value needs to be
	# Values that are too big can cause issues because of float accuracy, too small causes the terrain height to be wrong
	var normalization_factor:float = 10000
	_flatten_curve(flattened_curve,normalization_factor)

	# Get global bounding box from mesh, expanded by affected smoothing radius
	var offsets := Vector3(edge_margin+edge_falloff, 0, edge_margin+edge_falloff)
	var aabb: AABB = segment.road_mesh.global_transform * segment.road_mesh.get_aabb()
	var aabb_min := aabb.position - offsets
	var aabb_max := aabb.position + aabb.size + offsets

	# Snap bounds to terrain grid
	var min := Vector3(aabb_min.x, 0, aabb_min.z).snapped(Vector3(vertex_spacing, 0, vertex_spacing))
	var max := Vector3(aabb_max.x, 0, aabb_max.z).snapped(Vector3(vertex_spacing, 0, vertex_spacing)) + Vector3(vertex_spacing, 0, vertex_spacing)

	var world_to_local: Transform3D = segment.global_transform.inverse()

	var x = min.x
	while x <= max.x:
		var z = min.z
		while z <= max.z:
			var world_pos := Vector3(x, 0.0, z)
			var local_pos: Vector3 = world_to_local * world_pos

			var closest_distance := flattened_curve.get_closest_offset(local_pos)
			var curve_point := flattened_curve.sample_baked(closest_distance)
			curve_point.y *= normalization_factor
			var world_curve_point: Vector3 = segment.global_transform * curve_point

			# Check if we are beyond the egde of this RoadSegment, and thus
			# would overlap with updates done by the next RoadSegment
			if closest_distance == 0.0:
				var _offset = world_pos - segment.start_point.global_position
				var zdist := absf(segment.start_point.global_transform.basis.z.dot(_offset))
				if zdist > vertex_spacing:
					z += vertex_spacing
					continue
			if closest_distance == flattened_curve.get_baked_length():
				var _offset = world_pos - segment.end_point.global_position # check this, also if can be flipped..???
				var zdist:float = abs(segment.end_point.global_transform.basis.z.dot(_offset))
				if zdist > vertex_spacing:
					z += vertex_spacing
					continue

			# TODO: project this world position onto the xz plane of the transform
			# returned at this curvepoint, to account for road tilting
			# Likely making use of: sample_baked_with_rotation
			var road_y: float = world_curve_point.y + offset

			var lateral_vector := world_pos - Vector3(world_curve_point.x, 0.0, world_curve_point.z)

			var t := clamp(closest_distance / flattened_curve.get_baked_length(), 0.0, 1.0)
			# Note: this will not be exact as it's not actually linear, as there
			# is some ease/smoothing done for lane count / width changes
			# TODO: Need to account for RoadPoint alignment, right now assumes CENTERED
			# Offset by lane_width * number rev lanes if not centered.
			var width := lerpf(start_width, end_width, t)

			var lat_dist: float = lateral_vector.length()
			if lat_dist <= width / 2.0 + edge_margin:
				# Flatten to exactly match the road, adding shoulder margin
				var terrain_pos := Vector3(x, road_y, z)
				#if not terrain.data.has_regionp(terrain_pos):
					#print("SKipping not region rp post, todo: expand_boundaries")
					#continue
				#var region = terrain.data.get_regionp(terrain_pos)
				#if not region:
					#print("SKipping not region, todo: expand_boundaries")
					#continue
				_set_road_height(terrain_pos, road_y, 1.0)
				#region.set_edited(true)
			elif lat_dist <= width / 2.0 + edge_margin + edge_falloff:
				# Smoothly interpolate height beyon shoulder to prior height
				# TODO: improve possible creasing issues caused here
				var terrain_pos := Vector3(x, road_y, z)
				# TODO: Revisit this, currently requestion regionp's tanks performance / gets stuck.
				# severley. Howeve, errors for attempting to set heights for
				# invalid regions is very fast, just noisy in the console.
				#if not terrain.data.has_regionp(terrain_pos):
					#print("SKipping not region rp post, todo: expand_boundaries")
				#	continue
				#var region = terrain.data.get_regionp(terrain_pos)
				#if not region:
					#print("Skipping region")
					#continue
				#region.set_edited(true)
				var factor: float = (lat_dist - edge_margin - width / 2.0) / edge_falloff
				# REPLACE-layer coverage weight feathers the shoulder into the underlying terrain.
				if _layer_id >= 0:
					_set_road_height(terrain_pos, road_y, _falloff_weight(factor))
				else:
					var reference_height:float = terrain.data.get_height(terrain_pos)
					_set_road_height(terrain_pos, _lerp_smoothed_height(road_y, reference_height, factor))


			z += vertex_spacing
		x += vertex_spacing


func cull_terrain_via_roadsegment(segment) -> void: # RoadSegment
	if not validate_segment(segment):
		print_debug("not valid for culling")
		return

	var mesh: Mesh = segment.road_mesh.mesh
	if mesh == null:
		print_debug("no mesh found for road, won't cut")
		return

	# clean up any lingering collision meshes
	for ch in segment.road_mesh.get_children():
		ch.queue_free()  # Prior collision meshes

	# create new colission mesh for eventual raycasting
	print_debug("creating trimesh for hole culling")
	segment.road_mesh.create_trimesh_collision()
	var space_states: Array[PhysicsDirectSpaceState3D] = []
	for ch in segment.road_mesh.get_children():
		var sbody := ch as StaticBody3D # Set to null if casting fails
		if not sbody:
			continue
		sbody.collision_layer = raycast_layer
		sbody.collision_mask = raycast_layer
		space_states.append(sbody.get_world_3d().direct_space_state)

	# Create a 2D Mask for segment to reduce 3D raycasts
	var curve: Curve3D = segment.curve
	var boundingCurve: Curve2D = curve_3d_to_2d(curve)
	var start_width: float = get_road_width(segment.start_point)
	var end_width: float = get_road_width(segment.end_point)
	var bounding_box_offset = Vector2(segment.start_point.global_position.x,segment.start_point.global_position.z)
	var bounding_polygon: PackedVector2Array = curve_2d_to_boundingbox(boundingCurve,start_width,end_width, bounding_box_offset)

	var vertex_spacing: float = terrain.vertex_spacing

	# Get global bounding box from mesh, expanded by affected smoothing radius
	var offsets := Vector3(edge_margin+edge_falloff, 0, edge_margin+edge_falloff)
	var aabb: AABB = segment.road_mesh.global_transform * segment.road_mesh.get_aabb()
	var aabb_min := aabb.position - offsets
	var aabb_max := aabb.position + aabb.size + offsets

	# Snap bounds to terrain grid
	var min := Vector3(aabb_min.x, 0, aabb_min.z).snapped(Vector3(vertex_spacing, 0, vertex_spacing))
	var max := Vector3(aabb_max.x, 0, aabb_max.z).snapped(Vector3(vertex_spacing, 0, vertex_spacing)) + Vector3(vertex_spacing, 0, vertex_spacing)

	# hashset for xz plane where the road overlaps the Terrain
	var intersect_coords: Dictionary # 4.4 typing: Dictionary[Vector2,bool]

	# itterate over the xz plane of the curve to find intersecting points which are hidden
	var x = min.x
	while x <= max.x:
		var z = min.z
		while z <= max.z:
			# ignore the coords outside of the bounding polygon
			if not Geometry2D.is_point_in_polygon(Vector2(x,z), bounding_polygon):
				z+= vertex_spacing
				continue
			# check that the road does infact cover the terrain on (x,z)
			if get_road_height(x,z,aabb_min.y,aabb_max.y,space_states).size() > 0:
				intersect_coords[Vector2(x,z)] = true
			z += vertex_spacing
		x += vertex_spacing

	# free the temporary collision meshs we created
	for ch in segment.road_mesh.get_children():
		ch.queue_free()

	#print(str(intersect_coords.keys()))
	# add hole for each point which has all 8 neighbours on x-z plane
	for point in intersect_coords.keys():
		if intersect_coords.has(Vector2(point.x - vertex_spacing,point.y)) \
		and intersect_coords.has(Vector2(point.x + vertex_spacing,point.y)) \
		and intersect_coords.has(Vector2(point.x,point.y - vertex_spacing)) \
		and intersect_coords.has(Vector2(point.x,point.y + vertex_spacing)) \
		and intersect_coords.has(Vector2(point.x - vertex_spacing,point.y - vertex_spacing)) \
		and intersect_coords.has(Vector2(point.x + vertex_spacing,point.y + vertex_spacing)) \
		and intersect_coords.has(Vector2(point.x + vertex_spacing,point.y - vertex_spacing)) \
		and intersect_coords.has(Vector2(point.x - vertex_spacing,point.y + vertex_spacing)):
			_set_road_hole(Vector3(point.x, 0, point.y), true)


## Helper Methods
# TODO: Move this utility into the RoadSegment (with offset) or RoadPoint class (no offset)
func get_road_width(point) -> float: # RoadPoint
	return (point.gutter_profile.x*2
		+ point.shoulder_width_l
		+ point.shoulder_width_r
		+ point.lane_width * point.lanes.size()
	)


## Used to create a "Mask"
func curve_3d_to_2d(curve: Curve3D) -> Curve2D:
	var curve2d := Curve2D.new()
	var point_count := curve.get_point_count()

	for i in point_count:
		var pos3 = curve.get_point_position(i)
		var in3 = curve.get_point_in(i)
		var out3 = curve.get_point_out(i)
		var tilt = curve.get_point_tilt(i)

		# Project to XZ plane (drop Y)
		var pos2 = Vector2(pos3.x, pos3.z)
		var in2 = Vector2(in3.x, in3.z)
		var out2 = Vector2(out3.x, out3.z)

		curve2d.add_point(pos2, in2, out2)
	return curve2d


func curve_2d_to_boundingbox(curve: Curve2D, start_width: float, end_width: float, offset: Vector2) -> PackedVector2Array:
	var baked := curve.get_baked_points()
	var count := baked.size()
	var result := PackedVector2Array()
	if count < 2:
		return result

	var left_points: Array[Vector2] = []
	var right_points: Array[Vector2] = []


	# first tangent
	var extrapolated_neg_1 = baked[0] - baked[1]
	var tangent: Vector2 = (baked[0] - extrapolated_neg_1).normalized()
	var perpendicular_right = tangent.rotated(deg_to_rad(90))
	var perpendicular_left = tangent.rotated(deg_to_rad(-90))
	left_points.append(extrapolated_neg_1 + perpendicular_left * start_width + offset)
	right_points.append(extrapolated_neg_1 + perpendicular_right * start_width + offset)

	for i in count:
		if i == 0:
			tangent = (baked[1] - baked[0]).normalized()
		elif i == count - 1:
			tangent = (baked[i] - baked[i - 1]).normalized()
		else:
			tangent = (baked[i+1] - baked[i-1]).normalized()
		perpendicular_right = tangent.rotated(deg_to_rad(90))
		perpendicular_left = tangent.rotated(deg_to_rad(-90))
		var t := float(i) / float(count - 1)
		var width := lerpf(start_width, end_width, t) * 0.5
		left_points.append(baked[i] + perpendicular_left * width + offset)
		right_points.append(baked[i] + perpendicular_right * width + offset)

	var extrapolated_last = baked[count - 1] + (baked[count - 1] - baked[count - 2])
	tangent = (extrapolated_last - baked[count - 1]).normalized()
	perpendicular_right = tangent.rotated(deg_to_rad(90))
	perpendicular_left = tangent.rotated(deg_to_rad(-90))
	left_points.append(extrapolated_last + perpendicular_left * end_width + offset)
	right_points.append(extrapolated_last + perpendicular_right * end_width + offset)

	right_points.reverse()
	result.append_array(PackedVector2Array(left_points))
	result.append_array(PackedVector2Array(right_points))
	return result


func validate_segment(segment) -> bool: # RoadSegment
	if not is_instance_valid(segment):
		return false
	if not is_instance_valid(segment.start_point) or not is_instance_valid(segment.end_point):
		return false
	return is_instance_valid(segment.road_mesh)


# can't be nullable so an empty array indicates null (failed to find a height)
func get_road_height(x: float, z: float, min_y: float, max_y: float, space_states: Array[PhysicsDirectSpaceState3D]) -> Array[float]:
	var ray := PhysicsRayQueryParameters3D.create(Vector3(x, max_y, z),Vector3(x, min_y, z))
	ray.collision_mask = raycast_layer
	var set_height := false
	var height:float = 0.0
	for state in space_states:
		var result = state.intersect_ray(ray)
		if not result.is_empty() and result.has("position"):
			if not set_height:
				set_height = true
				height = result["position"].y
			else:
				height = max(height, result["position"].y)
	if set_height:
		return [height]
	return []


## Reusable function to perform consistent falloff rate
func _lerp_smoothed_height(road_y: float, terrain_y: float, factor: float) -> float:
	return lerpf(road_y, terrain_y, ease(factor, -1.5))
