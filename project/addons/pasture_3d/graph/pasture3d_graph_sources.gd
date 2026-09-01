# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphSources — the one place that knows what a HOST owes a graph before it can be evaluated.
#
# ---- WHY THIS IS ONE FUNCTION AND NOT TWO ----
#
# A graph is a Resource: no position in the scene, no parent, no way to reach a brush. So every source node
# that names something in the scene — a road, and now a brush outline — has to be resolved from outside,
# and the three places that run a graph (the brush's graph step, the graph editor's preview, the graph
# editor's inspector hand-off) each have to do it.
#
# Roads were resolved directly through Pasture3DRoadNetwork.resolve_graph_paths at all three. Adding a
# second kind of source that way means six calls that must stay in step, and the failure when they do not
# is silent: a graph previews with its shapes resolved and BAKES with them empty, or the reverse, and
# either reads as a solver bug. A value defined in three places is fixed in none. So the sites call this,
# and this decides what resolution means.
@tool
class_name Pasture3DGraphSources
extends RefCounted


## Resolve every scene-naming source node in `p_graph` against `p_host`'s scene. Returns how many nodes
## were filled, roads and shapes together.
##
## `p_host` may be null — a graph edited with no brush in hand — and then nothing resolves and nothing
## errors. That is the same state as a road whose brush was deleted, and \§4.3's empty-path rule is what
## keeps it from being a crash: queries answer `unreachable`, masks answer 0.
static func resolve(p_graph: Pasture3DTerrainGraph, p_host: Node = null) -> int:
	if p_graph == null:
		return 0
	var filled := 0
	if p_host != null:
		var net := Pasture3DRoadNetwork.find_for(p_host)
		if net != null:
			filled += net.resolve_graph_paths(p_graph, p_host)
	filled += resolve_shapes(p_graph, p_host)
	return filled


## The shape half. Split out so it can be gated on its own, and called with an explicit terrain by hosts
## that have one but are not themselves under it.
##
## A key naming no brush leaves the node's path ALONE rather than clearing it, for the reason
## resolve_graph_paths gives at length: clearing would make a brush mid-rename flatten every terrain
## reading it for one bake, which reads as a solver bug rather than as a lookup that missed.
static func resolve_shapes(p_graph: Pasture3DTerrainGraph, p_host: Node = null) -> int:
	if p_graph == null:
		return 0
	var terrain := _terrain_of(p_host)
	var by_key := {}
	var keys := PackedStringArray()
	var collected := false
	var filled := 0
	for node in p_graph.nodes:
		if node == null or node.op() != &"shape_source":
			continue
		var src: Pasture3DGraphNodeShapeSource = node
		# Collected for EVERY shape source, including ones with an empty key: the dropdown's whole job is
		# to be there before you have chosen anything.
		if not collected:
			collected = true
			if terrain != null:
				for b in shape_brushes(terrain):
					var k: String = b.shape_key()
					by_key[k] = b
					keys.append(k)
				keys.sort()
		src.editor_shape_keys = keys
		if src.shape_key.is_empty():
			continue
		if by_key.has(src.shape_key):
			var brush: Pasture3DTerrainBrush = by_key[src.shape_key]
			_assign(src, brush.graph_shape_path(src.spline_index))
			filled += 1
	return filled


## Every brush under `p_terrain` that can offer an outline, in scene order.
##
## Road brushes are EXCLUDED. Not because a road has no spline — it has one, and this would happily hand
## it over — but because a road's centreline through a node called Shape Source is a trap: it is open, so
## Path Mask gives a corridor, which is what Road Source plus Path Mask already does, correctly and with
## the road's real per-vertex widths instead of nothing. Two ways to do one thing, one of them worse.
static func shape_brushes(p_terrain: Node) -> Array[Pasture3DTerrainBrush]:
	var out: Array[Pasture3DTerrainBrush] = []
	if p_terrain != null:
		_collect(p_terrain, out)
	return out


static func _collect(p_at: Node, p_out: Array[Pasture3DTerrainBrush]) -> void:
	for c in p_at.get_children():
		if c is Pasture3DTerrainBrush and not (c is Pasture3DRoadBrush):
			var b := c as Pasture3DTerrainBrush
			if b.graph_shape_count() > 0:
				p_out.append(b)
		_collect(c, p_out)


static func _terrain_of(p_host: Node) -> Node:
	var n: Node = p_host
	while n != null:
		if n is Pasture3D:
			return n
		n = n.get_parent()
	return null


## Assign only when the outline actually CHANGED. Assigning unconditionally emits `changed`, which bumps
## the node's revision, which invalidates every downstream cache — so a graph with a shape in it would
## re-solve from scratch on every bake and the cache would look broken rather than bypassed. This is the
## same rule Pasture3DRoadNetwork._assign follows, and it has its own control in the gate.
static func _assign(p_src: Pasture3DGraphNodeShapeSource, p_path: Pasture3DGraphPath) -> void:
	if p_path == null:
		return
	var cur := p_src.path
	if cur != null and cur.closed == p_path.closed and cur.points == p_path.points:
		return
	p_src.path = p_path
