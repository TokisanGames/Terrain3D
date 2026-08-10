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
##
## The first three read the ground's own shape. The last four read what a Pasture3DSim did here, out of
## the Sim Result assigned below — see PASTURE3D_SIM_NODE_SPEC.md §9.
enum Kind {
	SLOPE,      ## steepness in degrees, 0 (flat) to 90 (vertical)
	ALTITUDE,   ## world height in metres
	CURVATURE,  ## concavity, roughly -1 (ridge/convex) to +1 (hollow/concave); 0 is a straight slope
	FLOW,       ## upstream drainage area in SQUARE METRES — how much land drains through this cell
	EROSION,    ## metres of material the sim removed here, as a POSITIVE depth
	DEPOSITION, ## metres of material the sim laid down here
	WETNESS,    ## depth of standing water in metres, from the sim's depression fill
}

## The Kinds that read a Sim Result rather than the ground's own shape.
const SIM_KINDS: Array[Kind] = [Kind.FLOW, Kind.EROSION, Kind.DEPOSITION, Kind.WETNESS]

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


## The erosion sim's masks, for the FLOW / EROSION / DEPOSITION / WETNESS Kinds. Point it at the Sim
## Result of the Pasture3DSim that eroded this ground. Ignored by the other Kinds.
##
## Leave it null with a sim Kind selected and the gate reads a defined 0 everywhere — nothing is
## silently invented — and the brush raises a configuration warning. The same is true OUTSIDE the
## result's extent, which is the simulated area: a plow reaching past the edge of what was simulated
## gets 0 out there, not the nearest value smeared outwards.
##
## NOTE the result covers the loop PLUS its catchment margin, and the values in the margin are the
## sim's own, unmasked. So EROSION is non-zero over ground the sim never actually wrote to. That is
## deliberate (§8.2) — the channels feeding the rim are exactly where a gate wants real numbers — but it
## means a material keyed on erosion will paint outside the eroded loop unless the brush's own area
## stops it.
@export var sim_result: Pasture3DSimResult:
	set(v):
		sim_result = v
		emit_changed()


## True when this selector's Kind reads a Sim Result rather than the ground's own shape.
func is_sim_kind() -> bool:
	return SIM_KINDS.has(kind)


## The units `range_min` / `range_max` are in, for tooltips and warnings.
func units() -> String:
	match kind:
		Kind.ALTITUDE: return "m"
		Kind.CURVATURE: return ""
		Kind.FLOW: return "m2 of catchment"
		Kind.EROSION: return "m removed"
		Kind.DEPOSITION: return "m gained"
		Kind.WETNESS: return "m of water"
		_: return "deg"


## Flatten to the stride-8 wire block the evaluators read (spec §7).
##
## The Sim Result is NOT in this block and cannot be: the wire format is flat floats, and the masks are
## a whole grid with its own extent. The brush collects them separately (Pasture3DPlow._sim_result_for)
## and hands them over as one dictionary per bake.
func to_params() -> Array:
	return [float(kind), range_min, range_max, falloff_low, falloff_high,
			1.0 if invert else 0.0, strength, 0.0]
