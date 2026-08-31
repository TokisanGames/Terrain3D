# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadRuntime — the resolved network as a resource a GAME loads (§9.1, P6a).
#
# ---- WHAT "LOADS WITHOUT THE EDITOR AND WITHOUT THE TERRAIN" BUYS ----
#
# It is not a packaging convenience. It is the line that keeps this system from becoming a game engine:
# Pasture3D publishes road and lane DATA, and a project's traffic, AI and race logic are that project's
# to write. A runtime resource with no node references is the shape that makes the split enforceable
# rather than merely intended — there is nothing here to drive anything with.
#
# So this holds runs and the junction links between them, and answers questions. It does not tick, does
# not own nodes, and does not know a terrain exists.
@tool
class_name Pasture3DRoadRuntime
extends Resource

## Every baked run, in no particular order. Routes reference them by `id`, never by position here.
@export var runs: Array[Pasture3DRoadRun] = []

## Junction connectivity, as `[{at: Vector2, runs: PackedInt32Array, s: PackedFloat32Array}, ...]`:
## which run ids meet, and at what arc length along each. This is what the route validator walks to
## answer "do these two runs actually connect, and if not, what would" (§9.2).
@export var links: Array = []

## Bake stamp, so a stale runtime can be recognised rather than silently driven.
@export var built_at: String = ""


func run_by_id(p_id: int) -> Pasture3DRoadRun:
	for r in runs:
		if r != null and r.id == p_id:
			return r
	return null


## The nearest run to `p_world`, as `{run_id, s, t, distance, on_road, on_corridor, surface}` — the
## §9.1 progress query, minus the route-relative part, which is the route's own job.
##
## Linear over runs, and deliberately: a network is tens to hundreds of runs, the per-run test is a
## projection onto a polyline, and a spatial index here would be a second structure to invalidate for a
## query that is already cheap enough to call per frame per vehicle. If that stops being true it becomes
## a grid over run bounding boxes, which is a change behind this function rather than to it.
func locate(p_world: Vector3) -> Dictionary:
	var best := {}
	var best_d := INF
	for r in runs:
		if r == null:
			continue
		var hit := r.locate(p_world)
		if hit.is_empty():
			continue
		var d: float = hit["distance"]
		if d < best_d:
			best_d = d
			best = hit.duplicate()
			best["run_id"] = r.id
			best["surface"] = r.surface_at(float(hit["s"]))
	return best


## Run ids that meet the run `p_id`, with where along each. Used by the route validator and by any
## later auto-pathing tool, which is a solver over exactly this graph (§9.2).
func neighbours(p_id: int) -> Array:
	var out: Array = []
	for link: Dictionary in links:
		var ids: PackedInt32Array = link["runs"]
		var here := ids.find(p_id)
		if here < 0:
			continue
		for i in ids.size():
			if i == here:
				continue
			out.append({ "run_id": ids[i], "at": link["at"], "s": float(link["s"][i]),
					"from_s": float(link["s"][here]) })
	return out


## Do these two runs share a junction?
func connected(p_a: int, p_b: int) -> bool:
	for n: Dictionary in neighbours(p_a):
		if int(n["run_id"]) == p_b:
			return true
	return false
