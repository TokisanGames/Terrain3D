# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphGeomorphologyAccelerationGate — Headless parity gate and throughput benchmark for Phase 3
# geomorphological and structural shaping solvers (PASTURE3D_SOLVER_NATIVE_ACCELERATION_SPEC.md §4 Phase 3).

extends Node

const TOLERANCE: float = 0.0001
var _failures: int = 0


func _ready() -> void:
	print("\n=== GraphGeomorphologyAccelerationGate: Native Geomorphology & Filtering Gate ===\n")
	_test_a_erosion_thermal_parity()
	_test_b_talus_projection_parity()
	_test_c_spectral_equalizer_parity()
	_test_d_curvature_parity()
	_test_e_warp_parity()
	_run_benchmarks()

	if _failures == 0:
		print("\n=== GRAPH GEOMORPHOLOGY ACCELERATION PASS (0 failures) ===\n")
		get_tree().quit(0)
	else:
		printerr("\n=== GRAPH GEOMORPHOLOGY ACCELERATION FAIL (%d failures) ===\n" % _failures)
		get_tree().quit(1)


func _assert_max_diff(p_label: String, p_a: PackedFloat32Array, p_b: PackedFloat32Array, p_tol: float = TOLERANCE) -> void:
	if p_a.size() != p_b.size():
		printerr("    FAIL: Size mismatch in %s (%d vs %d)" % [p_label, p_a.size(), p_b.size()])
		_failures += 1
		return

	var max_diff: float = 0.0
	for i in range(p_a.size()):
		var va := p_a[i]
		var vb := p_b[i]
		if is_nan(va) and is_nan(vb):
			continue
		if is_nan(va) != is_nan(vb):
			printerr("    FAIL: NaN mismatch in %s at index %d" % [p_label, i])
			_failures += 1
			return
		max_diff = maxf(max_diff, absf(va - vb))

	print("    %s max |cpp - gdscript| = %.9f (want <= %.7f)" % [p_label, max_diff, p_tol])
	if max_diff > p_tol:
		printerr("    !! C++ %s diverged from GDScript oracle" % p_label)
		_failures += 1


func _generate_cliff_grid(gw: int, gh: int) -> PackedFloat32Array:
	var grid := PackedFloat32Array()
	grid.resize(gw * gh)
	for iz in range(gh):
		for ix in range(gw):
			var dist := sqrt(float((ix - gw / 2) * (ix - gw / 2) + (iz - gh / 2) * (iz - gh / 2)))
			var val := clampf(50.0 - dist * 2.0, 0.0, 50.0)
			grid[iz * gw + ix] = val
	return grid


func _test_a_erosion_thermal_parity() -> void:
	print("[A] ErosionThermal: C++ Native vs GDScript Oracle")
	var gw := 64
	var gh := 64
	var n := gw * gh
	var surf := _generate_cliff_grid(gw, gh)
	var hardness := PackedFloat32Array()
	hardness.resize(n)
	for i in range(n):
		hardness[i] = 0.25 if (i % 3 == 0) else 0.0

	var rect := Rect2(-100, -100, 200, 200)
	var node := Pasture3DGraphNodeDevErosionThermal.new()
	node.talus_angle = 32.0
	node.iterations = 10
	node.settling_rate = 0.65

	var gd_res: Array = node._solve_gdscript(surf, hardness, gw, gh, rect)
	var cpp_dict: Dictionary = Pasture3DUtil.erosion_thermal_solve_grid(surf, hardness, gw, gh, rect, 32.0, 10, 0.65)

	_assert_max_diff("Thermal height", cpp_dict["height"], gd_res[0])
	_assert_max_diff("Thermal talus mask", cpp_dict["talus"], gd_res[1])


func _test_b_talus_projection_parity() -> void:
	print("\n[B] TalusProjection: C++ Native vs GDScript Oracle")
	var gw := 64
	var gh := 64
	var n := gw * gh
	var surf := _generate_cliff_grid(gw, gh)
	var mask := PackedFloat32Array()
	mask.resize(n)
	for i in range(n):
		mask[i] = 1.0 if (i % gw < gw / 2) else 0.5

	var rect := Rect2(-100, -100, 200, 200)
	var node := Pasture3DGraphNodeDevTalusProjection.new()
	node.talus_angle_deg = 35.0
	node.iterations = 12
	node.transfer_rate = 0.5
	node.amount = 0.85

	var gd_res: PackedFloat32Array = node._eval_grid_gdscript(surf, mask, gw, gh, rect)
	var cpp_res: PackedFloat32Array = Pasture3DUtil.talus_projection_grid(surf, mask, gw, gh, rect, 35.0, 12, 0.5, 0.85)

	_assert_max_diff("Talus projection height", cpp_res, gd_res)


func _test_c_spectral_equalizer_parity() -> void:
	print("\n[C] SpectralEqualizer: C++ Native vs GDScript Oracle")
	var gw := 64
	var gh := 64
	var n := gw * gh
	var surf := _generate_cliff_grid(gw, gh)
	var mask := PackedFloat32Array()
	mask.resize(n)
	mask.fill(1.0)

	var node := Pasture3DGraphNodeDevSpectralEqualizer.new()
	node.macro_gain = 1.5
	node.meso_gain = 0.8
	node.micro_gain = 2.0
	node.macro_passes = 12
	node.meso_passes = 3
	node.amount = 0.9

	var gd_res: PackedFloat32Array = node._eval_grid_gdscript(surf, mask, gw, gh)
	var cpp_res: PackedFloat32Array = Pasture3DUtil.spectral_equalizer_grid(surf, mask, gw, gh, 1.5, 0.8, 2.0, 12, 3, 0.9)

	_assert_max_diff("Spectral equalizer height", cpp_res, gd_res)


func _test_d_curvature_parity() -> void:
	print("\n[D] Curvature: C++ Native vs GDScript Oracle")
	var gw := 64
	var gh := 64
	var surf := _generate_cliff_grid(gw, gh)
	var node := Pasture3DGraphNodeDevCurvature.new()
	node.radius = 2
	node.contrast = 1.5

	for mode_idx in [0, 1, 2]:
		node.mode = mode_idx as Pasture3DGraphNodeDevCurvature.Mode
		var mode_name := "RIDGE" if mode_idx == 0 else ("VALLEY" if mode_idx == 1 else "TOTAL")
		var gd_res: PackedFloat32Array = node._eval_grid_gdscript(surf, gw, gh)
		var cpp_res: PackedFloat32Array = Pasture3DUtil.curvature_grid(surf, gw, gh, mode_idx, 2, 1.5)
		_assert_max_diff("Curvature (%s)" % mode_name, cpp_res, gd_res)


func _test_e_warp_parity() -> void:
	print("\n[E] Warp: C++ Native vs GDScript Oracle")
	var gw := 64
	var gh := 64
	var n := gw * gh
	var surf := _generate_cliff_grid(gw, gh)
	var rect := Rect2(-100, -100, 200, 200)

	var node := Pasture3DGraphNodeWarp.new()
	node.warp_type = Pasture3DGraphNodeWarp.WarpType.FRACTAL
	node.frequency = 0.02
	node.strength = 15.0
	node.octaves = 3
	node.amplitude = 10.0
	node.roughness = 0.5
	node.seed = 12345

	var gd_res := PackedFloat32Array()
	gd_res.resize(n)
	for iz in range(gh):
		for ix in range(gw):
			var i := iz * gw + ix
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, gw, gh, rect)
			gd_res[i] = node.eval_cell(w.x, w.y, PackedFloat32Array([surf[i]]))

	var cpp_res: PackedFloat32Array = Pasture3DUtil.warp_grid(surf, gw, gh, rect, 1, 0.02, 15.0, 3, 10.0, 0.5, 12345)
	_assert_max_diff("Warp height", cpp_res, gd_res)


func _run_benchmarks() -> void:
	print("\n[F] Performance Benchmarks across Grid Scales\n")
	var scales: Array = [128, 512]
	var rect := Rect2(-256, -256, 512, 512)

	print("--- 1. ErosionThermal Benchmarks (10 Iterations) ---")
	print("%-12s | %-12s | %-12s | %-12s" % ["Grid Size", "GDScript", "C++ Native", "Speedup"])
	print("-------------------------------------------------------")
	for sz in scales:
		var n: int = sz * sz
		var surf := _generate_cliff_grid(sz, sz)
		var hardness := PackedFloat32Array(); hardness.resize(n); hardness.fill(0.0)
		var node := Pasture3DGraphNodeDevErosionThermal.new()
		node.talus_angle = 32.0; node.iterations = 10; node.settling_rate = 0.65

		var t0 := Time.get_ticks_usec()
		node._solve_gdscript(surf, hardness, sz, sz, rect)
		var t_gd := (Time.get_ticks_usec() - t0) / 1000.0

		var t1 := Time.get_ticks_usec()
		Pasture3DUtil.erosion_thermal_solve_grid(surf, hardness, sz, sz, rect, 32.0, 10, 0.65)
		var t_cpp := (Time.get_ticks_usec() - t1) / 1000.0

		var sp := t_gd / maxf(t_cpp, 0.001)
		print("%-12s | %8.2f ms    | %8.2f ms    | %.1fx" % ["%dx%d" % [sz, sz], t_gd, t_cpp, sp])

	print("\n--- 2. SpectralEqualizer Benchmarks ---")
	print("%-12s | %-12s | %-12s | %-12s" % ["Grid Size", "GDScript", "C++ Native", "Speedup"])
	print("-------------------------------------------------------")
	for sz in scales:
		var n: int = sz * sz
		var surf := _generate_cliff_grid(sz, sz)
		var mask := PackedFloat32Array(); mask.resize(n); mask.fill(1.0)
		var node := Pasture3DGraphNodeDevSpectralEqualizer.new()
		node.macro_gain = 1.5; node.meso_gain = 0.8; node.micro_gain = 2.0
		node.macro_passes = 12; node.meso_passes = 3; node.amount = 0.9

		var t0 := Time.get_ticks_usec()
		node._eval_grid_gdscript(surf, mask, sz, sz)
		var t_gd := (Time.get_ticks_usec() - t0) / 1000.0

		var t1 := Time.get_ticks_usec()
		Pasture3DUtil.spectral_equalizer_grid(surf, mask, sz, sz, 1.5, 0.8, 2.0, 12, 3, 0.9)
		var t_cpp := (Time.get_ticks_usec() - t1) / 1000.0

		var sp := t_gd / maxf(t_cpp, 0.001)
		print("%-12s | %8.2f ms    | %8.2f ms    | %.1fx" % ["%dx%d" % [sz, sz], t_gd, t_cpp, sp])

	print("\n--- 3. Curvature Benchmarks ---")
	print("%-12s | %-12s | %-12s | %-12s" % ["Grid Size", "GDScript", "C++ Native", "Speedup"])
	print("-------------------------------------------------------")
	for sz in scales:
		var surf := _generate_cliff_grid(sz, sz)
		var node := Pasture3DGraphNodeDevCurvature.new()
		node.radius = 2; node.contrast = 1.5

		var t0 := Time.get_ticks_usec()
		node._eval_grid_gdscript(surf, sz, sz)
		var t_gd := (Time.get_ticks_usec() - t0) / 1000.0

		var t1 := Time.get_ticks_usec()
		Pasture3DUtil.curvature_grid(surf, sz, sz, 0, 2, 1.5)
		var t_cpp := (Time.get_ticks_usec() - t1) / 1000.0

		var sp := t_gd / maxf(t_cpp, 0.001)
		print("%-12s | %8.2f ms    | %8.2f ms    | %.1fx" % ["%dx%d" % [sz, sz], t_gd, t_cpp, sp])
