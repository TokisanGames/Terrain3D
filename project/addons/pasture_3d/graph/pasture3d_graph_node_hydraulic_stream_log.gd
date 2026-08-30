# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeHydraulicStreamLog — Logarithmic Stream-Power Bedrock Incision SOLVER.
# Computes hydrological drainage flow accumulation and applies non-linear stream-power incision:
# E = K * log(1 + A^m * S^n), carving deep natural river valleys while preventing runaway gorge blowouts.
#
# ---- Outputs ----
#   port 0  "height"             HEIGHT  eroded surface elevation (metres)
#   port 1  "channel_mask"       MASK    carved stream channel presence
#   port 2  "flow_accumulation"  MASK    drainage catchment flow discharge
@tool
class_name Pasture3DGraphNodeHydraulicStreamLog
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

## Minimum catchment area threshold (cells) before stream incision activates.
@export_range(0.0, 50.0, 0.5) var min_catchment: float = 1.0:
	set(v):
		min_catchment = maxf(v, 0.0)
		_param_changed()

## Transverse river channel bank smoothing rate [0.0..0.5].
@export_range(0.0, 0.5, 0.01) var bank_smoothing: float = 0.1:
	set(v):
		bank_smoothing = clampf(v, 0.0, 0.5)
		_param_changed()

## Relative elevation peak preservation factor [0.0..1.0] (Hesiod peak protection).
@export_range(0.0, 1.0, 0.05) var peak_preservation: float = 0.5:
	set(v):
		peak_preservation = clampf(v, 0.0, 1.0)
		_param_changed()

## Slope gradient shaping power exponent [0.1..2.0].
@export_range(0.1, 2.0, 0.05) var gradient_power: float = 0.8:
	set(v):
		gradient_power = clampf(v, 0.1, 2.0)
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

@export_tool_button("Bake Stream-Log Erosion") var _bake_btn = clear_cache

# ---- Runtime freeze state ----
var _cache: Dictionary = {}
var _cache_key: int = 0
var _dirty_since_bake: bool = false
var _stale: bool = false


func op() -> StringName:
	return &"hydraulic_stream_log"


func role() -> Role:
	return Role.SOLVER


func display_name() -> String:
	return "Logarithmic Stream Erosion"


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 4


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "mask", "iterations", "incision_rate"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.HEIGHT,
		PortType.MASK,
		PortType.INT,
		PortType.FLOAT,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return 1.0
		2: return float(iterations)
		3: return incision_rate
		_: return 0.0


func output_count() -> int:
	return 3


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "channel_mask", "flow_accumulation"])


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
	if is_zero_approx(incision_rate):
		w.append("%s: Incision Rate is 0, so no stream carving will occur." % display_name())
	return w


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	var mask_in: PackedFloat32Array = (p_inputs[1] as PackedFloat32Array) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array) else PackedFloat32Array()
	var iters: int = int(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else iterations
	var ir: float = float(p_inputs[3][0]) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and p_inputs[3].size() > 0) else incision_rate

	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)

	if evaluation == Evaluation.FROZEN:
		var key := _surface_hash(surface, p_gw, p_gh)
		if not _cache.is_empty():
			if _dirty_since_bake or key != _cache_key:
				_set_stale(true)
			return _cache[_cache_key]
		var solved := _solve_dynamic(surface, p_gw, p_gh, p_rect, iters, ir, mask_in)
		_cache = {}
		_cache_key = key
		_cache[key] = solved
		_dirty_since_bake = false
		_set_stale(false)
		return solved

	if not _cache.is_empty():
		_cache.clear()
	_set_stale(false)
	return _solve_dynamic(surface, p_gw, p_gh, p_rect, iters, ir, mask_in)


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


func _solve_dynamic(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_iters: int, p_ir: float, p_mask: PackedFloat32Array) -> Array:
	var n := p_gw * p_gh
	var params := {
		"iterations": p_iters,
		"incision_rate": p_ir,
		"area_exponent": area_exponent,
		"slope_exponent": slope_exponent,
		"min_catchment": min_catchment,
		"bank_smoothing": bank_smoothing,
		"peak_preservation": peak_preservation,
		"gradient_power": gradient_power,
		"mask": p_mask,
	}

	if not ClassDB.class_has_method("Pasture3DUtil", "hydraulic_stream_log_solve_grid"):
		push_error("[Pasture3D] Pasture3DUtil.hydraulic_stream_log_solve_grid is not bound. Rebuild GDExtension.")
		return [p_surface.duplicate(), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	var res: Dictionary = Pasture3DUtil.hydraulic_stream_log_solve_grid(p_surface, p_gw, p_gh, p_rect, params)
	if not bool(res.get("ok", false)):
		push_error("[Pasture3D] Hydraulic stream log native solve failed.")
		return [p_surface.duplicate(), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	return [
		res["height"] as PackedFloat32Array,
		res["channel_mask"] as PackedFloat32Array,
		res["flow_accumulation"] as PackedFloat32Array,
	]
