@tool
class_name Pasture3DGraphNodeDevMountainRangeRadial
extends Pasture3DGraphNode

## Development reference oracle for MountainRangeRadial.

@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

@export_range(0.0, 100.0, 0.1, "or_greater") var elevation: float = 25.0:
	set(v):
		elevation = maxf(v, 0.0)
		_param_changed()

@export_range(0.01, 32.0, 0.1) var kw_x: float = 4.0:
	set(v):
		kw_x = maxf(v, 0.01)
		_param_changed()

@export_range(0.01, 32.0, 0.1) var kw_y: float = 4.0:
	set(v):
		kw_y = maxf(v, 0.01)
		_param_changed()

@export_range(0.01, 1.0, 0.01) var half_width: float = 0.2:
	set(v):
		half_width = maxf(v, 0.01)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var angle_spread_ratio: float = 0.5:
	set(v):
		angle_spread_ratio = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(0.01, 2.0, 0.01) var core_size_ratio: float = 0.2:
	set(v):
		core_size_ratio = maxf(v, 0.01)
		_param_changed()

@export var center: Vector2 = Vector2(0.5, 0.5):
	set(v):
		center = v
		_param_changed()

@export_range(1, 16, 1) var octaves: int = 8:
	set(v):
		octaves = clampi(v, 1, 16)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var weight: float = 0.7:
	set(v):
		weight = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var persistence: float = 0.5:
	set(v):
		persistence = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(0.01, 4.0, 0.05) var lacunarity: float = 2.0:
	set(v):
		lacunarity = maxf(v, 0.01)
		_param_changed()


func op() -> StringName:
	return &"dev_mountain_range_radial"


func display_name() -> String:
	return "[Dev/GD] Mountain Range (Radial)"


func category() -> StringName:
	return &"Dev / Reference"


func input_count() -> int:
	return 4


func input_names() -> PackedStringArray:
	return PackedStringArray(["ctrl", "dx", "dy", "envelope"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.HEIGHT, PortType.HEIGHT, PortType.MASK])


func output_count() -> int:
	return 2


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "angle"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.VECTOR])


func _param_changed() -> void:
	emit_changed()


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var ctrl_in: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else PackedFloat32Array()
	var dx_in: PackedFloat32Array = (p_inputs[1] as PackedFloat32Array) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array) else PackedFloat32Array()
	var dy_in: PackedFloat32Array = (p_inputs[2] as PackedFloat32Array) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array) else PackedFloat32Array()
	var env_in: PackedFloat32Array = (p_inputs[3] as PackedFloat32Array) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array) else PackedFloat32Array()

	var params := {
		"seed": seed,
		"elevation": elevation,
		"kw_x": kw_x,
		"kw_y": kw_y,
		"half_width": half_width,
		"angle_spread_ratio": angle_spread_ratio,
		"core_size_ratio": core_size_ratio,
		"center": center,
		"octaves": octaves,
		"weight": weight,
		"persistence": persistence,
		"lacunarity": lacunarity,
		"ctrl_param": ctrl_in,
		"dx": dx_in,
		"dy": dy_in,
		"envelope": env_in,
	}

	return solve_oracle(p_gw, p_gh, p_rect, params)


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


static func _gabor_wave_scalar(x: float, y: float, dir_x: float, dir_y: float, angle_spread_ratio: float, seed_u: int) -> float:
	var ip_x: float = floor(x)
	var ip_y: float = floor(y)
	var fp_x: float = x - ip_x
	var fp_y: float = y - ip_y
	var i_ipx: int = int(ip_x)
	var i_ipy: int = int(ip_y)

	var av: float = 0.0
	var at: float = 0.0

	for j in range(-2, 3):
		for i in range(-2, 3):
			var h: Vector2 = _hash22(i_ipx + i, i_ipy + j, seed_u)
			var rx: float = fp_x - (float(i) + h.x)
			var ry: float = fp_y - (float(j) + h.y)

			var k_rand: Vector2 = _hash22(i_ipx + i + 11, i_ipy + j + 31, seed_u)
			var kx: float = dir_x + angle_spread_ratio * (2.0 * k_rand.x - 1.0)
			var ky: float = dir_y + angle_spread_ratio * (2.0 * k_rand.y - 1.0)
			var kn: float = sqrt(kx * kx + ky * ky)
			if kn > 1e-6:
				kx /= kn
				ky /= kn

			var d: float = rx * rx + ry * ry
			var l: float = rx * kx + ry * ky
			var w: float = exp(-4.0 * d)
			var cs: float = cos(6.2831853 * l)

			av += w * cs
			at += w

	return (av / at) if (at > 1e-6) else 0.0


static func _gabor_wave_scalar_fbm(x: float, y: float, dir_x: float, dir_y: float, angle_spread_ratio: float,
		octaves: int, weight: float, persistence: float, lacunarity: float, seed_u: int) -> float:
	var n: float = 0.0
	var nf: float = 1.0
	var na: float = 0.6
	for o in range(octaves):
		var v: float = _gabor_wave_scalar(x * nf, y * nf, dir_x, dir_y, angle_spread_ratio, seed_u + o * 5437)
		n += v * na
		na *= (1.0 - weight) + weight * minf(v + 1.0, 2.0) * 0.5
		na *= persistence
		nf *= lacunarity
	return n


static func solve_oracle(p_gw: int, p_gh: int, _p_rect: Rect2, p_params: Dictionary) -> Array:
	var n: int = p_gw * p_gh
	var out_h := PackedFloat32Array()
	out_h.resize(n)
	var out_a := PackedFloat32Array()
	out_a.resize(n)

	var s_val: int = int(p_params.get("seed", 0))
	var elevation_val: float = float(p_params.get("elevation", 25.0))
	var kw_x_val: float = maxf(0.01, float(p_params.get("kw_x", 4.0)))
	var kw_y_val: float = maxf(0.01, float(p_params.get("kw_y", 4.0)))
	var half_width_val: float = maxf(0.01, float(p_params.get("half_width", 0.2)))
	var angle_spread_ratio_val: float = clampf(float(p_params.get("angle_spread_ratio", 0.5)), 0.0, 1.0)
	var core_size_ratio_val: float = maxf(0.01, float(p_params.get("core_size_ratio", 0.2)))
	var center_val: Vector2 = p_params.get("center", Vector2(0.5, 0.5))
	var octaves_val: int = clampi(int(p_params.get("octaves", 8)), 1, 16)
	var weight_val: float = clampf(float(p_params.get("weight", 0.7)), 0.0, 1.0)
	var persistence_val: float = clampf(float(p_params.get("persistence", 0.5)), 0.0, 1.0)
	var lacunarity_val: float = maxf(0.01, float(p_params.get("lacunarity", 2.0)))

	var ctrl_param: PackedFloat32Array = p_params.get("ctrl_param", PackedFloat32Array())
	var dx: PackedFloat32Array = p_params.get("dx", PackedFloat32Array())
	var dy: PackedFloat32Array = p_params.get("dy", PackedFloat32Array())
	var env: PackedFloat32Array = p_params.get("envelope", PackedFloat32Array())
	var has_ctrl: bool = (ctrl_param.size() == n)
	var has_dx: bool = (dx.size() == n)
	var has_dy: bool = (dy.size() == n)
	var has_env: bool = (env.size() == n)

	var seed_u: int = _wang_hash(s_val)
	var r2_max: float = core_size_ratio_val / maxf(0.01, maxf(kw_x_val, kw_y_val))
	var hw2: float = maxf(1e-5, half_width_val * half_width_val)

	for iz in range(p_gh):
		var ny: float = float(iz) / float(p_gh - 1) if p_gh > 1 else 0.5
		for ix in range(p_gw):
			var nx: float = float(ix) / float(p_gw - 1) if p_gw > 1 else 0.5
			var idx: int = iz * p_gw + ix

			var ct: float = ctrl_param[idx] if has_ctrl else 1.0
			var dx_val: float = dx[idx] if has_dx else 0.0
			var dy_val: float = dy[idx] if has_dy else 0.0

			var px: float = (nx + dx_val) * kw_x_val
			var py: float = (ny + dy_val) * kw_y_val

			var cx: float = nx - center_val.x
			var cy: float = ny - center_val.y
			var r2: float = cx * cx + cy * cy
			var amp: float = env[idx] if has_env else exp(-0.5 * r2 / hw2)

			var theta: float = atan2(cy, cx) + 1.5707963268
			var dir_x: float = cos(theta)
			var dir_y: float = sin(theta)

			ct *= amp
			var eff_weight: float = (1.0 - ct) + ct * weight_val
			var noise: float = _gabor_wave_scalar_fbm(px, py, dir_x, dir_y, angle_spread_ratio_val,
					octaves_val, eff_weight, persistence_val, lacunarity_val, seed_u)

			var t: float = minf(1.0, r2 / maxf(1e-5, r2_max))
			t = sqrt(t) * (1.0 - exp(-500.0 * t))
			t = clampf(t, 0.0, 1.0)
			t = t * t * (3.0 - 2.0 * t)

			out_h[idx] = amp * lerp(1.0, 0.5 * noise + 0.5, t) * elevation_val
			out_a[idx] = theta

	return [out_h, out_a]
