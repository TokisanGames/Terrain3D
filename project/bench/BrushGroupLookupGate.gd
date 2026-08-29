# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# BrushGroupLookupGate — the graph editor must be able to find a brush it was never handed.
#
# `Pasture3DTerrainBrush` joins the group `Pasture3DTerrainBrush.BRUSH_GROUP` ("pasture3d_brush"). Three
# lookups used to ask for "pasture3d_brushes", a group nothing joins, so their loops matched nothing and
# always fell through to null. It stayed invisible because the paths that use them try the editor SELECTION
# first, and in interactive use the brush is usually selected — the group scan is the fallback for exactly
# the case the Terrain Graph dock's "Brush Details" and graph dropdown exist to serve: you are in the graph,
# and the selection has moved on.
#
# So this gate asserts the lookup succeeds with NOTHING selected, and pairs every criterion with the old
# string. If the control passes too, the group scan was never the thing that answered and this gate is
# measuring the selection path instead of what it claims to measure.
#
# See PASTURE3D_BRUSH_GRAPH_SHORTCUTS_SPEC.md Phase 0.

extends Node

const OLD_GROUP := &"pasture3d_brushes" ## the group that never existed — the control

var _fail := 0


func _ready() -> void:
	print("=== BrushGroupLookupGate: finding a brush by group, with nothing selected ===\n")
	_test_group_membership()
	_test_editor_finds_brush_for_modifier()
	_test_editor_finds_host_brush()
	_test_modifier_finds_its_own_host()
	print("\n=== %s (%d failures) ===\n" % [
		"BRUSH GROUP LOOKUP PASS" if _fail == 0 else "BRUSH GROUP LOOKUP FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


## A Mound carrying one graph modifier, in the tree so group lookups can see it.
func _make_brush() -> Array:
	var mound := Pasture3DMound.new()
	mound.name = "GateMound"
	var mod := Pasture3DNodeGraph.new()
	mod.graph = Pasture3DTerrainGraph.create_default()
	mound.modifiers = [mod]
	add_child(mound)
	return [mound, mod]


func _check(p_label: String, p_ok: bool, p_detail: String = "") -> void:
	if not p_ok:
		_fail += 1
	print("    %s %s%s" % ["PASS" if p_ok else "FAIL", p_label, ("  (%s)" % p_detail) if p_detail != "" else ""])


func _test_group_membership() -> void:
	print("[A] The brush joins BRUSH_GROUP and not the old spelling")
	var pair := _make_brush()
	var mound: Pasture3DMound = pair[0]
	var in_real: bool = mound.is_in_group(Pasture3DTerrainBrush.BRUSH_GROUP)
	var in_old: bool = mound.is_in_group(OLD_GROUP)
	_check("brush is in '%s'" % Pasture3DTerrainBrush.BRUSH_GROUP, in_real)
	_check("control: brush is NOT in '%s'" % OLD_GROUP, not in_old)
	mound.queue_free()
	print("")


func _test_editor_finds_brush_for_modifier() -> void:
	print("[B] Pasture3DGraphEditor._find_brush_for_modifier, nothing selected")
	var pair := _make_brush()
	var mound: Pasture3DMound = pair[0]
	var mod: Pasture3DNodeGraph = pair[1]
	_clear_selection()

	var ed := Pasture3DGraphEditor.new()
	add_child(ed)
	var found = ed._find_brush_for_modifier(mod)
	_check("found the host brush", found == mound, "got %s" % _name_of(found))
	_check("control: the old group finds nothing", _scan(OLD_GROUP, mod) == null)

	ed.queue_free()
	mound.queue_free()
	print("")


func _test_editor_finds_host_brush() -> void:
	print("[C] Pasture3DGraphEditor._find_host_brush via the graph, nothing selected")
	var pair := _make_brush()
	var mound: Pasture3DMound = pair[0]
	var mod: Pasture3DNodeGraph = pair[1]
	_clear_selection()

	var ed := Pasture3DGraphEditor.new()
	add_child(ed)
	# Bind the graph WITHOUT handing over the modifier or the brush: the group scan is the only route left,
	# which is the state the dock is in after the selection moves on.
	ed.graph = mod.graph
	ed.host_modifier = null
	ed.host_brush = null
	var found = ed._find_host_brush()
	_check("found the host brush from the graph alone", found == mound, "got %s" % _name_of(found))

	ed.queue_free()
	mound.queue_free()
	print("")


func _test_modifier_finds_its_own_host() -> void:
	print("[D] Pasture3DNodeGraph.bake_graph resolves its host brush")
	var pair := _make_brush()
	var mound: Pasture3DMound = pair[0]
	var mod: Pasture3DNodeGraph = pair[1]
	_clear_selection()
	# bake_graph() takes the group route when it is handed no host and nothing is selected. It must reach
	# the brush; if it does not it silently falls back to _touch() and the bake never happens.
	_check("brush is reachable from the modifier by group",
			_scan(Pasture3DTerrainBrush.BRUSH_GROUP, mod) == mound)
	_check("control: the old group cannot reach it", _scan(OLD_GROUP, mod) == null)
	mound.queue_free()
	print("")


## The same scan the fixed code does, run against an arbitrary group name so the control is exact.
func _scan(p_group: StringName, p_mod: Pasture3DNodeGraph) -> Node:
	for b in get_tree().get_nodes_in_group(p_group):
		if b is Pasture3DTerrainBrush and (b as Pasture3DTerrainBrush).modifiers.has(p_mod):
			return b
	return null


func _clear_selection() -> void:
	if Engine.is_editor_hint() and EditorInterface != null:
		EditorInterface.get_selection().clear()


func _name_of(p_node) -> String:
	return "null" if p_node == null else str(p_node.name)
