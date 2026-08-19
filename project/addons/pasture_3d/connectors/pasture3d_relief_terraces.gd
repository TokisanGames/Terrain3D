# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DReliefTerraces — quantises relief into stepped benches: eroded hillsides, quarry cuts,
# agricultural terracing. Modelled on Gaea's FractalTerraces (multi-octave bands with controllable riser
# hardness and uneven step spacing) rather than an even Terrace, because even bands read as artificial.
#
# TERRACE is a PROFILE op: it remaps whatever is already in the accumulator. That makes this material do
# two different useful things depending on where you put it — see Base Relief below.
# See PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md §5.
@tool
class_name Pasture3DReliefTerraces
extends Pasture3DReliefMaterial

## How many benches across the full relief range.
@export_range(2, 64) var steps: int = 8:
	set(v):
		steps = maxi(v, 1)
		_touch()
## 0 = no terracing at all (the relief passes through untouched). 1 = flat benches with near-vertical
## risers. Mid values give the weathered look where each bench still slopes slightly.
@export_range(0.0, 1.0, 0.01) var hardness: float = 0.8:
	set(v):
		hardness = clampf(v, 0.0, 1.0)
		_touch()
## Randomises the height of each band boundary so the benches are not evenly spaced. This is the single
## setting that separates "eroded strata" from "staircase".
@export_range(0.0, 0.5, 0.01) var step_jitter: float = 0.08:
	set(v):
		step_jitter = maxf(v, 0.0)
		_touch()
## Length scale of the step jitter, in metres.
@export_range(4.0, 512.0, 1.0, "or_greater") var jitter_size: float = 80.0:
	set(v):
		jitter_size = maxf(v, 0.01)
		_touch()

@export_group("Base Relief")
## Built-in landform for this material to terrace, so it is useful on its own. Set to 0 when this
## material sits ABOVE another layer in a Pasture3DReliefStack — then it terraces that layer's output
## instead of adding a shape of its own.
@export_range(0.0, 1.0, 0.01, "or_greater") var base_amount: float = 1.0:
	set(v):
		base_amount = maxf(v, 0.0)
		_touch()
## Size of the largest feature in the built-in base relief, in metres.
@export_range(4.0, 512.0, 1.0, "or_greater") var base_size: float = 90.0:
	set(v):
		base_size = maxf(v, 0.01)
		_touch()
@export_range(1, 8) var base_octaves: int = 4:
	set(v):
		base_octaves = clampi(v, 1, 8)
		_touch()
@export var seed: int = 0:
	set(v):
		seed = v
		_touch()


func _build() -> void:
	if base_amount > 0.0:
		_emit(Op.FBM, Blend.ADD, [base_amount, 1.0 / base_size, base_octaves, 2.0, 0.5, seed, 1.0])
	_emit(Op.TERRACE, Blend.ADD, [steps, hardness, step_jitter, seed + 2311, 1.0 / jitter_size])


func _configuration_warning() -> String:
	if hardness <= 0.0:
		return "Relief Terraces hardness is 0 — the relief passes through without being terraced."
	return ""
