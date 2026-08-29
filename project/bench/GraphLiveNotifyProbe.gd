# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphLiveNotifyProbe — does editing a graph node reach the host brush when the modifier is LIVE?
#
# The user reports a LIVE graph modifier no longer repaints until Bake is pressed. That can break in two
# very different places, and they need different fixes:
#
#   DATA LAYER    node.changed -> graph._on_node_changed -> graph.emit_changed -> mod._on_graph_changed
#                 -> mod._touch -> brush._on_modifier_changed.  Testable headless. This probe.
#   EDITOR ONLY   _on_modifier_changed -> _arm_refresh_timer -> bake.  Gated on Engine.is_editor_hint(),
#                 so a headless run cannot see it and a PASS here means the fault is downstream.
#
# Every criterion is paired with a control, because the failure mode being hunted is a notification that is
# SWALLOWED — and a probe that only ever asserts "the signal arrived" cannot tell a working chain from one
# where every edit emits regardless of whether it should.

extends Node

const BrushGraphRow = preload("res://addons/pasture_3d/src/brush_graph_row.gd")

var _fail := 0
var _hits := 0


func _ready() -> void:
	print("=== GraphLiveNotifyProbe: a LIVE graph edit reaching the brush ===\n")
	_test_chain()
	_test_affects_output_filter()
	_test_rename_guard()
	_test_added_modifier_is_bound()
	print("\n=== %s (%d failures) ===\n" % [
		"LIVE NOTIFY PASS" if _fail == 0 else "LIVE NOTIFY FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_label: String, p_ok: bool, p_detail: String = "") -> void:
	if not p_ok:
		_fail += 1
	print("    %s %s%s" % ["PASS" if p_ok else "FAIL", p_label,
			("  (%s)" % p_detail) if p_detail != "" else ""])


func _on_brush_changed() -> void:
	_hits += 1


## A Mound carrying one LIVE graph modifier, already listening on the brush's own `changed`.
func _rig() -> Array:
	var mound := Pasture3DMound.new()
	var mod := Pasture3DNodeGraph.new()
	var g := Pasture3DTerrainGraph.create_default()
	mod.graph = g
	mod.evaluation = Pasture3DNode.Evaluation.LIVE
	mound.modifiers = [mod]
	add_child(mound)
	# The brush's own `changed` is not what repaints it — `_on_modifier_changed` is — so watch that
	# handler's INPUT: the modifier's signal. Counting the modifier's emissions is what says whether the
	# graph edit got through at all.
	mod.changed.connect(_on_brush_changed)
	return [mound, mod, g]


func _first_param_node(p_graph: Pasture3DTerrainGraph) -> Pasture3DGraphNode:
	for n in p_graph.nodes:
		if n != null and n.op() != &"output":
			return n
	return null


func _test_chain() -> void:
	print("[A] node param -> graph -> modifier")
	var rig := _rig()
	var mound: Pasture3DMound = rig[0]
	var mod: Pasture3DNodeGraph = rig[1]
	var g: Pasture3DTerrainGraph = rig[2]

	var node := _first_param_node(g)
	_check("the default graph has a parameter node to poke", node != null,
			"ops: %s" % [_ops(g)])
	if node == null:
		mound.queue_free()
		print("")
		return

	_hits = 0
	var before := g.content_key()
	node.emit_changed()
	_check("the modifier was notified", _hits > 0, "%d emissions" % _hits)
	_check("and the graph's content key moved", g.content_key() != before,
			"%d -> %d" % [before, g.content_key()])

	# Control: a modifier whose graph is NOT this one must not hear it. Without this, "the signal arrived"
	# could just mean every modifier fires on every edit anywhere.
	_hits = 0
	var stranger := Pasture3DTerrainGraph.create_default()
	mod.graph = stranger
	_hits = 0
	node.emit_changed()
	_check("control: after rebinding, the old graph no longer notifies", _hits == 0,
			"%d emissions" % _hits)

	mound.queue_free()
	print("")


func _test_affects_output_filter() -> void:
	print("[B] The downstream filter in Pasture3DTerrainGraph._on_node_changed")
	var g := Pasture3DTerrainGraph.create_default()
	var seen := [0]
	g.changed.connect(func(): seen[0] += 1)

	var out_idx := g.output_index()
	_check("the default graph resolves an output", out_idx >= 0, "output_index %d" % out_idx)

	var node := _first_param_node(g)
	if node == null or out_idx < 0:
		print("")
		return
	var n_idx := g.nodes.find(node)
	var down := g.get_downstream_nodes(n_idx)
	_check("the poked node reaches the output", down.has(out_idx),
			"node %d downstream %s, output %d" % [n_idx, str(down), out_idx])

	seen[0] = 0
	node.emit_changed()
	_check("so its edit emits `changed`", seen[0] > 0, "%d emissions" % seen[0])

	# Control: a node wired to NOTHING must be filtered out, or the filter is not doing its job and this
	# test proves nothing about the connected case.
	var orphan := node.duplicate()
	var list := g.nodes.duplicate()
	list.append(orphan)
	g.nodes = list
	seen[0] = 0
	orphan.emit_changed()
	_check("control: an unwired node's edit is filtered out", seen[0] == 0, "%d emissions" % seen[0])
	print("")


func _test_rename_guard() -> void:
	print("[C] The rename guard in Pasture3DTerrainBrush._on_modifier_changed")
	# `_on_modifier_changed` returns EARLY when the stack's names differ from its cache — that is the
	# rename path. If the cache is out of step for any other reason, the first real edit after it is
	# swallowed, which is exactly the reported symptom. Poke twice and check BOTH get through.
	var rig := _rig()
	var mound: Pasture3DMound = rig[0]
	var g: Pasture3DTerrainGraph = rig[2]
	var node := _first_param_node(g)
	if node == null:
		mound.queue_free()
		print("")
		return

	var names_before := mound._stack_names()
	mound._on_modifier_changed()
	var swallowed := mound._stack_names_cache != names_before
	_check("the name cache is in step after one notification", not swallowed,
			"cache %s vs %s" % [str(mound._stack_names_cache), str(names_before)])
	mound.queue_free()
	print("")


## THE BUG THIS FILE WAS WRITTEN FOR. `modifiers` is an Array — a reference — so `modifiers.append(m)`
## mutates the stack without running the setter, and the setter is the only thing that connects the new
## modifier's `changed` to the brush. A brush that got its graph that way hears nothing for the rest of the
## session: no debounced re-bake, and the terrain moves only when Bake calls the rasteriser directly.
##
## The control is the append itself. Without it, "the modifier notifies the brush" would pass on a brush
## that was already listening for some unrelated reason, and would never have caught this.
func _test_added_modifier_is_bound() -> void:
	print("[D] A modifier added at runtime is bound to its brush")

	var mound := Pasture3DMound.new()
	add_child(mound)
	var mod = BrushGraphRow.ensure_graph_modifier(mound)
	_check("ensure_graph_modifier returned one", mod != null)
	if mod == null:
		mound.queue_free()
		print("")
		return
	_check("it is in the stack", mound.modifiers.has(mod))
	_check("and the brush is listening to it — the whole live path",
			mod.changed.get_connections().size() > 0,
			"%d connections" % mod.changed.get_connections().size())

	# Control: the direct append, which is what the two call sites used to do.
	var deaf := Pasture3DMound.new()
	add_child(deaf)
	var stray := Pasture3DNodeGraph.new()
	stray.graph = Pasture3DTerrainGraph.create_default()
	deaf.modifiers.append(stray)
	_check("control: a directly appended modifier is NOT bound",
			stray.changed.get_connections().is_empty(),
			"%d connections" % stray.changed.get_connections().size())

	mound.queue_free()
	deaf.queue_free()
	print("")


func _ops(p_graph: Pasture3DTerrainGraph) -> Array:
	var out := []
	for n in p_graph.nodes:
		out.append(String(n.op()) if n != null else "<null>")
	return out
