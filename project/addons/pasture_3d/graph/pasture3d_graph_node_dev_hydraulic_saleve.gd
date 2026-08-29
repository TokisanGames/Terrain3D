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

@export_range(0.05, 4.0, 0.05) var shape_preservation: float = 2.0:
	set(v):
		shape_preservation = clampf(v, 0.05, 4.0)
		_param_changed()

## Vertical scale (metres) every length is measured against; 0 = the input's own relief. Mirrors the
## native node's Reference Relief.
@export_range(0.0, 500.0, 1.0, "or_greater", "suffix:m") var reference_relief: float = 0.0:
	set(v):
		reference_relief = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 0.5, 0.01) var bank_smoothing: float = 0.1:
	set(v):
		bank_smoothing = clampf(v, 0.0, 0.5)
		_param_changed()

@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

@export_group("Sediment Deposition (Stage 2)")
## Alluvial hole-filling radius in METRES (mirrors the native node).
@export_range(0.0, 200.0, 0.5, "or_greater", "suffix:m") var deposition_radius: float = 25.0:
	set(v):
		deposition_radius = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var deposition_strength: float = 0.5:
	set(v):
		deposition_strength = clampf(v, 0.0, 1.0)
		_param_changed()

@export_group("Fine River Incision (Stage 3)")
@export_range(0.0, 1.0, 0.005) var stream_strength: float = 0.02:
	set(v):
		stream_strength = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(0.01, 1.0, 0.01) var stream_exp: float = 0.8:
	set(v):
		stream_exp = clampf(v, 0.01, 1.0)
		_param_changed()

@export_group("Post-Processing (Stage 4)")
@export var enable_post_smoothing: bool = false:
	set(v):
		enable_post_smoothing = v
		_param_changed()

@export_range(0.0, 5.0, 0.05) var gain: float = 1.0:
	set(v):
		gain = maxf(v, 0.0)
		_param_changed()

@export_range(0.1, 4.0, 0.05) var gamma: float = 1.0:
	set(v):
		gamma = maxf(v, 0.01)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var mix_factor: float = 1.0:
	set(v):
		mix_factor = clampf(v, 0.0, 1.0)
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
	return 4


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "dx", "dy", "mask"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.HEIGHT,
		PortType.FLOAT,
		PortType.FLOAT,
		PortType.MASK,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return 0.0
		2: return 0.0
		3: return 1.0
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
	var dx_in: PackedFloat32Array = (p_inputs[1] as PackedFloat32Array) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array) else PackedFloat32Array()
	var dy_in: PackedFloat32Array = (p_inputs[2] as PackedFloat32Array) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array) else PackedFloat32Array()
	var mask_in: PackedFloat32Array = (p_inputs[3] as PackedFloat32Array) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array) else PackedFloat32Array()

	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)

	var p := {
		"iterations": iterations,
		"erosion_strength": erosion_strength,
		"drainage_exponent": drainage_exponent,
		"drainage_noise": drainage_noise,
		"shape_preservation": shape_preservation,
		"reference_relief": reference_relief,
		"bank_smoothing": bank_smoothing,
		"seed": seed,
		"dx": dx_in,
		"dy": dy_in,
		"mask": mask_in,
		"deposition_radius": deposition_radius,
		"deposition_strength": deposition_strength,
		"stream_strength": stream_strength,
		"stream_exp": stream_exp,
		"enable_post_smoothing": enable_post_smoothing,
		"gain": gain,
		"gamma": gamma,
		"mix_factor": mix_factor,
	}

	return solve_gd(surface, p_gw, p_gh, p_rect, p)


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


# ---- Pure GDScript Reference Oracle ----------------------------------------------------------------

static func _fast_hash_to_unit(p_seed: int, key: int) -> float:
	var n: int = (p_seed ^ (key * 0x5bd1e995)) & 0xffffffff
	n = (n ^ (n >> 13)) * 0x5bd1e995 & 0xffffffff
	n = (n ^ (n >> 15)) & 0xffffffff
	return float((n & 0x00ffffff)) / 8388608.0 - 1.0


static func solve_gd(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_params: Dictionary) -> Array:
	var n: int = p_gw * p_gh
	if p_surface.size() != n or p_gw < 2 or p_gh < 2:
		var empty := PackedFloat32Array()
		empty.resize(n)
		empty.fill(0.0)
		return [p_surface.duplicate(), empty.duplicate(), empty]

	var mask: PackedFloat32Array = p_params.get("mask", PackedFloat32Array())
	var has_mask: bool = (mask.size() == n)
	var dx_arr: PackedFloat32Array = p_params.get("dx", PackedFloat32Array())
	var dy_arr: PackedFloat32Array = p_params.get("dy", PackedFloat32Array())
	var has_dx: bool = (dx_arr.size() == n)
	var has_dy: bool = (dy_arr.size() == n)

	var iters: int = maxi(1, int(p_params.get("iterations", 25)))
	var erosion_strength: float = clampf(float(p_params.get("erosion_strength", 0.5)), 0.0, 1.0)
	var m_exp: float = clampf(float(p_params.get("drainage_exponent", 0.15)), 0.01, 0.8)
	var noise_strength: float = maxf(0.0, float(p_params.get("drainage_noise", 0.15)))
	var shape_preservation: float = clampf(float(p_params.get("shape_preservation", 2.0)), 0.1, 4.0)
	var bank_smoothing: float = clampf(float(p_params.get("bank_smoothing", 0.1)), 0.0, 0.5)
	var p_seed: int = int(p_params.get("seed", 0))

	var reference_relief: float = maxf(0.0, float(p_params.get("reference_relief", 0.0)))
	var dep_radius: float = maxf(0.0, float(p_params.get("deposition_radius", 25.0)))
	var dep_strength: float = clampf(float(p_params.get("deposition_strength", 0.5)), 0.0, 1.0)
	var str_strength: float = clampf(float(p_params.get("stream_strength", 0.02)), 0.0, 1.0)
	var str_exp: float = clampf(float(p_params.get("stream_exp", 0.8)), 0.01, 1.0)
	var enable_post_smooth: bool = bool(p_params.get("enable_post_smoothing", false))
	var gain_val: float = maxf(0.0, float(p_params.get("gain", 1.0)))
	var gamma_val: float = maxf(0.01, float(p_params.get("gamma", 1.0)))
	var mix_val: float = clampf(float(p_params.get("mix_factor", 1.0)), 0.0, 1.0)

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
	# The solver's unit of length: a vertical scale in metres that every horizontal distance is divided by,
	# so slopes are true gradients and the grid's cell COUNT enters nothing. 0 = take it from the input's
	# own relief (moves with the solved extent — a Modifier Margin brings surrounding ground into range).
	# Mirrors hydraulic_saleve_solve; the parity gate compares the two.
	var relief_ref: float = reference_relief if reference_relief > 0.0 else zptp
	var vref: float = maxf(relief_ref, 1.0e-5)
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
			erodibility[idx] = pow(clampf(1.0 - (h - zmin) / vref, 0.01, 1.0), shape_preservation)
			is_outlet[idx] = (ix == 0 or ix == p_gw - 1 or iz == 0 or iz == p_gh - 1)

	var cell_dx: float = (p_rect.size.x / float(maxi(p_gw, 1))) if p_rect.size.x > 0.0 else 1.0
	var cell_dz: float = (p_rect.size.y / float(maxi(p_gh, 1))) if p_rect.size.y > 0.0 else 1.0
	var dx: float = cell_dx / vref
	var dz: float = cell_dz / vref
	var diag_dist: float = sqrt(dx * dx + dz * dz)
	var cell_area: float = dx * dz
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

	# Stage 1: Steady-State LEM solve
	for iter in range(iters):
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
							var warp_factor: float = 1.0
							if has_dx and has_dy:
								warp_factor += 0.5 * (dx_arr[idx] * float(n_dx[k]) + dy_arr[idx] * float(n_dz[k]))
							var score: float = slope * (warp_factor + noise_strength * noise)
							if score > best_score:
								best_score = score
								best_k = n_idx
				receivers[idx] = best_k

		for i in range(n):
			order[i] = i
		order.sort_custom(func(a: int, b: int) -> bool:
			return z[a] > z[b]
		)
		area_acc.fill(cell_area)
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
				var celerity: float = erodibility[idx] * pow(maxf(area_acc[idx], cell_area), m_exp)
				response_times[idx] = response_times[r] + (d / maxf(celerity, 1.0e-4))
			else:
				response_times[idx] = 0.0
		var diff: float = 0.0
		for i in range(n - 1, -1, -1):
			var idx: int = order[i]
			var r: int = receivers[idx]
			if r == idx: continue
			var new_z: float = z[r] + (response_times[idx] - response_times[r]) * 0.05
			var ix: int = idx % p_gw
			var iz: int = idx / p_gw
			var rx: int = r % p_gw
			var rz: int = r / p_gw
			var d: float = maxf(sqrt(pow(float(ix - rx) * dx, 2.0) + pow(float(iz - rz) * dz, 2.0)), 1.0e-5)
			var slope: float = (new_z - z[r]) / d
			if slope > 4.0: new_z = z[r] + 4.0 * d
			diff += absf(new_z - z[idx])
			z[idx] = new_z
		if diff / float(n) < 1.0e-4: break

	var ze_min: float = INF
	var ze_max: float = -INF
	for v in z:
		if v < ze_min: ze_min = v
		if v > ze_max: ze_max = v
	var ze_span: float = maxf(ze_max - ze_min, 1.0e-5)
	for i in range(n):
		z[i] = (z[i] - ze_min) / ze_span

	# Stage 2: Sediment Deposition
	var sediment := PackedFloat32Array()
	sediment.resize(n)
	sediment.fill(0.0)

	if dep_strength > 0.0 and dep_radius > 0.0:
		var cell_m: float = maxf(minf(cell_dx, cell_dz), 1.0e-4)
		var ir: int = maxi(1, int(round(dep_radius / cell_m)))
		ir = mini(ir, maxi(1, mini(p_gw, p_gh) / 2))
		var z_fill := z.duplicate()
		for iz in range(p_gh):
			for ix in range(p_gw):
				var idx: int = iz * p_gw + ix
				var max_n: float = z_fill[idx]
				for dy_i in range(-ir, ir + 1):
					var ny: int = iz + dy_i
					if ny < 0 or ny >= p_gh: continue
					for dx_i in range(-ir, ir + 1):
						var nx: int = ix + dx_i
						if nx < 0 or nx >= p_gw: continue
						if dx_i * dx_i + dy_i * dy_i <= ir * ir:
							max_n = maxf(max_n, z_fill[ny * p_gw + nx])
				z_fill[idx] = 0.5 * (z_fill[idx] + max_n)

		for i in range(n):
			var d_val: float = maxf(0.0, z_fill[i] - z[i])
			var dep: float = dep_strength * d_val
			z[i] += dep
			sediment[i] = dep * relief_ref

	# Stage 3: Fine Stream Power Incision
	if str_strength > 0.0:
		for idx in order:
			var r: int = receivers[idx]
			if r != idx:
				var ix: int = idx % p_gw
				var iz: int = idx / p_gw
				var rx: int = r % p_gw
				var rz: int = r / p_gw
				var d: float = maxf(sqrt(pow(float(ix - rx) * dx, 2.0) + pow(float(iz - rz) * dz, 2.0)), 1.0e-5)
				var slope: float = maxf(0.0, (z[idx] - z[r]) / d)
				var stream_inc: float = str_strength * log(1.0 + pow(maxf(area_acc[idx], cell_area), str_exp) * slope) * erodibility[idx] * 0.15
				z[idx] = maxf(z[r], z[idx] - stream_inc)

	# Stage 4: Post-Processing & Tonal Controls
	if enable_post_smooth or bank_smoothing > 0.0:
		var smoothed := z.duplicate()
		var blend: float = 0.3 if enable_post_smooth else (bank_smoothing * 0.4)
		for iz in range(1, p_gh - 1):
			for ix in range(1, p_gw - 1):
				var idx: int = iz * p_gw + ix
				var avg: float = 0.25 * (z[iz * p_gw + ix - 1] + z[iz * p_gw + ix + 1] +
						z[(iz - 1) * p_gw + ix] + z[(iz + 1) * p_gw + ix])
				smoothed[idx] = (1.0 - blend) * z[idx] + blend * avg
		z = smoothed

	if gamma_val != 1.0 or gain_val != 1.0:
		for i in range(n):
			z[i] = gain_val * pow(clampf(z[i], 0.0, 1.0), gamma_val)

	var final_height := PackedFloat32Array()
	final_height.resize(n)
	var eroded_rock := PackedFloat32Array()
	eroded_rock.resize(n)

	for i in range(n):
		var orig_h: float = p_surface[i]
		if not is_finite(orig_h):
			final_height[i] = orig_h
			eroded_rock[i] = 0.0
			continue

		var eroded_h: float = zmin + z[i] * relief_ref
		var m_val: float = mask[i] if has_mask else 1.0
		var eff_weight: float = erosion_strength * mix_val * m_val

		var res_h: float = (1.0 - eff_weight) * orig_h + eff_weight * eroded_h
		final_height[i] = res_h
		eroded_rock[i] = maxf(0.0, orig_h - res_h)

	return [final_height, eroded_rock, sediment]


func _param_changed() -> void:
	if not _cache.is_empty():
		_dirty_since_bake = true
	emit_changed()
