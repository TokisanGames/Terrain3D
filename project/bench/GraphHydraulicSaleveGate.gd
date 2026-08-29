# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphHydraulicSaleveGate: Parity & Regression test for Salève Large-Scale Drainage Erosion.
# Tests C++ Native vs GDScript Tier 1 oracle bit-level equivalence, dendritic tributary branching,
# fine rill incision, shape preservation, and sediment mask tracking.

extends Node

const DevHydraulicSaleve = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_hydraulic_saleve.gd")

const EPS_SINGLE_PASS := 1.0e-5
const EPS_MULTI_PASS := 0.01

var _fail := 0


func _ready() -> void:
	print("=== GraphHydraulicSaleveGate: Salève Large-Scale Drainage Erosion Gate ===\n")
	_test_single_pass_parity()
	_test_multi_pass_parity()
	_test_alluvial_sediment_deposition()
	_test_fine_stream_incision()
	_test_dx_dy_domain_distortion()
	_test_post_processing()
	_test_mountain_shape_preservation()
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
		"erosion_strength": 0.7,
		"drainage_exponent": 0.2,
		"drainage_noise": 0.15,
		"shape_preservation": 2.0,
		"bank_smoothing": 0.1,
		"deposition_radius": 0.1,
		"deposition_strength": 0.5,
		"stream_strength": 0.02,
		"stream_exp": 0.8,
		"gain": 1.0,
		"gamma": 1.0,
		"mix_factor": 1.0,
		"seed": 42,
	}

	var res_gd: Array = DevHydraulicSaleve.solve_gd(surface, gw, gh, rect, params)
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
		"erosion_strength": 0.7,
		"drainage_exponent": 0.2,
		"drainage_noise": 0.15,
		"shape_preservation": 2.0,
		"bank_smoothing": 0.1,
		"deposition_radius": 0.1,
		"deposition_strength": 0.5,
		"stream_strength": 0.02,
		"stream_exp": 0.8,
		"gain": 1.0,
		"gamma": 1.0,
		"mix_factor": 1.0,
		"seed": 1337,
	}

	var res_gd: Array = DevHydraulicSaleve.solve_gd(surface, gw, gh, rect, params)
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


func _test_alluvial_sediment_deposition() -> void:
	print("\n[B] Stage 2: Alluvial Sediment Deposition & Hole Filling")
	var gw := 48
	var gh := 48
	var rect := Rect2(0, 0, 100, 100)
	var surface := _create_mountain_dome(gw, gh, 30.0)

	var res: Dictionary = Pasture3DUtil.hydraulic_saleve_solve_grid(surface, gw, gh, rect, {
		"iterations": 10,
		"erosion_strength": 0.7,
		"deposition_radius": 0.15,
		"deposition_strength": 0.6,
		"seed": 101,
	})

	var max_sed: float = _max_val(res["sediment"])
	print("    Max alluvial sediment thickness = %.4f m (want > 0.5 m)" % max_sed)
	if max_sed < 0.5:
		_fail += 1
		print("    !! Insufficient alluvial sediment deposition")


func _test_fine_stream_incision() -> void:
	print("\n[C] Stage 3: Fine Dendritic River Channel Incision")
	var gw := 48
	var gh := 48
	var rect := Rect2(0, 0, 100, 100)
	var surface := _create_mountain_dome(gw, gh, 30.0)

	var res_base: Dictionary = Pasture3DUtil.hydraulic_saleve_solve_grid(surface, gw, gh, rect, {
		"iterations": 10,
		"erosion_strength": 0.7,
		"stream_strength": 0.0,
		"seed": 202,
	})

	var res_stream: Dictionary = Pasture3DUtil.hydraulic_saleve_solve_grid(surface, gw, gh, rect, {
		"iterations": 10,
		"erosion_strength": 0.7,
		"stream_strength": 0.05,
		"stream_exp": 0.8,
		"seed": 202,
	})

	var diff := _max_diff(res_base["height"], res_stream["height"])
	print("    Fine stream delta vs uncarved = %.4f m (want > 0.2 m)" % diff)
	if diff < 0.2:
		_fail += 1
		print("    !! Fine stream power pass did not carve sufficient couloirs")


func _test_dx_dy_domain_distortion() -> void:
	print("\n[D] Stage 1: Domain Coordinate Distortion (dx / dy)")
	var gw := 48
	var gh := 48
	var rect := Rect2(0, 0, 100, 100)
	var surface := _create_mountain_dome(gw, gh, 30.0)

	var dx_arr := PackedFloat32Array()
	dx_arr.resize(gw * gh)
	var dy_arr := PackedFloat32Array()
	dy_arr.resize(gw * gh)
	for iz in range(gh):
		for ix in range(gw):
			dx_arr[iz * gw + ix] = sin(float(iz) * 0.3) * 0.5
			dy_arr[iz * gw + ix] = cos(float(ix) * 0.3) * 0.5

	var res_straight: Dictionary = Pasture3DUtil.hydraulic_saleve_solve_grid(surface, gw, gh, rect, {
		"iterations": 10,
		"erosion_strength": 0.7,
		"seed": 303,
	})

	var res_warped: Dictionary = Pasture3DUtil.hydraulic_saleve_solve_grid(surface, gw, gh, rect, {
		"iterations": 10,
		"erosion_strength": 0.7,
		"dx": dx_arr,
		"dy": dy_arr,
		"seed": 303,
	})

	var diff := _max_diff(res_straight["height"], res_warped["height"])
	print("    dx/dy warped drainage delta = %.4f m (want > 0.5 m)" % diff)
	if diff < 0.5:
		_fail += 1
		print("    !! dx/dy domain distortion did not influence drainage routing")


func _test_post_processing() -> void:
	print("\n[E] Stage 4: Post-Processing & Tonal Curve Controls")
	var gw := 32
	var gh := 32
	var rect := Rect2(0, 0, 100, 100)
	var surface := _create_mountain_dome(gw, gh, 30.0)

	var res_gamma: Dictionary = Pasture3DUtil.hydraulic_saleve_solve_grid(surface, gw, gh, rect, {
		"iterations": 5,
		"erosion_strength": 0.8,
		"gamma": 1.5,
		"gain": 1.2,
		"seed": 404,
	})

	var res_flat: Dictionary = Pasture3DUtil.hydraulic_saleve_solve_grid(surface, gw, gh, rect, {
		"iterations": 5,
		"erosion_strength": 0.8,
		"gamma": 1.0,
		"gain": 1.0,
		"seed": 404,
	})

	var diff := _max_diff(res_gamma["height"], res_flat["height"])
	print("    Post-process curve delta = %.4f m (want > 1.0 m)" % diff)
	if diff < 1.0:
		_fail += 1
		print("    !! Post-processing tonal curve was not applied")


func _test_mountain_shape_preservation() -> void:
	print("\n[F] Mountain Shape Preservation")
	var gw := 48
	var gh := 48
	var rect := Rect2(0, 0, 100, 100)
	var surface := _create_mountain_dome(gw, gh, 30.0)

	var res: Dictionary = Pasture3DUtil.hydraulic_saleve_solve_grid(surface, gw, gh, rect, {
		"iterations": 25,
		"erosion_strength": 0.7,
		"drainage_exponent": 0.2,
		"drainage_noise": 0.15,
		"shape_preservation": 2.0,
		"bank_smoothing": 0.1,
	})

	var orig_peak: float = _max_val(surface)
	var eroded_peak: float = _max_val(res["height"])
	var peak_retention: float = (eroded_peak / orig_peak) * 100.0

	print("    Original peak: %.2f m | Eroded peak: %.2f m (retention: %.1f%%)" % [orig_peak, eroded_peak, peak_retention])
	if peak_retention < 85.0:
		_fail += 1
		print("    !! Mountain peak was excessively collapsed")


func _test_nan_boundary_invariance() -> void:
	print("\n[G] NaN Boundary Invariance")
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
		"erosion_strength": 0.7,
		"drainage_exponent": 0.2,
		"drainage_noise": 0.15,
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
