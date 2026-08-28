# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevLakeFlooding — pure GDScript reference oracle for Lake Flooding & Shoreline extraction.
# Used for algorithm prototyping, A/B testing, and automated headless CI parity verification.
@tool
class_name Pasture3DGraphNodeDevLakeFlooding
extends Pasture3DGraphNode

enum Evaluation { LIVE, FROZEN }
enum FloodMode { SPILLWAY_BASIN, GLOBAL_ELEVATION }

@export_group("Simulation")
@export var flood_mode: FloodMode = FloodMode.SPILLWAY_BASIN:
	set(v):
		flood_mode = v
		_param_changed()

@export_range(-1000.0, 5000.0, 0.5) var water_elevation: float = 50.0:
	set(v):
		water_elevation = v
		_param_changed()

@export_range(0.0, 1.0, 0.01) var flood_percent: float = 1.0:
	set(v):
		flood_percent = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(0.1, 50.0, 0.5) var shoreline_width: float = 5.0:
	set(v):
		shoreline_width = maxf(v, 0.1)
		_param_changed()

@export_group("Evaluation")
@export var evaluation: Evaluation = Evaluation.LIVE:
	set(v):
		evaluation = v
		emit_changed()

@export_tool_button("Bake Lakes") var _bake_btn = clear_cache

var _cache: Dictionary = {}
var _cache_key: int = 0
var _dirty_since_bake: bool = false
var _stale: bool = false
var _last_lake_polys: Array[PackedVector2Array] = []
var _last_water_level: float = 0.0


func op() -> StringName:
	return &"dev_lake_flooding"


func role() -> Role:
	return Role.SOLVER


func display_name() -> String:
	return "[Dev/GD] Lake Flooding"


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["terrain"])


func output_count() -> int:
	return 3


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "water_depth", "shoreline"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK, PortType.MASK])


func clear_cache() -> void:
	if _cache.is_empty() and not _stale and not _dirty_since_bake:
		return
	_cache.clear()
	_dirty_since_bake = false
	_stale = false
	emit_changed()


func _param_changed() -> void:
	_dirty_since_bake = true
	emit_changed()


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var in_grid: PackedFloat32Array
	if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and (p_inputs[0] as PackedFloat32Array).size() == n:
		in_grid = p_inputs[0]
	else:
		in_grid = Pasture3DGraphOps.zeros(n)

	if evaluation == Evaluation.FROZEN:
		var key := _grid_hash(in_grid)
		if not _cache.is_empty():
			if _dirty_since_bake or key != _cache_key:
				_stale = true
			return _cache[_cache_key]
		var solved := _solve_gdscript(in_grid, p_gw, p_gh, p_rect)
		_cache = {}
		_cache_key = key
		_cache[key] = solved
		_dirty_since_bake = false
		_stale = false
		return solved

	if not _cache.is_empty():
		_cache.clear()
	_stale = false
	return _solve_gdscript(in_grid, p_gw, p_gh, p_rect)


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func _solve_gdscript(p_h: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var out_h := PackedFloat32Array()
	var out_depth := PackedFloat32Array()
	var out_shore := PackedFloat32Array()
	out_h.resize(n)
	out_depth.resize(n)
	out_shore.resize(n)

	var dx := p_rect.size.x / maxf(float(p_gw - 1), 1.0) if (p_rect.size.x > 0.0 and p_gw > 1) else 2.0
	var dz := p_rect.size.y / maxf(float(p_gh - 1), 1.0) if (p_rect.size.y > 0.0 and p_gh > 1) else 2.0

	var water_grid := PackedFloat32Array()
	water_grid.resize(n)

	if flood_mode == FloodMode.GLOBAL_ELEVATION:
		_last_water_level = water_elevation
		for i in range(n):
			var zh := p_h[i]
			water_grid[i] = maxf(zh, water_elevation) if is_finite(zh) else NAN
	else:
		var filled := Pasture3DGraphNodeDevDepressionFilling._priority_flood_fill(p_h, p_gw, p_gh, dx, dz, 0.0, 0.0)
		for i in range(n):
			var raw_z := p_h[i]
			var spill_z := filled[i]
			if is_finite(raw_z) and is_finite(spill_z):
				var max_depth := maxf(spill_z - raw_z, 0.0)
				water_grid[i] = raw_z + max_depth * flood_percent
			else:
				water_grid[i] = raw_z

	for i in range(n):
		var raw_z := p_h[i]
		var wz := water_grid[i]
		if not is_finite(raw_z) or not is_finite(wz):
			out_h[i] = NAN
			out_depth[i] = 0.0
			out_shore[i] = 0.0
			continue

		var depth := maxf(wz - raw_z, 0.0)
		out_h[i] = wz
		out_depth[i] = depth
		out_shore[i] = clampf(depth / maxf(shoreline_width, 0.1), 0.0, 1.0)

	_extract_lake_contours(out_depth, p_gw, p_gh, p_rect)
	return [out_h, out_depth, out_shore]


func _extract_lake_contours(p_depth: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> void:
	_last_lake_polys.clear()
	var dx := p_rect.size.x / maxf(float(p_gw - 1), 1.0)
	var dz := p_rect.size.y / maxf(float(p_gh - 1), 1.0)

	var boundary_pts := PackedVector2Array()
	for iz in range(1, p_gh - 1):
		for ix in range(1, p_gw - 1):
			var idx := iz * p_gw + ix
			if p_depth[idx] > 0.05:
				var is_edge := (p_depth[idx - 1] <= 0.05 or p_depth[idx + 1] <= 0.05 or
						p_depth[idx - p_gw] <= 0.05 or p_depth[idx + p_gw] <= 0.05)
				if is_edge:
					var wx := p_rect.position.x + ix * dx
					var wz := p_rect.position.y + iz * dz
					boundary_pts.append(Vector2(wx, wz))

	if boundary_pts.size() >= 3:
		_last_lake_polys.append(boundary_pts)


func _grid_hash(arr: PackedFloat32Array) -> int:
	var h: int = arr.size()
	for i in range(0, arr.size(), maxi(1, arr.size() / 32)):
		h = (h * 31) ^ int(arr[i] * 1000.0)
	return h
