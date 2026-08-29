@tool
class_name Pasture3DGraphNodeCaldera
extends Pasture3DGraphNode

## Volcanic collapse caldera with inner floor depression and asymptotic outer flanks, ported from Hesiod/HighMap.

## Elevation / vertical amplitude in metres.
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
	return &"caldera"


func display_name() -> String:
	return "Caldera"


func category() -> StringName:
	return &"Generators"


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
	var n := p_gw * p_gh
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

	if not ClassDB.class_has_method("Pasture3DUtil", "caldera_generate_grid"):
		push_error("[Pasture3D] Pasture3DUtil.caldera_generate_grid is not bound. Rebuild GDExtension.")
		return [Pasture3DGraphOps.zeros(n)]

	var res: PackedFloat32Array = Pasture3DUtil.caldera_generate_grid(p_gw, p_gh, p_rect, params)
	return [res]
