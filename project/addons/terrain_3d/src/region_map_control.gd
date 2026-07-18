# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Region grid for the streaming dock. Draws the streaming state of every region as a
# grid of cells and reports clicks as region locations, so a streaming editor can be
# navigated spatially. Also usable as a runtime debug overlay.
@tool
extends Control

signal cell_clicked(location: Vector2i)

const COLOR_RESIDENT := Color(0.32, 0.72, 0.36) # loaded in memory
const COLOR_ON_DISK := Color(0.42, 0.42, 0.46) # on disk, not loaded
const COLOR_LOADING := Color(0.85, 0.72, 0.20) # threaded load in flight
const COLOR_FAILED := Color(0.80, 0.28, 0.24) # load failed, not retried
const COLOR_EMPTY := Color(0.20, 0.20, 0.23, 0.5) # no region authored
const COLOR_FOCUS := Color(0.95, 0.95, 1.0) # camera / clipmap target region
const COLOR_WINDOW := Color(0.45, 0.75, 1.0, 0.9) # loaded-area outline
const COLOR_GRID := Color(0.12, 0.12, 0.14)

var _terrain: Terrain3D
var _min_loc := Vector2i.ZERO
var _max_loc := Vector2i.ZERO
var _cell_px: float = 8.0
var _origin := Vector2.ZERO

# Cached sets rebuilt on refresh, so _draw and hit testing stay cheap.
var _resident := {}
var _on_disk := {}
var _loading := {}
var _failed := {}
var _focus := Vector2i.ZERO
var _has_focus := false


func set_terrain(p_terrain: Terrain3D) -> void:
	_terrain = p_terrain
	refresh()


# Pulls the current streaming state off the terrain and repaints. Cheap enough to
# call from a timer while the dock is visible.
func refresh() -> void:
	_resident.clear()
	_on_disk.clear()
	_loading.clear()
	_failed.clear()
	_has_focus = false
	if not is_instance_valid(_terrain) or _terrain.data == null:
		queue_redraw()
		return

	for loc in _terrain.data.get_region_locations():
		_resident[loc] = true
	var streamer := _terrain.get_streamer()
	if streamer != null:
		for loc in streamer.get_known_locations():
			if not _resident.has(loc):
				_on_disk[loc] = true
		for loc in streamer.get_pending_locations():
			_loading[loc] = true
		for loc in streamer.get_failed_locations():
			_failed[loc] = true

	var all_keys: Array = _resident.keys() + _on_disk.keys() + _loading.keys() + _failed.keys()
	if all_keys.is_empty():
		queue_redraw()
		return
	var lo := Vector2i(all_keys[0])
	var hi := lo
	for k in all_keys:
		var loc := Vector2i(k)
		lo.x = mini(lo.x, loc.x)
		lo.y = mini(lo.y, loc.y)
		hi.x = maxi(hi.x, loc.x)
		hi.y = maxi(hi.y, loc.y)
	# One cell of margin so edge cells are not flush with the border.
	_min_loc = lo - Vector2i.ONE
	_max_loc = hi + Vector2i.ONE

	if _terrain.data.get_region_count() > 0 or _has_target():
		_focus = _terrain.data.get_region_location(_target_position())
		_has_focus = true
	queue_redraw()


func _has_target() -> bool:
	return is_instance_valid(_terrain)


func _target_position() -> Vector3:
	return _terrain.get_clipmap_target_position()


func _layout() -> void:
	var cols := _max_loc.x - _min_loc.x + 1
	var rows := _max_loc.y - _min_loc.y + 1
	var avail := size
	# Square cells that fit both axes, with a small floor so a huge world stays legible.
	_cell_px = maxf(3.0, floorf(minf(avail.x / float(maxi(cols, 1)), avail.y / float(maxi(rows, 1)))))
	var grid_w := _cell_px * cols
	var grid_h := _cell_px * rows
	_origin = ((avail - Vector2(grid_w, grid_h)) * 0.5).floor()


func _cell_rect(p_loc: Vector2i) -> Rect2:
	var rel := p_loc - _min_loc
	return Rect2(_origin + Vector2(rel.x, rel.y) * _cell_px, Vector2(_cell_px, _cell_px))


func _draw() -> void:
	if _max_loc == _min_loc:
		return
	_layout()
	var inset := Vector2(1, 1)
	for y in range(_min_loc.y, _max_loc.y + 1):
		for x in range(_min_loc.x, _max_loc.x + 1):
			var loc := Vector2i(x, y)
			var rect := _cell_rect(loc)
			var col := COLOR_EMPTY
			if _resident.has(loc):
				col = COLOR_RESIDENT
			elif _loading.has(loc):
				col = COLOR_LOADING
			elif _failed.has(loc):
				col = COLOR_FAILED
			elif _on_disk.has(loc):
				col = COLOR_ON_DISK
			draw_rect(Rect2(rect.position + inset, rect.size - inset * 2.0), col, true)

	# Focus cross over the target region.
	if _has_focus:
		var fr := _cell_rect(_focus)
		var c := fr.get_center()
		draw_line(Vector2(fr.position.x, c.y), Vector2(fr.end.x, c.y), COLOR_FOCUS, 1.0)
		draw_line(Vector2(c.x, fr.position.y), Vector2(c.x, fr.end.y), COLOR_FOCUS, 1.0)
		draw_rect(fr, COLOR_WINDOW, false, 1.0)


func _gui_input(p_event: InputEvent) -> void:
	if p_event is InputEventMouseButton and p_event.pressed and p_event.button_index == MOUSE_BUTTON_LEFT:
		if _cell_px <= 0.0:
			return
		var local: Vector2 = p_event.position - _origin
		if local.x < 0.0 or local.y < 0.0:
			return
		var cx := int(local.x / _cell_px)
		var cy := int(local.y / _cell_px)
		var loc := _min_loc + Vector2i(cx, cy)
		if loc.x <= _max_loc.x and loc.y <= _max_loc.y:
			cell_clicked.emit(loc)
