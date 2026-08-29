@tool
class_name Pasture3DGraphNodeMountainRangeRadial
extends Pasture3DGraphNode

## Radial branching alpine mountain range along tectonic axes, ported from Hesiod/HighMap.

@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

## Elevation / vertical amplitude in metres.
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
	return &"mountain_range_radial"


func display_name() -> String:
	return "Mountain Range (Radial)"


func category() -> StringName:
	return &"Generators"


func input_count() -> int:
	return 4


func input_names() -> PackedStringArray:
	return PackedStringArray(["ctrl", "dx", "dy", "envelope"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.HEIGHT, PortType.HEIGHT, PortType.MASK])


func input_unwired_default(p_port: int) -> float:
	# An unwired MASK (envelope) reads 1.0 — a missing gate is fully open, matching the native path.
	return 1.0 if input_port_types()[p_port] == PortType.MASK else 0.0


func output_count() -> int:
	return 2


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "angle"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.VECTOR])


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

	if not ClassDB.class_has_method("Pasture3DUtil", "mountain_range_radial_generate_grid"):
		push_error("[Pasture3D] Pasture3DUtil.mountain_range_radial_generate_grid is not bound. Rebuild GDExtension.")
		return [Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	var res: Array = Pasture3DUtil.mountain_range_radial_generate_grid(p_gw, p_gh, p_rect, params)
	return res
