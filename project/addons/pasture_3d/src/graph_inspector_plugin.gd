# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphInspectorPlugin — puts an "Edit in Graph Editor" button at the top of the Inspector for a
# Pasture3DTerrainGraph, and for a Pasture3DNodeGraph (the brush modifier that hosts one). Pressing it
# binds the bottom-panel Pasture3DGraphEditor to that graph and reveals the panel — the same flow as
# double-clicking a VisualShader. A graph modifier with no graph yet gets one created on the spot.
@tool
class_name Pasture3DGraphInspectorPlugin
extends EditorInspectorPlugin

var editor: Pasture3DGraphEditor
var plugin: EditorPlugin


func _can_handle(p_object: Object) -> bool:
	return p_object is Pasture3DTerrainGraph or p_object is Pasture3DNodeGraph


func _parse_begin(p_object: Object) -> void:
	var btn := Button.new()
	btn.text = "Edit in Graph Editor"
	btn.pressed.connect(_open.bind(p_object))
	add_custom_control(btn)


func _open(p_object: Object) -> void:
	var target: Pasture3DTerrainGraph = null
	if p_object is Pasture3DTerrainGraph:
		target = p_object
	elif p_object is Pasture3DNodeGraph:
		var node_graph := p_object as Pasture3DNodeGraph
		if node_graph.graph == null:
			node_graph.graph = Pasture3DTerrainGraph.new() # a modifier with no graph gets an empty one
		target = node_graph.graph
	if target == null or editor == null:
		return
	editor.edit_graph(target)
	if plugin != null:
		plugin.make_bottom_panel_item_visible(editor)
