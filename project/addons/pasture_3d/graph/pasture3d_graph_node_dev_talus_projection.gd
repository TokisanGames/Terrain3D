# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevTalusProjection — pure GDScript reference oracle for Talus Projection slope relaxation.
# Used for algorithm prototyping, A/B testing, and automated headless CI parity verification.
@tool
class_name Pasture3DGraphNodeDevTalusProjection
extends Pasture3DGraphNode

@export_range(5.0, 85.0, 0.5) var talus_angle_deg: float = 35.0:
	set(v):
		talus_angle_deg = clampf(v, 5.0, 85.0)
		emit_changed()

@export_range(1, 64, 1) var iterations: int = 12:
	set(v):
		iterations = maxi(v, 1)
		emit_changed()

@export_range(0.01, 1.0, 0.01) var transfer_rate: float = 0.5:
	set(v):
		transfer_rate = clampf(v, 0.01, 1.0)
		emit_changed()

@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		emit_changed()


func op() -> StringName:
	return &"dev_talus_projection"


func role() -> Role:
	return Role.FILTER


func display_name() -> String:
	return "[Dev/GD] Talus Projection"


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 2


func input_names() -> PackedStringArray:
	return PackedStringArray(["input", "mask"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK])


func input_unwired_default(p_port: int) -> float:
	return 1.0 if p_port == 1 else 0.0


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var in_grid: PackedFloat32Array
	if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and (p_inputs[0] as PackedFloat32Array).size() == n:
		in_grid = p_inputs[0]
	else:
		return Pasture3DGraphOps.zeros(n)

	if is_zero_approx(amount) or iterations <= 0:
		return in_grid.duplicate()

	var mask: PackedFloat32Array
	if p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and (p_inputs[1] as PackedFloat32Array).size() == n:
		mask = p_inputs[1]
	else:
		mask = Pasture3DGraphOps.filled(n, 1.0)

	return _eval_grid_gdscript(in_grid, mask, p_gw, p_gh, p_rect)


func _eval_grid_gdscript(in_grid: PackedFloat32Array, mask: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var h := in_grid.duplicate()
	var dx := p_rect.size.x / maxf(float(p_gw - 1), 1.0) if (p_rect.size.x > 0.0 and p_gw > 1) else 2.0
	var dz := p_rect.size.y / maxf(float(p_gh - 1), 1.0) if (p_rect.size.y > 0.0 and p_gh > 1) else 2.0
	var diag_d := sqrt(dx * dx + dz * dz)

	var tan_talus := tan(deg_to_rad(talus_angle_deg))
	var rate := transfer_rate * 0.25

	var offsets: Array[Vector3] = [
		Vector3(-1, 0, dx),
		Vector3(1, 0, dx),
		Vector3(0, -1, dz),
		Vector3(0, 1, dz),
		Vector3(-1, -1, diag_d),
		Vector3(1, -1, diag_d),
		Vector3(-1, 1, diag_d),
		Vector3(1, 1, diag_d)
	]

	var delta := PackedFloat32Array()
	delta.resize(n)

	for _iter in range(iterations):
		delta.fill(0.0)

		for iz in range(p_gh):
			var row := iz * p_gw
			for ix in range(p_gw):
				var i := row + ix
				var hi := h[i]
				if not is_finite(hi):
					continue

				for off in offsets:
					var nx := ix + int(off.x)
					var nz := iz + int(off.y)
					if nx < 0 or nx >= p_gw or nz < 0 or nz >= p_gh:
						continue

					var ni := nz * p_gw + nx
					var hni := h[ni]
					if not is_finite(hni):
						continue

					var diff := hi - hni
					var dist := off.z
					var max_diff := dist * tan_talus

					if diff > max_diff:
						var excess := (diff - max_diff) * rate
						delta[i] -= excess
						delta[ni] += excess

		for i in range(n):
			if is_finite(h[i]):
				h[i] += delta[i]

	for i in range(n):
		if is_finite(in_grid[i]) and is_finite(h[i]):
			var m := clampf(mask[i], 0.0, 1.0)
			h[i] = lerpf(in_grid[i], h[i], amount * m)

	return h


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(amount):
		w.append("%s: Amount is 0, so it passes input through unchanged." % display_name())
	return w
