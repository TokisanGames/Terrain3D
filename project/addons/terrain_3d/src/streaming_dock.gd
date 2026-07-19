# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Terrain Streaming dock. A spatial view of region residency, so a world too large to
# hold in memory can be navigated. Read only: it shows streaming and teleports the
# camera on a cell click, but does not edit terrain data. Streaming settings live on
# the Terrain3D node's inspector, not here.
@tool
extends PanelContainer

const RegionMapControl: Script = preload("res://addons/terrain_3d/src/region_map_control.gd")
const REFRESH_INTERVAL: float = 0.25

var plugin: EditorPlugin
var _terrain: Terrain3D
var _dock: Object # EditorDock on 4.6+, null on older editors

var _grid: Control
var _meter: ProgressBar
var _meter_label: Label
var _stats: Label
var _dirty_label: Label
var _save_button: Button
var _next_button: Button
var _dirty_cycle: int = 0
var _warn_label: Label
var _was_saturated: bool = false
var _ctx_menu: PopupMenu
var _ctx_loc: Vector2i
var _accum: float = 0.0


func initialize(p_plugin: EditorPlugin) -> void:
	plugin = p_plugin
	name = "Terrain Stream"
	_build()
	set_process(true)
	# Godot 4.6+ manages docks through EditorDock; older editors use the control API.
	if ClassDB.class_exists("EditorDock"):
		_dock = ClassDB.instantiate("EditorDock")
		_dock.title = "Terrain Stream"
		_dock.default_slot = 5 # EditorDock DOCK_SLOT_RIGHT_BL (bottom of the right column)
		_dock.closable = true
		_dock.available_layouts = 0x7 # EditorDock.DOCK_LAYOUT_ALL
		_dock.add_child(self)
		plugin.add_dock(_dock)
		_dock.open()
	else:
		plugin.add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_BL, self)


func remove_dock() -> void:
	if not is_instance_valid(plugin):
		return
	if _dock != null:
		plugin.remove_dock(_dock)
		_dock.queue_free() # frees self, its child
	else:
		plugin.remove_control_from_docks(self)
		queue_free()


func set_terrain(p_terrain: Terrain3D) -> void:
	if _terrain != p_terrain:
		if is_instance_valid(_terrain) and _terrain.edits_flushed.is_connected(_on_edits_flushed):
			_terrain.edits_flushed.disconnect(_on_edits_flushed)
		_terrain = p_terrain
		if is_instance_valid(_terrain) and not _terrain.edits_flushed.is_connected(_on_edits_flushed):
			_terrain.edits_flushed.connect(_on_edits_flushed)
	if _grid != null:
		_grid.set_terrain(p_terrain)
	_refresh()


# The engine saved pinned edits before a reinitialize (e.g. streaming was disabled or the
# pool resized). Acknowledge it so the save is not silent; the toggle itself lives on the
# node inspector, so this is a notice rather than a pre-toggle confirm.
func _on_edits_flushed(p_count: int) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Terrain edits saved"
	dialog.dialog_text = "%d unsaved region edit%s saved to disk before streaming reinitialized." % [
		p_count, "" if p_count == 1 else "s"]
	add_child(dialog)
	dialog.popup_centered()
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)


# Editor tool node: the editor drives _process, so poll the streaming state on an
# interval to track the camera and residency without a Timer.
func _process(p_delta: float) -> void:
	_accum += p_delta
	if _accum < REFRESH_INTERVAL:
		return
	_accum = 0.0
	# Track any Terrain3D in the open scene, so the dock is live without a selection.
	if not _valid():
		_auto_acquire()
	_refresh()


# Finds a Terrain3D in the edited scene when none was set by selection.
func _auto_acquire() -> void:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root != null:
		set_terrain(_find_terrain(root))


func _find_terrain(p_node: Node) -> Terrain3D:
	if p_node is Terrain3D:
		return p_node
	for child in p_node.get_children():
		var found := _find_terrain(child)
		if found != null:
			return found
	return null


func _build() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	var header := HBoxContainer.new()
	root.add_child(header)
	var title := Label.new()
	title.text = "Terrain Streaming"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var minimap_check := CheckBox.new()
	minimap_check.text = "Minimap"
	minimap_check.tooltip_text = "Prerender a world map under the grid. Off by default; nothing loads until on."
	minimap_check.toggled.connect(_on_minimap_toggled)
	header.add_child(minimap_check)
	var recenter := Button.new()
	recenter.text = "Recenter"
	recenter.tooltip_text = "Move the editor camera back to the nearest region."
	recenter.pressed.connect(_on_recenter)
	header.add_child(recenter)

	_grid = RegionMapControl.new()
	_grid.custom_minimum_size = Vector2(0, 180)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid.cell_clicked.connect(_on_cell_clicked)
	_grid.cell_right_clicked.connect(_on_cell_right_clicked)
	root.add_child(_grid)

	_ctx_menu = PopupMenu.new()
	_ctx_menu.id_pressed.connect(_on_ctx_menu)
	add_child(_ctx_menu)

	var meter_box := HBoxContainer.new()
	root.add_child(meter_box)
	var meter_title := Label.new()
	meter_title.text = "Residency"
	meter_box.add_child(meter_title)
	_meter = ProgressBar.new()
	_meter.show_percentage = false
	_meter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	meter_box.add_child(_meter)
	_meter_label = Label.new()
	_meter_label.text = "0 / 0"
	meter_box.add_child(_meter_label)

	_stats = Label.new()
	_stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_stats)

	_warn_label = Label.new()
	_warn_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_warn_label.add_theme_color_override("font_color", Color(0.95, 0.45, 0.35))
	_warn_label.visible = false
	root.add_child(_warn_label)

	var edits_box := HBoxContainer.new()
	root.add_child(edits_box)
	_dirty_label = Label.new()
	_dirty_label.text = "No unsaved edits"
	_dirty_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edits_box.add_child(_dirty_label)
	_next_button = Button.new()
	_next_button.text = "Next ▸"
	_next_button.tooltip_text = "Jump the editor camera to the next region with unsaved edits."
	_next_button.disabled = true
	_next_button.pressed.connect(_on_next_unsaved)
	edits_box.add_child(_next_button)
	_save_button = Button.new()
	_save_button.text = "Save edits"
	_save_button.tooltip_text = "Save every region with unsaved edits, freeing pool slots."
	_save_button.disabled = true
	_save_button.pressed.connect(_on_save_edits)
	edits_box.add_child(_save_button)


func _refresh() -> void:
	if _grid != null:
		_grid.refresh()
	if not _valid():
		_stats.text = "Select a Terrain3D node."
		_meter.value = 0
		_meter_label.text = "0 / 0"
		_dirty_label.text = "No unsaved edits"
		_save_button.disabled = true
		_next_button.disabled = true
		_warn_label.visible = false
		_was_saturated = false
		return
	var s: Dictionary = _terrain.get_streaming_stats()
	var resident: int = int(s.get("resident", 0))
	var slots: int = _terrain.data.get_slot_capacity() if _terrain.data != null else 0
	var dirty: int = _terrain.data.get_pinned_locations().size()
	# The pool is full and every slot holds an unsaved edit, so no new region can stream in
	# for editing until some are saved. Surface it: the brush would otherwise just stop
	# working with only a console warning.
	var saturated: bool = int(s.get("free_slots", -1)) == 0 and dirty >= slots and slots > 0
	_warn_label.visible = saturated
	if saturated:
		_warn_label.text = "Pool full of unsaved edits (%d/%d). Save to edit new areas." % [dirty, slots]
		if not _was_saturated:
			push_warning("Terrain3D streaming pool full of unsaved edits; save to continue editing new regions.")
	_was_saturated = saturated
	_meter.max_value = maxi(slots, 1)
	_meter.value = resident
	_meter_label.text = "%d / %d" % [resident, slots]
	# Tint the residency bar amber as unsaved edits fill the pool toward the wall.
	if dirty > 0:
		var frac: float = clampf(float(dirty) / float(maxi(slots, 1)), 0.0, 1.0)
		_meter.modulate = Color(1, 1, 1).lerp(Color(0.95, 0.68, 0.18), 0.4 + frac * 0.6)
	else:
		_meter.modulate = Color(1, 1, 1)
	_dirty_label.text = "%d unsaved edit%s" % [dirty, "" if dirty == 1 else "s"] if dirty > 0 else "No unsaved edits"
	_save_button.disabled = dirty == 0
	_next_button.disabled = dirty == 0
	_stats.text = "mode %s   in flight %d   failed %d   known %d\nlanded %d   evicted %d" % [
		s.get("mode", "-"), int(s.get("inflight", 0)), int(s.get("failed", 0)),
		int(s.get("known", 0)), int(s.get("landed_total", 0)), int(s.get("evicted_total", 0))]


func _on_cell_clicked(p_location: Vector2i) -> void:
	_teleport_to(p_location)


# Right-click a region on the map to stage or revert it without a brush stroke.
func _on_cell_right_clicked(p_location: Vector2i, p_screen_pos: Vector2) -> void:
	if not _valid():
		return
	var state: int = _terrain.data.get_region_load_state(p_location)
	if state == Terrain3DData.REGION_ABSENT:
		return # unauthored cell; nothing to act on
	_ctx_loc = p_location
	_ctx_menu.clear()
	_ctx_menu.add_item("Teleport here", 0)
	if state != Terrain3DData.REGION_RESIDENT:
		_ctx_menu.add_item("Load && pin here", 1)
	if _terrain.data.is_region_pinned(p_location):
		_ctx_menu.add_item("Discard edits", 2)
	_ctx_menu.reset_size()
	_ctx_menu.position = Vector2i(p_screen_pos)
	_ctx_menu.popup()


func _on_ctx_menu(p_id: int) -> void:
	if not _valid():
		return
	match p_id:
		0:
			_teleport_to(_ctx_loc)
		1:
			# Stage a region for editing: stream it in and hold it resident (pinned). Only
			# pin if it actually loaded, or a saturated pool leaves a phantom pin on a
			# non-resident region that Save cannot clear.
			if _terrain.data.ensure_region_resident(_ctx_loc) != null:
				_terrain.data.set_region_pinned(_ctx_loc, true)
				_teleport_to(_ctx_loc)
			else:
				push_warning("Could not load region %s: streaming pool is full of unsaved edits. Save some first." % _ctx_loc)
		2:
			_terrain.data.revert_region(_ctx_loc)
	_refresh()


func _on_minimap_toggled(p_on: bool) -> void:
	if _grid != null:
		_grid.set_minimap_enabled(p_on)


# Saves every region with an unsaved edit. save_region unpins each on success, freeing
# pool slots. Iterates a snapshot so clearing the pinned set mid-loop is safe.
func _on_save_edits() -> void:
	if not _valid():
		return
	var save_16: bool = _terrain.save_16_bit
	for loc in _terrain.data.get_pinned_locations():
		_terrain.data.save_region(loc, _terrain.data_directory, save_16)
	_refresh()


# Cycles the editor camera through the regions with unsaved edits, so scattered edits on a
# large world are easy to find and review before saving. Sorted for a stable walk order.
func _on_next_unsaved() -> void:
	if not _valid():
		return
	var pins: Array = _terrain.data.get_pinned_locations()
	if pins.is_empty():
		return
	pins.sort_custom(func(a, b): return a.y < b.y or (a.y == b.y and a.x < b.x))
	_dirty_cycle = _dirty_cycle % pins.size()
	_teleport_to(Vector2i(pins[_dirty_cycle]))
	_dirty_cycle += 1


func _on_recenter() -> void:
	_frame(Vector3.ZERO) # back to the world origin


func _teleport_to(p_location: Vector2i) -> void:
	if not _valid():
		return
	var span: float = float(_terrain.region_size) * _terrain.vertex_spacing
	_frame(Vector3((float(p_location.x) + 0.5) * span, 0.0, (float(p_location.y) + 0.5) * span))


# Frames the editor 3D camera on a world point so the grid drives navigation. Done
# here rather than through the plugin so it works whether or not the node is selected.
func _frame(p_center: Vector3) -> void:
	if not _valid():
		return
	var span: float = float(_terrain.region_size) * _terrain.vertex_spacing
	var vp := EditorInterface.get_editor_viewport_3d(0)
	var cam: Camera3D = vp.get_camera_3d() if vp != null else null
	if cam != null:
		# Flatten the pull-back to horizontal so a top-down camera does not make look_at
		# colinear with the up vector and silently no-op.
		var back: Vector3 = cam.global_transform.basis.z
		back.y = 0.0
		back = back.normalized() if back.length() > 0.01 else Vector3(0, 0, 1)
		cam.look_at_from_position(p_center + back * span * 1.5 + Vector3(0, span, 0), p_center)


func _valid() -> bool:
	return is_instance_valid(_terrain) and _terrain.data != null
