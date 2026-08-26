# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeStrata — a FILTER cell node: exposed rock layers. Like Terrace, but the benches are
# TILTED (geological dip) and broken up laterally, which is what makes sedimentary rock read as rock rather
# than a staircase. One input, one output; it bands EXACTLY the field wired into it and generates nothing.
#
# The clean-category split the relief system does not make: the relief STRATIFY op bands its material's own
# accumulator (its bundled base relief), so a Strata material standalone banded noise. Here Strata bands its
# input — wire a Ridged/Furrows/Input into it to choose what the beds cut across.
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
## Layer resistance. 0 leaves the field untouched; 1 gives sheer cliff faces between flat shelves.
@export_range(0.0, 1.0, 0.01) var hardness: float = 0.75:
	set(v):
		hardness = clampf(v, 0.0, 1.0)
		emit_changed()
## Cross-fade between the input (0) and the fully-layered field (1).
@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		emit_changed()

@export_group("Dip")
## Geological dip: how far the layers tilt across the ground, in METRES of rise per 100 m. 0 = horizontal
## bedding. Small values read as gently tilted strata.
@export_range(-20.0, 20.0, 0.1) var dip: float = 4.0:
	set(v):
		dip = v
		emit_changed()
## Compass direction the layers dip towards, in degrees.
@export_range(0.0, 360.0, 1.0) var dip_direction_degrees: float = 45.0:
	set(v):
		dip_direction_degrees = v
		emit_changed()

@export_group("Break Up")
## How far the layer boundaries wander, in metres, so beds break into local plates rather than running dead
## straight. The difference between rock and corduroy.
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
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["field"])


func eval_cell(p_wx: float, p_wz: float, p_inputs: PackedFloat32Array) -> float:
	var x := p_inputs[0] if p_inputs.size() > 0 else 0.0
	if is_nan(x):
		return x
	# Tilt the band boundaries: a bed rises `dip` metres per 100 m along the dip direction, plus world-space
	# break-up so the beds are not dead straight. The tilt is folded into the banded coordinate exactly as
	# the relief STRATIFY op folds it in (band the tilted value), which is what tilts the benches across space.
	var dipdir := deg_to_rad(dip_direction_degrees)
	var tilt := dip * (p_wx * cos(dipdir) + p_wz * sin(dipdir)) * 0.01
	if break_amount > 0.0:
		tilt += _break_field().get_noise_2d(p_wx, p_wz) * break_amount
	var xj := x + tilt
	var bh := maxf(band_height, 0.001)
	var t := xj / bh
	var q := floorf(t)
	var f := t - q
	var stepped := (q + pow(f, 1.0 + hardness * 15.0)) * bh
	return lerpf(x, stepped, amount)


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(amount):
		w.append("%s: Amount is 0, so it passes the input through unchanged." % display_name())
	elif hardness <= 0.0:
		w.append("%s: Hardness is 0, so the beds have no visible risers." % display_name())
	return w


func _break_field() -> FastNoiseLite:
	if _dirty or _break == null:
		# Matches the relief STRATIFY op's break-up noise: 3 octaves at 1 / break_size.
		_break = Pasture3DReliefMaterial._configure_noise(1.0 / maxf(break_size, 0.01), 3, 2.0, 0.5, seed, false)
		_dirty = false
	return _break
