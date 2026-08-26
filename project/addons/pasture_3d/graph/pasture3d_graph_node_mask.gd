# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeMask — a FILTER grid node: read a terrain property of the INPUT surface (slope,
# altitude, or curvature) and output a 0..1 WEIGHT field. It gates nothing on its own — you multiply it in
# with a Blend(MUL). This is the relief system's `selector` decoupled into its own node: instead of every
# generator carrying a hidden slope/altitude gate, you wire Input -> Mask into a Blend(MUL) against the
# generator, so "craggy only on steep flanks" is a visible sub-graph rather than a buried property.
#
# GRID node: slope and curvature read a cell's neighbours, so it needs the whole field. The slope /
# curvature definitions match Pasture3DTerrainBrush._derive_fields (and relief_fields_build in C++), so a
# slope band here reads the same as a slope selector on a relief material: slope in degrees from the height
# gradient, curvature in METRES of deviation from the four-neighbour ring (positive = hollow, §21.6), and
# altitude is the input height itself.
@tool
class_name Pasture3DGraphNodeMask
extends Pasture3DGraphNode

## Which terrain property of the input the band reads.
enum Property { SLOPE, ALTITUDE, CURVATURE }

## The property to gate on. SLOPE is degrees; ALTITUDE and CURVATURE are metres.
@export var property: Property = Property.SLOPE:
	set(v):
		property = v
		emit_changed()

@export_group("Band")
## Lower edge of the pass band, in the property's units (degrees for Slope, metres otherwise).
@export var band_min: float = 20.0:
	set(v):
		band_min = v
		emit_changed()
## Upper edge of the pass band.
@export var band_max: float = 90.0:
	set(v):
		band_max = v
		emit_changed()
## Soft fade-in width below `band_min` (same units). 0 = a hard edge.
@export_range(0.0, 180.0, 0.1, "or_greater") var falloff_lo: float = 5.0:
	set(v):
		falloff_lo = maxf(v, 0.0)
		emit_changed()
## Soft fade-out width above `band_max`. 0 = a hard edge.
@export_range(0.0, 180.0, 0.1, "or_greater") var falloff_hi: float = 5.0:
	set(v):
		falloff_hi = maxf(v, 0.0)
		emit_changed()
## Flip the weight (1 - w): pass everything OUTSIDE the band instead of inside.
@export var invert: bool = false:
	set(v):
		invert = v
		emit_changed()
## How hard the gate bites: 0 = weight 1 everywhere (no gating), 1 = the full band weight. Lerps 1 -> band.
@export_range(0.0, 1.0, 0.01) var strength: float = 1.0:
	set(v):
		strength = clampf(v, 0.0, 1.0)
		emit_changed()


func op() -> StringName:
	return &"mask"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func output_port_type() -> int:
	return PortType.MASK


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["field"])


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var h: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if p_inputs.size() > 0 \
			else Pasture3DGraphOps.zeros(n)
	var out := PackedFloat32Array()
	out.resize(n)
	# World spacing per cell; may be anisotropic. Slope uses it; curvature is a spacing-independent
	# height deviation (metres over one cell), matching §21.6.
	var dx := p_rect.size.x / float(maxi(p_gw, 1))
	var dz := p_rect.size.y / float(maxi(p_gh, 1))
	var inv2x := 1.0 / (2.0 * maxf(dx, 1.0e-9))
	var inv2z := 1.0 / (2.0 * maxf(dz, 1.0e-9))
	for iz in range(p_gh):
		var row := iz * p_gw
		var zm := maxi(iz - 1, 0) * p_gw
		var zp := mini(iz + 1, p_gh - 1) * p_gw
		for ix in range(p_gw):
			var xm := maxi(ix - 1, 0)
			var xp := mini(ix + 1, p_gw - 1)
			var c := h[row + ix]
			var x := 0.0
			match property:
				Property.ALTITUDE:
					x = c
				Property.SLOPE:
					var gx := (h[row + xp] - h[row + xm]) * inv2x
					var gz := (h[zp + ix] - h[zm + ix]) * inv2z
					x = rad_to_deg(atan(sqrt(gx * gx + gz * gz)))
				Property.CURVATURE:
					x = (h[row + xp] + h[row + xm] + h[zp + ix] + h[zm + ix] - 4.0 * c) * 0.25
			out[row + ix] = _weight(x)
	return out


# The 0..1 band weight for a property value. Byte-for-byte the relief selector's shape
# (Pasture3DReliefMaterial._selector_value): a soft rise below the floor, a soft fall above the ceiling,
# an optional invert, then a strength lerp between "ungated" (1) and the band.
func _weight(p_x: float) -> float:
	var rise := 1.0 if p_x >= band_min else (smoothstep(band_min - falloff_lo, band_min, p_x) if falloff_lo > 0.0 else 0.0)
	var fall := 1.0 if p_x <= band_max else (1.0 - smoothstep(band_max, band_max + falloff_hi, p_x) if falloff_hi > 0.0 else 0.0)
	var s := clampf(minf(rise, fall), 0.0, 1.0)
	if invert:
		s = 1.0 - s
	return lerpf(1.0, s, strength)


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(strength):
		w.append("%s: Strength is 0, so the weight is 1 everywhere (no gating)." % display_name())
	elif band_min > band_max:
		w.append("%s: Band Min exceeds Band Max, so nothing passes (weight 0)." % display_name())
	return w
