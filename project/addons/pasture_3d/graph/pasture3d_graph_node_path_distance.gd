# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodePathDistance — turns a PATH into three fields: distance, s and t (§8).
#
# ---- ANALYTIC, NOT JUMP FLOODING ----
#
# The graph already has a Distance Transform and it uses JFA, for a reason that does not carry over here:
# an exact scan over a MASK is sequential, so CPU and GPU would disagree and the same terrain would change
# as it crossed the 256² threshold. Distance to a set of LINE SEGMENTS is closed form. Every cell is
# independent, the candidate set comes from a uniform index, and the answer is exact on both backends by
# construction rather than by tolerance.
#
# It is also the only way to get `s` and `t` at all. A flood knows which seed cell it came from; it does
# not know how far along a road that seed was, and it cannot know which side of the road it is on.
#
# ---- WHY THREE OUTPUTS AND NOT THREE NODES ----
#
# All three fall out of one query. Splitting them into three nodes would run the same nearest-segment
# search three times over the same grid to return three fields of it, and — worse — would let a graph wire
# `s` from one node and `t` from another with different parameters, so the two would describe different
# roads while looking like one.
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


func blocks_native() -> bool:
	return true


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func eval_grid_channels(_p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var dist := PackedFloat32Array()
	var s_out := PackedFloat32Array()
	var t_out := PackedFloat32Array()
	dist.resize(n)
	s_out.resize(n)
	t_out.resize(n)
	if _path == null or _path.segment_count() == 0:
		# One fill, not a per-cell branch. An unresolved Road Source is a normal state and the whole grid
		# has the same answer, so the empty case must not cost a query per cell to say so.
		dist.fill(_clamped(unreachable_distance))
		s_out.fill(0.0)
		t_out.fill(0.0)
		return [dist, s_out, t_out]

	# Cell CENTRES, matching the evaluator's own convention for a cell node's world XZ. Sampling corners
	# instead would offset the whole field by half a cell against every other node in the graph, which is
	# invisible at 1 m spacing and obvious at 16 m.
	var dx := p_rect.size.x / float(maxi(p_gw, 1))
	var dz := p_rect.size.y / float(maxi(p_gh, 1))
	var min_x := p_rect.position.x + 0.5 * dx
	var min_z := p_rect.position.y + 0.5 * dz
	for iz in range(p_gh):
		var row := iz * p_gw
		var wz: float = min_z + float(iz) * dz
		for ix in range(p_gw):
			var q := _path.nearest(Vector2(min_x + float(ix) * dx, wz))
			var idx := row + ix
			dist[idx] = _clamped(q["distance"])
			s_out[idx] = q["s"]
			t_out[idx] = q["t"]
	return [dist, s_out, t_out]


func _clamped(p_d: float) -> float:
	return p_d if max_distance <= 0.0 else minf(p_d, max_distance)


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if max_distance > 0.0 and max_distance < 1.0:
		out.append("Path Distance clamps at %.2f m, so almost the whole field reads as the clamp."
				% max_distance)
	return out
