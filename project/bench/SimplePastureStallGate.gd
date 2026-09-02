# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# SimplePastureStallGate — End-to-end timing on simple_pasture.tscn
#
@tool
extends Node


func _ready() -> void:
	print("\n================================================================================")
	print("=== SimplePastureStallGate: End-to-End Performance Verification ===")
	print("================================================================================\n")

	var scene: PackedScene = load("res://simple_pasture.tscn")
	var root := scene.instantiate()
	add_child(root)

	var terr: Pasture3D = root.get_node("Pasture3D")
	var net: Pasture3DRoadNetwork = root.get_node("Pasture3DRoadNetwork")
	var group: Node = net.get_node("Pasture3DRoadGroup")
	var road: Pasture3DRoadBrush = group.get_node("Road")
	var road2: Pasture3DRoadBrush = group.get_node("Road2")
	var road_path: Path3D = road.get_node("Road1")
	var curve: Curve3D = road_path.curve

	print("  [Setup] Initial bake / settle...")
	net.resolve_junctions()

	print("\n--- BENCHMARK: Moving Road Point 5 (Touching Plow) ---")
	var pt_idx := 5
	var old_local := curve.get_point_position(pt_idx)
	var new_local := old_local + Vector3(2.0, 0.0, 2.0)

	var t0 := Time.get_ticks_usec()
	curve.set_point_position(pt_idx, new_local)

	var moved := road._moved_point_indices(road_path)
	var dirty_box := road._spline_dirty_aabb(road_path, moved)
	var layer_id := road._layer_id
	var tile_world := road._layer_tile_world(layer_id)
	var clip_box := road._snap_aabb_to_tiles(dirty_box, tile_world)
	var blend := road._layer_blend_for(layer_id)

	var t_prep := (Time.get_ticks_usec() - t0) / 1000.0
	print("  1. Prep + Dirty Box: %.3f ms (Clip: %s)" % [t_prep, str(clip_box)])

	var t1 := Time.get_ticks_usec()
	road._refresh_owner_rect(road._layer_owner, {road_path.get_instance_id(): true}, false)
	var t_refresh := (Time.get_ticks_usec() - t1) / 1000.0
	print("  2. Road Layer _refresh_owner_rect (Road + Road2): %.3f ms" % t_refresh)

	var t2 := Time.get_ticks_usec()
	net.resolve_junctions()
	var t_resolve := (Time.get_ticks_usec() - t2) / 1000.0
	print("  3. Network resolve_junctions: %.3f ms" % t_resolve)

	var t_total := (Time.get_ticks_usec() - t0) / 1000.0
	print("\n  TOTAL END-TO-END POINT MOVE ON SIMPLE_PASTURE: %.3f ms" % t_total)

	print("\n=== COMPLETE ===\n")
	get_tree().quit(0)
