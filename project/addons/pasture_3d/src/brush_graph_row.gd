# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DBrushGraphRow — the row of two context-aware buttons at the top of a brush Inspector:
#
#   [ Add Graph | Open Graph ]   [ None | Frozen | Live | Mixed ]
#
# It lives in its own class, apart from Pasture3DGraphInspectorPlugin, for a reason that is not tidiness:
# `EditorInspectorPlugin` can only be instantiated by the editor, so anything built inside one cannot be
# driven by a headless gate. What the row SAYS about a modifier stack, and what pressing it DOES to that
# stack, is ordinary logic with real edge cases (a stack that disagrees with itself, most of all) and is
# worth testing. So the row is a plain HBoxContainer that anyone can construct, and the one thing it cannot
# do without the editor — reveal the bottom panel — is injected as a Callable.
#
# See PASTURE3D_BRUSH_GRAPH_SHORTCUTS_SPEC.md Phase 1, and bench/BrushGraphRowGate.tscn.

@tool
class_name Pasture3DBrushGraphRow
extends HBoxContainer

var brush: Pasture3DTerrainBrush

## Called as open_graph.call(graph, modifier, brush) when a press should reveal the graph. Left unset the
## row still edits the stack correctly and simply opens nothing, which is what a gate wants.
var open_graph: Callable = Callable()

var _graph_btn: Button
var _eval_btn: Button


## Construct with `.new()` then `setup()`, rather than a static `create()` factory. A static factory would
## have to name its own class to instantiate it, and a `class_name` only resolves once it has entered the
## project's global class cache — which happens on an editor filesystem scan and NOT in a headless run. A
## factory that cannot be called before an editor has opened the project is a factory the gate cannot use.
func setup(p_brush: Pasture3DTerrainBrush, p_open_graph: Callable = Callable()) -> Pasture3DBrushGraphRow:
	brush = p_brush
	open_graph = p_open_graph
	_build()
	return self


func _build() -> void:
	_graph_btn = Button.new()
	_graph_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_graph_btn.pressed.connect(_on_graph_pressed)
	add_child(_graph_btn)

	_eval_btn = Button.new()
	_eval_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_eval_btn.pressed.connect(_on_evaluation_pressed)
	add_child(_eval_btn)

	sync()


func graph_button() -> Button:
	return _graph_btn


func evaluation_button() -> Button:
	return _eval_btn


## Every graph modifier on the brush, in stack order. The ORDER matters: "Open Graph" opens the first, and
## the dock's dropdown (Phase 3) lists them in the order the Inspector shows them in.
func graph_mods() -> Array[Pasture3DNodeGraph]:
	var out: Array[Pasture3DNodeGraph] = []
	if brush == null:
		return out
	for m in brush.modifiers:
		if m is Pasture3DNodeGraph:
			out.append(m as Pasture3DNodeGraph)
	return out


## Repoint both labels at the stack as it is now. Called when the row is built and again after either
## button acts, so a press never leaves a label describing the state it just replaced. The Inspector
## rebuilds the row on selection change, so entering a brush is always correct; a stack edited from
## elsewhere while the same brush stays selected can still go stale (the spec's Phase 4).
func sync() -> void:
	var mods := graph_mods()
	var count := mods.size()

	if count == 0:
		_graph_btn.text = "Add Graph"
		_graph_btn.tooltip_text = "Add a Terrain Graph modifier to this brush and open it in the bottom panel"
		_eval_btn.disabled = true
		_eval_btn.text = "None"
		_eval_btn.tooltip_text = "This brush has no Terrain Graph modifiers to freeze or thaw"
		return

	_graph_btn.text = "Open Graph"
	_graph_btn.tooltip_text = "Open %s in the Terrain Graph editor%s" % [
		_mod_display_name(mods[0]),
		"" if count == 1 else " (the first of %d graph modifiers)" % count,
	]

	_eval_btn.disabled = false
	var frozen := 0
	for m in mods:
		if m.evaluation == Pasture3DNode.Evaluation.FROZEN:
			frozen += 1

	var plural: String = "the graph modifier" if count == 1 else "all %d graph modifiers" % count
	if frozen == count:
		_eval_btn.text = "Frozen"
		_eval_btn.tooltip_text = ("Frozen: cached output, re-solved only on an explicit Bake.\nPress to "
				+ "set %s to Live, which re-solves on every spline drag — slow on a large graph.") % plural
	elif frozen == 0:
		_eval_btn.text = "Live"
		_eval_btn.tooltip_text = "Live: re-solves on every refresh.\nPress to set %s to Frozen." % plural
	else:
		# Reporting the stack by its first member would describe several graphs by one of them and hide
		# the rest. Mixed is the honest reading, and the only one that says "go look at the stack".
		_eval_btn.text = "Mixed"
		_eval_btn.tooltip_text = ("%d of %d graph modifiers are Frozen.\nPress to set all of them to "
				+ "Frozen — the safe direction, since thawing graphs you have not seen can start a solve "
				+ "per drag. Press again for Live.") % [frozen, count]


## The modifier's own label, else "Terrain Graph <i>" by its index in the stack — the same number the
## Inspector prints on the row, so the fallback names something the user can actually find. The graph's
## resource path is deliberately not used: for a scene sub-resource it reads
## "simple_pasture.tscn::Resource_6pcwc", which identifies nothing.
func _mod_display_name(p_mod: Pasture3DNodeGraph) -> String:
	if p_mod.resource_name != "":
		return p_mod.resource_name
	return "Terrain Graph %d" % brush.modifiers.find(p_mod)


func _on_graph_pressed() -> void:
	if brush == null:
		return
	var mods := graph_mods()
	var mod: Pasture3DNodeGraph = mods[0] if not mods.is_empty() else ensure_graph_modifier(brush)
	if mod == null:
		return
	if mod.graph == null:
		mod.graph = Pasture3DTerrainGraph.create_default()
	if open_graph.is_valid():
		open_graph.call(mod.graph, mod, brush)
	sync()


## Frozen/Live flips the WHOLE stack, and a stack that disagrees converges to Frozen first: freezing what
## is already frozen costs nothing, while thawing an unknown number of graphs can start a solve per drag on
## one the user has never opened. Each write emits `changed` and the brush coalesces the refreshes through
## its own debounce, so no batching belongs here.
func _on_evaluation_pressed() -> void:
	var mods := graph_mods()
	if mods.is_empty():
		return
	var frozen := 0
	for m in mods:
		if m.evaluation == Pasture3DNode.Evaluation.FROZEN:
			frozen += 1
	# All-Frozen is the only state that thaws. All-Live freezes, and so does Mixed.
	var target: int = Pasture3DNode.Evaluation.LIVE if frozen == mods.size() \
			else Pasture3DNode.Evaluation.FROZEN
	for m in mods:
		m.evaluation = target
	sync()


## Find the brush's first graph modifier, or build one carrying the default `mountain_cone` -> `output`
## graph and append it. The single definition of "a new graph modifier" — the row's Add Graph and the
## inspector plugin's Edit in Graph Editor both come through here.
static func ensure_graph_modifier(p_brush: Pasture3DTerrainBrush) -> Pasture3DNodeGraph:
	if p_brush == null:
		return null
	for m in p_brush.modifiers:
		if m is Pasture3DNodeGraph:
			var found := m as Pasture3DNodeGraph
			if found.graph == null:
				found.graph = Pasture3DTerrainGraph.create_default()
			return found

	var mod := Pasture3DNodeGraph.new()
	mod.resource_name = "Terrain Graph"
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
	p_brush.modifiers.append(mod)
	return mod
