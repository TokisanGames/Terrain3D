# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphTerrainBusGate — headless verification gate for Phase 3: Multi-Channel Terrain Bus System.
#
# Asserts on:
#   [A] TerrainBusMerge and TerrainBusSplit port types, counts, and names
#   [B] Multi-channel bundling & unbundling integrity across single TERRAIN_BUS wire
#   [C] Registry categorization under Routing & Structural
#   [D] Single-call native C++ graph program lowering with Terrain Bus nodes
extends Node

var _fail := 0


func _ready() -> void:
	print("=== GraphTerrainBusGate: Multi-Channel Terrain Bus System ===\n")
	_a_bus_port_definitions()
	_b_bus_merge_and_split_data_flow()
	_c_registry_and_categories()
	_d_native_lowering()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH TERRAIN BUS PASS" if _fail == 0 else "GRAPH TERRAIN BUS FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _a_bus_port_definitions() -> void:
	print("[A] TerrainBusMerge and TerrainBusSplit port definitions")
	var merge_node: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"terrain_bus_merge")
	_assert(merge_node != null, "TerrainBusMerge instantiated")
	_assert(merge_node.input_count() == 5, "TerrainBusMerge has 5 inputs")
	_assert(merge_node.output_port_types()[0] == Pasture3DGraphNode.PortType.TERRAIN_BUS, "TerrainBusMerge primary output is PortType.TERRAIN_BUS")

	var split_node: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"terrain_bus_split")
	_assert(split_node != null, "TerrainBusSplit instantiated")
	_assert(split_node.input_port_types()[0] == Pasture3DGraphNode.PortType.TERRAIN_BUS, "TerrainBusSplit input is PortType.TERRAIN_BUS")
	_assert(split_node.output_count() == 5, "TerrainBusSplit has 5 output channels")
	_assert(split_node.output_port_types()[0] == Pasture3DGraphNode.PortType.HEIGHT, "Channel 0 is HEIGHT")
	_assert(split_node.output_port_types()[1] == Pasture3DGraphNode.PortType.MASK, "Channel 1 is MASK")
	_assert(split_node.output_port_types()[2] == Pasture3DGraphNode.PortType.HEIGHT, "Channel 2 is HEIGHT (water_depth)")
	_assert(split_node.output_port_types()[3] == Pasture3DGraphNode.PortType.MASK, "Channel 3 is MASK (sediment)")
	_assert(split_node.output_port_types()[4] == Pasture3DGraphNode.PortType.MASK, "Channel 4 is MASK (flow)")


func _b_bus_merge_and_split_data_flow() -> void:
	print("[B] Multi-channel bundling & unbundling data flow")
	var g := Pasture3DTerrainGraph.new()

	# Channels: Height = 100.0, Mask = 0.75, Water = 5.0, Sediment = 2.0, Flow = 0.5
	var c_height: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
	c_height.set("value", 100.0)
	var c_mask: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
	c_mask.set("value", 0.75)
	var c_water: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
	c_water.set("value", 5.0)

	var bus_merge: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"terrain_bus_merge")
	var bus_split: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"terrain_bus_split")
	var output: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"output")

	var i_h := g.add_node(c_height)
	var i_m := g.add_node(c_mask)
	var i_w := g.add_node(c_water)
	var i_merge := g.add_node(bus_merge)
	var i_split := g.add_node(bus_split)
	var i_out := g.add_node(output)

	# Wire individual channels into bus_merge
	g.connect_ports(i_h, 0, i_merge, 0)
	g.connect_ports(i_m, 0, i_merge, 1)
	g.connect_ports(i_w, 0, i_merge, 2)

	# Single TERRAIN_BUS connection between merge and split
	g.connect_ports(i_merge, 0, i_split, 0)

	# Wire split channel 0 (height) to output
	g.connect_ports(i_split, 0, i_out, 0)

	var res_height := g.evaluate(8, 8, Rect2(0, 0, 100, 100))
	_assert(is_equal_approx(res_height[0], 100.0), "Height channel routed through bus equals 100.0")

	# Reconnect output to split channel 2 (water_depth)
	g.disconnect_ports(i_split, 0, i_out, 0)
	g.connect_ports(i_split, 2, i_out, 0)

	var res_water := g.evaluate(8, 8, Rect2(0, 0, 100, 100))
	_assert(is_equal_approx(res_water[0], 5.0), "Water depth channel routed through bus equals 5.0")


func _c_registry_and_categories() -> void:
	print("[C] Registry categorization under Routing & Structural")
	var cat_map := Pasture3DGraphNodeRegistry.entries_by_category()
	var routing_entries: Array = cat_map.get("Routing & Structural", [])
	var has_merge := false
	var has_split := false
	for e in routing_entries:
		if e.get("op") == &"terrain_bus_merge": has_merge = true
		if e.get("op") == &"terrain_bus_split": has_split = true
	_assert(has_merge, "Terrain Bus Merge is registered in Routing & Structural")
	_assert(has_split, "Terrain Bus Split is registered in Routing & Structural")


func _d_native_lowering() -> void:
	print("[D] Single-call native C++ graph program lowering")
	var g := Pasture3DTerrainGraph.new()
	var c_node: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
	var bus_merge: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"terrain_bus_merge")
	var bus_split: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"terrain_bus_split")
	var out_node: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"output")

	var i0 := g.add_node(c_node)
	var i1 := g.add_node(bus_merge)
	var i2 := g.add_node(bus_split)
	var i3 := g.add_node(out_node)

	g.connect_ports(i0, 0, i1, 0)
	g.connect_ports(i1, 0, i2, 0)
	g.connect_ports(i2, 0, i3, 0)

	var prog := g.compile_graph_program()
	_assert(not prog.is_empty(), "compile_graph_program lowers successfully for graph with Terrain Bus")


func _assert(p_cond: bool, p_msg: String) -> void:
	if p_cond:
		print("  PASS: %s" % p_msg)
	else:
		_fail += 1
		printerr("  FAIL: %s" % p_msg)
