# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevDistanceTransform — the GDScript oracle twin of DistanceTransform.
#
# It runs JUMP FLOODING, not an exact transform, and that is the point. An exact oracle would disagree
# with the native kernel wherever JFA is approximate, and the parity criterion would then be measuring
# the algorithm's error instead of the port's. Exactness is checked separately, by the gate's DF
# criterion, against a brute-force field computed there.
#
# So this file is the readable statement of the contract: same seeding, same pass schedule, same metric
# in metres. Anything that changes in the C++ has to change here too, or DD will say so.
@tool
class_name Pasture3DGraphNodeDevDistanceTransform
extends Pasture3DGraphNode

@export_range(0.0, 1.0, 0.01) var threshold: float = 0.5
@export var direction: int = 0 ## Matches Pasture3DGraphNodeDistanceTransform.Direction.
@export var metric: int = 0 ## Matches Pasture3DGraphNodeDistanceTransform.Metric.
@export var output_units: int = 0 ## Matches Pasture3DGraphNodeDistanceTransform.OutputUnits.
@export var max_distance: float = 0.0

var last_normalisation_divisor: float = 1.0


func op() -> StringName:
	return &"dev_distance_transform"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["in"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.MASK])


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

	# NaN is neither inside nor outside — it is the brush loop mask, and seeding it either way would
	# invent a boundary through a region the user excluded.
	var inside := PackedByteArray()
	var valid := PackedByteArray()
	inside.resize(n)
	valid.resize(n)
	for i in n:
		var v := p_in[i]
		if is_nan(v):
			valid[i] = 0
			inside[i] = 0
		else:
			valid[i] = 1
			inside[i] = 1 if v > threshold else 0

	var need_out := direction != 1
	var need_in := direction != 0
	var d_out := _field(inside, true, p_gw, p_gh, dx, dz) if need_out else PackedFloat64Array()
	var d_in := _field(inside, false, p_gw, p_gh, dx, dz) if need_in else PackedFloat64Array()

	var dist := PackedFloat64Array()
	dist.resize(n)
	for i in n:
		match direction:
			1: dist[i] = d_in[i] if inside[i] == 1 else 0.0
			2: dist[i] = -d_in[i] if inside[i] == 1 else d_out[i]
			_: dist[i] = 0.0 if inside[i] == 1 else d_out[i]

	if max_distance > 0.0:
		for i in n:
			dist[i] = clampf(dist[i], -max_distance, max_distance)

	var divisor := 1.0
	if output_units == 1:
		if max_distance > 0.0:
			divisor = max_distance
		else:
			var hi := 0.0
			for i in n:
				hi = maxf(hi, absf(dist[i]))
			divisor = hi if hi > 1e-12 else 1.0
		for i in n:
			dist[i] /= divisor
	last_normalisation_divisor = divisor

	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = float(dist[i]) if valid[i] == 1 else NAN
	return out


func _metric_distance(p_ix: int, p_iz: int, p_sx: int, p_sz: int, p_dx: float, p_dz: float) -> float:
	var ax := absf(float(p_ix - p_sx)) * p_dx
	var az := absf(float(p_iz - p_sz)) * p_dz
	match metric:
		1: return ax + az
		2: return maxf(ax, az)
		_: return sqrt(ax * ax + az * az)


## Distance to the nearest cell whose inside-flag equals `p_want`, by jump flooding.
func _field(p_inside: PackedByteArray, p_want: bool, p_gw: int, p_gh: int, p_dx: float,
		p_dz: float) -> PackedFloat64Array:
	var n := p_gw * p_gh
	# Seed sites, as flat cell indices. -1 is "nothing adopted yet", i.e. infinitely far.
	var site := PackedInt32Array()
	site.resize(n)
	var want_byte := 1 if p_want else 0
	for i in n:
		site[i] = i if p_inside[i] == want_byte else -1

	var max_step := 1
	while max_step < maxi(p_gw, p_gh):
		max_step <<= 1

	var steps: PackedInt32Array = PackedInt32Array()
	var k := max_step / 2
	while k >= 1:
		steps.append(k)
		k >>= 1
	steps.append(1) # JFA+1 — the repair pass, and the C++ does the same.

	for step in steps:
		var next := site.duplicate()
		for iz in p_gh:
			for ix in p_gw:
				var i := iz * p_gw + ix
				var best := site[i]
				var best_d := INF
				if best >= 0:
					best_d = _metric_distance(ix, iz, best % p_gw, best / p_gw, p_dx, p_dz)
				for oz in range(-1, 2):
					for ox in range(-1, 2):
						if ox == 0 and oz == 0:
							continue
						var nx := ix + ox * step
						var nz := iz + oz * step
						if nx < 0 or nx >= p_gw or nz < 0 or nz >= p_gh:
							continue
						var cand := site[nz * p_gw + nx]
						if cand < 0:
							continue
						var d := _metric_distance(ix, iz, cand % p_gw, cand / p_gw, p_dx, p_dz)
						if d < best_d:
							best_d = d
							best = cand
				next[i] = best
		site = next

	# No seed anywhere: report the field diagonal rather than 0, which would read as "every cell is on
	# the boundary" — the opposite of the truth.
	var fallback := sqrt(pow(p_gw * p_dx, 2.0) + pow(p_gh * p_dz, 2.0))
	var out := PackedFloat64Array()
	out.resize(n)
	for iz in p_gh:
		for ix in p_gw:
			var i := iz * p_gw + ix
			var s := site[i]
			out[i] = fallback if s < 0 else _metric_distance(ix, iz, s % p_gw, s / p_gw, p_dx, p_dz)
	return out
