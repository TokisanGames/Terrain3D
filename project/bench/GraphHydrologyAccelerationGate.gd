# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphHydrologyAccelerationGate — Parity & Performance Benchmarking for Phase 2 Hydrology Solvers.
#
# Covers:
#   [A] DepressionFilling: C++ Priority-Flood vs GDScript oracle.
#   [B] LakeFlooding: C++ Basin Inundation & Shoreline vs GDScript oracle.
#   [C] StreamExtraction: C++ D8 Flow Accumulation & River Carving vs GDScript oracle.
#   [D] Performance Benchmarks across grid scales (128^2, 512^2, 1024^2).
extends Node

const EPS := 1.0e-4

var _fail := 0


func _ready() -> void:
	print("=== GraphHydrologyAccelerationGate: Native Hydrology & Priority-Flood Gate ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "depression_filling_grid"):
		print("!! Pasture3DUtil.depression_filling_grid missing — extension binary needs rebuild.")
		_fail += 1
		_finish()
		return

	_test_a_depression_filling_parity()
	_test_b_lake_flooding_parity()
	_test_c_stream_extraction_parity()
	_run_benchmarks()

	_finish()


func _finish() -> void:
	print("\n=== %s (%d failures) ===\n" % [
		"GRAPH HYDROLOGY ACCELERATION PASS" if _fail == 0 else "GRAPH HYDROLOGY ACCELERATION FAIL",
		_fail
	])
	get_tree().quit(0 if _fail == 0 else 1)


# --- Section A: DepressionFilling Parity -------------------------------------------------------------
func _test_a_depression_filling_parity() -> void:
	print("[A] DepressionFilling: C++ Native vs GDScript Priority-Flood Oracle")
	var gw := 64
	var gh := 64
	var rect := Rect2(-50.0, -50.0, 100.0, 100.0)
	var surf := _make_crater_surface(gw, gh)

	var node := Pasture3DGraphNodeDevDepressionFilling.new()
	node.epsilon_slope = 0.001
	node.fill_depth_limit = 5.0
	node.amount = 0.8

	var gd_res: PackedFloat32Array = node._eval_grid_gdscript(surf, gw, gh, rect)
	var cpp_res: PackedFloat32Array = Pasture3DUtil.depression_filling_grid(surf, gw, gh, rect,
			node.epsilon_slope, node.fill_depth_limit, node.amount)

	var diff := _max_abs_diff(gd_res, cpp_res)
	var max_i := -1
	var m := 0.0
	for i in range(gw * gh):
		var d := absf(gd_res[i] - cpp_res[i])
		if d > m:
			m = d
			max_i = i
	if max_i >= 0:
		print("    max diff at [%d, %d]: surf=%.2f, gd=%.2f, cpp=%.2f" % [
			max_i % gw, max_i / gw, surf[max_i], gd_res[max_i], cpp_res[max_i]
		])
	print("    DepressionFilling max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff, EPS])
	if diff > EPS:
		_fail += 1
		print("    !! C++ depression_filling_grid diverged from GDScript oracle")


# --- Section B: LakeFlooding Parity ------------------------------------------------------------------
func _test_b_lake_flooding_parity() -> void:
	print("\n[B] LakeFlooding: C++ Native vs GDScript Basin Inundation Oracle")
	var gw := 64
	var gh := 64
	var rect := Rect2(-50.0, -50.0, 100.0, 100.0)
	var surf := _make_crater_surface(gw, gh)

	var node := Pasture3DGraphNodeDevLakeFlooding.new()
	node.flood_mode = Pasture3DGraphNodeDevLakeFlooding.FloodMode.SPILLWAY_BASIN
	node.flood_percent = 0.75
	node.shoreline_width = 6.0

	var gd_res: Array = node._solve_gdscript(surf, gw, gh, rect)
	var cpp_res: Dictionary = Pasture3DUtil.lake_flooding_grid(surf, gw, gh, rect,
			int(node.flood_mode), node.water_elevation, node.flood_percent, node.shoreline_width)

	var diff_h := _max_abs_diff(gd_res[0], cpp_res["height"])
	var diff_d := _max_abs_diff(gd_res[1], cpp_res["water_depth"])
	var diff_s := _max_abs_diff(gd_res[2], cpp_res["shoreline"])

	print("    Lake height max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_h, EPS])
	print("    Lake depth  max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_d, EPS])
	print("    Lake shore  max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_s, EPS])

	if diff_h > EPS or diff_d > EPS or diff_s > EPS:
		_fail += 1
		print("    !! C++ lake_flooding_grid diverged from GDScript oracle")


# --- Section C: StreamExtraction Parity --------------------------------------------------------------
func _test_c_stream_extraction_parity() -> void:
	print("\n[C] StreamExtraction: C++ Native vs GDScript Flow Routing Oracle")
	var gw := 64
	var gh := 64
	var rect := Rect2(-50.0, -50.0, 100.0, 100.0)
	var surf := _make_valley_surface(gw, gh)

	var node := Pasture3DGraphNodeDevStreamExtraction.new()
	node.min_catchment_cells = 16.0
	node.carve_depth = 3.5
	node.channel_width = 8.0
	node.bank_falloff = 4.0

	var gd_res: Array = node._solve_gdscript(surf, gw, gh, rect)
	var cpp_res: Dictionary = Pasture3DUtil.stream_extraction_grid(surf, gw, gh, rect,
			node.min_catchment_cells, node.carve_depth, node.channel_width, node.bank_falloff)

	var diff_h := _max_abs_diff(gd_res[0], cpp_res["height"])
	var diff_c := _max_abs_diff(gd_res[1], cpp_res["channel_mask"])
	var diff_f := _max_abs_diff(gd_res[2], cpp_res["flow_rate"])

	print("    Stream height  max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_h, EPS])
	print("    Stream channel max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_c, EPS])
	print("    Stream flow    max |cpp - gdscript| = %.9f (want <= %.7f)" % [diff_f, EPS])

	if diff_h > EPS or diff_c > EPS or diff_f > EPS:
		_fail += 1
		print("    !! C++ stream_extraction_grid diverged from GDScript oracle")


# --- Section D: Performance Benchmarks --------------------------------------------------------------
func _run_benchmarks() -> void:
	print("\n[D] Performance Benchmarks across Grid Scales")
	var rect := Rect2(-500.0, -500.0, 1000.0, 1000.0)

	print("\n--- 1. DepressionFilling Benchmarks ---")
	print("Grid Size    | GDScript     | C++ Native   | Speedup")
	print("-------------------------------------------------------")
	_bench_df(128, rect)
	_bench_df(512, rect)
	_bench_df(1024, rect, true)

	print("\n--- 2. LakeFlooding Benchmarks ---")
	print("Grid Size    | GDScript     | C++ Native   | Speedup")
	print("-------------------------------------------------------")
	_bench_lf(128, rect)
	_bench_lf(512, rect)
	_bench_lf(1024, rect, true)

	print("\n--- 3. StreamExtraction Benchmarks ---")
	print("Grid Size    | GDScript     | C++ Native   | Speedup")
	print("-------------------------------------------------------")
	_bench_se(128, rect)
	_bench_se(512, rect)
	_bench_se(1024, rect, true)


func _bench_df(dim: int, rect: Rect2, skip_slow_gd: bool = false) -> void:
	var surf := _make_crater_surface(dim, dim)
	var df_node := Pasture3DGraphNodeDevDepressionFilling.new()

	var t0: int
	var t_gd: float = 0.0

	if not skip_slow_gd:
		t0 = Time.get_ticks_usec()
		var _r1 := df_node._eval_grid_gdscript(surf, dim, dim, rect)
		t_gd = float(Time.get_ticks_usec() - t0) / 1000.0

	t0 = Time.get_ticks_usec()
	var _r2 := Pasture3DUtil.depression_filling_grid(surf, dim, dim, rect, 0.0001, 0.0, 1.0)
	var t_cpp := float(Time.get_ticks_usec() - t0) / 1000.0

	if skip_slow_gd:
		print("%-12s | (est ~4.5s)  | %-12s | ~50x+ (est)" % [
			"%dx%d" % [dim, dim],
			"%.2f ms" % t_cpp
		])
	else:
		var speedup := t_gd / maxf(t_cpp, 0.001)
		print("%-12s | %-12s | %-12s | %.1fx" % [
			"%dx%d" % [dim, dim],
			"%.2f ms" % t_gd,
			"%.2f ms" % t_cpp,
			speedup
		])


func _bench_lf(dim: int, rect: Rect2, skip_slow_gd: bool = false) -> void:
	var surf := _make_crater_surface(dim, dim)
	var lf_node := Pasture3DGraphNodeDevLakeFlooding.new()

	var t0: int
	var t_gd: float = 0.0

	if not skip_slow_gd:
		t0 = Time.get_ticks_usec()
		var _r1 := lf_node._solve_gdscript(surf, dim, dim, rect)
		t_gd = float(Time.get_ticks_usec() - t0) / 1000.0

	t0 = Time.get_ticks_usec()
	var _r2 := Pasture3DUtil.lake_flooding_grid(surf, dim, dim, rect, 0, 10.0, 1.0, 4.0)
	var t_cpp := float(Time.get_ticks_usec() - t0) / 1000.0

	if skip_slow_gd:
		print("%-12s | (est ~5.0s)  | %-12s | ~50x+ (est)" % [
			"%dx%d" % [dim, dim],
			"%.2f ms" % t_cpp
		])
	else:
		var speedup := t_gd / maxf(t_cpp, 0.001)
		print("%-12s | %-12s | %-12s | %.1fx" % [
			"%dx%d" % [dim, dim],
			"%.2f ms" % t_gd,
			"%.2f ms" % t_cpp,
			speedup
		])


func _bench_se(dim: int, rect: Rect2, skip_slow_gd: bool = false) -> void:
	var surf := _make_valley_surface(dim, dim)
	var se_node := Pasture3DGraphNodeDevStreamExtraction.new()

	var t0: int
	var t_gd: float = 0.0

	if not skip_slow_gd:
		t0 = Time.get_ticks_usec()
		var _r1 := se_node._solve_gdscript(surf, dim, dim, rect)
		t_gd = float(Time.get_ticks_usec() - t0) / 1000.0

	t0 = Time.get_ticks_usec()
	var _r2 := Pasture3DUtil.stream_extraction_grid(surf, dim, dim, rect, 24.0, 3.0, 8.0, 4.0)
	var t_cpp := float(Time.get_ticks_usec() - t0) / 1000.0

	if skip_slow_gd:
		print("%-12s | (est ~6.0s)  | %-12s | ~50x+ (est)" % [
			"%dx%d" % [dim, dim],
			"%.2f ms" % t_cpp
		])
	else:
		var speedup := t_gd / maxf(t_cpp, 0.001)
		print("%-12s | %-12s | %-12s | %.1fx" % [
			"%dx%d" % [dim, dim],
			"%.2f ms" % t_gd,
			"%.2f ms" % t_cpp,
			speedup
		])


# --- Test Helpers -----------------------------------------------------------------------------------
func _make_crater_surface(gw: int, gh: int) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(gw * gh)
	var cx := gw * 0.5
	var cz := gh * 0.5
	var max_r := gw * 0.4
	for iz in range(gh):
		for ix in range(gw):
			var d := sqrt((ix - cx) * (ix - cx) + (iz - cz) * (iz - cz))
			var norm_d := clampf(d / max_r, 0.0, 1.0)
			# Bowl with rim at 20m, bottom at 5m, rim drop to 15m outside
			var h: float
			if norm_d < 0.7:
				h = lerpf(5.0, 20.0, norm_d / 0.7)
			else:
				h = lerpf(20.0, 15.0, (norm_d - 0.7) / 0.3)
			s[iz * gw + ix] = h
	return s


func _make_valley_surface(gw: int, gh: int) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(gw * gh)
	var cx := gw * 0.5
	for iz in range(gh):
		for ix in range(gw):
			var dist_center := absf(float(ix) - cx) / cx
			var base_slope := float(iz) / float(gh) * 15.0
			var valley_v := dist_center * 25.0
			s[iz * gw + ix] = base_slope + valley_v
	return s


func _max_abs_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var m: float = 0.0
	var n := mini(a.size(), b.size())
	for i in range(n):
		if is_finite(a[i]) and is_finite(b[i]):
			var diff := absf(a[i] - b[i])
			if diff > m:
				m = diff
		elif is_finite(a[i]) != is_finite(b[i]):
			return INF
	return m
