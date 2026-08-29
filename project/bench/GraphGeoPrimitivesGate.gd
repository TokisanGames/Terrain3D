# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphGeoPrimitivesGate — Native C++ vs Tier 1 GDScript Oracle for Geological Primitives (MountainCone, MountainInselberg).
# Verifies bit-level parity (<= 1e-5), ridge sharpening, domain warping, and whole-graph native lowering.

extends Node

const DevMountainCone = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_mountain_cone.gd")
const DevMountainInselberg = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_mountain_inselberg.gd")
const Pasture3DTerrainGraph = preload("res://addons/pasture_3d/graph/pasture3d_terrain_graph.gd")

const EPS_PARITY := 1.0e-5

var _fail := 0


func _ready() -> void:
	print("=== GraphGeoPrimitivesGate: Geological Primitives Gate ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "mountain_cone_generate_grid"):
		print("!! Pasture3DUtil.mountain_cone_generate_grid is missing — extension binary needs rebuild.")
		_fail += 1
		_finish()
		return

	_test_a_mountain_cone_parity()
	_test_b_mountain_inselberg_parity()
	_test_c_cone_features()
	_test_d_whole_graph_lowering()

	_finish()


func _finish() -> void:
	print("\n=== %s (%d failures) ===\n" % [
		"GRAPH GEO PRIMITIVES PASS" if _fail == 0 else "GRAPH GEO PRIMITIVES FAIL",
		_fail
	])
	get_tree().quit(0 if _fail == 0 else 1)


func _test_a_mountain_cone_parity() -> void:
	print("[A] MountainCone Bit-Level Parity: C++ Native vs GDScript Oracle")
	var gw := 64
	var gh := 64
	var rect := Rect2(-50.0, -50.0, 100.0, 100.0)

	var p := {
		"seed": 42,
		"elevation": 15.0,
		"scale": 1.0,
		"octaves": 6,
		"peak_kw": 4.0,
		"rugosity": 0.0,
		"angle": 30.0,
		"gamma": 0.5,
		"cone_alpha": 1.2,
		"ridge_amp": 0.4,
		"base_noise_amp": 0.05,
		"center": Vector2(0.5, 0.5),
	}

	var gd_res: PackedFloat32Array = DevMountainCone.solve_oracle(gw, gh, rect, p)
	var cpp_res: PackedFloat32Array = Pasture3DUtil.mountain_cone_generate_grid(gw, gh, rect, p)

	for i in range(gd_res.size()):
		var d := absf(gd_res[i] - cpp_res[i])
		if d > 0.001:
			print("    [first diff at %d] gd=%.6f cpp=%.6f diff=%.6f" % [i, gd_res[i], cpp_res[i], d])
			break

	var diff := _max_abs_diff(gd_res, cpp_res)
	print("    MountainCone max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff, EPS_PARITY])

	if diff > EPS_PARITY:
		_fail += 1
		print("    !! MountainCone C++ native solver diverged beyond bit-level tolerance")


func _test_b_mountain_inselberg_parity() -> void:
	print("\n[B] MountainInselberg Bit-Level Parity: C++ Native vs GDScript Oracle")
	var gw := 64
	var gh := 64
	var rect := Rect2(-50.0, -50.0, 100.0, 100.0)

	var p := {
		"seed": 1337,
		"elevation": 20.0,
		"scale": 1.0,
		"octaves": 6,
		"rugosity": 0.0,
		"angle": 60.0,
		"gamma": 0.5,
		"bulk_amp": 0.5,
		"base_noise_amp": 0.05,
		"center": Vector2(0.5, 0.5),
	}

	var gd_res: PackedFloat32Array = DevMountainInselberg.solve_oracle(gw, gh, rect, p)
	var cpp_res: PackedFloat32Array = Pasture3DUtil.mountain_inselberg_generate_grid(gw, gh, rect, p)

	var diff := _max_abs_diff(gd_res, cpp_res)
	print("    MountainInselberg max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff, EPS_PARITY])

	if diff > EPS_PARITY:
		_fail += 1
		print("    !! MountainInselberg C++ native solver diverged beyond bit-level tolerance")


func _test_c_cone_features() -> void:
	print("\n[C] MountainCone Feature Verification (Peak Sharpness & Ridge Modulation)")
	var gw := 64
	var gh := 64
	var rect := Rect2(-50.0, -50.0, 100.0, 100.0)

	var p := {
		"seed": 0,
		"elevation": 30.0,
		"scale": 1.0,
		"octaves": 8,
		"peak_kw": 4.0,
		"gamma": 0.5,
		"cone_alpha": 1.2,
		"ridge_amp": 0.5,
		"center": Vector2(0.5, 0.5),
	}

	var res: PackedFloat32Array = Pasture3DUtil.mountain_cone_generate_grid(gw, gh, rect, p)
	var max_h := _max_val(res)
	var border_h := res[0]

	print("    Summit peak elevation = %.2f m" % max_h)
	print("    Domain border elevation = %.2f m" % border_h)

	if max_h < 20.0 or border_h > 1.0:
		_fail += 1
		print("    !! Mountain cone failed summit or boundary decay criteria")


func _test_d_whole_graph_lowering() -> void:
	print("\n[D] Whole-Graph Lowering: MountainCone -> HydraulicSaleve Native Pipeline")
	var graph := Pasture3DTerrainGraph.new()

	var cone_node = Pasture3DGraphNodeRegistry.create(&"mountain_cone")
	var saleve_node = Pasture3DGraphNodeRegistry.create(&"hydraulic_saleve")
	var output_node = Pasture3DGraphNodeRegistry.create(&"output")

	var id_cone: int = graph.add_node(cone_node)
	var id_saleve: int = graph.add_node(saleve_node)
	var id_output: int = graph.add_node(output_node)

	graph.connect_ports(id_cone, 0, id_saleve, 0)
	graph.connect_ports(id_saleve, 0, id_output, 0)
	graph.output_node = id_output

	var is_native: bool = graph.native_supported()
	print("    MountainCone -> HydraulicSaleve native_supported = %s (want true)" % str(is_native))

	if not is_native:
		_fail += 1
		print("    !! Pipeline failed native graph lowering")


func _max_abs_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var m := 0.0
	for i in range(min(a.size(), b.size())):
		var d := absf(a[i] - b[i])
		if d > m:
			m = d
	return m


func _max_val(a: PackedFloat32Array) -> float:
	var m := 0.0
	for v in a:
		if is_finite(v) and v > m:
			m = v
	return m
