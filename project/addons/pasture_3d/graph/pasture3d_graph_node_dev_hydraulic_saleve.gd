# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevHydraulicSaleve — Pure GDScript Reference Oracle for Salève Hydraulic Erosion.
# Features Braun-Willett / FastScape control-point graph flow routing with scale-invariant implicit stream power incision.

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


## Pure GDScript reference solver implementation
static func solve_oracle(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_params: Dictionary) -> Array:
	var n: int = p_gw * p_gh
	if p_gw < 2 or p_gh < 2 or p_surface.size() != n:
		return [p_surface.duplicate(), PackedFloat32Array(), PackedFloat32Array()]

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

	var cell_dx: float = p_rect.size.x / float(maxi(p_gw, 1))
	var cell_dz: float = p_rect.size.y / float(maxi(p_gh, 1))

	var px_arr := PackedFloat32Array()
	px_arr.resize(n)
	var pz_arr := PackedFloat32Array()
	pz_arr.resize(n)
	var h_arr := PackedFloat32Array()
	h_arr.resize(n)
	var orig_h := PackedFloat32Array()
	orig_h.resize(n)

	for iz in range(p_gh):
		for ix in range(p_gw):
			var idx: int = iz * p_gw + ix
			var jx: float = _hash2d(ix, iz, p_seed) * 0.38
			var jz: float = _hash2d(ix, iz, p_seed + 1013) * 0.38
			px_arr[idx] = (float(ix) + 0.5 + jx) * cell_dx
			pz_arr[idx] = (float(iz) + 0.5 + jz) * cell_dz
			h_arr[idx] = p_surface[idx]
			orig_h[idx] = p_surface[idx]

	var n_dx: Array[int] = [-1, 1, 0, 0, -1, 1, -1, 1]
	var n_dz: Array[int] = [0, 0, -1, 1, -1, -1, 1, 1]

	var eroded_rock := PackedFloat32Array()
	eroded_rock.resize(n)
	eroded_rock.fill(0.0)

	var sediment_out := PackedFloat32Array()
	sediment_out.resize(n)
	sediment_out.fill(0.0)

	var flow := PackedFloat32Array()
	flow.resize(n)

	var sediment_accum := PackedFloat32Array()
	sediment_accum.resize(n)

	var order: Array[int] = []
	order.resize(n)

	for pass_idx in range(iterations):
		for i in range(n):
			order[i] = i

		order.sort_custom(func(a: int, b: int) -> bool:
			var ha: float = h_arr[a]
			var hb: float = h_arr[b]
			if not is_finite(ha): return false
			if not is_finite(hb): return true
			return ha > hb
		)

		flow.fill(1.0)
		sediment_accum.fill(0.0)

		for idx in order:
			var h_c: float = h_arr[idx]
			if not is_finite(h_c):
				continue
			var ix: int = idx % p_gw
			var iz: int = idx / p_gw
			var px: float = px_arr[idx]
			var pz: float = pz_arr[idx]

			var sum_drop: float = 0.0
			var drops: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
			var n_indices: Array[int] = [-1, -1, -1, -1, -1, -1, -1, -1]

			for k in range(8):
				var nx: int = ix + n_dx[k]
				var nz: int = iz + n_dz[k]
				if nx >= 0 and nx < p_gw and nz >= 0 and nz < p_gh:
					var n_idx: int = nz * p_gw + nx
					n_indices[k] = n_idx
					var h_n: float = h_arr[n_idx]
					if is_finite(h_n) and h_n < h_c:
						var dist: float = maxf(sqrt(pow(px_arr[n_idx] - px, 2.0) + pow(pz_arr[n_idx] - pz, 2.0)), 1.0e-4)
						var slope: float = (h_c - h_n) / dist

						if drainage_noise > 0.0:
							var pnoise: float = _hash2d(nx, nz, p_seed + pass_idx * 31 + k * 7)
							slope *= maxf(0.05, 1.0 + drainage_noise * pnoise)

						var w_drop: float = pow(slope, 1.3)
						drops[k] = w_drop
						sum_drop += w_drop

			if sum_drop > 1.0e-6:
				var my_flow: float = flow[idx]
				var my_sed: float = sediment_accum[idx]
				for k in range(8):
					if drops[k] > 0.0 and n_indices[k] >= 0:
						var n_idx: int = n_indices[k]
						var frac: float = drops[k] / sum_drop
						flow[n_idx] += my_flow * frac
						sediment_accum[n_idx] += my_sed * frac

		var next_h := h_arr.duplicate()

		for iz in range(p_gh):
			for ix in range(p_gw):
				var idx: int = iz * p_gw + ix
				var h_c: float = h_arr[idx]
				if not is_finite(h_c):
					continue
				var m_val: float = mask[idx] if has_mask else 1.0
				if m_val <= 0.001:
					continue

				var min_downhill: float = h_c
				var max_s: float = 0.0
				for k in range(8):
					var nx: int = ix + n_dx[k]
					var nz: int = iz + n_dz[k]
					if nx >= 0 and nx < p_gw and nz >= 0 and nz < p_gh:
						var n_idx: int = nz * p_gw + nx
						var h_n: float = h_arr[n_idx]
						if is_finite(h_n) and h_n < min_downhill:
							min_downhill = h_n
							var d: float = maxf(sqrt(pow(px_arr[n_idx] - px_arr[idx], 2.0) + pow(pz_arr[n_idx] - pz_arr[idx], 2.0)), 1.0e-4)
							var s: float = (h_c - h_n) / d
							if s > max_s: max_s = s

				var drop: float = h_c - min_downhill
				if drop > 1.0e-5:
					var a_accum: float = log(1.0 + maxf(0.0, flow[idx] - 1.0))
					var kp: float = erosion_strength * 0.15 * pow(maxf(a_accum, 0.1), drainage_exponent) * m_val
					if fine_erosion_strength > 0.0:
						kp += fine_erosion_strength * 0.1 * pow(maxf(max_s, 0.01), 0.8) * m_val

					var inc: float = (kp / (1.0 + kp)) * drop

					if shape_preservation > 0.0:
						var max_allowed_cut: float = 0.5 * orig_h[idx] / shape_preservation
						inc = minf(inc, maxf(0.0, max_allowed_cut))

					next_h[idx] = h_c - inc
					eroded_rock[idx] += inc
					sediment_accum[idx] += inc

				if max_s < 0.15 and sediment_accum[idx] > 0.0:
					var dep: float = sediment_strength * sediment_accum[idx] * (1.0 - max_s / 0.15) * m_val
					sediment_out[idx] += dep
					sediment_accum[idx] = maxf(0.0, sediment_accum[idx] - dep)

		if bank_smoothing > 0.0:
			for iz in range(1, p_gh - 1):
				for ix in range(1, p_gw - 1):
					var idx: int = iz * p_gw + ix
					if eroded_rock[idx] > 0.001 and is_finite(next_h[idx]):
						var avg: float = 0.25 * (next_h[iz * p_gw + ix - 1] + next_h[iz * p_gw + ix + 1] + next_h[(iz - 1) * p_gw + ix] + next_h[(iz + 1) * p_gw + ix])
						next_h[idx] = lerpf(next_h[idx], avg, bank_smoothing * 0.3)

		h_arr = next_h

	return [h_arr, eroded_rock, sediment_out]
