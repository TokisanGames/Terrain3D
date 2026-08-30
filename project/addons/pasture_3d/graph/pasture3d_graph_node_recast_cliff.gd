# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeRecastCliff — a FILTER grid node: push already-steep ground toward a stepped,
# near-vertical face, and leave gentle ground alone.
#
# The vertical-axis complement to Terrace and Strata. Those quantise on HEIGHT — every band sits at the
# same world Y. This quantises on SLOPE, so the faces appear where the terrain is actually steep,
# wherever that happens to be. Wired after Strata it gives banded cliffs; after SmoothFill it gives
# cliff-above-scree.
#
# The talus angle is a real angle, converted to a metric gradient. Hesiod writes this as `talus / shape.x`
# because its heightmaps are normalised over a unit square; doing that here would move the cliff
# threshold every time the bake resolution changed.
@tool
class_name Pasture3DGraphNodeRecastCliff
extends Pasture3DGraphNode

## Ground steeper than this grows a cliff face. Ground below it is untouched.
@export_range(5.0, 85.0, 0.5) var talus_angle_deg: float = 40.0:
	set(v):
		talus_angle_deg = clampf(v, 1.0, 89.0)
		emit_changed()

## The reference-blur radius in WORLD METRES. Sets how wide the cliff face reads.
@export_range(1.0, 500.0, 0.5, "or_greater") var radius: float = 20.0:
	set(v):
		radius = maxf(v, 0.0)
		emit_changed()

## How far the face is pushed out, in metres.
@export_range(0.0, 200.0, 0.5, "or_greater") var amplitude: float = 10.0:
	set(v):
		amplitude = v
		emit_changed()

## Sigmoid sharpness. Higher is a harder, more sheer step.
@export_range(0.1, 20.0, 0.1) var gain: float = 2.0:
	set(v):
		gain = maxf(v, 0.01)
		emit_changed()

## Bearing in degrees that a face must point toward to be recast. Negative means omnidirectional —
## which is the default, because a directional cliff is a deliberate art choice, not a physical one.
@export_range(-1.0, 360.0, 1.0) var direction_deg: float = -1.0:
	set(v):
		direction_deg = v
		emit_changed()

## Angular half-window around Direction, in degrees.
@export_range(0.0, 180.0, 1.0) var direction_spread_deg: float = 60.0:
	set(v):
		direction_spread_deg = clampf(v, 0.0, 180.0)
		emit_changed()

@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		emit_changed()


func op() -> StringName:
	return &"recast_cliff"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 4


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "talus", "amplitude", "mask"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.FLOAT, PortType.FLOAT, PortType.MASK])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return talus_angle_deg
		2: return amplitude
		3: return 1.0
		_: return 0.0


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var in_grid: PackedFloat32Array
	if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and (p_inputs[0] as PackedFloat32Array).size() == n:
		in_grid = p_inputs[0]
	else:
		return Pasture3DGraphOps.zeros(n)

	var talus: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else talus_angle_deg
	var amp: float = float(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else amplitude
	var mask: PackedFloat32Array = (p_inputs[3] as PackedFloat32Array) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and (p_inputs[3] as PackedFloat32Array).size() == n) else PackedFloat32Array()

	if is_zero_approx(amount) or is_zero_approx(amp):
		return in_grid.duplicate()

	if not ClassDB.class_has_method("Pasture3DUtil", "recast_cliff_grid"):
		push_error("[Pasture3D] Pasture3DUtil.recast_cliff_grid is not bound. Rebuild GDExtension.")
		return in_grid.duplicate()

	var res: PackedFloat32Array = Pasture3DUtil.recast_cliff_grid(in_grid, mask, p_gw, p_gh, p_rect,
			talus, radius, amp, gain, direction_deg, direction_spread_deg, amount)
	if res.size() != n:
		push_error("[Pasture3D] Recast cliff returned an invalid grid size.")
		return in_grid.duplicate()
	return res


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(amount) or is_zero_approx(amplitude):
		w.append("%s: Amount or Amplitude is 0, so it passes the input through unchanged." % display_name())
	if direction_deg >= 0.0 and is_zero_approx(direction_spread_deg):
		# A zero spread is a zero-width angular window, so nothing is ever inside it. This looks like a
		# broken node rather than a configured one.
		w.append("%s: Direction is set but Spread is 0, so no face is ever inside the window and nothing is recast." % display_name())
	if talus_angle_deg >= 85.0:
		w.append("%s: A talus angle of %.0f° is steeper than almost any natural slope, so few cells will qualify." % [display_name(), talus_angle_deg])
	return w
