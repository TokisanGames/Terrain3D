# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevErosionThermal — pure GDScript reference oracle for thermal weathering & talus scree erosion.
# Used for algorithm prototyping, A/B testing, and automated headless CI parity verification.
@tool
class_name Pasture3DGraphNodeDevErosionThermal
extends Pasture3DGraphNode

enum Evaluation { LIVE, FROZEN }

@export_group("Simulation")
@export_range(0.0, 90.0, 0.5) var talus_angle: float = 30.0:
	set(v):
		talus_angle = clampf(v, 0.0, 90.0)
		_param_changed()

@export_range(1, 100, 1, "or_greater") var iterations: int = 25:
	set(v):
		iterations = maxi(v, 1)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var settling_rate: float = 0.7:
	set(v):
		settling_rate = clampf(v, 0.0, 1.0)
		_param_changed()

@export_group("Evaluation")
@export var evaluation: Evaluation = Evaluation.LIVE:
	set(v):
		evaluation = v
		emit_changed()

@export_tool_button("Bake Thermal Erosion") var _bake_btn = clear_cache

var _cache: Dictionary = {}
var _cache_key: int = 0
var _dirty_since_bake: bool = false
var _stale: bool = false


func op() -> StringName:
	return &"dev_erosion_thermal"


func role() -> Role:
	return Role.FILTER


func display_name() -> String:
	return "[Dev/GD] Thermal Erosion"


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 2


func input_names() -> PackedStringArray:
	return PackedStringArray(["field", "hardness"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK])


func input_unwired_default(_p_port: int) -> float:
	return 0.0


func output_count() -> int:
	return 2


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "talus"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK])


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

	var hardness: PackedFloat32Array = (p_inputs[1] as PackedFloat32Array) if p_inputs.size() > 1 \
			else Pasture3DGraphOps.zeros(n)
	if hardness.size() != n:
		hardness = Pasture3DGraphOps.zeros(n)

	if evaluation == Evaluation.FROZEN:
		var key := _surface_hash(surface, hardness, p_gw, p_gh)
		if not _cache.is_empty():
			if _dirty_since_bake or key != _cache_key:
				_set_stale(true)
			return _cache[_cache_key]
		var solved := _solve_gdscript(surface, hardness, p_gw, p_gh, p_rect)
		_cache = {}
		_cache_key = key
		_cache[key] = solved
		_dirty_since_bake = false
		_set_stale(false)
		return solved

	if not _cache.is_empty():
		_cache.clear()
	_set_stale(false)
	return _solve_gdscript(surface, hardness, p_gw, p_gh, p_rect)


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


func _surface_hash(p_surface: PackedFloat32Array, p_hardness: PackedFloat32Array, p_gw: int, p_gh: int) -> int:
	var h := hash(p_gw) ^ (hash(p_gh) << 1)
	h = h ^ hash(p_surface) ^ (hash(p_hardness) << 2)
	return h


func _solve_gdscript(p_surface: PackedFloat32Array, p_hardness: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var height := p_surface.duplicate()
	var talus_accum := PackedFloat32Array(); talus_accum.resize(n); talus_accum.fill(0.0)

	var dx: float = p_rect.size.x / float(maxi(p_gw, 1))
	var dz: float = p_rect.size.y / float(maxi(p_gh, 1))
	var diag_dist: float = sqrt(dx * dx + dz * dz)

	var tan_talus: float = tan(deg_to_rad(talus_angle))

	var n_dx: Array[int] = [-1, 1, 0, 0, -1, 1, -1, 1]
	var n_dz: Array[int] = [0, 0, -1, 1, -1, -1, 1, 1]
	var n_dist: Array[float] = [dx, dx, dz, dz, diag_dist, diag_dist, diag_dist, diag_dist]

	for _pass in range(iterations):
		var next_height := height.duplicate()

		for iz in range(p_gh):
			var row := iz * p_gw
			for ix in range(p_gw):
				var i := row + ix
				var h_c: float = height[i]
				if not is_finite(h_c):
					continue

				var hard_c: float = clampf(p_hardness[i], 0.0, 1.0)
				var eff_tan: float = tan_talus * (1.0 + hard_c * 0.75)

				var excess: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
				var total_excess: float = 0.0
				var max_ex: float = 0.0

				for k in range(8):
					var nx: int = ix + n_dx[k]
					var nz: int = iz + n_dz[k]
					if nx >= 0 and nx < p_gw and nz >= 0 and nz < p_gh:
						var ni: int = nz * p_gw + nx
						var n_h: float = height[ni]
						if is_finite(n_h):
							var diff: float = h_c - n_h
							var max_diff: float = n_dist[k] * eff_tan
							if diff > max_diff:
								var ex: float = diff - max_diff
								excess[k] = ex
								total_excess += ex
								if ex > max_ex:
									max_ex = ex

				if total_excess > 0.0:
					var slip_amt: float = clampf(max_ex * 0.5 * settling_rate, 0.0, total_excess * 0.5)

					next_height[i] -= slip_amt
					for k in range(8):
						if excess[k] > 0.0:
							var frac: float = excess[k] / total_excess
							var moved: float = slip_amt * frac
							var ni: int = (iz + n_dz[k]) * p_gw + (ix + n_dx[k])
							next_height[ni] += moved
							talus_accum[ni] += moved

		height = next_height

	var max_talus: float = 1e-6
	for i in range(n):
		if is_finite(height[i]):
			max_talus = maxf(max_talus, talus_accum[i])

	var norm_talus := PackedFloat32Array(); norm_talus.resize(n)
	for i in range(n):
		if is_finite(height[i]):
			norm_talus[i] = clampf(talus_accum[i] / max_talus, 0.0, 1.0)
		else:
			norm_talus[i] = 0.0

	return [height, norm_talus]
