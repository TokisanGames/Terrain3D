# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadRouteGate — P6a: the runtime layer (§9.1) and the route model (§9.2).
#
# ---- WHY THE FIXTURES ARE BUILT BY HAND HERE ----
#
# Every other road gate builds its fixture from the kernels. This one builds `Pasture3DRoadRun` and
# `Pasture3DRoadRuntime` directly, with no brush, no network node and no terrain — because that IS the
# criterion §9.1 states. A runtime resource that could only be exercised through the editor would have
# failed the requirement while passing every test written against it.
#
# The reversal criteria are the heart of it. A rally stage runs both ways on different days, and
# `reversed` flips at read time rather than duplicating anything — so four quantities must flip and one
# must not, and a run that gets the split wrong drives perfectly while reporting nonsense to the
# co-driver.
@tool
extends Node

const CRITERIA: Array[String] = ["A", "B", "C", "D", "E", "F"]

var _fail: int = 0
var _reported: Dictionary = {}


func _ready() -> void:
	print("=== RoadRouteGate: the runtime layer and routes (P6a) ===\n")
	_a_the_runtime_needs_no_editor_and_no_terrain()
	_b_reversing_flips_four_things_and_not_the_fifth()
	_c_locate_round_trips_against_sampled_points()
	_d_route_arc_length_is_not_run_arc_length()
	_e_checkpoints_follow_a_moved_road()
	_f_the_validator_names_the_gap()
	_account_for_silent_criteria()
	print("\n=== %s (%d failures) ===\n" % ["ROAD ROUTE PASS" if _fail == 0 else "ROAD ROUTE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_reported[p_name] = true
	if not p_ok:
		_fail += 1
	print("%s %s: %s" % ["   " if p_ok else "!! ", p_name, p_detail])


func _account_for_silent_criteria() -> void:
	for name in CRITERIA:
		if not _reported.has(name):
			_fail += 1
			print("!!  %s: never reported — it crashed or returned early, so nothing was measured" % name)


# ---- fixtures -----------------------------------------------------------------------------------

## A run that turns and climbs, banked into the turn. Straight and flat would let the reversal criteria
## pass on code that flipped nothing at all: every quantity [B] checks is zero on a straight level road.
func _run(p_id: int, p_from: Vector2, p_to: Vector2, p_curve: float = 0.02) -> Pasture3DRoadRun:
	var r := Pasture3DRoadRun.new()
	r.id = p_id
	r.label = "Run%d" % p_id
	r.plan = PackedVector2Array([p_from, p_from.lerp(p_to, 0.5) + Vector2(0.0, 6.0), p_to])
	r.cum = Pasture3DRoadGrader.cumulative_length(r.plan)
	var n := int(r.cum[r.cum.size() - 1]) + 1
	var a := Pasture3DRoadAlignment.new()
	a.ds = 1.0
	var z := PackedFloat32Array(); var bank := PackedFloat32Array(); var curv := PackedFloat32Array()
	z.resize(n); bank.resize(n); curv.resize(n)
	for i in n:
		z[i] = float(i) * 0.04
		bank[i] = 0.08
		curv[i] = p_curve
	a.z = z; a.ground = z.duplicate(); a.bank = bank; a.curvature = curv
	r.alignment = a
	r.half_width = 4.0
	r.corridor_half_width = 8.0
	r.surfaces = [[0.0, r.length() * 0.5, &"tarmac"], [r.length() * 0.5, r.length(), &"gravel"]]
	return r


## Two runs meeting end to end at the origin-side join, plus a third off on its own.
func _network() -> Pasture3DRoadRuntime:
	var rt := Pasture3DRoadRuntime.new()
	var a := _run(1, Vector2(0.0, 0.0), Vector2(100.0, 0.0))
	var b := _run(2, Vector2(100.0, 0.0), Vector2(200.0, 0.0))
	var c := _run(3, Vector2(200.0, 0.0), Vector2(300.0, 0.0))
	var far := _run(9, Vector2(0.0, 900.0), Vector2(100.0, 900.0))
	rt.runs = [a, b, c, far]
	rt.links = [
		{ "at": Vector2(100.0, 0.0), "runs": PackedInt32Array([1, 2]),
			"s": PackedFloat32Array([a.length(), 0.0]) },
		{ "at": Vector2(200.0, 0.0), "runs": PackedInt32Array([2, 3]),
			"s": PackedFloat32Array([b.length(), 0.0]) },
	]
	return rt


func _route(p_rt: Pasture3DRoadRuntime, p_entries: Array) -> Pasture3DRoadRoute:
	var r := Pasture3DRoadRoute.new()
	r.entries = p_entries
	r.corridor_width = 8.0
	return r


# ---- A ------------------------------------------------------------------------------------------

## [A] The runtime answers with no editor, no terrain and no scene.
##
## §9.1's requirement, and the one that keeps this system inside its scope: Pasture3D publishes road and
## lane DATA, and a project's traffic, AI and race logic are that project's to write. A runtime resource
## holding nothing that resolves through a scene tree is what makes that split enforceable rather than
## merely intended — there is nothing in here to drive anything with.
##
## Checked by construction: this whole gate builds runs directly and never touches a brush or a Pasture3D
## node. If any of it needed one, nothing below would run at all.
func _a_the_runtime_needs_no_editor_and_no_terrain() -> void:
	print("[A] the runtime answers with no editor and no terrain")
	var rt := _network()
	var at := rt.locate(Vector3(50.0, 0.0, 1.0))
	print("    %d runs, %d links; locate(50, 1) -> run %s at s %.2f, t %+.2f, surface '%s'"
			% [rt.runs.size(), rt.links.size(), str(at.get("run_id", "?")), float(at.get("s", NAN)),
					float(at.get("t", NAN)), str(at.get("surface", ""))])
	_check("A", not at.is_empty() and int(at["run_id"]) == 1 and StringName(at["surface"]) == &"tarmac",
			"located on run %s with surface '%s' (want 1 and tarmac)"
					% [str(at.get("run_id", "?")), str(at.get("surface", ""))])

	# CONTROL: the surface must be a NAME, not a texture index. The texture a road is painted with is a
	# rendering choice that can change without the road changing, and physics asking "am I on gravel"
	# must not depend on which slot gravel occupies in this project's asset list.
	var late := rt.locate(Vector3(90.0, 0.0, 1.0))
	print("    control: further along the same run -> surface '%s' (want gravel, the second interval)"
			% str(late.get("surface", "")))
	if StringName(late.get("surface", &"")) != &"gravel":
		_fail += 1; print("    !! the surface intervals are not being read")


# ---- B ------------------------------------------------------------------------------------------

## [B] Reversing flips four things and conspicuously not the fifth.
##
## Arc length, tangent, curvature SIGN and bank SIGN all flip; height does not. A right-hander driven
## backwards is a left-hander, and pace notes read that sign directly (§9.4), so a run that keeps it calls
## every corner the wrong way. Bank flips for a related but distinct reason: the tarmac's physical tilt
## does not change, but "the driver's right" does, and bank is signed in that frame.
##
## Height is the one that gets flipped by symmetry with the others. Negate `z` and the stage runs
## underground — a climb driven backwards is a descent because you travel the profile the other way, not
## because the profile inverts.
func _b_reversing_flips_four_things_and_not_the_fifth() -> void:
	print("[B] reversing flips four things and not the fifth")
	var r := _run(1, Vector2(0.0, 0.0), Vector2(100.0, 0.0))
	var l := r.length()
	var fwd := r.sample(l * 0.25, false)
	var rev := r.sample(l * 0.75, true)  # the SAME physical point, approached from the other end
	print("    forward at s=%.1f: pos %s, curvature %+.4f, bank %+.3f"
			% [l * 0.25, str(fwd["position"].snappedf(0.01)), float(fwd["curvature"]), float(fwd["bank"])])
	print("    reversed at s=%.1f: pos %s, curvature %+.4f, bank %+.3f"
			% [l * 0.75, str(rev["position"].snappedf(0.01)), float(rev["curvature"]), float(rev["bank"])])
	var same_place: bool = (fwd["position"] as Vector3).distance_to(rev["position"]) < 1e-3
	var curv_flipped := absf(float(fwd["curvature"]) + float(rev["curvature"])) < 1e-5
	var bank_flipped := absf(float(fwd["bank"]) + float(rev["bank"])) < 1e-5
	var tan_flipped: bool = (fwd["tangent"] as Vector3).normalized().dot(
			(rev["tangent"] as Vector3).normalized()) < -0.99
	_check("B", same_place and curv_flipped and bank_flipped and tan_flipped,
			"same point %s, curvature flipped %s, bank flipped %s, tangent flipped %s (want all true)"
					% [str(same_place), str(curv_flipped), str(bank_flipped), str(tan_flipped)])

	# CONTROL: height must be IDENTICAL, not negated. This is the one a symmetric implementation gets
	# wrong, and it is the one that puts the stage underground.
	print("    control: height forward %.4f vs reversed %.4f (want identical, NOT negated)"
			% [fwd["position"].y, rev["position"].y])
	if absf(fwd["position"].y - rev["position"].y) > 1e-3:
		_fail += 1; print("    !! reversing changed the height of the road")

	# CONTROL: the fixture must actually turn and bank, or every flip above is 0 == -0.
	print("    control: the fixture's curvature %+.4f and bank %+.3f (both must be non-zero)"
			% [float(fwd["curvature"]), float(fwd["bank"])])
	if absf(float(fwd["curvature"])) < 1e-6 or absf(float(fwd["bank"])) < 1e-6:
		_fail += 1; print("    !! a straight level fixture cannot tell a flip from a no-op")

	# CONTROL: the banked up vector must be IDENTICAL forward and reversed, and must not be straight up.
	#
	# Identical is the surprising half, and it is the point. The tarmac's tilt is a fact about the world:
	# driving the other way does not re-cant the road. `bank` flips because it is signed in the DRIVER's
	# frame, and the tangent flips too, so rotating UP about the tangent by atan(bank) cancels exactly.
	# That cancellation is the criterion: it holds only if the two flips are expressed in the same frame,
	# and a world-space up that changed with the direction of travel would be a road that banks the wrong
	# way on one of the two stage days.
	var up_f: Vector3 = fwd["up"]
	var up_r: Vector3 = rev["up"]
	print("    control: up forward %s vs reversed %s (must be IDENTICAL — the road does not re-cant)"
			% [str(up_f.snappedf(0.001)), str(up_r.snappedf(0.001))])
	if up_f.distance_to(up_r) > 1e-3:
		_fail += 1; print("    !! the road's up vector changes with the direction of travel")
	print("    control: and it is tilted %.2f° off vertical (want non-zero, from the 8 %% banking)"
			% rad_to_deg(up_f.angle_to(Vector3.UP)))
	if up_f.angle_to(Vector3.UP) < 0.01:
		_fail += 1; print("    !! the up vector is not tracking the banking at all")


# ---- C ------------------------------------------------------------------------------------------

## [C] `locate` round-trips against sampled points.
##
## Sample the centreline at a known `s`, hand the world position back to `locate`, and the same `s` must
## come out with zero lateral. This is the criterion that catches a frame mismatch — a `t` measured in
## the wrong handedness, or an `s` measured along the plan while the sample walked the alignment — and
## those are invisible until something drives on it.
func _c_locate_round_trips_against_sampled_points() -> void:
	print("[C] locate round-trips against sampled points")
	var r := _run(1, Vector2(0.0, 0.0), Vector2(100.0, 0.0))
	var worst_s := 0.0
	var worst_t := 0.0
	for k in 9:
		var s := r.length() * float(k + 1) / 10.0
		var at := r.sample(s)
		var back := r.locate(at["position"])
		worst_s = maxf(worst_s, absf(float(back["s"]) - s))
		worst_t = maxf(worst_t, absf(float(back["t"])))
	print("    9 points: worst s error %.4f m, worst lateral %.4f m" % [worst_s, worst_t])
	_check("C", worst_s < 0.5 and worst_t < 0.05,
			"worst s error %.4f m, worst lateral %.4f m (want ~0)" % [worst_s, worst_t])

	# CONTROL: a point OFF the centreline must report the offset it was given, with the sign the driver's
	# frame implies. The road here runs +X, so the driver's right is +Z.
	var mid := r.sample(r.length() * 0.5)
	var right_of := (mid["position"] as Vector3) + Vector3(0.0, 0.0, 3.0)
	var off := r.locate(right_of)
	print("    control: 3 m to the driver's right reports t %+.3f (want about +3)" % float(off["t"]))
	if absf(float(off["t"]) - 3.0) > 0.2:
		_fail += 1; print("    !! lateral offset has the wrong sign or magnitude")

	# CONTROL: the corridor test must separate verge from off course (§9.3). 6 m out is verge on a road
	# with a 4 m half-width and an 8 m corridor; 12 m out is off course.
	var verge := r.locate((mid["position"] as Vector3) + Vector3(0.0, 0.0, 6.0))
	var gone := r.locate((mid["position"] as Vector3) + Vector3(0.0, 0.0, 12.0))
	print("    control: 6 m out -> on_road %s, on_corridor %s; 12 m out -> on_corridor %s"
			% [str(verge["on_road"]), str(verge["on_corridor"]), str(gone["on_corridor"])])
	if bool(verge["on_road"]) or not bool(verge["on_corridor"]) or bool(gone["on_corridor"]):
		_fail += 1; print("    !! the corridor does not separate verge from off course")


# ---- D ------------------------------------------------------------------------------------------

## [D] Route arc length is not run arc length.
##
## They are different coordinates and conflating them is the mistake `entry_at` exists to prevent: a
## checkpoint at 250 m means 250 m into the STAGE, which here is 150 m into the second run. A system that
## used the run's own arc length would look for 250 m along a 100 m road, clamp to its end, and put the
## gate at the wrong place without a word.
func _d_route_arc_length_is_not_run_arc_length() -> void:
	print("[D] route arc length is not run arc length")
	var rt := _network()
	var route := _route(rt, [{"run_id": 1, "reversed": false}, {"run_id": 2, "reversed": false},
			{"run_id": 3, "reversed": false}])
	var total := route.length(rt)
	var one := rt.run_by_id(1).length()
	var at := route.entry_at(rt, one + 30.0)
	print("    route is %.1f m over 3 runs of %.1f m; s = %.1f falls in entry %d at local s %.1f"
			% [total, one, one + 30.0, int(at["index"]), float(at["local_s"])])
	_check("D", int(at["index"]) == 1 and absf(float(at["local_s"]) - 30.0) < 0.5,
			"entry %d, local s %.2f (want entry 1 at 30 m into it)"
					% [int(at["index"]), float(at["local_s"])])

	# CONTROL: those must be DIFFERENT numbers here, or the criterion passes on code that returns `s`
	# unchanged. 130 m into the route is 30 m into run 2 — a 100 m difference.
	print("    control: route s %.1f vs run s %.1f differ by %.1f m (want > 1)"
			% [one + 30.0, 30.0, one])
	if one < 1.0:
		_fail += 1; print("    !! the first run is too short to tell the two coordinates apart")

	# CONTROL: progress must walk the entries, so the same physical point on the last run reports its
	# ROUTE distance, not its run distance.
	var far := route.sample(rt, total - 10.0)
	var prog := route.progress(rt, far["position"])
	print("    control: 10 m from the finish reports %.1f m from the start (want about %.1f)"
			% [float(prog["distance_from_start"]), total - 10.0])
	if absf(float(prog["distance_from_start"]) - (total - 10.0)) > 2.0:
		_fail += 1; print("    !! progress is not route-relative")


# ---- E ------------------------------------------------------------------------------------------

## [E] Checkpoints follow a moved road.
##
## This is the ergonomic payoff of routes being parametric (§9.2): a gate is an arc length, derived on
## demand, so moving the road moves its checkpoints. An authored gate node would stay where it was put
## and the stage would develop a checkpoint floating beside the new alignment, with nothing to flag it —
## the failure is silent and only appears when someone drives through where the gate used to be.
func _e_checkpoints_follow_a_moved_road() -> void:
	print("[E] checkpoints follow a moved road")
	var rt := _network()
	var route := _route(rt, [{"run_id": 1, "reversed": false}, {"run_id": 2, "reversed": false}])
	route.checkpoints = PackedFloat32Array([50.0])
	var before := route.gate(rt, 0)
	# Move the road: the same run, shifted 40 m in z. Nothing else is touched.
	var moved := rt.run_by_id(1)
	var shifted := PackedVector2Array()
	for pt in moved.plan:
		shifted.append(pt + Vector2(0.0, 40.0))
	moved.plan = shifted
	var after := route.gate(rt, 0)
	var delta: float = (after["position"] as Vector3).z - (before["position"] as Vector3).z
	print("    gate was at %s, is now at %s — it moved %.1f m in z with the road"
			% [str((before["position"] as Vector3).snappedf(0.1)),
					str((after["position"] as Vector3).snappedf(0.1)), delta])
	_check("E", absf(delta - 40.0) < 0.5, "the gate moved %.2f m (want 40, with the road)" % delta)

	# CONTROL: the gate must be perpendicular to the road and as wide as the corridor, or it is a point
	# rather than a gate and nothing can be driven through it.
	print("    control: gate normal %s, half width %.1f m (want along the road, %.1f)"
			% [str((after["normal"] as Vector3).snappedf(0.01)), float(after["half_width"]),
					route.corridor_width])
	if absf(float(after["half_width"]) - route.corridor_width) > 0.01 \
			or (after["normal"] as Vector3).length() < 0.9:
		_fail += 1; print("    !! the gate is not a plane across the corridor")


# ---- F ------------------------------------------------------------------------------------------

## [F] The validator reports the GAP, not just the failure.
##
## "Runs 1 and 3 do not meet" is a rejection; "nearest connection is via run 2" is a fix. The difference
## matters beyond the message: a later "pick start and finish, auto-path" tool is a solver over the same
## junction graph this walk already visits (§9.2), so naming the missing hop now is both the better error
## AND the shape that tool will need. A validator that only answered yes or no would have to be rewritten
## to become one.
func _f_the_validator_names_the_gap() -> void:
	print("[F] the validator names the gap")
	var rt := _network()
	var good := _route(rt, [{"run_id": 1, "reversed": false}, {"run_id": 2, "reversed": false}])
	var gap := _route(rt, [{"run_id": 1, "reversed": false}, {"run_id": 3, "reversed": false}])
	var good_msgs := good.validate(rt)
	var gap_msgs := gap.validate(rt)
	print("    a connected route reports %d problems" % good_msgs.size())
	for m in gap_msgs:
		print("    disconnected route says: %s" % m)
	var names_hop := gap_msgs.size() == 1 and gap_msgs[0].contains("via run 2")
	_check("F", good_msgs.is_empty() and names_hop,
			"connected route clean %s; the gap message names the missing hop %s"
					% [str(good_msgs.is_empty()), str(names_hop)])

	# CONTROL: a route naming a run that is not in the network must be caught FIRST and reported as such,
	# not reported as a missing junction — those have different fixes.
	var ghost := _route(rt, [{"run_id": 1, "reversed": false}, {"run_id": 77, "reversed": false}])
	var ghost_msgs := ghost.validate(rt)
	print("    control: a route naming a deleted run says: %s"
			% (ghost_msgs[0] if ghost_msgs.size() > 0 else "(nothing)"))
	if ghost_msgs.size() != 1 or not ghost_msgs[0].contains("not in the baked network"):
		_fail += 1; print("    !! a missing run is not distinguished from a missing junction")

	# CONTROL: a run genuinely alone in the network must not get a bogus suggestion.
	var lonely := _route(rt, [{"run_id": 1, "reversed": false}, {"run_id": 9, "reversed": false}])
	var lonely_msgs := lonely.validate(rt)
	print("    control: an unreachable run says: %s"
			% (lonely_msgs[0] if lonely_msgs.size() > 0 else "(nothing)"))
	if lonely_msgs.size() != 1 or not lonely_msgs[0].contains("no single run joins them"):
		_fail += 1; print("    !! an unreachable run was given a connection that does not exist")
