# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeErosionThermal — a thermal weathering & talus scree erosion SOLVER/filter.
# Simulates gravitational slope failure along steep cliffs exceeding the critical angle of repose (talus angle),
# shedding material downslope and accumulating scree aprons at slope toes.
#
# ---- Outputs ----
#   port 0  "height"  HEIGHT  stabilized surface elevation (metres)
#   port 1  "talus"   MASK    accumulated talus scree deposition
@tool
class_name Pasture3DGraphNodeErosionThermal
extends Pasture3DGraphNode

enum Evaluation { LIVE, FROZEN }

@export_group("Simulation")
## Critical angle of repose in degrees. Slopes steeper than this angle shed loose rock downhill.
@export_range(0.0, 90.0, 0.5) var talus_angle: float = 30.0:
	set(v):
		talus_angle = clampf(v, 0.0, 90.0)
		_param_changed()

## Number of cellular slippage passes. Higher iterations relax steep cliffs more thoroughly.
@export_range(1, 100, 1, "or_greater") var iterations: int = 25:
	set(v):
		iterations = maxi(v, 1)
		_param_changed()

## Fraction of excess material that slips downhill on each pass [0.0..1.0].
@export_range(0.0, 1.0, 0.01) var settling_rate: float = 0.7:
	set(v):
		settling_rate = clampf(v, 0.0, 1.0)
		_param_changed()

@export_group("Evaluation")
## LIVE re-solves on every evaluation; FROZEN caches the solve until Bake is pressed.
@export var evaluation: Evaluation = Evaluation.LIVE:
	set(v):
		evaluation = v
		emit_changed()

@export_tool_button("Bake Thermal Erosion") var _bake_btn = clear_cache

# ---- Runtime freeze state ----
var _cache: Dictionary = {}
var _cache_key: int = 0
var _dirty_since_bake: bool = false
var _stale: bool = false


func op() -> StringName:
	return &"erosion_thermal"


func role() -> Role:
	return Role.FILTER


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


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if _stale:
		w.append("%s is FROZEN and input or parameters changed. Press Bake to re-solve." % display_name())
	if is_zero_approx(settling_rate):
		w.append("%s: Settling Rate is 0, so no rock slippage will occur." % display_name())
	return w


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
		var solved := _solve(surface, hardness, p_gw, p_gh, p_rect)
		_cache = {}
		_cache_key = key
		_cache[key] = solved
		_dirty_since_bake = false
		_set_stale(false)
		return solved

	if not _cache.is_empty():
		_cache.clear()
	_set_stale(false)
	return _solve(surface, hardness, p_gw, p_gh, p_rect)


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


# ---- Internals -------------------------------------------------------------------------------------

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


func _solve(p_surface: PackedFloat32Array, p_hardness: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	if not ClassDB.class_has_method("Pasture3DUtil", "erosion_thermal_solve_grid"):
		push_error("[Pasture3D] Pasture3DUtil.erosion_thermal_solve_grid is not bound. Rebuild GDExtension.")
		return [p_surface.duplicate(), Pasture3DGraphOps.zeros(n)]

	var res: Dictionary = Pasture3DUtil.erosion_thermal_solve_grid(p_surface, p_hardness, p_gw, p_gh,
			p_rect, talus_angle, iterations, settling_rate)
	if not bool(res.get("ok", false)):
		push_error("[Pasture3D] Thermal erosion native solve failed.")
		return [p_surface.duplicate(), Pasture3DGraphOps.zeros(n)]

	return [res["height"], res["talus"]]
