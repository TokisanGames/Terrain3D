# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadMoundInteractionGate — Measures interaction between Roads & Mounds,
# and profiles adding/removing spline points.
#
@tool
extends Node

const REGION_SIZE: int = 64
const VERTEX_SPACING: float = 1.0

var _mound_paint_count: int = 0
var _mound_refresh_count: int = 0


func _ready() -> void:
	print("\n================================================================================")
	print("=== RoadMoundInteractionGate: Road/Mound Interaction & Add/Remove Point Timing ===")
	print("================================================================================\n")

	_run_investigation()

	print("\n=== INVESTIGATION COMPLETE ===\n")
	get_tree().quit(0)


func _run_investigation() -> void:
	# 1. Setup Terrain with 16 regions (4x4)
	var terrain := Pasture3D.new()
	terrain.name = "Terrain"
	terrain.region_size = REGION_SIZE
	terrain.vertex_spacing = VERTEX_SPACING
	add_child(terrain)

	# `terrain.data` is read-only - the terrain owns it - and regions are ADDED rather than assigned
	# as a location list. Both engine-side changes landed after this gate was written.
	var data: Pasture3DData = terrain.data
	for rz in range(-2, 3):
		for rx in range(-2, 3):
			data.add_region_blank(Vector2i(rx, rz))

	# 2. Setup Mound Brush
	var mound := Pasture3DMound.new()
	mound.name = "Mound"
	mound.terrain = terrain
	mound.log_bake_timing = false
	add_child(mound)

	var mound_path := Path3D.new()
	mound_path.name = "Loop1"
	var mound_curve := Curve3D.new()
	# Circle of 8 points around (0, 0) radius 40m
	for i in 8:
		var rad := float(i) * TAU / 8.0
		mound_curve.add_point(Vector3(cos(rad) * 40.0, 0.0, sin(rad) * 40.0))
	mound_path.curve = mound_curve
	mound.add_child(mound_path)

	# 3. Setup Road Network & Road Brush crossing through (0, 0)
	var net := Pasture3DRoadNetwork.new()
	net.name = "RoadNetwork"
	# A road network finds its terrain by PARENTAGE - it has no `terrain` property. Assigning one was
	# silently accepted until the engine started rejecting unknown properties, and it stops the gate dead.
	terrain.add_child(net)

	var road_type := Pasture3DRoadType.new()
	road_type.lane_width = 3.5
	road_type.shoulder_width = 1.0
	road_type.crown = 0.05
	road_type.surface_layer_id = 1
	var mat := StandardMaterial3D.new()
	road_type.surface_material = mat

	var road := Pasture3DRoadBrush.new()
	road.name = "MainRoad"
	road.terrain = terrain
	road.road_road_type = road_type
	road.log_bake_timing = false
	net.add_child(road)

	var road_path := Path3D.new()
	road_path.name = "Spline"
	var road_curve := Curve3D.new()
	# 1.2 km road crossing directly over the mound at (0,0)
	for i in 12:
		var x := -600.0 + float(i) * 100.0
		var z := sin(float(i) * 0.8) * 30.0 # crosses near 0
		road_curve.add_point(Vector3(x, 0.0, z))
	road_path.curve = road_curve
	road.add_child(road_path)

	var mod := Pasture3DNodeRoad.new()
	mod.alignment_step = 1.0
	mod.publish_masks = true
	road.modifiers = [mod]

	# Initial bake of mound and road
	print("  [Setup] Initial bake of Mound and Road...")
	mound._refresh_owner(mound._layer_owner, false, [])
	road._refresh_owner(road._layer_owner, false, [])
	net.resolve_junctions()
	print("  [Setup] Initial bake complete.")

	# Check layers created
	var mound_layer: int = data.find_layer_by_owner(mound._layer_owner)
	var road_layer: int = data.find_layer_by_owner(road._layer_owner)
	print("  [Layers] Mound Layer ID: %d ('%s'), Road Layer ID: %d ('%s')" % [
		mound_layer, mound._layer_owner, road_layer, road._layer_owner
	])

	# --------------------------------------------------------------------------------
	# TEST 1: Moving a Road point that intersects the Mound
	# --------------------------------------------------------------------------------
	print("\n--- TEST 1: Moving Road Point near Mound ---")
	# Hook mound paint
	var orig_mound_paint: Callable = mound._paint_into
	var mound_painted := [false]
	# Move road point #6 (at x = 0, directly on the mound)
	var target_pt := 6
	var old_pos := road_curve.get_point_position(target_pt)
	var new_pos := old_pos + Vector3(5.0, 0.0, 5.0)

	var t0 := Time.get_ticks_usec()
	road_curve.set_point_position(target_pt, new_pos)
	var moved := road._moved_point_indices(road_path)
	var dirty_box := road._spline_dirty_aabb(road_path, moved)
	var tile_world := road._layer_tile_world(road._layer_id)
	var clip_box := road._snap_aabb_to_tiles(dirty_box, tile_world)

	print("  Road clip box: %s" % str(clip_box))
	print("  Does clip box overlap Mound footprint? %s" % str(mound._spline_footprint_aabb(mound_path).intersects(clip_box)))

	# Check what tools are on road owner vs mound owner
	var road_tools := road._tools_on_owner(road._layer_owner)
	var mound_tools := mound._tools_on_owner(mound._layer_owner)
	print("  Tools on Road owner '%s': %s" % [road._layer_owner, str(road_tools)])
	print("  Tools on Mound owner '%s': %s" % [mound._layer_owner, str(mound_tools)])

	# Clear and paint road
	data.clear_layer_in_area(road._layer_id, clip_box)
	road._clip_aabb = clip_box
	road._defer_composite = true
	road._paint_into(road._layer_id, 0)
	road._defer_composite = false
	road._clip_aabb = AABB()
	data.composite_area(clip_box, false)
	data.update_maps(Pasture3DRegion.TYPE_HEIGHT, false, false)
	net.resolve_junctions()
	var t_move := (Time.get_ticks_usec() - t0) / 1000.0
	print("  Road point move took: %.3f ms" % t_move)

	# --------------------------------------------------------------------------------
	# TEST 2: Adding a spline point to the Road
	# --------------------------------------------------------------------------------
	print("\n--- TEST 2: Adding a Spline Point to the Road ---")
	var t0_add := Time.get_ticks_usec()
	# Insert point between 5 and 6 at x = -50m
	var insert_pos := Vector3(-50.0, 0.0, 10.0)
	road_curve.add_point(insert_pos, Vector3.ZERO, Vector3.ZERO, 6)

	var add_moved := road._moved_point_indices(road_path)
	print("  _moved_point_indices returned %d indices (out of %d total points)" % [add_moved.size(), road_curve.point_count])
	var add_dirty := road._spline_dirty_aabb(road_path, add_moved)
	print("  add_dirty box size: %s" % str(add_dirty.size))
	var add_clip := road._snap_aabb_to_tiles(add_dirty, tile_world)
	print("  add_clip box size: %s" % str(add_clip.size))

	data.clear_layer_in_area(road._layer_id, add_clip)
	road._clip_aabb = add_clip
	road._defer_composite = true
	road._paint_into(road._layer_id, 0)
	road._defer_composite = false
	road._clip_aabb = AABB()
	data.composite_area(add_clip, false)
	data.update_maps(Pasture3DRegion.TYPE_HEIGHT, false, false)
	net.resolve_junctions()
	var t_add := (Time.get_ticks_usec() - t0_add) / 1000.0
	print("  Adding spline point took: %.3f ms" % t_add)

	# --------------------------------------------------------------------------------
	# TEST 3: Removing a spline point from the Road
	# --------------------------------------------------------------------------------
	print("\n--- TEST 3: Removing a Spline Point from the Road ---")
	var t0_rem := Time.get_ticks_usec()
	road_curve.remove_point(6)

	var rem_moved := road._moved_point_indices(road_path)
	print("  _moved_point_indices returned %d indices (out of %d total points)" % [rem_moved.size(), road_curve.point_count])
	var rem_dirty := road._spline_dirty_aabb(road_path, rem_moved)
	print("  rem_dirty box size: %s" % str(rem_dirty.size))
	var rem_clip := road._snap_aabb_to_tiles(rem_dirty, tile_world)
	print("  rem_clip box size: %s" % str(rem_clip.size))

	data.clear_layer_in_area(road._layer_id, rem_clip)
	road._clip_aabb = rem_clip
	road._defer_composite = true
	road._paint_into(road._layer_id, 0)
	road._defer_composite = false
	road._clip_aabb = AABB()
	data.composite_area(rem_clip, false)
	data.update_maps(Pasture3DRegion.TYPE_HEIGHT, false, false)
	net.resolve_junctions()
	var t_rem := (Time.get_ticks_usec() - t0_rem) / 1000.0
	print("  Removing spline point took: %.3f ms" % t_rem)

	terrain.queue_free()
	mound.queue_free()
	net.queue_free()
