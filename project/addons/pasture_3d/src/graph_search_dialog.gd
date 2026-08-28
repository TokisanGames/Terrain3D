# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphSearchDialog — floating quick-search palette for Pasture3D terrain graph nodes (Tab / Space / Right-click).
# Allows instant fuzzy/keyword search, categorized expandable browsing, keyboard navigation (Up/Down/Enter/Escape),
# and fast node insertion.
@tool
class_name Pasture3DGraphSearchDialog
extends PopupPanel

signal node_selected(op: StringName, position: Vector2)

var _target_position: Vector2 = Vector2.ZERO
var _search_input: LineEdit
var _tree: Tree
var _category_collapse_states: Dictionary = {}


func _init() -> void:
	gui_embed_subwindows = false
	_build_ui()


func _build_ui() -> void:
	size = Vector2i(320, 360)
	min_size = Vector2i(280, 260)
	
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(vbox)
	
	_search_input = LineEdit.new()
	_search_input.placeholder_text = "Search nodes (e.g. noise, blur, const)..."
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
	_tree.item_collapsed.connect(_on_tree_item_collapsed)
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
	var query := p_query.strip_edges()
	var is_searching := not query.is_empty()
	var results: Array[Dictionary] = Pasture3DGraphNodeRegistry.search(query)
	
	# Group results by category
	var cat_map: Dictionary = {}
	for cat in Pasture3DGraphNodeRegistry.categories():
		cat_map[cat] = []
	for entry in results:
		var cat: String = entry.get("category", "Generators")
		if not cat_map.has(cat):
			cat_map[cat] = []
		(cat_map[cat] as Array).append(entry)
	
	var first_leaf: TreeItem = null
	
	for cat_name in Pasture3DGraphNodeRegistry.categories():
		var items_in_cat: Array = cat_map.get(cat_name, [])
		if items_in_cat.is_empty():
			continue
			
		var cat_item := _tree.create_item(root)
		cat_item.set_text(0, "▼ " + cat_name if is_searching else cat_name)
		cat_item.set_selectable(0, false)
		cat_item.set_selectable(1, false)
		cat_item.set_custom_color(0, Color(0.75, 0.85, 0.98))
		
		# In search mode, auto-expand; in browse mode, restore user collapse state (default expanded)
		var is_collapsed: bool = false
		if not is_searching and _category_collapse_states.has(cat_name):
			is_collapsed = bool(_category_collapse_states[cat_name])
		cat_item.collapsed = is_collapsed
		cat_item.set_metadata(1, cat_name) # Store category name for collapse tracking
		
		for entry in items_in_cat:
			var item := _tree.create_item(cat_item)
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
				"solver":
					item.set_custom_color(1, Color(0.4, 1.0, 0.8))
				"constant":
					item.set_custom_color(1, Color(0.2, 0.9, 0.7))
				"source", "sink":
					item.set_custom_color(1, Color(0.5, 1.0, 0.6))
				"utility":
					item.set_custom_color(1, Color(0.9, 0.9, 0.5))
				"dev / reference":
					item.set_custom_color(1, Color(1.0, 0.4, 0.4))
					
			if first_leaf == null:
				first_leaf = item
				
	if first_leaf != null:
		first_leaf.select(0)


func _on_tree_item_collapsed(p_item: TreeItem) -> void:
	var cat_name = p_item.get_metadata(1)
	if cat_name is String and not cat_name.is_empty():
		_category_collapse_states[cat_name] = p_item.collapsed


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
		_select_first_leaf()
		return
		
	var target: TreeItem = selected
	while true:
		if p_delta > 0:
			target = _get_next_visible_leaf(target)
		else:
			target = _get_prev_visible_leaf(target)
			
		if target == null or target == selected:
			break
		if not target.get_metadata(0) == null and not StringName(target.get_metadata(0)).is_empty():
			target.select(0)
			_tree.scroll_to_item(target)
			break


func _select_first_leaf() -> void:
	var root := _tree.get_root()
	if root == null:
		return
	var item := root.get_first_child()
	while item != null:
		if item.get_child_count() > 0 and not item.collapsed:
			item = item.get_first_child()
		else:
			if item.get_metadata(0) != null and not StringName(item.get_metadata(0)).is_empty():
				item.select(0)
				_tree.scroll_to_item(item)
				return
			item = item.get_next()


func _get_next_visible_leaf(p_item: TreeItem) -> TreeItem:
	if p_item == null:
		return null
	var nxt := p_item.get_next()
	if nxt != null:
		return nxt
	var parent := p_item.get_parent()
	if parent != null and parent != _tree.get_root():
		var p_nxt := parent.get_next()
		while p_nxt != null:
			if p_nxt.get_child_count() > 0 and not p_nxt.collapsed:
				return p_nxt.get_first_child()
			p_nxt = p_nxt.get_next()
	return null


func _get_prev_visible_leaf(p_item: TreeItem) -> TreeItem:
	if p_item == null:
		return null
	var prev := p_item.get_prev()
	if prev != null:
		return prev
	var parent := p_item.get_parent()
	if parent != null and parent != _tree.get_root():
		var p_prev := parent.get_prev()
		while p_prev != null:
			if p_prev.get_child_count() > 0 and not p_prev.collapsed:
				var last_child := p_prev.get_first_child()
				while last_child.get_next() != null:
					last_child = last_child.get_next()
				return last_child
			p_prev = p_prev.get_prev()
	return null


func _confirm_selection() -> void:
	var selected := _tree.get_selected()
	if selected != null:
		var op: StringName = selected.get_metadata(0) if selected.get_metadata(0) != null else &""
		if not op.is_empty():
			hide()
			node_selected.emit(op, _target_position)


func _on_tree_item_activated() -> void:
	_confirm_selection()


func _on_popup_hide() -> void:
	pass
