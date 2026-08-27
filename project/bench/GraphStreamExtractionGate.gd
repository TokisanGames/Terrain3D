# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphStreamExtractionGate — parity and behavior verification for Pasture3DGraphNodeStreamExtraction.
#
# Tests:
#   [A] Drainage flow routing: surface runoff collects in downhill valleys.
#   [B] Stream channel carving: riverbed channels carved along high-catchment cells.
#   [C] Multi-output channel isolation: height, channel_mask, and flow_rate.
#   [D] Frozen cache and Bake operation.
#   [E] Node metadata & warnings.
extends Node

const GW := 32
const GH := 32
const RECT := Rect2(-50.0, -50.0, 100.0, 100.0)
const EPS := 1.0e-4

var _fail := 0


func _ready() -> void:
	print("=== GraphStreamExtractionGate: flow routing and river channel solver ===\n")
	_a_flow_routing()
	_b_channel_carving()
	_c_multi_output_channels()
	_d_frozen_cache()
	_e_metadata_and_warnings()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH STREAM EXTRACTION PASS" if _fail == 0 else "GRAPH STREAM EXTRACTION FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _a_flow_routing() -> void:
	print("[A] Downhill drainage flow accumulation")
	var valley := _make_v_valley_grid(GW, GH)
	var stream := Pasture3DGraphNodeStreamExtraction.new()
	stream.min_catchment_cells = 10.0
	stream.carve_depth = 0.0

	var channels := stream.eval_grid_channels([valley], GW, GH, null, RECT)
	var flow: PackedFloat32Array = channels[2]

	# Central valley bottom (ix=16) should accumulate much higher flow than ridges (ix=0, ix=31)
	var ridge_flow := flow[16 * GW + 0]
	var valley_flow := flow[31 * GW + 16] # lowest downhill exit of the valley floor

	print("    ridge flow = %.4f, valley outlet flow = %.4f (valley > ridge)" % [ridge_flow, valley_flow])
	if valley_flow <= ridge_flow * 2.0:
		_fail += 1; print("    !! flow was not routed down into the valley floor")


func _b_channel_carving() -> void:
	print("[B] River channel bed carving")
	var valley := _make_v_valley_grid(GW, GH)
	var stream := Pasture3DGraphNodeStreamExtraction.new()
	stream.min_catchment_cells = 10.0
	stream.carve_depth = 4.0

	var channels := stream.eval_grid_channels([valley], GW, GH, null, RECT)
	var carved_h: PackedFloat32Array = channels[0]

	var orig_val := valley[30 * GW + 16]
	var new_val := carved_h[30 * GW + 16]

	print("    valley floor height: orig=%.2f m, carved=%.2f m (delta -%.2f m, want >= 1.0 m carve)" % [orig_val, new_val, orig_val - new_val])
	if orig_val - new_val < 1.0:
		_fail += 1; print("    !! river channel was not carved along high-flow path")


func _c_multi_output_channels() -> void:
	print("[C] Multi-output channel isolation")
	var valley := _make_v_valley_grid(GW, GH)
	var stream := Pasture3DGraphNodeStreamExtraction.new()
	stream.min_catchment_cells = 10.0

	var channels := stream.eval_grid_channels([valley], GW, GH, null, RECT)
	if channels.size() != 3:
		_fail += 1; print("    !! expected 3 output channels")
		return

	var h_grid: PackedFloat32Array = channels[0]
	var mask_grid: PackedFloat32Array = channels[1]
	var flow_grid: PackedFloat32Array = channels[2]

	if h_grid.size() != GW * GH or mask_grid.size() != GW * GH or flow_grid.size() != GW * GH:
		_fail += 1; print("    !! output channel size mismatch")


func _d_frozen_cache() -> void:
	print("[D] Frozen cache and Bake operation")
	var valley := _make_v_valley_grid(GW, GH)
	var stream := Pasture3DGraphNodeStreamExtraction.new()
	stream.evaluation = Pasture3DGraphNodeStreamExtraction.Evaluation.FROZEN
	stream.carve_depth = 2.0
	stream.min_catchment_cells = 10.0

	var ch1 := stream.eval_grid_channels([valley], GW, GH, null, RECT)
	stream.carve_depth = 8.0 # change param without bake
	var ch2 := stream.eval_grid_channels([valley], GW, GH, null, RECT)

	var diff := absf(ch1[0][30 * GW + 16] - ch2[0][30 * GW + 16])
	print("    frozen cache diff before bake = %.7f (want 0.0)" % diff)
	if diff > EPS:
		_fail += 1; print("    !! frozen cache did not hold previous result")

	stream.clear_cache()
	var ch3 := stream.eval_grid_channels([valley], GW, GH, null, RECT)
	var carved_h3: PackedFloat32Array = ch3[0]
	var delta_new: float = float(valley[30 * GW + 16]) - float(carved_h3[30 * GW + 16])
	print("    carve depth after bake = %.2f m (want > 3.0 m)" % delta_new)
	if delta_new < 3.0:
		_fail += 1; print("    !! clear_cache did not re-solve with new carve depth")


func _e_metadata_and_warnings() -> void:
	print("[E] Metadata and warnings")
	var stream := Pasture3DGraphNodeStreamExtraction.new()
	if stream.op() != &"stream_extraction":
		_fail += 1; print("    !! op mismatch")
	if stream.role() != Pasture3DGraphNode.Role.SOLVER:
		_fail += 1; print("    !! role mismatch")
	if stream.output_count() != 3:
		_fail += 1; print("    !! output_count != 3")


func _make_v_valley_grid(gw: int, gh: int) -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(gw * gh)
	var cx := gw / 2.0
	for iz in range(gh):
		for ix in range(gw):
			# V-shape in X, sloping downwards in Z
			var lateral := absf(float(ix) - cx) * 2.0
			var downhill := float(gh - 1 - iz) * 1.5
			g[iz * gw + ix] = lateral + downhill
	return g
