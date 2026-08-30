# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphPaletteAndConstantsGate — headless verification gate for Terrain Graph Categorized Palette,
# Constants of Different Data Types, and Expanded Port Types.
#
# Asserts on:
#   [A] PortType enum expansion & color palette integrity
#   [B] Constant nodes evaluation (ConstInt, ConstVector, ConstColor, ConstCurve, ConstBool)
#   [C] Node registry category indexing & categorization queries
#   [D] Search dialog categorized tree building & filtering
#   [E] Constant node serialization & graph integration
extends Node

const SearchDialogScript = preload("res://addons/pasture_3d/src/graph_search_dialog.gd")

var _fail := 0


func _ready() -> void:
	print("=== GraphPaletteAndConstantsGate: Palette Categorization & Constant Nodes ===\n")
	_a_port_type_system()
	_b_constant_nodes_eval()
	_c_registry_categories()
	_d_search_dialog_tree()
	_e_graph_with_constants_eval()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH PALETTE & CONSTANTS PASS" if _fail == 0 else "GRAPH PALETTE & CONSTANTS FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _a_port_type_system() -> void:
	print("[A] PortType enum expansion & color palette integrity")
	_assert(Pasture3DGraphNode.PortType.HEIGHT == 0, "PortType.HEIGHT is 0")
	_assert(Pasture3DGraphNode.PortType.MASK == 1, "PortType.MASK is 1")
	_assert(Pasture3DGraphNode.PortType.VECTOR == 2, "PortType.VECTOR is 2")
	_assert(Pasture3DGraphNode.PortType.CURVE == 3, "PortType.CURVE is 3")
	_assert(Pasture3DGraphNode.PortType.FLOAT == 4, "PortType.FLOAT is 4")
	_assert(Pasture3DGraphNode.PortType.INT == 5, "PortType.INT is 5")
	_assert(Pasture3DGraphNode.PortType.COLOR == 6, "PortType.COLOR is 6")
	_assert(Pasture3DGraphNode.PortType.BOOL == 7, "PortType.BOOL is 7")
	_assert(Pasture3DGraphNode.PortType.TERRAIN_BUS == 8, "PortType.TERRAIN_BUS is 8")
	_assert(Pasture3DGraphEditor.PORT_COLORS.size() >= 9, "PORT_COLORS has colors for all 9 types")


func _b_constant_nodes_eval() -> void:
	print("[B] Constant nodes evaluation")
	# Const Float
	var c_float: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
	_assert(c_float != null, "Const float node instantiated")
	c_float.set("value", 42.5)
	_assert(c_float.eval_cell(0, 0, PackedFloat32Array()) == 42.5, "Const float eval_cell equals 42.5")

	# Const Int
	var c_int: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const_int")
	_assert(c_int != null, "Const int node instantiated")
	_assert(c_int.output_port_type() == Pasture3DGraphNode.PortType.INT, "Const int output port is PortType.INT")
	c_int.set("value", 7)
	_assert(c_int.eval_cell(0, 0, PackedFloat32Array()) == 7.0, "Const int eval_cell equals 7.0")

	# Const Vector
	var c_vec: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const_vector")
	_assert(c_vec != null, "Const vector node instantiated")
	_assert(c_vec.output_port_type() == Pasture3DGraphNode.PortType.VECTOR, "Const vector output port is PortType.VECTOR")
	c_vec.set("value", Vector2(3.0, 4.0))
	_assert(is_equal_approx(c_vec.eval_cell(0, 0, PackedFloat32Array()), 5.0), "Const vector eval_cell returns length 5.0")

	# Const Color
	var c_col: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const_color")
	_assert(c_col != null, "Const color node instantiated")
	_assert(c_col.output_port_type() == Pasture3DGraphNode.PortType.COLOR, "Const color output port is PortType.COLOR")
	c_col.set("value", Color(1.0, 1.0, 1.0, 1.0))
	_assert(is_equal_approx(c_col.eval_cell(0, 0, PackedFloat32Array()), 1.0), "Const color white luminance equals 1.0")

	# Const Curve
	var c_curve: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const_curve")
	_assert(c_curve != null, "Const curve node instantiated")
	_assert(c_curve.output_port_type() == Pasture3DGraphNode.PortType.CURVE, "Const curve output port is PortType.CURVE")
	var curve: Curve = c_curve.get("curve")
	_assert(curve != null, "Const curve has initialized Curve resource")

	# Const Bool
	var c_bool: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const_bool")
	_assert(c_bool != null, "Const bool node instantiated")
	_assert(c_bool.output_port_type() == Pasture3DGraphNode.PortType.BOOL, "Const bool output port is PortType.BOOL")
	c_bool.set("value", true)
	_assert(c_bool.eval_cell(0, 0, PackedFloat32Array()) == 1.0, "Const bool true eval_cell is 1.0")
	c_bool.set("value", false)
	_assert(c_bool.eval_cell(0, 0, PackedFloat32Array()) == 0.0, "Const bool false eval_cell is 0.0")


func _c_registry_categories() -> void:
	print("[C] Node registry category indexing")
	var cats := Pasture3DGraphNodeRegistry.categories()
	_assert(cats.has("Generators"), "Registry has Generators category")
	_assert(cats.has("Constants"), "Registry has Constants category")
	_assert(cats.has("Filters & Modifiers"), "Registry has Filters & Modifiers category")
	_assert(cats.has("Solvers & Realism"), "Registry has Solvers & Realism category")
	_assert(cats.has("Math & Combiners"), "Registry has Math & Combiners category")
	_assert(cats.has("Routing & Structural"), "Registry has Routing & Structural category")

	var cat_map := Pasture3DGraphNodeRegistry.entries_by_category()
	var const_entries: Array = cat_map.get("Constants", [])
	_assert(const_entries.size() >= 6, "Constants category has at least 6 constant node types")

	var search_const := Pasture3DGraphNodeRegistry.search("constant")
	_assert(search_const.size() >= 6, "Search for 'constant' returns constant nodes")


func _d_search_dialog_tree() -> void:
	print("[D] Search dialog categorized tree building")
	var dlg: Pasture3DGraphSearchDialog = SearchDialogScript.new()
	add_child(dlg)
	dlg.open_at(Vector2(100, 100), Vector2(200, 200))
	_assert(dlg.get_child_count() > 0, "Search dialog opened and built UI tree")
	dlg.queue_free()


func _e_graph_with_constants_eval() -> void:
	print("[E] Constant node serialization & graph integration")
	var g := Pasture3DTerrainGraph.new()
	var c_float: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
	c_float.set("value", 10.0)
	var c_int: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const_int")
	c_int.set("value", 5)
	var blend: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"blend") # Add
	var output: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"output")

	var idx0 := g.add_node(c_float)
	var idx1 := g.add_node(c_int)
	var idx2 := g.add_node(blend)
	var idx3 := g.add_node(output)

	g.connect_ports(idx0, 0, idx2, 0)
	g.connect_ports(idx1, 0, idx2, 1)
	g.connect_ports(idx2, 0, idx3, 0)

	var result := g.evaluate(8, 8, Rect2(-10, -10, 20, 20))
	_assert(result.size() == 64, "Graph evaluation output has 64 cells")
	_assert(is_equal_approx(result[0], 15.0), "Evaluated result (10.0 + 5) equals 15.0")

	print("[F] Native C++ single-call SSA compilation integrity")
	# The CELL compiler is pointwise-only: ops 1-4 in pasture_3d_graph_ops.h are cell ops, and the
	# structural ops (input, output) are 10-12, handled by the WHOLE-GRAPH evaluator instead. A graph
	# carrying an Output sink therefore must NOT lower to a cell program — it has to decline so the
	# caller stays on a path that can actually run the sink. This gate used to demand the opposite.
	var cell_prog: Dictionary = g.compile_cell_program()
	_assert(cell_prog.is_empty(), "compile_cell_program declines a graph carrying an Output sink")
	# CONTROL: the same pointwise chain WITHOUT the sink lowers, so the check above is reporting the
	# sink and not a cell compiler that refuses everything.
	var g_no_sink := Pasture3DTerrainGraph.new()
	var s_float: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
	s_float.set("value", 10.0)
	var s_int: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const_int")
	s_int.set("value", 5)
	var s_blend: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"blend")
	var j0 := g_no_sink.add_node(s_float)
	var j1 := g_no_sink.add_node(s_int)
	var j2 := g_no_sink.add_node(s_blend)
	g_no_sink.connect_ports(j0, 0, j2, 0)
	g_no_sink.connect_ports(j1, 0, j2, 1)
	g_no_sink.output_node = j2 # no sink node, so the graph result is named by index
	var sink_free: Dictionary = g_no_sink.compile_cell_program()
	_assert(not sink_free.is_empty(), "control: the same chain without a sink lowers to native SSA")
	_assert((sink_free.get("ops", PackedInt32Array()) as PackedInt32Array).size() == 3, "SSA program contains all 3 cell ops")

	var graph_prog: Dictionary = g.compile_graph_program()
	_assert(not graph_prog.is_empty(), "compile_graph_program lowers successfully to native graph program")
	_assert((graph_prog.get("ops", PackedInt32Array()) as PackedInt32Array).size() == 4, "Graph program contains all 4 node ops")


func _assert(p_cond: bool, p_msg: String) -> void:
	if p_cond:
		print("  PASS: %s" % p_msg)
	else:
		_fail += 1
		printerr("  FAIL: %s" % p_msg)
