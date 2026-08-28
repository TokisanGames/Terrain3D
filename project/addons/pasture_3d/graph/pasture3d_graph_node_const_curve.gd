# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeConstCurve — a GENERATOR constant node holding a Curve resource.
@tool
class_name Pasture3DGraphNodeConstCurve
extends Pasture3DGraphNode

## The Curve resource.
@export var curve: Curve:
	set(v):
		curve = v
		emit_changed()


func _init() -> void:
	if curve == null:
		curve = Curve.new()
		curve.add_point(Vector2(0.0, 0.0))
		curve.add_point(Vector2(1.0, 1.0))
	if not curve.changed.is_connected(_on_curve_changed):
		curve.changed.connect(_on_curve_changed)


func _on_curve_changed() -> void:
	emit_changed()


func op() -> StringName:
	return &"const_curve"


func role() -> Role:
	return Role.GENERATOR


func input_count() -> int:
	return 0


func input_names() -> PackedStringArray:
	return PackedStringArray()


func output_port_type() -> int:
	return PortType.CURVE


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.CURVE])


func eval_cell(_p_wx: float, _p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	return curve.sample_baked(0.5) if curve != null else 0.0
