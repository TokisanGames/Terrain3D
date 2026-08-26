# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphEditModelGate — the graph editor's MODEL layer (terrain-graph increment 3). The GraphEdit view is
# editor-only and cannot be asserted headlessly (see the gizmo gates), so the mutation API it drives is
# factored onto Pasture3DTerrainGraph and tested here: add / connect (one wire per input) / disconnect /
# set output / remove-with-reindex, plus that a node param change forwards through the graph's `changed`.
#
# House discipline: measure a concrete result, and carry a control that must move if the path is dead.
extends Node

const GW := 8
const GH := 8
const RECT := Rect2(0, 0, 10, 10)

var _fail := 0


func _ready() -> void:
	print("=== GraphEditModelGate: Pasture3DTerrainGraph editing API (increment 3) ===\n")
	_a_add_via_registry()
	_b_connect_one_wire_per_port()
	_c_set_output_drives_evaluate()
	_d_remove_node_reindexes()
	_e_node_change_forwards()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH EDIT MODEL PASS" if _fail == 0 else "GRAPH EDIT MODEL FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _a_add_via_registry() -> void:
	print("[A] add_node via the registry")
	var g := Pasture3DTerrainGraph.new()
	var i0 := g.add_node(Pasture3DGraphNodeRegistry.create(&"noise"))
	var i1 := g.add_node(Pasture3DGraphNodeRegistry.create(&"smooth"))
	var ok := i0 == 0 and i1 == 1 and g.nodes.size() == 2 and g.nodes[0].op() == &"noise" \
			and g.nodes[1].op() == &"smooth"
	print("    indices %d,%d, size %d, ops [%s,%s]" % [i0, i1, g.nodes.size(),
			g.nodes[0].op() if g.nodes.size() > 0 else "-", g.nodes[1].op() if g.nodes.size() > 1 else "-"])
	if not ok:
		_fail += 1; print("    !! add_node/registry did not build the expected nodes")
	# CONTROL: a null add is rejected and does not grow the graph.
	var before := g.nodes.size()
	var bad := g.add_node(null)
	print("    control: add_node(null)=%d, size stays %s" % [bad, g.nodes.size() == before])
	if bad != -1 or g.nodes.size() != before:
		_fail += 1; print("    !! a null node was not rejected")


func _b_connect_one_wire_per_port() -> void:
	print("[B] connect_ports: one wire per input port (replace)")
	var g := Pasture3DTerrainGraph.new()
	g.add_node(Pasture3DGraphNodeRegistry.create(&"noise")) # 0
	g.add_node(Pasture3DGraphNodeRegistry.create(&"const")) # 1
	g.add_node(Pasture3DGraphNodeRegistry.create(&"blend")) # 2
	g.connect_ports(0, 0, 2, 0)
	g.connect_ports(1, 0, 2, 1)
	var two := g.connections.size() == 2
	g.connect_ports(1, 0, 2, 0) # replace the wire into blend.a
	var still_two := g.connections.size() == 2
	var a_from := _from_of(g, 2, 0)
	print("    2 distinct ports=%s, replace keeps 2=%s, blend.a now from %d (want 1)" % [two, still_two, a_from])
	if not two or not still_two or a_from != 1:
		_fail += 1; print("    !! an input port did not hold exactly one (replaceable) wire")
	# CONTROL: disconnect removes exactly that wire.
	g.disconnect_ports(1, 0, 2, 0)
	print("    control: disconnect -> %d wires (want 1)" % g.connections.size())
	if g.connections.size() != 1:
		_fail += 1; print("    !! disconnect_ports did not remove exactly one wire")


func _c_set_output_drives_evaluate() -> void:
	print("[C] set_output selects what evaluate returns")
	var g := Pasture3DTerrainGraph.new()
	var noise := Pasture3DGraphNodeRegistry.create(&"noise")
	noise.set("amplitude", 5.0)
	noise.set("noise", _make_noise())
	g.add_node(noise)
	g.set_output(0)
	var alive := not _all_zero(g.evaluate(GW, GH, RECT))
	g.set_output(-1)
	var off := _all_zero(g.evaluate(GW, GH, RECT))
	print("    output=0 -> non-zero=%s, output=-1 -> flat 0=%s" % [alive, off])
	if not alive or not off:
		_fail += 1; print("    !! set_output did not drive evaluate")
	# CONTROL: an out-of-range index is ignored (output stays -1, field stays flat).
	g.set_output(99)
	print("    control: set_output(99) ignored -> still flat = %s" % _all_zero(g.evaluate(GW, GH, RECT)))
	if not _all_zero(g.evaluate(GW, GH, RECT)):
		_fail += 1; print("    !! an out-of-range output index was accepted")


func _d_remove_node_reindexes() -> void:
	print("[D] remove_node drops touching wires, reindexes the rest, follows output")
	var g := Pasture3DTerrainGraph.new()
	for i in range(4):
		g.add_node(Pasture3DGraphNodeRegistry.create(&"const")) # 0,1,2,3
	g.connect_ports(1, 0, 3, 0)
	g.connect_ports(2, 0, 3, 1)
	g.set_output(3)
	# Remove node 0 (not in any wire, lower than everything): everything shifts down by one.
	g.remove_node(0)
	var ok1 := g.nodes.size() == 3 and g.output_node == 2 \
			and _has_wire(g, 0, 2, 0) and _has_wire(g, 1, 2, 1) and g.connections.size() == 2
	print("    after remove(0): size=%d, output=%d, wires=%s" % [g.nodes.size(), g.output_node, _wires_str(g)])
	if not ok1:
		_fail += 1; print("    !! removing a lower node did not reindex wires/output")
	# Remove node 0 again (now the one feeding blend.a): its wire is dropped, the other remaps.
	g.remove_node(0)
	var ok2 := g.nodes.size() == 2 and g.output_node == 1 \
			and g.connections.size() == 1 and _has_wire(g, 0, 1, 1)
	print("    after remove(0) again: size=%d, output=%d, wires=%s" % [g.nodes.size(), g.output_node, _wires_str(g)])
	if not ok2:
		_fail += 1; print("    !! removing a wired node did not drop/remap correctly")
	# CONTROL: removing the OUTPUT node clears output_node.
	g.remove_node(1)
	print("    control: remove output node -> output_node=%d (want -1)" % g.output_node)
	if g.output_node != -1:
		_fail += 1; print("    !! removing the output node did not clear output_node")


func _e_node_change_forwards() -> void:
	print("[E] a node param change forwards through graph.changed")
	var g := Pasture3DTerrainGraph.new()
	var noise := Pasture3DGraphNodeRegistry.create(&"noise")
	g.add_node(noise)
	var cnt := [0]
	g.changed.connect(func(): cnt[0] += 1)
	noise.set("amplitude", 3.0) # emits the node's changed -> graph's changed
	print("    editing amplitude fired graph.changed %d time(s) (want >= 1)" % cnt[0])
	if cnt[0] < 1:
		_fail += 1; print("    !! a node param change did not re-emit through the graph")
	# CONTROL: moving the node on the canvas must NOT re-bake.
	cnt[0] = 0
	noise.graph_position = Vector2(120, 40)
	print("    control: moving the node fired graph.changed %d time(s) (want 0)" % cnt[0])
	if cnt[0] != 0:
		_fail += 1; print("    !! graph_position emitted changed (would re-bake on every drag)")


# ---- helpers ----------------------------------------------------------------------------------------

func _from_of(p_g: Pasture3DTerrainGraph, p_to: int, p_to_port: int) -> int:
	for c in p_g.connections:
		if int(c[2]) == p_to and int(c[3]) == p_to_port:
			return int(c[0])
	return -999


func _has_wire(p_g: Pasture3DTerrainGraph, p_from: int, p_to: int, p_to_port: int) -> bool:
	for c in p_g.connections:
		if int(c[0]) == p_from and int(c[2]) == p_to and int(c[3]) == p_to_port:
			return true
	return false


func _wires_str(p_g: Pasture3DTerrainGraph) -> String:
	var parts: Array = []
	for c in p_g.connections:
		parts.append("%d->%d:%d" % [int(c[0]), int(c[2]), int(c[3])])
	return "[" + ", ".join(parts) + "]"


func _make_noise() -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = 3
	n.frequency = 0.1
	return n


func _all_zero(p_g: PackedFloat32Array) -> bool:
	for x in p_g:
		if absf(x) > 1.0e-9:
			return false
	return p_g.size() > 0
