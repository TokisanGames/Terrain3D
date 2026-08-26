# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphEditor — the bottom-panel visual editor for a Pasture3DTerrainGraph, built on Godot's
# GraphEdit/GraphNode (the same controls the VisualShader / Shader Graph editor uses). The canvas owns
# TOPOLOGY — nodes, wiring and which node is the output; a node's parameters are edited in Godot's normal
# Inspector (selecting a node makes it the edited resource). See PASTURE3D_TERRAIN_GRAPH_SPEC.md.
#
# All structural edits go through the graph's editing API (add_node / connect_ports / … on
# Pasture3DTerrainGraph), which the headless GraphEditModelGate covers; this file is the VIEW over it and
# rebuilds itself whenever the graph emits `changed`.
@tool
class_name Pasture3DGraphEditor
extends VBoxContainer

var plugin: EditorPlugin
var graph: Pasture3DTerrainGraph

var _graphedit: GraphEdit
var _add_menu: MenuButton
var _title: Label
var _hint: Label


func initialize(p_plugin: EditorPlugin) -> void:
	plugin = p_plugin
	_build_ui()
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
	custom_minimum_size = Vector2(0, 220)
	var bar := HBoxContainer.new()
	add_child(bar)
	_add_menu = MenuButton.new()
	_add_menu.text = "Add Node"
	_add_menu.flat = false
	for i in range(Pasture3DGraphNodeRegistry.entries().size()):
		var e: Dictionary = Pasture3DGraphNodeRegistry.entries()[i]
		_add_menu.get_popup().add_item("%s  (%s)" % [e["title"], e["role"]], i)
	_add_menu.get_popup().id_pressed.connect(_on_add_selected)
	bar.add_child(_add_menu)
	_title = Label.new()
	_title.text = "  (no graph)"
	bar.add_child(_title)

	_graphedit = GraphEdit.new()
	_graphedit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_graphedit.right_disconnects = true
	_graphedit.connection_request.connect(_on_connection_request)
	_graphedit.disconnection_request.connect(_on_disconnection_request)
	_graphedit.delete_nodes_request.connect(_on_delete_request)
	_graphedit.node_selected.connect(_on_node_selected)
	_graphedit.end_node_move.connect(_on_node_move_end)
	add_child(_graphedit)

	_hint = Label.new()
	_hint.text = "No graph open. Select a Pasture3DTerrainGraph (or a graph modifier) and press " \
			+ "\"Edit in Graph Editor\"."
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_graphedit.add_child(_hint)


# ---- build / rebuild --------------------------------------------------------------------------------

func _rebuild() -> void:
	if _graphedit == null:
		return
	_clear()
	var has := graph != null
	_add_menu.disabled = not has
	_title.text = "  editing: %s" % _graph_label() if has else "  (no graph)"
	_hint.visible = not has
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
	var is_out := p_index == graph.output_index()
	gn.title = p_node.display_name() + ("  ● OUT" if is_out else "")
	gn.position_offset = p_node.graph_position
	if is_out:
		gn.modulate = Color(0.8, 1.0, 0.85)

	# "Set as Output" lets you designate any node the output — but only when there is no Output SINK node,
	# which takes that role automatically (see Pasture3DTerrainGraph.output_index). A sink offers no button.
	if p_node.has_output() and not _graph_has_sink():
		var out_btn := Button.new()
		out_btn.text = "Out"
		out_btn.tooltip_text = "Make this node the graph's output"
		out_btn.pressed.connect(func(): graph.set_output(p_index))
		gn.get_titlebar_hbox().add_child(out_btn)

	# One row per input port; the single output (when the node has one) sits on the first row's right edge.
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


## True when the graph holds an Output sink node, which becomes the output automatically.
func _graph_has_sink() -> bool:
	for nd in graph.nodes:
		if nd != null and nd.op() == &"output":
			return true
	return false


func _graph_label() -> String:
	if not graph.resource_path.is_empty():
		return graph.resource_path.get_file()
	return "Terrain Graph"


# ---- edits (delegate to the model, which re-emits `changed` -> _rebuild) ------------------------------

func _on_add_selected(p_id: int) -> void:
	if graph == null:
		return
	var e: Dictionary = Pasture3DGraphNodeRegistry.entries()[p_id]
	var node := Pasture3DGraphNodeRegistry.create(e["op"])
	var pos := _graphedit.scroll_offset / _graphedit.zoom + Vector2(60, 60) + Vector2(30, 30) * graph.nodes.size()
	graph.add_node(node, pos)


func _on_connection_request(p_from: StringName, p_from_port: int, p_to: StringName, p_to_port: int) -> void:
	if graph != null:
		graph.connect_ports(_idx(p_from), p_from_port, _idx(p_to), p_to_port)


func _on_disconnection_request(p_from: StringName, p_from_port: int, p_to: StringName, p_to_port: int) -> void:
	if graph != null:
		graph.disconnect_ports(_idx(p_from), p_from_port, _idx(p_to), p_to_port)


func _on_delete_request(p_names: Array) -> void:
	if graph == null:
		return
	# Highest index first, because remove_node reindexes everything above it.
	var idx: Array = []
	for nm in p_names:
		idx.append(_idx(nm))
	idx.sort()
	idx.reverse()
	for i in idx:
		graph.remove_node(i)


func _on_node_selected(p_node: Node) -> void:
	if graph == null:
		return
	var i := _idx(p_node.name)
	if i >= 0 and i < graph.nodes.size() and graph.nodes[i] != null:
		EditorInterface.edit_resource(graph.nodes[i])


func _on_node_move_end() -> void:
	# Persist the layout without re-baking (graph_position does not emit `changed`).
	if graph == null:
		return
	for c in _graphedit.get_children():
		if c is GraphNode:
			var i := _idx(c.name)
			if i >= 0 and i < graph.nodes.size() and graph.nodes[i] != null:
				graph.nodes[i].graph_position = c.position_offset


func _idx(p_name) -> int:
	var s := String(p_name)
	return int(s.substr(1)) if s.begins_with("n") else -1
