# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DReliefCrater — a single impact crater: a flattenable bowl, a raised rim, and ejecta decaying
# outward. Sized and oriented by the brush's loop, so it needs Mapping = FIT (one crater per loop) or
# SCATTER (a crater field, phase 2). Under TILE it would repeat once per tile, which the plow warns about.
# See PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md §5.2.
@tool
class_name Pasture3DReliefCrater
extends Pasture3DReliefMaterial

## Depth of the bowl at its centre, as a fraction of the brush's Height Scale.
@export_range(0.0, 1.0, 0.01, "or_greater") var floor_depth: float = 0.7:
	set(v):
		floor_depth = maxf(v, 0.0)
		_touch()
## Height of the raised rim, as a fraction of Height Scale. Real craters have a rim far shallower than
## the bowl is deep; 0.1–0.25 of Floor Depth reads well.
@export_range(0.0, 1.0, 0.01, "or_greater") var rim_height: float = 0.15:
	set(v):
		rim_height = maxf(v, 0.0)
		_touch()
## Where the rim sits and how much room the ejecta gets, as a fraction of the loop radius. 0.25 puts the
## rim crest at 75% of the way out, with ejecta over the remaining quarter.
@export_range(0.02, 0.95, 0.01) var rim_width: float = 0.25:
	set(v):
		rim_width = clampf(v, 0.02, 0.95)
		_touch()
## How fast the ejecta blanket falls off past the rim. 1 = linear, higher = tighter to the rim.
@export_range(0.1, 6.0, 0.05) var ejecta_falloff: float = 2.0:
	set(v):
		ejecta_falloff = maxf(v, 0.01)
		_touch()
## 0 = parabolic bowl. Higher flattens the floor and steepens the walls, towards a flat-bottomed crater.
@export_range(0.0, 1.0, 0.01) var floor_flatness: float = 0.35:
	set(v):
		floor_flatness = clampf(v, 0.0, 1.0)
		_touch()
## Quantise the bowl into concentric benches (slumped terraces). 0 = smooth.
@export_range(0, 12) var terrace_steps: int = 0:
	set(v):
		terrace_steps = maxi(v, 0)
		_touch()

@export_group("Roughness")
## Optional fractal break-up layered over the crater so the rim and floor are not perfectly smooth.
## 0 = off (emits no extra op, so it costs nothing).
@export_range(0.0, 0.5, 0.01, "or_greater") var roughness: float = 0.0:
	set(v):
		roughness = maxf(v, 0.0)
		_touch()
## Size of the roughness detail, in metres.
@export_range(1.0, 128.0, 0.5, "or_greater") var roughness_size: float = 12.0:
	set(v):
		roughness_size = maxf(v, 0.01)
		_touch()
@export var seed: int = 0:
	set(v):
		seed = v
		_touch()


func _build() -> void:
	_emit(Op.CRATER, Blend.ADD,
			[1.0, floor_depth, rim_height, rim_width, ejecta_falloff, floor_flatness, terrace_steps, seed])
	if roughness > 0.0:
		_emit(Op.FBM, Blend.ADD, [roughness, 1.0 / roughness_size, 4, 2.0, 0.5, seed + 4409, 1.0])


## A crater lowers the ground, so the Add Water button should treat this brush as digging, not raising.
func _raises() -> bool:
	return false


func _configuration_warning() -> String:
	if floor_depth <= 0.0 and rim_height <= 0.0:
		return "Relief Crater has no depth and no rim — the material will not deform anything."
	return ""
