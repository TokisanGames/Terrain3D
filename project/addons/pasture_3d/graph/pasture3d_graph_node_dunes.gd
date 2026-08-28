# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDunes — a GENERATOR cell node: asymmetric dune ridges (a long windward slope, a short
# slip face) sampled at each cell's WORLD XZ, in metres. No inputs — it PRODUCES a texture. Crests wander
# so they are not dead straight.
#
# Like the Furrows node, this is the clean-category counterpart of the relief DUNES op: it delegates to
# Pasture3DReliefMaterial._dunes so a Dunes node and a relief Dunes material agree to the byte, but here it
# is a pure generator with none of the material's accumulator/selector/blend wrapper.
@tool
class_name Pasture3DGraphNodeDunes
extends Pasture3DGraphNode

## Crest-to-trough height at full output, in METRES.
@export var amplitude: float = 1.0:
	set(v):
		amplitude = v
		emit_changed()
## Distance from one crest to the next, in metres.
@export_range(2.0, 256.0, 0.5, "or_greater") var wavelength: float = 40.0:
	set(v):
		wavelength = maxf(v, 0.1)
		emit_changed()
## Direction the dunes march, in degrees. Crests run perpendicular to this.
@export_range(0.0, 360.0, 1.0) var direction_degrees: float = 0.0:
	set(v):
		direction_degrees = v
		emit_changed()
## Where the crest sits within one wavelength. 0.5 = symmetric; lower gives the classic long windward
## slope and abrupt slip face.
@export_range(0.05, 0.95, 0.01) var asymmetry: float = 0.7:
	set(v):
		asymmetry = clampf(v, 0.05, 0.95)
		emit_changed()
## Above 1 broadens the troughs and narrows the crests; below 1 rounds everything off.
@export_range(0.2, 4.0, 0.01) var crest_sharpness: float = 1.4:
	set(v):
		crest_sharpness = maxf(v, 0.01)
		emit_changed()

@export_group("Wander")
## How far crests drift sideways along their length, in metres. 0 = perfectly straight ridges.
@export_range(0.0, 64.0, 0.5, "or_greater") var wander_amount: float = 12.0:
	set(v):
		wander_amount = maxf(v, 0.0)
		_dirty = true
		emit_changed()
## Length scale of that drift, in metres. Larger = long lazy curves.
@export_range(4.0, 512.0, 1.0, "or_greater") var wander_size: float = 120.0:
	set(v):
		wander_size = maxf(v, 0.01)
		_dirty = true
		emit_changed()
@export var seed: int = 0:
	set(v):
		seed = v
		_dirty = true
		emit_changed()

# The wander field, built once and rebuilt only when a shaping property changes — the same construction as
# the relief DUNES op's noise, so the two sample identically.
var _wander: FastNoiseLite = null
var _dirty := true


func op() -> StringName:
	return &"dunes"


func role() -> Role:
	return Role.GENERATOR


func input_count() -> int:
	return 5


func input_names() -> PackedStringArray:
	return PackedStringArray(["amplitude", "wavelength", "direction", "asymmetry", "sharpness"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.FLOAT,
		PortType.FLOAT,
		PortType.FLOAT,
		PortType.FLOAT,
		PortType.FLOAT,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return amplitude
		1: return wavelength
		2: return direction_degrees
		3: return asymmetry
		4: return crest_sharpness
		_: return 0.0


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var a: float = float(p_inputs[0][0]) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and p_inputs[0].size() > 0) else amplitude
	var wl: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else wavelength
	var dir: float = float(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else direction_degrees
	var asym: float = float(p_inputs[3][0]) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and p_inputs[3].size() > 0) else asymmetry
	var sh: float = float(p_inputs[4][0]) if (p_inputs.size() > 4 and p_inputs[4] is PackedFloat32Array and p_inputs[4].size() > 0) else crest_sharpness
	return Pasture3DUtil.dunes_grid(p_gw, p_gh, p_rect, a, wl, dir, asym, sh, wander_amount, wander_size, seed)


func eval_cell(p_wx: float, p_wz: float, p_inputs: PackedFloat32Array) -> float:
	var a: float = p_inputs[0] if (p_inputs.size() > 0 and not is_nan(p_inputs[0])) else amplitude
	var wl: float = p_inputs[1] if (p_inputs.size() > 1 and not is_nan(p_inputs[1])) else wavelength
	var dir: float = p_inputs[2] if (p_inputs.size() > 2 and not is_nan(p_inputs[2])) else direction_degrees
	var asym: float = p_inputs[3] if (p_inputs.size() > 3 and not is_nan(p_inputs[3])) else asymmetry
	var sh: float = p_inputs[4] if (p_inputs.size() > 4 and not is_nan(p_inputs[4])) else crest_sharpness

	var pars := PackedFloat32Array([a, wl, deg_to_rad(dir), asym, sh, 1.0 / maxf(wander_size, 0.01), wander_amount, float(seed)])
	return Pasture3DReliefMaterial._dunes(p_wx, p_wz, pars, 0, _wander_noise())


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(amplitude):
		w.append("%s: Amplitude is 0 m, so the dunes contribute nothing." % display_name())
	return w


func _wander_noise() -> FastNoiseLite:
	if _dirty or _wander == null:
		_wander = Pasture3DReliefMaterial._configure_noise(1.0 / maxf(wander_size, 0.01), 2, 2.0, 0.5, seed, false)
		_dirty = false
	return _wander


func _params() -> PackedFloat32Array:
	# Layout as Pasture3DReliefMaterial._dunes reads it: [amp, wavelength, dir, asymmetry, sharpness,
	# wander_freq(unused in eval), wander_amount, seed].
	return PackedFloat32Array([amplitude, wavelength, deg_to_rad(direction_degrees), asymmetry,
			crest_sharpness, 1.0 / maxf(wander_size, 0.01), wander_amount, float(seed)])
