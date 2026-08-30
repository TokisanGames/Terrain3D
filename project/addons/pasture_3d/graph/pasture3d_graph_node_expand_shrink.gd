# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeExpandShrink — a FILTER grid node: grayscale morphology over a metric radius.
#
# Grows terrain outward (Expand), pulls it inward (Shrink), or composes the two to clean up a field:
# Open removes features smaller than the radius, Close fills gaps smaller than it, Gradient returns the
# difference and reads as an edge detector.
#
# Works on heights and on masks alike — it is a local min/max, so it never invents a value that was not
# already somewhere in the neighbourhood.
#
# The mode is SHRINK, not "Erosion". Five nodes in this graph already have Erosion in the name and every
# one is a geological simulation; a morphological erosion sharing that word would be a real trap.
@tool
class_name Pasture3DGraphNodeExpandShrink
extends Pasture3DGraphNode

enum Mode {
	EXPAND, ## Local maximum. Grows bright regions / raises terrain toward its local peaks.
	SHRINK, ## Local minimum. Shrinks bright regions / pulls terrain down toward its local lows.
	OPEN, ## Shrink then Expand. Removes features smaller than the radius, keeps larger ones.
	CLOSE, ## Expand then Shrink. Fills gaps smaller than the radius.
	GRADIENT, ## Expand minus Shrink. The local range — a morphological edge.
}

enum Kernel {
	DISC, ## Circular. Isotropic, no directional bias.
	SQUARE, ## Axis-aligned box. Cheaper, but leaves square corners on round features.
}

@export var mode: Mode = Mode.EXPAND:
	set(v):
		mode = v
		emit_changed()

## Structuring-element radius in WORLD METRES, not cells — so the result is the same shape whatever the
## bake resolution.
@export_range(0.0, 500.0, 0.5, "or_greater") var radius: float = 5.0:
	set(v):
		radius = maxf(v, 0.0)
		emit_changed()

@export var kernel: Kernel = Kernel.DISC:
	set(v):
		kernel = v
		emit_changed()

## Repeat the whole operation this many times. Cheaper than one large radius for a similar reach, and
## rounder, but not identical to it.
@export_range(1, 16, 1) var iterations: int = 1:
	set(v):
		iterations = clampi(v, 1, 64)
		emit_changed()

## Cross-fade between the input (0.0) and the morphed result (1.0).
@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		emit_changed()


func op() -> StringName:
	return &"expand_shrink"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 3


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "radius", "amount"])


func input_port_types() -> PackedInt32Array:
	# `in` is HEIGHT, but the kernel is a pure local min/max and is equally correct on a mask. Typing it
	# HEIGHT keeps the editor's connection rules simple without restricting what it actually does.
	return PackedInt32Array([PortType.HEIGHT, PortType.FLOAT, PortType.MASK])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return radius
		2: return amount
		_: return 0.0


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var in_grid: PackedFloat32Array
	if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and (p_inputs[0] as PackedFloat32Array).size() == n:
		in_grid = p_inputs[0]
	else:
		return Pasture3DGraphOps.zeros(n)

	var rad: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else radius
	var amt: float = float(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else amount

	if is_zero_approx(amt) or rad <= 0.0:
		return in_grid.duplicate()

	var mask: PackedFloat32Array = (p_mask as PackedFloat32Array) if (p_mask is PackedFloat32Array and (p_mask as PackedFloat32Array).size() == n) else PackedFloat32Array()

	if not ClassDB.class_has_method("Pasture3DUtil", "expand_shrink_grid"):
		push_error("[Pasture3D] Pasture3DUtil.expand_shrink_grid is not bound. Rebuild GDExtension.")
		return in_grid.duplicate()

	var res: PackedFloat32Array = Pasture3DUtil.expand_shrink_grid(in_grid, mask, p_gw, p_gh, p_rect,
			int(mode), rad, int(kernel), iterations, amt)
	if res.size() != n:
		push_error("[Pasture3D] Expand/shrink returned an invalid grid size.")
		return in_grid.duplicate()

	return res


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(amount):
		w.append("%s: Amount is 0, so it passes the input through unchanged." % display_name())
	elif radius <= 0.0:
		w.append("%s: Radius is 0, so the structuring element is a single cell and nothing changes." % display_name())
	if mode == Mode.GRADIENT and amount < 1.0:
		# Gradient does not return a modified terrain, it returns a DIFFERENCE — cross-fading it with the
		# input mixes two unrelated quantities and the result reads as neither.
		w.append("%s: Gradient outputs a local height range, not a terrain, so blending it with the input at Amount %.2f mixes two different quantities." % [display_name(), amount])
	return w
