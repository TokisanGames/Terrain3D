# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDepressionFilling — a FILTER grid node: Priority-Flood hydrological sink/pit filling.
#
# Identifies enclosed topographical depressions (local minima that cannot drain to grid borders) and
# raises them to the minimum elevation of their drainage spillway:
#
#   h_filled(x) = max(h(x), z_spillway(x))
#
# Eliminates spurious local minima, guaranteeing monotonic hydraulic drainage for subsequent erosion
# passes or road/river routing.
@tool
class_name Pasture3DGraphNodeDepressionFilling
extends Pasture3DGraphNode

## Minimal outward slope gradient (m/m) added to filled flats to ensure monotonic downhill flow.
@export_range(0.0, 0.01, 0.00005, "exp") var epsilon_slope: float = 0.0001:
	set(v):
		epsilon_slope = maxf(v, 0.0)
		emit_changed()

## Maximum vertical depth (in metres) to fill in a depression. 0.0 = unlimited (fills to spillway).
@export_range(0.0, 50.0, 0.5, "or_greater") var fill_depth_limit: float = 0.0:
	set(v):
		fill_depth_limit = maxf(v, 0.0)
		emit_changed()

## Cross-fade between original input (0.0) and filled terrain (1.0).
@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		emit_changed()


func op() -> StringName:
	return &"depression_filling"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["input"])


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var in_grid: PackedFloat32Array
	if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and (p_inputs[0] as PackedFloat32Array).size() == n:
		in_grid = p_inputs[0]
	else:
		return Pasture3DGraphOps.zeros(n)

	if is_zero_approx(amount):
		return in_grid.duplicate()

	if not ClassDB.class_has_method("Pasture3DUtil", "depression_filling_grid"):
		push_error("[Pasture3D] Pasture3DUtil.depression_filling_grid is not bound. Rebuild GDExtension.")
		return in_grid.duplicate()

	var res: PackedFloat32Array = Pasture3DUtil.depression_filling_grid(in_grid, p_gw, p_gh, p_rect,
			epsilon_slope, fill_depth_limit, amount)
	if res.size() != n:
		push_error("[Pasture3D] Depression filling native solve returned invalid grid size.")
		return in_grid.duplicate()

	return res


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(amount):
		w.append("%s: Amount is 0, so it passes input through unchanged." % display_name())
	return w
