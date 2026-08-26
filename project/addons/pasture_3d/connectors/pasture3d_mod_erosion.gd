# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DNodeErosion — the stream-power fluvial solver, run over a brush's OWN output before it
# composites. Phase 3b of PASTURE3D_BRUSH_EROSION_SPEC.md §6.7.
#
# This is the modifier the whole stack exists for. A FIELD operator (see Pasture3DNode's
# header): it routes water across the entire footprint, so it cannot be a relief op and cannot be folded
# into the rasteriser's cell loop. It is the same `erosion_solve` a Pasture3DSim runs — same parameter
# names, same defaults — so a value tuned on a standalone Sim transfers by reading one inspector and
# typing into another.
#
# ---- What it replaces ----
#
# Eroding a mound used to take a Pasture3DMound, a Pasture3DSim with its own duplicate spline, a
# Pasture3DSimResult on disk, and a second brush on a HIGHER layer to stamp flow-gated detail. All four
# collapse into this: one node, one spline, no resource file, no layer ordering to get right.
#
# ---- The two mechanical facts (§6.8) ----
#
# 1. THE SOLVER NEEDS AN ABSOLUTE SURFACE, and the working grid under an ADD blend holds a delta. The
#    host converts: the input is `base_below + vals`, and what goes back is `eroded - base_below`.
# 2. NaN OUTSIDE THE LOOP IS THE RIGHT BOUNDARY CONDITION, for free. `erosion_solve` turns non-finite
#    input into a fixed outlet at the field minimum, which for a mound is exactly right: the ground off
#    the loop is where the mountain's water goes.
#
# A mountain IS the drainage divide, so nothing upstream feeds it and `catchment_margin` — quadratic,
# and much of why the standalone Sim is expensive over a big area — does not apply to this host.
@tool
class_name Pasture3DNodeErosion
extends Pasture3DNode

@export_group("Simulation")
## Solver iterations. Each one re-routes the drainage network over the current surface, so more
## iterations deepen valleys AND let the network reorganise, rather than only scaling the same cut.
@export_range(1, 200, 1, "or_greater") var iterations: int = 30:
	set(v):
		iterations = maxi(v, 1)
		_touch()

## K in the stream-power law: how fast channels incise per iteration. The single knob for "how eroded".
@export_range(0.0, 1.0, 0.001, "or_greater") var erosion_rate: float = 0.08:
	set(v):
		erosion_rate = maxf(v, 0.0)
		_touch()

## m, the drainage-area exponent. Higher concentrates cutting into the big channels; lower spreads it.
@export_range(0.0, 1.0, 0.01) var area_exponent: float = 0.45:
	set(v):
		area_exponent = clampf(v, 0.0, 1.0)
		_touch()

## Hillslope diffusion, m² per step — the soil-creep term that rounds ridges and fills the sharpest
## notches. 0 leaves a purely fluvial, knife-edged result.
@export_range(0.0, 10.0, 0.01, "or_greater") var hillslope_diffusion: float = 0.15:
	set(v):
		hillslope_diffusion = maxf(v, 0.0)
		_touch()

## G, the sediment deposition coefficient (Yuan et al. 2019). 0 is detachment-limited — material is
## removed and never put back. Toward 1 rivers lay their load down again, building alluvial fans and
## filling valley floors.
##
## NOT free: the deposition term makes each cell depend on how much its whole upstream catchment eroded,
## which is only solvable by iterating, and convergence degrades sharply as G rises. The sweep count is
## capped and reported rather than allowed to run away.
@export_range(0.0, 1.0, 0.01) var deposition: float = 0.0:
	set(v):
		deposition = clampf(v, 0.0, 1.0)
		_touch()

@export_group("Erodability")
## Optional hardness map across the brush's footprint: dark erodes less, light erodes more. Sampled by
## luminance and remapped into `erodability_range`. Unassigned = uniform rock.
@export var erodability_map: Texture2D:
	set(v):
		erodability_map = v
		_lut_cache = []
		_touch()

## What black and white in the map mean, as multipliers on `erosion_rate`.
@export var erodability_range: Vector2 = Vector2(0.25, 2.0):
	set(v):
		erodability_range = v
		_touch()

@export_group("Fields")
## Publish this solve's four channels — flow, erosion, deposition, wetness — into the stack's field
## context, where any LATER modifier's selectors read them directly.
##
## THIS IS THE HALF THAT MAKES THE WORKFLOW WORK. With it on, a Relief modifier below this one can gate
## on "where water ran" with no Pasture3DSimResult on disk and no `sim_result` reference to wire up:
## shape the mountain, erode it, then stamp detail into the channels the erosion just cut, on one node.
##
## Off leaves the four channels at their defined zero, exactly as if no sim had ever run.
@export var publish_fields: bool = true:
	set(v):
		publish_fields = v
		_touch()

## Cached `[data, w, h, reason]` from `erodability_map`, so a slider drag does not re-read the image.
## Cleared whenever the map is reassigned.
var _lut_cache: Array = []

# ---- The frozen cache (§6.3) -----------------------------------------------------------------------
#
# `auto_refresh` re-bakes on every spline drag, and a solve per drag is unusable. FROZEN caches this
# modifier's output and re-solves only when it has nothing cached, or on an explicit Bake — which is what
# makes the modifiers AFTER it tunable at interactive speed. That is the real prize: iterating on a
# flow-gated detail pass stops costing a re-solve.
#
# IN MEMORY ONLY, deliberately. The baked heights already persist — they are in the terrain's own layer
# data — so a cache does not have to survive a reload for the LANDSCAPE to. All it would buy is skipping
# one solve after reopening a scene, and the price would be tens of megabytes of float grid inside a
# .tscn. Reopening and then tweaking a downstream modifier costs one solve; that is the whole cost.
#
# Keyed by GRID EXTENT, because a brush with several loops bakes several grids and one slot would thrash
# between them. Each entry holds the solve's own key — a hash of the exact surface handed to the solver,
# which is what makes staleness detection complete: nothing upstream can change without changing it.
var _cache: Dictionary = {}

## Set after a bake when a frozen entry was served against a surface it was not solved for. Reported as
## a configuration warning rather than silently re-solving or silently serving old data.
var _stale: bool = false

@export_tool_button("Bake Erosion") var _bake_btn = clear_cache


## Erosion is the one modifier that defaults to FROZEN (§6.3). Every other modifier costs microseconds
## and can afford to recompute on each of the many refreshes an `auto_refresh` spline drag fires; a solve
## cannot, and a brush that locked the editor per drag is the complaint this whole phase came from.
##
## The consequence is worth knowing before it surprises you: while Frozen, ANY change — upstream or to
## this modifier's own sliders — leaves the cached solve in place and raises a stale warning, until you
## press Bake Erosion. One rule, applied to everything, rather than a list of which edits re-solve.
## Set Evaluation to Live on a small brush where a solve is cheap enough to watch.
func _init() -> void:
	evaluation = Evaluation.FROZEN


func needs_grid() -> bool:
	return true


## Expensive by a wide margin — the one modifier where a cache is worth its own staleness problem.
func _supports_freezing() -> bool:
	return true


## Drop every cached solve, so the next refresh recomputes. This is the explicit Bake.
func clear_cache() -> void:
	if _cache.is_empty() and not _stale:
		return
	_cache.clear()
	_stale = false
	_touch()


func cache_bytes() -> int:
	var n := 0
	for k in _cache:
		var e: Dictionary = _cache[k]
		for f in ["grid", "flow", "ero", "dep", "wet"]:
			n += (e[f] as PackedFloat32Array).size() * 4
	return n


## The cache entry for one bake grid, or an empty Dictionary. `p_extent` identifies the grid; the host
## compares the entry's `key` against the surface it is about to solve.
func cache_for(p_extent: String) -> Dictionary:
	return _cache.get(p_extent, {})


## Store one solve. Called by the host after a bake, with what the solver actually produced.
func store_cache(p_extent: String, p_entry: Dictionary) -> void:
	_cache[p_extent] = p_entry


## Record whether the last bake served a stale entry. Deliberately does NOT `_touch()` — this is set
## DURING a bake, and re-baking from inside a bake is how a refresh loop starts.
func set_stale(p_stale: bool) -> void:
	if _stale == p_stale:
		return
	_stale = p_stale
	# The warning list is the only thing that changed, and it is safe to refresh from here.
	if Engine.is_editor_hint():
		emit_changed.call_deferred()


func op() -> StringName:
	return &"erosion"


## A zero rate is the honest "off": the solver would route water, iterate, and subtract nothing.
func is_active() -> bool:
	return enabled and iterations >= 1 and (not is_zero_approx(erosion_rate)
			or not is_zero_approx(hillslope_diffusion))


func to_params() -> Dictionary:
	var lut := _lut()
	return {
		"iterations": iterations,
		"erosion_rate": erosion_rate,
		"area_exponent": area_exponent,
		"diffusion": hillslope_diffusion,
		"deposition": deposition,
		"erodability_lut": lut[0],
		"erodability_w": lut[1],
		"erodability_h": lut[2],
		"erodability_min": erodability_range.x,
		"erodability_max": erodability_range.y,
		"publish_fields": publish_fields,
	}


func modifier_warnings(_p_host) -> PackedStringArray:
	var w := PackedStringArray()
	if not enabled:
		return w
	if _stale:
		w.append(("%s is FROZEN and the surface under it has changed, so the terrain is showing the "
			+ "erosion it solved for the OLD shape. Press Bake Erosion to re-solve, or set Evaluation "
			+ "to Live.") % display_name())
	if evaluation == Evaluation.FROZEN and not _cache.is_empty():
		w.append("%s holds %.1f MB of frozen solve. Press Bake Erosion to re-solve it."
			% [display_name(), cache_bytes() / 1048576.0])
	if is_zero_approx(erosion_rate) and is_zero_approx(hillslope_diffusion):
		w.append(("%s: both Erosion Rate and Hillslope Diffusion are 0, so the solver would route water "
			+ "and change nothing. Raise Erosion Rate to cut channels.") % display_name())
	if erodability_range.x <= 0.0 or erodability_range.y <= 0.0:
		w.append(("%s: Erodability Range must be positive at both ends — a non-positive multiplier "
			+ "makes the solver ADD material where the map is dark.") % display_name())
	var lut := _lut()
	if lut[3] != "":
		w.append("%s: the Erodability Map was ignored because %s; erodability is uniform."
			% [display_name(), lut[3]])
	return w


## `[data, w, h, reason]`, memoised. The LUT format is the erosion family's, so it lives on
## Pasture3DSimBase and Pasture3DSim reads the same one — the solver's remap depends on exactly how the
## luminance was sampled and downscaled, and two copies of that would eventually disagree.
func _lut() -> Array:
	if _lut_cache.is_empty():
		_lut_cache = Pasture3DSimBase.erodability_lut(erodability_map)
	return _lut_cache
