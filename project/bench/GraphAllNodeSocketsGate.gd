# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphAllNodeSocketsGate — headless verification gate for Universal Node Parameter Sockets.
#
# Asserts on:
#   [A] Parameter sockets across all Pasture3D graph nodes (port counts > 1, typed ports)
#   [B] Unwired default evaluation backward-compatibility
#   [C] Dynamically driven parameter socket evaluation
#   [D] Single-call native C++ graph program lowering with new node sockets
extends Node

var _fail := 0


func _ready() -> void:
	print("=== GraphAllNodeSocketsGate: Universal Parameter Sockets ===\n")
	_a_parameter_socket_definitions()
	_b_unwired_defaults_and_eval()
	_c_driven_parameter_sockets()
	_d_native_lowering_all_nodes()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH ALL NODE SOCKETS PASS" if _fail == 0 else "GRAPH ALL NODE SOCKETS FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _a_parameter_socket_definitions() -> void:
	print("[A] Parameter socket counts and types on all nodes")
	var checks: Array[Dictionary] = [
		{"op": &"noise_swiss", "min_inputs": 5, "type0": Pasture3DGraphNode.PortType.FLOAT},
		{"op": &"noise_jordan", "min_inputs": 5, "type0": Pasture3DGraphNode.PortType.FLOAT},
		{"op": &"furrows", "min_inputs": 4, "type0": Pasture3DGraphNode.PortType.FLOAT},
		{"op": &"dunes", "min_inputs": 5, "type0": Pasture3DGraphNode.PortType.FLOAT},
		{"op": &"crater", "min_inputs": 4, "type0": Pasture3DGraphNode.PortType.FLOAT},
		{"op": &"geological_primitive", "min_inputs": 4, "type0": Pasture3DGraphNode.PortType.FLOAT},
		{"op": &"warp", "min_inputs": 4, "type0": Pasture3DGraphNode.PortType.HEIGHT},
		{"op": &"strata", "min_inputs": 6, "type0": Pasture3DGraphNode.PortType.HEIGHT},
		{"op": &"curve", "min_inputs": 6, "type0": Pasture3DGraphNode.PortType.HEIGHT},
		{"op": &"mask", "min_inputs": 6, "type0": Pasture3DGraphNode.PortType.HEIGHT},
		{"op": &"curvature", "min_inputs": 3, "type0": Pasture3DGraphNode.PortType.HEIGHT},
		{"op": &"talus_projection", "min_inputs": 5, "type0": Pasture3DGraphNode.PortType.HEIGHT},
		{"op": &"spectral_equalizer", "min_inputs": 5, "type0": Pasture3DGraphNode.PortType.HEIGHT},
		{"op": &"depression_filling", "min_inputs": 3, "type0": Pasture3DGraphNode.PortType.HEIGHT},
		{"op": &"erosion_hydraulic", "min_inputs": 5, "type0": Pasture3DGraphNode.PortType.HEIGHT},
		{"op": &"erosion_thermal", "min_inputs": 5, "type0": Pasture3DGraphNode.PortType.HEIGHT},
		{"op": &"erosion", "min_inputs": 4, "type0": Pasture3DGraphNode.PortType.HEIGHT},
		{"op": &"scree", "min_inputs": 4, "type0": Pasture3DGraphNode.PortType.HEIGHT},
		{"op": &"dla", "min_inputs": 4, "type0": Pasture3DGraphNode.PortType.HEIGHT},
		{"op": &"lake_flooding", "min_inputs": 4, "type0": Pasture3DGraphNode.PortType.HEIGHT},
		{"op": &"stream_extraction", "min_inputs": 4, "type0": Pasture3DGraphNode.PortType.HEIGHT},
	]

	for c in checks:
		var node: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(c["op"])
		_assert(node != null, "Node %s registered and created" % c["op"])
		if node != null:
			_assert(node.input_count() >= c["min_inputs"], "%s has %d inputs (expected >= %d)" % [c["op"], node.input_count(), c["min_inputs"]])
			var types := node.input_port_types()
			_assert(types.size() >= c["min_inputs"], "%s has %d port types" % [c["op"], types.size()])
			if types.size() > 0:
				_assert(types[0] == c["type0"], "%s port 0 is %d (expected %d)" % [c["op"], types[0], c["type0"]])


func _b_unwired_defaults_and_eval() -> void:
	print("[B] Unwired defaults and evaluation fallbacks")
	var g := Pasture3DTerrainGraph.new()
	var swiss: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"noise_swiss")
	swiss.set("amplitude", 55.0)
	swiss.set("frequency", 0.01)
	var out: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"output")

	var i_s := g.add_node(swiss)
	var i_o := g.add_node(out)
	g.connect_ports(i_s, 0, i_o, 0)

	var rect := Rect2(0, 0, 100, 100)
	var grid: PackedFloat32Array = g.evaluate(16, 16, rect)
	_assert(grid.size() == 256, "Unwired Swiss grid evaluated with size 256")
	var has_non_zero := false
	for v in grid:
		if absf(v) > 0.001:
			has_non_zero = true
			break
	_assert(has_non_zero, "Unwired Swiss noise produced nonzero amplitude surface")


func _c_driven_parameter_sockets() -> void:
	print("[C] Dynamically driven parameter sockets")
	var g := Pasture3DTerrainGraph.new()

	# Constant 123.0 driving Swiss amplitude
	var c_amp: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
	c_amp.set("value", 123.0)

	var swiss: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"noise_swiss")
	swiss.set("amplitude", 1.0) # Local property is 1.0, but driven by 123.0

	var out: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"output")

	var i_c := g.add_node(c_amp)
	var i_s := g.add_node(swiss)
	var i_o := g.add_node(out)

	g.connect_ports(i_c, 0, i_s, 0) # Port 0 on Swiss is amplitude!
	g.connect_ports(i_s, 0, i_o, 0)

	var rect := Rect2(0, 0, 100, 100)
	var grid: PackedFloat32Array = g.evaluate(16, 16, rect)
	_assert(grid.size() == 256, "Driven Swiss evaluated successfully")
	var max_val := 0.0
	for v in grid:
		if absf(v) > max_val: max_val = absf(v)
	_assert(max_val > 10.0, "Driven amplitude resulted in large surface height (max_val=%.2f)" % max_val)


func _d_native_lowering_all_nodes() -> void:
	print("[D] Native SSA program compilation support for graph with parameter nodes")
	var g := Pasture3DTerrainGraph.new()
	var n1: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"noise_swiss")
	var n2: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"terrace")
	var n3: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"mask")
	var n4: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"output")

	var i1 := g.add_node(n1)
	var i2 := g.add_node(n2)
	var i3 := g.add_node(n3)
	var i4 := g.add_node(n4)

	g.connect_ports(i1, 0, i2, 0)
	g.connect_ports(i2, 0, i3, 0)
	g.connect_ports(i3, 0, i4, 0)

	_assert(g.native_supported(), "Graph with Swiss + Terrace + Mask is native_supported()")
	var prog: Dictionary = g.compile_graph_program()
	_assert(not prog.is_empty(), "compile_graph_program produced valid native program")
	_assert((prog.get("ops", []) as Array).size() == 4, "Compiled program contains all 4 ops")


func _assert(condition: bool, message: String) -> void:
	if condition:
		print("  PASS: %s" % message)
	else:
		print("  FAIL: %s" % message)
		_fail += 1
