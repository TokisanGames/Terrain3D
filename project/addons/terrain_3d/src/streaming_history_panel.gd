# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Terrain Edits history dock. A timeline of committed edits under editor streaming: each
# row is one operation; clicking it teleports the editor camera to the edited region.
# Read only navigation, undo/redo stays on the native Ctrl+Z stack.
@tool
extends PanelContainer

const MAP_NAMES := ["height", "control", "color"]
const MAX_ROWS := 500

var plugin: EditorPlugin
var _dock: Object # EditorDock on 4.6+, null on older editors
var _list: ItemList
var _editor: Object


func initialize(p_plugin: EditorPlugin) -> void:
	plugin = p_plugin
	name = "Terrain Edits"
	_build()
	# The editor object is created once by the plugin and lives for the session.
	_editor = plugin.editor
	if _editor != null and not _editor.edit_committed.is_connected(_on_edit_committed):
		_editor.edit_committed.connect(_on_edit_committed)
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
	if _list != null:
		_list.clear()


func remove_dock() -> void:
	if is_instance_valid(plugin) and plugin.scene_changed.is_connected(_on_scene_changed):
		plugin.scene_changed.disconnect(_on_scene_changed)
	if is_instance_valid(_editor) and _editor.edit_committed.is_connected(_on_edit_committed):
		_editor.edit_committed.disconnect(_on_edit_committed)
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
	clear.tooltip_text = "Clear the edit timeline. Does not affect undo."
	clear.pressed.connect(func(): _list.clear())
	header.add_child(clear)

	_list = ItemList.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.custom_minimum_size = Vector2(0, 160)
	_list.item_activated.connect(_on_row_activated)
	root.add_child(_list)

	var hint := Label.new()
	hint.text = "Double-click a row to jump there. Undo with Ctrl+Z."
	hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	root.add_child(hint)


func _on_edit_committed(p_descriptor: Dictionary) -> void:
	var locs: Array = p_descriptor.get("locations", [])
	var loc: Vector2i = Vector2i(locs[0]) if not locs.is_empty() else Vector2i.ZERO
	# The REGION tool edits no map, so label it by the add/remove operation instead.
	var label: String
	if int(p_descriptor.get("tool", -1)) == Terrain3DEditor.REGION:
		label = "region remove" if int(p_descriptor.get("operation", -1)) == Terrain3DEditor.SUBTRACT else "region add"
	else:
		var map_i: int = int(p_descriptor.get("map_type", 0))
		label = MAP_NAMES[map_i] if map_i >= 0 and map_i < MAP_NAMES.size() else "map"
	var extra: String = "  (+%d)" % (locs.size() - 1) if locs.size() > 1 else ""
	var text := "#%d  (%d,%d)  %s%s" % [int(p_descriptor.get("index", 0)), loc.x, loc.y, label, extra]
	var idx := _list.add_item(text)
	_list.set_item_metadata(idx, loc)
	_list.ensure_current_is_visible()
	# Bound the timeline so a long session does not grow it without limit.
	while _list.item_count > MAX_ROWS:
		_list.remove_item(0)


func _on_row_activated(p_index: int) -> void:
	var loc: Vector2i = _list.get_item_metadata(p_index)
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
