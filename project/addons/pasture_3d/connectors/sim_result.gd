# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DSimResult — the drainage masks a Pasture3DSim produces alongside the height it writes. Four
# per-cell fields over the area the sim SOLVED, so relief materials, splats and (phase 4) river and lake
# extraction can key off where the water went instead of guessing from slope.
# See PASTURE3D_SIM_NODE_SPEC.md §8.2.
#
# THREE THINGS TO KNOW BEFORE READING ONE:
#
# 1. It is at SIM resolution over the SIMULATED area, not at terrain resolution over the loop. `cell_size`
#    is the sim grid's spacing (vertex_spacing x the Preview/Build divisor) and the extent runs out to the
#    edge of the catchment margin — well outside the loop the sim actually wrote into. That is deliberate:
#    the channels feeding the loop rim are exactly where a selector needs real values. It also means
#    `erosion` in the margin describes ground the sim never touched. Consumers that want "only where the
#    terrain changed" must gate on their own brush area, not on this.
#
# 2. `flow` is stored LOG-SCALED. Drainage area spans decades, so the stored value is
#    log(max(area_m2, 1.0)) and reading it back means exp(). Use drainage_area_at() and never the raw
#    channel unless you mean log space.
#
# 3. `erosion` and `deposition` are the two SIGNS OF ONE FIELD — the net z_final - z_initial. `erosion` is
#    negative or zero, `deposition` positive or zero, never both non-zero at the same cell, and their sum
#    is the net delta exactly. Deposition is small in phases 1-2 by construction: detachment-limited
#    stream power removes material without transporting it, so the only deposition is hillslope diffusion
#    into concavities (§15's sediment-transport extension is what makes it a first-class channel).
@tool
class_name Pasture3DSimResult
extends Resource

## The four fields, for sample() and for the phase-3 selector Kinds that read them.
enum Channel {
	FLOW,       ## upstream drainage area, LOG-scaled (see drainage_area_at)
	EROSION,    ## metres of material removed, negative or zero
	DEPOSITION, ## metres of material gained, positive or zero
	WETNESS,    ## standing water depth from the depression fill, metres
}

## Area of one cell that always drains at least itself, and so the floor `flow` is stored against.
## exp(0) = this, i.e. an uncovered cell reads back as the smallest catchment there is rather than as a
## negative area. Must match SIM_FLOW_FLOOR in src/pasture_3d_sim.cpp.
const FLOW_FLOOR_M2: float = 1.0

@export_group("Extent")
## World X of sample column 0. The grid is corner-aligned: sample (0,0) sits exactly here.
@export var min_x: float = 0.0
## World Z of sample row 0.
@export var min_z: float = 0.0
## Metres between samples — the SIM resolution, NOT the terrain's vertex_spacing. A Preview writes a
## result several times coarser than a build.
@export var cell_size: float = 1.0
@export var width: int = 0
@export var height: int = 0

@export_group("Channels")
## Upstream drainage area, LOG-scaled: exp(flow[i]) is the area in m². Use drainage_area_at().
@export var flow: PackedFloat32Array
## Material removed, metres. Negative or zero.
@export var erosion: PackedFloat32Array
## Material gained, metres. Positive or zero. Small until §15's sediment transport lands.
@export var deposition: PackedFloat32Array
## Standing water depth from the depression fill (filled surface − real surface), metres.
@export var wetness: PackedFloat32Array

@export_group("Source")
## Which Sim node wrote this, for the "these masks came from somewhere else" warning. A name, not a
## path: the node can be renamed or reparented and the mask is still legitimately its.
@export var source_node: String = ""
## True when the last write was a PREVIEW. A preview solves a grid several times coarser and, per §6,
## erodes noticeably deeper than the build it approximates — so a mask built from one is a guide to
## WHERE, not to HOW MUCH.
@export var source_preview: bool = false
## The resolution divisor the source solve used (1 = build resolution).
@export var source_resolution: int = 1
## The solver settings behind these channels (§15 open question 4), so a consumer can warn that the mask
## no longer matches the node that owns it rather than silently painting from a stale field.
@export var source_iterations: int = 0
@export var source_erosion_rate: float = 0.0
@export var source_area_exponent: float = 0.0
@export var source_diffusion: float = 0.0
@export var source_catchment_margin: float = 0.0
## The Sim's loop-footprint hash at write time — the same hash the node compares to decide whether its
## area has moved since the last bake.
@export var source_area_hash: String = ""
## When this was written, ISO-8601 UTC. For a human looking at a .res and asking "is this from today's
## sim or last week's".
@export var source_time: String = ""
## How many loops were merged into this grid. > 1 means the §8.2 precedence rule was in play.
@export var source_loops: int = 0


## True when the grid dimensions and all four channels agree. A result that fails this is not partially
## usable — sampling it would read someone else's memory layout.
func is_valid() -> bool:
	var n := width * height
	return (width >= 2 and height >= 2 and cell_size > 0.0
			and flow.size() == n and erosion.size() == n
			and deposition.size() == n and wetness.size() == n)


## World XZ rect this result covers, as [min_x, max_x, min_z, max_z]. The grid is corner-aligned, so the
## last sample sits exactly on the max edge.
func world_bounds() -> Array:
	return [min_x, min_x + cell_size * float(maxi(width - 1, 0)),
			min_z, min_z + cell_size * float(maxi(height - 1, 0))]


## Bilinear sample of one channel at a world position (Y ignored).
##
## Returns a DEFINED 0 outside the extent and on an invalid resource — §9 is explicit that these must
## never return garbage, because a selector reading noise off the end of a mask is close to undiagnosable.
## Callers that need to distinguish "outside" from "zero here" ask covers() first.
func sample(p_channel: Channel, p_world: Vector3) -> float:
	if not is_valid():
		return 0.0
	var src: PackedFloat32Array = _channel(p_channel)
	var fu := (p_world.x - min_x) / cell_size
	var fv := (p_world.z - min_z) / cell_size
	if fu < 0.0 or fv < 0.0 or fu > float(width - 1) or fv > float(height - 1):
		return 0.0
	var x0 := clampi(int(floor(fu)), 0, width - 1)
	var y0 := clampi(int(floor(fv)), 0, height - 1)
	var x1 := mini(x0 + 1, width - 1)
	var y1 := mini(y0 + 1, height - 1)
	var tx := clampf(fu - float(x0), 0.0, 1.0)
	var ty := clampf(fv - float(y0), 0.0, 1.0)
	var a: float = src[y0 * width + x0] * (1.0 - tx) + src[y0 * width + x1] * tx
	var b: float = src[y1 * width + x0] * (1.0 - tx) + src[y1 * width + x1] * tx
	return a * (1.0 - ty) + b * ty


## True when a world position falls inside the sampled extent.
func covers(p_world: Vector3) -> bool:
	if not is_valid():
		return false
	var b := world_bounds()
	return p_world.x >= b[0] and p_world.x <= b[1] and p_world.z >= b[2] and p_world.z <= b[3]


## Upstream drainage area at a world position, in m² — `flow` un-logged. This is the only sanctioned way
## to read the flow channel as an area; the stored values are logarithms. Outside the extent it returns
## FLOW_FLOOR_M2 (a cell drains itself and nothing else), which is what exp(0) means everywhere else in
## the grid too.
func drainage_area_at(p_world: Vector3) -> float:
	if not covers(p_world):
		return FLOW_FLOOR_M2
	return exp(sample(Channel.FLOW, p_world))


## Net height change at a world position, metres: erosion + deposition, which is exactly z_final −
## z_initial because the two channels are the two signs of one field.
func net_delta_at(p_world: Vector3) -> float:
	return sample(Channel.EROSION, p_world) + sample(Channel.DEPOSITION, p_world)


## One line for logs and inspector tooltips.
func describe() -> String:
	if not is_valid():
		return "Pasture3DSimResult: empty"
	var b := world_bounds()
	return "Pasture3DSimResult: %dx%d @ %.2f m, X %.0f..%.0f Z %.0f..%.0f, %d loop(s)%s" % [
			width, height, cell_size, b[0], b[1], b[2], b[3], source_loops,
			", PREVIEW 1/%d" % source_resolution if source_preview else ""]


func _channel(p_channel: Channel) -> PackedFloat32Array:
	match p_channel:
		Channel.EROSION:
			return erosion
		Channel.DEPOSITION:
			return deposition
		Channel.WETNESS:
			return wetness
		_:
			return flow
