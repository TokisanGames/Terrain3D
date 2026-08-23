# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DReliefTerraces — quantises relief into stepped benches: eroded hillsides, quarry cuts,
# agricultural terracing. Modelled on Gaea's FractalTerraces (multi-octave bands with controllable riser
# hardness and uneven step spacing) rather than an even Terrace, because even bands read as artificial.
#
# TERRACE is a PROFILE op: it remaps whatever is already in the accumulator. That makes this material do
# two different useful things depending on where you put it — see Base Relief below.
# See PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md §5.
@tool
class_name Pasture3DReliefTerraces
extends Pasture3DReliefMaterial

## How many benches across the full relief range.
@export_range(2, 64) var steps: int = 8:
	set(v):
		steps = maxi(v, 1)
		_touch()
## 0 = no terracing at all (the relief passes through untouched). 1 = flat benches with near-vertical
## risers. Mid values give the weathered look where each bench still slopes slightly.
@export_range(0.0, 1.0, 0.01) var hardness: float = 0.8:
	set(v):
		hardness = clampf(v, 0.0, 1.0)
		_touch()
## Randomises the height of each band boundary so the benches are not evenly spaced. This is the single
## setting that separates "eroded strata" from "staircase".
@export_range(0.0, 0.5, 0.01) var step_jitter: float = 0.08:
	set(v):
		step_jitter = maxf(v, 0.0)
		_touch()
## Length scale of the step jitter, in metres.
@export_range(4.0, 512.0, 1.0, "or_greater") var jitter_size: float = 80.0:
	set(v):
		jitter_size = maxf(v, 0.01)
		_touch()

@export_group("Banding")
## WHAT the benches are cut across.
##
## [b]Accumulator[/b] (the default, and what this material always did) terraces whatever relief is already
## in the accumulator — its own Base Relief below when used alone, or the layer under it in a Stack.
##
## [b]Host Profile[/b] terraces the HOST BRUSH'S OWN SHAPE. On a Pasture3DMound that means benches cut
## into the hill, lying on its contours and following its height — which is what terracing a hill means,
## and what Accumulator cannot do, because the accumulator never contains the hill. Set Base Amount to 0
## with this: the hill IS the base, and a fractal added underneath just fights it.
##
## [b]Ground Altitude[/b] terraces world height out of the layers below, over Band Range. Use it for
## benches that hold one elevation across several brushes.
##
## Host Profile reads a flat 0 on a host with no profile of its own (a Pasture3DPlow), which produces one
## unbroken band; the brush raises a configuration warning saying so.
@export var band_source: Pasture3DReliefMaterial.BandSource = Pasture3DReliefMaterial.BandSource.ACCUMULATOR:
	set(v):
		band_source = v
		notify_property_list_changed() # Band Range only means something on Ground Altitude
		_touch()
## The world-height window Ground Altitude spreads its benches across, in metres: x = the elevation of the
## lowest riser, y = the highest. Ignored by the other two Band Sources.
##
## There is no useful default — it depends entirely on how tall your terrain is — so it is the one setting
## this material expects you to read off the ground and type in.
@export var band_range: Vector2 = Vector2(0.0, 100.0):
	set(v):
		band_range = v
		_touch()

@export_group("Base Relief")
## Built-in landform for this material to terrace, so it is useful on its own. Set to 0 when this
## material sits ABOVE another layer in a Pasture3DReliefStack — then it terraces that layer's output
## instead of adding a shape of its own.
@export_range(0.0, 1.0, 0.01, "or_greater") var base_amount: float = 1.0:
	set(v):
		base_amount = maxf(v, 0.0)
		_touch()
## Size of the largest feature in the built-in base relief, in metres.
@export_range(4.0, 512.0, 1.0, "or_greater") var base_size: float = 90.0:
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
		_emit(Op.FBM, Blend.ADD, [base_amount, 1.0 / base_size, base_octaves, 2.0, 0.5, seed, 1.0])
	# Slots 5-6 are unused; 7-8 carry the Ground Altitude window, which is the pair free in STRATIFY too.
	_emit(Op.TERRACE, Blend.ADD,
			[steps, hardness, step_jitter, seed + 2311, 1.0 / jitter_size, 0.0, 0.0,
					band_range.x, band_range.y],
			band_source << Pasture3DReliefMaterial.FLAG_BAND_SHIFT)


## Band Range is meaningless on the two Band Sources that are not Ground Altitude. Hidden rather than
## disabled, and never cleared, so switching back restores what was typed.
##
## `super` FIRST, and it is not optional: GDScript resolves a virtual to the most-derived implementation
## and stops there, so an override that does not chain silently repeals the base's rule. The base hides
## `blend` on a material that is not in a stack, and this override used to un-hide it — see spec §16.1.
func _validate_property(property: Dictionary) -> void:
	super(property)
	if (property.get("name", "") == "band_range"
			and band_source != Pasture3DReliefMaterial.BandSource.GROUND_ALTITUDE):
		property.usage &= ~PROPERTY_USAGE_EDITOR


func _configuration_warning() -> String:
	if hardness <= 0.0:
		return "Relief Terraces hardness is 0 — the relief passes through without being terraced."
	# The single most common mistake with this material, now with a second shape: under Host Profile the
	# hill is already the thing being banded, so a Base Relief on top is a competing shape rather than the
	# subject. Same sentence the Stack case has always warranted, at the one moment it is actionable.
	if band_source == Pasture3DReliefMaterial.BandSource.HOST_PROFILE and base_amount > 0.0:
		return ("Relief Terraces is banding the Host Profile but still adds its own Base Relief "
				+ "(Base Amount %.2f). Set Base Amount to 0 so the benches cut the brush's own shape." % base_amount)
	if (band_source == Pasture3DReliefMaterial.BandSource.GROUND_ALTITUDE
			and is_equal_approx(band_range.x, band_range.y)):
		return "Relief Terraces Band Range is empty (min == max) — every bench collapses onto one."
	return ""
