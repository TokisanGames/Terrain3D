# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphGeologicalPrimitiveGate — parity and behavior verification for Pasture3DGraphNodeGeologicalPrimitive.
#
# Tests:
#   [A] Inselberg dome formation: peak at center, zero outside radius.
#   [B] Volcanic caldera depression: raised rim with central cavity depression.
#   [C] Cuesta badlands asymmetry: gentle dip slope vs steep scarp cliff.
#   [D] Cell-node fold parity: evaluate() folded loop matches eval_cell().
#   [E] Node metadata & warnings.
extends Node

const GW := 32
const GH := 32
const RECT := Rect2(-50.0, -50.0, 100.0, 100.0)
const EPS := 1.0e-4

var _fail := 0


func _ready() -> void:
	print("=== GraphGeologicalPrimitiveGate: macro geological primitive generator ===\n")
	_a_inselberg_dome()
	_b_volcanic_caldera()
	_c_cuesta_asymmetry()
	_d_cell_fold_parity()
	_e_metadata_and_warnings()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH GEOLOGICAL PASS" if _fail == 0 else "GRAPH GEOLOGICAL FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _a_inselberg_dome() -> void:
	print("[A] Inselberg dome peak and boundary falloff")
	var gp := Pasture3DGraphNodeGeologicalPrimitive.new()
	gp.primitive_type = Pasture3DGraphNodeGeologicalPrimitive.PrimitiveType.INSELBERG
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
	gp.height = 100.0
	gp.radius = 50.0

	var center_cavity := gp.eval_cell(0.0, 0.0, PackedFloat32Array())
	var rim_peak := gp.eval_cell(20.0, 0.0, PackedFloat32Array()) # r = 20m is 0.4*50m = rim

	print("    caldera center = %.2f m, rim peak = %.2f m (rim > center)" % [center_cavity, rim_peak])
	if rim_peak <= center_cavity + 10.0:
		_fail += 1; print("    !! caldera failed to form raised rim over central depression")


func _c_cuesta_asymmetry() -> void:
	print("[C] Cuesta badlands asymmetry: steep scarp vs gentle dip slope")
	var gp := Pasture3DGraphNodeGeologicalPrimitive.new()
	gp.primitive_type = Pasture3DGraphNodeGeologicalPrimitive.PrimitiveType.CUESTA_BADLANDS
	gp.height = 50.0
	gp.radius = 40.0

	# Scarp side (-lx) vs Dip side (+lx)
	var scarp_flank := gp.eval_cell(-15.0, 0.0, PackedFloat32Array())
	var dip_flank := gp.eval_cell(15.0, 0.0, PackedFloat32Array())

	print("    scarp side height = %.2f m, dip side height = %.2f m (asymmetric)" % [scarp_flank, dip_flank])
	if absf(scarp_flank - dip_flank) < 5.0:
		_fail += 1; print("    !! cuesta lacked expected structural asymmetry")


func _d_cell_fold_parity() -> void:
	print("[D] Cell-node fold parity with graph evaluate")
	var gp := Pasture3DGraphNodeGeologicalPrimitive.new()
	gp.primitive_type = Pasture3DGraphNodeGeologicalPrimitive.PrimitiveType.INSELBERG
	gp.height = 60.0
	gp.radius = 45.0

	var g := Pasture3DTerrainGraph.new()
	g.nodes = [gp]
	g.output_node = 0

	var evaluated := g.evaluate(GW, GH, RECT)
	var max_diff := 0.0
	for iz in range(GH):
		for ix in range(GW):
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, GW, GH, RECT)
			var expected := gp.eval_cell(w.x, w.y, PackedFloat32Array())
			var got := evaluated[iz * GW + ix]
			max_diff = maxf(max_diff, absf(got - expected))

	print("    max fold diff = %.7f (want < %.7f)" % [max_diff, EPS])
	if max_diff > EPS:
		_fail += 1; print("    !! graph fold deviated from cell evaluation")


func _e_metadata_and_warnings() -> void:
	print("[E] Metadata validation")
	var gp := Pasture3DGraphNodeGeologicalPrimitive.new()
	if gp.op() != &"geological_primitive":
		_fail += 1; print("    !! op mismatch")
	if gp.role() != Pasture3DGraphNode.Role.GENERATOR:
		_fail += 1; print("    !! role mismatch")
	if gp.needs_grid():
		_fail += 1; print("    !! needs_grid should be false for cell generator")
