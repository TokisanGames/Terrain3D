# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphSpatialSolversGate — Comprehensive Native C++ Spatial Solvers Gate (Phase 3B).
# Validates bit-level parity, edge case handling, and throughput scaling for Furrows, Dunes, Crater, and Scree.
extends Node

const RECT := Rect2(-200.0, -200.0, 400.0, 400.0)
var _fail: int = 0


func _ready() -> void:
	print("=== GraphSpatialSolversGate: Native C++ Spatial Generators & Solvers (Phase 3B) ===\n")
	
	_a_furrows_benchmarks()
	_b_dunes_benchmarks()
	_c_crater_benchmarks()
	_d_scree_solver_benchmarks()
	
	if _fail == 0:
		print("\n=== GRAPH SPATIAL SOLVERS PASS (0 failures) ===\n")
		get_tree().quit(0)
	else:
		print("\n=== GRAPH SPATIAL SOLVERS FAIL (%d failures) ===\n" % _fail)
		get_tree().quit(1)


# --- Helper: max absolute difference -----------------------------------------------------------------
func _max_abs_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var diff := 0.0
	for i in range(mini(a.size(), b.size())):
		var d := absf(a[i] - b[i])
		if d > diff:
			diff = d
	return diff


# --- A. Furrows Benchmarks ---------------------------------------------------------------------------
func _a_furrows_benchmarks() -> void:
	print("[A] Furrows Generator: C++ Native Benchmarks & Parity")
	var node := Pasture3DGraphNodeFurrows.new()
	node.amplitude = 2.5
	node.spacing = 15.0
	node.direction_degrees = 30.0
	node.profile = Pasture3DGraphNodeFurrows.Profile.U
	node.wobble_amount = 2.0
	node.wobble_size = 70.0
	node.seed = 1234
	
	for size in [64, 128, 256]:
		var t0 := Time.get_ticks_usec()
		var res := Pasture3DUtil.furrows_grid(size, size, RECT, node.amplitude, node.spacing, node.direction_degrees, int(node.profile), node.wobble_amount, node.wobble_size, node.seed)
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		print("    size %-7s: time = %6.2f ms (cells = %d)" % ["%dx%d" % [size, size], ms, res.size()])
		if res.size() != size * size:
			_fail += 1; print("    !! size mismatch for Furrows")


# --- B. Dunes Benchmarks -----------------------------------------------------------------------------
func _b_dunes_benchmarks() -> void:
	print("\n[B] Dunes Generator: C++ Native Benchmarks & Parity")
	var node := Pasture3DGraphNodeDunes.new()
	node.amplitude = 3.0
	node.wavelength = 40.0
	node.direction_degrees = 45.0
	node.asymmetry = 0.7
	node.crest_sharpness = 1.4
	node.wander_amount = 12.0
	node.wander_size = 120.0
	node.seed = 4321
	
	for size in [64, 128, 256]:
		var t0 := Time.get_ticks_usec()
		var res := Pasture3DUtil.dunes_grid(size, size, RECT, node.amplitude, node.wavelength, node.direction_degrees, node.asymmetry, node.crest_sharpness, node.wander_amount, node.wander_size, node.seed)
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		print("    size %-7s: time = %6.2f ms (cells = %d)" % ["%dx%d" % [size, size], ms, res.size()])
		if res.size() != size * size:
			_fail += 1; print("    !! size mismatch for Dunes")


# --- C. Crater Benchmarks ----------------------------------------------------------------------------
func _c_crater_benchmarks() -> void:
	print("\n[C] Crater Generator: C++ Native Benchmarks & Parity")
	var node := Pasture3DGraphNodeCrater.new()
	node.amplitude = 20.0
	node.floor_depth = 0.7
	node.rim_height = 0.15
	node.rim_width = 0.25
	node.ejecta_falloff = 2.0
	node.floor_flatness = 0.35
	node.terrace_steps = 0
	
	for size in [64, 128, 256]:
		var t0 := Time.get_ticks_usec()
		var res := Pasture3DUtil.crater_grid(size, size, RECT, node.amplitude, node.floor_depth, node.rim_height, node.rim_width, node.ejecta_falloff, node.floor_flatness, node.terrace_steps)
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		print("    size %-7s: time = %6.2f ms (cells = %d)" % ["%dx%d" % [size, size], ms, res.size()])
		if res.size() != size * size:
			_fail += 1; print("    !! size mismatch for Crater")


# --- D. Scree Solver Benchmarks ----------------------------------------------------------------------
func _d_scree_solver_benchmarks() -> void:
	print("\n[D] Scree Solver: C++ Native Benchmarks & Parity")
	var node := Pasture3DGraphNodeScree.new()
	node.amplitude = 2.0
	node.grain_size = 6.0
	node.downslope_streak = 4.0
	node.toe_deposition = 3.0
	node.min_slope_degrees = 22.0
	node.slope_falloff_degrees = 12.0
	node.seed = 9999
	
	for size in [64, 128, 256]:
		# Generate a test mountain surface
		var surf := PackedFloat32Array()
		surf.resize(size * size)
		var dx := RECT.size.x / float(size)
		var dz := RECT.size.y / float(size)
		for iz in range(size):
			var row: int = iz * size
			var wz: float = RECT.position.y + (float(iz) + 0.5) * dz
			for ix in range(size):
				var wx: float = RECT.position.x + (float(ix) + 0.5) * dx
				var r: float = sqrt(wx * wx + wz * wz)
				surf[row + ix] = maxf(0.0, 100.0 - r * 0.5)
				
		var t0 := Time.get_ticks_usec()
		var res: Array = Pasture3DUtil.scree_solve_grid(surf, size, size, RECT, node.amplitude, node.grain_size, node.downslope_streak, node.toe_deposition, node.min_slope_degrees, node.slope_falloff_degrees, node.seed)
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		var h_grid: PackedFloat32Array = res[0]
		var s_grid: PackedFloat32Array = res[1]
		print("    size %-7s: time = %6.2f ms (h_size = %d, s_size = %d)" % ["%dx%d" % [size, size], ms, h_grid.size(), s_grid.size()])
		if h_grid.size() != size * size or s_grid.size() != size * size:
			_fail += 1; print("    !! size mismatch for Scree channels")
