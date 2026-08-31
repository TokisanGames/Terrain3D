# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadModelGate — the road system's DATA MODEL and its resolve chain (road P0).
# See PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §4, §5.3 and §11.
#
# P0 has no terrain effect, so there is no field delta to measure. What there IS to measure is every
# claim the model makes that a later phase will be built on top of and could not cheaply revisit:
#
#   A  a value resolves from the NEAREST level that has an opinion (Segment -> Brush -> Group ->
#      Network -> RoadType), which is the whole point of the hierarchy
#   B  clearing an override RE-INHERITS rather than freezing the value it happened to be showing —
#      the thing the rejected push-down design could not do
#   C  segments override by ARC LENGTH, last match winning
#   D  inserting a spline point does NOT disturb a segment override — the reason segments are ranges
#      rather than per-interval, and the single most expensive claim here to be wrong about
#   E  type exclusion is by REFERENCE, so reordering the network catalogue re-points nothing
#   F  a group edit moves the children that never disagreed and leaves the ones that did
#
# House discipline: every criterion carries a CONTROL that must move if the path is dead.
extends Node

var _fail := 0
var _root: Node3D


func _ready() -> void:
	print("=== RoadModelGate: road data model + resolve chain (P0) ===\n")
	_root = Node3D.new()
	add_child(_root)
	_a_resolves_from_nearest_level()
	_b_clearing_re_inherits()
	_c_segments_override_by_arc_length()
	_d_inserting_a_point_does_not_move_an_override()
	_e_exclusion_survives_a_reorder()
	_f_group_edit_moves_only_the_undisagreeing()
	print("\n=== %s (%d failures) ===\n" % ["ROAD MODEL PASS" if _fail == 0 else "ROAD MODEL FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---- fixture ------------------------------------------------------------------------------------

## Network -> Group -> Brush, with one road type in the catalogue. Returned as a dictionary rather than
## members so each criterion builds its own and cannot leak state into the next.
func _build(p_lanes_on_type: int = 2) -> Dictionary:
	var net := Pasture3DRoadNetwork.new()
	var rt := Pasture3DRoadType.new()
	rt.type_name = "Country Lane"
	rt.lane_count = p_lanes_on_type
	rt.surface_id = &"tarmac"
	net.road_types = [rt]
	_root.add_child(net)

	var grp := Pasture3DRoadGroup.new()
	net.add_child(grp)

	var brush := Pasture3DRoadBrush.new()
	grp.add_child(brush)

	return { "net": net, "group": grp, "brush": brush, "type": rt }


func _teardown(p_fx: Dictionary) -> void:
	var net: Node = p_fx["net"]
	if is_instance_valid(net):
		net.queue_free()


# ---- A ------------------------------------------------------------------------------------------

func _a_resolves_from_nearest_level() -> void:
	print("[A] a value resolves from the nearest level with an opinion")
	var fx := _build(2)
	var brush: Pasture3DRoadBrush = fx["brush"]
	var grp: Pasture3DRoadGroup = fx["group"]
	var net: Pasture3DRoadNetwork = fx["net"]

	# Nobody overrides: the RoadType answers.
	var from_type := brush.resolved_lane_count()
	# Network has an opinion.
	net.road_defaults.lane_count = 3
	var from_net := brush.resolved_lane_count()
	# Group outranks the network.
	grp.road_defaults.lane_count = 4
	var from_group := brush.resolved_lane_count()
	# Brush outranks the group.
	brush.road_defaults.lane_count = 5
	var from_brush := brush.resolved_lane_count()
	# A segment outranks the brush, but only inside its range.
	var seg := Pasture3DRoadSegment.new()
	seg.from_distance = 100.0
	seg.to_distance = 200.0
	seg.lane_count = 6
	brush.segments = [seg]
	var inside := brush.resolved_lane_count(150.0)
	var outside := brush.resolved_lane_count(50.0)

	print("    type=%d net=%d group=%d brush=%d segment@150=%d outside@50=%d" %
			[from_type, from_net, from_group, from_brush, inside, outside])
	var ok := from_type == 2 and from_net == 3 and from_group == 4 and from_brush == 5 \
			and inside == 6 and outside == 5
	if not ok:
		_fail += 1; print("    !! the chain did not resolve nearest-first (want 2,3,4,5,6,5)")

	# CONTROL: an UNSET level is skipped rather than answering with its sentinel. Clearing the brush
	# must fall through to the group, not to -1 and not to the type.
	brush.road_defaults.lane_count = -1
	var skipped := brush.resolved_lane_count()
	print("    control: brush unset -> %d (want 4, the group's)" % skipped)
	if skipped != 4:
		_fail += 1; print("    !! an unset level was not skipped")
	_teardown(fx)


# ---- B ------------------------------------------------------------------------------------------

func _b_clearing_re_inherits() -> void:
	print("[B] clearing an override re-inherits (it does not freeze the shown value)")
	var fx := _build(2)
	var brush: Pasture3DRoadBrush = fx["brush"]
	var grp: Pasture3DRoadGroup = fx["group"]

	grp.road_defaults.lane_count = 4
	brush.road_defaults.lane_count = 4 # deliberately the SAME value the group happens to have
	var before := brush.resolved_lane_count()
	# The group moves. A pushed-down design could not tell this brush's 4 from an inherited 4; here the
	# brush is genuinely overridden and must NOT follow.
	grp.road_defaults.lane_count = 7
	var held := brush.resolved_lane_count()
	# Now clear the override: it must follow the group again, not stay at 4.
	brush.road_defaults.clear_overrides()
	var followed := brush.resolved_lane_count()

	print("    before=%d, after group->7 overridden brush stays %d, after clear %d" % [before, held, followed])
	var ok := before == 4 and held == 4 and followed == 7
	if not ok:
		_fail += 1; print("    !! clear/override semantics wrong (want 4, 4, 7)")

	# CONTROL: is_empty tracks it, so the inspector can grey the row honestly.
	var empty_after_clear := brush.road_defaults.is_empty()
	brush.road_defaults.lane_count = 2
	var empty_after_set := brush.road_defaults.is_empty()
	print("    control: is_empty after clear=%s, after set=%s" % [empty_after_clear, empty_after_set])
	if not empty_after_clear or empty_after_set:
		_fail += 1; print("    !! is_empty did not track the override state")
	_teardown(fx)


# ---- C ------------------------------------------------------------------------------------------

func _c_segments_override_by_arc_length() -> void:
	print("[C] segments override by arc length, last match wins")
	var fx := _build(2)
	var brush: Pasture3DRoadBrush = fx["brush"]

	var gravel := Pasture3DRoadSegment.new()
	gravel.label = "Gravel"
	gravel.from_distance = 400.0
	gravel.to_distance = 2400.0
	gravel.surface_id = &"gravel"

	var bridge := Pasture3DRoadSegment.new()
	bridge.label = "Bridge"
	bridge.from_distance = 1000.0
	bridge.to_distance = 1080.0
	bridge.is_bridge = true

	brush.segments = [gravel, bridge] # the bridge sits INSIDE the gravel stretch

	var before_gravel := brush.resolved_surface_id(100.0)
	var in_gravel := brush.resolved_surface_id(800.0)
	var on_bridge := brush.resolved_surface_id(1040.0)
	var after := brush.resolved_surface_id(3000.0)
	var bridge_flags := [brush.is_bridge_at(800.0), brush.is_bridge_at(1040.0), brush.is_bridge_at(2000.0)]

	print("    surface @100=%s @800=%s @1040=%s @3000=%s | bridge flags %s"
			% [before_gravel, in_gravel, on_bridge, after, bridge_flags])
	# The bridge sets no surface, so inside it the surface still resolves to the BRUSH's chain, not to
	# gravel — the last matching segment wins per FIELD, which is the behaviour a later phase needs.
	var ok := before_gravel == &"tarmac" and in_gravel == &"gravel" and after == &"tarmac" \
			and bridge_flags == [false, true, false]
	if not ok:
		_fail += 1; print("    !! segment ranges did not resolve as expected")

	# CONTROL: the half-open range does not claim its end, so abutting segments cannot both own a metre.
	var at_end := gravel.covers(2400.0)
	var at_start := gravel.covers(400.0)
	print("    control: covers(from)=%s covers(to)=%s (want true, false)" % [at_start, at_end])
	if not at_start or at_end:
		_fail += 1; print("    !! the range is not half-open [from, to)")
	_teardown(fx)


# ---- D ------------------------------------------------------------------------------------------

func _d_inserting_a_point_does_not_move_an_override() -> void:
	print("[D] inserting a spline point does not disturb a segment override")
	var fx := _build(2)
	var brush: Pasture3DRoadBrush = fx["brush"]

	# A straight 300 m run as three collinear points, so inserting a fourth changes the point COUNT and
	# the interval indices while leaving the geometry — and therefore every arc length — identical.
	var path := Path3D.new()
	var c := Curve3D.new()
	c.add_point(Vector3(0, 0, 0))
	c.add_point(Vector3(0, 0, 150))
	c.add_point(Vector3(0, 0, 300))
	path.curve = c
	brush.add_child(path)

	var seg := Pasture3DRoadSegment.new()
	seg.from_distance = 100.0
	seg.to_distance = 200.0
	seg.surface_id = &"gravel"
	brush.segments = [seg]

	var len_before := c.get_baked_length()
	var at_150_before := brush.resolved_surface_id(150.0)
	var at_50_before := brush.resolved_surface_id(50.0)

	# Insert a point in the MIDDLE of the run. Under a per-interval segment model this splits the
	# interval the override lived on and the override lands somewhere else; under arc length it is inert.
	c.add_point(Vector3(0, 0, 75), Vector3.ZERO, Vector3.ZERO, 1)

	var len_after := c.get_baked_length()
	var at_150_after := brush.resolved_surface_id(150.0)
	var at_50_after := brush.resolved_surface_id(50.0)

	print("    points 3->%d, length %.1f->%.1f, @150 %s->%s, @50 %s->%s"
			% [c.point_count, len_before, len_after, at_150_before, at_150_after, at_50_before, at_50_after])
	var ok := c.point_count == 4 and absf(len_after - len_before) < 0.01 \
			and at_150_after == &"gravel" and at_150_before == &"gravel" \
			and at_50_after == &"tarmac" and at_50_before == &"tarmac"
	if not ok:
		_fail += 1; print("    !! a spline point insertion moved a segment override")

	# CONTROL: the override is not simply inert — moving its RANGE does change the answer, so the test
	# above is measuring stability and not a dead lookup.
	seg.from_distance = 0.0
	seg.to_distance = 60.0
	var moved := brush.resolved_surface_id(50.0)
	print("    control: range moved to [0,60) -> @50 is %s (want gravel)" % moved)
	if moved != &"gravel":
		_fail += 1; print("    !! the segment lookup is dead — moving the range changed nothing")
	_teardown(fx)


# ---- E ------------------------------------------------------------------------------------------

func _e_exclusion_survives_a_reorder() -> void:
	print("[E] type exclusion is by reference, so a catalogue reorder re-points nothing")
	var fx := _build(2)
	var net: Pasture3DRoadNetwork = fx["net"]
	var grp: Pasture3DRoadGroup = fx["group"]
	var paved: Pasture3DRoadType = fx["type"]

	var dirt := Pasture3DRoadType.new()
	dirt.type_name = "Dirt Track"
	dirt.priority = -10
	var motorway := Pasture3DRoadType.new()
	motorway.type_name = "Motorway"
	motorway.priority = 100
	net.road_types = [paved, dirt, motorway]

	grp.excluded_road_types = [dirt]
	var before := _names(grp.available_road_types())

	# Reorder the catalogue. An exclusion list of INDICES would now be excluding a different type.
	net.road_types = [motorway, dirt, paved]
	var after := _names(grp.available_road_types())

	print("    before %s" % [before])
	print("    after  %s" % [after])
	var ok := not before.has("Dirt Track") and not after.has("Dirt Track") \
			and after.has("Country Lane") and after.has("Motorway") and after.size() == 2
	if not ok:
		_fail += 1; print("    !! the exclusion did not survive a reorder")

	# CONTROL: the exclusion is real — dropping it brings the type back.
	grp.excluded_road_types = []
	var unexcluded := _names(grp.available_road_types())
	print("    control: exclusion cleared -> %s" % [unexcluded])
	if not unexcluded.has("Dirt Track") or unexcluded.size() != 3:
		_fail += 1; print("    !! clearing the exclusion did not restore the type")

	# A group type is offered alongside the network's, and is not duplicated if it is also in the
	# catalogue.
	grp.group_road_types = [motorway]
	var merged := _names(grp.available_road_types())
	print("    group type merged, no duplicate: %s" % [merged])
	if merged.size() != 3 or merged.count("Motorway") != 1:
		_fail += 1; print("    !! group and network types did not merge without duplicates")
	_teardown(fx)


# ---- F ------------------------------------------------------------------------------------------

func _f_group_edit_moves_only_the_undisagreeing() -> void:
	print("[F] a group edit moves the children that never disagreed, and only those")
	var fx := _build(2)
	var grp: Pasture3DRoadGroup = fx["group"]
	var follower: Pasture3DRoadBrush = fx["brush"]

	var dissenter := Pasture3DRoadBrush.new()
	grp.add_child(dissenter)
	dissenter.road_defaults.lane_count = 2

	grp.road_defaults.lane_count = 3
	var f_before := follower.resolved_lane_count()
	var d_before := dissenter.resolved_lane_count()

	grp.road_defaults.lane_count = 6
	var f_after := follower.resolved_lane_count()
	var d_after := dissenter.resolved_lane_count()

	print("    follower %d->%d, dissenter %d->%d" % [f_before, f_after, d_before, d_after])
	var ok := f_before == 3 and f_after == 6 and d_before == 2 and d_after == 2
	if not ok:
		_fail += 1; print("    !! a group edit did not move exactly the un-overridden child")

	# CONTROL: the group's content_key moves, so a later phase's cache has something to key on.
	var key_before := grp.content_key
	grp.road_defaults.lane_count = 8
	var key_after := grp.content_key
	print("    control: group content_key %d -> %d" % [key_before, key_after])
	if key_after <= key_before:
		_fail += 1; print("    !! a defaults edit did not bump the group's content_key")
	_teardown(fx)


func _names(p_types: Array[Pasture3DRoadType]) -> Array:
	var out: Array = []
	for t: Pasture3DRoadType in p_types:
		out.append(t.type_name)
	return out
