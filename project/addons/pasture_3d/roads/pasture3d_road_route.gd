# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadRoute — a stage: an ordered walk through the network (§9.2, P6a).
#
# ---- WHY THERE IS NO TRACK ASSET ----
#
# The world is open-world-first and a stage is a SECTION OF IT — point to point, with checkpoints, never
# a closed circuit (§9). So there is no separate track authoring path and nothing here is geometry: a
# route is an ordered list of runs that already exist for open-world reasons, plus a few numbers. Every
# quantity a stage needs is derived from the alignment §7 already solved.
#
# That is a simplification rather than an extra requirement, and it is what makes checkpoints parametric:
# a gate is an arc length, so MOVING THE ROAD MOVES ITS CHECKPOINTS and a stage cannot silently develop a
# gate floating beside the new alignment.
@tool
class_name Pasture3DRoadRoute
extends Resource

## The walk, start to finish: `[{run_id: int, reversed: bool}, ...]`.
##
## Runs are named by STABLE ID, not by index into the runtime's array (§9.2), so a route survives edits
## elsewhere in the network. An index would break every route the moment a road was deleted from the
## middle of the network — and break it silently, by pointing at whichever road moved into that slot.
@export var entries: Array = []

## Gates, as arc length along the ROUTE in metres — not along any one run, and not placed objects. A
## gate is derived: a plane perpendicular to the centreline at `s`, as wide as the corridor.
@export var checkpoints: PackedFloat32Array = PackedFloat32Array()

## Off-course threshold, metres either side of the centreline (§9.3). Cutting onto the verge is
## legitimate rally driving; leaving the corridor is not. So the test is against this, not against the
## carriageway edge, and the band between them is the verge you are allowed to use.
@export var corridor_width: float = 8.0

## How tall a derived checkpoint gate is, metres.
@export var gate_height: float = 6.0


## Total route length, metres. Cached is not worth it: this is a sum over a handful of entries.
func length(p_runtime: Pasture3DRoadRuntime) -> float:
	var total := 0.0
	for e: Dictionary in entries:
		var r := p_runtime.run_by_id(int(e["run_id"])) if p_runtime != null else null
		if r != null:
			total += r.length()
	return total


## Which entry contains route arc length `p_s`, as `{index, run_id, reversed, local_s, entry_start}`,
## or {} past the end.
##
## The route's `s` and a run's `s` are different coordinates and are kept visibly so. Conflating them is
## the mistake this whole function exists to prevent: a checkpoint at 4 km means 4 km into the STAGE,
## which may be 300 m into the third run, and a system that used the run's own arc length would put the
## gate 4 km along a road that is 900 m long — clamped to its end, silently, at the wrong place.
func entry_at(p_runtime: Pasture3DRoadRuntime, p_s: float) -> Dictionary:
	if p_runtime == null:
		return {}
	var walked := 0.0
	for i in entries.size():
		var e: Dictionary = entries[i]
		var r := p_runtime.run_by_id(int(e["run_id"]))
		if r == null:
			continue
		var l := r.length()
		if p_s < walked + l or i == entries.size() - 1:
			return { "index": i, "run_id": r.id, "reversed": bool(e.get("reversed", false)),
					"local_s": clampf(p_s - walked, 0.0, l), "entry_start": walked }
		walked += l
	return {}


## Position, tangent and banked up at route arc length `p_s` — the centreline a game follows.
func sample(p_runtime: Pasture3DRoadRuntime, p_s: float) -> Dictionary:
	var e := entry_at(p_runtime, p_s)
	if e.is_empty():
		return {}
	var r := p_runtime.run_by_id(int(e["run_id"]))
	if r == null:
		return {}
	var out := r.sample(float(e["local_s"]), bool(e["reversed"]))
	if not out.is_empty():
		out["run_id"] = r.id
		out["surface"] = r.surface_at(float(e["local_s"]), bool(e["reversed"]))
	return out


## Route-relative progress for a world position (§9.2):
## `{distance_from_start, lateral, next_checkpoint, next_checkpoint_distance, on_corridor, run_id}`.
##
## Route-relative, NOT lap-relative — there are no laps. `distance_from_start` walks the entries, so the
## same physical position on a road used twice by one route reports two different distances, which is
## the answer a point-to-point stage wants.
func progress(p_runtime: Pasture3DRoadRuntime, p_world: Vector3) -> Dictionary:
	if p_runtime == null or entries.is_empty():
		return {}
	var best := {}
	var best_d := INF
	var walked := 0.0
	for e: Dictionary in entries:
		var r := p_runtime.run_by_id(int(e["run_id"]))
		if r == null:
			continue
		var rev := bool(e.get("reversed", false))
		var hit := r.locate(p_world, rev)
		if not hit.is_empty() and float(hit["distance"]) < best_d:
			best_d = float(hit["distance"])
			best = { "distance_from_start": walked + float(hit["s"]), "lateral": float(hit["t"]),
					"on_corridor": absf(float(hit["t"])) <= corridor_width, "run_id": r.id }
		walked += r.length()
	if best.is_empty():
		return {}
	best["next_checkpoint"] = -1
	best["next_checkpoint_distance"] = INF
	for i in checkpoints.size():
		if checkpoints[i] >= float(best["distance_from_start"]):
			best["next_checkpoint"] = i
			best["next_checkpoint_distance"] = checkpoints[i] - float(best["distance_from_start"])
			break
	return best


## A checkpoint gate as `{position, normal, half_width, height}` — derived, never stored.
##
## This is the payoff of routes being parametric: nothing here is authored geometry, so a road that moves
## takes its gates with it. An authored gate node would stay where it was put, and a stage would develop
## a checkpoint floating beside the new alignment with nothing to flag it.
func gate(p_runtime: Pasture3DRoadRuntime, p_index: int) -> Dictionary:
	if p_index < 0 or p_index >= checkpoints.size():
		return {}
	var at := sample(p_runtime, checkpoints[p_index])
	if at.is_empty():
		return {}
	return { "position": at["position"], "normal": (at["tangent"] as Vector3).normalized(),
			"half_width": corridor_width, "height": gate_height, "up": at["up"] }


## Edit-time validation (§9.2). Returns one line per problem, empty when the route is sound.
##
## ---- THE VALIDATOR REPORTS THE GAP, NOT JUST THE FAILURE ----
##
## "no junction between run 12 and run 13" is a rejection; "nearest connection is via run 41" is a fix.
## The difference matters more than it looks: a later "pick start and finish, auto-path" tool is a solver
## over the same junction graph this walk already visits, so naming the missing hop now is both the
## better message AND the shape that tool will need. A validator that only said yes or no would have to
## be rewritten to become one.
func validate(p_runtime: Pasture3DRoadRuntime) -> PackedStringArray:
	var out := PackedStringArray()
	if p_runtime == null:
		out.append("No runtime to validate against — bake the network first.")
		return out
	if entries.is_empty():
		out.append("The route is empty: add the road runs it follows, in order.")
		return out
	for i in entries.size():
		var e: Dictionary = entries[i]
		var id := int(e.get("run_id", -1))
		if p_runtime.run_by_id(id) == null:
			out.append("Entry %d names run %d, which is not in the baked network." % [i, id])
	if out.size() > 0:
		return out
	for i in range(entries.size() - 1):
		var a := int(entries[i]["run_id"])
		var b := int(entries[i + 1]["run_id"])
		if p_runtime.connected(a, b):
			continue
		out.append("Entries %d and %d (runs %s and %s) do not meet at a junction%s"
				% [i, i + 1, _name_of(p_runtime, a), _name_of(p_runtime, b), _suggest(p_runtime, a, b)])
	for s in checkpoints:
		if s < 0.0 or s > length(p_runtime):
			out.append("Checkpoint at %.1f m is off the route, which is %.1f m long."
					% [s, length(p_runtime)])
	return out


## The one-hop connection between two runs, phrased as a suggestion, or a full stop when there is none.
## One hop only: past that the message stops being a fix and becomes a route of its own, which is the
## auto-pathing tool's job rather than the validator's.
func _suggest(p_runtime: Pasture3DRoadRuntime, p_a: int, p_b: int) -> String:
	for n: Dictionary in p_runtime.neighbours(p_a):
		if p_runtime.connected(int(n["run_id"]), p_b):
			return " — nearest connection is via run %s." % _name_of(p_runtime, int(n["run_id"]))
	return " — and no single run joins them; they may be in separate parts of the network."


func _name_of(p_runtime: Pasture3DRoadRuntime, p_id: int) -> String:
	var r := p_runtime.run_by_id(p_id)
	if r == null or r.label == "":
		return str(p_id)
	return "%d (%s)" % [p_id, r.label]
