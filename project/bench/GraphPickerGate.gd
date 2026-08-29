# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphPickerGate — the Terrain Graph dock's graph dropdown.
#
# Phase 3 of PASTURE3D_BRUSH_GRAPH_SHORTCUTS_SPEC.md. This is the only one of the four controls that has to
# reason about a list which changes underneath it, so the criteria are mostly about the cases that are NOT
# the happy path: no graph, no host brush, a graph the stack does not contain, and a stack whose modifiers
# have no labels.
#
# Two things are pinned harder than the rest because getting them wrong is silent:
#
#   * item METADATA is the modifier's stack index, not the object. Selecting re-resolves against the live
#     stack, so a modifier deleted after the menu was built cannot be opened from a stale reference. [E]
#     rebuilds after a deletion and checks the picker followed.
#   * the not-in-stack case shows the GRAPH's own name and selects it. Showing some other graph's name
#     while editing this one is the failure that would never be noticed. [D] covers it.
#
# [C] is the control for the naming rule: an unlabelled modifier must fall back to "Terrain Graph <i>", and
# a labelled one must NOT — otherwise "the label is used" could just mean every item gets the same text.

extends Node

var _fail := 0


func _ready() -> void:
	print("=== GraphPickerGate: the dock's graph dropdown ===\n")
	if not _preflight():
		print("\n=== GRAPH PICKER FAIL (harness could not build the dock) ===\n")
		get_tree().quit(1)
		return
	_test_no_graph()
	_test_standalone_graph()
	_test_stack_naming()
	_test_graph_not_in_stack()
	_test_index_metadata_survives_deletion()
	_test_selecting_switches_graph()
	print("\n=== %s (%d failures) ===\n" % [
		"GRAPH PICKER PASS" if _fail == 0 else "GRAPH PICKER FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _preflight() -> bool:
	var ed := _editor()
	var ok: bool = ed._graph_picker is OptionButton
	print("    %s harness can build the dock toolbar\n" % ("PASS" if ok else "FAIL"))
	ed.queue_free()
	return ok


func _check(p_label: String, p_ok: bool, p_detail: String = "") -> void:
	if not p_ok:
		_fail += 1
	print("    %s %s%s" % ["PASS" if p_ok else "FAIL", p_label,
			("  (%s)" % p_detail) if p_detail != "" else ""])


func _editor() -> Pasture3DGraphEditor:
	var ed := Pasture3DGraphEditor.new()
	add_child(ed)
	ed._build_ui()
	return ed


func _mod(p_label: String) -> Pasture3DNodeGraph:
	var m := Pasture3DNodeGraph.new()
	m.graph = Pasture3DTerrainGraph.create_default()
	if p_label != "":
		m.resource_name = p_label
	return m


func _items(p_ed: Pasture3DGraphEditor) -> PackedStringArray:
	var out := PackedStringArray()
	for i in range(p_ed._graph_picker.item_count):
		out.append(p_ed._graph_picker.get_item_text(i))
	return out


func _test_no_graph() -> void:
	print("[A] Nothing bound")
	var ed := _editor()
	ed._rebuild()
	_check("reads '(no graph)'", _items(ed) == PackedStringArray(["(no graph)"]), str(_items(ed)))
	_check("is disabled", ed._graph_picker.disabled)
	ed.queue_free()
	print("")


func _test_standalone_graph() -> void:
	print("[B] A graph with no host brush")
	var ed := _editor()
	ed.graph = Pasture3DTerrainGraph.create_default()
	ed._rebuild()
	_check("exactly one item", ed._graph_picker.item_count == 1, str(_items(ed)))
	_check("is disabled — there is no stack to pick from", ed._graph_picker.disabled)
	ed.queue_free()
	print("")


func _test_stack_naming() -> void:
	print("[C] Item names: the modifier's label, else 'Terrain Graph <stack index>'")
	var mound := Pasture3DMound.new()
	var labelled := _mod("NoiseAndErosion")
	var bare := _mod("")
	# A non-graph modifier FIRST, so the fallback index must be the stack index and not a count of graphs.
	mound.modifiers = [Pasture3DNodeNoise.new(), labelled, bare]
	add_child(mound)

	var ed := _editor()
	ed.graph = labelled.graph
	ed._rebuild()
	var items := _items(ed)
	_check("two items, the noise modifier skipped", items.size() == 2, str(items))
	_check("the labelled one uses its label", items.size() == 2 and items[0] == "NoiseAndErosion", str(items))
	_check("control: the bare one falls back to its STACK index, not 1",
			items.size() == 2 and items[1] == "Terrain Graph 2", str(items))
	_check("the edited graph is selected", ed._graph_picker.selected == 0)
	_check("is enabled", not ed._graph_picker.disabled)

	ed.queue_free()
	mound.queue_free()
	print("")


func _test_graph_not_in_stack() -> void:
	print("[D] Editing a graph the host brush does not own")
	var mound := Pasture3DMound.new()
	var owned := _mod("Owned")
	mound.modifiers = [owned]
	add_child(mound)
	# Bind a graph that is NOT in the stack, while the brush is still discoverable.
	var stranger := Pasture3DTerrainGraph.create_default()

	var ed := _editor()
	ed.graph = stranger
	ed.host_brush = mound
	ed._rebuild()
	var items := _items(ed)
	_check("the stack's graph is still listed", items.has("Owned"), str(items))
	_check("the stranger is appended", items.size() == 2, str(items))
	_check("and the stranger is what is selected, not 'Owned'",
			ed._graph_picker.selected == items.size() - 1, "selected %d" % ed._graph_picker.selected)
	_check("selecting the stranger's own entry is a no-op (metadata -1)",
			int(ed._graph_picker.get_item_metadata(items.size() - 1)) == -1)

	ed.queue_free()
	mound.queue_free()
	print("")


func _test_index_metadata_survives_deletion() -> void:
	print("[E] Metadata is a stack index, re-resolved against the live stack")
	var mound := Pasture3DMound.new()
	var a := _mod("A")
	var b := _mod("B")
	mound.modifiers = [a, b]
	add_child(mound)

	var ed := _editor()
	ed.graph = b.graph
	ed.host_brush = mound
	ed._rebuild()
	_check("B is at stack index 1", int(ed._graph_picker.get_item_metadata(1)) == 1)

	# Delete A. B is now index 0, and a picker holding object references would still be right while one
	# holding stale indices must be REBUILT — which is what _rebuild does.
	mound.modifiers = [b]
	ed._rebuild()
	var items := _items(ed)
	_check("one item left", items.size() == 1, str(items))
	_check("B moved to stack index 0", items.size() == 1 and int(ed._graph_picker.get_item_metadata(0)) == 0)
	_check("and it is still the selection", ed._graph_picker.selected == 0)

	ed.queue_free()
	mound.queue_free()
	print("")


func _test_selecting_switches_graph() -> void:
	print("[F] Picking an item binds that graph")
	var mound := Pasture3DMound.new()
	var a := _mod("A")
	var b := _mod("B")
	mound.modifiers = [a, b]
	add_child(mound)

	var ed := _editor()
	ed.graph = a.graph
	ed.host_brush = mound
	ed._rebuild()
	_check("starts on A", ed.graph == a.graph)

	ed._on_graph_picked(1)
	_check("picking item 1 binds B's graph", ed.graph == b.graph)
	_check("and records B as the host modifier", ed.host_modifier == b)

	ed.queue_free()
	mound.queue_free()
	print("")
