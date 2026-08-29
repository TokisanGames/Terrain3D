# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevHydraulicSaleve — Pure GDScript Reference Oracle for Salève Hydraulic Erosion.
# Features stable raster multi-flow routing with dendritic noise perturbation, secondary micro-rills,
# and lateral riverbed bank diffusion.

@tool
class_name Pasture3DGraphNodeDevHydraulicSaleve
extends Pasture3DGraphNode

enum Evaluation { LIVE, FROZEN }

@export_group("Simulation")
@export_range(1, 100, 1, "or_greater") var iterations: int = 25:
	set(v):
		iterations = maxi(v, 1)
		_param_changed()

@export_range(0.01, 2.0, 0.01, "or_greater") var erosion_strength: float = 0.7:
	set(v):
		erosion_strength = maxf(v, 0.0)
		_param_changed()

@export_range(0.01, 1.0, 0.01) var drainage_exponent: float = 0.2:
	set(v):
		drainage_exponent = clampf(v, 0.01, 1.0)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var drainage_noise: float = 0.15:
	set(v):
		drainage_noise = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 0.5, 0.005) var fine_erosion_strength: float = 0.05:
	set(v):
		fine_erosion_strength = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 2.0, 0.05) var shape_preservation: float = 0.8:
	set(v):
		shape_preservation = clampf(v, 0.0, 2.0)
		_param_changed()

@export_range(0.0, 0.5, 0.01) var bank_smoothing: float = 0.1:
	set(v):
		bank_smoothing = clampf(v, 0.0, 0.5)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var sediment_strength: float = 0.3:
	set(v):
		sediment_strength = clampf(v, 0.0, 1.0)
		_param_changed()

@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

@export_group("Evaluation")
@export var evaluation: Evaluation = Evaluation.LIVE:
	set(v):
		evaluation = v
		emit_changed()

@export_tool_button("Bake Salève Erosion") var _bake_btn = clear_cache

var _cache: Dictionary = {}
var _cache_key: int = 0
var _dirty_since_bake: bool = false
var _stale: bool = false


func op() -> StringName:
	return &"dev_hydraulic_saleve"


func role() -> Role:
	return Role.SOLVER


func display_name() -> String:
	return "[Dev/GD] Salève Hydraulic Erosion"


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 5


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "mask", "iterations", "erosion_strength", "drainage_exponent"])


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
		2: return float(iterations)
		3: return erosion_strength
		4: return drainage_exponent
		_: return 0.0


func output_count() -> int:
	return 3


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "eroded_rock", "sediment"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK, PortType.MASK])


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
	return w


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	var mask_in: PackedFloat32Array = (p_inputs[1] as PackedFloat32Array) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array) else PackedFloat32Array()
	var iters: int = int(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else iterations
	var er: float = float(p_inputs[3][0]) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and p_inputs[3].size() > 0) else erosion_strength
	var de: float = float(p_inputs[4][0]) if (p_inputs.size() > 4 and p_inputs[4] is PackedFloat32Array and p_inputs[4].size() > 0) else drainage_exponent

	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)

	var p := {
		"iterations": iters,
		"erosion_strength": er,
		"drainage_exponent": de,
		"drainage_noise": drainage_noise,
		"fine_erosion_strength": fine_erosion_strength,
		"shape_preservation": shape_preservation,
		"bank_smoothing": bank_smoothing,
		"sediment_strength": sediment_strength,
		"seed": seed,
		"mask": mask_in,
	}

	return solve_oracle(surface, p_gw, p_gh, p_rect, p)


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func _param_changed() -> void:
	if not _cache.is_empty():
		_dirty_since_bake = true
	emit_changed()


static func _hash2d(x: int, y: int, p_seed: int) -> float:
	var n: int = int((x * 73856093) ^ (y * 19349663) ^ (p_seed * 83492791)) & 0xffffffff
	n = int((n ^ (n >> 13)) * 0x5bd1e995) & 0xffffffff
	n = (n ^ (n >> 15)) & 0xffffffff
	return float(n & 0x00ffffff) / 8388608.0 - 1.0


static func _smooth_noise2d(x: float, z: float, p_seed: int) -> float:
	var ix: int = int(floorf(x))
	var iz: int = int(floorf(z))
	var fx: float = x - float(ix)
	var fz: float = z - float(iz)

	var wx: float = fx * fx * fx * (fx * (fx * 6.0 - 15.0) + 10.0)
	var wz: float = fz * fz * fz * (fz * (fz * 6.0 - 15.0) + 10.0)

	var v00: float = _hash2d(ix, iz, p_seed)
	var v10: float = _hash2d(ix + 1, iz, p_seed)
	var v01: float = _hash2d(ix, iz + 1, p_seed)
	var v11: float = _hash2d(ix + 1, iz + 1, p_seed)

	var nx0: float = lerpf(v00, v10, wx)
	var nx1: float = lerpf(v01, v11, wx)
	return lerpf(nx0, nx1, wz)


## Pure GDScript reference solver implementation
static func solve_oracle(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_params: Dictionary) -> Array:
	var n: int = p_gw * p_gh
	if p_gw < 2 or p_gh < 2 or p_surface.size() != n:
		return [p_surface.duplicate(), PackedFloat32Array(), PackedFloat32Array()]

	var height := p_surface.duplicate()
	var eroded_rock := PackedFloat32Array()
	eroded_rock.resize(n)
	eroded_rock.fill(0.0)

	var sediment := PackedFloat32Array()
	sediment.resize(n)
	sediment.fill(0.0)

	var mask: PackedFloat32Array = p_params.get("mask", PackedFloat32Array())
	var has_mask: bool = (mask.size() == n)

	var iterations: int = maxi(1, int(p_params.get("iterations", 25)))
	var erosion_strength: float = maxf(0.0, float(p_params.get("erosion_strength", 0.7)))
	var drainage_exponent: float = clampf(float(p_params.get("drainage_exponent", 0.2)), 0.01, 1.0)
	var drainage_noise: float = maxf(0.0, float(p_params.get("drainage_noise", 0.15)))
	var fine_erosion_strength: float = maxf(0.0, float(p_params.get("fine_erosion_strength", 0.05)))
	var shape_preservation: float = clampf(float(p_params.get("shape_preservation", 0.8)), 0.0, 2.0)
	var bank_smoothing: float = clampf(float(p_params.get("bank_smoothing", 0.1)), 0.0, 0.5)
	var sediment_strength: float = clampf(float(p_params.get("sediment_strength", 0.3)), 0.0, 1.0)
	var p_seed: int = int(p_params.get("seed", 0))

	var dx: float = p_rect.size.x / float(maxi(p_gw, 1))
	var dz: float = p_rect.size.y / float(maxi(p_gh, 1))
	var diag_dist: float = sqrt(dx * dx + dz * dz)

	var n_dx: Array[int] = [-1, 1, 0, 0, -1, 1, -1, 1]
	var n_dz: Array[int] = [0, 0, -1, 1, -1, -1, 1, 1]
	var n_dist: Array[float] = [dx, dx, dz, dz, diag_dist, diag_dist, diag_dist, diag_dist]

	for pass_idx in range(iterations):
		# 1. Sort indices descending by elevation
		var order: Array[int] = []
		order.resize(n)
		for i in range(n):
			order[i] = i

		order.sort_custom(func(a: int, b: int) -> bool:
			var ha: float = height[a]
			var hb: float = height[b]
			if not is_finite(ha): return false
			if not is_finite(hb): return true
			return ha > hb
		)

		# 2. Accumulate drainage flow with noise perturbation
		var current_flow := PackedFloat32Array()
		current_flow.resize(n)
		current_flow.fill(1.0)

		var current_sediment := PackedFloat32Array()
		current_sediment.resize(n)
		current_sediment.fill(0.0)

		for idx in order:
			var h_c: float = height[idx]
			if not is_finite(h_c):
				continue
			var cx: int = idx % p_gw
			var cz: int = idx / p_gw

			var sum_drop: float = 0.0
			var drops: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]

			for k in range(8):
				var nx: int = cx + n_dx[k]
				var nz: int = cz + n_dz[k]
				if nx >= 0 and nx < p_gw and nz >= 0 and nz < p_gh:
					var n_idx: int = nz * p_gw + nx
					var h_n: float = height[n_idx]
					if is_finite(h_n) and h_n < h_c:
						var drop: float = (h_c - h_n) / n_dist[k]

						if drainage_noise > 0.0:
							var nval: float = _smooth_noise2d(float(nx) * 0.25, float(nz) * 0.25, p_seed + pass_idx * 17 + k * 3)
							drop *= maxf(0.05, 1.0 + drainage_noise * nval)

						var weighted_drop: float = pow(drop, 1.3)
						drops[k] = weighted_drop
						sum_drop += weighted_drop

			if sum_drop > 1.0e-6:
				var my_flow: float = current_flow[idx]
				var my_sed: float = current_sediment[idx]
				for k in range(8):
					if drops[k] > 0.0:
						var nx: int = cx + n_dx[k]
						var nz: int = cz + n_dz[k]
						var n_idx: int = nz * p_gw + nx
						var frac: float = drops[k] / sum_drop
						current_flow[n_idx] += my_flow * frac
						current_sediment[n_idx] += my_sed * frac

		# 3. Compute Salève Incision
		var incision_map := PackedFloat32Array()
		incision_map.resize(n)
		incision_map.fill(0.0)

		var dep_map := PackedFloat32Array()
		dep_map.resize(n)
		dep_map.fill(0.0)

		for iz in range(p_gh):
			var row: int = iz * p_gw
			for ix in range(p_gw):
				var idx: int = row + ix
				var h_c: float = height[idx]
				if not is_finite(h_c):
					continue

				var m_val: float = mask[idx] if has_mask else 1.0
				if m_val <= 0.001:
					continue

				var h_l: float = height[row + ix - 1] if ix > 0 and is_finite(height[row + ix - 1]) else h_c
				var h_r: float = height[row + ix + 1] if ix < p_gw - 1 and is_finite(height[row + ix + 1]) else h_c
				var h_u: float = height[(iz - 1) * p_gw + ix] if iz > 0 and is_finite(height[(iz - 1) * p_gw + ix]) else h_c
				var h_d: float = height[(iz + 1) * p_gw + ix] if iz < p_gh - 1 and is_finite(height[(iz + 1) * p_gw + ix]) else h_c

				var gx: float = (h_r - h_l) / (2.0 * dx)
				var gz: float = (h_d - h_u) / (2.0 * dz)
				var slope: float = sqrt(gx * gx + gz * gz)

				var diff: float = current_flow[idx] - 1.0
				var a_accum: float = diff if (diff > 15.0) else (log(1.0 + exp(diff)) if diff > -15.0 else 0.0)

				var inc_primary: float = 0.0
				if a_accum > 0.01 and slope > 1.0e-5:
					var power: float = pow(a_accum, drainage_exponent) * slope
					inc_primary = erosion_strength * 0.25 * log(1.0 + power) * m_val

				var inc_fine: float = 0.0
				if fine_erosion_strength > 0.0 and slope > 0.02:
					inc_fine = fine_erosion_strength * 0.1 * pow(slope, 0.8) * m_val

				var total_incision: float = inc_primary + inc_fine

				if total_incision > 0.0:
					var center_weight: float = 1.0 - bank_smoothing * 0.6
					var neighbor_weight: float = (bank_smoothing * 0.6) * 0.25

					incision_map[idx] += total_incision * center_weight
					if ix > 0: incision_map[row + ix - 1] += total_incision * neighbor_weight
					if ix < p_gw - 1: incision_map[row + ix + 1] += total_incision * neighbor_weight
					if iz > 0: incision_map[(iz - 1) * p_gw + ix] += total_incision * neighbor_weight
					if iz < p_gh - 1: incision_map[(iz + 1) * p_gw + ix] += total_incision * neighbor_weight

					current_sediment[idx] += total_incision

				if slope < 0.15 and current_sediment[idx] > 0.0:
					var dep: float = sediment_strength * current_sediment[idx] * (1.0 - slope / 0.15) * m_val
					dep_map[idx] += dep
					current_sediment[idx] = maxf(0.0, current_sediment[idx] - dep)

		# 4. Apply incision with base-level descent clamping
		var next_height := height.duplicate()
		for iz in range(p_gh):
			var row: int = iz * p_gw
			for ix in range(p_gw):
				var idx: int = row + ix
				var h_c: float = height[idx]
				if not is_finite(h_c):
					continue

				var cut: float = incision_map[idx]
				if cut > 0.0:
					var cx: int = ix
					var cz: int = iz
					var min_downhill: float = h_c
					for k in range(8):
						var nx: int = cx + n_dx[k]
						var nz: int = cz + n_dz[k]
						if nx >= 0 and nx < p_gw and nz >= 0 and nz < p_gh:
							var h_n: float = height[nz * p_gw + nx]
							if is_finite(h_n) and h_n < min_downhill:
								min_downhill = h_n

					var max_cut: float = maxf(0.0, (h_c - min_downhill) + 0.15 * cut)
					cut = minf(cut, max_cut)
					next_height[idx] = h_c - cut
					eroded_rock[idx] += cut

				sediment[idx] += dep_map[idx]

		height = next_height

	return [height, eroded_rock, sediment]
