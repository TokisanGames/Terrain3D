@tool
class_name Pasture3DGraphNodeShatteredPeak
extends Pasture3DGraphNode

## Fractured alpine peak with Voronoi fault lines and sharp fissures, ported from Hesiod/HighMap.

@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

## Elevation / vertical amplitude in metres.
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
	return &"shattered_peak"


func display_name() -> String:
	return "Shattered Peak"


func category() -> StringName:
	return &"Generators"


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


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
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

	if not ClassDB.class_has_method("Pasture3DUtil", "shattered_peak_generate_grid"):
		push_error("[Pasture3D] Pasture3DUtil.shattered_peak_generate_grid is not bound. Rebuild GDExtension.")
		return [Pasture3DGraphOps.zeros(n)]

	var res: PackedFloat32Array = Pasture3DUtil.shattered_peak_generate_grid(p_gw, p_gh, p_rect, params)
	return [res]
