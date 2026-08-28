# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeStrata — a FILTER cell node: exposed rock layers. Like Terrace, but the benches are
# TILTED (geological dip) and broken up laterally, which is what makes sedimentary rock read as rock rather
# than a staircase. One input, one output; it bands EXACTLY the field wired into it and generates nothing.
#
# HEIGHT-DOMAIN, matching the Terrace node: a bench every `band_height` metres, with the band boundaries
# tilted by `dip` (metres of rise per 100 m along the dip direction) and wandered by world-space noise.
@tool
class_name Pasture3DGraphNodeStrata
extends Pasture3DGraphNode

## Elevation between rock layers, in metres.
@export_range(0.5, 200.0, 0.1, "or_greater") var band_height: float = 8.0:
	set(v):
		band_height = maxf(v, 0.001)
		emit_changed()

## Strata frequency (layers per 100m). Convenience view of layer density.
var strata_frequency: float:
	get:
		return 100.0 / maxf(band_height, 0.001)
	set(v):
		if v > 0.0:
			band_height = 100.0 / v

## Layer resistance / hardness contrast. 0 leaves the field untouched; 1 gives sheer cliff faces between flat shelves.
@export_range(0.0, 1.0, 0.01) var hardness: float = 0.75:
	set(v):
		hardness = clampf(v, 0.0, 1.0)
		emit_changed()

## Hardness contrast alias for geological parameter naming.
var hardness_contrast: float:
	get:
		return hardness
	set(v):
		hardness = v

## Cross-fade between the input (0) and the fully-layered field (1).
@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		emit_changed()

## Optional custom cross-section profile for strata ledges. When null, uses power-law profile.
@export var terrace_profile: Curve:
	set(v):
		if terrace_profile != null and terrace_profile.changed.is_connected(emit_changed):
			terrace_profile.changed.disconnect(emit_changed)
		terrace_profile = v
		if terrace_profile != null and not terrace_profile.changed.is_connected(emit_changed):
			terrace_profile.changed.connect(emit_changed)
		emit_changed()

@export_group("Dip & Strike")
## Geological dip: how far the layers tilt across the ground, in METRES of rise per 100 m. 0 = horizontal bedding.
@export_range(-45.0, 45.0, 0.1) var dip: float = 4.0:
	set(v):
		dip = v
		emit_changed()

## Geological dip angle alias in degrees (tan(dip_angle) * 100 = dip).
var dip_angle: float:
	get:
		return rad_to_deg(atan(dip * 0.01))
	set(v):
		dip = tan(deg_to_rad(v)) * 100.0

## Compass direction the layers dip towards, in degrees.
@export_range(0.0, 360.0, 1.0) var dip_direction_degrees: float = 45.0:
	set(v):
		dip_direction_degrees = v
		emit_changed()

## Strike direction azimuth alias (perpendicular to dip direction).
var strike_direction: float:
	get:
		return fposmod(dip_direction_degrees + 90.0, 360.0)
	set(v):
		dip_direction_degrees = fposmod(v - 90.0, 360.0)

@export_group("Break Up")
## How far the layer boundaries wander, in metres, so beds break into local plates rather than running dead straight.
@export_range(0.0, 32.0, 0.1, "or_greater") var break_amount: float = 3.0:
	set(v):
		break_amount = maxf(v, 0.0)
		_dirty = true
		emit_changed()

## Size of those plates, in metres.
@export_range(4.0, 512.0, 1.0, "or_greater") var break_size: float = 45.0:
	set(v):
		break_size = maxf(v, 0.01)
		_dirty = true
		emit_changed()

@export var seed: int = 0:
	set(v):
		seed = v
		_dirty = true
		emit_changed()

var _break: FastNoiseLite = null
var _dirty := true


func op() -> StringName:
	return &"strata"


func role() -> Role:
	return Role.FILTER


func input_count() -> int:
	return 6


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "band_height", "hardness", "dip", "direction", "amount"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.HEIGHT,
		PortType.FLOAT,
		PortType.FLOAT,
		PortType.FLOAT,
		PortType.FLOAT,
		PortType.MASK,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return band_height
		2: return hardness
		3: return dip
		4: return dip_direction_degrees
		5: return amount
		_: return 0.0


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var s: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else Pasture3DGraphOps.zeros(p_gw * p_gh)
	var bh: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else band_height
	var h: float = float(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else hardness
	var d: float = float(p_inputs[3][0]) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and p_inputs[3].size() > 0) else dip
	var dir: float = float(p_inputs[4][0]) if (p_inputs.size() > 4 and p_inputs[4] is PackedFloat32Array and p_inputs[4].size() > 0) else dip_direction_degrees
	var amt: float = float(p_inputs[5][0]) if (p_inputs.size() > 5 and p_inputs[5] is PackedFloat32Array and p_inputs[5].size() > 0) else amount

	if terrace_profile != null:
		var out := PackedFloat32Array()
		out.resize(p_gw * p_gh)
		for iz in range(p_gh):
			var row := iz * p_gw
			for ix in range(p_gw):
				var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, p_gw, p_gh, p_rect)
				out[row + ix] = eval_cell(w.x, w.y, PackedFloat32Array([s[row + ix], bh, h, d, dir, amt]))
		return out
	return Pasture3DUtil.strata_grid(s, p_gw, p_gh, p_rect, bh, h, amt, d, dir, break_amount, break_size, seed)


func eval_cell(p_wx: float, p_wz: float, p_inputs: PackedFloat32Array) -> float:
	var x: float = p_inputs[0] if (p_inputs.size() > 0 and not is_nan(p_inputs[0])) else 0.0
	var bh: float = p_inputs[1] if (p_inputs.size() > 1 and not is_nan(p_inputs[1])) else band_height
	var h: float = p_inputs[2] if (p_inputs.size() > 2 and not is_nan(p_inputs[2])) else hardness
	var d: float = p_inputs[3] if (p_inputs.size() > 3 and not is_nan(p_inputs[3])) else dip
	var dir: float = p_inputs[4] if (p_inputs.size() > 4 and not is_nan(p_inputs[4])) else dip_direction_degrees
	var amt: float = p_inputs[5] if (p_inputs.size() > 5 and not is_nan(p_inputs[5])) else amount

	if is_nan(x):
		return x

	var dipdir := deg_to_rad(dir)
	var tilt := d * (p_wx * cos(dipdir) + p_wz * sin(dipdir)) * 0.01
	if break_amount > 0.0:
		tilt += _break_field().get_noise_2d(p_wx, p_wz) * break_amount
	var xj := x + tilt
	var bh_clean := maxf(bh, 0.001)
	var t := xj / bh_clean
	var q := floorf(t)
	var f := t - q

	var profile_val: float
	if terrace_profile != null:
		profile_val = terrace_profile.sample_baked(clampf(f, 0.0, 1.0))
	else:
		profile_val = pow(f, 1.0 + h * 15.0)

	var stepped := (q + profile_val) * bh_clean
	return lerpf(x, stepped, amt)


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(amount):
		w.append("%s: Amount is 0, so it passes the input through unchanged." % display_name())
	elif hardness <= 0.0 and terrace_profile == null:
		w.append("%s: Hardness is 0, so the beds have no visible risers." % display_name())
	return w


func _break_field() -> FastNoiseLite:
	if _dirty or _break == null:
		_break = FastNoiseLite.new()
		_break.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_break.fractal_type = FastNoiseLite.FRACTAL_FBM
		_break.fractal_octaves = 3
		_break.frequency = 1.0 / maxf(break_size, 0.01)
		_break.seed = seed
		_dirty = false
	return _break
