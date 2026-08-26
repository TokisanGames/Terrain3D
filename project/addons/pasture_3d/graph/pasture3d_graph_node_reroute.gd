# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeReroute — a lightweight 1-in / 1-out pass-through cell node used to route long wires cleanly.
# Has zero effect on height values: passes its single input straight to output.
@tool
class_name Pasture3DGraphNodeReroute
extends Pasture3DGraphNode


func op() -> StringName:
	return &"reroute"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return false


func has_output() -> bool:
	return true


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["in"])


func eval_cell(_p_wx: float, _p_wz: float, p_inputs: PackedFloat32Array) -> float:
	return p_inputs[0] if p_inputs.size() > 0 else 0.0
