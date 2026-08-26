# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeOutput — the graph's SINK: its single input is the field the graph hands back to its
# host. A graph that contains an Output node uses it as the output automatically
# (Pasture3DTerrainGraph.output_index), so the standard paradigm is to wire the pipeline INTO it rather than
# pressing "Set as Output" on some node. When the graph is a step in a brush's modifier stack, this field
# becomes the surface passed to the next modifier — or, if the graph is the last step, the surface applied
# to the brush.
#
# A cell passthrough: eval_cell returns its one input unchanged, so it costs nothing and folds away. It has
# no output port of its own — its value leaves the graph, nothing downstream consumes it (see has_output).
@tool
class_name Pasture3DGraphNodeOutput
extends Pasture3DGraphNode


func op() -> StringName:
	return &"output"


func role() -> Role:
	return Role.FILTER


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["result"])


## The sink exposes no output port — its value is the graph's result, read by the host, not by another node.
func has_output() -> bool:
	return false


func eval_cell(_p_wx: float, _p_wz: float, p_inputs: PackedFloat32Array) -> float:
	return p_inputs[0] if p_inputs.size() > 0 else 0.0
