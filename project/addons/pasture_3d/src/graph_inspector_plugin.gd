# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphInspectorPlugin — the shortcuts at the very top of the Inspector for anything that owns or
# is a terrain graph.
#
#   * a Pasture3DTerrainGraph, or a Pasture3DNodeGraph (the brush modifier that hosts one), gets a single
#     "Edit in Graph Editor" button — neither object has a modifier stack to describe.
#   * a Pasture3DTerrainBrush that runs a modifier stack gets a Pasture3DBrushGraphRow: Add/Open Graph and
#     the stack's Evaluation. A brush that does NOT run a stack (`_supports_modifiers()` false — Ridge,
#     Trough, Splat, Sim) gets nothing, the same rule Pasture3DTerrainBrush._get_property_list applies to
#     the Modifiers group. Shipping a control that silently does nothing is worse than not shipping it.
#
# The row's own logic lives in Pasture3DBrushGraphRow because this class cannot be instantiated outside the
# editor and therefore cannot be tested; see that file's header.
#
# See PASTURE3D_BRUSH_GRAPH_SHORTCUTS_SPEC.md Phase 1.

@tool
class_name Pasture3DGraphInspectorPlugin
extends EditorInspectorPlugin

# Preloaded rather than referenced by class_name: the plugin script loads at editor startup, potentially
# before a newly added class_name has entered the global class cache.
const BrushGraphRow = preload("res://addons/pasture_3d/src/brush_graph_row.gd")

var editor: Pasture3DGraphEditor
var plugin: EditorPlugin


func _can_handle(p_object: Object) -> bool:
	return p_object is Pasture3DTerrainGraph or p_object is Pasture3DNodeGraph \
			or p_object is Pasture3DTerrainBrush


func _parse_begin(p_object: Object) -> void:
	if p_object is Pasture3DTerrainBrush:
		var brush := p_object as Pasture3DTerrainBrush
		if not brush._supports_modifiers():
			return
		add_custom_control(BrushGraphRow.new().setup(brush, _bind))
		return

	var btn := Button.new()
	btn.text = "Edit in Graph Editor"
	btn.tooltip_text = "Open the Terrain Graph visual editor in the bottom panel"
	btn.pressed.connect(_open.bind(p_object))
	add_custom_control(btn)


func _open(p_object: Object) -> void:
	if p_object is Pasture3DTerrainGraph:
		_bind(p_object as Pasture3DTerrainGraph, null, null)
		return

	if p_object is Pasture3DNodeGraph:
		var mod := p_object as Pasture3DNodeGraph
		if mod.graph == null:
			mod.graph = Pasture3DTerrainGraph.create_default()
		_bind(mod.graph, mod, null)
		return

	if p_object is Pasture3DTerrainBrush:
		var brush := p_object as Pasture3DTerrainBrush
		var mod := BrushGraphRow.ensure_graph_modifier(brush)
		if mod != null:
			_bind(mod.graph, mod, brush)


func _bind(p_graph: Pasture3DTerrainGraph, p_mod: Pasture3DNodeGraph,
		p_brush: Pasture3DTerrainBrush) -> void:
	if p_graph == null or editor == null:
		return
	editor.edit_graph(p_graph, p_mod, p_brush)
	if plugin != null:
		plugin.make_bottom_panel_item_visible(editor)
