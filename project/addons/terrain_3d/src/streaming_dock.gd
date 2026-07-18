# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Terrain Streaming dock. A spatial view of region residency plus the streaming
# controls, so a world too large to hold in memory can be opened and navigated. Read
# only in this form: it shows and drives streaming but does not edit terrain data.
@tool
extends PanelContainer

const RegionMapControl: Script = preload("res://addons/terrain_3d/src/region_map_control.gd")
const REFRESH_INTERVAL: float = 0.5

var plugin: EditorPlugin
var _terrain: Terrain3D

var _grid: Control
var _meter: ProgressBar
var _meter_label: Label
var _stats: Label
var _editor_check: CheckBox
var _enabled_check: CheckBox
var _distance_spin: SpinBox
var _slots_spin: SpinBox
var _shape_option: OptionButton
var _mode_option: OptionButton
var _timer: Timer
var _syncing: bool = false


func initialize(p_plugin: EditorPlugin) -> void:
	plugin = p_plugin
	name = "Terrain Stream"
	_build()
	_timer = Timer.new()
	_timer.wait_time = REFRESH_INTERVAL
	_timer.timeout.connect(_on_refresh)
	add_child(_timer)
	_timer.start()
	plugin.add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_BL, self)


func remove_dock() -> void:
	if is_instance_valid(plugin):
		plugin.remove_control_from_docks(self)


func set_terrain(p_terrain: Terrain3D) -> void:
	_terrain = p_terrain
	if _grid != null:
		_grid.set_terrain(p_terrain)
	_sync_controls()
	_on_refresh()


func _build() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	var title := Label.new()
	title.text = "Terrain Streaming"
	root.add_child(title)

	_grid = RegionMapControl.new()
	_grid.custom_minimum_size = Vector2(0, 180)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid.cell_clicked.connect(_on_cell_clicked)
	root.add_child(_grid)

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

	root.add_child(HSeparator.new())

	_editor_check = CheckBox.new()
	_editor_check.text = "Editor streaming"
	_editor_check.tooltip_text = "Stream regions in the editor. Editing is read only while on."
	_editor_check.toggled.connect(_on_editor_toggled)
	root.add_child(_editor_check)

	_enabled_check = CheckBox.new()
	_enabled_check.text = "Streaming enabled"
	_enabled_check.toggled.connect(_on_enabled_toggled)
	root.add_child(_enabled_check)

	_distance_spin = _add_labeled_spin(root, "Distance", 1, 15, _on_distance_changed)
	_slots_spin = _add_labeled_spin(root, "Slots", 25, 1024, _on_slots_changed)

	_shape_option = _add_labeled_option(root, "Shape", ["Square", "Circle"], _on_shape_changed)
	_mode_option = _add_labeled_option(root, "Mode", ["Disk", "RAM"], _on_mode_changed)


func _add_labeled_spin(p_parent: Node, p_label: String, p_min: int, p_max: int, p_cb: Callable) -> SpinBox:
	var box := HBoxContainer.new()
	p_parent.add_child(box)
	var lbl := Label.new()
	lbl.text = p_label
	lbl.custom_minimum_size = Vector2(70, 0)
	box.add_child(lbl)
	var spin := SpinBox.new()
	spin.min_value = p_min
	spin.max_value = p_max
	spin.step = 1
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.value_changed.connect(p_cb)
	box.add_child(spin)
	return spin


func _add_labeled_option(p_parent: Node, p_label: String, p_items: Array, p_cb: Callable) -> OptionButton:
	var box := HBoxContainer.new()
	p_parent.add_child(box)
	var lbl := Label.new()
	lbl.text = p_label
	lbl.custom_minimum_size = Vector2(70, 0)
	box.add_child(lbl)
	var opt := OptionButton.new()
	for item in p_items:
		opt.add_item(item)
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.item_selected.connect(p_cb)
	box.add_child(opt)
	return opt


# Pushes the terrain's current streaming settings into the controls without echoing
# each change back to the terrain.
func _sync_controls() -> void:
	if not _valid():
		return
	_syncing = true
	_editor_check.button_pressed = _terrain.streaming_editor
	_enabled_check.button_pressed = _terrain.streaming_enabled
	_distance_spin.value = _terrain.streaming_distance
	_slots_spin.value = _terrain.streaming_slots
	_shape_option.selected = _terrain.streaming_shape
	_mode_option.selected = _terrain.streaming_mode
	_syncing = false


func _on_refresh() -> void:
	if not is_visible_in_tree():
		return
	if _grid != null:
		_grid.refresh()
	if not _valid():
		_stats.text = "No terrain selected."
		_meter.value = 0
		_meter_label.text = "0 / 0"
		return
	var s: Dictionary = _terrain.get_streaming_stats()
	var resident: int = int(s.get("resident", 0))
	var slots: int = _terrain.data.get_slot_capacity() if _terrain.data != null else 0
	_meter.max_value = maxi(slots, 1)
	_meter.value = resident
	_meter_label.text = "%d / %d" % [resident, slots]
	# Color toward red as residency approaches the pool wall.
	var frac: float = float(resident) / float(maxi(slots, 1))
	_meter.add_theme_color_override("fill", Color(0.35, 0.7, 0.4).lerp(Color(0.85, 0.3, 0.25), clampf(frac, 0.0, 1.0)))
	_stats.text = "mode %s   in flight %d   failed %d   known %d\nlanded %d   evicted %d" % [
		s.get("mode", "-"), int(s.get("inflight", 0)), int(s.get("failed", 0)),
		int(s.get("known", 0)), int(s.get("landed_total", 0)), int(s.get("evicted_total", 0))]


func _on_cell_clicked(p_location: Vector2i) -> void:
	if _valid() and plugin.has_method("focus_region"):
		plugin.focus_region(p_location)


func _on_editor_toggled(p_on: bool) -> void:
	if not _syncing and _valid():
		_terrain.streaming_editor = p_on


func _on_enabled_toggled(p_on: bool) -> void:
	if not _syncing and _valid():
		_terrain.streaming_enabled = p_on


func _on_distance_changed(p_value: float) -> void:
	if not _syncing and _valid():
		_terrain.streaming_distance = int(p_value)
		_sync_controls() # distance can grow slots, reflect it


func _on_slots_changed(p_value: float) -> void:
	if not _syncing and _valid():
		_terrain.streaming_slots = int(p_value)
		_sync_controls() # slots can pull distance down


func _on_shape_changed(p_index: int) -> void:
	if not _syncing and _valid():
		_terrain.streaming_shape = p_index


func _on_mode_changed(p_index: int) -> void:
	if not _syncing and _valid():
		_terrain.streaming_mode = p_index


func _valid() -> bool:
	return is_instance_valid(_terrain) and _terrain.data != null
