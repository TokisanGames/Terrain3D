# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevTransform — pure GDScript reference oracle for the Transform affine resample.
# PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md §4.1, deliverable 3.
#
# This node exists because an inverse affine plus a bilinear tap is exactly where a half-texel offset
# hides: it produces a result that looks right at a glance and is wrong by half a cell everywhere, which
# only shows up as a seam when two transformed regions meet. The gate holds the C++ kernel to this.
@tool
class_name Pasture3DGraphNodeDevTransform
extends Pasture3DGraphNode

enum EdgeMode { CLAMP, ZERO, WRAP }

@export var offset: Vector2 = Vector2.ZERO:
	set(v):
		offset = v
		emit_changed()

@export_range(-180.0, 180.0, 0.1) var rotation_deg: float = 0.0:
	set(v):
		rotation_deg = v
		emit_changed()

@export_range(0.01, 10.0, 0.01, "or_greater") var scale: float = 1.0:
	set(v):
		scale = maxf(v, 0.001)
		emit_changed()

@export var pivot: Vector2 = Vector2.ZERO:
	set(v):
		pivot = v
		emit_changed()

@export var edge_mode: EdgeMode = EdgeMode.CLAMP:
	set(v):
		edge_mode = v
		emit_changed()

@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		emit_changed()


func op() -> StringName:
	return &"dev_transform"


func role() -> Role:
	return Role.FILTER


func display_name() -> String:
	return "[Dev/GD] Transform"


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["in"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT])


func input_unwired_default(_p_port: int) -> float:
	return 0.0


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var in_grid: PackedFloat32Array
	if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and (p_inputs[0] as PackedFloat32Array).size() == n:
		in_grid = p_inputs[0]
	else:
		return Pasture3DGraphOps.zeros(n)

	if is_zero_approx(amount) or (offset == Vector2.ZERO and is_zero_approx(rotation_deg) and is_equal_approx(scale, 1.0)):
		return in_grid.duplicate()

	return _eval_grid_gdscript(in_grid, p_gw, p_gh, p_rect)


## Bilinear read of `g` at FRACTIONAL cell coordinates, honouring the edge mode. Fractional, not integer:
## the caller has already converted world metres to cell space, and rounding here is what would introduce
## the half-texel error this oracle exists to catch.
func _sample(g: PackedFloat32Array, p_fx: float, p_fz: float, p_gw: int, p_gh: int) -> float:
	var x0 := int(floor(p_fx))
	var z0 := int(floor(p_fz))
	var tx := p_fx - float(x0)
	var tz := p_fz - float(z0)

	var acc := 0.0
	var wsum := 0.0
	for k in 4:
		var sx := x0 + (k & 1)
		var sz := z0 + (k >> 1)
		var wx := (tx if (k & 1) == 1 else 1.0 - tx)
		var wz := (tz if (k >> 1) == 1 else 1.0 - tz)
		var w := wx * wz
		if w <= 0.0:
			continue

		match edge_mode:
			EdgeMode.CLAMP:
				sx = clampi(sx, 0, p_gw - 1)
				sz = clampi(sz, 0, p_gh - 1)
			EdgeMode.WRAP:
				sx = posmod(sx, p_gw)
				sz = posmod(sz, p_gh)
			EdgeMode.ZERO:
				if sx < 0 or sx >= p_gw or sz < 0 or sz >= p_gh:
					# A defined 0 contributes nothing but still consumes its weight, so the edge fades
					# out rather than being renormalised back to full amplitude.
					wsum += w
					continue

		var v := g[sz * p_gw + sx]
		if is_nan(v):
			# NaN is the brush-loop mask (spec §3.4): it must not be averaged into a finite neighbour.
			# Dropping its weight entirely keeps the finite part of the tap correctly normalised.
			continue
		acc += w * v
		wsum += w

	if wsum <= 0.0:
		return 0.0
	return acc / wsum


func _eval_grid_gdscript(in_grid: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var out := PackedFloat32Array()
	out.resize(n)

	# Cell size and origin, matching Pasture3DTerrainGraph.cell_to_world exactly (dx divides by gw, NOT
	# gw-1, and the sample sits at the cell CENTRE). A disagreement here reads as an evaluator bug.
	var dx := p_rect.size.x / float(maxi(p_gw, 1))
	var dz := p_rect.size.y / float(maxi(p_gh, 1))
	var ox := p_rect.position.x
	var oz := p_rect.position.y

	# Inverse affine. Forward is T(pivot) R S T(-pivot) T(offset); the inverse undoes offset first, then
	# un-pivots, un-rotates and un-scales.
	var rad := deg_to_rad(rotation_deg)
	var cs := cos(-rad)
	var sn := sin(-rad)
	var inv_s := 1.0 / maxf(scale, 0.001)

	for iz in p_gh:
		for ix in p_gw:
			var i := iz * p_gw + ix
			var v_in := in_grid[i]
			if is_nan(v_in):
				out[i] = NAN
				continue

			var wx := ox + (float(ix) + 0.5) * dx
			var wz := oz + (float(iz) + 0.5) * dz

			var px := wx - offset.x - pivot.x
			var pz := wz - offset.y - pivot.y
			var rx := (px * cs - pz * sn) * inv_s + pivot.x
			var rz := (px * sn + pz * cs) * inv_s + pivot.y

			var fx := (rx - ox) / dx - 0.5
			var fz := (rz - oz) / dz - 0.5

			out[i] = lerpf(v_in, _sample(in_grid, fx, fz, p_gw, p_gh), amount)

	return out
