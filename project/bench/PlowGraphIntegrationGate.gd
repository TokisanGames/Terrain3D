# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# PlowGraphIntegrationGate — Test suite verifying Pasture3DPlow modifier system integration.

extends Node

const Pasture3DPlow = preload("res://addons/pasture_3d/connectors/pasture3d_plow.gd")
const Pasture3DTerrainGraph = preload("res://addons/pasture_3d/graph/pasture3d_terrain_graph.gd")
const Pasture3DNodeGraph = preload("res://addons/pasture_3d/connectors/pasture3d_mod_graph.gd")
const Pasture3DGraphEditor = preload("res://addons/pasture_3d/src/graph_editor.gd")

var _fail := 0


func _ready() -> void:
	print("=== PlowGraphIntegrationGate: Plow Brush Modifier System Integration Gate ===\n")

	_test_a_plow_modifier_support()
	_test_b_plow_graph_editor_binding_and_bake()
	_test_c_plow_mountain_cone_eval()
	_test_d_legacy_migration()

	_finish()


func _finish() -> void:
	print("\n=== %s (%d failures) ===\n" % [
		"PLOW GRAPH INTEGRATION PASS" if _fail == 0 else "PLOW GRAPH INTEGRATION FAIL",
		_fail
	])
	get_tree().quit(0 if _fail == 0 else 1)


func _test_a_plow_modifier_support() -> void:
	print("[A] Modifier Support on Pasture3DPlow")
	var plow := Pasture3DPlow.new()
	var supp := plow._supports_modifiers()
	print("    _supports_modifiers() = %s (want true)" % str(supp))

	if not supp:
		_fail += 1
		print("    !! Plow does not report modifier support")

	var mg := Pasture3DNodeGraph.new()
	mg.resource_name = "Terrain Graph"
	mg.graph = Pasture3DTerrainGraph.new()
	var cone = Pasture3DGraphNodeRegistry.create(&"mountain_cone")
	if cone != null:
		cone.set("elevation", 40.0)
	var out_n = Pasture3DGraphNodeRegistry.create(&"output")
	mg.graph.add_node(cone)
	mg.graph.add_node(out_n)
	mg.graph.connect_ports(0, 0, 1, 0)
	mg.graph.output_node = 1

	plow.modifiers.append(mg)
	print("    plow.modifiers.size() = %d (want 1)" % plow.modifiers.size())

	if plow.modifiers.size() != 1:
		_fail += 1
		print("    !! Failed to append modifier to plow")

	plow.free()


func _test_b_plow_graph_editor_binding_and_bake() -> void:
	print("\n[B] Graph Editor Binding to Pasture3DPlow Modifiers and Host Brush Resolution")
	var editor := Pasture3DGraphEditor.new()
	editor._build_ui()

	var plow := Pasture3DPlow.new()
	var mg := Pasture3DNodeGraph.new()
	mg.resource_name = "Terrain Graph"
	var graph := Pasture3DTerrainGraph.new()
	var cone = Pasture3DGraphNodeRegistry.create(&"mountain_cone")
	var saleve = Pasture3DGraphNodeRegistry.create(&"hydraulic_saleve")
	var out_n = Pasture3DGraphNodeRegistry.create(&"output")

	var id_c: int = graph.add_node(cone)
	var id_s: int = graph.add_node(saleve)
	var id_o: int = graph.add_node(out_n)
	graph.connect_ports(id_c, 0, id_s, 0)
	graph.connect_ports(id_s, 0, id_o, 0)
	graph.output_node = id_o
	mg.graph = graph
	plow.modifiers.append(mg)

	editor.edit_graph(graph, mg, plow)

	var host_b: Pasture3DTerrainBrush = editor._find_host_brush()
	print("    Resolved host brush = %s (want plow)" % str(host_b == plow))

	if host_b != plow:
		_fail += 1
		print("    !! Graph editor failed to resolve Plow as host brush")

	editor._on_bake_brush_pressed()
	print("    Triggered _on_bake_brush_pressed() successfully")

	editor.queue_free()
	plow.free()


func _test_c_plow_mountain_cone_eval() -> void:
	print("\n[C] Plow Modifier Evaluation of MountainCone Graph")
	var graph := Pasture3DTerrainGraph.new()
	var cone = Pasture3DGraphNodeRegistry.create(&"mountain_cone")
	cone.set("elevation", 50.0)
	cone.set("scale", 1.0)
	var out_n = Pasture3DGraphNodeRegistry.create(&"output")

	var id_c: int = graph.add_node(cone)
	var id_o: int = graph.add_node(out_n)
	graph.connect_ports(id_c, 0, id_o, 0)
	graph.output_node = id_o

	var res: PackedFloat32Array = graph.evaluate(64, 64, Rect2(-50.0, -50.0, 100.0, 100.0))
	var max_h := 0.0
	for v in res:
		if is_finite(v) and v > max_h:
			max_h = v

	print("    Plow mountain cone apex height = %.2f m (want > 30 m)" % max_h)
	if max_h < 30.0:
		_fail += 1
		print("    !! Plow graph evaluation produced insufficient elevation")


func _test_d_legacy_migration() -> void:
	print("\n[D] Legacy Property Migration into Modifiers")
	var plow := Pasture3DPlow.new()
	var g := Pasture3DTerrainGraph.new()
	var cone = Pasture3DGraphNodeRegistry.create(&"mountain_cone")
	g.add_node(cone)

	plow.set("source", 4) # Source.GRAPH
	plow.set("graph", g)
	plow._migrate_legacy()

	print("    migrated modifiers count = %d (want 1)" % plow.modifiers.size())
	if plow.modifiers.size() != 1 or not (plow.modifiers[0] is Pasture3DNodeGraph):
		_fail += 1
		print("    !! Legacy migration failed to produce Pasture3DNodeGraph modifier")
	else:
		var mg: Pasture3DNodeGraph = plow.modifiers[0] as Pasture3DNodeGraph
		print("    migrated modifier graph matches = %s (want true)" % str(mg.graph == g))
		if mg.graph != g:
			_fail += 1
			print("    !! Migrated modifier graph mismatch")

	plow.free()
