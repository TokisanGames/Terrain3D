# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeTransform — a FILTER grid node: move, rotate and scale an upstream subgraph in world
# XZ. PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md §4.1. Fuses Hesiod's Translate + Rotate + Zoom, because
# three nodes for one affine is three resamples and three chances to blur.
#
# WHY THIS IS A GRID NODE AND NOT A CELL NODE (spec §3.1). eval_cell receives its inputs ALREADY evaluated
# at (wx, wz) — a node cannot ask its upstream for a value at a different coordinate. Domain Warp sidesteps
# that by never warping its input at all: it warps only its own internal noise sample. Transform cannot,
# because its whole job is to relocate whatever is upstream. So it resamples the materialised input grid at
# inverse-transformed positions instead. The cost is one grid materialisation and band-limiting by the
# input grid, so a large scale-up blurs; the benefit is that it works against ANY upstream, solver output
# included.
#
# EVERY PARAMETER IS IN WORLD METRES OR DEGREES. Nothing here is in grid cells (spec §3.6).
@tool
class_name Pasture3DGraphNodeTransform
extends Pasture3DGraphNode

## What a sample that lands outside the input grid reads. CLAMP repeats the edge value, ZERO reads a
## defined 0, WRAP tiles the field.
enum EdgeMode { CLAMP, ZERO, WRAP }

@export_group("Affine")
## World XZ translation in metres. Positive X moves the terrain east.
@export var offset: Vector2 = Vector2.ZERO:
	set(v):
		offset = v
		emit_changed()

## Rotation about `pivot`, in degrees, counter-clockwise looking down.
@export_range(-180.0, 180.0, 0.1) var rotation_deg: float = 0.0:
	set(v):
		rotation_deg = v
		emit_changed()

## Uniform scale about `pivot`. Above 1 magnifies the upstream terrain (and blurs it, see the header);
## below 1 shrinks it, bringing more of the field into view.
@export_range(0.01, 10.0, 0.01, "or_greater") var scale: float = 1.0:
	set(v):
		scale = maxf(v, 0.001)
		emit_changed()

## World XZ point that rotation and scale act about, in metres. Defaults to the world origin, NOT to the
## grid centre — the grid centre moves with the brush, which would make the same node behave differently
## at two placements.
@export var pivot: Vector2 = Vector2.ZERO:
	set(v):
		pivot = v
		emit_changed()

@export_group("Sampling")
## What a sample outside the input grid reads.
@export var edge_mode: EdgeMode = EdgeMode.CLAMP:
	set(v):
		edge_mode = v
		emit_changed()

## Cross-fade between the untransformed input (0.0) and the transformed result (1.0).
@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		emit_changed()


func op() -> StringName:
	return &"transform"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 5


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "offset", "rotation", "scale", "amount"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.HEIGHT,
		PortType.VECTOR,
		PortType.FLOAT,
		PortType.FLOAT,
		PortType.MASK,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return 0.0
		2: return rotation_deg
		3: return scale
		4: return amount
		_: return 0.0


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var in_grid: PackedFloat32Array
	if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and (p_inputs[0] as PackedFloat32Array).size() == n:
		in_grid = p_inputs[0]
	else:
		return Pasture3DGraphOps.zeros(n)

	var rot: float = float(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else rotation_deg
	var scl: float = float(p_inputs[3][0]) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and p_inputs[3].size() > 0) else scale
	var amt: float = float(p_inputs[4][0]) if (p_inputs.size() > 4 and p_inputs[4] is PackedFloat32Array and p_inputs[4].size() > 0) else amount

	# The identity affine is a bit-for-bit pass-through, not a resample. A resample through the identity
	# would still cost a bilinear tap per cell and would round-trip through float, so the gate's TA
	# criterion would measure the resampler's error rather than the transform's.
	if is_zero_approx(amt) or (offset == Vector2.ZERO and is_zero_approx(rot) and is_equal_approx(scl, 1.0)):
		return in_grid.duplicate()

	if not ClassDB.class_has_method("Pasture3DUtil", "transform_grid"):
		push_error("[Pasture3D] Pasture3DUtil.transform_grid is not bound. Rebuild GDExtension.")
		return in_grid.duplicate()

	var res: PackedFloat32Array = Pasture3DUtil.transform_grid(in_grid, p_gw, p_gh, p_rect,
			offset, rot, scl, pivot, int(edge_mode), amt)
	if res.size() != n:
		push_error("[Pasture3D] Transform native resample returned invalid grid size.")
		return in_grid.duplicate()

	return res


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(amount):
		w.append("%s: Amount is 0, so it passes the input through unchanged." % display_name())
	elif offset == Vector2.ZERO and is_zero_approx(rotation_deg) and is_equal_approx(scale, 1.0):
		w.append("%s: Offset, Rotation and Scale are all identity, so it passes the input through unchanged." % display_name())
	elif scale > 2.0:
		w.append("%s: Scale above 2 magnifies the input grid, which softens detail — the resample cannot invent frequencies the upstream grid does not carry." % display_name())
	return w
