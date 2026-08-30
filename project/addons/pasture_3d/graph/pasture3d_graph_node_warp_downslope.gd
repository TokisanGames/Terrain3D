# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeWarpDownslope — a FILTER grid node: displace the surface ALONG its own gradient.
#
# The distinction from Warp is the whole point. Warp pushes terrain around with noise, in directions that
# have nothing to do with the terrain, and the result reads as "distorted" rather than "worked". This
# pushes each cell downhill — the direction material actually travels — so ridgelines lean, spurs trail
# and valley walls smear the way a fluvial surface does, for a fraction of the cost of an erosion solve.
#
# The useful middle rung between "no erosion" and "freeze a solver". It is not a substitute for one: it
# moves the surface without conserving anything, so it cannot deposit and it cannot cut a channel.
@tool
class_name Pasture3DGraphNodeWarpDownslope
extends Pasture3DGraphNode

## How far a cell is dragged downhill, in WORLD METRES.
@export_range(0.0, 500.0, 0.5, "or_greater") var displacement: float = 20.0:
	set(v):
		displacement = v
		emit_changed()

## The scale the downslope DIRECTION is read at, in WORLD METRES. Small values chase per-cell detail and
## give a noisy, unconvincing warp; set it to the scale of the landform you want to lean.
@export_range(0.0, 500.0, 0.5, "or_greater") var radius: float = 20.0:
	set(v):
		radius = maxf(v, 0.0)
		emit_changed()

## Warp UPslope instead. Physically backwards, and occasionally exactly what a stylised look wants.
@export var reverse: bool = false:
	set(v):
		reverse = v
		emit_changed()

@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		emit_changed()


func op() -> StringName:
	return &"warp_downslope"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 3


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "amount", "mask"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.FLOAT, PortType.MASK])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return amount
		2: return 1.0
		_: return 0.0


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var in_grid: PackedFloat32Array
	if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and (p_inputs[0] as PackedFloat32Array).size() == n:
		in_grid = p_inputs[0]
	else:
		return Pasture3DGraphOps.zeros(n)

	var amt: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else amount
	var mask: PackedFloat32Array = (p_inputs[2] as PackedFloat32Array) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and (p_inputs[2] as PackedFloat32Array).size() == n) else PackedFloat32Array()

	if is_zero_approx(amt) or is_zero_approx(displacement):
		return in_grid.duplicate()

	if not ClassDB.class_has_method("Pasture3DUtil", "warp_downslope_grid"):
		push_error("[Pasture3D] Pasture3DUtil.warp_downslope_grid is not bound. Rebuild GDExtension.")
		return in_grid.duplicate()

	var res: PackedFloat32Array = Pasture3DUtil.warp_downslope_grid(in_grid, mask, p_gw, p_gh, p_rect,
			displacement, radius, reverse, amt)
	if res.size() != n:
		push_error("[Pasture3D] Warp downslope returned an invalid grid size.")
		return in_grid.duplicate()
	return res


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(amount) or is_zero_approx(displacement):
		w.append("%s: Amount or Displacement is 0, so it passes the input through unchanged." % display_name())
	if radius <= 0.0:
		# The direction is then read off the raw surface, so the warp chases per-cell noise instead of the
		# landform — which is the behaviour this node exists to avoid.
		w.append("%s: Radius is 0, so the downslope direction is read from the unsmoothed surface and the warp will follow per-cell noise." % display_name())
	return w
