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
#
# WHERE THE WINDOW COMES FROM is the author's choice (spec §11 q1, settled 2026-08-30). By default the
# node AUTO-WINDOWS to the input's own min/max for that bake, which needs nothing authored. The cost is
# that the output becomes content-dependent: two masked brush regions that see different extremes
# normalise differently and can disagree along the seam where they meet. Ticking Explicit Window pins the
# window to metres and makes the node a pure function of its input again, which is the cure for a seam.
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
## Off (the default): the window is the input's own min/max for this bake — nothing to author, but the
## result depends on the content, so two brush regions can disagree at a shared edge. On: Range Min /
## Range Max below are used verbatim, in metres, and the node is a pure function of its input.
@export var explicit_window: bool = false:
	set(v):
		explicit_window = v
		emit_changed()

## Bottom of the height range the curve acts on, in metres. Ignored unless Explicit Window is on.
## Input below this passes through unchanged.
@export var range_min: float = 0.0:
	set(v):
		range_min = v
		emit_changed()

## Top of the height range the curve acts on, in metres. Ignored unless Explicit Window is on.
## Input above this passes through unchanged.
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


## Auto-windowing needs the input's extremes, which a single cell cannot see. The node evaluates whole
## grids in both modes rather than only when auto, so there is one code path and not two that can drift.
func needs_grid() -> bool:
	return true


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


## One cell, given a window that has already been resolved. Both evaluators go through here.
func shape_value(p_in: float, p_amount: float, p_lo: float, p_hi: float, p_mask: float) -> float:
	if is_nan(p_in):
		return NAN
	var span: float = p_hi - p_lo
	if span <= 0.0:
		# A degenerate window has no defined normalisation. Pass through rather than invent one.
		return p_in
	# Outside the window there is nothing to shape, and clamping into it would flatten the peaks.
	if p_in <= p_lo or p_in >= p_hi:
		return p_in
	var t: float = (p_in - p_lo) / span
	var shaped: float = p_lo + curve_value(t, maxf(p_amount, 0.001)) * span
	return lerpf(p_in, shaped, clampf(p_mask * mask_amount, 0.0, 1.0))


## The window this bake will use: the authored metres, or the input's own finite extremes. Returned as a
## pair so a gate can assert what was chosen rather than infer it from the shaped output.
func resolve_window(p_in: PackedFloat32Array) -> Vector2:
	if explicit_window:
		return Vector2(range_min, range_max)
	var lo := INF
	var hi := -INF
	for v in p_in:
		if is_finite(v):
			lo = minf(lo, v)
			hi = maxf(hi, v)
	if not is_finite(lo) or not is_finite(hi):
		return Vector2(0.0, 0.0) # nothing finite to measure; shape_value passes through on span <= 0
	return Vector2(lo, hi)


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, _p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var h: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	var amt: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else amount
	var has_mask: bool = p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() == n
	var msk: PackedFloat32Array = p_inputs[2] if has_mask else PackedFloat32Array()
	var win := resolve_window(h)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in range(n):
		var m: float = 1.0
		if has_mask and is_finite(msk[i]):
			m = msk[i]
		out[i] = shape_value(h[i], amt, win.x, win.y, m)
	return out


func eval_cell(_p_wx: float, _p_wz: float, p_inputs: PackedFloat32Array) -> float:
	var base_in: float = p_inputs[0] if (p_inputs.size() > 0) else 0.0
	var amt: float = p_inputs[1] if (p_inputs.size() > 1 and not is_nan(p_inputs[1])) else amount
	var msk: float = p_inputs[2] if (p_inputs.size() > 2 and not is_nan(p_inputs[2])) else 1.0
	# A single cell has no extremes to auto-window against, so this path can only honour the authored
	# window. `needs_grid()` is true precisely so nothing routes an auto-windowed node through here.
	return shape_value(base_in, amt, range_min, range_max, msk)


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if explicit_window and range_max <= range_min:
		w.append("%s: Height Window is empty (Range Max <= Range Min), so it passes the input through unchanged." % display_name())
	elif is_equal_approx(amount, 1.0):
		w.append("%s: Amount is 1.0, which is the identity curve in both modes." % display_name())
	elif is_zero_approx(mask_amount):
		w.append("%s: Mask Amount is 0, so it passes the input through unchanged." % display_name())
	return w
