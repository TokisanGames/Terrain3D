# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphDrivenParamSweepProbe — sweeps EVERY node's FLOAT/INT parameter port and asks whether wiring it
# actually does anything, on both evaluators.
#
# This is a probe, not a gate: it prints a census and asserts nothing, because "this port did not respond"
# is not automatically a defect. A port can legitimately be inert at the value chosen here.
#
# It exists because the native evaluator ignored generator parameter wires for months and only one gate
# noticed, on one node, on one port. The check that found it generalises: build the same one-node graph
# twice, drive one parameter port from a Const, and compare
#
#   * the native/folded evaluator against the unfolded GDScript reference — they read the SAME graph, so any
#     disagreement is a bug in one of them, no judgement required; and
#   * the driven run against the undriven one — if neither evaluator moves, they may BOTH be ignoring the
#     wire, which is exactly the failure mode that hid in Swiss. Agreement alone would have called that
#     clean.
extends Node

const GW := 24
const GH := 24
const RECT := Rect2(0, 0, 400, 400)

## Values to try on a driven port. A single value risks landing somewhere the parameter genuinely does
## nothing (a zero amount, an angle equal to the default); the largest response over the set is reported.
const PROBE_VALUES: Array[float] = [0.35, 3.0, 40.0]

var _mismatch: Array[String] = []
var _inert: Array[String] = []
var _tested := 0


func _ready() -> void:
	print("=== Driven parameter sweep: every node, every FLOAT/INT port ===\n")
	var ops := _ops_to_sweep()
	print("[sweep] %d ops with parameter ports\n" % ops.size())

	for op in ops:
		var probe: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(op)
		if probe == null:
			continue
		var types: PackedInt32Array = probe.input_port_types()
		var names: PackedStringArray = probe.input_names()
		var lines: Array[String] = []
		for k in types.size():
			if types[k] != Pasture3DGraphNode.PortType.FLOAT and types[k] != Pasture3DGraphNode.PortType.INT:
				continue
			_tested += 1
			var r := _probe_port(op, k)
			var label := "%s.%s[%d]" % [op, names[k] if k < names.size() else "?", k]
			if r["mismatch"] > 1e-3:
				_mismatch.append("%s  native %.4f vs unfolded %.4f" % [label, r["native"], r["unfolded"]])
				lines.append("    MISMATCH %-28s native %10.4f  unfolded %10.4f" % [label, r["native"], r["unfolded"]])
			elif r["response"] <= 1e-6:
				_inert.append(label)
				lines.append("    inert    %-28s no response on either path" % label)
		if not lines.is_empty():
			print("  %s%s" % [op, "" if lines.is_empty() else ""])
			for l in lines:
				print(l)

	print("\n--- census ---")
	print("  %d parameter ports swept" % _tested)
	print("  %d MISMATCH  (the two evaluators disagree — a bug in one of them)" % _mismatch.size())
	print("  %d inert     (neither path responded; may be legitimate at these values)" % _inert.size())
	if not _mismatch.is_empty():
		print("\n  Evaluator disagreements:")
		for m in _mismatch:
			print("    %s" % m)
	if not _inert.is_empty():
		print("\n  Inert ports, for a human to judge:")
		for i in _inert:
			print("    %s" % i)
	print("\n=== sweep complete ===\n")
	get_tree().quit(0)


## Every registered op that has at least one FLOAT or INT input port.
func _ops_to_sweep() -> Array[StringName]:
	var out: Array[StringName] = []
	for entry in Pasture3DGraphNodeRegistry.entries():
		var op: StringName = entry["op"] if entry.has("op") else &""
		if op == &"" or String(op).begins_with("dev_"):
			continue
		var n: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(op)
		if n == null:
			continue
		var types: PackedInt32Array = n.input_port_types()
		for t in types:
			if t == Pasture3DGraphNode.PortType.FLOAT or t == Pasture3DGraphNode.PortType.INT:
				out.append(op)
				break
	return out


## Drive one port and compare the evaluators, taking the strongest response over PROBE_VALUES.
func _probe_port(p_op: StringName, p_port: int) -> Dictionary:
	var base_n := _peak(p_op, p_port, 0.0, false, false)
	var base_u := _peak(p_op, p_port, 0.0, false, true)
	var best := {"mismatch": 0.0, "response": 0.0, "native": base_n, "unfolded": base_u}
	for v in PROBE_VALUES:
		var n := _peak(p_op, p_port, v, true, false)
		var u := _peak(p_op, p_port, v, true, true)
		var mism := absf(n - u)
		var resp := maxf(absf(n - base_n), absf(u - base_u))
		# Report the value that separates the evaluators most; failing that, the one that moved the output
		# most. A port that responds anywhere has answered the question.
		if mism > best["mismatch"] or (is_equal_approx(mism, best["mismatch"]) and resp > best["response"]):
			best = {"mismatch": mism, "response": maxf(resp, best["response"]), "native": n, "unfolded": u}
		elif resp > best["response"]:
			best["response"] = resp
	return best


## Peak |height| of a one-node graph, with port `p_port` optionally driven from a Const. A node whose port 0
## is a HEIGHT input is fed a real noise field, so the comparison is not made against a flat zero.
func _peak(p_op: StringName, p_port: int, p_value: float, p_drive: bool, p_unfolded: bool) -> float:
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
	var grid: PackedFloat32Array = g._eval_unfolded(GW, GH, RECT) if p_unfolded else g.evaluate(GW, GH, RECT)
	var m := 0.0
	for v in grid:
		if is_finite(v):
			m = maxf(m, absf(v))
	return m
