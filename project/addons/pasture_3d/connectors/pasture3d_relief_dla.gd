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
#
# BECAUSE THE FIELD IS STRETCHED ONCE OVER THE LOOP'S RECTANGLE, IT IS GROWN TO THAT RECTANGLE'S SHAPE.
# The host hands the oriented half-extents over before compile (`set_host_frame`), the grid is cropped to
# their ratio, and the cluster is confined to the ellipse inscribed in it. Growing one square field and
# letting the samplers stretch it — which is what this material did until it met a loop that was not
# square — multiplies every ridge width, branch spacing and blur radius along one axis by the loop's
# aspect ratio.
# See PASTURE3D_BRUSH_EROSION_SPEC.md §9.
@tool
class_name Pasture3DReliefDLA
extends Pasture3DReliefMaterial

## The finished mountain's OUTER RADIUS, as a fraction of the loop's half-extent. 1.0 reaches the edge of
## the fitted rectangle; 0.5 is a mountain sitting in the middle of its loop with clear ground round it.
## This is the SIZE control, and it is exact: the cluster and the blur that widens it are BOTH derived
## from this, and together they spend all of it.
##
## A fraction of the half-extent along EACH of the loop's own axes, so on a 3:1 loop the massif is three
## times as long as it is wide and reaches the edge at both ends. What it is not is three times as long
## with ridges to match — the texture on it stays the size it would be on a square loop.
##
## They did not always. An earlier version reserved a fixed share of the radius for the blur whether the
## blur wanted it or not, and measured on a 240 m loop that left the relief at exactly 0.00 m for the
## first 24 m in from the edge — reported from the editor as "the influence only goes half way down the
## mesh", which is precisely what it was.
## LIVE regrows the cluster whenever anything it is grown from moves; FROZEN holds the mountain it has
## and regrows only on Bake Mountain.
##
## The same two words Pasture3DNodeErosion uses, deliberately — and the same default, for the same reason.
## Growing a 512² cluster is seconds of GDScript, `auto_refresh` re-bakes on every frame of a drag, and
## a material that regrew per frame locked the editor. FROZEN is what makes this a usable brush.
enum Evaluation { LIVE, FROZEN }

## Whether the cluster regrows on every change, or holds until Bake Mountain.
##
## FROZEN is the default and one rule covers everything: ANY change — a slider here, the loop's shape,
## the surface Ridge Seeding reads — leaves the grown mountain in place and raises a stale warning until
## you press Bake Mountain. Set it to Live on a small, low-Resolution material where a regrow is cheap
## enough to watch.
@export var evaluation: Evaluation = Evaluation.FROZEN:
	set(v):
		evaluation = v
		_touch()

## Regrow the cluster against everything as it stands now. The explicit Bake, and the counterpart to
## Pasture3DNodeErosion's Bake Erosion.
@export_tool_button("Bake Mountain") var _bake_btn = bake_mountain

@export_range(0.2, 1.0, 0.01) var coverage: float = 0.95:
	set(v):
		coverage = clampf(v, 0.2, 1.0)
		_touch()
## Widest working grid the cluster is grown on, in cells. The final blur dominates how this reads, so
## resolution beyond the vertex spacing buys detail the mesh cannot carry — 512² is 1.0 MB of float field
## and about 2 s to grow; 256² is a quarter of both. Paid once per change to a GROWTH property, not once
## per bake.
##
## A LIST rather than a slider, because only powers of two do anything: the hierarchy halves the grid and
## the material rounds down to make that exact, so a slider offering 64-step values was offering 15
## choices of which 5 were real and 192 behaved exactly as 128.
@export_enum("64:64", "128:128", "256:256", "512:512", "1024:1024") var resolution: int = 512:
	set(v):
		resolution = clampi(v, 64, 1024)
		_touch()
## How many grow-then-upscale rounds. Each round doubles the grid, subdivides every branch with a
## displaced midpoint, and grows again — which is what produces a HIERARCHY of major ridges and minor
## spurs rather than one scale of branching. 1 means "grow once, at full resolution", which is both much
## slower and much less interesting.
## The useful maximum is set by `resolution`, not by a number chosen here: the coarsest grid is floored at
## 16 cells, so 512 supports 6 rounds and 1024 supports 7, and anything past that halves nothing. The
## range goes to 8 for the largest grid and the material warns when the setting outruns its resolution
## rather than silently doing less than the number says.
@export_range(1, 8) var hierarchy_levels: int = 4:
	set(v):
		hierarchy_levels = clampi(v, 1, 8)
		_touch()
## How coarse the branching is: the spacing between ridges, as a fraction of the mountain's own radius.
## Small is a finely divided massif of many thin spurs; large is a few broad arms.
##
## This and `coverage` are the two controls that answer "bigger" and "chunkier", and they are DELIBERATELY
## INDEPENDENT. The particle count and the blur radii are both derived from them, because the raw particle
## count does not survive a change of size: measured, the same 2000 particles gave a saturated blob with no
## visible branching at coverage 0.5 and a spindly wireframe at 0.98. Sizing the mountain should not
## restyle it, so the density is held and the count follows.
##
## Cost follows the count, which rises as this falls — roughly (1 / detail_size)^0.7.
##
## The whole range does something, which took fixing: the blur used to be capped at a fixed share of the
## radius, and everything past 0.16 hit that cap and stopped widening the ridges at all. Over half the
## slider was inert.
@export_range(0.03, 0.50, 0.005) var detail_size: float = 0.12:
	set(v):
		detail_size = clampf(v, 0.03, 0.50)
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

@export_group("Ridge Seeding")
## Grow the cluster OUT OF the ridges already on the brush instead of out of a single point in the
## middle. The host hands this material the surface the modifiers ABOVE it produced, the convex ridge
## lines in it become the cluster's starting skeleton, and the walk decorates those rather than inventing
## its own trunk somewhere else.
##
## The workflow it exists for is `Relief → Erosion → DLA`: rough in a landform, let erosion carve the
## drainage, then grow the ridge network along what erosion actually cut. A ridge network is the dual of
## a drainage network, so the two agree structurally — but only if the DLA is told where the drainage
## went, which unseeded it never is.
##
## NOTE the surface arrives from the PREVIOUS bake, exactly as a frozen erosion solve does, so turning
## this on takes two bakes to settle. The brush schedules the second one itself. It reads the modifiers
## above this one and never this material's own output, so it cannot feed itself.
@export var ridge_seeding: bool = false:
	set(v):
		ridge_seeding = v
		_touch()
## How much of the seeded surface counts as ridge, as a fraction of the cells inside the mountain. Small
## picks out only the sharpest crest lines; large seeds broad shoulders too and leaves the walk less to
## invent.
@export_range(0.01, 0.30, 0.005) var ridge_amount: float = 0.05:
	set(v):
		ridge_amount = clampf(v, 0.01, 0.30)
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
# The surface the host captured from the modifiers ABOVE this one, in the brush's own metres, plus the
# frame needed to map it onto the field's loop-normalised square. Empty until a bake has handed one over.
# NOT saved: it is derived from the rest of the stack, and storing it would let a stale copy travel with
# the .tres and quietly seed the wrong mountain.
var _seed: Dictionary = {}
var _seed_hash := 0
var _dla_key := ""
var _dla_field := PackedFloat32Array()
var _dla_n := 0
# The field's own dimensions AT THE TIME IT WAS GROWN. `_build` crops to these rather than to the loop's
# current ones, which matters only while FROZEN and stale: cropping a field grown for a square loop down
# to a newly-narrowed rectangle would cut the massif off at the crop edge — the loop-boundary step the
# blur budget exists to prevent, reintroduced by the cache that was supposed to be harmless.
var _dla_dims := Vector2i.ZERO
## Set when the held field was grown for inputs that have since moved. Reported as a warning rather than
## silently regrowing (which is the freeze) or silently serving old data (which is the trap).
var _stale := false
## True while the host has told us it can grow this off the main thread — see set_growth_deferred.
var _growth_deferred := false
## Set by `_build` when it declined to grow inside a bake, and cleared when the field lands. This is what
## `collect_growth` hands the host.
var _pending_grow := false
## One-shot: a worker's field was stored since the host last asked about deferral. Without it a stack
## enclosing this material would not be told to re-splice, and pass 3 of the driver would hand out the
## empty program pass 1 produced. See set_growth_deferred.
var _growth_landed := false
# The loop's oriented half-extents in metres, handed over by the host before every compile (see
# set_host_frame). Only their RATIO is used, and only to decide `_field_dims` — a mountain has no absolute
# size in here, it has a size relative to its loop.
var _host_ex := 1.0
var _host_ez := 1.0
var _host_dims := Vector2i.ZERO

# The reference point the derived quantities are calibrated at. Everything below is expressed as a ratio
# to it, so the shipped defaults reproduce a geometry that was tuned by looking at the result, and moving
# either control scales away from that rather than away from an abstraction.
const REF_DETAIL := 0.12
const REF_COVERAGE := 0.9
const REF_PARTICLES := 3000
const REF_RESOLUTION := 512
## The blur's share at REF_DETAIL, i.e. 4d/(1+4d) at d = 0.12. Written out so the particle calibration
## stays pinned to the reference geometry even when the split formula moves.
const REF_BLUR_SHARE := 0.3243
## The most of the mountain's radius the blur may take. Not a reservation — a CEILING. The blur asks for
## about four times the branch spacing (the radii double, so the widest level lands at roughly twice the
## gap between ridges, which is what makes the massif read as ground with ridges on it rather than as a
## wireframe) and gets it, and the cluster takes everything left over.
##
## 0.70 is chosen so the ceiling does not bind anywhere inside the authored `detail_size` range: the ask
## is 4d/(1+4d) of the radius, which reaches 0.70 only at d = 0.58. A ceiling that binds mid-range is a
## slider that stops working half way along, which is exactly what the previous 0.38 did.
const BLUR_CEILING := 0.70
## Fewest cells the baked field may have on its short side. Below 2 the bilinear samplers read a defined
## zero and the material vanishes; 8 is where a massif still has somewhere to be. A loop elongated past
## `resolution / FIELD_MIN` is warned about rather than silently un-squished, because the honest answer
## there is more Resolution and not a different shape.
const FIELD_MIN := 8


## The loop's oriented half-extents, in metres. Handed over by the host BEFORE compile(), because the
## field is grown inside compile() and has to be grown to the shape it is going to be stretched over.
##
## Sets `_dirty` directly instead of calling `_touch()`. `_touch()` emits `changed`, the brush re-bakes on
## `changed`, and the host calls this DURING a bake — so the tidy-looking version is an infinite loop.
## Nothing an artist can see has changed anyway; the compiled program has simply gone out of date.
##
## Compared through `_field_dims`, not through the raw ratio: two loops whose aspect differs in the fourth
## decimal produce the same grid, and regrowing a 512² cluster because a spline point moved a millimetre
## is the difference between an editable material and an unusable one. A material shared by two loops of
## genuinely different shape does regrow on each bake — the single-slot field cache cannot hold both.
func set_host_frame(p_ex: float, p_ez: float) -> bool:
	_host_ex = maxf(p_ex, 0.001)
	_host_ez = maxf(p_ez, 0.001)
	var dims := _field_dims()
	if dims == _host_dims:
		return false
	_host_dims = dims
	# FROZEN and holding a mountain: the compiled program does not change — `_build` emits the field at
	# the dims it was GROWN for — so invalidating here would put a recompile and a re-splice through every
	# enclosing stack on every frame of a reshape drag, to produce the same bytes. The shape change is
	# recorded as staleness instead, which is the thing the user actually needs told.
	if evaluation == Evaluation.FROZEN and not _dla_field.is_empty():
		_mark_stale()
		return false
	_dirty = true
	return true


## The baked field's own dimensions, in cells, cut out of the square working grid.
##
## THE WORKING GRID IS SQUARE AND ITS CELLS ARE SQUARE IN WORLD METRES. It covers a square of side
## 2 * max(ex, ez) in loop-local space; the loop's own rectangle is the centred crop of that square, and
## the crop is what gets baked. The massif is confined to the ellipse `_outer` describes, which is
## `coverage` of the half-extent along BOTH of the loop's axes and therefore lies inside the crop.
##
## The alternative is what this material used to do: grow one square field and let the evaluators stretch
## it over the rectangle. That maps a round mountain onto a 3:1 loop by making every ridge on it three
## times wider one way than the other — the cluster, the blur that widens it and the branch spacing all
## multiplied along a single axis. It is not visible on the square test loops the material was built on,
## and it is the first thing anyone sees on a hand-drawn one.
##
## Both dimensions are EVEN so the crop is exactly centred: `n` is a power of two, so `n - w` is even
## exactly when `w` is, and half a cell of offset would slide the massif off the middle of its loop.
func _field_dims() -> Vector2i:
	var n := _grid_size()
	var s := maxf(_host_ex, _host_ez)
	var w := clampi(int(round(float(n) * _host_ex / s)) & ~1, FIELD_MIN, n)
	var h := clampi(int(round(float(n) * _host_ez / s)) & ~1, FIELD_MIN, n)
	return Vector2i(w, h)


## The crop's extents as a fraction of the working grid, which is the factor every radius in here is
## anisotropic by. Exactly (1, 1) on a square loop, so a square loop grows the cluster it always grew.
func _aspect_scale() -> Vector2:
	var n := _grid_size()
	var d := _field_dims()
	return Vector2(float(d.x - 1) / float(n - 1), float(d.y - 1) / float(n - 1))


## The finished massif's outer semi-axes, in cells. Everything beyond this ELLIPSE is untouched zero,
## which is the invariant that keeps a FIT-mapped DLA from stepping at its loop boundary — and the ellipse
## is the loop's own rectangle scaled by `coverage`, so the invariant now holds on both axes rather than
## on the one that happened to be longer.
func _outer(n: int) -> Vector2:
	return _aspect_scale() * (coverage * 0.5 * float(n))


## How far out something is as a fraction of what it is allowed: 1.0 is ON the envelope. Every reach test
## in the growth is written in these units so that one number means the same thing on a square loop and on
## a 3:1 one, and so the cluster's ENVELOPE is the only anisotropic thing about it — the branching inside
## it stays on a square lattice with square cells and comes out the same shape everywhere.
static func _rho(dx: float, dy: float, e: Vector2) -> float:
	var u := dx / maxf(e.x, 0.001)
	var v := dy / maxf(e.y, 0.001)
	return sqrt(u * u + v * v)


## How wide the ridges are, in cells. The blur asks for four times the branch spacing and the spacing is
## `detail_size` of the cluster's reach, so this and `_grow_extent` are one equation solved together:
## blur = 4d * grow and grow = outer - blur gives blur = outer * 4d/(1+4d), which is what this returns.
##
## THE TWO SUM TO `coverage` EXACTLY. Nothing is reserved and left unspent, which is the whole point: the
## previous version fixed the split at 62/38 whatever the blur actually wanted, and the difference was
## empty ground between the mountain and its loop.
##
## Sized off the SHORTER semi-axis. The blur is one isotropic radius in cells — it has to be, because a
## blur with two radii is precisely the squashing this material is built to avoid — so the axis that can
## afford the least is the one that can set it. It is also the axis on which "everything outside
## `coverage` is zero" would break first, and that invariant is worth more than a ridge or two of width.
func _blur_budget(n: int) -> int:
	var o := _outer(n)
	var m := minf(o.x, o.y)
	var ask := 4.0 * detail_size
	return clampi(int(m * minf(ask / (1.0 + ask), BLUR_CEILING)), 1, maxi(1, int(m * BLUR_CEILING)))


## The cluster's own reach on each axis: everything the blur did not take.
##
## The floor is `min(4, half the axis)` rather than a flat 4 cells. A flat floor is fine while every axis
## is comfortably bigger than it, and on the short axis of an elongated loop at a COARSE hierarchy level
## it is not: the floor would push that level's cluster out past its own envelope, the upscales carry it,
## and the massif is then cut off square at the crop edge — the loop-boundary step this whole budget
## exists to prevent, reintroduced on the one axis nobody was looking at.
func _grow_extent(n: int) -> Vector2:
	var o := _outer(n)
	var b := float(_blur_budget(n))
	return Vector2(maxf(minf(4.0, o.x * 0.5), o.x - b), maxf(minf(4.0, o.y * 0.5), o.y - b))


## Particles walked at the FINAL grid; coarser rounds get proportionally fewer, in the ratio of their grid
## sizes. A cluster's cell count scales as roughly r^1.7 while an upscale only doubles its node count, so
## every round has to ADD about as many nodes as it inherited -- a flat budget starves the fine rounds and
## the massif never reaches its loop.
##
## Derived rather than authored, so that changing either control holds the DENSITY and only changes the
## thing it names. The scaling is not a guess: box-counting a cluster of radius R at the branch spacing s
## gives (R/s)^1.7 occupied boxes carrying about s cells of branch each, so the cell count goes as
## R^1.7 * s^-0.7, and with s = detail_size * R that is LINEAR IN R and detail_size^-0.7.
##
## The first version used ^1.7 on both, which is the exponent for the cluster's MASS rather than for the
## budget that builds it, and it starved the coarse end badly enough to be visible: at detail 0.30 the
## cluster reached 71 % of its allowed radius and the mountain came out small when only its texture was
## supposed to change.
##
## On an elongated loop it is the LONG semi-axis that goes in, and that is the same law rather than an
## exception to it. The branch spacing is set by the short axis (see `_blur_budget`), so an A x B massif
## is A/B blobs of radius B laid end to end, and cells = area / spacing = A*B / (d*B) = A/d — the same
## count a circle of radius A would need, and identical to the old expression when A = B.
func _particles() -> int:
	var e := _grow_extent(_grid_size())
	var r := maxf(e.x, e.y)
	var ref_r := REF_COVERAGE * 0.5 * float(REF_RESOLUTION) * (1.0 - REF_BLUR_SHARE)
	return clampi(int(float(REF_PARTICLES) * (r / ref_r) * pow(REF_DETAIL / detail_size, 0.7)), 64, 24000)


## THREE OUTCOMES, and which one this is depends on `evaluation` and on what is already held:
##
##   * nothing grown yet — grow, here or on the host's worker, and emit nothing until it lands;
##   * LIVE and something moved — regrow, but keep emitting the old mountain meanwhile so it does not
##     blink out of the viewport for the pass in between;
##   * FROZEN and something moved — emit what is held and say it is stale. This is the case the whole
##     mechanism exists for, and it is one rule: EVERY input is covered by it, because the key is a hash
##     of all of them rather than a list of the ones somebody remembered to check.
func _build() -> void:
	# Seeding on and nothing handed over yet: emit NOTHING rather than grow an unseeded mountain the next
	# bake would throw away. The brush warns, captures the surface on this bake, and comes straight back.
	if ridge_seeding and _seed.is_empty():
		return
	var want := _growth_key()
	if want != _dla_key or _dla_field.is_empty():
		if evaluation == Evaluation.LIVE or _dla_field.is_empty():
			if _growth_deferred:
				_pending_grow = true
			else:
				_grow_field()
		else:
			_mark_stale()
	if _dla_field.is_empty():
		return
	_emit(Op.DLA, Blend.ADD, [1.0, _bake_field(_crop(_dla_field, _dla_n, _dla_dims.x, _dla_dims.y),
			_dla_dims.x, _dla_dims.y)])


## True when this material is waiting on the host to hand it a surface to seed from. The host asks before
## every bake, and captures only when something says yes — so an unseeded DLA costs nothing.
func wants_seed_surface() -> bool:
	return ridge_seeding


## Hand over the surface the modifiers above this one produced. Returns true when it DIFFERS from the one
## already held, which is the host's signal that the field has to be regrown and the bake repeated.
##
## Hashing the grid rather than tracking what fed it is the same decision `brush_mod_erosion_key` makes
## for a frozen solve, for the same reason: the spline, the shape properties and every modifier above are
## all in the grid, and none of them can move without moving this.
func set_seed_surface(p_surface: Dictionary) -> bool:
	var g: PackedFloat32Array = p_surface.get("surface", PackedFloat32Array())
	var h := 0
	if not g.is_empty():
		h = hash(g) ^ (hash(p_surface.get("gw", 0)) * 31) ^ (hash(p_surface.get("frame", [])) * 131)
	if h == _seed_hash:
		return false
	_seed = p_surface
	_seed_hash = h
	# FROZEN and already grown: KEEP THE SURFACE, do not regrow, and do not ask for another bake.
	#
	# This is the freeze the whole change is about. The captured surface moves whenever anything on the
	# brush does — including translating the node, which changes nothing else about the mountain — so a
	# seeded DLA answered `true` on every bake of every drag, regrew a 512² cluster to do it, and got a
	# second bake scheduled for its trouble. Two regrows per frame. The surface is still taken, so Bake
	# Mountain grows from what is on the brush NOW rather than from whatever it last happened to see.
	if evaluation == Evaluation.FROZEN and not _dla_field.is_empty():
		_mark_stale()
		return false
	_touch()
	return true


## Everything the grown cluster depends on, in one string. A HASH OF THE INPUTS rather than a list of
## which edits count as a change, for the same reason `brush_mod_erosion_key` hashes the solver's input
## grid: it is complete by construction, and nothing can be forgotten out of it later.
##
## The field dimensions are a growth input like any other — the envelope is derived from them, so two
## loops of different shape are two different mountains. `strength`, `blend`, `selector` and
## `output_curve` are deliberately NOT in here: they invalidate the compiled program and none of them
## moves a single cell of the cluster.
func _growth_key() -> String:
	var d := _field_dims()
	return "%d|%d|%d|%.4f|%.4f|%d|%.4f|%.4f|%.4f|%d|%.4f|%d|%d|%d" % [seed, resolution,
			hierarchy_levels, detail_size, wander, blur_levels, blur_growth, profile_power, coverage,
			1 if ridge_seeding else 0, ridge_amount, _seed_hash, d.x, d.y]


## Grow the cluster and take the result, on whichever thread called. The synchronous path: what every
## host without a deferred driver gets (the Plow, a headless gate), and what this material always did.
func _grow_field() -> void:
	var st := {}
	grow_into(st)
	store_growth(st)


## ---- The growth protocol (Pasture3DReliefMaterial's four hooks) ------------------------------------


## The host offering to grow this off the main thread for the bake in flight. See the base class.
##
## Reports a change only when the ANSWER changes the compiled program. A material that is holding a field
## and has nothing outstanding emits the same bytes either way, and saying "yes I moved" there would put
## a recompile and a re-splice through every enclosing stack on both passes of every deferred bake.
##
## `_growth_landed` is why this is not simply `_pending_grow`: after the worker's field is stored, this
## material's own `_dirty` is already set, but the STACK holding it has copied the empty program pass 1
## produced and has no other way to hear that the bytes underneath it moved.
func set_growth_deferred(p_deferred: bool) -> bool:
	# A landed field is reported whether or not the FLAG moved. The driver's growth loop bakes twice with
	# deferral still on — grow, then bake again to see whether that produced more work — and on that
	# second bake the flag has not changed. Reporting nothing there leaves the enclosing stack splicing
	# the empty program the first bake produced, which is a stacked DLA painting nothing at all.
	var moved := _growth_landed
	_growth_landed = false
	if _growth_deferred != p_deferred:
		_growth_deferred = p_deferred
		if _pending_grow or _dla_field.is_empty():
			moved = true
	if moved:
		_dirty = true
	return moved


func has_growth() -> bool:
	return true


func collect_growth(p_out: Array) -> void:
	if _pending_grow:
		p_out.append(self)


## RUNS ON A POOL THREAD. Grows the cluster into `p_state` and writes NOTHING back to this material —
## the same discipline `_erosion_solve_one` keeps, and for the same reason: the main thread is yielding
## frames while this runs, and an inspector redraw or a mask preview can compile this material on any one
## of them. A half-replaced `_dla_field` read by a compile is a crash, not a wrong mountain.
##
## It does READ this material's properties, and the main thread could move one mid-grow. That is benign
## and self-correcting: the key was taken before the growth started, so a field grown against a moved
## slider is stored under a key that no longer matches and the next bake reports it stale.
func grow_into(p_state: Dictionary) -> void:
	# Taken HERE, before the first particle walks, so that a property moved while this runs produces a
	# field stored under a key that no longer matches — reported stale on the next bake — rather than one
	# quietly filed as current.
	p_state["key"] = _growth_key()
	var rng := RandomNumberGenerator.new()
	# Seeded, never randomize(): the field is part of the compiled program, so two bakes of one saved
	# resource have to be bitwise identical or every re-bake would move the mountain. Gate CP.
	rng.seed = seed
	var res := _grid_size()
	var n0 := maxi(res >> (hierarchy_levels - 1), 16)
	var cluster := _grow(rng, n0, res)
	p_state["field"] = _mass(_rasterise(cluster, res), res)
	p_state["n"] = res
	p_state["dims"] = _field_dims()


## MAIN THREAD. Take what `grow_into` built. Split from it so nothing but this line ever writes the
## material's own arrays, whichever thread the growth ran on.
func store_growth(p_state: Dictionary) -> void:
	_dla_field = p_state["field"]
	_dla_n = int(p_state["n"])
	_dla_dims = p_state["dims"]
	_dla_key = String(p_state["key"])
	_pending_grow = false
	_stale = false
	_growth_landed = true
	_dirty = true


## Called on a worker by the host, one material at a time. The pair above, in the order a driver wants
## them — kept here so a host never has to know that `grow_into` is the half that may not touch anything.
func grow_now() -> void:
	_grow_field()


## Drop the grown mountain so the next bake grows a new one. THE BAKE BUTTON.
##
## Nothing here is saved with the resource, so this is the whole cache: reopening a scene regrows once,
## in the background, and the alternative is a megabyte of float field inside every .tres that references
## the material. Same trade Pasture3DNodeErosion makes, and for the same reason — the mountain the user is
## looking at is already persisted, in the terrain's layer data.
func clear_growth() -> int:
	if _dla_field.is_empty() and not _stale:
		return 0
	_dla_field = PackedFloat32Array()
	_dla_dims = Vector2i.ZERO
	_dla_n = 0
	_dla_key = ""
	_stale = false
	_touch()
	return 1


func growth_bytes() -> int:
	return _dla_field.size() * 4


## The Bake Mountain button. `clear_growth` answers with a count that a tool button has nowhere to put.
func bake_mountain() -> void:
	clear_growth()


## Record that the held mountain no longer matches its inputs.
##
## Deliberately NOT `_touch()`: every caller runs DURING a bake, and `_touch` emits `changed`, which the
## brush re-bakes on. The deferred emit on the FALSE->TRUE edge only is what puts the warning in the
## inspector without turning a reshape drag into one re-bake per frame — the flag stays true for the rest
## of the drag, so the edge fires once. Mirrors Pasture3DNodeErosion.set_stale.
func _mark_stale() -> void:
	if _stale:
		return
	_stale = true
	if Engine.is_editor_hint():
		emit_changed.call_deferred()


## Cut the loop's own rectangle out of the square working grid. Exactly centred, because `_field_dims`
## keeps both dimensions even — and cutting rather than resampling is what keeps the field's cells the
## same square metres the cluster was grown on, which is the entire point of the exercise.
##
## Nothing is lost: the massif is confined to the ellipse inscribed in this crop, and the blur budget is
## what guarantees it stays there after widening.
func _crop(g: PackedFloat32Array, n: int, w: int, h: int) -> PackedFloat32Array:
	if w >= n and h >= n:
		return g
	var x0 := (n - w) / 2
	var y0 := (n - h) / 2
	var out := PackedFloat32Array()
	for y in range(h):
		var src := (y0 + y) * n + x0
		out.append_array(g.slice(src, src + w))
	return out


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
	var xs := PackedFloat32Array()
	var ys := PackedFloat32Array()
	var parents := PackedInt32Array()
	# `owner[cell]` is the node index that put material in that cell, which is how a stuck particle finds
	# out what it stuck TO. -1 is empty.
	var owner := PackedInt32Array()
	owner.resize(n * n)
	owner.fill(-1)
	# The starting skeleton: the ridges the host handed over, or a single point in the middle. Seeded, the
	# cluster is a FOREST rather than a tree -- separate crest lines have no reason to be connected, and
	# nothing downstream needs them to be (a parentless node rasterises as a point and is skipped by the
	# upscale's midpoint pass).
	var seeded := _seed_ridges(n, xs, ys, parents, owner)
	if not seeded:
		xs.append(float(n) * 0.5)
		ys.append(float(n) * 0.5)
		parents.append(-1)
		owner[int(n * 0.5) * n + int(n * 0.5)] = 0

	var level := 0
	while true:
		# The reach allowed at THIS level, ramped so every level has somewhere to grow. An upscale
		# doubles the cluster AND the grid, so a fixed fraction would leave the cluster already at its
		# limit the moment the grid doubled -- which is exactly what an earlier version did, and it grew
		# 33 nodes at level 0 and then nothing at all for five rounds. Coarse levels decide the trunk
		# inside a smaller disc; the last level is the one that reaches GROW_EXTENT.
		_grow_level(rng, n, lerpf(0.7, 1.0, float(level) / float(maxi(rounds, 1))),
				maxi(24, _particles() * n / p_res), xs, ys, parents, owner)
		if n >= p_res:
			break
		n *= 2
		level += 1
		owner = _upscale(rng, n, xs, ys, parents)
		# Re-seed at every scale, not only the coarsest. Seeding once at level 0 puts the ridge lines on a
		# 32-cell grid where five arms are a few pixels wide, and three upscales plus a few thousand
		# particles bury them: measured, a star-shaped seed and no seed at all produced fields that
		# correlated with the star to 0.53 and 0.51 -- the seed was doing nothing. Re-reading the surface at
		# each level is what makes the finest branches follow the finest ridges.
		if seeded:
			_seed_ridges(n, xs, ys, parents, owner)
	return [xs, ys, parents]


## Place the starting cluster on the ridge lines of the captured surface. False when there is no surface,
## or nothing in it reads as a ridge, and the caller falls back to a single central seed.
##
## The measure is the negative Laplacian — how far a cell stands above the mean of its four neighbours —
## which is positive on a crest and negative in a valley. Thresholded by QUANTILE rather than by a height,
## because the surfaces this runs on differ by orders of magnitude in relief (a roughed-in fractal, an
## eroded landform, a bare dome) and a fixed threshold would seed everything on one and nothing on the
## next.
func _seed_ridges(n: int, xs: PackedFloat32Array, ys: PackedFloat32Array, parents: PackedInt32Array,
		owner: PackedInt32Array) -> bool:
	if not ridge_seeding or _seed.is_empty():
		return false
	var h := _sample_seed(n)
	if h.is_empty():
		return false
	var c := float(n) * 0.5
	var limit := _grow_extent(n)
	var ridge := PackedFloat32Array()
	ridge.resize(n * n)
	ridge.fill(-INF)
	var live := PackedFloat32Array()
	for y in range(1, n - 1):
		for x in range(1, n - 1):
			if _rho(float(x) - c, float(y) - c, limit) > 1.0:
				continue
			var i := y * n + x
			var v := h[i]
			if not is_finite(v):
				continue
			var ring := 0.0
			var k := 0
			for d in [-1, 1, -n, n]:
				var nv := h[i + d]
				if is_finite(nv):
					ring += nv
					k += 1
			if k == 0:
				continue
			ridge[i] = v - ring / float(k)
			live.append(ridge[i])
	if live.size() < 16:
		return false
	live.sort()
	# A crest has to actually STAND UP. On a surface with no relief at all the quantile still returns a
	# number, and without this the material would seed a ring of numerical noise and call it a ridge.
	var cut: float = live[clampi(int(float(live.size()) * (1.0 - ridge_amount)), 0, live.size() - 1)]
	if cut <= 0.0:
		return false
	for y in range(1, n - 1):
		for x in range(1, n - 1):
			var i := y * n + x
			if ridge[i] < cut:
				continue
			if owner[i] >= 0:
				continue # already cluster, from the upscale of a coarser level
			owner[i] = xs.size()
			xs.append(float(x))
			ys.append(float(y))
			parents.append(-1)
	return not xs.is_empty()


## The captured surface resampled onto the level-0 grid, through the LOOP FRAME rather than by a plain
## rescale: the bake grid is the spline's axis-aligned bounding box while the field is the loop's ORIENTED
## rectangle, and on a rotated loop those are different squares. NaN outside the brush, which the ridge
## measure skips.
##
## Read over the SQUARE the working grid covers — side 2 * max(ex, ez) — and not over the loop's
## rectangle, because that square is what the grid's cells are. The corners of it that stick out past the
## loop are sampled too and are simply never seeded from: the ridge search is confined to the envelope,
## which is inside the rectangle by construction.
func _sample_seed(n: int) -> PackedFloat32Array:
	var g: PackedFloat32Array = _seed.get("surface", PackedFloat32Array())
	var gw: int = _seed.get("gw", 0)
	var gh: int = _seed.get("gh", 0)
	var frame: Array = _seed.get("frame", [])
	if g.size() != gw * gh or gw < 2 or gh < 2 or frame.size() < 9:
		return PackedFloat32Array()
	var cx: float = frame[0]
	var cz: float = frame[1]
	var fcos: float = frame[2]
	var fsin: float = frame[3]
	var ex: float = frame[4]
	var ez: float = frame[5]
	var min_x: float = frame[6]
	var min_z: float = frame[7]
	var vs: float = frame[8]
	if vs <= 0.0:
		return PackedFloat32Array()
	var side: float = maxf(ex, ez)
	var out := PackedFloat32Array()
	out.resize(n * n)
	for y in range(n):
		var nv := (float(y) / float(n - 1)) * 2.0 - 1.0
		for x in range(n):
			var nu := (float(x) / float(n - 1)) * 2.0 - 1.0
			# loop-local metres, then back out to world through the frame's rotation
			var lx := nu * side
			var lz := nv * side
			var wx := cx + lx * fcos - lz * fsin
			var wz := cz + lx * fsin + lz * fcos
			out[y * n + x] = _bilinear(g, gw, gh, (wx - min_x) / vs, (wz - min_z) / vs)
	return out


## Bilinear read with NaN propagation: a cell whose neighbourhood is partly outside the brush must read
## NaN, not a value averaged against nothing.
func _bilinear(g: PackedFloat32Array, gw: int, gh: int, fx: float, fy: float) -> float:
	if fx < 0.0 or fy < 0.0 or fx > float(gw - 1) or fy > float(gh - 1):
		return NAN
	var x0 := int(fx)
	var y0 := int(fy)
	var x1 := mini(x0 + 1, gw - 1)
	var y1 := mini(y0 + 1, gh - 1)
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var a := g[y0 * gw + x0]
	var b := g[y0 * gw + x1]
	var cc := g[y1 * gw + x0]
	var d := g[y1 * gw + x1]
	if not (is_finite(a) and is_finite(b) and is_finite(cc) and is_finite(d)):
		return NAN
	return (a * (1.0 - tx) + b * tx) * (1.0 - ty) + (cc * (1.0 - tx) + d * tx) * ty


## One round of aggregation on an n x n grid, capped at `p_frac` of the level's allowed reach.
##
## Particles launch within the cluster's own reach, never from the grid edge: a walk in from the edge is
## quadratic in the empty gap and is where a naive DLA spends all of its time, for no difference at all in
## the result.
##
## `reach`, `limit` and `kill` are all in ENVELOPE units (see `_rho`) rather than in cells, so the one
## thing the loop's shape changes is where the boundary is — not how the walk behaves on the way to it.
## The two fixed margins that were in cells stay in cells, converted through the SHORT semi-axis so that
## "three cells past the current reach" is still three cells on the axis where three cells is the most.
func _grow_level(rng: RandomNumberGenerator, n: int, p_frac: float, p_particles: int,
		xs: PackedFloat32Array, ys: PackedFloat32Array, parents: PackedInt32Array,
		owner: PackedInt32Array) -> void:
	var c := float(n) * 0.5
	var env := _grow_extent(n)
	var limit := p_frac
	var per_cell := 1.0 / maxf(minf(env.x, env.y), 1.0)
	var reach := per_cell
	for i in range(xs.size()):
		reach = maxf(reach, _rho(xs[i] - c, ys[i] - c, env))
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
		#
		# The interior draw is `sqrt(u)`, which is uniform over the DISC. Drawing the radius uniformly
		# instead over-weights the middle by 1/r, and measured, that is what kept the massif at 0.67 of a
		# loop it was allowed 0.96 of: the mass piled into the centre, the mean node sat at 0.23 of the
		# half-extent, and raising `particles` fourfold bought 0.05.
		# Reaching the limit comes FIRST and the fill takes what is left. A flat 50/50 ties the cluster's
		# reach to its particle count, and that count now follows `detail_size` -- so a coarse setting spent
		# its whole budget without ever arriving, and the mountain came out small when only its texture was
		# supposed to change. Capped at 70% of the budget so a limit that cannot be reached at all still
		# leaves something to fill the middle with, rather than starving it into a hollow ring.
		var growing := reach < limit and pi * 10 < p_particles * 7
		var launch: float = minf(reach + 3.0 * per_cell, limit) * (
				1.0 if (growing or (pi & 1) == 0) else sqrt(rng.randf()))
		# Uniform in the ANGLE and then scaled onto the envelope's two semi-axes, which looks like the
		# sampling bug it is not: for an ellipse that parametrisation is exactly the harmonic measure —
		# where a random walker released at infinity actually arrives — so it is the launch distribution
		# a DLA is supposed to have, and the circle case is the special case of it. Correcting it to
		# uniform arc length would UNDER-feed the tips of an elongated massif.
		var ang := rng.randf() * TAU
		var px := int(round(c + cos(ang) * launch * env.x))
		var py := int(round(c + sin(ang) * launch * env.y))
		var kill := limit + 6.0 * per_cell
		var stuck := -1
		for _s in range(budget):
			if px < 1 or py < 1 or px >= n - 1 or py >= n - 1:
				break
			if _rho(float(px) - c, float(py) - c, env) > kill:
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
		if _rho(float(px) - c, float(py) - c, env) > limit:
			continue
		var id := xs.size()
		xs.append(float(px))
		ys.append(float(py))
		parents.append(stuck)
		owner[py * n + px] = id
		reach = maxf(reach, _rho(float(px) - c, float(py) - c, env))


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


## Doubling radii whose TOTAL is capped at the blur's share of `coverage`. The cap is the invariant that
## keeps the massif inside the field: the cluster reaches `_grow_extent` and the blur can push material at
## most `_blur_budget` further, so everything outside `coverage` of the half-extent is still exactly zero
## and the material fades out inside its own loop rather than being cut off at the edge.
##
## Levels are DROPPED, not shrunk, when the budget runs out: the smallest useful radius is 1 cell, so on a
## small grid the widest levels are simply not affordable. Keeping them by clamping r0 to 1 would break the
## invariant instead of the level count, which is the wrong thing to give up - a mountain with one fewer
## scale of massing still fades out inside its loop.
func _blur_radii(n: int) -> PackedInt32Array:
	var budget := _blur_budget(n)
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


## How many grow-then-upscale rounds this resolution can actually run: the coarsest grid is floored at 16
## cells, so past that a further round halves nothing.
func _effective_levels() -> int:
	var n := _grid_size()
	var rounds := 1
	while (n >> rounds) >= 16 and rounds < hierarchy_levels:
		rounds += 1
	return rounds


func _configuration_warning() -> String:
	if _stale:
		return ("Relief DLA is FROZEN and something it is grown from has changed, so the terrain is "
			+ "showing the mountain it grew for the OLD settings. Press Bake Mountain to regrow it, or "
			+ "set Evaluation to Live.")
	if hierarchy_levels > _effective_levels():
		return (("Relief DLA is set to %d hierarchy levels but a %d² grid can only run %d — the coarsest "
			+ "grid bottoms out at 16 cells. Raise Resolution, or lower Hierarchy Levels to %d.")
			% [hierarchy_levels, _grid_size(), _effective_levels(), _effective_levels()])
	if ridge_seeding and _seed.is_empty():
		return ("Relief DLA is seeding from the brush's ridges but has not been handed a surface yet. "
			+ "It stamps nothing until the next bake, which the brush schedules itself.")
	# Branch spacing measured in CELLS, not in fractions: below about two cells apart the grid cannot hold
	# the branches separately and the detail control silently stops doing anything. Measured on the SHORT
	# semi-axis, which is the one the blur is sized from and therefore the one that runs out first.
	var e := _grow_extent(_grid_size())
	var spacing := detail_size * minf(e.x, e.y)
	if spacing < 2.0:
		return (("Relief DLA's ridges would be %.1f cells apart at this Resolution, which the working grid "
			+ "cannot resolve. Raise Resolution, raise Detail Size, or raise Coverage.") % spacing)
	# The field is grown to the LOOP'S OWN proportions so the ridges come out the same size in both
	# directions (see _field_dims). Past about `resolution / FIELD_MIN` : 1 there is no short side left to
	# grow a massif on, and the honest fix is more Resolution rather than a squashed mountain.
	var d := _field_dims()
	if mini(d.x, d.y) <= FIELD_MIN and maxf(_host_ex, _host_ez) / minf(_host_ex, _host_ez) > 1.5:
		return (("Relief DLA is on a loop about %.0f:1, which at Resolution %d leaves only %d cells across "
			+ "its short side. Raise Resolution, or draw a less elongated loop.")
			% [maxf(_host_ex, _host_ez) / minf(_host_ex, _host_ez), _grid_size(), mini(d.x, d.y)])
	return ""
