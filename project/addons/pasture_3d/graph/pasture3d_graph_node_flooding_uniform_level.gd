# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeFloodingUniformLevel — flood the surface up to a uniform world-Y level.
#
# This is deliberately NOT LakeFlooding. LakeFlooding is a solver: it finds basins, fills them to their
# spillways, and can spawn water bodies. This is a comparison against a plane. It is the cheap node for the
# common case — a sea level, a valley reservoir at a known height — and it costs one subtraction per cell.
#
# It does not spawn a Pasture3DPond. Two nodes racing to create water bodies is a bug factory, so
# LakeFlooding keeps that relationship and this one publishes fields.
#
#   port 0  "height"  HEIGHT  the surface, raised to the level where it was below it (or passed through)
#   port 1  "depth"   HEIGHT  max(level - z, 0) in METRES — feed this to WaterMask
#   port 2  "mask"    MASK    1 where flooded
@tool
class_name Pasture3DGraphNodeFloodingUniformLevel
extends Pasture3DGraphNode

## The water surface, in WORLD METRES on Y — the same axis the height field is in, not a normalised depth.
@export_range(-500.0, 2000.0, 0.1, "or_greater", "or_less") var water_level: float = 0.0:
	set(v):
		water_level = v
		emit_changed()

## ON raises the terrain itself to the level, giving a flat lake bed you can see. OFF leaves the height
## untouched and publishes only the depth and mask, which is what you want when a water plane or a shader
## will render the surface and the terrain underneath should keep its shape.
@export var clamp_terrain: bool = true:
	set(v):
		clamp_terrain = v
		emit_changed()


func op() -> StringName:
	return &"flooding_uniform_level"


func role() -> Role:
	return Role.FILTER


## TRUE, where the spec proposed false so the node would fuse into a cell run. It cannot: the cell path in
## `evaluate()` never populates the aux channel array, so ports 1 and 2 of a fused node would silently read
## zeros. A multi-output node in this codebase is a grid node — that is not a performance choice, it is what
## makes the extra ports exist at all.
func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 2


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "water_level"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.FLOAT])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		1: return water_level
		_: return 0.0


func output_count() -> int:
	return 3


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "depth", "mask"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.HEIGHT, PortType.MASK])


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, _p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and p_inputs[0].size() == n) else Pasture3DGraphOps.zeros(n)
	var level: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else water_level

	if not ClassDB.class_has_method("Pasture3DUtil", "flooding_uniform_level_grid"):
		push_error("[Pasture3D] Pasture3DUtil.flooding_uniform_level_grid is not bound. Rebuild GDExtension.")
		return [surface.duplicate(), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	var res: Dictionary = Pasture3DUtil.flooding_uniform_level_grid(surface, p_gw, p_gh, level, clamp_terrain)
	if res.is_empty():
		return [surface.duplicate(), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]
	return [res["height"], res["depth"], res["mask"]]


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if not clamp_terrain:
		w.append("%s: Clamp Terrain is off, so the height output is the input unchanged and only the "
			% display_name() + "Depth and Mask ports carry the flood.")
	return w
