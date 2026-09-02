# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadMultiNetworkGate — Measures network-wide rebuilding behavior when editing one road.
#
@tool
extends Node


func _ready() -> void:
	print("\n================================================================================")
	print("=== RoadMultiNetworkGate: Multi-Road Network Rebuild Behavior ===")
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
	road_type.lane_width = 3.5
	road_type.surface_layer_id = 1
	var mat := StandardMaterial3D.new()
	road_type.surface_material = mat

	# Create 4 roads
	var roads: Array[Pasture3DRoadBrush] = []
	for r in 4:
		var b := Pasture3DRoadBrush.new()
		b.name = "Road%d" % r
		b.terrain = terr
		b.road_road_type = road_type
		net.add_child(b)

		var path := Path3D.new()
		path.name = "Path"
		var c := Curve3D.new()
		# Road 0: horizontal across (0, 0)
		# Road 1: vertical crossing Road 0 at (0, 0)
		# Road 2: parallel horizontal at z = 100 (far away)
		# Road 3: parallel horizontal at z = 200 (far away)
		var z_offset := 0.0 if r <= 1 else float(r - 1) * 100.0
		for i in 6:
			if r == 1:
				c.add_point(Vector3(0.0, 0.0, -150.0 + float(i) * 60.0))
			else:
				c.add_point(Vector3(-150.0 + float(i) * 60.0, 0.0, z_offset))
		path.curve = c
		b.add_child(path)

		var mod := Pasture3DNodeRoad.new()
		mod.alignment_step = 1.0
		b.modifiers = [mod]
		roads.append(b)

	# Initial bake of all 4 roads
	print("  [Setup] Baking 4 roads...")
	for b in roads:
		b._refresh_owner(b._layer_owner, false, [])
	net.resolve_junctions()
	print("  [Setup] Initial bake complete. Junctions detected: %d" % net.junctions.size())

	print("\n--- CASE A: Moving Road 2 (Independent, no junctions) ---")
	var r2_spline: Path3D = roads[2].get_node("Path")
	var pt_pos := r2_spline.curve.get_point_position(2)
	r2_spline.curve.set_point_position(2, pt_pos + Vector3(0.0, 0.0, 5.0))

	# Record digests before
	var digests_before: Array[String] = []
	for b in roads:
		digests_before.append(b.alignment_digest() + "|" + b.junction_digest())

	roads[2]._schedule_spline_refresh(r2_spline)
	# Force process deferred
	roads[2]._refresh_owner_rect(roads[2]._layer_owner, {r2_spline.get_instance_id(): true}, false)
	net.resolve_junctions()

	# Check digests after
	for r in 4:
		var d_after := roads[r].alignment_digest() + "|" + roads[r].junction_digest()
		var changed := d_after != digests_before[r]
		print("  Road %d digest changed: %s" % [r, str(changed)])

	print("\n--- CASE B: Moving Road 0 (Crosses Road 1 at (0, 0)) ---")
	var r0_spline: Path3D = roads[0].get_node("Path")
	var pt0_pos := r0_spline.curve.get_point_position(2)
	r0_spline.curve.set_point_position(2, pt0_pos + Vector3(0.0, 0.0, 5.0))

	var digests_before_b: Array[String] = []
	for b in roads:
		digests_before_b.append(b.alignment_digest() + "|" + b.junction_digest())

	roads[0]._refresh_owner_rect(roads[0]._layer_owner, {r0_spline.get_instance_id(): true}, false)
	net.resolve_junctions()

	for r in 4:
		var d_after := roads[r].alignment_digest() + "|" + roads[r].junction_digest()
		var changed := d_after != digests_before_b[r]
		print("  Road %d digest changed: %s" % [r, str(changed)])

	terr.queue_free()
	net.queue_free()
	get_tree().quit(0)
