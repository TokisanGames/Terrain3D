# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeBlend — a COMBINER cell node: two input ports (A, B) combined per cell by `mode`.
# The two-input merge is what makes the graph a DAG rather than a chain, and the modes mirror the relief
# op-program's Blend enum so the vocabulary stays one.
@tool
class_name Pasture3DGraphNodeBlend
extends Pasture3DGraphNode

## How A and B combine. ADD/SUB stack relief; MUL gates one by the other; MAX/MIN take the upper/lower
## envelope (a hill that never digs, a valley that never bulges).
enum Mode { ADD, SUB, MUL, MAX, MIN }

@export var mode: Mode = Mode.ADD:
	set(v):
		mode = v
		emit_changed()


func op() -> StringName:
	return &"blend"


func role() -> Role:
	return Role.COMBINER


func input_count() -> int:
	return 2


func input_names() -> PackedStringArray:
	return PackedStringArray(["a", "b"])


func eval_cell(_p_wx: float, _p_wz: float, p_inputs: PackedFloat32Array) -> float:
	var a: float = p_inputs[0] if p_inputs.size() > 0 else 0.0
	var b: float = p_inputs[1] if p_inputs.size() > 1 else 0.0
	match mode:
		Mode.ADD: return a + b
		Mode.SUB: return a - b
		Mode.MUL: return a * b
		Mode.MAX: return maxf(a, b)
		Mode.MIN: return minf(a, b)
	return a
