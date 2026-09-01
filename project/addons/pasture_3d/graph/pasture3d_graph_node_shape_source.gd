# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeShapeSource — §8.1: a brush's own outline, as a closed PATH in the graph.
#
# ---- WHY THIS EXISTS, AND WHY IT IS NOT A SECOND ROAD SOURCE ----
#
# The geometry table has always been able to hold a closed path, and Path Mask has filled its interior by
# even-odd winding since P2a. Nothing in the editor could produce one. So the whole closed-path branch —
# kernel, GPU refusal, oracle — was reachable only from a gate, which is a good way for a feature to be
# correct and useless at the same time.
#
# The case it serves: a Mound already draws the region it raises. A graph that wants to mask something to
# that same region had to have the region drawn AGAIN as a Plow. Two splines meaning one thing, drifting
# apart the moment either is edited, with nothing anywhere saying they were supposed to agree. A Shape
# Source names the Mound instead, and the outline has one author.
#
# ---- ONE SPLINE, NOT ALL OF THEM ----
#
# A brush may hold several splines and paints all of them. This node offers ONE, chosen by index, because
# `in_g` names one table entry (§4.2) — and the honest extension for several is the `group` id recorded at
# the end of §8.2, not a node that quietly unions its outlines into a single ring. A union of two disjoint
# rings written as one polyline is not a polyline; it is two, joined by a segment across the gap between
# them, and every distance query would see that segment as a wall.
#
# `spline_index` past the end resolves to an EMPTY path, not to the last spline. Clamping would make a
# graph keep working while pointing at a shape nobody chose, after a spline was deleted.
@tool
class_name Pasture3DGraphNodeShapeSource
extends Pasture3DGraphNode

## The brush this node stands for, by the key its terrain uses. Empty means "whatever path is assigned",
## which is what a hand-authored outline or a gate uses. Note the difference from Road Source: an empty key
## does NOT fall back to the host brush, because the host of a graph is the brush the graph is a modifier
## ON, and a brush masking itself by its own outline is a step that can never change anything.
@export var shape_key: String = "":
	set(v):
		shape_key = v
		emit_changed()

## Which of the named brush's splines to take. See the header for why this is not a union.
@export_range(0, 32) var spline_index: int = 0:
	set(v):
		spline_index = maxi(v, 0)
		emit_changed()

## The resolved outline. Written by the host at bake, or assigned directly. Null until then.
##
## Emits `changed` through this node when the path itself changes, so a brush whose spline was dragged
## invalidates the caches of everything downstream — the same reason Road Source does it.
@export var path: Pasture3DGraphPath:
	set(v):
		if path != null and path.changed.is_connected(emit_changed):
			path.changed.disconnect(emit_changed)
		path = v
		if path != null and not path.changed.is_connected(emit_changed):
			path.changed.connect(emit_changed)
		emit_changed()


## The shape keys the HOST last offered, for the inspector dropdown. Never saved and never read by the
## solve. Setting it NOTIFIES, because `_validate_property` only runs while Godot builds a property list
## and a list stamped after that build is invisible — the bug that left Road Key a String box for a while.
var editor_shape_keys: PackedStringArray = PackedStringArray():
	set(v):
		if editor_shape_keys == v:
			return
		editor_shape_keys = v
		notify_property_list_changed()


## ENUM_SUGGESTION, not ENUM, for the reason spelled out on Road Source: a hard enum can only hold values
## that exist right now, so a graph opened with its scene absent would render the key it already holds as
## invalid and rewrite it to a different brush on the first click.
func _validate_property(property: Dictionary) -> void:
	if property["name"] != &"shape_key" or editor_shape_keys.is_empty():
		return
	property["hint"] = PROPERTY_HINT_ENUM_SUGGESTION
	property["hint_string"] = ",".join(editor_shape_keys)


func op() -> StringName:
	return &"shape_source"


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


## A PATH producer still fills a grid slot, with zeros. See Pasture3DGraphNode.path_output.
func eval_cell(_p_wx: float, _p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	return 0.0


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if path == null or path.segment_count() == 0:
		if shape_key.is_empty():
			out.append("Shape Source has no brush key and no path: it produces nothing.")
		else:
			out.append("Shape Source \"%s\" has not been resolved yet; it produces an empty path."
					% shape_key)
	elif not path.closed:
		# Worth saying out loud rather than leaving to be discovered: an OPEN path through Path Mask is a
		# corridor, not a region, so a Ridge or Trough named here masks a ribbon along its line. That is a
		# legitimate thing to want, and it is not what "Shape Source" leads you to expect.
		out.append("Shape Source \"%s\" resolved to an OPEN outline, so Path Mask will give a corridor "
				% shape_key + "along it rather than filling a region.")
	return out
