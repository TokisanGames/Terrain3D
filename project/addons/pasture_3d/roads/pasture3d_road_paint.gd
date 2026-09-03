# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadPaint — TIER FAR (§10): the carriageway written into the terrain's control map, so a road
# at distance costs nothing at all. No mesh, no draw call, no streaming — and, the part that matters,
# nothing to pop, because at that range the road IS the terrain and LODs with the terrain's own clipmap.
#
# ---- THIS ONLY WORKS BECAUSE THE ROAD WENT THROUGH THE HEIGHTMAP ----
#
# Most road systems lay a ribbon ON the ground and then fight the seam between the two forever. P1 and
# P2 put the road INTO the ground, so by the time this runs the surface is already the right shape and
# the only thing left is to say what it is made of. That is a texture id and a coverage weight per cell,
# which is the smallest tier of the three and the one that is always on.
#
# ---- A KERNEL, NOT A PAINTER ----
#
# Nothing here touches a Terrain, a layer or a Node. It turns coverage into control words, and the brush
# does the writing — the same split as the grader, and for the same reason: the right answer for a cell
# is a closed-form function of the coverage and the ids, so it can be gated on numbers instead of on
# whether the terrain looks right afterwards.
@tool
class_name Pasture3DRoadPaint
extends RefCounted

## Below this coverage a cell is left alone entirely. Not a tidiness threshold: writing weight-zero
## samples still marks the layer as covering those cells, which makes the road's footprint on the layer
## grow to the whole corridor and stops anything underneath from showing through at the edges.
const MIN_COVERAGE: float = 0.004

## Control-word bit layout, mirroring Pasture3DUtil / the region control encoding. Written out here
## rather than imported so this kernel stays a pure function of ints — and so the gate can assert the
## packing, which is the part a texture id being off by one bit looks exactly like.
const BASE_SHIFT: int = 27
const OVERLAY_SHIFT: int = 22
const BLEND_SHIFT: int = 14
const ID_MASK: int = 0x1F
const BLEND_MASK: int = 0xFF
## Bits that belong to nobody here: the hole flag and the navigation flag. Preserved from whatever was
## already in the cell, because a road paint that cleared a hole somebody carved would be destroying
## authored content to say something unrelated about the surface.
const PRESERVE_MASK: int = 0x6


## Pack a control word.
static func encode(p_base: int, p_overlay: int, p_blend: int, p_preserved: int = 0) -> int:
	return ((p_base & ID_MASK) << BASE_SHIFT) \
			| ((p_overlay & ID_MASK) << OVERLAY_SHIFT) \
			| ((clampi(p_blend, 0, 255) & BLEND_MASK) << BLEND_SHIFT) \
			| (p_preserved & PRESERVE_MASK)


static func base_of(p_control: int) -> int:
	return (p_control >> BASE_SHIFT) & ID_MASK


static func overlay_of(p_control: int) -> int:
	return (p_control >> OVERLAY_SHIFT) & ID_MASK


static func blend_of(p_control: int) -> int:
	return (p_control >> BLEND_SHIFT) & BLEND_MASK


## Turn one road's surface coverage into the control words to write.
##
## `p_surface` is the grader's float coverage: 1 on the formation, easing to 0 past its edge.
## `p_existing` is the control already in each cell, or empty when the caller cannot read it back.
## `p_opts` carries `texture_id` (the surface's texture index) and `preserve_base` (default true).
##
## Returns `{cells, control, weight}` — parallel arrays over only the cells worth writing, so the caller
## walks a short list rather than the whole grid. Cells below MIN_COVERAGE are absent, not zeroed.
##
## THE BASE IS PRESERVED AND THE OVERLAY IS THE ROAD, which is the whole of how the edge works. The
## shader blends base → overlay by the blend field, so a cell at coverage 0.4 comes out as 40% road over
## whatever was already there. Writing the road into BOTH fields and feathering with the layer weight
## instead would look identical on bare terrain and wrong everywhere else: the layer weight decides how
## much of this LAYER covers, so a half-covered cell would show the layer BELOW the road rather than the
## grass beside it.
static func surface_control(p_surface: PackedFloat32Array, p_existing: PackedInt32Array,
		p_opts: Dictionary = {}) -> Dictionary:
	var texture_id := int(p_opts.get("texture_id", 0))
	# A NEGATIVE texture id means "this surface does not paint" (§4.4), and it is the DEFAULT, so this
	# is the ordinary case rather than an error. It is refused here as well as at the caller because a
	# 5-bit field turns -1 into texture 31 silently: the road would paint, in whatever texture happens
	# to sit in the last slot, and look like a wrong texture id rather than like a road nobody asked to
	# be painted.
	if texture_id < 0:
		return {"cells": PackedInt32Array(), "control": PackedInt32Array(), "weight": PackedFloat32Array()}
	# ABOVE the field is refused too, and loudly, because it is the opposite kind of mistake. -1 is the
	# default and means "do not paint", so it is silent; 32 is a typed-in id that ID_MASK would alias to
	# texture 0, painting a real texture nobody chose and looking like the road picked the wrong one.
	if texture_id > ID_MASK:
		push_warning("Pasture3D: road surface_layer_id %d is above the 5-bit control field (max %d); not painting."
				% [texture_id, ID_MASK])
		return {"cells": PackedInt32Array(), "control": PackedInt32Array(), "weight": PackedFloat32Array()}
	var preserve_base := bool(p_opts.get("preserve_base", true))
	var cells := PackedInt32Array()
	var control := PackedInt32Array()
	var weight := PackedFloat32Array()
	for i in p_surface.size():
		var cover := p_surface[i]
		if not is_finite(cover) or cover < MIN_COVERAGE:
			continue
		var cur := p_existing[i] if i < p_existing.size() else 0
		var base := base_of(cur) if preserve_base else texture_id
		cells.append(i)
		control.append(encode(base, texture_id, int(round(clampf(cover, 0.0, 1.0) * 255.0)),
				cur & PRESERVE_MASK))
		# The LAYER weight is coverage, not blend: full where the road has anything to say, so the layer
		# owns the cell and a re-bake that no longer covers it can give it back.
		weight.append(1.0)
	return {"cells": cells, "control": control, "weight": weight}


## World XZ of grid cell `p_index`. The mapping between the mask grid and the terrain, in one place,
## because it is the thing that is silently wrong when a road paints itself half a region away.
static func cell_position(p_index: int, p_gw: int, p_min_x: float, p_min_z: float,
		p_vs: float) -> Vector3:
	if p_gw <= 0:
		return Vector3.ZERO
	var ix := p_index % p_gw
	var iz := p_index / p_gw
	return Vector3(p_min_x + float(ix) * p_vs, 0.0, p_min_z + float(iz) * p_vs)
