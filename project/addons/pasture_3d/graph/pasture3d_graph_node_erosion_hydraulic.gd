# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeErosionHydraulic — a hydrodynamic hydraulic erosion SOLVER/filter.
# Simulates continuous rainfall, downhill water routing, slope-limited sediment capacity, erosion pickup,
# sediment transport, deposition, and evaporation over an elevation heightfield.
#
# ---- Outputs ----
#   port 0  "height"    HEIGHT  eroded surface elevation (metres)
#   port 1  "sediment"  MASK    accumulated sediment / deposition concentration
#   port 2  "flow"      MASK    water flow accumulation / drainage paths
@tool
class_name Pasture3DGraphNodeErosionHydraulic
extends Pasture3DGraphNode

enum Evaluation { LIVE, FROZEN }

@export_group("Simulation")
## Number of simulation passes. More iterations deepen channels and carve drainage networks.
@export_range(1, 100, 1, "or_greater") var iterations: int = 25:
	set(v):
		iterations = maxi(v, 1)
		_param_changed()

## Amount of rain water added per cell on each iteration pass. Higher rain rate produces stronger flow accumulation.
@export_range(0.001, 0.5, 0.005, "or_greater") var rain_rate: float = 0.05:
	set(v):
		rain_rate = maxf(v, 0.0)
		_param_changed()

## Fraction of water that evaporates per pass [0.0..1.0].
@export_range(0.0, 1.0, 0.005) var evaporation_rate: float = 0.02:
	set(v):
		evaporation_rate = clampf(v, 0.0, 1.0)
		_param_changed()

## Maximum sediment that water can carry per unit of flow velocity and slope.
@export_range(0.1, 50.0, 0.5, "or_greater") var sediment_capacity: float = 8.0:
	set(v):
		sediment_capacity = maxf(v, 0.0)
		_param_changed()

## Rate at which soil/rock is dissolved into flowing water when sediment is below capacity [0.0..1.0].
@export_range(0.0, 1.0, 0.01) var erosion_speed: float = 0.5:
	set(v):
		erosion_speed = clampf(v, 0.0, 1.0)
		_param_changed()

## Rate at which excess sediment drops out of water and settles when above capacity [0.0..1.0].
@export_range(0.0, 1.0, 0.01) var deposition_speed: float = 0.4:
	set(v):
		deposition_speed = clampf(v, 0.0, 1.0)
		_param_changed()

## Minimum slope gradient used for sediment capacity to maintain transport across shallow beds.
@export_range(0.0, 0.5, 0.005) var min_slope: float = 0.01:
	set(v):
		min_slope = maxf(v, 0.0)
		_param_changed()

## FROZEN means this node serves its own cache, which only the GDScript evaluator can do. See
## Pasture3DGraphNode.blocks_native().
func blocks_native() -> bool:
	return evaluation == Evaluation.FROZEN


@export_group("Evaluation")
## LIVE re-solves on every evaluation; FROZEN caches the solve until Bake is pressed.
@export var evaluation: Evaluation = Evaluation.LIVE:
	set(v):
		evaluation = v
		emit_changed()

@export_tool_button("Bake Hydraulic Erosion") var _bake_btn = clear_cache

# ---- Runtime freeze state ----
var _cache: Dictionary = {}
var _cache_key: int = 0
var _dirty_since_bake: bool = false
var _stale: bool = false


func op() -> StringName:
	return &"erosion_hydraulic"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 5


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "iterations", "rain_rate", "erosion_speed", "deposition_speed"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.HEIGHT,
		PortType.INT,
		PortType.FLOAT,
		PortType.FLOAT,
		PortType.FLOAT,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return float(iterations)
		2: return rain_rate
		3: return erosion_speed
		4: return deposition_speed
		_: return 0.0


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


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if _stale:
		w.append("%s is FROZEN and input or parameters changed. Press Bake to re-solve." % display_name())
	if is_zero_approx(rain_rate) or is_zero_approx(erosion_speed):
		w.append("%s: Rain Rate or Erosion Speed is 0, so no erosion will occur." % display_name())
	return w


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	var iters: int = int(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else iterations
	var rr: float = float(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else rain_rate
	var es: float = float(p_inputs[3][0]) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and p_inputs[3].size() > 0) else erosion_speed
	var ds: float = float(p_inputs[4][0]) if (p_inputs.size() > 4 and p_inputs[4] is PackedFloat32Array and p_inputs[4].size() > 0) else deposition_speed

	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)

	if evaluation == Evaluation.FROZEN:
		var key := _surface_hash(surface, p_gw, p_gh)
		if not _cache.is_empty():
			if _dirty_since_bake or key != _cache_key:
				_set_stale(true)
			return _cache[_cache_key]
		var solved := _solve_dynamic(surface, p_gw, p_gh, p_rect, iters, rr, es, ds)
		_cache = {}
		_cache_key = key
		_cache[key] = solved
		_dirty_since_bake = false
		_set_stale(false)
		return solved

	if not _cache.is_empty():
		_cache.clear()
	_set_stale(false)
	return _solve_dynamic(surface, p_gw, p_gh, p_rect, iters, rr, es, ds)


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


func _surface_hash(p_surface: PackedFloat32Array, p_gw: int, p_gh: int) -> int:
	var h := hash(p_gw) ^ (hash(p_gh) << 1)
	h = h ^ hash(p_surface)
	return h


func _solve_dynamic(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_iters: int, p_rr: float, p_es: float, p_ds: float) -> Array:
	var n := p_gw * p_gh
	var params := {
		"iterations": p_iters,
		"rain_rate": p_rr,
		"evaporation_rate": evaporation_rate,
		"sediment_capacity": sediment_capacity,
		"erosion_speed": p_es,
		"deposition_speed": p_ds,
		"min_slope": min_slope,
	}
	if not ClassDB.class_has_method("Pasture3DUtil", "erosion_hydraulic_solve_grid_best"):
		push_error("[Pasture3D] Pasture3DUtil.erosion_hydraulic_solve_grid_best is not bound. Rebuild GDExtension.")
		return [p_surface.duplicate(), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	var res: Dictionary = Pasture3DUtil.erosion_hydraulic_solve_grid_best(p_surface, p_gw, p_gh, p_rect, params)
	if not bool(res.get("ok", false)):
		push_error("[Pasture3D] Hydraulic erosion native solve failed.")
		return [p_surface.duplicate(), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	return [res["height"], res["sediment"], res["flow"]]
