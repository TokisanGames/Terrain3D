# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DReliefDLA — a mountain grown by diffusion-limited aggregation. Particles random-walk until they
# stick to a cluster, which branches; blurring that skeleton at increasing radii and summing the copies
# turns it into a massif with major ridges and minor spurs. A ridge network is the topological dual of a
# drainage network, which is why DLA lands on the same branching statistics erosion produces without
# simulating anything, and why DLA-then-erosion reinforces rather than fights.
#
# UNLIKE EVERY OTHER RELIEF MATERIAL THIS ONE IS NOT POINT-EVALUATED. There is no closed form for "is
# (u,v) on the cluster" without having grown the whole cluster, so the grid is grown ONCE per compile in
# GDScript, baked into the program's field table, and bilinear-sampled by both evaluators — which is also
# what makes the C++/GDScript oracle parity free rather than maintained (spec §9.1). Sized by the loop
# exactly like a Crater, so it needs Mapping = Fit or Scatter; the host warns under Tile.
# See PASTURE3D_BRUSH_EROSION_SPEC.md §9.
@tool
class_name Pasture3DReliefDLA
extends Pasture3DReliefMaterial

## Widest working grid the cluster is grown on, in cells. The final blur dominates how this reads, so
## resolution beyond the vertex spacing buys detail the mesh cannot carry — 512² is 1.0 MB of float field
## and about 2 s to grow, and is the sensible ceiling for a single mountain; 256² is a quarter of both.
## Paid once per change to a growth property, not once per bake. Rounded DOWN to a power of two so the
## hierarchy's halving is exact.
@export_range(64, 1024, 64) var resolution: int = 512:
	set(v):
		resolution = clampi(v, 64, 1024)
		_touch()
## How many grow-then-upscale rounds. Each round doubles the grid, subdivides every branch with a
## displaced midpoint, and grows again — which is what produces a HIERARCHY of major ridges and minor
## spurs rather than one scale of branching. 1 means "grow once, at full resolution", which is both much
## slower and much less interesting.
@export_range(1, 6) var hierarchy_levels: int = 4:
	set(v):
		hierarchy_levels = clampi(v, 1, 6)
		_touch()
## Particles walked at the FINAL grid; coarser rounds get proportionally fewer, in the ratio of their
## grid sizes. A cluster's cell count scales as roughly r^1.7 while an upscale only doubles its node
## count, so every round has to ADD about as many nodes as it inherited -- a flat budget starves the
## fine rounds and the massif never reaches its loop. Higher is bushier and slower, linearly.
@export_range(64, 8192, 1) var particles: int = 2000:
	set(v):
		particles = clampi(v, 64, 8192)
		_touch()
## How far a branch's inserted midpoint is thrown sideways when the grid doubles, as a fraction of the
## branch's length, and how far every existing node is jittered at the same time. 0 keeps the cluster on
## its lattice and the arms come out visibly axis-aligned; ~0.3 reads as a ridge.
@export_range(0.0, 1.0, 0.01) var wander: float = 0.32:
	set(v):
		wander = clampf(v, 0.0, 1.0)
		_touch()
@export var seed: int = 0:
	set(v):
		seed = v
		_touch()

@export_group("Massing")
## How many times the skeleton is blurred and summed. Each level roughly doubles the radius, so this is
## the number of scales the massif is built from, not a quality slider.
@export_range(1, 7) var blur_levels: int = 5:
	set(v):
		blur_levels = clampi(v, 1, 7)
		_touch()
## Weight ratio between one blur level and the next-wider one. Above 1 the broad blurs carry the mass and
## the result reads as a MOUNTAIN with ridges on it; below 1 the sharp skeleton dominates and it reads as
## a bare ridge network. 1 weights every scale equally.
@export_range(0.25, 4.0, 0.05) var blur_growth: float = 1.6:
	set(v):
		blur_growth = clampf(v, 0.25, 4.0)
		_touch()
## Remap applied to the normalised field: 1 = linear, above 1 pulls the flanks down towards the base and
## sharpens the summit, below 1 fattens the massif out towards a plateau.
@export_range(0.25, 4.0, 0.05) var profile_power: float = 1.0:
	set(v):
		profile_power = clampf(v, 0.25, 4.0)
		_touch()

# The grown field, memoised on the growth inputs ALONE. `strength`, `blend`, `selector` and
# `output_curve` all call _touch() and so invalidate the compiled program, but none of them changes a
# single cell of the cluster — and regrowing a 512² DLA because someone dragged a strength slider is the
# difference between an editable material and an unusable one.
var _dla_key := ""
var _dla_field := PackedFloat32Array()
var _dla_n := 0

## Fraction of the grid half-width the cluster is allowed to reach. The remaining margin has to be at
## least the total blur support (see _blur_radii), or the massif would be clipped by the field's edge
## instead of fading to zero inside it — and a DLA that does not read 0 at nu,nv = ±1 puts a step at the
## loop boundary on every FIT-mapped brush.
const GROW_EXTENT := 0.30
## Total blur support as a fraction of the grid width, so GROW_EXTENT + this stays inside 0.5.
const BLUR_SUPPORT := 0.18


func _build() -> void:
	var f := _field()
	if f.is_empty():
		return
	_emit(Op.DLA, Blend.ADD, [1.0, _bake_field(f, _dla_n, _dla_n)])


## The normalised 0..1 field, grown on demand and cached on the growth inputs.
func _field() -> PackedFloat32Array:
	var key := "%d|%d|%d|%d|%.4f|%d|%.4f|%.4f" % [seed, resolution, hierarchy_levels, particles,
			wander, blur_levels, blur_growth, profile_power]
	if key == _dla_key and not _dla_field.is_empty():
		return _dla_field
	var rng := RandomNumberGenerator.new()
	# Seeded, never randomize(): the field is part of the compiled program, so two bakes of one saved
	# resource have to be bitwise identical or every re-bake would move the mountain. Gate CP.
	rng.seed = seed
	var res := _grid_size()
	var n0 := maxi(res >> (hierarchy_levels - 1), 16)
	var cluster := _grow(rng, n0, res)
	var raster := _rasterise(cluster, res)
	_dla_field = _mass(raster, res)
	_dla_n = res
	_dla_key = key
	return _dla_field


## `resolution` rounded DOWN to a power of two, so halving it `hierarchy_levels - 1` times is exact and
## the upscale steps land on whole cells.
func _grid_size() -> int:
	var n := 64
	while n * 2 <= resolution:
		n *= 2
	return n


## Grow the cluster as a NODE GRAPH (positions plus a parent link), not as a bitmap. The bitmap only
## exists to answer "is this cell occupied"; the graph is what survives an upscale, and it is what lets a
## branch be subdivided and thrown sideways when the grid doubles.
##
## Returns [xs, ys, parents] in FINAL-grid cell coordinates.
func _grow(rng: RandomNumberGenerator, p_n0: int, p_res: int) -> Array:
	var n := p_n0
	# How many doublings this run will make, so the extent ramp below knows where the last level is.
	var rounds := 0
	var probe := p_n0
	while probe < p_res:
		probe *= 2
		rounds += 1
	var xs := PackedFloat32Array([float(n) * 0.5])
	var ys := PackedFloat32Array([float(n) * 0.5])
	var parents := PackedInt32Array([-1])
	# `owner[cell]` is the node index that put material in that cell, which is how a stuck particle finds
	# out what it stuck TO. -1 is empty.
	var owner := PackedInt32Array()
	owner.resize(n * n)
	owner.fill(-1)
	owner[int(n * 0.5) * n + int(n * 0.5)] = 0

	var level := 0
	while true:
		# The reach allowed at THIS level, ramped so every level has somewhere to grow. An upscale
		# doubles the cluster AND the grid, so a fixed fraction would leave the cluster already at its
		# limit the moment the grid doubled -- which is exactly what an earlier version did, and it grew
		# 33 nodes at level 0 and then nothing at all for five rounds. Coarse levels decide the trunk
		# inside a smaller disc; the last level is the one that reaches GROW_EXTENT.
		_grow_level(rng, n, lerpf(0.7, 1.0, float(level) / float(maxi(rounds, 1))),
				maxi(24, particles * n / p_res), xs, ys, parents, owner)
		if n >= p_res:
			break
		n *= 2
		level += 1
		owner = _upscale(rng, n, xs, ys, parents)
	return [xs, ys, parents]


## One round of aggregation on an n x n grid, capped at `p_frac` of the level's allowed reach.
##
## Particles launch within the cluster's own reach, never from the grid edge: a walk in from the edge is
## quadratic in the empty gap and is where a naive DLA spends all of its time, for no difference at all in
## the result.
func _grow_level(rng: RandomNumberGenerator, n: int, p_frac: float, p_particles: int,
		xs: PackedFloat32Array, ys: PackedFloat32Array, parents: PackedInt32Array,
		owner: PackedInt32Array) -> void:
	var c := float(n) * 0.5
	var limit := float(n) * GROW_EXTENT * p_frac
	var reach := 1.0
	for i in range(xs.size()):
		reach = maxf(reach, sqrt(pow(xs[i] - c, 2.0) + pow(ys[i] - c, 2.0)))
	# Steps, not nodes: a particle takes one step per iteration and the budget has to cover crossing the
	# launch gap several times over. Bounded so an unstickable particle cannot spin.
	var budget := n * 4
	for pi in range(p_particles):
		# HALF the particles launch on the envelope and half anywhere inside it, alternately. Pure DLA is
		# all envelope, and it is tip-dominated: every particle meets the outside first, so once the
		# cluster has touched its limit the remaining mass piles into a shell and the massif comes out
		# HOLLOW - a ring of ridges round an empty middle, which is a crater, not a mountain. All-interior
		# is the opposite failure: the cluster stops reaching outward and never fills its loop. The split
		# is deterministic (alternating, not sampled) so the mix does not itself vary with the seed.
		var launch: float = minf(reach + 3.0, limit) * (1.0 if (pi & 1) == 0 else rng.randf())
		var ang := rng.randf() * TAU
		var px := int(round(c + cos(ang) * launch))
		var py := int(round(c + sin(ang) * launch))
		var kill := limit + 6.0
		var stuck := -1
		for _s in range(budget):
			if px < 1 or py < 1 or px >= n - 1 or py >= n - 1:
				break
			if sqrt(pow(float(px) - c, 2.0) + pow(float(py) - c, 2.0)) > kill:
				break
			stuck = _neighbour_owner(owner, n, px, py)
			if stuck >= 0:
				break
			# 4-neighbour walk. An 8-neighbour one sticks through diagonals and produces a visibly
			# blockier cluster at these grid sizes.
			match rng.randi() & 3:
				0: px += 1
				1: px -= 1
				2: py += 1
				_: py -= 1
		if stuck < 0:
			continue
		# Reject rather than stop. An earlier version broke out of the particle loop the moment the
		# cluster touched its limit, which meant a level whose upscaled cluster ALREADY touched it grew
		# nothing at all -- and a displaced midpoint can push the reach out past the ramp's headroom, so
		# that was most levels. Dropping the one particle instead lets the level keep filling in behind
		# the envelope, which is where a hierarchy's finer branches come from.
		if sqrt(pow(float(px) - c, 2.0) + pow(float(py) - c, 2.0)) > limit:
			continue
		var id := xs.size()
		xs.append(float(px))
		ys.append(float(py))
		parents.append(stuck)
		owner[py * n + px] = id
		reach = maxf(reach, sqrt(pow(float(px) - c, 2.0) + pow(float(py) - c, 2.0)))


## The node index of an occupied 4-neighbour, or -1.
func _neighbour_owner(owner: PackedInt32Array, n: int, px: int, py: int) -> int:
	var o := owner[py * n + px - 1]
	if o >= 0:
		return o
	o = owner[py * n + px + 1]
	if o >= 0:
		return o
	o = owner[(py - 1) * n + px]
	if o >= 0:
		return o
	return owner[(py + 1) * n + px]


## Double the grid: every node's coordinates double, and every branch gains a midpoint thrown sideways by
## `wander`. The displaced midpoints are the whole reason the hierarchy exists — without them an upscale
## would just be a bigger picture of the same cluster, and the next round of growth would decorate a set
## of dead-straight lines. Returns the rebuilt owner grid.
func _upscale(rng: RandomNumberGenerator, n: int, xs: PackedFloat32Array, ys: PackedFloat32Array,
		parents: PackedInt32Array) -> PackedInt32Array:
	var count := xs.size()
	# Doubling alone turns one coarse step into a dead-straight run of 2^levels cells, and a midpoint
	# displacement cannot break it: subdividing halves the segment as fast as doubling lengthens it, so
	# the throw stays sub-cell forever and the cluster reads as a set of axis-aligned bars. Jittering
	# every node as well is what puts the kink in each run.
	var jit := wander * 0.75
	for i in range(count):
		xs[i] = xs[i] * 2.0 + rng.randfn(0.0, jit)
		ys[i] = ys[i] * 2.0 + rng.randfn(0.0, jit)
	var lo := 1.0
	var hi := float(n - 2)
	for i in range(count):
		var pa := parents[i]
		if pa < 0:
			continue
		var dx := xs[i] - xs[pa]
		var dy := ys[i] - ys[pa]
		var seg := sqrt(dx * dx + dy * dy)
		var mx := (xs[i] + xs[pa]) * 0.5
		var my := (ys[i] + ys[pa]) * 0.5
		if seg > 0.0001 and wander > 0.0:
			var throw := rng.randfn(0.0, seg * wander * 0.5)
			mx += (-dy / seg) * throw
			my += (dx / seg) * throw
		var mid := xs.size()
		xs.append(clampf(mx, lo, hi))
		ys.append(clampf(my, lo, hi))
		parents.append(pa)
		parents[i] = mid
	var owner := PackedInt32Array()
	owner.resize(n * n)
	owner.fill(-1)
	for i in range(xs.size()):
		_stamp_edge(owner, n, xs, ys, parents, i)
	return owner


## Walk the segment from node i to its parent, claiming every cell it crosses for node i. Bresenham would
## do; this steps along the line at one cell per step, which is a couple of lines shorter and cannot leave
## a gap because the step length is 1.
func _stamp_edge(owner: PackedInt32Array, n: int, xs: PackedFloat32Array, ys: PackedFloat32Array,
		parents: PackedInt32Array, i: int) -> void:
	var pa := parents[i]
	var cx := int(round(xs[i]))
	var cy := int(round(ys[i]))
	if cx >= 0 and cy >= 0 and cx < n and cy < n:
		owner[cy * n + cx] = i
	if pa < 0:
		return
	var dx := xs[pa] - xs[i]
	var dy := ys[pa] - ys[i]
	var steps := int(ceil(maxf(absf(dx), absf(dy))))
	if steps < 1:
		return
	for s in range(1, steps):
		var t := float(s) / float(steps)
		var x := int(round(xs[i] + dx * t))
		var y := int(round(ys[i] + dy * t))
		if x < 0 or y < 0 or x >= n or y >= n:
			continue
		if owner[y * n + x] < 0:
			owner[y * n + x] = i


## Draw the finished graph into a float grid: every cell a branch crosses is 1, everything else 0.
##
## DELIBERATELY BINARY. An earlier version weighted each branch by its SUBTREE MASS -- trunk bright, tips
## dim -- on the reasoning that a massif should be heaviest where the cluster is heaviest. Measured, that
## is wrong twice over: the mass range across a cluster spans four decades, so under any remapping the
## trunk becomes a spike with the branches barely visible, and the massing it was trying to produce is
## what the blur stack already does for free -- a cell surrounded by dense cluster gets a high value from
## the wide blurs without being told to. The skeleton's job is to say WHERE the ridges are, and only that.
func _rasterise(p_cluster: Array, p_res: int) -> PackedFloat32Array:
	var xs: PackedFloat32Array = p_cluster[0]
	var ys: PackedFloat32Array = p_cluster[1]
	var parents: PackedInt32Array = p_cluster[2]
	var count := xs.size()
	var out := PackedFloat32Array()
	out.resize(p_res * p_res)
	out.fill(0.0)
	for i in range(count):
		var pa := parents[i]
		if pa < 0:
			_plot(out, p_res, xs[i], ys[i])
			continue
		var dx := xs[pa] - xs[i]
		var dy := ys[pa] - ys[i]
		var steps := maxi(1, int(ceil(maxf(absf(dx), absf(dy)))))
		for s in range(steps + 1):
			var t := float(s) / float(steps)
			_plot(out, p_res, xs[i] + dx * t, ys[i] + dy * t)
	return out


func _plot(g: PackedFloat32Array, n: int, x: float, y: float) -> void:
	var ix := int(round(x))
	var iy := int(round(y))
	if ix >= 0 and iy >= 0 and ix < n and iy < n:
		g[iy * n + ix] = 1.0


## Blur the skeleton at increasing radii and sum the copies, weighted. This is what turns a one-cell-wide
## line drawing into terrain: the narrow blurs keep the ridge crests, the wide ones supply the mass they
## sit on. Applied cumulatively (each level blurs the previous level's output) rather than re-blurring the
## original, because N cumulative box passes at doubling radii cost the same as one apiece and land on the
## same exponential series of supports.
func _mass(p_raster: PackedFloat32Array, n: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n * n)
	out.fill(0.0)
	var img := p_raster
	var weight := 1.0
	var total := 0.0
	for r in _blur_radii(n):
		img = _box_blur(img, n, r)
		# EACH LEVEL IS RENORMALISED TO ITS OWN PEAK before it is weighted, and that is not a tidiness
		# measure -- it is what makes `blur_growth` mean anything. A box blur of a one-cell-wide skeleton
		# divides its amplitude by roughly the radius, so raw copies fall off far faster than any sane
		# weight ramp can lift them and the sum is the NARROWEST blur every time: glowing thin lines on
		# black, with no massing at all. Renormalised, the ramp sets the balance between scales directly.
		var lvl := 0.0
		for i in range(n * n):
			lvl = maxf(lvl, img[i])
		if lvl <= 0.0:
			continue
		var k := weight / lvl
		for i in range(n * n):
			out[i] += img[i] * k
		total += weight
		weight *= blur_growth
	if total <= 0.0:
		return out
	var peak := 0.0
	for i in range(n * n):
		peak = maxf(peak, out[i])
	if peak <= 0.0:
		return out
	var inv := 1.0 / peak
	var pw := profile_power
	for i in range(n * n):
		var v := out[i] * inv
		out[i] = v if pw == 1.0 else pow(v, pw)
	return out


## Doubling radii whose TOTAL is capped at BLUR_SUPPORT of the grid. The cap is the invariant that keeps
## the massif inside the field: growth reaches GROW_EXTENT (0.35) and the blur can push material at most
## BLUR_SUPPORT further, so the outer 5% of the field is still exactly zero and the material fades
## out inside its own loop rather than being cut off at the edge.
##
## Levels are DROPPED, not shrunk, when the budget runs out: the smallest useful radius is 1 cell, so on a
## small grid the widest levels are simply not affordable. Keeping them by clamping r0 to 1 would break the
## invariant instead of the level count, which is the wrong thing to give up - a mountain with one fewer
## scale of massing still fades out inside its loop.
func _blur_radii(n: int) -> PackedInt32Array:
	var budget := maxi(1, int(float(n) * BLUR_SUPPORT))
	var span := (1 << blur_levels) - 1 # 1 + 2 + 4 + ... = 2^levels - 1
	var r0 := maxi(1, budget / span)
	var out := PackedInt32Array()
	var used := 0
	for k in range(blur_levels):
		var r := r0 << k
		if used + r > budget and not out.is_empty():
			break
		out.append(r)
		used += r
	return out


## Separable box blur with a running sum, so the cost is independent of the radius. Edges clamp.
func _box_blur(p_src: PackedFloat32Array, n: int, r: int) -> PackedFloat32Array:
	var tmp := PackedFloat32Array()
	tmp.resize(n * n)
	var inv := 1.0 / float(2 * r + 1)
	for y in range(n):
		var row := y * n
		var acc := p_src[row] * float(r + 1)
		for i in range(1, r + 1):
			acc += p_src[row + mini(i, n - 1)]
		for x in range(n):
			tmp[row + x] = acc * inv
			acc += p_src[row + mini(x + r + 1, n - 1)] - p_src[row + maxi(x - r, 0)]
	var out := PackedFloat32Array()
	out.resize(n * n)
	for x in range(n):
		var acc := tmp[x] * float(r + 1)
		for i in range(1, r + 1):
			acc += tmp[mini(i, n - 1) * n + x]
		for y in range(n):
			out[y * n + x] = acc * inv
			acc += tmp[mini(y + r + 1, n - 1) * n + x] - tmp[maxi(y - r, 0) * n + x]
	return out


func _configuration_warning() -> String:
	if particles < 32 and hierarchy_levels < 2:
		return ("Relief DLA has too few particles and no hierarchy to subdivide them — the cluster will be "
			+ "a handful of spikes. Raise Particles, or Hierarchy Levels.")
	return ""
