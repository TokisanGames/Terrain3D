# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeInput — the graph's SOURCE for the surface it is handed. When a graph runs as a step in
# a brush's modifier stack (Pasture3DNodeGraph), this yields the working surface entering the step: the
# brush's own shape plus every modifier above the graph step. Wire it in to READ the terrain the graph is
# processing — smooth it, add relief to it, gate on it — rather than generating in a vacuum.
#
# It is a GRID node with no inputs: its whole grid is supplied by the evaluator, not computed. A graph run
# with no surface to offer (a headless evaluate that passes none, or a whole-terrain host that has none yet)
# reads a defined flat 0, never invented values.
@tool
class_name Pasture3DGraphNodeInput
extends Pasture3DGraphNode


func op() -> StringName:
	return &"input"


func role() -> Role:
	return Role.GENERATOR


## A grid node: its value is the whole incoming surface, which is not point-evaluable.
func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 0


func input_names() -> PackedStringArray:
	return PackedStringArray()


## Never actually called — the evaluator fills an Input node's grid from the surface it was handed, before
## it would dispatch here. Kept defined (a flat 0) so a stray caller gets nothing rather than an error.
func eval_grid(_p_inputs: Array, p_gw: int, p_gh: int, _p_mask, _p_rect: Rect2) -> PackedFloat32Array:
	return Pasture3DGraphOps.zeros(p_gw * p_gh)
