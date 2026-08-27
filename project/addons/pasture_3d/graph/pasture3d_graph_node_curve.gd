# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeCurve — a FILTER cell node: remap the INPUT field through a transfer Curve. One input,
# one output; it reshapes what is wired into it and generates nothing. Use it to flatten valleys, exaggerate
# peaks, clip a side, or apply any custom height response.
#
# METRIC domain and range (matching the Terrace node's height-domain model): the input window
# [input_min, input_max] metres maps onto the curve's X in [0, 1], the curve's Y in [0, 1] maps back onto
# [output_min, output_max] metres, and `amount` cross-fades input against the remap. Values outside the
# input window clamp to the window edges.
@tool
class_name Pasture3DGraphNodeCurve
extends Pasture3DGraphNode

## The transfer function. X and Y are both read over [0, 1]. Unassigned = a pass-through (and a warning).
@export var curve: Curve:
	set(v):
		if curve != null and curve.changed.is_connected(emit_changed):
			curve.changed.disconnect(emit_changed)
		curve = v
		if curve != null and not curve.changed.is_connected(emit_changed):
			curve.changed.connect(emit_changed)
		emit_changed()

@export_group("Input window (metres → curve X)")
## Input height mapped to the curve's left edge (X = 0).
@export var input_min: float = 0.0:
	set(v):
		input_min = v
		emit_changed()

var in_min: float:
	get: return input_min
	set(v): input_min = v

## Input height mapped to the curve's right edge (X = 1).
@export var input_max: float = 100.0:
	set(v):
		input_max = v
		emit_changed()

var in_max: float:
	get: return input_max
	set(v): input_max = v

@export_group("Output range (curve Y → metres)")
## Height the curve's Y = 0 maps to.
@export var output_min: float = 0.0:
	set(v):
		output_min = v
		emit_changed()

var out_min: float:
	get: return output_min
	set(v): output_min = v

## Height the curve's Y = 1 maps to.
@export var output_max: float = 100.0:
	set(v):
		output_max = v
		emit_changed()

var out_max: float:
	get: return output_max
	set(v): output_max = v

## Cross-fade between the input (0) and the remapped field (1).
@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		emit_changed()

@export_tool_button("Auto Fit Range") var _auto_btn = auto_fit_range


func auto_fit_range(p_min: float = 0.0, p_max: float = 100.0) -> void:
	input_min = p_min
	input_max = p_max
	emit_changed()


func op() -> StringName:
	return &"curve"


func role() -> Role:
	return Role.FILTER


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["field"])


func eval_cell(_p_wx: float, _p_wz: float, p_inputs: PackedFloat32Array) -> float:
	var x := p_inputs[0] if p_inputs.size() > 0 else 0.0
	if curve == null or is_nan(x):
		return x
	var span := input_max - input_min
	var tx := clampf((x - input_min) / span, 0.0, 1.0) if absf(span) > 1.0e-9 else 0.0
	var y := curve.sample_baked(tx)
	var remapped := lerpf(output_min, output_max, y)
	return lerpf(x, remapped, amount)


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if curve == null:
		w.append("%s: no Curve assigned, so it passes the input through unchanged." % display_name())
	elif is_zero_approx(amount):
		w.append("%s: Amount is 0, so it passes the input through unchanged." % display_name())
	elif absf(input_max - input_min) <= 1.0e-9:
		w.append("%s: the input window is empty (min == max) — every value maps to curve X = 0." % display_name())
	return w
