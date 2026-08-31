# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadAlignment — the SOLVED vertical profile of one road run, sampled uniformly along its
# centreline: how high the road is at every metre, how steeply it climbs there, and how far it is banked.
# Produced by Pasture3DRoadAlignmentSolver; see PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §7.
#
# ---- THIS IS THE DIFFERENCE BETWEEN A ROAD AND A RIBBON ----
#
# The plan alignment (where the road goes in XZ) is authored on the spline. The VERTICAL alignment is
# not: it is solved, subject to a hard gradient limit, by trading cut against fill. A road that simply
# drapes on the terrain reads as a ribbon laid over a hill, because a real road cuts through the crest
# and fills the dip rather than following either.
#
# ---- WHAT ELSE FALLS OUT OF IT ----
#
# Two things come free once this exists, and neither is available to a draped road:
#
#   * BANKING. Plan curvature gives superelevation by v²·κ/g, which is physics rather than styling, and
#     is the same number a racing track wants. It is baked into the run's Curve3D tilt, so a game reads
#     it straight out of `Curve3D.sample_baked_up_vector()`.
#   * PACE NOTES (P6). Corner severity is κ; "crest" and "dip" are the sign of d²z/ds² — of the SOLVED
#     profile. On a draped road that second derivative is terrain noise, not road geometry, so the calls
#     would be nonsense. `curvature` and `z` are kept here for exactly that consumer.
#
# Sampling is uniform in arc length (`ds` metres apart, starting at `s0`), which is what makes every
# query below an index rather than a search.
@tool
class_name Pasture3DRoadAlignment
extends Resource

## Arc-length spacing between samples, metres.
@export var ds: float = 1.0
## Arc length of the first sample, metres from the start of the run.
@export var s0: float = 0.0
## Solved road surface height at each sample, metres. The answer this whole class exists to carry.
@export var z: PackedFloat32Array = PackedFloat32Array()
## Terrain height under each sample, metres — kept so cut/fill can be re-derived and so a later phase
## can grade the ground toward `z` without re-sampling the heightmap.
@export var ground: PackedFloat32Array = PackedFloat32Array()
## Signed plan curvature at each sample, 1/metres. Positive turns left. Drives banking, and is the
## corner-severity input for pace notes.
@export var curvature: PackedFloat32Array = PackedFloat32Array()
## Superelevation at each sample as a rise/run RATIO across the carriageway, signed like `curvature`.
@export var bank: PackedFloat32Array = PackedFloat32Array()
## Sample indices whose height was pinned by the designer and not solved for.
@export var pinned: PackedInt32Array = PackedInt32Array()

@export_group("Diagnostics")
## The gradient limit the solve was run under, rise/run. Kept so a result can be checked against the
## constraint it was actually given rather than against whatever the RoadType says now.
@export var max_grade_used: float = 0.08
## Steepest |dz/ds| in the result. Must not exceed `max_grade_used` by more than rounding.
@export var peak_grade: float = 0.0
## Metres³ of material removed and added (per metre of width — multiply by the road's width).
@export var cut_volume: float = 0.0
@export var fill_volume: float = 0.0
## Largest distance any pinned sample ended up from the height it was pinned to, metres. Non-zero means
## the pins asked for something the gradient limit forbids — see `Pasture3DRoadAlignmentSolver`.
@export var pin_error: float = 0.0
## False when the solve could not reach a profile satisfying the gradient limit. Never silently ignored:
## a caller that gets this should say so rather than build a road that climbs a wall.
@export var feasible: bool = true


## Number of samples.
func count() -> int:
	return z.size()


## Total arc length this alignment covers, metres.
func length() -> float:
	return maxf(float(count() - 1), 0.0) * ds


## Sample index nearest `p_s` metres along the run, clamped to the ends.
func index_at(p_s: float) -> int:
	if count() == 0:
		return -1
	return clampi(int(round((p_s - s0) / maxf(ds, 1e-6))), 0, count() - 1)


## Road height at `p_s` metres, linearly interpolated. NAN when there is nothing solved.
func height_at(p_s: float) -> float:
	var n := count()
	if n == 0:
		return NAN
	if n == 1:
		return z[0]
	var t := (p_s - s0) / maxf(ds, 1e-6)
	var i := clampi(int(floor(t)), 0, n - 2)
	return lerpf(z[i], z[i + 1], clampf(t - float(i), 0.0, 1.0))


## Gradient at sample `p_i`, rise/run, by central difference (one-sided at the ends). The quantity the
## solve constrains, so it is derived here rather than stored — a stored copy could disagree with `z`.
func grade_at(p_i: int) -> float:
	var n := count()
	if n < 2:
		return 0.0
	var i := clampi(p_i, 0, n - 1)
	if i == 0:
		return (z[1] - z[0]) / ds
	if i == n - 1:
		return (z[n - 1] - z[n - 2]) / ds
	return (z[i + 1] - z[i - 1]) / (2.0 * ds)


## Vertical curvature at sample `p_i`, 1/metres — the second difference of the SOLVED profile. Positive
## is a dip (sag), negative is a crest. The pace-note generator's crest/dip test, and the reason the
## solver carries a smoothness term at all.
func vertical_curvature_at(p_i: int) -> float:
	var n := count()
	if n < 3:
		return 0.0
	var i := clampi(p_i, 1, n - 2)
	return (z[i - 1] - 2.0 * z[i] + z[i + 1]) / (ds * ds)


## Height of the road above (+) or below (−) the terrain at sample `p_i`. Positive is fill, negative is
## cut. The field P2's grader turns into earthworks, and the test for a bridge or a tunnel interval.
func offset_at(p_i: int) -> float:
	if p_i < 0 or p_i >= count() or p_i >= ground.size():
		return 0.0
	return z[p_i] - ground[p_i]


## Banking as a TILT in radians about the direction of travel, which is what a Curve3D point's tilt
## wants. `bank` is stored as a ratio because that is how road engineering states it and how
## `max_superelevation` is authored.
func tilt_at(p_i: int) -> float:
	if p_i < 0 or p_i >= bank.size():
		return 0.0
	return atan(bank[p_i])


## Intervals where the road stands far enough off the ground to need a structure: `[[from_s, to_s,
## is_bridge], …]`, bridge when the road is above the terrain and a tunnel when below. Emitting the
## INTERVAL is what stops a later phase building an absurd earth dam across a valley; building the
## structure itself is a separate system and out of scope.
func structure_intervals(p_bridge_threshold: float = 6.0, p_tunnel_threshold: float = 6.0) -> Array:
	var out: Array = []
	var n := mini(count(), ground.size())
	var open := -1
	var open_bridge := false
	for i in n:
		var d := offset_at(i)
		var is_b := d > p_bridge_threshold
		var is_t := d < -p_tunnel_threshold
		var hit := is_b or is_t
		if hit and open < 0:
			open = i
			open_bridge = is_b
		elif open >= 0 and (not hit or is_b != open_bridge):
			out.append([s0 + float(open) * ds, s0 + float(i - 1) * ds, open_bridge])
			open = i if hit else -1
			open_bridge = is_b
	if open >= 0:
		out.append([s0 + float(open) * ds, s0 + float(n - 1) * ds, open_bridge])
	return out
