# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DReliefScree — loose rock shed off steep ground and piled at the bottom: talus fans, gully
# fill, the rubble apron at the foot of a cliff.
#
# This is the first material that reads the terrain rather than only writing to it. It ships with a slope
# selector already configured, because scree that ignores slope is just noise — the whole point is that
# it appears where rock is being shed and accumulates where the surface flattens out.
# See PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md §5, §7.
@tool
class_name Pasture3DReliefScree
extends Pasture3DReliefMaterial

## Size of the rubble texture, as a fraction of the brush's Height Scale. Scree is a thin skin over the
## rock beneath it — small values read correctly.
@export_range(0.0, 1.0, 0.01, "or_greater") var amplitude: float = 0.12:
	set(v):
		amplitude = maxf(v, 0.0)
		_touch()
## Size of the individual rubble clumps, in metres. Below about 4 m on a 1 m terrain this stops resolving.
@export_range(1.0, 64.0, 0.5, "or_greater") var grain_size: float = 6.0:
	set(v):
		grain_size = maxf(v, 0.01)
		_touch()
## How far the rubble is smeared downhill, in metres. This is what makes it read as material that has
## travelled rather than static noise sitting on a slope. 0 = no smearing.
@export_range(0.0, 32.0, 0.1, "or_greater") var downslope_streak: float = 4.0:
	set(v):
		downslope_streak = maxf(v, 0.0)
		_touch()
## How much material piles into concavities — the toe of a slope, the floor of a gully. This is the part
## that makes a talus fan look deposited instead of sprayed on.
@export_range(0.0, 1.0, 0.01, "or_greater") var toe_deposition: float = 0.35:
	set(v):
		toe_deposition = maxf(v, 0.0)
		_touch()
@export var seed: int = 0:
	set(v):
		seed = v
		_touch()

@export_group("Slope Gate")
## Below this angle, in degrees, no scree is generated — flat ground sheds nothing.
@export_range(0.0, 90.0, 0.5) var min_slope_degrees: float = 22.0:
	set(v):
		min_slope_degrees = clampf(v, 0.0, 90.0)
		_touch()
## Softness of that cut-off, in degrees. A hard cut leaves a visible contour line across the hillside.
@export_range(0.0, 45.0, 0.5) var slope_falloff_degrees: float = 12.0:
	set(v):
		slope_falloff_degrees = clampf(v, 0.0, 45.0)
		_touch()


func _build() -> void:
	# The op carries its own slope gate rather than relying on the base's `selector` property, so the
	# material works out of the box. Assigning a selector on top still works — it gates the op further.
	var gate := Pasture3DReliefSelector.new()
	gate.kind = Pasture3DReliefSelector.Kind.SLOPE
	gate.range_min = min_slope_degrees
	gate.range_max = 90.0
	gate.falloff_low = slope_falloff_degrees
	gate.falloff_high = 0.0
	gate.strength = 1.0
	_emit(Op.SCREE, Blend.ADD, [amplitude, 1.0 / grain_size, downslope_streak, toe_deposition, seed],
			0, _emit_selector(gate))


func _configuration_warning() -> String:
	if amplitude <= 0.0 and toe_deposition <= 0.0:
		return "Relief Scree has no amplitude and no toe deposition — the material will not deform anything."
	return ""
