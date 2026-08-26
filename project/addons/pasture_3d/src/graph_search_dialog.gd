# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphSearchDialog — floating quick-search palette for Pasture3D terrain graph nodes (Tab / Space / Right-click).
# Allows instant fuzzy/keyword search, keyboard navigation (Up/Down/Enter/Escape), and fast node insertion.
@tool
class_name Pasture3DGraphSearchDialog
extends PopupPanel

signal node_selected(op: StringName, position: Vector2)

var _target_position: Vector2 = Vector2.ZERO
var _search_input: LineEdit
var _tree: Tree
var _results: Array[Dictionary] = []


func _init() -> void:
	gui_embed_subwindows = false
	_build_ui()


func _build_ui() -> void:
	size = Vector2i(300, 320)
	min_size = Vector2i(260, 240)
	
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(vbox)
	
	_search_input = LineEdit.new()
	_search_input.placeholder_text = "Search nodes (e.g. noise, blur, blend)..."
	_search_input.clear_button_enabled = true
	_search_input.text_changed.connect(_on_search_text_changed)
	_search_input.gui_input.connect(_on_search_input_gui_input)
	vbox.add_child(_search_input)
	
	_tree = Tree.new()
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.columns = 2
	_tree.set_column_title(0, "Node")
	_tree.set_column_title(1, "Role")
	_tree.set_column_expand(0, true)
	_tree.set_column_expand(1, false)
	_tree.set_column_custom_minimum_width(1, 80)
	_tree.column_titles_visible = false
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_ROW
	_tree.item_activated.connect(_on_tree_item_activated)
	vbox.add_child(_tree)
	
	popup_hide.connect(_on_popup_hide)


## Opens the search palette at the given global screen position, associating it with `p_graph_pos`
## (in graph canvas position_offset coordinates).
func open_at(p_screen_pos: Vector2, p_graph_pos: Vector2) -> void:
	_target_position = p_graph_pos
	_search_input.text = ""
	_refresh_tree("")
	
	reset_size()
	position = Vector2i(p_screen_pos.round())
	popup()
	_search_input.grab_focus()
	_search_input.select_all()


func _refresh_tree(p_query: String) -> void:
	_tree.clear()
	var root := _tree.create_item()
	_results = Pasture3DGraphNodeRegistry.search(p_query)
	
	var first_item: TreeItem = null
	for entry in _results:
		var item := _tree.create_item(root)
		var op_name: StringName = entry.get("op", &"")
		var title: String = entry.get("title", String(op_name))
		var role: String = entry.get("role", "")
		var desc: String = entry.get("description", "")
		
		item.set_text(0, title)
		item.set_text(1, role)
		item.set_tooltip_text(0, "%s (%s)\n%s" % [title, role, desc])
		item.set_tooltip_text(1, "%s (%s)\n%s" % [title, role, desc])
		item.set_metadata(0, op_name)
		
		# Role color accents
		match role.to_lower():
			"generator":
				item.set_custom_color(1, Color(0.4, 0.8, 1.0))
			"filter":
				item.set_custom_color(1, Color(1.0, 0.75, 0.4))
			"combiner":
				item.set_custom_color(1, Color(0.8, 0.5, 1.0))
			"source", "sink":
				item.set_custom_color(1, Color(0.5, 1.0, 0.6))
				
		if first_item == null:
			first_item = item
			
	if first_item != null:
		first_item.select(0)


func _on_search_text_changed(p_new_text: String) -> void:
	_refresh_tree(p_new_text)


func _on_search_input_gui_input(p_event: InputEvent) -> void:
	if p_event is InputEventKey and p_event.pressed:
		match p_event.keycode:
			KEY_ENTER, KEY_KP_ENTER:
				_confirm_selection()
				get_viewport().set_input_as_handled()
			KEY_DOWN:
				_navigate_tree(1)
				get_viewport().set_input_as_handled()
			KEY_UP:
				_navigate_tree(-1)
				get_viewport().set_input_as_handled()
			KEY_ESCAPE:
				hide()
				get_viewport().set_input_as_handled()


func _navigate_tree(p_delta: int) -> void:
	var selected := _tree.get_selected()
	if selected == null:
		var root := _tree.get_root()
		if root and root.get_first_child():
			root.get_first_child().select(0)
		return
		
	var target: TreeItem = null
	if p_delta > 0:
		target = selected.get_next()
	else:
		target = selected.get_prev()
		
	if target != null:
		target.select(0)
		_tree.scroll_to_item(target)


func _confirm_selection() -> void:
	var selected := _tree.get_selected()
	if selected != null:
		var op: StringName = selected.get_metadata(0)
		if not op.is_empty():
			hide()
			node_selected.emit(op, _target_position)


func _on_tree_item_activated() -> void:
	_confirm_selection()


func _on_popup_hide() -> void:
	pass
