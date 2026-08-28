# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevErosionHydraulic — pure GDScript reference oracle for hydraulic erosion simulation.
# Used for algorithm prototyping, A/B testing, and automated headless CI parity verification.
@tool
class_name Pasture3DGraphNodeDevErosionHydraulic
extends Pasture3DGraphNode

enum Evaluation { LIVE, FROZEN }

@export_group("Simulation")
@export_range(1, 100, 1, "or_greater") var iterations: int = 25:
	set(v):
		iterations = maxi(v, 1)
		_param_changed()

@export_range(0.001, 0.5, 0.005, "or_greater") var rain_rate: float = 0.05:
	set(v):
		rain_rate = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 1.0, 0.005) var evaporation_rate: float = 0.02:
	set(v):
		evaporation_rate = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(0.1, 50.0, 0.5, "or_greater") var sediment_capacity: float = 8.0:
	set(v):
		sediment_capacity = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var erosion_speed: float = 0.5:
	set(v):
		erosion_speed = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var deposition_speed: float = 0.4:
	set(v):
		deposition_speed = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(0.0, 0.5, 0.005) var min_slope: float = 0.01:
	set(v):
		min_slope = maxf(v, 0.0)
		_param_changed()

@export_group("Evaluation")
@export var evaluation: Evaluation = Evaluation.LIVE:
	set(v):
		evaluation = v
		emit_changed()

@export_tool_button("Bake Hydraulic Erosion") var _bake_btn = clear_cache

var _cache: Dictionary = {}
var _cache_key: int = 0
var _dirty_since_bake: bool = false
var _stale: bool = false


func op() -> StringName:
	return &"dev_erosion_hydraulic"


func role() -> Role:
	return Role.SOLVER


func display_name() -> String:
	return "[Dev/GD] Hydraulic Erosion"


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["height"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT])


func output_count() -> int:
	return 3


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "sediment", "flow"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK, PortType.MASK])


func clear_cache() -> void:
	if _cache.is_empty() and not _stale and not _dirty_since_bake:
		return
	_cache.clear()
	_dirty_since_bake = false
	_stale = false
	emit_changed()


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if p_inputs.size() > 0 \
			else Pasture3DGraphOps.zeros(n)
	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)

	if evaluation == Evaluation.FROZEN:
		var key := _surface_hash(surface, p_gw, p_gh)
		if not _cache.is_empty():
			if _dirty_since_bake or key != _cache_key:
				_set_stale(true)
			return _cache[_cache_key]
		var solved := _solve_gdscript(surface, p_gw, p_gh, p_rect)
		_cache = {}
		_cache_key = key
		_cache[key] = solved
		_dirty_since_bake = false
		_set_stale(false)
		return solved

	if not _cache.is_empty():
		_cache.clear()
	_set_stale(false)
	return _solve_gdscript(surface, p_gw, p_gh, p_rect)


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func _param_changed() -> void:
	if not _cache.is_empty():
		_dirty_since_bake = true
	emit_changed()


func _set_stale(p_stale: bool) -> void:
	if _stale == p_stale:
		return
	_stale = p_stale
	if Engine.is_editor_hint():
		emit_changed.call_deferred()


func _surface_hash(p_surface: PackedFloat32Array, p_gw: int, p_gh: int) -> int:
	var h := hash(p_gw) ^ (hash(p_gh) << 1)
	h = h ^ hash(p_surface)
	return h


func _solve_gdscript(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> Array:
	var params := {
		"iterations": iterations,
		"rain_rate": rain_rate,
		"evaporation_rate": evaporation_rate,
		"sediment_capacity": sediment_capacity,
		"erosion_speed": erosion_speed,
		"deposition_speed": deposition_speed,
		"min_slope": min_slope,
	}
	return solve_oracle(p_surface, p_gw, p_gh, p_rect, params)


static func solve_oracle(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_params: Dictionary) -> Array:
	var n := p_gw * p_gh
	var height := p_surface.duplicate()
	var sediment := PackedFloat32Array(); sediment.resize(n); sediment.fill(0.0)
	var water := PackedFloat32Array(); water.resize(n); water.fill(0.0)
	var flow_accum := PackedFloat32Array(); flow_accum.resize(n); flow_accum.fill(0.0)

	var p_iterations: int = maxi(int(p_params.get("iterations", 25)), 1)
	var p_rain: float = maxf(float(p_params.get("rain_rate", 0.05)), 0.0)
	var p_evap: float = clampf(float(p_params.get("evaporation_rate", 0.02)), 0.0, 1.0)
	var p_cap: float = maxf(float(p_params.get("sediment_capacity", 8.0)), 0.0)
	var p_ero_spd: float = clampf(float(p_params.get("erosion_speed", 0.5)), 0.0, 1.0)
	var p_dep_spd: float = clampf(float(p_params.get("deposition_speed", 0.4)), 0.0, 1.0)
	var p_min_slope: float = maxf(float(p_params.get("min_slope", 0.01)), 0.0)

	var dx: float = p_rect.size.x / float(maxi(p_gw, 1))
	var dz: float = p_rect.size.y / float(maxi(p_gh, 1))
	var cell_dist: float = sqrt(maxf(dx * dz, 1e-6))

	var n_dx: Array[int] = [-1, 1, 0, 0]
	var n_dz: Array[int] = [0, 0, -1, 1]
	var n_dist: Array[float] = [dx, dx, dz, dz]

	for _pass in range(p_iterations):
		for i in range(n):
			if is_finite(height[i]):
				water[i] += p_rain
				flow_accum[i] += p_rain

		var next_water := water.duplicate()
		var next_sediment := sediment.duplicate()
		var next_height := height.duplicate()

		for iz in range(p_gh):
			var row := iz * p_gw
			for ix in range(p_gw):
				var i := row + ix
				var h_c: float = height[i]
				var w_c: float = water[i]
				if not is_finite(h_c) or w_c <= 1e-7:
					continue

				var total_alt: float = h_c + w_c
				var diffs: Array[float] = [0.0, 0.0, 0.0, 0.0]
				var total_diff: float = 0.0
				var max_slope: float = 0.0
				var min_downhill_diff: float = INF

				for k in range(4):
					var nx: int = ix + n_dx[k]
					var nz: int = iz + n_dz[k]
					if nx >= 0 and nx < p_gw and nz >= 0 and nz < p_gh:
						var ni: int = nz * p_gw + nx
						var n_h: float = height[ni]
						var n_w: float = water[ni]
						if is_finite(n_h):
							var n_total: float = n_h + n_w
							var diff: float = total_alt - n_total
							if diff > 0.0:
								diffs[k] = diff
								total_diff += diff
								min_downhill_diff = minf(min_downhill_diff, diff)
								var slope: float = diff / n_dist[k]
								if slope > max_slope:
									max_slope = slope

				if total_diff > 0.0:
					var eff_slope: float = maxf(max_slope, p_min_slope)
					var vel: float = sqrt(clampf(eff_slope * cell_dist, 0.05, 50.0))
					var flow_factor: float = log(1.0 + flow_accum[i] * 10.0) + 1.0
					var cap: float = p_cap * eff_slope * vel * w_c * flow_factor * 0.5

					var sed_c: float = sediment[i]
					var max_erode: float = min_downhill_diff * 0.4
					var max_dep: float = min_downhill_diff * 0.4

					if sed_c < cap:
						var erode_amt: float = clampf((cap - sed_c) * p_ero_spd * 0.4, 0.0, max_erode)
						next_height[i] -= erode_amt
						sed_c += erode_amt
					elif sed_c > cap:
						var dep_amt: float = clampf((sed_c - cap) * p_dep_spd * 0.4, 0.0, max_dep)
						next_height[i] += dep_amt
						sed_c -= dep_amt

					var flow_out: float = minf(w_c * 0.6, total_diff * 0.5)
					next_water[i] -= flow_out

					for k in range(4):
						if diffs[k] > 0.0:
							var frac: float = diffs[k] / total_diff
							var moved_w: float = flow_out * frac
							var moved_s: float = sed_c * (moved_w / maxf(w_c, 1e-6))
							var ni: int = (iz + n_dz[k]) * p_gw + (ix + n_dx[k])
							next_water[ni] += moved_w
							next_sediment[ni] += moved_s
							flow_accum[ni] += moved_w
							sed_c = maxf(sed_c - moved_s, 0.0)

					next_sediment[i] = sed_c

		for i in range(n):
			if is_finite(next_height[i]):
				next_water[i] *= (1.0 - p_evap)

		water = next_water
		sediment = next_sediment
		height = next_height

	var max_flow: float = 1e-6
	var max_sed: float = 1e-6
	for i in range(n):
		if is_finite(height[i]):
			max_flow = maxf(max_flow, flow_accum[i])
			max_sed = maxf(max_sed, sediment[i])

	var norm_sediment := PackedFloat32Array(); norm_sediment.resize(n)
	var norm_flow := PackedFloat32Array(); norm_flow.resize(n)
	for i in range(n):
		if is_finite(height[i]):
			norm_sediment[i] = clampf(sediment[i] / max_sed, 0.0, 1.0)
			norm_flow[i] = clampf(flow_accum[i] / max_flow, 0.0, 1.0)
		else:
			norm_sediment[i] = 0.0
			norm_flow[i] = 0.0

	return [height, norm_sediment, norm_flow]
