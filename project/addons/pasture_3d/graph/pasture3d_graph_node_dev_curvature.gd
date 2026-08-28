# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevCurvature — pure GDScript reference oracle for Discrete Laplacian Curvature mask.
# Used for algorithm prototyping, A/B testing, and automated headless CI parity verification.
@tool
class_name Pasture3DGraphNodeDevCurvature
extends Pasture3DGraphNode

enum Mode {
	CONVEXITY_RIDGE,
	CONCAVITY_VALLEY,
	TOTAL_CURVATURE
}

@export var mode: Mode = Mode.CONVEXITY_RIDGE:
	set(v):
		mode = v
		emit_changed()

@export_range(1, 16, 1) var radius: int = 1:
	set(v):
		radius = maxi(v, 1)
		emit_changed()

@export_range(0.1, 10.0, 0.1, "or_greater") var contrast: float = 1.0:
	set(v):
		contrast = maxf(v, 0.01)
		emit_changed()


func op() -> StringName:
	return &"dev_curvature"


func role() -> Role:
	return Role.FILTER


func display_name() -> String:
	return "[Dev/GD] Curvature Mask"


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["field"])


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
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if p_inputs.size() > 0 \
			else Pasture3DGraphOps.zeros(n)
	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)

	return _eval_grid_gdscript(surface, p_gw, p_gh)


func _eval_grid_gdscript(surface: PackedFloat32Array, p_gw: int, p_gh: int) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var result := PackedFloat32Array()
	result.resize(n)
	result.fill(0.0)

	var r := radius
	var raw_curv := PackedFloat32Array()
	raw_curv.resize(n)
	var max_val: float = 0.0

	for iz in range(p_gh):
		var row := iz * p_gw
		for ix in range(p_gw):
			var i := row + ix
			var c := surface[i]
			if not is_finite(c):
				raw_curv[i] = 0.0
				continue

			var hxm: float
			if ix - r >= 0:
				hxm = surface[row + (ix - r)]
			else:
				var opp := surface[row + mini(ix + r, p_gw - 1)]
				hxm = 2.0 * c - opp if is_finite(opp) else c

			var hxp: float
			if ix + r < p_gw:
				hxp = surface[row + (ix + r)]
			else:
				var opp := surface[row + maxi(ix - r, 0)]
				hxp = 2.0 * c - opp if is_finite(opp) else c

			var hzm: float
			if iz - r >= 0:
				hzm = surface[(iz - r) * p_gw + ix]
			else:
				var opp := surface[mini(iz + r, p_gh - 1) * p_gw + ix]
				hzm = 2.0 * c - opp if is_finite(opp) else c

			var hzp: float
			if iz + r < p_gh:
				hzp = surface[(iz + r) * p_gw + ix]
			else:
				var opp := surface[maxi(iz - r, 0) * p_gw + ix]
				hzp = 2.0 * c - opp if is_finite(opp) else c

			if not is_finite(hxm): hxm = c
			if not is_finite(hxp): hxp = c
			if not is_finite(hzm): hzm = c
			if not is_finite(hzp): hzp = c

			var laplacian := (hxm + hxp + hzm + hzp) * 0.25 - c
			var val := 0.0

			match mode:
				Mode.CONVEXITY_RIDGE:
					val = maxf(-laplacian, 0.0)
				Mode.CONCAVITY_VALLEY:
					val = maxf(laplacian, 0.0)
				Mode.TOTAL_CURVATURE:
					val = absf(laplacian)

			raw_curv[i] = val
			max_val = maxf(max_val, val)

	if max_val < 1e-5:
		return result

	for i in range(n):
		if is_finite(surface[i]):
			var norm: float = clampf((raw_curv[i] / max_val) * contrast, 0.0, 1.0)
			result[i] = smoothstep(0.0, 1.0, norm)

	return result
