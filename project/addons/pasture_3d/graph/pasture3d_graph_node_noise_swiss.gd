# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeNoiseSwiss — a GENERATOR cell node: Swiss ridge fractal noise sampled at each cell's
# WORLD XZ, in metres. No inputs.
#
# Computes Swiss Alps-style mountainous terrain by accumulating inverted ridge noise modulated by
# local gradient terms, sharpening knife-edge crests and smoothing U-shaped glacial valleys:
#
#   r(x) = (offset - |N(x)|)^2
#   h_{i+1}(x) = h_i(x) + A_i * r(x * f_i + erosion * d) * (1 - erosion * ||d||)
#
# This produces dramatic alpine arêtes, horns, cirques, and flat-bottomed troughs in a single
# point-evaluable cell pass.
@tool
class_name Pasture3DGraphNodeNoiseSwiss
extends Pasture3DGraphNode

## Height scale at full output, in METRES.
@export var amplitude: float = 100.0:
	set(v):
		amplitude = v
		emit_changed()

## Base spatial frequency. Smaller values create wider alpine peaks.
@export_range(0.0001, 0.1, 0.0001, "exp") var frequency: float = 0.002:
	set(v):
		frequency = maxf(v, 0.00001)
		_dirty = true
		emit_changed()

## Number of fractal octave layers (1..10).
@export_range(1, 10, 1) var octaves: int = 6:
	set(v):
		octaves = clampi(v, 1, 10)
		emit_changed()

## Amplitude decay factor per octave.
@export_range(0.1, 1.0, 0.01) var gain: float = 0.5:
	set(v):
		gain = clampf(v, 0.01, 2.0)
		emit_changed()

## Frequency multiplier per octave.
@export_range(1.0, 4.0, 0.05) var lacunarity: float = 2.0:
	set(v):
		lacunarity = maxf(v, 1.0)
		emit_changed()

@export_group("Ridge & Alpine Modulation")
## Offset for the inverted ridge function (1.0 - |noise|). Higher values create thicker massifs.
@export_range(0.5, 2.0, 0.05) var ridge_offset: float = 1.0:
	set(v):
		ridge_offset = maxf(v, 0.1)
		emit_changed()

## Strength of slope-dependent erosion accentuation on ridges and valley floors.
@export_range(0.0, 1.0, 0.01) var erosion_accent: float = 0.15:
	set(v):
		erosion_accent = clampf(v, 0.0, 1.0)
		emit_changed()

@export var seed: int = 0:
	set(v):
		seed = v
		_dirty = true
		emit_changed()

var _noise: FastNoiseLite = null
var _dirty := true


func op() -> StringName:
	return &"noise_swiss"


func role() -> Role:
	return Role.GENERATOR


func input_count() -> int:
	return 0


func input_names() -> PackedStringArray:
	return PackedStringArray()


func eval_cell(p_wx: float, p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	if is_zero_approx(amplitude) or octaves <= 0:
		return 0.0

	var nz := _get_noise()
	var total_h := 0.0
	var cur_amp := 1.0
	var cur_freq := frequency
	var sum_deriv := Vector2.ZERO
	var max_amp := 0.0

	const EPS: float = 0.2

	for i in range(octaves):
		var sample_pos := Vector2(p_wx, p_wz) * cur_freq + sum_deriv * erosion_accent
		var raw_n := nz.get_noise_2d(sample_pos.x, sample_pos.y)

		# Finite-difference derivative of the raw noise basis
		var n_dx := (nz.get_noise_2d(sample_pos.x + EPS, sample_pos.y) - nz.get_noise_2d(sample_pos.x - EPS, sample_pos.y)) / (2.0 * EPS)
		var n_dz := (nz.get_noise_2d(sample_pos.x, sample_pos.y + EPS) - nz.get_noise_2d(sample_pos.x, sample_pos.y - EPS)) / (2.0 * EPS)
		var grad := Vector2(n_dx, n_dz)

		# Inverted ridge shape: (offset - |noise|)^2
		var ridge_term := maxf(0.0, ridge_offset - absf(raw_n))
		var ridge_val := ridge_term * ridge_term

		# Modulation factor from accumulated derivative
		var modulation := clampf(1.0 - erosion_accent * sum_deriv.length(), 0.05, 1.0)

		total_h += cur_amp * ridge_val * modulation
		sum_deriv += grad * cur_amp * (-2.0 * ridge_term * signf(raw_n)) * modulation
		max_amp += cur_amp * (ridge_offset * ridge_offset)

		cur_amp *= gain
		cur_freq *= lacunarity

	var normalized := (total_h / maxf(max_amp, 0.0001)) * 2.0 - 1.0
	return normalized * amplitude


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(amplitude):
		w.append("%s: Amplitude is 0 m, so the noise contributes nothing." % display_name())
	elif octaves <= 0:
		w.append("%s: Octaves is 0, generating flat terrain." % display_name())
	return w


func _get_noise() -> FastNoiseLite:
	if _dirty or _noise == null:
		_noise = FastNoiseLite.new()
		_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_noise.fractal_type = FastNoiseLite.FRACTAL_NONE
		_noise.frequency = 1.0
		_noise.seed = seed
		_dirty = false
	return _noise
