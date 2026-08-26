# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DNodeSmooth — NaN-aware separable Gaussian blur over the brush's output grid, as a modifier
# stack step. The field-operator replacement for Pasture3DMound's `smooth_passes`.
#
# A FIELD modifier (see Pasture3DNode's header): it reads neighbours, so it cannot be folded
# into the rasteriser's cell loop and forces the working grid to be materialised at its position in the
# stack. NaN cells — outside the footprint, or clipped away — are skipped rather than averaged, so the
# blur never bleeds the feature outward past its own boundary.
#
# Position in the stack is the whole point of having it here rather than as a property: smoothing before
# a relief pass softens the shape the relief lands on, smoothing after it softens the relief itself, and
# those are different results that used to be inexpressible.
@tool
class_name Pasture3DNodeSmooth
extends Pasture3DNode

## Blur passes. 0 = off (no cost, no allocation), 1-2 = subtle, 3+ = heavy rounding.
@export_range(0, 5) var passes: int = 1:
	set(v):
		passes = v
		_touch()


func needs_grid() -> bool:
	return true


func op() -> StringName:
	return &"smooth"


func is_active() -> bool:
	return enabled and passes > 0


func to_params() -> Dictionary:
	return {"passes": passes}
