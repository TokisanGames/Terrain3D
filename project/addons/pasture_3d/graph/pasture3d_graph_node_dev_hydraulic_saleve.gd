# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevHydraulicSaleve — Pure GDScript Reference Oracle for Salève Hydraulic Erosion.
# Faithful 1-to-1 implementation of Hesiod / HighMap hmap::hydraulic_saleve steady-state chi-solver.

@tool
class_name Pasture3DGraphNodeDevHydraulicSaleve
extends Pasture3DGraphNode

enum Evaluation { LIVE, FROZEN }

@export_group("Simulation")
@export_range(1, 100, 1, "or_greater") var iterations: int = 25:
	set(v):
		iterations = maxi(v, 1)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var erosion_strength: float = 0.5:
	set(v):
		erosion_strength = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(0.01, 0.8, 0.01) var drainage_exponent: float = 0.15:
	set(v):
		drainage_exponent = clampf(v, 0.01, 0.8)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var drainage_noise: float = 0.15:
	set(v):
		drainage_noise = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 0.5, 0.005) var fine_erosion_strength: float = 0.05:
	set(v):
		fine_erosion_strength = maxf(v, 0.0)
		_param_changed()

@export_range(0.05, 4.0, 0.05) var shape_preservation: float = 0.2:
	set(v):
		shape_preservation = clampf(v, 0.05, 4.0)
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


static func _fast_hash_to_unit(p_seed: int, key: int) -> float:
	var n: int = int(p_seed ^ (key * 0x5bd1e995)) & 0xffffffff
	n = int((n ^ (n >> 13)) * 0x5bd1e995) & 0xffffffff
	n = (n ^ (n >> 15)) & 0xffffffff
	return float(n & 0x00ffffff) / 8388608.0 - 1.0


## Pure GDScript reference solver implementation
static func solve_oracle(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, _p_rect: Rect2, p_params: Dictionary) -> Array:
	var n: int = p_gw * p_gh
	if p_gw < 2 or p_gh < 2 or p_surface.size() != n:
		return [p_surface.duplicate(), PackedFloat32Array(), PackedFloat32Array()]

	var mask: PackedFloat32Array = p_params.get("mask", PackedFloat32Array())
	var has_mask: bool = (mask.size() == n)

	var iterations: int = maxi(1, int(p_params.get("iterations", 25)))
	var erosion_strength: float = clampf(float(p_params.get("erosion_strength", 0.7)), 0.0, 1.0)
	var m_exp: float = clampf(float(p_params.get("drainage_exponent", 0.15)), 0.01, 0.8)
	var noise_strength: float = maxf(0.0, float(p_params.get("drainage_noise", 0.1)))
	var shape_preservation: float = clampf(float(p_params.get("shape_preservation", 2.0)), 0.1, 4.0)
	var bank_smoothing: float = clampf(float(p_params.get("bank_smoothing", 0.1)), 0.0, 0.5)
	var p_seed: int = int(p_params.get("seed", 0))

	var zmin: float = INF
	var zmax: float = -INF
	for v in p_surface:
		if is_finite(v):
			if v < zmin: zmin = v
			if v > zmax: zmax = v

	if zmax - zmin < 1.0e-5:
		var zeroes := PackedFloat32Array()
		zeroes.resize(n)
		zeroes.fill(0.0)
		return [p_surface.duplicate(), zeroes.duplicate(), zeroes]

	var zptp: float = zmax - zmin

	var z := PackedFloat32Array()
	z.resize(n)
	var erodibility := PackedFloat32Array()
	erodibility.resize(n)
	var is_outlet: Array[bool] = []
	is_outlet.resize(n)

	for iz in range(p_gh):
		for ix in range(p_gw):
			var idx: int = iz * p_gw + ix
			var h: float = p_surface[idx]
			if not is_finite(h):
				z[idx] = 0.0
				is_outlet[idx] = true
				continue

			var zn: float = (h - zmin) / zptp
			z[idx] = zn
			erodibility[idx] = pow(clampf(1.0 - zn, 0.01, 1.0), shape_preservation)
			is_outlet[idx] = (ix == 0 or ix == p_gw - 1 or iz == 0 or iz == p_gh - 1)

	var dx: float = 1.0 / float(maxi(p_gw, 1))
	var dz: float = 1.0 / float(maxi(p_gh, 1))
	var diag_dist: float = sqrt(dx * dx + dz * dz)

	var n_dx: Array[int] = [-1, 1, 0, 0, -1, 1, -1, 1]
	var n_dz: Array[int] = [0, 0, -1, 1, -1, -1, 1, 1]
	var n_dist: Array[float] = [dx, dx, dz, dz, diag_dist, diag_dist, diag_dist, diag_dist]

	var receivers: Array[int] = []
	receivers.resize(n)
	var area_acc := PackedFloat32Array()
	area_acc.resize(n)
	var response_times := PackedFloat32Array()
	response_times.resize(n)
	var order: Array[int] = []
	order.resize(n)

	for iter in range(iterations):
		for iz in range(p_gh):
			for ix in range(p_gw):
				var idx: int = iz * p_gw + ix
				if is_outlet[idx]:
					receivers[idx] = idx
					continue

				var z_c: float = z[idx]
				var best_score: float = -1.0e9
				var best_k: int = idx

				for k in range(8):
					var nx: int = ix + n_dx[k]
					var nz: int = iz + n_dz[k]
					if nx >= 0 and nx < p_gw and nz >= 0 and nz < p_gh:
						var n_idx: int = nz * p_gw + nx
						var dz_val: float = z_c - z[n_idx]
						if dz_val > 0.0:
							var slope: float = dz_val / n_dist[k]
							var noise: float = _fast_hash_to_unit(p_seed + iter * 17, idx ^ (n_idx << 16))
							var score: float = slope * (1.0 + noise_strength * noise)
							if score > best_score:
								best_score = score
								best_k = n_idx

				receivers[idx] = best_k

		for i in range(n):
			order[i] = i
		order.sort_custom(func(a: int, b: int) -> bool:
			return z[a] > z[b]
		)

		area_acc.fill(1.0)
		for idx in order:
			var r: int = receivers[idx]
			if r != idx:
				area_acc[r] += area_acc[idx]

		response_times.fill(0.0)
		for i in range(n - 1, -1, -1):
			var idx: int = order[i]
			var r: int = receivers[idx]
			if r != idx:
				var ix: int = idx % p_gw
				var iz: int = idx / p_gw
				var rx: int = r % p_gw
				var rz: int = r / p_gw
				var d: float = maxf(sqrt(pow(float(ix - rx) * dx, 2.0) + pow(float(iz - rz) * dz, 2.0)), 1.0e-5)
				var celerity: float = erodibility[idx] * pow(maxf(area_acc[idx], 1.0), m_exp)
				response_times[idx] = response_times[r] + (d / maxf(celerity, 1.0e-4))
			else:
				response_times[idx] = 0.0

		var diff: float = 0.0
		for i in range(n - 1, -1, -1):
			var idx: int = order[i]
			var r: int = receivers[idx]
			if r == idx:
				continue

			var new_z: float = z[r] + (response_times[idx] - response_times[r]) * 0.05
			var ix: int = idx % p_gw
			var iz: int = idx / p_gw
			var rx: int = r % p_gw
			var rz: int = r / p_gw
			var d: float = maxf(sqrt(pow(float(ix - rx) * dx, 2.0) + pow(float(iz - rz) * dz, 2.0)), 1.0e-5)
			var slope: float = (new_z - z[r]) / d
			if slope > 4.0:
				new_z = z[r] + 4.0 * d

			diff += absf(new_z - z[idx])
			z[idx] = new_z

		if diff / float(n) < 1.0e-4:
			break

	var ze_min: float = INF
	var ze_max: float = -INF
	for v in z:
		if v < ze_min: ze_min = v
		if v > ze_max: ze_max = v
	var ze_span: float = maxf(ze_max - ze_min, 1.0e-5)
	for i in range(n):
		z[i] = (z[i] - ze_min) / ze_span

	if bank_smoothing > 0.0:
		var smoothed := z.duplicate()
		var blend: float = bank_smoothing * 0.4
		for iz in range(1, p_gh - 1):
			for ix in range(1, p_gw - 1):
				var idx: int = iz * p_gw + ix
				var avg: float = 0.25 * (z[iz * p_gw + ix - 1] + z[iz * p_gw + ix + 1] +
						z[(iz - 1) * p_gw + ix] + z[(iz + 1) * p_gw + ix])
				smoothed[idx] = (1.0 - blend) * z[idx] + blend * avg
		z = smoothed

	var final_height := PackedFloat32Array()
	final_height.resize(n)
	var eroded_rock := PackedFloat32Array()
	eroded_rock.resize(n)
	var sediment := PackedFloat32Array()
	sediment.resize(n)
	sediment.fill(0.0)

	for i in range(n):
		var orig_h: float = p_surface[i]
		if not is_finite(orig_h):
			final_height[i] = orig_h
			eroded_rock[i] = 0.0
			continue

		var eroded_h: float = zmin + z[i] * zptp
		var m_val: float = mask[i] if has_mask else 1.0
		var strength: float = erosion_strength * m_val

		var res_h: float = (1.0 - strength) * orig_h + strength * eroded_h
		final_height[i] = res_h
		eroded_rock[i] = maxf(0.0, orig_h - res_h)

	return [final_height, eroded_rock, sediment]
