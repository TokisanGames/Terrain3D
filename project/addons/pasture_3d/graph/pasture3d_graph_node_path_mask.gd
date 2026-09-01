# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodePathMask — a PATH as a [0,1] mask over the grid (§8).
#
# ---- THE PRODUCTION NODE. THE MATHS IS IN C++ ----
#
# The argument for the node — why a mask is not just a falloff over Path Distance, and what the §8 wiring
# uses it for — lives in Pasture3DGraphNodeDevPathMask, the [Dev/GD] oracle this node is measured against
# by RoadNativeParityGate. This file marshals the path into flat arrays, calls
# Pasture3DUtil.path_mask_grid, and FAILS FAST if the kernel is not there
# (PASTURE3D_GDSCRIPT_CPP_NODE_SEPARATION_SPEC.md §3.1).
#
# ---- OPEN AND CLOSED ARE TWO RULES, NOT ONE RULE WITH A SWITCH ----
#
# An open path masks a CORRIDOR along itself. A closed one masks its INTERIOR, by an even-odd winding test.
# The distinction is the whole point of §8.1: it lets a Mound, Plow or Pond outline be reused as a graph
# mask instead of the same region being drawn a second time as a Plow. Thresholding across-distance on a
# closed outline would give two ribbons along the boundary and a hole down the middle — right for a road,
# absurd for a lake — so the kernel branches on `closed` rather than reinterpreting a parameter.
@tool
class_name Pasture3DGraphNodePathMask
extends Pasture3DGraphNode

## Multiplies the path's half-width before the test. 1.0 is the carriageway edge; ~1.3 reaches the
## shoulder; larger values are a corridor rather than a road. Ignored on a closed path — see `feather`.
@export_range(0.05, 8.0, 0.01, "or_greater") var width_scale: float = 1.0:
	set(v):
		width_scale = maxf(v, 0.01)
		emit_changed()

## Metres over which the mask falls from 1 to 0 beyond the edge — the carriageway edge on an open path,
## the boundary on a closed one. 0 is a hard edge, which aliases badly at coarse grid spacings and is
## offered anyway because a mask fed to a REPLACE operation wants it.
@export_range(0.0, 50.0, 0.1, "or_greater") var feather: float = 2.0:
	set(v):
		feather = maxf(v, 0.0)
		emit_changed()

## Invert the result: 1 everywhere the road is NOT. The §8 wiring needs the inverse, and asking for it
## here rather than through a downstream One Minus keeps a two-node idiom to one node.
@export var invert: bool = false:
	set(v):
		invert = v
		emit_changed()

var _path: Pasture3DGraphPath = null


func op() -> StringName:
	return &"path_mask"


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


func output_names() -> PackedStringArray:
	return PackedStringArray(["mask"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.MASK])


func reads_paths() -> bool:
	return true


func set_path_inputs(p_paths: Array) -> void:
	_path = p_paths[0] if p_paths.size() > 0 and p_paths[0] is Pasture3DGraphPath else null


## Still true, and it is the TIER 3 statement: this node's maths is native, but the lowered program has no
## operand a polyline can travel in, so a graph containing one cannot be handed to graph_eval_grid whole.
## Removed in P2c with the geometry table, not before.
func eval_grid(_p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	if not ClassDB.class_has_method("Pasture3DUtil", "path_mask_grid"):
		push_error("[Pasture3D] Pasture3DUtil.path_mask_grid is not bound. Rebuild GDExtension.")
		return _empty_fill(n)

	# The empty-path answer is the KERNEL's, not this node's, so the two cannot disagree about which
	# direction "no road" masks in — the one value here whose inversion erases a terrain instead of
	# protecting it.
	var pts := _path.points if _path != null else PackedVector2Array()
	var widths := _path.half_widths if _path != null else PackedFloat32Array()
	var is_closed := _path != null and _path.closed
	var out: PackedFloat32Array = Pasture3DUtil.path_mask_grid(pts, widths, is_closed, p_gw, p_gh,
			p_rect, width_scale, feather, invert)
	if out.size() != n:
		push_error("[Pasture3D] path_mask_grid returned %d cells for a %d cell grid." % [out.size(), n])
		return _empty_fill(n)
	return out


## The safe answer when the kernel is missing or failed: mask nothing, inverted the same way the kernel
## would have inverted it. A fail-fast that returned a plausible mask would be the silent degradation the
## whole native separation exists to delete.
func _empty_fill(p_n: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_n)
	out.fill(1.0 if invert else 0.0)
	return out


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if _path != null and _path.closed and not is_equal_approx(width_scale, 1.0):
		out.append("This path is closed, so Path Mask fills its interior and Width Scale does nothing.")
	if width_scale < 0.1:
		out.append("Path Mask scales the width by %.2f, so the mask is narrower than one cell on most grids."
				% width_scale)
	return out
