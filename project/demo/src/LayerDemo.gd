extends Node3D

@export var terrain_path: NodePath
@export var instruction_label_path: NodePath

var _terrain: Terrain3D
var _data: Terrain3DData
var _region_loc: Vector2i
var _demo_layers: Array = []
var _layers_enabled := false
var _instruction_label: Label
var _base_coverage := Rect2i()
var _coverage_offset := Vector2i.ZERO
const MOVE_STEP := 8

func _ready() -> void:
	set_process_input(true)
	if terrain_path.is_empty():
		_terrain = find_child("Terrain3D")
	else:
		_terrain = get_node_or_null(terrain_path)
	if _terrain == null:
		push_error("LayerDemo: Terrain3D node not found.")
		return
	await _terrain.ready
	await get_tree().process_frame
	_data = _terrain.get_data()
	if _data == null:
		push_error("LayerDemo: Terrain3DData unavailable.")
		return
	var regions: Array = _data.get_region_locations()
	if regions.is_empty():
		push_error("LayerDemo: No regions loaded in Terrain3DData.")
		return
	_region_loc = regions[0]
	if instruction_label_path.is_empty():
		_instruction_label = null
	else:
		_instruction_label = get_node_or_null(instruction_label_path)
	if not _build_demo_layers():
		return
	_set_layers_enabled(true)
	_update_instruction()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == Key.KEY_L:
		_set_layers_enabled(not _layers_enabled)
		_update_instruction()
	elif event is InputEventKey and event.pressed and not event.echo and _layers_enabled:
		var delta := Vector2i.ZERO
		match event.keycode:
			Key.KEY_LEFT:
				delta.x = -MOVE_STEP
			Key.KEY_RIGHT:
				delta.x = MOVE_STEP
			Key.KEY_UP:
				delta.y = -MOVE_STEP
			Key.KEY_DOWN:
				delta.y = MOVE_STEP
			_:
				return
		_move_layers(delta)

func _build_demo_layers() -> bool:
	var region: Terrain3DRegion = _data.get_region(_region_loc)
	if region == null:
		push_error("LayerDemo: Region %s unavailable." % [_region_loc])
		return false
	var region_size: int = region.get_region_size()
	var target_size: int = clampi(256, 64, region_size)
	var coverage_side: int = clampi(target_size, 32, region_size)
	var margin := int((region_size - coverage_side) * 0.5)
	margin = max(margin, 0)
	var coverage_position := Vector2i(margin, margin)
	var coverage := Rect2i(coverage_position, Vector2i(coverage_side, coverage_side))
	var height_layer := _create_height_layer(coverage_side, coverage)
	var color_layer := _create_color_layer(coverage_side, coverage)
	if height_layer == null or color_layer == null:
		return false
	var stored_height := _data.add_layer(_region_loc, Terrain3DRegion.TYPE_HEIGHT, height_layer, false)
	if stored_height == null:
		stored_height = height_layer
	var stored_color := _data.add_layer(_region_loc, Terrain3DRegion.TYPE_COLOR, color_layer, false)
	if stored_color == null:
		stored_color = color_layer
	var height_index := _data.get_layers(_region_loc, Terrain3DRegion.TYPE_HEIGHT).find(stored_height)
	var color_index := _data.get_layers(_region_loc, Terrain3DRegion.TYPE_COLOR).find(stored_color)
	_demo_layers = [
		{"map_type": Terrain3DRegion.TYPE_HEIGHT, "layer": stored_height, "index": height_index},
		{"map_type": Terrain3DRegion.TYPE_COLOR, "layer": stored_color, "index": color_index}
	]
	_base_coverage = coverage
	_data.update_maps(Terrain3DRegion.TYPE_HEIGHT, false, false)
	_data.update_maps(Terrain3DRegion.TYPE_COLOR, false, false)
	return true

func _create_height_layer(size: int, coverage: Rect2i) -> Terrain3DLayer:
	var layer := Terrain3DLayer.new()
	layer.set_map_type(Terrain3DRegion.TYPE_HEIGHT)
	layer.set_blend_mode(Terrain3DLayer.BLEND_ADD)
	layer.set_intensity(0.9)
	layer.set_feather_radius(float(size) * 0.25)
	layer.set_enabled(false)
	var payload := Image.create(size, size, false, Image.FORMAT_RF)
	var center := Vector2(size - 1, size - 1) * 0.5
	var radius: float = max(float(size) * 0.5, 1.0)
	for y in size:
		for x in size:
			var dist := Vector2(x, y).distance_to(center)
			var falloff: float = clampf(1.0 - dist / radius, 0.0, 1.0)
			var height: float = pow(falloff, 3.0) * 0.55
			payload.set_pixel(x, y, Color(height, 0.0, 0.0, 1.0))
	layer.set_payload(payload)
	layer.set_coverage(coverage)
	return layer

func _create_color_layer(size: int, coverage: Rect2i) -> Terrain3DLayer:
	var layer := Terrain3DLayer.new()
	layer.set_map_type(Terrain3DRegion.TYPE_COLOR)
	layer.set_blend_mode(Terrain3DLayer.BLEND_REPLACE)
	layer.set_intensity(1.0)
	layer.set_feather_radius(float(size) * 0.25)
	layer.set_enabled(false)
	var payload := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var alpha := Image.create(size, size, false, Image.FORMAT_RF)
	var center := Vector2(size - 1, size - 1) * 0.5
	var radius: float = max(float(size) * 0.5, 1.0)
	var tint := Color(0.9, 0.45, 0.2, 1.0)
	for y in size:
		for x in size:
			var dist := Vector2(x, y).distance_to(center)
			var falloff: float = clampf(1.0 - dist / radius, 0.0, 1.0)
			var strength: float = pow(falloff, 2.0)
			if strength <= 0.0:
				continue
			alpha.set_pixel(x, y, Color(strength, 0.0, 0.0, 1.0))
			payload.set_pixel(x, y, Color(tint.r, tint.g, tint.b, 1.0))
	layer.set_payload(payload)
	layer.set_alpha(alpha)
	layer.set_coverage(coverage)
	return layer

func _set_layers_enabled(enabled: bool) -> void:
	if _demo_layers.is_empty():
		return
	var map_types := {}
	for item in _demo_layers:
		var layer: Terrain3DLayer = item["layer"]
		if layer == null:
			continue
		layer.set_enabled(enabled)
		layer.mark_dirty()
		map_types[item["map_type"]] = true
	for map_type in map_types.keys():
		_data.update_maps(map_type, false, false)
	_layers_enabled = enabled
	if enabled:
		_apply_layer_offset(_coverage_offset)

func _update_instruction() -> void:
	if _instruction_label == null:
		return
	var state := "ON" if _layers_enabled else "OFF"
	var move_hint := "Use arrow keys to slide the stamp" if _layers_enabled else ""
	_instruction_label.text = "Press L to toggle demo layers (currently %s). %s" % [state, move_hint]

func _move_layers(delta: Vector2i) -> void:
	if delta == Vector2i.ZERO or _demo_layers.is_empty():
		return
	var region: Terrain3DRegion = _data.get_region(_region_loc)
	if region == null:
		return
	var region_size := region.get_region_size()
	var new_pos := _base_coverage.position + _coverage_offset + delta
	new_pos.x = clampi(new_pos.x, 0, region_size - _base_coverage.size.x)
	new_pos.y = clampi(new_pos.y, 0, region_size - _base_coverage.size.y)
	_coverage_offset = new_pos - _base_coverage.position
	_apply_layer_offset(_coverage_offset)

func _apply_layer_offset(offset: Vector2i) -> void:
	var target_rect := Rect2i(_base_coverage.position + offset, _base_coverage.size)
	var pending_types := {}
	for item in _demo_layers:
		var layer: Terrain3DLayer = item.get("layer")
		var index: int = int(item.get("index", -1))
		var map_type: int = int(item.get("map_type", Terrain3DRegion.TYPE_MAX))
		if layer == null or map_type == Terrain3DRegion.TYPE_MAX or index < 0:
			continue
		if _data.set_layer_coverage(_region_loc, map_type, index, target_rect, false):
			pending_types[map_type] = true
	for map_type in pending_types.keys():
		_data.update_maps(map_type, false, false)
