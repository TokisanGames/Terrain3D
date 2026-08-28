# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphHydraulicSaleveGate: Parity & Regression test for Salève Structural Hydraulic Erosion.
# Tests C++ Native vs GDScript Tier 1 oracle bit-level equivalence, joint azimuth deflection,
# mountain crest curvature shielding, and sediment deposition.

extends Node

const DevHydraulicSaleve = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_hydraulic_saleve.gd")

const EPS_SINGLE_PASS := 5.0e-6
const EPS_MULTI_PASS := 0.01

var _fail := 0


func _ready() -> void:
	print("=== GraphHydraulicSaleveGate: Salève Structural Hydraulic Erosion Gate ===\n")
	_test_single_pass_parity()
	_test_multi_pass_parity()
	_test_joint_azimuth_deflection()
	_test_ridge_preservation()
	_test_nan_boundary_invariance()
	print("\n=== %s (%d failures) ===\n" % [
		"GRAPH HYDRAULIC SALEVE PASS" if _fail == 0 else "GRAPH HYDRAULIC SALEVE FAIL",
		_fail
	])
	get_tree().quit(0 if _fail == 0 else 1)


func _test_single_pass_parity() -> void:
	print("[A1] Bit-level Parity (Single Pass): C++ Native vs GDScript Tier 1 Oracle")
	var gw := 48
	var gh := 48
	var rect := Rect2(0, 0, 100, 100)
	var surface := _create_mountain_dome(gw, gh, 25.0)

	var params := {
		"iterations": 1,
		"incision_rate": 0.25,
		"joint_azimuth": 45.0,
		"joint_strength": 0.5,
		"ridge_preservation": 0.8,
		"deposition_rate": 0.3,
		"bank_smoothing": 0.1,
	}

	var res_gd: Array = DevHydraulicSaleve.solve_oracle(surface, gw, gh, rect, params)
	var res_cpp: Dictionary = Pasture3DUtil.hydraulic_saleve_solve_grid(surface, gw, gh, rect, params)

	var diff_h := _max_diff(res_cpp["height"], res_gd[0])
	var diff_er := _max_diff(res_cpp["eroded_rock"], res_gd[1])
	var diff_sed := _max_diff(res_cpp["sediment"], res_gd[2])

	print("    [1 pass] Height       max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_h, EPS_SINGLE_PASS])
	print("    [1 pass] Eroded Rock  max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_er, EPS_SINGLE_PASS])
	print("    [1 pass] Sediment     max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_sed, EPS_SINGLE_PASS])

	if diff_h > EPS_SINGLE_PASS or diff_er > EPS_SINGLE_PASS or diff_sed > EPS_SINGLE_PASS:
		_fail += 1
		print("    !! Single pass C++ native solver diverged from GDScript oracle")


func _test_multi_pass_parity() -> void:
	print("\n[A2] Multi-Pass Parity (15 Iterations): C++ Native vs GDScript Tier 1 Oracle")
	var gw := 48
	var gh := 48
	var rect := Rect2(0, 0, 100, 100)
	var surface := _create_mountain_dome(gw, gh, 25.0)

	var params := {
		"iterations": 15,
		"incision_rate": 0.2,
		"joint_azimuth": 30.0,
		"joint_strength": 0.4,
		"ridge_preservation": 0.8,
		"deposition_rate": 0.25,
		"bank_smoothing": 0.1,
	}

	var res_gd: Array = DevHydraulicSaleve.solve_oracle(surface, gw, gh, rect, params)
	var res_cpp: Dictionary = Pasture3DUtil.hydraulic_saleve_solve_grid(surface, gw, gh, rect, params)

	var diff_h := _max_diff(res_cpp["height"], res_gd[0])
	var diff_er := _max_diff(res_cpp["eroded_rock"], res_gd[1])
	var diff_sed := _max_diff(res_cpp["sediment"], res_gd[2])

	print("    [15 pass] Height      max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_h, EPS_MULTI_PASS])
	print("    [15 pass] Eroded Rock max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_er, EPS_MULTI_PASS])
	print("    [15 pass] Sediment    max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_sed, EPS_MULTI_PASS])

	if diff_h > EPS_MULTI_PASS or diff_er > EPS_MULTI_PASS or diff_sed > EPS_MULTI_PASS:
		_fail += 1
		print("    !! Multi-pass C++ native solver diverged beyond iterative tolerance")


func _test_joint_azimuth_deflection() -> void:
	print("\n[B] Structural Joint Azimuth Deflection")
	var gw := 48
	var gh := 48
	var rect := Rect2(0, 0, 100, 100)
	var surface := _create_mountain_dome(gw, gh, 20.0)

	var p_45 := {
		"iterations": 10,
		"incision_rate": 0.3,
		"joint_azimuth": 45.0,
		"joint_strength": 0.8,
		"ridge_preservation": 0.5,
		"deposition_rate": 0.0,
		"bank_smoothing": 0.1,
	}
	var res_45: Dictionary = Pasture3DUtil.hydraulic_saleve_solve_grid(surface, gw, gh, rect, p_45)

	var p_135 := {
		"iterations": 10,
		"incision_rate": 0.3,
		"joint_azimuth": 135.0,
		"joint_strength": 0.8,
		"ridge_preservation": 0.5,
		"deposition_rate": 0.0,
		"bank_smoothing": 0.1,
	}
	var res_135: Dictionary = Pasture3DUtil.hydraulic_saleve_solve_grid(surface, gw, gh, rect, p_135)

	var diff := _max_diff(res_45["height"], res_135["height"])
	print("    Max height variance between 45° and 135° joint azimuths = %.4f m (want > 0.10 m)" % diff)
	if diff < 0.10:
		_fail += 1
		print("    !! Joint azimuth did not meaningfully deflect stream carving pathways")


func _test_ridge_preservation() -> void:
	print("\n[C] Mountain Ridge Crest Preservation")
	var gw := 48
	var gh := 48
	var rect := Rect2(0, 0, 100, 100)
	var surface := _create_mountain_dome(gw, gh, 30.0)

	var p_shielded := {
		"iterations": 15,
		"incision_rate": 0.3,
		"joint_azimuth": 0.0,
		"joint_strength": 0.0,
		"ridge_preservation": 1.0,
		"deposition_rate": 0.0,
		"bank_smoothing": 0.1,
	}
	var res_shield: Dictionary = Pasture3DUtil.hydraulic_saleve_solve_grid(surface, gw, gh, rect, p_shielded)

	var orig_peak: float = _max_val(surface)
	var eroded_peak: float = _max_val(res_shield["height"])
	var peak_retention: float = (eroded_peak / orig_peak) * 100.0

	print("    Original peak: %.2f m | Eroded peak: %.2f m (retention: %.1f%%)" % [orig_peak, eroded_peak, peak_retention])
	if peak_retention < 95.0:
		_fail += 1
		print("    !! Mountain ridge crest was excessively flattened")


func _test_nan_boundary_invariance() -> void:
	print("\n[D] NaN Boundary Invariance")
	var gw := 16
	var gh := 16
	var rect := Rect2(0, 0, 50, 50)
	var arr := PackedFloat32Array()
	arr.resize(gw * gh)
	for iz in range(gh):
		for ix in range(gw):
			if ix == 0 or iz == 0:
				arr[iz * gw + ix] = NAN
			else:
				arr[iz * gw + ix] = 10.0

	var res: Dictionary = Pasture3DUtil.hydraulic_saleve_solve_grid(arr, gw, gh, rect, {
		"iterations": 5,
		"incision_rate": 0.2,
		"joint_azimuth": 45.0,
		"joint_strength": 0.5,
		"ridge_preservation": 0.8,
		"deposition_rate": 0.3,
	})

	var nan_ok := true
	var h_out: PackedFloat32Array = res["height"]
	for iz in range(gh):
		for ix in range(gw):
			if ix == 0 or iz == 0:
				if is_finite(h_out[iz * gw + ix]):
					nan_ok = false

	print("    NaN boundary preserved = %s" % str(nan_ok))
	if not nan_ok:
		_fail += 1
		print("    !! NaN boundary cells were corrupted")


# --- Helpers ---

func _create_mountain_dome(gw: int, gh: int, peak_h: float) -> PackedFloat32Array:
	var arr := PackedFloat32Array()
	arr.resize(gw * gh)
	var cx := float(gw) * 0.5
	var cz := float(gh) * 0.5
	var rad := float(gw) * 0.45
	for iz in range(gh):
		for ix in range(gw):
			var dist := sqrt(pow(float(ix) - cx, 2.0) + pow(float(iz) - cz, 2.0))
			var t := clampf(1.0 - (dist / rad), 0.0, 1.0)
			arr[iz * gw + ix] = peak_h * (t * t * (3.0 - 2.0 * t))
	return arr


func _max_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var md: float = 0.0
	for i in range(mini(a.size(), b.size())):
		if is_finite(a[i]) and is_finite(b[i]):
			md = maxf(md, absf(a[i] - b[i]))
	return md


func _max_val(a: PackedFloat32Array) -> float:
	var mv: float = -INF
	for v in a:
		if is_finite(v) and v > mv:
			mv = v
	return mv
