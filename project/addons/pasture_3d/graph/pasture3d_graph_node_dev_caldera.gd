@tool
class_name Pasture3DGraphNodeDevCaldera
extends Pasture3DGraphNode

## Development reference oracle for Caldera.

@export_range(0.0, 100.0, 0.1, "or_greater") var elevation: float = 25.0:
	set(v):
		elevation = maxf(v, 0.0)
		_param_changed()

@export_range(0.01, 1.0, 0.01) var radius: float = 0.2:
	set(v):
		radius = maxf(v, 0.01)
		_param_changed()

@export_range(0.001, 1.0, 0.005) var sigma_inner: float = 0.05:
	set(v):
		sigma_inner = maxf(v, 0.001)
		_param_changed()

@export_range(0.001, 1.0, 0.005) var sigma_outer: float = 0.15:
	set(v):
		sigma_outer = maxf(v, 0.001)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var z_bottom: float = 0.2:
	set(v):
		z_bottom = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(0.0, 0.2, 0.005) var noise_r_amp: float = 0.02:
	set(v):
		noise_r_amp = v
		_param_changed()

@export_range(0.0, 0.5, 0.01) var noise_z_ratio: float = 0.05:
	set(v):
		noise_z_ratio = v
		_param_changed()

@export var center: Vector2 = Vector2(0.5, 0.5):
	set(v):
		center = v
		_param_changed()


func op() -> StringName:
	return &"dev_caldera"


func display_name() -> String:
	return "[Dev/GD] Caldera"


func category() -> StringName:
	return &"Dev / Reference"


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["noise"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT])


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
	var noise_in: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else PackedFloat32Array()

	var params := {
		"elevation": elevation,
		"radius": radius,
		"sigma_inner": sigma_inner,
		"sigma_outer": sigma_outer,
		"z_bottom": z_bottom,
		"noise_r_amp": noise_r_amp,
		"noise_z_ratio": noise_z_ratio,
		"center": center,
		"noise": noise_in,
	}

	return [solve_oracle(p_gw, p_gh, p_rect, params)]


static func solve_oracle(p_gw: int, p_gh: int, _p_rect: Rect2, p_params: Dictionary) -> PackedFloat32Array:
	var n: int = p_gw * p_gh
	var out := PackedFloat32Array()
	out.resize(n)

	var elevation_val: float = float(p_params.get("elevation", 25.0))
	var radius_val: float = maxf(0.01, float(p_params.get("radius", 0.2)))
	var sigma_inner_val: float = maxf(0.001, float(p_params.get("sigma_inner", 0.05)))
	var sigma_outer_val: float = maxf(0.001, float(p_params.get("sigma_outer", 0.15)))
	var z_bottom_val: float = clampf(float(p_params.get("z_bottom", 0.2)), 0.0, 1.0)
	var noise_r_amp_val: float = float(p_params.get("noise_r_amp", 0.02))
	var noise_z_ratio_val: float = float(p_params.get("noise_z_ratio", 0.05))
	var center_val: Vector2 = p_params.get("center", Vector2(0.5, 0.5))

	var noise_arr: PackedFloat32Array = p_params.get("noise", PackedFloat32Array())
	var has_noise: bool = (noise_arr.size() == n)

	var si2: float = sigma_inner_val * sigma_inner_val
	var so2: float = sigma_outer_val * sigma_outer_val

	for iz in range(p_gh):
		var ny: float = float(iz) / float(p_gh - 1) if p_gh > 1 else 0.5
		for ix in range(p_gw):
			var nx: float = float(ix) / float(p_gw - 1) if p_gw > 1 else 0.5
			var idx: int = iz * p_gw + ix

			var cx: float = nx - center_val.x
			var cy: float = ny - center_val.y
			var r: float = sqrt(cx * cx + cy * cy) - radius_val

			if has_noise:
				r += noise_r_amp_val * (2.0 * noise_arr[idx] - 1.0)

			var z: float = 0.0
			if r < 0.0:
				z = z_bottom_val + exp(-0.5 * r * r / maxf(1e-6, si2)) * (1.0 - z_bottom_val)
			else:
				z = 1.0 / (1.0 + r * r / maxf(1e-6, so2))

			if has_noise:
				z *= 1.0 + noise_z_ratio_val * (2.0 * noise_arr[idx] - 1.0)

			out[idx] = z * elevation_val

	return out
