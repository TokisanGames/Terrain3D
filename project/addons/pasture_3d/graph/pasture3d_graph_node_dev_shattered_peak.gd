@tool
class_name Pasture3DGraphNodeDevShatteredPeak
extends Pasture3DGraphNode

## Development reference oracle for ShatteredPeak.

@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

@export_range(0.0, 100.0, 0.1, "or_greater") var elevation: float = 25.0:
	set(v):
		elevation = maxf(v, 0.0)
		_param_changed()

@export_range(0.01, 10.0, 0.05) var scale: float = 1.0:
	set(v):
		scale = maxf(v, 0.01)
		_param_changed()

@export_range(1, 16, 1) var octaves: int = 8:
	set(v):
		octaves = clampi(v, 1, 16)
		_param_changed()

@export_range(0.1, 16.0, 0.1) var peak_kw: float = 4.0:
	set(v):
		peak_kw = maxf(v, 0.1)
		_param_changed()

@export_range(0.0, 1.0, 0.05) var rugosity: float = 0.0:
	set(v):
		rugosity = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(-180.0, 180.0, 1.0) var angle: float = 45.0:
	set(v):
		angle = v
		_param_changed()

@export_range(0.01, 4.0, 0.05) var gamma: float = 0.5:
	set(v):
		gamma = maxf(v, 0.01)
		_param_changed()

@export_range(0.0, 2.0, 0.05) var bulk_amp: float = 0.5:
	set(v):
		bulk_amp = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 0.5, 0.01) var base_noise_amp: float = 0.05:
	set(v):
		base_noise_amp = v
		_param_changed()

@export_range(0.001, 0.5, 0.005) var k_smoothing: float = 0.05:
	set(v):
		k_smoothing = maxf(v, 0.001)
		_param_changed()

@export var center: Vector2 = Vector2(0.5, 0.5):
	set(v):
		center = v
		_param_changed()


func op() -> StringName:
	return &"dev_shattered_peak"


func display_name() -> String:
	return "[Dev/GD] Shattered Peak"


func category() -> StringName:
	return &"Dev / Reference"


func input_count() -> int:
	return 2


func input_names() -> PackedStringArray:
	return PackedStringArray(["dx", "dy"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.HEIGHT])


func output_count() -> int:
	return 1


func output_names() -> PackedStringArray:
	return PackedStringArray(["out"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT])


func _param_changed() -> void:
	emit_changed()


func needs_grid() -> bool:
	return true


func role() -> Role:
	return Role.GENERATOR


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var dx_in: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else PackedFloat32Array()
	var dy_in: PackedFloat32Array = (p_inputs[1] as PackedFloat32Array) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array) else PackedFloat32Array()

	var params := {
		"seed": seed,
		"elevation": elevation,
		"scale": scale,
		"octaves": octaves,
		"peak_kw": peak_kw,
		"rugosity": rugosity,
		"angle": angle,
		"gamma": gamma,
		"bulk_amp": bulk_amp,
		"base_noise_amp": base_noise_amp,
		"k_smoothing": k_smoothing,
		"center": center,
		"dx": dx_in,
		"dy": dy_in,
	}

	return [solve_oracle(p_gw, p_gh, p_rect, params)]


static func _wang_hash(seed_u: int) -> int:
	var s: int = (seed_u ^ 61) ^ (seed_u >> 16)
	s = (s * 9) & 0xFFFFFFFF
	s = s ^ (s >> 4)
	s = (s * 0x27d4eb2d) & 0xFFFFFFFF
	s = s ^ (s >> 15)
	return s & 0xFFFFFFFF


static func _hash22(ix: int, iy: int, seed_u: int) -> Vector2:
	var ux: int = (ix * 0x8da6b343) & 0xFFFFFFFF
	var uy: int = (iy * 0xd8163841) & 0xFFFFFFFF
	var h1: int = (ux ^ uy ^ seed_u) & 0xFFFFFFFF
	h1 ^= (h1 >> 13)
	h1 = (h1 * 0x85ebca6b) & 0xFFFFFFFF
	h1 ^= (h1 >> 16)
	var ox: float = float(h1 & 0xFFFFFF) / 16777216.0

	var h2: int = ((ux ^ 0x5bd1e995) ^ uy ^ (seed_u + 1013904223)) & 0xFFFFFFFF
	h2 ^= (h2 >> 13)
	h2 = (h2 * 0x85ebca6b) & 0xFFFFFFFF
	h2 ^= (h2 >> 16)
	var oy: float = float(h2 & 0xFFFFFF) / 16777216.0

	return Vector2(ox, oy)


static func _simplex2_raw(xin: float, yin: float, seed_u: int) -> float:
	var F2: float = 0.5 * (sqrt(3.0) - 1.0)
	var G2: float = (3.0 - sqrt(3.0)) / 6.0
	var s: float = (xin + yin) * F2
	var i: int = int(floor(xin + s))
	var j: int = int(floor(yin + s))
	var t: float = float(i + j) * G2
	var X0: float = float(i) - t
	var Y0: float = float(j) - t
	var x0: float = xin - X0
	var y0: float = yin - Y0

	var i1: int = 1 if x0 > y0 else 0
	var j1: int = 0 if x0 > y0 else 1

	var x1: float = x0 - float(i1) + G2
	var y1: float = y0 - float(j1) + G2
	var x2: float = x0 - 1.0 + 2.0 * G2
	var y2: float = y0 - 1.0 + 2.0 * G2

	var n0: float = 0.0
	var n1: float = 0.0
	var n2: float = 0.0

	var t0: float = 0.5 - x0 * x0 - y0 * y0
	if t0 > 0.0:
		t0 *= t0
		var h_vec: Vector2 = _hash22(i, j, seed_u)
		var h: float = h_vec.x * 6.2831853
		n0 = t0 * t0 * (cos(h) * x0 + sin(h) * y0)

	var t1: float = 0.5 - x1 * x1 - y1 * y1
	if t1 > 0.0:
		t1 *= t1
		var h_vec: Vector2 = _hash22(i + i1, j + j1, seed_u)
		var h: float = h_vec.x * 6.2831853
		n1 = t1 * t1 * (cos(h) * x1 + sin(h) * y1)

	var t2: float = 0.5 - x2 * x2 - y2 * y2
	if t2 > 0.0:
		t2 *= t2
		var h_vec: Vector2 = _hash22(i + 1, j + 1, seed_u)
		var h: float = h_vec.x * 6.2831853
		n2 = t2 * t2 * (cos(h) * x2 + sin(h) * y2)

	return 70.0 * (n0 + n1 + n2)


static func _simplex2_fbm(x: float, y: float, octaves: int, persistence: float, lacunarity: float, seed_u: int) -> float:
	var total: float = 0.0
	var amp: float = 1.0
	var freq: float = 1.0
	var max_amp: float = 0.0
	for o in range(octaves):
		total += amp * _simplex2_raw(x * freq, y * freq, seed_u + o * 7919)
		max_amp += amp
		amp *= persistence
		freq *= lacunarity
	return (total / max_amp) if max_amp > 0.0 else 0.0


static func _voronoi_edge_distance_raw(x: float, y: float, seed_u: int) -> float:
	var px: float = floor(x)
	var py: float = floor(y)
	var fx: float = x - px
	var fy: float = y - py

	var ipx: int = int(px)
	var ipy: int = int(py)

	var mbx: int = 0
	var mby: int = 0
	var mr_x: float = 0.0
	var mr_y: float = 0.0
	var md: float = 8.0

	for j in range(-1, 2):
		for i in range(-1, 2):
			var bx: float = float(i)
			var by: float = float(j)
			var h_vec: Vector2 = _hash22(ipx + i, ipy + j, seed_u)
			var rx: float = bx - fx + h_vec.x
			var ry: float = by - fy + h_vec.y
			var d: float = rx * rx + ry * ry
			if d < md:
				md = d
				mr_x = rx
				mr_y = ry
				mbx = i
				mby = j

	var res: float = 8.0
	for j in range(-2, 3):
		for i in range(-2, 3):
			var bx: float = float(mbx + i)
			var by: float = float(mby + j)
			var h_vec: Vector2 = _hash22(ipx + mbx + i, ipy + mby + j, seed_u)
			var rx: float = bx - fx + h_vec.x
			var ry: float = by - fy + h_vec.y

			var diff_x: float = rx - mr_x
			var diff_y: float = ry - mr_y
			if diff_x * diff_x + diff_y * diff_y > 1e-6:
				var mid_x: float = 0.5 * (mr_x + rx)
				var mid_y: float = 0.5 * (mr_y + ry)
				var norm: float = sqrt(diff_x * diff_x + diff_y * diff_y)
				var dir_x: float = (rx - mr_x) / norm
				var dir_y: float = (ry - mr_y) / norm
				var d: float = mid_x * dir_x + mid_y * dir_y
				res = minf(res, d)

	return maxf(0.0, res)


static func _voronoi_edge_fbm(x: float, y: float, octaves: int, persistence: float, lacunarity: float, seed_u: int) -> float:
	var total: float = 0.0
	var amp: float = 1.0
	var freq: float = 1.0
	var max_amp: float = 0.0
	for o in range(octaves):
		total += amp * _voronoi_edge_distance_raw(x * freq, y * freq, seed_u + o * 6271)
		max_amp += amp
		amp *= persistence
		freq *= lacunarity
	return (total / max_amp) if max_amp > 0.0 else 0.0


static func solve_oracle(p_gw: int, p_gh: int, _p_rect: Rect2, p_params: Dictionary) -> PackedFloat32Array:
	var n: int = p_gw * p_gh
	var out := PackedFloat32Array()
	out.resize(n)

	var s_val: int = int(p_params.get("seed", 0))
	var elevation_val: float = float(p_params.get("elevation", 25.0))
	var scale_val: float = maxf(0.01, float(p_params.get("scale", 1.0)))
	var octaves_val: int = clampi(int(p_params.get("octaves", 8)), 1, 16)
	var peak_kw_val: float = maxf(0.1, float(p_params.get("peak_kw", 4.0)))
	var angle_val: float = float(p_params.get("angle", 45.0))
	var gamma_val: float = maxf(0.01, float(p_params.get("gamma", 0.5)))
	var bulk_amp_val: float = maxf(0.0, float(p_params.get("bulk_amp", 0.5)))
	var base_noise_amp_val: float = float(p_params.get("base_noise_amp", 0.05))
	var center_val: Vector2 = p_params.get("center", Vector2(0.5, 0.5))

	var dx: PackedFloat32Array = p_params.get("dx", PackedFloat32Array())
	var dy: PackedFloat32Array = p_params.get("dy", PackedFloat32Array())
	var has_dx: bool = (dx.size() == n)
	var has_dy: bool = (dy.size() == n)

	var half_width: float = 0.2 * scale_val
	var kw: float = peak_kw_val / scale_val
	var persistence: float = 0.5
	var lacunarity: float = 2.0
	var alpha: float = angle_val * 0.0174532925
	var seed_u: int = _wang_hash(s_val)

	for iz in range(p_gh):
		var ny: float = float(iz) / float(p_gh - 1) if p_gh > 1 else 0.5
		for ix in range(p_gw):
			var nx: float = float(ix) / float(p_gw - 1) if p_gw > 1 else 0.5
			var idx: int = iz * p_gw + ix

			var base_n: float = scale_val * base_noise_amp_val * _simplex2_fbm(nx * kw, ny * kw, octaves_val, persistence, lacunarity, seed_u)
			var disp_x: float = base_n * cos(alpha) + (dx[idx] if has_dx else 0.0)
			var disp_y: float = base_n * sin(alpha) + (dy[idx] if has_dy else 0.0)

			var cx: float = nx + disp_x * 0.1 - center_val.x
			var cy: float = ny + disp_y * 0.1 - center_val.y
			var r2: float = (cx * cx + cy * cy) / maxf(1e-5, half_width * half_width)
			var pulse: float = exp(-0.5 * r2)

			var vx: float = (nx + disp_x) * kw
			var vy: float = (ny + disp_y) * kw
			var vor: float = _voronoi_edge_fbm(vx, vy, octaves_val, persistence, lacunarity, seed_u + 89)
			vor = (vor * pulse + bulk_amp_val * pulse) / (0.5 + bulk_amp_val)

			if gamma_val > 0.0:
				vor = pow(maxf(0.0, vor), gamma_val)

			out[idx] = vor * elevation_val

	return out
