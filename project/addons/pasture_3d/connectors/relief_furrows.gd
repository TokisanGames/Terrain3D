# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DReliefFurrows — parallel corrugation at LANDFORM scale: ridge-and-furrow field systems,
# terraced paddy ridges, erosion rills and gullies.
#
# Scale note, because it decides whether this material is visible at all: the plow writes into the height
# map, which is sampled at the terrain's vertex_spacing (1 m by default). A cycle needs roughly four
# samples to survive meshing, so spacing below ~4 m simply does not render — and actual plough rows
# (~0.5 m) are not expressible here at any setting. They belong in the surface shader. What IS expressible
# is the real landform: medieval ridge-and-furrow runs 5-20 m crest to crest, which is this material's
# home ground. The brush raises a configuration warning if the spacing drops under the terrain's limit.
# See PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md §5.
@tool
class_name Pasture3DReliefFurrows
extends Pasture3DReliefMaterial

## Cross-section of each row.
enum Profile { V, U, SQUARE }

## Ridge-to-furrow contribution, as a fraction of the brush's Height Scale.
@export_range(0.0, 1.0, 0.01, "or_greater") var amplitude: float = 0.35:
	set(v):
		amplitude = v
		_touch()
## Distance between ridge crests, in metres. Must stay well above the terrain's vertex spacing to render
## at all — see the scale note at the top of this file.
@export_range(2.0, 64.0, 0.1, "or_greater") var spacing: float = 15.0:
	set(v):
		spacing = maxf(v, 0.1)
		_touch()
## Direction the rows run, in degrees.
@export_range(0.0, 360.0, 1.0) var direction_degrees: float = 0.0:
	set(v):
		direction_degrees = v
		_touch()
## V = sharp plough cut. U = weathered, rounded. SQUARE = flat-topped beds with steep sides.
@export var profile: Profile = Profile.U:
	set(v):
		profile = v
		_touch()

@export_group("Wobble")
## Sideways waver along each row, in metres — worked ground is never perfectly straight.
@export_range(0.0, 16.0, 0.1, "or_greater") var wobble_amount: float = 2.0:
	set(v):
		wobble_amount = maxf(v, 0.0)
		_touch()
## Length scale of that waver, in metres.
@export_range(1.0, 256.0, 0.5, "or_greater") var wobble_size: float = 70.0:
	set(v):
		wobble_size = maxf(v, 0.01)
		_touch()
@export var seed: int = 0:
	set(v):
		seed = v
		_touch()


func _build() -> void:
	_emit(Op.FURROWS, Blend.ADD, [amplitude, spacing, deg_to_rad(direction_degrees), int(profile),
			1.0 / wobble_size, wobble_amount, seed])


func _configuration_warning() -> String:
	if amplitude <= 0.0:
		return "Relief Furrows amplitude is 0 — the material will not deform anything."
	return ""
