# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeMountainCone — Production UI Node for MountainCone geological primitive.
# Ported from Hesiod / HighMap (mountain_cone.cpp). Generates conical alpine peaks
# with cellular Voronoi knife-edge ridges, strike-angle domain warping, and sigmoid envelope.

@tool
class_name Pasture3DGraphNodeMountainCone
extends Pasture3DGraphNode

## Deterministic random seed for procedural features.
@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

## Apex peak vertical elevation / amplitude in metres.
@export_range(0.0, 100.0, 0.1, "or_greater") var elevation: float = 25.0:
	set(v):
		elevation = maxf(v, 0.0)
		_param_changed()

## Overall spatial footprint scale of the mountain.
@export_range(0.01, 10.0, 0.05) var scale: float = 1.0:
	set(v):
		scale = maxf(v, 0.01)
		_param_changed()

## Number of fractal octaves for ridge refinement.
@export_range(1, 16, 1) var octaves: int = 8:
	set(v):
		octaves = clampi(v, 1, 16)
		_param_changed()

## Spatial wavenumber / density of primary summit ridges.
@export_range(0.1, 20.0, 0.1) var peak_kw: float = 4.0:
	set(v):
		peak_kw = maxf(v, 0.1)
		_param_changed()

## Surface rugosity / micro-roughness.
@export_range(0.0, 1.0, 0.01) var rugosity: float = 0.0:
	set(v):
		rugosity = clampf(v, 0.0, 1.0)
		_param_changed()

## Strike angle (degrees) for geological tectonic deformation.
@export_range(-180.0, 180.0, 1.0) var angle: float = 45.0:
	set(v):
		angle = v
		_param_changed()

## Gamma exponent profile sharpening for knife-edge ridge crests.
@export_range(0.01, 4.0, 0.05) var gamma: float = 0.5:
	set(v):
		gamma = maxf(v, 0.01)
		_param_changed()

## Sigmoidal conical decay sharpness exponent.
@export_range(0.01, 4.0, 0.05) var cone_alpha: float = 1.2:
	set(v):
		cone_alpha = maxf(v, 0.01)
		_param_changed()

## Amplitude of cellular Voronoi knife-edge ridges across the mountain cone.
@export_range(0.0, 4.0, 0.05) var ridge_amp: float = 0.4:
	set(v):
		ridge_amp = maxf(v, 0.0)
		_param_changed()

## Base Simplex noise displacement amplitude for domain warping.
@export_range(0.0, 1.0, 0.01) var base_noise_amp: float = 0.05:
	set(v):
		base_noise_amp = maxf(v, 0.0)
		_param_changed()

## Normalized center coordinates [0..1] of the mountain apex.
@export var center: Vector2 = Vector2(0.5, 0.5):
	set(v):
		center = v
		_param_changed()

enum Evaluation { LIVE, FROZEN }

@export_group("Evaluation")
## LIVE evaluates dynamically; FROZEN caches the result until Bake is pressed.
@export var evaluation: Evaluation = Evaluation.LIVE:
	set(v):
		evaluation = v
		emit_changed()

@export_tool_button("Bake Mountain Cone") var _bake_btn = clear_cache

var _cache: Dictionary = {}
var _cache_key: int = 0
var _dirty_since_bake: bool = false
var _stale: bool = false


func op() -> StringName:
	return &"mountain_cone"


func display_name() -> String:
	return "Mountain Cone"


func input_names() -> PackedStringArray:
	return PackedStringArray(["dx", "dy", "envelope"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.HEIGHT, PortType.MASK])


func output_names() -> PackedStringArray:
	return PackedStringArray(["out"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT])


func clear_cache() -> void:
	if _cache.is_empty() and not _stale and not _dirty_since_bake:
		return
	_cache.clear()
	_dirty_since_bake = false
	_stale = false
	emit_changed()


func _param_changed() -> void:
	if not _cache.is_empty():
		_dirty_since_bake = true
	emit_changed()


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var dx_in: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else PackedFloat32Array()
	var dy_in: PackedFloat32Array = (p_inputs[1] as PackedFloat32Array) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array) else PackedFloat32Array()
	var env_in: PackedFloat32Array = (p_inputs[2] as PackedFloat32Array) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array) else PackedFloat32Array()

	var params := {
		"seed": seed,
		"elevation": elevation,
		"scale": scale,
		"octaves": octaves,
		"peak_kw": peak_kw,
		"rugosity": rugosity,
		"angle": angle,
		"gamma": gamma,
		"cone_alpha": cone_alpha,
		"ridge_amp": ridge_amp,
		"base_noise_amp": base_noise_amp,
		"center": center,
		"dx": dx_in,
		"dy": dy_in,
		"envelope": env_in,
	}

	if not ClassDB.class_has_method("Pasture3DUtil", "mountain_cone_generate_grid"):
		push_error("[Pasture3D] Pasture3DUtil.mountain_cone_generate_grid is not bound. Rebuild GDExtension.")
		return [Pasture3DGraphOps.zeros(n)]

	var res: PackedFloat32Array = Pasture3DUtil.mountain_cone_generate_grid(p_gw, p_gh, p_rect, params)
	return [res]
