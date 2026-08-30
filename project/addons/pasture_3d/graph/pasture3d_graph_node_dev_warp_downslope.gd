# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevWarpDownslope — the GDScript oracle twin for WarpDownslope (spec §7.1).
#
# Deliberately slow and literal. It reuses the Phase 3 oracle's box_mean rather than blurring its own way:
# the gradient direction is only as trustworthy as the blur it is read from, and two blurs would be two
# definitions of "radius".
@tool
class_name Pasture3DGraphNodeDevWarpDownslope
extends Pasture3DGraphNode

## Matches GRADIENT_EPSILON in src/pasture_3d_warp_downslope.cpp and the 1.0e-4 in the mode-17 shader.
const GRADIENT_EPSILON := 1.0e-4

@export var displacement: float = 20.0
@export var radius: float = 20.0
@export var reverse: bool = false
@export_range(0.0, 1.0, 0.01) var amount: float = 1.0


func op() -> StringName:
	return &"dev_warp_downslope"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["in"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT])


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	if p_inputs.is_empty() or not (p_inputs[0] is PackedFloat32Array) or p_inputs[0].size() != n:
		return Pasture3DGraphOps.zeros(n)
	return solve(p_inputs[0], p_gw, p_gh, p_rect)


func solve(p_in: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	if is_zero_approx(amount) or is_zero_approx(displacement):
		return p_in.duplicate()

	var blur := Pasture3DGraphNodeDevTerrainMetrics.new()
	var sm: PackedFloat32Array = blur.box_mean(p_in, p_gw, p_gh, p_rect, radius) if radius > 0.0 else p_in

	var dx := p_rect.size.x / float(p_gw)
	var dz := p_rect.size.y / float(p_gh)
	# Sample UPHILL so the SURFACE moves downhill: a resample is a backward map, out(x) = in(x + d)
	# shifts the pattern by -d. The same sign as `sign` in warp_downslope_solve.
	var sign := -1.0 if reverse else 1.0

	var out := PackedFloat32Array()
	out.resize(n)
	for iz in p_gh:
		for ix in p_gw:
			var i := iz * p_gw + ix
			var z := p_in[i]
			if is_nan(z):
				out[i] = NAN
				continue
			var xm := maxi(ix - 1, 0)
			var xp := mini(ix + 1, p_gw - 1)
			var zm := maxi(iz - 1, 0)
			var zp := mini(iz + 1, p_gh - 1)
			var sxm := sm[iz * p_gw + xm]
			var sxp := sm[iz * p_gw + xp]
			var szm := sm[zm * p_gw + ix]
			var szp := sm[zp * p_gw + ix]
			if is_nan(sxm) or is_nan(sxp) or is_nan(szm) or is_nan(szp):
				out[i] = z
				continue
			var gx := (sxp - sxm) / (float(xp - xm) * dx)
			var gz := (szp - szm) / (float(zp - zm) * dz)
			var mag := sqrt(gx * gx + gz * gz)
			if mag <= GRADIENT_EPSILON:
				out[i] = z
				continue
			var step := displacement * amount * sign
			var fx := float(ix) + (gx / mag) * step / dx
			var fz := float(iz) + (gz / mag) * step / dz
			out[i] = _sample(p_in, fx, fz, p_gw, p_gh)
	return out


## Bilinear, CLAMP edges, NaN taps DROPPED rather than averaged — the same rule as
## transform_sample_bilinear, because letting a NaN bleed into a finite neighbour pulls a seam along
## every brush-loop rim.
func _sample(p_g: PackedFloat32Array, p_fx: float, p_fz: float, p_gw: int, p_gh: int) -> float:
	var x0 := int(floor(p_fx))
	var z0 := int(floor(p_fz))
	var tx := p_fx - float(x0)
	var tz := p_fz - float(z0)
	var acc := 0.0
	var wsum := 0.0
	for k in range(4):
		var sx := clampi(x0 + (k & 1), 0, p_gw - 1)
		var sz := clampi(z0 + (k >> 1), 0, p_gh - 1)
		var wx := tx if (k & 1) == 1 else (1.0 - tx)
		var wz := tz if (k >> 1) == 1 else (1.0 - tz)
		var w := wx * wz
		if w <= 0.0:
			continue
		var v := p_g[sz * p_gw + sx]
		if is_nan(v):
			continue
		acc += w * v
		wsum += w
	return 0.0 if wsum <= 0.0 else float(acc / wsum)
