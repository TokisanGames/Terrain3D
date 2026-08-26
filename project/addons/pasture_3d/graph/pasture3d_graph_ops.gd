# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphOps — stateless grid helpers shared by the terrain-graph grid nodes. Static only; it
# holds no data and is never instanced. The point is a SINGLE definition of an operation that more than
# one node (and, later, the C++/GPU backend) must agree on bit-for-bit.
@tool
class_name Pasture3DGraphOps
extends RefCounted


## A separable, NaN-aware box blur — 0.5 centre, 0.25 each neighbour, renormalised at the edges and
## across holes so a NaN neighbour drops out of the average instead of poisoning it. NaN is preserved
## where the input is NaN (a hole stays a hole).
##
## This MIRRORS `Pasture3DTerrainBrush._blur_grid` byte-for-byte on purpose: the graph's Smooth node and
## the stack's Smooth op must produce the same surface, so that when the stack folds into the graph the
## two paths are provably one. Consolidate to a single caller when that fold lands (see
## PASTURE3D_TERRAIN_GRAPH_SPEC.md, "cell-node fold").
##
## Mutates and returns `p_vals` (row-major, `p_gw * p_gh`). `passes <= 0` is the identity.
static func blur_nan(p_vals: PackedFloat32Array, p_gw: int, p_gh: int, p_passes: int) -> PackedFloat32Array:
	if p_passes <= 0:
		return p_vals
	var tmp := PackedFloat32Array()
	tmp.resize(p_gw * p_gh)
	for _pass in range(p_passes):
		# Horizontal: p_vals -> tmp
		for iz in range(p_gh):
			var row := iz * p_gw
			for ix in range(p_gw):
				var v: float = p_vals[row + ix]
				if not is_finite(v):
					tmp[row + ix] = NAN
					continue
				var s := 0.5 * v
				var wt := 0.5
				if ix > 0 and is_finite(p_vals[row + ix - 1]): s += 0.25 * p_vals[row + ix - 1]; wt += 0.25
				if ix < p_gw - 1 and is_finite(p_vals[row + ix + 1]): s += 0.25 * p_vals[row + ix + 1]; wt += 0.25
				tmp[row + ix] = s / wt
		# Vertical: tmp -> p_vals
		for iz in range(p_gh):
			var row := iz * p_gw
			for ix in range(p_gw):
				var v: float = tmp[row + ix]
				if not is_finite(v):
					p_vals[row + ix] = NAN
					continue
				var s := 0.5 * v
				var wt := 0.5
				if iz > 0 and is_finite(tmp[(iz - 1) * p_gw + ix]): s += 0.25 * tmp[(iz - 1) * p_gw + ix]; wt += 0.25
				if iz < p_gh - 1 and is_finite(tmp[(iz + 1) * p_gw + ix]): s += 0.25 * tmp[(iz + 1) * p_gw + ix]; wt += 0.25
				p_vals[row + ix] = s / wt
	return p_vals


## A zero-filled grid of `p_n` cells — the defined value of an unconnected input port, so a missing wire
## reads a clean 0 everywhere rather than erroring or reading stale memory.
static func zeros(p_n: int) -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(p_n)
	return g
