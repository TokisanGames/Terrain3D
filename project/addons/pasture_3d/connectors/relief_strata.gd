# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DReliefStrata — exposed rock layers. Like Terraces, but the bands are TILTED (geological dip)
# and broken up laterally, which is what makes sedimentary rock read as rock rather than as a staircase.
# Modelled on Gaea's Stratify: broken strata in confined local zones rather than uniform global bands.
#
# STRATIFY is a PROFILE op: it remaps whatever is already in the accumulator — see Base Relief below.
# See PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md §5.
@tool
class_name Pasture3DReliefStrata
extends Pasture3DReliefMaterial

## How many rock layers across the full relief range.
@export_range(2, 64) var layers: int = 14:
	set(v):
		layers = maxi(v, 1)
		_touch()
## How resistant each layer is: 0 leaves the relief untouched, 1 gives sheer cliff faces between flat
## shelves. Real sedimentary rock alternates, so mid-high values with break-up read best.
@export_range(0.0, 1.0, 0.01) var hardness: float = 0.75:
	set(v):
		hardness = clampf(v, 0.0, 1.0)
		_touch()
## Geological dip: how far the layers tilt across the ground, in relief units per 100 m. 0 = perfectly
## horizontal bedding. Small values (0.1–0.4) read as gently tilted strata.
@export_range(-2.0, 2.0, 0.01) var dip: float = 0.25:
	set(v):
		dip = v
		_touch()
## Compass direction the layers dip towards, in degrees.
@export_range(0.0, 360.0, 1.0) var dip_direction_degrees: float = 45.0:
	set(v):
		dip_direction_degrees = v
		_touch()

@export_group("Break Up")
## How much the layer boundaries wander, so beds are broken into local plates instead of running dead
## straight across the whole area. This is the difference between rock and corduroy.
@export_range(0.0, 0.5, 0.01) var break_amount: float = 0.12:
	set(v):
		break_amount = maxf(v, 0.0)
		_touch()
## Size of those plates, in metres.
@export_range(4.0, 512.0, 1.0, "or_greater") var break_size: float = 45.0:
	set(v):
		break_size = maxf(v, 0.01)
		_touch()

@export_group("Base Relief")
## Built-in landform for this material to stratify, so it is useful on its own. Set to 0 when this
## material sits ABOVE another layer in a Pasture3DReliefStack — then it stratifies that layer's output.
@export_range(0.0, 1.0, 0.01, "or_greater") var base_amount: float = 1.0:
	set(v):
		base_amount = maxf(v, 0.0)
		_touch()
## Size of the largest feature in the built-in base relief, in metres.
@export_range(4.0, 512.0, 1.0, "or_greater") var base_size: float = 70.0:
	set(v):
		base_size = maxf(v, 0.01)
		_touch()
@export_range(1, 8) var base_octaves: int = 4:
	set(v):
		base_octaves = clampi(v, 1, 8)
		_touch()
@export var seed: int = 0:
	set(v):
		seed = v
		_touch()


func _build() -> void:
	if base_amount > 0.0:
		# Ridged reads as rock; a smooth fBm base under hard strata looks like stacked pancakes.
		_emit(Op.RIDGED, Blend.ADD, [base_amount, 1.0 / base_size, base_octaves, 2.0, 0.5, seed, 1.0])
	_emit(Op.STRATIFY, Blend.ADD, [layers, hardness, dip, deg_to_rad(dip_direction_degrees),
			1.0 / break_size, break_amount, seed + 6607])


func _configuration_warning() -> String:
	if hardness <= 0.0:
		return "Relief Strata hardness is 0 — the relief passes through without being layered."
	return ""
