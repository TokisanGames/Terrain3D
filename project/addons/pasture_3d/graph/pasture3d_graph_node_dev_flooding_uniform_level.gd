# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevFloodingUniformLevel — the GDScript oracle twin for FloodingUniformLevel (spec §8.1).
#
# The arithmetic is trivial; what this oracle actually pins is the NaN convention. A masked-out cell (off a
# brush loop) is not "dry land at 0 m" — it is absent, and it must stay absent in the height, the depth and
# the mask alike. That is the part a re-implementation gets wrong, so it is the part written twice.
@tool
class_name Pasture3DGraphNodeDevFloodingUniformLevel
extends Pasture3DGraphNode

@export var water_level: float = 0.0
@export var clamp_terrain: bool = true


func op() -> StringName:
	return &"dev_flooding_uniform_level"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["in"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT])


func output_count() -> int:
	return 3


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "depth", "mask"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.HEIGHT, PortType.MASK])


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, _p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	if p_inputs.is_empty() or not (p_inputs[0] is PackedFloat32Array) or p_inputs[0].size() != n:
		var z := Pasture3DGraphOps.zeros(n)
		return [z, z.duplicate(), z.duplicate()]
	return solve(p_inputs[0], p_gw, p_gh)


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


## Returns [height, depth, mask].
func solve(p_in: PackedFloat32Array, p_gw: int, p_gh: int) -> Array:
	var n := p_gw * p_gh
	var height := PackedFloat32Array()
	var depth := PackedFloat32Array()
	var mask := PackedFloat32Array()
	height.resize(n)
	depth.resize(n)
	mask.resize(n)
	for i in n:
		var z := p_in[i]
		if not is_finite(z):
			height[i] = z
			depth[i] = z
			mask[i] = z
			continue
		var d := maxf(water_level - z, 0.0)
		height[i] = maxf(z, water_level) if clamp_terrain else z
		depth[i] = d
		mask[i] = 1.0 if d > 0.0 else 0.0
	return [height, depth, mask]
