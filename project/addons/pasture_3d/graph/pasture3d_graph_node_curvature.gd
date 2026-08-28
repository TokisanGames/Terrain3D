# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeCurvature — a terrain curvature / second derivative MASK filter.
# Calculates local surface convexity (ridges/peaks) vs. concavity (valleys/gullies) using a discrete
# Laplacian kernel to generate precise, responsive distribution masks for texturing, vegetation, and erosion.
#
# Output: port 0 "mask" (MASK, normalized [0.0, 1.0])
@tool
class_name Pasture3DGraphNodeCurvature
extends Pasture3DGraphNode

enum Mode { CONVEXITY_RIDGE = 0, CONCAVITY_VALLEY = 1, TOTAL_CURVATURE = 2 }

@export_group("Curvature Analysis")
## Analysis mode: Convexity (mountain ridges/peaks), Concavity (valleys/drainage basins), or Total Curvature.
@export var mode: Mode = Mode.CONVEXITY_RIDGE:
	set(v):
		mode = v
		emit_changed()

## Kernel sampling distance in cells. Larger radius captures broader landforms; smaller radius captures fine micro-crests.
@export_range(1, 16, 1) var radius: int = 1:
	set(v):
		radius = maxi(v, 1)
		emit_changed()

## Contrast / gain multiplier applied to the resulting curvature mask.
@export_range(0.1, 10.0, 0.1, "or_greater") var contrast: float = 1.0:
	set(v):
		contrast = maxf(v, 0.01)
		emit_changed()


func op() -> StringName:
	return &"curvature"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 3


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "radius", "contrast"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.HEIGHT,
		PortType.INT,
		PortType.FLOAT,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return float(radius)
		2: return contrast
		_: return 0.0


func output_count() -> int:
	return 1


func output_names() -> PackedStringArray:
	return PackedStringArray(["mask"])


func output_port_type() -> int:
	return PortType.MASK


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.MASK])


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, _p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	var rad: int = int(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else radius
	var cont: float = float(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else contrast

	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)

	if not ClassDB.class_has_method("Pasture3DUtil", "curvature_grid"):
		push_error("[Pasture3D] Pasture3DUtil.curvature_grid is not bound. Rebuild GDExtension.")
		return Pasture3DGraphOps.zeros(n)

	var res: PackedFloat32Array = Pasture3DUtil.curvature_grid(surface, p_gw, p_gh, int(mode), rad, cont)
	if res.size() != n:
		push_error("[Pasture3D] Curvature native solve returned invalid grid size.")
		return Pasture3DGraphOps.zeros(n)

	return res
