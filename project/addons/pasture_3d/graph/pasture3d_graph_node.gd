# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNode — abstract base for one node of a Pasture3DTerrainGraph. A node reads zero or more
# input height grids and produces one output height grid; the graph wires them into a DAG and evaluates
# in topological order (Pasture3DTerrainGraph.evaluate).
#
# ---- CELL vs GRID, the same split the brush node stack rests on ----
#
# The distinction is `needs_grid()`, lifted from Pasture3DNode (see PASTURE3D_NODE_VOCABULARY.md):
#
#   A CELL node is point-evaluable: `eval_cell(wx, wz, inputs)` sees one cell — its world XZ and its
#   inputs' values THERE — and returns that cell's output. Noise, Const and Blend are cell nodes. A run
#   of them can (later) fold into one loop, exactly as the stack folds a run of cell modifiers.
#
#   A GRID node needs the whole grid: `eval_grid(inputs, gw, gh, mask)` reads neighbours or routes across
#   the field — a blur, an erosion solve. It cannot be expressed per-cell, which is the structural reason
#   the two entry points exist.
#
# In increment 1 the evaluator materialises one grid per node either way (it loops cells calling
# eval_cell for a cell node, or calls eval_grid once for a grid node). The FOLD — fusing a run of cell
# nodes into a single pass, then a C++/GPU backend — is a later optimisation, not a correctness concern.
#
# ---- op() is the dispatch tag, a SUPERSET of the stack's ----
#
# `op()` names the operation the way Pasture3DNode.op() does (&"noise", &"smooth", …). The graph's op
# vocabulary is deliberately a superset of the stack's so the two collapse into one system rather than
# diverging; a node that shares a stack op's name must compute the same thing.
@tool
class_name Pasture3DGraphNode
extends Resource

## What a node does to the field, so the editor palette and the (later) fold can group nodes without
## parsing their op. GENERATOR takes no input and makes a field; FILTER transforms one input; COMBINER
## merges several; SOLVER takes an input field and iterates/routes a simulation over it (Scree, DLA,
## Erosion). A SOLVER is always a grid node, and it is the category that may expose MULTIPLE outputs — a
## primary height plus derived channels (a deposition/flow/wetness mask) that downstream Mask/Blend nodes
## read. See PASTURE3D_TERRAIN_GRAPH_SPEC.md (Solvers).
enum Role { GENERATOR, FILTER, COMBINER, SOLVER }

## A view onto `resource_name`, so a graph of three Blend nodes does not read as three identical rows in
## the editor. EDITOR-only, not stored twice: `resource_name` already serialises. Mirrors
## Pasture3DNode.label.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var label: String:
	set(v):
		resource_name = v
	get:
		return resource_name

## Where this node sits on the graph editor canvas, in GraphEdit offset units. Persisted so a layout
## survives a reload. Deliberately does NOT emit `changed`: moving a node is not a reason to re-bake the
## terrain, only a reason to re-save the layout.
@export var graph_position: Vector2 = Vector2.ZERO

## When muted, this node is bypassed during graph evaluation (passes its first input through, or 0.0).
@export var muted: bool = false:
	set(v):
		muted = v
		emit_changed()

## When collapsed, the editor hides internal inline controls, displaying a compact header with port slots.
@export var collapsed: bool = false

## When true, the graph editor shows this node's inline 2D thumbnail. Pure toggle state — the editor owns
## all preview rendering; the node stores nothing about the preview beyond this flag.
@export var preview_on: bool = false

# ---- Per-Node Output Buffer Caching (Milestone 1) ----------------------------------------------------
var _cached_grid: PackedFloat32Array = PackedFloat32Array()
var _cached_aux: Dictionary = {}
var _dirty_revision: int = 1
var _last_baked_revision: int = -1
var _inputs_hash: int = 0
var _last_access_tick: int = 0


func _init() -> void:
	changed.connect(_on_node_changed_bump_revision)


func _on_node_changed_bump_revision() -> void:
	_dirty_revision += 1


## Returns true if the node needs re-evaluation (its properties changed, inputs signature changed, or cache empty).
func is_dirty(p_inputs_hash: int) -> bool:
	if _cached_grid.is_empty():
		return true
	if _dirty_revision != _last_baked_revision:
		return true
	if _inputs_hash != p_inputs_hash:
		return true
	return false


## Stores primary output grid and auxiliary channel grids in the node's local cache.
func store_cache(p_grid: PackedFloat32Array, p_aux: Dictionary, p_inputs_hash: int, p_access_tick: int = 0) -> void:
	_cached_grid = p_grid
	_cached_aux = p_aux
	_last_baked_revision = _dirty_revision
	_inputs_hash = p_inputs_hash
	_last_access_tick = p_access_tick


## Clears this node's cached buffers and resets cache revisions.
func clear_cache() -> void:
	_cached_grid = PackedFloat32Array()
	_cached_aux = {}
	_last_baked_revision = -1
	_inputs_hash = 0


## Returns the primary cached output grid (port 0).
func get_cached_grid() -> PackedFloat32Array:
	return _cached_grid


## Returns the dictionary of cached auxiliary channel grids (ports >= 1).
func get_cached_aux() -> Dictionary:
	return _cached_aux


## Approximate memory footprint in bytes consumed by this node's cached grids.
func get_cache_size_bytes() -> int:
	var total := _cached_grid.size() * 4
	for k in _cached_aux:
		var arr = _cached_aux[k]
		if arr is PackedFloat32Array:
			total += (arr as PackedFloat32Array).size() * 4
	return total



## The dispatch tag. MUST match the string any equivalent stack op / native backend tests.
func op() -> StringName:
	return &""


## Which palette group this node belongs to. Drives nothing in the evaluator; it is authoring metadata.
func role() -> Role:
	return Role.FILTER


## True when this node needs the whole grid (reads neighbours or routes across it). False = a cell node,
## evaluated per cell through `eval_cell`. See the header.
func needs_grid() -> bool:
	return false


## True when this node holds state the native whole-graph evaluator cannot see — in practice, a per-solver
## FROZEN cache. The native program is a pure function of the graph's parameters and its input surface; it
## has no way to serve a cached solve or to notice it has gone stale. A node that answers true takes the
## WHOLE graph off the native path (the bail is graph-wide), which is the price of the cache actually
## working. Solvers that are LIVE must keep answering false, or freezing would cost native everywhere.
func blocks_native() -> bool:
	return false


## True when this node exposes an output port that other nodes can wire from. The Output sink returns
## false — its value is the graph's result, read by the host, not consumed downstream. EDITOR-only (drives
## whether a right-side slot is drawn); the evaluator reads the output through `output_index`.
func has_output() -> bool:
	return true


## Port data types for visual wiring and validation.
enum PortType {
	HEIGHT = 0,       # Scalar elevation field (meters) - Sky Blue
	MASK = 1,         # Normalized scalar [0.0, 1.0] - Amber
	VECTOR = 2,       # Directional 2D/3D vector / angle field - Purple
	CURVE = 3,        # Spline / transfer curve - Emerald
	FLOAT = 4,        # General scalar float value / factor - Cyan
	INT = 5,          # Discrete count / integer - Cobalt Blue
	COLOR = 6,        # RGBA color / tint / gradient band - Magenta/Pink
	BOOL = 7,         # Boolean toggle / gate switch - Lime Yellow
	TERRAIN_BUS = 8,  # Bundled multi-channel stream - Warm Gold
	PATH = 9,         # World-space polyline with per-vertex width (Pasture3DGraphPath) - Slate
}


## The PATH this node produces, or null. The ONE thing in the graph that does not travel as a grid.
##
## ---- WHY THERE IS A SIDEBAND AT ALL ----
##
## Every other port carries a PackedFloat32Array because every other port is a FIELD. A road is not: it
## is a centreline and a width, and rasterising it into a grid to send it down a wire would fix its
## resolution at the wire instead of at the consumer and throw away the arc length that makes it a road
## rather than a shape. So a PATH port produces no grid; the evaluator carries the resource beside the
## grids, exactly as it already carries a multi-output solver's `aux` channels beside them.
##
## A node whose output is PATH still occupies a grid slot, filled with zeros. That is deliberate: the
## alternative is a special case in every loop that indexes `grids` by node, in exchange for saving one
## array on one node.
func path_output() -> Pasture3DGraphPath:
	return null


## True when this node reads PATH inputs, so the evaluator collects them before calling `eval_grid`.
## Answering true costs one dictionary walk per evaluation and nothing else.
func reads_paths() -> bool:
	return false


## Hand this node its PATH inputs, in INPUT PORT ORDER, with null for a port that is unwired or wired to
## something that produces no path. Called immediately before `eval_grid` and only when `reads_paths()`.
##
## Passed in rather than fetched, because a Resource has no way back to the graph that owns it, and
## giving it one would make every node able to reach every other — which is the property that keeps
## the evaluator's ordering meaningful.
func set_path_inputs(_p_paths: Array) -> void:
	pass


## Types for each input port. Defaults to HEIGHT for all ports.
func input_port_types() -> PackedInt32Array:
	var arr := PackedInt32Array()
	arr.resize(input_count())
	arr.fill(PortType.HEIGHT)
	return arr


## Output port type of the PRIMARY (port 0) output. Defaults to HEIGHT. Kept as the single-output
## shorthand; `output_port_types()[0]` is the same value.
func output_port_type() -> int:
	return output_port_types()[0]


## How many output ports this node exposes. 1 for every node except a multi-output SOLVER, which returns
## its primary height plus one grid per derived channel (e.g. Scree = [height, deposition-mask]). The
## connection tuple already carries `from_port`, so a consumer wires to a specific channel; the evaluator
## materialises port 0 into its `grids` slot and ports >= 1 into a parallel `aux` map.
func output_count() -> int:
	return 1


## Labels for each output port, for the editor's right-side slots. Length should match `output_count()`.
func output_names() -> PackedStringArray:
	return PackedStringArray(["out"])


## Types for each output port, in port order. Defaults to a single HEIGHT. A multi-output node overrides
## this so the editor colours each channel slot (a Scree's channel-1 slot is MASK-amber).
func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT])


## MULTI-OUTPUT grid entry point. Returns one grid per output port, in port order (`output_count()`
## entries). The default wraps the single-output `eval_grid` as `[eval_grid(...)]`, so only a node that
## actually produces channels overrides this. Only called for a node whose `output_count() > 1`; every
## single-output grid node continues to go through `eval_grid` unchanged.
func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> Array:
	return [eval_grid(p_inputs, p_gw, p_gh, p_mask, p_rect)]


## How many input ports this node reads. GENERATOR = 0; a FILTER = 1; Blend = 2.
func input_count() -> int:
	return 1


## Port labels, for the editor and for configuration warnings. Length should match `input_count()`.
func input_names() -> PackedStringArray:
	return PackedStringArray(["in"])


## The value an UNWIRED input port reads. A HEIGHT port reads 0 (a missing height adds nothing); a MASK
## port reads 1.0 (a missing gate is fully open, so an unwired mask input is a no-op rather than a hard 0
## that would zero the node out). Nodes with a mask/weight input override this per port.
func input_unwired_default(_p_port: int) -> float:
	return 0.0


## CELL node entry point. `p_wx` / `p_wz` are this cell's WORLD XZ (so noise stays continuous where two
## graphs or brushes meet). `p_inputs` holds each input port's value AT THIS CELL, in port order. Returns
## the cell's output height. Default = pass the first input through (a no-op filter).
func eval_cell(_p_wx: float, _p_wz: float, p_inputs: PackedFloat32Array) -> float:
	return p_inputs[0] if p_inputs.size() > 0 else 0.0


## GRID node entry point. `p_inputs` is one grid (PackedFloat32Array, row-major `p_gw * p_gh`) per input
## port, in port order; `p_mask` is an optional [0,1] grid of the same shape, or null; `p_rect` is the
## world-XZ extent the grid covers, so a frame-dependent generator (Crater, DLA) can normalise a cell's
## world position to the loop. Returns the output grid. Default = pass the first input through. Only called
## when `needs_grid()` is true.
func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, _p_rect: Rect2) -> PackedFloat32Array:
	return (p_inputs[0] as PackedFloat32Array) if p_inputs.size() > 0 else Pasture3DGraphOps.zeros(p_gw * p_gh)


## Problems that only exist when this graph runs inside a BRUSH, where the footprint is one masked
## region among several and neighbouring regions have to agree where they meet. Kept apart from
## `node_warnings` because the same graph resource is meant to be reusable: what is a defect in a brush
## can be the whole point on a full terrain, and a warning that fires in both places is one users learn
## to ignore. Empty = nothing to say.
func node_warnings_in_brush() -> PackedStringArray:
	return PackedStringArray()


## Problems worth surfacing in the graph's configuration warnings (an unassigned noise, a zero pass
## count). Empty = nothing to say.
func node_warnings() -> PackedStringArray:
	return PackedStringArray()


## Human-readable name for warnings: the user's label, else the class name with the Pasture3DGraphNode
## prefix stripped.
func display_name() -> String:
	if not resource_name.is_empty():
		return resource_name
	return String(get_script().get_global_name()).trim_prefix("Pasture3DGraphNode")
