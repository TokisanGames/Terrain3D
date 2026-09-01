# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# BrushGraphRowGate — the two context-aware buttons at the top of a brush Inspector.
#
# Phase 1 of PASTURE3D_BRUSH_GRAPH_SHORTCUTS_SPEC.md. The row is a Pasture3DBrushGraphRow, which exists as
# its own class precisely so this gate can drive it: `EditorInspectorPlugin` can only be instantiated by
# the editor, so logic living inside one cannot be tested at all. Build a brush, make a row, read the
# labels, emit `pressed`, read them again.
#
# The criteria that matter are the ones about a stack that DISAGREES. A label reporting the first of three
# graph modifiers is wrong in a way you only notice after acting on it, so [C] pins Mixed, pins that Mixed
# resolves toward Frozen (the safe direction — thawing graphs you have not seen can start a solve per
# spline drag), and pins that a second press then reaches Live.
#
# [E] is the control: a brush with no modifier stack must be refused the row, and a brush that has one must
# not be. Without the second half, "refused" could just mean the check always says no.

extends Node

# Preloaded rather than referenced by class_name: a newly added class_name only enters the project's
# global class cache after an editor filesystem scan, and this gate must run on a clean checkout.
const BrushGraphRow = preload("res://addons/pasture_3d/src/brush_graph_row.gd")
const Pasture3DPlow = preload("res://addons/pasture_3d/connectors/pasture3d_plow.gd")

var _fail := 0


func _ready() -> void:
	print("=== BrushGraphRowGate: Add/Open Graph + Frozen/Live/Mixed/None ===\n")
	if not _preflight():
		print("\n=== BRUSH GRAPH ROW FAIL (harness could not build a row) ===\n")
		get_tree().quit(1)
		return
	_test_empty_stack()
	_test_add_graph()
	_test_mixed_stack()
	_test_all_live()
	_test_unsupported_brush_is_the_control()
	print("\n=== %s (%d failures) ===\n" % [
		"BRUSH GRAPH ROW PASS" if _fail == 0 else "BRUSH GRAPH ROW FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


## A gate that cannot build its subject must FAIL, not print PASS over a wall of script errors. The first
## draft of this file did exactly that — every criterion errored on a null plugin and it still reported
## "0 failures", because a runtime error increments no counter. So check the subject exists first.
func _preflight() -> bool:
	var brush := Pasture3DMound.new()
	add_child(brush)
	var row = BrushGraphRow.new().setup(brush)
	var ok: bool = row != null and row.get_child_count() == 2 \
			and row.graph_button() is Button and row.evaluation_button() is Button
	print("    %s harness can build a row with two buttons\n" % ("PASS" if ok else "FAIL"))
	if row != null:
		row.queue_free()
	brush.queue_free()
	return ok


func _check(p_label: String, p_ok: bool, p_detail: String = "") -> void:
	if not p_ok:
		_fail += 1
	print("    %s %s%s" % ["PASS" if p_ok else "FAIL", p_label,
			("  (%s)" % p_detail) if p_detail != "" else ""])


func _mound() -> Pasture3DMound:
	var m := Pasture3DMound.new()
	add_child(m)
	return m


func _graph_mod(p_evaluation: int) -> Pasture3DNodeGraph:
	var mod := Pasture3DNodeGraph.new()
	mod.graph = Pasture3DTerrainGraph.create_default()
	mod.evaluation = p_evaluation
	return mod


## [graph button, evaluation button, the row itself so the caller can free it]
func _row(p_brush: Pasture3DTerrainBrush) -> Array:
	var row = BrushGraphRow.new().setup(p_brush)
	add_child(row)
	return [row.graph_button(), row.evaluation_button(), row]


func _test_empty_stack() -> void:
	print("[A] No graph modifiers")
	var brush := _mound()
	var r := _row(brush)
	_check("graph button reads 'Add Graph'", r[0].text == "Add Graph", r[0].text)
	_check("evaluation reads 'None'", r[1].text == "None", r[1].text)
	_check("evaluation is disabled", r[1].disabled)
	r[2].queue_free()
	brush.queue_free()
	print("")


func _test_add_graph() -> void:
	print("[B] Pressing Add Graph")
	var brush := _mound()
	var r := _row(brush)
	var row = r[2]
	r[0].emit_signal(&"pressed")

	var mods: Array = row.graph_mods()
	_check("a graph modifier was appended", mods.size() == 1, "got %d" % mods.size())
	_check("it carries a graph", mods.size() == 1 and mods[0].graph != null)
	if mods.size() == 1 and mods[0].graph != null:
		var g: Pasture3DTerrainGraph = mods[0].graph
		var is_input_to_output: bool = g.nodes.size() == 2 and g.nodes[0].op() == &"input" \
				and g.nodes[1].op() == &"output" and g.connections.size() == 1
		_check("graph is an Input -> Output default filter", is_input_to_output)
	_check("graph button now reads 'Open Graph'", r[0].text == "Open Graph", r[0].text)
	# A new graph modifier defaults to FROZEN (Pasture3DNodeGraph._init), so the row must start saying so
	# rather than keep reading None.
	_check("evaluation now reads 'Frozen'", r[1].text == "Frozen", r[1].text)
	_check("evaluation is enabled", not r[1].disabled)

	# Pressing again must OPEN the existing one, not append a second.
	r[0].emit_signal(&"pressed")
	_check("pressing again does not append another", row.graph_mods().size() == 1,
			"got %d" % row.graph_mods().size())
	r[2].queue_free()
	brush.queue_free()

	# Plow brush: Add Graph must create a Mountain Cone -> Output generator graph
	var plow := Pasture3DPlow.new()
	add_child(plow)
	var r_plow := _row(plow)
	r_plow[0].emit_signal(&"pressed")
	var plow_mods: Array = r_plow[2].graph_mods()
	_check("plow: a graph modifier was appended", plow_mods.size() == 1, "got %d" % plow_mods.size())
	if plow_mods.size() == 1 and plow_mods[0].graph != null:
		var pg: Pasture3DTerrainGraph = plow_mods[0].graph
		var is_cone_to_output: bool = pg.nodes.size() == 2 and pg.nodes[0].op() == &"mountain_cone" \
				and pg.nodes[1].op() == &"output" and pg.connections.size() == 1
		_check("plow: graph is a Mountain Cone -> Output generator", is_cone_to_output)
	r_plow[2].queue_free()
	plow.queue_free()
	print("")


func _test_mixed_stack() -> void:
	print("[C] A stack that disagrees reads Mixed, and converges to Frozen")
	var brush := _mound()
	brush.modifiers = [
		_graph_mod(Pasture3DNode.Evaluation.FROZEN),
		_graph_mod(Pasture3DNode.Evaluation.LIVE),
		_graph_mod(Pasture3DNode.Evaluation.LIVE),
	]
	var r := _row(brush)
	_check("reads 'Mixed', not the first modifier's 'Frozen'", r[1].text == "Mixed", r[1].text)

	r[1].emit_signal(&"pressed")
	_check("first press froze ALL three", _all_are(brush, Pasture3DNode.Evaluation.FROZEN))
	_check("label now reads 'Frozen'", r[1].text == "Frozen", r[1].text)

	r[1].emit_signal(&"pressed")
	_check("second press thawed all three", _all_are(brush, Pasture3DNode.Evaluation.LIVE))
	_check("label now reads 'Live'", r[1].text == "Live", r[1].text)
	r[2].queue_free()
	brush.queue_free()
	print("")


func _test_all_live() -> void:
	print("[D] An all-Live stack reads Live and freezes")
	var brush := _mound()
	brush.modifiers = [
		_graph_mod(Pasture3DNode.Evaluation.LIVE),
		_graph_mod(Pasture3DNode.Evaluation.LIVE),
	]
	var r := _row(brush)
	_check("reads 'Live'", r[1].text == "Live", r[1].text)
	r[1].emit_signal(&"pressed")
	_check("press froze both", _all_are(brush, Pasture3DNode.Evaluation.FROZEN))
	r[2].queue_free()
	brush.queue_free()
	print("")


func _test_unsupported_brush_is_the_control() -> void:
	print("[E] CONTROL: only a brush that runs a stack may get the row")
	# _parse_begin returns before add_custom_control when _supports_modifiers() is false. The
	# EditorInspector cannot be driven headless, so this pins the guard that early return reads.
	var ridge := Pasture3DRidge.new()
	add_child(ridge)
	_check("control: Pasture3DRidge reports false", not ridge._supports_modifiers())
	ridge.queue_free()

	var mound := _mound()
	_check("Pasture3DMound reports true", mound._supports_modifiers())
	mound.queue_free()
	print("")


func _all_are(p_brush: Pasture3DTerrainBrush, p_evaluation: int) -> bool:
	for m in p_brush.modifiers:
		if m is Pasture3DNodeGraph and (m as Pasture3DNodeGraph).evaluation != p_evaluation:
			return false
	return true
