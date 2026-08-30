# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphAllNodeSocketsGate — headless verification gate for Universal Node Parameter Sockets.
#
# Asserts on:
#   [A] Parameter sockets across all Pasture3D graph nodes (port counts > 1, typed ports)
#   [B] Unwired default evaluation backward-compatibility
#   [C] Dynamically driven parameter socket evaluation
#   [D] Single-call native C++ graph program lowering with new node sockets
#   [E] Every generator honours a driven parameter socket, on BOTH evaluators
#   [F] No node's native path IGNORES a driven parameter port (sweeps all 105 of them)
extends Node

var _fail := 0


func _ready() -> void:
	print("=== GraphAllNodeSocketsGate: Universal Parameter Sockets ===\n")
	_a_parameter_socket_definitions()
	_b_unwired_defaults_and_eval()
	_c_driven_parameter_sockets()
	_d_native_lowering_all_nodes()
	_e_driven_params_all_generators()
	_f_no_native_path_ignores_a_driven_port()
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


# [E] The regression net for a bug that was silent for months: the native evaluator read a generator's
# parameters out of the compiled program and ignored every wire into a parameter port, so a Const driving
# an amplitude changed nothing. Section C caught it for Swiss only, and only on port 0.
#
# Each generator below is evaluated twice — once with its local property at a small value, once with that
# same property driven from a Const at a large one — on BOTH evaluators. Three things have to hold, and the
# first two are the controls that make the third mean something:
#   * the undriven run must NOT already produce the driven magnitude, or the check would pass on a node
#     that ignores the wire entirely;
#   * the two evaluators must agree, or one of them is silently reading a different graph;
#   * driving the port must actually move the output.
func _e_driven_params_all_generators() -> void:
	print("[E] Driven parameter sockets on every generator, native and unfolded")
	# op, the property on port 0, its quiet value, and the driven value.
	var cases: Array[Dictionary] = [
		{"op": &"noise_swiss", "prop": &"amplitude", "quiet": 1.0, "driven": 123.0},
		{"op": &"noise_jordan", "prop": &"amplitude", "quiet": 1.0, "driven": 123.0},
		{"op": &"furrows", "prop": &"amplitude", "quiet": 1.0, "driven": 90.0},
		{"op": &"dunes", "prop": &"amplitude", "quiet": 1.0, "driven": 90.0},
		{"op": &"crater", "prop": &"amplitude", "quiet": 5.0, "driven": 80.0},
		{"op": &"geological_primitive", "prop": &"height", "quiet": 5.0, "driven": 80.0},
	]
	var rect := Rect2(0, 0, 400, 400)
	for c in cases:
		var quiet := _peak(c["op"], c["prop"], c["quiet"], 0.0, false)
		var native := _peak(c["op"], c["prop"], c["quiet"], c["driven"], false)
		var unfolded := _peak(c["op"], c["prop"], c["quiet"], c["driven"], true)
		# The control. If the quiet run already reaches the driven magnitude the comparison is vacuous.
		_assert(quiet < 0.5 * native, "%s undriven stays small (%.2f vs driven %.2f)" % [c["op"], quiet, native])
		_assert(absf(native - unfolded) <= maxf(1e-3, 1e-4 * absf(native)),
				"%s agrees across evaluators (native %.4f, unfolded %.4f)" % [c["op"], native, unfolded])
		_assert(native > quiet * 2.0, "%s port 0 responds to a driven Const" % c["op"])

	# Ports past the fourth. A compiled program carries four GRID slots, in0..in3 — but a driven SCALAR
	# needs no grid slot, only cell 0 of its source, so those ports ride a flat overflow table and the graph
	# stays native. This used to decline outright, which cost a user every native op in the graph for
	# wiring one Const to Swiss `frequency`. Both halves are asserted: the mapped port keeps acceleration
	# AND is actually honoured, the unmapped port still declines rather than being dropped on the floor.
	var g := Pasture3DTerrainGraph.new()
	var s5: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"noise_swiss")
	var c5: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
	c5.set("value", 0.05)
	var o5: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"output")
	var i_c5 := g.add_node(c5)
	var i_s5 := g.add_node(s5)
	g.connect_ports(i_c5, 0, i_s5, 4) # frequency
	g.connect_ports(i_s5, 0, g.add_node(o5), 0)
	_assert(g.native_supported(), "a driven scalar on port 4 keeps the native path")

	# Honoured, not merely tolerated: a frequency an order of magnitude apart must change the surface. The
	# node's own local frequency is left alone, so the only thing that moved is the wire.
	var rect5 := Rect2(-256.0, -256.0, 512.0, 512.0)
	var lo := g.evaluate(64, 64, rect5)
	c5.set("value", 0.0005)
	var hi := g.evaluate(64, 64, rect5)
	var moved := 0.0
	for i in range(mini(lo.size(), hi.size())):
		moved = maxf(moved, absf(lo[i] - hi[i]))
	_assert(moved > 1.0, "port 4 actually reaches the native kernel (peak delta %.3f m)" % moved)

	# The unfolded oracle is the second opinion. If only the native path moved, the two evaluators now
	# disagree about what port 4 means, which is the bug class this whole gate exists for.
	var uf := g._eval_unfolded(64, 64, rect5)
	var agree := 0.0
	for i in range(mini(uf.size(), hi.size())):
		agree = maxf(agree, absf(uf[i] - hi[i]))
	_assert(agree <= maxf(1e-2, 1e-3 * moved), "port 4 agrees across evaluators (max |native - unfolded| %.4f)" % agree)

	# CONTROL: a port >= 4 that PARAM_PORT_MAP does not map is a grid input with nowhere to go, and must
	# still decline. terrain_bus_merge's port 4 carries a `flow` channel, not a scalar. Without this the
	# relaxation above would read as "port >= 4 is fine now", which is not what was built.
	var gb := Pasture3DTerrainGraph.new()
	var bm: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"terrain_bus_merge")
	if bm != null and bm.input_count() > 4:
		var cb: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
		var i_cb := gb.add_node(cb)
		var i_bm := gb.add_node(bm)
		gb.connect_ports(i_cb, 0, i_bm, 4)
		gb.connect_ports(i_bm, 0, gb.add_node(Pasture3DGraphNodeRegistry.create(&"output")), 0)
		_assert(not gb.native_supported(), "an UNMAPPED port 4 still declines the native path")
	else:
		_assert(false, "control gone: terrain_bus_merge no longer has an unmapped fifth port")


## The peak |height| of a one-generator graph, optionally with port 0 driven by a Const, on either the
## folded/native evaluator or the unfolded reference.
func _peak(p_op: StringName, p_prop: StringName, p_local: float, p_driven: float,
		p_unfolded: bool) -> float:
	var g := Pasture3DTerrainGraph.new()
	var n: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(p_op)
	n.set(p_prop, p_local)
	var o: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"output")
	var i_n := g.add_node(n)
	var i_o := g.add_node(o)
	if p_driven != 0.0:
		var c: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
		c.set("value", p_driven)
		g.connect_ports(g.add_node(c), 0, i_n, 0)
	g.connect_ports(i_n, 0, i_o, 0)
	var rect := Rect2(0, 0, 400, 400)
	var grid: PackedFloat32Array = g._eval_unfolded(32, 32, rect) if p_unfolded else g.evaluate(32, 32, rect)
	var m := 0.0
	for v in grid:
		if is_finite(v):
			m = maxf(m, absf(v))
	return m


# [F] The general form of [E], over every FLOAT/INT parameter port on every node — 105 of them.
#
# The criterion is deliberately NOT "the two evaluators agree". Several of these nodes are chaotic iterative
# solvers whose native kernel and GDScript oracle differ by a percent or two for reasons that have nothing
# to do with parameter wiring, and a gate that fails on those would be noise. What is unambiguous is this:
# if driving a port moves the UNFOLDED result but leaves the NATIVE result exactly where it was undriven,
# the native path ignored the wire. That was true of 52 ports before this was fixed.
#
# The control is the last line: at least half the ports must visibly respond somewhere. Without it a harness
# that silently evaluated nothing — a broken graph build, a zeroed fixture — would report a clean sweep,
# and "measured nothing" would be indistinguishable from "measured well".
func _f_no_native_path_ignores_a_driven_port() -> void:
	print("[F] Sweep: does any node's native path ignore a driven parameter port?")
	# Nothing is excluded from this sweep. hydraulic_saleve's dx/dy used to be, because they are typed
	# FLOAT but are per-cell FIELDS the native case consumes as grids — and driving one moved the
	# unfolded result while leaving native bit-identical. That turned out to be a real bug, not a
	# wrongly-shaped question: the solver applied its drainage warp only when BOTH axes were present,
	# and the two evaluators disagree about an unwired port (a zeros GRID in GDScript, absent in the
	# compiled program), so dx alone warped on one path and did nothing on the other. Fixed in
	# pasture_3d_hydraulic_saleve.cpp; the exclusion is gone rather than documented.
	var ignored: Array[String] = []
	var responded := 0
	var swept := 0
	for entry in Pasture3DGraphNodeRegistry.entries():
		var op: StringName = entry["op"] if entry.has("op") else &""
		if op == &"" or String(op).begins_with("dev_"):
			continue
		var probe: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(op)
		if probe == null:
			continue
		var types: PackedInt32Array = probe.input_port_types()
		var names: PackedStringArray = probe.input_names()
		# EVERY port, not the first four. The cap was here because a wire past port 3 declined the native
		# path outright, so there was nothing to compare; driven scalars beyond it now ride the pdrv_*
		# overflow table, and they need sweeping exactly like the rest. A port >= 4 that is still unmapped
		# sends the graph to GDScript, where both readings move together, so it cannot fail this falsely.
		for k in types.size():
			if types[k] != Pasture3DGraphNode.PortType.FLOAT and types[k] != Pasture3DGraphNode.PortType.INT:
				continue
			swept += 1
			# 16x16 and two values, because this runs over 105 ports and some of them are iterative
			# solvers. The question here is binary — did the native path move at all — so resolution buys
			# nothing; section E does the careful, higher-resolution version on the generators.
			var base_n := _peak_port(op, k, 0.0, false, false)
			var base_u := _peak_port(op, k, 0.0, false, true)
			var moved_native := false
			var moved_unfolded := false
			for v in [3.0, 40.0]:
				var dn := absf(_peak_port(op, k, v, true, false) - base_n)
				var du := absf(_peak_port(op, k, v, true, true) - base_u)
				if dn > maxf(1e-4, 1e-4 * absf(base_n)):
					moved_native = true
				if du > maxf(1e-4, 1e-4 * absf(base_u)):
					moved_unfolded = true
			if moved_native:
				responded += 1
			elif moved_unfolded:
				ignored.append("%s.%s[%d]" % [op, names[k] if k < names.size() else "?", k])
	_assert(ignored.is_empty(), "no native path ignores a driven port (%d swept, %d ignored%s)"
			% [swept, ignored.size(), "" if ignored.is_empty() else ": " + ", ".join(ignored)])
	# The control: a sweep where nothing moved anywhere has measured nothing, and would pass the check above.
	_assert(responded * 2 >= swept, "the sweep can see responses at all (%d of %d ports moved)" % [responded, swept])


## Peak |height| of a one-node graph with an arbitrary PORT optionally driven from a Const. Section E's
## `_peak` drives port 0 by setting a property; this one drives any of the first four ports by index, which
## is what the sweep needs. A node whose port 0 is a HEIGHT input is fed a real field so the comparison is
## not made against a flat zero. 16x16, because the sweep covers 105 ports and the question it asks is
## binary — did the native path move at all — so resolution buys nothing.
func _peak_port(p_op: StringName, p_port: int, p_value: float, p_drive: bool, p_unfolded: bool) -> float:
	var g := Pasture3DTerrainGraph.new()
	var n: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(p_op)
	if n == null:
		return 0.0
	var o: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"output")
	var i_n := g.add_node(n)
	var i_o := g.add_node(o)
	var types: PackedInt32Array = n.input_port_types()
	if types.size() > 0 and types[0] == Pasture3DGraphNode.PortType.HEIGHT and p_port != 0:
		var src: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"noise_swiss")
		src.set("amplitude", 60.0)
		src.set("frequency", 0.01)
		g.connect_ports(g.add_node(src), 0, i_n, 0)
	if p_drive:
		var c: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"const")
		c.set("value", p_value)
		g.connect_ports(g.add_node(c), 0, i_n, p_port)
	g.connect_ports(i_n, 0, i_o, 0)
	var rect := Rect2(0, 0, 400, 400)
	var grid: PackedFloat32Array = g._eval_unfolded(16, 16, rect) if p_unfolded else g.evaluate(16, 16, rect)
	var m := 0.0
	for v in grid:
		if is_finite(v):
			m = maxf(m, absf(v))
	return m


func _assert(condition: bool, message: String) -> void:
	if condition:
		print("  PASS: %s" % message)
	else:
		print("  FAIL: %s" % message)
		_fail += 1
