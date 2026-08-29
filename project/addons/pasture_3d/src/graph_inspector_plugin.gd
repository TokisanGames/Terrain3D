# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphInspectorPlugin — puts an "Edit in Graph Editor" button at the top of the Inspector for a
# Pasture3DTerrainGraph, for a Pasture3DNodeGraph (the brush modifier that hosts one), and for a
# Pasture3DPlow height brush (when Source = GRAPH or to switch to GRAPH). Pressing it binds the bottom-panel
# Pasture3DGraphEditor to that graph and reveals the panel.

@tool
class_name Pasture3DGraphInspectorPlugin
extends EditorInspectorPlugin

var editor: Pasture3DGraphEditor
var plugin: EditorPlugin


func _can_handle(p_object: Object) -> bool:
	return p_object is Pasture3DTerrainGraph or p_object is Pasture3DNodeGraph or p_object is Pasture3DPlow


func _parse_begin(p_object: Object) -> void:
	if p_object is Pasture3DPlow:
		var plow := p_object as Pasture3DPlow
		var btn := Button.new()
		btn.text = "Edit in Graph Editor"
		btn.tooltip_text = "Open the Terrain Graph visual editor in the bottom panel for this Plow brush"
		btn.pressed.connect(_open.bind(p_object))
		add_custom_control(btn)
	else:
		var btn := Button.new()
		btn.text = "Edit in Graph Editor"
		btn.tooltip_text = "Open the Terrain Graph visual editor in the bottom panel"
		btn.pressed.connect(_open.bind(p_object))
		add_custom_control(btn)


func _open(p_object: Object) -> void:
	var target: Pasture3DTerrainGraph = null
	var mod: Pasture3DNodeGraph = null
	var brush: Pasture3DTerrainBrush = null

	if p_object is Pasture3DTerrainGraph:
		target = p_object as Pasture3DTerrainGraph
	elif p_object is Pasture3DNodeGraph:
		mod = p_object as Pasture3DNodeGraph
		if mod.graph == null:
			mod.graph = Pasture3DTerrainGraph.create_default()
		target = mod.graph
	elif p_object is Pasture3DPlow:
		var plow := p_object as Pasture3DPlow
		brush = plow
		# Find or add a Pasture3DNodeGraph in plow.modifiers
		for m in plow.modifiers:
			if m is Pasture3DNodeGraph:
				mod = m as Pasture3DNodeGraph
				break
		if mod == null:
			mod = Pasture3DNodeGraph.new()
			mod.name = "Terrain Graph"
			mod.graph = Pasture3DTerrainGraph.new()
			var mc = Pasture3DGraphNodeRegistry.create(&"mountain_cone")
			if mc != null:
				mc.set("elevation", 35.0)
			var out_n = Pasture3DGraphNodeRegistry.create(&"output")
			if mc != null and out_n != null:
				mod.graph.add_node(mc)
				mod.graph.add_node(out_n)
				mod.graph.connect_ports(0, 0, 1, 0)
				mod.graph.output_node = 1
			else:
				mod.graph = Pasture3DTerrainGraph.create_default()
			plow.modifiers.append(mod)
		elif mod.graph == null:
			mod.graph = Pasture3DTerrainGraph.create_default()
		target = mod.graph

	if target == null or editor == null:
		return
	editor.edit_graph(target, mod, brush)
	if plugin != null:
		plugin.make_bottom_panel_item_visible(editor)
