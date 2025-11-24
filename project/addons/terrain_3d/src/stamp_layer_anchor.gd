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
@export var allow_claimed_sources := false ## When true this anchor may retarget layers already controlled by another anchor.
@export var anchor_id: String = "" : set = _set_anchor_id
@export var claimed_group_id: int = 0 : set = _set_claimed_group_id
@export_multiline var source_summary: String = "" : set = _set_source_summary

const MAP_UPDATE_THROTTLE_MS := 33
const META_ANCHOR_ID := &"terrain3d_stamp_anchor_id"
static var _group_claims := {}

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
var _preferred_layer: Terrain3DStampLayer
var _template_group_id := 0
var _map_update_dirty := false
var _pending_full_map_rebuild := false
var _next_map_update_msec := 0
var _map_update_timer: SceneTreeTimer
var _claimed_group_ref: int = 0

func _set_anchor_id(value: String) -> void:
	anchor_id = value
	_retag_active_layers()

func _set_claimed_group_id(value: int) -> void:
	claimed_group_id = value

func _set_source_summary(value: String) -> void:
	source_summary = value

func _ensure_anchor_id() -> void:
	if anchor_id.strip_edges() == "":
		anchor_id = _generate_anchor_id()

func _generate_anchor_id() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return "stamp-%08x%08x" % [rng.randi(), rng.randi()]

static func _prune_group_claims() -> void:
	var stale := []
	for group_id in _group_claims.keys():
		var ref: WeakRef = _group_claims[group_id]
		if ref.get_ref() == null:
			stale.append(group_id)
	for group_id in stale:
		_group_claims.erase(group_id)

func _claim_group_id(group_id: int) -> void:
	if group_id == 0:
		return
	_prune_group_claims()
	_group_claims[group_id] = weakref(self)
	_claimed_group_ref = group_id
	_set_claimed_group_id(group_id)

func _release_group_claim(group_id: int = -1) -> void:
	var target_id := group_id if group_id > 0 else _claimed_group_ref
	if target_id == 0:
		return
	if _group_claims.has(target_id):
		var owner: WeakRef = _group_claims[target_id]
		if owner.get_ref() == self or owner.get_ref() == null:
			_group_claims.erase(target_id)
	if target_id == _claimed_group_ref or group_id <= 0:
		_claimed_group_ref = 0
	_set_claimed_group_id(_claimed_group_ref)

func _is_group_claimed_by_other(group_id: int) -> bool:
	if group_id == 0:
		return false
	_prune_group_claims()
	if not _group_claims.has(group_id):
		return false
	var owner: Object = _group_claims[group_id].get_ref()
	return owner != null and owner != self

func _tag_layer_anchor(layer: Terrain3DLayer) -> void:
	if layer == null:
		return
	if anchor_id.strip_edges() == "":
		return
	layer.set_meta(META_ANCHOR_ID, anchor_id)

func _retag_active_layers() -> void:
	for region_loc in _active_layers.keys():
		var layer: Terrain3DStampLayer = _active_layers[region_loc]
		if layer and is_instance_valid(layer):
			_tag_layer_anchor(layer)

func _is_layer_claimed_by_other(layer: Terrain3DLayer) -> bool:
	if layer == null:
		return false
	if allow_claimed_sources:
		return false
	var stored_id := ""
	if layer.has_meta(META_ANCHOR_ID):
		stored_id = str(layer.get_meta(META_ANCHOR_ID, ""))
	if stored_id != "" and stored_id != anchor_id:
		return true
	return _is_group_claimed_by_other(int(layer.get_group_id()))

func _get_map_type_name(type_value: int) -> String:
	match type_value:
		Terrain3DRegion.TYPE_HEIGHT:
			return "Height"
		Terrain3DRegion.TYPE_CONTROL:
			return "Control"
		Terrain3DRegion.TYPE_COLOR:
			return "Color"
		_:
			return "Unknown"

func _describe_layer_source(layer: Terrain3DLayer) -> String:
	if layer == null or _data == null:
		return "Unassigned"
	var info := _data.get_layer_owner_info(layer, layer.get_map_type())
	var region_loc: Vector2i = info.get("region_location", target_region)
	var idx := int(info.get("index", layer_index))
	var group_id := int(layer.get_group_id())
	return "%s layer #%d (group %d) in region %s" % [_get_map_type_name(layer.get_map_type()), idx, group_id, str(region_loc)]

func _log(message: String) -> void:
	if not debug_logging:
		return
	print("[Terrain3DStampAnchor:%s] %s" % [str(get_instance_id()), message])

func _ready() -> void:
	_ensure_anchor_id()
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
		_release_group_claim()
		_clear_active_layers(true)
		_flush_map_update()

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
	_preferred_layer = layer_ref if (layer_ref is Terrain3DStampLayer) else null
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
		_log("ensure_template: unable to resolve source layer")
		return false
	var captured := false
	if _data:
		var group_id := _data.ensure_layer_group_id(source)
		if group_id != 0:
			captured = _capture_group_template(source, group_id)
	if not captured:
		captured = _capture_single_layer_template(source)
	if captured:
		_preferred_layer = null
		_clear_active_layers(true)
		_claim_group_id(_template_group_id)
		_set_source_summary(_describe_layer_source(source))
		_log("ensure_template: captured payload %s (map_type=%d)" % [str(_template_size), map_type])
	else:
		_log("ensure_template: failed to capture payload for layer %s" % [str(source)])
	return captured

func _capture_single_layer_template(source: Terrain3DStampLayer) -> bool:
	if source == null:
		return false
	var payload := source.get_payload()
	if payload == null or payload.is_empty():
		_log("capture_single_layer_template: source payload missing")
		return false
	var duplicate := payload.duplicate()
	if duplicate == null or duplicate.is_empty():
		_log("capture_single_layer_template: failed to duplicate payload image")
		return false
	var alpha := source.get_alpha()
	var alpha_copy := alpha.duplicate() if alpha else null
	_template_payload = duplicate
	_template_alpha = alpha_copy
	_template_size = _template_payload.get_size()
	if _template_size.x <= 0 or _template_size.y <= 0:
		_log("capture_single_layer_template: payload has invalid dimensions %s" % [str(_template_size)])
		_template_payload = null
		_template_alpha = null
		return false
	_template_intensity = source.get_intensity()
	_template_feather_radius = source.get_feather_radius()
	_template_blend_mode = source.get_blend_mode()
	map_type = source.get_map_type()
	_template_ready = true
	if _data:
		_template_group_id = _data.ensure_layer_group_id(source)
	else:
		_template_group_id = source.get_group_id()
	if _data and layer_index >= 0:
		_data.remove_layer(target_region, map_type, layer_index, true)
	return true

func _capture_group_template(source: Terrain3DStampLayer, group_id: int) -> bool:
	if source == null or group_id == 0:
		return false
	if _terrain == null or _data == null:
		return false
	var map_type_local := source.get_map_type()
	var slices := _get_group_slices(map_type_local, group_id)
	if slices.is_empty():
		return false
	if not _bake_group_template_images(slices, source):
		return false
	_remove_group_layers(slices, map_type_local)
	_template_group_id = group_id
	return true

func _get_group_slices(map_type_in: int, group_id: int) -> Array:
	if _data == null or group_id == 0:
		return []
	var groups: Array = _data.get_layer_groups(map_type_in) if _data.has_method("get_layer_groups") else []
	for group_dict in groups:
		if int(group_dict.get("group_id", 0)) == group_id:
			return group_dict.get("layers", [])
	return []

func _bake_group_template_images(slices: Array, source: Terrain3DStampLayer) -> bool:
	var region_size := int(_terrain.get_region_size()) if _terrain else 0
	if region_size <= 0:
		_log("capture_group_template: invalid region size")
		return false
	var prepared: Array = []
	var min_point := Vector2i(1_000_000_000, 1_000_000_000)
	var max_point := Vector2i(-1_000_000_000, -1_000_000_000)
	for slice in slices:
		var layer: Terrain3DLayer = slice.get("layer")
		if layer == null or not (layer is Terrain3DStampLayer):
			continue
		var payload: Image = layer.get_payload()
		if payload == null or payload.is_empty():
			continue
		var region_loc: Vector2i = slice.get("region_location", Vector2i.ZERO)
		if payload.get_format() == Image.FORMAT_MAX:
			_log("capture_group_template: skipping slice with unresolved payload format @ %s" % [str(region_loc)])
			continue
		var coverage: Rect2i = layer.get_coverage()
		if not coverage.has_area():
			continue
		var region_origin := region_loc * region_size
		var slice_global := Rect2i(region_origin + coverage.position, coverage.size)
		min_point.x = min(min_point.x, slice_global.position.x)
		min_point.y = min(min_point.y, slice_global.position.y)
		var slice_end := slice_global.position + slice_global.size
		max_point.x = max(max_point.x, slice_end.x)
		max_point.y = max(max_point.y, slice_end.y)
		prepared.append({
			"payload": payload,
			"alpha": layer.get_alpha(),
			"global_rect": slice_global
		})
	if prepared.is_empty():
		_log("capture_group_template: no valid payload slices found")
		return false
	var bounds_size := max_point - min_point
	if bounds_size.x <= 0 or bounds_size.y <= 0:
		_log("capture_group_template: combined bounds invalid %s" % [str(bounds_size)])
		return false
	var payload_format: Image.Format = prepared[0]["payload"].get_format()
	if payload_format == Image.FORMAT_MAX:
		var fallback_payload: Image = source.get_payload()
		if fallback_payload:
			payload_format = fallback_payload.get_format()
	if payload_format == Image.FORMAT_MAX:
		_log("capture_group_template: unresolved payload format")
		return false
	var combined := Image.create(bounds_size.x, bounds_size.y, false, payload_format)
	combined.fill(Color(0.0, 0.0, 0.0, 0.0))
	var combined_alpha: Image
	var alpha_format := Image.FORMAT_MAX
	for prepared_slice in prepared:
		var slice_payload: Image = prepared_slice["payload"]
		if slice_payload.get_format() != payload_format and slice_payload.get_format() != Image.FORMAT_MAX:
			var converted := slice_payload.duplicate()
			if converted:
				converted.convert(payload_format)
				slice_payload = converted
			else:
				continue
		var slice_rect: Rect2i = prepared_slice["global_rect"]
		var copy_size := slice_rect.size
		var payload_size := slice_payload.get_size()
		copy_size.x = min(copy_size.x, payload_size.x)
		copy_size.y = min(copy_size.y, payload_size.y)
		if copy_size.x <= 0 or copy_size.y <= 0:
			continue
		var src_rect := Rect2i(Vector2i.ZERO, copy_size)
		combined.blit_rect(slice_payload, src_rect, slice_rect.position - min_point)
		var slice_alpha: Image = prepared_slice["alpha"]
		if slice_alpha:
			if slice_alpha.get_format() == Image.FORMAT_MAX:
				continue
			if combined_alpha == null:
				alpha_format = slice_alpha.get_format()
				if alpha_format == Image.FORMAT_MAX:
					alpha_format = Image.FORMAT_R8
				combined_alpha = Image.create(bounds_size.x, bounds_size.y, false, alpha_format)
				combined_alpha.fill(Color(0.0, 0.0, 0.0, 0.0))
			elif slice_alpha.get_format() != alpha_format and slice_alpha.get_format() != Image.FORMAT_MAX:
				var converted_alpha := slice_alpha.duplicate()
				if converted_alpha:
					converted_alpha.convert(alpha_format)
					slice_alpha = converted_alpha
				else:
					continue
			var alpha_size := Vector2i(min(copy_size.x, slice_alpha.get_width()), min(copy_size.y, slice_alpha.get_height()))
			if alpha_size.x <= 0 or alpha_size.y <= 0:
				continue
			var alpha_src_rect := Rect2i(Vector2i.ZERO, alpha_size)
			combined_alpha.blit_rect(slice_alpha, alpha_src_rect, slice_rect.position - min_point)
	_template_payload = combined
	_template_alpha = combined_alpha
	_template_size = bounds_size
	_template_intensity = source.get_intensity()
	_template_feather_radius = source.get_feather_radius()
	_template_blend_mode = source.get_blend_mode()
	map_type = source.get_map_type()
	_template_ready = true
	return true

func _remove_group_layers(slices: Array, map_type_in: int) -> void:
	if _data == null:
		return
	var removal := {}
	for slice in slices:
		var layer: Terrain3DLayer = slice.get("layer")
		if _is_layer_claimed_by_other(layer):
			continue
		var region_loc: Vector2i = slice.get("region_location", Vector2i.ZERO)
		var layer_index_value := int(slice.get("layer_index", -1))
		if layer_index_value < 0:
			continue
		var key := "%d,%d" % [region_loc.x, region_loc.y]
		if not removal.has(key):
			removal[key] = {
				"region": region_loc,
				"indices": []
			}
		removal[key]["indices"].append(layer_index_value)
	var removed := false
	for key in removal.keys():
		var entry: Dictionary = removal[key]
		var indices: Array = entry["indices"]
		indices.sort()
		indices.reverse()
		for idx in indices:
			_data.remove_layer(entry["region"], map_type_in, idx, false)
			removed = true
	if removed:
		_queue_map_update()

func _resolve_source_layer(force_region: bool) -> Terrain3DStampLayer:
	if _terrain == null:
		_resolve_terrain()
	if _data == null:
		return null
	if _preferred_layer and is_instance_valid(_preferred_layer):
		if not _is_layer_claimed_by_other(_preferred_layer):
			return _preferred_layer
		elif allow_claimed_sources:
			return _preferred_layer
		else:
			_log("resolve_source_layer: preferred layer is owned by another anchor")
	if auto_region or force_region:
		target_region = _data.get_region_location(global_transform.origin)
		_log("resolve_source_layer: auto target region=%s" % [str(target_region)])
	var region: Terrain3DRegion = _data.get_region(target_region)
	if region == null:
		_log("resolve_source_layer: region %s missing" % [str(target_region)])
		return null
	var layers: Array = region.get_layers(map_type)
	var manual_index := layer_index >= 0 and layer_index < layers.size()
	if manual_index:
		var candidate: Terrain3DLayer = layers[layer_index]
		if candidate is Terrain3DStampLayer:
			if not _is_layer_claimed_by_other(candidate) or allow_claimed_sources:
				_log("resolve_source_layer: using indexed layer %d" % layer_index)
				return candidate as Terrain3DStampLayer
			else:
				_log("resolve_source_layer: indexed layer %d is owned by another anchor" % layer_index)
	if not auto_layer_search:
		_log("resolve_source_layer: indexed layer not stamp and search disabled")
		return null
	for i in range(layers.size()):
		var fallback: Terrain3DLayer = layers[i]
		if fallback is Terrain3DStampLayer:
			if _is_layer_claimed_by_other(fallback) and not allow_claimed_sources:
				continue
			layer_index = i
			_log("resolve_source_layer: switched to fallback layer %d" % layer_index)
			return fallback as Terrain3DStampLayer
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
		_queue_map_update()
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
		_queue_map_update()
	_active_layers.clear()

func _reset_template() -> void:
	_clear_active_layers(true)
	_template_ready = false
	_template_payload = null
	_template_alpha = null
	_template_size = Vector2i.ZERO
	_active_layers.clear()
	_preferred_layer = null
	_release_group_claim(_template_group_id)
	_template_group_id = 0
	_set_claimed_group_id(0)
	_set_source_summary("")

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
	if added:
		_pending_full_map_rebuild = true
	return added != null

func _create_slice_layer(region_loc: Vector2i, payload: Image, alpha: Image, coverage: Rect2i) -> Terrain3DStampLayer:
	if payload == null or not coverage.has_area():
		return null
	var layer := _data.add_stamp_layer(region_loc, map_type, payload, coverage, alpha, _template_intensity, _template_feather_radius, _template_blend_mode, -1, false)
	if layer and _template_group_id != 0:
		layer.set_group_id(_template_group_id)
		_data.ensure_layer_group_id(layer)
	_tag_layer_anchor(layer)
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
	if _template_group_id != 0:
		layer.set_group_id(_template_group_id)
		if _data:
			_data.ensure_layer_group_id(layer)
	_tag_layer_anchor(layer)
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
	if update_maps:
		_queue_map_update()
	return true

func _queue_map_update(force_full_rebuild: bool = false, immediate: bool = false) -> void:
	if _data == null:
		return
	_map_update_dirty = true
	if force_full_rebuild:
		_pending_full_map_rebuild = true
	if immediate:
		_apply_map_update()
		return
	var now := Time.get_ticks_msec()
	if now >= _next_map_update_msec:
		_apply_map_update()
		return
	if _map_update_timer:
		return
	var wait_ms := max(0, _next_map_update_msec - now)
	if wait_ms <= 0:
		call_deferred("_apply_map_update")
		return
	var tree := get_tree()
	if tree == null:
		_apply_map_update()
		return
	_map_update_timer = tree.create_timer(float(wait_ms) / 1000.0)
	_map_update_timer.timeout.connect(Callable(self, "_on_map_update_timeout"), Object.CONNECT_ONE_SHOT)

func _on_map_update_timeout() -> void:
	_map_update_timer = null
	_apply_map_update()

func _apply_map_update() -> void:
	if _data == null:
		_map_update_dirty = false
		_pending_full_map_rebuild = false
		_map_update_timer = null
		return
	if not _map_update_dirty and not _pending_full_map_rebuild:
		return
	_map_update_dirty = false
	var force_full := _pending_full_map_rebuild
	_pending_full_map_rebuild = false
	_map_update_timer = null
	_data.update_maps(map_type, force_full, false)
	_next_map_update_msec = Time.get_ticks_msec() + MAP_UPDATE_THROTTLE_MS

func _flush_map_update() -> void:
	if _data == null:
		return
	if _map_update_timer:
		_map_update_timer = null
	if _map_update_dirty or _pending_full_map_rebuild:
		_map_update_dirty = true
		_apply_map_update()
