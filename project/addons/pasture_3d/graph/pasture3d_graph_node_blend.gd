# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeBlend — a COMBINER cell node: two input ports (A, B) combined per cell by `mode`,
# plus an optional MASK/weight port that gates the combine. The two-input merge is what makes the graph a
# DAG rather than a chain, and the modes mirror the relief op-program's Blend enum so the vocabulary stays
# one.
#
# ---- The mask port (port 2) ----
#
# When wired, `result = lerp(a, blended, mask)`: the mask [0,1] chooses per cell how much of the combined
# value replaces A, so a solver's deposition/flow channel can stamp B's detail only where the mask is hot.
# Its unwired default is 1.0 (see input_unwired_default) — a Blend with no mask wired is exactly the old
# two-input blend, so existing graphs are unchanged.
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
	return 3


func input_names() -> PackedStringArray:
	return PackedStringArray(["a", "b", "mask"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.HEIGHT, PortType.MASK])


## The mask (port 2) reads 1.0 when unwired, so a Blend with no mask is the plain two-input combine.
func input_unwired_default(p_port: int) -> float:
	return 1.0 if p_port == 2 else 0.0


func eval_cell(_p_wx: float, _p_wz: float, p_inputs: PackedFloat32Array) -> float:
	var a: float = p_inputs[0] if p_inputs.size() > 0 else 0.0
	var b: float = p_inputs[1] if p_inputs.size() > 1 else 0.0
	var m: float = p_inputs[2] if p_inputs.size() > 2 else 1.0
	var blended := a
	match mode:
		Mode.ADD: blended = a + b
		Mode.SUB: blended = a - b
		Mode.MUL: blended = a * b
		Mode.MAX: blended = maxf(a, b)
		Mode.MIN: blended = minf(a, b)
	# A gates how much of the combine replaces the base. m == 1 (the unwired default) is the plain blend.
	return lerpf(a, blended, clampf(m, 0.0, 1.0))
