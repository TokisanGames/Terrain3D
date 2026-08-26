# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeFurrows — a GENERATOR cell node: parallel corrugation (ridge-and-furrow) sampled at
# each cell's WORLD XZ, in metres. No inputs — it PRODUCES a texture. Compose it with Blend/Smooth or feed
# it to a filter; it does not read or gate on anything of its own.
#
# This is the clean-category counterpart of the relief FURROWS op (PASTURE3D_TERRAIN_GRAPH_SPEC.md): it
# reuses the exact corrugation math (Pasture3DReliefMaterial._furrows) so a Furrows node and a relief
# Furrows material agree to the byte, but here it is a pure generator — none of the material's accumulator,
# selector, blend or output-curve wrapper. Sampling in world space keeps the field continuous where two
# graphs or two masked brush regions meet, exactly like the Noise node.
@tool
class_name Pasture3DGraphNodeFurrows
extends Pasture3DGraphNode

## Cross-section of each row. Mirrors Pasture3DReliefFurrows.Profile.
enum Profile { V, U, SQUARE }

## Ridge-to-furrow height at full output, in METRES (the graph works in absolute metres, so unlike the
## relief material this is not a fraction of a host's Height Scale).
@export var amplitude: float = 1.0:
	set(v):
		amplitude = v
		emit_changed()
## Distance between ridge crests, in metres. Stay well above the terrain's vertex spacing or the rows do
## not survive meshing (~4 m minimum to render at 1 m spacing).
@export_range(2.0, 64.0, 0.1, "or_greater") var spacing: float = 15.0:
	set(v):
		spacing = maxf(v, 0.1)
		emit_changed()
## Direction the rows run, in degrees.
@export_range(0.0, 360.0, 1.0) var direction_degrees: float = 0.0:
	set(v):
		direction_degrees = v
		emit_changed()
## V = sharp cut. U = weathered, rounded. SQUARE = flat-topped beds with steep sides.
@export var profile: Profile = Profile.U:
	set(v):
		profile = v
		emit_changed()

@export_group("Wobble")
## Sideways waver along each row, in metres — worked ground is never perfectly straight.
@export_range(0.0, 16.0, 0.1, "or_greater") var wobble_amount: float = 2.0:
	set(v):
		wobble_amount = maxf(v, 0.0)
		_dirty = true
		emit_changed()
## Length scale of that waver, in metres.
@export_range(1.0, 256.0, 0.5, "or_greater") var wobble_size: float = 70.0:
	set(v):
		wobble_size = maxf(v, 0.01)
		_dirty = true
		emit_changed()
@export var seed: int = 0:
	set(v):
		seed = v
		_dirty = true
		emit_changed()

# The wobble field, built ONCE (per-cell construction would be catastrophic) and rebuilt only when a
# property that shapes it changes. Built the same way as the relief FURROWS op's noise, so the two agree.
var _wobble: FastNoiseLite = null
var _dirty := true


func op() -> StringName:
	return &"furrows"


func role() -> Role:
	return Role.GENERATOR


func input_count() -> int:
	return 0


func input_names() -> PackedStringArray:
	return PackedStringArray()


func eval_cell(p_wx: float, p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	# Delegate to the canonical corrugation math so a Furrows node never drifts from a relief Furrows op.
	# params layout as Pasture3DReliefMaterial._furrows reads it: [amp, spacing, dir, profile, _, wobble].
	return Pasture3DReliefMaterial._furrows(p_wx, p_wz, _params(), 0, _wobble_noise())


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(amplitude):
		w.append("%s: Amplitude is 0 m, so the furrows contribute nothing." % display_name())
	return w


# The wobble field, built the SAME way as Pasture3DReliefMaterial._make_noise for a FURROWS op
# (frequency = 1 / wobble_size, 2 octaves, seed), so the graph node and the relief op sample identically.
func _wobble_noise() -> FastNoiseLite:
	if _dirty or _wobble == null:
		_wobble = Pasture3DReliefMaterial._configure_noise(1.0 / maxf(wobble_size, 0.01), 2, 2.0, 0.5, seed, false)
		_dirty = false
	return _wobble


func _params() -> PackedFloat32Array:
	return PackedFloat32Array([amplitude, spacing, deg_to_rad(direction_degrees), float(profile),
			0.0, wobble_amount, float(seed)])
