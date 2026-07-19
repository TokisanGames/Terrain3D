# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Region grid for the streaming dock. Draws every region as a grid cell colored by its
# streaming state over a world-map underlay, and reports clicks as region locations so
# a streaming editor can be navigated spatially. Also usable as a runtime debug overlay.
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
const COLOR_DIRTY := Color(0.95, 0.68, 0.18) # unsaved editor edit (pinned)

# Prerender the whole minimap up front unless the world is bigger than this many
# regions, in which case the map fills in from residency instead. Capped resolution.
const PRERENDER_MAX_REGIONS := 2048
const MINIMAP_MAX_PX := 384

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
var _dirty := {}
var _focus := Vector2i.ZERO
var _has_focus := false

# World-map underlay. The prerendered texture is the primary source; _tile_h is a
# fallback that fills in from residency when the world is too big to prerender.
var _minimap_enabled := false
var _cache_terrain: Terrain3D
var _world_tex: ImageTexture
var _world_lo := Vector2i.ZERO
var _world_hi := Vector2i.ZERO
var _tile_h := {}
var _tile_hmin: float = 0.0
var _tile_hmax: float = 1.0
var _thread: Thread
var _prerendering := false


func _ready() -> void:
	clip_contents = true # keep the focus cross from drawing past the grid when far out


# Enables the world-map underlay. Off by default: nothing is preloaded until it is on.
func set_minimap_enabled(p_on: bool) -> void:
	if _minimap_enabled == p_on:
		return
	_minimap_enabled = p_on
	if not p_on:
		_world_tex = null
		_tile_h.clear()
	elif _world_tex == null:
		_start_prerender()
	queue_redraw()


func is_minimap_enabled() -> bool:
	return _minimap_enabled


func set_terrain(p_terrain: Terrain3D) -> void:
	# Key the cached map on the terrain instance so deselecting (a null set) keeps it,
	# and only a genuinely different world rebuilds it.
	if p_terrain != null and p_terrain != _cache_terrain:
		_cache_terrain = p_terrain
		_world_tex = null
		_tile_h.clear()
		_terrain = p_terrain
		_start_prerender()
	_terrain = p_terrain
	refresh()


# Pulls the current streaming state off the terrain and repaints.
func refresh() -> void:
	_resident.clear()
	_on_disk.clear()
	_loading.clear()
	_failed.clear()
	_dirty.clear()
	_has_focus = false
	if not is_instance_valid(_terrain) or _terrain.data == null:
		queue_redraw()
		return

	var span: float = float(_terrain.region_size) * _terrain.vertex_spacing
	for loc in _terrain.data.get_region_locations():
		_resident[loc] = true
		# Fallback minimap: sample the region center height while resident.
		if _minimap_enabled and _world_tex == null and not _tile_h.has(loc):
			var center := Vector3((float(loc.x) + 0.5) * span, 0.0, (float(loc.y) + 0.5) * span)
			var h: float = _terrain.data.get_height(center)
			if is_finite(h):
				_tile_h[loc] = h
	var streamer := _terrain.get_streamer()
	if streamer != null:
		for loc in streamer.get_known_locations():
			if not _resident.has(loc):
				_on_disk[loc] = true
		for loc in streamer.get_pending_locations():
			_loading[loc] = true
		for loc in streamer.get_failed_locations():
			_failed[loc] = true
	for loc in _terrain.data.get_pinned_locations():
		_dirty[loc] = true

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

	_focus = _terrain.data.get_region_location(_terrain.get_clipmap_target_position())
	_has_focus = true
	# The grid follows the camera out of the world: grow the bounds to always contain
	# the focus so the cursor stays on the map instead of drifting off it.
	lo.x = mini(lo.x, _focus.x)
	lo.y = mini(lo.y, _focus.y)
	hi.x = maxi(hi.x, _focus.x)
	hi.y = maxi(hi.y, _focus.y)
	# One cell of margin so edge cells are not flush with the border.
	_min_loc = lo - Vector2i.ONE
	_max_loc = hi + Vector2i.ONE

	if _world_tex == null and not _tile_h.is_empty():
		var vals: Array = _tile_h.values()
		_tile_hmin = vals[0]
		_tile_hmax = vals[0]
		for h in vals:
			_tile_hmin = minf(_tile_hmin, h)
			_tile_hmax = maxf(_tile_hmax, h)
	queue_redraw()


# Sea-level-anchored minimap palette. The coastline stays fixed at height 0: below it is
# water (shallow teal to deep navy), 0 and up is land (coast green through olive and brown
# to pale peaks). Depth and elevation scale to the world's own min and max so the full range
# reads, but 0 is always the shoreline, so land never colors as water and vice versa.
func _height_color(p_h: float, p_lo: float, p_hi: float) -> Color:
	if p_h < 0.0:
		var dt := clampf(-p_h / maxf(-p_lo, 0.0001), 0.0, 1.0)
		dt = sqrt(dt) # spread the shallows so coasts read
		return Color(0.33, 0.58, 0.66).lerp(Color(0.06, 0.14, 0.33), dt)
	return _land_ramp(clampf(p_h / maxf(p_hi, 0.0001), 0.0, 1.0))


# Land gradient: coast green -> olive -> brown -> pale rock/snow.
func _land_ramp(p_t: float) -> Color:
	const STOPS := [
		Color(0.34, 0.50, 0.26), # coast green
		Color(0.52, 0.55, 0.30), # olive
		Color(0.56, 0.44, 0.28), # brown
		Color(0.88, 0.88, 0.90), # pale peak
	]
	var t := clampf(p_t, 0.0, 1.0) * (STOPS.size() - 1)
	var i := int(floor(t))
	if i >= STOPS.size() - 1:
		return STOPS[STOPS.size() - 1]
	return STOPS[i].lerp(STOPS[i + 1], t - float(i))


func _tile_color(p_h: float) -> Color:
	return _height_color(p_h, _tile_hmin, _tile_hmax)


# Reads every region file on a background thread, downsampling each into a block of a
# world height image, so the whole minimap is ready without loading regions into the
# streaming pool or freezing the editor.
func _start_prerender() -> void:
	if not _minimap_enabled or _prerendering or not is_instance_valid(_terrain) or _terrain.data == null:
		return
	var streamer := _terrain.get_streamer()
	if streamer == null:
		return
	var known: Array = streamer.get_known_locations()
	if known.is_empty() or known.size() > PRERENDER_MAX_REGIONS:
		return
	var lo := Vector2i(known[0])
	var hi := lo
	for k in known:
		var l := Vector2i(k)
		lo.x = mini(lo.x, l.x)
		lo.y = mini(lo.y, l.y)
		hi.x = maxi(hi.x, l.x)
		hi.y = maxi(hi.y, l.y)
	var gw := hi.x - lo.x + 1
	var gh := hi.y - lo.y + 1
	var block := clampi(int(float(MINIMAP_MAX_PX) / float(maxi(gw, gh))), 1, 8)
	var payload := {
		"dir": _terrain.data_directory, "locs": known, "terrain": _terrain,
		"lo": lo, "hi": hi, "gw": gw, "gh": gh, "block": block,
	}
	_prerendering = true
	_thread = Thread.new()
	_thread.start(_prerender_worker.bind(payload))


func _prerender_worker(p_payload: Dictionary) -> void:
	var lo: Vector2i = p_payload.lo
	var block: int = p_payload.block
	var w: int = p_payload.gw * block
	var h: int = p_payload.gh * block
	var heights := Image.create(w, h, false, Image.FORMAT_RF)
	heights.fill(Color(NAN, 0, 0)) # NAN marks cells with no region
	var hmin := INF
	var hmax := -INF
	for k in p_payload.locs:
		var loc := Vector2i(k)
		var path: String = p_payload.dir + "/" + Terrain3DUtil.location_to_filename(loc)
		var region: Terrain3DRegion = ResourceLoader.load(path, "Terrain3DRegion", ResourceLoader.CACHE_MODE_IGNORE)
		if region == null:
			continue
		var hm: Image = region.get_height_map()
		if hm == null:
			continue
		var d: Image = hm.duplicate()
		d.resize(block, block, Image.INTERPOLATE_BILINEAR)
		var ox := (loc.x - lo.x) * block
		var oy := (loc.y - lo.y) * block
		for by in range(block):
			for bx in range(block):
				var v := d.get_pixel(bx, by).r
				if is_finite(v):
					heights.set_pixel(ox + bx, oy + by, Color(v, 0, 0))
					hmin = minf(hmin, v)
					hmax = maxf(hmax, v)
	var colored := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in range(h):
		for x in range(w):
			var v := heights.get_pixel(x, y).r
			if is_nan(v):
				colored.set_pixel(x, y, Color(0, 0, 0, 0))
			else:
				var c := _height_color(v, hmin, hmax)
				c.a = 1.0
				colored.set_pixel(x, y, c)
	call_deferred("_prerender_done", colored, p_payload.lo, p_payload.hi, p_payload.terrain)


func _prerender_done(p_image: Image, p_lo: Vector2i, p_hi: Vector2i, p_terrain: Terrain3D) -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_prerendering = false
	# Discard if the world changed while the thread ran, then rebuild for the new one.
	if p_terrain != _cache_terrain:
		_start_prerender()
		return
	# The minimap may have been switched off while the thread ran; drop the result.
	if not _minimap_enabled:
		return
	_world_lo = p_lo
	_world_hi = p_hi
	_world_tex = ImageTexture.create_from_image(p_image)
	queue_redraw()


func _notification(p_what: int) -> void:
	if p_what == NOTIFICATION_PREDELETE and _thread != null and _thread.is_started():
		_thread.wait_to_finish()
		_thread = null


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
	# World-map underlay: the prerendered texture stretched over its region bounds.
	if _minimap_enabled and _world_tex != null:
		var tl := _cell_rect(_world_lo).position
		var br := _cell_rect(_world_hi).end
		draw_texture_rect(_world_tex, Rect2(tl, br - tl), false)

	for y in range(_min_loc.y, _max_loc.y + 1):
		for x in range(_min_loc.x, _max_loc.x + 1):
			var loc := Vector2i(x, y)
			var body := Rect2(_cell_rect(loc).position + inset, Vector2(_cell_px, _cell_px) - inset * 2.0)
			var mapped: bool = _minimap_enabled and _world_tex != null
			# Fallback per-region tint where there is no prerendered texture.
			if not mapped and _tile_h.has(loc):
				draw_rect(body, _tile_color(_tile_h[loc]), true)
				mapped = true
			elif not mapped and _on_disk.has(loc):
				draw_rect(body, COLOR_ON_DISK, true)
			elif not mapped and not (_resident.has(loc) or _loading.has(loc) or _failed.has(loc)):
				draw_rect(body, COLOR_EMPTY, true)
			# Streaming state overlay. Over a map it is a border so the map shows
			# through; without a map the fill carries the loading/failed color.
			var state := Color(0, 0, 0, 0)
			if _resident.has(loc):
				state = COLOR_RESIDENT
			elif _loading.has(loc):
				state = COLOR_LOADING
			elif _failed.has(loc):
				state = COLOR_FAILED
			if state.a > 0.0:
				draw_rect(body, state, not mapped)
			# Unsaved edit: an amber border on top so it reads over any fill or state.
			if _dirty.has(loc):
				draw_rect(body, COLOR_DIRTY, false, 2.0)

	# Focus cross over the target region.
	if _has_focus:
		var fr := _cell_rect(_focus)
		var c := fr.get_center()
		draw_line(Vector2(fr.position.x, c.y), Vector2(fr.end.x, c.y), COLOR_FOCUS, 1.0)
		draw_line(Vector2(c.x, fr.position.y), Vector2(c.x, fr.end.y), COLOR_FOCUS, 1.0)
		draw_rect(fr, COLOR_WINDOW, false, 1.0)


func _gui_input(p_event: InputEvent) -> void:
	if p_event is InputEventMouseButton and p_event.pressed and p_event.button_index == MOUSE_BUTTON_LEFT:
		_layout() # ensure cell metrics are current even before the first paint
		if _cell_px <= 0.0 or _max_loc == _min_loc:
			return
		var local: Vector2 = p_event.position - _origin
		if local.x < 0.0 or local.y < 0.0:
			return
		var cx := int(local.x / _cell_px)
		var cy := int(local.y / _cell_px)
		var loc := _min_loc + Vector2i(cx, cy)
		if loc.x <= _max_loc.x and loc.y <= _max_loc.y:
			cell_clicked.emit(loc)
