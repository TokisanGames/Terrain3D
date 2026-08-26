# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphUsabilityGate — headless verification gate for Terrain Graph Phase 1 Usability features
# (PASTURE3D_TERRAIN_GRAPH_USABILITY_SPEC.md §6).
#
# Asserts on:
#   [A] Registry search & keyword fuzzy matching
#   [B] Subgraph duplication & internal wire remapping
#   [C] Subgraph clipboard serialize / deserialize round-trip
#   [D] Undo/Redo action sequences on node creation, deletion, connection, and repositioning
#
# Follows the house discipline: every criterion measures a concrete state delta and carries a control.
extends Node

const FrameDataScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_frame_data.gd")
const RerouteNodeScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_reroute.gd")

var _fail := 0


func _ready() -> void:
	print("=== GraphUsabilityGate: Terrain Graph Usability Phases 1, 2 & 3 ===\n")
	_a_registry_search_and_tags()
	_b_subgraph_duplication_and_wire_remapping()
	_c_clipboard_serialize_deserialize()
	_d_undo_redo_actions()
	_e_keyboard_shortcuts_and_selection()
	_f_graph_frames_and_grouping()
	_g_reroute_node_and_connection_splitting()
	_h_mute_bypass_evaluation()
	_i_inline_controls_and_live_updates()
	_j_solo_output_override()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH USABILITY PASS" if _fail == 0 else "GRAPH USABILITY FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _a_registry_search_and_tags() -> void:
	print("[A] Registry search & keyword fuzzy matching")
	var noise_results := Pasture3DGraphNodeRegistry.search("noise")
	var perlin_results := Pasture3DGraphNodeRegistry.search("perlin") # matched via tag
	var blur_results := Pasture3DGraphNodeRegistry.search("blur") # matched via tag -> smooth
	var math_results := Pasture3DGraphNodeRegistry.search("math") # matched via tag -> blend
	
	var has_noise := false
	for r in noise_results:
		if r.get("op") == &"noise":
			has_noise = true
			
	var has_perlin := false
	for r in perlin_results:
		if r.get("op") == &"noise":
			has_perlin = true
			
	var has_smooth := false
	for r in blur_results:
		if r.get("op") == &"smooth":
			has_smooth = true
			
	var has_blend := false
	for r in math_results:
		if r.get("op") == &"blend":
			has_blend = true
			
	var ok := has_noise and has_perlin and has_smooth and has_blend
	print("    noise search: %s, perlin tag: %s, blur tag: %s, math tag: %s" % [has_noise, has_perlin, has_smooth, has_blend])
	if not ok:
		_fail += 1; print("    !! registry search or tags failed to match expected ops")
		
	# CONTROL: an impossible query returns no results.
	var empty_results := Pasture3DGraphNodeRegistry.search("xyz_impossible_query_999")
	print("    control: impossible query results count = %d (want 0)" % empty_results.size())
	if empty_results.size() != 0:
		_fail += 1; print("    !! search returned false positives on impossible query")


func _b_subgraph_duplication_and_wire_remapping() -> void:
	print("[B] Subgraph duplication & internal wire remapping")
	var g := Pasture3DTerrainGraph.new()
	var n0 := g.add_node(Pasture3DGraphNodeRegistry.create(&"noise"), Vector2(100, 100)) # 0
	var n1 := g.add_node(Pasture3DGraphNodeRegistry.create(&"const"), Vector2(100, 200)) # 1
	var n2 := g.add_node(Pasture3DGraphNodeRegistry.create(&"blend"), Vector2(300, 150)) # 2
	var n3 := g.add_node(Pasture3DGraphNodeRegistry.create(&"output"), Vector2(500, 150)) # 3
	
	g.connect_ports(n0, 0, n2, 0)
	g.connect_ports(n1, 0, n2, 1)
	g.connect_ports(n2, 0, n3, 0) # external wire to output
	
	# Duplicate nodes 0, 1, 2 (Noise, Const, Blend) with offset (40, 40)
	var dup_indices := g.duplicate_subgraph([n0, n1, n2], Vector2(40, 40))
	
	var count_ok := dup_indices.size() == 3 and g.nodes.size() == 7
	var d0 := dup_indices[0] # 4
	var d1 := dup_indices[1] # 5
	var d2 := dup_indices[2] # 6
	
	var pos_ok := g.nodes[d0].graph_position == Vector2(140, 140) \
			and g.nodes[d1].graph_position == Vector2(140, 240) \
			and g.nodes[d2].graph_position == Vector2(340, 190)
			
	var wire_ok := _has_wire(g, d0, d2, 0) and _has_wire(g, d1, d2, 1) and not _has_wire(g, d2, n3, 0)
	
	print("    cloned count=%d, new total=%d, offset positions ok=%s, internal wires remapped=%s" % [
		dup_indices.size(), g.nodes.size(), pos_ok, wire_ok
	])
	if not count_ok or not pos_ok or not wire_ok:
		_fail += 1; print("    !! subgraph duplication did not clone or remap internal wires correctly")
		
	# CONTROL: duplicating empty selection returns empty array and alters nothing.
	var before_size := g.nodes.size()
	var empty_dup := g.duplicate_subgraph([])
	print("    control: empty duplicate -> %d nodes, total stays %d" % [empty_dup.size(), g.nodes.size()])
	if empty_dup.size() != 0 or g.nodes.size() != before_size:
		_fail += 1; print("    !! empty duplication mutated graph")


func _c_clipboard_serialize_deserialize() -> void:
	print("[C] Subgraph clipboard serialize / deserialize round-trip")
	var g := Pasture3DTerrainGraph.new()
	var n0 := g.add_node(Pasture3DGraphNodeRegistry.create(&"noise"), Vector2(100, 100))
	var n1 := g.add_node(Pasture3DGraphNodeRegistry.create(&"smooth"), Vector2(300, 100))
	g.connect_ports(n0, 0, n1, 0)
	
	var clip := g.serialize_subgraph([n0, n1])
	var nodes_in_clip: Array = clip.get("nodes", [])
	var wires_in_clip: Array = clip.get("connections", [])
	
	var serialize_ok := nodes_in_clip.size() == 2 and wires_in_clip.size() == 1
	print("    serialized nodes=%d, internal wires=%d" % [nodes_in_clip.size(), wires_in_clip.size()])
	if not serialize_ok:
		_fail += 1; print("    !! serialization failed to capture nodes or wires")
		
	var target_pos := Vector2(500, 500)
	var pasted_indices := g.deserialize_subgraph(clip, target_pos)
	var paste_ok := pasted_indices.size() == 2 and g.nodes.size() == 4
	var p0 := pasted_indices[0]
	var p1 := pasted_indices[1]
	var paste_wire_ok := _has_wire(g, p0, p1, 0)
	
	print("    pasted indices count=%d, total nodes=%d, pasted wire ok=%s" % [
		pasted_indices.size(), g.nodes.size(), paste_wire_ok
	])
	if not paste_ok or not paste_wire_ok:
		_fail += 1; print("    !! deserialization failed to rebuild nodes or wire")
		
	# CONTROL: deserializing empty data returns empty array.
	var empty_paste := g.deserialize_subgraph({})
	print("    control: empty deserialize -> %d" % empty_paste.size())
	if empty_paste.size() != 0:
		_fail += 1; print("    !! empty deserialization created phantom nodes")


func _d_undo_redo_actions() -> void:
	print("[D] Undo/Redo action sequences")
	var g := Pasture3DTerrainGraph.new()
	var editor := Pasture3DGraphEditor.new()
	editor._build_ui()
	editor.edit_graph(g)
	
	var ur: UndoRedo = editor._get_undo_redo()
	
	# Test Add Node Action
	var noise_node := Pasture3DGraphNodeRegistry.create(&"noise")
	editor._action_add_node(noise_node, Vector2(100, 100))
	var size_after_add := g.nodes.size()
	
	ur.undo()
	var size_after_undo := g.nodes.size()
	
	ur.redo()
	var size_after_redo := g.nodes.size()
	
	var add_undo_ok := size_after_add == 1 and size_after_undo == 0 and size_after_redo == 1
	print("    add node -> size %d, undo -> %d, redo -> %d (ok=%s)" % [
		size_after_add, size_after_undo, size_after_redo, add_undo_ok
	])
	if not add_undo_ok:
		_fail += 1; print("    !! add_node undo/redo failed")
		
	# Add a second node and test Connect Action
	var smooth_node := Pasture3DGraphNodeRegistry.create(&"smooth")
	editor._action_add_node(smooth_node, Vector2(300, 100)) # idx 1
	editor._action_connect(0, 0, 1, 0)
	var wires_after_connect := g.connections.size()
	
	ur.undo()
	var wires_after_undo := g.connections.size()
	
	ur.redo()
	var wires_after_redo := g.connections.size()
	
	var connect_undo_ok := wires_after_connect == 1 and wires_after_undo == 0 and wires_after_redo == 1
	print("    connect -> wires %d, undo -> %d, redo -> %d (ok=%s)" % [
		wires_after_connect, wires_after_undo, wires_after_redo, connect_undo_ok
	])
	if not connect_undo_ok:
		_fail += 1; print("    !! connect undo/redo failed")
		
	# Test Delete Node Action with wires
	editor._action_delete_nodes([0])
	var nodes_after_del := g.nodes.size()
	var wires_after_del := g.connections.size()
	
	ur.undo()
	var nodes_after_del_undo := g.nodes.size()
	var wires_after_del_undo := g.connections.size()
	
	ur.redo()
	var nodes_after_del_redo := g.nodes.size()
	var wires_after_del_redo := g.connections.size()
	
	var del_undo_ok := nodes_after_del == 1 and wires_after_del == 0 \
			and nodes_after_del_undo == 2 and wires_after_del_undo == 1 \
			and nodes_after_del_redo == 1 and wires_after_del_redo == 0
			
	print("    delete -> nodes %d wires %d, undo -> nodes %d wires %d, redo -> nodes %d wires %d (ok=%s)" % [
		nodes_after_del, wires_after_del, nodes_after_del_undo, wires_after_del_undo,
		nodes_after_del_redo, wires_after_del_redo, del_undo_ok
	])
	if not del_undo_ok:
		_fail += 1; print("    !! delete undo/redo failed to restore nodes or wires")
		
	# Clean up editor control node
	editor.free()


func _e_keyboard_shortcuts_and_selection() -> void:
	print("[E] Keyboard shortcuts & multi-selection")
	var g = Pasture3DTerrainGraph.new()
	var n0 = g.add_node(Pasture3DGraphNodeRegistry.create(&"noise"), Vector2(100, 100)) # 0
	var n1 = g.add_node(Pasture3DGraphNodeRegistry.create(&"const"), Vector2(100, 200)) # 1
	
	var editor = Pasture3DGraphEditor.new()
	editor._build_ui()
	editor.edit_graph(g)
	
	# Select all nodes
	editor._select_all_nodes(true)
	var sel = editor._get_selected_node_indices()
	var sel_ok = sel.size() == 2
	print("    select all nodes: count=%d (want 2)" % sel.size())
	if not sel_ok:
		_fail += 1; print("    !! select all failed to select both nodes")
		
	# Test Ctrl+D Duplicate Event
	var ev_ctrl_d = InputEventKey.new()
	ev_ctrl_d.pressed = true
	ev_ctrl_d.ctrl_pressed = true
	ev_ctrl_d.keycode = KEY_D
	editor._on_graphedit_gui_input(ev_ctrl_d)
	
	var dup_ok = g.nodes.size() == 4
	print("    Ctrl+D input event: node count = %d (want 4)" % g.nodes.size())
	if not dup_ok:
		_fail += 1; print("    !! Ctrl+D event did not duplicate nodes")
		
	# Test Ctrl+C Copy Event on node 0
	editor._select_all_nodes(false)
	var gn0: GraphNode = editor._graphedit.get_node_or_null("n0")
	if gn0:
		gn0.set_selected(true)
	
	var ev_ctrl_c = InputEventKey.new()
	ev_ctrl_c.pressed = true
	ev_ctrl_c.ctrl_pressed = true
	ev_ctrl_c.keycode = KEY_C
	editor._on_graphedit_gui_input(ev_ctrl_c)
	
	# Test Ctrl+V Paste Event
	var ev_ctrl_v = InputEventKey.new()
	ev_ctrl_v.pressed = true
	ev_ctrl_v.ctrl_pressed = true
	ev_ctrl_v.keycode = KEY_V
	editor._on_graphedit_gui_input(ev_ctrl_v)
	
	var paste_ok = g.nodes.size() == 5
	print("    Ctrl+C & Ctrl+V input event: node count = %d (want 5)" % g.nodes.size())
	if not paste_ok:
		_fail += 1; print("    !! Ctrl+C / Ctrl+V event failed")
		
	editor.free()


func _f_graph_frames_and_grouping() -> void:
	print("[F] GraphFrame grouping, serialization & node attachment")
	var g = Pasture3DTerrainGraph.new()
	var n0 = g.add_node(Pasture3DGraphNodeRegistry.create(&"noise"), Vector2(100, 100)) # 0
	var n1 = g.add_node(Pasture3DGraphNodeRegistry.create(&"const"), Vector2(100, 200)) # 1
	var n2 = g.add_node(Pasture3DGraphNodeRegistry.create(&"smooth"), Vector2(300, 150)) # 2
	
	# Group nodes 0 and 1 into a frame
	var f_idx = g.group_nodes_in_frame([n0, n1], "Generators", Color(0.3, 0.4, 0.5, 0.8))
	var f_created = f_idx == 0 and g.frames.size() == 1
	var frame = g.frames[0] if g.frames.size() > 0 else null
	
	var frame_ok: bool = frame != null and frame.title == "Generators" \
			and frame.attached_node_indices.size() == 2 \
			and frame.attached_node_indices[0] == 0 and frame.attached_node_indices[1] == 1
			
	print("    frame created=%s, title='%s', attached=%s" % [
		f_created, frame.title if frame else "", frame.attached_node_indices if frame else []
	])
	if not f_created or not frame_ok:
		_fail += 1; print("    !! frame grouping failed")
		
	# Removing node 0 shifts node 1 down to index 0, so frame attachment must remap from [0, 1] to [0]
	g.remove_node(0)
	var remapped_ok: bool = g.frames.size() == 1 and g.frames[0].attached_node_indices.size() == 1 \
			and g.frames[0].attached_node_indices[0] == 0
			
	print("    after remove_node(0): frame attached=%s (ok=%s)" % [
		g.frames[0].attached_node_indices if g.frames.size() > 0 else [], remapped_ok
	])
	if not remapped_ok:
		_fail += 1; print("    !! node removal did not remap frame attached indices")
		
	# CONTROL: removing frame drops frame without affecting nodes.
	var node_count_before = g.nodes.size()
	g.remove_frame(0)
	print("    control: remove_frame -> %d frames (want 0), nodes stay %d" % [g.frames.size(), g.nodes.size()])
	if g.frames.size() != 0 or g.nodes.size() != node_count_before:
		_fail += 1; print("    !! frame removal failed or mutated nodes")


func _g_reroute_node_and_connection_splitting() -> void:
	print("[G] Reroute node transparent passthrough & connection splitting")
	var g = Pasture3DTerrainGraph.new()
	var c0 = Pasture3DGraphNodeRegistry.create(&"const")
	c0.set("value", 10.0)
	var n0 = g.add_node(c0, Vector2(100, 100)) # 0
	
	var c1 = Pasture3DGraphNodeRegistry.create(&"const")
	c1.set("value", 5.0)
	var n1 = g.add_node(c1, Vector2(100, 200)) # 1
	
	var blend = Pasture3DGraphNodeRegistry.create(&"blend")
	var n2 = g.add_node(blend, Vector2(300, 150)) # 2
	
	var out_node = Pasture3DGraphNodeRegistry.create(&"output")
	var n3 = g.add_node(out_node, Vector2(500, 150)) # 3
	
	g.connect_ports(n0, 0, n2, 0)
	g.connect_ports(n1, 0, n2, 1)
	g.connect_ports(n2, 0, n3, 0)
	
	var baseline: PackedFloat32Array = g.evaluate(8, 8, Rect2(0, 0, 10, 10))
	var base_val: float = baseline[0]
	print("    baseline evaluation (10 + 5) = %.1f" % base_val)
	if absf(base_val - 15.0) > 1.0e-5:
		_fail += 1; print("    !! baseline evaluation did not produce 15.0")
		
	# Split connection (0:0 -> 2:0) with a Reroute node
	var reroute_node = Pasture3DGraphNodeRegistry.create(&"reroute")
	var r_idx: int = g.split_connection_with_node(n0, 0, n2, 0, reroute_node, Vector2(200, 100))
	
	var split_ok: bool = r_idx == 4 and g.connections.size() == 4 \
			and _has_wire(g, n0, r_idx, 0) and _has_wire(g, r_idx, n2, 0) and not _has_wire(g, n0, n2, 0)
			
	var rerouted_field: PackedFloat32Array = g.evaluate(8, 8, Rect2(0, 0, 10, 10))
	var rerouted_val: float = rerouted_field[0]
	
	var diff_from_base: float = 0.0
	for i in range(baseline.size()):
		diff_from_base = maxf(diff_from_base, absf(baseline[i] - rerouted_field[i]))
		
	var passthrough_ok: bool = diff_from_base < 1.0e-6
	print("    split wire ok=%s, max |rerouted - baseline| = %.8f m (want 0.0)" % [split_ok, diff_from_base])
	if not split_ok or not passthrough_ok:
		_fail += 1; print("    !! reroute node did not pass values transparently or split connection correctly")
		
	# CONTROL: disconnecting reroute drops field back to unwired default (5.0).
	g.disconnect_ports(r_idx, 0, n2, 0)
	var unwired_field: PackedFloat32Array = g.evaluate(8, 8, Rect2(0, 0, 10, 10))
	print("    control: disconnecting reroute -> %.1f (want 5.0)" % unwired_field[0])
	if absf(unwired_field[0] - 5.0) > 1.0e-5:
		_fail += 1; print("    !! disconnected reroute did not revert field")


func _h_mute_bypass_evaluation() -> void:
	print("[H] Mute bypass evaluation across Filters & Combiners")
	var g = Pasture3DTerrainGraph.new()
	var c10 = Pasture3DGraphNodeRegistry.create(&"const")
	c10.set("value", 10.0)
	var n0 = g.add_node(c10, Vector2(100, 100)) # 0
	
	var c5 = Pasture3DGraphNodeRegistry.create(&"const")
	c5.set("value", 5.0)
	var n1 = g.add_node(c5, Vector2(100, 200)) # 1
	
	var blend = Pasture3DGraphNodeRegistry.create(&"blend")
	var n2 = g.add_node(blend, Vector2(300, 150)) # 2
	
	var smooth = Pasture3DGraphNodeRegistry.create(&"smooth")
	smooth.set("passes", 3)
	var n3 = g.add_node(smooth, Vector2(500, 150)) # 3
	
	var out_node = Pasture3DGraphNodeRegistry.create(&"output")
	var n4 = g.add_node(out_node, Vector2(700, 150)) # 4
	
	g.connect_ports(n0, 0, n2, 0) # 10 -> blend A
	g.connect_ports(n1, 0, n2, 1) # 5 -> blend B
	g.connect_ports(n2, 0, n3, 0) # blend -> smooth
	g.connect_ports(n3, 0, n4, 0) # smooth -> output
	
	# Normal evaluation: (10 + 5) = 15.0 -> smoothed = 15.0
	var normal_field: PackedFloat32Array = g.evaluate(8, 8, Rect2(0, 0, 10, 10))
	print("    normal output = %.1f" % normal_field[0])
	
	# MUTE Blend node -> should bypass blend and pass port 0 (10.0) through to smooth -> output is 10.0
	blend.muted = true
	var blend_muted_field: PackedFloat32Array = g.evaluate(8, 8, Rect2(0, 0, 10, 10))
	print("    blend muted output = %.1f (want 10.0)" % blend_muted_field[0])
	if absf(blend_muted_field[0] - 10.0) > 1.0e-5:
		_fail += 1; print("    !! muted blend did not bypass to input 0")
		
	# MUTE Smooth node as well -> output is still 10.0
	smooth.muted = true
	var all_muted_field: PackedFloat32Array = g.evaluate(8, 8, Rect2(0, 0, 10, 10))
	print("    blend & smooth muted output = %.1f (want 10.0)" % all_muted_field[0])
	if absf(all_muted_field[0] - 10.0) > 1.0e-5:
		_fail += 1; print("    !! muted smooth did not pass input through")
		
	# CONTROL: unmuting restores 15.0
	blend.muted = false
	smooth.muted = false
	var restored_field: PackedFloat32Array = g.evaluate(8, 8, Rect2(0, 0, 10, 10))
	print("    control: unmuting restores = %.1f (want 15.0)" % restored_field[0])
	if absf(restored_field[0] - 15.0) > 1.0e-5:
		_fail += 1; print("    !! unmuting did not restore output")


func _i_inline_controls_and_live_updates() -> void:
	print("[I] Inline parameter mutation & live update signal propagation")
	var g = Pasture3DTerrainGraph.new()
	var c_node = Pasture3DGraphNodeRegistry.create(&"const")
	c_node.set("value", 3.0)
	var n0 = g.add_node(c_node, Vector2(100, 100))
	
	var out_node = Pasture3DGraphNodeRegistry.create(&"output")
	var n1 = g.add_node(out_node, Vector2(300, 100))
	g.connect_ports(n0, 0, n1, 0)
	
	var editor = Pasture3DGraphEditor.new()
	editor._build_ui()
	editor.edit_graph(g)
	
	var key_before = g.content_key()
	# Live edit const node parameter
	c_node.value = 42.0
	var key_after = g.content_key()
	var live_field: PackedFloat32Array = g.evaluate(8, 8, Rect2(0, 0, 10, 10))
	
	print("    key bumped=%s (%d -> %d), new field value=%.1f (want 42.0)" % [
		key_after > key_before, key_before, key_after, live_field[0]
	])
	if key_after <= key_before or absf(live_field[0] - 42.0) > 1.0e-5:
		_fail += 1; print("    !! inline parameter mutation did not bump content key or update evaluation")
		
	# Toggle Mute via editor action
	editor._action_set_node_muted(n0, true)
	var muted_field: PackedFloat32Array = g.evaluate(8, 8, Rect2(0, 0, 10, 10))
	print("    action mute const node -> %.1f (want 0.0)" % muted_field[0])
	if absf(muted_field[0] - 0.0) > 1.0e-5:
		_fail += 1; print("    !! editor action mute failed")
		
	editor.free()


func _j_solo_output_override() -> void:
	print("[J] Solo output override evaluation and toggling")
	var g = Pasture3DTerrainGraph.new()
	var c10 = Pasture3DGraphNodeRegistry.create(&"const")
	c10.set("value", 10.0)
	var n0 = g.add_node(c10, Vector2(100, 100)) # 0
	
	var c5 = Pasture3DGraphNodeRegistry.create(&"const")
	c5.set("value", 5.0)
	var n1 = g.add_node(c5, Vector2(100, 200)) # 1
	
	var blend = Pasture3DGraphNodeRegistry.create(&"blend")
	var n2 = g.add_node(blend, Vector2(300, 150)) # 2
	
	var out_node = Pasture3DGraphNodeRegistry.create(&"output")
	var n3 = g.add_node(out_node, Vector2(500, 150)) # 3
	
	g.connect_ports(n0, 0, n2, 0)
	g.connect_ports(n1, 0, n2, 1)
	g.connect_ports(n2, 0, n3, 0)
	
	var normal_field: PackedFloat32Array = g.evaluate(8, 8, Rect2(0, 0, 10, 10))
	print("    normal output (10 + 5) = %.1f" % normal_field[0])
	
	# Solo node 1 (c5 = 5.0)
	g.set_output(n1)
	var solo_field: PackedFloat32Array = g.evaluate(8, 8, Rect2(0, 0, 10, 10))
	print("    solo node 1 (Const 5) output = %.1f (want 5.0)" % solo_field[0])
	if absf(solo_field[0] - 5.0) > 1.0e-5:
		_fail += 1; print("    !! solo override did not route to soloed node")
		
	# Solo node 0 (c10 = 10.0)
	g.set_output(n0)
	var solo0_field: PackedFloat32Array = g.evaluate(8, 8, Rect2(0, 0, 10, 10))
	print("    solo node 0 (Const 10) output = %.1f (want 10.0)" % solo0_field[0])
	if absf(solo0_field[0] - 10.0) > 1.0e-5:
		_fail += 1; print("    !! solo override did not route to node 0")
		
	# Toggle solo off by calling set_output on node 0 again
	g.set_output(n0)
	var restored_field: PackedFloat32Array = g.evaluate(8, 8, Rect2(0, 0, 10, 10))
	print("    toggle solo off -> output = %.1f (want 15.0)" % restored_field[0])
	if absf(restored_field[0] - 15.0) > 1.0e-5:
		_fail += 1; print("    !! toggling solo off did not restore default output")


# ---- helpers ----------------------------------------------------------------------------------------

func _has_wire(p_g: Pasture3DTerrainGraph, p_from: int, p_to: int, p_to_port: int) -> bool:
	for c in p_g.connections:
		if int(c[0]) == p_from and int(c[2]) == p_to and int(c[3]) == p_to_port:
			return true
	return false
