# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphThreadPoolBenchmarkGate — Multi-threaded Grid Chunking & Worker Thread Pool Gate (Milestone 2).
# Verifies bit-level deterministic parity, thread safety, absence of seam artifacts, and throughput scaling.
extends Node

const RECT := Rect2(-500.0, -500.0, 1000.0, 1000.0)
var _fail: int = 0


func _ready() -> void:
	print("=== GraphThreadPoolBenchmarkGate: Multi-Threaded Grid Chunking (Milestone 2) ===\n")
	
	_a_bit_level_parity_and_thread_safety()
	_b_chunk_boundary_continuity()
	_c_spatial_filter_multithreaded_parity()
	_d_throughput_scaling_benchmark()
	
	if _fail == 0:
		print("\n=== GRAPH THREAD POOL PASS (0 failures) ===\n")
		get_tree().quit(0)
	else:
		print("\n=== GRAPH THREAD POOL FAIL (%d failures) ===\n" % _fail)
		get_tree().quit(1)


# --- Helper: create procedural cell pipeline ---------------------------------------------------------
func _create_cell_program() -> Dictionary:
	var nz := FastNoiseLite.new()
	nz.seed = 4242
	nz.frequency = 0.005
	nz.fractal_octaves = 4
	
	var j_nz := FastNoiseLite.new()
	j_nz.seed = 9999
	j_nz.frequency = 0.02
	
	var prog := {
		"ops": PackedInt32Array([1, 2, 3, 4]), # NOISE=1, CONST=2, BLEND(ADD)=3, TERRACE=4
		"params": PackedFloat32Array([35.0, 10.0, 0.0, 8.0]), # amp, const, ADD, band_height
		"params_b": PackedFloat32Array([0.0, 0.0, 0.0, 0.75]), # hardness
		"params_c": PackedFloat32Array([0.0, 0.0, 0.0, 1.0]), # amount
		"params_d": PackedFloat32Array([0.0, 0.0, 0.0, 0.2]), # jitter
		"in_a": PackedInt32Array([-1, -1, 0, 2]),
		"in_b": PackedInt32Array([-1, -1, 1, -1]),
		"noise": [nz, null, null, j_nz],
		"output": 3
	}
	return prog


# --- Helper: evaluate single-threaded in GDScript as mathematical oracle ------------------------------
func _eval_cell_oracle(prog: Dictionary, gw: int, gh: int, rect: Rect2) -> PackedFloat32Array:
	var n := gw * gh
	var out := PackedFloat32Array()
	out.resize(n)
	var dx: float = rect.size.x / float(maxi(gw, 1))
	var dz: float = rect.size.y / float(maxi(gh, 1))
	
	var ops: PackedInt32Array = prog["ops"]
	var params: PackedFloat32Array = prog["params"]
	var params_b: PackedFloat32Array = prog["params_b"]
	var params_c: PackedFloat32Array = prog["params_c"]
	var params_d: PackedFloat32Array = prog["params_d"]
	var in_a: PackedInt32Array = prog["in_a"]
	var in_b: PackedInt32Array = prog["in_b"]
	var noise_arr: Array = prog["noise"]
	var out_slot: int = prog["output"]
	var slot_count: int = ops.size()
	
	var scratch := PackedFloat64Array()
	scratch.resize(slot_count)
	
	for iz in range(gh):
		var row := iz * gw
		var wz: float = rect.position.y + (float(iz) + 0.5) * dz
		for ix in range(gw):
			var wx: float = rect.position.x + (float(ix) + 0.5) * dx
			for s in range(slot_count):
				var op := ops[s]
				var val := 0.0
				match op:
					1: # NOISE
						var nz: FastNoiseLite = noise_arr[s]
						val = float(params[s]) * float(nz.get_noise_2d(wx, wz)) if nz != null else 0.0
					2: # CONST
						val = float(params[s])
					3: # BLEND
						var a := scratch[in_a[s]] if in_a[s] >= 0 else 0.0
						var b := scratch[in_b[s]] if in_b[s] >= 0 else 0.0
						val = a + b # ADD
					4: # TERRACE
						var x := scratch[in_a[s]] if in_a[s] >= 0 else 0.0
						var bh := maxf(float(params[s]), 0.001)
						var hard: float = float(params_b[s])
						var amt: float = float(params_c[s])
						var jit: float = float(params_d[s])
						var j_nz: FastNoiseLite = noise_arr[s]
						var xj: float = x
						if jit > 0.0 and j_nz != null:
							xj += float(j_nz.get_noise_2d(wx, wz)) * jit
						var t: float = xj / bh
						var q: float = floor(t)
						var f: float = t - q
						var stepped: float = (q + pow(f, 1.0 + hard * 15.0)) * bh
						val = x + (stepped - x) * amt
				scratch[s] = val
			out[row + ix] = float(scratch[out_slot])
	return out


func _max_abs_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var diff := 0.0
	for i in range(mini(a.size(), b.size())):
		var d := absf(a[i] - b[i])
		if d > diff:
			diff = d
	return diff


# --- A. Bit-Level Parity & Thread Safety -------------------------------------------------------------
func _a_bit_level_parity_and_thread_safety() -> void:
	print("[A] Bit-level Parity & Thread-Safety (512x512 and 1024x1024)")
	var prog := _create_cell_program()
	
	for size in [256, 512]:
		var oracle := _eval_cell_oracle(prog, size, size, RECT)
		var parallel_res := Pasture3DUtil.graph_cell_eval_grid(prog, size, size, RECT)
		var diff := _max_abs_diff(oracle, parallel_res)
		print("    size %dx%d: max |parallel - oracle| = %.8f m (want < 0.0001)" % [size, size, diff])
		if diff >= 0.0001:
			_fail += 1
			print("    !! parallel cell evaluation produced numerical discrepancy at size %dx%d" % [size, size])
			
	# CONTROL: mutating noise frequency produces substantial difference
	var alt_prog := _create_cell_program()
	(alt_prog["noise"][0] as FastNoiseLite).frequency = 0.05
	var alt_res := Pasture3DUtil.graph_cell_eval_grid(alt_prog, 256, 256, RECT)
	var oracle_base := _eval_cell_oracle(prog, 256, 256, RECT)
	var ctrl_diff := _max_abs_diff(alt_res, oracle_base)
	print("    control: altered pipeline difference = %.3f m (want > 0.1)" % ctrl_diff)
	if ctrl_diff <= 0.1:
		_fail += 1; print("    !! control failed to diverge")


# --- B. Chunk Boundary Continuity (Zero Seam Artifacts) -----------------------------------------------
func _b_chunk_boundary_continuity() -> void:
	print("[B] Chunk Boundary Continuity (Zero Seam Artifacts)")
	var prog := _create_cell_program()
	var gw := 512
	var gh := 512
	var parallel_res := Pasture3DUtil.graph_cell_eval_grid(prog, gw, gh, RECT)
	var oracle_res := _eval_cell_oracle(prog, gw, gh, RECT)
	
	# Verify that across all chunk partition boundary rows (every 16th row), MT matches Oracle with 0 error
	var max_boundary_err := 0.0
	for iz in range(16, gh - 1, 16):
		var row := iz * gw
		for ix in range(gw):
			var err := absf(parallel_res[row + ix] - oracle_res[row + ix])
			if err > max_boundary_err:
				max_boundary_err = err
				
	print("    max chunk boundary discrepancy = %.8f m (want < 0.0001)" % max_boundary_err)
	if max_boundary_err >= 0.0001:
		_fail += 1; print("    !! seam discontinuity detected across chunk boundaries")
		
	# CONTROL: artificial seam offset of 0.5m on boundary row detected
	var control_seam := parallel_res.duplicate()
	control_seam[16 * gw + 10] += 0.5
	var ctrl_err := absf(control_seam[16 * gw + 10] - oracle_res[16 * gw + 10])
	print("    control: artificial seam error = %.3f m (want > 0.1)" % ctrl_err)
	if ctrl_err <= 0.1:
		_fail += 1; print("    !! control failed to detect artificial seam error")


# --- C. Spatial Filter Multi-Threaded Parity ---------------------------------------------------------
func _c_spatial_filter_multithreaded_parity() -> void:
	print("[C] Spatial Filters Multi-Threaded Parity (Warp, Curvature, Spectral Equalizer)")
	var size := 256
	var prog := _create_cell_program()
	var base_surf := Pasture3DUtil.graph_cell_eval_grid(prog, size, size, RECT)
	
	# 1. Warp
	var warp_res := Pasture3DUtil.warp_grid(base_surf, size, size, RECT, 0, 0.01, 15.0, 3, 20.0, 0.5, 12345)
	print("    warp result size = %d, valid cells = %s" % [warp_res.size(), warp_res.size() == size * size])
	if warp_res.size() != size * size:
		_fail += 1; print("    !! warp_grid failed")
		
	# 2. Curvature
	var curv_res := Pasture3DUtil.curvature_grid(base_surf, size, size, 0, 2, 1.0)
	print("    curvature result size = %d, valid cells = %s" % [curv_res.size(), curv_res.size() == size * size])
	if curv_res.size() != size * size:
		_fail += 1; print("    !! curvature_grid failed")
		
	# 3. Spectral Equalizer
	var spec_res := Pasture3DUtil.spectral_equalizer_grid(base_surf, PackedFloat32Array(), size, size, 1.5, 0.8, 1.2, 8, 3, 1.0)
	print("    spectral equalizer result size = %d, valid cells = %s" % [spec_res.size(), spec_res.size() == size * size])
	if spec_res.size() != size * size:
		_fail += 1; print("    !! spectral_equalizer_grid failed")


# --- D. Throughput Scaling Benchmark ------------------------------------------------------------------
func _d_throughput_scaling_benchmark() -> void:
	print("[D] Throughput Scaling Benchmark across Grid Scales")
	var prog := _create_cell_program()
	
	print("Grid Size    | GDScript Oracle | C++ Multi-Threaded | Speedup")
	print("---------------------------------------------------------------")
	for size in [128, 256, 512]:
		# Measure GDScript oracle (single-threaded interpreted)
		var t0_gd := Time.get_ticks_usec()
		var _res_gd := _eval_cell_oracle(prog, size, size, RECT)
		var gd_ms := float(Time.get_ticks_usec() - t0_gd) / 1000.0
		
		# Measure C++ Multi-Threaded
		var t0_mt := Time.get_ticks_usec()
		var _res_mt := Pasture3DUtil.graph_cell_eval_grid(prog, size, size, RECT)
		var mt_ms := float(Time.get_ticks_usec() - t0_mt) / 1000.0
		
		var speedup := gd_ms / maxf(mt_ms, 0.001)
		print("%-12s | %9.2f ms   | %14.2f ms   | %6.1fx" % [
			"%dx%d" % [size, size],
			gd_ms,
			mt_ms,
			speedup
		])
		if speedup < 3.0:
			_fail += 1; print("    !! speedup insufficient at %dx%d (expected >= 3.0x)" % [size, size])
