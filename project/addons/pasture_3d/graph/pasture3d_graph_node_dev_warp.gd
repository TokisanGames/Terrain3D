# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevWarp — pure GDScript reference oracle for domain warp coordinate distortion.
# Used for algorithm prototyping, A/B testing, and automated headless CI parity verification.
@tool
class_name Pasture3DGraphNodeDevWarp
extends Pasture3DGraphNode

enum WarpType { SIMPLE, FRACTAL }

@export var warp_type: WarpType = WarpType.FRACTAL:
	set(v):
		warp_type = v
		_dirty = true
		emit_changed()

@export_range(0.0001, 0.1, 0.0005, "exp") var frequency: float = 0.005:
	set(v):
		frequency = maxf(v, 0.00001)
		_dirty = true
		emit_changed()

@export_range(0.0, 200.0, 0.5) var strength: float = 25.0:
	set(v):
		strength = maxf(v, 0.0)
		emit_changed()

@export_range(1, 8, 1) var octaves: int = 3:
	set(v):
		octaves = clampi(v, 1, 8)
		_dirty = true
		emit_changed()

@export_range(0.0, 500.0, 1.0) var amplitude: float = 50.0:
	set(v):
		amplitude = maxf(v, 0.0)
		emit_changed()

@export_range(0.0, 1.0, 0.05) var roughness: float = 0.5:
	set(v):
		roughness = clampf(v, 0.0, 1.0)
		_dirty = true
		emit_changed()

@export var seed: int = 0:
	set(v):
		seed = v
		_dirty = true
		emit_changed()

var _noise_x: FastNoiseLite = null
var _noise_z: FastNoiseLite = null
var _noise_out: FastNoiseLite = null
var _dirty := true


func op() -> StringName:
	return &"dev_warp"


func role() -> Role:
	return Role.FILTER


func display_name() -> String:
	return "[Dev/GD] Domain Warp"


func needs_grid() -> bool:
	return false


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["field"])


func input_unwired_default(_p_port: int) -> float:
	return 0.0


func eval_cell(p_wx: float, p_wz: float, p_inputs: PackedFloat32Array) -> float:
	var base_in := p_inputs[0] if p_inputs.size() > 0 else 0.0
	if is_nan(base_in):
		return NAN

	_ensure_noise()

	var dx: float = 0.0
	var dz: float = 0.0

	if strength > 0.0:
		dx = _noise_x.get_noise_2d(p_wx, p_wz) * strength
		dz = _noise_z.get_noise_2d(p_wx, p_wz) * strength

	var warped_x := p_wx + dx
	var warped_z := p_wz + dz

	var sample := _noise_out.get_noise_2d(warped_x, warped_z)
	var generated_h := sample * amplitude

	return base_in + generated_h


func _ensure_noise() -> void:
	if not _dirty and _noise_x != null and _noise_z != null and _noise_out != null:
		return

	var ftype = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	var fract = FastNoiseLite.FRACTAL_FBM if warp_type == WarpType.FRACTAL else FastNoiseLite.FRACTAL_NONE

	_noise_x = FastNoiseLite.new()
	_noise_x.noise_type = ftype
	_noise_x.fractal_type = fract
	_noise_x.fractal_octaves = octaves
	_noise_x.fractal_gain = roughness
	_noise_x.frequency = frequency
	_noise_x.seed = seed

	_noise_z = FastNoiseLite.new()
	_noise_z.noise_type = ftype
	_noise_z.fractal_type = fract
	_noise_z.fractal_octaves = octaves
	_noise_z.fractal_gain = roughness
	_noise_z.frequency = frequency
	_noise_z.seed = seed + 1013904223

	_noise_out = FastNoiseLite.new()
	_noise_out.noise_type = ftype
	_noise_out.fractal_type = fract
	_noise_out.fractal_octaves = octaves
	_noise_out.fractal_gain = roughness
	_noise_out.frequency = frequency
	_noise_out.seed = seed + 2038074743

	_dirty = false
