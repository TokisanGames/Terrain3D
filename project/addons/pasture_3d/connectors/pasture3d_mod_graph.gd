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
# ---- Evaluation is LIVE in this increment ----
#
# Unlike Pasture3DNodeErosion this does NOT default to FROZEN yet: the frozen cache (keyed by grid extent
# and the input surface, with a Bake button and a stale warning) is the next optimisation, reusing the
# erosion modifier's cache pattern verbatim. Until then a graph re-evaluates on every refresh, so keep
# graphs modest while dragging. See PASTURE3D_TERRAIN_GRAPH_SPEC.md, build order.
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

## Metres of relief at the graph's full output, masked by the brush's interior profile so the rim stays
## clean — the same convention as the Noise and Relief nodes' amplitude.
@export var strength: float = 1.0:
	set(v):
		strength = v
		_touch()


func op() -> StringName:
	return &"graph"


## A graph reads the whole grid (its own grid nodes route across it), so it is a grid node and cannot be
## folded into the cell loop.
func needs_grid() -> bool:
	return true


## Inactive with no graph, a zero strength, or a graph with no output — exactly the cases where running
## it would cost the O(cells) evaluation and the forced GDScript path for nothing.
func is_active() -> bool:
	return enabled and graph != null and not is_zero_approx(strength) and graph.output_node >= 0


func modifier_warnings(_p_host) -> PackedStringArray:
	var w := PackedStringArray()
	if not enabled:
		return w
	if graph == null:
		w.append("%s: no Terrain Graph assigned, so it contributes nothing." % display_name())
		return w
	if is_zero_approx(strength):
		w.append("%s: Strength is 0 m, so the graph contributes nothing." % display_name())
	w.append_array(graph.graph_warnings())
	return w
