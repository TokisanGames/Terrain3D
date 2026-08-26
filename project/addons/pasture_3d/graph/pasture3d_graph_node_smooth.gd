# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeSmooth — a FILTER grid node: the NaN-aware separable blur, `passes` times, over its
# one input. It reads neighbours, so it is a GRID node — the graph's first proof that the cell/grid split
# carries the same weight here as in the brush stack.
#
# Shares its blur with the stack's Smooth op through Pasture3DGraphOps.blur_nan, so the two are provably
# the same operation.
@tool
class_name Pasture3DGraphNodeSmooth
extends Pasture3DGraphNode

## Blur iterations. 0 = identity (the input passes through untouched).
@export_range(0, 20, 1, "or_greater") var passes: int = 1:
	set(v):
		passes = maxi(v, 0)
		emit_changed()


func op() -> StringName:
	return &"smooth"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 1


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, _p_rect: Rect2) -> PackedFloat32Array:
	# Duplicate so the blur does not mutate the upstream node's cached grid (the evaluator may hand the
	# same grid to more than one consumer).
	var g: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array).duplicate() if p_inputs.size() > 0 \
			else Pasture3DGraphOps.zeros(p_gw * p_gh)
	return Pasture3DGraphOps.blur_nan(g, p_gw, p_gh, passes)


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if passes == 0:
		w.append("%s: Passes is 0, so it passes its input through unchanged." % display_name())
	return w
