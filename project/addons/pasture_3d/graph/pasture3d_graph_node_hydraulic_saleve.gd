# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeHydraulicSaleve — Salève Structural Hydraulic Erosion SOLVER.
# Combines geological joint-aligned runoff deflection, mountain crest curvature shielding, and sediment deposition.
#
# ---- Outputs ----
#   port 0  "height"       HEIGHT  eroded surface elevation (metres)
#   port 1  "eroded_rock"  MASK    cumulative bedrock incision intensity
#   port 2  "sediment"     MASK    alluvial sediment deposition thickness
@tool
class_name Pasture3DGraphNodeHydraulicSaleve
extends Pasture3DGraphNode

enum Evaluation { LIVE, FROZEN }

@export_group("Simulation")
## Total simulation passes.
@export_range(1, 50, 1, "or_greater") var iterations: int = 20:
	set(v):
		iterations = maxi(v, 1)
		_param_changed()

## Bedrock incision strength multiplier.
@export_range(0.01, 2.0, 0.01, "or_greater") var incision_rate: float = 0.2:
	set(v):
		incision_rate = maxf(v, 0.0)
		_param_changed()

## Azimuth angle (degrees) of structural bedrock fracture joints.
@export_range(0.0, 360.0, 1.0) var joint_azimuth: float = 45.0:
	set(v):
		joint_azimuth = fmod(v, 360.0)
		_param_changed()

## Strength of geological fracture alignment on flow routing [0.0..1.0].
@export_range(0.0, 1.0, 0.01) var joint_strength: float = 0.4:
	set(v):
		joint_strength = clampf(v, 0.0, 1.0)
		_param_changed()

## Protection factor shielding sharp mountain ridge crests from water rounding [0.0..1.0].
@export_range(0.0, 1.0, 0.01) var ridge_preservation: float = 0.8:
	set(v):
		ridge_preservation = clampf(v, 0.0, 1.0)
		_param_changed()

## Alluvial sediment settling rate in flatter basins [0.0..1.0].
@export_range(0.0, 1.0, 0.01) var deposition_rate: float = 0.3:
	set(v):
		deposition_rate = clampf(v, 0.0, 1.0)
		_param_changed()

## Transverse river channel bank smoothing rate [0.0..0.5].
@export_range(0.0, 0.5, 0.01) var bank_smoothing: float = 0.1:
	set(v):
		bank_smoothing = clampf(v, 0.0, 0.5)
		_param_changed()

@export_group("Evaluation")
## LIVE re-solves on every evaluation; FROZEN caches the solve until Bake is pressed.
@export var evaluation: Evaluation = Evaluation.LIVE:
	set(v):
		evaluation = v
		emit_changed()

@export_tool_button("Bake Salève Erosion") var _bake_btn = clear_cache

# ---- Runtime freeze state ----
var _cache: Dictionary = {}
var _cache_key: int = 0
var _dirty_since_bake: bool = false
var _stale: bool = false


func op() -> StringName:
	return &"hydraulic_saleve"


func role() -> Role:
	return Role.SOLVER


func display_name() -> String:
	return "Salève Hydraulic Erosion"


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 5


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "mask", "iterations", "joint_azimuth", "joint_strength"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.HEIGHT,
		PortType.MASK,
		PortType.INT,
		PortType.FLOAT,
		PortType.FLOAT,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return 1.0
		2: return float(iterations)
		3: return joint_azimuth
		4: return joint_strength
		_: return 0.0


func output_count() -> int:
	return 3


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "eroded_rock", "sediment"])


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
		w.append("%s: Incision Rate is 0, so no erosion will occur." % display_name())
	return w


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	var mask_in: PackedFloat32Array = (p_inputs[1] as PackedFloat32Array) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array) else PackedFloat32Array()
	var iters: int = int(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else iterations
	var az: float = float(p_inputs[3][0]) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and p_inputs[3].size() > 0) else joint_azimuth
	var js: float = float(p_inputs[4][0]) if (p_inputs.size() > 4 and p_inputs[4] is PackedFloat32Array and p_inputs[4].size() > 0) else joint_strength

	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)

	if evaluation == Evaluation.FROZEN:
		var key := _surface_hash(surface, p_gw, p_gh)
		if not _cache.is_empty():
			if _dirty_since_bake or key != _cache_key:
				_set_stale(true)
			return _cache[_cache_key]
		var solved := _solve_dynamic(surface, p_gw, p_gh, p_rect, iters, az, js, mask_in)
		_cache = {}
		_cache_key = key
		_cache[key] = solved
		_dirty_since_bake = false
		_set_stale(false)
		return solved

	if not _cache.is_empty():
		_cache.clear()
	_set_stale(false)
	return _solve_dynamic(surface, p_gw, p_gh, p_rect, iters, az, js, mask_in)


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


func _solve_dynamic(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_iters: int, p_az: float, p_js: float, p_mask: PackedFloat32Array) -> Array:
	var n := p_gw * p_gh
	var params := {
		"iterations": p_iters,
		"incision_rate": incision_rate,
		"joint_azimuth": p_az,
		"joint_strength": p_js,
		"ridge_preservation": ridge_preservation,
		"deposition_rate": deposition_rate,
		"bank_smoothing": bank_smoothing,
		"mask": p_mask,
	}

	if not ClassDB.class_has_method("Pasture3DUtil", "hydraulic_saleve_solve_grid"):
		push_error("[Pasture3D] Pasture3DUtil.hydraulic_saleve_solve_grid is not bound. Rebuild GDExtension.")
		return [p_surface.duplicate(), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	var res: Dictionary = Pasture3DUtil.hydraulic_saleve_solve_grid(p_surface, p_gw, p_gh, p_rect, params)
	if not bool(res.get("ok", false)):
		push_error("[Pasture3D] Salève hydraulic native solve failed.")
		return [p_surface.duplicate(), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	return [
		res["height"] as PackedFloat32Array,
		res["eroded_rock"] as PackedFloat32Array,
		res["sediment"] as PackedFloat32Array,
	]
