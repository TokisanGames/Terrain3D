# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevErosion — reference/dev erosion node.
# Used for algorithm prototyping, A/B testing, and automated headless CI parity verification.
@tool
class_name Pasture3DGraphNodeDevErosion
extends Pasture3DGraphNode

enum Evaluation { LIVE, FROZEN }

@export_range(1, 200, 1, "or_greater") var iterations: int = 15:
	set(v):
		iterations = maxi(v, 1)
		_param_changed()

@export_range(0.0, 1.0, 0.005, "or_greater") var erosion_rate: float = 0.05:
	set(v):
		erosion_rate = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var area_exponent: float = 0.45:
	set(v):
		area_exponent = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(0.0, 10.0, 0.01, "or_greater") var hillslope_diffusion: float = 0.15:
	set(v):
		hillslope_diffusion = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var deposition: float = 0.0:
	set(v):
		deposition = clampf(v, 0.0, 1.0)
		_param_changed()

@export_group("Evaluation")
@export var evaluation: Evaluation = Evaluation.FROZEN:
	set(v):
		evaluation = v
		emit_changed()

@export_tool_button("Bake Erosion") var _bake_btn = clear_cache

var _cache: Dictionary = {}
var _cache_key: int = 0
var _dirty_since_bake: bool = false
var _stale: bool = false


func op() -> StringName:
	return &"dev_erosion"


func role() -> Role:
	return Role.SOLVER


func display_name() -> String:
	return "[Dev/GD] Erosion"


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["field"])


func output_count() -> int:
	return 5


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "flow", "erosion", "deposition", "wetness"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK, PortType.MASK, PortType.MASK, PortType.MASK])


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
		var solved := _solve(surface, p_gw, p_gh, p_rect)
		_cache = {}
		_cache_key = key
		_cache[key] = solved
		_dirty_since_bake = false
		_set_stale(false)
		return solved

	if not _cache.is_empty():
		_cache.clear()
	_set_stale(false)
	return _solve(surface, p_gw, p_gh, p_rect)


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


func _solve(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var dx := p_rect.size.x / float(maxi(p_gw, 1))
	var dz := p_rect.size.y / float(maxi(p_gh, 1))
	var cell_size := sqrt(maxf(dx * dz, 1e-12))
	var params := {
		"iterations": iterations,
		"erosion_rate": erosion_rate,
		"area_exponent": area_exponent,
		"diffusion": hillslope_diffusion,
		"deposition": deposition,
	}
	if not ClassDB.class_has_method("Pasture3DUtil", "erosion_solve_grid"):
		push_error("[Pasture3D] Pasture3DUtil.erosion_solve_grid is not bound.")
		return [p_surface, Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n),
				Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	var res: Dictionary = Pasture3DUtil.erosion_solve_grid(p_surface, p_gw, p_gh, cell_size, params,
			PackedFloat32Array())
	if res.is_empty() or not bool(res.get("ok", false)):
		return [p_surface, Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n),
				Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]
	return [res["z"], res["flow"], res["ero"], res["dep"], res["wet"]]


func _surface_hash(p_surface: PackedFloat32Array, p_gw: int, p_gh: int) -> int:
	var h := hash(p_gw) ^ (hash(p_gh) << 1)
	h = h ^ hash(p_surface)
	return h
