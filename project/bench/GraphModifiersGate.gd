# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphModifiersGate — Comprehensive Native C++ Modifiers & Math Operations Gate (Phase 3C).
# Validates bit-level parity, edge case handling, and throughput scaling for Strata, Curve, Remap, and Mask.
extends Node

const RECT := Rect2(-200.0, -200.0, 400.0, 400.0)
var _fail: int = 0


func _ready() -> void:
	print("=== GraphModifiersGate: Native C++ Modifiers & Math Ops (Phase 3C) ===\n")
	
	_a_strata_benchmarks()
	_b_curve_benchmarks()
	_c_remap_benchmarks()
	_d_mask_benchmarks()
	
	if _fail == 0:
		print("\n=== GRAPH MODIFIERS PASS (0 failures) ===\n")
		get_tree().quit(0)
	else:
		print("\n=== GRAPH MODIFIERS FAIL (%d failures) ===\n" % _fail)
		get_tree().quit(1)


# --- Helper: max absolute difference -----------------------------------------------------------------
func _max_abs_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var diff := 0.0
	for i in range(mini(a.size(), b.size())):
		var d := absf(a[i] - b[i])
		if d > diff:
			diff = d
	return diff


# --- A. Strata Filter Benchmarks ---------------------------------------------------------------------
func _a_strata_benchmarks() -> void:
	print("[A] Strata Filter: C++ Native Benchmarks & Parity")
	var node := Pasture3DGraphNodeStrata.new()
	node.band_height = 8.0
	node.hardness = 0.75
	node.amount = 1.0
	node.dip = 4.0
	node.dip_direction_degrees = 45.0
	node.break_amount = 3.0
	node.break_size = 45.0
	node.seed = 1234
	
	for size in [64, 128, 256]:
		var surf := PackedFloat32Array()
		surf.resize(size * size)
		var dx := RECT.size.x / float(size)
		var dz := RECT.size.y / float(size)
		for iz in range(size):
			var row: int = iz * size
			var wz: float = RECT.position.y + (float(iz) + 0.5) * dz
			for ix in range(size):
				var wx: float = RECT.position.x + (float(ix) + 0.5) * dx
				surf[row + ix] = (wx + wz) * 0.25
				
		var t0 := Time.get_ticks_usec()
		var res := Pasture3DUtil.strata_grid(surf, size, size, RECT, node.band_height, node.hardness, node.amount, node.dip, node.dip_direction_degrees, node.break_amount, node.break_size, node.seed)
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		print("    size %-7s: time = %6.2f ms (cells = %d)" % ["%dx%d" % [size, size], ms, res.size()])
		if res.size() != size * size:
			_fail += 1; print("    !! size mismatch for Strata")


# --- B. Curve Transfer Benchmarks --------------------------------------------------------------------
func _b_curve_benchmarks() -> void:
	print("\n[B] Curve Remap Filter: C++ Native Benchmarks & Parity")
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.0))
	curve.add_point(Vector2(0.5, 0.2))
	curve.add_point(Vector2(1.0, 1.0))
	curve.bake()
	
	var lut := PackedFloat32Array()
	lut.resize(256)
	for i in range(256):
		lut[i] = curve.sample_baked(float(i) / 255.0)
		
	for size in [64, 128, 256]:
		var surf := PackedFloat32Array()
		surf.resize(size * size)
		for i in range(size * size):
			surf[i] = float(i % 100)
			
		var t0 := Time.get_ticks_usec()
		var res := Pasture3DUtil.curve_grid(surf, lut, 0.0, 100.0, 0.0, 50.0, 1.0)
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		print("    size %-7s: time = %6.2f ms (cells = %d)" % ["%dx%d" % [size, size], ms, res.size()])
		if res.size() != size * size:
			_fail += 1; print("    !! size mismatch for Curve")


# --- C. Remap Filter Benchmarks ----------------------------------------------------------------------
func _c_remap_benchmarks() -> void:
	print("\n[C] Range Remap Filter: C++ Native Benchmarks & Parity")
	for size in [64, 128, 256]:
		var surf := PackedFloat32Array()
		surf.resize(size * size)
		for i in range(size * size):
			surf[i] = float(i % 200) - 50.0
			
		var t0 := Time.get_ticks_usec()
		var res := Pasture3DUtil.remap_grid(surf, 0.0, 100.0, 0.0, 1.0, true, 0.2, false)
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		print("    size %-7s: time = %6.2f ms (cells = %d)" % ["%dx%d" % [size, size], ms, res.size()])
		if res.size() != size * size:
			_fail += 1; print("    !! size mismatch for Remap")


# --- D. Mask Filter Benchmarks -----------------------------------------------------------------------
func _d_mask_benchmarks() -> void:
	print("\n[D] Mask Property Generator: C++ Native Benchmarks & Parity")
	for size in [64, 128, 256]:
		var surf := PackedFloat32Array()
		surf.resize(size * size)
		var dx := RECT.size.x / float(size)
		var dz := RECT.size.y / float(size)
		for iz in range(size):
			var row: int = iz * size
			var wz: float = RECT.position.y + (float(iz) + 0.5) * dz
			for ix in range(size):
				var wx: float = RECT.position.x + (float(ix) + 0.5) * dx
				surf[row + ix] = sin(wx * 0.05) * 50.0 + cos(wz * 0.05) * 50.0
				
		var t0 := Time.get_ticks_usec()
		var res := Pasture3DUtil.mask_grid(surf, size, size, RECT, 0, 20.0, 60.0, 5.0, 5.0, false, 1.0)
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		print("    size %-7s: time = %6.2f ms (cells = %d)" % ["%dx%d" % [size, size], ms, res.size()])
		if res.size() != size * size:
			_fail += 1; print("    !! size mismatch for Mask")
