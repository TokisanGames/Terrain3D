# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadSegment — an override applied to a RANGE OF ARC LENGTH along a road brush's spline:
# "from 400 m to 2400 m this is gravel, and the last 80 m of that is a bridge".
# See PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §4.2.
#
# ---- WHY ARC LENGTH, AND WHY A RESOURCE ----
#
# The natural-looking design is one segment per spline INTERVAL, as a scene node — which is what
# godot-road-generator does. Both halves of that were changed here, for four reasons:
#
#   1. Spline point spacing is an authoring convenience, not a geometric unit. A 2 km straight is one
#      point-to-point interval; a fussy corner is six. Nothing about the road agrees with that split.
#   2. Inserting a point SPLITS a segment and orphans whatever was overridden on it — and users insert
#      points constantly. Under arc length, inserting a point in the middle of a gravel stretch leaves
#      the gravel stretch alone, which is the only behaviour anyone expects.
#   3. Mesh chunking has to be free to align to terrain REGIONS (§10) so a road chunk's lifetime matches
#      a region's. If a segment were the chunk, chunk length would be decided by where the artist
#      happened to click.
#   4. Scene nodes do not scale. Hundreds of kilometres of road is thousands of nodes in the tree and in
#      the .tscn. Resources in an array cost a row in the inspector.
#
# So a segment is a Resource in `Pasture3DRoadBrush.segments`, mirroring how the brush already holds its
# `modifiers` — same inspector idiom, same undo behaviour, same bake contract.
#
# It EXTENDS Pasture3DRoadOverrides rather than holding one, because a segment IS an override plus the
# range it applies to. Everything it does not set resolves up the chain to the brush.
@tool
class_name Pasture3DRoadSegment
extends Pasture3DRoadOverrides

## The name on this segment's ROW in the brush's Segments list, so a list of four overrides does not
## read as four identical rows. A view onto `resource_name`, exactly as Pasture3DNode.label is — the
## storage already exists and a second string would only give the two a way to disagree.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var label: String:
	set(v):
		resource_name = v
	get:
		return resource_name

@export_group("Range")
## Where this override starts, metres along the spline from its beginning.
@export var from_distance: float = 0.0:
	set(v):
		from_distance = maxf(v, 0.0)
		emit_changed()

## Where it ends, metres along the spline. A range that ends at or before it starts covers nothing and
## is reported by `range_warnings()` rather than silently doing nothing.
@export var to_distance: float = 100.0:
	set(v):
		to_distance = maxf(v, 0.0)
		emit_changed()

@export_group("Structure")
## This stretch is carried on a bridge: the terrain is NOT graded under it, and the alignment is free of
## the ground. It also does more work than it looks — a bridge segment is excluded from intersection
## resolution (§6.3), because an overpass OVERLAPS every road it crosses without meeting any of them.
## Grade separation therefore falls out of this one flag.
@export var is_bridge: bool = false:
	set(v):
		is_bridge = v
		emit_changed()

## Suppress terrain paint over this range, leaving the natural surface. For a ford, or a stretch where
## the road is meant to have been reclaimed.
@export var suppress_paint: bool = false:
	set(v):
		suppress_paint = v
		emit_changed()


## Metres this override covers. Zero for a range that ends where it starts.
func length() -> float:
	return maxf(to_distance - from_distance, 0.0)


## True when `p_distance` metres along the spline falls inside this segment. Half-open [from, to) so two
## segments that abut at the same distance do not both claim the boundary — the later one wins there,
## which is also the rule `Pasture3DRoadBrush.segment_at` relies on.
func covers(p_distance: float) -> bool:
	return p_distance >= from_distance and p_distance < to_distance


## True when this segment's range overlaps `p_other`'s. Overlap is legal — the LAST matching segment in
## the brush's array wins, so a short bridge can sit inside a long gravel stretch — but it is worth
## surfacing, because an accidental overlap looks exactly like a setting that will not take.
func overlaps(p_other: Pasture3DRoadSegment) -> bool:
	if p_other == null:
		return false
	return from_distance < p_other.to_distance and p_other.from_distance < to_distance


## Problems worth showing on the brush. Not errors: a segment past the end of a shortened spline is a
## normal intermediate state while editing, and deleting it for the user would be worse than saying so.
func range_warnings(p_spline_length: float = NAN) -> PackedStringArray:
	var out := PackedStringArray()
	if length() <= 0.0:
		out.append("Segment '%s' covers no distance (from %.1f m, to %.1f m)."
				% [resource_name if not resource_name.is_empty() else "Segment", from_distance, to_distance])
	if is_finite(p_spline_length) and from_distance >= p_spline_length:
		out.append("Segment '%s' starts at %.1f m, past the end of the spline (%.1f m)."
				% [resource_name if not resource_name.is_empty() else "Segment", from_distance, p_spline_length])
	return out
