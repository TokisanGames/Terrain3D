# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DReliefDunes — parallel dune ridges with a long windward slope and a short steep slip face,
# wandering so the crests are not dead straight. Sand seas, snow drifts, moraine.
# See PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md §5.
@tool
class_name Pasture3DReliefDunes
extends Pasture3DReliefMaterial

## Crest-to-trough contribution, as a fraction of the brush's Height Scale.
@export_range(0.0, 1.0, 0.01, "or_greater") var amplitude: float = 1.0:
	set(v):
		amplitude = v
		_touch()
## Distance from one crest to the next, in metres.
@export_range(2.0, 256.0, 0.5, "or_greater") var wavelength: float = 40.0:
	set(v):
		wavelength = maxf(v, 0.1)
		_touch()
## Direction the dunes march, in degrees. Crests run perpendicular to this.
@export_range(0.0, 360.0, 1.0) var direction_degrees: float = 0.0:
	set(v):
		direction_degrees = v
		_touch()
## Where the crest sits within one wavelength. 0.5 = symmetric; lower values give the classic long
## windward slope and abrupt slip face.
@export_range(0.05, 0.95, 0.01) var asymmetry: float = 0.7:
	set(v):
		asymmetry = clampf(v, 0.05, 0.95)
		_touch()
## Above 1 broadens the troughs and narrows the crests; below 1 rounds everything off.
@export_range(0.2, 4.0, 0.01) var crest_sharpness: float = 1.4:
	set(v):
		crest_sharpness = maxf(v, 0.01)
		_touch()

@export_group("Wander")
## How far crests drift sideways along their length, in metres. 0 = perfectly straight ridges.
@export_range(0.0, 64.0, 0.5, "or_greater") var wander_amount: float = 12.0:
	set(v):
		wander_amount = maxf(v, 0.0)
		_touch()
## Length scale of that drift, in metres. Larger = long lazy curves.
@export_range(4.0, 512.0, 1.0, "or_greater") var wander_size: float = 120.0:
	set(v):
		wander_size = maxf(v, 0.01)
		_touch()
@export var seed: int = 0:
	set(v):
		seed = v
		_touch()


func _build() -> void:
	_emit(Op.DUNES, Blend.ADD, [amplitude, wavelength, deg_to_rad(direction_degrees), asymmetry,
			crest_sharpness, 1.0 / wander_size, wander_amount, seed])


func _configuration_warning() -> String:
	if amplitude <= 0.0:
		return "Relief Dunes amplitude is 0 — the material will not deform anything."
	return ""
