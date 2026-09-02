# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# SimplePastureStallGate — Timing inside _refresh_owner_rect
#
@tool
extends Node


func _ready() -> void:
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

	var pt_idx := 5
	var old_local := curve.get_point_position(pt_idx)
	var new_local := old_local + Vector3(2.0, 0.0, 2.0)
	curve.set_point_position(pt_idx, new_local)

	var moved := road._moved_point_indices(road_path)
	var dirty_box := road._spline_dirty_aabb(road_path, moved)
	var layer_id := road._layer_id
	var tile_world := road._layer_tile_world(layer_id)
	var clip_box := road._snap_aabb_to_tiles(dirty_box, tile_world)
	var blend := road._layer_blend_for(layer_id)

	print("\n--- TIMING INSIDE _refresh_owner_rect ---")
	var t0 := Time.get_ticks_usec()
	terr.data.clear_layer_in_area(layer_id, clip_box)
	print("  1. clear_layer_in_area: %.3f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))

	var t1 := Time.get_ticks_usec()
	road._clip_aabb = clip_box
	road._defer_composite = true
	road._paint_into(layer_id, blend)
	road._defer_composite = false
	road._clip_aabb = AABB()
	print("  2. Road._paint_into: %.3f ms" % ((Time.get_ticks_usec() - t1) / 1000.0))

	var t2 := Time.get_ticks_usec()
	var road2_in := road2._overlaps_box(clip_box)
	print("  3. Road2 overlaps clip: %s" % str(road2_in))
	if road2_in:
		road2._clip_aabb = clip_box
		road2._defer_composite = true
		road2._paint_into(layer_id, blend)
		road2._defer_composite = false
		road2._clip_aabb = AABB()
	print("  3. Road2._paint_into: %.3f ms" % ((Time.get_ticks_usec() - t2) / 1000.0))

	var t3 := Time.get_ticks_usec()
	terr.data.composite_area(clip_box, false)
	print("  4. composite_area: %.3f ms" % ((Time.get_ticks_usec() - t3) / 1000.0))

	var t4 := Time.get_ticks_usec()
	terr.data.update_maps(Pasture3DData.TYPE_HEIGHT, false, false)
	print("  5. update_maps: %.3f ms" % ((Time.get_ticks_usec() - t4) / 1000.0))

	get_tree().quit(0)
