# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeHydraulicParticle — Eulerian-Lagrangian droplet hydraulic erosion SOLVER.
# Casts thousands of virtual water droplets across the terrain that gather momentum, carve channels along
# gradients, transport sediment, and deposit alluvial fans.
#
# ---- Outputs ----
#   port 0  "height"       HEIGHT  eroded surface elevation (metres)
#   port 1  "sediment"     MASK    accumulated sediment deposition concentration
#   port 2  "flow"         MASK    droplet path flow density
#   port 3  "water_depth"  MASK    droplet water depth
@tool
class_name Pasture3DGraphNodeHydraulicParticle
extends Pasture3DGraphNode

enum Evaluation { LIVE, FROZEN }

@export_group("Simulation")
## Total number of raindrops / particles simulated across the terrain footprint.
@export_range(1000, 200000, 1000, "or_greater") var droplet_count: int = 25000:
	set(v):
		droplet_count = maxi(v, 1)
		_param_changed()

## Maximum lifetime / steps a single droplet can travel before terminating.
@export_range(5, 100, 1) var max_lifetime: int = 30:
	set(v):
		max_lifetime = maxi(v, 1)
		_param_changed()

## Droplet momentum weight [0.0..1.0]. Higher inertia causes droplets to overshoot turns and follow valley lines.
@export_range(0.0, 1.0, 0.01) var inertia: float = 0.05:
	set(v):
		inertia = clampf(v, 0.0, 1.0)
		_param_changed()

## Multiplier for the amount of sediment water can carry per unit of velocity and slope.
@export_range(0.1, 20.0, 0.1, "or_greater") var sediment_capacity: float = 4.0:
	set(v):
		sediment_capacity = maxf(v, 0.0)
		_param_changed()

## Rate at which soil/bedrock dissolves into the water droplet when below sediment capacity [0.0..1.0].
@export_range(0.0, 1.0, 0.01) var erosion_speed: float = 0.3:
	set(v):
		erosion_speed = clampf(v, 0.0, 1.0)
		_param_changed()

## Rate at which excess sediment is deposited onto the terrain when above capacity [0.0..1.0].
@export_range(0.0, 1.0, 0.01) var deposition_speed: float = 0.3:
	set(v):
		deposition_speed = clampf(v, 0.0, 1.0)
		_param_changed()

## Fraction of water volume that evaporates per droplet step [0.0..1.0].
@export_range(0.0, 0.5, 0.005) var evaporation_rate: float = 0.01:
	set(v):
		evaporation_rate = clampf(v, 0.0, 1.0)
		_param_changed()

## Minimum slope gradient used for sediment capacity calculation.
@export_range(0.001, 0.2, 0.005) var min_slope: float = 0.01:
	set(v):
		min_slope = maxf(v, 0.0001)
		_param_changed()

## Gravitational acceleration constant scaling downhill speed.
@export_range(0.5, 20.0, 0.5) var gravity: float = 4.0:
	set(v):
		gravity = maxf(v, 0.1)
		_param_changed()

## Bedrock elevation resistance gap (metres) preventing runaway hole gouging into flat terrain.
@export_range(0.1, 50.0, 0.5) var bedrock_gap: float = 2.0:
	set(v):
		bedrock_gap = maxf(v, 0.0)
		_param_changed()

## Ridge forcing cross-gradient strength to organize droplets into dendritic tributary trees.
@export_range(0.0, 2.0, 0.05) var ridge_forcing: float = 0.0:
	set(v):
		ridge_forcing = maxf(v, 0.0)
		_param_changed()

## Deterministic random seed for particle distribution.
@export var seed: int = 1337:
	set(v):
		seed = v
		_param_changed()

## FROZEN means this node serves its own cache, which only the GDScript evaluator can do. See
## Pasture3DGraphNode.blocks_native().
func blocks_native() -> bool:
	return evaluation == Evaluation.FROZEN


@export_group("Evaluation")
## LIVE re-solves on every evaluation; FROZEN caches the solve until Bake is pressed.
@export var evaluation: Evaluation = Evaluation.LIVE:
	set(v):
		evaluation = v
		emit_changed()

@export_tool_button("Bake Particle Erosion") var _bake_btn = clear_cache

# ---- Runtime freeze state ----
var _cache: Dictionary = {}
var _cache_key: int = 0
var _dirty_since_bake: bool = false
var _stale: bool = false


func op() -> StringName:
	return &"hydraulic_particle"


func role() -> Role:
	return Role.SOLVER


func display_name() -> String:
	return "Particle Hydraulic Erosion"


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 5


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "mask", "droplets", "erosion_speed", "deposition_speed"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.HEIGHT,
		PortType.MASK,
		PortType.INT,
		PortType.FLOAT,
		PortType.FLOAT,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return 1.0
		2: return float(droplet_count)
		3: return erosion_speed
		4: return deposition_speed
		_: return 0.0


func output_count() -> int:
	return 4


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "sediment", "flow", "water_depth"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK, PortType.MASK, PortType.MASK])


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
		w.append("%s is FROZEN and input or parameters changed. Press Bake to re-solve." % display_name())
	if droplet_count <= 0 or is_zero_approx(erosion_speed):
		w.append("%s: Droplet Count or Erosion Speed is 0, so no erosion will occur." % display_name())
	return w


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	var mask_in: PackedFloat32Array = (p_inputs[1] as PackedFloat32Array) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array) else PackedFloat32Array()
	var d_count: int = int(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else droplet_count
	var es: float = float(p_inputs[3][0]) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and p_inputs[3].size() > 0) else erosion_speed
	var ds: float = float(p_inputs[4][0]) if (p_inputs.size() > 4 and p_inputs[4] is PackedFloat32Array and p_inputs[4].size() > 0) else deposition_speed

	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)

	if evaluation == Evaluation.FROZEN:
		var key := _surface_hash(surface, p_gw, p_gh)
		if not _cache.is_empty():
			if _dirty_since_bake or key != _cache_key:
				_set_stale(true)
			return _cache[_cache_key]
		var solved := _solve_dynamic(surface, p_gw, p_gh, p_rect, d_count, es, ds, mask_in)
		_cache = {}
		_cache_key = key
		_cache[key] = solved
		_dirty_since_bake = false
		_set_stale(false)
		return solved

	if not _cache.is_empty():
		_cache.clear()
	_set_stale(false)
	return _solve_dynamic(surface, p_gw, p_gh, p_rect, d_count, es, ds, mask_in)


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


func _surface_hash(p_surface: PackedFloat32Array, p_gw: int, p_gh: int) -> int:
	var h := hash(p_gw) ^ (hash(p_gh) << 1)
	h = h ^ hash(p_surface)
	return h


func _solve_dynamic(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_droplets: int, p_es: float, p_ds: float, p_mask: PackedFloat32Array) -> Array:
	var n := p_gw * p_gh
	var params := {
		"droplet_count": p_droplets,
		"max_lifetime": max_lifetime,
		"inertia": inertia,
		"sediment_capacity": sediment_capacity,
		"erosion_speed": p_es,
		"deposition_speed": p_ds,
		"evaporation_rate": evaporation_rate,
		"min_slope": min_slope,
		"gravity": gravity,
		"bedrock_gap": bedrock_gap,
		"ridge_forcing": ridge_forcing,
		"seed": seed,
		"mask": p_mask,
	}

	if not ClassDB.class_has_method("Pasture3DUtil", "hydraulic_particle_solve_grid"):
		push_error("[Pasture3D] Pasture3DUtil.hydraulic_particle_solve_grid is not bound. Rebuild GDExtension.")
		return [p_surface.duplicate(), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	var res: Dictionary = Pasture3DUtil.hydraulic_particle_solve_grid(p_surface, p_gw, p_gh, p_rect, params)
	if not bool(res.get("ok", false)):
		push_error("[Pasture3D] Hydraulic particle native solve failed.")
		return [p_surface.duplicate(), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	return [
		res["height"] as PackedFloat32Array,
		res["sediment"] as PackedFloat32Array,
		res["flow"] as PackedFloat32Array,
		res["water_depth"] as PackedFloat32Array,
	]
