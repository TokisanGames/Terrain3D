# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Terrain Edits history dock. A timeline of edits made under editor streaming. Consecutive
# edits to the same region collapse into one row with a count; each row shows the tool, its
# save state, and when it was made. Double-clicking a row teleports the editor camera to the
# region; unsaved rows carry a Save button. Undone edits grey out and return on redo, so the
# list mirrors the native Ctrl+Z / Ctrl+Shift+Z stack. It navigates and saves, but the edits
# themselves live on the terrain data, not here.
@tool
extends PanelContainer

const ICON_DIR := "res://addons/terrain_3d/icons/"
const MAP_NAMES := ["height", "control", "color"]
const MAX_GROUPS := 400
const REFRESH_INTERVAL := 0.5

const COLOR_UNSAVED := Color(0.95, 0.68, 0.18)
const COLOR_SAVED := Color(0.55, 0.75, 0.55)
const COLOR_UNDONE := Color(0.5, 0.5, 0.55)
const COL_SAVE := 2

var plugin: EditorPlugin
var _dock: Object # EditorDock on 4.6+, null on older editors
var _tree: Tree
var _editor: Object

# One entry per row: { loc, tool, op, map_type, label, indices: Array[int], first_ms }.
var _groups: Array = []
var _index_group := {} # edit index -> its group Dictionary
var _undone := {} # edit index -> true while sitting on the redo side of the stack
var _icon_cache := {}
var _accum := 0.0


func initialize(p_plugin: EditorPlugin) -> void:
	plugin = p_plugin
	name = "Terrain Edits"
	_build()
	set_process(true)
	# The editor object is created once by the plugin and lives for the session.
	_editor = plugin.editor
	if _editor != null and not _editor.edit_committed.is_connected(_on_edit_committed):
		_editor.edit_committed.connect(_on_edit_committed)
	if _editor != null and not _editor.edit_reverted.is_connected(_on_edit_reverted):
		_editor.edit_reverted.connect(_on_edit_reverted)
	# Reset the timeline when the edited scene changes; its rows belong to that scene.
	if not plugin.scene_changed.is_connected(_on_scene_changed):
		plugin.scene_changed.connect(_on_scene_changed)
	if ClassDB.class_exists("EditorDock"):
		_dock = ClassDB.instantiate("EditorDock")
		_dock.title = "Terrain Edits"
		_dock.default_slot = 5 # EditorDock DOCK_SLOT_RIGHT_BL (bottom of the right column)
		_dock.closable = true
		_dock.available_layouts = 0x7
		_dock.add_child(self)
		plugin.add_dock(_dock)
		_dock.open()
	else:
		plugin.add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_BL, self)


func _on_scene_changed(_scene_root: Node) -> void:
	_clear_all()


func remove_dock() -> void:
	if is_instance_valid(plugin) and plugin.scene_changed.is_connected(_on_scene_changed):
		plugin.scene_changed.disconnect(_on_scene_changed)
	if is_instance_valid(_editor) and _editor.edit_committed.is_connected(_on_edit_committed):
		_editor.edit_committed.disconnect(_on_edit_committed)
	if is_instance_valid(_editor) and _editor.edit_reverted.is_connected(_on_edit_reverted):
		_editor.edit_reverted.disconnect(_on_edit_reverted)
	if not is_instance_valid(plugin):
		return
	if _dock != null:
		plugin.remove_dock(_dock)
		_dock.queue_free()
	else:
		plugin.remove_control_from_docks(self)
		queue_free()


func _build() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	add_child(root)

	var header := HBoxContainer.new()
	root.add_child(header)
	var title := Label.new()
	title.text = "Terrain Edits"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var clear := Button.new()
	clear.text = "Clear"
	clear.tooltip_text = "Clear the edit timeline. Does not affect undo or saved data."
	clear.pressed.connect(_clear_all)
	header.add_child(clear)

	_tree = Tree.new()
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.custom_minimum_size = Vector2(0, 160)
	_tree.hide_root = true
	_tree.columns = 4
	_tree.set_column_title(0, "Region")
	_tree.set_column_title(1, "Edit")
	_tree.set_column_title(COL_SAVE, "State")
	_tree.set_column_title(3, "When")
	_tree.column_titles_visible = true
	_tree.set_column_expand(0, true)
	_tree.set_column_expand(1, true)
	_tree.set_column_expand(COL_SAVE, false)
	_tree.set_column_expand(3, false)
	_tree.set_column_custom_minimum_width(COL_SAVE, 74)
	_tree.set_column_custom_minimum_width(3, 48)
	_tree.item_activated.connect(_on_row_activated)
	_tree.button_clicked.connect(_on_button_clicked)
	root.add_child(_tree)

	var hint := Label.new()
	hint.text = "Double-click a row to jump there. Undo with Ctrl+Z."
	hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	root.add_child(hint)


func _on_edit_committed(p_descriptor: Dictionary) -> void:
	var idx: int = int(p_descriptor.get("index", 0))
	if _index_group.has(idx):
		# Redo re-emits the original descriptor: bring the edit back to the active side.
		_undone.erase(idx)
		_rebuild()
		return
	# A brand new edit discards anything still sitting on the redo side, the way the native
	# undo stack drops the redo branch when you act after undoing.
	if not _undone.is_empty():
		_purge_undone()
	var locs: Array = p_descriptor.get("locations", [])
	var loc: Vector2i = Vector2i(locs[0]) if not locs.is_empty() else Vector2i.ZERO
	var tool: int = int(p_descriptor.get("tool", -1))
	var op: int = int(p_descriptor.get("operation", -1))
	var map_type: int = int(p_descriptor.get("map_type", 0))
	# Collapse only into the most recent row, so a return to an earlier region starts a fresh
	# row rather than merging across intervening edits.
	var g: Dictionary = _groups.back() if not _groups.is_empty() else {}
	if g.is_empty() or g.loc != loc or g.tool != tool or g.op != op or g.map_type != map_type:
		g = {
			"loc": loc, "tool": tool, "op": op, "map_type": map_type,
			"label": _edit_label(tool, op, map_type), "indices": [], "first_ms": Time.get_ticks_msec(),
		}
		_groups.append(g)
		while _groups.size() > MAX_GROUPS:
			var dropped: Dictionary = _groups.pop_front()
			for i in dropped.indices:
				_index_group.erase(i)
	g.indices.append(idx)
	_index_group[idx] = g
	_rebuild()


func _on_edit_reverted(p_edit_index: int) -> void:
	if _index_group.has(p_edit_index):
		_undone[p_edit_index] = true
		_rebuild()


# Drop the undone edits for good; their rows and index bookkeeping go with them.
func _purge_undone() -> void:
	for idx in _undone.keys():
		var g: Dictionary = _index_group.get(idx, {})
		if not g.is_empty():
			g.indices.erase(idx)
		_index_group.erase(idx)
	_groups = _groups.filter(func(x): return not x.indices.is_empty())
	_undone.clear()


func _clear_all() -> void:
	_groups.clear()
	_index_group.clear()
	_undone.clear()
	_rebuild()


# Active edits in a group are those not currently sitting on the redo side.
func _active_count(p_group: Dictionary) -> int:
	var n := 0
	for i in p_group.indices:
		if not _undone.has(i):
			n += 1
	return n


func _rebuild() -> void:
	if _tree == null:
		return
	_tree.clear()
	var rootitem := _tree.create_item()
	var data: Object = _terrain_data()
	for g in _groups:
		var active := _active_count(g)
		var total: int = g.indices.size()
		var count: int = active if active > 0 else total
		var undone := active == 0
		var pinned: bool = false
		if data != null and not undone:
			pinned = data.is_region_pinned(g.loc)

		var row := _tree.create_item(rootitem)
		row.set_icon(0, _tool_icon(g.tool, g.op))
		row.set_icon_max_width(0, 16)
		row.set_text(0, "(%d, %d)" % [g.loc.x, g.loc.y])
		row.set_text(1, g.label + ("  ×%d" % count if count > 1 else ""))
		row.set_metadata(0, g.loc)
		row.set_tooltip_text(0, "Region (%d, %d)" % [g.loc.x, g.loc.y])

		if undone:
			row.set_text(COL_SAVE, "undone")
			for c in range(4):
				row.set_custom_color(c, COLOR_UNDONE)
		elif pinned:
			row.set_text(COL_SAVE, "unsaved")
			row.set_custom_color(COL_SAVE, COLOR_UNSAVED)
			row.add_button(COL_SAVE, _save_icon(), 0, false, "Save this region to disk")
		else:
			row.set_text(COL_SAVE, "saved")
			row.set_custom_color(COL_SAVE, COLOR_SAVED)

		row.set_text(3, _ago(g.first_ms))
		row.set_custom_color(3, Color(0.6, 0.6, 0.65))


# Editor tool node: the editor drives _process. Refresh on an interval so the relative time
# and each region's saved state track without a Timer.
func _process(p_delta: float) -> void:
	_accum += p_delta
	if _accum < REFRESH_INTERVAL:
		return
	_accum = 0.0
	if not _groups.is_empty():
		_rebuild()


func _on_row_activated() -> void:
	var item := _tree.get_selected()
	if item == null:
		return
	var loc: Vector2i = item.get_metadata(0)
	var terrain := _find_terrain()
	if terrain == null:
		return
	var span: float = float(terrain.region_size) * terrain.vertex_spacing
	var center := Vector3((float(loc.x) + 0.5) * span, 0.0, (float(loc.y) + 0.5) * span)
	var vp := EditorInterface.get_editor_viewport_3d(0)
	var cam: Camera3D = vp.get_camera_3d() if vp != null else null
	if cam != null:
		# Flatten the pull-back to horizontal so it never lines up with the up vector
		# (a top-down camera would make look_at colinear and silently no-op).
		var back: Vector3 = cam.global_transform.basis.z
		back.y = 0.0
		back = back.normalized() if back.length() > 0.01 else Vector3(0, 0, 1)
		cam.look_at_from_position(center + back * span * 1.5 + Vector3(0, span, 0), center)


func _on_button_clicked(p_item: TreeItem, _p_column: int, _p_id: int, _p_mouse: int) -> void:
	var loc: Vector2i = p_item.get_metadata(0)
	var terrain := _find_terrain()
	if terrain == null or terrain.data == null:
		return
	terrain.data.save_region(loc, terrain.data_directory, terrain.save_16_bit)
	_rebuild()


func _edit_label(p_tool: int, p_op: int, p_map_type: int) -> String:
	if p_tool == Terrain3DEditor.REGION:
		return "region remove" if p_op == Terrain3DEditor.SUBTRACT else "region add"
	if p_tool == Terrain3DEditor.INSTANCER:
		return "instances"
	return MAP_NAMES[p_map_type] if p_map_type >= 0 and p_map_type < MAP_NAMES.size() else "map"


func _tool_icon(p_tool: int, p_op: int) -> Texture2D:
	var icon_name := "terrain3d"
	match p_tool:
		Terrain3DEditor.REGION:
			icon_name = "region_remove" if p_op == Terrain3DEditor.SUBTRACT else "region_add"
		Terrain3DEditor.SCULPT:
			icon_name = "height_add"
		Terrain3DEditor.HEIGHT:
			icon_name = "height_flat"
		Terrain3DEditor.TEXTURE:
			icon_name = "texture_paint"
		Terrain3DEditor.COLOR:
			icon_name = "color_paint"
		Terrain3DEditor.ROUGHNESS:
			icon_name = "wetness"
		Terrain3DEditor.AUTOSHADER:
			icon_name = "autoshader"
		Terrain3DEditor.HOLES:
			icon_name = "holes"
		Terrain3DEditor.NAVIGATION:
			icon_name = "navigation"
		Terrain3DEditor.INSTANCER:
			icon_name = "multimesh"
	if not _icon_cache.has(icon_name):
		_icon_cache[icon_name] = load(ICON_DIR + icon_name + ".svg")
	return _icon_cache[icon_name]


func _save_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon("Save", "EditorIcons")


func _ago(p_first_ms: int) -> String:
	var secs: int = maxi(0, (Time.get_ticks_msec() - p_first_ms) / 1000)
	if secs < 60:
		return "%ds" % secs
	if secs < 3600:
		return "%dm" % (secs / 60)
	return "%dh" % (secs / 3600)


func _terrain_data() -> Object:
	var t := _find_terrain()
	return t.data if t != null else null


func _find_terrain() -> Terrain3D:
	if is_instance_valid(plugin) and is_instance_valid(plugin.terrain):
		return plugin.terrain
	var root: Node = EditorInterface.get_edited_scene_root()
	return _walk(root) if root != null else null


func _walk(p_node: Node) -> Terrain3D:
	if p_node is Terrain3D:
		return p_node
	for c in p_node.get_children():
		var r := _walk(c)
		if r != null:
			return r
	return null
