@tool
extends Path3D

## Maintains one or more Terrain3D curve layers that follow this path.
## The path's Y coordinates define the target terrain height, optionally offset by `depth`.
## Assign `falloff_curve` to sculpt the cross-section profile (Curve X = distance 0-1, Y = weight 0-1).
class_name Terrain3DCurveLayerPath

@export_node_path("Terrain3D") var terrain_path: NodePath
@export_range(0.1, 256.0, 0.01) var width := 8.0
## Additional offset applied to the path-defined height (in meters).
@export_range(-256.0, 256.0, 0.01) var depth := 0.0
@export var dual_groove := false
@export_range(0.0, 64.0, 0.01) var feather_radius := 1.0
@export var falloff_curve: Curve
@export_range(0.1, 32.0, 0.01) var bake_interval := 1.0
@export var auto_create_regions := true
@export var update_maps_on_change := true
@export var update_in_editor := true
@export var update_in_game := true

@export var remove_on_exit := true
@export var debug_logging := false

var _terrain: Terrain3D
var _data: Terrain3DData
var _curve: Curve3D
var _pending_update := false
var _force_rebuild := false
var _region_layers := {}
var _last_terrain_path := NodePath()
var _last_settings_signature := 0

func _ready() -> void:
	_resolve_terrain()
	_update_curve_reference()
	request_update(true)
	set_process(true)
	update_configuration_warnings()

func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		_resolve_terrain()
		_update_curve_reference()
	elif what == NOTIFICATION_TRANSFORM_CHANGED:
		request_update()
	elif what == NOTIFICATION_EXIT_TREE:
		if remove_on_exit:
			_remove_all_layers(false)

func _process(_delta: float) -> void:
	if bake_interval < 0.1:
		bake_interval = 0.1
	if terrain_path != _last_terrain_path:
		_last_terrain_path = terrain_path
		_resolve_terrain()
		request_update(true)
	var settings_signature := hash([width, depth, dual_groove, feather_radius, bake_interval, auto_create_regions, update_maps_on_change])
	if settings_signature != _last_settings_signature:
		_last_settings_signature = settings_signature
		if _curve:
			_curve.bake_interval = bake_interval
		request_update()
	if curve != _curve:
		_update_curve_reference()
	if not _pending_update:
		return
	if Engine.is_editor_hint():
		if not update_in_editor:
			return
	else:
		if not update_in_game:
			return
	_pending_update = false
	var force := _force_rebuild
	_force_rebuild = false
	_apply_update(force)

func request_update(force: bool = false) -> void:
	_pending_update = true
	if force:
		_force_rebuild = true
	set_process(true)

func force_update() -> void:
	request_update(true)

func clear_layers(update_maps: bool = true) -> void:
	_remove_all_layers(update_maps)

func _resolve_terrain() -> void:
	if terrain_path != NodePath():
		var node := get_node_or_null(terrain_path)
		if node is Terrain3D:
			_terrain = node
	if _terrain == null:
		var current := get_parent()
		while current:
			if current is Terrain3D:
				_terrain = current
				break
			current = current.get_parent()
	_data = _terrain.get_data() if _terrain else null
	update_configuration_warnings()

func _update_curve_reference() -> void:
	var current_curve := curve
	if _curve == current_curve:
		return
	if _curve and _curve.changed.is_connected(_on_curve_changed):
		_curve.changed.disconnect(_on_curve_changed)
	_curve = current_curve
	if _curve:
		_curve.bake_interval = bake_interval
		_curve.changed.connect(_on_curve_changed)
	request_update(true)
	update_configuration_warnings()

func _on_curve_changed() -> void:
	request_update()

func _apply_update(force: bool) -> void:
	if _terrain == null or _data == null:
		_log("update skipped: terrain unresolved")
		return
	if _curve == null:
		_log("update skipped: curve missing")
		if force:
			_remove_all_layers(false)
		return
	var world_points := _collect_world_points()
	if world_points.size() < 2:
		_log("update skipped: insufficient curve samples (%d)" % world_points.size())
		if force:
			_remove_all_layers(false)
		return
	var region_point_map := _build_region_point_map(world_points)
	if region_point_map.is_empty():
		_log("update skipped: no regions intersect curve")
		if force:
			_remove_all_layers(false)
		return
	var changed := false
	var regions := region_point_map.keys()
	if auto_create_regions:
		for region_loc in regions:
			if _data.has_region(region_loc):
				continue
			var added := _data.add_region_blank(region_loc, true)
			if added:
				changed = true
	changed = _sync_region_layers(region_point_map) or changed
	changed = _prune_stale_regions(regions) or changed
	if changed and update_maps_on_change:
		_data.update_maps(Terrain3DRegion.TYPE_HEIGHT, false, false)

func _collect_world_points() -> PackedVector3Array:
	var result := PackedVector3Array()
	if _curve == null:
		return result
	var local_points := _curve.get_baked_points()
	if local_points.is_empty():
		var count := _curve.get_point_count()
		for i in range(count):
			local_points.append(_curve.get_point_position(i))
	for point in local_points:
		var world := to_global(point)
		if result.is_empty():
			result.append(world)
		else:
			var last := result[result.size() - 1]
			if world.distance_squared_to(last) > 1e-6:
				result.append(world)
	return result

func _build_region_point_map(world_points: PackedVector3Array) -> Dictionary:
	var map := {}
	if world_points.is_empty() or _terrain == null:
		return map
	var candidates := _collect_candidate_regions(world_points)
	for region_loc in candidates:
		var subset := _filter_points_for_region(region_loc, world_points)
		if subset.size() >= 2:
			map[region_loc] = subset
	return map

func _collect_candidate_regions(world_points: PackedVector3Array) -> Array:
	var regions: Array = []
	if world_points.is_empty() or _terrain == null:
		return regions
	var spacing := _terrain.get_vertex_spacing()
	var region_extent := float(_terrain.get_region_size()) * spacing
	if region_extent <= 0.0:
		return regions
	var pad := (width * 0.5) + feather_radius + spacing
	var min_x := INF
	var min_z := INF
	var max_x := -INF
	var max_z := -INF
	for point in world_points:
		min_x = min(min_x, point.x)
		min_z = min(min_z, point.z)
		max_x = max(max_x, point.x)
		max_z = max(max_z, point.z)
	min_x -= pad
	min_z -= pad
	max_x += pad
	max_z += pad
	var min_rx := int(floor(min_x / region_extent))
	var min_rz := int(floor(min_z / region_extent))
	var max_rx := int(floor(max_x / region_extent))
	var max_rz := int(floor(max_z / region_extent))
	for rx in range(min_rx, max_rx + 1):
		for rz in range(min_rz, max_rz + 1):
			regions.append(Vector2i(rx, rz))
	return regions

func _filter_points_for_region(region_loc: Vector2i, world_points: PackedVector3Array) -> PackedVector3Array:
	var filtered := PackedVector3Array()
	if _terrain == null:
		return filtered
	var spacing := _terrain.get_vertex_spacing()
	var region_extent := float(_terrain.get_region_size()) * spacing
	var margin := (width * 0.5) + feather_radius + spacing
	var origin := Vector3(region_loc.x, 0.0, region_loc.y) * region_extent
	var min_x := origin.x - margin
	var max_x := origin.x + region_extent + margin
	var min_z := origin.z - margin
	var max_z := origin.z + region_extent + margin
	var captured_indices: PackedInt32Array = PackedInt32Array()
	for i in range(world_points.size()):
		var point := world_points[i]
		if point.x < min_x or point.x > max_x or point.z < min_z or point.z > max_z:
			continue
		filtered.append(point)
		captured_indices.append(i)
	if filtered.size() == 1:
		var idx := captured_indices[0]
		if idx > 0:
			filtered.insert(0, world_points[idx - 1])
		elif idx < world_points.size() - 1:
			filtered.append(world_points[idx + 1])
	return filtered

func _sync_region_layers(region_point_map: Dictionary) -> bool:
	var changed := false
	for region_loc in region_point_map.keys():
		var points: PackedVector3Array = region_point_map[region_loc]
		if not _data.has_region(region_loc):
			_log("skip region %s: not loaded" % str(region_loc))
			continue
		changed = _ensure_region_layer(region_loc, points) or changed
	return changed

func _ensure_region_layer(region_loc: Vector2i, region_world_points: PackedVector3Array) -> bool:
	var info = _region_layers.get(region_loc)
	if info == null:
		return _create_region_layer(region_loc, region_world_points)
	var layer: Terrain3DCurveLayer = info.get("layer")
	if layer == null:
		_region_layers.erase(region_loc)
		return _create_region_layer(region_loc, region_world_points)
	var region := _data.get_region(region_loc)
	if region == null:
		_log("region %s missing while updating" % str(region_loc))
		return false
	if region.get_height_map() == null or region.get_height_map().get_width() <= 0:
		region.sanitize_maps()
		if region.get_height_map() == null or region.get_height_map().get_width() <= 0:
			var region_size := _terrain.get_region_size()
			if region_size <= 0:
				_log("region %s has no valid region size; skipping update" % str(region_loc))
				return false
			var height_image := Image.create(region_size, region_size, false, Image.FORMAT_RF)
			height_image.fill(Color(0.0, 0.0, 0.0, 1.0))
			region.set_height_map(height_image)
			region.mark_layers_dirty(Terrain3DRegion.TYPE_HEIGHT)
	var local_points := _make_local_points(region_loc, region_world_points)
	if local_points.size() < 2:
		_log("region %s update skipped: insufficient local samples" % str(region_loc))
		return false
	layer.set_points(local_points)
	layer.set_width(width)
	layer.set_depth(depth)
	layer.set_dual_groove(dual_groove)
	layer.set_falloff_curve(falloff_curve)
	layer.set_feather_radius(feather_radius)
	layer.mark_dirty()
	if region:
		region.mark_layers_dirty(Terrain3DRegion.TYPE_HEIGHT, true)
	var index := _find_layer_index(region_loc, layer)
	if index >= 0:
		info["index"] = index
	if debug_logging:
		var payload := layer.get_payload()
		var payload_size := payload.get_size() if payload else Vector2i.ZERO
		_log("updated layer %s idx=%d coverage=%s payload=%s points=%d" % [str(region_loc), index, str(layer.get_coverage()), str(payload_size), region_world_points.size()])
	return true

func _create_region_layer(region_loc: Vector2i, region_world_points: PackedVector3Array) -> bool:
	var subset := region_world_points
	if subset.size() < 2:
		return false
	var region := _data.get_region(region_loc)
	if region:
		if region.get_height_map() == null or region.get_height_map().get_width() <= 0:
			region.sanitize_maps()
			if region.get_height_map() == null or region.get_height_map().get_width() <= 0:
				var region_size := _terrain.get_region_size()
				if region_size <= 0:
					_log("region %s has no valid region size; cannot create curve layer" % str(region_loc))
					return false
				var height_image := Image.create(region_size, region_size, false, Image.FORMAT_RF)
				height_image.fill(Color(0.0, 0.0, 0.0, 1.0))
				region.set_height_map(height_image)
				region.mark_layers_dirty(Terrain3DRegion.TYPE_HEIGHT)
	var layer := _data.add_curve_layer(region_loc, subset, width, depth, dual_groove, feather_radius, false)
	if layer == null:
		_log("failed to add curve layer in region %s" % str(region_loc))
		return false
	layer.set_falloff_curve(falloff_curve)
	var index := _find_layer_index(region_loc, layer)
	_region_layers[region_loc] = {"layer": layer, "index": index}
	_log("added curve layer in region %s (index=%d)" % [str(region_loc), index])
	if region:
		region.mark_layers_dirty(Terrain3DRegion.TYPE_HEIGHT, true)
	if debug_logging:
		var payload := layer.get_payload()
		var payload_size := payload.get_size() if payload else Vector2i.ZERO
		_log("created layer %s idx=%d coverage=%s payload=%s points=%d" % [str(region_loc), index, str(layer.get_coverage()), str(payload_size), subset.size()])
	return true

func _make_local_points(region_loc: Vector2i, world_points: PackedVector3Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	if world_points.is_empty() or _terrain == null:
		return result
	var spacing := _terrain.get_vertex_spacing()
	var origin := Vector3(region_loc.x, 0.0, region_loc.y) * float(_terrain.get_region_size()) * spacing
	var region_extent := float(_terrain.get_region_size()) * spacing
	var margin := (width * 0.5) + feather_radius + spacing
	for point in world_points:
		var local := point - origin
		if abs(local.x) > region_extent + margin or abs(local.z) > region_extent + margin:
			continue
		result.append(local)
	return result

func _prune_stale_regions(active_regions: Array) -> bool:
	var active := {}
	for region_loc in active_regions:
		active[region_loc] = true
	var changed := false
	for region_loc in _region_layers.keys():
		if active.has(region_loc):
			continue
		changed = _remove_region_layer(region_loc) or changed
	return changed

func _remove_region_layer(region_loc: Vector2i) -> bool:
	var info = _region_layers.get(region_loc)
	if info == null:
		return false
	var layer: Terrain3DCurveLayer = info.get("layer")
	var index := int(info.get("index", -1))
	if layer:
		index = _find_layer_index(region_loc, layer)
	if index >= 0 and _data.has_region(region_loc):
		_data.remove_layer(region_loc, Terrain3DRegion.TYPE_HEIGHT, index, false)
	_region_layers.erase(region_loc)
	_log("removed curve layer from region %s" % str(region_loc))
	return index >= 0

func _remove_all_layers(update_maps: bool) -> void:
	var removed := false
	for region_loc in _region_layers.keys():
		removed = _remove_region_layer(region_loc) or removed
	_region_layers.clear()
	if removed and update_maps and _data:
		_data.update_maps(Terrain3DRegion.TYPE_HEIGHT, false, false)

func _find_layer_index(region_loc: Vector2i, target: Terrain3DCurveLayer) -> int:
	if target == null or _data == null:
		return -1
	var region := _data.get_region(region_loc)
	if region == null:
		return -1
	var layers: Array = region.get_layers(Terrain3DRegion.TYPE_HEIGHT)
	for i in range(layers.size()):
		if layers[i] == target:
			return i
	return -1

func _log(message: String) -> void:
	if not debug_logging:
		return
	print("[Terrain3DCurveLayerPath:%s] %s" % [str(get_instance_id()), message])

func _get_configuration_warning() -> String:
	var warnings := PackedStringArray()
	if _terrain == null:
		warnings.append("Terrain3D node not resolved.")
	if _curve == null:
		warnings.append("Assign or create a Curve3D for this path.")
	elif _curve.get_point_count() < 2 and _curve.get_baked_points().size() < 2:
		warnings.append("Curve needs at least two points.")
	return "\n".join(warnings)