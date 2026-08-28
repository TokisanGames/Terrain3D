# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeTalusProjection — a FILTER grid node: angle-of-repose slope relaxation and scree
# apron generation.
#
# Iteratively relaxes over-steep terrain slopes exceeding a critical talus angle (e.g. 35°), transferring
# excess volume downward to deposit natural scree aprons at cliff bottoms while conserving total elevation
# volume.
@tool
class_name Pasture3DGraphNodeTalusProjection
extends Pasture3DGraphNode

## Critical angle of repose in degrees. Slopes steeper than this will shed material downward.
@export_range(10.0, 80.0, 0.5) var talus_angle_deg: float = 35.0:
	set(v):
		talus_angle_deg = clampf(v, 1.0, 89.0)
		emit_changed()

## Number of relaxation solver passes. More passes allow talus to travel further down long slopes.
@export_range(1, 64, 1) var iterations: int = 16:
	set(v):
		iterations = clampi(v, 1, 128)
		emit_changed()

## Fraction of excess slope height transferred per pass (0.01..1.0).
@export_range(0.05, 1.0, 0.05) var transfer_rate: float = 0.5:
	set(v):
		transfer_rate = clampf(v, 0.01, 1.0)
		emit_changed()

## Cross-fade between input terrain (0.0) and relaxed talus surface (1.0).
@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		emit_changed()


func op() -> StringName:
	return &"talus_projection"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 5


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "talus_angle", "iterations", "transfer_rate", "amount"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.HEIGHT,
		PortType.FLOAT,
		PortType.INT,
		PortType.FLOAT,
		PortType.MASK,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return talus_angle_deg
		2: return float(iterations)
		3: return transfer_rate
		4: return amount
		_: return 0.0


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var in_grid: PackedFloat32Array
	if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and (p_inputs[0] as PackedFloat32Array).size() == n:
		in_grid = p_inputs[0]
	else:
		return Pasture3DGraphOps.zeros(n)

	var angle: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else talus_angle_deg
	var iters: int = int(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else iterations
	var rate: float = float(p_inputs[3][0]) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and p_inputs[3].size() > 0) else transfer_rate
	var amt: float = float(p_inputs[4][0]) if (p_inputs.size() > 4 and p_inputs[4] is PackedFloat32Array and p_inputs[4].size() > 0) else amount

	if is_zero_approx(amt) or iters <= 0:
		return in_grid.duplicate()

	var mask: PackedFloat32Array = (p_mask as PackedFloat32Array) if (p_mask is PackedFloat32Array and (p_mask as PackedFloat32Array).size() == n) else Pasture3DGraphOps.filled(n, 1.0)

	if not ClassDB.class_has_method("Pasture3DUtil", "talus_projection_grid"):
		push_error("[Pasture3D] Pasture3DUtil.talus_projection_grid is not bound. Rebuild GDExtension.")
		return in_grid.duplicate()

	var res: PackedFloat32Array = Pasture3DUtil.talus_projection_grid(in_grid, mask, p_gw, p_gh, p_rect,
			angle, iters, rate, amt)
	if res.size() != n:
		push_error("[Pasture3D] Talus projection native solve returned invalid grid size.")
		return in_grid.duplicate()

	return res


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(amount):
		w.append("%s: Amount is 0, so it passes the input through unchanged." % display_name())
	elif iterations <= 0:
		w.append("%s: Iterations is 0, so no talus relaxation occurs." % display_name())
	return w
