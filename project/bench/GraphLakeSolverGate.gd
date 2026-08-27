# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphLakeSolverGate — parity and behavior verification for Pasture3DGraphNodeLakeFlooding.
#
# Tests:
#   [A] Multi-output channel generation: height, water_depth, and shoreline.
#   [B] Water depth exactness: depth == max(0, water_elevation - bed_height).
#   [C] Shoreline feathering mask along water boundary.
#   [D] Frozen cache and Bake behavior.
#   [E] Node metadata & port types.
extends Node

const GW := 32
const GH := 32
const RECT := Rect2(-50.0, -50.0, 100.0, 100.0)
const EPS := 1.0e-4

var _fail := 0


func _ready() -> void:
	print("=== GraphLakeSolverGate: hydrological lake flooding solver ===\n")
	_a_multi_output_channels()
	_b_water_depth_exactness()
	_c_shoreline_mask()
	_d_frozen_cache()
	_e_metadata_and_ports()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH LAKE SOLVER PASS" if _fail == 0 else "GRAPH LAKE SOLVER FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _a_multi_output_channels() -> void:
	print("[A] Multi-output channel generation")
	var bed := _make_bowl_grid(GW, GH, 0.0, 20.0) # 0m in center, 20m on rim
	var lake := Pasture3DGraphNodeLakeFlooding.new()
	lake.flood_mode = Pasture3DGraphNodeLakeFlooding.FloodMode.GLOBAL_ELEVATION
	lake.water_elevation = 10.0
	lake.shoreline_width = 4.0

	var channels := lake.eval_grid_channels([bed], GW, GH, null, RECT)

	if channels.size() != 3:
		_fail += 1; print("    !! expected 3 output channels, got %d" % channels.size())
		return

	var h_grid: PackedFloat32Array = channels[0]
	var depth_grid: PackedFloat32Array = channels[1]
	var shore_grid: PackedFloat32Array = channels[2]

	print("    center height: %.2f m (want 10.0m water plane)" % h_grid[16 * GW + 16])
	if absf(h_grid[16 * GW + 16] - 10.0) > EPS:
		_fail += 1; print("    !! lake surface was not at water elevation")

	print("    center depth: %.2f m (want 10.0m water depth)" % depth_grid[16 * GW + 16])
	if absf(depth_grid[16 * GW + 16] - 10.0) > EPS:
		_fail += 1; print("    !! water depth mismatch")

	print("    rim depth: %.2f m (want 0.0m dry rim)" % depth_grid[0])
	if depth_grid[0] > EPS:
		_fail += 1; print("    !! dry land received non-zero water depth")


func _b_water_depth_exactness() -> void:
	print("[B] Water depth exactness across grid")
	var bed := _make_bowl_grid(GW, GH, 0.0, 20.0)
	var lake := Pasture3DGraphNodeLakeFlooding.new()
	lake.flood_mode = Pasture3DGraphNodeLakeFlooding.FloodMode.GLOBAL_ELEVATION
	lake.water_elevation = 8.0

	var channels := lake.eval_grid_channels([bed], GW, GH, null, RECT)
	var depth: PackedFloat32Array = channels[1]

	var max_err := 0.0
	for i in range(GW * GH):
		var expected := maxf(8.0 - bed[i], 0.0)
		max_err = maxf(max_err, absf(depth[i] - expected))

	print("    max depth error = %.7f (want < %.7f)" % [max_err, EPS])
	if max_err > EPS:
		_fail += 1; print("    !! water depth deviated from analytical equation")


func _c_shoreline_mask() -> void:
	print("[C] Shoreline mask transition")
	var bed := _make_bowl_grid(GW, GH, 0.0, 20.0)
	var lake := Pasture3DGraphNodeLakeFlooding.new()
	lake.flood_mode = Pasture3DGraphNodeLakeFlooding.FloodMode.GLOBAL_ELEVATION
	lake.water_elevation = 10.0
	lake.shoreline_width = 5.0

	var channels := lake.eval_grid_channels([bed], GW, GH, null, RECT)
	var shore: PackedFloat32Array = channels[2]

	var center_val := shore[16 * GW + 16]
	var dry_val := shore[0]

	print("    deep lake shore value = %.2f (want 1.0), dry land = %.2f (want 0.0)" % [center_val, dry_val])
	if absf(center_val - 1.0) > EPS or dry_val > EPS:
		_fail += 1; print("    !! shoreline mask bounds incorrect")


func _d_frozen_cache() -> void:
	print("[D] Frozen cache and Bake operation")
	var bed := _make_bowl_grid(GW, GH, 0.0, 20.0)
	var lake := Pasture3DGraphNodeLakeFlooding.new()
	lake.flood_mode = Pasture3DGraphNodeLakeFlooding.FloodMode.GLOBAL_ELEVATION
	lake.evaluation = Pasture3DGraphNodeLakeFlooding.Evaluation.FROZEN
	lake.water_elevation = 10.0

	var ch1 := lake.eval_grid_channels([bed], GW, GH, null, RECT)
	lake.water_elevation = 15.0 # change param without bake
	var ch2 := lake.eval_grid_channels([bed], GW, GH, null, RECT)

	var diff := absf(ch1[0][16 * GW + 16] - ch2[0][16 * GW + 16])
	print("    frozen cache diff before bake = %.7f (want 0.0)" % diff)
	if diff > EPS:
		_fail += 1; print("    !! frozen cache did not hold previous result")

	lake.clear_cache()
	var ch3 := lake.eval_grid_channels([bed], GW, GH, null, RECT)
	print("    height after bake = %.2f m (want 15.0m)" % ch3[0][16 * GW + 16])
	if absf(ch3[0][16 * GW + 16] - 15.0) > EPS:
		_fail += 1; print("    !! clear_cache did not re-solve")


func _e_metadata_and_ports() -> void:
	print("[E] Metadata and port types")
	var lake := Pasture3DGraphNodeLakeFlooding.new()
	if lake.op() != &"lake_flooding":
		_fail += 1; print("    !! op mismatch")
	if lake.role() != Pasture3DGraphNode.Role.SOLVER:
		_fail += 1; print("    !! role mismatch")
	if lake.output_count() != 3:
		_fail += 1; print("    !! output_count != 3")
	if lake.output_port_types()[0] != Pasture3DGraphNode.PortType.HEIGHT:
		_fail += 1; print("    !! port 0 should be HEIGHT")
	if lake.output_port_types()[1] != Pasture3DGraphNode.PortType.MASK:
		_fail += 1; print("    !! port 1 should be MASK")


func _make_bowl_grid(gw: int, gh: int, center_z: float, rim_z: float) -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(gw * gh)
	var max_r := float(gw) * 0.5
	for iz in range(gh):
		for ix in range(gw):
			var r := sqrt(float((ix - gw/2)*(ix - gw/2) + (iz - gh/2)*(iz - gh/2)))
			var t := clampf(r / max_r, 0.0, 1.0)
			g[iz * gw + ix] = lerpf(center_z, rim_z, t)
	return g
