# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# BrushDetailsButtonGate — the Terrain Graph dock's "Brush Details" button appears exactly when there is a
# brush to show.
#
# Phase 2 of PASTURE3D_BRUSH_GRAPH_SHORTCUTS_SPEC.md. What the press DOES is two EditorInterface calls that
# cannot run outside the editor, so this gate pins the half that can go wrong silently: the visibility
# rule, and the host lookup it is built on. A graph opened as a standalone .tres has no brush, and a button
# reading "Brush Details" that can never do anything is worse than no button.
#
# This is also the feature that most needs Phase 0's group fallback, because it is pressed while you are in
# the graph — exactly when the brush is NOT the current selection. So [B] binds the graph WITHOUT handing
# over the modifier or the brush, which is the state the dock is really in.
#
# [C] is the control: the same editor, bound to a graph no brush owns, must hide the button. Without it,
# "visible" could just mean the button is always visible.

extends Node

var _fail := 0


func _ready() -> void:
	print("=== BrushDetailsButtonGate: the button appears only with a host brush ===\n")
	if not _preflight():
		print("\n=== BRUSH DETAILS FAIL (harness could not build the dock) ===\n")
		get_tree().quit(1)
		return
	_test_hidden_before_any_graph()
	_test_visible_with_host_brush()
	_test_hidden_for_standalone_graph()
	print("\n=== %s (%d failures) ===\n" % [
		"BRUSH DETAILS PASS" if _fail == 0 else "BRUSH DETAILS FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


## A gate that cannot build its subject must FAIL rather than print PASS over a wall of errors.
func _preflight() -> bool:
	var ed := _editor()
	var ok: bool = ed._brush_details_button is Button
	print("    %s harness can build the dock toolbar\n" % ("PASS" if ok else "FAIL"))
	ed.queue_free()
	return ok


func _check(p_label: String, p_ok: bool, p_detail: String = "") -> void:
	if not p_ok:
		_fail += 1
	print("    %s %s%s" % ["PASS" if p_ok else "FAIL", p_label,
			("  (%s)" % p_detail) if p_detail != "" else ""])


## The dock, with its toolbar built but no EditorPlugin — `initialize()` needs one, `_build_ui()` does not.
func _editor() -> Pasture3DGraphEditor:
	var ed := Pasture3DGraphEditor.new()
	add_child(ed)
	ed._build_ui()
	return ed


func _brush_with_graph() -> Array:
	var mound := Pasture3DMound.new()
	var mod := Pasture3DNodeGraph.new()
	mod.graph = Pasture3DTerrainGraph.create_default()
	mound.modifiers = [mod]
	add_child(mound)
	return [mound, mod]


func _test_hidden_before_any_graph() -> void:
	print("[A] No graph bound at all")
	var ed := _editor()
	ed._rebuild()
	_check("button is hidden", not ed._brush_details_button.visible)
	ed.queue_free()
	print("")


func _test_visible_with_host_brush() -> void:
	print("[B] A graph whose brush must be found by group, not by selection")
	var pair := _brush_with_graph()
	var mound: Pasture3DMound = pair[0]
	var mod: Pasture3DNodeGraph = pair[1]

	var ed := _editor()
	# Bind the graph WITHOUT the modifier or the brush: the group scan is the only route left, which is the
	# state the dock is in once the selection moves on. Before Phase 0 this returned null.
	ed.graph = mod.graph
	ed.host_modifier = null
	ed.host_brush = null
	_check("_find_host_brush() reaches the brush", ed._find_host_brush() == mound)
	ed._rebuild()
	_check("button is visible", ed._brush_details_button.visible)

	ed.queue_free()
	mound.queue_free()
	print("")


func _test_hidden_for_standalone_graph() -> void:
	print("[C] CONTROL: a standalone graph no brush owns")
	var ed := _editor()
	ed.graph = Pasture3DTerrainGraph.create_default()
	ed.host_modifier = null
	ed.host_brush = null
	_check("control: _find_host_brush() finds nothing", ed._find_host_brush() == null)
	ed._rebuild()
	_check("control: button is hidden", not ed._brush_details_button.visible)
	ed.queue_free()
	print("")
