# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeSpectralEqualizer — a FILTER grid node: 3-band spatial frequency equalizer.
#
# Decomposes input terrain into Macro (low-frequency base relief), Meso (mid-frequency ridges/hills),
# and Micro (high-frequency crags/surface roughness) spatial bands using multi-scale separable Gaussian
# blurs, allowing independent gain adjustment for each band.
#
# When all three gains equal 1.0, this is the exact mathematical identity across the grid.
@tool
class_name Pasture3DGraphNodeSpectralEqualizer
extends Pasture3DGraphNode

## Gain multiplier for broad mountain massifs and low-frequency terrain contours.
@export_range(0.0, 4.0, 0.05) var macro_gain: float = 1.0:
	set(v):
		macro_gain = maxf(v, 0.0)
		emit_changed()

## Gain multiplier for intermediate hills, ridges, and valleys.
@export_range(0.0, 4.0, 0.05) var meso_gain: float = 1.0:
	set(v):
		meso_gain = maxf(v, 0.0)
		emit_changed()

## Gain multiplier for fine surface crags, rocky textures, and high-frequency ripples.
@export_range(0.0, 4.0, 0.05) var micro_gain: float = 1.5:
	set(v):
		micro_gain = maxf(v, 0.0)
		emit_changed()

@export_group("Filter Passes")
## Blur passes defining the boundary of the macro/meso frequency transition.
@export_range(4, 64, 2) var macro_passes: int = 16:
	set(v):
		macro_passes = maxi(v, 1)
		emit_changed()

## Blur passes defining the boundary of the meso/micro frequency transition.
@export_range(1, 16, 1) var meso_passes: int = 4:
	set(v):
		meso_passes = maxi(v, 1)
		emit_changed()

## Cross-fade between original input (0.0) and equalized terrain (1.0).
@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		emit_changed()


func op() -> StringName:
	return &"spectral_equalizer"


func role() -> Role:
	return Role.FILTER


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


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, _p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var in_grid: PackedFloat32Array
	if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and (p_inputs[0] as PackedFloat32Array).size() == n:
		in_grid = p_inputs[0]
	else:
		return Pasture3DGraphOps.zeros(n)

	if is_zero_approx(amount):
		return in_grid.duplicate()

	# Exact identity optimization when all gains are 1.0
	if is_equal_approx(macro_gain, 1.0) and is_equal_approx(meso_gain, 1.0) and is_equal_approx(micro_gain, 1.0):
		return in_grid.duplicate()

	var mask: PackedFloat32Array
	if p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and (p_inputs[1] as PackedFloat32Array).size() == n:
		mask = p_inputs[1]
	else:
		mask = Pasture3DGraphOps.filled(n, 1.0)

	if ClassDB.class_has_method("Pasture3DUtil", "spectral_equalizer_grid"):
		var res: PackedFloat32Array = Pasture3DUtil.spectral_equalizer_grid(in_grid, mask, p_gw, p_gh,
				macro_gain, meso_gain, micro_gain, macro_passes, meso_passes, amount)
		if res.size() == n:
			return res

	return _eval_grid_gdscript(in_grid, mask, p_gw, p_gh)


func _eval_grid_gdscript(in_grid: PackedFloat32Array, mask: PackedFloat32Array, p_gw: int, p_gh: int) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var p_meso := mini(meso_passes, macro_passes)
	var p_macro := maxi(macro_passes, meso_passes)

	# Multi-scale decomposition
	var l_meso := Pasture3DGraphOps.blur_nan(in_grid.duplicate(), p_gw, p_gh, p_meso)
	var l_macro := Pasture3DGraphOps.blur_nan(l_meso.duplicate(), p_gw, p_gh, p_macro - p_meso)

	var out_grid := PackedFloat32Array()
	out_grid.resize(n)

	for i in range(n):
		var h_orig := in_grid[i]
		if not is_finite(h_orig):
			out_grid[i] = NAN
			continue

		var macro_val := l_macro[i]
		var meso_band := l_meso[i] - macro_val
		var micro_band := h_orig - l_meso[i]

		var h_eq := macro_gain * macro_val + meso_gain * meso_band + micro_gain * micro_band
		var m := clampf(mask[i], 0.0, 1.0)
		out_grid[i] = lerpf(h_orig, h_eq, amount * m)

	return out_grid


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(amount):
		w.append("%s: Amount is 0, so it passes the input through unchanged." % display_name())
	elif meso_passes >= macro_passes:
		w.append("%s: Meso passes (%d) should be less than macro passes (%d) for proper band separation." % [display_name(), meso_passes, macro_passes])
	return w
