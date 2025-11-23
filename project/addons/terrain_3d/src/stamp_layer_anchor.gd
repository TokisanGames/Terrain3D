@tool
extends Node3D

## Rebuilds an arbitrary-sized Terrain3D stamp across every region it overlaps.
class_name Terrain3DStampAnchor

@export_node_path("Node") var terrain_path: NodePath
@export_enum("Height:0", "Control:1", "Color:2") var map_type: int = Terrain3DRegion.TYPE_HEIGHT
@export var layer_index: int = 0
@export var target_region: Vector2i = Vector2i.ZERO
@export var auto_region := true ## When true the source layer is resolved from the anchor position.
@export var auto_layer_search := true ## Falls back to the first stamp layer in the region when the requested index is not a stamp.
@export var auto_create_regions := true ## Create regions on-demand when the stamp spills outside loaded tiles.
@export var align_to_terrain := true
@export var height_offset := 0.0
@export var update_in_editor := true
@export var update_in_game := true
@export_range(0.0, 5.0, 0.01) var min_move_distance := 0.05
@export var debug_logging := false

var _terrain: Terrain3D
var _data: Terrain3DData
var _template_ready := false
var _template_payload: Image
var _template_alpha: Image
var _template_size := Vector2i.ZERO
var _template_intensity := 1.0
var _template_feather_radius := 0.0
var _template_blend_mode := Terrain3DLayer.BLEND_ADD
var _active_layers := {} ## Dict[Vector2i] = Ref<Terrain3DStampLayer>
var _last_position := Vector3.INF

func _log(message: String) -> void:
	if not debug_logging:
		return
	print("[Terrain3DStampAnchor:%s] %s" % [str(get_instance_id()), message])

func _ready() -> void:
	_resolve_terrain()
	_last_position = Vector3.INF
	set_process(true)

func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		if not update_in_editor:
			return
	else:
		if not update_in_game:
			return
	_update_anchor()

func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		_resolve_terrain()
	elif what == NOTIFICATION_TRANSFORM_CHANGED:
		if Engine.is_editor_hint() and update_in_editor:
			force_update()
	elif what == NOTIFICATION_EXIT_TREE:
		_clear_active_layers(true)

func set_terrain_node(terrain: Terrain3D) -> void:
	_terrain = terrain
	_data = _terrain.get_data() if _terrain else null
	_reset_template()
	_log("set_terrain_node: terrain=%s" % [(_terrain and _terrain.get_path()) if _terrain else "<none>"])

func set_target_layer(region_loc: Vector2i, map_type_in: int, index: int, layer_ref: Terrain3DLayer = null) -> void:
	_resolve_terrain()
	var resolved_region := region_loc
	var resolved_map_type := map_type_in
	var resolved_index := index
	if layer_ref and layer_ref is Terrain3DStampLayer:
		resolved_map_type = layer_ref.get_map_type()
		if _data:
			var owner_info := _data.get_layer_owner_info(layer_ref, resolved_map_type)
			if owner_info.has("region_location"):
				resolved_region = owner_info.get("region_location", resolved_region)
			if owner_info.has("index"):
				resolved_index = int(owner_info.get("index", resolved_index))
		else:
			_log("set_target_layer: data unavailable when assigning from layer ref")
	elif layer_ref:
		_log("set_target_layer: provided layer is not a Terrain3DStampLayer")
	resolved_index = max(resolved_index, -1)
	target_region = resolved_region
	map_type = resolved_map_type
	layer_index = resolved_index
	_reset_template()
	_log("set_target_layer: region=%s map_type=%d index=%d layer_ref=%s" % [str(target_region), map_type, layer_index, str(layer_ref)])

func force_update() -> void:
	_last_position = Vector3.INF
	_update_anchor(true)

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

func _update_anchor(force: bool = false) -> void:
	if not _ensure_template(force):
		_log("update_anchor: template unresolved")
		return
	var world_pos := _compute_world_position()
	if _last_position != Vector3.INF and not force and world_pos.distance_to(_last_position) < min_move_distance:
		_log("update_anchor: movement below threshold (delta=%s)" % [str(world_pos.distance_to(_last_position))])
		return
	var global_rect := _make_global_rect(world_pos)
	if not global_rect.has_area():
		_log("update_anchor: computed coverage has no area")
		return
	if _deploy_stamp(global_rect):
		_last_position = world_pos
		if align_to_terrain and not Engine.is_editor_hint():
			global_position.y = world_pos.y
		_log("update_anchor: stamp refreshed @ %s covering %s" % [str(world_pos), str(global_rect)])

func _ensure_template(force_region: bool) -> bool:
	if _template_ready:
		return true
	var source := _resolve_source_layer(force_region)
	if source == null:
		return false
	var payload := source.get_payload()
	if payload == null:
		_log("ensure_template: source payload missing")
		return false
	_template_payload = payload.duplicate()
	if _template_payload == null:
		_log("ensure_template: failed to duplicate payload image")
		return false
	var alpha := source.get_alpha()
	_template_alpha = alpha.duplicate() if alpha else null
	_template_size = _template_payload.get_size()
	if _template_size.x <= 0 or _template_size.y <= 0:
		_log("ensure_template: payload has invalid dimensions %s" % [str(_template_size)])
		_template_payload = null
		_template_alpha = null
		return false
	_template_intensity = source.get_intensity()
	_template_feather_radius = source.get_feather_radius()
	_template_blend_mode = source.get_blend_mode()
	map_type = source.get_map_type()
	_template_ready = true
	if _data:
		_data.remove_layer(target_region, map_type, layer_index, true)
	_clear_active_layers(true)
	_log("ensure_template: captured payload %s (map_type=%d)" % [str(_template_size), map_type])
	return true

func _resolve_source_layer(force_region: bool) -> Terrain3DStampLayer:
	if _terrain == null:
		_resolve_terrain()
	if _data == null:
		return null
	if auto_region or force_region:
		target_region = _data.get_region_location(global_transform.origin)
		_log("resolve_source_layer: auto target region=%s" % [str(target_region)])
	var region: Terrain3DRegion = _data.get_region(target_region)
	if region == null:
		_log("resolve_source_layer: region %s missing" % [str(target_region)])
		return null
	var layers: Array = region.get_layers(map_type)
	if layer_index >= 0 and layer_index < layers.size():
		var candidate: Terrain3DLayer = layers[layer_index]
		if candidate is Terrain3DStampLayer:
			_log("resolve_source_layer: using indexed layer %d" % layer_index)
			return candidate
	if not auto_layer_search:
		_log("resolve_source_layer: indexed layer not stamp and search disabled")
		return null
	for i in range(layers.size()):
		var fallback: Terrain3DLayer = layers[i]
		if fallback is Terrain3DStampLayer:
			layer_index = i
			_log("resolve_source_layer: switched to fallback layer %d" % layer_index)
			return fallback
	_log("resolve_source_layer: no stamp layers available in %s" % [str(target_region)])
	return null

func _compute_world_position() -> Vector3:
	var world_pos := global_transform.origin
	if align_to_terrain and _data:
		var ground := _data.get_height(world_pos)
		if is_finite(ground):
			world_pos.y = ground + height_offset
	else:
		world_pos.y += height_offset
	return world_pos

func _make_global_rect(world_pos: Vector3) -> Rect2i:
	if _terrain == null or _template_size == Vector2i.ZERO:
		return Rect2i()
	var spacing := _terrain.get_vertex_spacing()
	if spacing <= 0.0:
		return Rect2i()
	var grid := Vector2(world_pos.x, world_pos.z) / spacing
	var half := Vector2(_template_size.x, _template_size.y) * 0.5
	var origin := Vector2(grid.x - half.x, grid.y - half.y)
	var top_left := Vector2i(int(round(origin.x)), int(round(origin.y)))
	return Rect2i(top_left, _template_size)

func _deploy_stamp(global_rect: Rect2i) -> bool:
	if _data == null or _terrain == null or _template_payload == null:
		return false
	var slices := _compute_stamp_slices(global_rect)
	if slices.is_empty():
		_log("deploy_stamp: coverage %s produced no slices" % [str(global_rect)])
		return false
	var touched := {}
	var changed := false
	for slice in slices:
		var region_loc: Vector2i = slice.get("region_location", Vector2i.ZERO)
		var coverage: Rect2i = slice.get("coverage", Rect2i())
		if not coverage.has_area():
			continue
		var payload_rect: Rect2i = slice.get("payload_rect", Rect2i())
		if not payload_rect.has_area():
			continue
		var payload_bundle := _build_slice_payload(payload_rect, coverage)
		var payload: Image = payload_bundle.get("payload")
		if payload == null or payload.get_width() <= 0 or payload.get_height() <= 0:
			_log("deploy_stamp: failed to bake payload for region %s coverage %s" % [str(region_loc), str(coverage)])
			continue
		var alpha: Image = payload_bundle.get("alpha")
		if not _ensure_region_available(region_loc):
			_log("deploy_stamp: region %s unavailable and auto create disabled" % [str(region_loc)])
			continue
		var layer: Terrain3DStampLayer = _active_layers.get(region_loc)
		if layer and is_instance_valid(layer):
			_update_slice_layer(layer, payload, alpha, coverage)
		else:
			layer = _create_slice_layer(region_loc, payload, alpha, coverage)
			if layer:
				_active_layers[region_loc] = layer
		if layer:
			touched[region_loc] = true
			changed = true
	var removed := _prune_inactive_layers(touched)
	if changed or removed:
		_data.update_maps(map_type, false, false)
	return not _active_layers.is_empty()

func _clear_active_layers(update_maps: bool) -> void:
	if _active_layers.is_empty() or _data == null:
		_active_layers.clear()
		return
	var removed := false
	var keys := _active_layers.keys()
	for region_loc in keys:
		if _remove_region_entry(region_loc, false):
			removed = true
	if removed and update_maps:
		_data.update_maps(map_type, false, false)
	_active_layers.clear()

func _reset_template() -> void:
	_clear_active_layers(true)
	_template_ready = false
	_template_payload = null
	_template_alpha = null
	_template_size = Vector2i.ZERO
	_active_layers.clear()

func _build_slice_payload(payload_rect: Rect2i, coverage: Rect2i) -> Dictionary:
	var result := {}
	if _template_payload == null or not payload_rect.has_area() or not coverage.has_area():
		return result
	var template_bounds := Rect2i(Vector2i.ZERO, _template_size)
	if not template_bounds.encloses(payload_rect):
		_log("build_slice_payload: payload rect %s exceeds template bounds %s" % [str(payload_rect), str(template_bounds)])
		return result
	var src_rect := Rect2i(payload_rect.position, coverage.size)
	var payload := _template_payload.get_region(src_rect)
	if payload == null or payload.is_empty():
		_log("build_slice_payload: failed to carve payload for rect %s" % [str(src_rect)])
		return result
	result["payload"] = payload
	if _template_alpha and _template_alpha.get_width() == _template_size.x and _template_alpha.get_height() == _template_size.y:
		var alpha := _template_alpha.get_region(src_rect)
		if alpha and not alpha.is_empty():
			result["alpha"] = alpha
	return result

func _compute_stamp_slices(global_rect: Rect2i) -> Array:
	var slices: Array = []
	if not global_rect.has_area() or _terrain == null:
		return slices
	var region_size := int(_terrain.get_region_size())
	if region_size <= 0:
		return slices
	var coverage_end := global_rect.position + global_rect.size - Vector2i.ONE
	var min_region_x := _floor_div_int(global_rect.position.x, region_size)
	var min_region_y := _floor_div_int(global_rect.position.y, region_size)
	var max_region_x := _floor_div_int(coverage_end.x, region_size)
	var max_region_y := _floor_div_int(coverage_end.y, region_size)
	for region_y in range(min_region_y, max_region_y + 1):
		for region_x in range(min_region_x, max_region_x + 1):
			var region_loc := Vector2i(region_x, region_y)
			var region_bounds := Rect2i(region_loc * region_size, Vector2i(region_size, region_size))
			var slice_global := region_bounds.intersection(global_rect)
			if not slice_global.has_area():
				continue
			var coverage := Rect2i(slice_global.position - region_bounds.position, slice_global.size)
			var payload_rect := Rect2i(slice_global.position - global_rect.position, slice_global.size)
			slices.append({
				"region_location": region_loc,
				"coverage": coverage,
				"payload_rect": payload_rect
			})
	return slices

func _floor_div_int(value: int, divisor: int) -> int:
	if divisor == 0:
		return 0
	var result := value / divisor
	result = int(result)
	var remainder := value % divisor
	if remainder != 0 and ((remainder < 0) != (divisor < 0)):
		result -= 1
	return result

func _ensure_region_available(region_loc: Vector2i) -> bool:
	if _data == null:
		return false
	if _data.has_region(region_loc):
		return true
	if not auto_create_regions:
		return false
	var added: Terrain3DRegion = _data.add_region_blank(region_loc, false)
	return added != null

func _create_slice_layer(region_loc: Vector2i, payload: Image, alpha: Image, coverage: Rect2i) -> Terrain3DStampLayer:
	if payload == null or not coverage.has_area():
		return null
	var layer := _data.add_stamp_layer(region_loc, map_type, payload, coverage, alpha, _template_intensity, _template_feather_radius, _template_blend_mode, -1, false)
	return layer if layer is Terrain3DStampLayer else null

func _update_slice_layer(layer: Terrain3DStampLayer, payload: Image, alpha: Image, coverage: Rect2i) -> void:
	if payload:
		layer.set_payload(payload)
	if alpha or layer.get_alpha():
		layer.set_alpha(alpha)
	layer.set_intensity(_template_intensity)
	layer.set_feather_radius(_template_feather_radius)
	layer.set_blend_mode(_template_blend_mode)
	layer.set_coverage(coverage)
	layer.mark_dirty()
	var info := _data.get_layer_owner_info(layer, map_type)
	var region_loc: Vector2i = info.get("region_location", Vector2i.ZERO)
	var index := int(info.get("index", -1))
	if index >= 0:
		_data.set_layer_coverage(region_loc, map_type, index, coverage, false)

func _prune_inactive_layers(touched: Dictionary) -> bool:
	var removed := false
	var stale := []
	for region_loc in _active_layers.keys():
		if not touched.has(region_loc):
			stale.append(region_loc)
	for region_loc in stale:
		if _remove_region_entry(region_loc, false):
			removed = true
	return removed

func _remove_region_entry(region_loc: Vector2i, update_maps: bool) -> bool:
	var layer: Terrain3DStampLayer = _active_layers.get(region_loc)
	if layer == null or _data == null:
		_active_layers.erase(region_loc)
		return false
	var info := _data.get_layer_owner_info(layer, map_type)
	var index := int(info.get("index", -1))
	if index < 0:
		_active_layers.erase(region_loc)
		return false
	_data.remove_layer(region_loc, map_type, index, update_maps)
	_active_layers.erase(region_loc)
	return true
