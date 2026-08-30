# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDistanceTransform — a FILTER grid node: how far each cell is from the nearest cell
# of a thresholded mask, in WORLD METRES.
#
# The workhorse behind shorelines, riverbank falloff, road verges and "keep this many metres clear of
# that" masks. Feed it a mask, get a field that grows outward from the mask boundary; remap or curve it
# to turn that into a gradient.
#
# Implemented with jump flooding rather than an exact distance transform (spec §5.1). The reason is not
# speed: the exact scan is sequential and could not be ported to the GPU, so CPU and GPU would produce
# different terrain — and because the GPU route is switched on by a cell-count threshold, the SAME
# terrain would change when you crossed 256². JFA runs identically everywhere.
@tool
class_name Pasture3DGraphNodeDistanceTransform
extends Pasture3DGraphNode

enum Direction {
	OUTSIDE, ## Distance from outside the mask to its boundary. 0 inside.
	INSIDE, ## Depth into the mask from its boundary. 0 outside.
	SIGNED, ## Positive outside, negative inside, crossing zero at the boundary.
}

enum Metric {
	EUCLIDEAN, ## Straight-line distance. What you almost always want.
	MANHATTAN, ## Axis-aligned steps. Produces diamond contours.
	CHEBYSHEV, ## Max of the axis distances. Produces square contours.
}

enum OutputUnits {
	METRES, ## Distances as-is, in world metres.
	NORMALISED, ## Divided by Max Distance, or by the field's own maximum when that is 0.
}

## Cells with a mask value above this count as "inside".
@export_range(0.0, 1.0, 0.01) var threshold: float = 0.5:
	set(v):
		threshold = v
		emit_changed()

## Which side of the mask boundary the distance is measured on.
@export var direction: Direction = Direction.OUTSIDE:
	set(v):
		direction = v
		emit_changed()

## How distance is measured. Euclidean is the physical answer; the other two are stylistic.
@export var metric: Metric = Metric.EUCLIDEAN:
	set(v):
		metric = v
		emit_changed()

## Metres, or a 0..1 field. See the warning attached to NORMALISED.
@export var output_units: OutputUnits = OutputUnits.METRES:
	set(v):
		output_units = v
		emit_changed()

## Clamp distances to this many metres. 0 means unbounded. In NORMALISED mode this is also the divisor,
## which is the only way to get a normalised output that does not change with content or resolution.
@export_range(0.0, 5000.0, 1.0, "or_greater") var max_distance: float = 0.0:
	set(v):
		max_distance = maxf(v, 0.0)
		emit_changed()

## The divisor the last bake actually used. Read-only, and deliberately part of the interface: a
## normalised field is meaningless without it, so the node stores it rather than printing it.
var last_normalisation_divisor: float = 1.0


func op() -> StringName:
	return &"distance_transform"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 2


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "threshold"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.MASK, PortType.FLOAT])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return threshold
		_: return 0.0


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var in_grid: PackedFloat32Array
	if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and (p_inputs[0] as PackedFloat32Array).size() == n:
		in_grid = p_inputs[0]
	else:
		return Pasture3DGraphOps.zeros(n)

	var thr: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else threshold

	if not ClassDB.class_has_method("Pasture3DUtil", "distance_transform_grid"):
		push_error("[Pasture3D] Pasture3DUtil.distance_transform_grid is not bound. Rebuild GDExtension.")
		return in_grid.duplicate()

	var res: Dictionary = Pasture3DUtil.distance_transform_grid(in_grid, p_gw, p_gh, p_rect, thr,
			int(direction), int(metric), int(output_units), max_distance)
	var grid: PackedFloat32Array = res.get("grid", PackedFloat32Array())
	if grid.size() != n:
		push_error("[Pasture3D] Distance transform returned an invalid grid size.")
		return in_grid.duplicate()

	last_normalisation_divisor = float(res.get("divisor", 1.0))
	return grid


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if output_units == OutputUnits.NORMALISED and max_distance <= 0.0:
		# The calibration rule: a normalised asset without its divisor is not reproducible. With
		# max_distance at 0 the divisor is whatever the last bake happened to measure, so the same graph
		# over different terrain — or the same terrain at a different resolution — rescales silently.
		w.append("%s: Normalised with Max Distance 0, so the divisor is the field's own maximum (last bake: %.3f m). This makes the output content- and resolution-dependent; set Max Distance to pin it." % [display_name(), last_normalisation_divisor])
	if max_distance > 0.0 and direction == Direction.SIGNED:
		w.append("%s: Max Distance clamps the signed field symmetrically, so both the inside and outside limbs flatten at %.1f m." % [display_name(), max_distance])
	return w
