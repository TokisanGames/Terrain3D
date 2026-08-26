# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeConst — a GENERATOR cell node that outputs one fixed height everywhere. Small on
# purpose: it is the offset/bias a Blend needs, and it gives gates a known field to assert against.
@tool
class_name Pasture3DGraphNodeConst
extends Pasture3DGraphNode

## The value written to every cell, in metres.
@export var value: float = 0.0:
	set(v):
		value = v
		emit_changed()


func op() -> StringName:
	return &"const"


func role() -> Role:
	return Role.GENERATOR


func input_count() -> int:
	return 0


func input_names() -> PackedStringArray:
	return PackedStringArray()


func eval_cell(_p_wx: float, _p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	return value
