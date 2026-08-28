# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevHydraulicSaleve — Pure GDScript Reference Oracle for Salève Hydraulic Erosion.
# Features structural joint fracture alignment, crest curvature preservation, and sediment deposition.

@tool
class_name Pasture3DGraphNodeDevHydraulicSaleve
extends Pasture3DGraphNode

enum Evaluation { LIVE, FROZEN }

@export_group("Simulation")
@export_range(1, 50, 1, "or_greater") var iterations: int = 20:
	set(v):
		iterations = maxi(v, 1)
		_param_changed()

@export_range(0.01, 2.0, 0.01, "or_greater") var incision_rate: float = 0.2:
	set(v):
		incision_rate = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 360.0, 1.0) var joint_azimuth: float = 45.0:
	set(v):
		joint_azimuth = fmod(v, 360.0)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var joint_strength: float = 0.4:
	set(v):
		joint_strength = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var ridge_preservation: float = 0.8:
	set(v):
		ridge_preservation = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var deposition_rate: float = 0.3:
	set(v):
		deposition_rate = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(0.0, 0.5, 0.01) var bank_smoothing: float = 0.1:
	set(v):
		bank_smoothing = clampf(v, 0.0, 0.5)
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
	return PackedStringArray(["in", "mask", "iterations", "joint_azimuth", "joint_strength"])


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
		3: return joint_azimuth
		4: return joint_strength
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
	var az: float = float(p_inputs[3][0]) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and p_inputs[3].size() > 0) else joint_azimuth
	var js: float = float(p_inputs[4][0]) if (p_inputs.size() > 4 and p_inputs[4] is PackedFloat32Array and p_inputs[4].size() > 0) else joint_strength

	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)

	var p := {
		"iterations": iters,
		"incision_rate": incision_rate,
		"joint_azimuth": az,
		"joint_strength": js,
		"ridge_preservation": ridge_preservation,
		"deposition_rate": deposition_rate,
		"bank_smoothing": bank_smoothing,
		"mask": mask_in,
	}

	return solve_oracle(surface, p_gw, p_gh, p_rect, p)


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func _param_changed() -> void:
	if not _cache.is_empty():
		_dirty_since_bake = true
	emit_changed()


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

	var iterations: int = maxi(1, int(p_params.get("iterations", 20)))
	var incision_rate: float = maxf(0.0, float(p_params.get("incision_rate", 0.2)))
	var joint_azimuth: float = float(p_params.get("joint_azimuth", 45.0))
	var joint_strength: float = clampf(float(p_params.get("joint_strength", 0.4)), 0.0, 1.0)
	var ridge_preservation: float = clampf(float(p_params.get("ridge_preservation", 0.8)), 0.0, 1.0)
	var deposition_rate: float = clampf(float(p_params.get("deposition_rate", 0.3)), 0.0, 1.0)
	var bank_smoothing: float = clampf(float(p_params.get("bank_smoothing", 0.1)), 0.0, 0.5)

	var dx: float = p_rect.size.x / float(maxi(p_gw, 1))
	var dz: float = p_rect.size.y / float(maxi(p_gh, 1))
	var diag_dist: float = sqrt(dx * dx + dz * dz)

	var n_dx: Array[int] = [-1, 1, 0, 0, -1, 1, -1, 1]
	var n_dz: Array[int] = [0, 0, -1, 1, -1, -1, 1, 1]
	var n_dist: Array[float] = [dx, dx, dz, dz, diag_dist, diag_dist, diag_dist, diag_dist]

	# Precompute joint alignment angle factors
	var joint_rad: float = deg_to_rad(joint_azimuth)
	var joint_ux: float = sin(joint_rad)
	var joint_uz: float = -cos(joint_rad)
	var joint_weights: Array[float] = []
	joint_weights.resize(8)
	for k in range(8):
		var nx_dir: float = float(n_dx[k]) * dx / n_dist[k]
		var nz_dir: float = float(n_dz[k]) * dz / n_dist[k]
		var dot: float = absf(nx_dir * joint_ux + nz_dir * joint_uz) # [0..1]
		joint_weights[k] = (1.0 - joint_strength) + joint_strength * dot

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

		# 2. Accumulate drainage flow with joint-biased weighting
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
						var weighted_drop: float = pow(drop, 1.2) * joint_weights[k]
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

		# 3. Compute Salève Incision with Ridge Curvature Shielding & Lateral Bank Width
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

				# 2D discrete Laplacian curvature (convex ridge = negative)
				var lap: float = (h_l + h_r - 2.0 * h_c) / (dx * dx) + (h_u + h_d - 2.0 * h_c) / (dz * dz)
				var ridge_shield: float = 1.0
				if lap < 0.0:
					# Ridge crest — shield from erosion
					ridge_shield = maxf(0.0, 1.0 - ridge_preservation * clampf(-lap * dx * 0.5, 0.0, 1.0))

				var flow_val: float = current_flow[idx]
				var a_accum: float = log(1.0 + maxf(0.0, flow_val - 1.0))

				if a_accum > 0.01 and slope > 1.0e-5:
					var power: float = sqrt(a_accum) * slope
					var incision: float = incision_rate * log(1.0 + power) * ridge_shield * m_val

					var center_w: float = 1.0 - bank_smoothing * 0.6
					var neigh_w: float = (bank_smoothing * 0.6) * 0.25

					incision_map[idx] += incision * center_w
					if ix > 0: incision_map[row + ix - 1] += incision * neigh_w
					if ix < p_gw - 1: incision_map[row + ix + 1] += incision * neigh_w
					if iz > 0: incision_map[(iz - 1) * p_gw + ix] += incision * neigh_w
					if iz < p_gh - 1: incision_map[(iz + 1) * p_gw + ix] += incision * neigh_w

					# Add eroded rock to sediment flux
					current_sediment[idx] += incision

				# Deposition in flat / low-slope basins
				if slope < 0.2 and current_sediment[idx] > 0.0:
					var dep: float = deposition_rate * current_sediment[idx] * (1.0 - slope / 0.2) * m_val
					dep_map[idx] += dep
					current_sediment[idx] = maxf(0.0, current_sediment[idx] - dep)

		# 4. Apply incision & deposition
		var next_height := height.duplicate()
		for iz in range(p_gh):
			var row: int = iz * p_gw
			for ix in range(p_gw):
				var idx: int = row + ix
				var h_c: float = height[idx]
				if not is_finite(h_c):
					continue

				var cut: float = incision_map[idx]
				var dep: float = dep_map[idx]

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
					var max_cut: float = maxf(0.0, (h_c - min_downhill) + 0.05 * cut)
					cut = minf(cut, max_cut)
					eroded_rock[idx] += cut

				var h_next: float = h_c - cut + dep
				next_height[idx] = h_next
				sediment[idx] += dep

		height = next_height

	return [height, eroded_rock, sediment]
