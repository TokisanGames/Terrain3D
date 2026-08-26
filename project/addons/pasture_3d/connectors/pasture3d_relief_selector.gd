# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DTerrainMask — gates a relief material by what the ground is already doing: its steepness,
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
class_name Pasture3DTerrainMask
extends Resource

## Which property of the underlying ground to gate on. Ids MUST stay in sync with
## ReliefSelectorFilterType in src/pasture_3d_relief_ops.h.
##
## The first three read the ground's own shape. The last four read what a Pasture3DSim did here, out of
## the Sim Result assigned below — see PASTURE3D_SIM_NODE_SPEC.md §9.
##
## CHANGING THE FILTER TYPE CHANGES THE UNITS, so it re-defaults the band to one that means something in
## the new ones (§21.5) — but only while the band is still the OUTGOING Filter Type's default. Edit any of
## Range Min, Range Max, either Falloff or Measure Radius and your numbers survive every later change.
enum FilterType {
	SLOPE,      ## steepness in degrees, 0 (flat) to 90 (vertical)
	ALTITUDE,   ## world height in metres
	CURVATURE,  ## METRES this cell sits below its surroundings, measured over Measure Radius; + is a hollow
	FLOW,       ## upstream drainage area in SQUARE METRES — how much land drains through this cell
	EROSION,    ## metres of material the sim removed here, as a POSITIVE depth
	DEPOSITION, ## metres of material the sim laid down here
	WETNESS,    ## depth of standing water in metres, from the sim's depression fill
}

## Which surface Slope / Altitude / Curvature measure. Ids MUST stay in sync with ReliefFieldSource in
## src/pasture_3d_relief_ops.h. The four sim Filter Types ignore this — a Sim Result is one field with one
## meaning, and there is no host-profile version of "how much land drains through here".
enum FieldSource {
	BELOW_LAYER, ## the composite of the layers UNDER this brush's own — the historical behaviour
	HOST_PROFILE, ## the host brush's OWN generated shape, before any relief is added to it
}

## The Filter Types that read a Sim Result rather than the ground's own shape.
const SIM_FILTER_TYPES: Array[FilterType] = [FilterType.FLOW, FilterType.EROSION,
		FilterType.DEPOSITION, FilterType.WETNESS]

## The band each Filter Type defaults to, as [range_min, range_max, falloff_low, falloff_high, measure_radius].
## Measured against real ground rather than invented — the audit table in PASTURE3D_SIM_NODE_SPEC.md §21.5
## records what each field's range actually is over one bake at the shipped solver defaults, and every row
## here selects a usable fraction of it. Gate BG is that audit turned into a standing check.
##
## ALTITUDE deliberately keeps the shipped 25–90 band (§21.10 decision 1): a Resource cannot reach a
## terrain to derive one, and any constant is wrong somewhere — 1–365 m on the demo, something else on a
## 4 km map. It is the one Filter Type you always set by hand. It is listed rather than omitted so that the
## "is this band still untouched?" test below has an answer for it, and switching AWAY from ALTITUDE on an
## untouched selector re-defaults like every other FilterType. Its entry IS today's default, so switching TO it
## changes nothing, which is what "unchanged" means.
const PRESETS := {
	FilterType.SLOPE: [25.0, 90.0, 10.0, 10.0, 0.0],
	FilterType.ALTITUDE: [25.0, 90.0, 10.0, 10.0, 0.0],
	FilterType.CURVATURE: [0.25, 100.0, 0.1, 0.0, 8.0],
	FilterType.FLOW: [5000.0, 1e9, 2500.0, 0.0, 0.0],
	FilterType.EROSION: [2.0, 1000.0, 1.0, 0.0, 0.0],
	FilterType.DEPOSITION: [0.25, 100.0, 0.1, 0.0, 0.0],
	FilterType.WETNESS: [0.5, 1000.0, 0.25, 0.0, 0.0],
}

## Inspector slider bounds per Filter Type, as [range_lo, range_hi, step, extra_hint]. The VALUE is never
## clamped to these — every hint is `or_greater` — but a 0–90 slider on a FLOW falloff measured in square
## metres is actively misleading, and a slider you cannot aim is the same as no slider (§21.5).
const RANGE_HINTS := {
	FilterType.SLOPE: [0.0, 90.0, 0.1, ""],
	FilterType.ALTITUDE: [0.0, 1000.0, 1.0, ",or_less"],
	FilterType.CURVATURE: [-5.0, 5.0, 0.01, ",or_less"],
	FilterType.FLOW: [0.0, 100000.0, 10.0, ""],
	FilterType.EROSION: [0.0, 60.0, 0.1, ""],
	FilterType.DEPOSITION: [0.0, 5.0, 0.01, ""],
	FilterType.WETNESS: [0.0, 30.0, 0.1, ""],
}
## The same per Filter Type for the two falloffs, which are a WIDTH in those units and so never go negative.
const FALLOFF_HINTS := {
	FilterType.SLOPE: [0.0, 90.0, 0.1],
	FilterType.ALTITUDE: [0.0, 500.0, 1.0],
	FilterType.CURVATURE: [0.0, 5.0, 0.01],
	FilterType.FLOW: [0.0, 50000.0, 10.0],
	FilterType.EROSION: [0.0, 30.0, 0.1],
	FilterType.DEPOSITION: [0.0, 2.0, 0.01],
	FilterType.WETNESS: [0.0, 15.0, 0.1],
}

@export var filter_type: FilterType = FilterType.SLOPE:
	set(v):
		var outgoing := filter_type
		filter_type = v
		if v != outgoing:
			_apply_preset(outgoing, v)
			notify_property_list_changed() # the sliders below are per-Filter Type
		emit_changed()
## Lower edge of the band that passes, in this Filter Type's units (degrees / metres / m² of catchment).
@export var range_min: float = 25.0:
	set(v):
		range_min = v
		emit_changed()
## Upper edge of the band that passes. Must not be below Range Min — a band the wrong way round passes
## NOTHING, anywhere, on any Filter Type, and the brush that owns this selector says so.
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
## Ignored by every other Filter Type — Altitude and the four sim channels are values, not shapes, and have
## nothing to average over.
@export_range(0.0, 64.0, 0.5, "or_greater") var measure_radius: float = 0.0:
	set(v):
		measure_radius = maxf(v, 0.0)
		emit_changed()

## WHICH SURFACE Slope, Altitude and Curvature are measured on.
##
## [b]Below Layer[/b] (the default, and what every selector did before this existed) reads the composite
## of the layers UNDER this brush's own. That is what stops a brush gating on its own relief and drifting
## a little further on every re-bake, and on a Plow laid over existing terrain it is exactly right.
##
## [b]Host Profile[/b] reads the host brush's own generated shape — a Mound's dome — before any relief is
## added to it. Use it when the thing you want to gate on is the landform this brush is making, which is
## the usual case on a Mound: "craggy on the flanks, smooth on top" is a Slope band on Host Profile, and
## cannot be expressed on Below Layer at all, because the ground under a Mound is usually flat and every
## Filter Type then returns one constant.
##
## It cannot drift either, and for a structural reason rather than a lucky one: the profile is a function
## of the loop and the shape properties ONLY, so relief keyed on it can never feed itself.
##
## Only landform brushes have a profile to offer. On a Pasture3DPlow or a Pasture3DSim this reads a
## defined 0 everywhere and the host raises a configuration warning — it does NOT quietly fall back to
## Below Layer, because a fallback would make a mis-set Field Source invisible.
@export var field_source: FieldSource = FieldSource.BELOW_LAYER:
	set(v):
		field_source = v
		emit_changed()


## The erosion sim's masks, for the FLOW / EROSION / DEPOSITION / WETNESS Filter Types. Point it at the Sim
## Result of the Pasture3DSim that eroded this ground. Ignored by the other Filter Types.
##
## Leave it null with a sim Filter Type selected and the gate reads a defined 0 everywhere — nothing is
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


## True when this selector's Filter Type reads a Sim Result rather than the ground's own shape.
func is_sim_filter_type() -> bool:
	return SIM_FILTER_TYPES.has(filter_type)


## True when this selector's Filter Type measures a SHAPE, so `measure_radius` means something to it.
func uses_measure_radius() -> bool:
	return filter_type == FilterType.SLOPE or filter_type == FilterType.CURVATURE


## The units `range_min` / `range_max` are in, for tooltips and warnings.
func units() -> String:
	match filter_type:
		FilterType.ALTITUDE: return "m"
		FilterType.CURVATURE: return "m of hollow"
		FilterType.FLOW: return "m2 of catchment"
		FilterType.EROSION: return "m removed"
		FilterType.DEPOSITION: return "m gained"
		FilterType.WETNESS: return "m of water"
		_: return "deg"


## True when every band field still matches THIS Filter Type's preset, i.e. nothing here has been
## hand-tuned — the exact condition under which a Filter Type change re-defaults the band. Exposed so a
## gate (BE) can ask the question without changing anything.
func band_is_preset() -> bool:
	var p: Array = PRESETS.get(filter_type, [])
	if p.is_empty():
		return false
	return (is_equal_approx(range_min, p[0]) and is_equal_approx(range_max, p[1])
			and is_equal_approx(falloff_low, p[2]) and is_equal_approx(falloff_high, p[3])
			and is_equal_approx(measure_radius, p[4]))


## True when this band is inverted — Range Min above Range Max. The evaluator's `min(rise, fall)` is then
## 0 everywhere, so the selector gates NOTHING through, on every Filter Type, with nothing visible to say why
## (§21.5). Every host that owns a selector turns this into a configuration warning.
func is_inverted_band() -> bool:
	return range_min > range_max


## Re-default the band when the Filter Type changes — but ONLY while it is still the outgoing one's preset.
##
## The comparison is against the OUTGOING Filter Type, which is the whole rule: a band that reads 5000 because
## someone typed 5000 into a SLOPE selector is EDITED, even though 5000 is exactly what FLOW's preset would
## have given it. Silently overwriting an edited band would be worse than shipping useless defaults,
## because useless defaults are at least visible.
func _apply_preset(p_from: FilterType, p_to: FilterType) -> void:
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


## Per-Filter-Type slider bounds, and hide Measure Radius on the ones it does nothing for. The stored
## value is untouched either way — this is the hint, not the data.
func _validate_property(property: Dictionary) -> void:
	var n: String = property.get("name", "")
	if n == "range_min" or n == "range_max":
		var h: Array = RANGE_HINTS.get(filter_type, RANGE_HINTS[FilterType.SLOPE])
		property.hint = PROPERTY_HINT_RANGE
		property.hint_string = "%f,%f,%f,or_greater%s" % [h[0], h[1], h[2], h[3]]
	elif n == "falloff_low" or n == "falloff_high":
		var h: Array = FALLOFF_HINTS.get(filter_type, FALLOFF_HINTS[FilterType.SLOPE])
		property.hint = PROPERTY_HINT_RANGE
		property.hint_string = "%f,%f,%f,or_greater" % [h[0], h[1], h[2]]
	elif n == "measure_radius" and not uses_measure_radius():
		property.usage &= ~PROPERTY_USAGE_EDITOR # still stored, so switching back restores it
	elif n == "field_source" and is_sim_filter_type():
		property.usage &= ~PROPERTY_USAGE_EDITOR # same: hidden on the sim Filter Types, never cleared


## True when this selector measures the host brush's own profile rather than the layers below it. Only a
## landform brush can answer that; every other host turns this into a configuration warning.
func uses_host_profile() -> bool:
	return field_source == FieldSource.HOST_PROFILE and not is_sim_filter_type()


## Flatten to the stride-9 wire block the evaluators read (spec §7).
##
## The eighth float was the reserved slot until §21.6 spent it on `measure_radius`; the ninth is
## `field_source`. Widening the stride needs no migration BECAUSE THE BLOCK IS NEVER SERIALISED — it is
## rebuilt from these resources on every compile, so nothing on disk carries the old width. (Contrast the
## `kind` rename below, which touched a STORED property and did need a shim.)
##
## `field_source` is written as BELOW_LAYER for the four sim Filter Types whatever the property says: a
## Sim Result has no host-profile variant, and normalising it here means the evaluators never have to ask.
##
## The Sim Result is NOT in this block and cannot be: the wire format is flat floats, and the masks are
## a whole grid with its own extent. The brush collects them separately (Pasture3DPlow._sim_result_for)
## and hands them over as one dictionary per bake.
func to_params() -> Array:
	return [float(filter_type), range_min, range_max, falloff_low, falloff_high,
			1.0 if invert else 0.0, strength,
			measure_radius if uses_measure_radius() else 0.0,
			float(FieldSource.HOST_PROFILE if uses_host_profile() else FieldSource.BELOW_LAYER)]


## Migration: this property was called `kind` until it was renamed for legibility. Every `.tres` and
## `.tscn` authored before the rename stores `kind = 3`, and Godot DISCARDS a stored property it cannot
## find — so without this the whole point of the rename would be that every authored selector silently
## reverts to Slope, which is both the default and the one value that looks like nothing went wrong.
##
## `_set` is reached for exactly the properties the object does not otherwise have, which is what makes
## this a migration rather than an alias with two sources of truth: nothing in this file reads `kind`, and
## the moment the resource is next saved the old name is gone. `_get` answers for the same name so a
## user's own `selector.kind` keeps reading, rather than returning null at the one moment it matters.
##
## Gate BE loads a hand-written pre-rename resource and fails if the Filter Type comes back as Slope.
func _set(property: StringName, value: Variant) -> bool:
	if property == &"kind":
		filter_type = value
		return true
	return false


func _get(property: StringName) -> Variant:
	return filter_type if property == &"kind" else null
