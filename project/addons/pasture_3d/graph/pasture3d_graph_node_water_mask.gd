# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeWaterMask — the submerged mask, and a shore band measured in METRES from the waterline.
#
# The shore band is what the node is for. Thresholding a depth field is one line of Remap; a beach that is
# eight metres wide whatever the bake resolution is not, because it needs a real distance transform. This
# runs the SIGNED transform from §5.1 against the water mask and windows |d| — so the band straddles the
# waterline and the wet-sand material does not stop dead at the water's edge.
#
#   port 0  "water"  MASK  1 where depth exceeds the threshold
#   port 1  "shore"  MASK  1 at the waterline, falling to 0 at Shore Width on BOTH sides
@tool
class_name Pasture3DGraphNodeWaterMask
extends Pasture3DGraphNode

enum ShoreFalloff { LINEAR = 0, SMOOTH = 1 }

## Depth in METRES above which a cell counts as underwater. Not zero by default: a depth field that grazes
## the waterline would otherwise flicker a one-cell speckle of "water" across every damp flat.
@export_range(0.0, 10.0, 0.001, "or_greater") var depth_threshold: float = 0.01:
	set(v):
		depth_threshold = maxf(v, 0.0)
		emit_changed()

## Half-width of the shore band in WORLD METRES, measured either side of the waterline.
@export_range(0.0, 200.0, 0.1, "or_greater") var shore_width: float = 8.0:
	set(v):
		shore_width = maxf(v, 0.0)
		emit_changed()

@export var shore_falloff: ShoreFalloff = ShoreFalloff.SMOOTH:
	set(v):
		shore_falloff = v
		emit_changed()


func op() -> StringName:
	return &"water_mask"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


## Two ports, where the spec listed three. The spec's `height` port fed nothing: the water mask comes from
## the depth, and the shore band comes from the distance to that mask. A port wired to nothing inside the
## node is worse than a missing one — it tells the author a value matters when it does not.
func input_count() -> int:
	return 2


func input_names() -> PackedStringArray:
	return PackedStringArray(["depth", "shore_width"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.FLOAT])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		1: return shore_width
		_: return 0.0


func output_count() -> int:
	return 2


func output_names() -> PackedStringArray:
	return PackedStringArray(["water", "shore"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.MASK, PortType.MASK])


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var depth: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and p_inputs[0].size() == n) else Pasture3DGraphOps.zeros(n)
	var width: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else shore_width

	if not ClassDB.class_has_method("Pasture3DUtil", "water_mask_grid"):
		push_error("[Pasture3D] Pasture3DUtil.water_mask_grid is not bound. Rebuild GDExtension.")
		return [Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	var res: Dictionary = Pasture3DUtil.water_mask_grid(depth, p_gw, p_gh, p_rect, depth_threshold, width,
			int(shore_falloff))
	if res.is_empty():
		return [Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]
	return [res["water"], res["shore"]]


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(shore_width):
		w.append("%s: Shore Width is 0, so the Shore output is empty and only the Water mask is produced."
			% display_name())
	return w
