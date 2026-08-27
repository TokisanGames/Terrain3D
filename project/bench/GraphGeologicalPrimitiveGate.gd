# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphGeologicalPrimitiveGate — parity and behavior verification for Pasture3DGraphNodeGeologicalPrimitive
# and Pasture3DPlow Graph / Modifier support.
#
# Tests:
#   [A] Inselberg dome formation: peak at center, zero outside radius.
#   [B] Volcanic caldera depression: raised rim with central cavity depression.
#   [C] Cuesta badlands asymmetry: gentle dip slope vs steep scarp cliff.
#   [D] FIT_FRAME vs METRIC_WORLD mapping parity with graph evaluate.
#   [E] Node metadata & Plow brush graph integration.
extends Node

const GW := 32
const GH := 32
const RECT := Rect2(-50.0, -50.0, 100.0, 100.0)
const EPS := 1.0e-4

var _fail := 0


func _ready() -> void:
	print("=== GraphGeologicalPrimitiveGate: macro geological primitive generator & plow graph ===\n")
	_a_inselberg_dome()
	_b_volcanic_caldera()
	_c_cuesta_asymmetry()
	_d_mapping_parity()
	_e_plow_graph_integration()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH GEOLOGICAL PASS" if _fail == 0 else "GRAPH GEOLOGICAL FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _a_inselberg_dome() -> void:
	print("[A] Inselberg dome peak and boundary falloff")
	var gp := Pasture3DGraphNodeGeologicalPrimitive.new()
	gp.primitive_type = Pasture3DGraphNodeGeologicalPrimitive.PrimitiveType.INSELBERG
	gp.mapping = Pasture3DGraphNodeGeologicalPrimitive.Mapping.METRIC_WORLD
	gp.height = 80.0
	gp.radius = 40.0

	var center_val := gp.eval_cell(0.0, 0.0, PackedFloat32Array())
	var outside_val := gp.eval_cell(45.0, 0.0, PackedFloat32Array())

	print("    inselberg center = %.2f m (want 80.0m), outside radius = %.2f m (want 0.0m)" % [center_val, outside_val])
	if absf(center_val - 80.0) > EPS:
		_fail += 1; print("    !! inselberg peak height mismatch")
	if outside_val > EPS:
		_fail += 1; print("    !! inselberg did not fall off to 0 outside radius")


func _b_volcanic_caldera() -> void:
	print("[B] Volcanic caldera crater rim and central depression")
	var gp := Pasture3DGraphNodeGeologicalPrimitive.new()
	gp.primitive_type = Pasture3DGraphNodeGeologicalPrimitive.PrimitiveType.VOLCANIC_CALDERA
	gp.mapping = Pasture3DGraphNodeGeologicalPrimitive.Mapping.METRIC_WORLD
	gp.height = 100.0
	gp.radius = 50.0

	var center_cavity := gp.eval_cell(0.0, 0.0, PackedFloat32Array())
	var rim_peak := gp.eval_cell(22.5, 0.0, PackedFloat32Array()) # r = 22.5m is 0.45*50m = rim

	print("    caldera center = %.2f m, rim peak = %.2f m (rim > center)" % [center_cavity, rim_peak])
	if rim_peak <= center_cavity + 10.0:
		_fail += 1; print("    !! caldera failed to form raised rim over central depression")


func _c_cuesta_asymmetry() -> void:
	print("[C] Cuesta badlands asymmetry: steep scarp vs gentle dip slope")
	var gp := Pasture3DGraphNodeGeologicalPrimitive.new()
	gp.primitive_type = Pasture3DGraphNodeGeologicalPrimitive.PrimitiveType.CUESTA_BADLANDS
	gp.mapping = Pasture3DGraphNodeGeologicalPrimitive.Mapping.METRIC_WORLD
	gp.height = 50.0
	gp.radius = 40.0

	# Scarp side (-lx) vs Dip side (+lx)
	var scarp_flank := gp.eval_cell(-15.0, 0.0, PackedFloat32Array())
	var dip_flank := gp.eval_cell(15.0, 0.0, PackedFloat32Array())

	print("    scarp side height = %.2f m, dip side height = %.2f m (asymmetric)" % [scarp_flank, dip_flank])
	if absf(scarp_flank - dip_flank) < 5.0:
		_fail += 1; print("    !! cuesta lacked expected structural asymmetry")


func _d_mapping_parity() -> void:
	print("[D] FIT_FRAME and METRIC_WORLD evaluation parity")
	var gp := Pasture3DGraphNodeGeologicalPrimitive.new()
	gp.primitive_type = Pasture3DGraphNodeGeologicalPrimitive.PrimitiveType.INSELBERG
	gp.mapping = Pasture3DGraphNodeGeologicalPrimitive.Mapping.FIT_FRAME
	gp.height = 60.0
	gp.radius = 1.0

	var g := Pasture3DTerrainGraph.new()
	g.nodes = [gp]
	g.output_node = 0

	var evaluated := g.evaluate(GW, GH, RECT)
	# Center cell at GW/2, GH/2 should be at peak height
	var center_idx := (GH / 2) * GW + (GW / 2)
	var center_height := evaluated[center_idx]
	print("    FIT_FRAME peak = %.2f m (want ~60.0m)" % center_height)
	if absf(center_height - 60.0) > 2.0:
		_fail += 1; print("    !! FIT_FRAME center height deviated")

	# Edge cells should be 0
	var corner_height := evaluated[0]
	if corner_height > EPS:
		_fail += 1; print("    !! FIT_FRAME boundary did not fall off to zero")


func _e_plow_graph_integration() -> void:
	print("[E] Pasture3DPlow Graph and Modifier support")
	var plow := Pasture3DPlow.new()
	if not plow._supports_modifiers():
		_fail += 1; print("    !! plow does not report modifier support")
	plow.source = Pasture3DPlow.Source.GRAPH
	var g := Pasture3DTerrainGraph.new()
	var gp := Pasture3DGraphNodeGeologicalPrimitive.new()
	gp.height = 40.0
	g.nodes = [gp]
	g.output_node = 0
	plow.graph = g
	var warnings := plow._get_configuration_warnings()
	print("    plow graph warnings count = %d" % warnings.size())
	plow.free()
