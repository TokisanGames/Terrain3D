# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadStressGate — End-to-End microsecond-level profiling for long roads (1 km to 3 km)
# and scaling across region counts (16, 64, 256 regions).
#
@tool
extends Node

const REGION_SIZE: int = 64
const VERTEX_SPACING: float = 1.0


func _ready() -> void:
	print("\n================================================================================")
	print("=== RoadStressGate: End-to-End Profiling on Long Roads & Region Scaling ===")
	print("================================================================================\n")

	_run_stress_test("1.2 km S-Curve on 64 Regions (8x8)", 1200.0, 12, 8)
	_run_stress_test("3.0 km Mountain Pass on 64 Regions (8x8)", 3000.0, 25, 8)
	_run_stress_test("3.0 km Mountain Pass on 256 Regions (16x16)", 3000.0, 25, 16)

	print("\n=== ROAD STRESS PROFILING COMPLETE ===\n")
	get_tree().quit(0)


func _run_stress_test(p_title: String, p_length: float, p_points: int, p_regions_per_axis: int) -> void:
	print("--------------------------------------------------------------------------------")
	print("RUNNING: %s (%d total regions)" % [p_title, p_regions_per_axis * p_regions_per_axis])
	print("--------------------------------------------------------------------------------")

	# Setup terrain
	var terrain := Pasture3D.new()
	terrain.name = "Terrain"
	terrain.region_size = REGION_SIZE
	terrain.vertex_spacing = VERTEX_SPACING
	add_child(terrain)

	# `terrain.data` is read-only - the terrain owns it - and regions are ADDED rather than assigned
	# as a location list. Both engine-side changes landed after this gate was written.
	var data: Pasture3DData = terrain.data
	for rz in range(-2, p_regions_per_axis - 2):
		for rx in range(-2, p_regions_per_axis - 2):
			data.add_region_blank(Vector2i(rx, rz))

	# Create network
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

	# Create the main long road brush
	var brush := Pasture3DRoadBrush.new()
	brush.name = "MainRoad"
	brush.terrain = terrain
	brush.road_road_type = road_type
	brush.log_bake_timing = false
	net.add_child(brush)

	var path := Path3D.new()
	path.name = "Spline"
	var curve := Curve3D.new()

	# Build S / Z shape curve with p_points
	var dx := p_length / float(p_points - 1)
	for i in p_points:
		var x := float(i) * dx
		var z := sin(float(i) * 0.8) * 120.0 + (50.0 if (i % 4 < 2) else -50.0)
		curve.add_point(Vector3(x, 0.0, z))
	path.curve = curve
	brush.add_child(path)

	var mod := Pasture3DNodeRoad.new()
	mod.alignment_step = 1.0
	mod.publish_masks = true
	brush.modifiers = [mod]

	# Add 2 sibling roads to simulate a realistic network
	for s_idx in 2:
		var sib := Pasture3DRoadBrush.new()
		sib.name = "SiblingRoad%d" % s_idx
		sib.terrain = terrain
		sib.road_road_type = road_type
		net.add_child(sib)
		var sib_path := Path3D.new()
		sib_path.name = "Spline"
		var sib_curve := Curve3D.new()
		sib_curve.add_point(Vector3(200.0 * float(s_idx + 1), 0.0, -200.0))
		sib_curve.add_point(Vector3(200.0 * float(s_idx + 1), 0.0, 200.0))
		sib_path.curve = sib_curve
		sib.add_child(sib_path)
		var sib_mod := Pasture3DNodeRoad.new()
		sib_mod.alignment_step = 1.0
		sib_mod.publish_masks = true
		sib.modifiers = [sib_mod]

	# Initial full bake to settle everything into cache
	print("  [Setup] Initializing %d regions & baking network..." % data.get_region_count())
	var t0_init := Time.get_ticks_usec()
	brush._refresh_owner(brush._layer_owner, false, [])
	net.resolve_junctions()
	var t_init_total := (Time.get_ticks_usec() - t0_init) / 1000.0
	print("  [Setup] Initial bake complete (took %.2f ms)" % t_init_total)

	# --------------------------------------------------------------------------------
	# BENCHMARK: Move a single control point (e.g. middle point)
	# --------------------------------------------------------------------------------
	var target_pt := maxi(p_points / 2, 1)
	var old_pos := curve.get_point_position(target_pt)
	var new_pos := old_pos + Vector3(5.0, 0.0, 5.0)

	print("  [Benchmark] Simulating single point move on point #%d (offset +5m)..." % target_pt)

	var t_start := Time.get_ticks_usec()

	# 1. Curve mutation
	curve.set_point_position(target_pt, new_pos)
	var t_curve := Time.get_ticks_usec()

	# 2. Dirty-rect computation
	var moved := brush._moved_point_indices(path)
	var dirty_box := brush._spline_dirty_aabb(path, moved)
	var t_dirty := Time.get_ticks_usec()

	# 3. Tile Snapping
	var tile_world := brush._layer_tile_world(brush._layer_id)
	var clip_box := brush._snap_aabb_to_tiles(dirty_box, tile_world)
	var t_snap := Time.get_ticks_usec()

	# 4. Clear layer tiles inside dirty box
	terrain.data.clear_layer_in_area(brush._layer_id, clip_box)
	var t_clear := Time.get_ticks_usec()

	# 5. Paint footprint (alignment solver + native stamp_road_line)
	brush._clip_aabb = clip_box
	brush._defer_composite = true
	brush._paint_into(brush._layer_id, 0)
	brush._defer_composite = false
	brush._clip_aabb = AABB()
	var t_paint := Time.get_ticks_usec()

	# 6. Composite area
	terrain.data.composite_area(clip_box, false)
	var t_comp := Time.get_ticks_usec()

	# 7. Update GPU maps
	terrain.data.update_maps(Pasture3DRegion.TYPE_HEIGHT, false, false)
	var t_gpu := Time.get_ticks_usec()

	# 8. Network resolve
	var t_net_start := Time.get_ticks_usec()

	# 8a: Junctions
	var runs: Array = []
	for b in net.road_brushes():
		var r := b.build_run()
		if not r.is_empty():
			runs.append(r)
	net.junctions = net._typed(Pasture3DRoadJunctionSolver.resolve(runs, net.junctions))
	var t_junctions := Time.get_ticks_usec()

	# 8b: Lane graphs
	net._resolve_lane_graphs(net.road_brushes())
	var t_lanes := Time.get_ticks_usec()

	# 8c: Paint roads detailed profiling
	var t_paint_roads_start := Time.get_ticks_usec()
	var ordered := net.paint_order(net.road_brushes())
	var t_order := Time.get_ticks_usec()
	net._clear_paint_layers(ordered)
	var t_clear_paint := Time.get_ticks_usec()
	var painted_cells := 0
	for b in ordered:
		painted_cells += b.paint_surface()
	var t_paint_cells := Time.get_ticks_usec()
	if painted_cells > 0:
		terrain.data.composite_regions()
	var t_comp_regions := Time.get_ticks_usec()

	# 8d: Build chunks
	var total_chunks := net.build_chunks(net.road_brushes())
	var t_chunks := Time.get_ticks_usec()

	# 8e: Build runtime
	net.build_runtime(net.road_brushes())
	var t_runtime := Time.get_ticks_usec()

	var t_end := Time.get_ticks_usec()

	# Print detailed breakdown
	print("\n  ================ TIMING BREAKDOWN (POINT MOVE) ================")
	print("  1. Curve Mutation:               %7.3f ms" % ((t_curve - t_start) / 1000.0))
	print("  2. Dirty AABB Calculation:       %7.3f ms  (Box: %s)" % [((t_dirty - t_curve) / 1000.0), str(dirty_box.size)])
	print("  3. Tile Snapping:                %7.3f ms  (Clip: %s)" % [((t_snap - t_dirty) / 1000.0), str(clip_box.size)])
	print("  4. Layer Tile Clear & Composite: %7.3f ms" % ((t_clear - t_snap) / 1000.0))
	print("  5. Alignment & Road Rasterize:   %7.3f ms" % ((t_paint - t_clear) / 1000.0))
	print("  6. Area Height Composite:        %7.3f ms" % ((t_comp - t_paint) / 1000.0))
	print("  7. GPU Texture Map Upload:       %7.3f ms" % ((t_gpu - t_comp) / 1000.0))
	print("  8. Road Network Resolve:")
	print("     - Junction Detection:         %7.3f ms" % ((t_junctions - t_net_start) / 1000.0))
	print("     - Lane Graphs:                %7.3f ms" % ((t_lanes - t_junctions) / 1000.0))
	print("     - Control Paint (paint_roads):%7.3f ms TOTAL" % ((t_comp_regions - t_paint_roads_start) / 1000.0))
	print("         * Clear paint layers:     %7.3f ms" % ((t_clear_paint - t_order) / 1000.0))
	print("         * C++ Paint cells:        %7.3f ms  (%d cells)" % [((t_paint_cells - t_clear_paint) / 1000.0), painted_cells])
	print("         * composite_regions:      %7.3f ms  (%d regions)" % [((t_comp_regions - t_paint_cells) / 1000.0), data.get_region_count()])
	print("     - Ribbon Meshing (chunks):    %7.3f ms  (%d chunks across %d LODs)" % [((t_chunks - t_comp_regions) / 1000.0), total_chunks, Pasture3DRoadMesher.LOD_LEVELS])
	print("     - Runtime Serialization:      %7.3f ms" % ((t_runtime - t_chunks) / 1000.0))
	print("  ---------------------------------------------------------------")
	print("  TOTAL END-TO-END POINT MOVE:     %7.3f ms" % ((t_end - t_start) / 1000.0))
	print("  ===============================================================\n")

	# Clean up nodes
	terrain.queue_free()
	net.queue_free()
