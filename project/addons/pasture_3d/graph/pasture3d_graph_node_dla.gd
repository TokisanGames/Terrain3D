# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDLA — a mountain grown by diffusion-limited aggregation, as a graph-native SOLVER.
# Particles random-walk until they stick to a branching cluster; blurring that skeleton at doubling radii
# and summing turns it into a massif of major ridges and minor spurs. A ridge network is the topological
# dual of a drainage network, so a DLA massif lands on the same branching statistics erosion produces
# WITHOUT simulating water — which is why `Input → DLA → Erosion` reinforces rather than fights.
#
# ---- Why this composes Pasture3DReliefDLA instead of reimplementing it ----
#
# The growth is ~600 lines of delicately tuned GDScript with a documented history of six growth bugs that
# each produced a *plausible* field. It lives on `Pasture3DReliefDLA` and its `grow_into(state)` hook grows
# the cluster into a state Dictionary and touches nothing on the material. This node OWNS a configured
# engine instance and drives that hook, so the entire growth path is reused byte-for-byte and only the thin
# adapter here is new: mirror the params, hand the engine the loop frame + optional seed surface, and sample
# its grown field onto the output grid. (Per the DLA design note: a DLA needs a grid at COMPILE time only
# and is a point operator where it counts — so it is a graph node, never a brush modifier.)
#
# ---- Two outputs ----
#
#   port 0  "height"  HEIGHT  the massif, in metres (amplitude · normalised field)
#   port 1  "mask"    MASK    the normalised field itself [0,1] — the mountain's footprint/intensity, for a
#                             downstream Blend that stamps rock detail only on the massif.
#
# ---- Optional seed input (what makes it a SOLVER, not a bare Generator) ----
#
# With Ridge Seeding on, the wired input field is the surface the cluster grows OUT OF: its crest lines
# become the starting skeleton, so `Input → Erosion → DLA` grows the ridge network along what erosion
# actually cut. Unwired (or seeding off) it grows from a single central seed — a pure generator.
#
# ---- Per-solver freeze (defaults to FROZEN) ----
#
# Growing a cluster is seconds of GDScript; re-running it on every evaluation is unusable, so this node
# defaults to FROZEN with the same per-solver cache/stale/Bake as Erosion. In memory only.
@tool
class_name Pasture3DGraphNodeDLA
extends Pasture3DGraphNode

const ReliefDLA = preload("res://addons/pasture_3d/connectors/pasture3d_relief_dla.gd")

enum Evaluation { LIVE, FROZEN }

## The massif's height, in metres — the amplitude of the finished mountain. The grown field is normalised
## [0,1], so this is a straight multiplier on it.
@export_range(0.0, 4000.0, 1.0, "or_greater") var amplitude: float = 400.0:
	set(v):
		amplitude = maxf(v, 0.0)
		_param_changed()

@export_group("Shape")
## Outer radius as a fraction of the rect's half-extent: 1.0 reaches the edge, 0.5 sits in the middle with
## clear ground around it. The SIZE control — the cluster and the blur that widens it both derive from it.
@export_range(0.2, 1.0, 0.01) var coverage: float = 0.95:
	set(v):
		coverage = clampf(v, 0.2, 1.0)
		_param_changed()
## Ridge spacing as a fraction of the massif's radius — small is a finely divided massif of thin spurs,
## large a few broad arms. Independent of `coverage`: sizing the mountain does not restyle it.
@export_range(0.03, 0.50, 0.005) var detail_size: float = 0.12:
	set(v):
		detail_size = clampf(v, 0.03, 0.50)
		_param_changed()
## Remap on the normalised field: 1 linear, above 1 pulls the flanks down and sharpens the summit, below 1
## fattens toward a plateau.
@export_range(0.25, 4.0, 0.05) var profile_power: float = 1.0:
	set(v):
		profile_power = clampf(v, 0.25, 4.0)
		_param_changed()
@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

@export_group("Growth")
## Widest working grid the cluster is grown on, in cells. Only powers of two do anything; the final blur
## dominates how it reads, so resolution beyond the output grid buys little. 512² ≈ 2 s to grow.
@export_enum("64:64", "128:128", "256:256", "512:512", "1024:1024") var resolution: int = 256:
	set(v):
		resolution = clampi(v, 64, 1024)
		_param_changed()
## How many grow-then-upscale rounds — the number of ridge SCALES, not a quality knob. Capped by
## `resolution` (the coarsest grid floors at 16 cells).
@export_range(1, 8) var hierarchy_levels: int = 4:
	set(v):
		hierarchy_levels = clampi(v, 1, 8)
		_param_changed()
## Sideways throw of an inserted midpoint when the grid doubles, as a fraction of the branch length. 0 keeps
## the cluster axis-aligned; ~0.3 reads as a ridge.
@export_range(0.0, 1.0, 0.01) var wander: float = 0.32:
	set(v):
		wander = clampf(v, 0.0, 1.0)
		_param_changed()

@export_group("Massing")
## How many times the skeleton is blurred and summed — the number of scales the massif is built from.
@export_range(1, 7) var blur_levels: int = 5:
	set(v):
		blur_levels = clampi(v, 1, 7)
		_param_changed()
## Weight ratio between one blur level and the next-wider. Above 1 the broad blurs carry the mass (a
## MOUNTAIN with ridges); below 1 the sharp skeleton dominates (a bare ridge network).
@export_range(0.25, 4.0, 0.05) var blur_growth: float = 1.6:
	set(v):
		blur_growth = clampf(v, 0.25, 4.0)
		_param_changed()

@export_group("Ridge Seeding")
## Grow the cluster OUT OF the ridges in the wired input field instead of from a single central point. The
## crest lines of the input become the starting skeleton — the `Erosion → DLA` workflow. Needs an input.
@export var ridge_seeding: bool = false:
	set(v):
		ridge_seeding = v
		_param_changed()
## What fraction of the cells inside the mountain count as ridge — small picks only the sharpest crests.
@export_range(0.01, 0.30, 0.005) var ridge_amount: float = 0.05:
	set(v):
		ridge_amount = clampf(v, 0.01, 0.30)
		_param_changed()

@export_group("Evaluation")
## FROZEN (the default) grows once and serves the cache until Bake Mountain, raising a stale warning when a
## growth input changed. Growth is expensive; LIVE regrows on EVERY evaluation and is only for a small
## Resolution where a regrow is cheap enough to watch.
@export var evaluation: Evaluation = Evaluation.FROZEN:
	set(v):
		evaluation = v
		emit_changed()

@export_tool_button("Bake Mountain") var _bake_btn = clear_cache

# ---- Runtime freeze state (not serialised — the caches rebuild on demand) ----
var _cache: Dictionary = {}        # input-hash -> [height, mask]
var _cache_key: int = 0
var _dirty_since_bake: bool = false
var _stale: bool = false


func op() -> StringName:
	return &"dla"


func role() -> Role:
	return Role.SOLVER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["seed"])


func output_count() -> int:
	return 2


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "mask"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK])


## Drop the grown mountain so the next evaluation regrows. The explicit Bake.
func clear_cache() -> void:
	if _cache.is_empty() and not _stale and not _dirty_since_bake:
		return
	_cache.clear()
	_dirty_since_bake = false
	_stale = false
	emit_changed()


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if _stale:
		w.append("%s is FROZEN and a growth input changed since the bake — it is showing the mountain it "
			% display_name() + "grew for the old settings. Press Bake Mountain to regrow.")
	if amplitude <= 0.0:
		w.append("%s has zero amplitude, so it deposits no height." % display_name())
	return w


## Two channels: [0] massif height (metres), [1] normalised field [0,1]. Applies the per-solver freeze.
func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if p_inputs.size() > 0 \
			else Pasture3DGraphOps.zeros(n)
	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)

	if evaluation == Evaluation.FROZEN:
		var key := _surface_hash(surface, p_gw, p_gh)
		if not _cache.is_empty():
			if _dirty_since_bake or key != _cache_key:
				_set_stale(true)
			return _cache[_cache_key]
		var solved := _solve(surface, p_gw, p_gh, p_rect)
		_cache = {}
		_cache_key = key
		_cache[key] = solved
		_dirty_since_bake = false
		_set_stale(false)
		return solved

	# LIVE
	if not _cache.is_empty():
		_cache.clear()
	_set_stale(false)
	return _solve(surface, p_gw, p_gh, p_rect)


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


# ---- Internals -------------------------------------------------------------------------------------

func _param_changed() -> void:
	if not _cache.is_empty():
		_dirty_since_bake = true
	emit_changed()


func _set_stale(p_stale: bool) -> void:
	if _stale == p_stale:
		return
	_stale = p_stale
	if Engine.is_editor_hint():
		emit_changed.call_deferred()


## Grow the cluster and sample the field onto the output grid. The growth itself runs on a configured
## Pasture3DReliefDLA through its `grow_into` hook (which writes only into a state Dictionary), so nothing
## in the tuned growth path is duplicated here. The field is normalised [0,1] and stretched once over the
## whole rect, exactly as the relief samplers do. A NaN in a wired input passes through as NaN height / 0
## mask — the brush-loop boundary is where the mountain stops.
func _solve(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var engine := _make_engine(p_surface, p_gw, p_gh, p_rect)
	var state := {}
	engine.grow_into(state)
	var field: PackedFloat32Array = state.get("field", PackedFloat32Array())
	var grown_n: int = int(state.get("n", 0))
	var dims: Vector2i = state.get("dims", Vector2i.ZERO)
	var height := PackedFloat32Array(); height.resize(n)
	var mask := PackedFloat32Array(); mask.resize(n)
	if field.is_empty() or grown_n <= 0 or dims.x <= 0 or dims.y <= 0:
		# Growth produced nothing (e.g. degenerate params): a flat zero massif is the honest empty result.
		return [height, mask]
	# Crop the square working field to the loop's own rectangle (the relief material's own crop), then
	# stretch that w×h field over the whole rect.
	var cropped: PackedFloat32Array = engine._crop(field, grown_n, dims.x, dims.y)
	var w := dims.x
	var h := dims.y
	var input_wired := _is_input_wired(p_surface)
	for iz in range(p_gh):
		var row := iz * p_gw
		var v := (float(iz) + 0.5) / float(p_gh)
		var fy := v * float(h - 1)
		for ix in range(p_gw):
			var i := row + ix
			if input_wired and is_nan(p_surface[i]):
				height[i] = NAN
				mask[i] = 0.0
				continue
			var u := (float(ix) + 0.5) / float(p_gw)
			var fx := u * float(w - 1)
			var s := _bilinear01(cropped, w, h, fx, fy)
			mask[i] = s
			height[i] = amplitude * s
	return [height, mask]


## A fresh Pasture3DReliefDLA configured to this node's params, its loop frame, and (when seeding) the
## input surface as the seed. Private fields are set directly rather than through the material's setters:
## the setters emit `changed` / set brush-dirty flags meant for the relief stack host, and this node is not
## that host — it only wants the growth. See the engine's own header for what each field means.
func _make_engine(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> Object:
	var e = ReliefDLA.new()
	e.coverage = coverage
	e.resolution = resolution
	e.hierarchy_levels = hierarchy_levels
	e.detail_size = detail_size
	e.wander = wander
	e.seed = seed
	e.blur_levels = blur_levels
	e.blur_growth = blur_growth
	e.profile_power = profile_power
	e.ridge_seeding = ridge_seeding
	e.ridge_amount = ridge_amount
	# The loop's half-extents drive the field's aspect (the engine crops the square grid to this ratio).
	e._host_ex = maxf(p_rect.size.x * 0.5, 0.001)
	e._host_ez = maxf(p_rect.size.y * 0.5, 0.001)
	# Seed surface: only when seeding AND an input is actually wired. The engine samples it through a frame
	# that maps loop-local metres back to grid indices; our grid is axis-aligned over the rect with square
	# cells, so cos/sin are 1/0 and vs is the cell size. min_x/min_z carry the half-cell so a world point at
	# a cell centre lands on an integer index (the engine's _bilinear reads cell centres at integers).
	if ridge_seeding and _is_input_wired(p_surface):
		var dx := p_rect.size.x / float(maxi(p_gw, 1))
		var dz := p_rect.size.y / float(maxi(p_gh, 1))
		var ex := p_rect.size.x * 0.5
		var ez := p_rect.size.y * 0.5
		var frame := [p_rect.position.x + ex, p_rect.position.y + ez, 1.0, 0.0, ex, ez,
				p_rect.position.x + 0.5 * dx, p_rect.position.y + 0.5 * dz, dx]
		e._seed = {"surface": p_surface, "gw": p_gw, "gh": p_gh, "frame": frame}
		e._seed_hash = hash(p_surface) ^ (hash(p_gw) * 31)
	return e


## Whether the input field is actually connected: an unwired HEIGHT input reads the all-zero default, and a
## flat-zero surface is not a seed. Any NaN (a brush loop) or any non-zero value means a real input.
func _is_input_wired(p_surface: PackedFloat32Array) -> bool:
	for v in p_surface:
		if v != 0.0:
			return true
	return false


## Bilinear read of a [0,1] field with clamped edges. The field carries no NaN (it is 0 outside the massif),
## so no propagation is needed.
func _bilinear01(g: PackedFloat32Array, w: int, h: int, fx: float, fy: float) -> float:
	var x0 := clampi(int(fx), 0, w - 1)
	var y0 := clampi(int(fy), 0, h - 1)
	var x1 := mini(x0 + 1, w - 1)
	var y1 := mini(y0 + 1, h - 1)
	var tx := clampf(fx - float(x0), 0.0, 1.0)
	var ty := clampf(fy - float(y0), 0.0, 1.0)
	var a := g[y0 * w + x0]
	var b := g[y0 * w + x1]
	var c := g[y1 * w + x0]
	var d := g[y1 * w + x1]
	return (a * (1.0 - tx) + b * tx) * (1.0 - ty) + (c * (1.0 - tx) + d * tx) * ty


## A cheap order-sensitive hash of the surface, the freeze staleness key.
func _surface_hash(p_surface: PackedFloat32Array, p_gw: int, p_gh: int) -> int:
	var h := hash(p_gw) ^ (hash(p_gh) << 1)
	h = h ^ hash(p_surface)
	return h
