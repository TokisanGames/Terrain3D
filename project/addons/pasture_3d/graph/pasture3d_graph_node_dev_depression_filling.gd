# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevDepressionFilling — pure GDScript reference oracle for Priority-Flood depression filling.
# Used for algorithm prototyping, A/B testing, and automated headless CI parity verification.
@tool
class_name Pasture3DGraphNodeDevDepressionFilling
extends Pasture3DGraphNode

@export_range(0.0, 0.01, 0.00005, "exp") var epsilon_slope: float = 0.0001:
	set(v):
		epsilon_slope = maxf(v, 0.0)
		emit_changed()

@export_range(0.0, 50.0, 0.5, "or_greater") var fill_depth_limit: float = 0.0:
	set(v):
		fill_depth_limit = maxf(v, 0.0)
		emit_changed()

@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		emit_changed()


func op() -> StringName:
	return &"dev_depression_filling"


func role() -> Role:
	return Role.FILTER


func display_name() -> String:
	return "[Dev/GD] Depression Filling"


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["input"])


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var in_grid: PackedFloat32Array
	if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and (p_inputs[0] as PackedFloat32Array).size() == n:
		in_grid = p_inputs[0]
	else:
		return Pasture3DGraphOps.zeros(n)

	if is_zero_approx(amount):
		return in_grid.duplicate()

	return _eval_grid_gdscript(in_grid, p_gw, p_gh, p_rect)


func _eval_grid_gdscript(in_grid: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var dx := p_rect.size.x / maxf(float(p_gw - 1), 1.0) if (p_rect.size.x > 0.0 and p_gw > 1) else 2.0
	var dz := p_rect.size.y / maxf(float(p_gh - 1), 1.0) if (p_rect.size.y > 0.0 and p_gh > 1) else 2.0

	var filled := _priority_flood_fill(in_grid, p_gw, p_gh, dx, dz, epsilon_slope, fill_depth_limit)

	if is_equal_approx(amount, 1.0):
		return filled

	var out := PackedFloat32Array()
	out.resize(n)
	for i in range(n):
		if is_finite(in_grid[i]) and is_finite(filled[i]):
			out[i] = lerpf(in_grid[i], filled[i], amount)
		else:
			out[i] = in_grid[i]
	return out


static func _priority_flood_fill(p_h: PackedFloat32Array, p_gw: int, p_gh: int, p_dx: float, p_dz: float,
		p_eps: float, p_depth_limit: float) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var filled := PackedFloat32Array()
	filled.resize(n)
	filled.fill(INF)

	var visited := PackedByteArray()
	visited.resize(n)

	var heap := _MinHeap.new()

	for iz in range(p_gh):
		for ix in range(p_gw):
			var idx := iz * p_gw + ix
			var is_edge := (ix == 0 or ix == p_gw - 1 or iz == 0 or iz == p_gh - 1)
			var val := p_h[idx]

			if not is_finite(val):
				visited[idx] = 1
				filled[idx] = NAN
			elif is_edge:
				visited[idx] = 1
				filled[idx] = val
				heap.push(val, idx)

	var diag_d := sqrt(p_dx * p_dx + p_dz * p_dz)
	var offsets: Array[Vector3] = [
		Vector3(-1, 0, p_dx), Vector3(1, 0, p_dx),
		Vector3(0, -1, p_dz), Vector3(0, 1, p_dz),
		Vector3(-1, -1, diag_d), Vector3(1, -1, diag_d),
		Vector3(-1, 1, diag_d), Vector3(1, 1, diag_d)
	]

	while not heap.is_empty():
		var top := heap.pop()
		var spill_z: float = top[0]
		var cur_idx: int = int(top[1])
		var c_ix := cur_idx % p_gw
		var c_iz := cur_idx / p_gw

		for off in offsets:
			var nx := c_ix + int(off.x)
			var nz := c_iz + int(off.y)
			if nx < 0 or nx >= p_gw or nz < 0 or nz >= p_gh:
				continue

			var n_idx := nz * p_gw + nx
			if visited[n_idx] == 1:
				continue

			visited[n_idx] = 1
			var raw_z := p_h[n_idx]

			if not is_finite(raw_z):
				filled[n_idx] = NAN
				continue

			var min_spill := spill_z + p_eps * off.z
			var spill_elev := maxf(raw_z, min_spill)
			heap.push(spill_elev, n_idx)

			var filled_z := spill_elev
			if p_depth_limit > 0.0 and (filled_z - raw_z) > p_depth_limit:
				filled_z = raw_z + p_depth_limit

			filled[n_idx] = filled_z

	return filled


class _MinHeap:
	var _items: Array = []

	func is_empty() -> bool:
		return _items.is_empty()

	func push(val: float, idx: int) -> void:
		_items.append([val, idx])
		_sift_up(_items.size() - 1)

	func pop() -> Array:
		if _items.is_empty():
			return [INF, -1]
		var top: Array = _items[0]
		var last: Array = _items.pop_back()
		if not _items.is_empty():
			_items[0] = last
			_sift_down(0)
		return top

	func _sift_up(i: int) -> void:
		while i > 0:
			var parent := (i - 1) / 2
			if _items[i][0] < _items[parent][0]:
				var tmp: Array = _items[i]
				_items[i] = _items[parent]
				_items[parent] = tmp
				i = parent
			else:
				break

	func _sift_down(i: int) -> void:
		var size := _items.size()
		while true:
			var smallest := i
			var left := 2 * i + 1
			var right := 2 * i + 2
			if left < size and _items[left][0] < _items[smallest][0]:
				smallest = left
			if right < size and _items[right][0] < _items[smallest][0]:
				smallest = right
			if smallest != i:
				var tmp: Array = _items[i]
				_items[i] = _items[smallest]
				_items[smallest] = tmp
				i = smallest
			else:
				break
