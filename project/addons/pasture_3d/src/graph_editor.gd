# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphEditor — the bottom-panel visual editor for a Pasture3DTerrainGraph, built on Godot's
# GraphEdit/GraphNode (the same controls the VisualShader / Shader Graph editor uses). The canvas owns
# TOPOLOGY — nodes, wiring and which node is the output; a node's parameters can be edited inline or in
# Godot's normal Inspector. See PASTURE3D_TERRAIN_GRAPH_USABILITY_SPEC.md.
#
# All structural edits go through undo/redo actions operating on Pasture3DTerrainGraph.
@tool
class_name Pasture3DGraphEditor
extends VBoxContainer

const SearchDialogScript = preload("res://addons/pasture_3d/src/graph_search_dialog.gd")

var plugin: EditorPlugin
var graph: Pasture3DTerrainGraph

var _graphedit: GraphEdit
var _search_dialog: PopupPanel
var _add_button: Button
var _minimap_button: Button
var _arrange_button: Button
var _title: Label
var _hint: Label

## Standalone fallback when running without EditorPlugin (e.g. tests)
var _local_undo_redo: UndoRedo = UndoRedo.new()

## Internal clipboard for copy/cut/paste
var _clipboard: Dictionary = {}

## Track previous node positions for undo/redo move actions
var _drag_start_positions: Dictionary = {}


func initialize(p_plugin: EditorPlugin) -> void:
	plugin = p_plugin
	_build_ui()
	if plugin:
		plugin.add_control_to_bottom_panel(self, "Terrain Graph")


func remove_dock() -> void:
	edit_graph(null)
	if plugin:
		plugin.remove_control_from_bottom_panel(self)


## Bind the panel to a graph (or null). Reconnects the `changed` -> rebuild link and redraws.
func edit_graph(p_graph: Pasture3DTerrainGraph) -> void:
	if graph == p_graph:
		_rebuild()
		return
	if graph != null and graph.changed.is_connected(_rebuild):
		graph.changed.disconnect(_rebuild)
	graph = p_graph
	if graph != null and not graph.changed.is_connected(_rebuild):
		graph.changed.connect(_rebuild)
	_rebuild()


func _build_ui() -> void:
	custom_minimum_size = Vector2(0, 240)
	
	var bar := HBoxContainer.new()
	add_child(bar)
	
	_add_button = Button.new()
	_add_button.text = "Add Node"
	_add_button.tooltip_text = "Add a new node to the graph (or press Tab / Space over canvas)"
	_add_button.pressed.connect(_on_add_button_pressed)
	bar.add_child(_add_button)
	
	_minimap_button = Button.new()
	_minimap_button.text = "Minimap"
	_minimap_button.toggle_mode = true
	_minimap_button.button_pressed = false
	_minimap_button.tooltip_text = "Toggle canvas navigation minimap"
	_minimap_button.toggled.connect(_on_minimap_toggled)
	bar.add_child(_minimap_button)
	
	_arrange_button = Button.new()
	_arrange_button.text = "Arrange"
	_arrange_button.tooltip_text = "Automatically arrange graph nodes into a clean layout"
	_arrange_button.pressed.connect(func(): if _graphedit: _graphedit.arrange_nodes())
	bar.add_child(_arrange_button)
	
	_title = Label.new()
	_title.text = "  (no graph)"
	bar.add_child(_title)

	_graphedit = GraphEdit.new()
	_graphedit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_graphedit.right_disconnects = true
	_graphedit.minimap_enabled = false
	_graphedit.connection_request.connect(_on_connection_request)
	_graphedit.disconnection_request.connect(_on_disconnection_request)
	_graphedit.delete_nodes_request.connect(_on_delete_request)
	_graphedit.node_selected.connect(_on_node_selected)
	_graphedit.begin_node_move.connect(_on_node_move_begin)
	_graphedit.end_node_move.connect(_on_node_move_end)
	_graphedit.popup_request.connect(_on_popup_request)
	_graphedit.gui_input.connect(_on_graphedit_gui_input)
	add_child(_graphedit)

	_search_dialog = SearchDialogScript.new()
	_search_dialog.node_selected.connect(_on_search_node_selected)
	add_child(_search_dialog)

	_hint = Label.new()
	_hint.text = "No graph open. Select a Pasture3DTerrainGraph (or a graph modifier) and press " \
			+ "\"Edit in Graph Editor\"."
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_graphedit.add_child(_hint)


# ---- Undo / Redo Helper -----------------------------------------------------------------------------

func _get_undo_redo():
	if plugin != null:
		return plugin.get_undo_redo()
	return _local_undo_redo


func _ur_create_action(p_name: String) -> void:
	var ur = _get_undo_redo()
	if ur is EditorUndoRedoManager:
		ur.create_action(p_name, UndoRedo.MERGE_DISABLE, graph)
	elif ur is UndoRedo:
		ur.create_action(p_name)


func _ur_add_do_method(p_obj: Object, p_method: StringName, p_args: Array = []) -> void:
	var ur = _get_undo_redo()
	if ur is EditorUndoRedoManager:
		match p_args.size():
			0: ur.add_do_method(p_obj, p_method)
			1: ur.add_do_method(p_obj, p_method, p_args[0])
			2: ur.add_do_method(p_obj, p_method, p_args[0], p_args[1])
			3: ur.add_do_method(p_obj, p_method, p_args[0], p_args[1], p_args[2])
			4: ur.add_do_method(p_obj, p_method, p_args[0], p_args[1], p_args[2], p_args[3])
	elif ur is UndoRedo:
		match p_args.size():
			0: ur.add_do_method(Callable(p_obj, p_method))
			1: ur.add_do_method(Callable(p_obj, p_method).bind(p_args[0]))
			2: ur.add_do_method(Callable(p_obj, p_method).bind(p_args[0], p_args[1]))
			3: ur.add_do_method(Callable(p_obj, p_method).bind(p_args[0], p_args[1], p_args[2]))
			4: ur.add_do_method(Callable(p_obj, p_method).bind(p_args[0], p_args[1], p_args[2], p_args[3]))


func _ur_add_undo_method(p_obj: Object, p_method: StringName, p_args: Array = []) -> void:
	var ur = _get_undo_redo()
	if ur is EditorUndoRedoManager:
		match p_args.size():
			0: ur.add_undo_method(p_obj, p_method)
			1: ur.add_undo_method(p_obj, p_method, p_args[0])
			2: ur.add_undo_method(p_obj, p_method, p_args[0], p_args[1])
			3: ur.add_undo_method(p_obj, p_method, p_args[0], p_args[1], p_args[2])
			4: ur.add_undo_method(p_obj, p_method, p_args[0], p_args[1], p_args[2], p_args[3])
	elif ur is UndoRedo:
		match p_args.size():
			0: ur.add_undo_method(Callable(p_obj, p_method))
			1: ur.add_undo_method(Callable(p_obj, p_method).bind(p_args[0]))
			2: ur.add_undo_method(Callable(p_obj, p_method).bind(p_args[0], p_args[1]))
			3: ur.add_undo_method(Callable(p_obj, p_method).bind(p_args[0], p_args[1], p_args[2]))
			4: ur.add_undo_method(Callable(p_obj, p_method).bind(p_args[0], p_args[1], p_args[2], p_args[3]))


func _ur_add_do_property(p_obj: Object, p_prop: StringName, p_val: Variant) -> void:
	var ur = _get_undo_redo()
	if ur != null:
		ur.add_do_property(p_obj, p_prop, p_val)


func _ur_add_undo_property(p_obj: Object, p_prop: StringName, p_val: Variant) -> void:
	var ur = _get_undo_redo()
	if ur != null:
		ur.add_undo_property(p_obj, p_prop, p_val)


func _ur_commit(p_execute: bool = true) -> void:
	var ur = _get_undo_redo()
	if ur != null:
		ur.commit_action(p_execute)


# ---- Build / Rebuild --------------------------------------------------------------------------------

func _rebuild() -> void:
	if _graphedit == null:
		return
	_clear()
	var has := graph != null
	if _add_button != null: _add_button.disabled = not has
	if _minimap_button != null: _minimap_button.disabled = not has
	if _arrange_button != null: _arrange_button.disabled = not has
	if _title != null: _title.text = "  editing: %s" % _graph_label() if has else "  (no graph)"
	if _hint != null: _hint.visible = not has
	if not has:
		return
		
	for i in range(graph.nodes.size()):
		var node: Pasture3DGraphNode = graph.nodes[i]
		if node != null:
			_graphedit.add_child(_make_graphnode(i, node))
			
	for c in graph.connections:
		if c.size() >= 4:
			_graphedit.connect_node("n%d" % int(c[0]), int(c[1]), "n%d" % int(c[2]), int(c[3]))


func _clear() -> void:
	_graphedit.clear_connections()
	for c in _graphedit.get_children():
		if c is GraphNode:
			_graphedit.remove_child(c)
			c.queue_free()


func _make_graphnode(p_index: int, p_node: Pasture3DGraphNode) -> GraphNode:
	var gn := GraphNode.new()
	gn.name = "n%d" % p_index
	gn.set_selectable(true)
	gn.set_draggable(true)
	var is_out := p_index == graph.output_index()
	gn.title = p_node.display_name() + ("  ● OUT" if is_out else "")
	gn.position_offset = p_node.graph_position
	if is_out:
		gn.modulate = Color(0.8, 1.0, 0.85)

	# "Set as Output" button
	if p_node.has_output() and not _graph_has_sink():
		var out_btn := Button.new()
		out_btn.text = "Out"
		out_btn.tooltip_text = "Make this node the graph's output"
		out_btn.pressed.connect(func(): _action_set_output(p_index))
		gn.get_titlebar_hbox().add_child(out_btn)

	var names := p_node.input_names()
	var n_in := p_node.input_count()
	var has_right := p_node.has_output()
	var rows := maxi(n_in, 1)
	for r in range(rows):
		var lbl := Label.new()
		lbl.text = names[r] if r < n_in else " "
		gn.add_child(lbl)
	for r in range(rows):
		gn.set_slot(r, r < n_in, 0, Color(0.6, 0.8, 1.0), has_right and r == 0, 0, Color(1.0, 0.85, 0.5))
	return gn


func _graph_has_sink() -> bool:
	for nd in graph.nodes:
		if nd != null and nd.op() == &"output":
			return true
	return false


func _graph_label() -> String:
	if not graph.resource_path.is_empty():
		return graph.resource_path.get_file()
	return "Terrain Graph"


# ---- Search & Creation ------------------------------------------------------------------------------

func _on_add_button_pressed() -> void:
	if graph == null:
		return
	var center_screen: Vector2 = _graphedit.get_global_transform().origin + _graphedit.size * 0.5
	var center_graph: Vector2 = (_graphedit.scroll_offset + _graphedit.size * 0.5) / _graphedit.zoom
	_search_dialog.open_at(center_screen, center_graph)


func _on_popup_request(p_at_position: Vector2) -> void:
	if graph == null:
		return
	var screen_pos := _graphedit.get_screen_transform() * p_at_position
	var graph_pos := (p_at_position + _graphedit.scroll_offset) / _graphedit.zoom
	_search_dialog.open_at(screen_pos, graph_pos)


func _on_search_node_selected(p_op: StringName, p_position: Vector2) -> void:
	if graph == null:
		return
	var node := Pasture3DGraphNodeRegistry.create(p_op)
	if node != null:
		_action_add_node(node, p_position)


# ---- Undoable Actions -------------------------------------------------------------------------------

func _action_add_node(p_node: Pasture3DGraphNode, p_pos: Vector2) -> void:
	var idx := graph.nodes.size()
	_ur_create_action("Add Terrain Graph Node")
	_ur_add_do_method(graph, &"add_node", [p_node, p_pos])
	_ur_add_undo_method(graph, &"remove_node", [idx])
	_ur_commit()


func _action_delete_nodes(p_indices: Array[int]) -> void:
	if p_indices.is_empty() or graph == null:
		return
		
	var sorted_indices := p_indices.duplicate()
	sorted_indices.sort()
	sorted_indices.reverse()
	
	var old_nodes := graph.nodes.duplicate()
	var old_conns := graph.connections.duplicate()
	var old_out := graph.output_node
	
	_ur_create_action("Delete Terrain Graph Node(s)")
	for i in sorted_indices:
		_ur_add_do_method(graph, &"remove_node", [i])
	_ur_add_undo_property(graph, &"nodes", old_nodes)
	_ur_add_undo_property(graph, &"connections", old_conns)
	_ur_add_undo_property(graph, &"output_node", old_out)
	_ur_commit()


func _action_connect(p_from: int, p_from_port: int, p_to: int, p_to_port: int) -> void:
	var old_conns := graph.connections.duplicate()
	_ur_create_action("Connect Terrain Graph Ports")
	_ur_add_do_method(graph, &"connect_ports", [p_from, p_from_port, p_to, p_to_port])
	_ur_add_undo_property(graph, &"connections", old_conns)
	_ur_commit()


func _action_disconnect(p_from: int, p_from_port: int, p_to: int, p_to_port: int) -> void:
	_ur_create_action("Disconnect Terrain Graph Ports")
	_ur_add_do_method(graph, &"disconnect_ports", [p_from, p_from_port, p_to, p_to_port])
	_ur_add_undo_method(graph, &"connect_ports", [p_from, p_from_port, p_to, p_to_port])
	_ur_commit()


func _action_set_output(p_index: int) -> void:
	var old_out := graph.output_node
	_ur_create_action("Set Terrain Graph Output")
	_ur_add_do_method(graph, &"set_output", [p_index])
	_ur_add_undo_method(graph, &"set_output", [old_out])
	_ur_commit()


# ---- GraphEdit Callbacks ----------------------------------------------------------------------------

func _on_connection_request(p_from: StringName, p_from_port: int, p_to: StringName, p_to_port: int) -> void:
	if graph != null:
		_action_connect(_idx(p_from), p_from_port, _idx(p_to), p_to_port)


func _on_disconnection_request(p_from: StringName, p_from_port: int, p_to: StringName, p_to_port: int) -> void:
	if graph != null:
		_action_disconnect(_idx(p_from), p_from_port, _idx(p_to), p_to_port)


func _on_delete_request(p_names: Array) -> void:
	if graph == null:
		return
	var idx: Array[int] = []
	for nm in p_names:
		idx.append(_idx(nm))
	_action_delete_nodes(idx)


func _on_node_selected(p_node: Node) -> void:
	if graph == null:
		return
	var i := _idx(p_node.name)
	if i >= 0 and i < graph.nodes.size() and graph.nodes[i] != null:
		if plugin != null:
			EditorInterface.edit_resource(graph.nodes[i])


func _on_node_move_begin() -> void:
	_drag_start_positions.clear()
	for c in _graphedit.get_children():
		if c is GraphNode:
			var i := _idx(c.name)
			if i >= 0 and i < graph.nodes.size() and graph.nodes[i] != null:
				_drag_start_positions[i] = graph.nodes[i].graph_position


func _on_node_move_end() -> void:
	if graph == null:
		return
	var end_positions: Dictionary = {}
	var has_diff := false
	for c in _graphedit.get_children():
		if c is GraphNode:
			var i := _idx(c.name)
			if i >= 0 and i < graph.nodes.size() and graph.nodes[i] != null:
				end_positions[i] = c.position_offset
				graph.nodes[i].graph_position = c.position_offset
				if _drag_start_positions.has(i) and _drag_start_positions[i] != c.position_offset:
					has_diff = true
					
	if has_diff and not _drag_start_positions.is_empty():
		var start_snap := _drag_start_positions.duplicate()
		var end_snap := end_positions.duplicate()
		_ur_create_action("Move Terrain Graph Node(s)")
		_ur_add_do_method(self, &"_apply_node_positions", [end_snap])
		_ur_add_undo_method(self, &"_apply_node_positions", [start_snap])
		_ur_commit(false)


func _apply_node_positions(p_positions: Dictionary) -> void:
	if graph == null:
		return
	for idx in p_positions.keys():
		var i := int(idx)
		if i >= 0 and i < graph.nodes.size() and graph.nodes[i] != null:
			graph.nodes[i].graph_position = p_positions[idx]
	_rebuild()


func _on_minimap_toggled(p_enabled: bool) -> void:
	if _graphedit != null:
		_graphedit.minimap_enabled = p_enabled


# ---- Clipboard & Navigation Shortcuts ---------------------------------------------------------------

func _get_selected_node_indices() -> Array[int]:
	var result: Array[int] = []
	if _graphedit == null:
		return result
	for c in _graphedit.get_children():
		if c is GraphNode and c.is_selected():
			var i := _idx(c.name)
			if i >= 0:
				result.append(i)
	return result


func duplicate_selected() -> void:
	if graph == null:
		return
	var selected := _get_selected_node_indices()
	if selected.is_empty():
		return
	var old_nodes := graph.nodes.duplicate()
	var old_conns := graph.connections.duplicate()
	_ur_create_action("Duplicate Terrain Graph Node(s)")
	_ur_add_do_method(graph, &"duplicate_subgraph", [selected, Vector2(40, 40)])
	_ur_add_undo_property(graph, &"nodes", old_nodes)
	_ur_add_undo_property(graph, &"connections", old_conns)
	_ur_commit()


func copy_selected() -> void:
	if graph == null:
		return
	var selected := _get_selected_node_indices()
	if not selected.is_empty():
		_clipboard = graph.serialize_subgraph(selected)


func cut_selected() -> void:
	if graph == null:
		return
	var selected := _get_selected_node_indices()
	if not selected.is_empty():
		_clipboard = graph.serialize_subgraph(selected)
		_action_delete_nodes(selected)


func paste() -> void:
	if graph == null or _clipboard.is_empty() or _clipboard.get("nodes", []).is_empty():
		return
	var mouse_pos := _graphedit.get_local_mouse_position() if _graphedit.is_inside_tree() else Vector2.ZERO
	var graph_pos := (mouse_pos + _graphedit.scroll_offset) / _graphedit.zoom
	var old_nodes := graph.nodes.duplicate()
	var old_conns := graph.connections.duplicate()
	var clip_data := _clipboard.duplicate(true)
	
	_ur_create_action("Paste Terrain Graph Node(s)")
	_ur_add_do_method(graph, &"deserialize_subgraph", [clip_data, graph_pos])
	_ur_add_undo_property(graph, &"nodes", old_nodes)
	_ur_add_undo_property(graph, &"connections", old_conns)
	_ur_commit()


func frame_selected() -> void:
	if _graphedit == null:
		return
	var min_pos := Vector2(INF, INF)
	var max_pos := Vector2(-INF, -INF)
	var has_sel := false
	for c in _graphedit.get_children():
		if c is GraphNode and c.is_selected():
			has_sel = true
			min_pos = min_pos.min(c.position_offset)
			max_pos = max_pos.max(c.position_offset + c.size)
			
	if not has_sel:
		frame_all()
		return
		
	var center := (min_pos + max_pos) * 0.5
	_graphedit.scroll_offset = center * _graphedit.zoom - _graphedit.size * 0.5


func frame_all() -> void:
	if _graphedit == null:
		return
	var min_pos := Vector2(INF, INF)
	var max_pos := Vector2(-INF, -INF)
	var count := 0
	for c in _graphedit.get_children():
		if c is GraphNode:
			count += 1
			min_pos = min_pos.min(c.position_offset)
			max_pos = max_pos.max(c.position_offset + c.size)
			
	if count == 0:
		_graphedit.scroll_offset = Vector2.ZERO
		return
		
	var center := (min_pos + max_pos) * 0.5
	_graphedit.scroll_offset = center * _graphedit.zoom - _graphedit.size * 0.5


func _select_all_nodes(p_selected: bool) -> void:
	if _graphedit == null:
		return
	for c in _graphedit.get_children():
		if c is GraphElement:
			c.set_selected(p_selected)


func _accept_event() -> void:
	if is_inside_tree() and get_viewport() != null:
		get_viewport().set_input_as_handled()


func _on_graphedit_gui_input(p_event: InputEvent) -> void:
	if p_event is InputEventKey and p_event.pressed:
		var is_ctrl: bool = p_event.ctrl_pressed or p_event.meta_pressed or p_event.is_command_or_control_autoremap()
		
		# Quick Search: Tab or Space (when Ctrl is not held)
		if not is_ctrl and (p_event.keycode == KEY_TAB or p_event.keycode == KEY_SPACE):
			var mouse_pos := _graphedit.get_local_mouse_position() if _graphedit.is_inside_tree() else Vector2.ZERO
			_on_popup_request(mouse_pos)
			_accept_event()
			return
			
		# Shortcuts with Ctrl / Cmd
		if is_ctrl:
			match p_event.keycode:
				KEY_D:
					duplicate_selected()
					_accept_event()
				KEY_C:
					copy_selected()
					_accept_event()
				KEY_X:
					cut_selected()
					_accept_event()
				KEY_V:
					paste()
					_accept_event()
				KEY_A:
					_select_all_nodes(true)
					_accept_event()
			return
			
		# Non-Ctrl Shortcuts
		match p_event.keycode:
			KEY_DELETE, KEY_BACKSPACE:
				var sel := _get_selected_node_indices()
				if not sel.is_empty():
					_action_delete_nodes(sel)
					_accept_event()
			KEY_F:
				frame_selected()
				_accept_event()
			KEY_HOME:
				frame_all()
				_accept_event()
			KEY_A:
				frame_all()
				_accept_event()


func _idx(p_name) -> int:
	var s := String(p_name)
	return int(s.substr(1)) if s.begins_with("n") else -1
