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
##
## CHANGING THE KIND CHANGES THE UNITS, so it re-defaults the band to one that means something in the new
## ones (§21.5) — but only while the band is still the OUTGOING Kind's default. Edit any of Range Min,
## Range Max, either Falloff or Measure Radius and your numbers survive every later Kind change.
enum Kind {
	SLOPE,      ## steepness in degrees, 0 (flat) to 90 (vertical)
	ALTITUDE,   ## world height in metres
	CURVATURE,  ## METRES this cell sits below its surroundings, measured over Measure Radius; + is a hollow
	FLOW,       ## upstream drainage area in SQUARE METRES — how much land drains through this cell
	EROSION,    ## metres of material the sim removed here, as a POSITIVE depth
	DEPOSITION, ## metres of material the sim laid down here
	WETNESS,    ## depth of standing water in metres, from the sim's depression fill
}

## The Kinds that read a Sim Result rather than the ground's own shape.
const SIM_KINDS: Array[Kind] = [Kind.FLOW, Kind.EROSION, Kind.DEPOSITION, Kind.WETNESS]

## The band each Kind defaults to, as [range_min, range_max, falloff_low, falloff_high, measure_radius].
## Measured against real ground rather than invented — the audit table in PASTURE3D_SIM_NODE_SPEC.md §21.5
## records what each field's range actually is over one bake at the shipped solver defaults, and every row
## here selects a usable fraction of it. Gate BG is that audit turned into a standing check.
##
## ALTITUDE deliberately keeps the shipped 25–90 band (§21.10 decision 1): a Resource cannot reach a
## terrain to derive one, and any constant is wrong somewhere — 1–365 m on the demo, something else on a
## 4 km map. It is the one Kind you always set by hand. It is listed rather than omitted so that the
## "is this band still untouched?" test below has an answer for it, and switching AWAY from ALTITUDE on an
## untouched selector re-defaults like every other Kind. Its entry IS today's default, so switching TO it
## changes nothing, which is what "unchanged" means.
const PRESETS := {
	Kind.SLOPE: [25.0, 90.0, 10.0, 10.0, 0.0],
	Kind.ALTITUDE: [25.0, 90.0, 10.0, 10.0, 0.0],
	Kind.CURVATURE: [0.25, 100.0, 0.1, 0.0, 8.0],
	Kind.FLOW: [5000.0, 1e9, 2500.0, 0.0, 0.0],
	Kind.EROSION: [2.0, 1000.0, 1.0, 0.0, 0.0],
	Kind.DEPOSITION: [0.25, 100.0, 0.1, 0.0, 0.0],
	Kind.WETNESS: [0.5, 1000.0, 0.25, 0.0, 0.0],
}

## Inspector slider bounds per Kind, as [range_lo, range_hi, step, extra_hint]. The VALUE is never clamped
## to these — every hint is `or_greater` — but a 0–90 slider on a FLOW falloff measured in square metres is
## actively misleading, and a slider you cannot aim is the same as no slider (§21.5).
const RANGE_HINTS := {
	Kind.SLOPE: [0.0, 90.0, 0.1, ""],
	Kind.ALTITUDE: [0.0, 1000.0, 1.0, ",or_less"],
	Kind.CURVATURE: [-5.0, 5.0, 0.01, ",or_less"],
	Kind.FLOW: [0.0, 100000.0, 10.0, ""],
	Kind.EROSION: [0.0, 60.0, 0.1, ""],
	Kind.DEPOSITION: [0.0, 5.0, 0.01, ""],
	Kind.WETNESS: [0.0, 30.0, 0.1, ""],
}
## The same per Kind for the two falloffs, which are a WIDTH in those units and so never go negative.
const FALLOFF_HINTS := {
	Kind.SLOPE: [0.0, 90.0, 0.1],
	Kind.ALTITUDE: [0.0, 500.0, 1.0],
	Kind.CURVATURE: [0.0, 5.0, 0.01],
	Kind.FLOW: [0.0, 50000.0, 10.0],
	Kind.EROSION: [0.0, 30.0, 0.1],
	Kind.DEPOSITION: [0.0, 2.0, 0.01],
	Kind.WETNESS: [0.0, 15.0, 0.1],
}

@export var kind: Kind = Kind.SLOPE:
	set(v):
		var outgoing := kind
		kind = v
		if v != outgoing:
			_apply_preset(outgoing, v)
			notify_property_list_changed() # the sliders below are per-Kind
		emit_changed()
## Lower edge of the band that passes, in this Kind's units (degrees / metres / m² of catchment).
@export var range_min: float = 25.0:
	set(v):
		range_min = v
		emit_changed()
## Upper edge of the band that passes. Must not be below Range Min — a band the wrong way round passes
## NOTHING, anywhere, on any Kind, and the brush that owns this selector says so.
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

## Over what distance, in METRES, Slope and Curvature are measured. 0 means one cell — one vertex spacing
## on a bake, one sim cell on a Sim's mask — which is what they have always meant, bit for bit.
##
## Raise it to ask about landform instead of texture: "steep over 20 m" rather than "steep between two
## adjacent vertices", which is what you want on noisy or eroded ground. Curvature reads the mean height
## of the ring at this radius minus this cell's, so 8 m answers "is there a hollow here 8 m across".
##
## Ignored by every other Kind — Altitude and the four sim channels are values, not shapes, and have
## nothing to average over.
@export_range(0.0, 64.0, 0.5, "or_greater") var measure_radius: float = 0.0:
	set(v):
		measure_radius = maxf(v, 0.0)
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


## True when this selector's Kind measures a SHAPE, so `measure_radius` means something to it.
func uses_measure_radius() -> bool:
	return kind == Kind.SLOPE or kind == Kind.CURVATURE


## The units `range_min` / `range_max` are in, for tooltips and warnings.
func units() -> String:
	match kind:
		Kind.ALTITUDE: return "m"
		Kind.CURVATURE: return "m of hollow"
		Kind.FLOW: return "m2 of catchment"
		Kind.EROSION: return "m removed"
		Kind.DEPOSITION: return "m gained"
		Kind.WETNESS: return "m of water"
		_: return "deg"


## True when every band field still matches THIS Kind's preset, i.e. nothing here has been hand-tuned — the
## exact condition under which a Kind change re-defaults the band. Exposed so a gate (BE) can ask the
## question without changing anything.
func band_is_preset() -> bool:
	var p: Array = PRESETS.get(kind, [])
	if p.is_empty():
		return false
	return (is_equal_approx(range_min, p[0]) and is_equal_approx(range_max, p[1])
			and is_equal_approx(falloff_low, p[2]) and is_equal_approx(falloff_high, p[3])
			and is_equal_approx(measure_radius, p[4]))


## True when this band is inverted — Range Min above Range Max. The evaluator's `min(rise, fall)` is then
## 0 everywhere, so the selector gates NOTHING through, on every Kind, with nothing visible to say why
## (§21.5). Every host that owns a selector turns this into a configuration warning.
func is_inverted_band() -> bool:
	return range_min > range_max


## Re-default the band when the Kind changes — but ONLY while it is still the outgoing Kind's preset.
##
## The comparison is against the OUTGOING Kind, which is the whole rule: a band that reads 5000 because
## someone typed 5000 into a SLOPE selector is EDITED, even though 5000 is exactly what FLOW's preset would
## have given it. Silently overwriting an edited band would be worse than shipping useless defaults,
## because useless defaults are at least visible.
func _apply_preset(p_from: Kind, p_to: Kind) -> void:
	var from: Array = PRESETS.get(p_from, [])
	var to: Array = PRESETS.get(p_to, [])
	if from.is_empty() or to.is_empty():
		return
	if not (is_equal_approx(range_min, from[0]) and is_equal_approx(range_max, from[1])
			and is_equal_approx(falloff_low, from[2]) and is_equal_approx(falloff_high, from[3])
			and is_equal_approx(measure_radius, from[4])):
		return # edited: leave every field alone
	range_min = to[0]
	range_max = to[1]
	falloff_low = to[2]
	falloff_high = to[3]
	measure_radius = to[4]


## Per-Kind slider bounds, and hide Measure Radius on the Kinds it does nothing for. The stored value is
## untouched either way — this is the hint, not the data.
func _validate_property(property: Dictionary) -> void:
	var n: String = property.get("name", "")
	if n == "range_min" or n == "range_max":
		var h: Array = RANGE_HINTS.get(kind, RANGE_HINTS[Kind.SLOPE])
		property.hint = PROPERTY_HINT_RANGE
		property.hint_string = "%f,%f,%f,or_greater%s" % [h[0], h[1], h[2], h[3]]
	elif n == "falloff_low" or n == "falloff_high":
		var h: Array = FALLOFF_HINTS.get(kind, FALLOFF_HINTS[Kind.SLOPE])
		property.hint = PROPERTY_HINT_RANGE
		property.hint_string = "%f,%f,%f,or_greater" % [h[0], h[1], h[2]]
	elif n == "measure_radius" and not uses_measure_radius():
		property.usage &= ~PROPERTY_USAGE_EDITOR # still stored, so switching Kind back restores it


## Flatten to the stride-8 wire block the evaluators read (spec §7).
##
## The eighth float was the reserved slot until §21.6 spent it on `measure_radius`; the stride, and so the
## wire format, is unchanged.
##
## The Sim Result is NOT in this block and cannot be: the wire format is flat floats, and the masks are
## a whole grid with its own extent. The brush collects them separately (Pasture3DPlow._sim_result_for)
## and hands them over as one dictionary per bake.
func to_params() -> Array:
	return [float(kind), range_min, range_max, falloff_low, falloff_high,
			1.0 if invert else 0.0, strength,
			measure_radius if uses_measure_radius() else 0.0]
