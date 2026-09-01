# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevPathMask — a PATH as a [0,1] mask over the grid (§8).
#
# ---- WHY THIS EXISTS SEPARATELY FROM Path Distance ----
#
# Path Distance already answers "how far is this cell from the road", and a mask is a falloff over that.
# But the falloff wanted is almost never over METRES: it is over the road's own width, which varies along
# its length, and reconstructing "am I on the carriageway" downstream from `distance` alone would need
# the half-width as a second field to compare against. `t` is exactly that comparison already made, so
# this node is a threshold on `t` and stays honest wherever the road widens.
#
# ---- THE §8 WIRING THIS IS FOR ----
#
#   Input → Road Grade ──┬──────────────────→ Blend ← Erosion
#                        └─ roadbed (inv) → Blend.mask
#
# Road Grade publishes `roadbed` for the road it actually cut, which is the right mask when a road has
# been graded. This node is the mask you can have WITHOUT grading: keep a river off the carriageway, stop
# a scatter layer on the verge, hold erosion out of a corridor a road has not been cut into yet.
@tool
class_name Pasture3DGraphNodeDevPathMask
extends Pasture3DGraphNode

## Multiplies the path's half-width before the test. 1.0 is the carriageway edge; ~1.3 reaches the
## shoulder; larger values are a corridor rather than a road.
@export_range(0.05, 8.0, 0.01, "or_greater") var width_scale: float = 1.0:
	set(v):
		width_scale = maxf(v, 0.01)
		emit_changed()

## Metres over which the mask falls from 1 to 0 beyond the edge. 0 is a hard edge, which aliases badly at
## coarse grid spacings and is offered anyway because a mask fed to a REPLACE operation wants it.
@export_range(0.0, 50.0, 0.1, "or_greater") var feather: float = 2.0:
	set(v):
		feather = maxf(v, 0.0)
		emit_changed()

## Invert the result: 1 everywhere the road is NOT. The §8 wiring above needs the inverse, and asking for
## it here rather than through a downstream One Minus keeps a two-node idiom to one node.
@export var invert: bool = false:
	set(v):
		invert = v
		emit_changed()

var _path: Pasture3DGraphPath = null


func op() -> StringName:
	return &"dev_path_mask"


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


func blocks_native() -> bool:
	return true


## An empty path masks NOTHING, and that direction is not arbitrary.
##
## `invert` is applied to the empty answer too, so an unresolved Road Source under an inverted mask reads
## as "all terrain, no road" rather than as "no terrain at all". The alternative — filling 1 before the
## inversion — would make a graph being edited briefly erase everything it was protecting.
func eval_grid(_p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_gw * p_gh)
	if _path == null or _path.segment_count() == 0:
		out.fill(1.0 if invert else 0.0)
		return out

	# Cell CENTRES, the same convention as Path Distance — the two nodes describe the same road and a
	# half-cell disagreement between them would show as a mask that misses its own distance field.
	var dx := p_rect.size.x / float(maxi(p_gw, 1))
	var dz := p_rect.size.y / float(maxi(p_gh, 1))
	var min_x := p_rect.position.x + 0.5 * dx
	var min_z := p_rect.position.y + 0.5 * dz
	# ---- REGION: a closed path masks its INTERIOR, not a corridor along its edge ----
	#
	# Not a parameter on the corridor branch, a different rule. Thresholding `t` on a closed outline gives
	# two ribbons along the boundary with a hole down the middle — correct for a road, absurd for a lake.
	# `width_scale` says nothing here and is deliberately ignored rather than multiplied into something
	# meaningless; node_warnings says so out loud.
	if _path.closed:
		for iz in range(p_gh):
			var rrow := iz * p_gw
			var rwz: float = min_z + float(iz) * dz
			for ix in range(p_gw):
				var at := Vector2(min_x + float(ix) * dx, rwz)
				var m2: float = 1.0
				if not _path.inside(at):
					# Outside: fall off over `feather` metres of distance to the boundary. Inside is a flat
					# 1 — feathering inward as well would eat a small shape from both sides and leave a
					# region that never reaches full strength anywhere.
					var d: float = float(_path.nearest(at)["distance"])
					m2 = 0.0 if feather <= 0.0 else clampf(1.0 - d / feather, 0.0, 1.0)
				out[rrow + ix] = (1.0 - m2) if invert else m2
		return out

	for iz in range(p_gh):
		var row := iz * p_gw
		var wz: float = min_z + float(iz) * dz
		for ix in range(p_gw):
			var q := _path.nearest(Vector2(min_x + float(ix) * dx, wz))
			# Back from `t` to metres via the half-width AT THIS s, so the feather is a real distance
			# wherever the road is wide and wherever it is narrow. Reading the feather in `t` units
			# instead would make it four times softer on a four-lane road than on a track.
			var half: float = maxf(_path.half_width_at(q["s"]) * width_scale, 1e-6)
			var edge: float = float(q["distance"]) - half
			var m: float = 1.0
			if edge > 0.0:
				m = 0.0 if feather <= 0.0 else clampf(1.0 - edge / feather, 0.0, 1.0)
			out[row + ix] = (1.0 - m) if invert else m
	return out


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if _path != null and _path.closed and not is_equal_approx(width_scale, 1.0):
		out.append("This path is closed, so Path Mask fills its interior and Width Scale does nothing.")
	if width_scale < 0.1:
		out.append("Path Mask scales the width by %.2f, so the mask is narrower than one cell on most grids."
				% width_scale)
	return out
