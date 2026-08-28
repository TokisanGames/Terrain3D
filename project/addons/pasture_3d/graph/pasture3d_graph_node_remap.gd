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
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["field"])


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, _p_rect: Rect2) -> PackedFloat32Array:
	var s: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if p_inputs.size() > 0 else Pasture3DGraphOps.zeros(p_gw * p_gh)
	return Pasture3DUtil.remap_grid(s, in_min, in_max, out_min, out_max, clamp_output, soft_knee, invert)


func eval_cell(_p_wx: float, _p_wz: float, p_inputs: PackedFloat32Array) -> float:
	var x := p_inputs[0] if p_inputs.size() > 0 else 0.0
	if is_nan(x):
		return NAN

	var span := in_max - in_min
	var t: float = (x - in_min) / span if absf(span) > 1e-9 else 0.0

	if invert:
		t = 1.0 - t

	if clamp_output:
		if soft_knee > 0.0:
			t = _apply_soft_knee(t, soft_knee)
		else:
			t = clampf(t, 0.0, 1.0)

	return lerpf(out_min, out_max, t)


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
