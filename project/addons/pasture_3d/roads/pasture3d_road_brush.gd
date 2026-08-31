# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadBrush — lays out a road along one or more child Path3D splines, open or closed, exactly
# as Pasture3DRidge and Pasture3DTrough lay out a crest or a channel.
# See PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §2 and §4.1.
#
# ---- WHY A BRUSH ----
#
# The plugin's authoring idiom is a Pasture3DTerrainBrush with child splines and a modifier stack, and a
# brush can already mount an entire terrain graph inside that stack (Pasture3DNodeGraph). So
# "brush-authored" and "graph-driven" were never alternatives: the brush is the authoring surface and
# the stack is how a road's terrain effect will reach the heightmap in P2. Extending the base hands over
# the spline gizmos, `snap_to_surface`, the debounced repaint, undo, the FROZEN/stale/Bake contract and
# the native rasteriser path — none of which a standalone road node would get.
#
# ---- P0 SCOPE: THIS BRUSH DOES NOT TOUCH THE TERRAIN YET ----
#
# `_paint_spline` is deliberately empty. P0 is the data model and the resolve chain; the grading
# modifier is P2 (a Pasture3DRoadModifier in the stack, with the mask channels the proposal's §8 lists).
# An empty paint is safe rather than half-done — the brush can be placed, parented, given segments and
# resolved against, and it will not write a single vertex until the phase that is supposed to.
@tool
@icon("res://addons/pasture_3d/icons/brush_terrain.svg")
class_name Pasture3DRoadBrush
extends Pasture3DTerrainBrush

@export_group("Road")
## What this brush overrides for its whole length. Sits between its segments and its group in the
## resolve chain (§5.3). Unset fields inherit; they are never copied down from the group.
@export var road_defaults: Pasture3DRoadOverrides:
	set(v):
		if road_defaults != null and road_defaults.changed.is_connected(_on_road_changed):
			road_defaults.changed.disconnect(_on_road_changed)
		road_defaults = v
		if road_defaults != null and not road_defaults.changed.is_connected(_on_road_changed):
			road_defaults.changed.connect(_on_road_changed)
		_on_road_changed()

## Per-stretch overrides, each covering a range of arc length along the spline (§4.2). Later entries win
## where two overlap, so a short bridge can sit inside a long gravel stretch.
@export var segments: Array[Pasture3DRoadSegment] = []:
	set(v):
		for s: Pasture3DRoadSegment in segments:
			if s != null and s.changed.is_connected(_on_road_changed):
				s.changed.disconnect(_on_road_changed)
		segments = v
		for s: Pasture3DRoadSegment in segments:
			if s != null and not s.changed.is_connected(_on_road_changed):
				s.changed.connect(_on_road_changed)
		_on_road_changed()

## Close the spline into a loop. Roads are usually open runs; a ring road or a closed test circuit is
## the exception, which is why this defaults off where Pasture3DMound's equivalent defaults on.
@export var closed: bool = false:
	set(v):
		closed = v
		_schedule_refresh()

## Bumped whenever a resolved value could have changed. The staleness key P2's grading modifier and P4's
## intersection resolver will fold into their caches.
var content_key: int = 0


func _init() -> void:
	super()
	if road_defaults == null:
		road_defaults = Pasture3DRoadOverrides.new()


func _ready() -> void:
	super()
	if road_defaults != null and not road_defaults.changed.is_connected(_on_road_changed):
		road_defaults.changed.connect(_on_road_changed)
	for s: Pasture3DRoadSegment in segments:
		if s != null and not s.changed.is_connected(_on_road_changed):
			s.changed.connect(_on_road_changed)


func _on_road_changed() -> void:
	content_key += 1
	update_configuration_warnings()


# ---- The resolve chain (§5.3) -------------------------------------------------------------------

## This brush's group, or null when it is parented straight under the network. A group is optional.
func road_group() -> Pasture3DRoadGroup:
	return Pasture3DRoadGroup.find_for(get_parent())


## This brush's network, or null when it is not under one.
func road_network() -> Pasture3DRoadNetwork:
	return Pasture3DRoadNetwork.find_for(get_parent())


## The override levels, NEAREST FIRST, optionally including the segment covering `p_distance` metres
## along the spline. The one place the hierarchy's order is written down: everything that resolves a
## road value goes through here rather than walking parents itself.
func resolve_chain(p_distance: float = NAN) -> Array:
	var chain: Array = []
	if is_finite(p_distance):
		var seg := segment_at(p_distance)
		if seg != null:
			chain.append(seg)
	chain.append(road_defaults)
	var grp := road_group()
	if grp != null:
		chain.append(grp.road_defaults)
	var net := road_network()
	if net != null:
		chain.append(net.road_defaults)
	return chain


## The resolved value of one inheritable field, walking Segment -> Brush -> Group -> Network. Returns
## null when no level has an opinion — ask the road type for those (`resolved_road_type` first).
func resolved(p_field: StringName, p_distance: float = NAN) -> Variant:
	return Pasture3DRoadOverrides.resolve(resolve_chain(p_distance), p_field)


## The road type in force, optionally at a distance along the spline. Falls back to the first type the
## group offers, so a freshly placed brush under a configured network builds something rather than
## nothing.
func resolved_road_type(p_distance: float = NAN) -> Pasture3DRoadType:
	var t: Variant = resolved(&"road_type", p_distance)
	if t != null:
		return t as Pasture3DRoadType
	var grp := road_group()
	if grp != null:
		var avail := grp.available_road_types()
		if not avail.is_empty():
			return avail[0]
	var net := road_network()
	if net != null:
		var types := net.valid_road_types()
		if not types.is_empty():
			return types[0]
	return null


## Lanes in force at `p_distance`, falling through to the road type's own default — the last link in
## the chain, and the reason a type carries real values rather than sentinels.
func resolved_lane_count(p_distance: float = NAN) -> int:
	var v: Variant = resolved(&"lane_count", p_distance)
	if v != null:
		return int(v)
	var t := resolved_road_type(p_distance)
	return t.lane_count if t != null else 2


## Physics surface in force at `p_distance`. Mid-stage surface changes (§4.4) are a segment overriding
## this, which is exactly the case arc-length ranges exist for.
func resolved_surface_id(p_distance: float = NAN) -> StringName:
	var v: Variant = resolved(&"surface_id", p_distance)
	if v != null:
		return StringName(v)
	var t := resolved_road_type(p_distance)
	return t.surface_id if t != null else &""


## True when the road drapes on the terrain instead of solving a grade-limited alignment. Defaults
## FALSE: a draped road is the failure the P1 solver exists to avoid, so it has to be asked for.
func resolved_follow_terrain(p_distance: float = NAN) -> bool:
	var v: Variant = resolved(&"follow_terrain", p_distance)
	return int(v) == int(Pasture3DRoadOverrides.Tri.ON) if v != null else false


# ---- Segments -----------------------------------------------------------------------------------

## The segment covering `p_distance`, or null. LAST match wins, so a short bridge declared after a long
## gravel stretch overrides it inside its range — the array order is the precedence, which is the same
## rule the modifier stack uses and the only one that survives being read out loud.
func segment_at(p_distance: float) -> Pasture3DRoadSegment:
	var found: Pasture3DRoadSegment = null
	for s: Pasture3DRoadSegment in segments:
		if s != null and s.covers(p_distance):
			found = s
	return found


## True when `p_distance` is carried on a bridge. Read by P2's grader (do not cut the terrain here) and
## by P4's intersection resolver (an overpass overlaps without meeting, §6.3).
func is_bridge_at(p_distance: float) -> bool:
	var s := segment_at(p_distance)
	return s != null and s.is_bridge


# ---- Brush base hooks ---------------------------------------------------------------------------

func _default_layer_name() -> String:
	var grp := road_group()
	return grp.layer_name if grp != null else "Roads"


func _default_snap_to_surface() -> bool:
	return true # the plan alignment is placed ON the ground; P1 then decides the road's own height


func _spline_basename() -> String:
	return "Road"


func _is_closed() -> bool:
	return closed


func _padding() -> float:
	var t := resolved_road_type()
	return (t.disturbed_width(resolved_lane_count()) * 0.5 + 2.0) if t != null else 16.0


## Starter shape: a straight run, matching Ridge's.
func _make_starter_curve() -> Curve3D:
	var c := Curve3D.new()
	c.add_point(Vector3(0.0, 0.0, -50.0))
	c.add_point(Vector3(0.0, 0.0, 50.0))
	return c


## P0: no terrain effect. The grading modifier is P2 — see the header.
func _paint_spline(_path: Path3D) -> void:
	pass


func _get_configuration_warnings() -> PackedStringArray:
	var out := super()
	if road_network() == null:
		out.append("No Pasture3DRoadNetwork above this brush. Road types and defaults cannot resolve.")
	if resolved_road_type() == null:
		out.append("No road type resolves here. Set one on this brush, or add one to the network catalogue.")
	var total := _spline_length()
	for s: Pasture3DRoadSegment in segments:
		if s != null:
			out.append_array(s.range_warnings(total))
	return out


## Total arc length of this brush's splines, metres, or NAN when there is nothing to measure. Used to
## tell a segment it has been left past the end of a shortened spline.
func _spline_length() -> float:
	var total := 0.0
	var any := false
	for path: Path3D in _get_splines():
		if path != null and path.curve != null and path.curve.point_count >= 2:
			total += path.curve.get_baked_length()
			any = true
	return total if any else NAN
