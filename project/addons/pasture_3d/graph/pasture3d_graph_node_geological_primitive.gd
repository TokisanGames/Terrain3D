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
	return 0


func eval_grid(_p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var out := PackedFloat32Array()
	out.resize(n)

	if mapping == Mapping.METRIC_WORLD:
		for iz in range(p_gh):
			var row := iz * p_gw
			for ix in range(p_gw):
				var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, p_gw, p_gh, p_rect)
				out[row + ix] = eval_cell(w.x, w.y, PackedFloat32Array())
		return out

	# FIT_FRAME mapping: center is frame center + normalized offset
	var cx := p_rect.position.x + p_rect.size.x * 0.5 + center_offset.x * (p_rect.size.x * 0.5)
	var cz := p_rect.position.y + p_rect.size.y * 0.5 + center_offset.y * (p_rect.size.y * 0.5)
	var half_ex := maxf(p_rect.size.x * 0.5 * radius, 0.001)
	var half_ez := maxf(p_rect.size.y * 0.5 * radius * eccentricity, 0.001)

	var rad := deg_to_rad(azimuth_degrees)
	var cos_a := cos(rad)
	var sin_a := sin(rad)

	for iz in range(p_gh):
		var row := iz * p_gw
		for ix in range(p_gw):
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, p_gw, p_gh, p_rect)
			var rx := w.x - cx
			var rz := w.y - cz

			var lx := rx * cos_a + rz * sin_a
			var lz := -rx * sin_a + rz * cos_a

			var norm_x := lx / half_ex
			var norm_z := lz / half_ez
			var d := sqrt(norm_x * norm_x + norm_z * norm_z)

			out[row + ix] = _profile_at(d, norm_x)

	return out


func eval_cell(p_wx: float, p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	# Local rotated and scaled coordinates
	var rx := p_wx - center_offset.x
	var rz := p_wz - center_offset.y

	var rad := deg_to_rad(azimuth_degrees)
	var cos_a := cos(rad)
	var sin_a := sin(rad)

	var lx := rx * cos_a + rz * sin_a
	var lz := -rx * sin_a + rz * cos_a

	# Elliptical distance metric
	var inv_r := 1.0 / maxf(radius, 0.001)
	var norm_x := lx * inv_r
	var norm_z := (lz * inv_r) / maxf(eccentricity, 0.01)
	var d := sqrt(norm_x * norm_x + norm_z * norm_z)

	return _profile_at(d, norm_x)


func _profile_at(d: float, norm_x: float) -> float:
	match primitive_type:
		PrimitiveType.INSELBERG:
			if d >= 1.0:
				return 0.0
			var dome := pow(cos(d * PI * 0.5), steepness)
			return height * dome

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
