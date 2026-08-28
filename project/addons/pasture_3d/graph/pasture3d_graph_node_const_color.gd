# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeConstColor — a GENERATOR constant node that outputs a Color / tint value.
@tool
class_name Pasture3DGraphNodeConstColor
extends Pasture3DGraphNode

## The Color value.
@export var value: Color = Color.WHITE:
	set(v):
		value = v
		emit_changed()


func op() -> StringName:
	return &"const_color"


func role() -> Role:
	return Role.GENERATOR


func input_count() -> int:
	return 0


func input_names() -> PackedStringArray:
	return PackedStringArray()


func output_port_type() -> int:
	return PortType.COLOR


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.COLOR])


func eval_cell(_p_wx: float, _p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	return value.get_luminance()
