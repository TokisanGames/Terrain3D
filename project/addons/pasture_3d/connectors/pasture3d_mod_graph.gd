# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DNodeGraph — a brush node-stack step that runs a whole Pasture3DTerrainGraph over the brush's
# footprint and adds its output, feathered by the brush's interior profile. This is the MOUNT that makes
# the terrain graph (PASTURE3D_TERRAIN_GRAPH_SPEC.md) usable: the same reusable graph resource that can
# drive a whole landscape becomes a masked, local operation on a brush.
#
# It is a GRID node — the graph reads across the whole footprint, so it cannot fold into the cell loop —
# and the host evaluates it in `Pasture3DTerrainBrush._apply_graph_step`. Because the native C++
# rasteriser does not know the `&"graph"` op, a brush carrying an active one is routed onto the GDScript
# rasteriser (`Pasture3DTerrainBrush._native_raster` -> `_stack_forces_gdscript`); the graph itself is
# pure GDScript today.
#
# ---- FROZEN by default (mirrors Pasture3DNodeErosion) ----
#
# A graph over a terrain-spanning footprint is expensive, and auto_refresh re-bakes on every spline drag,
# so this defaults to FROZEN: its raw output is cached per grid EXTENT and re-evaluated only on a cache
# miss (a new extent, or reopening a scene) or an explicit Bake. While frozen, ANY change — a node param,
# the wiring, the graph swapped — leaves the cached output in place and raises a stale warning until you
# press Bake Graph. Set Evaluation to Live on a small graph to watch it update per drag.
#
# The cache stores the RAW graph output (before strength and the interior profile), which is why it stays
# valid as the spline drags WITHIN an extent: the graph is world-fixed, and only strength and the profile
# — applied per bake in _apply_graph_step — move with the footprint. So editing Strength never invalidates.
@tool
class_name Pasture3DNodeGraph
extends Pasture3DNode

## The graph to run. Its `.tres` is the reusable "one graph per landscape" unit — the same resource can
## drive a whole terrain elsewhere. Unassigned = the node is inactive (it contributes nothing and does
## not force the GDScript path).
@export var graph: Pasture3DTerrainGraph:
	set(v):
		if graph != null and graph.changed.is_connected(_touch):
			graph.changed.disconnect(_touch)
		graph = v
		if graph != null and not graph.changed.is_connected(_touch):
			graph.changed.connect(_touch)
		_touch()

## How strongly the graph's output replaces the incoming surface, 0..1, feathered further by the brush's
## interior profile so the rim stays clean. 0 = the graph does nothing; 1 = its output fully applies at the
## profile's centre. It is an AMOUNT, not metres: the graph is a filter (input → output), and a generator
## node inside it already carries its own amplitude.
@export_range(0.0, 1.0, 0.01) var strength: float = 1.0:
	set(v):
		strength = clampf(v, 0.0, 1.0)
		_touch()


# ---- The frozen cache (mirrors Pasture3DNodeErosion §6.3) --------------------------------------------
#
# IN MEMORY ONLY and keyed by grid EXTENT: the baked heights already persist in the layer, so the cache
# only saves re-evaluating after a reload, and several loops bake several grids that must not thrash one
# slot. Each entry is `{key, grid}` — `key` is the graph's content revision at bake time, the staleness
# signal. The host (Pasture3DTerrainBrush._compile_modifiers / _commit_modifier_caches) drives all of it;
# these methods are the storage it calls, the same contract the erosion modifier uses.
var _cache: Dictionary = {}
var _stale: bool = false

## Working input surface captured during brush rasterisation, used to render live 2D previews in Graph Editor
var last_input_surface: PackedFloat32Array = PackedFloat32Array()
var last_rect: Rect2 = Rect2(-50.0, -50.0, 100.0, 100.0)
var last_gw: int = 0
var last_gh: int = 0

@export_tool_button("Bake Graph") var _bake_btn = clear_cache


## Graph steps default to FROZEN — a solve per drag is unusable over a big footprint. See the header.
func _init() -> void:
	evaluation = Evaluation.FROZEN


func _supports_freezing() -> bool:
	return true


## Drop every cached evaluation, so the next refresh recomputes. This is the explicit Bake.
func clear_cache() -> void:
	if _cache.is_empty() and not _stale:
		return
	_cache.clear()
	_stale = false
	_touch()


func cache_bytes() -> int:
	var n := 0
	for k in _cache:
		n += (_cache[k].get("grid", PackedFloat32Array()) as PackedFloat32Array).size() * 4
	return n


func cache_for(p_extent: String) -> Dictionary:
	return _cache.get(p_extent, {})


func store_cache(p_extent: String, p_entry: Dictionary) -> void:
	_cache[p_extent] = p_entry


## Record whether the last bake served a cache the graph has since changed under. Set DURING a bake, so it
## deliberately does not `_touch()` (that would re-bake from inside a bake); it only refreshes warnings.
func set_stale(p_stale: bool) -> void:
	if _stale == p_stale:
		return
	_stale = p_stale
	if Engine.is_editor_hint():
		emit_changed.call_deferred()


func op() -> StringName:
	return &"graph"


## A graph reads the whole grid (its own grid nodes route across it), so it is a grid node and cannot be
## folded into the cell loop.
func needs_grid() -> bool:
	return true


## Inactive with no graph, a zero strength, or a graph with no output — exactly the cases where running
## it would cost the O(cells) evaluation and the forced GDScript path for nothing.
func is_active() -> bool:
	return enabled and graph != null and not is_zero_approx(strength) and graph.output_index() >= 0


func modifier_warnings(_p_host) -> PackedStringArray:
	var w := PackedStringArray()
	if not enabled:
		return w
	if graph == null:
		w.append("%s: no Terrain Graph assigned, so it contributes nothing." % display_name())
		return w
	if is_zero_approx(strength):
		w.append("%s: Strength is 0 m, so the graph contributes nothing." % display_name())
	if _stale:
		w.append(("%s is FROZEN and the graph has changed since it was baked, so the terrain is showing "
			+ "the OLD graph. Press Bake Graph to re-evaluate, or set Evaluation to Live.") % display_name())
	if evaluation == Evaluation.FROZEN and not _cache.is_empty():
		w.append("%s holds %.1f MB of cached graph output. Press Bake Graph to re-evaluate it."
			% [display_name(), cache_bytes() / 1048576.0])
	w.append_array(graph.graph_warnings())
	return w
