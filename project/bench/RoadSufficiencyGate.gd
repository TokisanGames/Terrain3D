# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadSufficiencyGate — THE P4b COMPLETENESS BAR (§6.4, §11). Not "is the lane graph correct" — the
# other gates ask that — but "is it ENOUGH".
#
# ---- WHY A GATE CANNOT ANSWER THIS BY ITSELF ----
#
# Every other road gate is written against the road system's own vocabulary, so it can only ask
# questions the road system already knows how to answer. Sufficiency is the opposite question: what
# does a consumer need that nobody thought to publish? The only way to find that out is to write the
# consumer, and the only honest version of it is one that is forbidden from cheating.
#
# So this gate drives bench/reference/road_lane_follower.gd — a vehicle that follows lanes, stops at
# junctions and yields, using nothing but the four published queries — and asserts three separate
# things: that it never touches a solver, that it never needs data it cannot get, and that it actually
# gets where it is going. The first two are the sufficiency claim. The third is what stops the first two
# from being satisfiable by a follower that does nothing.
#
# Writing the follower found three gaps, all closed in the DATA rather than worked around in the
# consumer: a stop line carried no arc length, `lane_stop` answered with the first junction rather than
# the next one, and a road would not say how long it was. That is the gate working — it is meant to be
# run when the published surface changes, and to be believed when it says something is missing.
@tool
extends Node

const Follower: GDScript = preload("res://bench/reference/road_lane_follower.gd")
const FOLLOWER_PATH: String = "res://bench/reference/road_lane_follower.gd"

## Classes a consumer must never have to touch. These are the road system's own machinery: if the
## follower names one, it is doing the road system's job and the published data was not enough.
const FORBIDDEN: Array = ["Pasture3DRoadRightOfWay", "Pasture3DRoadLaneSolver",
	"Pasture3DRoadJunctionSolver", "Pasture3DRoadGrader", "Pasture3DRoadAlignmentSolver"]

const GW: int = 121
const GH: int = 121
const VS: float = 1.0
const MIN_X: float = -60.0
const MIN_Z: float = -60.0
const STEP: float = 0.1

var _fail: int = 0


func _ready() -> void:
	print("=== RoadSufficiencyGate: can a naive consumer drive on the published data? (P4b) ===\n")
	_a_the_follower_touches_only_the_published_surface()
	_b_the_follower_crosses_a_real_junction()
	_c_the_follower_never_needs_data_it_cannot_get()
	_d_the_follower_yields_to_the_traffic_that_has_priority()
	_e_the_follower_obeys_a_signal_and_is_not_fooled_by_its_absence()
	_f_the_trip_is_continuous_across_the_junction()
	print("\n=== %s (%d failures) ===\n" % ["ROAD SUFFICIENCY PASS" if _fail == 0 else "ROAD SUFFICIENCY FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	if not p_ok:
		_fail += 1
	print("%s %s: %s" % ["   " if p_ok else "!! ", p_name, p_detail])


# ---- fixtures -----------------------------------------------------------------------------------

func _road_type(p_name: String, p_priority: int, p_lanes: int) -> Pasture3DRoadType:
	var t := Pasture3DRoadType.new()
	t.type_name = p_name
	t.priority = p_priority
	t.lane_count = p_lanes
	t.lane_width = 3.5
	t.shoulder_width = 0.5
	return t


func _brush(p_net: Pasture3DRoadNetwork, p_name: String, p_a: Vector2, p_b: Vector2,
		p_type: Pasture3DRoadType) -> Pasture3DRoadBrush:
	var b := Pasture3DRoadBrush.new()
	b.name = p_name
	p_net.add_child(b)
	var path := Path3D.new()
	path.name = p_name + "Spline"
	var c := Curve3D.new()
	c.add_point(Vector3(p_a.x, 0.0, p_a.y))
	c.add_point(Vector3(p_b.x, 0.0, p_b.y))
	path.curve = c
	b.add_child(path)
	b.road_road_type = p_type
	var mod := Pasture3DNodeRoad.new()
	mod.alignment_step = 1.0
	b.modifiers = [mod]
	return b


func _grid(p_h: float) -> PackedFloat32Array:
	var z := PackedFloat32Array()
	z.resize(GW * GH)
	z.fill(p_h)
	return z


## A crossroads at the origin: a major east-west road and a minor north-south one, both 100 m long, so
## the junction sits at arc length 50 on each. Flat ground — the terrain is not what is under test here,
## and a flat world makes the follower's trip a straight line whose every position is predictable.
func _crossroads() -> Dictionary:
	var net := Pasture3DRoadNetwork.new()
	add_child(net)
	var major := _road_type("major", 10, 2)
	var minor := _road_type("minor", 1, 2)
	net.road_types = [major, minor]
	var ew := _brush(net, "EW", Vector2(-50.0, 0.0), Vector2(50.0, 0.0), major)
	var ns := _brush(net, "NS", Vector2(0.0, -50.0), Vector2(0.0, 50.0), minor)
	var ground := _grid(0.0)
	# Bake, resolve, bake — the fixed point the network's own gate drives explicitly. Two passes are
	# needed before the lane graph is built from pinned profiles.
	for _i in 3:
		for b in [ew, ns]:
			var mod: Pasture3DNodeRoad = b.road_modifier()
			b.grade_surface(mod, ground, GW, GH, MIN_X, MIN_Z, VS)
		net.resolve_junctions()
	return {"net": net, "ew": ew, "ns": ns}


## Run a follower until it finishes or the step budget runs out.
func _drive(p_f: RefCounted, p_steps: int = 400) -> int:
	var n := 0
	while n < p_steps and p_f.step(STEP):
		n += 1
	return n


func _follower_on(p_net: Pasture3DRoadNetwork, p_brush: Pasture3DRoadBrush, p_at: float) -> RefCounted:
	var f: RefCounted = Follower.new()
	f.start(p_net, p_brush.road_key(), Pasture3DRoadLanes.FORWARD, p_at)
	return f


# ---- A ------------------------------------------------------------------------------------------

## [A] The follower touches only the published surface.
##
## Read from its SOURCE, not from its behaviour: a consumer that reaches into a solver still works, and
## that is exactly the failure this gate exists to catch — the data being insufficient while everything
## appears fine because the reference consumer quietly compensated.
func _a_the_follower_touches_only_the_published_surface() -> void:
	print("[A] the follower touches only the published surface")
	var src := FileAccess.get_file_as_string(FOLLOWER_PATH)
	var code := _strip_comments(src)
	var found := PackedStringArray()
	for name: String in FORBIDDEN:
		if code.contains(name):
			found.append(name)

	# The declared surface must also be real. A `USES` list naming a method that no longer exists means
	# the surface moved and this file did not, which would make the declaration decorative.
	var owners := {
		"Pasture3DRoadNetwork": Pasture3DRoadNetwork.new(),
		"Pasture3DRoadBrush": Pasture3DRoadBrush.new(),
		"Pasture3DRoadJunction": Pasture3DRoadJunction.new(),
		"Pasture3DRoadLanes": Pasture3DRoadLanes.new(),
	}
	var absent := PackedStringArray()
	for entry: Array in Follower.USES:
		var owner: Object = owners.get(String(entry[0]), null)
		for m: String in entry[1]:
			if owner == null or not owner.has_method(m):
				absent.append("%s.%s" % [entry[0], m])
	for o in owners.values():
		if o is Node:
			o.free()
	print("    %d forbidden references: %s; %d declared methods missing: %s"
			% [found.size(), "none" if found.is_empty() else ", ".join(found),
				absent.size(), "none" if absent.is_empty() else ", ".join(absent)])
	_check("A", found.is_empty() and absent.is_empty(),
			"%s; %s" % [
				"no solver is named" if found.is_empty() else "NAMES " + ", ".join(found),
				"the declared surface is real" if absent.is_empty() else "MISSING " + ", ".join(absent)])

	# CONTROL: the scan must actually be able to see a violation. Without this, [A] passes on a scan
	# that reads the wrong file, strips too much, or matches nothing.
	var decoy := code + "\nvar cheat = Pasture3DRoadRightOfWay.conflicts([], {}, false)\n"
	var caught := false
	for name: String in FORBIDDEN:
		if _strip_comments(decoy).contains(name):
			caught = true
	print("    control: a planted solver call is %s" % ["caught" if caught else "NOT CAUGHT"])
	if not caught:
		_fail += 1; print("    !! the source scan cannot see a violation")


## Source with its comments removed, so a class named in prose is not mistaken for a call. Crude on
## purpose: the follower contains no string literal with a '#' in it, and a scan that is easy to read is
## worth more here than one that is complete.
func _strip_comments(p_src: String) -> String:
	var out := PackedStringArray()
	for line: String in p_src.split("\n"):
		var i := line.find("#")
		out.append(line if i < 0 else line.substr(0, i))
	return "\n".join(out)


# ---- B ------------------------------------------------------------------------------------------

## [B] The follower gets somewhere: it crosses the junction and reaches the far end of its road.
##
## The clause that stops the rest of the gate being satisfiable by a follower that never moves. It is
## also the connectivity claim in its bluntest form — if the lane graph does not join the minor road's
## approach to its own continuation, nothing here arrives.
func _b_the_follower_crosses_a_real_junction() -> void:
	print("[B] the follower crosses the junction and reaches the far end")
	var w := _crossroads()
	var net: Pasture3DRoadNetwork = w["net"]
	var f := _follower_on(net, w["ns"], 5.0)
	var steps := _drive(f)
	var at: Vector3 = f.position()
	print("    %d steps; crossed %d junction(s); ended at (%.1f, %.1f) on %s"
			% [steps, f.junctions_crossed, at.x, at.z, f.road_key])
	# It starts at z = -45 and runs +Z. Crossing the junction at the origin and running out of road puts
	# it at the north end, near z = +50.
	_check("B", f.junctions_crossed == 1 and f.finished and at.z > 40.0 and absf(at.x) < 4.0,
			"crossed %d (want 1); finished %s; ended z %.1f (want > 40), x %.1f (want near 0)" % [
				f.junctions_crossed, f.finished, at.z, at.x])

	# CONTROL: disable the junction and the crossing must stop happening. Without it [B] would pass on a
	# follower that simply ran along its road ignoring the junction entirely — which is the single most
	# likely way for this gate to be quietly worthless.
	for j in net.junctions:
		j.disabled = true
	var g := _follower_on(net, w["ns"], 5.0)
	_drive(g)
	print("    control: junction disabled -> crossed %d (want 0), ended z %.1f"
			% [g.junctions_crossed, g.position().z])
	if g.junctions_crossed != 0:
		_fail += 1; print("    !! the follower crosses a junction that is switched off")
	net.queue_free()


# ---- C ------------------------------------------------------------------------------------------

## [C] The follower never needs data it cannot get. THE SUFFICIENCY CLAIM ITSELF.
##
## The follower records every query that could not answer it, with the reason in words. This prints
## them verbatim: a failure here is not a bug in the follower, it is a list of things §6.4 promised a
## consumer would not have to reconstruct and did not deliver.
func _c_the_follower_never_needs_data_it_cannot_get() -> void:
	print("[C] the follower never needs data the road system will not give it")
	var w := _crossroads()
	var net: Pasture3DRoadNetwork = w["net"]
	# Both roads, both directions — a gap that only shows on the major road, or only when travelling
	# against the arc length, is still a gap.
	var missing := PackedStringArray()
	var trips := 0
	for spec: Array in [[w["ns"], Pasture3DRoadLanes.FORWARD], [w["ns"], Pasture3DRoadLanes.BACKWARD],
			[w["ew"], Pasture3DRoadLanes.FORWARD], [w["ew"], Pasture3DRoadLanes.BACKWARD]]:
		var brush: Pasture3DRoadBrush = spec[0]
		var f: RefCounted = Follower.new()
		var start: float = 5.0 if int(spec[1]) == Pasture3DRoadLanes.FORWARD else 95.0
		if not f.start(net, brush.road_key(), int(spec[1]), start):
			missing.append_array(f.missing)
			continue
		_drive(f)
		trips += 1
		for m: String in f.missing:
			if not missing.has(m):
				missing.append(m)
	for m: String in missing:
		print("    MISSING: %s" % m)
	print("    %d trips completed; %d distinct gaps" % [trips, missing.size()])
	_check("C", trips == 4 and missing.is_empty(),
			"%d of 4 trips ran; %s" % [trips,
				"nothing missing" if missing.is_empty() else "%d GAPS in the published data" % missing.size()])
	net.queue_free()


# ---- D ------------------------------------------------------------------------------------------

## [D] The follower yields to traffic that has priority, and does not yield to traffic that does not.
##
## Both halves matter. A consumer that yields to everything deadlocks at the first crossroads and looks,
## from the outside, exactly like one that is being correctly cautious.
func _d_the_follower_yields_to_the_traffic_that_has_priority() -> void:
	print("[D] the follower yields to priority traffic, and only to that")
	var w := _crossroads()
	var net: Pasture3DRoadNetwork = w["net"]
	var j: Pasture3DRoadJunction = net.junctions[0] if not net.junctions.is_empty() else null
	if j == null:
		_check("D", false, "no junction was resolved")
		net.queue_free()
		return

	# The major road's straight-ahead movement, occupied. The minor road's follower must hold for it.
	var ew_key: String = (w["ew"] as Pasture3DRoadBrush).road_key()
	var occupied := StringName("")
	for c in j.connectors:
		if c.from_key == ew_key and c.turn == Pasture3DRoadLaneConnector.Turn.STRAIGHT:
			occupied = c.id
	var minor := _follower_on(net, w["ns"], 5.0)
	minor.occupancy = func(id: StringName) -> bool: return id == occupied
	_drive(minor, 120)
	var held: bool = minor.holding and minor.hold_reason == "yield"
	print("    minor road, major road occupied: holding=%s reason=%s at z %.1f"
			% [minor.holding, minor.hold_reason, minor.position().z])

	# The reverse: the MAJOR road's follower must not hold for the minor road. Same geometry, same
	# occupancy machinery, opposite answer — and the only thing that differs is priority.
	var ns_key: String = (w["ns"] as Pasture3DRoadBrush).road_key()
	var minor_move := StringName("")
	for c in j.connectors:
		if c.from_key == ns_key and c.turn == Pasture3DRoadLaneConnector.Turn.STRAIGHT:
			minor_move = c.id
	var major := _follower_on(net, w["ew"], 5.0)
	major.occupancy = func(id: StringName) -> bool: return id == minor_move
	_drive(major)
	print("    major road, minor road occupied: crossed %d, finished %s"
			% [major.junctions_crossed, major.finished])
	_check("D", held and major.junctions_crossed == 1 and not major.holding,
			"minor %s; major %s" % [
				"holds for the major road" if held else "DOES NOT HOLD (reason '%s')" % minor.hold_reason,
				"proceeds" if major.junctions_crossed == 1 else "IS ALSO BLOCKED"])

	# CONTROL: clear the occupancy and the minor road must go. Without this, [D] passes on a follower
	# that is simply stuck — which is what a wrong stop-line distance, an empty connector list or a
	# missing curve all look like.
	minor.occupancy = func(_id: StringName) -> bool: return false
	_drive(minor)
	print("    control: nothing occupied -> minor crossed %d (want 1)" % minor.junctions_crossed)
	if minor.junctions_crossed != 1:
		_fail += 1; print("    !! the follower never proceeds even with the way clear")
	net.queue_free()


# ---- E ------------------------------------------------------------------------------------------

## [E] The follower obeys a signal, and is not fooled by the absence of one.
##
## The second clause is the one worth having. `signal_state` returns NONE at an unsignalised junction
## rather than GREEN, precisely so a naive consumer cannot read a green light where there is no light —
## and the only way to know that promise is kept is to have a naive consumer read it.
func _e_the_follower_obeys_a_signal_and_is_not_fooled_by_its_absence() -> void:
	print("[E] the follower obeys a signal, and is not fooled by the absence of one")
	var w := _crossroads()
	var net: Pasture3DRoadNetwork = w["net"]
	var j: Pasture3DRoadJunction = net.junctions[0]
	j.control = Pasture3DRoadJunction.ControlType.SIGNALS
	var ns_key: String = (w["ns"] as Pasture3DRoadBrush).road_key()
	# Put the minor road on red by parking the cycle in the phase that serves the other road.
	var mine := j.phase_for(ns_key)
	j.phase_index = 0 if mine != 0 else 1
	j.phase_elapsed = 0.0

	var f := _follower_on(net, w["ns"], 5.0)
	_drive(f, 200)
	var stopped: bool = f.holding and f.hold_reason == "signal" and f.junctions_crossed == 0
	print("    red: holding=%s reason=%s crossed=%d" % [f.holding, f.hold_reason, f.junctions_crossed])

	# Now give it a green and it must go.
	j.phase_index = mine
	j.phase_elapsed = 0.0
	_drive(f)
	print("    green: crossed=%d finished=%s" % [f.junctions_crossed, f.finished])
	_check("E", stopped and f.junctions_crossed == 1,
			"%s on red; %s on green" % [
				"holds" if stopped else "DOES NOT HOLD",
				"proceeds" if f.junctions_crossed == 1 else "STILL DOES NOT MOVE"])

	# CONTROL: an unsignalised junction must not hold the follower for a signal. NONE read as RED would
	# stop every vehicle in an uncontrolled world forever; NONE read as GREEN is the failure the query
	# is shaped to prevent. This distinguishes both from correct behaviour.
	var w2 := _crossroads()
	var net2: Pasture3DRoadNetwork = w2["net"]
	net2.junctions[0].control = Pasture3DRoadJunction.ControlType.INHERIT
	var g := _follower_on(net2, w2["ns"], 5.0)
	_drive(g)
	print("    control: unsignalised -> crossed %d (want 1), hold reason '%s' (want none)"
			% [g.junctions_crossed, g.hold_reason])
	if g.junctions_crossed != 1 or g.hold_reason == "signal":
		_fail += 1; print("    !! an unsignalised junction is being read as a signal")
	net.queue_free()
	net2.queue_free()


# ---- F ------------------------------------------------------------------------------------------

## [F] The trip is continuous: no step moves the vehicle further than it could have driven.
##
## The handoff between a road and a connector is where a lane graph goes wrong invisibly. Adopting the
## wrong arc length after a turn, or the wrong end of the junction, produces a vehicle that teleports —
## and every other criterion here still passes, because it still arrives. This is asked of the POSITION
## rather than of the data, so no bookkeeping error can hide inside it.
func _f_the_trip_is_continuous_across_the_junction() -> void:
	print("[F] the trip is continuous — nothing teleports")
	var w := _crossroads()
	var net: Pasture3DRoadNetwork = w["net"]
	var f := _follower_on(net, w["ns"], 5.0)
	# A step is SPEED x STEP = 0.8 m; allow half as much again for the curvature of a connector, where
	# the straight-line move between two samples is not the distance travelled.
	var budget := Follower.SPEED * STEP * 1.5
	var worst := 0.0
	var prev: Vector3 = f.position()
	var n := 0
	while n < 400 and f.step(STEP):
		var here: Vector3 = f.position()
		worst = maxf(worst, prev.distance_to(here))
		prev = here
		n += 1
	print("    %d steps; longest single move %.3f m (budget %.3f)" % [n, worst, budget])
	_check("F", f.junctions_crossed == 1 and worst <= budget,
			"longest move %.3f m against a %.3f m budget; %d junction(s) crossed" % [
				worst, budget, f.junctions_crossed])

	# CONTROL: the measurement must be able to see a jump. Teleport the follower a known distance and
	# the same comparison must reject it.
	# Planted on a follower that is still ON its road, so the jump is a real 25 m of arc length rather
	# than a move clamped against the end of the run.
	var t: RefCounted = _follower_on(net, w["ns"], 5.0)
	var before: Vector3 = t.position()
	t.distance += 25.0
	var jump := before.distance_to(t.position())
	print("    control: a planted 25 m jump measures %.1f m and %s the budget"
			% [jump, "exceeds" if jump > budget else "DOES NOT EXCEED"])
	if jump <= budget:
		_fail += 1; print("    !! the continuity check cannot see a teleport")
	net.queue_free()
