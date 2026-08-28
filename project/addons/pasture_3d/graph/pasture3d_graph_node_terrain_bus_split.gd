# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeTerrainBusSplit — UTILITY node that unbundles a TERRAIN_BUS connection into separate
# height, mask, water_depth, sediment, and flow channel wires.
@tool
class_name Pasture3DGraphNodeTerrainBusSplit
extends Pasture3DGraphNode


func op() -> StringName:
	return &"terrain_bus_split"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["bus"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.TERRAIN_BUS])


func output_count() -> int:
	return 5


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "mask", "water_depth", "sediment", "flow"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.HEIGHT,
		PortType.MASK,
		PortType.HEIGHT,
		PortType.MASK,
		PortType.MASK,
	])


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, _p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var h: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	var m: PackedFloat32Array = (p_inputs[1] as PackedFloat32Array) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array) else Pasture3DGraphOps.filled(n, 1.0)
	var w: PackedFloat32Array = (p_inputs[2] as PackedFloat32Array) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	var s: PackedFloat32Array = (p_inputs[3] as PackedFloat32Array) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	var f: PackedFloat32Array = (p_inputs[4] as PackedFloat32Array) if (p_inputs.size() > 4 and p_inputs[4] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	return [h, m, w, s, f]
