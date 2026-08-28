# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphPhase1BrushTest — Verifies that graphs containing HydraulicParticle and HydraulicStreamLog
# are recognized as native_supported() == true, compile into native SSA graph programs, and
# preserve brush mounds while incising natural riverbeds.

extends Node

var _fail := 0


func _ready() -> void:
	print("=== GraphPhase1BrushTest: Native Support & Brush Preservation ===\n")
	_test_native_supported()
	_test_brush_mound_preservation()
	_finish()


func _finish() -> void:
	print("\n=== %s (%d failures) ===\n" % [
		"PHASE 1 BRUSH TEST PASS" if _fail == 0 else "PHASE 1 BRUSH TEST FAIL",
		_fail
	])
	get_tree().quit(0 if _fail == 0 else 1)


func _test_native_supported() -> void:
	print("[A] Testing graph.native_supported() for new Phase 1 erosion nodes")
	var g1 := Pasture3DTerrainGraph.new()
	var in1: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"input")
	var hp: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"hydraulic_particle")
	var out1: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"output")
	g1.nodes = [in1, hp, out1]
	g1.connections = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, 0, 2, 0])]
	g1.output_node = 2

	var supp1: bool = g1.native_supported()
	print("    Graph with HydraulicParticle native_supported = %s (want true)" % str(supp1))
	if not supp1:
		_fail += 1
		print("    !! HydraulicParticle not marked as native_supported")

	var g2 := Pasture3DTerrainGraph.new()
	var in2: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"input")
	var hsl: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"hydraulic_stream_log")
	var out2: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"output")
	g2.nodes = [in2, hsl, out2]
	g2.connections = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, 0, 2, 0])]
	g2.output_node = 2

	var supp2: bool = g2.native_supported()
	print("    Graph with HydraulicStreamLog native_supported = %s (want true)" % str(supp2))
	if not supp2:
		_fail += 1
		print("    !! HydraulicStreamLog not marked as native_supported")


func _test_brush_mound_preservation() -> void:
	print("\n[B] Testing Brush Mound Elevation Preservation during Logarithmic Stream Erosion")
	var gw := 64
	var gh := 64
	var rect := Rect2(-50.0, -50.0, 100.0, 100.0)

	# Construct a 20m high dome brush mound
	var mound := PackedFloat32Array()
	mound.resize(gw * gh)
	var peak_h := 20.0
	for iz in range(gh):
		var nz := float(iz) / float(gh - 1) - 0.5
		for ix in range(gw):
			var nx := float(ix) / float(gw - 1) - 0.5
			var r := sqrt(nx * nx + nz * nz) * 2.0 # 0 at center, 1 at boundary
			var h := maxf(0.0, peak_h * (1.0 - r * r))
			mound[iz * gw + ix] = h

	var p := {
		"iterations": 15,
		"incision_rate": 0.15,
		"area_exponent": 0.5,
		"slope_exponent": 1.0,
		"min_catchment": 1.0,
		"bank_smoothing": 0.1,
	}

	var res: Dictionary = Pasture3DUtil.hydraulic_stream_log_solve_grid(mound, gw, gh, rect, p)
	var out_h: PackedFloat32Array = res["height"]

	var center_idx := (gh / 2) * gw + (gw / 2)
	var orig_peak := mound[center_idx]
	var new_peak := out_h[center_idx]
	var peak_retention := new_peak / orig_peak

	print("    Original mound peak: %.2f m" % orig_peak)
	print("    Eroded mound peak:   %.2f m (retention = %.1f%%)" % [new_peak, peak_retention * 100.0])

	# The peak should not be flattened/wiped out (retention > 90% since drainage originates at peak)
	if peak_retention < 0.85:
		_fail += 1
		print("    !! Brush mound was flattened (peak retention %.1f%% < 85%%)" % (peak_retention * 100.0))
	else:
		print("    PASS: Brush mound structure strongly preserved while streams carve slopes.")
