# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadRibbonPickingGate — Automated verification of road ribbon click selection
#
@tool
extends Node

var _fail: int = 0


func _check(p_id: String, p_ok: bool, p_detail: String) -> void:
	print("  [%s] %s - %s" % [p_id, "PASS" if p_ok else "FAIL", p_detail])
	if not p_ok:
		_fail += 1


func _ready() -> void:
	print("\n================================================================================")
	print("=== RoadRibbonPickingGate: Road Ribbon 3D Picking Verification ===")
	print("================================================================================\n")

	var terr := Pasture3D.new()
	terr.name = "Terrain"
	terr.region_size = 64
	terr.vertex_spacing = 1.0
	add_child(terr)

	# `terr.data` is read-only now - the terrain owns it - and regions are added rather than assigned as
	# a location list. This gate had not been runnable since those two engine-side changes landed.
	var data: Pasture3DData = terr.data
	for rz in range(-2, 3):
		for rx in range(-2, 3):
			data.add_region_blank(Vector2i(rx, rz))

	var net := Pasture3DRoadNetwork.new()
	net.name = "Network"
	# The network reads its terrain from its parent now; `terrain` is no longer assignable on it.
	terr.add_child(net)

	var road_type := Pasture3DRoadType.new()
	road_type.lane_width = 4.0
	road_type.shoulder_width = 1.0

	var road0 := Pasture3DRoadBrush.new()
	road0.name = "MainRoad"
	road0.terrain = terr
	road0.road_road_type = road_type
	net.add_child(road0)

	var p0 := Path3D.new()
	var c0 := Curve3D.new()
	# Straight road along X from -100 to +100 at z = 0
	c0.add_point(Vector3(-100.0, 0.0, 0.0))
	c0.add_point(Vector3(0.0, 0.0, 0.0))
	c0.add_point(Vector3(100.0, 0.0, 0.0))
	p0.curve = c0
	road0.add_child(p0)

	var road1 := Pasture3DRoadBrush.new()
	road1.name = "SideRoad"
	road1.terrain = terr
	road1.road_road_type = road_type
	net.add_child(road1)

	var p1 := Path3D.new()
	var c1 := Curve3D.new()
	# Straight road along Z from -100 to +100 at x = 50 (parallel / separate)
	c1.add_point(Vector3(50.0, 0.0, -100.0))
	c1.add_point(Vector3(50.0, 0.0, 0.0))
	c1.add_point(Vector3(50.0, 0.0, 100.0))
	p1.curve = c1
	road1.add_child(p1)

	# Setup a viewport and camera looking down at (0, 0, 0)
	var vp := SubViewport.new()
	vp.size = Vector2i(1024, 768)
	add_child(vp)

	# look_at needs the node in the tree, so it is parented FIRST. It was not, and the error it raised
	# left the camera facing down -Z with an unusable projection.
	var cam := Camera3D.new()
	vp.add_child(cam)
	cam.position = Vector3(0.0, 50.0, 50.0)
	cam.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)

	# Allow camera matrices to update
	cam.current = true

	print("  [Setup] Camera position: %s, looking at (0, 0, 0)" % str(cam.position))

	# Test 1: Screen position of point on Road 0 (at origin (0, 0, 0))
	var s0 := cam.unproject_position(Vector3(0.0, 0.0, 0.0))
	print("  Road 0 center (0, 0, 0) projects to screen: %s" % str(s0))
	var d0_on := road0.pick_road_screen_distance(cam, s0, 18.0)
	var d1_on := road1.pick_road_screen_distance(cam, s0, 18.0)
	print("  Clicking at Road 0 center: road0 dist = %.2f px, road1 dist = %.2f px" % [d0_on, d1_on])
	assert(d0_on <= 5.0, "Expected hit on Road 0")
	assert(is_inf(d1_on) or d1_on > 50.0, "Expected miss on Road 1")

	# Test 2: Screen position of point on Road 1 (at (50, 0, 0))
	var s1 := cam.unproject_position(Vector3(50.0, 0.0, 0.0))
	print("\n  Road 1 center (50, 0, 0) projects to screen: %s" % str(s1))
	var d0_on_1 := road0.pick_road_screen_distance(cam, s1, 18.0)
	var d1_on_1 := road1.pick_road_screen_distance(cam, s1, 18.0)
	print("  Clicking at Road 1 center: road0 dist = %.2f px, road1 dist = %.2f px" % [d0_on_1, d1_on_1])
	assert(d1_on_1 <= 5.0, "Expected hit on Road 1")

	# Test 3: Screen position far away from both roads (e.g. at (-50, 0, 50))
	var s_empty := cam.unproject_position(Vector3(-50.0, 0.0, 50.0))
	print("\n  Empty ground (-50, 0, 50) projects to screen: %s" % str(s_empty))
	var d0_empty := road0.pick_road_screen_distance(cam, s_empty, 18.0)
	var d1_empty := road1.pick_road_screen_distance(cam, s_empty, 18.0)
	print("  Clicking at empty ground: road0 dist = %.2f px, road1 dist = %.2f px" % [d0_empty, d1_empty])
	assert(is_inf(d0_empty) and is_inf(d1_empty), "Expected miss on both roads")

	_w_a_road_straddling_the_camera_does_not_swallow_clicks(road0)
	if _fail > 0:
		print("\n=== ROAD RIBBON PICKING FAIL (%d criterion/control failure(s)) ===\n" % _fail)
		get_tree().quit(1)
		return

	print("\n=== ROAD RIBBON PICKING PASS (All assertions passed!) ===\n")

	vp.queue_free()
	terr.queue_free()
	net.queue_free()
	get_tree().quit(0)


# ---- [W] -----------------------------------------------------------------------------------------
#
# PASTURE3D_ROAD_PERF_REGRESSION_SPEC.md R8. Added 2026-09-02.
#
# The screen-space segment loop skipped a segment only when BOTH endpoints were behind the camera.
# `unproject_position` returns a mirrored, meaningless coordinate for a point behind the near plane, so a
# segment STRADDLING the camera plane - which is every segment under your feet when you stand on the road,
# the commonest editing position there is - was measured against a screen segment that does not exist.
# Clicks well off the road selected it.
#
# The three tests above cannot see this: their camera is 50 m up and 50 m back, so nothing straddles.


## Where a screen ray meets the y = 0 plane, or a far sentinel when it never does.
##
## An analytic plane rather than `terrain.get_intersection`: this gate's terrain carries no height data,
## and a ground oracle that owes nothing to the code under test is what the criterion needs anyway.
func _ground_hit(p_cam: Camera3D, p_screen: Vector2) -> Vector3:
	var o := p_cam.project_ray_origin(p_screen)
	var d := p_cam.project_ray_normal(p_screen)
	if absf(d.y) < 1e-6:
		return Vector3(1e9, 0.0, 1e9)
	var t := -o.y / d.y
	if t <= 0.0:
		return Vector3(1e9, 0.0, 1e9)
	return o + d * t


## The pre-fix screen-space loop, verbatim apart from the `and` and the old margin constant. This is the
## control: the criterion is worth nothing unless the old code actually behaved differently here, and
## asserting that in prose instead of measuring it is the habit these gates exist to break.
func _pick_with_and(p_road: Pasture3DRoadBrush, p_cam: Camera3D, p_screen: Vector2,
		p_margin: float) -> float:
	var best_d := INF
	var half_w := p_road.corridor_half_width()
	for path in p_road._get_splines():
		if path == null or path.curve == null:
			continue
		var pts: PackedVector3Array = path.curve.get_baked_points()
		if pts.size() < 2:
			continue
		var xf: Transform3D = path.global_transform
		for i in range(pts.size() - 1):
			var w1: Vector3 = xf * pts[i]
			var w2: Vector3 = xf * pts[i + 1]
			if p_cam.is_position_behind(w1) and p_cam.is_position_behind(w2):
				continue
			var s1 := p_cam.unproject_position(w1)
			var s2 := p_cam.unproject_position(w2)
			var pt := Geometry2D.get_closest_point_to_segment(p_screen, s1, s2)
			var d := p_screen.distance_to(pt)
			var mid := (w1 + w2) * 0.5
			var cam_dist := p_cam.global_position.distance_to(mid)
			var effective_margin := maxf(p_margin, half_w * (500.0 / maxf(cam_dist, 1.0)))
			if d <= effective_margin and d < best_d:
				best_d = d
	return best_d


func _w_a_road_straddling_the_camera_does_not_swallow_clicks(p_road: Pasture3DRoadBrush) -> void:
	print("\n  [W] a road running through the camera does not swallow clicks beside it")

	# ON the road, at eye height, looking along it: segments now lie both ahead of the camera and behind
	# it, and the ones under it straddle the camera plane.
	var vp := SubViewport.new()
	vp.size = Vector2i(1024, 768)
	add_child(vp)
	var cam := Camera3D.new()
	vp.add_child(cam)
	# A wide FOV so ground far to either side of the road is on screen at all - and because the margin
	# scale under test is now derived from the FOV rather than from a constant.
	cam.fov = 100.0
	cam.position = Vector3(0.0, 25.0, 0.0)
	cam.look_at(Vector3(60.0, 0.0, 0.0), Vector3.UP)
	cam.current = true

	var half_w := p_road.corridor_half_width()
	print("    camera at %s looking down the road; corridor half-width %.2f m"
			% [str(cam.position), half_w])

	# The offsets start at five corridor half-widths, which is further out than the bug strictly needs.
	# That is deliberate: the corridor margin nearer in is legitimately generous - it is a margin in
	# METRES converted to pixels, so a click a few tens of metres off a 30 m corridor is a hit by design -
	# and a criterion that called those hits failures would be testing the margin, not the projection.
	#
	# The sample set is built from WORLD points that are plainly off the road - well outside the
	# corridor, and near enough to the camera that world distance and screen distance still correspond -
	# and then projected. Sampling the screen instead and asking where the ray lands puts most of the
	# samples near the horizon, where a point 50 m off the road is genuinely a pixel from its screen
	# line; a hit there is correct picking, not the bug under test.
	var off_road: Array[Vector2] = []
	for xi in range(1, 16):
		for zi in range(0, 14):
			for sign: float in [-1.0, 1.0]:
				var wx := 20.0 + float(xi) * 9.0
				var wz := sign * (half_w * 5.0 + float(zi) * 30.0)
				var wp := Vector3(wx, 0.0, wz)
				if cam.is_position_behind(wp):
					continue
				var sp := cam.unproject_position(wp)
				if sp.x < 0.0 or sp.y < 0.0 or sp.x > 1024.0 or sp.y > 768.0:
					continue
				off_road.append(sp)
	print("    %d on-screen sample(s), every one at least %.1f m off the centreline and within 150 m"
			% [off_road.size(), half_w * 5.0])
	if off_road.size() < 10:
		_fail += 1
		print("    !! too few off-road samples, so [W] would be measuring nothing")

	var fixed_hits := 0
	var old_hits := 0
	for sp in off_road:
		if not is_inf(p_road.pick_road_screen_distance(cam, sp, 18.0)):
			fixed_hits += 1
		if not is_inf(_pick_with_and(p_road, cam, sp, 18.0)):
			old_hits += 1
	_check("W", fixed_hits == 0,
			"%d of %d clicks well off the road are reported as hits (want 0)"
					% [fixed_hits, off_road.size()])

	# CONTROL: the pre-fix loop must fail here, or the fixture never reproduced the bug.
	print("    control: the same clicks through the pre-fix `and` hit %d of %d time(s) (want > 0)"
			% [old_hits, off_road.size()])
	if old_hits == 0:
		_fail += 1
		print("    !! the pre-fix loop agrees, so this fixture does not exercise a straddling segment")

	# The other half of the same statement: the road ahead is still pickable. A loop that skipped
	# everything would pass the criterion above and break selection outright.
	var on := cam.unproject_position(Vector3(60.0, 0.0, 0.0))
	var d_on := p_road.pick_road_screen_distance(cam, on, 18.0)
	print("    control: a click on the road 60 m ahead reports %.2f px (want finite)" % d_on)
	if is_inf(d_on):
		_fail += 1
		print("    !! the fix made the road ahead unpickable")

	vp.queue_free()
