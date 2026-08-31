# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadPaintGate — P5 TIER FAR (§10): the carriageway written into the terrain's control map.
#
# ---- WHAT THIS CAN AND CANNOT SEE ----
#
# It gates the two halves that are decidable from numbers: the coverage the grader computes, and the
# control words the paint kernel packs from it. Both are closed form, so the right answer is written out
# rather than produced by the code under test.
#
# It does NOT drive a real Pasture3D terrain — the same boundary RoadNetworkGate draws, and for the same
# reason: `set_control_on_layer` needs regions, a layer stack and a composite, none of which a headless
# gate can assemble honestly. What that leaves uncovered is the write itself, and the manual pass in the
# editor is what covers it. The one part of the WIRING that is checkable here is the paint order, and it
# is checked, because a paint in the wrong order still produces a fully painted road — just the other
# road's, which is invisible until somebody notices the wrong surface at a junction.
@tool
extends Node

const GW: int = 81
const GH: int = 81
const VS: float = 1.0
const MIN_X: float = -40.0
const MIN_Z: float = -40.0

var _fail: int = 0


func _ready() -> void:
	print("=== RoadPaintGate: the road as terrain, at no cost (P5 tier FAR) ===\n")
	_a_coverage_is_solid_on_the_formation_and_fades_past_it()
	_b_a_control_word_packs_where_the_engine_reads_it()
	_c_the_base_texture_and_the_hole_bit_survive_a_paint()
	_d_coverage_becomes_blend_and_bare_cells_are_not_written()
	_e_roads_paint_in_ascending_priority()
	_f_a_cell_lands_where_the_bake_grid_says_it_does()
	_g_a_surface_that_does_not_paint_paints_nothing()
	print("\n=== %s (%d failures) ===\n" % ["ROAD PAINT PASS" if _fail == 0 else "ROAD PAINT FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	if not p_ok:
		_fail += 1
	print("%s %s: %s" % ["   " if p_ok else "!! ", p_name, p_detail])


# ---- fixtures -----------------------------------------------------------------------------------

## A straight road along +X at z = 0 on flat ground, graded. Returns the grader's result.
##
## Flat ground on purpose: the coverage is a function of across-distance alone, so a flat world makes
## every expected number a closed form of the half-width and the shoulder rather than something that
## has to be read back out of a solved profile.
func _straight(p_half: float = 4.0, p_shoulder: float = 1.0, p_fade: float = 1.0) -> Dictionary:
	var z := PackedFloat32Array()
	z.resize(GW * GH)
	z.fill(0.0)
	var plan := PackedVector2Array([Vector2(-35.0, 0.0), Vector2(35.0, 0.0)])
	var cum := Pasture3DRoadGrader.cumulative_length(plan)
	var n := int(cum[cum.size() - 1]) + 1
	var alignment := Pasture3DRoadAlignment.new()
	alignment.ds = 1.0
	var heights := PackedFloat32Array()
	heights.resize(n)
	heights.fill(0.0)
	alignment.z = heights
	alignment.ground = heights.duplicate()
	alignment.bank = PackedFloat32Array()
	alignment.bank.resize(n)
	alignment.curvature = PackedFloat32Array()
	alignment.curvature.resize(n)
	var half := PackedFloat32Array()
	var shoulder := PackedFloat32Array()
	var verge := PackedFloat32Array()
	half.resize(n); shoulder.resize(n); verge.resize(n)
	half.fill(p_half); shoulder.fill(p_shoulder); verge.fill(4.0)
	return Pasture3DRoadGrader.grade(z, GW, GH, MIN_X, MIN_Z, VS, plan, alignment,
			half, shoulder, verge, PackedByteArray(), {"crown": 0.0, "surface_fade": p_fade})


## Coverage at across-distance `p_u` on the road above, sampled at x = 0.
func _cover_at(p_res: Dictionary, p_u: float) -> float:
	var cover: PackedFloat32Array = p_res["surface"]
	var ix := int(round((0.0 - MIN_X) / VS))
	var iz := int(round((p_u - MIN_Z) / VS))
	return cover[iz * GW + ix]


# ---- A ------------------------------------------------------------------------------------------

## [A] Coverage is 1 out to the edge of formation and eases to 0 over the fade, so the painted road has
## an edge rather than a cut-out.
##
## The numbers are closed form: half 4 + shoulder 2 = 6 m of solid, then one shoulder of fade to 8 m.
## Smoothstep, so the midpoint of the fade is exactly 0.5 and the ends are exactly 1 and 0 — three
## values that between them pin the curve without asserting its whole shape. The widths are chosen so
## every sampled across-distance lands ON a grid line: at 1 m spacing an off-grid sample snaps to its
## neighbour, which reads as the fade being absent when it is only being sampled past its end.
func _a_coverage_is_solid_on_the_formation_and_fades_past_it() -> void:
	print("[A] coverage is solid on the formation and fades past it")
	var res := _straight(4.0, 2.0, 1.0)
	var on_bed := _cover_at(res, 0.0)
	var at_edge := _cover_at(res, 6.0)
	var mid_fade := _cover_at(res, 7.0)
	var past := _cover_at(res, 8.0)
	var far := _cover_at(res, 11.0)
	print("    u = 0.0 -> %.3f | 6.0 (edge) -> %.3f | 7.0 (mid fade) -> %.3f | 8.0 -> %.3f | 11.0 -> %.3f"
			% [on_bed, at_edge, mid_fade, past, far])
	_check("A", is_equal_approx(on_bed, 1.0) and is_equal_approx(at_edge, 1.0)
			and absf(mid_fade - 0.5) < 0.01 and past < 0.01 and far < 0.01,
			"centre %.3f and edge %.3f (want 1.000); mid-fade %.3f (want 0.500); past %.3f and far %.3f (want 0.000)"
					% [on_bed, at_edge, mid_fade, past, far])

	# CONTROL: no fade must give a hard edge. Without it [A] passes on a coverage that is always 1
	# inside some radius and 0 outside it, with the fade doing nothing.
	var hard := _straight(4.0, 2.0, 0.0)
	var hard_mid := _cover_at(hard, 7.0)
	print("    control: surface_fade 0 -> coverage at 7.0 is %.3f (want 0.000)" % hard_mid)
	if hard_mid > 0.001:
		_fail += 1; print("    !! the fade width does not change the coverage")


# ---- B ------------------------------------------------------------------------------------------

## [B] A control word packs into the bits the engine reads it out of.
##
## Asserted against LITERAL shifts, not against the kernel's own constants — those are the thing under
## test. This is the criterion that catches a texture id one bit out of place, which produces a road
## painted in a texture nobody chose and looks, in the editor, exactly like a wrong texture id.
func _b_a_control_word_packs_where_the_engine_reads_it() -> void:
	print("[B] a control word packs where the engine reads it")
	var w := Pasture3DRoadPaint.encode(7, 3, 200)
	var base_bits := (w >> 27) & 0x1F
	var overlay_bits := (w >> 22) & 0x1F
	var blend_bits := (w >> 14) & 0xFF
	print("    encode(base 7, overlay 3, blend 200) -> base %d, overlay %d, blend %d"
			% [base_bits, overlay_bits, blend_bits])
	var packed: bool = base_bits == 7 and overlay_bits == 3 and blend_bits == 200
	var reads_back: bool = Pasture3DRoadPaint.base_of(w) == 7 and Pasture3DRoadPaint.overlay_of(w) == 3 and Pasture3DRoadPaint.blend_of(w) == 200
	_check("B", packed and reads_back,
			"%s; accessors %s" % ["packed correctly" if packed else "WRONG BITS",
				"agree" if reads_back else "DISAGREE with the literal shifts"])

	# CONTROL: the widest legal texture id must not bleed into the next field. A 5-bit id is 0..31, and
	# an id written without masking would push its top bit into the field above and change a DIFFERENT
	# texture — the failure that is invisible until the one road using id 31 is painted.
	var wide := Pasture3DRoadPaint.encode(31, 31, 255)
	var clean: bool = Pasture3DRoadPaint.base_of(wide) == 31 and Pasture3DRoadPaint.overlay_of(wide) == 31 \
			and Pasture3DRoadPaint.blend_of(wide) == 255
	print("    control: ids 31/31 blend 255 -> base %d, overlay %d, blend %d (want 31/31/255)"
			% [Pasture3DRoadPaint.base_of(wide), Pasture3DRoadPaint.overlay_of(wide), Pasture3DRoadPaint.blend_of(wide)])
	if not clean:
		_fail += 1; print("    !! a maximum-width id bleeds into the neighbouring field")


# ---- C ------------------------------------------------------------------------------------------

## [C] The base texture and the hole bit survive a paint.
##
## A road says what the SURFACE is. It has no opinion about what was underneath it or about a hole
## somebody carved through the terrain, and a paint that cleared either would be destroying authored
## content to say something unrelated.
func _c_the_base_texture_and_the_hole_bit_survive_a_paint() -> void:
	print("[C] the base texture and the hole bit survive a paint")
	# Existing cell: base 11, overlay 2, blend 0, hole bit set.
	var existing := Pasture3DRoadPaint.encode(11, 2, 0) | 0x4
	var cover := PackedFloat32Array([1.0])
	var plan := Pasture3DRoadPaint.surface_control(cover, PackedInt32Array([existing]), {"texture_id": 5})
	var out: int = plan["control"][0]
	print("    was base 11 + hole -> base %d, overlay %d, hole bit %s"
			% [Pasture3DRoadPaint.base_of(out), Pasture3DRoadPaint.overlay_of(out), "kept" if (out & 0x4) != 0 else "LOST"])
	_check("C", Pasture3DRoadPaint.base_of(out) == 11 and Pasture3DRoadPaint.overlay_of(out) == 5 and (out & 0x4) != 0,
			"base %d (want 11); overlay %d (want 5); hole %s" % [
				Pasture3DRoadPaint.base_of(out), Pasture3DRoadPaint.overlay_of(out),
				"kept" if (out & 0x4) != 0 else "DESTROYED"])

	# CONTROL: preserve_base off must actually replace the base. Without it [C] would pass on a kernel
	# that ignored the option and always kept what was there.
	var forced := Pasture3DRoadPaint.surface_control(cover, PackedInt32Array([existing]),
			{"texture_id": 5, "preserve_base": false})
	var f: int = forced["control"][0]
	print("    control: preserve_base off -> base %d (want 5)" % Pasture3DRoadPaint.base_of(f))
	if Pasture3DRoadPaint.base_of(f) != 5:
		_fail += 1; print("    !! preserve_base does nothing")


# ---- D ------------------------------------------------------------------------------------------

## [D] Coverage becomes the blend field, and a cell with nothing to say is not written at all.
##
## The second half matters more than it looks. Writing a weight-zero sample still marks the layer as
## COVERING that cell, so a road that wrote its whole corridor would own every cell out to the verge and
## stop anything underneath showing through at the edges — a road with a rectangle of dead ground round
## it, from a paint that looked like it was doing nothing.
func _d_coverage_becomes_blend_and_bare_cells_are_not_written() -> void:
	print("[D] coverage becomes blend, and empty cells are not written")
	var cover := PackedFloat32Array([1.0, 0.4, 0.0, 0.001])
	var plan := Pasture3DRoadPaint.surface_control(cover, PackedInt32Array(), {"texture_id": 5})
	var cells: PackedInt32Array = plan["cells"]
	var control: PackedInt32Array = plan["control"]
	var blends := PackedStringArray()
	for c in control:
		blends.append(str(Pasture3DRoadPaint.blend_of(c)))
	print("    coverage 1.0, 0.4, 0.0, 0.001 -> %d cells %s with blends %s"
			% [cells.size(), str(Array(cells)), " ".join(blends)])
	# 0.4 x 255 = 102. The last two are below MIN_COVERAGE and must not appear.
	_check("D", cells.size() == 2 and cells[0] == 0 and cells[1] == 1
			and Pasture3DRoadPaint.blend_of(control[0]) == 255 and Pasture3DRoadPaint.blend_of(control[1]) == 102,
			"%d cells (want 2, indices 0 and 1); blends %s (want 255 102)" % [cells.size(), " ".join(blends)])

	# CONTROL: full coverage everywhere must write every cell. Without it [D] passes on a kernel that
	# writes nothing at all, which satisfies "empty cells are not written" completely.
	var full := PackedFloat32Array([1.0, 1.0, 1.0, 1.0])
	var all_cells: PackedInt32Array = Pasture3DRoadPaint.surface_control(full, PackedInt32Array(), {})["cells"]
	print("    control: coverage 1.0 x4 -> %d cells (want 4)" % all_cells.size())
	if all_cells.size() != 4:
		_fail += 1; print("    !! covered cells are being dropped too")


# ---- E ------------------------------------------------------------------------------------------

## [E] Roads paint in ascending priority, so the most important surface is the one written last.
##
## The layer is REPLACE and the last write wins, so this ordering IS the priority rule for surfaces
## (§5.2). A paint in the wrong order still produces a fully painted road — the other road's — which is
## why it is asserted here rather than left to be noticed in the editor.
func _e_roads_paint_in_ascending_priority() -> void:
	print("[E] roads paint in ascending priority")
	var net := Pasture3DRoadNetwork.new()
	add_child(net)
	var major := _road_type("major", 10)
	var minor := _road_type("minor", 1)
	net.road_types = [major, minor]
	var a := _brush(net, "MinorFirst", minor)
	var b := _brush(net, "MajorSecond", major)
	# Scene order already has the minor road first, so a pass that did nothing would look correct.
	# The revealing case is the opposite one, which the control below builds.
	var names := PackedStringArray()
	for x in net.paint_order([b, a]):
		names.append("%s(%d)" % [x.name, x.road_priority()])
	print("    given [major, minor] -> %s" % " then ".join(names))
	_check("E", names.size() == 2 and names[0].begins_with("MinorFirst"),
			"paints %s (want the minor road first, so the major road overwrites it)" % " then ".join(names))

	# CONTROL: swapping the priorities must swap the order. Without it [E] passes on an implementation
	# that sorts by name, by scene order, or not at all.
	a.road_road_type = major
	b.road_road_type = minor
	var swapped := PackedStringArray()
	for x in net.paint_order([b, a]):
		swapped.append("%s(%d)" % [x.name, x.road_priority()])
	print("    control: priorities swapped -> %s" % " then ".join(swapped))
	if swapped.is_empty() or not swapped[0].begins_with("MajorSecond"):
		_fail += 1; print("    !! the paint order does not follow priority")
	net.queue_free()


func _road_type(p_name: String, p_priority: int) -> Pasture3DRoadType:
	var t := Pasture3DRoadType.new()
	t.type_name = p_name
	t.priority = p_priority
	t.lane_count = 2
	return t


func _brush(p_net: Pasture3DRoadNetwork, p_name: String, p_type: Pasture3DRoadType) -> Pasture3DRoadBrush:
	var b := Pasture3DRoadBrush.new()
	b.name = p_name
	p_net.add_child(b)
	b.road_road_type = p_type
	return b


# ---- F ------------------------------------------------------------------------------------------

## [F] A mask cell lands at the world position the bake grid says it does.
##
## One multiplication and one add, and the reason it is gated is that it is the step with no feedback:
## every other part of the paint can be right while this is wrong, and the result is a correct road
## painted somewhere else entirely.
func _f_a_cell_lands_where_the_bake_grid_says_it_does() -> void:
	print("[F] a cell lands where the bake grid says it does")
	# Cell (3, 2) of an 81-wide grid is index 2 * 81 + 3 = 165.
	var at := Pasture3DRoadPaint.cell_position(165, GW, MIN_X, MIN_Z, VS)
	var origin := Pasture3DRoadPaint.cell_position(0, GW, MIN_X, MIN_Z, VS)
	print("    index 165 on an %d-wide grid from (%.1f, %.1f) at %.1f m -> (%.1f, %.1f); index 0 -> (%.1f, %.1f)"
			% [GW, MIN_X, MIN_Z, VS, at.x, at.z, origin.x, origin.z])
	_check("F", is_equal_approx(at.x, MIN_X + 3.0) and is_equal_approx(at.z, MIN_Z + 2.0)
			and is_equal_approx(origin.x, MIN_X) and is_equal_approx(origin.z, MIN_Z),
			"(%.1f, %.1f) (want %.1f, %.1f); origin (%.1f, %.1f) (want %.1f, %.1f)" % [
				at.x, at.z, MIN_X + 3.0, MIN_Z + 2.0, origin.x, origin.z, MIN_X, MIN_Z])

	# CONTROL: a different vertex spacing must scale the offset, not just shift it. Without this the
	# criterion passes on a mapping that ignores `vs` — correct at 1 m, and wrong on every terrain that
	# is not 1 m, which is the default but not the rule.
	var coarse := Pasture3DRoadPaint.cell_position(165, GW, MIN_X, MIN_Z, 2.0)
	print("    control: 2 m spacing -> (%.1f, %.1f) (want %.1f, %.1f)"
			% [coarse.x, coarse.z, MIN_X + 6.0, MIN_Z + 4.0])
	if not is_equal_approx(coarse.x, MIN_X + 6.0) or not is_equal_approx(coarse.z, MIN_Z + 4.0):
		_fail += 1; print("    !! vertex spacing does not scale the cell position")


# ---- G ------------------------------------------------------------------------------------------

## [G] A surface with no texture chosen paints nothing at all.
##
## `surface_layer_id` is -1 by default and -1 means "do not paint" (§4.4), so this is the state every
## project is in before somebody picks a road texture — not an error case. It is gated because of what
## -1 does on the way into a 5-bit field: it becomes 31. The road would paint, in whatever texture sits
## in the last slot, and the symptom would read as a wrong texture id rather than as a road nobody asked
## to be painted at all.
func _g_a_surface_that_does_not_paint_paints_nothing() -> void:
	print("[G] a surface with no texture chosen paints nothing")
	var cover := PackedFloat32Array([1.0, 1.0, 1.0])
	var plan := Pasture3DRoadPaint.surface_control(cover, PackedInt32Array(), {"texture_id": -1})
	var cells: PackedInt32Array = plan["cells"]
	print("    fully covered, texture_id -1 -> %d cells written" % cells.size())
	_check("G", cells.is_empty(), "%d cells (want 0 — -1 must not become texture 31)" % cells.size())

	# CONTROL: id 0 is a real texture and must paint. Without it [G] passes on a kernel that has stopped
	# painting entirely, and "paints nothing" is then true for the wrong reason.
	var real: PackedInt32Array = Pasture3DRoadPaint.surface_control(cover, PackedInt32Array(),
			{"texture_id": 0})["cells"]
	print("    control: texture_id 0 -> %d cells (want 3)" % real.size())
	if real.size() != 3:
		_fail += 1; print("    !! texture 0 is being refused as though it meant nothing")
