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
	_terrain = p_terrain
	if _grid != null:
		_grid.set_terrain(p_terrain)
	_refresh()


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


func _refresh() -> void:
	if _grid != null:
		_grid.refresh()
	if not _valid():
		_stats.text = "Select a Terrain3D node."
		_meter.value = 0
		_meter_label.text = "0 / 0"
		return
	var s: Dictionary = _terrain.get_streaming_stats()
	var resident: int = int(s.get("resident", 0))
	var slots: int = _terrain.data.get_slot_capacity() if _terrain.data != null else 0
	_meter.max_value = maxi(slots, 1)
	_meter.value = resident
	_meter_label.text = "%d / %d" % [resident, slots]
	_stats.text = "mode %s   in flight %d   failed %d   known %d\nlanded %d   evicted %d" % [
		s.get("mode", "-"), int(s.get("inflight", 0)), int(s.get("failed", 0)),
		int(s.get("known", 0)), int(s.get("landed_total", 0)), int(s.get("evicted_total", 0))]


func _on_cell_clicked(p_location: Vector2i) -> void:
	_teleport_to(p_location)


func _on_minimap_toggled(p_on: bool) -> void:
	if _grid != null:
		_grid.set_minimap_enabled(p_on)


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
		var back: Vector3 = cam.global_transform.basis.z
		cam.look_at_from_position(p_center + back * span * 1.5 + Vector3(0, span, 0), p_center)


func _valid() -> bool:
	return is_instance_valid(_terrain) and _terrain.data != null
