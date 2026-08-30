# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeContrast — a FILTER cell node: pointwise gain / gamma shaping of elevation.
# PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md §4.3. Fuses Hesiod's Gain and GammaCorrection, which are the
# same one-line curve on a normalised value.
#
# THE HEIGHT WINDOW IS NOT OPTIONAL POLISH. Hesiod operates on [0,1] heightmaps, so it applies pow() to a
# raw array value. Pasture3D heights are METRES: pow() on a metre value is meaningless, and terrain below
# sea level is negative, where pow() with a fractional exponent returns NaN. So the window maps
# [range_min, range_max] to [0,1], the curve runs there, and the result maps back to metres. Heights
# outside the window pass through untouched rather than being clamped into it — clamping would flatten
# every peak above the window into a plateau (spec §3.6).
@tool
class_name Pasture3DGraphNodeContrast
extends Pasture3DGraphNode

## GAIN pushes values away from the window's midpoint (S-curve, more contrast) or toward it. GAMMA is the
## classic power curve: it biases the whole window up or down without pinning the midpoint.
enum Mode { GAIN, GAMMA }

## Which pointwise curve to apply.
@export var mode: Mode = Mode.GAIN:
	set(v):
		mode = v
		emit_changed()

## The curve's strength. 1.0 is the identity in BOTH modes. Above 1 GAIN steepens the S and GAMMA darkens
## (pulls terrain down); below 1 GAIN flattens and GAMMA lifts.
@export_range(0.01, 8.0, 0.01, "or_greater") var amount: float = 1.0:
	set(v):
		amount = maxf(v, 0.001)
		emit_changed()

@export_group("Height Window")
## Bottom of the height range the curve acts on, in metres. Input below this passes through unchanged.
@export var range_min: float = 0.0:
	set(v):
		range_min = v
		emit_changed()

## Top of the height range the curve acts on, in metres. Input above this passes through unchanged.
@export var range_max: float = 100.0:
	set(v):
		range_max = v
		emit_changed()

@export_group("Masking")
## Cross-fade between the untouched input (0.0) and the fully shaped result (1.0), multiplied by the
## `mask` port when one is wired.
@export_range(0.0, 1.0, 0.01) var mask_amount: float = 1.0:
	set(v):
		mask_amount = clampf(v, 0.0, 1.0)
		emit_changed()


func op() -> StringName:
	return &"contrast"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return false


func input_count() -> int:
	return 3


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "amount", "mask"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.HEIGHT,
		PortType.FLOAT,
		PortType.MASK,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return amount
		2: return 1.0
		_: return 0.0


## The curve on a normalised [0,1] value. Split out so the gate can assert the curve itself rather than
## inferring it through the window arithmetic.
func curve_value(p_t: float, p_amount: float) -> float:
	var t: float = clampf(p_t, 0.0, 1.0)
	if mode == Mode.GAMMA:
		return pow(t, p_amount)
	# Schlick gain: symmetric about 0.5, so the window's midpoint is a fixed point.
	if t < 0.5:
		return 0.5 * pow(2.0 * t, p_amount)
	return 1.0 - 0.5 * pow(2.0 - 2.0 * t, p_amount)


func eval_cell(_p_wx: float, _p_wz: float, p_inputs: PackedFloat32Array) -> float:
	var base_in: float = p_inputs[0] if (p_inputs.size() > 0) else 0.0
	if is_nan(base_in):
		return NAN

	var amt: float = p_inputs[1] if (p_inputs.size() > 1 and not is_nan(p_inputs[1])) else amount
	var msk: float = p_inputs[2] if (p_inputs.size() > 2 and not is_nan(p_inputs[2])) else 1.0

	var span: float = range_max - range_min
	if span <= 0.0:
		# A degenerate window has no defined normalisation. Pass through rather than invent one.
		return base_in

	# Outside the window there is nothing to shape, and clamping into it would flatten the peaks.
	if base_in <= range_min or base_in >= range_max:
		return base_in

	var t: float = (base_in - range_min) / span
	var shaped: float = range_min + curve_value(t, maxf(amt, 0.001)) * span
	return lerpf(base_in, shaped, clampf(msk * mask_amount, 0.0, 1.0))


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if range_max <= range_min:
		w.append("%s: Height Window is empty (Range Max <= Range Min), so it passes the input through unchanged." % display_name())
	elif is_equal_approx(amount, 1.0):
		w.append("%s: Amount is 1.0, which is the identity curve in both modes." % display_name())
	elif is_zero_approx(mask_amount):
		w.append("%s: Mask Amount is 0, so it passes the input through unchanged." % display_name())
	return w
