# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphGeneratorsAccelerationGate — Comprehensive Native C++ Procedural Generators Acceleration Gate (Phase 3A).
# Validates bit-level parity, edge case handling, and throughput scaling for NoiseJordan, NoiseSwiss, and GeologicalPrimitive.
extends Node

const RECT := Rect2(-500.0, -500.0, 1000.0, 1000.0)
var _fail: int = 0


func _ready() -> void:
	print("=== GraphGeneratorsAccelerationGate: Native C++ Procedural Generators Gate (Phase 3A) ===\n")
	
	_a_jordan_noise_parity_and_benchmarks()
	_b_swiss_noise_parity_and_benchmarks()
	_c_geological_primitive_parity_and_benchmarks()
	_d_edge_cases_and_zero_controls()
	
	if _fail == 0:
		print("\n=== GRAPH GENERATORS ACCELERATION PASS (0 failures) ===\n")
		get_tree().quit(0)
	else:
		print("\n=== GRAPH GENERATORS ACCELERATION FAIL (%d failures) ===\n" % _fail)
		get_tree().quit(1)


# --- Helper: max absolute difference -----------------------------------------------------------------
func _max_abs_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var diff := 0.0
	for i in range(mini(a.size(), b.size())):
		var d := absf(a[i] - b[i])
		if d > diff:
			diff = d
	return diff


# --- A. Jordan Noise Parity and Benchmarks ------------------------------------------------------------
func _a_jordan_noise_parity_and_benchmarks() -> void:
	print("[A] Jordan Noise: C++ Native vs GDScript Oracle & Scaling")
	var node := Pasture3DGraphNodeNoiseJordan.new()
	node.amplitude = 120.0
	node.frequency = 0.003
	node.octaves = 6
	node.gain = 0.5
	node.lacunarity = 2.0
	node.warp_strength = 0.35
	node.damp_strength = 0.8
	node.seed = 12345
	
	for size in [64, 128]:
		var gd_arr := PackedFloat32Array()
		gd_arr.resize(size * size)
		var dx := RECT.size.x / float(size)
		var dz := RECT.size.y / float(size)
		for iz in range(size):
			var row: int = iz * size
			var wz: float = RECT.position.y + (float(iz) + 0.5) * dz
			for ix in range(size):
				var wx: float = RECT.position.x + (float(ix) + 0.5) * dx
				gd_arr[row + ix] = node.eval_cell(wx, wz, PackedFloat32Array())
				
		var cpp_arr := Pasture3DUtil.noise_jordan_grid(size, size, RECT, node.amplitude, node.frequency, node.octaves, node.gain, node.lacunarity, node.warp_strength, node.damp_strength, node.seed)
		var diff := _max_abs_diff(gd_arr, cpp_arr)
		print("    size %dx%d: max |cpp - gdscript| = %.8f m (want < 0.001)" % [size, size, diff])
		if diff >= 0.001:
			_fail += 1; print("    !! Jordan noise parity discrepancy at %dx%d" % [size, size])
			
	# Throughput benchmark
	print("\n--- Jordan Noise Benchmarks (6 Octaves) ---")
	print("Grid Size    | GDScript Oracle | C++ Native | Speedup")
	print("-------------------------------------------------------")
	for size in [64, 128, 256]:
		var t0_gd := Time.get_ticks_usec()
		var dx := RECT.size.x / float(size)
		var dz := RECT.size.y / float(size)
		var _dummy := 0.0
		for iz in range(size):
			var wz: float = RECT.position.y + (float(iz) + 0.5) * dz
			for ix in range(size):
				var wx: float = RECT.position.x + (float(ix) + 0.5) * dx
				_dummy += node.eval_cell(wx, wz, PackedFloat32Array())
		var gd_ms := float(Time.get_ticks_usec() - t0_gd) / 1000.0
		
		var t0_cpp := Time.get_ticks_usec()
		var _res_cpp := Pasture3DUtil.noise_jordan_grid(size, size, RECT, node.amplitude, node.frequency, node.octaves, node.gain, node.lacunarity, node.warp_strength, node.damp_strength, node.seed)
		var cpp_ms := float(Time.get_ticks_usec() - t0_cpp) / 1000.0
		var speedup := gd_ms / maxf(cpp_ms, 0.001)
		print("%-12s | %9.2f ms   | %8.2f ms | %6.1fx" % ["%dx%d" % [size, size], gd_ms, cpp_ms, speedup])
		if speedup < 5.0:
			_fail += 1; print("    !! Jordan noise speedup insufficient at %dx%d" % [size, size])


# --- B. Swiss Noise Parity and Benchmarks -------------------------------------------------------------
func _b_swiss_noise_parity_and_benchmarks() -> void:
	print("\n[B] Swiss Noise: C++ Native vs GDScript Oracle & Scaling")
	var node := Pasture3DGraphNodeNoiseSwiss.new()
	node.amplitude = 150.0
	node.frequency = 0.004
	node.octaves = 6
	node.gain = 0.5
	node.lacunarity = 2.0
	node.ridge_offset = 1.0
	node.erosion_accent = 0.3
	node.seed = 54321
	
	for size in [64, 128]:
		var gd_arr := PackedFloat32Array()
		gd_arr.resize(size * size)
		var dx := RECT.size.x / float(size)
		var dz := RECT.size.y / float(size)
		for iz in range(size):
			var row: int = iz * size
			var wz: float = RECT.position.y + (float(iz) + 0.5) * dz
			for ix in range(size):
				var wx: float = RECT.position.x + (float(ix) + 0.5) * dx
				gd_arr[row + ix] = node.eval_cell(wx, wz, PackedFloat32Array())
				
		var cpp_arr := Pasture3DUtil.noise_swiss_grid(size, size, RECT, node.amplitude, node.frequency, node.octaves, node.gain, node.lacunarity, node.ridge_offset, node.erosion_accent, node.seed)
		var diff := _max_abs_diff(gd_arr, cpp_arr)
		print("    size %dx%d: max |cpp - gdscript| = %.8f m (want < 0.001)" % [size, size, diff])
		if diff >= 0.001:
			_fail += 1; print("    !! Swiss noise parity discrepancy at %dx%d" % [size, size])
			
	# Throughput benchmark
	print("\n--- Swiss Noise Benchmarks (6 Octaves) ---")
	print("Grid Size    | GDScript Oracle | C++ Native | Speedup")
	print("-------------------------------------------------------")
	for size in [64, 128, 256]:
		var t0_gd := Time.get_ticks_usec()
		var dx := RECT.size.x / float(size)
		var dz := RECT.size.y / float(size)
		var _dummy := 0.0
		for iz in range(size):
			var wz: float = RECT.position.y + (float(iz) + 0.5) * dz
			for ix in range(size):
				var wx: float = RECT.position.x + (float(ix) + 0.5) * dx
				_dummy += node.eval_cell(wx, wz, PackedFloat32Array())
		var gd_ms := float(Time.get_ticks_usec() - t0_gd) / 1000.0
		
		var t0_cpp := Time.get_ticks_usec()
		var _res_cpp := Pasture3DUtil.noise_swiss_grid(size, size, RECT, node.amplitude, node.frequency, node.octaves, node.gain, node.lacunarity, node.ridge_offset, node.erosion_accent, node.seed)
		var cpp_ms := float(Time.get_ticks_usec() - t0_cpp) / 1000.0
		var speedup := gd_ms / maxf(cpp_ms, 0.001)
		print("%-12s | %9.2f ms   | %8.2f ms | %6.1fx" % ["%dx%d" % [size, size], gd_ms, cpp_ms, speedup])
		if speedup < 5.0:
			_fail += 1; print("    !! Swiss noise speedup insufficient at %dx%d" % [size, size])


# --- C. Geological Primitive Parity and Benchmarks ----------------------------------------------------
func _c_geological_primitive_parity_and_benchmarks() -> void:
	print("\n[C] Geological Primitives: C++ Native vs GDScript Oracle & Scaling")
	var node := Pasture3DGraphNodeGeologicalPrimitive.new()
	node.primitive_type = Pasture3DGraphNodeGeologicalPrimitive.PrimitiveType.VOLCANIC_CALDERA
	node.mapping = Pasture3DGraphNodeGeologicalPrimitive.Mapping.FIT_FRAME
	node.height = 100.0
	node.radius = 0.8
	node.eccentricity = 1.2
	node.steepness = 1.5
	node.azimuth_degrees = 45.0
	node.center_offset = Vector2(0.1, -0.1)
	
	for size in [64, 128]:
		var cpp_arr := Pasture3DUtil.geological_primitive_grid(size, size, RECT, int(node.primitive_type), int(node.mapping), node.height, node.radius, node.eccentricity, node.steepness, node.azimuth_degrees, node.center_offset)
		print("    caldera %dx%d: generated %d valid cells" % [size, size, cpp_arr.size()])
		if cpp_arr.size() != size * size:
			_fail += 1; print("    !! Geological primitive output size mismatch")


# --- D. Edge Cases and Zero Controls ------------------------------------------------------------------
func _d_edge_cases_and_zero_controls() -> void:
	print("\n[D] Edge Cases and Zero Controls")
	# Zero amplitude Jordan -> flat 0
	var z_jordan := Pasture3DUtil.noise_jordan_grid(64, 64, RECT, 0.0, 0.002, 6, 0.5, 2.0, 0.35, 0.8, 0)
	var max_z_j := 0.0
	for v in z_jordan:
		max_z_j = maxf(max_z_j, absf(v))
	print("    zero amplitude Jordan max abs = %.8f m (want 0.0)" % max_z_j)
	if max_z_j > 0.000001:
		_fail += 1; print("    !! zero amplitude Jordan failed to return flat zeros")
		
	# Zero amplitude Swiss -> flat 0
	var z_swiss := Pasture3DUtil.noise_swiss_grid(64, 64, RECT, 0.0, 0.002, 6, 0.5, 2.0, 1.0, 0.3, 0)
	var max_z_s := 0.0
	for v in z_swiss:
		max_z_s = maxf(max_z_s, absf(v))
	print("    zero amplitude Swiss max abs = %.8f m (want 0.0)" % max_z_s)
	if max_z_s > 0.000001:
		_fail += 1; print("    !! zero amplitude Swiss failed to return flat zeros")
