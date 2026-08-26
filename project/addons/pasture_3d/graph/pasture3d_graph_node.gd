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
@export var collapsed: bool = false:
	set(v):
		collapsed = v
		emit_changed()


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


## True when this node exposes an output port that other nodes can wire from. The Output sink returns
## false — its value is the graph's result, read by the host, not consumed downstream. EDITOR-only (drives
## whether a right-side slot is drawn); the evaluator reads the output through `output_index`.
func has_output() -> bool:
	return true


## Port data types for visual wiring and validation.
enum PortType {
	HEIGHT = 0,   # Scalar elevation field (meters) - Sky Blue
	MASK = 1,     # Normalized scalar [0.0, 1.0] - Amber
	VECTOR = 2,   # Directional 2D vector / angle field - Purple
	CURVE = 3,    # Spline / transfer curve - Emerald
}


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
