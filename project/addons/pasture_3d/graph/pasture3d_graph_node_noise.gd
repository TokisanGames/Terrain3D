# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeNoise — a GENERATOR cell node: FastNoiseLite sampled at each cell's WORLD XZ, scaled
# by `amplitude` (metres). No inputs. Sampling in world space is what keeps the field continuous where
# two graphs or two masked brush regions meet, matching how the relief and brush paths sample.
@tool
class_name Pasture3DGraphNodeNoise
extends Pasture3DGraphNode

## The noise source. Its own seed / frequency / fractal settings shape the field; this node only scales
## and places it. Unassigned = a defined flat 0 (and a configuration warning), never invented values.
@export var noise: FastNoiseLite:
	set(v):
		noise = v
		emit_changed()

## Metres of relief at the noise's full [-1, 1] output.
@export var amplitude: float = 1.0:
	set(v):
		amplitude = v
		emit_changed()


func op() -> StringName:
	return &"noise"


func role() -> Role:
	return Role.GENERATOR


func input_count() -> int:
	return 0


func input_names() -> PackedStringArray:
	return PackedStringArray()


func eval_cell(p_wx: float, p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	if noise == null:
		return 0.0
	return amplitude * noise.get_noise_2d(p_wx, p_wz)


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if noise == null:
		w.append("%s: no FastNoiseLite assigned, so it generates a flat 0." % display_name())
	elif is_zero_approx(amplitude):
		w.append("%s: Amplitude is 0 m, so the noise contributes nothing." % display_name())
	return w
