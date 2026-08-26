# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeTerrace — a FILTER cell node: quantise the INPUT field into level benches. One input,
# one output; it generates nothing of its own. This is the clean-category split the relief system does not
# make — the relief TERRACE op bands its material's own accumulated fractal, so a Terraces material on flat
# ground still produced steps out of nothing. Here a Terrace node bands exactly what is wired into it, so
# you terrace an upstream Furrows, Noise, or the Input surface by connecting it.
#
# HEIGHT-DOMAIN, not a normalised [0,1] band: the input is metres, so the control is `band_height` in
# metres — a bench every N m of elevation, which is what terracing terrain means. `hardness` shapes the
# riser (0 = smooth ramp/identity, 1 = flat benches with near-vertical steps), reusing the exact exponent
# curve of Pasture3DReliefMaterial._band. `amount` cross-fades between the input and the fully-banded field.
@tool
class_name Pasture3DGraphNodeTerrace
extends Pasture3DGraphNode

## Elevation between benches, in metres. A bench every `band_height` m of height.
@export_range(0.5, 200.0, 0.1, "or_greater") var band_height: float = 10.0:
	set(v):
		band_height = maxf(v, 0.001)
		emit_changed()
## Riser shape. 0 = smooth (identity — no visible step). 1 = flat benches with near-vertical risers.
@export_range(0.0, 1.0, 0.01) var hardness: float = 0.8:
	set(v):
		hardness = clampf(v, 0.0, 1.0)
		emit_changed()
## Cross-fade between the input (0) and the fully-terraced field (1). 1 = full terracing.
@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		emit_changed()

@export_group("Jitter")
## Break the benches off dead-level: shift each cell's banding height by up to this many metres of
## world-space noise, so contour lines waver. 0 = perfectly level benches.
@export_range(0.0, 16.0, 0.1, "or_greater") var jitter: float = 0.0:
	set(v):
		jitter = maxf(v, 0.0)
		_dirty = true
		emit_changed()
## Length scale of that waver, in metres.
@export_range(1.0, 256.0, 0.5, "or_greater") var jitter_size: float = 40.0:
	set(v):
		jitter_size = maxf(v, 0.01)
		_dirty = true
		emit_changed()
@export var seed: int = 0:
	set(v):
		seed = v
		_dirty = true
		emit_changed()

# The jitter field, built once and rebuilt only when a shaping property changes.
var _jitter_noise: FastNoiseLite = null
var _dirty := true


func op() -> StringName:
	return &"terrace"


func role() -> Role:
	return Role.FILTER


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["field"])


func eval_cell(p_wx: float, p_wz: float, p_inputs: PackedFloat32Array) -> float:
	var x := p_inputs[0] if p_inputs.size() > 0 else 0.0
	if is_nan(x):
		return x
	var xj := x
	if jitter > 0.0:
		# Shift the banded height (not the output) so a bench boundary wavers across the ground.
		xj += _jitter_field().get_noise_2d(p_wx, p_wz) * jitter
	# Band in metres: floor to the bench, then reshape the fractional riser by the hardness exponent,
	# exactly as Pasture3DReliefMaterial._band does on a [0,1] coordinate — here scaled to metric bands.
	var bh := maxf(band_height, 0.001)
	var t := xj / bh
	var q := floorf(t)
	var f := t - q
	var stepped := (q + pow(f, 1.0 + hardness * 15.0)) * bh
	# Reunite with the un-jittered input: the jitter perturbs WHICH bench a cell falls to, but the bench
	# value itself is the stepped height; cross-fade that against the true input by `amount`.
	return lerpf(x, stepped, amount)


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(amount):
		w.append("%s: Amount is 0, so it passes the input through unchanged." % display_name())
	elif hardness <= 0.0:
		w.append("%s: Hardness is 0, so the benches have no visible risers." % display_name())
	return w


func _jitter_field() -> FastNoiseLite:
	if _dirty or _jitter_noise == null:
		_jitter_noise = Pasture3DReliefMaterial._configure_noise(1.0 / maxf(jitter_size, 0.01), 2, 2.0, 0.5, seed, false)
		_dirty = false
	return _jitter_noise
