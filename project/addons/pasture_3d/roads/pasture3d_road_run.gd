# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadRun — one baked road, as the RUNTIME sees it (§9.1, P6a).
#
# ---- WHY THIS IS A COPY AND NOT A REFERENCE ----
#
# The whole point of the runtime layer is that it "loads without the editor plugin and without the
# terrain" (§9.1). So a run may not hold a brush, a node path, or anything that resolves through a scene
# tree — a race mode loads this resource and drives it, with no Pasture3D node in the project at all.
# Everything the brush knew that the runtime needs is COPIED here at bake, and the copy is the contract.
#
# That has a cost worth stating: a run is stale the moment the road is edited, exactly like a baked
# lightmap. The network rebuilds it on resolve, and a run carries `source_key` so a rebuild can match it
# back to the brush it came from — but nothing here notices the road moving on its own.
@tool
class_name Pasture3DRoadRun
extends Resource

## Stable identity, used by routes to name this run (§9.2). Assigned at first bake and never reused, so
## a route survives edits elsewhere in the network — the same discipline as §5.3's exclusion lists. An
## ARRAY INDEX would break every route the moment a road was deleted from the middle of the network, and
## it would break silently, by pointing at a different road that happens to be there now.
@export var id: int = -1

## The brush's `road_key()` at bake time — a node path relative to the network. Editor-side only: it is
## how a rebuild matches this run back to its source. The runtime never resolves it, because at runtime
## there is nothing to resolve it against.
@export var source_key: String = ""

## Human-readable, for route inspectors and the validator's messages.
@export var label: String = ""

## The plan: world XZ of the centreline, and the cumulative arc length at each point.
@export var plan: PackedVector2Array = PackedVector2Array()
@export var cum: PackedFloat32Array = PackedFloat32Array()

## The solved vertical alignment — height, banking, curvature. Already a Resource with exported arrays,
## so it serialises as-is rather than being unpacked into parallel arrays here.
@export var alignment: Pasture3DRoadAlignment

## Cross-section, frozen at bake. `lanes` is the §9.1 lane list in the profile's frame.
@export var half_width: float = 4.0
@export var shoulder_width: float = 0.5
@export var crown: float = 0.05
@export var lanes: Array = []
@export var one_way: bool = false

## Corridor half-width for the off-course test (§9.3). The band between the carriageway edge and this is
## verge you are allowed to use; beyond it is off course.
@export var corridor_half_width: float = 8.0

## Surface as data (§4.4): `[[from_s, to_s, surface_id], ...]`, ascending and non-overlapping. Rally
## physics reads this rather than sampling the control map, because the control map is a rendering
## artifact and the surface a car is on is a fact about the road.
@export var surfaces: Array = []


func length() -> float:
	return cum[cum.size() - 1] if cum.size() > 0 else 0.0


## Position, tangent and the banked up vector at arc length `p_s`, as
## `{position, tangent, up, curvature, bank, grade}`.
##
## `p_reversed` is applied HERE rather than by duplicating the run, which is the §9.2 requirement: a
## rally stage runs both ways on different days, and nothing should be stored twice for it.
##
## ---- WHAT REVERSING ACTUALLY FLIPS ----
##
## Four things flip and one conspicuously does not, and getting the split wrong produces a road that
## drives correctly and reports nonsense:
##
##   arc length  — `s` is measured from the other end.
##   tangent     — negated; you are going the other way.
##   curvature   — SIGN flips. A right-hander driven backwards is a left-hander. Pace notes read this
##                 sign directly (§9.4), so a run that kept it calls every corner the wrong way.
##   bank        — SIGN flips, for the same reason and a different one. The tarmac's physical tilt does
##                 not change; "the driver's right" does, and `bank` is signed in that frame.
##   height      — does NOT flip. The road is where it is. A climb driven backwards is a descent, but
##                 that falls out of travelling along the profile in the other direction, not out of
##                 negating it — negate `z` and the stage runs underground.
func sample(p_s: float, p_reversed: bool = false) -> Dictionary:
	if alignment == null or plan.size() < 2:
		return {}
	var len := length()
	var s := clampf(p_s, 0.0, len)
	var flip := -1.0 if p_reversed else 1.0
	var at_s := (len - s) if p_reversed else s
	var pos := Pasture3DRoadGrader.plan_point_at(plan, cum, at_s)
	var tan := Pasture3DRoadGrader.plan_tangent_at(plan, cum, at_s)
	if tan.length_squared() > 1e-12:
		tan = tan.normalized() * flip
	var i := alignment.index_at(at_s)
	var bank: float = (alignment.bank[i] if i < alignment.bank.size() else 0.0) * flip
	var curv: float = (alignment.curvature[i] if i < alignment.curvature.size() else 0.0) * flip
	var grade: float = alignment.grade_at(i) * flip
	var y := alignment.height_at(at_s)
	# The banked up: the surface normal tilted about the direction of travel. `bank` is a rise/run across
	# the road, so the tilt angle is atan(bank), not bank — small-angle at 6 % and wrong by a degree at 30.
	var fwd := Vector3(tan.x, 0.0, tan.y)
	var up := Vector3.UP.rotated(fwd.normalized(), atan(bank)) if fwd.length_squared() > 1e-12 \
			else Vector3.UP
	return {
		"position": Vector3(pos.x, y, pos.y),
		"tangent": fwd,
		"up": up,
		"curvature": curv,
		"bank": bank,
		"grade": grade,
	}


## The surface id at arc length `p_s`, or &"" where nothing was recorded.
##
## A StringName naming an asset, not a texture index: the texture a road is PAINTED with is a rendering
## choice that can change without the road changing, and physics asking "am I on gravel" must not have to
## know which slot gravel happens to occupy in this project's asset list.
func surface_at(p_s: float, p_reversed: bool = false) -> StringName:
	var at_s := (length() - p_s) if p_reversed else p_s
	for iv: Array in surfaces:
		if at_s >= float(iv[0]) and at_s < float(iv[1]):
			return StringName(iv[2])
	return &""


## How far either side of a surface boundary the two blend, metres. A real surface change is not a line
## — tarmac runs out into loose gravel over a few metres of scatter — and physics that stepped grip at a
## line would snap the car at a point the driver cannot see.
const SURFACE_BLEND: float = 6.0


## The surface at `p_s` as `{primary, secondary, blend}` (§9.1).
##
## `blend` runs 0 to 1 from primary toward secondary. Away from a boundary it is 0 and `secondary` is
## empty, so the common case is one name and a zero — a caller that ignores blending entirely still gets
## the right answer everywhere except in the transition.
##
## Blending is the requirement, not a nicety: rally physics needs surface as data AND needs the blend so
## grip does not step-change at a transition. A stepped coefficient at 120 km/h is an unrecoverable snap
## with no visible cause, which reads as a physics bug rather than as a data one.
func sample_surface(p_s: float, p_reversed: bool = false) -> Dictionary:
	var at_s := (length() - p_s) if p_reversed else p_s
	var here := StringName("")
	var idx := -1
	for i in surfaces.size():
		if at_s >= float(surfaces[i][0]) and at_s < float(surfaces[i][1]):
			here = StringName(surfaces[i][2])
			idx = i
			break
	if idx < 0:
		return { "primary": &"", "secondary": &"", "blend": 0.0 }
	var from_s := float(surfaces[idx][0])
	var to_s := float(surfaces[idx][1])
	# Nearest boundary that HAS another surface on the far side. The ends of the road are boundaries too
	# and blending into nothing there would fade grip away at the start line.
	if idx > 0 and at_s - from_s < SURFACE_BLEND:
		var other := StringName(surfaces[idx - 1][2])
		if other != here:
			# Half the blend band lies each side of the line, so at the line itself blend is 0.5 and the
			# two surfaces are equal. Anything else makes the transition asymmetric, and which way it
			# leans would then depend on the direction of travel.
			return { "primary": here, "secondary": other,
					"blend": (1.0 - (at_s - from_s) / SURFACE_BLEND) * 0.5 }
	if idx < surfaces.size() - 1 and to_s - at_s < SURFACE_BLEND:
		var other := StringName(surfaces[idx + 1][2])
		if other != here:
			return { "primary": here, "secondary": other,
					"blend": (1.0 - (to_s - at_s) / SURFACE_BLEND) * 0.5 }
	return { "primary": here, "secondary": &"", "blend": 0.0 }


## Where `p_world` sits relative to this run: `{s, t, distance, on_road, on_corridor}`.
##
## `t` is signed across-distance, positive to the driver's RIGHT in the direction of travel — the
## grader's `u`, and the same frame the lanes and markings were authored in. Reversed, `t` flips with the
## tangent, because right and left are properties of the driver rather than of the tarmac.
func locate(p_world: Vector3, p_reversed: bool = false) -> Dictionary:
	if plan.size() < 2:
		return {}
	var hit := Pasture3DRoadGrader.nearest_on_plan(plan, cum, Vector2(p_world.x, p_world.z))
	var d: float = hit[0]
	var raw_s: float = hit[1]
	var t: float = d * float(hit[2])
	var len := length()
	return {
		"s": (len - raw_s) if p_reversed else raw_s,
		"t": -t if p_reversed else t,
		"distance": d,
		"on_road": d <= half_width,
		"on_corridor": d <= corridor_half_width,
	}
