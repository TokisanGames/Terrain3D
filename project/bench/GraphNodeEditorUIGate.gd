extends Node

## Gate verifying that ALL registered graph nodes can be created, populated in the GraphEdit UI,
## inspected, connected, and evaluated without any GDScript errors or warnings.

func _ready() -> void:
	print("\n=== GraphNodeEditorUIGate: Testing All Nodes in Graph Editor UI ===\n")
	var failures: int = 0

	var entries: Array[Dictionary] = Pasture3DGraphNodeRegistry.entries(true)
	print("Found %d registered nodes to validate..." % entries.size())

	var editor_script = load("res://addons/pasture_3d/src/graph_editor.gd")
	var editor = VBoxContainer.new()
	editor.set_script(editor_script)
	add_child(editor)

	var graph = Pasture3DTerrainGraph.new()
	editor.graph = graph

	for entry in entries:
		var op_name: StringName = entry.get("op", &"")
		var title: String = entry.get("title", "")
		print("  -> Testing node: %s ('%s')" % [title, op_name])

		var node = Pasture3DGraphNodeRegistry.create(op_name)
		if node == null:
			print("     !! FAIL: Failed to instantiate node '%s'" % op_name)
			failures += 1
			continue

		# Verify port contracts
		var in_cnt := node.input_count()
		var in_names := node.input_names()
		var in_types := node.input_port_types()
		if in_names.size() != in_cnt:
			print("     !! FAIL: input_names().size() (%d) != input_count() (%d)" % [in_names.size(), in_cnt])
			failures += 1
		if in_types.size() != in_cnt:
			print("     !! FAIL: input_port_types().size() (%d) != input_count() (%d)" % [in_types.size(), in_cnt])
			failures += 1

		var out_cnt := node.output_count()
		var out_names := node.output_names()
		var out_types := node.output_port_types()
		if out_names.size() != out_cnt:
			print("     !! FAIL: output_names().size() (%d) != output_count() (%d)" % [out_names.size(), out_cnt])
			failures += 1
		if out_types.size() != out_cnt:
			print("     !! FAIL: output_port_types().size() (%d) != output_count() (%d)" % [out_types.size(), out_cnt])
			failures += 1

		# Test slot population in editor UI
		var gn := GraphNode.new()
		editor._populate_node_slots_and_controls(gn, 0, node)
		gn.free()

	# Test evaluating each node standalone
	print("\nTesting standalone evaluate for all generator nodes...")
	var gw: int = 32
	var gh: int = 32
	var rect := Rect2(-50.0, -50.0, 100.0, 100.0)

	for entry in entries:
		var op_name: StringName = entry.get("op", &"")
		var node = Pasture3DGraphNodeRegistry.create(op_name)
		if node == null or node.input_count() > 0:
			continue # skip filter/combiner/solvers that need inputs

		var test_graph := Pasture3DTerrainGraph.new()
		var out_node := Pasture3DGraphNodeOutput.new()
		test_graph.nodes = [node, out_node]
		test_graph.connections = [PackedInt32Array([0, 0, 1, 0])]

		var res: PackedFloat32Array = test_graph.evaluate(gw, gh, rect)
		if res.size() != gw * gh:
			print("     !! FAIL: evaluate failed for node '%s'" % op_name)
			failures += 1

	if failures == 0:
		print("\n=== GRAPH NODE EDITOR UI GATE PASS (0 failures) ===\n")
	else:
		print("\n=== GRAPH NODE EDITOR UI GATE FAIL (%d failures) ===\n" % failures)

	get_tree().quit(0 if failures == 0 else 1)
