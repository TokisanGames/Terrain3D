# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeTerrainBusMerge — COMBINER node that bundles individual height, mask, water_depth,
# sediment, and flow channels into a single multi-channel TERRAIN_BUS connection noodle.
@tool
class_name Pasture3DGraphNodeTerrainBusMerge
extends Pasture3DGraphNode


func op() -> StringName:
	return &"terrain_bus_merge"


func role() -> Role:
	return Role.COMBINER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 5


func input_names() -> PackedStringArray:
	return PackedStringArray(["height", "mask", "water_depth", "sediment", "flow"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.HEIGHT,
		PortType.MASK,
		PortType.HEIGHT,
		PortType.MASK,
		PortType.MASK,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		1: return 1.0 # Mask default open
		_: return 0.0


func output_count() -> int:
	return 5


func output_names() -> PackedStringArray:
	return PackedStringArray(["bus", "mask", "water_depth", "sediment", "flow"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.TERRAIN_BUS,
		PortType.MASK,
		PortType.HEIGHT,
		PortType.MASK,
		PortType.MASK,
	])


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, _p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var h: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	var m: PackedFloat32Array = (p_inputs[1] as PackedFloat32Array) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array) else Pasture3DGraphOps.fill(n, 1.0)
	var w: PackedFloat32Array = (p_inputs[2] as PackedFloat32Array) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	var s: PackedFloat32Array = (p_inputs[3] as PackedFloat32Array) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	var f: PackedFloat32Array = (p_inputs[4] as PackedFloat32Array) if (p_inputs.size() > 4 and p_inputs[4] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	return [h, m, w, s, f]
