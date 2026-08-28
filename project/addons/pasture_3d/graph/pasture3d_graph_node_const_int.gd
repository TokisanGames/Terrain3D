# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeConstInt — a GENERATOR constant node that outputs a discrete integer value / count.
@tool
class_name Pasture3DGraphNodeConstInt
extends Pasture3DGraphNode

## The discrete integer value.
@export var value: int = 1:
	set(v):
		value = v
		emit_changed()


func op() -> StringName:
	return &"const_int"


func role() -> Role:
	return Role.GENERATOR


func input_count() -> int:
	return 0


func input_names() -> PackedStringArray:
	return PackedStringArray()


func output_port_type() -> int:
	return PortType.INT


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.INT])


func eval_cell(_p_wx: float, _p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	return float(value)
