extends Node

## Automated test gate for Phase 2 Geological Primitives:
## MountainRangeRadial, MountainTibesti, MountainStump, ShatteredPeak, Caldera.
## Asserts bit-level parity between C++ native solver and pure GDScript Tier 1 reference oracle,
## and tests whole-graph compilation & lowering.

const DevMountainRangeRadial = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_mountain_range_radial.gd")
const DevMountainTibesti = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_mountain_tibesti.gd")
const DevMountainStump = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_mountain_stump.gd")
const DevShatteredPeak = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_shattered_peak.gd")
const DevCaldera = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_caldera.gd")

const TOLERANCE: float = 1e-4

func _ready() -> void:
	print("\n=== GraphGeoPrimitivesPhase2Gate: Geological Primitives Phase 2 Gate ===\n")
	var failures: int = 0

	var gw: int = 64
	var gh: int = 64
	var rect: Rect2 = Rect2(-100.0, -100.0, 200.0, 200.0)

	# -------------------------------------------------------------------------
	# [A] MountainRangeRadial Parity
	# -------------------------------------------------------------------------
	print("[A] MountainRangeRadial Bit-Level Parity: C++ Native vs GDScript Oracle")
	var range_params := {
		"seed": 1337,
		"elevation": 25.0,
		"kw_x": 4.0,
		"kw_y": 4.0,
		"half_width": 0.25,
		"angle_spread_ratio": 0.4,
		"core_size_ratio": 0.2,
		"center": Vector2(0.5, 0.5),
		"octaves": 8,
		"weight": 0.7,
		"persistence": 0.5,
		"lacunarity": 2.0,
	}

	var res_cpp_range: Array = Pasture3DUtil.mountain_range_radial_generate_grid(gw, gh, rect, range_params)
	var res_gd_range: Array = DevMountainRangeRadial.solve_oracle(gw, gh, rect, range_params)

	var h_cpp_range: PackedFloat32Array = res_cpp_range[0]
	var h_gd_range: PackedFloat32Array = res_gd_range[0]
	var max_diff_range: float = _max_abs_diff(h_cpp_range, h_gd_range)
	print("    MountainRangeRadial height max |cpp - gdscript| = %.9f (want <= %.7f)" % [max_diff_range, TOLERANCE])
	if max_diff_range > TOLERANCE:
		print("    !! FAIL: MountainRangeRadial height parity exceeded tolerance")
		failures += 1

	# -------------------------------------------------------------------------
	# [B] MountainTibesti Parity
	# -------------------------------------------------------------------------
	print("\n[B] MountainTibesti Bit-Level Parity: C++ Native vs GDScript Oracle")
	var tibesti_params := {
		"seed": 2026,
		"elevation": 30.0,
		"scale": 1.0,
		"octaves": 8,
		"peak_kw": 4.0,
		"rugosity": 0.0,
		"angle": 30.0,
		"angle_spread_ratio": 0.5,
		"gamma": 0.5,
		"bulk_amp": 0.5,
		"base_noise_amp": 0.05,
		"center": Vector2(0.5, 0.5),
	}

	var h_cpp_tibesti: PackedFloat32Array = Pasture3DUtil.mountain_tibesti_generate_grid(gw, gh, rect, tibesti_params)
	var h_gd_tibesti: PackedFloat32Array = DevMountainTibesti.solve_oracle(gw, gh, rect, tibesti_params)

	var max_diff_tibesti: float = _max_abs_diff(h_cpp_tibesti, h_gd_tibesti)
	print("    MountainTibesti max |cpp - gdscript| = %.9f (want <= %.7f)" % [max_diff_tibesti, TOLERANCE])
	if max_diff_tibesti > TOLERANCE:
		print("    !! FAIL: MountainTibesti parity exceeded tolerance")
		failures += 1

	# -------------------------------------------------------------------------
	# [C] MountainStump Parity
	# -------------------------------------------------------------------------
	print("\n[C] MountainStump Bit-Level Parity: C++ Native vs GDScript Oracle")
	var stump_params := {
		"seed": 777,
		"elevation": 25.0,
		"scale": 1.0,
		"octaves": 8,
		"peak_kw": 4.0,
		"rugosity": 0.0,
		"angle": 60.0,
		"k_smoothing": 0.05,
		"gamma": 0.5,
		"ridge_amp": 0.4,
		"base_noise_amp": 0.05,
		"center": Vector2(0.5, 0.5),
	}

	var h_cpp_stump: PackedFloat32Array = Pasture3DUtil.mountain_stump_generate_grid(gw, gh, rect, stump_params)
	var h_gd_stump: PackedFloat32Array = DevMountainStump.solve_oracle(gw, gh, rect, stump_params)

	var max_diff_stump: float = _max_abs_diff(h_cpp_stump, h_gd_stump)
	print("    MountainStump max |cpp - gdscript| = %.9f (want <= %.7f)" % [max_diff_stump, TOLERANCE])
	if max_diff_stump > TOLERANCE:
		print("    !! FAIL: MountainStump parity exceeded tolerance")
		failures += 1

	# -------------------------------------------------------------------------
	# [D] ShatteredPeak Parity
	# -------------------------------------------------------------------------
	print("\n[D] ShatteredPeak Bit-Level Parity: C++ Native vs GDScript Oracle")
	var peak_params := {
		"seed": 999,
		"elevation": 28.0,
		"scale": 1.0,
		"octaves": 8,
		"peak_kw": 4.0,
		"rugosity": 0.0,
		"angle": 45.0,
		"gamma": 0.5,
		"bulk_amp": 0.5,
		"base_noise_amp": 0.05,
		"k_smoothing": 0.05,
		"center": Vector2(0.5, 0.5),
	}

	var h_cpp_peak: PackedFloat32Array = Pasture3DUtil.shattered_peak_generate_grid(gw, gh, rect, peak_params)
	var h_gd_peak: PackedFloat32Array = DevShatteredPeak.solve_oracle(gw, gh, rect, peak_params)

	var max_diff_peak: float = _max_abs_diff(h_cpp_peak, h_gd_peak)
	print("    ShatteredPeak max |cpp - gdscript| = %.9f (want <= %.7f)" % [max_diff_peak, TOLERANCE])
	if max_diff_peak > TOLERANCE:
		print("    !! FAIL: ShatteredPeak parity exceeded tolerance")
		failures += 1

	# -------------------------------------------------------------------------
	# [E] Caldera Parity
	# -------------------------------------------------------------------------
	print("\n[E] Caldera Bit-Level Parity: C++ Native vs GDScript Oracle")
	var caldera_params := {
		"elevation": 25.0,
		"radius": 0.25,
		"sigma_inner": 0.05,
		"sigma_outer": 0.15,
		"z_bottom": 0.2,
		"noise_r_amp": 0.02,
		"noise_z_ratio": 0.05,
		"center": Vector2(0.5, 0.5),
	}

	var h_cpp_caldera: PackedFloat32Array = Pasture3DUtil.caldera_generate_grid(gw, gh, rect, caldera_params)
	var h_gd_caldera: PackedFloat32Array = DevCaldera.solve_oracle(gw, gh, rect, caldera_params)

	var max_diff_caldera: float = _max_abs_diff(h_cpp_caldera, h_gd_caldera)
	print("    Caldera max |cpp - gdscript| = %.9f (want <= %.7f)" % [max_diff_caldera, TOLERANCE])
	if max_diff_caldera > TOLERANCE:
		print("    !! FAIL: Caldera parity exceeded tolerance")
		failures += 1

	# -------------------------------------------------------------------------
	# [F] Whole-Graph Lowering: MountainRangeRadial -> HydraulicSaleve
	# -------------------------------------------------------------------------
	print("\n[F] Whole-Graph Lowering: MountainRangeRadial -> HydraulicSaleve Native Pipeline")
	var graph := Pasture3DTerrainGraph.new()
	var range_node = Pasture3DGraphNodeRegistry.create(&"mountain_range_radial")
	var saleve = Pasture3DGraphNodeRegistry.create(&"hydraulic_saleve")
	var output := Pasture3DGraphNodeOutput.new()

	graph.nodes = [range_node, saleve, output]
	graph.connections = [
		PackedInt32Array([0, 0, 1, 0]),
		PackedInt32Array([1, 0, 2, 0])
	]

	var supported: bool = graph.native_supported(2)
	print("    MountainRangeRadial -> HydraulicSaleve native_supported = %s (want true)" % [supported])
	if not supported:
		print("    !! FAIL: graph failed native_supported check")
		failures += 1

	var eval_res: PackedFloat32Array = graph.evaluate(gw, gh, rect)
	var max_elev: float = _max_val(eval_res)
	print("    Evaluated graph peak elevation = %.2f m (want > 15 m)" % [max_elev])
	if max_elev < 15.0:
		print("    !! FAIL: peak elevation below threshold")
		failures += 1

	# -------------------------------------------------------------------------
	# Result Summary
	# -------------------------------------------------------------------------
	if failures == 0:
		print("\n=== GRAPH GEO PRIMITIVES PHASE 2 PASS (0 failures) ===\n")
	else:
		print("\n=== GRAPH GEO PRIMITIVES PHASE 2 FAIL (%d failures) ===\n" % failures)

	get_tree().quit(0 if failures == 0 else 1)


func _max_abs_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var md: float = 0.0
	var n: int = mini(a.size(), b.size())
	for i in range(n):
		var diff: float = absf(a[i] - b[i])
		if diff > md:
			md = diff
	return md


func _max_val(a: PackedFloat32Array) -> float:
	var m: float = -1e9
	for v in a:
		if v > m:
			m = v
	return m
