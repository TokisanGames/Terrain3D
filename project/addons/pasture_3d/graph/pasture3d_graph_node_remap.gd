# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeRemap — a range remapping and soft-knee saturation CELL node.
# Maps arbitrary elevation or mask intervals [in_min, in_max] -> [out_min, out_max] with
# optional soft-knee saturation smoothing, boundary clamping, and range inversion.
@tool
class_name Pasture3DGraphNodeRemap
extends Pasture3DGraphNode

@export_group("Input Window")
## Lower bound of the input range.
@export var in_min: float = 0.0:
	set(v):
		in_min = v
		emit_changed()

## Upper bound of the input range.
@export var in_max: float = 100.0:
	set(v):
		in_max = v
		emit_changed()

@export_group("Output Range")
## Output value corresponding to in_min (or in_max if inverted).
@export var out_min: float = 0.0:
	set(v):
		out_min = v
		emit_changed()

## Output value corresponding to in_max (or in_min if inverted).
@export var out_max: float = 1.0:
	set(v):
		out_max = v
		emit_changed()

@export_group("Shaping")
## Clamp output within [out_min, out_max] interval.
@export var clamp_output: bool = true:
	set(v):
		clamp_output = v
		emit_changed()

## Soft-knee margin [0.0..1.0]. Smooths saturation transition near the clamping bounds.
@export_range(0.0, 1.0, 0.01) var soft_knee: float = 0.0:
	set(v):
		soft_knee = clampf(v, 0.0, 1.0)
		emit_changed()

## Invert the normalized mapping direction.
@export var invert: bool = false:
	set(v):
		invert = v
		emit_changed()

@export_tool_button("Auto Fit Range") var _auto_btn = auto_fit_range


func auto_fit_range(p_min: float = 0.0, p_max: float = 1.0) -> void:
	in_min = p_min
	in_max = p_max
	emit_changed()


func op() -> StringName:
	return &"remap"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return false


func input_count() -> int:
	return 5


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "in_min", "in_max", "out_min", "out_max"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.FLOAT, PortType.FLOAT, PortType.FLOAT, PortType.FLOAT])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		1: return in_min
		2: return in_max
		3: return out_min
		4: return out_max
		_: return 0.0


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, _p_rect: Rect2) -> PackedFloat32Array:
	var s: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if p_inputs.size() > 0 else Pasture3DGraphOps.zeros(p_gw * p_gh)
	var imin: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else in_min
	var imax: float = float(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else in_max
	var omin: float = float(p_inputs[3][0]) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and p_inputs[3].size() > 0) else out_min
	var omax: float = float(p_inputs[4][0]) if (p_inputs.size() > 4 and p_inputs[4] is PackedFloat32Array and p_inputs[4].size() > 0) else out_max
	return Pasture3DUtil.remap_grid(s, imin, imax, omin, omax, clamp_output, soft_knee, invert)


func eval_cell(_p_wx: float, _p_wz: float, p_inputs: PackedFloat32Array) -> float:
	var x: float = p_inputs[0] if p_inputs.size() > 0 else 0.0
	if is_nan(x):
		return NAN

	var imin: float = p_inputs[1] if (p_inputs.size() > 1 and not is_nan(p_inputs[1])) else in_min
	var imax: float = p_inputs[2] if (p_inputs.size() > 2 and not is_nan(p_inputs[2])) else in_max
	var omin: float = p_inputs[3] if (p_inputs.size() > 3 and not is_nan(p_inputs[3])) else out_min
	var omax: float = p_inputs[4] if (p_inputs.size() > 4 and not is_nan(p_inputs[4])) else out_max

	var span := imax - imin
	var t: float = (x - imin) / span if absf(span) > 1e-9 else 0.0

	if invert:
		t = 1.0 - t

	if clamp_output:
		if soft_knee > 0.0:
			t = _apply_soft_knee(t, soft_knee)
		else:
			t = clampf(t, 0.0, 1.0)

	return lerpf(omin, omax, t)


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if absf(in_max - in_min) <= 1e-9:
		w.append("%s: Input window is empty (in_min == in_max) — all values map to out_min." % display_name())
	return w


## Soft-knee smooth clamping function using smooth polynomial transitions at boundaries
func _apply_soft_knee(p_t: float, p_knee: float) -> float:
	var k := clampf(p_knee * 0.5, 0.001, 0.499)
	if p_t <= -k:
		return 0.0
	if p_t < k:
		var u := (p_t + k) / (2.0 * k)
		return smoothstep(0.0, 1.0, u) * k
	if p_t <= 1.0 - k:
		return p_t
	if p_t < 1.0 + k:
		var u := (p_t - (1.0 - k)) / (2.0 * k)
		return (1.0 - k) + smoothstep(0.0, 1.0, u) * k
	return 1.0
