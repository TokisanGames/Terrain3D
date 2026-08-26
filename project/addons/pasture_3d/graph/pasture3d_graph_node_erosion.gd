# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeErosion — the stream-power fluvial SOLVER as a graph node. It routes water across its
# whole input field, incises channels, rounds ridges by hillslope diffusion, and (toward G=1) lays sediment
# back down. It is the SAME native `erosion_solve` the brush erosion modifier and Pasture3DSim run — one
# implementation, reached here through the Pasture3DUtil.erosion_solve_grid binding — so a value tuned on a
# Sim or a brush transfers by reading one inspector and typing into another. Being a whole-grid drainage
# solve, it is a grid node and can never fold into a per-cell run.
#
# ---- The five outputs (multi-output) ----
#
#   port 0  "height"      HEIGHT  the eroded surface (absolute metres) — the field the graph carries on with
#   port 1  "flow"        MASK    drainage area (m²): where water accumulates. Raw, unbounded — normalise or
#                                 log-scale downstream if you want a [0,1] mask out of it.
#   port 2  "erosion"     MASK    metres CUT this solve (positive) — for stamping scoured-rock detail
#   port 3  "deposition"  MASK    metres LAID DOWN this solve (positive) — alluvium, valley fill, fans
#   port 4  "wetness"     MASK    lake depth (metres): standing water in filled depressions
#
# The four derived channels match the units the brush erosion modifier publishes (see
# pasture_3d_brush_raster brush_mod_erode), so a graph that reads "erosion" reads the same field a brush
# stack would. The height channel is the primary output (port 0), served to single-output callers.
#
# ---- Per-solver freeze (defaults to FROZEN) ----
#
# A solve is the one operation in the graph expensive enough that re-running it on every evaluation is
# unusable — the same complaint the brush erosion modifier's freeze came from. So this node, unlike the cheap
# Scree solver, defaults to FROZEN: it solves once, caches the five channels keyed by a hash of the input
# surface, and thereafter serves the cache — flagging itself stale (a node warning) when the surface or its
# own params have changed since the bake — until Bake Erosion clears it. In memory only, like the modifier's
# cache: the baked heights already persist in the terrain's layer data, so the cache need not survive a
# reload.
@tool
class_name Pasture3DGraphNodeErosion
extends Pasture3DGraphNode

enum Evaluation { LIVE, FROZEN }

@export_group("Simulation")
## Solver iterations. Each one re-routes the drainage network over the current surface, so more iterations
## deepen valleys AND let the network reorganise, rather than only scaling the same cut.
@export_range(1, 200, 1, "or_greater") var iterations: int = 30:
	set(v):
		iterations = maxi(v, 1)
		_param_changed()
## K in the stream-power law: how fast channels incise per iteration. The single knob for "how eroded".
@export_range(0.0, 1.0, 0.001, "or_greater") var erosion_rate: float = 0.08:
	set(v):
		erosion_rate = maxf(v, 0.0)
		_param_changed()
## m, the drainage-area exponent. Higher concentrates cutting into the big channels; lower spreads it.
@export_range(0.0, 1.0, 0.01) var area_exponent: float = 0.45:
	set(v):
		area_exponent = clampf(v, 0.0, 1.0)
		_param_changed()
## Hillslope diffusion, m² per step — the soil-creep term that rounds ridges and fills the sharpest
## notches. 0 leaves a purely fluvial, knife-edged result.
@export_range(0.0, 10.0, 0.01, "or_greater") var hillslope_diffusion: float = 0.15:
	set(v):
		hillslope_diffusion = maxf(v, 0.0)
		_param_changed()
## G, the sediment deposition coefficient (Yuan et al. 2019). 0 is detachment-limited — material is removed
## and never put back. Toward 1 rivers lay their load down again, building alluvial fans and filling valley
## floors. NOT free: it makes each cell depend on its whole upstream catchment, so convergence degrades as
## G rises and the solver's sweep count is capped.
@export_range(0.0, 1.0, 0.01) var deposition: float = 0.0:
	set(v):
		deposition = clampf(v, 0.0, 1.0)
		_param_changed()

@export_group("Evaluation")
## FROZEN (the default) solves once and serves the cache until Bake Erosion, raising a stale warning when the
## surface or params changed since. A solve is expensive; LIVE re-solves on EVERY evaluation and is only for
## a small graph where a solve is cheap enough to watch.
@export var evaluation: Evaluation = Evaluation.FROZEN:
	set(v):
		evaluation = v
		emit_changed()

@export_tool_button("Bake Erosion") var _bake_btn = clear_cache

# ---- Runtime freeze state (not serialised — the caches rebuild on demand) ----
var _cache: Dictionary = {}        # input-hash -> [height, flow, ero, dep, wet]
var _cache_key: int = 0            # the input hash the cache was solved for
var _dirty_since_bake: bool = false
var _stale: bool = false


func op() -> StringName:
	return &"erosion"


func role() -> Role:
	return Role.SOLVER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["field"])


func output_count() -> int:
	return 5


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "flow", "erosion", "deposition", "wetness"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK, PortType.MASK, PortType.MASK, PortType.MASK])


## Drop the cached solve, so the next evaluation re-solves. This is the explicit Bake.
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
		w.append("%s is FROZEN and the surface or its parameters changed since the bake — it is showing "
			% display_name() + "the erosion it solved for the old shape. Press Bake Erosion to re-solve.")
	if evaluation == Evaluation.FROZEN and not _cache.is_empty():
		w.append("%s holds %.1f MB of frozen solve. Press Bake Erosion to re-solve it."
			% [display_name(), _cache_bytes() / 1048576.0])
	if is_zero_approx(erosion_rate) and is_zero_approx(hillslope_diffusion):
		w.append("%s: both Erosion Rate and Hillslope Diffusion are 0, so the solver routes water and "
			% display_name() + "changes nothing. Raise Erosion Rate to cut channels.")
	return w


## Five channels: [0] eroded height, [1] flow m², [2] erosion m, [3] deposition m, [4] wetness m. Applies
## the per-solver freeze.
func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if p_inputs.size() > 0 \
			else Pasture3DGraphOps.zeros(n)
	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)

	if evaluation == Evaluation.FROZEN:
		var key := _surface_hash(surface, p_gw, p_gh)
		if not _cache.is_empty():
			# Serve the cache; flag stale if anything moved since the bake, but do NOT re-solve.
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
	# Single-output callers (and the default lowering) get the primary eroded-height channel.
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
	# The warning list changed; refresh it without re-solving (this runs DURING a bake).
	if Engine.is_editor_hint():
		emit_changed.call_deferred()


## Run the native stream-power solve over `p_surface` and split it into the five channels. The grid maps onto
## `p_rect`, so the cell size handed to the solver is sqrt(dx*dz) — the side of a square with the true cell
## area, which is what the drainage-area term (cell_size²) needs. NaN in the surface (off a brush loop) is a
## no-data outlet and passes through as NaN in the height / 0 in every channel, handled by the binding.
func _solve(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var dx := p_rect.size.x / float(maxi(p_gw, 1))
	var dz := p_rect.size.y / float(maxi(p_gh, 1))
	var cell_size := sqrt(maxf(dx * dz, 1e-12))
	var params := {
		"iterations": iterations,
		"erosion_rate": erosion_rate,
		"area_exponent": area_exponent,
		"diffusion": hillslope_diffusion,
		"deposition": deposition,
	}
	var res: Dictionary = Pasture3DUtil.erosion_solve_grid(p_surface, p_gw, p_gh, cell_size, params,
			PackedFloat32Array())
	if res.is_empty() or not bool(res.get("ok", false)):
		# The solve failed or was refused (shape mismatch): pass the surface through untouched, zero
		# channels, rather than stamping a wrong shape. A warning is not raised here — a failed native call
		# is a build/plumbing fault the gate catches, not an artist-facing condition.
		return [p_surface, Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n),
				Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]
	return [res["z"], res["flow"], res["ero"], res["dep"], res["wet"]]


func _cache_bytes() -> int:
	var b := 0
	for k in _cache:
		for g in (_cache[k] as Array):
			b += (g as PackedFloat32Array).size() * 4
	return b


## A cheap order-sensitive hash of the surface, the freeze staleness key: a different upstream surface
## produces a different key, so a frozen solve knows it is looking at new ground.
func _surface_hash(p_surface: PackedFloat32Array, p_gw: int, p_gh: int) -> int:
	var h := hash(p_gw) ^ (hash(p_gh) << 1)
	h = h ^ hash(p_surface)
	return h
