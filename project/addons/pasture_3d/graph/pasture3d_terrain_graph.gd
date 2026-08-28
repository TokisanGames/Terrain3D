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

# ---- Topology memoization ----------------------------------------------------------------------------
# `_eval_order` and `_fold_plan` depend ONLY on graph topology (nodes, connections, and which node is the
# output) — never on parameter values or mute state — so their results are safe to cache until the topology
# changes. A single bake chains native_supported -> compile_graph_program -> _fold_plan, each recomputing
# the same O(V*E) order/fold from scratch; the editor's async pipeline recompiles a program per expanded
# preview. Caching keyed on the resolved root, cleared on `structure_changed`, removes that redundant walk.
# The cached objects are shared and MUST be treated as read-only by callers.
var _order_cache: Dictionary = {}   # root:int -> Array (topological order)
var _fold_cache: Dictionary = {}    # root:int -> Dictionary (fold plan)


func _invalidate_topology_cache() -> void:
	_order_cache.clear()
	_fold_cache.clear()


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
# output. If it does, the graph re-emits `changed` so the host brush re-bakes. A node disconnected from the
# output changes nothing the bake would see, so no re-bake is triggered.

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
		var out_idx := output_index()
		if out_idx >= 0:
			affects_output = get_downstream_nodes(n_idx).has(out_idx)

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
	structure_changed.connect(_invalidate_topology_cache)


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

	# 1. Native C++ Whole-Graph Acceleration Path
	if native_supported(out) and ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid"):
		var prog: Dictionary = compile_graph_program(out)
		if not prog.is_empty():
			var in_surf := _surface_grid(p_input, n)
			var field: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(prog, p_gw, p_gh, p_rect, in_surf)
			if not field.is_empty() and field.size() == n:
				# The bake does not touch 2D node previews. The graph editor owns previews end to end,
				# rendering them off the main thread from its own single low-res tap pass (see graph_editor.gd).
				if p_root_node < 0 or p_root_node == output_index():
					nodes[out].store_cache(field, {}, _compute_node_inputs_hash(out, p_gw, p_gh, p_rect, p_mask, p_input, {}, {}), _global_access_tick)
				return field

	# 2. GDScript Folded / Multi-Channel Evaluation Reference Path
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
				var cell_in := PackedFloat32Array()
				cell_in.resize(8)
				for iz in range(p_gh):
					var row := iz * p_gw
					var wz: float = min_z + float(iz) * dz
					for ix in range(p_gw):
						var wx: float = min_x + float(ix) * dx
						g[row + ix] = _cell_value_fast(s0, row + ix, wx, wz, grids, aux, inputs_of, input_ports_of, cell_in)
				grids[ni] = g
		elif node.op() == &"input":
			grids[ni] = _surface_grid(p_input, n) # the surface handed in, or a flat 0 when none
		elif node.op() == &"output":
			var s0: int = inputs_of[ni][0] if not inputs_of[ni].is_empty() else -1
			var sp0: int = input_ports_of[ni][0] if not input_ports_of[ni].is_empty() else 0
			grids[ni] = _read_channel(s0, sp0, grids, aux, n).duplicate()
		elif node.op() == &"noise_jordan" or node.op() == &"noise_swiss" or node.op() == &"furrows" or node.op() == &"dunes":
			var in_grids := _input_grids(ni, grids, aux, n)
			grids[ni] = node.eval_grid(in_grids, p_gw, p_gh, p_mask, p_rect)
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

		# The bake does not touch 2D node previews — the graph editor owns them (see the note above).
		if p_root_node < 0 or p_root_node == output_index():
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
	# Topology-only result — served from cache until `structure_changed` clears it. Read-only for callers.
	if _fold_cache.has(out):
		return _fold_cache[out]
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
	var plan := {"order": order, "inputs_of": inputs_of, "input_ports_of": input_ports_of,
			"materialize": materialize}
	_fold_cache[out] = plan
	return plan


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
		if node.muted:
			op_id = 3 # BLEND
			param = 0.0 # BLEND_ADD
			sb = -1 # unwired second input (adds 0.0 -> pure passthrough of sa)
		else:
			match node.op():
				&"noise":
					op_id = 1; param = float(node.get("amplitude")); nz = node.get("noise")
				&"const":
					op_id = 2; param = float(node.get("value"))
				&"const_int":
					op_id = 2; param = float(int(node.get("value")))
				&"const_vector":
					var cv: Vector2 = node.get("value") if node.get("value") is Vector2 else Vector2.ZERO
					op_id = 2; param = cv.length()
				&"const_color":
					var cc: Color = node.get("value") if node.get("value") is Color else Color.WHITE
					op_id = 2; param = cc.get_luminance()
				&"const_bool":
					op_id = 2; param = 1.0 if bool(node.get("value")) else 0.0
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
func compile_graph_program(p_root_node: int = -1) -> Dictionary:
	var out := p_root_node if (p_root_node >= 0 and p_root_node < nodes.size()) else output_index()
	if out < 0 or out >= nodes.size() or nodes[out] == null:
		return {}
	var order := _eval_order(out)
	if order.is_empty():
		return {}
	for c in connections:
		if c.size() >= 4 and int(c[1]) > 0:
			var to_node := int(c[2])
			var from_node := int(c[0])
			if order.has(to_node) and order.has(from_node):
				return {}
	var slot_of := {}
	for k in range(order.size()):
		slot_of[order[k]] = k
	var inputs_of: Dictionary = _fold_plan(out)["inputs_of"] # node -> [source node per port, -1 unwired]
	var ops := PackedInt32Array()
	var params := PackedFloat32Array()
	var params_b := PackedFloat32Array()
	var params_c := PackedFloat32Array()
	var params_d := PackedFloat32Array()
	var params_e := PackedFloat32Array()
	var params_f := PackedFloat32Array()
	var params_g := PackedFloat32Array()
	var params_h := PackedFloat32Array()
	var params_i := PackedFloat32Array()
	var params_j := PackedFloat32Array()
	var params_k := PackedFloat32Array()
	var params_l := PackedFloat32Array()
	var in0 := PackedInt32Array()
	var in1 := PackedInt32Array()
	var in2 := PackedInt32Array()
	var noise_tab: Array = []
	var luts_tab: Array = []

	for ni in order:
		var node: Pasture3DGraphNode = nodes[ni]
		var srcs: Array = inputs_of[ni]
		var s0: int = int(srcs[0]) if srcs.size() > 0 else -1
		var s1: int = int(srcs[1]) if srcs.size() > 1 else -1
		var s2: int = int(srcs[2]) if srcs.size() > 2 else -1
		var lowered := _lower_node_op(node)
		if lowered.is_empty():
			return {} # an op the native evaluator does not implement
		var op_id: int = int(lowered["op"])
		var _pr: PackedFloat32Array = lowered["params"]
		var p0: float = _pr[0]; var pb: float = _pr[1]; var pc: float = _pr[2]; var pd: float = _pr[3]
		var pe: float = _pr[4]; var pf: float = _pr[5]; var pg: float = _pr[6]; var ph: float = _pr[7]
		var pi: float = _pr[8]; var pj: float = _pr[9]; var pk: float = _pr[10]; var pl: float = _pr[11]
		var nz = lowered["noise"]
		var lut = lowered["lut"]

		ops.append(op_id)
		params.append(p0); params_b.append(pb); params_c.append(pc); params_d.append(pd)
		params_e.append(pe); params_f.append(pf); params_g.append(pg); params_h.append(ph)
		params_i.append(pi); params_j.append(pj); params_k.append(pk); params_l.append(pl)
		noise_tab.append(nz)
		luts_tab.append(lut)
		in0.append(int(slot_of[s0]) if s0 >= 0 else -1)
		in1.append(int(slot_of[s1]) if s1 >= 0 else -1)
		in2.append(int(slot_of[s2]) if s2 >= 0 else -1)

	return {
		"ops": ops, "params": params, "params_b": params_b, "params_c": params_c, "params_d": params_d,
		"params_e": params_e, "params_f": params_f, "params_g": params_g, "params_h": params_h,
		"params_i": params_i, "params_j": params_j, "params_k": params_k, "params_l": params_l,
		"in0": in0, "in1": in1, "in2": in2,
		"noise": noise_tab, "luts": luts_tab, "output": int(slot_of[out]),
	}


## Lower ONE node into the native op table: its GraphCellOpType id, the 12 parallel scalar params
## (p0..pl, index-aligned with compile_graph_program's params/params_b/.../params_l), its FastNoiseLite (or
## null), and its CURVE LUT (or an empty array). The single source of truth for the op vocabulary, shared by
## the single-root bake compile (`compile_graph_program`) and the multi-root preview compile
## (`compile_graph_program_multi`) so a new node's lowering is written once. Returns {} for an op the native
## evaluator does not implement — the caller then abandons the native path. A muted node lowers to op 12
## (passthrough of its first input), matching the folded evaluator's mute semantics.
func _lower_node_op(node: Pasture3DGraphNode) -> Dictionary:
	var op_id := 0
	var p0 := 0.0; var pb := 0.0; var pc := 0.0; var pd := 0.0; var pe := 0.0
	var pf := 0.0; var pg := 0.0; var ph := 0.0; var pi := 0.0; var pj := 0.0
	var pk := 0.0; var pl := 0.0
	var nz = null
	var lut = PackedFloat32Array()

	var _f := func(p: StringName, def: float = 0.0) -> float:
		var v = node.get(p)
		return float(v) if v != null else def

	var _i := func(p: StringName, def: int = 0) -> int:
		var v = node.get(p)
		return int(v) if v != null else def

	if node.muted:
		op_id = 12 # GRAPH_OP_OUTPUT / GRAPH_OP_REROUTE (passthrough of in0)
	else:
		match node.op():
			&"input":
				op_id = 10
			&"output", &"reroute", &"terrain_bus_merge", &"terrain_bus_split":
				op_id = 12
			&"noise":
				op_id = 1; p0 = _f.call(&"amplitude", 1.0); nz = node.get("noise")
			&"const":
				op_id = 2; p0 = _f.call(&"value", 0.0)
			&"const_int":
				op_id = 2; p0 = float(_i.call(&"value", 0))
			&"const_vector":
				var cv: Vector2 = node.get("value") if node.get("value") is Vector2 else Vector2.ZERO
				op_id = 2; p0 = cv.length()
			&"const_color":
				var cc: Color = node.get("value") if node.get("value") is Color else Color.WHITE
				op_id = 2; p0 = cc.get_luminance()
			&"const_bool":
				op_id = 2; p0 = 1.0 if bool(node.get("value")) else 0.0
			&"const_curve":
				op_id = 21; p0 = 0.0; pb = 1.0; pc = 0.0; pd = 1.0; pe = 1.0
				var c: Curve = node.get("curve")
				if c != null:
					lut.resize(256)
					for li in range(256):
						lut[li] = c.sample_baked(float(li) / 255.0)
			&"blend":
				op_id = 3; p0 = float(_i.call(&"mode", 0))
			&"terrace":
				op_id = 4
				p0 = _f.call(&"band_height", 8.0)
				pb = _f.call(&"hardness", 0.8)
				pc = _f.call(&"amount", 1.0)
				pd = _f.call(&"jitter", 0.0)
				if pd > 0.0 and node.has_method("_jitter_field"):
					nz = node.call("_jitter_field")
			&"smooth":
				op_id = 11; p0 = float(_i.call(&"passes", 1))
			&"noise_jordan":
				op_id = 13; p0 = _f.call(&"amplitude", 100.0); pb = _f.call(&"frequency", 0.005); pc = float(_i.call(&"octaves", 6)); pd = _f.call(&"gain", 0.5); pe = _f.call(&"lacunarity", 2.0); pf = _f.call(&"warp_strength", 0.35); pg = _f.call(&"damp_strength", 0.8); ph = float(_i.call(&"seed", 0))
			&"noise_swiss":
				op_id = 14; p0 = _f.call(&"amplitude", 100.0); pb = _f.call(&"frequency", 0.005); pc = float(_i.call(&"octaves", 6)); pd = _f.call(&"gain", 0.5); pe = _f.call(&"lacunarity", 2.0); pf = _f.call(&"ridge_offset", 1.0); pg = _f.call(&"erosion_accent", 0.3); ph = float(_i.call(&"seed", 0))
			&"geological_primitive":
				op_id = 15; p0 = float(_i.call(&"primitive_type", 0)); pb = float(_i.call(&"mapping", 0)); pc = _f.call(&"height", 50.0); pd = _f.call(&"radius", 50.0); pe = _f.call(&"eccentricity", 0.0); pf = _f.call(&"steepness", 1.0); pg = _f.call(&"azimuth_degrees", 0.0); var off: Vector2 = node.get("center_offset") if node.get("center_offset") != null else Vector2.ZERO; pj = off.x; pk = off.y
			&"furrows":
				op_id = 16; p0 = _f.call(&"amplitude", 1.0); pb = _f.call(&"spacing", 15.0); pc = _f.call(&"direction_degrees", 0.0); pd = float(_i.call(&"profile", 1)); pe = _f.call(&"wobble_amount", 2.0); pf = _f.call(&"wobble_size", 70.0); pg = float(_i.call(&"seed", 0))
			&"dunes":
				op_id = 17; p0 = _f.call(&"amplitude", 2.0); pb = _f.call(&"wavelength", 30.0); pc = _f.call(&"direction_degrees", 0.0); pd = _f.call(&"asymmetry", 0.4); pe = _f.call(&"crest_sharpness", 0.6); pf = _f.call(&"wander_amount", 2.0); pg = _f.call(&"wander_size", 60.0); ph = float(_i.call(&"seed", 0))
			&"crater":
				op_id = 18; p0 = _f.call(&"amplitude", 10.0); pb = _f.call(&"floor_depth", 14.0); pc = _f.call(&"rim_height", 4.0); pd = _f.call(&"rim_width", 0.25); pe = _f.call(&"ejecta_falloff", 2.5); pf = _f.call(&"floor_flatness", 0.4); pg = float(_i.call(&"terrace_steps", 0))
			&"warp":
				op_id = 19; p0 = float(_i.call(&"warp_type", 0)); pb = _f.call(&"frequency", 0.01); pc = _f.call(&"strength", 10.0); pd = float(_i.call(&"octaves", 3)); pe = _f.call(&"amplitude", 1.0); pf = _f.call(&"roughness", 0.5); pg = float(_i.call(&"seed", 0))
			&"strata":
				op_id = 20; p0 = _f.call(&"band_height", 8.0); pb = _f.call(&"hardness", 0.75); pc = _f.call(&"amount", 1.0); pd = _f.call(&"dip", 4.0); pe = _f.call(&"dip_direction_degrees", 45.0); pf = _f.call(&"break_amount", 3.0); pg = _f.call(&"break_size", 40.0); ph = float(_i.call(&"seed", 0))
			&"curve":
				op_id = 21; p0 = _f.call(&"input_min", 0.0); pb = _f.call(&"input_max", 100.0); pc = _f.call(&"output_min", 0.0); pd = _f.call(&"output_max", 100.0); pe = _f.call(&"amount", 1.0)
				var c: Curve = node.get("curve")
				if c != null:
					lut.resize(256)
					for li in range(256):
						lut[li] = c.sample_baked(float(li) / 255.0)
			&"remap":
				op_id = 22; p0 = _f.call(&"in_min", 0.0); pb = _f.call(&"in_max", 100.0); pc = _f.call(&"out_min", 0.0); pd = _f.call(&"out_max", 100.0); pe = 1.0 if bool(node.get("clamp_output")) else 0.0; pf = _f.call(&"soft_knee", 0.0); pg = 1.0 if bool(node.get("invert")) else 0.0
			&"mask":
				op_id = 23; p0 = float(_i.call(&"property", 0)); pb = _f.call(&"band_min", 0.0); pc = _f.call(&"band_max", 90.0); pd = _f.call(&"falloff_lo", 0.0); pe = _f.call(&"falloff_hi", 0.0); pf = 1.0 if bool(node.get("invert")) else 0.0; pg = _f.call(&"strength", 1.0)
			&"curvature":
				op_id = 24; p0 = float(_i.call(&"mode", 0)); pb = float(_i.call(&"radius", 1)); pc = _f.call(&"contrast", 1.0)
			&"talus_projection":
				op_id = 25; p0 = _f.call(&"talus_angle_deg", 35.0); pb = float(_i.call(&"iterations", 16)); pc = _f.call(&"transfer_rate", 0.5); pd = _f.call(&"amount", 1.0)
			&"spectral_equalizer":
				op_id = 26; p0 = _f.call(&"macro_gain", 1.0); pb = _f.call(&"meso_gain", 1.0); pc = _f.call(&"micro_gain", 1.5); pd = float(_i.call(&"macro_passes", 16)); pe = float(_i.call(&"meso_passes", 4)); pf = _f.call(&"amount", 1.0)
			&"depression_filling":
				op_id = 27; p0 = _f.call(&"epsilon_slope", 0.0001); pb = _f.call(&"fill_depth_limit", 0.0); pc = _f.call(&"amount", 1.0)
			&"lake_flooding":
				op_id = 28; p0 = float(_i.call(&"flood_mode", 0)); pb = _f.call(&"water_elevation", 10.0); pc = _f.call(&"flood_percent", 1.0); pd = _f.call(&"shoreline_width", 4.0)
			&"stream_extraction":
				op_id = 29; p0 = _f.call(&"min_catchment_cells", 24.0); pb = _f.call(&"carve_depth", 3.0); pc = _f.call(&"channel_width", 8.0); pd = _f.call(&"bank_falloff", 4.0)
			&"erosion_hydraulic":
				op_id = 30; p0 = float(_i.call(&"iterations", 25)); pb = _f.call(&"rain_rate", 0.05); pc = _f.call(&"evaporation_rate", 0.02); pd = _f.call(&"sediment_capacity", 8.0); pe = _f.call(&"erosion_speed", 0.5); pf = _f.call(&"deposition_speed", 0.4); pg = _f.call(&"min_slope", 0.01)
			&"erosion_thermal":
				op_id = 31; p0 = _f.call(&"talus_angle", 30.0); pb = float(_i.call(&"iterations", 25)); pc = _f.call(&"settling_rate", 0.7)
			&"scree":
				op_id = 32; p0 = _f.call(&"amplitude", 2.0); pb = _f.call(&"grain_size", 0.05); pc = _f.call(&"downslope_streak", 0.7); pd = _f.call(&"toe_deposition", 0.8); pe = _f.call(&"min_slope_degrees", 25.0); pf = _f.call(&"slope_falloff_degrees", 8.0); pg = float(_i.call(&"seed", 0))
			&"erosion":
				op_id = 33; p0 = float(_i.call(&"iterations", 30)); pb = _f.call(&"erosion_rate", 0.08); pc = _f.call(&"area_exponent", 0.45); pd = _f.call(&"hillslope_diffusion", 0.15); pe = _f.call(&"deposition", 0.0)
			_:
				return {} # an op the native evaluator does not implement

	return {
		"op": op_id,
		"params": PackedFloat32Array([p0, pb, pc, pd, pe, pf, pg, ph, pi, pj, pk, pl]),
		"noise": nz,
		"lut": lut,
	}


## Topological order of the UNION of every root's ancestry — one program that can cover several preview
## roots at once. Same ancestor walk + Kahn sort as `_eval_order`, over the combined `needed` set; empty on a
## cycle. NOT memoized: the root SET varies with which previews are toggled on, so caching it would thrash;
## the single-root `_eval_order` stays the cached hot path the bake rides.
func _eval_order_multi(p_roots: Array) -> Array:
	var needed := {}
	var frontier: Array = []
	for r in p_roots:
		var ri := int(r)
		if ri >= 0 and ri < nodes.size() and nodes[ri] != null and not needed.has(ri):
			needed[ri] = true
			frontier.push_back(ri)
	if needed.is_empty():
		return []
	while not frontier.is_empty():
		var cur: int = frontier.pop_back()
		for c in connections:
			if c.size() >= 4 and int(c[2]) == cur:
				var from := int(c[0])
				if from >= 0 and from < nodes.size() and not needed.has(from):
					needed[from] = true
					frontier.push_back(from)
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
		return [] # a cycle in the combined ancestry
	return order


## Compile ONE native program covering every root in `p_roots` and their ancestors, plus a `slot_of` map
## (node index -> SSA slot) so the caller can find each preview node's tap slot. Backs the editor's inline
## previews: one program feeds one `Pasture3DUtil.graph_eval_grid_taps` pass, so N open previews cost a
## single evaluation. Returns {} — "no native preview this tick" — when the root set is empty, its combined
## ancestry has a cycle or a secondary-port (port >= 1) wire, or any node's op is not native. The program's
## `output` is set to one root's slot purely to satisfy graph_build's range check; the caller reads the
## tapped buffers, never the output.
func compile_graph_program_multi(p_roots: Array) -> Dictionary:
	var order := _eval_order_multi(p_roots)
	if order.is_empty():
		return {}
	var needed := {}
	for ni in order:
		needed[ni] = true
	# A secondary-port wire needs the multi-channel GDScript path; the taps program has no aux channels, so
	# bail exactly as native_supported / compile_graph_program do.
	for c in connections:
		if c.size() >= 4 and int(c[1]) > 0:
			var to_node := int(c[2])
			var from_node := int(c[0])
			if needed.has(to_node) and needed.has(from_node):
				return {}
	var slot_of := {}
	for k in range(order.size()):
		slot_of[order[k]] = k
	# inputs_of over the union ancestor set — same construction as _fold_plan, restricted to `needed`.
	var inputs_of := {}
	for ni in order:
		var arr: Array = []
		arr.resize(nodes[ni].input_count())
		arr.fill(-1)
		inputs_of[ni] = arr
	for c in connections:
		if c.size() >= 4:
			var to := int(c[2])
			var from := int(c[0])
			if needed.has(to) and needed.has(from):
				var tp := int(c[3])
				if tp >= 0 and tp < (inputs_of[to] as Array).size():
					inputs_of[to][tp] = from
	var ops := PackedInt32Array()
	var params := PackedFloat32Array()
	var params_b := PackedFloat32Array()
	var params_c := PackedFloat32Array()
	var params_d := PackedFloat32Array()
	var params_e := PackedFloat32Array()
	var params_f := PackedFloat32Array()
	var params_g := PackedFloat32Array()
	var params_h := PackedFloat32Array()
	var params_i := PackedFloat32Array()
	var params_j := PackedFloat32Array()
	var params_k := PackedFloat32Array()
	var params_l := PackedFloat32Array()
	var in0 := PackedInt32Array()
	var in1 := PackedInt32Array()
	var in2 := PackedInt32Array()
	var noise_tab: Array = []
	var luts_tab: Array = []
	for ni in order:
		var node: Pasture3DGraphNode = nodes[ni]
		var srcs: Array = inputs_of[ni]
		var s0: int = int(srcs[0]) if srcs.size() > 0 else -1
		var s1: int = int(srcs[1]) if srcs.size() > 1 else -1
		var s2: int = int(srcs[2]) if srcs.size() > 2 else -1
		var lowered := _lower_node_op(node)
		if lowered.is_empty():
			return {} # an op the native evaluator does not implement
		var _pr: PackedFloat32Array = lowered["params"]
		ops.append(int(lowered["op"]))
		params.append(_pr[0]); params_b.append(_pr[1]); params_c.append(_pr[2]); params_d.append(_pr[3])
		params_e.append(_pr[4]); params_f.append(_pr[5]); params_g.append(_pr[6]); params_h.append(_pr[7])
		params_i.append(_pr[8]); params_j.append(_pr[9]); params_k.append(_pr[10]); params_l.append(_pr[11])
		noise_tab.append(lowered["noise"])
		luts_tab.append(lowered["lut"])
		in0.append(int(slot_of[s0]) if s0 >= 0 else -1)
		in1.append(int(slot_of[s1]) if s1 >= 0 else -1)
		in2.append(int(slot_of[s2]) if s2 >= 0 else -1)
	var out_slot := 0
	for r in p_roots:
		var ri := int(r)
		if slot_of.has(ri):
			out_slot = int(slot_of[ri])
			break
	return {
		"program": {
			"ops": ops, "params": params, "params_b": params_b, "params_c": params_c, "params_d": params_d,
			"params_e": params_e, "params_f": params_f, "params_g": params_g, "params_h": params_h,
			"params_i": params_i, "params_j": params_j, "params_k": params_k, "params_l": params_l,
			"in0": in0, "in1": in1, "in2": in2,
			"noise": noise_tab, "luts": luts_tab, "output": out_slot,
		},
		"slot_of": slot_of,
	}


## True when every node feeding the output has an op the native whole-graph evaluator implements.
func native_supported(p_root_node: int = -1) -> bool:
	var out := p_root_node if (p_root_node >= 0 and p_root_node < nodes.size()) else output_index()
	if out < 0 or out >= nodes.size() or nodes[out] == null:
		return false
	var order := _eval_order(out)
	if order.is_empty():
		return false
	const SUPPORTED := [
		&"input", &"output", &"reroute", &"terrain_bus_merge", &"terrain_bus_split",
		&"noise", &"const", &"const_int", &"const_vector", &"const_color", &"const_bool", &"const_curve",
		&"blend", &"smooth", &"terrace",
		&"noise_jordan", &"noise_swiss", &"geological_primitive", &"furrows", &"dunes",
		&"crater", &"warp", &"strata", &"curve", &"remap", &"mask", &"curvature",
		&"talus_projection", &"spectral_equalizer", &"depression_filling", &"lake_flooding",
		&"stream_extraction", &"erosion_hydraulic", &"erosion_thermal", &"scree", &"erosion"
	]
	for ni in order:
		if nodes[ni] == null or (not nodes[ni].muted and not SUPPORTED.has(nodes[ni].op())):
			return false
	# If any wire in the active DAG feeds from a secondary port (port >= 1, e.g. a solver mask),
	# stay on the multi-channel GDScript evaluator so the secondary channel is correctly read.
	for c in connections:
		if c.size() >= 4 and int(c[1]) > 0:
			var to_node := int(c[2])
			var from_node := int(c[0])
			if order.has(to_node) and order.has(from_node):
				return false
	return true



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
		elif node.op() == &"noise_jordan":
			grids[ni] = Pasture3DUtil.noise_jordan_grid(p_gw, p_gh, p_rect, node.amplitude, node.frequency, node.octaves, node.gain, node.lacunarity, node.warp_strength, node.damp_strength, node.seed)
		elif node.op() == &"noise_swiss":
			grids[ni] = Pasture3DUtil.noise_swiss_grid(p_gw, p_gh, p_rect, node.amplitude, node.frequency, node.octaves, node.gain, node.lacunarity, node.ridge_offset, node.erosion_accent, node.seed)
		elif node.op() == &"furrows":
			grids[ni] = Pasture3DUtil.furrows_grid(p_gw, p_gh, p_rect, node.amplitude, node.spacing, node.direction_degrees, int(node.profile), node.wobble_amount, node.wobble_size, node.seed)
		elif node.op() == &"dunes":
			grids[ni] = Pasture3DUtil.dunes_grid(p_gw, p_gh, p_rect, node.amplitude, node.wavelength, node.direction_degrees, node.asymmetry, node.crest_sharpness, node.wander_amount, node.wander_size, node.seed)
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
	# Topology-only result — served from cache until `structure_changed` clears it. Read-only for callers.
	if _order_cache.has(root):
		return _order_cache[root]
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
		order = [] # a cycle in the output's ancestry
	_order_cache[root] = order
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
