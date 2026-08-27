# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeGeologicalPrimitive — a GENERATOR cell node: parametric macro landforms.
#
# Generates solitary geological structures and landforms via continuous analytic radial distance and
# morphological profiling:
#
#   1. INSELBERG: Solitary steep-sided monadnock / bornhardt with sharp cliffs and a curved pediment toe.
#   2. VOLCANIC_CALDERA: Volcanic shield dome with a central collapsed caldera crater.
#   3. CUESTA_BADLANDS: Asymmetric geological ridge with a gentle dip slope and a steep scarp cliff face.
#
# Point-evaluable per cell at world (wx, wz) with zero intermediate allocations.
@tool
class_name Pasture3DGraphNodeGeologicalPrimitive
extends Pasture3DGraphNode

enum PrimitiveType {
	INSELBERG,         ## Solitary steep-sided monolithic dome rising from a flat plain.
	VOLCANIC_CALDERA,  ## Volcanic shield dome with a central collapsed crater depression.
	CUESTA_BADLANDS,   ## Asymmetric ridge with gentle dip slope and steep scarp face.
}

## Macro geological landform archetype.
@export var primitive_type: PrimitiveType = PrimitiveType.INSELBERG:
	set(v):
		primitive_type = v
		emit_changed()

## Base footprint radius in metres.
@export_range(10.0, 500.0, 5.0, "or_greater") var radius: float = 100.0:
	set(v):
		radius = maxf(v, 1.0)
		emit_changed()

## Maximum peak elevation in metres.
@export_range(-200.0, 500.0, 1.0) var height: float = 60.0:
	set(v):
		height = v
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

## World horizontal offset (metres) from region origin.
@export var center_offset: Vector2 = Vector2.ZERO:
	set(v):
		center_offset = v
		emit_changed()


func op() -> StringName:
	return &"geological_primitive"


func role() -> Role:
	return Role.GENERATOR


func needs_grid() -> bool:
	return false


func input_count() -> int:
	return 0


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

	match primitive_type:
		PrimitiveType.INSELBERG:
			# Bornhardt / Monadnock: exponential / hyperbolic profile with concave pediment toe
			if d >= 1.0:
				return 0.0
			var t := 1.0 - d
			# Hyperbolic dome profile
			var profile := pow(t, steepness) * (1.0 + 0.5 * (1.0 - pow(d, 2.0)))
			return height * clampf(profile, 0.0, 1.0)

		PrimitiveType.VOLCANIC_CALDERA:
			# Volcanic shield dome with central collapsed crater
			if d >= 1.0:
				return 0.0
			var rim_pos := 0.4
			var caldera_depth := 0.6 # fraction of height
			if d < rim_pos:
				# Inside caldera basin
				var basin_t := d / rim_pos
				var basin_profile := (1.0 - caldera_depth) + caldera_depth * pow(basin_t, steepness)
				return height * basin_profile
			else:
				# Outer shield flank
				var flank_t := (1.0 - d) / (1.0 - rim_pos)
				return height * pow(clampf(flank_t, 0.0, 1.0), steepness)

		PrimitiveType.CUESTA_BADLANDS:
			# Asymmetric cuesta: gentle dip slope along +lx, steep scarp face along -lx
			if d >= 1.0:
				return 0.0
			var envelope := pow(1.0 - d, 0.8) # radial boundary envelope
			var scarp_steepness := 0.25 # width of steep scarp
			var dip_factor := 0.0
			if norm_x < 0.0:
				# Steep scarp face
				dip_factor = 1.0 - pow(clampf(-norm_x / scarp_steepness, 0.0, 1.0), steepness)
			else:
				# Gentle dip slope
				dip_factor = 1.0 - pow(clampf(norm_x, 0.0, 1.0), 0.7)
			return height * clampf(dip_factor * envelope, 0.0, 1.0)

	return 0.0
