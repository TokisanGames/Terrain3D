# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeConstBool — a GENERATOR constant node that outputs a boolean state (true/false).
@tool
class_name Pasture3DGraphNodeConstBool
extends Pasture3DGraphNode

## The boolean toggle state.
@export var value: bool = true:
	set(v):
		value = v
		emit_changed()


func op() -> StringName:
	return &"const_bool"


func role() -> Role:
	return Role.GENERATOR


func input_count() -> int:
	return 0


func input_names() -> PackedStringArray:
	return PackedStringArray()


func output_port_type() -> int:
	return PortType.BOOL


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.BOOL])


func eval_cell(_p_wx: float, _p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	return 1.0 if value else 0.0
