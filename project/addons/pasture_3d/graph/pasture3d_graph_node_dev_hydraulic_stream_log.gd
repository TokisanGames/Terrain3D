# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevHydraulicStreamLog — pure GDScript reference oracle for logarithmic stream-power erosion.
# Solves catchment drainage accumulation and logarithmic bedrock incision: E = K * log(1 + A^m * S^n).
# Used for algorithm prototyping, A/B testing, and automated headless CI parity verification.
@tool
class_name Pasture3DGraphNodeDevHydraulicStreamLog
extends Pasture3DGraphNode

enum Evaluation { LIVE, FROZEN }

@export_group("Simulation")
## Number of simulation passes.
@export_range(1, 50, 1, "or_greater") var iterations: int = 15:
	set(v):
		iterations = maxi(v, 1)
		_param_changed()

## Bedrock channel incision intensity factor.
@export_range(0.01, 2.0, 0.01, "or_greater") var incision_rate: float = 0.15:
	set(v):
		incision_rate = maxf(v, 0.0)
		_param_changed()

## Catchment drainage area power exponent (m ≈ 0.5 in standard stream power law).
@export_range(0.1, 1.5, 0.05) var area_exponent: float = 0.5:
	set(v):
		area_exponent = maxf(v, 0.0)
		_param_changed()

## Local slope gradient power exponent (n ≈ 1.0 in standard stream power law).
@export_range(0.1, 2.0, 0.05) var slope_exponent: float = 1.0:
	set(v):
		slope_exponent = maxf(v, 0.0)
		_param_changed()

## Minimum upstream catchment accumulation required before channel carving begins.
@export_range(0.1, 50.0, 0.5) var min_catchment: float = 1.0:
	set(v):
		min_catchment = maxf(v, 0.0)
		_param_changed()

## Transverse channel diffusion / smoothing rate to avoid single-pixel crevasse artifacts.
@export_range(0.0, 0.5, 0.01) var bank_smoothing: float = 0.1:
	set(v):
		bank_smoothing = clampf(v, 0.0, 0.5)
		_param_changed()

@export_group("Evaluation")
@export var evaluation: Evaluation = Evaluation.LIVE:
	set(v):
		evaluation = v
		emit_changed()

@export_tool_button("Bake Stream-Log Erosion") var _bake_btn = clear_cache

var _cache: Dictionary = {}
var _cache_key: int = 0
var _dirty_since_bake: bool = false
var _stale: bool = false


func op() -> StringName:
	return &"dev_hydraulic_stream_log"


func role() -> Role:
	return Role.SOLVER


func display_name() -> String:
	return "[Dev/GD] Logarithmic Stream Erosion"


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 2


func input_names() -> PackedStringArray:
	return PackedStringArray(["height", "mask"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK])


func output_count() -> int:
	return 3


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "channel_mask", "flow_accumulation"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK, PortType.MASK])


func _param_changed() -> void:
	if evaluation == Evaluation.FROZEN:
		_stale = true
	emit_changed()


func clear_cache() -> void:
	_cache.clear()
	_cache_key = 0
	_dirty_since_bake = false
	_stale = false
	emit_changed()


## Pure GDScript reference oracle for logarithmic stream power erosion.
static func solve_oracle(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_params: Dictionary) -> Array:
	if p_gw < 2 or p_gh < 2 or p_surface.size() != p_gw * p_gh:
		return [PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()]

	var n: int = p_gw * p_gh
	var height := p_surface.duplicate()
	var channel_mask := PackedFloat32Array()
	var flow_accum := PackedFloat32Array()
	channel_mask.resize(n)
	channel_mask.fill(0.0)
	flow_accum.resize(n)
	flow_accum.fill(0.0)

	var iterations: int = maxi(1, int(p_params.get("iterations", 15)))
	var incision_rate: float = maxf(0.0, float(p_params.get("incision_rate", 0.15)))
	var area_exponent: float = maxf(0.0, float(p_params.get("area_exponent", 0.5)))
	var slope_exponent: float = maxf(0.0, float(p_params.get("slope_exponent", 1.0)))
	var min_catchment: float = maxf(0.0, float(p_params.get("min_catchment", 1.0)))
	var bank_smoothing: float = clampf(float(p_params.get("bank_smoothing", 0.1)), 0.0, 0.5)

	var mask: PackedFloat32Array = p_params.get("mask", PackedFloat32Array())
	var has_mask: bool = (mask.size() == n)

	var dx: float = p_rect.size.x / float(maxi(p_gw, 1))
	var dz: float = p_rect.size.y / float(maxi(p_gh, 1))
	var cell_size: float = sqrt(maxf(dx * dz, 1.0e-6))

	var n_dx: Array[int] = [-1, 1, 0, 0, -1, 1, -1, 1]
	var n_dz: Array[int] = [0, 0, -1, 1, -1, -1, 1, 1]
	var n_dist: Array[float] = [dx, dx, dz, dz, sqrt(dx*dx + dz*dz), sqrt(dx*dx + dz*dz), sqrt(dx*dx + dz*dz), sqrt(dx*dx + dz*dz)]

	for pass_idx in range(iterations):
		# 1. Sort indices descending by elevation for DAG accumulation
		var order: Array[int] = []
		order.resize(n)
		for i in range(n):
			order[i] = i

		order.sort_custom(func(a: int, b: int) -> bool:
			var ha: float = height[a]
			var hb: float = height[b]
			if not is_finite(ha):
				return false
			if not is_finite(hb):
				return true
			return ha > hb
		)

		# 2. Accumulate drainage flow
		var current_flow := PackedFloat32Array()
		current_flow.resize(n)
		current_flow.fill(1.0) # Base precipitation 1.0 per cell

		for idx in order:
			var h_c: float = height[idx]
			if not is_finite(h_c):
				continue
			var cx: int = idx % p_gw
			var cz: int = idx / p_gw

			# Find downhill steepest descent neighbors
			var max_drop: float = 0.0
			var sum_drop: float = 0.0
			var drops: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]

			for k in range(8):
				var nx: int = cx + n_dx[k]
				var nz: int = cz + n_dz[k]
				if nx >= 0 and nx < p_gw and nz >= 0 and nz < p_gh:
					var n_idx: int = nz * p_gw + nx
					var h_n: float = height[n_idx]
					if is_finite(h_n) and h_n < h_c:
						var drop: float = (h_c - h_n) / n_dist[k]
						var weighted_drop: float = pow(drop, 1.3)
						drops[k] = weighted_drop
						sum_drop += weighted_drop

			if sum_drop > 1.0e-6:
				var my_flow: float = current_flow[idx]
				for k in range(8):
					if drops[k] > 0.0:
						var nx: int = cx + n_dx[k]
						var nz: int = cz + n_dz[k]
						var n_idx: int = nz * p_gw + nx
						var frac: float = drops[k] / sum_drop
						current_flow[n_idx] += my_flow * frac

		# 3. Compute Logarithmic Stream-Power Incision with lateral bank spreading
		var incision_map := PackedFloat32Array()
		incision_map.resize(n)
		incision_map.fill(0.0)

		for iz in range(p_gh):
			var row: int = iz * p_gw
			for ix in range(p_gw):
				var idx: int = row + ix
				var h_c: float = height[idx]
				if not is_finite(h_c):
					continue

				var m_val: float = mask[idx] if has_mask else 1.0
				if m_val <= 0.001:
					continue

				# Local slope gradient
				var h_l: float = height[row + ix - 1] if ix > 0 and is_finite(height[row + ix - 1]) else h_c
				var h_r: float = height[row + ix + 1] if ix < p_gw - 1 and is_finite(height[row + ix + 1]) else h_c
				var h_u: float = height[(iz - 1) * p_gw + ix] if iz > 0 and is_finite(height[(iz - 1) * p_gw + ix]) else h_c
				var h_d: float = height[(iz + 1) * p_gw + ix] if iz < p_gh - 1 and is_finite(height[(iz + 1) * p_gw + ix]) else h_c

				var gx: float = (h_r - h_l) / (2.0 * dx)
				var gz: float = (h_d - h_u) / (2.0 * dz)
				var slope: float = sqrt(gx * gx + gz * gz)

				var diff: float = current_flow[idx] - min_catchment
				var a_accum: float = diff if (diff > 15.0) else (log(1.0 + exp(diff)) if diff > -15.0 else 0.0)

				if a_accum > 0.01 and slope > 1.0e-5:
					var power: float = pow(a_accum, area_exponent) * pow(slope, slope_exponent)
					var incision: float = incision_rate * log(1.0 + power) * m_val

					var center_weight: float = 1.0 - bank_smoothing * 0.6
					var neighbor_weight: float = (bank_smoothing * 0.6) * 0.25

					incision_map[idx] += incision * center_weight
					if ix > 0: incision_map[row + ix - 1] += incision * neighbor_weight
					if ix < p_gw - 1: incision_map[row + ix + 1] += incision * neighbor_weight
					if iz > 0: incision_map[(iz - 1) * p_gw + ix] += incision * neighbor_weight
					if iz < p_gh - 1: incision_map[(iz + 1) * p_gw + ix] += incision * neighbor_weight

				flow_accum[idx] = current_flow[idx]

		# 4. Apply incision with base-level descent clamping
		var next_height := height.duplicate()
		for iz in range(p_gh):
			var row: int = iz * p_gw
			for ix in range(p_gw):
				var idx: int = row + ix
				var h_c: float = height[idx]
				if not is_finite(h_c):
					continue

				var cut: float = incision_map[idx]
				if cut > 0.0:
					var cx: int = ix
					var cz: int = iz
					var min_downhill: float = h_c
					for k in range(8):
						var nx: int = cx + n_dx[k]
						var nz: int = cz + n_dz[k]
						if nx >= 0 and nx < p_gw and nz >= 0 and nz < p_gh:
							var h_n: float = height[nz * p_gw + nx]
							if is_finite(h_n) and h_n < min_downhill:
								min_downhill = h_n

					var max_cut: float = maxf(0.0, (h_c - min_downhill) + 0.05 * cut)
					cut = minf(cut, max_cut)
					next_height[idx] = h_c - cut
					channel_mask[idx] = maxf(channel_mask[idx], clampf(cut / (incision_rate * 2.0 + 1.0e-5), 0.0, 1.0))

		height = next_height

	return [height, channel_mask, flow_accum]
