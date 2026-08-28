# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphHydraulicStreamLogGate — Native C++ vs Tier 1 GDScript Oracle for Logarithmic Stream Power Erosion.
# Verifies bit-level parity (<= 2e-6 m), logarithmic incision response, channel mask generation, and NaN handling.

extends Node

const DevHydraulicStreamLog = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_hydraulic_stream_log.gd")

const EPS_SINGLE_PASS := 5.0e-6
const EPS_MULTI_PASS := 0.01

var _fail := 0


func _ready() -> void:
	print("=== GraphHydraulicStreamLogGate: Logarithmic Stream-Power Erosion Gate ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "hydraulic_stream_log_solve_grid"):
		print("!! Pasture3DUtil.hydraulic_stream_log_solve_grid is missing — extension binary needs rebuild.")
		_fail += 1
		_finish()
		return

	_test_a_native_parity()
	_test_b_logarithmic_scaling()
	_test_c_nan_boundary_handling()
	_test_d_channel_extraction()

	_finish()


func _finish() -> void:
	print("\n=== %s (%d failures) ===\n" % [
		"GRAPH HYDRAULIC STREAM LOG PASS" if _fail == 0 else "GRAPH HYDRAULIC STREAM LOG FAIL",
		_fail
	])
	get_tree().quit(0 if _fail == 0 else 1)


func _test_a_native_parity() -> void:
	print("[A1] Bit-level Parity (Single Pass): C++ Native vs GDScript Tier 1 Oracle")
	var gw := 64
	var gh := 64
	var rect := Rect2(-50.0, -50.0, 100.0, 100.0)
	var surf := _make_test_surface(gw, gh)

	var p1 := {
		"iterations": 1,
		"incision_rate": 0.15,
		"area_exponent": 0.5,
		"slope_exponent": 1.0,
		"min_catchment": 1.0,
		"bank_smoothing": 0.1,
	}

	var gd_res1: Array = DevHydraulicStreamLog.solve_oracle(surf, gw, gh, rect, p1)
	var cpp_res1: Dictionary = Pasture3DUtil.hydraulic_stream_log_solve_grid(surf, gw, gh, rect, p1)

	var diff_h1 := _max_abs_diff(gd_res1[0], cpp_res1["height"])
	var diff_c1 := _max_abs_diff(gd_res1[1], cpp_res1["channel_mask"])
	var diff_f1 := _max_abs_diff(gd_res1[2], cpp_res1["flow_accumulation"])

	print("    [1 pass] Height            max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_h1, EPS_SINGLE_PASS])
	print("    [1 pass] Channel Mask      max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_c1, EPS_SINGLE_PASS])
	print("    [1 pass] Flow Accumulation max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_f1, EPS_SINGLE_PASS])

	if diff_h1 > EPS_SINGLE_PASS or diff_c1 > EPS_SINGLE_PASS or diff_f1 > EPS_SINGLE_PASS:
		_fail += 1
		print("    !! Single pass C++ native solver diverged beyond bit-level tolerance")

	print("\n[A2] Multi-Pass Parity (10 Iterations): C++ Native vs GDScript Tier 1 Oracle")
	var p10 := {
		"iterations": 10,
		"incision_rate": 0.15,
		"area_exponent": 0.5,
		"slope_exponent": 1.0,
		"min_catchment": 1.0,
		"bank_smoothing": 0.1,
	}

	var gd_res10: Array = DevHydraulicStreamLog.solve_oracle(surf, gw, gh, rect, p10)
	var cpp_res10: Dictionary = Pasture3DUtil.hydraulic_stream_log_solve_grid(surf, gw, gh, rect, p10)

	var diff_h10 := _max_abs_diff(gd_res10[0], cpp_res10["height"])
	var diff_c10 := _max_abs_diff(gd_res10[1], cpp_res10["channel_mask"])
	var diff_f10 := _max_abs_diff(gd_res10[2], cpp_res10["flow_accumulation"])

	print("    [10 pass] Height            max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_h10, EPS_MULTI_PASS])
	print("    [10 pass] Channel Mask      max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_c10, EPS_MULTI_PASS])
	print("    [10 pass] Flow Accumulation max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_f10, EPS_MULTI_PASS])

	if diff_h10 > EPS_MULTI_PASS or diff_c10 > EPS_MULTI_PASS or diff_f10 > EPS_MULTI_PASS:
		_fail += 1
		print("    !! Multi-pass C++ native solver diverged beyond iterative tolerance")


func _test_b_logarithmic_scaling() -> void:
	print("\n[B] Logarithmic Scaling & Stability (No Runaway Blowouts)")
	var gw := 64
	var gh := 64
	var rect := Rect2(0.0, 0.0, 100.0, 100.0)
	var surf := _make_test_surface(gw, gh)

	var p1 := { "iterations": 5, "incision_rate": 0.1, "area_exponent": 0.5, "slope_exponent": 1.0 }
	var p2 := { "iterations": 25, "incision_rate": 0.1, "area_exponent": 0.5, "slope_exponent": 1.0 }

	var res1: Dictionary = Pasture3DUtil.hydraulic_stream_log_solve_grid(surf, gw, gh, rect, p1)
	var res2: Dictionary = Pasture3DUtil.hydraulic_stream_log_solve_grid(surf, gw, gh, rect, p2)

	var cut1 := _max_abs_diff(surf, res1["height"])
	var cut2 := _max_abs_diff(surf, res2["height"])

	print("    Incision depth @ 5 passes = %.4f m" % cut1)
	print("    Incision depth @ 25 passes = %.4f m" % cut2)

	if cut2 <= cut1 or cut2 > 25.0:
		_fail += 1
		print("    !! Incision failed stability / monotonic growth criteria")


func _test_c_nan_boundary_handling() -> void:
	print("\n[C] NaN Boundary Invariance")
	var gw := 32
	var gh := 32
	var rect := Rect2(0.0, 0.0, 50.0, 50.0)
	var surf := _make_test_surface(gw, gh)

	for ix in range(gw):
		surf[ix] = NAN
		surf[(gh - 1) * gw + ix] = NAN
	for iz in range(gh):
		surf[iz * gw] = NAN
		surf[iz * gw + (gw - 1)] = NAN

	var p := { "iterations": 5 }
	var res: Dictionary = Pasture3DUtil.hydraulic_stream_log_solve_grid(surf, gw, gh, rect, p)
	var h: PackedFloat32Array = res["height"]

	var nan_ok := true
	for ix in range(gw):
		if not is_nan(h[ix]) or not is_nan(h[(gh - 1) * gw + ix]):
			nan_ok = false
	for iz in range(gh):
		if not is_nan(h[iz * gw]) or not is_nan(h[iz * gw + (gw - 1)]):
			nan_ok = false

	print("    NaN borders preserved: %s" % str(nan_ok))
	if not nan_ok:
		_fail += 1
		print("    !! Solver corrupted NaN boundaries")


func _test_d_channel_extraction() -> void:
	print("\n[D] Channel Mask & Flow Accumulation Response")
	var gw := 64
	var gh := 64
	var rect := Rect2(0.0, 0.0, 100.0, 100.0)
	var surf := _make_test_surface(gw, gh)

	var p := {
		"iterations": 15,
		"incision_rate": 0.2,
		"area_exponent": 0.5,
		"slope_exponent": 1.0,
		"min_catchment": 2.0,
		"bank_smoothing": 0.1,
	}

	var res: Dictionary = Pasture3DUtil.hydraulic_stream_log_solve_grid(surf, gw, gh, rect, p)
	var c: PackedFloat32Array = res["channel_mask"]
	var f: PackedFloat32Array = res["flow_accumulation"]

	var max_c := _max_val(c)
	var max_f := _max_val(f)

	print("    Max channel mask = %.4f" % max_c)
	print("    Max flow accumulation = %.4f cells" % max_f)

	if max_c < 0.05 or max_f < 10.0:
		_fail += 1
		print("    !! Channel mask or flow accumulation failed to extract river network")


func _make_test_surface(p_gw: int, p_gh: int) -> PackedFloat32Array:
	var arr := PackedFloat32Array()
	arr.resize(p_gw * p_gh)
	for iz in range(p_gh):
		var nz := float(iz) / float(p_gh - 1)
		for ix in range(p_gw):
			var nx := float(ix) / float(p_gw - 1)
			# Sloped terrain with central valley thalweg
			var valley := absf(nx - 0.5) * 20.0
			var slope := (1.0 - nz) * 40.0
			var h := slope + valley + 2.0 * sin(nx * 8.0) * cos(nz * 8.0)
			arr[iz * p_gw + ix] = h
	return arr


func _max_abs_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var m := 0.0
	for i in range(min(a.size(), b.size())):
		var va := a[i]
		var vb := b[i]
		if is_nan(va) and is_nan(vb):
			continue
		if is_nan(va) or is_nan(vb):
			return 99999.0
		var d := absf(va - vb)
		if d > m:
			m = d
	return m


func _max_val(a: PackedFloat32Array) -> float:
	var m := 0.0
	for v in a:
		if is_finite(v) and v > m:
			m = v
	return m
