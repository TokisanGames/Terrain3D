# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodePathDistance — turns a PATH into three fields: distance, s and t (§8).
#
# ---- THE PRODUCTION NODE. THE MATHS IS IN C++ ----
#
# The algorithm, and the argument for it, live in Pasture3DGraphNodeDevPathDistance — the [Dev/GD] oracle
# this node is measured against by RoadNativeParityGate. Read that file for WHY the query is analytic
# rather than jump-flooded, and why three outputs come out of one node. This file is the production half:
# it marshals the path into flat arrays, calls Pasture3DUtil.path_query_grid, and FAILS FAST if the kernel
# is not there (PASTURE3D_GDSCRIPT_CPP_NODE_SEPARATION_SPEC.md §3.1).
#
# ---- THE PATH FLATTENS TWICE, IN TWO PLACES, AND THAT IS NOT DUPLICATION ----
#
# This body is the TIER 2 form: the node owns the Pasture3DGraphPath and hands C++ two flat arrays per
# evaluation. It runs whenever this node is evaluated on its own — a preview tap, a folded sub-tree, a
# graph held on the GDScript path by something else in it.
#
# The TIER 3 form is `compile_graph_program`, which since P2c puts the same two arrays in the program's
# geometry table and lowers this node to GRAPH_OP_PATH_QUERY. Both hand the same points and widths to the
# same kernel; what differs is WHEN the flattening happens — per evaluation here, once per bake there,
# shared by every slot that names the road.
#
# The flattening is cheap either way and it is per evaluation, not per cell: two Packed arrays copied
# once, against a nearest-segment search run gw*gh times.
@tool
class_name Pasture3DGraphNodePathDistance
extends Pasture3DGraphNode

## What `distance` reads where the path is empty or unreachable, in metres.
##
## Not INF and not 0. INF poisons every downstream arithmetic node into NAN, and 0 means "on the road",
## which would make a graph with an unresolved Road Source paint a road over the entire terrain — the
## most destructive possible reading of "no road here".
@export var unreachable_distance: float = 10000.0:
	set(v):
		unreachable_distance = v
		emit_changed()

## Clamp `distance` to this many metres, 0 for no clamp. A distance field is almost always consumed
## through a falloff over the first few metres, and clamping keeps the useful range out of the noise when
## the field is previewed or written to a 16-bit channel.
@export_range(0.0, 2000.0, 1.0, "or_greater") var max_distance: float = 0.0:
	set(v):
		max_distance = v
		emit_changed()

var _path: Pasture3DGraphPath = null


func op() -> StringName:
	return &"path_distance"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["path"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.PATH])


func output_count() -> int:
	return 3


func output_names() -> PackedStringArray:
	return PackedStringArray(["distance", "s", "t"])


## `distance` and `s` are metres, so HEIGHT-typed rather than MASK: a mask is [0,1] by contract and these
## two are not. `t` is normalised but SIGNED and unbounded off the carriageway, which is also not a mask.
func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.HEIGHT, PortType.HEIGHT])


func reads_paths() -> bool:
	return true


func set_path_inputs(p_paths: Array) -> void:
	_path = p_paths[0] if p_paths.size() > 0 and p_paths[0] is Pasture3DGraphPath else null


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func eval_grid_channels(_p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	if not ClassDB.class_has_method("Pasture3DUtil", "path_query_grid"):
		push_error("[Pasture3D] Pasture3DUtil.path_query_grid is not bound. Rebuild GDExtension.")
		return _unreachable_fill(n)

	# An empty or unresolved path is handled INSIDE the kernel, not here, so the two cannot disagree about
	# what "no road" reads as — the one answer in this node whose wrong value flattens a terrain.
	var pts := _path.points if _path != null else PackedVector2Array()
	var widths := _path.half_widths if _path != null else PackedFloat32Array()
	var res: Dictionary = Pasture3DUtil.path_query_grid(pts, widths, p_gw, p_gh, p_rect,
			unreachable_distance, max_distance)
	if not bool(res.get("ok", false)):
		push_error("[Pasture3D] path_query_grid failed for a %d x %d grid." % [p_gw, p_gh])
		return _unreachable_fill(n)

	var dist: PackedFloat32Array = res["distance"]
	if dist.size() != n:
		push_error("[Pasture3D] path_query_grid returned %d cells for a %d cell grid." % [dist.size(), n])
		return _unreachable_fill(n)
	return [dist, res["s"], res["t"]]


## The safe answer when the kernel is missing or failed: far away, everywhere. Not zeros — see
## `unreachable_distance`. A fail-fast that returned a plausible field would be the silent degradation the
## whole native separation exists to delete.
func _unreachable_fill(p_n: int) -> Array:
	var dist := PackedFloat32Array()
	var s_out := PackedFloat32Array()
	var t_out := PackedFloat32Array()
	dist.resize(p_n)
	s_out.resize(p_n)
	t_out.resize(p_n)
	dist.fill(unreachable_distance if max_distance <= 0.0 else minf(unreachable_distance, max_distance))
	s_out.fill(0.0)
	t_out.fill(0.0)
	return [dist, s_out, t_out]


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if max_distance > 0.0 and max_distance < 1.0:
		out.append("Path Distance clamps at %.2f m, so almost the whole field reads as the clamp."
				% max_distance)
	return out
