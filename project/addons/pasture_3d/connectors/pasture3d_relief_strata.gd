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

@export_group("Banding")
## WHAT the rock layers are cut across.
##
## [b]Accumulator[/b] (the default, and what this material always did) stratifies whatever relief is
## already in the accumulator — its own Base Relief below when used alone, or the layer under it in a
## Stack.
##
## [b]Host Profile[/b] stratifies the HOST BRUSH'S OWN SHAPE. On a Pasture3DMound that means beds exposed
## across the hill at their own elevations, following it — which is what stratifying a hill means, and
## what Accumulator cannot do, because the accumulator never contains the hill. Set Base Amount to 0 with
## this: the hill IS the base.
##
## [b]Ground Altitude[/b] stratifies world height out of the layers below, over Band Range — beds that
## hold one geological elevation across several brushes, which is what real bedding does.
##
## Host Profile reads a flat 0 on a host with no profile of its own (a Pasture3DPlow), which produces one
## unbroken bed; the brush raises a configuration warning saying so.
@export var band_source: Pasture3DReliefMaterial.BandSource = Pasture3DReliefMaterial.BandSource.ACCUMULATOR:
	set(v):
		band_source = v
		notify_property_list_changed() # Band Range only means something on Ground Altitude
		_touch()
## The world-height window Ground Altitude spreads its beds across, in metres: x = the elevation of the
## lowest bed, y = the highest. Ignored by the other two Band Sources.
##
## There is no useful default — it depends entirely on how tall your terrain is — so it is the one setting
## this material expects you to read off the ground and type in.
@export var band_range: Vector2 = Vector2(0.0, 100.0):
	set(v):
		band_range = v
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


## Our own, plus the Band Source this material carries.
func wants_host_profile() -> bool:
	return (super() or band_source == Pasture3DReliefMaterial.BandSource.HOST_PROFILE)


func _build() -> void:
	if base_amount > 0.0:
		# Ridged reads as rock; a smooth fBm base under hard strata looks like stacked pancakes.
		_emit(Op.RIDGED, Blend.ADD, [base_amount, 1.0 / base_size, base_octaves, 2.0, 0.5, seed, 1.0])
	# Slots 0-6 are the strata settings; 7-8 carry the Ground Altitude window, the pair free in TERRACE too.
	_emit(Op.STRATIFY, Blend.ADD, [layers, hardness, dip, deg_to_rad(dip_direction_degrees),
			1.0 / break_size, break_amount, seed + 6607, band_range.x, band_range.y],
			band_source << Pasture3DReliefMaterial.FLAG_BAND_SHIFT)


## Band Range is meaningless on the two Band Sources that are not Ground Altitude. Hidden rather than
## disabled, and never cleared, so switching back restores what was typed.
func _validate_property(property: Dictionary) -> void:
	if (property.get("name", "") == "band_range"
			and band_source != Pasture3DReliefMaterial.BandSource.GROUND_ALTITUDE):
		property.usage &= ~PROPERTY_USAGE_EDITOR


func _configuration_warning() -> String:
	if hardness <= 0.0:
		return "Relief Strata hardness is 0 — the relief passes through without being layered."
	if band_source == Pasture3DReliefMaterial.BandSource.HOST_PROFILE and base_amount > 0.0:
		return ("Relief Strata is banding the Host Profile but still adds its own Base Relief "
				+ "(Base Amount %.2f). Set Base Amount to 0 so the beds cut the brush's own shape." % base_amount)
	if (band_source == Pasture3DReliefMaterial.BandSource.GROUND_ALTITUDE
			and is_equal_approx(band_range.x, band_range.y)):
		return "Relief Strata Band Range is empty (min == max) — every bed collapses onto one."
	return ""
