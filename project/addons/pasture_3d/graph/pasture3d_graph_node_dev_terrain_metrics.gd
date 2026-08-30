# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevTerrainMetrics — the GDScript oracle twin for all three Phase 3 nodes.
#
# One file rather than three because they share the thing most likely to be got wrong: the separable box
# mean, and the conversion of a metre radius into a cell half-width. If those drifted between three
# separate oracles the parity gate would go green while the kernels disagreed about what "50 metres"
# means. Writing the reference once makes that impossible.
#
# Deliberately slow and literal. Optimising this file would delete the reason it exists.
@tool
class_name Pasture3DGraphNodeDevTerrainMetrics
extends Pasture3DGraphNode

enum Which { RELATIVE_ELEVATION, SMOOTH_FILL, RECAST_CLIFF }

@export var which: Which = Which.RELATIVE_ELEVATION

## RelativeElevation.
@export var radius: float = 200.0
@export var output_units: int = 0

## SmoothFill.
@export var mode: int = 0
@export var k: float = 0.1

## RecastCliff.
@export var talus_angle_deg: float = 40.0
@export var amplitude: float = 10.0
@export var gain: float = 2.0
@export var direction_deg: float = -1.0
@export var direction_spread_deg: float = 60.0

@export_range(0.0, 1.0, 0.01) var amount: float = 1.0

## SmoothFill's second channel, filled in by solve(). Normalised, like the native node's.
var last_deposition: PackedFloat32Array = PackedFloat32Array()
var last_deposition_divisor: float = 1.0


func op() -> StringName:
	return &"dev_terrain_metrics"


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
	match which:
		Which.SMOOTH_FILL: return _smooth_fill(p_in, p_gw, p_gh, p_rect)
		Which.RECAST_CLIFF: return _recast_cliff(p_in, p_gw, p_gh, p_rect)
		_: return _relative_elevation(p_in, p_gw, p_gh, p_rect)


## Metres to cells, rounded to NEAREST — the single conversion every Phase 2/3 kernel shares. Truncating
## biases every radius downward by up to a cell and shows up as a systematic failure of the metric
## invariance criteria, not as rounding.
func _cells(p_radius_m: float, p_cell: float) -> int:
	return int(round(p_radius_m / p_cell)) if p_cell > 0.0 else 0


## The separable box mean: two 1D passes of direct gathers, NaN taps skipped rather than counted.
func box_mean(p_g: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2,
		p_radius_m: float) -> PackedFloat32Array:
	var wx := _cells(p_radius_m, p_rect.size.x / float(p_gw))
	var wz := _cells(p_radius_m, p_rect.size.y / float(p_gh))
	if wx <= 0 and wz <= 0:
		return p_g.duplicate()

	var tmp := PackedFloat64Array()
	tmp.resize(p_gw * p_gh)
	for iz in p_gh:
		for ix in p_gw:
			var sum := 0.0
			var count := 0
			for ox in range(-wx, wx + 1):
				var nx := ix + ox
				if nx < 0 or nx >= p_gw:
					continue
				var v := p_g[iz * p_gw + nx]
				if is_nan(v):
					continue
				sum += v
				count += 1
			tmp[iz * p_gw + ix] = (sum / float(count)) if count > 0 else NAN

	var out := PackedFloat32Array()
	out.resize(p_gw * p_gh)
	for iz in p_gh:
		for ix in p_gw:
			var sum := 0.0
			var count := 0
			for oz in range(-wz, wz + 1):
				var nz := iz + oz
				if nz < 0 or nz >= p_gh:
					continue
				var v := tmp[nz * p_gw + ix]
				if is_nan(v):
					continue
				sum += v
				count += 1
			var i := iz * p_gw + ix
			out[i] = float(sum / float(count)) if count > 0 else p_g[i]
	return out


func _relative_elevation(p_in: PackedFloat32Array, p_gw: int, p_gh: int,
		p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	# The SAME disc the morphology oracle walks — reusing it is what makes this node's neighbourhood
	# provably the one the ExpandShrink gate already pinned down.
	var morph := Pasture3DGraphNodeDevExpandShrink.new()
	morph.radius = radius
	morph.kernel = 0
	morph.iterations = 1
	morph.amount = 1.0
	morph.mode = 1 # SHRINK — the local minimum
	var lo := morph.solve(p_in, p_gw, p_gh, p_rect)
	morph.mode = 0 # EXPAND — the local maximum
	var hi := morph.solve(p_in, p_gw, p_gh, p_rect)

	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var z := p_in[i]
		if is_nan(z):
			out[i] = NAN
			continue
		if output_units == 1:
			out[i] = z - lo[i]
			continue
		var span: float = hi[i] - lo[i]
		# A flat neighbourhood is neither basin nor crest; 0.5 is the honest midpoint.
		out[i] = ((z - lo[i]) / span) if span > 1e-9 else 0.5
	return out


func _smin(p_a: float, p_b: float, p_k: float) -> float:
	if p_k <= 1e-9:
		return minf(p_a, p_b)
	var h := clampf(0.5 + 0.5 * (p_b - p_a) / p_k, 0.0, 1.0)
	return (p_b * (1.0 - h) + p_a * h) - p_k * h * (1.0 - h)


func _smax(p_a: float, p_b: float, p_k: float) -> float:
	return -_smin(-p_a, -p_b, p_k)


func _smooth_fill(p_in: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var out := PackedFloat32Array()
	out.resize(n)
	last_deposition = PackedFloat32Array()
	last_deposition.resize(n)
	last_deposition_divisor = 1.0

	if amount <= 0.0 or radius <= 0.0:
		return p_in.duplicate()

	var zb := box_mean(p_in, p_gw, p_gh, p_rect, radius)
	var dx := p_rect.size.x / float(p_gw)
	var dz := p_rect.size.y / float(p_gh)
	var delta := PackedFloat64Array()
	delta.resize(n)

	for iz in p_gh:
		for ix in p_gw:
			var i := iz * p_gw + ix
			var z := p_in[i]
			if is_nan(z):
				out[i] = NAN
				continue
			var b := zb[i]
			var h := z
			if mode == 2: # SMEAR_PEAKS
				h = _smin(z, b, k)
			else:
				var apply := true
				if mode == 1: # FILL_HOLES — a pit is concave along BOTH axes; a valley is not.
					var xm := maxi(ix - 1, 0)
					var xp := mini(ix + 1, p_gw - 1)
					var zm := maxi(iz - 1, 0)
					var zp := mini(iz + 1, p_gh - 1)
					var zxm := p_in[iz * p_gw + xm]
					var zxp := p_in[iz * p_gw + xp]
					var zzm := p_in[zm * p_gw + ix]
					var zzp := p_in[zp * p_gw + ix]
					if is_nan(zxm) or is_nan(zxp) or is_nan(zzm) or is_nan(zzp):
						apply = false
					else:
						var d2x := (zxp - 2.0 * z + zxm) / (dx * dx)
						var d2z := (zzp - 2.0 * z + zzm) / (dz * dz)
						apply = d2x > 0.0 and d2z > 0.0
				h = _smax(z, b, k) if apply else z
			var o := z + (h - z) * amount
			out[i] = o
			delta[i] = o - z

	var hi := 0.0
	for i in n:
		hi = maxf(hi, absf(delta[i]))
	last_deposition_divisor = hi if hi > 1e-12 else 1.0
	for i in n:
		last_deposition[i] = float(delta[i] / last_deposition_divisor) if not is_nan(p_in[i]) else NAN
	return out


func _recast_cliff(p_in: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	if amount <= 0.0 or is_zero_approx(amplitude):
		return p_in.duplicate()

	var zb := box_mean(p_in, p_gw, p_gh, p_rect, radius)
	var dx := p_rect.size.x / float(p_gw)
	var dz := p_rect.size.y / float(p_gh)
	# A real angle, converted to a metric gradient — rise over run in metres, not a per-cell rise.
	var tan_talus := tan(deg_to_rad(talus_angle_deg))
	var lo_gate := tan_talus * 0.75
	var hi_gate := tan_talus * 1.25
	var directional := direction_deg >= 0.0
	var dir_rad := deg_to_rad(direction_deg)
	var spread_rad := deg_to_rad(maxf(direction_spread_deg, 0.0))
	var g := maxf(gain, 1e-6)

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
			var zxm := p_in[iz * p_gw + xm]
			var zxp := p_in[iz * p_gw + xp]
			var zzm := p_in[zm * p_gw + ix]
			var zzp := p_in[zp * p_gw + ix]
			if is_nan(zxm) or is_nan(zxp) or is_nan(zzm) or is_nan(zzp):
				out[i] = z
				continue
			var gx := (zxp - zxm) / (float(xp - xm) * dx)
			var gz := (zzp - zzm) / (float(zp - zm) * dz)
			var slope := sqrt(gx * gx + gz * gz)

			var gate := 0.0
			if hi_gate <= lo_gate:
				gate = 1.0 if slope >= tan_talus else 0.0
			else:
				var u := clampf((slope - lo_gate) / (hi_gate - lo_gate), 0.0, 1.0)
				gate = u * u * (3.0 - 2.0 * u)

			if directional and gate > 0.0:
				if slope <= 1e-12:
					gate = 0.0
				else:
					# The bearing the ground FACES is the downhill direction.
					var face := atan2(-gz, -gx)
					var diff := face - dir_rad
					while diff > PI:
						diff -= TAU
					while diff < -PI:
						diff += TAU
					var ang := absf(diff)
					if spread_rad <= 0.0 or ang >= spread_rad:
						gate = 0.0
					else:
						var u2 := 1.0 - (ang / spread_rad)
						gate *= u2 * u2 * (3.0 - 2.0 * u2)

			var w := amount * gate
			if w <= 0.0:
				out[i] = z
				continue
			var dev := z - zb[i]
			var s := 1.0 / (1.0 + exp(-g * dev / amplitude))
			out[i] = z + amplitude * (s - 0.5) * w
	return out
