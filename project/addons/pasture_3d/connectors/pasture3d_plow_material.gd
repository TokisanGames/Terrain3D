# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DPlowMaterial — a reusable "brush material" for the Pasture3DPlow height brush. It bundles a
# heightmap (the relief shape) with how it reads, so the same relief can be saved as a .tres and shared
# across plow brushes. This is deliberately SEPARATE from the terrain's surface textures: a plow
# material defines how to DEFORM the ground, not what it looks like. Assign one on a Pasture3DPlow with
# Source = MATERIAL. See PASTURE3D_PLOW_BRUSH_SPEC.md §3.3.
@tool
class_name Pasture3DPlowMaterial
extends Resource

## Grayscale heightmap defining the relief. Red/luminance is the height (mid-grey = no change when the
## brush's Height Offset is 0.5); should be tileable. Prefer a Lossless/uncompressed import.
@export var height_map: Texture2D:
	set(v):
		height_map = v
		emit_changed()
## Flip the relief so peaks become pits.
@export var invert: bool = false:
	set(v):
		invert = v
		emit_changed()
## Per-material relief multiplier, combined with the brush's Height Scale (lets a saved material carry
## its own intensity).
@export_range(0.0, 4.0, 0.01, "or_greater") var strength: float = 1.0:
	set(v):
		strength = maxf(v, 0.0)
		emit_changed()
