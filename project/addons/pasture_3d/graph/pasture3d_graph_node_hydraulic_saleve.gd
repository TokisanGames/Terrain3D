# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeHydraulicSaleve — Salève Structural Large-Scale Hydraulic Erosion SOLVER.
# Implements large-scale dendritic drainage routing with noise perturbation, secondary micro-rill flow,
# mountain shape preservation, and transverse channel bank diffusion.
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
@export_range(1, 100, 1, "or_greater") var iterations: int = 25:
	set(v):
		iterations = maxi(v, 1)
		_param_changed()

## Large-scale drainage erosion strength.
@export_range(0.0, 1.0, 0.01) var erosion_strength: float = 0.5:
	set(v):
		erosion_strength = clampf(v, 0.0, 1.0)
		_param_changed()

## Catchment drainage exponent for stream power scaling.
@export_range(0.01, 0.8, 0.01) var drainage_exponent: float = 0.15:
	set(v):
		drainage_exponent = clampf(v, 0.01, 0.8)
		_param_changed()

## Coherent noise strength perturbing drainage flow routing to create natural dendritic branching.
@export_range(0.0, 1.0, 0.01) var drainage_noise: float = 0.15:
	set(v):
		drainage_noise = maxf(v, 0.0)
		_param_changed()

## Mountain shape preservation strength; preserves macroscopic mountain silhouette.
@export_range(0.05, 4.0, 0.05) var shape_preservation: float = 2.0:
	set(v):
		shape_preservation = clampf(v, 0.05, 4.0)
		_param_changed()

## Transverse river channel bank smoothing rate [0.0..0.5].
@export_range(0.0, 0.5, 0.01) var bank_smoothing: float = 0.1:
	set(v):
		bank_smoothing = clampf(v, 0.0, 0.5)
		_param_changed()

## Noise seed for drainage branch perturbation.
@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

@export_group("Sediment Deposition (Stage 2)")
## Alluvial depression hole filling radius ratio.
@export_range(0.0, 0.5, 0.01) var deposition_radius: float = 0.1:
	set(v):
		deposition_radius = maxf(v, 0.0)
		_param_changed()

## Alluvial sediment deposition strength.
@export_range(0.0, 1.0, 0.01) var deposition_strength: float = 0.5:
	set(v):
		deposition_strength = clampf(v, 0.0, 1.0)
		_param_changed()

@export_group("Fine River Incision (Stage 3)")
## Secondary fine dendritic rill erosion strength.
@export_range(0.0, 1.0, 0.005) var stream_strength: float = 0.02:
	set(v):
		stream_strength = clampf(v, 0.0, 1.0)
		_param_changed()

## Secondary stream influence exponent.
@export_range(0.01, 1.0, 0.01) var stream_exp: float = 0.8:
	set(v):
		stream_exp = clampf(v, 0.01, 1.0)
		_param_changed()

@export_group("Post-Processing (Stage 4)")
## Enable spatial post-smoothing.
@export var enable_post_smoothing: bool = false:
	set(v):
		enable_post_smoothing = v
		_param_changed()

## Tonal gain scaling multiplier.
@export_range(0.0, 5.0, 0.05) var gain: float = 1.0:
	set(v):
		gain = maxf(v, 0.0)
		_param_changed()

## Gamma curve contrast exponent.
@export_range(0.1, 4.0, 0.05) var gamma: float = 1.0:
	set(v):
		gamma = maxf(v, 0.01)
		_param_changed()

## Overall mix factor blending eroded terrain with input surface.
@export_range(0.0, 1.0, 0.01) var mix_factor: float = 1.0:
	set(v):
		mix_factor = clampf(v, 0.0, 1.0)
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
	return 4


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "dx", "dy", "mask"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.HEIGHT,
		PortType.FLOAT,
		PortType.FLOAT,
		PortType.MASK,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return 0.0
		2: return 0.0
		3: return 1.0
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
	if is_zero_approx(erosion_strength):
		w.append("%s: Erosion Strength is 0, so no erosion will occur." % display_name())
	return w


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	var dx_in: PackedFloat32Array = (p_inputs[1] as PackedFloat32Array) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array) else PackedFloat32Array()
	var dy_in: PackedFloat32Array = (p_inputs[2] as PackedFloat32Array) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array) else PackedFloat32Array()
	var mask_in: PackedFloat32Array = (p_inputs[3] as PackedFloat32Array) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array) else PackedFloat32Array()

	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)

	if evaluation == Evaluation.FROZEN:
		var key := _surface_hash(surface, p_gw, p_gh)
		if not _cache.is_empty():
			if _dirty_since_bake or key != _cache_key:
				_set_stale(true)
			return _cache[_cache_key]
		var solved := _solve_dynamic(surface, p_gw, p_gh, p_rect, dx_in, dy_in, mask_in)
		_cache = {}
		_cache_key = key
		_cache[key] = solved
		_dirty_since_bake = false
		_set_stale(false)
		return solved

	if not _cache.is_empty():
		_cache.clear()
	_set_stale(false)
	return _solve_dynamic(surface, p_gw, p_gh, p_rect, dx_in, dy_in, mask_in)


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


func _solve_dynamic(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_dx: PackedFloat32Array, p_dy: PackedFloat32Array, p_mask: PackedFloat32Array) -> Array:
	var n := p_gw * p_gh
	var params := {
		"iterations": iterations,
		"erosion_strength": erosion_strength,
		"drainage_exponent": drainage_exponent,
		"drainage_noise": drainage_noise,
		"shape_preservation": shape_preservation,
		"bank_smoothing": bank_smoothing,
		"seed": seed,
		"dx": p_dx,
		"dy": p_dy,
		"mask": p_mask,
		"deposition_radius": deposition_radius,
		"deposition_strength": deposition_strength,
		"stream_strength": stream_strength,
		"stream_exp": stream_exp,
		"enable_post_smoothing": enable_post_smoothing,
		"gain": gain,
		"gamma": gamma,
		"mix_factor": mix_factor,
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
