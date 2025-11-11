@tool
extends Node3D

## Keeps a Terrain3D stamp layer aligned with this node's position.
class_name Terrain3DStampAnchor

@export_node_path("Node") var terrain_path: NodePath
@export_enum("Height:0", "Control:1", "Color:2") var map_type: int = Terrain3DRegion.TYPE_HEIGHT
@export var layer_index: int = 0
@export var target_region: Vector2i = Vector2i.ZERO
@export var auto_region := true
@export var auto_layer_search := true
@export var align_to_terrain := true
@export var height_offset := 0.0
@export var update_in_editor := true
@export var update_in_game := true
@export_range(0.0, 5.0, 0.01) var min_move_distance := 0.05
@export var auto_shrink_coverage := true
@export_range(0, 32, 1) var shrink_padding_pixels := 2
@export_range(0.0, 1.0, 0.001) var shrink_threshold := 0.002
@export var debug_logging := false

var _terrain: Terrain3D
var _data: Terrain3DData
var _stamp_layer: Terrain3DStampLayer
var _last_position := Vector3.INF
var _coverage_trimmed := false

func _log(message: String) -> void:
	if not debug_logging:
		return
	print("[Terrain3DStampAnchor:%s] %s" % [str(get_instance_id()), message])

func _ready() -> void:
	_resolve_terrain()
	_log("ready: terrain=%s" % [(_terrain and _terrain.get_path()) if _terrain else "<none>"])
	_ensure_layer(true)
	_last_position = global_transform.origin
	set_process(true)

func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		if not update_in_editor:
			return
	else:
		if not update_in_game:
			return
	_update_layer()

func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		_resolve_terrain()
	elif what == NOTIFICATION_TRANSFORM_CHANGED:
		if Engine.is_editor_hint() and update_in_editor:
			_update_layer(true)

func set_terrain_node(terrain: Terrain3D) -> void:
	_terrain = terrain
	_data = _terrain.get_data() if _terrain else null
	_stamp_layer = null
	_log("set_terrain_node: terrain=%s" % [(_terrain and _terrain.get_path()) if _terrain else "<none>"])

func set_target_layer(region_loc: Vector2i, map_type_in: int, index: int, layer: Terrain3DStampLayer = null) -> void:
	target_region = region_loc
	map_type = map_type_in
	layer_index = index
	if layer:
		_stamp_layer = layer
	_coverage_trimmed = false
	_log("set_target_layer: region=%s map_type=%d index=%d layer=%s" % [str(target_region), map_type, layer_index, str(_stamp_layer)])

func force_update() -> void:
	_last_position = Vector3.INF
	_coverage_trimmed = false
	_update_layer(true)

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
	_log("resolve_terrain: terrain=%s data=%s" % [(_terrain and _terrain.get_path()) if _terrain else "<none>", str(_data)])

func _ensure_layer(force_region: bool = false) -> bool:
	if _terrain == null:
		_log("ensure_layer: terrain missing, attempting resolve")
		_resolve_terrain()
	if _terrain == null:
		_log("ensure_layer: terrain unresolved")
		return false
	if _data == null:
		_data = _terrain.get_data()
	if _data == null:
		_log("ensure_layer: terrain data missing")
		return false
	if auto_region or force_region:
		target_region = _data.get_region_location(global_transform.origin)
		_log("ensure_layer: target_region updated to %s" % [str(target_region)])
	var region: Terrain3DRegion = _data.get_region(target_region)
	if region == null:
		_log("ensure_layer: region %s not loaded" % [str(target_region)])
		_stamp_layer = null
		return false
	var layers: Array = region.get_layers(map_type)
	if layer_index >= 0 and layer_index < layers.size():
		var candidate: Terrain3DLayer = layers[layer_index]
		if candidate is Terrain3DStampLayer:
			_stamp_layer = candidate
			_coverage_trimmed = false
			_log("ensure_layer: using indexed layer %d" % layer_index)
			return true
	if not auto_layer_search:
		_log("ensure_layer: indexed layer not a stamp and auto search disabled")
		_stamp_layer = null
		return false
	for i in range(layers.size()):
		var fallback: Terrain3DLayer = layers[i]
		if fallback is Terrain3DStampLayer:
			_stamp_layer = fallback
			layer_index = i
			_coverage_trimmed = false
			_log("ensure_layer: switched to fallback layer %d" % layer_index)
			return true
	_log("ensure_layer: no stamp layer available in region %s" % [str(target_region)])
	_stamp_layer = null
	return false

func _update_layer(force: bool = false) -> void:
	if not _ensure_layer(force):
		_log("update_layer: unable to resolve stamp layer (force=%s)" % [str(force)])
		return
	if auto_shrink_coverage:
		_maybe_shrink_coverage(force)
	var world_pos := global_transform.origin
	if align_to_terrain and _data:
		var ground := _data.get_height(world_pos)
		if is_finite(ground):
			world_pos.y = ground + height_offset
	else:
		world_pos.y += height_offset
	if _last_position != Vector3.INF and not force and world_pos.distance_to(_last_position) < min_move_distance:
		_log("update_layer: movement below threshold (delta=%s)" % [str(world_pos.distance_to(_last_position))])
		return
	_log("update_layer: requesting move to %s" % [str(world_pos)])
	if _data.move_stamp_layer(_stamp_layer, world_pos, true):
		_last_position = world_pos
		if not Engine.is_editor_hint() and align_to_terrain:
			global_position.y = world_pos.y
		if auto_region:
			target_region = _data.get_region_location(world_pos)
		if auto_region or auto_layer_search:
			_ensure_layer()
		_log("update_layer: move succeeded (region=%s coverage=%s)" % [str(target_region), str(_stamp_layer.get_coverage())])
	else:
		_log("update_layer: move rejected by Terrain3DData")

func _maybe_shrink_coverage(force: bool) -> void:
	if _stamp_layer == null or _data == null or _terrain == null:
		_log("maybe_shrink_coverage: missing required references")
		return
	if not force and _coverage_trimmed:
		_log("maybe_shrink_coverage: already trimmed")
		return
	var coverage := _stamp_layer.get_coverage()
	var target_size := _terrain.get_region_size()
	if not force and coverage.size.x < target_size and coverage.size.y < target_size:
		_log("maybe_shrink_coverage: current coverage already smaller than region")
		_coverage_trimmed = true
		return
	if _shrink_layer_to_payload():
		_coverage_trimmed = true
		_log("maybe_shrink_coverage: coverage trimmed to %s" % [str(_stamp_layer.get_coverage())])
		_recenter_to_layer()
		_last_position = Vector3.INF
	else:
		_log("maybe_shrink_coverage: shrink attempt skipped")

func _shrink_layer_to_payload() -> bool:
	var payload := _stamp_layer.get_payload()
	if payload == null:
		_log("shrink_layer_to_payload: payload missing")
		return false
	var alpha := _stamp_layer.get_alpha()
	var bounds := _calculate_payload_bounds(payload, alpha)
	if not bounds.has_area():
		_log("shrink_layer_to_payload: bounds have no area")
		return false
	var padded := _apply_padding(bounds, payload.get_size())
	if not padded.has_area():
		_log("shrink_layer_to_payload: padded bounds invalid")
		return false
	var coverage := _stamp_layer.get_coverage()
	var new_coverage := Rect2i(coverage.position + padded.position, padded.size)
	if coverage == new_coverage:
		_log("shrink_layer_to_payload: coverage unchanged")
		return false
	_log("shrink_layer_to_payload: old=%s padded=%s new=%s" % [str(coverage), str(padded), str(new_coverage)])
	var new_payload := Image.create(padded.size.x, padded.size.y, false, payload.get_format())
	new_payload.blit_rect(payload, Rect2i(padded.position, padded.size), Vector2i.ZERO)
	_stamp_layer.set_payload(new_payload)
	if alpha:
		var new_alpha := Image.create(padded.size.x, padded.size.y, false, alpha.get_format())
		new_alpha.blit_rect(alpha, Rect2i(padded.position, padded.size), Vector2i.ZERO)
		_stamp_layer.set_alpha(new_alpha)
	if _data.set_layer_coverage(target_region, map_type, layer_index, new_coverage, true):
		_stamp_layer.mark_dirty()
		return true
	_stamp_layer.set_coverage(new_coverage)
	_stamp_layer.mark_dirty()
	return true

func _calculate_payload_bounds(payload: Image, alpha: Image) -> Rect2i:
	var size := payload.get_size()
	if size.x <= 0 or size.y <= 0:
		return Rect2i()
	var min_x := size.x
	var min_y := size.y
	var max_x := -1
	var max_y := -1
	for y in range(size.y):
		for x in range(size.x):
			var weight := 0.0
			if alpha:
				weight = alpha.get_pixel(x, y).r
			else:
				var color := payload.get_pixel(x, y)
				match map_type:
					Terrain3DRegion.TYPE_HEIGHT, Terrain3DRegion.TYPE_CONTROL:
						weight = abs(color.r)
					Terrain3DRegion.TYPE_COLOR:
						weight = max(color.a, abs(color.r), abs(color.g), abs(color.b))
					_:
						weight = abs(color.r)
			if weight > shrink_threshold:
				if x < min_x:
					min_x = x
				if x > max_x:
					max_x = x
				if y < min_y:
					min_y = y
				if y > max_y:
					max_y = y
	if max_x < min_x or max_y < min_y:
		return Rect2i()
	var rect_pos := Vector2i(min_x, min_y)
	var rect_size := Vector2i(max_x - min_x + 1, max_y - min_y + 1)
	return Rect2i(rect_pos, rect_size)

func _apply_padding(bounds: Rect2i, payload_size: Vector2i) -> Rect2i:
	var padded := bounds
	if shrink_padding_pixels > 0:
		var pad := shrink_padding_pixels
		var start := padded.position - Vector2i(pad, pad)
		var end := padded.position + padded.size + Vector2i(pad, pad)
		start.x = clampi(start.x, 0, max(payload_size.x - 1, 0))
		start.y = clampi(start.y, 0, max(payload_size.y - 1, 0))
		end.x = clampi(end.x, 1, payload_size.x)
		end.y = clampi(end.y, 1, payload_size.y)
		padded.position = start
		padded.size = end - start
	return padded

func _recenter_to_layer() -> void:
	if _terrain == null or _stamp_layer == null:
		_log("recenter_to_layer: missing references")
		return
	var coverage := _stamp_layer.get_coverage()
	if not coverage.has_area():
		_log("recenter_to_layer: coverage empty")
		return
	var spacing := _terrain.get_vertex_spacing()
	var region_world := Vector3(target_region.x, 0.0, target_region.y) * float(_terrain.get_region_size()) * spacing
	var center := Vector2(coverage.position.x, coverage.position.y) + Vector2(coverage.size.x, coverage.size.y) * 0.5
	var world := region_world + Vector3(center.x * spacing, 0.0, center.y * spacing)
	if align_to_terrain and _data:
		var ground := _data.get_height(world)
		if is_finite(ground):
			world.y = ground + height_offset
	global_position = world
	_log("recenter_to_layer: anchor moved to %s" % [str(world)])
