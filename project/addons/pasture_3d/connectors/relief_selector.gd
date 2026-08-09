# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DReliefSelector — gates a relief material by what the ground is already doing: its steepness,
# its altitude, or its concavity. "Craggy detail on the flanks, smooth on the plateaus", "strata only
# above the treeline", "scree piling into the hollows". This is the single technique that separates a
# uniform stamp from something that reads as geology.
#
# Assign one to a relief material's Selector property and it gates every shape that material generates.
#
# IMPORTANT — what it reads: the surface BELOW this brush's own layer, never the finished terrain. Reading
# the final composite would feed a brush's own relief back into its own mask and drift on every re-bake,
# which is the same class of bug the base_below plumbing exists to prevent.
# See PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md §7.
@tool
class_name Pasture3DReliefSelector
extends Resource

## Which property of the underlying ground to gate on. Ids MUST stay in sync with ReliefSelectorKind in
## src/pasture_3d_relief_ops.h.
enum Kind {
	SLOPE,     ## steepness in degrees, 0 (flat) to 90 (vertical)
	ALTITUDE,  ## world height in metres
	CURVATURE, ## concavity, roughly -1 (ridge/convex) to +1 (hollow/concave); 0 is a straight slope
}

@export var kind: Kind = Kind.SLOPE:
	set(v):
		kind = v
		emit_changed()
## Lower edge of the band that passes, in this Kind's units (degrees / metres / curvature).
@export var range_min: float = 25.0:
	set(v):
		range_min = v
		emit_changed()
## Upper edge of the band that passes.
@export var range_max: float = 90.0:
	set(v):
		range_max = v
		emit_changed()
## How far below Range Min the gate fades in, in the same units. 0 = a hard cut, which usually shows as
## a visible seam across the terrain.
@export_range(0.0, 90.0, 0.1, "or_greater") var falloff_low: float = 10.0:
	set(v):
		falloff_low = maxf(v, 0.0)
		emit_changed()
## How far above Range Max the gate fades out.
@export_range(0.0, 90.0, 0.1, "or_greater") var falloff_high: float = 10.0:
	set(v):
		falloff_high = maxf(v, 0.0)
		emit_changed()
## Pass everything OUTSIDE the band instead of inside it.
@export var invert: bool = false:
	set(v):
		invert = v
		emit_changed()
## How hard the gate bites. 1 = the material only appears inside the band; 0 = no gating at all (the
## material appears everywhere, exactly as if no selector were assigned). Values between fade the
## material down outside the band rather than removing it.
@export_range(0.0, 1.0, 0.01) var strength: float = 1.0:
	set(v):
		strength = clampf(v, 0.0, 1.0)
		emit_changed()


## Flatten to the stride-8 wire block the evaluators read (spec §7).
func to_params() -> Array:
	return [float(kind), range_min, range_max, falloff_low, falloff_high,
			1.0 if invert else 0.0, strength, 0.0]
