# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevExpandShrink — the GDScript oracle twin of ExpandShrink.
#
# Deliberately the naive O(r²) gather: for every cell, walk every offset in the structuring element and
# take the min or max. That is the definition of the operation written out longhand, which is exactly
# what the native kernel's deque-based running extremum needs checking against — the fast version is only
# trustworthy because a slow, obviously-correct one says it agrees.
#
# Keep it slow. Optimising this file would delete the reason it exists.
@tool
class_name Pasture3DGraphNodeDevExpandShrink
extends Pasture3DGraphNode

@export var mode: int = 0 ## Matches Pasture3DGraphNodeExpandShrink.Mode.
@export var radius: float = 5.0 ## Metres.
@export var kernel: int = 0 ## Matches Pasture3DGraphNodeExpandShrink.Kernel.
@export_range(1, 16, 1) var iterations: int = 1
@export_range(0.0, 1.0, 0.01) var amount: float = 1.0


func op() -> StringName:
	return &"dev_expand_shrink"


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


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	if p_inputs.is_empty() or not (p_inputs[0] is PackedFloat32Array) or p_inputs[0].size() != n:
		return Pasture3DGraphOps.zeros(n)
	return solve(p_inputs[0], p_gw, p_gh, p_rect)


## The whole oracle, callable directly from a gate without building a graph.
func solve(p_in: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var dx := p_rect.size.x / float(p_gw)
	var dz := p_rect.size.y / float(p_gh)
	# Metres to cells, rounded to NEAREST. Truncating would bias every radius downward by up to a cell,
	# which shows up as a systematic failure of the metric-invariance criterion rather than as rounding.
	var wx := int(round(radius / dx)) if dx > 0.0 else 0
	var wz := int(round(radius / dz)) if dz > 0.0 else 0

	if amount <= 0.0 or iterations <= 0 or (wx <= 0 and wz <= 0):
		return p_in.duplicate()

	var offsets := _offsets(wx, wz)

	var cur := p_in.duplicate()
	for _it in iterations:
		cur = _apply_mode(cur, p_gw, p_gh, offsets)

	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var v_in := p_in[i]
		if is_nan(v_in):
			out[i] = NAN
			continue
		var v_out := cur[i]
		if is_nan(v_out):
			out[i] = v_in
			continue
		out[i] = v_in + (v_out - v_in) * amount
	return out


## The structuring element as a list of (dx, dz) cell offsets. The disc is elliptical in cells whenever
## the world cells are not square, which is what keeps the SHAPE circular in metres.
func _offsets(p_wx: int, p_wz: int) -> Array:
	var out: Array = []
	for oz in range(-p_wz, p_wz + 1):
		for ox in range(-p_wx, p_wx + 1):
			if kernel == 1: # SQUARE
				out.append(Vector2i(ox, oz))
				continue
			var fx := float(ox) / float(maxi(p_wx, 1))
			var fz := float(oz) / float(maxi(p_wz, 1))
			if fx * fx + fz * fz <= 1.0:
				out.append(Vector2i(ox, oz))
	return out


func _apply_mode(p_g: PackedFloat32Array, p_gw: int, p_gh: int, p_offsets: Array) -> PackedFloat32Array:
	match mode:
		1: return _extremum(p_g, p_gw, p_gh, p_offsets, false)
		2: return _extremum(_extremum(p_g, p_gw, p_gh, p_offsets, false), p_gw, p_gh, p_offsets, true)
		3: return _extremum(_extremum(p_g, p_gw, p_gh, p_offsets, true), p_gw, p_gh, p_offsets, false)
		4:
			var hi := _extremum(p_g, p_gw, p_gh, p_offsets, true)
			var lo := _extremum(p_g, p_gw, p_gh, p_offsets, false)
			var out := PackedFloat32Array()
			out.resize(p_g.size())
			for i in p_g.size():
				out[i] = hi[i] - lo[i]
			return out
		_: return _extremum(p_g, p_gw, p_gh, p_offsets, true)


func _extremum(p_g: PackedFloat32Array, p_gw: int, p_gh: int, p_offsets: Array,
		p_is_max: bool) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_g.size())
	for iz in p_gh:
		for ix in p_gw:
			var best := NAN
			for o in p_offsets:
				var nx: int = ix + o.x
				var nz: int = iz + o.y
				if nx < 0 or nx >= p_gw or nz < 0 or nz >= p_gh:
					continue
				var v := p_g[nz * p_gw + nx]
				# NaN is SKIPPED, never folded in. Under a max a NaN-as-minus-infinity is invisible;
				# under a min a NaN-as-plus-infinity swallows the window. Both are wrong.
				if is_nan(v):
					continue
				if is_nan(best) or (v > best if p_is_max else v < best):
					best = v
			out[iz * p_gw + ix] = best
	return out
