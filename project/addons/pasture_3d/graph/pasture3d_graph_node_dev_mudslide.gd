# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevMudslide — the GDScript oracle twin for Mudslide (spec §8.3).
#
# Deliberately slow and literal, and DELTA-ACCUMULATED like the kernel: every sweep fills a delta buffer for
# every cell and applies it in a second pass. Writing the oracle as an in-place scatter would have been
# shorter and would have made it a different algorithm — an order-dependent one — so the two would disagree
# for a reason that has nothing to do with a bug in either.
@tool
class_name Pasture3DGraphNodeDevMudslide
extends Pasture3DGraphNode

## Matches MAX_SWEEPS in src/pasture_3d_mudslide.cpp.
const MAX_SWEEPS := 4096

## Matches TRANSPORT_GAIN in src/pasture_3d_mudslide.cpp and the f5 factor in the mode-21/22 shader. The
## per-sweep fraction is derived from it and the cell size; see that file for why a constant per-sweep
## fraction is not resolution-invariant.
const TRANSPORT_GAIN := 0.25

@export var talus_angle_deg: float = 30.0
@export var depth: float = 4.0
@export var travel_distance: float = 60.0
@export var depth_exponent: float = 1.0
@export var viscosity_power: float = 1.0
@export_range(0.0, 1.0, 0.01) var amount: float = 1.0


func op() -> StringName:
	return &"dev_mudslide"


func role() -> Role:
	return Role.SOLVER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 2


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "mask"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK])


func output_count() -> int:
	return 2


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "deposition"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK])


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	if p_inputs.is_empty() or not (p_inputs[0] is PackedFloat32Array) or p_inputs[0].size() != n:
		return Pasture3DGraphOps.zeros(n)
	var mask := PackedFloat32Array()
	if p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() == n:
		mask = p_inputs[1]
	return solve(p_inputs[0], mask, p_gw, p_gh, p_rect)


func solve(p_in: PackedFloat32Array, p_mask: PackedFloat32Array, p_gw: int, p_gh: int,
		p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	if amount <= 0.0 or depth <= 0.0 or travel_distance <= 0.0:
		return p_in.duplicate()

	# gw, not gw-1 — the cell_to_world convention.
	var dx := p_rect.size.x / float(p_gw)
	var dz := p_rect.size.y / float(p_gh)
	var diag := sqrt(dx * dx + dz * dz)
	var cell := minf(dx, dz)
	if cell <= 0.0:
		return p_in.duplicate()

	var sweeps := clampi(int(round(travel_distance / cell)), 1, MAX_SWEEPS)
	var step_fraction := clampf(TRANSPORT_GAIN, 0.0, 0.5)
	var tan_repose := tan(deg_to_rad(clampf(talus_angle_deg, 0.0, 89.0)))

	var off_x := [-1, 1, 0, 0, -1, 1, -1, 1]
	var off_z := [0, 0, -1, 1, -1, -1, 1, 1]
	var off_d := [dx, dx, dz, dz, diag, diag, diag, diag]

	var h := PackedFloat64Array()
	h.resize(n)
	for i in n:
		h[i] = p_in[i]

	# An all-zero mask counts as NO mask — see the note in src/pasture_3d_mudslide.cpp. The graph feeds an
	# unwired port a grid of zeros, so the two cases arrive here identical.
	var have_mask := p_mask.size() == n
	if have_mask:
		var any := false
		for i in n:
			if is_finite(p_mask[i]) and p_mask[i] > 0.0:
				any = true
				break
		have_mask = any
	var mobile := PackedFloat64Array()
	mobile.resize(n)
	for iz in p_gh:
		for ix in p_gw:
			var i := iz * p_gw + ix
			if not is_finite(h[i]):
				continue
			if have_mask:
				var m := p_mask[i]
				mobile[i] = depth * (clampf(m, 0.0, 1.0) if is_finite(m) else 0.0)
				continue
			var xm := maxi(ix - 1, 0)
			var xp := mini(ix + 1, p_gw - 1)
			var zm := maxi(iz - 1, 0)
			var zp := mini(iz + 1, p_gh - 1)
			var hxm := h[iz * p_gw + xm]
			var hxp := h[iz * p_gw + xp]
			var hzm := h[zm * p_gw + ix]
			var hzp := h[zp * p_gw + ix]
			if not (is_finite(hxm) and is_finite(hxp) and is_finite(hzm) and is_finite(hzp)):
				continue
			var gx := (hxp - hxm) / (float(xp - xm) * dx)
			var gz := (hzp - hzm) / (float(zp - zm) * dz)
			if sqrt(gx * gx + gz * gz) > tan_repose:
				mobile[i] = depth

	var dh := PackedFloat64Array()
	var dm := PackedFloat64Array()
	dh.resize(n)
	dm.resize(n)
	var weight := PackedFloat64Array()
	weight.resize(8)
	var drop := PackedFloat64Array()
	drop.resize(8)

	for _sweep in sweeps:
		for i in n:
			dh[i] = 0.0
			dm[i] = 0.0

		for iz in p_gh:
			for ix in p_gw:
				var i := iz * p_gw + ix
				var m := mobile[i]
				if m <= 1e-9 or not is_finite(h[i]):
					continue
				var frac := clampf(pow(clampf(m / depth, 0.0, 1.0), depth_exponent), 0.0, 1.0)
				var budget := m * frac * amount
				if budget <= 1e-12:
					continue

				var wsum := 0.0
				var lower := 0
				for k in 8:
					weight[k] = 0.0
					drop[k] = 0.0
					var nx: int = ix + off_x[k]
					var nz: int = iz + off_z[k]
					if nx < 0 or nx >= p_gw or nz < 0 or nz >= p_gh:
						continue
					var hn := h[nz * p_gw + nx]
					if not is_finite(hn):
						continue # NaN is the brush-loop mask: nothing flows into a hole in the world
					var dist: float = off_d[k]
					var excess := (h[i] - hn) - dist * tan_repose
					if excess <= 0.0:
						continue
					weight[k] = pow(excess / dist, viscosity_power)
					wsum += weight[k]
					drop[k] = h[i] - hn
					lower += 1
				if lower == 0 or wsum <= 0.0:
					continue

				var move_total := budget * step_fraction
				if move_total <= 1e-12:
					continue

				for k in 8:
					if weight[k] <= 0.0:
						continue
					var ni: int = (iz + off_z[k]) * p_gw + (ix + off_x[k])
					# Never more than half the drop: filling a neighbour above this cell would reverse the
					# slope and the material would come straight back on the next sweep.
					var give := minf(move_total * (weight[k] / wsum), 0.5 * drop[k])
					if give <= 0.0:
						continue
					dh[i] -= give
					dh[ni] += give
					dm[i] -= give
					dm[ni] += give

		for i in n:
			if not is_finite(h[i]):
				continue
			h[i] += dh[i]
			mobile[i] = maxf(0.0, mobile[i] + dm[i])

	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = float(h[i]) if is_finite(h[i]) else p_in[i]
	return out
