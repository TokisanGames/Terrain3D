# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevRoadSource — the GENERATOR end of §8: puts a road into a terrain graph as a PATH.
#
# ---- IT NAMES A ROAD, IT DOES NOT OWN ONE ----
#
# A graph is a Resource and has no way to reach the scene, so this node cannot go and find a
# Pasture3DRoadBrush by itself. It holds a ROAD KEY, and the host that runs the graph resolves that key
# against the network and injects the geometry before evaluating — the same shape as the input surface,
# which is likewise handed in rather than fetched.
#
# The consequence is worth stating because it looks like a bug the first time: a Road Source in a graph
# opened on its own, with no host, produces an EMPTY path. Every query answers INF, Path Distance fills
# with `unreachable_distance`, and nothing crashes. That is the correct behaviour for a road that has not
# been baked yet, and it is the same state as a road whose brush was deleted.
#
# `path` is also directly assignable, and that is not only for tests: a graph that wants a fixed
# centreline it authored itself — a canal, a fence line, a boundary — is a legitimate use, and there is
# nothing in the query that cares whether a road brush made the points.
@tool
class_name Pasture3DGraphNodeDevRoadSource
extends Pasture3DGraphNode

## The road this node stands for, by the key Pasture3DRoadNetwork uses. Empty means "whatever path is
## assigned", which is what a hand-authored path or a gate uses.
@export var road_key: String = "":
	set(v):
		road_key = v
		emit_changed()

## The resolved geometry. Written by the host at bake, or assigned directly. Null until then.
##
## Emits `changed` through this node when the path itself changes, which is what makes a re-baked road
## invalidate the caches of everything downstream: the evaluator folds a source node's revision into its
## consumers' input hashes, so a path that changed silently would otherwise serve a stale distance field
## that looks exactly like a correct one.
@export var path: Pasture3DGraphPath:
	set(v):
		if path != null and path.changed.is_connected(emit_changed):
			path.changed.disconnect(emit_changed)
		path = v
		if path != null and not path.changed.is_connected(emit_changed):
			path.changed.connect(emit_changed)
		emit_changed()


## The road keys the HOST last offered, for the inspector dropdown. Never saved and never read by the
## solve — `road_key` remains the only thing that decides which road this node names.
##
## Stamped by Pasture3DRoadNetwork.resolve_graph_paths, which is the one place that already walks the
## graph looking for these nodes and already has the network in hand. A graph is a Resource and cannot
## reach the scene, so the list has to arrive from outside for the same reason the PATH does.
var editor_road_keys: PackedStringArray = PackedStringArray()


## Offer the network's roads as suggestions, and keep the field typeable.
##
## ENUM_SUGGESTION rather than ENUM, deliberately. A hard enum can only hold values that exist RIGHT NOW,
## so a graph opened with its network absent — a scene mid-load, a graph edited on its own, a road being
## renamed — would show its key as invalid and the first click would silently rewrite it to a different
## road. A suggestion list makes the common case a dropdown without making the uncommon case destructive.
func _validate_property(property: Dictionary) -> void:
	if property["name"] != &"road_key" or editor_road_keys.is_empty():
		return
	property["hint"] = PROPERTY_HINT_ENUM_SUGGESTION
	property["hint_string"] = ",".join(editor_road_keys)


func op() -> StringName:
	return &"dev_road_source"


func role() -> Role:
	return Role.GENERATOR


func input_count() -> int:
	return 0


func input_names() -> PackedStringArray:
	return PackedStringArray()


func output_names() -> PackedStringArray:
	return PackedStringArray(["path"])


func output_port_type() -> int:
	return PortType.PATH


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.PATH])


func path_output() -> Pasture3DGraphPath:
	return path


## A PATH producer still fills a grid slot, with zeros. See Pasture3DGraphNode.path_output for why the
## slot exists rather than being special-cased out of every loop that indexes by node.
func eval_cell(_p_wx: float, _p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	return 0.0


## Native cannot carry a resource down a wire, and the bail is graph-wide: one Road Source drops the
## WHOLE graph to the GDScript path. Said out loud here rather than discovered as a slowdown, because
## that is a real cost and the reason §8 frames the graph route as the case that needs control, not as
## the route a plain road should take.
func blocks_native() -> bool:
	return true


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if path == null or path.segment_count() == 0:
		if road_key.is_empty():
			out.append("Road Source has no road key and no path: it produces nothing.")
		else:
			out.append("Road Source \"%s\" has not been resolved yet; it produces an empty path."
					% road_key)
	return out
