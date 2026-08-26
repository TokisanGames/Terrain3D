# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DTerrainGraph — a saveable DAG of Pasture3DGraphNodes that evaluates to one height field. This
# is the reusable unit the whole feature turns on: a graph is a `.tres`, so "a different graph per kind
# of landscape" is just a different resource, and the same graph can drive a whole terrain OR be masked
# to a brush's footprint (the later stack-mount increment).
#
# It generalises the brush node stack from a chain to a DAG. Increment 1 is the EVALUATOR ONLY — headless
# and gated, the way the Sim was built (PASTURE3D_SIM_NODE_SPEC.md) before it grew a UI and a threaded
# backend. No editor UI, no C++/GPU, no stack mount yet; those are later increments
# (PASTURE3D_TERRAIN_GRAPH_SPEC.md, build order).
#
# ---- Evaluation model (increment 1): simplest-correct ----
#
# Topologically order the nodes feeding the output and MATERIALISE ONE GRID PER NODE. A cell node's grid
# is a per-cell loop over `eval_cell`; a grid node's is one `eval_grid` call. No fold yet — a run of cell
# nodes is not fused into a single loop. That fold (and then a C++/GPU backend that keeps grids resident)
# is a pure optimisation layered on later; the per-node grid is the oracle it must match.
@tool
class_name Pasture3DTerrainGraph
extends Resource

## The nodes. Order here is authoring order only — evaluation order is derived from `connections`.
@export var nodes: Array[Pasture3DGraphNode] = []:
	set(v):
		nodes = v
		emit_changed()

## The wires, each a PackedInt32Array `[from_node, from_port, to_node, to_port]` (indices into `nodes`).
## `from_port` is reserved for multi-output nodes (always 0 today); `to_port` is the destination input
## port. Set programmatically here and by the later GraphEdit UI, so it is a plain untyped Array of
## fixed-shape rows rather than an inspector-edited field.
@export var connections: Array = []:
	set(v):
		connections = v
		emit_changed()

## Index into `nodes` of the node whose grid is the graph's output. -1 (or out of range) = no output, and
## `evaluate` returns a flat 0 field rather than guessing.
@export var output_node: int = -1:
	set(v):
		output_node = v
		emit_changed()


## Map a cell to its WORLD XZ. Cell-CENTRE sampling over `p_rect` (position = min XZ, size = extent).
## Static so the graph and any oracle sample the identical point — a mapping disagreement would look like
## a solver bug. `dx = size / count`, `w = min + (i + 0.5) * dx`.
static func cell_to_world(p_ix: int, p_iz: int, p_gw: int, p_gh: int, p_rect: Rect2) -> Vector2:
	var dx := p_rect.size.x / float(maxi(p_gw, 1))
	var dz := p_rect.size.y / float(maxi(p_gh, 1))
	return Vector2(p_rect.position.x + (float(p_ix) + 0.5) * dx,
			p_rect.position.y + (float(p_iz) + 0.5) * dz)


## Evaluate the graph to a `p_gw * p_gh` row-major height field over `p_rect` (world XZ). `p_mask` is an
## optional [0,1] grid of the same shape handed to grid nodes; it is NOT applied globally here — where a
## graph's result lands is the concern of whatever hosts it (a whole-terrain bake, or the masked brush
## mount), not of the graph itself. A missing output or a cycle yields a flat 0 field.
func evaluate(p_gw: int, p_gh: int, p_rect: Rect2, p_mask = null) -> PackedFloat32Array:
	var n := p_gw * p_gh
	if output_node < 0 or output_node >= nodes.size() or nodes[output_node] == null:
		return Pasture3DGraphOps.zeros(n)
	var order := _eval_order()
	if order.is_empty(): # unreachable output or a cycle in its ancestry
		return Pasture3DGraphOps.zeros(n)

	var grids := {} # node index -> PackedFloat32Array
	for ni in order:
		var node: Pasture3DGraphNode = nodes[ni]
		var in_grids := _input_grids(ni, grids, n)
		if node.needs_grid():
			grids[ni] = node.eval_grid(in_grids, p_gw, p_gh, p_mask)
		else:
			var g := PackedFloat32Array()
			g.resize(n)
			var cell_in := PackedFloat32Array()
			cell_in.resize(in_grids.size())
			for iz in range(p_gh):
				var row := iz * p_gw
				for ix in range(p_gw):
					var w := cell_to_world(ix, iz, p_gw, p_gh, p_rect)
					for k in range(in_grids.size()):
						cell_in[k] = (in_grids[k] as PackedFloat32Array)[row + ix]
					g[row + ix] = node.eval_cell(w.x, w.y, cell_in)
			grids[ni] = g
	return grids[output_node]


## The input grids for node `p_ni`, one per input port in port order; an unwired port reads zeros so a
## missing connection is a clean 0, not an error.
func _input_grids(p_ni: int, p_grids: Dictionary, p_n: int) -> Array:
	var count: int = nodes[p_ni].input_count()
	var out: Array = []
	out.resize(count)
	for p in range(count):
		out[p] = Pasture3DGraphOps.zeros(p_n)
	for c in connections:
		if c.size() >= 4 and int(c[2]) == p_ni:
			var to_port := int(c[3])
			var from := int(c[0])
			if to_port >= 0 and to_port < count and p_grids.has(from):
				out[to_port] = p_grids[from]
	return out


## Topological order of exactly the nodes that feed `output_node`. Empty if the output is unreachable or
## its ancestry contains a cycle (Kahn leaves nodes unresolved). Restricting to ancestors means a stray
## disconnected node neither runs nor breaks the sort.
func _eval_order() -> Array:
	# 1. Ancestor set: walk connections backwards from the output.
	var needed := {output_node: true}
	var frontier: Array = [output_node]
	while not frontier.is_empty():
		var cur: int = frontier.pop_back()
		for c in connections:
			if c.size() >= 4 and int(c[2]) == cur:
				var from := int(c[0])
				if from >= 0 and from < nodes.size() and not needed.has(from):
					needed[from] = true
					frontier.push_back(from)
	# 2. Kahn's algorithm over edges internal to the ancestor set.
	var indeg := {}
	for ni in needed:
		indeg[ni] = 0
	for c in connections:
		if c.size() >= 4:
			var from := int(c[0])
			var to := int(c[2])
			if needed.has(from) and needed.has(to):
				indeg[to] += 1
	var ready: Array = []
	for ni in indeg:
		if indeg[ni] == 0:
			ready.push_back(ni)
	var order: Array = []
	while not ready.is_empty():
		var ni: int = ready.pop_back()
		order.push_back(ni)
		for c in connections:
			if c.size() >= 4 and int(c[0]) == ni and needed.has(int(c[2])):
				var to := int(c[2])
				indeg[to] -= 1
				if indeg[to] == 0:
					ready.push_back(to)
	if order.size() != needed.size():
		return [] # a cycle in the output's ancestry
	return order


## True when the output's ancestry contains a cycle — surfaced as a warning and the reason `evaluate`
## returns a flat field.
func has_cycle() -> bool:
	return output_node >= 0 and output_node < nodes.size() and nodes[output_node] != null \
			and _eval_order().is_empty()


## Problems worth telling the user about, for a host's configuration warnings: a missing output, a cycle,
## a null node, an unwired required input, plus each node's own complaints.
func graph_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if output_node < 0 or output_node >= nodes.size():
		w.append("Terrain graph has no output node set, so it evaluates to a flat 0.")
		return w
	if has_cycle():
		w.append("Terrain graph has a cycle feeding its output, so it evaluates to a flat 0. Remove a "
			+ "connection to break the loop.")
	# Unwired required inputs (a filter/combiner with a port nothing connects to).
	for ni in range(nodes.size()):
		var node: Pasture3DGraphNode = nodes[ni]
		if node == null:
			w.append("Terrain graph node %d is empty (null)." % ni)
			continue
		var wired := {}
		for c in connections:
			if c.size() >= 4 and int(c[2]) == ni:
				wired[int(c[3])] = true
		for p in range(node.input_count()):
			if not wired.has(p):
				var names := node.input_names()
				var pname: String = names[p] if p < names.size() else str(p)
				w.append("%s: input '%s' is unconnected and reads 0." % [node.display_name(), pname])
		w.append_array(node.node_warnings())
	return w
