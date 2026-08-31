# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DNodeRoad — the road's terrain effect as a step in the brush's modifier stack, beside
# `&"erode"` and `&"graph"`. See PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §8.
#
# It is a GRID node: the grader reads the whole footprint (a batter at one cell depends on the road's
# height at the arc length nearest it, which is nowhere near that cell in grid terms), so it cannot fold
# into the rasteriser's cell loop. The native C++ rasteriser does not know the `&"road"` op yet, so a
# brush carrying an active one routes onto the GDScript rasteriser exactly as an unsupported graph does
# (`Pasture3DTerrainBrush._stack_forces_gdscript`); the native `BrushModStep::ROAD` and then the GPU pass
# follow on the three-tier discipline, with this kernel as their A/B oracle.
#
# ---- WHY A MODIFIER AND NOT JUST THE BRUSH'S PAINT ----
#
# Because it makes the ordering against erosion an editable fact rather than a hidden one. `Erosion` then
# `Road` cuts the weathered mountain; `Road` then `Erosion` weathers the cut itself. Terrain3D's connector
# flattens the heightmap after the fact and erosion never learns about it. Here it is the order of two
# rows in a list.
#
# ---- LIVE by default, unlike Erosion and Graph ----
#
# Those two default to FROZEN because a solve over a terrain-spanning footprint costs seconds and
# `auto_refresh` re-bakes on every spline drag. Grading is a single pass over the footprint with a
# closed-form distance query, so freezing it would be a cache for something barely more expensive than
# the cache — and, worse, it would show the road lagging a spline the user is dragging, which is the one
# thing this modifier exists to make immediate. Freezing is still OFFERED, because a very long road with
# a fine alignment step is a different cost class.
@tool
class_name Pasture3DNodeRoad
extends Pasture3DNode

## Metres between alignment samples along the run. The solve and every per-sample array are at this
## spacing, so it sets both the vertical profile's resolution and the grader's along-road accuracy.
## 1 m matches the usual vertex spacing; coarsening it is the first thing to try on a very long road.
@export_range(0.25, 10.0, 0.25, "or_greater") var alignment_step: float = 1.0:
	set(v):
		alignment_step = maxf(v, 0.05)
		_touch()

## How far past the edge of formation the batters and the disturbed ground may reach, metres. Read from
## the resolved RoadType when this is negative — which is the default, so the road type stays the single
## place a road's width is described.
@export var verge_override: float = -1.0:
	set(v):
		verge_override = v
		_touch()

@export_group("Earthworks")
## Cross-fall of the carriageway as a rise/run ratio, so water sheds to the edges instead of standing on
## the road. Negative when this should come from the RoadType.
@export var crown_override: float = -1.0:
	set(v):
		crown_override = v
		_touch()

## Batter slopes as rise/run: how steeply the ground climbs out of a cutting and descends off an
## embankment. Negative takes the RoadType's. Cuttings normally stand steeper than embankments, which is
## why they are two numbers and not one.
@export var cut_batter_override: float = -1.0:
	set(v):
		cut_batter_override = v
		_touch()

@export var fill_batter_override: float = -1.0:
	set(v):
		fill_batter_override = v
		_touch()

@export_group("Structures")
## Height difference at which an unbridged stretch is REPORTED as wanting a structure, metres. It does
## not suppress anything on its own — an author marking a bridge segment does that (§4.2) — it only
## fills the `structure` mask, so a road quietly building a 40 m earth dam across a valley shows up as a
## warning instead of as something to notice in the viewport later.
@export_range(1.0, 60.0, 0.5, "or_greater") var structure_threshold: float = 8.0:
	set(v):
		structure_threshold = maxf(v, 0.5)
		_touch()

@export_group("Output")
## Keep the channel masks (`roadbed`, `cut`, `fill`, `verge`, `structure`) after the bake, for the mesh
## and control-map paint phase to read. They cost one float grid each, so a road that is only shaping
## terrain can turn them off.
@export var publish_masks: bool = true:
	set(v):
		publish_masks = v
		_touch()

@export_tool_button("Bake Road") var _bake_btn = clear_cache

## The last bake's masks, keyed by grid extent, and the diagnostics a warning is built from. Not saved:
## they are re-derived by the next bake, and a stale copy on disk would be worse than none.
var last_masks: Dictionary = {}
var last_alignment: Pasture3DRoadAlignment = null
var _cache: Dictionary = {}
var _stale: bool = false


func _init() -> void:
	if resource_name.is_empty():
		resource_name = "Road"


## The grader reads across the whole footprint — see the header.
func needs_grid() -> bool:
	return true


## Offered, but off by default. See the header for why this one differs from Erosion and Graph.
func _supports_freezing() -> bool:
	return true


func op() -> StringName:
	return &"road"


func clear_cache() -> void:
	_cache.clear()
	_stale = false
	_touch()


func cache_bytes() -> int:
	var total := 0
	for k in _cache:
		var e: Dictionary = _cache[k]
		for f in e:
			if e[f] is PackedFloat32Array:
				total += (e[f] as PackedFloat32Array).size() * 4
	return total


func cache_for(p_extent: String) -> Dictionary:
	return _cache.get(p_extent, {})


func store_cache(p_extent: String, p_entry: Dictionary) -> void:
	_cache[p_extent] = p_entry


## Set DURING a bake, so it deliberately does not `_touch()` — that would re-bake from inside a bake.
func set_stale(p_stale: bool) -> void:
	if _stale == p_stale:
		return
	_stale = p_stale
	if Engine.is_editor_hint():
		emit_changed.call_deferred()


## Resolve one earthworks number: this modifier's override when it is set, otherwise the road type's.
## The modifier overriding the type is deliberate and one-directional — a stack step is a local
## exception to a shared description, never a place the shared description gets edited from.
func resolved_number(p_override: float, p_type_value: float) -> float:
	return p_override if p_override >= 0.0 else p_type_value


func to_params() -> Dictionary:
	return {
		"alignment_step": alignment_step,
		"verge_override": verge_override,
		"crown_override": crown_override,
		"cut_batter_override": cut_batter_override,
		"fill_batter_override": fill_batter_override,
		"structure_threshold": structure_threshold,
		"publish_masks": publish_masks,
	}


func content_key() -> int:
	return hash([alignment_step, verge_override, crown_override, cut_batter_override,
			fill_batter_override, structure_threshold, publish_masks, enabled])


func modifier_warnings(p_host) -> PackedStringArray:
	var w := PackedStringArray()
	if not enabled:
		return w
	# The one host complaint worth making: this modifier reads a road's segments, its resolve chain and
	# its alignment, none of which exist on a Mound. Mounted on the wrong brush it is not subtly wrong,
	# it does nothing at all, and silence would leave the user adjusting batters that were never read.
	if not (p_host is Pasture3DRoadBrush):
		w.append(("%s only works on a Pasture3DRoadBrush — it reads the road's segments and solved "
			+ "alignment. On this brush it contributes nothing.") % display_name())
		return w
	var brush: Pasture3DRoadBrush = p_host
	if brush.resolved_road_type() == null:
		w.append("%s: no road type resolves on this brush, so it has no widths to grade to."
			% display_name())
	if brush.resolved_follow_terrain():
		w.append(("%s: Follow Terrain is on, so the road drapes and no vertical alignment is solved. "
			+ "The carriageway will inherit every bump under it.") % display_name())
	if _stale:
		w.append(("%s is FROZEN and the road has changed since it was baked, so the terrain is showing "
			+ "the OLD road. Press Bake Road, or set Evaluation to Live.") % display_name())
	var deep := _deepest_structure()
	if deep > structure_threshold:
		w.append(("%s: the road stands %.1f m clear of the ground at its worst, past the %.1f m "
			+ "structure threshold. Mark that stretch as a bridge, or it is graded as solid earth.")
			% [display_name(), deep, structure_threshold])
	return w


## Worst height the last bake put between the road and the ground, metres. 0 when nothing is baked.
func _deepest_structure() -> float:
	if last_alignment == null:
		return 0.0
	var worst := 0.0
	for i in last_alignment.count():
		worst = maxf(worst, absf(last_alignment.offset_at(i)))
	return worst
