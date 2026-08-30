# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevWaterMask — the GDScript oracle twin for WaterMask (spec §8.2).
#
# It reuses the Phase 2 distance-transform oracle rather than measuring distance its own way. A shore band is
# only as trustworthy as the distance it is windowed from, and a second distance implementation here would be
# a second chance to disagree about what a metre is — which is the exact bug the band exists to avoid.
@tool
class_name Pasture3DGraphNodeDevWaterMask
extends Pasture3DGraphNode

@export var depth_threshold: float = 0.01
@export var shore_width: float = 8.0
@export var shore_falloff: int = 1 ## Matches Pasture3DGraphNodeWaterMask.ShoreFalloff.


func op() -> StringName:
	return &"dev_water_mask"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["depth"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT])


func output_count() -> int:
	return 2


func output_names() -> PackedStringArray:
	return PackedStringArray(["water", "shore"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.MASK, PortType.MASK])


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	if p_inputs.is_empty() or not (p_inputs[0] is PackedFloat32Array) or p_inputs[0].size() != n:
		var z := Pasture3DGraphOps.zeros(n)
		return [z, z.duplicate()]
	return solve(p_inputs[0], p_gw, p_gh, p_rect)


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


## Returns [water, shore].
func solve(p_depth: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var water := PackedFloat32Array()
	water.resize(n)
	for i in n:
		var d := p_depth[i]
		water[i] = d if not is_finite(d) else (1.0 if d > depth_threshold else 0.0)

	var shore := Pasture3DGraphOps.zeros(n)
	if shore_width <= 0.0:
		return [water, shore]

	# Threshold 0.5 because `water` is already a hard 0/1 field: the transform's own threshold is not a
	# second chance to redefine where the water is.
	var dt := Pasture3DGraphNodeDevDistanceTransform.new()
	dt.threshold = 0.5
	dt.direction = Pasture3DGraphNodeDistanceTransform.Direction.SIGNED
	dt.metric = Pasture3DGraphNodeDistanceTransform.Metric.EUCLIDEAN
	dt.output_units = Pasture3DGraphNodeDistanceTransform.OutputUnits.METRES
	dt.max_distance = 0.0
	var sd: PackedFloat32Array = dt.solve(water, p_gw, p_gh, p_rect)
	if sd.size() != n:
		return [water, shore]

	for i in n:
		var s := sd[i]
		if not is_finite(s):
			shore[i] = s
			continue
		# |d|, so the band is as wide on the wet side as on the dry one.
		var t := clampf(1.0 - absf(s) / shore_width, 0.0, 1.0)
		shore[i] = (t * t * (3.0 - 2.0 * t)) if shore_falloff == 1 else t
	return [water, shore]
