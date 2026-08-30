# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeGavoronoise — a GENERATOR: gradient-aware Voronoi with derivative feedback.
#
# The gap it fills is specific. FastNoiseLite's cellular mode gives you the distance field, and a distance
# field is blobs — isotropic cells with no relationship between neighbours. What makes a ridgeline read as
# eroded is that each branch knows which way the last one sloped, and that is exactly what the derivative
# feedback here adds: every octave is sampled at coordinates displaced by the accumulated slope of the
# octaves before it, so cell walls bend into dendritic branches instead of tiling.
#
# The result is the best quality-per-millisecond generator in this catalogue: branching ridgelines that
# read as water-worked with no erosion pass behind them.
@tool
class_name Pasture3DGraphNodeGavoronoise
extends Pasture3DGraphNode

## Peak height in WORLD METRES.
@export_range(0.0, 2000.0, 1.0, "or_greater") var amplitude: float = 60.0:
	set(v):
		amplitude = v
		emit_changed()

## CYCLES PER METRE. 0.002 is a ridge roughly every 500 m. Because it is per metre and not per cell, the
## same world rect gives the same ridge spacing at any bake resolution.
@export_range(0.0001, 0.05, 0.0001, "or_greater") var frequency: float = 0.002:
	set(v):
		frequency = maxf(v, 0.00001)
		emit_changed()

@export_range(1, 8, 1) var octaves: int = 4:
	set(v):
		octaves = clampi(v, 1, 8)
		emit_changed()

@export var seed: int = 0:
	set(v):
		seed = v
		emit_changed()

@export_group("Strike")

## The tectonic strike direction the ridges run along, in degrees.
@export_range(0.0, 360.0, 1.0) var angle_deg: float = 0.0:
	set(v):
		angle_deg = v
		emit_changed()

## How far ridges are allowed to wander off the strike. At 0 they are exactly parallel — a fold belt. At 1
## the strike direction stops being visible at all.
@export_range(0.0, 1.0, 0.01) var angle_spread: float = 1.0:
	set(v):
		angle_spread = clampf(v, 0.0, 1.0)
		emit_changed()

@export_group("Feedback")

## Damping of later octaves by the accumulated slope. Raising it calms the field; dropping it to 0 lets
## the feedback run away and the branching degenerates into noise.
@export_range(0.0, 10.0, 0.05) var slope_strength: float = 1.0:
	set(v):
		slope_strength = maxf(v, 0.0)
		emit_changed()

## How far the accumulated slope displaces the next octave's sample. This IS the branching: at 0 the node
## degenerates to plain fractal Voronoi, which is what FastNoiseLite already gives you.
@export_range(0.0, 10.0, 0.05) var branch_strength: float = 2.0:
	set(v):
		branch_strength = maxf(v, 0.0)
		emit_changed()

@export_group("Output Window")

@export_range(0.0, 1.0, 0.01) var z_cut_min: float = 0.2:
	set(v):
		z_cut_min = clampf(v, 0.0, 1.0)
		emit_changed()

@export_range(0.0, 1.0, 0.01) var z_cut_max: float = 1.0:
	set(v):
		z_cut_max = clampf(v, 0.0, 1.0)
		emit_changed()


func op() -> StringName:
	return &"gavoronoise"


func role() -> Role:
	return Role.GENERATOR


## TRUE, where the spec proposed false. The spec called this "cell, fusible", but fusible means having an
## `eval_cell` that the fold can inline, and this node has none — the octave loop with its derivative
## feedback is not a per-cell expression the folder can splice into a neighbour's loop. Jordan and Swiss
## make the same claim and are then special-cased back out of the cell path in TWO separate evaluators;
## saying `true` here is the same behaviour with one fewer place to forget.
func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 3


func input_names() -> PackedStringArray:
	return PackedStringArray(["amplitude", "angle", "frequency"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.FLOAT, PortType.FLOAT, PortType.FLOAT])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return amplitude
		1: return angle_deg
		2: return frequency
		_: return 0.0


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var amp: float = float(p_inputs[0][0]) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and p_inputs[0].size() > 0) else amplitude
	var ang: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else angle_deg
	var freq: float = float(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else frequency

	if not ClassDB.class_has_method("Pasture3DUtil", "gavoronoise_grid"):
		push_error("[Pasture3D] Pasture3DUtil.gavoronoise_grid is not bound. Rebuild GDExtension.")
		return Pasture3DGraphOps.zeros(n)

	var res: PackedFloat32Array = Pasture3DUtil.gavoronoise_grid(p_gw, p_gh, p_rect, amp, freq, octaves,
			seed, ang, angle_spread, slope_strength, branch_strength, z_cut_min, z_cut_max)
	if res.size() != n:
		push_error("[Pasture3D] Gavoronoise returned an invalid grid size.")
		return Pasture3DGraphOps.zeros(n)
	return res


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(branch_strength):
		# Without the feedback this is fractal Voronoi, which FastNoiseLite's cellular mode already
		# provides — so the node is doing nothing the engine could not do more cheaply.
		w.append("%s: Branch Strength is 0, so there is no derivative feedback and this is plain fractal Voronoi." % display_name())
	if z_cut_max <= z_cut_min:
		w.append("%s: Z Cut Max is not above Z Cut Min, so the output window is empty and the field is flat." % display_name())
	if is_zero_approx(amplitude):
		w.append("%s: Amplitude is 0, so the output is flat." % display_name())
	return w
