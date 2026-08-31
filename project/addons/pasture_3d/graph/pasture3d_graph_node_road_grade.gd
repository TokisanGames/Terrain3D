# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeRoadGrade — cuts a road into a surface inside the graph (§8).
#
# ---- WHY THIS NODE IS THE POINT OF §8 ----
#
# The brush already grades. What the brush cannot express is ORDER against erosion, and that is not a
# detail: it is the difference between a road cut through a weathered mountain and a hillside that has
# weathered around an existing cut. Terrain3D's connector flattens the heightmap after the fact and
# erosion never learns; here the choice is one wire:
#
#   Input → Erosion → Road Grade → Output                     # the road cuts the weathered mountain
#
#   Input → Road Grade ──┬───────────────────→ Blend ← Erosion  # the hillside weathers AROUND the cut
#                        └─ roadbed (inv) → Blend.mask
#
# ---- AN ADAPTER, NOT A SECOND GRADER ----
#
# Every number comes from Pasture3DRoadGrader.grade, the same call the brush's own step makes, with the
# same profile arrays out of the same Pasture3DRoadBrush.grading_profile. This file converts a graph rect
# into the grader's origin-and-spacing and hands the channels back as ports. A second implementation
# would mean a road that is one shape in the brush and another in the graph, differing by the amount
# nobody notices until they are looking at a seam.
@tool
class_name Pasture3DGraphNodeRoadGrade
extends Pasture3DGraphNode

## Blend the graded result against the incoming surface. 1 is the full cut. Below 1 is NOT a shallower
## road — it is a road half-carved into the ground, which is what you want while dialling a corridor in
## and never what you want in a bake.
@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		emit_changed()

var _path: Pasture3DGraphPath = null


func op() -> StringName:
	return &"road_grade"


func role() -> Role:
	return Role.SOLVER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 2


func input_names() -> PackedStringArray:
	return PackedStringArray(["surface", "path"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.PATH])


func output_count() -> int:
	return 6


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "roadbed", "cut", "fill", "verge", "structure"])


## `height` is a surface; the five channels are [0,1] coverage and are MASKs by contract — which is what
## makes `roadbed` wire straight into a Blend's mask input, the §8 wiring this node exists for.
func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK, PortType.MASK, PortType.MASK,
			PortType.MASK, PortType.MASK])


func reads_paths() -> bool:
	return true


func set_path_inputs(p_paths: Array) -> void:
	_path = p_paths[1] if p_paths.size() > 1 and p_paths[1] is Pasture3DGraphPath else null


func blocks_native() -> bool:
	return true


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = p_inputs[0] if p_inputs.size() > 0 else PackedFloat32Array()
	if surface.size() != n:
		surface = PackedFloat32Array()
		surface.resize(n)

	# PASS THE SURFACE THROUGH when there is no road to cut, rather than returning zeros. An unresolved
	# Road Source is a normal state — a graph mid-edit passes through it constantly — and a node that
	# flattened the terrain to sea level while a road was being renamed would read as a catastrophic bug.
	if _path == null or not _path.can_grade():
		var empty := PackedFloat32Array()
		empty.resize(n)
		return [surface, empty, empty.duplicate(), empty.duplicate(), empty.duplicate(),
				empty.duplicate()]

	# The grader takes ONE spacing and a corner origin. Cell centres, matching Path Distance and Path
	# Mask, so the three nodes agree about where a cell is; sqrt(dx*dz) for the spacing, the same
	# equivalent-square the Erosion node uses on a non-square rect.
	var dx := p_rect.size.x / float(maxi(p_gw, 1))
	var dz := p_rect.size.y / float(maxi(p_gh, 1))
	var vs := sqrt(maxf(dx * dz, 1e-12))
	var res: Dictionary = Pasture3DRoadGrader.grade(surface, p_gw, p_gh,
			p_rect.position.x + 0.5 * dx, p_rect.position.y + 0.5 * dz, vs,
			_path.points, _path.alignment,
			_path.sample_half_widths, _path.sample_shoulders, _path.sample_verges,
			_path.sample_suppress, {
				"crown": _path.crown,
				"cut_batter": _path.cut_batter,
				"fill_batter": _path.fill_batter,
				"skip": _path.sample_skip,
			})

	var height: PackedFloat32Array = res["height"]
	if amount < 1.0:
		# Lerped against the INCOMING surface, not against the grader's own idea of ground: the surface
		# entering this step is what §8 makes editable, and it is the thing an Erosion node above may
		# have just changed.
		for i in n:
			height[i] = surface[i] + (height[i] - surface[i]) * amount
	return [height, res["roadbed"], res["cut"], res["fill"], res["verge"], res["structure"]]


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if _path != null and _path.segment_count() > 0 and not _path.can_grade():
		out.append("This path has no solved profile, so Road Grade passes the surface through. "
				+ "Bake the road it names.")
	if amount < 1.0:
		out.append("Road Grade is at %.0f%%, so the road is only part-carved." % (amount * 100.0))
	return out
