# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DReliefFractal — multi-octave relief: rolling hills (fBm), craggy rock (ridged multifractal), or
# lumpy dunes (billow), with optional domain warping to break up the regularity that plain fBm always has.
# This is the workhorse "make this section craggy" material. See PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md §5.
@tool
class_name Pasture3DReliefFractal
extends Pasture3DReliefMaterial

## HILLS = smooth rolling fBm. CRAGGY = ridged multifractal (sharp ridges, smooth valleys — the classic
## rocky look). LUMPY = billow (rounded mounds, good under dunes and moraine).
enum Style { HILLS, CRAGGY, LUMPY }

@export var style: Style = Style.CRAGGY:
	set(v):
		style = v
		notify_property_list_changed() # sharpness is CRAGGY-only
		_touch()
## Peak-to-trough contribution, as a fraction of the brush's Height Scale.
@export_range(0.0, 1.0, 0.01, "or_greater") var amplitude: float = 1.0:
	set(v):
		amplitude = v
		_touch()
## Size of the largest feature, in metres. Smaller = busier relief. (Frequency is 1 / feature size.)
@export_range(1.0, 512.0, 0.5, "or_greater") var feature_size: float = 64.0:
	set(v):
		feature_size = maxf(v, 0.01)
		_touch()
## Detail levels stacked on top of the base feature. Each octave halves the size and reduces the height
## by Gain. Beyond ~5 the extra octaves fall below the terrain's vertex spacing and only cost time.
@export_range(1, 8) var octaves: int = 5:
	set(v):
		octaves = clampi(v, 1, 8)
		_touch()
## Size ratio between octaves. 2.0 = each octave is half the size of the one before.
@export_range(1.5, 4.0, 0.01) var lacunarity: float = 2.0:
	set(v):
		lacunarity = v
		_touch()
## Height ratio between octaves. Higher = rougher; lower = smoother, more dominated by the base shape.
@export_range(0.1, 0.9, 0.01) var gain: float = 0.5:
	set(v):
		gain = v
		_touch()
## CRAGGY only. Above 1 sharpens ridges into knife edges; below 1 rounds them off.
@export_range(0.25, 4.0, 0.01) var sharpness: float = 1.0:
	set(v):
		sharpness = v
		_touch()
@export var seed: int = 0:
	set(v):
		seed = v
		_touch()

@export_group("Domain Warp")
## Metres of lateral displacement applied to the sample point before the fractal is read. This is what
## turns regular-looking noise into twisted, tectonic-looking relief. 0 = off (no cost).
@export_range(0.0, 64.0, 0.5, "or_greater") var warp_amount: float = 0.0:
	set(v):
		warp_amount = maxf(v, 0.0)
		_touch()
## Size of the warping swirls, in metres. Usually a bit larger than Feature Size.
@export_range(1.0, 512.0, 0.5, "or_greater") var warp_size: float = 96.0:
	set(v):
		warp_size = maxf(v, 0.01)
		_touch()
@export_range(1, 4) var warp_octaves: int = 2:
	set(v):
		warp_octaves = clampi(v, 1, 4)
		_touch()


func _validate_property(property: Dictionary) -> void:
	if property.name == "sharpness" and style != Style.CRAGGY:
		property.usage &= ~PROPERTY_USAGE_EDITOR


func _build() -> void:
	# WARP must be emitted first: it is a DOMAIN op, so it only affects the ops that follow it.
	if warp_amount > 0.0:
		_emit(Op.WARP, Blend.ADD, [warp_amount, 1.0 / warp_size, warp_octaves, seed + 7717])
	var op := Op.FBM
	if style == Style.CRAGGY:
		op = Op.RIDGED
	elif style == Style.LUMPY:
		op = Op.BILLOW
	_emit(op, Blend.ADD, [amplitude, 1.0 / feature_size, octaves, lacunarity, gain, seed, sharpness])


func _configuration_warning() -> String:
	if amplitude <= 0.0:
		return "Relief Fractal amplitude is 0 — the material will not deform anything."
	return ""
