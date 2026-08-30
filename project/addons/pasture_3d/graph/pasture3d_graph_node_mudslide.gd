# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeMudslide — a SOLVER that moves a FINITE, MASKABLE quantity of material downhill.
#
# Not TalusProjection or ErosionThermal with different defaults. Those relax slope EVERYWHERE until the whole
# surface sits at its angle of repose; there is no budget and nothing to run out of. This starts with a
# specific depth of mobile material on a hillside the author picked with a mask, moves it, and stops when it
# is spent. It is the node for one scar, not for global weathering — and it is why the mask port is the
# interesting one.
#
#   port 0  "height"      HEIGHT  the surface after the slide
#   port 1  "deposition"  MASK    where material LANDED, normalised 0..1 (see deposition_divisor())
@tool
class_name Pasture3DGraphNodeMudslide
extends Pasture3DGraphNode

enum Evaluation { LIVE, FROZEN }

@export_group("Material")
## Below this slope material comes to rest, so this is where deposition comes from — there is no separate
## deposition rule, only the absence of a driving slope.
@export_range(0.0, 89.0, 0.5) var talus_angle_deg: float = 30.0:
	set(v):
		talus_angle_deg = clampf(v, 0.0, 89.0)
		_param_changed()

## Depth of mobile material, in METRES. The budget: the slide cannot move more than this.
@export_range(0.0, 100.0, 0.1, "or_greater") var depth: float = 4.0:
	set(v):
		depth = maxf(v, 0.0)
		_param_changed()

## How far down the hill the slide runs, in WORLD METRES.
##
## The reference implementation exposes an iteration count here. An iteration count is a CELL-SPACE quantity
## — a sweep advances material about one cell — so the same setting would reach four times as far on a 4 m
## grid as on a 1 m one, and a slide tuned at one bake resolution would land somewhere else at another. The
## sweep count is derived from this and the cell size instead.
@export_range(0.0, 2000.0, 1.0, "or_greater") var travel_distance: float = 60.0:
	set(v):
		travel_distance = maxf(v, 0.0)
		_param_changed()

@export_group("Flow")
## Raising it makes the transportable fraction thin faster as the pool runs down, so the slide tails off into
## a thin distal deposit instead of stopping with a blunt front.
@export_range(0.1, 8.0, 0.05) var depth_exponent: float = 1.0:
	set(v):
		depth_exponent = maxf(v, 0.01)
		_param_changed()

## How sharply flow concentrates into the steepest neighbour. 1 shares in proportion to slope; higher values
## channel the slide into narrow tongues; below 1 it spreads as a sheet.
@export_range(0.1, 8.0, 0.05) var viscosity_power: float = 1.0:
	set(v):
		viscosity_power = maxf(v, 0.01)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		_param_changed()

@export_group("Evaluation")
## FROZEN (the default) sweeps once and serves the cache until Bake Mudslide, flagging itself stale when the
## input or its parameters changed since. The sweep count scales with Travel Distance over the cell size, so
## on a fine grid this is a real solve and not something to re-run on every evaluation.
@export var evaluation: Evaluation = Evaluation.FROZEN:
	set(v):
		evaluation = v
		emit_changed()

@export_tool_button("Bake Mudslide") var _bake_btn = clear_cache

# ---- Runtime freeze state (not serialised — the caches rebuild on demand) ----
var _cache: Dictionary = {}
var _cache_key: int = 0
var _dirty_since_bake: bool = false
var _stale: bool = false
var _deposition_divisor: float = 1.0


func op() -> StringName:
	return &"mudslide"


func role() -> Role:
	return Role.SOLVER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 3


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "mask", "amount"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK, PortType.FLOAT])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		2: return amount
		_: return 0.0


func output_count() -> int:
	return 2


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "deposition"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK])


## The METRES the normalised deposition channel was divided by. A 0..1 channel is meaningless without it, so
## it is readable rather than printed — a downstream Remap can put the channel back into metres.
func deposition_divisor() -> float:
	return _deposition_divisor


func clear_cache() -> void:
	if _cache.is_empty() and not _stale and not _dirty_since_bake:
		return
	_cache.clear()
	_dirty_since_bake = false
	_stale = false
	emit_changed()


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and p_inputs[0].size() == n) else Pasture3DGraphOps.zeros(n)
	var mask: PackedFloat32Array = (p_inputs[1] as PackedFloat32Array) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() == n) else PackedFloat32Array()
	var amt: float = float(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else amount

	if evaluation == Evaluation.FROZEN:
		var key := _input_hash(surface, mask, p_gw, p_gh)
		if not _cache.is_empty():
			if _dirty_since_bake or key != _cache_key:
				_set_stale(true)
			return _cache[_cache_key]
		var solved := _solve(surface, mask, p_gw, p_gh, p_rect, amt)
		_cache = {}
		_cache_key = key
		_cache[key] = solved
		_dirty_since_bake = false
		_set_stale(false)
		return solved

	if not _cache.is_empty():
		_cache.clear()
	_set_stale(false)
	return _solve(surface, mask, p_gw, p_gh, p_rect, amt)


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if _stale:
		w.append("%s is FROZEN and its input or parameters changed since the bake — it is showing the "
			% display_name() + "slide it solved for the old shape. Press Bake Mudslide to re-solve.")
	if is_zero_approx(depth) or is_zero_approx(travel_distance) or is_zero_approx(amount):
		w.append("%s: Depth, Travel Distance or Amount is 0, so no material moves." % display_name())
	return w


# ---- Internals -------------------------------------------------------------------------------------

func _solve(p_surface: PackedFloat32Array, p_mask: PackedFloat32Array, p_gw: int, p_gh: int,
		p_rect: Rect2, p_amount: float) -> Array:
	var n := p_gw * p_gh
	if not ClassDB.class_has_method("Pasture3DUtil", "mudslide_grid"):
		push_error("[Pasture3D] Pasture3DUtil.mudslide_grid is not bound. Rebuild GDExtension.")
		return [p_surface.duplicate(), Pasture3DGraphOps.zeros(n)]

	var res: Dictionary = Pasture3DUtil.mudslide_grid(p_surface, p_mask, p_gw, p_gh, p_rect,
			talus_angle_deg, depth, travel_distance, depth_exponent, viscosity_power, p_amount)
	if res.is_empty():
		return [p_surface.duplicate(), Pasture3DGraphOps.zeros(n)]
	_deposition_divisor = float(res.get("divisor", 1.0))
	return [res["height"], res["deposition"]]


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


func _input_hash(p_surface: PackedFloat32Array, p_mask: PackedFloat32Array, p_gw: int, p_gh: int) -> int:
	# The MASK is in the key as well as the surface: this node's whole point is that the author chooses where
	# the material sits, so a mask that moved is a different slide even on identical ground.
	var h := hash(p_gw) ^ (hash(p_gh) << 1)
	h = h ^ hash(p_surface)
	h = h ^ (hash(p_mask) << 3)
	return h
