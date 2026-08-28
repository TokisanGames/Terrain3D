# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeNoiseJordan — a GENERATOR cell node: derivative-feedback fractional Brownian motion
# (fBm) sampled at each cell's WORLD XZ, in metres. No inputs.
#
# Unlike standard linear fBm where octaves sum independently, Jordan noise accumulates octave gradients
# and warps subsequent octave coordinates while damping high-frequency noise on steep slopes:
#
#   h_{i+1}(x) = h_i(x) + A_i * N(x * f_i + warp * sum(grad_k)) / (1 + damp * ||sum(grad_k)||^2)
#
# This produces realistic mountain fluting, sharp non-uniform ridges, and natural sediment accumulation
# shelves in a single point-evaluable cell pass.
@tool
class_name Pasture3DGraphNodeNoiseJordan
extends Pasture3DGraphNode

## Height scale at full output, in METRES.
@export var amplitude: float = 100.0:
	set(v):
		amplitude = v
		emit_changed()

## Base spatial frequency. Smaller values make larger mountain massifs.
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

@export_group("Derivative Feedback")
## How strongly accumulated slope gradients displace/warp subsequent octave sample positions.
@export_range(0.0, 2.0, 0.01) var warp_strength: float = 0.35:
	set(v):
		warp_strength = maxf(v, 0.0)
		emit_changed()

## How strongly accumulated steepness damps/suppresses high-frequency octaves on cliff faces.
@export_range(0.0, 2.0, 0.01) var damp_strength: float = 0.8:
	set(v):
		damp_strength = maxf(v, 0.0)
		emit_changed()

@export var seed: int = 0:
	set(v):
		seed = v
		_dirty = true
		emit_changed()

var _noise: FastNoiseLite = null
var _dirty := true


func op() -> StringName:
	return &"noise_jordan"


func role() -> Role:
	return Role.GENERATOR


func input_count() -> int:
	return 0


func input_names() -> PackedStringArray:
	return PackedStringArray()


func eval_grid(_p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return Pasture3DUtil.noise_jordan_grid(p_gw, p_gh, p_rect, amplitude, frequency, octaves, gain, lacunarity, warp_strength, damp_strength, seed)


func eval_cell(p_wx: float, p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	if is_zero_approx(amplitude) or octaves <= 0:
		return 0.0

	var nz := _get_noise()
	var total_h := 0.0
	var cur_amp := 1.0
	var cur_freq := frequency
	var sum_grad := Vector2.ZERO
	var max_amp := 0.0

	const EPS: float = 0.2

	for i in range(octaves):
		# Warp octave sampling coordinates by accumulated gradient
		var sample_pos := Vector2(p_wx, p_wz) * cur_freq + sum_grad * warp_strength
		var n_val := nz.get_noise_2d(sample_pos.x, sample_pos.y)

		# Analytical finite-difference gradient of the noise basis
		var n_dx := (nz.get_noise_2d(sample_pos.x + EPS, sample_pos.y) - nz.get_noise_2d(sample_pos.x - EPS, sample_pos.y)) / (2.0 * EPS)
		var n_dz := (nz.get_noise_2d(sample_pos.x, sample_pos.y + EPS) - nz.get_noise_2d(sample_pos.x, sample_pos.y - EPS)) / (2.0 * EPS)
		var grad := Vector2(n_dx, n_dz)

		# Damping factor based on accumulated gradient magnitude
		var damp := 1.0 / (1.0 + damp_strength * sum_grad.length_squared())

		total_h += cur_amp * n_val * damp
		sum_grad += grad * cur_amp * damp
		max_amp += cur_amp

		cur_amp *= gain
		cur_freq *= lacunarity

	var normalized := total_h / maxf(max_amp, 0.0001)
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
