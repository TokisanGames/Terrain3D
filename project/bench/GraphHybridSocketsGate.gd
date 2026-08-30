# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphHybridSocketsGate — headless verification gate for Phase 2: In-line Hybrid Parameter Sockets & Smart Socket Collapse.
#
# Asserts on:
#   [A] Parameter socket defaults & property fallbacks
#   [B] Parameter socket wire modulation (Noise amplitude, Terrace band_height, Remap range)
#   [C] Smart socket collapse in GraphEditor slot row population
#   [D] Single-call native C++ SSA program lowering with parameter sockets
extends Node

const GraphEditorScript = preload("res://addons/pasture_3d/src/graph_editor.gd")

var _fail := 0


func _ready() -> void:
	print("=== GraphHybridSocketsGate: In-line Hybrid Parameter Sockets & Smart Collapse ===\n")
	_a_parameter_socket_defaults()
	_b_parameter_socket_modulation()
	_c_editor_smart_collapse()
	_d_native_ssa_lowering()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH HYBRID SOCKETS PASS" if _fail == 0 else "GRAPH HYBRID SOCKETS FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _a_parameter_socket_defaults() -> void:
	print("[A] Parameter socket defaults & property fallbacks")
	# Noise node
	var nz_node: Pasture3DGraphNodeNoise = Pasture3DGraphNodeRegistry.create(&"noise")
	_assert(nz_node != null, "Noise node created")
	_assert(nz_node.input_count() == 1, "Noise has 1 input port (amplitude)")
	_assert(nz_node.input_names()[0] == "amplitude", "Noise input port is named 'amplitude'")
	_assert(nz_node.input_port_types()[0] == Pasture3DGraphNode.PortType.FLOAT, "Noise amplitude is PortType.FLOAT")
	nz_node.amplitude = 75.0
	_assert(nz_node.input_unwired_default(0) == 75.0, "Unwired amplitude default returns 75.0")

	# Terrace node
	var terr_node: Pasture3DGraphNodeTerrace = Pasture3DGraphNodeRegistry.create(&"terrace")
	_assert(terr_node != null, "Terrace node created")
	_assert(terr_node.input_count() == 4, "Terrace has 4 input ports (in, band_height, hardness, amount)")
	terr_node.band_height = 25.0
	terr_node.hardness = 0.9
	terr_node.amount = 0.5
	_assert(terr_node.input_unwired_default(1) == 25.0, "Unwired band_height default returns 25.0")
	_assert(terr_node.input_unwired_default(2) == 0.9, "Unwired hardness default returns 0.9")
	_assert(terr_node.input_unwired_default(3) == 0.5, "Unwired amount default returns 0.5")

	# Remap node
	var remap_node: Pasture3DGraphNodeRemap = Pasture3DGraphNodeRegistry.create(&"remap")
	_assert(remap_node != null, "Remap node created")
	_assert(remap_node.input_count() == 5, "Remap has 5 input ports (in, in_min, in_max, out_min, out_max)")
	remap_node.in_min = 10.0
	remap_node.in_max = 50.0
	_assert(remap_node.input_unwired_default(1) == 10.0, "Unwired in_min returns 10.0")
	_assert(remap_node.input_unwired_default(2) == 50.0, "Unwired in_max returns 50.0")


func _b_parameter_socket_modulation() -> void:
	print("[B] Parameter socket wire modulation")
	var g := Pasture3DTerrainGraph.new()

	# Noise node whose amplitude is driven by a ConstFloat node
	var const_amp: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
	const_amp.set("value", 50.0)

	var nz: Pasture3DGraphNodeNoise = Pasture3DGraphNodeRegistry.create(&"noise")
	var fn := FastNoiseLite.new()
	fn.seed = 1337
	fn.frequency = 0.05
	nz.noise = fn
	nz.amplitude = 1.0 # Will be modulated by const_amp (50.0)

	var out_node: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"output")

	var i_const := g.add_node(const_amp)
	var i_nz := g.add_node(nz)
	var i_out := g.add_node(out_node)

	# Wire const -> noise.amplitude (port 0), noise -> output (port 0)
	g.connect_ports(i_const, 0, i_nz, 0)
	g.connect_ports(i_nz, 0, i_out, 0)

	var res := g.evaluate(8, 8, Rect2(0, 0, 100, 100))
	_assert(res.size() == 64, "Evaluated modulated noise grid (64 cells)")
	
	# Cell 0 amplitude verification. Cell 0 is NOT world (0, 0): the evaluator samples at the cell
	# CENTRE, with dx = rect.size.x / gw, so an 8-wide grid over a 100 m rect puts cell 0 at 6.25 m.
	# Sampling the oracle at the rect's corner instead compared two different points and reported it
	# as an amplitude failure.
	var dx := 100.0 / 8.0
	var wx := 0.0 + 0.5 * dx
	var raw_sample := fn.get_noise_2d(wx, wx)
	var expected := 50.0 * raw_sample
	_assert(is_equal_approx(res[0], expected), "Cell 0 equals modulated 50.0 * noise (%f vs %f)" % [res[0], expected])


func _c_editor_smart_collapse() -> void:
	print("[C] Smart socket collapse in GraphEditor slot row population")
	var g := Pasture3DTerrainGraph.new()
	var const_node: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
	var nz_node: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"noise")
	var out_node: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"output")

	var i0 := g.add_node(const_node)
	var i1 := g.add_node(nz_node)
	var i2 := g.add_node(out_node)

	# Wire const -> noise.amplitude
	g.connect_ports(i0, 0, i1, 0)
	g.connect_ports(i1, 0, i2, 0)

	var editor: Pasture3DGraphEditor = GraphEditorScript.new()
	add_child(editor)
	# The panel builds its GraphEdit in initialize(); with no plugin it just skips docking itself.
	# Without this `_graphedit` stays null and the section walked a null node.
	editor.initialize(null)
	# `load_graph` was renamed `edit_graph`; the old call threw, which aborted section C without
	# counting a failure — the gate looked one short rather than broken.
	editor.edit_graph(g)

	# Locate the GraphNode for nz_node ("n1")
	var gn_noise: GraphNode = null
	for child in editor._graphedit.get_children():
		if child is GraphNode and child.name == "n1":
			gn_noise = child
			break

	_assert(gn_noise != null, "GraphEditor instanced GraphNode for noise")
	if gn_noise != null:
		# Row 0 is the wired amplitude slot row. Since it's wired, the inline SpinBox was collapsed
		var row0 = gn_noise.get_child(0)
		_assert(row0 is HBoxContainer, "Slot row 0 is HBoxContainer")
		# In wired state, it only contains the label, no SpinBox child
		var has_spinbox := false
		for c in row0.get_children():
			if c is SpinBox:
				has_spinbox = true
		_assert(not has_spinbox, "Inline SpinBox collapsed on wired socket row")

	editor.queue_free()


func _d_native_ssa_lowering() -> void:
	print("[D] Single-call native C++ SSA program lowering")
	var g := Pasture3DTerrainGraph.new()
	var const_node: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
	const_node.set("value", 20.0)
	var nz_node: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"noise")
	var out_node: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"output")

	var i0 := g.add_node(const_node)
	var i1 := g.add_node(nz_node)
	var i2 := g.add_node(out_node)

	g.connect_ports(i0, 0, i1, 0)
	g.connect_ports(i1, 0, i2, 0)

	var prog := g.compile_graph_program()
	_assert(not prog.is_empty(), "compile_graph_program lowers successfully for graph with parameter sockets")


func _assert(p_cond: bool, p_msg: String) -> void:
	if p_cond:
		print("  PASS: %s" % p_msg)
	else:
		_fail += 1
		printerr("  FAIL: %s" % p_msg)
