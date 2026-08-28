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

const PORT_COLORS: Array[Color] = [
	Color(0.36, 0.68, 0.89), # 0: HEIGHT (#5dade2) - Sky Blue
	Color(0.95, 0.61, 0.07), # 1: MASK (#f39c12) - Amber
	Color(0.69, 0.48, 0.77), # 2: VECTOR (#af7ac5) - Purple
	Color(0.18, 0.80, 0.44), # 3: CURVE (#2ecc71) - Emerald
	Color(0.00, 0.82, 0.83), # 4: FLOAT (#00d2d3) - Cyan
	Color(0.18, 0.53, 0.87), # 5: INT (#2e86de) - Cobalt Blue
	Color(1.00, 0.42, 0.51), # 6: COLOR (#ff6b81) - Magenta/Pink
	Color(0.66, 0.90, 0.81), # 7: BOOL (#a8e6cf) - Lime Yellow
	Color(0.95, 0.77, 0.06), # 8: TERRAIN_BUS (#f1c40f) - Warm Gold
]

var plugin: EditorPlugin
var graph: Pasture3DTerrainGraph
var host_modifier: Pasture3DNodeGraph = null

var _graphedit: GraphEdit
var _search_dialog: PopupPanel
var _add_button: Button
var _presets_button: MenuButton
var _frame_button: Button
var _minimap_button: Button
var _arrange_button: Button
var _bake_brush_button: Button
var _title: Label
var _hint: Label

var _last_structure_hash: int = 0

## Standalone fallback when running without EditorPlugin (e.g. tests)
var _local_undo_redo: UndoRedo = UndoRedo.new()

## Internal clipboard for copy/cut/paste
var _clipboard: Dictionary = {}

## Track previous node/frame positions for undo/redo move actions
var _drag_start_positions: Dictionary = {}

## Track pending drag-to-create connection
var _pending_drag_connection: Dictionary = {}

# ---- Inline node previews (single-pass multi-tap) ----------------------------------------------------
# One low-resolution graph evaluation taps EVERY preview-on node's buffer at once
# (Pasture3DUtil.graph_eval_grid_taps), over a fixed canonical domain that never depends on the brush. So a
# refresh costs a single eval regardless of how many previews are open, it runs off the main thread, and
# toggling a preview is a pure show/hide of an already-built TextureRect that never triggers evaluation.
const PREVIEW_SIZE: int = 96
const PREVIEW_RECT := Rect2(-50.0, -50.0, 100.0, 100.0)
const PREVIEW_DEBOUNCE_SEC: float = 0.12

var _preview_rects: Dictionary = {}   # node index -> TextureRect, one per previewable (has_output) node
var _preview_buttons: Dictionary = {} # node index -> the 👁 toggle Button, so undo/redo can resync it
var _preview_timer: Timer = null      # debounces refreshes; one-shot, restarted on each graph change
var _preview_token: int = 0           # bumped per dispatch so a stale async result is dropped on apply


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
	elif host_modifier != null and (p_graph == null or host_modifier.graph != p_graph):
		host_modifier = null

	if graph == p_graph:
		_on_graph_changed()
		return
	if graph != null and graph.changed.is_connected(_on_graph_changed):
		graph.changed.disconnect(_on_graph_changed)
	if graph != null and graph.has_signal(&"structure_changed") and graph.structure_changed.is_connected(_on_graph_changed):
		graph.structure_changed.disconnect(_on_graph_changed)
	graph = p_graph
	if graph != null:
		if not graph.changed.is_connected(_on_graph_changed):
			graph.changed.connect(_on_graph_changed)
		if graph.has_signal(&"structure_changed") and not graph.structure_changed.is_connected(_on_graph_changed):
			graph.structure_changed.connect(_on_graph_changed)
	_last_structure_hash = _structure_hash()
	_rebuild()


func _structure_hash() -> int:
	if graph == null:
		return 0
	var h: int = graph.nodes.size() ^ (graph.connections.size() << 4) ^ (graph.frames.size() << 8)
	for i in range(graph.nodes.size()):
		var nd: Pasture3DGraphNode = graph.nodes[i]
		if nd != null:
			# preview_on is deliberately NOT hashed: toggling a preview must never rebuild the canvas — it is
			# a pure show/hide handled by _on_preview_toggled, so it stays out of the structure signature.
			h = h ^ (nd.op().hash() << (i % 16)) ^ (int(nd.collapsed) << ((i + 1) % 16))
	for c in graph.connections:
		if c.size() >= 4:
			var conn_hash := int(c[0]) | (int(c[1]) << 8) | (int(c[2]) << 16) | (int(c[3]) << 24)
			h = h ^ (conn_hash * 2654435761)
	return h


func _on_graph_changed() -> void:
	if graph == null:
		_rebuild()
		return
	var sh := _structure_hash()
	if sh != _last_structure_hash:
		_last_structure_hash = sh
		_rebuild()
	else:
		_refresh_nodes_state()
	# A parameter or wiring change moves the previewed output; re-tap after the debounce. (_rebuild also
	# schedules, so the structure-changed branch above is covered too.)
	_schedule_preview_refresh()


func _refresh_nodes_state() -> void:
	if graph == null or _graphedit == null:
		return
	for i in range(graph.nodes.size()):
		var node: Pasture3DGraphNode = graph.nodes[i]
		if node == null:
			continue
		var gn_name := "n%d" % i
		if _graphedit.has_node(gn_name):
			var gn: GraphNode = _graphedit.get_node(gn_name) as GraphNode
			if gn != null:
				var is_out := i == graph.output_index()
				var is_solo := graph.output_override == i
				gn.title = node.display_name() + ("  ★ SOLO" if is_solo else ("  ● OUT" if is_out else ""))
				if is_solo:
					gn.modulate = Color(1.0, 0.9, 0.5)
				elif is_out:
					gn.modulate = Color(0.8, 1.0, 0.85)
				elif node.muted:
					gn.modulate = Color(0.65, 0.65, 0.7, 0.6)
				else:
					gn.modulate = Color.WHITE


func _auto_fit_node_range(p_index: int) -> void:
	if graph == null or p_index < 0 or p_index >= graph.nodes.size():
		return
	var node: Pasture3DGraphNode = graph.nodes[p_index]
	if node == null:
		return
	
	# Find what is wired into input port 0 of this node
	var src_node := -1
	for c in graph.connections:
		if int(c[2]) == p_index and int(c[3]) == 0:
			src_node = int(c[0])
			break
			
	var input_data := _get_preview_input_data()
	var in_grid: PackedFloat32Array = input_data.get("grid", PackedFloat32Array())
	var in_gw: int = input_data.get("gw", 0)
	var in_gh: int = input_data.get("gh", 0)
	var in_rect: Rect2 = input_data.get("rect", Rect2(-50.0, -50.0, 100.0, 100.0))
	var sample_input: PackedFloat32Array
	if in_grid.size() == 128 * 128 and in_gw == 128 and in_gh == 128:
		sample_input = in_grid
	elif not in_grid.is_empty() and in_gw > 0 and in_gh > 0:
		sample_input = Pasture3DUtil.resample_grid(in_grid, in_gw, in_gh, 128, 128)
	else:
		sample_input = Pasture3DUtil.sample_brush_input(128, 128, in_rect)
		
	var field: PackedFloat32Array
	if src_node >= 0:
		field = graph.evaluate(128, 128, in_rect, null, sample_input, src_node)
	else:
		field = sample_input
		
	var min_val := INF
	var max_val := -INF
	for v in field:
		if is_finite(v):
			min_val = minf(min_val, v)
			max_val = maxf(max_val, v)
			
	if is_inf(min_val) or is_inf(max_val) or max_val - min_val < 0.001:
		min_val = 0.0
		max_val = 100.0
	else:
		min_val = floorf(min_val * 10.0) / 10.0
		max_val = ceilf(max_val * 10.0) / 10.0
		
	_ur_create_action("Auto Fit Range")
	if node.op() == &"curve":
		_ur_add_do_property(node, &"input_min", min_val)
		_ur_add_do_property(node, &"input_max", max_val)
		_ur_add_undo_property(node, &"input_min", node.get("input_min"))
		_ur_add_undo_property(node, &"input_max", node.get("input_max"))
	elif node.op() == &"remap":
		_ur_add_do_property(node, &"in_min", min_val)
		_ur_add_do_property(node, &"in_max", max_val)
		_ur_add_undo_property(node, &"in_min", node.get("in_min"))
		_ur_add_undo_property(node, &"in_max", node.get("in_max"))
	_ur_commit()
	_refresh_nodes_state()


func _find_brush_for_modifier(p_mod: Pasture3DNodeGraph) -> Pasture3DTerrainBrush:
	if p_mod == null or not is_inside_tree():
		return null
	var sel := EditorInterface.get_selection().get_selected_nodes()
	for nd in sel:
		if nd is Pasture3DTerrainBrush and (nd as Pasture3DTerrainBrush).modifiers.has(p_mod):
			return nd as Pasture3DTerrainBrush
	for b in get_tree().get_nodes_in_group("pasture3d_brushes"):
		if b is Pasture3DTerrainBrush and b.modifiers.has(p_mod):
			return b
	return null


func _find_host_brush() -> Pasture3DTerrainBrush:
	if host_modifier != null:
		var b := _find_brush_for_modifier(host_modifier)
		if b != null:
			return b
	if plugin != null and graph != null and is_inside_tree():
		var sel := EditorInterface.get_selection().get_selected_nodes()
		for nd in sel:
			if nd is Pasture3DTerrainBrush:
				for m in (nd as Pasture3DTerrainBrush).modifiers:
					if m is Pasture3DNodeGraph and (m as Pasture3DNodeGraph).graph == graph:
						return nd as Pasture3DTerrainBrush
		for b in get_tree().get_nodes_in_group("pasture3d_brushes"):
			if b is Pasture3DTerrainBrush:
				for m in b.modifiers:
					if m is Pasture3DNodeGraph and (m as Pasture3DNodeGraph).graph == graph:
						return b
	return null


func _find_host_modifier() -> Pasture3DNodeGraph:
	if host_modifier != null and host_modifier.graph == graph:
		return host_modifier
	var brush := _find_host_brush()
	if brush != null:
		for m in brush.modifiers:
			if m is Pasture3DNodeGraph and (m as Pasture3DNodeGraph).graph == graph:
				host_modifier = m
				return m
	return null


func _on_bake_brush_pressed() -> void:
	var mod := _find_host_modifier()
	if mod != null:
		mod.bake_graph()


func _get_preview_input_data() -> Dictionary:
	var brush := _find_host_brush()
	if brush != null and brush.has_method("generate_preview_surface"):
		var ps: Array = brush.generate_preview_surface(128, 128)
		if not ps.is_empty() and ps[0].size() == 128 * 128:
			return {
				"grid": ps[0],
				"gw": ps[1],
				"gh": ps[2],
				"rect": ps[3],
			}
	var mod := _find_host_modifier()
	if mod != null and not mod.last_input_surface.is_empty():
		return {
			"grid": mod.last_input_surface,
			"gw": mod.last_gw,
			"gh": mod.last_gh,
			"rect": mod.last_rect,
		}
	return {
		"grid": Pasture3DUtil.sample_brush_input(128, 128, Rect2(-50.0, -50.0, 100.0, 100.0)),
		"gw": 128,
		"gh": 128,
		"rect": Rect2(-50.0, -50.0, 100.0, 100.0),
	}


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
	popup.add_item("Eroded Alpine Massif (Noise + Hydraulic + Thermal + Ridge)", 5)
	popup.add_item("Sedimentary Canyon (Strata + Curvature + Curve Remap)", 6)
	popup.add_item("Glacial Valley (Domain Warp + Furrows + Hydraulic Erosion)", 7)
	popup.id_pressed.connect(_on_preset_selected)
	bar.add_child(_presets_button)
	
	_frame_button = Button.new()
	_frame_button.text = "Group Frame"
	_frame_button.tooltip_text = "Group selected nodes into a visual GraphFrame (Ctrl+J or C)"
	_frame_button.pressed.connect(group_selected_in_frame)
	bar.add_child(_frame_button)

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

	_bake_brush_button = Button.new()
	_bake_brush_button.text = "Bake to Brush"
	_bake_brush_button.tooltip_text = "Force full evaluation and bake this graph into the host brush terrain layer"
	_bake_brush_button.pressed.connect(_on_bake_brush_pressed)
	_bake_brush_button.visible = false
	bar.add_child(_bake_brush_button)
	
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

	# Debounce timer for inline preview refreshes: coalesces a burst of edits into one tap pass.
	_preview_timer = Timer.new()
	_preview_timer.one_shot = true
	_preview_timer.timeout.connect(_refresh_previews)
	add_child(_preview_timer)


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
	if _minimap_button != null: _minimap_button.disabled = not has
	if _arrange_button != null: _arrange_button.disabled = not has
	var mod := _find_host_modifier()
	if _bake_brush_button != null:
		_bake_brush_button.visible = (has and mod != null)
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

	# Fill any preview-on nodes rebuilt just now (their TextureRects start empty).
	_schedule_preview_refresh()


func _clear() -> void:
	# The TextureRects belong to the GraphNodes about to be freed; drop the map and invalidate any in-flight
	# async tap result so it cannot apply to a stale rect.
	_preview_rects.clear()
	_preview_buttons.clear()
	_preview_token += 1
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
	else:
		gn.modulate = Color.WHITE

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

		# Inline 2D preview toggle [👁]. A pure show/hide of this node's thumbnail — never evaluates the
		# graph. Turning it on schedules the shared low-res tap pass that fills every open preview at once.
		var prev_btn := Button.new()
		prev_btn.text = "👁"
		prev_btn.toggle_mode = true
		prev_btn.button_pressed = p_node.preview_on
		prev_btn.tooltip_text = "Show this node's 2D preview thumbnail"
		prev_btn.toggled.connect(func(pressed: bool): _action_set_node_preview(p_index, pressed))
		thbox.add_child(prev_btn)
		_preview_buttons[p_index] = prev_btn

	# Bake button — a SOLVER carries its own frozen cache, so it can be re-solved from the canvas without
	# opening the Inspector. Runs the same clear_cache() the "Bake" inspector button does. Highlighted amber
	# when the node is FROZEN-and-stale so a graph showing an old solve advertises the fix.
	if p_node.role() == Pasture3DGraphNode.Role.SOLVER and p_node.has_method("clear_cache"):
		var bake_btn := Button.new()
		bake_btn.text = "Bake"
		bake_btn.tooltip_text = "Re-solve this solver (clears its frozen cache)"
		if bool(p_node.get("_stale")):
			bake_btn.modulate = Color(1.0, 0.75, 0.3)
		bake_btn.pressed.connect(func(): _action_bake_solver(p_index))
		thbox.add_child(bake_btn)

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
	var out_names := p_node.output_names()
	var out_types := p_node.output_port_types()
	var n_out := p_node.output_count() if has_right else 0
	var multi_out := n_out > 1

	# Find wired input port indices
	var wired_inputs: Dictionary = {}
	for c in graph.connections:
		if int(c[2]) == p_index:
			wired_inputs[int(c[3])] = int(c[0])

	var rows := maxi(maxi(n_in, n_out), 1)
	for r in range(rows):
		var row_box := HBoxContainer.new()
		row_box.custom_minimum_size = Vector2(0, 24)

		var in_name: String = names[r] if r < n_in else ""
		if not in_name.is_empty():
			var lbl := Label.new()
			lbl.text = in_name
			row_box.add_child(lbl)

		# Smart Socket Collapse: embed inline parameter widget on unwired socket rows
		if not p_node.collapsed and r < n_in:
			var is_wired := wired_inputs.has(r)
			if not is_wired:
				_append_slot_inline_widget(row_box, p_node, p_index, r, in_name)

		# Label each output channel on the right so a multi-output node's ports are told apart.
		if multi_out and r < n_out:
			var spacer := Control.new()
			spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row_box.add_child(spacer)
			var out_lbl := Label.new()
			out_lbl.text = out_names[r] if r < out_names.size() else "out"
			out_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			out_lbl.modulate = Color(0.8, 0.85, 0.95, 0.9)
			row_box.add_child(out_lbl)

		var in_type: int = in_types[r] if r < in_types.size() else 0
		var in_color: Color = PORT_COLORS[in_type % PORT_COLORS.size()]
		var row_out_type: int = out_types[r] if r < out_types.size() else out_type
		var row_out_color: Color = PORT_COLORS[row_out_type % PORT_COLORS.size()]

		p_gn.add_child(row_box)
		p_gn.set_slot(r, r < n_in, in_type, in_color, r < n_out, row_out_type, row_out_color)

	# Additional node-level inline parameter controls (if node is not collapsed)
	if not p_node.collapsed:
		_add_inline_node_controls(p_gn, p_index, p_node)

	# Inline 2D preview thumbnail. Built for every previewable (has_output) node but shown only when the
	# node's preview_on flag is set, so toggling is an instant show/hide with no rebuild and no evaluation.
	# The texture itself is filled asynchronously by the shared tap pass (_refresh_previews).
	if has_right:
		var box := CenterContainer.new()
		box.custom_minimum_size = Vector2(PREVIEW_SIZE, PREVIEW_SIZE)
		var tex_rect := TextureRect.new()
		tex_rect.custom_minimum_size = Vector2(PREVIEW_SIZE, PREVIEW_SIZE)
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(tex_rect)
		box.visible = p_node.preview_on
		p_gn.add_child(box)
		_preview_rects[p_index] = tex_rect


func _append_slot_inline_widget(p_row: HBoxContainer, p_node: Pasture3DGraphNode, p_index: int, p_port: int, p_port_name: String) -> void:
	var op := p_node.op()
	match op:
		&"const":
			if p_port == 0:
				var sb := SpinBox.new(); sb.min_value = -10000.0; sb.max_value = 10000.0; sb.step = 0.5
				sb.value = float(p_node.get("value"))
				sb.value_changed.connect(func(val: float): p_node.set("value", val))
				p_row.add_child(sb)

		&"const_int":
			if p_port == 0:
				var sb := SpinBox.new(); sb.min_value = -100000.0; sb.max_value = 100000.0; sb.step = 1.0
				sb.value = float(p_node.get("value"))
				sb.value_changed.connect(func(val: float): p_node.set("value", int(val)))
				p_row.add_child(sb)

		&"const_vector":
			if p_port == 0:
				var v: Vector2 = p_node.get("value") if p_node.get("value") is Vector2 else Vector2.ZERO
				var sb_x := SpinBox.new(); sb_x.min_value = -10000.0; sb_x.max_value = 10000.0; sb_x.step = 0.1; sb_x.value = v.x
				var sb_y := SpinBox.new(); sb_y.min_value = -10000.0; sb_y.max_value = 10000.0; sb_y.step = 0.1; sb_y.value = v.y
				sb_x.value_changed.connect(func(val: float):
					var cur: Vector2 = p_node.get("value") if p_node.get("value") is Vector2 else Vector2.ZERO
					p_node.set("value", Vector2(val, cur.y))
				)
				sb_y.value_changed.connect(func(val: float):
					var cur: Vector2 = p_node.get("value") if p_node.get("value") is Vector2 else Vector2.ZERO
					p_node.set("value", Vector2(cur.x, val))
				)
				p_row.add_child(sb_x); p_row.add_child(sb_y)

		&"const_color":
			if p_port == 0:
				var cp := ColorPickerButton.new()
				cp.color = p_node.get("value") if p_node.get("value") is Color else Color.WHITE
				cp.custom_minimum_size = Vector2(40, 22)
				cp.color_changed.connect(func(col: Color): p_node.set("value", col))
				p_row.add_child(cp)

		&"const_bool":
			if p_port == 0:
				var cb := CheckBox.new(); cb.text = "Enabled"
				cb.button_pressed = bool(p_node.get("value"))
				cb.toggled.connect(func(val: bool): p_node.set("value", val))
				p_row.add_child(cb)

		&"const_curve":
			if p_port == 0:
				var btn := Button.new(); btn.text = "Linear / Ease"
				btn.pressed.connect(func():
					var c: Curve = p_node.get("curve")
					if c != null and c.point_count >= 2:
						c.clear_points()
						c.add_point(Vector2(0, 0))
						c.add_point(Vector2(0.5, 0.2))
						c.add_point(Vector2(1, 1))
				)
				p_row.add_child(btn)

		&"noise":
			if p_port == 0:
				var a_sb := SpinBox.new(); a_sb.min_value = 0.0; a_sb.max_value = 1000.0; a_sb.step = 0.5
				a_sb.value = float(p_node.get("amplitude"))
				a_sb.value_changed.connect(func(val: float): p_node.set("amplitude", val))
				p_row.add_child(a_sb)
				var seed_btn := Button.new(); seed_btn.text = "🎲"; seed_btn.tooltip_text = "Randomize seed"
				seed_btn.pressed.connect(func():
					var n: FastNoiseLite = p_node.get("noise")
					if n != null: n.seed = randi() % 100000
				)
				p_row.add_child(seed_btn)

		&"noise_swiss":
			if p_port == 0:
				var a_sb := SpinBox.new(); a_sb.min_value = 0.0; a_sb.max_value = 2000.0; a_sb.step = 1.0
				a_sb.value = float(p_node.get("amplitude"))
				a_sb.value_changed.connect(func(val: float): p_node.set("amplitude", val))
				p_row.add_child(a_sb)
				var seed_btn := Button.new(); seed_btn.text = "🎲"; seed_btn.tooltip_text = "Randomize seed"
				seed_btn.pressed.connect(func(): p_node.set("seed", randi() % 100000))
				p_row.add_child(seed_btn)
			elif p_port == 1:
				var ro_sb := SpinBox.new(); ro_sb.min_value = 0.1; ro_sb.max_value = 5.0; ro_sb.step = 0.05
				ro_sb.value = float(p_node.get("ridge_offset"))
				ro_sb.value_changed.connect(func(val: float): p_node.set("ridge_offset", val))
				p_row.add_child(ro_sb)
			elif p_port == 2:
				var ea_sb := SpinBox.new(); ea_sb.min_value = 0.0; ea_sb.max_value = 1.0; ea_sb.step = 0.01
				ea_sb.value = float(p_node.get("erosion_accent"))
				ea_sb.value_changed.connect(func(val: float): p_node.set("erosion_accent", val))
				p_row.add_child(ea_sb)
			elif p_port == 3:
				var g_sb := SpinBox.new(); g_sb.min_value = 0.01; g_sb.max_value = 2.0; g_sb.step = 0.05
				g_sb.value = float(p_node.get("gain"))
				g_sb.value_changed.connect(func(val: float): p_node.set("gain", val))
				p_row.add_child(g_sb)
			elif p_port == 4:
				var f_sb := SpinBox.new(); f_sb.min_value = 0.0001; f_sb.max_value = 0.1; f_sb.step = 0.0005
				f_sb.value = float(p_node.get("frequency"))
				f_sb.value_changed.connect(func(val: float): p_node.set("frequency", val))
				p_row.add_child(f_sb)

		&"noise_jordan":
			if p_port == 0:
				var a_sb := SpinBox.new(); a_sb.min_value = 0.0; a_sb.max_value = 2000.0; a_sb.step = 1.0
				a_sb.value = float(p_node.get("amplitude"))
				a_sb.value_changed.connect(func(val: float): p_node.set("amplitude", val))
				p_row.add_child(a_sb)
				var seed_btn := Button.new(); seed_btn.text = "🎲"; seed_btn.tooltip_text = "Randomize seed"
				seed_btn.pressed.connect(func(): p_node.set("seed", randi() % 100000))
				p_row.add_child(seed_btn)
			elif p_port == 1:
				var ws_sb := SpinBox.new(); ws_sb.min_value = 0.0; ws_sb.max_value = 2.0; ws_sb.step = 0.05
				ws_sb.value = float(p_node.get("warp_strength"))
				ws_sb.value_changed.connect(func(val: float): p_node.set("warp_strength", val))
				p_row.add_child(ws_sb)
			elif p_port == 2:
				var ds_sb := SpinBox.new(); ds_sb.min_value = 0.0; ds_sb.max_value = 2.0; ds_sb.step = 0.05
				ds_sb.value = float(p_node.get("damp_strength"))
				ds_sb.value_changed.connect(func(val: float): p_node.set("damp_strength", val))
				p_row.add_child(ds_sb)
			elif p_port == 3:
				var g_sb := SpinBox.new(); g_sb.min_value = 0.01; g_sb.max_value = 2.0; g_sb.step = 0.05
				g_sb.value = float(p_node.get("gain"))
				g_sb.value_changed.connect(func(val: float): p_node.set("gain", val))
				p_row.add_child(g_sb)
			elif p_port == 4:
				var f_sb := SpinBox.new(); f_sb.min_value = 0.0001; f_sb.max_value = 0.1; f_sb.step = 0.0005
				f_sb.value = float(p_node.get("frequency"))
				f_sb.value_changed.connect(func(val: float): p_node.set("frequency", val))
				p_row.add_child(f_sb)

		&"furrows":
			if p_port == 0:
				var a_sb := SpinBox.new(); a_sb.min_value = 0.0; a_sb.max_value = 500.0; a_sb.step = 0.5
				a_sb.value = float(p_node.get("amplitude"))
				a_sb.value_changed.connect(func(val: float): p_node.set("amplitude", val))
				p_row.add_child(a_sb)
				var seed_btn := Button.new(); seed_btn.text = "🎲"; seed_btn.tooltip_text = "Randomize seed"
				seed_btn.pressed.connect(func(): p_node.set("seed", randi() % 100000))
				p_row.add_child(seed_btn)
			elif p_port == 1:
				var sp_sb := SpinBox.new(); sp_sb.min_value = 1.0; sp_sb.max_value = 500.0; sp_sb.step = 1.0
				sp_sb.value = float(p_node.get("spacing"))
				sp_sb.value_changed.connect(func(val: float): p_node.set("spacing", val))
				p_row.add_child(sp_sb)
			elif p_port == 2:
				var dir_sb := SpinBox.new(); dir_sb.min_value = 0.0; dir_sb.max_value = 360.0; dir_sb.step = 1.0
				dir_sb.value = float(p_node.get("direction_degrees"))
				dir_sb.value_changed.connect(func(val: float): p_node.set("direction_degrees", val))
				p_row.add_child(dir_sb)
			elif p_port == 3:
				var wob_sb := SpinBox.new(); wob_sb.min_value = 0.0; wob_sb.max_value = 50.0; wob_sb.step = 0.5
				wob_sb.value = float(p_node.get("wobble_amount"))
				wob_sb.value_changed.connect(func(val: float): p_node.set("wobble_amount", val))
				p_row.add_child(wob_sb)

		&"dunes":
			if p_port == 0:
				var a_sb := SpinBox.new(); a_sb.min_value = 0.0; a_sb.max_value = 500.0; a_sb.step = 0.5
				a_sb.value = float(p_node.get("amplitude"))
				a_sb.value_changed.connect(func(val: float): p_node.set("amplitude", val))
				p_row.add_child(a_sb)
				var seed_btn := Button.new(); seed_btn.text = "🎲"; seed_btn.tooltip_text = "Randomize seed"
				seed_btn.pressed.connect(func(): p_node.set("seed", randi() % 100000))
				p_row.add_child(seed_btn)
			elif p_port == 1:
				var wl_sb := SpinBox.new(); wl_sb.min_value = 1.0; wl_sb.max_value = 500.0; wl_sb.step = 1.0
				wl_sb.value = float(p_node.get("wavelength"))
				wl_sb.value_changed.connect(func(val: float): p_node.set("wavelength", val))
				p_row.add_child(wl_sb)
			elif p_port == 2:
				var dir_sb := SpinBox.new(); dir_sb.min_value = 0.0; dir_sb.max_value = 360.0; dir_sb.step = 1.0
				dir_sb.value = float(p_node.get("direction_degrees"))
				dir_sb.value_changed.connect(func(val: float): p_node.set("direction_degrees", val))
				p_row.add_child(dir_sb)
			elif p_port == 3:
				var asym_sb := SpinBox.new(); asym_sb.min_value = 0.0; asym_sb.max_value = 1.0; asym_sb.step = 0.05
				asym_sb.value = float(p_node.get("asymmetry"))
				asym_sb.value_changed.connect(func(val: float): p_node.set("asymmetry", val))
				p_row.add_child(asym_sb)
			elif p_port == 4:
				var sh_sb := SpinBox.new(); sh_sb.min_value = 0.0; sh_sb.max_value = 1.0; sh_sb.step = 0.05
				sh_sb.value = float(p_node.get("crest_sharpness"))
				sh_sb.value_changed.connect(func(val: float): p_node.set("crest_sharpness", val))
				p_row.add_child(sh_sb)

		&"crater":
			if p_port == 0:
				var a_sb := SpinBox.new(); a_sb.min_value = 0.0; a_sb.max_value = 1000.0; a_sb.step = 0.5
				a_sb.value = float(p_node.get("amplitude"))
				a_sb.value_changed.connect(func(val: float): p_node.set("amplitude", val))
				p_row.add_child(a_sb)
			elif p_port == 1:
				var fd_sb := SpinBox.new(); fd_sb.min_value = 0.0; fd_sb.max_value = 500.0; fd_sb.step = 0.5
				fd_sb.value = float(p_node.get("floor_depth"))
				fd_sb.value_changed.connect(func(val: float): p_node.set("floor_depth", val))
				p_row.add_child(fd_sb)
			elif p_port == 2:
				var rh_sb := SpinBox.new(); rh_sb.min_value = 0.0; rh_sb.max_value = 200.0; rh_sb.step = 0.5
				rh_sb.value = float(p_node.get("rim_height"))
				rh_sb.value_changed.connect(func(val: float): p_node.set("rim_height", val))
				p_row.add_child(rh_sb)
			elif p_port == 3:
				var rw_sb := SpinBox.new(); rw_sb.min_value = 0.01; rw_sb.max_value = 1.0; rw_sb.step = 0.02
				rw_sb.value = float(p_node.get("rim_width"))
				rw_sb.value_changed.connect(func(val: float): p_node.set("rim_width", val))
				p_row.add_child(rw_sb)

		&"geological_primitive":
			if p_port == 0:
				var h_sb := SpinBox.new(); h_sb.min_value = 1.0; h_sb.max_value = 1000.0; h_sb.step = 1.0
				h_sb.value = float(p_node.get("height"))
				h_sb.value_changed.connect(func(val: float): p_node.set("height", val))
				p_row.add_child(h_sb)
			elif p_port == 1:
				var r_sb := SpinBox.new(); r_sb.min_value = 1.0; r_sb.max_value = 1000.0; r_sb.step = 1.0
				r_sb.value = float(p_node.get("radius"))
				r_sb.value_changed.connect(func(val: float): p_node.set("radius", val))
				p_row.add_child(r_sb)
			elif p_port == 2:
				var st_sb := SpinBox.new(); st_sb.min_value = 0.1; st_sb.max_value = 5.0; st_sb.step = 0.1
				st_sb.value = float(p_node.get("steepness"))
				st_sb.value_changed.connect(func(val: float): p_node.set("steepness", val))
				p_row.add_child(st_sb)
			elif p_port == 3:
				var ecc_sb := SpinBox.new(); ecc_sb.min_value = 0.0; ecc_sb.max_value = 0.95; ecc_sb.step = 0.05
				ecc_sb.value = float(p_node.get("eccentricity"))
				ecc_sb.value_changed.connect(func(val: float): p_node.set("eccentricity", val))
				p_row.add_child(ecc_sb)

		&"warp":
			if p_port == 1:
				var st_sb := SpinBox.new(); st_sb.min_value = 0.0; st_sb.max_value = 200.0; st_sb.step = 0.5
				st_sb.value = float(p_node.get("strength"))
				st_sb.value_changed.connect(func(val: float): p_node.set("strength", val))
				p_row.add_child(st_sb)
			elif p_port == 2:
				var a_sb := SpinBox.new(); a_sb.min_value = 0.0; a_sb.max_value = 500.0; a_sb.step = 0.5
				a_sb.value = float(p_node.get("amplitude"))
				a_sb.value_changed.connect(func(val: float): p_node.set("amplitude", val))
				p_row.add_child(a_sb)
			elif p_port == 3:
				var f_sb := SpinBox.new(); f_sb.min_value = 0.0001; f_sb.max_value = 0.1; f_sb.step = 0.001
				f_sb.value = float(p_node.get("frequency"))
				f_sb.value_changed.connect(func(val: float): p_node.set("frequency", val))
				p_row.add_child(f_sb)

		&"blend":
			if p_port == 0:
				var opt := OptionButton.new()
				opt.add_item("Add (+)", 0)
				opt.add_item("Subtract (-)", 1)
				opt.add_item("Multiply (*)", 2)
				opt.add_item("Max", 3)
				opt.add_item("Min", 4)
				opt.selected = int(p_node.get("mode"))
				opt.item_selected.connect(func(idx: int): p_node.set("mode", idx))
				p_row.add_child(opt)

		&"terrace":
			if p_port == 1:
				var b_sb := SpinBox.new(); b_sb.min_value = 0.1; b_sb.max_value = 200.0; b_sb.step = 0.5
				b_sb.value = float(p_node.get("band_height"))
				b_sb.value_changed.connect(func(val: float): p_node.set("band_height", val))
				p_row.add_child(b_sb)
			elif p_port == 2:
				var h_sb := SpinBox.new(); h_sb.min_value = 0.0; h_sb.max_value = 1.0; h_sb.step = 0.05
				h_sb.value = float(p_node.get("hardness"))
				h_sb.value_changed.connect(func(val: float): p_node.set("hardness", val))
				p_row.add_child(h_sb)
			elif p_port == 3:
				var amt_sb := SpinBox.new(); amt_sb.min_value = 0.0; amt_sb.max_value = 1.0; amt_sb.step = 0.05
				amt_sb.value = float(p_node.get("amount"))
				amt_sb.value_changed.connect(func(val: float): p_node.set("amount", val))
				p_row.add_child(amt_sb)

		&"strata":
			if p_port == 1:
				var b_sb := SpinBox.new(); b_sb.min_value = 0.1; b_sb.max_value = 200.0; b_sb.step = 0.5
				b_sb.value = float(p_node.get("band_height"))
				b_sb.value_changed.connect(func(val: float): p_node.set("band_height", val))
				p_row.add_child(b_sb)
			elif p_port == 2:
				var h_sb := SpinBox.new(); h_sb.min_value = 0.0; h_sb.max_value = 1.0; h_sb.step = 0.05
				h_sb.value = float(p_node.get("hardness"))
				h_sb.value_changed.connect(func(val: float): p_node.set("hardness", val))
				p_row.add_child(h_sb)
			elif p_port == 3:
				var d_sb := SpinBox.new(); d_sb.min_value = -45.0; d_sb.max_value = 45.0; d_sb.step = 0.5
				d_sb.value = float(p_node.get("dip"))
				d_sb.value_changed.connect(func(val: float): p_node.set("dip", val))
				p_row.add_child(d_sb)
			elif p_port == 4:
				var dir_sb := SpinBox.new(); dir_sb.min_value = 0.0; dir_sb.max_value = 360.0; dir_sb.step = 1.0
				dir_sb.value = float(p_node.get("dip_direction_degrees"))
				dir_sb.value_changed.connect(func(val: float): p_node.set("dip_direction_degrees", val))
				p_row.add_child(dir_sb)
			elif p_port == 5:
				var amt_sb := SpinBox.new(); amt_sb.min_value = 0.0; amt_sb.max_value = 1.0; amt_sb.step = 0.05
				amt_sb.value = float(p_node.get("amount"))
				amt_sb.value_changed.connect(func(val: float): p_node.set("amount", val))
				p_row.add_child(amt_sb)

		&"curve":
			if p_port == 1:
				var sb := SpinBox.new(); sb.min_value = -10000.0; sb.max_value = 10000.0; sb.step = 0.5; sb.value = float(p_node.get("input_min"))
				sb.value_changed.connect(func(v: float): p_node.set("input_min", v))
				p_row.add_child(sb)
			elif p_port == 2:
				var sb := SpinBox.new(); sb.min_value = -10000.0; sb.max_value = 10000.0; sb.step = 0.5; sb.value = float(p_node.get("input_max"))
				sb.value_changed.connect(func(v: float): p_node.set("input_max", v))
				p_row.add_child(sb)
			elif p_port == 3:
				var sb := SpinBox.new(); sb.min_value = -10000.0; sb.max_value = 10000.0; sb.step = 0.5; sb.value = float(p_node.get("output_min"))
				sb.value_changed.connect(func(v: float): p_node.set("output_min", v))
				p_row.add_child(sb)
			elif p_port == 4:
				var sb := SpinBox.new(); sb.min_value = -10000.0; sb.max_value = 10000.0; sb.step = 0.5; sb.value = float(p_node.get("output_max"))
				sb.value_changed.connect(func(v: float): p_node.set("output_max", v))
				p_row.add_child(sb)
			elif p_port == 5:
				var sb := SpinBox.new(); sb.min_value = 0.0; sb.max_value = 1.0; sb.step = 0.05; sb.value = float(p_node.get("amount"))
				sb.value_changed.connect(func(v: float): p_node.set("amount", v))
				p_row.add_child(sb)

		&"remap":
			if p_port == 1:
				var sb := SpinBox.new(); sb.min_value = -10000.0; sb.max_value = 10000.0; sb.step = 0.5; sb.value = float(p_node.get("in_min"))
				sb.value_changed.connect(func(v: float): p_node.set("in_min", v))
				p_row.add_child(sb)
			elif p_port == 2:
				var sb := SpinBox.new(); sb.min_value = -10000.0; sb.max_value = 10000.0; sb.step = 0.5; sb.value = float(p_node.get("in_max"))
				sb.value_changed.connect(func(v: float): p_node.set("in_max", v))
				p_row.add_child(sb)
			elif p_port == 3:
				var sb := SpinBox.new(); sb.min_value = -10000.0; sb.max_value = 10000.0; sb.step = 0.5; sb.value = float(p_node.get("out_min"))
				sb.value_changed.connect(func(v: float): p_node.set("out_min", v))
				p_row.add_child(sb)
			elif p_port == 4:
				var sb := SpinBox.new(); sb.min_value = -10000.0; sb.max_value = 10000.0; sb.step = 0.5; sb.value = float(p_node.get("out_max"))
				sb.value_changed.connect(func(v: float): p_node.set("out_max", v))
				p_row.add_child(sb)

		&"mask":
			if p_port == 0:
				var opt := OptionButton.new()
				opt.add_item("Slope (deg)", 0); opt.add_item("Elevation (m)", 1); opt.add_item("Curvature", 2)
				opt.selected = int(p_node.get("property"))
				opt.item_selected.connect(func(id: int): p_node.set("property", id))
				p_row.add_child(opt)
			elif p_port == 1:
				var sb := SpinBox.new(); sb.min_value = -10000.0; sb.max_value = 10000.0; sb.step = 0.5; sb.value = float(p_node.get("band_min"))
				sb.value_changed.connect(func(v: float): p_node.set("band_min", v))
				p_row.add_child(sb)
			elif p_port == 2:
				var sb := SpinBox.new(); sb.min_value = -10000.0; sb.max_value = 10000.0; sb.step = 0.5; sb.value = float(p_node.get("band_max"))
				sb.value_changed.connect(func(v: float): p_node.set("band_max", v))
				p_row.add_child(sb)
			elif p_port == 3:
				var sb := SpinBox.new(); sb.min_value = 0.0; sb.max_value = 500.0; sb.step = 0.5; sb.value = float(p_node.get("falloff_lo"))
				sb.value_changed.connect(func(v: float): p_node.set("falloff_lo", v))
				p_row.add_child(sb)
			elif p_port == 4:
				var sb := SpinBox.new(); sb.min_value = 0.0; sb.max_value = 500.0; sb.step = 0.5; sb.value = float(p_node.get("falloff_hi"))
				sb.value_changed.connect(func(v: float): p_node.set("falloff_hi", v))
				p_row.add_child(sb)
			elif p_port == 5:
				var sb := SpinBox.new(); sb.min_value = 0.0; sb.max_value = 1.0; sb.step = 0.05; sb.value = float(p_node.get("strength"))
				sb.value_changed.connect(func(v: float): p_node.set("strength", v))
				p_row.add_child(sb)

		&"curvature":
			if p_port == 0:
				var opt := OptionButton.new()
				opt.add_item("Total", 0); opt.add_item("Convexity", 1); opt.add_item("Concavity", 2)
				opt.selected = int(p_node.get("mode"))
				opt.item_selected.connect(func(id: int): p_node.set("mode", id))
				p_row.add_child(opt)
			elif p_port == 1:
				var sb := SpinBox.new(); sb.min_value = 1; sb.max_value = 10; sb.step = 1; sb.value = int(p_node.get("radius"))
				sb.value_changed.connect(func(v: float): p_node.set("radius", int(v)))
				p_row.add_child(sb)
			elif p_port == 2:
				var sb := SpinBox.new(); sb.min_value = 0.1; sb.max_value = 10.0; sb.step = 0.1; sb.value = float(p_node.get("contrast"))
				sb.value_changed.connect(func(v: float): p_node.set("contrast", v))
				p_row.add_child(sb)

		&"talus_projection":
			if p_port == 1:
				var sb := SpinBox.new(); sb.min_value = 5.0; sb.max_value = 80.0; sb.step = 0.5; sb.value = float(p_node.get("talus_angle_deg"))
				sb.value_changed.connect(func(v: float): p_node.set("talus_angle_deg", v))
				p_row.add_child(sb)
			elif p_port == 2:
				var sb := SpinBox.new(); sb.min_value = 1; sb.max_value = 100; sb.step = 1; sb.value = int(p_node.get("iterations"))
				sb.value_changed.connect(func(v: float): p_node.set("iterations", int(v)))
				p_row.add_child(sb)
			elif p_port == 3:
				var sb := SpinBox.new(); sb.min_value = 0.01; sb.max_value = 1.0; sb.step = 0.05; sb.value = float(p_node.get("transfer_rate"))
				sb.value_changed.connect(func(v: float): p_node.set("transfer_rate", v))
				p_row.add_child(sb)
			elif p_port == 4:
				var sb := SpinBox.new(); sb.min_value = 0.0; sb.max_value = 1.0; sb.step = 0.05; sb.value = float(p_node.get("amount"))
				sb.value_changed.connect(func(v: float): p_node.set("amount", v))
				p_row.add_child(sb)

		&"spectral_equalizer":
			if p_port == 1:
				var sb := SpinBox.new(); sb.min_value = 0.0; sb.max_value = 5.0; sb.step = 0.05; sb.value = float(p_node.get("macro_gain"))
				sb.value_changed.connect(func(v: float): p_node.set("macro_gain", v))
				p_row.add_child(sb)
			elif p_port == 2:
				var sb := SpinBox.new(); sb.min_value = 0.0; sb.max_value = 5.0; sb.step = 0.05; sb.value = float(p_node.get("meso_gain"))
				sb.value_changed.connect(func(v: float): p_node.set("meso_gain", v))
				p_row.add_child(sb)
			elif p_port == 3:
				var sb := SpinBox.new(); sb.min_value = 0.0; sb.max_value = 5.0; sb.step = 0.05; sb.value = float(p_node.get("micro_gain"))
				sb.value_changed.connect(func(v: float): p_node.set("micro_gain", v))
				p_row.add_child(sb)
			elif p_port == 4:
				var sb := SpinBox.new(); sb.min_value = 0.0; sb.max_value = 1.0; sb.step = 0.05; sb.value = float(p_node.get("amount"))
				sb.value_changed.connect(func(v: float): p_node.set("amount", v))
				p_row.add_child(sb)

		&"depression_filling":
			if p_port == 1:
				var sb := SpinBox.new(); sb.min_value = 0.0; sb.max_value = 500.0; sb.step = 0.5; sb.value = float(p_node.get("fill_depth_limit"))
				sb.value_changed.connect(func(v: float): p_node.set("fill_depth_limit", v))
				p_row.add_child(sb)
			elif p_port == 2:
				var sb := SpinBox.new(); sb.min_value = 0.0; sb.max_value = 1.0; sb.step = 0.05; sb.value = float(p_node.get("amount"))
				sb.value_changed.connect(func(v: float): p_node.set("amount", v))
				p_row.add_child(sb)

		&"erosion_hydraulic":
			if p_port == 1:
				var sb := SpinBox.new(); sb.min_value = 1; sb.max_value = 200; sb.step = 1; sb.value = int(p_node.get("iterations"))
				sb.value_changed.connect(func(v: float): p_node.set("iterations", int(v)))
				p_row.add_child(sb)
			elif p_port == 2:
				var sb := SpinBox.new(); sb.min_value = 0.001; sb.max_value = 1.0; sb.step = 0.01; sb.value = float(p_node.get("rain_rate"))
				sb.value_changed.connect(func(v: float): p_node.set("rain_rate", v))
				p_row.add_child(sb)
			elif p_port == 3:
				var sb := SpinBox.new(); sb.min_value = 0.01; sb.max_value = 2.0; sb.step = 0.05; sb.value = float(p_node.get("erosion_speed"))
				sb.value_changed.connect(func(v: float): p_node.set("erosion_speed", v))
				p_row.add_child(sb)
			elif p_port == 4:
				var sb := SpinBox.new(); sb.min_value = 0.01; sb.max_value = 2.0; sb.step = 0.05; sb.value = float(p_node.get("deposition_speed"))
				sb.value_changed.connect(func(v: float): p_node.set("deposition_speed", v))
				p_row.add_child(sb)

		&"erosion_thermal":
			if p_port == 2:
				var sb := SpinBox.new(); sb.min_value = 5.0; sb.max_value = 80.0; sb.step = 0.5; sb.value = float(p_node.get("talus_angle"))
				sb.value_changed.connect(func(v: float): p_node.set("talus_angle", v))
				p_row.add_child(sb)
			elif p_port == 3:
				var sb := SpinBox.new(); sb.min_value = 1; sb.max_value = 200; sb.step = 1; sb.value = int(p_node.get("iterations"))
				sb.value_changed.connect(func(v: float): p_node.set("iterations", int(v)))
				p_row.add_child(sb)
			elif p_port == 4:
				var sb := SpinBox.new(); sb.min_value = 0.01; sb.max_value = 1.0; sb.step = 0.05; sb.value = float(p_node.get("settling_rate"))
				sb.value_changed.connect(func(v: float): p_node.set("settling_rate", v))
				p_row.add_child(sb)

		&"erosion":
			if p_port == 1:
				var sb := SpinBox.new(); sb.min_value = 1; sb.max_value = 200; sb.step = 1; sb.value = int(p_node.get("iterations"))
				sb.value_changed.connect(func(v: float): p_node.set("iterations", int(v)))
				p_row.add_child(sb)
			elif p_port == 2:
				var sb := SpinBox.new(); sb.min_value = 0.001; sb.max_value = 1.0; sb.step = 0.01; sb.value = float(p_node.get("erosion_rate"))
				sb.value_changed.connect(func(v: float): p_node.set("erosion_rate", v))
				p_row.add_child(sb)
			elif p_port == 3:
				var sb := SpinBox.new(); sb.min_value = 0.0; sb.max_value = 2.0; sb.step = 0.05; sb.value = float(p_node.get("hillslope_diffusion"))
				sb.value_changed.connect(func(v: float): p_node.set("hillslope_diffusion", v))
				p_row.add_child(sb)

		&"scree":
			if p_port == 1:
				var sb := SpinBox.new(); sb.min_value = 0.0; sb.max_value = 100.0; sb.step = 0.5; sb.value = float(p_node.get("amplitude"))
				sb.value_changed.connect(func(v: float): p_node.set("amplitude", v))
				p_row.add_child(sb)
			elif p_port == 2:
				var sb := SpinBox.new(); sb.min_value = 0.01; sb.max_value = 10.0; sb.step = 0.05; sb.value = float(p_node.get("grain_size"))
				sb.value_changed.connect(func(v: float): p_node.set("grain_size", v))
				p_row.add_child(sb)
			elif p_port == 3:
				var sb := SpinBox.new(); sb.min_value = 5.0; sb.max_value = 60.0; sb.step = 0.5; sb.value = float(p_node.get("min_slope_degrees"))
				sb.value_changed.connect(func(v: float): p_node.set("min_slope_degrees", v))
				p_row.add_child(sb)

		&"dla":
			if p_port == 1:
				var sb := SpinBox.new(); sb.min_value = 0.0; sb.max_value = 500.0; sb.step = 1.0; sb.value = float(p_node.get("amplitude"))
				sb.value_changed.connect(func(v: float): p_node.set("amplitude", v))
				p_row.add_child(sb)
			elif p_port == 2:
				var sb := SpinBox.new(); sb.min_value = 0.2; sb.max_value = 1.0; sb.step = 0.05; sb.value = float(p_node.get("coverage"))
				sb.value_changed.connect(func(v: float): p_node.set("coverage", v))
				p_row.add_child(sb)
			elif p_port == 3:
				var sb := SpinBox.new(); sb.min_value = 0.03; sb.max_value = 0.50; sb.step = 0.01; sb.value = float(p_node.get("detail_size"))
				sb.value_changed.connect(func(v: float): p_node.set("detail_size", v))
				p_row.add_child(sb)

		&"lake_flooding":
			if p_port == 0:
				var opt := OptionButton.new()
				opt.add_item("Global Elevation", 0); opt.add_item("Local Depressions", 1)
				opt.selected = int(p_node.get("flood_mode"))
				opt.item_selected.connect(func(id: int): p_node.set("flood_mode", id))
				p_row.add_child(opt)
			elif p_port == 1:
				var sb := SpinBox.new(); sb.min_value = -1000.0; sb.max_value = 2000.0; sb.step = 0.5; sb.value = float(p_node.get("water_elevation"))
				sb.value_changed.connect(func(v: float): p_node.set("water_elevation", v))
				p_row.add_child(sb)
			elif p_port == 2:
				var sb := SpinBox.new(); sb.min_value = 0.0; sb.max_value = 1.0; sb.step = 0.02; sb.value = float(p_node.get("flood_percent"))
				sb.value_changed.connect(func(v: float): p_node.set("flood_percent", v))
				p_row.add_child(sb)
			elif p_port == 3:
				var sb := SpinBox.new(); sb.min_value = 0.0; sb.max_value = 50.0; sb.step = 0.5; sb.value = float(p_node.get("shoreline_width"))
				sb.value_changed.connect(func(v: float): p_node.set("shoreline_width", v))
				p_row.add_child(sb)

		&"stream_extraction":
			if p_port == 1:
				var sb := SpinBox.new(); sb.min_value = 1.0; sb.max_value = 500.0; sb.step = 1.0; sb.value = float(p_node.get("min_catchment_cells"))
				sb.value_changed.connect(func(v: float): p_node.set("min_catchment_cells", v))
				p_row.add_child(sb)
			elif p_port == 2:
				var sb := SpinBox.new(); sb.min_value = 0.0; sb.max_value = 50.0; sb.step = 0.2; sb.value = float(p_node.get("carve_depth"))
				sb.value_changed.connect(func(v: float): p_node.set("carve_depth", v))
				p_row.add_child(sb)
			elif p_port == 3:
				var sb := SpinBox.new(); sb.min_value = 1.0; sb.max_value = 50.0; sb.step = 0.5; sb.value = float(p_node.get("channel_width"))
				sb.value_changed.connect(func(v: float): p_node.set("channel_width", v))
				p_row.add_child(sb)


func _add_inline_node_controls(p_gn: GraphNode, p_index: int, p_node: Pasture3DGraphNode) -> void:
	var op := p_node.op()
	match op:
		&"remap", &"curve":
			var btn_row := HBoxContainer.new()
			var auto_btn := Button.new()
			auto_btn.text = "Auto Fit Range"
			auto_btn.tooltip_text = "Auto fit in_min and in_max to upstream terrain range"
			auto_btn.pressed.connect(func():
				_auto_fit_node_range(p_index)
			)
			btn_row.add_child(auto_btn)
			p_gn.add_child(btn_row)


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

		5: # Eroded Alpine Massif (Noise + Hydraulic + Thermal + Ridge)
			var nz = Pasture3DGraphNodeRegistry.create(&"noise")
			nz.set("amplitude", 45.0)
			var fnz = FastNoiseLite.new()
			fnz.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
			fnz.frequency = 0.006
			fnz.fractal_octaves = 5
			nz.set("noise", fnz)

			var hydro = Pasture3DGraphNodeRegistry.create(&"erosion_hydraulic")
			hydro.set("iterations", 15)
			hydro.set("rain_rate", 0.02)
			hydro.set("erosion_speed", 0.35)
			hydro.set("deposition_speed", 0.25)

			var therm = Pasture3DGraphNodeRegistry.create(&"erosion_thermal")
			therm.set("talus_angle", 30.0)
			therm.set("iterations", 12)
			therm.set("settling_rate", 0.45)

			var curv = Pasture3DGraphNodeRegistry.create(&"curvature")
			curv.set("mode", 0) # Ridge
			curv.set("radius", 2)
			curv.set("contrast", 1.5)

			_ur_add_do_method(graph, &"add_node", [nz, p_pos])
			_ur_add_do_method(graph, &"add_node", [hydro, p_pos + Vector2(220, 0)])
			_ur_add_do_method(graph, &"add_node", [therm, p_pos + Vector2(440, 0)])
			_ur_add_do_method(graph, &"add_node", [curv, p_pos + Vector2(660, 0)])
			_ur_add_do_method(graph, &"connect_ports", [base_idx, 0, base_idx + 1, 0])
			_ur_add_do_method(graph, &"connect_ports", [base_idx + 1, 0, base_idx + 2, 0])
			_ur_add_do_method(graph, &"connect_ports", [base_idx + 2, 0, base_idx + 3, 0])
			_ur_add_do_method(graph, &"group_nodes_in_frame", [[base_idx, base_idx + 1, base_idx + 2, base_idx + 3], "Eroded Alpine Massif"])

		6: # Sedimentary Canyon (Strata + Curvature + Curve Remap)
			var nz = Pasture3DGraphNodeRegistry.create(&"noise")
			nz.set("amplitude", 30.0)
			var fnz = FastNoiseLite.new()
			fnz.frequency = 0.005
			nz.set("noise", fnz)

			var strata = Pasture3DGraphNodeRegistry.create(&"strata")
			strata.set("band_height", 6.0)
			strata.set("hardness", 0.8)
			strata.set("dip", 5.0)
			strata.set("dip_direction_degrees", 60.0)

			var curv = Pasture3DGraphNodeRegistry.create(&"curvature")
			curv.set("mode", 1) # Valley
			curv.set("radius", 1)
			curv.set("contrast", 1.8)

			var curve_node = Pasture3DGraphNodeRegistry.create(&"curve")
			var c = Curve.new()
			c.add_point(Vector2(0, 0))
			c.add_point(Vector2(0.5, 0.3))
			c.add_point(Vector2(1.0, 1.0))
			curve_node.set("curve", c)
			curve_node.set("input_min", 0.0)
			curve_node.set("input_max", 50.0)
			curve_node.set("output_min", 0.0)
			curve_node.set("output_max", 60.0)

			_ur_add_do_method(graph, &"add_node", [nz, p_pos])
			_ur_add_do_method(graph, &"add_node", [strata, p_pos + Vector2(220, 0)])
			_ur_add_do_method(graph, &"add_node", [curve_node, p_pos + Vector2(440, 0)])
			_ur_add_do_method(graph, &"add_node", [curv, p_pos + Vector2(440, 160)])
			_ur_add_do_method(graph, &"connect_ports", [base_idx, 0, base_idx + 1, 0])
			_ur_add_do_method(graph, &"connect_ports", [base_idx + 1, 0, base_idx + 2, 0])
			_ur_add_do_method(graph, &"connect_ports", [base_idx + 1, 0, base_idx + 3, 0])
			_ur_add_do_method(graph, &"group_nodes_in_frame", [[base_idx, base_idx + 1, base_idx + 2, base_idx + 3], "Sedimentary Canyon"])

		7: # Glacial Valley (Domain Warp + Furrows + Hydraulic Erosion)
			var furrows = Pasture3DGraphNodeRegistry.create(&"furrows")
			furrows.set("amplitude", 20.0)
			furrows.set("spacing", 120.0)

			var warp = Pasture3DGraphNodeRegistry.create(&"warp")
			warp.set("strength", 35.0)
			warp.set("frequency", 0.008)
			warp.set("amplitude", 10.0)

			var hydro = Pasture3DGraphNodeRegistry.create(&"erosion_hydraulic")
			hydro.set("iterations", 18)
			hydro.set("rain_rate", 0.015)
			hydro.set("erosion_speed", 0.4)

			var remap = Pasture3DGraphNodeRegistry.create(&"remap")
			remap.set("in_min", -10.0)
			remap.set("in_max", 50.0)
			remap.set("out_min", 0.0)
			remap.set("out_max", 40.0)
			remap.set("soft_knee", 0.2)

			_ur_add_do_method(graph, &"add_node", [furrows, p_pos])
			_ur_add_do_method(graph, &"add_node", [warp, p_pos + Vector2(220, 0)])
			_ur_add_do_method(graph, &"add_node", [hydro, p_pos + Vector2(440, 0)])
			_ur_add_do_method(graph, &"add_node", [remap, p_pos + Vector2(660, 0)])
			_ur_add_do_method(graph, &"connect_ports", [base_idx, 0, base_idx + 1, 0])
			_ur_add_do_method(graph, &"connect_ports", [base_idx + 1, 0, base_idx + 2, 0])
			_ur_add_do_method(graph, &"connect_ports", [base_idx + 2, 0, base_idx + 3, 0])
			_ur_add_do_method(graph, &"group_nodes_in_frame", [[base_idx, base_idx + 1, base_idx + 2, base_idx + 3], "Glacial Valley"])
			
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


## Re-solve a solver from the canvas — the same clear_cache() the node's inspector "Bake" button runs.
## NOT an undo/redo action: it drops an in-memory cache and re-solves to the SAME result the graph would
## produce live, so there is nothing to undo. The node emits `changed`, which re-bakes the host.
func _action_bake_solver(p_index: int) -> void:
	if graph == null or p_index < 0 or p_index >= graph.nodes.size():
		return
	var node: Pasture3DGraphNode = graph.nodes[p_index]
	if node != null and node.has_method("clear_cache"):
		node.clear_cache()


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


## Toggle a node's inline 2D preview. Routed through undo/redo so the flag persists and the scene is marked
## dirty, but the whole do/undo is ONE method (`_apply_preview_flag`) with an explicit target value, so it is
## independent of operation ordering within the action and never depends on preview_on's read-back. It never
## emits the node's `changed`, so it never re-bakes the terrain; turning a preview on evaluates nothing here
## and just schedules the shared low-res tap pass to fill the newly shown thumbnail.
func _action_set_node_preview(p_index: int, p_on: bool) -> void:
	if graph == null or p_index < 0 or p_index >= graph.nodes.size():
		return
	var node: Pasture3DGraphNode = graph.nodes[p_index]
	if node == null or node.preview_on == p_on:
		return
	_ur_create_action("Toggle Node Preview")
	_ur_add_do_method(self, &"_apply_preview_flag", [p_index, p_on])
	_ur_add_undo_method(self, &"_apply_preview_flag", [p_index, not p_on])
	_ur_commit()


## Set a node's preview_on and sync its UI in one step (the toggle action's do/undo body). Sets the flag
## directly — preview_on has no emitting setter, so this does NOT re-bake — then shows/hides the thumbnail
## box, matches the 👁 button, and schedules a refresh so a newly shown thumbnail fills in. Pure view work.
func _apply_preview_flag(p_index: int, p_on: bool) -> void:
	if graph == null or p_index < 0 or p_index >= graph.nodes.size():
		return
	var node: Pasture3DGraphNode = graph.nodes[p_index]
	if node == null:
		return
	node.preview_on = p_on
	if _preview_rects.has(p_index):
		var tr: TextureRect = _preview_rects[p_index]
		if is_instance_valid(tr) and tr.get_parent() != null:
			tr.get_parent().visible = p_on
	if _preview_buttons.has(p_index):
		var btn: Button = _preview_buttons[p_index]
		if is_instance_valid(btn) and btn.button_pressed != p_on:
			btn.set_pressed_no_signal(p_on)
	_schedule_preview_refresh()


## (Re)start the debounce timer when at least one node wants a preview. Cheap and idempotent — the real work
## happens once on timeout. When nothing is preview-on, invalidates any in-flight result and stays idle.
func _schedule_preview_refresh() -> void:
	if graph == null or _preview_timer == null:
		return
	var any_on := false
	for n in graph.nodes:
		if n != null and n.preview_on:
			any_on = true
			break
	if not any_on:
		_preview_token += 1 # drop anything in flight; nothing to show
		return
	_preview_timer.start(PREVIEW_DEBOUNCE_SEC)


## Debounce timeout: compile ONE native program covering every preview-on node, sample the canonical input,
## and hand the heavy evaluation + hillshade to a worker thread. All graph reads (compile, output types)
## happen here on the main thread; only pure C++ calls over plain arrays run off-thread.
func _refresh_previews() -> void:
	if graph == null or _preview_rects.is_empty():
		return
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_taps"):
		return # extension without the multi-tap primitive; skip previews rather than fall back to a re-eval
	var roots: Array = []
	for i in range(graph.nodes.size()):
		var n: Pasture3DGraphNode = graph.nodes[i]
		if n != null and n.preview_on and _preview_rects.has(i):
			roots.append(i)
	if roots.is_empty():
		return
	var compiled: Dictionary = graph.compile_graph_program_multi(roots)
	if compiled.is_empty():
		return # non-native graph (e.g. a solver mask wire); leave the last thumbnails in place this tick
	var program: Dictionary = compiled["program"]
	var slot_of: Dictionary = compiled["slot_of"]
	var tap_slots := PackedInt32Array()
	var slot_to_node: Dictionary = {}
	var slot_is_mask: Dictionary = {}
	for i in roots:
		if slot_of.has(i):
			var slot: int = int(slot_of[i])
			tap_slots.append(slot)
			slot_to_node[slot] = i
			slot_is_mask[slot] = graph.nodes[i].output_port_type() == Pasture3DGraphNode.PortType.MASK
	if tap_slots.is_empty():
		return
	var input: PackedFloat32Array = Pasture3DUtil.sample_brush_input(PREVIEW_SIZE, PREVIEW_SIZE, PREVIEW_RECT)
	_preview_token += 1
	var token := _preview_token
	WorkerThreadPool.add_task(func():
		_preview_worker(token, program, input, tap_slots, slot_to_node, slot_is_mask))


## Worker-thread body: one native tap pass, then a hillshade per tapped buffer. Touches only stateless C++
## statics over the plain data captured on the main thread, so it is safe off-thread; results are marshalled
## back with call_deferred, guarded by the dispatch token.
func _preview_worker(p_token: int, p_program: Dictionary, p_input: PackedFloat32Array,
		p_tap_slots: PackedInt32Array, p_slot_to_node: Dictionary, p_slot_is_mask: Dictionary) -> void:
	var taps: Dictionary = Pasture3DUtil.graph_eval_grid_taps(
			p_program, PREVIEW_SIZE, PREVIEW_SIZE, PREVIEW_RECT, p_input, p_tap_slots)
	var results: Dictionary = {}
	for slot in taps:
		var field: PackedFloat32Array = taps[slot]
		if field.size() != PREVIEW_SIZE * PREVIEW_SIZE:
			continue
		var is_mask: bool = bool(p_slot_is_mask.get(slot, false))
		var bytes: PackedByteArray = Pasture3DUtil.hillshade_image_grid(field, PREVIEW_SIZE, PREVIEW_SIZE, is_mask)
		results[int(p_slot_to_node[slot])] = bytes
	call_deferred(&"_apply_preview_textures", p_token, results)


## Main-thread apply of a completed tap pass. Drops the result if a newer dispatch (or a rebuild/clear) has
## bumped the token, or if a target rect no longer exists. Reuses each TextureRect's ImageTexture in place
## when the size matches so a refresh does not churn GPU textures.
func _apply_preview_textures(p_token: int, p_results: Dictionary) -> void:
	if p_token != _preview_token:
		return # a newer refresh superseded this one, or the canvas was rebuilt
	for idx in p_results:
		if not _preview_rects.has(idx):
			continue
		var tr: TextureRect = _preview_rects[idx]
		if not is_instance_valid(tr):
			continue
		var bytes: PackedByteArray = p_results[idx]
		if bytes.size() != PREVIEW_SIZE * PREVIEW_SIZE * 4:
			continue
		var img := Image.create_from_data(PREVIEW_SIZE, PREVIEW_SIZE, false, Image.FORMAT_RGBA8, bytes)
		var tex := tr.texture as ImageTexture
		if tex != null and tex.get_width() == PREVIEW_SIZE and tex.get_height() == PREVIEW_SIZE:
			tex.update(img)
		else:
			tr.texture = ImageTexture.create_from_image(img)


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
