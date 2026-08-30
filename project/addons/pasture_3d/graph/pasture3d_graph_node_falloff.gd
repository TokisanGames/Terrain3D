# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeFalloff — a FILTER cell node: attenuate the input toward 0 with distance from a world
# centre. PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md §4.2.
#
# This is the node that ends a landmass. Without it, every generator in the graph runs to the horizon and
# the only way to stop one is a Mask + Blend(MUL) chain hand-built out of an altitude band, which gates on
# the WRONG axis — it cuts by height, not by distance from anywhere.
#
# CELL node (needs_grid() = false): the attenuation is a closed-form function of the cell's own world XZ,
# so it folds into the per-cell program and never materialises a grid. The distance is measured in WORLD
# METRES from `centre`, not in grid fractions, so the same falloff reads identically at any bake resolution
# and under any modifier margin (spec §3.6).
@tool
class_name Pasture3DGraphNodeFalloff
extends Pasture3DGraphNode

## How distance from the centre is measured. RADIAL is a circle, SQUARE a rectangle (Chebyshev distance),
## and the AXIS modes fade along one axis only — a coastline rather than an island.
enum Shape { RADIAL, SQUARE, AXIS_X, AXIS_Z }

## The distance metric the falloff uses.
@export var shape: Shape = Shape.RADIAL:
	set(v):
		shape = v
		emit_changed()

@export_group("Placement")
## World XZ centre the distance is measured from, in metres.
@export var centre: Vector2 = Vector2.ZERO:
	set(v):
		centre = v
		emit_changed()

## Metres from `centre` that pass through at full strength. Inside this the input is untouched.
@export_range(0.0, 2000.0, 1.0, "or_greater") var radius: float = 500.0:
	set(v):
		radius = maxf(v, 0.0)
		emit_changed()

## Metres of fade beyond `radius`, from full input to 0. 0 = a hard cliff edge.
@export_range(0.0, 2000.0, 1.0, "or_greater") var feather: float = 200.0:
	set(v):
		feather = maxf(v, 0.0)
		emit_changed()

@export_group("Shaping")
## Cross-fade between the untouched input (0.0) and the fully attenuated result (1.0).
@export_range(0.0, 1.0, 0.01) var strength: float = 1.0:
	set(v):
		strength = clampf(v, 0.0, 1.0)
		emit_changed()

## Swap inside for outside: keep the far field and cut the middle, for a ring or a crater rim.
@export var invert: bool = false:
	set(v):
		invert = v
		emit_changed()

## Metres of distance perturbation taken from the `noise` input port. Breaks the falloff's perfect circle
## into a ragged coastline. 0 leaves the edge geometric.
@export_range(0.0, 500.0, 1.0, "or_greater") var distance_noise: float = 0.0:
	set(v):
		distance_noise = maxf(v, 0.0)
		emit_changed()


func op() -> StringName:
	return &"falloff"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return false


func input_count() -> int:
	return 4


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "strength", "radius", "noise"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.HEIGHT,
		PortType.FLOAT,
		PortType.FLOAT,
		PortType.HEIGHT,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return strength
		2: return radius
		3: return 0.0
		_: return 0.0


## The 0..1 attenuation at a world point. Shared by eval_cell and by the gate, so a criterion that checks
## the attenuation curve tests the same arithmetic the bake runs.
func attenuation(p_wx: float, p_wz: float, p_radius: float, p_noise: float) -> float:
	var dx: float = p_wx - centre.x
	var dz: float = p_wz - centre.y
	var d: float = 0.0
	match shape:
		Shape.RADIAL: d = sqrt(dx * dx + dz * dz)
		Shape.SQUARE: d = maxf(absf(dx), absf(dz))
		Shape.AXIS_X: d = absf(dx)
		Shape.AXIS_Z: d = absf(dz)
	d += distance_noise * p_noise

	# smoothstep returns 0 below `radius` and 1 past `radius + feather`; the attenuation is its complement.
	# A zero feather would make smoothstep's edges equal, so step to a hard edge rather than divide by 0.
	var t: float = 0.0
	if feather <= 0.0:
		t = 0.0 if d <= p_radius else 1.0
	else:
		t = smoothstep(p_radius, p_radius + feather, d)

	var a: float = 1.0 - t
	if invert:
		a = 1.0 - a
	return a


func eval_cell(p_wx: float, p_wz: float, p_inputs: PackedFloat32Array) -> float:
	var base_in: float = p_inputs[0] if (p_inputs.size() > 0) else 0.0
	if is_nan(base_in):
		return NAN

	var st: float = p_inputs[1] if (p_inputs.size() > 1 and not is_nan(p_inputs[1])) else strength
	var r: float = p_inputs[2] if (p_inputs.size() > 2 and not is_nan(p_inputs[2])) else radius
	var nz: float = p_inputs[3] if (p_inputs.size() > 3 and not is_nan(p_inputs[3])) else 0.0

	var a: float = attenuation(p_wx, p_wz, r, nz)
	return base_in * lerpf(1.0, a, clampf(st, 0.0, 1.0))


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(strength):
		w.append("%s: Strength is 0, so it passes the input through unchanged." % display_name())
	elif is_zero_approx(radius) and is_zero_approx(feather) and not invert:
		w.append("%s: Radius and Feather are both 0, so everything outside the centre point is cut to 0." % display_name())
	return w
