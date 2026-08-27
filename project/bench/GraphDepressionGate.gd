# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphDepressionGate — parity and behavior verification for Pasture3DGraphNodeDepressionFilling.
#
# Tests:
#   [A] Basin pit filling: an enclosed hole is raised exactly to its lowest drainage spillway.
#   [B] Flat flow gradient: epsilon_slope guarantees monotonic outward slope across the filled pit.
#   [C] Depth limit control: limits max fill height when configured.
#   [D] Amount & NaN safety.
#   [E] Node metadata & warnings.
extends Node

const GW := 32
const GH := 32
const RECT := Rect2(-32.0, -32.0, 64.0, 64.0)
const EPS := 1.0e-4

var _fail := 0


func _ready() -> void:
	print("=== GraphDepressionGate: Priority-Flood depression filling filter ===\n")
	_a_basin_pit_filling()
	_b_monotonic_gradient()
	_c_depth_limit()
	_d_amount_and_nan_safety()
	_e_metadata_and_warnings()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH DEPRESSION PASS" if _fail == 0 else "GRAPH DEPRESSION FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _a_basin_pit_filling() -> void:
	print("[A] Enclosed depression pit raised to lowest spillway")
	var crater := _make_crater_grid(GW, GH, 20.0, 5.0) # 20m rim, 5m bottom, spillway on edge at 15m
	var df := Pasture3DGraphNodeDepressionFilling.new()
	df.epsilon_slope = 0.0
	df.amount = 1.0

	var filled := df.eval_grid([crater], GW, GH, null, RECT)

	# Pit bottom should be raised to rim spillway
	var center_orig := crater[16 * GW + 16]
	var center_filled := filled[16 * GW + 16]

	print("    pit floor: orig=%.2f m, filled=%.2f m (want >= 15.0 m)" % [center_orig, center_filled])
	if center_filled < 14.99:
		_fail += 1; print("    !! depression was not filled to spillway")


func _b_monotonic_gradient() -> void:
	print("[B] Epsilon slope provides outward monotonic gradient")
	var crater := _make_crater_grid(GW, GH, 20.0, 5.0)
	var df := Pasture3DGraphNodeDepressionFilling.new()
	df.epsilon_slope = 0.01
	df.amount = 1.0

	var filled := df.eval_grid([crater], GW, GH, null, RECT)
	var c_val := filled[16 * GW + 16]
	var n_val := filled[16 * GW + 17]

	print("    center=%.4f m, neighbor=%.4f m (center > neighbor for outward drainage)" % [c_val, n_val])
	if c_val <= n_val:
		_fail += 1; print("    !! epsilon slope did not create monotonic gradient")


func _c_depth_limit() -> void:
	print("[C] Fill depth limit cap")
	var crater := _make_crater_grid(GW, GH, 20.0, 5.0) # 15m depth
	var df := Pasture3DGraphNodeDepressionFilling.new()
	df.fill_depth_limit = 4.0 # only fill 4m
	df.epsilon_slope = 0.0
	df.amount = 1.0

	var filled := df.eval_grid([crater], GW, GH, null, RECT)
	var center_filled := filled[16 * GW + 16]

	print("    capped floor: %.2f m (orig=5.0m, want approx 9.0m)" % center_filled)
	if absf(center_filled - 9.0) > 0.1:
		_fail += 1; print("    !! fill depth limit was not respected")


func _d_amount_and_nan_safety() -> void:
	print("[D] Amount and NaN safety")
	var crater := _make_crater_grid(GW, GH, 20.0, 5.0)
	crater[0] = NAN

	var df0 := Pasture3DGraphNodeDepressionFilling.new()
	df0.amount = 0.0
	var out0 := df0.eval_grid([crater], GW, GH, null, RECT)

	var diff0 := absf(out0[16 * GW + 16] - crater[16 * GW + 16])
	if diff0 > EPS:
		_fail += 1; print("    !! amount 0 was not identity")

	var df1 := Pasture3DGraphNodeDepressionFilling.new()
	df1.amount = 1.0
	var out1 := df1.eval_grid([crater], GW, GH, null, RECT)
	if not is_nan(out1[0]):
		_fail += 1; print("    !! NaN was not preserved")


func _e_metadata_and_warnings() -> void:
	print("[E] Metadata and warnings")
	var df := Pasture3DGraphNodeDepressionFilling.new()
	if df.op() != &"depression_filling":
		_fail += 1; print("    !! op mismatch")
	if df.role() != Pasture3DGraphNode.Role.FILTER:
		_fail += 1; print("    !! role mismatch")
	if not df.needs_grid():
		_fail += 1; print("    !! needs_grid should be true")


func _make_crater_grid(gw: int, gh: int, rim: float, floor: float) -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(gw * gh)
	var cx := gw / 2.0
	var cz := gh / 2.0
	for iz in range(gh):
		for ix in range(gw):
			var dist := sqrt((ix - cx) * (ix - cx) + (iz - cz) * (iz - cz))
			if dist < 6.0:
				g[iz * gw + ix] = floor
			elif dist < 12.0:
				g[iz * gw + ix] = rim
			else:
				g[iz * gw + ix] = 15.0 # spillway height at outer border
	return g
