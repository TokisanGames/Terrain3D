# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeCrater — a GENERATOR grid node: one impact crater (a flattenable bowl, a raised rim,
# ejecta decaying outward) filling the evaluation FRAME. No inputs — it PRODUCES a field.
#
# WHY A GRID NODE. The crater is radial in LOOP-NORMALISED coordinates: nu,nv are ±1 at the frame's edge,
# so the bowl fills the graph's rect and an elongated rect gives an elongated crater — exactly the relief
# CRATER op's FIT mapping. A cell node is handed only its world XZ; it cannot know the frame. A grid node
# receives `p_rect`, from which the centre and half-extents (and so nu,nv and the metric rim scale) fall
# out. It delegates the profile to Pasture3DReliefMaterial._crater, so a Crater node and a relief Crater
# material agree to the byte.
@tool
class_name Pasture3DGraphNodeCrater
extends Pasture3DGraphNode

## Depth of the bowl at its centre, in METRES (the graph works in absolute metres). The rim height and
## floor depth below are fractions OF this.
@export var amplitude: float = 20.0:
	set(v):
		amplitude = v
		emit_changed()
## Depth of the bowl floor, as a fraction of Amplitude.
@export_range(0.0, 1.0, 0.01, "or_greater") var floor_depth: float = 0.7:
	set(v):
		floor_depth = maxf(v, 0.0)
		emit_changed()
## Height of the raised rim, as a fraction of Amplitude. Real craters have a rim far shallower than the
## bowl is deep; 0.1–0.25 reads well.
@export_range(0.0, 1.0, 0.01, "or_greater") var rim_height: float = 0.15:
	set(v):
		rim_height = maxf(v, 0.0)
		emit_changed()
## Where the rim sits and how much room the ejecta gets, as a fraction of the frame radius. 0.25 puts the
## rim crest 75% of the way out, ejecta over the remaining quarter.
@export_range(0.02, 0.95, 0.01) var rim_width: float = 0.25:
	set(v):
		rim_width = clampf(v, 0.02, 0.95)
		emit_changed()
## How fast the ejecta blanket falls off past the rim. 1 = linear, higher = tighter to the rim.
@export_range(0.1, 6.0, 0.05) var ejecta_falloff: float = 2.0:
	set(v):
		ejecta_falloff = maxf(v, 0.01)
		emit_changed()
## 0 = parabolic bowl. Higher flattens the floor and steepens the walls.
@export_range(0.0, 1.0, 0.01) var floor_flatness: float = 0.35:
	set(v):
		floor_flatness = clampf(v, 0.0, 1.0)
		emit_changed()
## Quantise the bowl into concentric benches (slumped terraces). 0 = smooth.
@export_range(0, 12) var terrace_steps: int = 0:
	set(v):
		terrace_steps = maxi(v, 0)
		emit_changed()


func op() -> StringName:
	return &"crater"


func role() -> Role:
	return Role.GENERATOR


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 0


func input_names() -> PackedStringArray:
	return PackedStringArray()


func eval_grid(_p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_gw * p_gh)
	# The frame's centre and half-extents. inv_ex/inv_ez turn a metre offset into normalised space, so a
	# world position maps to nu,nv in [-1, 1] over the rect (±1 at the edge) — exactly the relief loop.
	var cx := p_rect.position.x + p_rect.size.x * 0.5
	var cz := p_rect.position.y + p_rect.size.y * 0.5
	var inv_ex := 2.0 / maxf(p_rect.size.x, 1.0e-9)
	var inv_ez := 2.0 / maxf(p_rect.size.y, 1.0e-9)
	var params := _params()
	for iz in range(p_gh):
		var row := iz * p_gw
		for ix in range(p_gw):
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, p_gw, p_gh, p_rect)
			var nu := (w.x - cx) * inv_ex
			var nv := (w.y - cz) * inv_ez
			out[row + ix] = Pasture3DReliefMaterial._crater(nu, nv, inv_ex, inv_ez, params, 0)
	return out


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(amplitude) or (is_zero_approx(floor_depth) and is_zero_approx(rim_height)):
		w.append("%s: no depth and no rim, so the crater deforms nothing." % display_name())
	return w


func _params() -> PackedFloat32Array:
	# Layout as Pasture3DReliefMaterial._crater reads it:
	# [amp, floor_depth, rim_height, rim_width, ejecta_falloff, floor_flatness, terrace_steps].
	return PackedFloat32Array([amplitude, floor_depth, rim_height, rim_width, ejecta_falloff,
			floor_flatness, float(terrace_steps)])
