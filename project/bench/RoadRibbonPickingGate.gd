# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadRibbonPickingGate — Automated verification of road ribbon click selection
#
@tool
extends Node


func _ready() -> void:
	print("\n================================================================================")
	print("=== RoadRibbonPickingGate: Road Ribbon 3D Picking Verification ===")
	print("================================================================================\n")

	var terr := Pasture3D.new()
	terr.name = "Terrain"
	terr.region_size = 64
	terr.vertex_spacing = 1.0
	add_child(terr)

	var data := Pasture3DData.new()
	terr.data = data
	for rz in range(-2, 3):
		for rx in range(-2, 3):
			data.set_region_locations(data.get_region_locations() + [Vector2i(rx, rz)])

	var net := Pasture3DRoadNetwork.new()
	net.name = "Network"
	net.terrain = terr
	add_child(net)

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

	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 50.0, 50.0)
	cam.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)
	vp.add_child(cam)

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
	assert(is_infinite(d1_on) or d1_on > 50.0, "Expected miss on Road 1")

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
	assert(is_infinite(d0_empty) and is_infinite(d1_empty), "Expected miss on both roads")

	print("\n=== ROAD RIBBON PICKING PASS (All assertions passed!) ===\n")

	vp.queue_free()
	terr.queue_free()
	net.queue_free()
	get_tree().quit(0)
