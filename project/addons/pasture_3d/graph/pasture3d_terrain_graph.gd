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

const FrameDataScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_frame_data.gd")

## Emitted when a specific node's parameters change, carrying that node's index and all its downstream dependents.
signal node_updated(node_idx: int, downstream_indices: Array[int])

## Emitted when graph topology (nodes added/removed, frames, positions) changes for UI canvas synchronization.
signal structure_changed()

## The nodes. Order here is authoring order only — evaluation order is derived from `connections`.
@export var nodes: Array[Pasture3DGraphNode] = []:
	set(v):
		_bind_nodes(nodes, false)
		nodes = v
		_bind_nodes(nodes, true)
		structure_changed.emit()
		if output_index() >= 0:
			emit_changed()

## The wires, each a PackedInt32Array `[from_node, from_port, to_node, to_port]` (indices into `nodes`).
## `from_port` is reserved for multi-output nodes (always 0 today); `to_port` is the destination input
## port. Set programmatically here and by the later GraphEdit UI, so it is a plain untyped Array of
## fixed-shape rows rather than an inspector-edited field.
@export var connections: Array = []:
	set(v):
		connections = v
		structure_changed.emit()
		emit_changed()

## Index into `nodes` of the node whose grid is the graph's output. -1 (or out of range) = no output, and
## `evaluate` returns a flat 0 field rather than guessing.
@export var output_node: int = -1:
	set(v):
		output_node = v
		structure_changed.emit()
		emit_changed()

## Temporary editor solo preview override (-1 = normal graph output). When set >= 0, evaluate() routes
## this node's output to the 3D viewport without mutating the permanent saved output.
@export var output_override: int = -1:
	set(v):
		output_override = v
		structure_changed.emit()
		emit_changed()

## Comment and grouping boxes organizing subsets of nodes on the visual canvas.
@export var frames: Array = []:
	set(v):
		_bind_frames(frames, false)
		frames = v
		_bind_frames(frames, true)
		structure_changed.emit()

# ---- Cache Memory Management (Milestone 1) -----------------------------------------------------------
## Maximum total memory in bytes allowed for per-node cached output grids (default 256 MB).
@export var max_cache_bytes: int = 268435456

var _global_access_tick: int = 0


## Clears all cached output grid buffers across every node in the graph.
func clear_cache() -> void:
	for n in nodes:
		if n != null:
			n.clear_cache()


## Total memory footprint in bytes across all node cached grid buffers in this graph.
func get_total_cache_bytes() -> int:
	var total := 0
	for n in nodes:
		if n != null:
			total += n.get_cache_size_bytes()
	return total


## Evicts least-recently-accessed node caches until total memory footprint is <= max_cache_bytes.
func _evict_cache_if_needed() -> void:
	if max_cache_bytes <= 0:
		return
	if get_total_cache_bytes() <= max_cache_bytes:
		return
	
	var cached_nodes: Array[Pasture3DGraphNode] = []
	for n in nodes:
		if n != null and not n.get_cached_grid().is_empty():
			cached_nodes.append(n)
			
	cached_nodes.sort_custom(func(a: Pasture3DGraphNode, b: Pasture3DGraphNode) -> bool:
		return a._last_access_tick < b._last_access_tick
	)
	
	for n in cached_nodes:
		n.clear_cache()
		if get_total_cache_bytes() <= max_cache_bytes:
			break



# ---- Change forwarding -------------------------------------------------------------------------------
#
# A node's own property setters emit `changed` on the node; the graph checks if that node feeds the active
# output. If connected, the graph re-emits `changed` so the host brush re-bakes. If disconnected, only
# `node_updated` is fired to update local canvas previews without triggering unnecessary terrain bakes.

func _bind_nodes(p_list: Array, p_connect: bool) -> void:
	for n in p_list:
		if n == null:
			continue
		if p_connect:
			if not n.changed.is_connected(_on_node_changed):
				n.changed.connect(_on_node_changed.bind(n))
		elif n.changed.is_connected(_on_node_changed):
			n.changed.disconnect(_on_node_changed)


func _on_node_changed(p_node: Pasture3DGraphNode = null) -> void:
	var n_idx := -1
	if p_node != null:
		n_idx = nodes.find(p_node)
	
	var affects_output := true
	if n_idx >= 0:
		var downstream := get_downstream_nodes(n_idx)
		var out_idx := output_index()
		if out_idx >= 0:
			affects_output = downstream.has(out_idx)
		node_updated.emit(n_idx, downstream)
	
	if affects_output:
		emit_changed()


## Returns all downstream node indices that depend on `p_start_node` (including `p_start_node` itself).
func get_downstream_nodes(p_start_node: int) -> Array[int]:
	var result: Array[int] = [p_start_node]
	var frontier: Array[int] = [p_start_node]
	var visited := {p_start_node: true}
	while not frontier.is_empty():
		var cur: int = frontier.pop_back()
		for c in connections:
			if c.size() >= 4 and int(c[0]) == cur:
				var to := int(c[2])
				if to >= 0 and to < nodes.size() and not visited.has(to):
					visited[to] = true
					result.append(to)
					frontier.push_back(to)
	return result


func _bind_frames(p_list: Array, p_connect: bool) -> void:
	for f in p_list:
		if f == null:
			continue
		if p_connect:
			if not f.changed.is_connected(_on_frame_changed):
				f.changed.connect(_on_frame_changed)
		elif f.changed.is_connected(_on_frame_changed):
			f.changed.disconnect(_on_frame_changed)


func _on_frame_changed() -> void:
	structure_changed.emit()


## Monotonic content revision, bumped on every `changed` (any node param, wiring, or output). A host's
## frozen cache stores the revision it baked at; a served entry whose revision differs is stale. Absolute
## value does not matter — only that it changes on an edit — so resetting to 0 on reload is fine, because
## the in-memory cache is empty then too.
var _revision: int = 0


func _init() -> void:
	changed.connect(func(): _revision += 1)


## The current content revision — a host reads this as the staleness key for a frozen bake.
func content_key() -> int:
	return _revision


# ---- Editing API -------------------------------------------------------------------------------------
#
# The seam the graph editor drives and the gate tests. Every mutation keeps `connections` and
# `output_node` consistent with `nodes` and emits `changed`. Reassigning `nodes`/`connections` goes
# through their setters, so binding and the emit happen there.

## Append a node at `p_pos` and return its index.
func add_node(p_node: Pasture3DGraphNode, p_pos: Vector2 = Vector2.ZERO) -> int:
	if p_node == null:
		return -1
	p_node.graph_position = p_pos
	var arr := nodes.duplicate()
	arr.append(p_node)
	nodes = arr
	return nodes.size() - 1


## Remove the node at `p_index`: drop every connection touching it, shift indices above it down by one,
## follow `output_node`, and update frame attachments.
func remove_node(p_index: int) -> void:
	if p_index < 0 or p_index >= nodes.size():
		return
	var remapped: Array = []
	for c in connections:
		var f := int(c[0])
		var t := int(c[2])
		if f == p_index or t == p_index:
			continue
		remapped.append(PackedInt32Array([
			f - 1 if f > p_index else f, int(c[1]),
			t - 1 if t > p_index else t, int(c[3])]))
	if output_node == p_index:
		output_node = -1
	elif output_node > p_index:
		output_node = output_node - 1
		
	if output_override == p_index:
		output_override = -1
	elif output_override > p_index:
		output_override = output_override - 1
	connections = remapped
	
	# Remap frame attached indices
	for f in frames:
		if f != null:
			var new_attached := PackedInt32Array()
			for idx in f.attached_node_indices:
				if idx == p_index:
					continue
				new_attached.append(idx - 1 if idx > p_index else idx)
			f.attached_node_indices = new_attached
			
	var arr := nodes.duplicate()
	arr.remove_at(p_index)
	nodes = arr


## Append a frame and return its index.
func add_frame(p_frame: Resource) -> int:
	if p_frame == null:
		return -1
	var arr := frames.duplicate()
	arr.append(p_frame)
	frames = arr
	return frames.size() - 1


## Remove the frame at `p_index`.
func remove_frame(p_index: int) -> void:
	if p_index < 0 or p_index >= frames.size():
		return
	var arr := frames.duplicate()
	arr.remove_at(p_index)
	frames = arr


## Groups the specified node indices into a new GraphFrame bounding them. Returns frame index.
func group_nodes_in_frame(p_indices: Array, p_title: String = "Group", p_tint: Color = Color(0.2, 0.25, 0.35, 0.75)) -> int:
	var valid_indices: Array[int] = []
	var min_pos := Vector2(INF, INF)
	var max_pos := Vector2(-INF, -INF)
	
	for idx in p_indices:
		var i := int(idx)
		if i >= 0 and i < nodes.size() and nodes[i] != null:
			valid_indices.append(i)
			var pos: Vector2 = nodes[i].graph_position
			min_pos = min_pos.min(pos)
			max_pos = max_pos.max(pos + Vector2(200, 100))
			
	var frame_pos: Vector2 = min_pos - Vector2(30, 40) if not is_inf(min_pos.x) else Vector2(100, 100)
	var frame_size: Vector2 = (max_pos - min_pos) + Vector2(60, 80) if not is_inf(min_pos.x) else Vector2(320, 240)
	frame_size = frame_size.max(Vector2(200, 140))
	
	var fd = FrameDataScript.new()
	fd.title = p_title
	fd.tint_color = p_tint
	fd.position_offset = frame_pos
	fd.size = frame_size
	fd.attached_node_indices = PackedInt32Array(valid_indices)
	return add_frame(fd)


## Splits an existing connection `(from:from_port -> to:to_port)` by inserting `p_node` at `p_pos`.
## Returns the newly inserted node's index. Performs insertion and rewiring atomically.
func split_connection_with_node(p_from: int, p_from_port: int, p_to: int, p_to_port: int, p_node: Pasture3DGraphNode, p_pos: Vector2) -> int:
	p_node.graph_position = p_pos
	var arr := nodes.duplicate()
	arr.append(p_node)
	var new_idx := arr.size() - 1
	
	var new_conns: Array = []
	for c in connections:
		if int(c[0]) == p_from and int(c[1]) == p_from_port \
				and int(c[2]) == p_to and int(c[3]) == p_to_port:
			continue
		new_conns.append(c)
	new_conns.append(PackedInt32Array([p_from, p_from_port, new_idx, 0]))
	new_conns.append(PackedInt32Array([new_idx, 0, p_to, p_to_port]))
	
	_bind_nodes([p_node], true)
	nodes = arr
	connections = new_conns
	return new_idx


## Wire `from`:`from_port` -> `to`:`to_port`. An input port takes ONE wire, so any existing wire into
## `(to, to_port)` is replaced.
func connect_ports(p_from: int, p_from_port: int, p_to: int, p_to_port: int) -> void:
	var arr: Array = []
	for c in connections:
		if int(c[2]) == p_to and int(c[3]) == p_to_port:
			continue
		arr.append(c)
	arr.append(PackedInt32Array([p_from, p_from_port, p_to, p_to_port]))
	connections = arr


## Remove exactly the wire `from`:`from_port` -> `to`:`to_port`, if present.
func disconnect_ports(p_from: int, p_from_port: int, p_to: int, p_to_port: int) -> void:
	var arr: Array = []
	for c in connections:
		if int(c[0]) == p_from and int(c[1]) == p_from_port \
				and int(c[2]) == p_to and int(c[3]) == p_to_port:
			continue
		arr.append(c)
	connections = arr


## Designate the graph's output node (-1 = none). Also toggles solo preview override.
func set_output(p_index: int) -> void:
	if p_index >= -1 and p_index < nodes.size():
		if output_override == p_index:
			output_override = -1
		else:
			output_override = p_index
		output_node = p_index


## Returns all connections touching `p_index` ([from, from_port, to, to_port]).
func get_node_connections(p_index: int) -> Array:
	var result: Array = []
	for c in connections:
		if int(c[0]) == p_index or int(c[2]) == p_index:
			result.append(c)
	return result


## Serializes a subset of nodes and their internal connecting wires into a clipboard dictionary.
func serialize_subgraph(p_indices: Array) -> Dictionary:
	var valid_indices: Array[int] = []
	for idx in p_indices:
		var i := int(idx)
		if i >= 0 and i < nodes.size() and nodes[i] != null and not valid_indices.has(i):
			valid_indices.append(i)
	if valid_indices.is_empty():
		return {"nodes": [], "connections": [], "center": Vector2.ZERO}
	
	var cloned_nodes: Array[Pasture3DGraphNode] = []
	var center_accum := Vector2.ZERO
	for i in valid_indices:
		var cloned: Pasture3DGraphNode = nodes[i].duplicate(true)
		cloned.graph_position = nodes[i].graph_position
		center_accum += nodes[i].graph_position
		cloned_nodes.append(cloned)
	var center := center_accum / float(valid_indices.size())
	
	var internal_wires: Array = []
	for c in connections:
		var f := int(c[0])
		var t := int(c[2])
		var local_f := valid_indices.find(f)
		var local_t := valid_indices.find(t)
		if local_f != -1 and local_t != -1:
			internal_wires.append(PackedInt32Array([local_f, int(c[1]), local_t, int(c[3])]))
			
	return {
		"nodes": cloned_nodes,
		"connections": internal_wires,
		"center": center,
	}


## Deserializes subgraph data into the graph. If `p_at_position` is provided, positions are offset relative
## to the data's center. Returns the newly created global node indices.
func deserialize_subgraph(p_data: Dictionary, p_at_position: Vector2 = Vector2.INF) -> Array[int]:
	var input_nodes: Array = p_data.get("nodes", [])
	var input_wires: Array = p_data.get("connections", [])
	var original_center: Vector2 = p_data.get("center", Vector2.ZERO)
	if input_nodes.is_empty():
		return []
	
	var offset := Vector2.ZERO
	if not is_inf(p_at_position.x) and not is_inf(p_at_position.y):
		offset = p_at_position - original_center
		
	var new_indices: Array[int] = []
	for n in input_nodes:
		if n is Pasture3DGraphNode:
			var cloned: Pasture3DGraphNode = n.duplicate(true)
			var new_pos: Vector2 = n.graph_position + offset
			var idx := add_node(cloned, new_pos)
			new_indices.append(idx)
			
	for w in input_wires:
		if w.size() >= 4:
			var local_f := int(w[0])
			var local_t := int(w[2])
			if local_f >= 0 and local_f < new_indices.size() and local_t >= 0 and local_t < new_indices.size():
				connect_ports(new_indices[local_f], int(w[1]), new_indices[local_t], int(w[3]))
				
	return new_indices


## Duplicates selected nodes and internal connecting wires by `p_offset`. Returns new global indices.
func duplicate_subgraph(p_indices: Array, p_offset: Vector2 = Vector2(40, 40)) -> Array[int]:
	var serialized := serialize_subgraph(p_indices)
	if serialized["nodes"].is_empty():
		return []
	for n in serialized["nodes"]:
		n.graph_position += p_offset
	return deserialize_subgraph(serialized, Vector2.INF)



## The EFFECTIVE output node the evaluator returns: an explicit solo override (if set), else an explicit
## Output node (op &"output"), else the designated `output_node`.
func output_index() -> int:
	if output_override >= 0 and output_override < nodes.size() and nodes[output_override] != null:
		return output_override
	for i in range(nodes.size()):
		if nodes[i] != null and nodes[i].op() == &"output":
			return i
	return output_node


## True when an Input node feeds the output — the graph is a FILTER whose result depends on the surface it
## is handed, not a pure generator. A host reads this to decide whether its frozen cache must key on that
## surface: an Input-reading graph re-evaluates when the surface changes, a generator does not.
func reads_input() -> bool:
	for ni in _eval_order():
		if nodes[ni] != null and nodes[ni].op() == &"input":
			return true
	return false


## A fresh graph pre-populated with an Input → Output pair, wired together — the standard starting point a
## host hands the user instead of a blank canvas. As built it is the IDENTITY (Output passes the surface
## straight through), so it changes nothing until nodes are inserted between the two. Laid out left-to-right
## so the Add-node flow drops new nodes into the gap.
static func create_default() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var input := Pasture3DGraphNodeInput.new()
	input.graph_position = Vector2(40.0, 80.0)
	var output := Pasture3DGraphNodeOutput.new()
	output.graph_position = Vector2(420.0, 80.0)
	var nodes: Array[Pasture3DGraphNode] = [input, output]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 1, 0])] # Input.out -> Output.result
	return g


## Map a cell to its WORLD XZ. Cell-CENTRE sampling over `p_rect` (position = min XZ, size = extent).
## Static so the graph and any oracle sample the identical point — a mapping disagreement would look like
## a solver bug. `dx = size / count`, `w = min + (i + 0.5) * dx`.
static func cell_to_world(p_ix: int, p_iz: int, p_gw: int, p_gh: int, p_rect: Rect2) -> Vector2:
	var dx := p_rect.size.x / float(maxi(p_gw, 1))
	var dz := p_rect.size.y / float(maxi(p_gh, 1))
	return Vector2(p_rect.position.x + (float(p_ix) + 0.5) * dx,
			p_rect.position.y + (float(p_iz) + 0.5) * dz)


## Evaluate the graph to a `p_gw * p_gh` row-major height field over `p_rect` (world XZ). `p_mask` is an
## optional [0,1] grid handed to grid nodes; it is NOT applied globally — where a graph's result lands is
## the host's concern. A missing output or a cycle yields a flat 0 field.
##
## Uses the CELL-NODE FOLD: a run of cell nodes is evaluated INLINE in one loop rather than materialising
## a grid per node — the same optimisation the brush node stack makes. Only a grid node, the OUTPUT, a
## node that fans out to more than one consumer, and a node feeding a grid node get a materialised grid; a
## cell node consumed once by another cell node folds into that consumer's loop, saving an allocation and
## a pass. `_eval_unfolded` is the reference this matches (to float32 rounding — the fold keeps
## intermediates in double, so it is in fact slightly more accurate); GraphFoldGate holds the two together.
func evaluate(p_gw: int, p_gh: int, p_rect: Rect2, p_mask = null, p_input = null, p_root_node: int = -1) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var out := p_root_node if (p_root_node >= 0 and p_root_node < nodes.size()) else output_index()
	if out < 0 or out >= nodes.size() or nodes[out] == null:
		return Pasture3DGraphOps.zeros(n)
	var plan := _fold_plan(out)
	var order: Array = plan["order"]
	if order.is_empty(): # unreachable output or a cycle
		return Pasture3DGraphOps.zeros(n)
	var inputs_of: Dictionary = plan["inputs_of"]
	var input_ports_of: Dictionary = plan["input_ports_of"]
	var materialize: Dictionary = plan["materialize"]

	_global_access_tick += 1

	var dx := p_rect.size.x / float(maxi(p_gw, 1))
	var dz := p_rect.size.y / float(maxi(p_gh, 1))
	var min_x := p_rect.position.x + 0.5 * dx
	var min_z := p_rect.position.y + 0.5 * dz

	var grids := {} # node index -> materialised grid (port 0)
	var aux := {}   # node index -> { output_port >= 1 : grid } for multi-output solver channels
	for ni in order:
		var node: Pasture3DGraphNode = nodes[ni]
		var inputs_hash: int = _compute_node_inputs_hash(ni, p_gw, p_gh, p_rect, p_mask, p_input, inputs_of, input_ports_of)

		# Cache hit check: if clean and matching size, serve cached grid in 0.0 ms
		if not node.is_dirty(inputs_hash) and node.get_cached_grid().size() == n:
			grids[ni] = node.get_cached_grid()
			var c_aux := node.get_cached_aux()
			if not c_aux.is_empty():
				aux[ni] = c_aux
			node._last_access_tick = _global_access_tick
			continue

		if node.muted:
			var s0: int = inputs_of[ni][0] if not inputs_of[ni].is_empty() else -1
			var sp0: int = input_ports_of[ni][0] if not input_ports_of[ni].is_empty() else 0
			if s0 < 0:
				grids[ni] = Pasture3DGraphOps.zeros(n)
			elif sp0 > 0 or grids.has(s0):
				grids[ni] = _read_channel(s0, sp0, grids, aux, n).duplicate()
			else:
				var g := PackedFloat32Array()
				g.resize(n)
				for iz in range(p_gh):
					var row := iz * p_gw
					var wz: float = min_z + float(iz) * dz
					for ix in range(p_gw):
						var wx: float = min_x + float(ix) * dx
						g[row + ix] = _cell_input(s0, sp0, row + ix, wx, wz, grids, aux, inputs_of, input_ports_of)
				grids[ni] = g
		elif node.op() == &"input":
			grids[ni] = _surface_grid(p_input, n) # the surface handed in, or a flat 0 when none
		elif node.op() == &"output":
			var s0: int = inputs_of[ni][0] if not inputs_of[ni].is_empty() else -1
			var sp0: int = input_ports_of[ni][0] if not input_ports_of[ni].is_empty() else 0
			grids[ni] = _read_channel(s0, sp0, grids, aux, n).duplicate()
		elif node.needs_grid():
			var in_grids := _input_grids(ni, grids, aux, n)
			if node.output_count() > 1:
				var chans: Array = node.eval_grid_channels(in_grids, p_gw, p_gh, p_mask, p_rect)
				grids[ni] = chans[0]
				var ax := {}
				for pi in range(1, chans.size()):
					ax[pi] = chans[pi]
				aux[ni] = ax
			else:
				grids[ni] = node.eval_grid(in_grids, p_gw, p_gh, p_mask, p_rect)
		else:
			var g := PackedFloat32Array()
			g.resize(n)
			var in_grids := _input_grids(ni, grids, aux, n)
			var in_count: int = in_grids.size()
			var cell_in := PackedFloat32Array()
			cell_in.resize(in_count)
			if in_count == 1:
				var in0: PackedFloat32Array = in_grids[0]
				for iz in range(p_gh):
					var row := iz * p_gw
					var wz: float = min_z + float(iz) * dz
					for ix in range(p_gw):
						var idx := row + ix
						var wx: float = min_x + float(ix) * dx
						cell_in[0] = in0[idx]
						g[idx] = node.eval_cell(wx, wz, cell_in)
			elif in_count == 0:
				for iz in range(p_gh):
					var row := iz * p_gw
					var wz: float = min_z + float(iz) * dz
					for ix in range(p_gw):
						var idx := row + ix
						var wx: float = min_x + float(ix) * dx
						g[idx] = node.eval_cell(wx, wz, cell_in)
			else:
				for iz in range(p_gh):
					var row := iz * p_gw
					var wz: float = min_z + float(iz) * dz
					for ix in range(p_gw):
						var idx := row + ix
						var wx: float = min_x + float(ix) * dx
						for p in range(in_count):
							cell_in[p] = (in_grids[p] as PackedFloat32Array)[idx]
						g[idx] = node.eval_cell(wx, wz, cell_in)
			grids[ni] = g

		node.store_cache(grids[ni], aux.get(ni, {}), inputs_hash, _global_access_tick)
		_evict_cache_if_needed()

	return grids[out]


## Computes a signature hash representing node inputs, wiring, and spatial evaluation context.
func _compute_node_inputs_hash(p_ni: int, p_gw: int, p_gh: int, p_rect: Rect2, p_mask, p_input, p_inputs_of: Dictionary, p_input_ports_of: Dictionary, p_materialize: Dictionary = {}) -> int:
	var node: Pasture3DGraphNode = nodes[p_ni]
	var sig: Array = [
		p_gw,
		p_gh,
		p_rect.position.x,
		p_rect.position.y,
		p_rect.size.x,
		p_rect.size.y,
		node.muted,
		node.op(),
	]
	if node.op() == &"input":
		if p_input is PackedFloat32Array:
			sig.append(p_input.size())
			if not p_input.is_empty():
				sig.append(p_input[0])
				sig.append(p_input[p_input.size() - 1])
		else:
			sig.append(0)
	if node.needs_grid() and p_mask != null:
		if p_mask is PackedFloat32Array:
			sig.append(p_mask.size())
			if not p_mask.is_empty():
				sig.append(p_mask[0])
				sig.append(p_mask[p_mask.size() - 1])

	var srcs: Array = p_inputs_of.get(p_ni, [])
	var ports: Array = p_input_ports_of.get(p_ni, [])
	for p in range(srcs.size()):
		var s: int = srcs[p]
		var sp: int = ports[p]
		if s < 0 or s >= nodes.size() or nodes[s] == null:
			sig.append(-1)
			sig.append(node.input_unwired_default(p))
		else:
			_append_input_signature(s, sp, sig, p_inputs_of, p_input_ports_of, p_materialize)
	return hash(sig)


func _append_input_signature(p_s: int, p_sp: int, p_sig: Array, p_inputs_of: Dictionary, p_input_ports_of: Dictionary, p_materialize: Dictionary) -> void:
	if p_s < 0 or p_s >= nodes.size() or nodes[p_s] == null:
		p_sig.append(-1)
		return
	var src_node: Pasture3DGraphNode = nodes[p_s]
	p_sig.append(p_s)
	p_sig.append(p_sp)
	p_sig.append(src_node.muted)
	p_sig.append(src_node._dirty_revision)
	if p_materialize.get(p_s, true):
		p_sig.append(src_node._inputs_hash)
	else:
		# Folded upstream node: recurse into its inputs
		var srcs: Array = p_inputs_of.get(p_s, [])
		var ports: Array = p_input_ports_of.get(p_s, [])
		for p in range(srcs.size()):
			var sub_s: int = srcs[p]
			var sub_sp: int = ports[p]
			if sub_s < 0 or sub_s >= nodes.size() or nodes[sub_s] == null:
				p_sig.append(-1)
				p_sig.append(src_node.input_unwired_default(p))
			else:
				_append_input_signature(sub_s, sub_sp, p_sig, p_inputs_of, p_input_ports_of, p_materialize)


func _cell_value_fast(p_ni: int, p_cell: int, p_wx: float, p_wz: float, p_grids: Dictionary, p_aux: Dictionary,
		p_inputs_of: Dictionary, p_ports_of: Dictionary, p_cell_in: PackedFloat32Array) -> float:
	if p_grids.has(p_ni):
		return (p_grids[p_ni] as PackedFloat32Array)[p_cell]
	var node: Pasture3DGraphNode = nodes[p_ni]
	var srcs: Array = p_inputs_of[p_ni]
	var ports: Array = p_ports_of[p_ni]
	if node.muted:
		if srcs.is_empty() or srcs[0] < 0:
			return 0.0
		return _cell_input(srcs[0], ports[0], p_cell, p_wx, p_wz, p_grids, p_aux, p_inputs_of, p_ports_of)
	for k in range(srcs.size()):
		if srcs[k] < 0:
			p_cell_in[k] = node.input_unwired_default(k)
		else:
			p_cell_in[k] = _cell_input(srcs[k], ports[k], p_cell, p_wx, p_wz, p_grids, p_aux, p_inputs_of, p_ports_of)
	return node.eval_cell(p_wx, p_wz, p_cell_in)




## The grid an Input node yields: a COPY of the surface handed to `evaluate`, or a flat 0 when none was
## (or its size does not match the grid). Copied so a downstream grid node mutating it in place cannot
## corrupt the host's working surface.
func _surface_grid(p_input, p_n: int) -> PackedFloat32Array:
	if p_input is PackedFloat32Array and (p_input as PackedFloat32Array).size() == p_n:
		return (p_input as PackedFloat32Array).duplicate()
	return Pasture3DGraphOps.zeros(p_n)


## A cell node's value at one cell, folding unmaterialised cell inputs inline. A materialised node (a grid
## node, or a materialised cell node) is read from its grid; a folded input recurses. `p_cell` is the
## row-major index; `p_wx`/`p_wz` the world XZ.
func _cell_value(p_ni: int, p_cell: int, p_wx: float, p_wz: float, p_grids: Dictionary, p_aux: Dictionary,
		p_inputs_of: Dictionary, p_ports_of: Dictionary) -> float:
	if p_grids.has(p_ni):
		return (p_grids[p_ni] as PackedFloat32Array)[p_cell]
	var node: Pasture3DGraphNode = nodes[p_ni]
	var srcs: Array = p_inputs_of[p_ni]
	var ports: Array = p_ports_of[p_ni]
	if node.muted:
		if srcs.is_empty() or srcs[0] < 0:
			return 0.0
		return _cell_input(srcs[0], ports[0], p_cell, p_wx, p_wz, p_grids, p_aux, p_inputs_of, p_ports_of)
	var cell_in := PackedFloat32Array()
	cell_in.resize(srcs.size())
	for k in range(srcs.size()):
		if srcs[k] < 0:
			cell_in[k] = node.input_unwired_default(k)
		else:
			cell_in[k] = _cell_input(srcs[k], ports[k], p_cell, p_wx, p_wz, p_grids, p_aux, p_inputs_of, p_ports_of)
	return node.eval_cell(p_wx, p_wz, cell_in)


## One input value at a cell: an unwired source reads 0; a port >= 1 reads a materialised multi-output
## channel directly out of `p_aux`; a port-0 source recurses (folding an unmaterialised cell run inline, or
## reading a materialised source's primary grid).
func _cell_input(p_src: int, p_port: int, p_cell: int, p_wx: float, p_wz: float, p_grids: Dictionary,
		p_aux: Dictionary, p_inputs_of: Dictionary, p_ports_of: Dictionary) -> float:
	if p_src < 0:
		return 0.0
	if p_port > 0:
		if p_aux.has(p_src) and (p_aux[p_src] as Dictionary).has(p_port):
			return (p_aux[p_src][p_port] as PackedFloat32Array)[p_cell]
		return 0.0
	return _cell_value(p_src, p_cell, p_wx, p_wz, p_grids, p_aux, p_inputs_of, p_ports_of)


## The fold plan for the output's ancestry: the topo `order`, each node's input source per port
## (`inputs_of`, -1 = unwired), and which nodes MATERIALISE (`materialize`). A node materialises if it is a
## grid node, the output, fans out to more than one consumer, or feeds a grid node; every other cell node
## folds. Exposed for GraphFoldGate.
func _fold_plan(p_root: int = -1) -> Dictionary:
	var out := p_root if (p_root >= 0 and p_root < nodes.size()) else output_index()
	var order := _eval_order(out)
	var needed := {}
	for ni in order:
		needed[ni] = true
	var inputs_of := {}
	var input_ports_of := {}
	for ni in order:
		var arr: Array = []
		arr.resize(nodes[ni].input_count())
		arr.fill(-1)
		inputs_of[ni] = arr
		var parr: Array = []
		parr.resize(nodes[ni].input_count())
		parr.fill(0)
		input_ports_of[ni] = parr
	for c in connections:
		if c.size() >= 4:
			var to := int(c[2])
			var from := int(c[0])
			if needed.has(to) and needed.has(from):
				var tp := int(c[3])
				if tp >= 0 and tp < (inputs_of[to] as Array).size():
					inputs_of[to][tp] = from
					input_ports_of[to][tp] = int(c[1])
	var fanout := {}
	var grid_consumer := {}
	for ni in order:
		fanout[ni] = 0
		grid_consumer[ni] = false
	for ni in order:
		for s in inputs_of[ni]:
			if s >= 0 and needed.has(s):
				fanout[s] += 1
				if nodes[ni].needs_grid():
					grid_consumer[s] = true
	var materialize := {}
	for ni in order:
		materialize[ni] = nodes[ni].needs_grid() or ni == out \
				or fanout[ni] > 1 or grid_consumer[ni]
	return {"order": order, "inputs_of": inputs_of, "input_ports_of": input_ports_of,
			"materialize": materialize}


## Lower a CELL-ONLY graph into the flat SSA program the native evaluator reads
## (Pasture3DUtil.graph_cell_eval_grid; C++ side pasture_3d_graph_ops). One instruction per node in
## topological order, so an instruction's inputs are always lower-numbered slots. Returns {} — meaning
## "not lowerable, stay on the GDScript path" — when the output is missing, its ancestry has a cycle, or it
## contains ANY grid node (a neighbour-reading pass like Smooth cannot fold into a per-cell loop). That is
## exactly the fold's cell-run scope (§6): the native path optimises the cell runs, and `evaluate` remains
## the oracle it must match. A node whose op the native evaluator does not know also returns {} rather than
## a program the two sides would read differently.
##
## Program keys, all parallel and one entry per slot except `output`:
##   ops     [int]   GraphCellOpType — 1 noise, 2 const, 3 blend (a WIRE FORMAT shared with C++)
##   params  [float] one scalar per slot: amplitude (noise) / value (const) / mode (blend)
##   in_a    [int]   input-A source slot, or -1 for an unwired port (reads 0)
##   in_b    [int]   input-B source slot (blend only), or -1
##   noise   [Variant] the slot's FastNoiseLite (noise ops) or null — passed as-is, never rebuilt, so the
##                   two evaluators cannot disagree on the noise
##   output  int     the slot whose value is the graph output
func compile_cell_program() -> Dictionary:
	var out := output_index()
	if out < 0 or out >= nodes.size() or nodes[out] == null:
		return {}
	var order := _eval_order()
	if order.is_empty():
		return {}
	var slot_of := {}
	for k in range(order.size()):
		slot_of[order[k]] = k
	var inputs_of: Dictionary = _fold_plan()["inputs_of"] # node -> [source node per port, -1 unwired]
	var ops := PackedInt32Array()
	var params := PackedFloat32Array()
	var params_b := PackedFloat32Array()
	var params_c := PackedFloat32Array()
	var params_d := PackedFloat32Array()
	var in_a := PackedInt32Array()
	var in_b := PackedInt32Array()
	var noise_tab: Array = []
	for ni in order:
		var node: Pasture3DGraphNode = nodes[ni]
		if node.needs_grid():
			return {} # a grid node cannot fold into a per-cell run — stay on the GDScript path
		var srcs: Array = inputs_of[ni]
		var sa: int = int(srcs[0]) if srcs.size() > 0 else -1
		var sb: int = int(srcs[1]) if srcs.size() > 1 else -1
		var op_id := 0
		var param := 0.0
		var pb := 0.0
		var pc := 0.0
		var pd := 0.0
		var nz = null
		match node.op():
			&"noise":
				op_id = 1; param = float(node.get("amplitude")); nz = node.get("noise")
			&"const":
				op_id = 2; param = float(node.get("value"))
			&"blend":
				if srcs.size() > 2 and int(srcs[2]) >= 0:
					return {} # a masked blend is 3-input; the native cell evaluator only reads a & b
				op_id = 3; param = float(int(node.get("mode")))
			&"terrace":
				op_id = 4
				param = float(node.get("band_height"))
				pb = float(node.get("hardness"))
				pc = float(node.get("amount"))
				pd = float(node.get("jitter"))
				if pd > 0.0 and node.has_method("_jitter_field"):
					nz = node.call("_jitter_field")
			_:
				return {} # an op the native cell evaluator does not implement
		ops.append(op_id)
		params.append(param)
		params_b.append(pb)
		params_c.append(pc)
		params_d.append(pd)
		noise_tab.append(nz)
		# Generators have no inputs; -1 there is harmless (the native evaluator only reads a blend's ports).
		in_a.append(int(slot_of[sa]) if sa >= 0 else -1)
		in_b.append(int(slot_of[sb]) if sb >= 0 else -1)
	return {
		"ops": ops, "params": params, "params_b": params_b, "params_c": params_c, "params_d": params_d,
		"in_a": in_a, "in_b": in_b,
		"noise": noise_tab, "output": int(slot_of[out]),
	}


## Lower the WHOLE graph — any node types — into the flat program the native evaluator materialises node by
## node (`Pasture3DUtil.graph_eval_grid`; C++ `pasture_3d_graph_ops`). One slot per node in topological
## order, so a slot's inputs are always earlier slots. This is the materialise-every-node analogue of
## `_eval_unfolded` (which `evaluate`, the folded path, matches to float32 rounding); the native side does
## not fold, so it mirrors the unfolded reference. Returns {} — "stay on the GDScript path" — for a missing
## or cyclic output, or a node whose op the native evaluator does not implement.
##
## Program keys, all parallel and one entry per slot except `output`:
##   ops      [int]     GraphCellOpType — 1 noise, 2 const, 3 blend, 4 terrace, 10 input, 11 smooth, 12 output
##   params   [float]   amplitude | value | blend-mode | smooth-passes | band_height
##   params_b [float]   hardness
##   params_c [float]   amount
##   params_d [float]   jitter
##   in0      [int]     first input's source slot, or -1 unwired
##   in1      [int]     second input's source slot (blend only), or -1
##   noise    [Variant] the slot's FastNoiseLite (noise/jitter ops) or null — passed as-is, never rebuilt
##   output   int       the slot whose grid is the graph output
func compile_graph_program() -> Dictionary:
	var out := output_index()
	if out < 0 or out >= nodes.size() or nodes[out] == null:
		return {}
	var order := _eval_order()
	if order.is_empty():
		return {}
	var slot_of := {}
	for k in range(order.size()):
		slot_of[order[k]] = k
	var inputs_of: Dictionary = _fold_plan()["inputs_of"] # node -> [source node per port, -1 unwired]
	var ops := PackedInt32Array()
	var params := PackedFloat32Array()
	var params_b := PackedFloat32Array()
	var params_c := PackedFloat32Array()
	var params_d := PackedFloat32Array()
	var in0 := PackedInt32Array()
	var in1 := PackedInt32Array()
	var noise_tab: Array = []
	for ni in order:
		var node: Pasture3DGraphNode = nodes[ni]
		var srcs: Array = inputs_of[ni]
		var s0: int = int(srcs[0]) if srcs.size() > 0 else -1
		var s1: int = int(srcs[1]) if srcs.size() > 1 else -1
		var op_id := 0
		var param := 0.0
		var pb := 0.0
		var pc := 0.0
		var pd := 0.0
		var nz = null
		match node.op():
			&"input":
				op_id = 10
			&"noise":
				op_id = 1; param = float(node.get("amplitude")); nz = node.get("noise")
			&"const":
				op_id = 2; param = float(node.get("value"))
			&"blend":
				if srcs.size() > 2 and int(srcs[2]) >= 0:
					return {} # a masked blend is 3-input; the native whole-graph evaluator reads only in0/in1
				op_id = 3; param = float(int(node.get("mode")))
			&"terrace":
				op_id = 4
				param = float(node.get("band_height"))
				pb = float(node.get("hardness"))
				pc = float(node.get("amount"))
				pd = float(node.get("jitter"))
				if pd > 0.0 and node.has_method("_jitter_field"):
					nz = node.call("_jitter_field")
			&"smooth":
				op_id = 11; param = float(int(node.get("passes")))
			&"output":
				op_id = 12
			_:
				return {} # an op the native evaluator does not implement
		ops.append(op_id)
		params.append(param)
		params_b.append(pb)
		params_c.append(pc)
		params_d.append(pd)
		noise_tab.append(nz)
		in0.append(int(slot_of[s0]) if s0 >= 0 else -1)
		in1.append(int(slot_of[s1]) if s1 >= 0 else -1)
	return {
		"ops": ops, "params": params, "params_b": params_b, "params_c": params_c, "params_d": params_d,
		"in0": in0, "in1": in1,
		"noise": noise_tab, "output": int(slot_of[out]),
	}


## True when every node feeding the output has an op the native whole-graph evaluator implements — i.e.
## `compile_graph_program()` would return a program, so the host can run this graph natively instead of
## forcing the GDScript rasteriser. Cheap structural check (no grids), for `_stack_forces_gdscript`.
func native_supported() -> bool:
	var out := output_index()
	if out < 0 or out >= nodes.size() or nodes[out] == null:
		return false
	var order := _eval_order()
	if order.is_empty():
		return false
	const SUPPORTED := [&"input", &"noise", &"const", &"blend", &"smooth", &"terrace", &"output"]
	for ni in order:
		if nodes[ni] == null or nodes[ni].muted or not SUPPORTED.has(nodes[ni].op()):
			return false
	# A Blend whose MASK port (2) is wired is a 3-input op the native evaluator reads as a plain 2-input
	# blend, so it must stay on the GDScript path where the mask is applied.
	if _has_masked_blend(order):
		return false
	return true


## True when a Blend node in `p_order` has its mask input (port 2) wired — the case the native lowering
## cannot represent. Scans connections rather than the fold plan so it is cheap enough for native_supported.
func _has_masked_blend(p_order: Array) -> bool:
	for c in connections:
		if c.size() >= 4 and int(c[3]) == 2:
			var to := int(c[2])
			if to >= 0 and to < nodes.size() and nodes[to] != null \
					and nodes[to].op() == &"blend" and p_order.has(to):
				return true
	return false


## The pre-fold reference: materialise EVERY node's grid (increment 1's evaluator). Kept as the oracle the
## folded `evaluate` is checked against — GraphFoldGate asserts they agree to float32 rounding.
func _eval_unfolded(p_gw: int, p_gh: int, p_rect: Rect2, p_mask = null, p_input = null) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var out := output_index()
	if out < 0 or out >= nodes.size() or nodes[out] == null:
		return Pasture3DGraphOps.zeros(n)
	var order := _eval_order()
	if order.is_empty():
		return Pasture3DGraphOps.zeros(n)
	var grids := {}
	var aux := {}
	for ni in order:
		var node: Pasture3DGraphNode = nodes[ni]
		if node.op() == &"input":
			grids[ni] = _surface_grid(p_input, n)
			continue
		var in_grids := _input_grids(ni, grids, aux, n)
		if node.muted:
			grids[ni] = (in_grids[0] as PackedFloat32Array) if not in_grids.is_empty() else Pasture3DGraphOps.zeros(n)
		elif node.needs_grid() and node.output_count() > 1:
			var chans: Array = node.eval_grid_channels(in_grids, p_gw, p_gh, p_mask, p_rect)
			grids[ni] = chans[0]
			var ax := {}
			for pi in range(1, chans.size()):
				ax[pi] = chans[pi]
			aux[ni] = ax
		elif node.needs_grid():
			grids[ni] = node.eval_grid(in_grids, p_gw, p_gh, p_mask, p_rect)
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
	return grids[out]


## The input grids for node `p_ni`, one per input port in port order; an unwired port reads zeros so a
## missing connection is a clean 0, not an error. Channel-aware: a connection from a multi-output source's
## port >= 1 reads that channel out of `p_aux[from]`, so a grid node can consume a solver's mask channel.
func _input_grids(p_ni: int, p_grids: Dictionary, p_aux: Dictionary, p_n: int) -> Array:
	var node: Pasture3DGraphNode = nodes[p_ni]
	var count: int = node.input_count()
	var out: Array = []
	out.resize(count)
	for p in range(count):
		var dv: float = node.input_unwired_default(p)
		out[p] = Pasture3DGraphOps.zeros(p_n) if is_zero_approx(dv) else Pasture3DGraphOps.filled(p_n, dv)
	for c in connections:
		if c.size() >= 4 and int(c[2]) == p_ni:
			var to_port := int(c[3])
			var from := int(c[0])
			var from_port := int(c[1])
			if to_port >= 0 and to_port < count:
				out[to_port] = _read_channel(from, from_port, p_grids, p_aux, p_n)
	return out


## One source node's output grid at `p_from_port`: port 0 comes from the materialised `p_grids` slot;
## a port >= 1 comes from `p_aux[p_from]` (a multi-output solver's derived channel). Reads zeros when the
## source has not materialised or lacks that channel, so a stale wire is a clean 0.
func _read_channel(p_from: int, p_from_port: int, p_grids: Dictionary, p_aux: Dictionary, p_n: int) -> PackedFloat32Array:
	if p_from_port <= 0:
		return p_grids[p_from] if p_grids.has(p_from) else Pasture3DGraphOps.zeros(p_n)
	if p_aux.has(p_from) and (p_aux[p_from] as Dictionary).has(p_from_port):
		return p_aux[p_from][p_from_port]
	return Pasture3DGraphOps.zeros(p_n)


## Topological order of exactly the nodes that feed the output (`output_index`). Empty if the output is
## unreachable or its ancestry contains a cycle (Kahn leaves nodes unresolved). Restricting to ancestors
## means a stray disconnected node neither runs nor breaks the sort.
func _eval_order(p_root: int = -1) -> Array:
	# 1. Ancestor set: walk connections backwards from the root.
	var root := p_root if (p_root >= 0 and p_root < nodes.size()) else output_index()
	if root < 0 or root >= nodes.size() or nodes[root] == null:
		return []
	var needed := {root: true}
	var frontier: Array = [root]
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
	var out := output_index()
	return out >= 0 and out < nodes.size() and nodes[out] != null \
			and _eval_order().is_empty()


## Problems worth telling the user about, for a host's configuration warnings: a missing output, a cycle,
## a null node, an unwired required input, plus each node's own complaints.
func graph_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if output_index() < 0 or output_index() >= nodes.size():
		w.append("Terrain graph has no output node set. Add an Output node (or Set as Output on a node), "
			+ "or it evaluates to a flat 0.")
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
