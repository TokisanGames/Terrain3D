# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphEditor — the bottom-panel visual editor for a Pasture3DTerrainGraph, built on Godot's
# GraphEdit/GraphNode/GraphFrame (the same controls the VisualShader / Shader Graph editor uses). The canvas owns
# TOPOLOGY — nodes, wiring, frames, and which node is the output; a node's parameters can be edited inline or in
# Godot's normal Inspector. See PASTURE3D_TERRAIN_GRAPH_USABILITY_SPEC.md.
#
# All structural edits go through undo/redo actions operating on Pasture3DTerrainGraph.
@tool
class_name Pasture3DGraphEditor
extends VBoxContainer

const SearchDialogScript = preload("res://addons/pasture_3d/src/graph_search_dialog.gd")
const ThumbnailGenScript = preload("res://addons/pasture_3d/src/graph_thumbnail_generator.gd")

const PORT_COLORS: Array[Color] = [
	Color(0.36, 0.68, 0.89), # 0: HEIGHT (#5dade2) - Sky Blue
	Color(0.95, 0.61, 0.07), # 1: MASK (#f39c12) - Amber
	Color(0.69, 0.48, 0.77), # 2: VECTOR (#af7ac5) - Purple
	Color(0.18, 0.80, 0.44), # 3: CURVE (#2ecc71) - Emerald
]

var plugin: EditorPlugin
var graph: Pasture3DTerrainGraph
var host_modifier: Pasture3DNodeGraph = null

var _graphedit: GraphEdit
var _search_dialog: PopupPanel
var _add_button: Button
var _presets_button: MenuButton
var _frame_button: Button
var _preview_button: Button
var _minimap_button: Button
var _arrange_button: Button
var _title: Label
var _hint: Label

var _show_previews: bool = false

## Standalone fallback when running without EditorPlugin (e.g. tests)
var _local_undo_redo: UndoRedo = UndoRedo.new()

## Internal clipboard for copy/cut/paste
var _clipboard: Dictionary = {}

## Track previous node/frame positions for undo/redo move actions
var _drag_start_positions: Dictionary = {}

## Track pending drag-to-create connection
var _pending_drag_connection: Dictionary = {}


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
func edit_graph(p_graph: Pasture3DTerrainGraph, p_mod: Pasture3DNodeGraph = null) -> void:
	if p_mod != null:
		host_modifier = p_mod
	elif host_modifier != null and host_modifier.graph != p_graph:
		host_modifier = null
		
	if graph == p_graph:
		_rebuild()
		return
	if graph != null and graph.changed.is_connected(_rebuild):
		graph.changed.disconnect(_rebuild)
	graph = p_graph
	if graph != null and not graph.changed.is_connected(_rebuild):
		graph.changed.connect(_rebuild)
	_rebuild()


func _find_host_modifier() -> Pasture3DNodeGraph:
	if host_modifier != null and host_modifier.graph == graph:
		return host_modifier
	if plugin != null and graph != null:
		var sel := EditorInterface.get_selection().get_selected_nodes()
		for nd in sel:
			if nd is Pasture3DTerrainBrush:
				for m in (nd as Pasture3DTerrainBrush).modifiers:
					if m is Pasture3DNodeGraph and (m as Pasture3DNodeGraph).graph == graph:
						host_modifier = m
						return m
	return null


func _build_ui() -> void:
	custom_minimum_size = Vector2(0, 240)
	
	var bar := HBoxContainer.new()
	add_child(bar)
	
	_add_button = Button.new()
	_add_button.text = "Add Node"
	_add_button.tooltip_text = "Add a new node to the graph (or press Tab / Space over canvas)"
	_add_button.pressed.connect(_on_add_button_pressed)
	bar.add_child(_add_button)

	_presets_button = MenuButton.new()
	_presets_button.text = "Presets"
	_presets_button.tooltip_text = "Insert pre-configured terrain graph template networks"
	var popup: PopupMenu = _presets_button.get_popup()
	popup.clear()
	popup.add_item("Alpine Mountain (Noise + Strata + Smooth)", 0)
	popup.add_item("Desert Dunes (Dunes + Ripple Furrows)", 1)
	popup.add_item("Impact Crater Field (Crater + Relief)", 2)
	popup.add_item("Terraced Valley (Input + Terraces)", 3)
	popup.add_item("Steep Flank Mask (Slope Gate + Noise)", 4)
	popup.id_pressed.connect(_on_preset_selected)
	bar.add_child(_presets_button)
	
	_frame_button = Button.new()
	_frame_button.text = "Group Frame"
	_frame_button.tooltip_text = "Group selected nodes into a visual GraphFrame (Ctrl+J or C)"
	_frame_button.pressed.connect(group_selected_in_frame)
	bar.add_child(_frame_button)
	
	_preview_button = Button.new()
	_preview_button.text = "2D Previews"
	_preview_button.toggle_mode = true
	_preview_button.button_pressed = false
	_preview_button.tooltip_text = "Toggle inline 2D heightmap thumbnail previews"
	_preview_button.toggled.connect(func(enabled: bool):
		_show_previews = enabled
		_rebuild()
	)
	bar.add_child(_preview_button)

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
	
	# Register Phase 4 Valid Port Connection Types
	_graphedit.add_valid_connection_type(Pasture3DGraphNode.PortType.HEIGHT, Pasture3DGraphNode.PortType.HEIGHT)
	_graphedit.add_valid_connection_type(Pasture3DGraphNode.PortType.MASK, Pasture3DGraphNode.PortType.MASK)
	_graphedit.add_valid_connection_type(Pasture3DGraphNode.PortType.HEIGHT, Pasture3DGraphNode.PortType.MASK)
	_graphedit.add_valid_connection_type(Pasture3DGraphNode.PortType.MASK, Pasture3DGraphNode.PortType.HEIGHT)
	_graphedit.add_valid_connection_type(Pasture3DGraphNode.PortType.VECTOR, Pasture3DGraphNode.PortType.VECTOR)
	_graphedit.add_valid_connection_type(Pasture3DGraphNode.PortType.CURVE, Pasture3DGraphNode.PortType.CURVE)

	_graphedit.add_valid_right_disconnect_type(Pasture3DGraphNode.PortType.HEIGHT)
	_graphedit.add_valid_right_disconnect_type(Pasture3DGraphNode.PortType.MASK)
	_graphedit.add_valid_right_disconnect_type(Pasture3DGraphNode.PortType.VECTOR)
	_graphedit.add_valid_right_disconnect_type(Pasture3DGraphNode.PortType.CURVE)

	_graphedit.connection_request.connect(_on_connection_request)
	_graphedit.disconnection_request.connect(_on_disconnection_request)
	_graphedit.connection_to_empty.connect(_on_connection_to_empty)
	_graphedit.connection_from_empty.connect(_on_connection_from_empty)
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
			5: ur.add_do_method(p_obj, p_method, p_args[0], p_args[1], p_args[2], p_args[3], p_args[4])
			6: ur.add_do_method(p_obj, p_method, p_args[0], p_args[1], p_args[2], p_args[3], p_args[4], p_args[5])
	elif ur is UndoRedo:
		match p_args.size():
			0: ur.add_do_method(Callable(p_obj, p_method))
			1: ur.add_do_method(Callable(p_obj, p_method).bind(p_args[0]))
			2: ur.add_do_method(Callable(p_obj, p_method).bind(p_args[0], p_args[1]))
			3: ur.add_do_method(Callable(p_obj, p_method).bind(p_args[0], p_args[1], p_args[2]))
			4: ur.add_do_method(Callable(p_obj, p_method).bind(p_args[0], p_args[1], p_args[2], p_args[3]))
			5: ur.add_do_method(Callable(p_obj, p_method).bind(p_args[0], p_args[1], p_args[2], p_args[3], p_args[4]))
			6: ur.add_do_method(Callable(p_obj, p_method).bind(p_args[0], p_args[1], p_args[2], p_args[3], p_args[4], p_args[5]))


func _ur_add_undo_method(p_obj: Object, p_method: StringName, p_args: Array = []) -> void:
	var ur = _get_undo_redo()
	if ur is EditorUndoRedoManager:
		match p_args.size():
			0: ur.add_undo_method(p_obj, p_method)
			1: ur.add_undo_method(p_obj, p_method, p_args[0])
			2: ur.add_undo_method(p_obj, p_method, p_args[0], p_args[1])
			3: ur.add_undo_method(p_obj, p_method, p_args[0], p_args[1], p_args[2])
			4: ur.add_undo_method(p_obj, p_method, p_args[0], p_args[1], p_args[2], p_args[3])
			5: ur.add_undo_method(p_obj, p_method, p_args[0], p_args[1], p_args[2], p_args[3], p_args[4])
			6: ur.add_undo_method(p_obj, p_method, p_args[0], p_args[1], p_args[2], p_args[3], p_args[4], p_args[5])
	elif ur is UndoRedo:
		match p_args.size():
			0: ur.add_undo_method(Callable(p_obj, p_method))
			1: ur.add_undo_method(Callable(p_obj, p_method).bind(p_args[0]))
			2: ur.add_undo_method(Callable(p_obj, p_method).bind(p_args[0], p_args[1]))
			3: ur.add_undo_method(Callable(p_obj, p_method).bind(p_args[0], p_args[1], p_args[2]))
			4: ur.add_undo_method(Callable(p_obj, p_method).bind(p_args[0], p_args[1], p_args[2], p_args[3]))
			5: ur.add_undo_method(Callable(p_obj, p_method).bind(p_args[0], p_args[1], p_args[2], p_args[3], p_args[4]))
			6: ur.add_undo_method(Callable(p_obj, p_method).bind(p_args[0], p_args[1], p_args[2], p_args[3], p_args[4], p_args[5]))


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
	if _presets_button != null: _presets_button.disabled = not has
	if _frame_button != null: _frame_button.disabled = not has
	if _preview_button != null: _preview_button.disabled = not has
	if _minimap_button != null: _minimap_button.disabled = not has
	if _arrange_button != null: _arrange_button.disabled = not has
	if _title != null: _title.text = "  editing: %s" % _graph_label() if has else "  (no graph)"
	if _hint != null: _hint.visible = not has
	if not has:
		return
		
	# 1. Recreate Frames
	for f_idx in range(graph.frames.size()):
		var fdata = graph.frames[f_idx]
		if fdata != null:
			var gf := GraphFrame.new()
			gf.name = "f%d" % f_idx
			gf.title = fdata.title
			gf.position_offset = fdata.position_offset
			gf.size = fdata.size
			gf.set_tint_color_enabled(true)
			gf.set_tint_color(fdata.tint_color)
			gf.set_autoshrink_enabled(fdata.autoshrink)
			_graphedit.add_child(gf)
			
	# 2. Recreate Nodes
	for i in range(graph.nodes.size()):
		var node: Pasture3DGraphNode = graph.nodes[i]
		if node != null:
			_graphedit.add_child(_make_graphnode(i, node))
			
	# 3. Attach Nodes to Frames
	for f_idx in range(graph.frames.size()):
		var fdata = graph.frames[f_idx]
		if fdata != null:
			for n_idx in fdata.attached_node_indices:
				if n_idx >= 0 and n_idx < graph.nodes.size():
					_graphedit.attach_graph_element_to_frame("n%d" % n_idx, "f%d" % f_idx)
			
	# 4. Connect Wires
	for c in graph.connections:
		if c.size() >= 4:
			_graphedit.connect_node("n%d" % int(c[0]), int(c[1]), "n%d" % int(c[2]), int(c[3]))


func _clear() -> void:
	_graphedit.clear_connections()
	for c in _graphedit.get_children():
		if c is GraphElement:
			_graphedit.remove_child(c)
			c.queue_free()


func _make_graphnode(p_index: int, p_node: Pasture3DGraphNode) -> GraphNode:
	var gn := GraphNode.new()
	gn.name = "n%d" % p_index
	gn.set_selectable(true)
	gn.set_draggable(true)
	gn.position_offset = p_node.graph_position
	
	# Compact rendering for Reroute dot nodes
	if p_node.op() == &"reroute":
		gn.title = "●"
		gn.custom_minimum_size = Vector2(36, 32)
		var row := Control.new()
		row.custom_minimum_size = Vector2(0, 14)
		gn.add_child(row)
		gn.set_slot(0, true, Pasture3DGraphNode.PortType.HEIGHT, PORT_COLORS[0], true, Pasture3DGraphNode.PortType.HEIGHT, PORT_COLORS[0])
		return gn
		
	var is_out := p_index == graph.output_index()
	var is_solo := graph.output_override == p_index
	gn.title = p_node.display_name() + ("  ★ SOLO" if is_solo else ("  ● OUT" if is_out else ""))
	if is_solo:
		gn.modulate = Color(1.0, 0.9, 0.5)
	elif is_out:
		gn.modulate = Color(0.8, 1.0, 0.85)
	elif p_node.muted:
		gn.modulate = Color(0.65, 0.65, 0.7, 0.6)

	var thbox: HBoxContainer = gn.get_titlebar_hbox()

	# Tier Badge ([CELL] / [GRID])
	var tier_lbl := Label.new()
	tier_lbl.text = "[GRID]" if p_node.needs_grid() else "[CELL]"
	tier_lbl.modulate = Color(0.4, 0.75, 1.0, 0.8) if p_node.needs_grid() else Color(0.45, 0.9, 0.55, 0.8)
	tier_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thbox.add_child(tier_lbl)

	# Mute / Bypass Button [M]
	var mute_btn := Button.new()
	mute_btn.text = "M"
	mute_btn.toggle_mode = true
	mute_btn.button_pressed = p_node.muted
	mute_btn.tooltip_text = "Mute / Bypass node (M)"
	mute_btn.toggled.connect(func(pressed: bool): _action_set_node_muted(p_index, pressed))
	thbox.add_child(mute_btn)

	# Collapse Button [-] / [+]
	var fold_btn := Button.new()
	fold_btn.text = "+" if p_node.collapsed else "-"
	fold_btn.tooltip_text = "Collapse / Expand inline controls"
	fold_btn.pressed.connect(func(): _action_set_node_collapsed(p_index, not p_node.collapsed))
	thbox.add_child(fold_btn)

	# Solo / Output button
	if p_node.has_output():
		var out_btn := Button.new()
		out_btn.text = "★" if is_solo else "Out"
		out_btn.tooltip_text = "Toggle Solo Output preview for this node (S)"
		out_btn.pressed.connect(func(): _action_set_output(p_index))
		thbox.add_child(out_btn)

	# Populate Slots & Inline Controls
	_populate_node_slots_and_controls(gn, p_index, p_node)
	return gn


func _populate_node_slots_and_controls(p_gn: GraphNode, p_index: int, p_node: Pasture3DGraphNode) -> void:
	var names := p_node.input_names()
	var n_in := p_node.input_count()
	var has_right := p_node.has_output()
	var in_types := p_node.input_port_types()
	var out_type := p_node.output_port_type()
	var out_color: Color = PORT_COLORS[out_type % PORT_COLORS.size()]
	
	# Find wired input port indices
	var wired_inputs: Dictionary = {}
	for c in graph.connections:
		if int(c[2]) == p_index:
			wired_inputs[int(c[3])] = int(c[0])
			
	var rows := maxi(n_in, 1)
	for r in range(rows):
		var row_box := HBoxContainer.new()
		row_box.custom_minimum_size = Vector2(0, 22)
		
		var lbl := Label.new()
		lbl.text = names[r] if r < n_in else " "
		row_box.add_child(lbl)
		
		var in_type: int = in_types[r] if r < in_types.size() else 0
		var in_color: Color = PORT_COLORS[in_type % PORT_COLORS.size()]
		
		p_gn.add_child(row_box)
		p_gn.set_slot(r, r < n_in, in_type, in_color, has_right and r == 0, out_type, out_color)

	# 2D Heightmap Preview Thumbnail (if enabled and not collapsed)
	if _show_previews and not p_node.collapsed:
		var mod := _find_host_modifier()
		var in_grid := mod.last_input_surface if mod != null else PackedFloat32Array()
		var in_gw := mod.last_gw if mod != null else 0
		var in_gh := mod.last_gh if mod != null else 0
		var in_rect := mod.last_rect if mod != null and mod.last_rect.size.x > 0 else Rect2(-50.0, -50.0, 100.0, 100.0)
		var tex: ImageTexture = ThumbnailGenScript.generate_thumbnail(graph, p_index, 128, in_grid, in_gw, in_gh, in_rect)
		if tex != null:
			var center_box := CenterContainer.new()
			var trect := TextureRect.new()
			trect.texture = tex
			trect.custom_minimum_size = Vector2(128, 128)
			trect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			trect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			center_box.add_child(trect)
			p_gn.add_child(center_box)

	# Inline parameter controls (if node is not collapsed)
	if not p_node.collapsed:
		_add_inline_node_controls(p_gn, p_node)


func _add_inline_node_controls(p_gn: GraphNode, p_node: Pasture3DGraphNode) -> void:
	var op := p_node.op()
	match op:
		&"blend":
			var row := HBoxContainer.new()
			var opt := OptionButton.new()
			opt.add_item("Add (+)", 0)
			opt.add_item("Subtract (-)", 1)
			opt.add_item("Multiply (*)", 2)
			opt.add_item("Max", 3)
			opt.add_item("Min", 4)
			opt.selected = int(p_node.get("mode"))
			opt.item_selected.connect(func(idx: int): p_node.set("mode", idx))
			row.add_child(opt)
			p_gn.add_child(row)
			
		&"const":
			var row := HBoxContainer.new()
			var lbl := Label.new(); lbl.text = "Val:"
			var sb := SpinBox.new()
			sb.min_value = -10000.0; sb.max_value = 10000.0; sb.step = 0.5
			sb.value = float(p_node.get("value"))
			sb.value_changed.connect(func(val: float): p_node.set("value", val))
			row.add_child(lbl); row.add_child(sb)
			p_gn.add_child(row)
			
		&"noise":
			var f_row := HBoxContainer.new()
			var f_lbl := Label.new(); f_lbl.text = "Freq:"
			var f_sb := SpinBox.new(); f_sb.min_value = 0.0001; f_sb.max_value = 1.0; f_sb.step = 0.001
			var nz: FastNoiseLite = p_node.get("noise")
			f_sb.value = nz.frequency if nz != null else 0.01
			f_sb.value_changed.connect(func(val: float): 
				var n: FastNoiseLite = p_node.get("noise")
				if n != null: n.frequency = val
			)
			f_row.add_child(f_lbl); f_row.add_child(f_sb)
			p_gn.add_child(f_row)
			
			var a_row := HBoxContainer.new()
			var a_lbl := Label.new(); a_lbl.text = "Amp:"
			var a_sb := SpinBox.new(); a_sb.min_value = 0.0; a_sb.max_value = 1000.0; a_sb.step = 0.5
			a_sb.value = float(p_node.get("amplitude"))
			a_sb.value_changed.connect(func(val: float): p_node.set("amplitude", val))
			
			var seed_btn := Button.new()
			seed_btn.text = "🎲"
			seed_btn.tooltip_text = "Randomize noise seed"
			seed_btn.pressed.connect(func():
				var n: FastNoiseLite = p_node.get("noise")
				if n != null: n.seed = randi() % 100000
			)
			a_row.add_child(a_lbl); a_row.add_child(a_sb); a_row.add_child(seed_btn)
			p_gn.add_child(a_row)
			
		&"smooth":
			var row := HBoxContainer.new()
			var lbl := Label.new(); lbl.text = "Passes:"
			var sb := SpinBox.new(); sb.min_value = 1; sb.max_value = 20; sb.step = 1
			sb.value = int(p_node.get("passes"))
			sb.value_changed.connect(func(val: float): p_node.set("passes", int(val)))
			row.add_child(lbl); row.add_child(sb)
			p_gn.add_child(row)
			
		&"terrace":
			var b_row := HBoxContainer.new()
			var b_lbl := Label.new(); b_lbl.text = "Step:"
			var b_sb := SpinBox.new(); b_sb.min_value = 0.1; b_sb.max_value = 200.0; b_sb.step = 0.5
			b_sb.value = float(p_node.get("band_height"))
			b_sb.value_changed.connect(func(val: float): p_node.set("band_height", val))
			b_row.add_child(b_lbl); b_row.add_child(b_sb)
			p_gn.add_child(b_row)
			
			var h_row := HBoxContainer.new()
			var h_lbl := Label.new(); h_lbl.text = "Hard:"
			var h_sb := SpinBox.new(); h_sb.min_value = 0.0; h_sb.max_value = 1.0; h_sb.step = 0.05
			h_sb.value = float(p_node.get("hardness"))
			h_sb.value_changed.connect(func(val: float): p_node.set("hardness", val))
			h_row.add_child(h_lbl); h_row.add_child(h_sb)
			p_gn.add_child(h_row)
			
		&"furrows":
			var s_row := HBoxContainer.new()
			var s_lbl := Label.new(); s_lbl.text = "Space:"
			var s_sb := SpinBox.new(); s_sb.min_value = 0.5; s_sb.max_value = 200.0; s_sb.step = 0.5
			s_sb.value = float(p_node.get("spacing"))
			s_sb.value_changed.connect(func(val: float): p_node.set("spacing", val))
			s_row.add_child(s_lbl); s_row.add_child(s_sb)
			p_gn.add_child(s_row)
			
			var a_row := HBoxContainer.new()
			var a_lbl := Label.new(); a_lbl.text = "Amp:"
			var a_sb := SpinBox.new(); a_sb.min_value = 0.0; a_sb.max_value = 500.0; a_sb.step = 0.5
			a_sb.value = float(p_node.get("amplitude"))
			a_sb.value_changed.connect(func(val: float): p_node.set("amplitude", val))
			a_row.add_child(a_lbl); a_row.add_child(a_sb)
			p_gn.add_child(a_row)

		&"dunes":
			var w_row := HBoxContainer.new()
			var w_lbl := Label.new(); w_lbl.text = "Wave:"
			var w_sb := SpinBox.new(); w_sb.min_value = 1.0; w_sb.max_value = 256.0; w_sb.step = 1.0
			w_sb.value = float(p_node.get("wavelength"))
			w_sb.value_changed.connect(func(val: float): p_node.set("wavelength", val))
			w_row.add_child(w_lbl); w_row.add_child(w_sb)
			p_gn.add_child(w_row)
			
			var a_row := HBoxContainer.new()
			var a_lbl := Label.new(); a_lbl.text = "Amp:"
			var a_sb := SpinBox.new(); a_sb.min_value = 0.0; a_sb.max_value = 500.0; a_sb.step = 0.5
			a_sb.value = float(p_node.get("amplitude"))
			a_sb.value_changed.connect(func(val: float): p_node.set("amplitude", val))
			a_row.add_child(a_lbl); a_row.add_child(a_sb)
			p_gn.add_child(a_row)

		&"mask":
			var m_row := HBoxContainer.new()
			var opt := OptionButton.new()
			opt.add_item("Slope", 0)
			opt.add_item("Altitude", 1)
			opt.add_item("Curvature", 2)
			opt.selected = int(p_node.get("property"))
			opt.item_selected.connect(func(idx: int): p_node.set("property", idx))
			m_row.add_child(opt)
			p_gn.add_child(m_row)


func _graph_has_sink() -> bool:
	for nd in graph.nodes:
		if nd != null and nd.op() == &"output":
			return true
	return false


func _graph_label() -> String:
	if not graph.resource_path.is_empty():
		return graph.resource_path.get_file()
	return "Terrain Graph"


# ---- Preset Templates -------------------------------------------------------------------------------

func _on_preset_selected(p_id: int) -> void:
	if graph == null:
		return
	var center_graph: Vector2 = (_graphedit.scroll_offset + _graphedit.size * 0.5) / _graphedit.zoom
	_insert_preset(p_id, center_graph)


func _insert_preset(p_id: int, p_pos: Vector2) -> void:
	var old_nodes := graph.nodes.duplicate()
	var old_conns := graph.connections.duplicate()
	var old_frames := graph.frames.duplicate()
	var base_idx := graph.nodes.size()
	
	_ur_create_action("Insert Terrain Preset")
	
	match p_id:
		0: # Alpine Mountain (Noise + Strata + Smooth)
			var nz = Pasture3DGraphNodeRegistry.create(&"noise")
			nz.set("amplitude", 35.0)
			var fnz = FastNoiseLite.new()
			fnz.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
			fnz.frequency = 0.008
			fnz.fractal_octaves = 5
			nz.set("noise", fnz)
			
			var ter = Pasture3DGraphNodeRegistry.create(&"terrace")
			ter.set("band_height", 8.0)
			ter.set("hardness", 0.7)
			
			var sm = Pasture3DGraphNodeRegistry.create(&"smooth")
			sm.set("passes", 2)
			
			_ur_add_do_method(graph, &"add_node", [nz, p_pos])
			_ur_add_do_method(graph, &"add_node", [ter, p_pos + Vector2(220, 0)])
			_ur_add_do_method(graph, &"add_node", [sm, p_pos + Vector2(440, 0)])
			_ur_add_do_method(graph, &"connect_ports", [base_idx, 0, base_idx + 1, 0])
			_ur_add_do_method(graph, &"connect_ports", [base_idx + 1, 0, base_idx + 2, 0])
			_ur_add_do_method(graph, &"group_nodes_in_frame", [[base_idx, base_idx + 1, base_idx + 2], "Alpine Mountain"])
			
		1: # Desert Dunes (Dunes + Ripple Furrows)
			var dunes = Pasture3DGraphNodeRegistry.create(&"dunes")
			dunes.set("amplitude", 12.0)
			dunes.set("wavelength", 60.0)
			dunes.set("asymmetry", 0.75)
			
			var furrows = Pasture3DGraphNodeRegistry.create(&"furrows")
			furrows.set("amplitude", 0.8)
			furrows.set("spacing", 6.0)
			
			var blend = Pasture3DGraphNodeRegistry.create(&"blend")
			blend.set("mode", 0) # ADD
			
			_ur_add_do_method(graph, &"add_node", [dunes, p_pos])
			_ur_add_do_method(graph, &"add_node", [furrows, p_pos + Vector2(0, 150)])
			_ur_add_do_method(graph, &"add_node", [blend, p_pos + Vector2(240, 75)])
			_ur_add_do_method(graph, &"connect_ports", [base_idx, 0, base_idx + 2, 0])
			_ur_add_do_method(graph, &"connect_ports", [base_idx + 1, 0, base_idx + 2, 1])
			_ur_add_do_method(graph, &"group_nodes_in_frame", [[base_idx, base_idx + 1, base_idx + 2], "Desert Dunes"])
			
		2: # Impact Crater Field
			var crater = Pasture3DGraphNodeRegistry.create(&"crater")
			var nz = Pasture3DGraphNodeRegistry.create(&"noise")
			nz.set("amplitude", 5.0)
			var blend = Pasture3DGraphNodeRegistry.create(&"blend")
			blend.set("mode", 3) # MAX
			
			_ur_add_do_method(graph, &"add_node", [crater, p_pos])
			_ur_add_do_method(graph, &"add_node", [nz, p_pos + Vector2(0, 150)])
			_ur_add_do_method(graph, &"add_node", [blend, p_pos + Vector2(240, 75)])
			_ur_add_do_method(graph, &"connect_ports", [base_idx, 0, base_idx + 2, 0])
			_ur_add_do_method(graph, &"connect_ports", [base_idx + 1, 0, base_idx + 2, 1])
			_ur_add_do_method(graph, &"group_nodes_in_frame", [[base_idx, base_idx + 1, base_idx + 2], "Impact Crater Field"])
			
		3: # Terraced Valley (Input + Terraces)
			var inp = Pasture3DGraphNodeRegistry.create(&"input")
			var ter = Pasture3DGraphNodeRegistry.create(&"terrace")
			ter.set("band_height", 12.0)
			ter.set("hardness", 0.85)
			
			_ur_add_do_method(graph, &"add_node", [inp, p_pos])
			_ur_add_do_method(graph, &"add_node", [ter, p_pos + Vector2(200, 0)])
			_ur_add_do_method(graph, &"connect_ports", [base_idx, 0, base_idx + 1, 0])
			_ur_add_do_method(graph, &"group_nodes_in_frame", [[base_idx, base_idx + 1], "Terraced Valley"])
			
		4: # Steep Flank Mask (Slope Gate + Noise)
			var inp = Pasture3DGraphNodeRegistry.create(&"input")
			var mask = Pasture3DGraphNodeRegistry.create(&"mask")
			mask.set("property", 0) # Slope
			mask.set("band_min", 30.0)
			mask.set("band_max", 90.0)
			
			var nz = Pasture3DGraphNodeRegistry.create(&"noise")
			nz.set("amplitude", 8.0)
			
			var blend = Pasture3DGraphNodeRegistry.create(&"blend")
			blend.set("mode", 2) # MUL
			
			_ur_add_do_method(graph, &"add_node", [inp, p_pos])
			_ur_add_do_method(graph, &"add_node", [mask, p_pos + Vector2(200, 0)])
			_ur_add_do_method(graph, &"add_node", [nz, p_pos + Vector2(200, 150)])
			_ur_add_do_method(graph, &"add_node", [blend, p_pos + Vector2(420, 75)])
			_ur_add_do_method(graph, &"connect_ports", [base_idx, 0, base_idx + 1, 0])
			_ur_add_do_method(graph, &"connect_ports", [base_idx + 1, 0, base_idx + 3, 0])
			_ur_add_do_method(graph, &"connect_ports", [base_idx + 2, 0, base_idx + 3, 1])
			_ur_add_do_method(graph, &"group_nodes_in_frame", [[base_idx, base_idx + 1, base_idx + 2, base_idx + 3], "Steep Flank Mask"])
			
	_ur_add_undo_property(graph, &"nodes", old_nodes)
	_ur_add_undo_property(graph, &"connections", old_conns)
	_ur_add_undo_property(graph, &"frames", old_frames)
	_ur_commit()


# ---- Search & Creation ------------------------------------------------------------------------------

func _on_add_button_pressed() -> void:
	if graph == null:
		return
	_pending_drag_connection.clear()
	var center_screen: Vector2 = _graphedit.get_global_transform().origin + _graphedit.size * 0.5
	var center_graph: Vector2 = (_graphedit.scroll_offset + _graphedit.size * 0.5) / _graphedit.zoom
	_search_dialog.open_at(center_screen, center_graph)


func _on_popup_request(p_at_position: Vector2) -> void:
	if graph == null:
		return
	_pending_drag_connection.clear()
	var screen_pos := _graphedit.get_screen_transform() * p_at_position
	var graph_pos := (p_at_position + _graphedit.scroll_offset) / _graphedit.zoom
	_search_dialog.open_at(screen_pos, graph_pos)


func _on_connection_to_empty(p_from: StringName, p_from_port: int, p_release_position: Vector2) -> void:
	if graph == null:
		return
	var f_idx := _idx(p_from)
	if f_idx < 0:
		return
	var screen_pos := (_graphedit.get_screen_transform() * p_release_position) if _graphedit.is_inside_tree() else p_release_position
	var graph_pos := (p_release_position + _graphedit.scroll_offset) / _graphedit.zoom
	_pending_drag_connection = {
		"mode": "from",
		"from_node": f_idx,
		"from_port": p_from_port,
	}
	if _search_dialog != null and _search_dialog.is_inside_tree():
		_search_dialog.open_at(screen_pos, graph_pos)


func _on_connection_from_empty(p_to: StringName, p_to_port: int, p_release_position: Vector2) -> void:
	if graph == null:
		return
	var t_idx := _idx(p_to)
	if t_idx < 0:
		return
	var screen_pos := (_graphedit.get_screen_transform() * p_release_position) if _graphedit.is_inside_tree() else p_release_position
	var graph_pos := (p_release_position + _graphedit.scroll_offset) / _graphedit.zoom
	_pending_drag_connection = {
		"mode": "to",
		"to_node": t_idx,
		"to_port": p_to_port,
	}
	if _search_dialog != null and _search_dialog.is_inside_tree():
		_search_dialog.open_at(screen_pos, graph_pos)


func _on_search_node_selected(p_op: StringName, p_position: Vector2) -> void:
	if graph == null:
		return
	var node := Pasture3DGraphNodeRegistry.create(p_op)
	if node == null:
		return
		
	var pending := _pending_drag_connection.duplicate()
	_pending_drag_connection.clear()
	
	if pending.is_empty():
		_action_add_node(node, p_position)
		return
		
	# Drag-to-create: add node and wire in a single undoable action!
	var new_idx := graph.nodes.size()
	var old_nodes := graph.nodes.duplicate()
	var old_conns := graph.connections.duplicate()
	
	_ur_create_action("Create & Connect Node")
	_ur_add_do_method(graph, &"add_node", [node, p_position])
	if pending.get("mode") == "from":
		var f_idx: int = pending.get("from_node", -1)
		var f_port: int = pending.get("from_port", 0)
		if node.input_count() > 0:
			_ur_add_do_method(graph, &"connect_ports", [f_idx, f_port, new_idx, 0])
	elif pending.get("mode") == "to":
		var t_idx: int = pending.get("to_node", -1)
		var t_port: int = pending.get("to_port", 0)
		if node.has_output():
			_ur_add_do_method(graph, &"connect_ports", [new_idx, 0, t_idx, t_port])
	_ur_add_undo_property(graph, &"nodes", old_nodes)
	_ur_add_undo_property(graph, &"connections", old_conns)
	_ur_commit()


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


func _action_delete_frames(p_indices: Array[int]) -> void:
	if p_indices.is_empty() or graph == null:
		return
	var sorted_indices := p_indices.duplicate()
	sorted_indices.sort()
	sorted_indices.reverse()
	
	var old_frames := graph.frames.duplicate()
	_ur_create_action("Delete Graph Frame(s)")
	for i in sorted_indices:
		_ur_add_do_method(graph, &"remove_frame", [i])
	_ur_add_undo_property(graph, &"frames", old_frames)
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
	var old_override := graph.output_override
	_ur_create_action("Set Terrain Graph Output / Solo")
	_ur_add_do_method(graph, &"set_output", [p_index])
	_ur_add_undo_property(graph, &"output_override", old_override)
	_ur_add_undo_property(graph, &"output_node", old_out)
	_ur_commit()


func _action_set_node_muted(p_index: int, p_muted: bool) -> void:
	if graph == null or p_index < 0 or p_index >= graph.nodes.size():
		return
	var node: Pasture3DGraphNode = graph.nodes[p_index]
	if node == null or node.muted == p_muted:
		return
	_ur_create_action("Toggle Mute Node")
	_ur_add_do_property(node, &"muted", p_muted)
	_ur_add_undo_property(node, &"muted", not p_muted)
	_ur_commit()


func _action_set_node_collapsed(p_index: int, p_collapsed: bool) -> void:
	if graph == null or p_index < 0 or p_index >= graph.nodes.size():
		return
	var node: Pasture3DGraphNode = graph.nodes[p_index]
	if node == null or node.collapsed == p_collapsed:
		return
	_ur_create_action("Toggle Collapse Node")
	_ur_add_do_property(node, &"collapsed", p_collapsed)
	_ur_add_undo_property(node, &"collapsed", not p_collapsed)
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
	var node_indices: Array[int] = []
	var frame_indices: Array[int] = []
	for nm in p_names:
		var n_idx := _idx(nm)
		if n_idx >= 0:
			node_indices.append(n_idx)
		var f_idx := _frame_idx(nm)
		if f_idx >= 0:
			frame_indices.append(f_idx)
			
	if not node_indices.is_empty():
		_action_delete_nodes(node_indices)
	if not frame_indices.is_empty():
		_action_delete_frames(frame_indices)


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
				_drag_start_positions["n%d" % i] = graph.nodes[i].graph_position
		elif c is GraphFrame:
			var f := _frame_idx(c.name)
			if f >= 0 and f < graph.frames.size() and graph.frames[f] != null:
				_drag_start_positions["f%d" % f] = graph.frames[f].position_offset


func _on_node_move_end() -> void:
	if graph == null:
		return
	var end_positions: Dictionary = {}
	var has_diff := false
	for c in _graphedit.get_children():
		if c is GraphNode:
			var i := _idx(c.name)
			if i >= 0 and i < graph.nodes.size() and graph.nodes[i] != null:
				end_positions["n%d" % i] = c.position_offset
				graph.nodes[i].graph_position = c.position_offset
				var key := "n%d" % i
				if _drag_start_positions.has(key) and _drag_start_positions[key] != c.position_offset:
					has_diff = true
		elif c is GraphFrame:
			var f := _frame_idx(c.name)
			if f >= 0 and f < graph.frames.size() and graph.frames[f] != null:
				end_positions["f%d" % f] = c.position_offset
				graph.frames[f].position_offset = c.position_offset
				graph.frames[f].size = c.size
				var key := "f%d" % f
				if _drag_start_positions.has(key) and _drag_start_positions[key] != c.position_offset:
					has_diff = true
					
	if has_diff and not _drag_start_positions.is_empty():
		var start_snap := _drag_start_positions.duplicate()
		var end_snap := end_positions.duplicate()
		_ur_create_action("Move Terrain Graph Element(s)")
		_ur_add_do_method(self, &"_apply_element_positions", [end_snap])
		_ur_add_undo_method(self, &"_apply_element_positions", [start_snap])
		_ur_commit(false)


func _apply_element_positions(p_positions: Dictionary) -> void:
	if graph == null:
		return
	for key in p_positions.keys():
		var s := String(key)
		if s.begins_with("n"):
			var i := int(s.substr(1))
			if i >= 0 and i < graph.nodes.size() and graph.nodes[i] != null:
				graph.nodes[i].graph_position = p_positions[key]
		elif s.begins_with("f"):
			var f := int(s.substr(1))
			if f >= 0 and f < graph.frames.size() and graph.frames[f] != null:
				graph.frames[f].position_offset = p_positions[key]
	_rebuild()


func _on_minimap_toggled(p_enabled: bool) -> void:
	if _graphedit != null:
		_graphedit.minimap_enabled = p_enabled


# ---- Clipboard, Grouping & Navigation Shortcuts ----------------------------------------------------

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


func group_selected_in_frame() -> void:
	if graph == null:
		return
	var selected := _get_selected_node_indices()
	if selected.is_empty():
		return
	var old_frames := graph.frames.duplicate()
	_ur_create_action("Group Nodes in Frame")
	_ur_add_do_method(graph, &"group_nodes_in_frame", [selected, "Group"])
	_ur_add_undo_property(graph, &"frames", old_frames)
	_ur_commit()


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


func _split_closest_connection(p_mouse_pos: Vector2) -> void:
	if graph == null or _graphedit == null:
		return
	var conn: Dictionary = _graphedit.get_closest_connection_at_point(p_mouse_pos, 16.0)
	if conn.is_empty():
		return
		
	var from_node_name: StringName = conn.get("from_node", &"")
	var from_port: int = conn.get("from_port", 0)
	var to_node_name: StringName = conn.get("to_node", &"")
	var to_port: int = conn.get("to_port", 0)
	
	var f_idx := _idx(from_node_name)
	var t_idx := _idx(to_node_name)
	if f_idx < 0 or t_idx < 0:
		return
		
	var graph_pos: Vector2 = (p_mouse_pos + _graphedit.scroll_offset) / _graphedit.zoom
	var reroute_node = Pasture3DGraphNodeRegistry.create(&"reroute")
	
	var old_nodes := graph.nodes.duplicate()
	var old_conns := graph.connections.duplicate()
	
	_ur_create_action("Insert Reroute Node")
	_ur_add_do_method(graph, &"split_connection_with_node", [f_idx, from_port, t_idx, to_port, reroute_node, graph_pos])
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
		if c is GraphElement and c.is_selected():
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
		if c is GraphElement:
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
	# Double click on connection line -> split with Reroute node
	if p_event is InputEventMouseButton and p_event.pressed and p_event.double_click and p_event.button_index == MOUSE_BUTTON_LEFT:
		_split_closest_connection(p_event.position)
		_accept_event()
		return
		
	# Alt + Left Click on wire / port -> rapid wire disconnection
	if p_event is InputEventMouseButton and p_event.pressed and p_event.alt_pressed and p_event.button_index == MOUSE_BUTTON_LEFT:
		var conn: Dictionary = _graphedit.get_closest_connection_at_point(p_event.position, 20.0)
		if not conn.is_empty():
			var f_idx := _idx(conn.get("from_node", &""))
			var f_port: int = conn.get("from_port", 0)
			var t_idx := _idx(conn.get("to_node", &""))
			var t_port: int = conn.get("to_port", 0)
			if f_idx >= 0 and t_idx >= 0:
				_action_disconnect(f_idx, f_port, t_idx, t_port)
				_accept_event()
				return
		
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
				KEY_J:
					group_selected_in_frame()
					_accept_event()
			return
			
		# Non-Ctrl Shortcuts
		match p_event.keycode:
			KEY_DELETE, KEY_BACKSPACE:
				var sel := _get_selected_node_indices()
				if not sel.is_empty():
					_action_delete_nodes(sel)
					_accept_event()
			KEY_C:
				group_selected_in_frame()
				_accept_event()
			KEY_M:
				var sel := _get_selected_node_indices()
				for idx in sel:
					if idx >= 0 and idx < graph.nodes.size() and graph.nodes[idx] != null:
						_action_set_node_muted(idx, not graph.nodes[idx].muted)
				_accept_event()
			KEY_S:
				var sel := _get_selected_node_indices()
				if not sel.is_empty():
					_action_set_output(sel[0])
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


func _frame_idx(p_name) -> int:
	var s := String(p_name)
	return int(s.substr(1)) if s.begins_with("f") else -1
