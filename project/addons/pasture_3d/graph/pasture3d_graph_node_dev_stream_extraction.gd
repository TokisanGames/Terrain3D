# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevStreamExtraction — pure GDScript reference oracle for Stream Extraction & Thalweg routing.
# Used for algorithm prototyping, A/B testing, and automated headless CI parity verification.
@tool
class_name Pasture3DGraphNodeDevStreamExtraction
extends Pasture3DGraphNode

enum Evaluation { LIVE, FROZEN }

@export_group("Simulation")
@export_range(1.0, 500.0, 1.0) var min_catchment_cells: float = 30.0:
	set(v):
		min_catchment_cells = maxf(v, 1.0)
		_param_changed()

@export_range(0.0, 50.0, 0.5) var carve_depth: float = 4.0:
	set(v):
		carve_depth = maxf(v, 0.0)
		_param_changed()

@export_range(1.0, 100.0, 1.0) var channel_width: float = 12.0:
	set(v):
		channel_width = maxf(v, 1.0)
		_param_changed()

@export_range(0.0, 1.0, 0.05) var bank_falloff: float = 0.5:
	set(v):
		bank_falloff = clampf(v, 0.0, 1.0)
		_param_changed()

@export_group("Evaluation")
@export var evaluation: Evaluation = Evaluation.LIVE:
	set(v):
		evaluation = v
		emit_changed()

@export_tool_button("Bake Streams") var _bake_btn = clear_cache

var _cache: Dictionary = {}
var _cache_key: int = 0
var _dirty_since_bake: bool = false
var _stale: bool = false
var _last_stream_points: PackedVector3Array = PackedVector3Array()


func op() -> StringName:
	return &"dev_stream_extraction"


func role() -> Role:
	return Role.SOLVER


func display_name() -> String:
	return "[Dev/GD] Stream Extraction"


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["terrain"])


func output_count() -> int:
	return 3


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "channel_mask", "flow_rate"])


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
	var out_h := p_h.duplicate()
	var out_channel := PackedFloat32Array()
	var out_flow := PackedFloat32Array()
	out_channel.resize(n)
	out_flow.resize(n)

	var dx := p_rect.size.x / maxf(float(p_gw - 1), 1.0) if (p_rect.size.x > 0.0 and p_gw > 1) else 2.0
	var dz := p_rect.size.y / maxf(float(p_gh - 1), 1.0) if (p_rect.size.y > 0.0 and p_gh > 1) else 2.0

	var filled := Pasture3DGraphNodeDevDepressionFilling._priority_flood_fill(p_h, p_gw, p_gh, dx, dz, 0.0001, 0.0)

	var order: Array[int] = []
	order.resize(n)
	for i in range(n):
		order[i] = i
	order.sort_custom(func(a: int, b: int) -> bool:
		return filled[a] > filled[b]
	)

	var receiver := PackedInt32Array()
	receiver.resize(n)
	receiver.fill(-1)

	var diag_d := sqrt(dx * dx + dz * dz)
	var offsets: Array[Vector3] = [
		Vector3(-1, 0, dx), Vector3(1, 0, dx),
		Vector3(0, -1, dz), Vector3(0, 1, dz),
		Vector3(-1, -1, diag_d), Vector3(1, -1, diag_d),
		Vector3(-1, 1, diag_d), Vector3(1, 1, diag_d)
	]

	for iz in range(p_gh):
		for ix in range(p_gw):
			var idx := iz * p_gw + ix
			var zh := filled[idx]
			if not is_finite(zh):
				continue

			var max_slope := 0.0
			var best_rec := -1
			for off in offsets:
				var nx := ix + int(off.x)
				var nz := iz + int(off.y)
				if nx < 0 or nx >= p_gw or nz < 0 or nz >= p_gh:
					continue
				var n_idx := nz * p_gw + nx
				var n_zh := filled[n_idx]
				if not is_finite(n_zh):
					continue
				var slope := (zh - n_zh) / off.z
				if slope > max_slope:
					max_slope = slope
					best_rec = n_idx

			receiver[idx] = best_rec

	var accum := PackedFloat32Array()
	accum.resize(n)
	accum.fill(1.0)

	var max_accum := 1.0
	for idx in order:
		var rec := receiver[idx]
		if rec >= 0 and rec < n:
			accum[rec] += accum[idx]
			if accum[rec] > max_accum:
				max_accum = accum[rec]

	for i in range(n):
		var flow := accum[i]
		out_flow[i] = clampf(flow / maxf(max_accum, 1.0), 0.0, 1.0)

		if flow >= min_catchment_cells and is_finite(out_h[i]):
			var intensity := clampf((flow - min_catchment_cells) / maxf(min_catchment_cells * 2.0, 1.0), 0.0, 1.0)
			out_channel[i] = intensity
			var carve := carve_depth * intensity
			out_h[i] -= carve

	_trace_primary_streamline(accum, receiver, p_gw, p_gh, p_h, p_rect, dx, dz)
	return [out_h, out_channel, out_flow]


func _trace_primary_streamline(p_accum: PackedFloat32Array, p_rec: PackedInt32Array,
		p_gw: int, p_gh: int, p_h: PackedFloat32Array, p_rect: Rect2, p_dx: float, p_dz: float) -> void:
	var pts := PackedVector3Array()

	var max_idx := -1
	var max_val := min_catchment_cells
	for i in range(p_accum.size()):
		if p_accum[i] > max_val:
			max_val = p_accum[i]
			max_idx = i

	if max_idx < 0:
		_last_stream_points = pts
		return

	var stream_cells: Array[int] = [max_idx]
	var visited := {}
	var curr := max_idx

	while curr >= 0 and curr < p_rec.size() and not visited.has(curr):
		visited[curr] = true
		curr = p_rec[curr]
		if curr >= 0:
			stream_cells.append(curr)

	for c_idx in stream_cells:
		var ix := c_idx % p_gw
		var iz := c_idx / p_gw
		var wx := p_rect.position.x + ix * p_dx
		var wz := p_rect.position.y + iz * p_dz
		var wy := p_h[c_idx] if is_finite(p_h[c_idx]) else 0.0
		pts.append(Vector3(wx, wy, wz))

	_last_stream_points = pts


func _grid_hash(arr: PackedFloat32Array) -> int:
	var h: int = arr.size()
	for i in range(0, arr.size(), maxi(1, arr.size() / 32)):
		h = (h * 31) ^ int(arr[i] * 1000.0)
	return h
