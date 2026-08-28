# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevHydraulicParticle — pure GDScript reference oracle for particle-based hydraulic erosion.
# Eulerian-Lagrangian droplet simulation tracking momentum, velocity, sediment pickup, transport, and deposition.
# Used for algorithm prototyping, A/B testing, and automated headless CI parity verification.
@tool
class_name Pasture3DGraphNodeDevHydraulicParticle
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

## Deterministic random seed for particle distribution.
@export var seed: int = 1337:
	set(v):
		seed = v
		_param_changed()

@export_group("Evaluation")
@export var evaluation: Evaluation = Evaluation.LIVE:
	set(v):
		evaluation = v
		emit_changed()

@export_tool_button("Bake Particle Erosion") var _bake_btn = clear_cache

var _cache: Dictionary = {}
var _cache_key: int = 0
var _dirty_since_bake: bool = false
var _stale: bool = false


func op() -> StringName:
	return &"dev_hydraulic_particle"


func role() -> Role:
	return Role.SOLVER


func display_name() -> String:
	return "[Dev/GD] Particle Hydraulic Erosion"


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 2


func input_names() -> PackedStringArray:
	return PackedStringArray(["height", "mask"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK])


func output_count() -> int:
	return 4


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "sediment", "flow", "water_depth"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK, PortType.MASK, PortType.MASK])


func _param_changed() -> void:
	if evaluation == Evaluation.FROZEN:
		_stale = true
	emit_changed()


func clear_cache() -> void:
	_cache.clear()
	_cache_key = 0
	_dirty_since_bake = false
	_stale = false
	emit_changed()


## Deterministic 32-bit LCG PRNG for exact parity between GDScript and C++.
static func _next_rand(p_state: int) -> Array:
	var next_state: int = (p_state * 1664525 + 1013904223) & 0xFFFFFFFF
	var rand_float: float = float(next_state) / 4294967296.0
	return [next_state, rand_float]


## Pure GDScript reference oracle for particle hydraulic erosion.
static func solve_oracle(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_params: Dictionary) -> Array:
	if p_gw < 2 or p_gh < 2 or p_surface.size() != p_gw * p_gh:
		return [PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()]

	var n: int = p_gw * p_gh
	var height := p_surface.duplicate()
	var sediment := PackedFloat32Array()
	var flow := PackedFloat32Array()
	var water_depth := PackedFloat32Array()
	sediment.resize(n)
	sediment.fill(0.0)
	flow.resize(n)
	flow.fill(0.0)
	water_depth.resize(n)
	water_depth.fill(0.0)

	var droplet_count: int = maxi(1, int(p_params.get("droplet_count", 25000)))
	var max_lifetime: int = maxi(1, int(p_params.get("max_lifetime", 30)))
	var inertia: float = clampf(float(p_params.get("inertia", 0.05)), 0.0, 1.0)
	var sediment_capacity: float = maxf(0.0, float(p_params.get("sediment_capacity", 4.0)))
	var erosion_speed: float = clampf(float(p_params.get("erosion_speed", 0.3)), 0.0, 1.0)
	var deposition_speed: float = clampf(float(p_params.get("deposition_speed", 0.3)), 0.0, 1.0)
	var evaporation_rate: float = clampf(float(p_params.get("evaporation_rate", 0.01)), 0.0, 1.0)
	var min_slope: float = maxf(0.0001, float(p_params.get("min_slope", 0.01)))
	var gravity: float = maxf(0.1, float(p_params.get("gravity", 4.0)))
	var rng_seed: int = int(p_params.get("seed", 1337))

	var mask: PackedFloat32Array = p_params.get("mask", PackedFloat32Array())
	var has_mask: bool = (mask.size() == n)

	var rng_state: int = rng_seed

	for d in range(droplet_count):
		var r_res := _next_rand(rng_state)
		rng_state = r_res[0]
		var rx: float = r_res[1] * float(p_gw - 1)

		r_res = _next_rand(rng_state)
		rng_state = r_res[0]
		var rz: float = r_res[1] * float(p_gh - 1)

		var px: float = rx
		var pz: float = rz
		var dir_x: float = 0.0
		var dir_z: float = 0.0
		var speed: float = 1.0
		var water: float = 1.0
		var sed: float = 0.0

		var init_ix: int = clampi(int(px), 0, p_gw - 1)
		var init_iz: int = clampi(int(pz), 0, p_gh - 1)
		var init_idx: int = init_iz * p_gw + init_ix
		if not is_finite(height[init_idx]):
			continue
		if has_mask and mask[init_idx] <= 0.001:
			continue

		for step in range(max_lifetime):
			var ix: int = int(floor(px))
			var iz: int = int(floor(pz))
			if ix < 0 or ix >= p_gw - 1 or iz < 0 or iz >= p_gh - 1:
				break

			var u: float = px - float(ix)
			var v: float = pz - float(iz)

			var i00: int = iz * p_gw + ix
			var i10: int = i00 + 1
			var i01: int = (iz + 1) * p_gw + ix
			var i11: int = i01 + 1

			var h00: float = height[i00]
			var h10: float = height[i10]
			var h01: float = height[i01]
			var h11: float = height[i11]

			if not is_finite(h00) or not is_finite(h10) or not is_finite(h01) or not is_finite(h11):
				break

			var h_curr: float = (1.0 - u) * (1.0 - v) * h00 + u * (1.0 - v) * h10 + (1.0 - u) * v * h01 + u * v * h11

			# Surface gradient
			var gx: float = (1.0 - v) * (h10 - h00) + v * (h11 - h01)
			var gz: float = (1.0 - u) * (h01 - h00) + u * (h11 - h10)

			# Flow direction with inertia
			dir_x = dir_x * inertia - gx * (1.0 - inertia)
			dir_z = dir_z * inertia - gz * (1.0 - inertia)

			var dir_len: float = sqrt(dir_x * dir_x + dir_z * dir_z)
			if dir_len > 1.0e-6:
				dir_x /= dir_len
				dir_z /= dir_len
			else:
				r_res = _next_rand(rng_state)
				rng_state = r_res[0]
				var ang: float = r_res[1] * TAU
				dir_x = cos(ang)
				dir_z = sin(ang)

			var next_px: float = px + dir_x
			var next_pz: float = pz + dir_z

			var next_ix: int = int(floor(next_px))
			var next_iz: int = int(floor(next_pz))
			if next_ix < 0 or next_ix >= p_gw - 1 or next_iz < 0 or next_iz >= p_gh - 1:
				break

			var next_u: float = next_px - float(next_ix)
			var next_v: float = next_pz - float(next_iz)

			var ni00: int = next_iz * p_gw + next_ix
			var ni10: int = ni00 + 1
			var ni01: int = (next_iz + 1) * p_gw + next_ix
			var ni11: int = ni01 + 1

			var nh00: float = height[ni00]
			var nh10: float = height[ni10]
			var nh01: float = height[ni01]
			var nh11: float = height[ni11]

			if not is_finite(nh00) or not is_finite(nh10) or not is_finite(nh01) or not is_finite(nh11):
				break

			var h_next: float = (1.0 - next_u) * (1.0 - next_v) * nh00 + next_u * (1.0 - next_v) * nh10 + (1.0 - next_u) * next_v * nh01 + next_u * next_v * nh11
			var delta_h: float = h_next - h_curr

			# Bilinear weights for deposition/erosion on current cell quad
			var w00: float = (1.0 - u) * (1.0 - v)
			var w10: float = u * (1.0 - v)
			var w01: float = (1.0 - u) * v
			var w11: float = u * v

			var mask_val: float = 1.0
			if has_mask:
				mask_val = w00 * mask[i00] + w10 * mask[i10] + w01 * mask[i01] + w11 * mask[i11]

			if delta_h > 0.0:
				# Moving uphill into pit — deposit sediment
				var deposit_amt: float = minf(sed, delta_h) * mask_val
				sed -= deposit_amt
				height[i00] += deposit_amt * w00
				height[i10] += deposit_amt * w10
				height[i01] += deposit_amt * w01
				height[i11] += deposit_amt * w11
				sediment[i00] += deposit_amt * w00
				sediment[i10] += deposit_amt * w10
				sediment[i01] += deposit_amt * w01
				sediment[i11] += deposit_amt * w11
				break
			else:
				# Moving downhill — compute capacity and erode/deposit
				var slope: float = maxf(-delta_h, min_slope)
				var cap: float = slope * speed * water * sediment_capacity

				if sed > cap:
					var dep: float = (sed - cap) * deposition_speed * mask_val
					sed -= dep
					height[i00] += dep * w00
					height[i10] += dep * w10
					height[i01] += dep * w01
					height[i11] += dep * w11
					sediment[i00] += dep * w00
					sediment[i10] += dep * w10
					sediment[i01] += dep * w01
					sediment[i11] += dep * w11
				else:
					var ero: float = minf((cap - sed) * erosion_speed, -delta_h) * mask_val
					sed += ero
					height[i00] -= ero * w00
					height[i10] -= ero * w10
					height[i01] -= ero * w01
					height[i11] -= ero * w11

				speed = sqrt(maxf(0.0, speed * speed - delta_h * gravity))
				water *= (1.0 - evaporation_rate)

				# Flow accumulation
				flow[i00] += water * w00
				flow[i10] += water * w10
				flow[i01] += water * w01
				flow[i11] += water * w11

				water_depth[i00] = maxf(water_depth[i00], water * 0.05 * w00)
				water_depth[i10] = maxf(water_depth[i10], water * 0.05 * w10)
				water_depth[i01] = maxf(water_depth[i01], water * 0.05 * w01)
				water_depth[i11] = maxf(water_depth[i11], water * 0.05 * w11)

				px = next_px
				pz = next_pz

	return [height, sediment, flow, water_depth]
