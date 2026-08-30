# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeRelativeElevation — a FILTER grid node: where a cell sits between its LOCAL basin
# floor and its LOCAL crest.
#
# This is the correct gating field for snow, treeline, exposed rock and cliff vegetation, and it is not
# interchangeable with Mask (Altitude). Mask gates on ABSOLUTE world height, which is right for exactly
# one massif — the moment a graph has two mountains of different heights, every one of them gets its
# snowline at the same world Y, and the shorter mountain gets none at all. RelativeElevation measures
# each landform against its own base, so a 400 m hill and a 3000 m peak both read 1.0 at the summit.
@tool
class_name Pasture3DGraphNodeRelativeElevation
extends Pasture3DGraphNode

enum OutputUnits {
	NORMALISED, ## 0 on the local basin floor, 1 on the local crest. A MASK.
	METRES, ## Metres above the local basin floor. A HEIGHT.
}

## The neighbourhood the cell is judged against, in WORLD METRES. Roughly "how far away does the local
## valley floor live" — set it to the scale of the landform you want gated, not the scale of the detail.
@export_range(10.0, 2000.0, 5.0, "or_greater") var radius: float = 200.0:
	set(v):
		radius = maxf(v, 0.0)
		emit_changed()

@export var output_units: OutputUnits = OutputUnits.NORMALISED:
	set(v):
		output_units = v
		emit_changed()


func op() -> StringName:
	return &"relative_elevation"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 2


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "radius"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.FLOAT])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.MASK if output_units == OutputUnits.NORMALISED else PortType.HEIGHT])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return radius
		_: return 0.0


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var in_grid: PackedFloat32Array
	if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and (p_inputs[0] as PackedFloat32Array).size() == n:
		in_grid = p_inputs[0]
	else:
		return Pasture3DGraphOps.zeros(n)

	var rad: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else radius
	if rad <= 0.0:
		return in_grid.duplicate()

	if not ClassDB.class_has_method("Pasture3DUtil", "relative_elevation_grid"):
		push_error("[Pasture3D] Pasture3DUtil.relative_elevation_grid is not bound. Rebuild GDExtension.")
		return in_grid.duplicate()

	var res: PackedFloat32Array = Pasture3DUtil.relative_elevation_grid(in_grid, p_gw, p_gh, p_rect,
			rad, int(output_units))
	if res.size() != n:
		push_error("[Pasture3D] Relative elevation returned an invalid grid size.")
		return in_grid.duplicate()
	return res


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if radius <= 0.0:
		w.append("%s: Radius is 0, so every cell is its own neighbourhood and the output is constant." % display_name())
	return w
