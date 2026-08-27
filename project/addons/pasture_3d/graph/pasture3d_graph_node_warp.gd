# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeWarp — a domain-warp coordinate distortion CELL node.
# Warps 2D world-sampling coordinates (wx, wz) through procedural vector noise fields to create
# swirling rock striations, folded strata, glacial shears, and organic meandering landscapes.
@tool
class_name Pasture3DGraphNodeWarp
extends Pasture3DGraphNode

enum WarpType { SIMPLEX = 0, FRACTAL = 1 }

@export_group("Warp Noise")
## Warp algorithm type: Simplex noise vector offset or multi-octave Fractal domain warp.
@export var warp_type: WarpType = WarpType.SIMPLEX:
	set(v):
		warp_type = v
		_dirty = true
		emit_changed()

## Frequency of the coordinate distortion noise field.
@export_range(0.0001, 0.5, 0.0005, "or_greater") var frequency: float = 0.01:
	set(v):
		frequency = maxf(v, 0.00001)
		_dirty = true
		emit_changed()

## Displacement amplitude (strength) in world meters. How far coordinates are pushed.
@export_range(0.0, 200.0, 0.5, "or_greater") var strength: float = 20.0:
	set(v):
		strength = maxf(v, 0.0)
		emit_changed()

## Number of fractal octaves in the vector distortion field.
@export_range(1, 8, 1) var octaves: int = 3:
	set(v):
		octaves = clampi(v, 1, 8)
		_dirty = true
		emit_changed()

## Height output amplitude in meters when generating elevation.
@export_range(0.0, 500.0, 0.5, "or_greater") var amplitude: float = 15.0:
	set(v):
		amplitude = maxf(v, 0.0)
		emit_changed()

## Roughness / lacunarity gain between octaves [0.0..1.0].
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
	return &"warp"


func role() -> Role:
	return Role.FILTER


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

	# Compute 2D coordinate displacement vector
	var dx: float = 0.0
	var dz: float = 0.0

	if strength > 0.0:
		dx = _noise_x.get_noise_2d(p_wx, p_wz) * strength
		dz = _noise_z.get_noise_2d(p_wx, p_wz) * strength

	var warped_x := p_wx + dx
	var warped_z := p_wz + dz

	# Sample distorted noise field at warped coordinates
	var sample := _noise_out.get_noise_2d(warped_x, warped_z)
	var generated_h := sample * amplitude

	return base_in + generated_h


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(strength) and is_zero_approx(amplitude):
		w.append("%s: Strength and Amplitude are 0, so no warped relief is generated." % display_name())
	return w


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
	_noise_out.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise_out.fractal_octaves = octaves
	_noise_out.fractal_gain = roughness
	_noise_out.frequency = frequency
	_noise_out.seed = seed + 2147483647

	_dirty = false
