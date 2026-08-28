# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeGeologicalPrimitive — a GENERATOR node: parametric macro landforms.
#
# Generates solitary geological structures and landforms via continuous analytic radial distance and
# morphological profiling:
#
#   1. INSELBERG: Solitary steep-sided monadnock / bornhardt with sharp cliffs and a curved pediment toe.
#   2. VOLCANIC_CALDERA: Volcanic shield dome with a central collapsed caldera crater.
#   3. CUESTA_BADLANDS: Asymmetric geological ridge with a gentle dip slope and a steep scarp cliff face.
#
# Supports FIT_FRAME mapping (automatically scales to fill the brush / evaluation frame) and METRIC_WORLD
# mapping (absolute metric radius in world space).
@tool
class_name Pasture3DGraphNodeGeologicalPrimitive
extends Pasture3DGraphNode

enum PrimitiveType {
	INSELBERG,         ## Solitary steep-sided monolithic dome rising from a flat plain.
	VOLCANIC_CALDERA,  ## Volcanic shield dome with a central collapsed crater depression.
	CUESTA_BADLANDS,   ## Asymmetric ridge with gentle dip slope and steep scarp face.
}

enum Mapping {
	FIT_FRAME,     ## Scales the landform to fit within the brush / evaluation frame bounds.
	METRIC_WORLD,  ## Evaluates the landform with absolute world-metre radius and offset.
}

## Macro geological landform archetype.
@export var primitive_type: PrimitiveType = PrimitiveType.INSELBERG:
	set(v):
		primitive_type = v
		emit_changed()

## Coordinate mapping mode: FIT_FRAME scales to the brush/rect footprint, METRIC_WORLD uses absolute metres.
@export var mapping: Mapping = Mapping.FIT_FRAME:
	set(v):
		mapping = v
		emit_changed()
		notify_property_list_changed()

## Maximum peak elevation in metres.
@export_range(-200.0, 500.0, 1.0) var height: float = 60.0:
	set(v):
		height = v
		emit_changed()

## Size factor: footprint radius scale in FIT_FRAME mode (0.1..2.0), or absolute radius in metres in METRIC_WORLD.
@export_range(0.1, 500.0, 0.05, "or_greater") var radius: float = 1.0:
	set(v):
		radius = maxf(v, 0.01)
		emit_changed()

## Flank curvature steepness exponent.
@export_range(0.2, 5.0, 0.1) var steepness: float = 1.8:
	set(v):
		steepness = maxf(v, 0.01)
		emit_changed()

## Elliptical distortion ratio (1.0 = circular, > 1.0 = elongated).
@export_range(0.2, 5.0, 0.1) var eccentricity: float = 1.0:
	set(v):
		eccentricity = maxf(v, 0.05)
		emit_changed()

## Orientation angle in degrees for asymmetrical and elongated landforms.
@export_range(0.0, 360.0, 1.0) var azimuth_degrees: float = 0.0:
	set(v):
		azimuth_degrees = v
		emit_changed()

## Horizontal offset: normalized [-1, 1] offset in FIT_FRAME, or world metres in METRIC_WORLD.
@export var center_offset: Vector2 = Vector2.ZERO:
	set(v):
		center_offset = v
		emit_changed()


func op() -> StringName:
	return &"geological_primitive"


func role() -> Role:
	return Role.GENERATOR


func needs_grid() -> bool:
	return mapping == Mapping.FIT_FRAME


func input_count() -> int:
	return 4


func input_names() -> PackedStringArray:
	return PackedStringArray(["height", "radius", "steepness", "eccentricity"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.FLOAT,
		PortType.FLOAT,
		PortType.FLOAT,
		PortType.FLOAT,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return height
		1: return radius
		2: return steepness
		3: return eccentricity
		_: return 0.0


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var h: float = float(p_inputs[0][0]) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and p_inputs[0].size() > 0) else height
	var r: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else radius
	var st: float = float(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else steepness
	var ecc: float = float(p_inputs[3][0]) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and p_inputs[3].size() > 0) else eccentricity
	return Pasture3DUtil.geological_primitive_grid(p_gw, p_gh, p_rect, int(primitive_type), int(mapping), h, r, ecc, st, azimuth_degrees, center_offset)


func eval_cell(p_wx: float, p_wz: float, p_inputs: PackedFloat32Array) -> float:
	var h: float = p_inputs[0] if (p_inputs.size() > 0 and not is_nan(p_inputs[0])) else height
	var r: float = p_inputs[1] if (p_inputs.size() > 1 and not is_nan(p_inputs[1])) else radius
	var st: float = p_inputs[2] if (p_inputs.size() > 2 and not is_nan(p_inputs[2])) else steepness
	var ecc: float = p_inputs[3] if (p_inputs.size() > 3 and not is_nan(p_inputs[3])) else eccentricity

	# Local rotated and scaled coordinates
	var rx := p_wx - center_offset.x
	var rz := p_wz - center_offset.y

	var rad := deg_to_rad(azimuth_degrees)
	var cos_a := cos(rad)
	var sin_a := sin(rad)

	var lx := rx * cos_a + rz * sin_a
	var lz := -rx * sin_a + rz * cos_a

	# Elliptical distance metric
	var inv_r := 1.0 / maxf(r, 0.001)
	var norm_x := lx * inv_r
	var norm_z := (lz * inv_r) / maxf(ecc, 0.01)
	var d := sqrt(norm_x * norm_x + norm_z * norm_z)

	return _profile_at_dynamic(d, norm_x, h, st)


func _profile_at_dynamic(d: float, norm_x: float, p_h: float, p_st: float) -> float:
	match primitive_type:
		PrimitiveType.INSELBERG:
			if d >= 1.0:
				return 0.0
			var cliff_r := 0.55
			var cliff := 1.0 / (1.0 + pow(d / cliff_r, 2.5 * maxf(p_st, 0.2)))
			var pediment := smoothstep(1.0, 0.75, d)
			return p_h * (cliff * pediment)
		PrimitiveType.VOLCANIC_CALDERA:
			if d >= 1.0:
				return 0.0
			var rim_center := 0.65
			var rim_width := 0.25
			var rim_dist := absf(d - rim_center) / rim_width
			var rim_height_term := exp(-rim_dist * rim_dist * 3.0)
			var floor_depth := 0.7
			var floor_falloff := smoothstep(rim_center, 0.0, d)
			var caldera_floor := -floor_depth * floor_falloff
			var outer_flank := smoothstep(1.0, rim_center, d)
			return p_h * (rim_height_term * outer_flank + caldera_floor)
		PrimitiveType.CUESTA_BADLANDS:
			if d >= 1.0:
				return 0.0
			var outer_mask := 1.0 - smoothstep(0.8, 1.0, d)
			var dip_slope := (1.0 - norm_x * 0.5) * 0.5
			var escarpment_center := 0.4
			var escarpment_falloff := 1.0 / (1.0 + exp(-10.0 * (norm_x - escarpment_center) * maxf(p_st, 0.2)))
			var profile := dip_slope * (1.0 - escarpment_falloff)
			return p_h * profile * outer_mask
		_:
			return 0.0
	return 0.0


func _profile_at(d: float, norm_x: float) -> float:
	match primitive_type:
		PrimitiveType.INSELBERG:
			if d >= 1.0:
				return 0.0
			# Monolithic bornhardt / inselberg:
			# Broad rounded bedrock summit, steep sheer cliff walls, and a concave basal pediment skirt.
			var cliff_r := 0.55
			var cliff := 1.0 / (1.0 + pow(d / cliff_r, 2.5 * maxf(steepness, 0.2)))
			var pediment := smoothstep(1.0, 0.75, d)
			return height * (cliff * pediment)

		PrimitiveType.VOLCANIC_CALDERA:
			if d >= 1.0:
				return 0.0
			var rim_pos := 0.45
			var floor_ratio := 0.35
			if d <= rim_pos:
				var bt := d / rim_pos
				var bowl := floor_ratio + (1.0 - floor_ratio) * pow(sin(bt * PI * 0.5), steepness)
				return height * bowl
			else:
				var ft := (1.0 - d) / (1.0 - rim_pos)
				var flank := pow(sin(ft * PI * 0.5), steepness)
				return height * flank

		PrimitiveType.CUESTA_BADLANDS:
			if d >= 1.0:
				return 0.0
			var envelope := pow(cos(d * PI * 0.5), 0.75)
			var scarp_factor := 0.25
			var x_profile := 0.0
			if norm_x < 0.0:
				var st := clampf(-norm_x / scarp_factor, 0.0, 1.0)
				x_profile = pow(cos(st * PI * 0.5), steepness)
			else:
				var dt := clampf(norm_x, 0.0, 1.0)
				x_profile = pow(cos(dt * PI * 0.5), 0.6)
			return height * x_profile * envelope

	return 0.0
