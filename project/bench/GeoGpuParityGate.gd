# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GeoGpuParityGate — the GPU geological-primitive solver vs the CPU solver (MountainCone first).
#
# The claim: Pasture3DUtil.mountain_cone_generate_grid_gpu (C++ Pasture3DGraphGPU, one dispatch of
# shaders/graph_geo_primitives.glsl over a local RenderingDevice) produces the SAME field as the CPU solver
# mountain_cone_generate_grid within a small epsilon. Both host-side derive the identical constants (kw,
# cos/sin alpha, wang-hashed seed, Nyquist-capped octaves), so only the per-cell arithmetic differs (GPU
# float vs CPU float intermediates) — that is where the epsilon comes from. The strict CPU-vs-oracle gate
# (GraphGeoPrimitivesGate) holds 1e-5 bit-parity on the CPU solver; this gate holds ~1e-3 across the GPU.
#
# _gpu bypasses the graph_gpu_threshold so the GPU path runs at ANY grid size (the production _best route
# only crosses to the GPU at/above the threshold — too large to iterate here).
#
# RUN NON-HEADLESS: the dummy headless driver has no local RenderingDevice. When none is available (CI /
# --headless) the GPU call returns empty and this gate SKIPS with a clear message rather than failing — the
# same discipline as GraphGpuParityGate. Every criterion carries a control that must move.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project res://bench/GeoGpuParityGate.tscn   (no --headless)
extends Node

const GW := 96
const GH := 96
const RECT := Rect2(-32.0, -32.0, 64.0, 64.0)
const TOL := 1.0e-3 # GPU float vs CPU float intermediates

var _fail := 0


func _ready() -> void:
	print("=== GeoGpuParityGate: GPU geological primitives vs CPU solver ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "mountain_cone_generate_grid_gpu"):
		print("!! Pasture3DUtil.mountain_cone_generate_grid_gpu is missing — the DLL is stale; rebuild the extension.")
		_finish(1); return
	# Availability probe: an empty return means no local RenderingDevice (headless / no driver).
	var probe := Pasture3DUtil.mountain_cone_generate_grid_gpu(GW, GH, RECT, _cone_params(1))
	if probe.is_empty():
		print("GPU unavailable (no local RenderingDevice — running --headless?). SKIPPING.")
		print("Run WITHOUT --headless on a machine with a GPU to actually verify GPU/CPU parity.")
		_finish(0); return

	_a_default_cone()
	_b_seed_variation()
	_c_wired_envelope()
	_d_wired_displacement()
	_e_mountain_inselberg()
	_f_mountain_range_radial()
	_g_mountain_tibesti()
	_h_mountain_stump()
	_i_shattered_peak()
	_j_caldera()
	_finish(_fail)


func _finish(p_code: int) -> void:
	print("\n=== %s (%d failures) ===\n" % ["GEO GPU PARITY PASS" if _fail == 0 else "GEO GPU PARITY FAIL", _fail])
	get_tree().quit(0 if p_code == 0 and _fail == 0 else 1)


# --- A. A default cone: GPU == CPU, and the field is non-trivial --------------------------------------
func _a_default_cone() -> void:
	print("[A] default MountainCone: GPU == CPU")
	var p := _cone_params(7)
	var gpu := Pasture3DUtil.mountain_cone_generate_grid_gpu(GW, GH, RECT, p)
	var cpu := Pasture3DUtil.mountain_cone_generate_grid(GW, GH, RECT, p)
	_check(gpu, cpu, "default")
	# control: the field must actually vary (a summit above a zero border), else parity is vacuous.
	var span := _maxv(gpu) - _minv(gpu)
	print("    control: GPU field span = %.3f m (want > 1.0)" % span)
	if span <= 1.0:
		_fail += 1; print("    !! field is flat — nothing was measured")


# --- B. Seed variation moves the field, and each seed matches --------------------------------------
func _b_seed_variation() -> void:
	print("[B] seed variation: GPU == CPU per seed, and seeds differ")
	var g1 := Pasture3DUtil.mountain_cone_generate_grid_gpu(GW, GH, RECT, _cone_params(1))
	var g2 := Pasture3DUtil.mountain_cone_generate_grid_gpu(GW, GH, RECT, _cone_params(99))
	_check(g1, Pasture3DUtil.mountain_cone_generate_grid(GW, GH, RECT, _cone_params(1)), "seed=1")
	_check(g2, Pasture3DUtil.mountain_cone_generate_grid(GW, GH, RECT, _cone_params(99)), "seed=99")
	var moved := _maxdiff(g1, g2)
	print("    control: a different seed moves the GPU field by %.3f (want > 0.05)" % moved)
	if moved <= 0.05:
		_fail += 1; print("    !! control dead — seed is not reaching the shader")


# --- C. A wired envelope input carves the cone identically -----------------------------------------
func _c_wired_envelope() -> void:
	print("[C] wired envelope (input C): GPU == CPU, and the envelope bites")
	var p := _cone_params(7)
	var no_env := Pasture3DUtil.mountain_cone_generate_grid_gpu(GW, GH, RECT, p)
	p["envelope"] = _radial_mask()
	var gpu := Pasture3DUtil.mountain_cone_generate_grid_gpu(GW, GH, RECT, p)
	var cpu := Pasture3DUtil.mountain_cone_generate_grid(GW, GH, RECT, p)
	_check(gpu, cpu, "envelope")
	var bit := _maxdiff(no_env, gpu)
	print("    control: the envelope changed the GPU field by %.3f (want > 0.05)" % bit)
	if bit <= 0.05:
		_fail += 1; print("    !! the envelope input was ignored on the GPU")


# --- D. Wired dx/dy displacement warps the field identically ---------------------------------------
func _d_wired_displacement() -> void:
	print("[D] wired displacement (inputs A/B): GPU == CPU, and it warps")
	var p := _cone_params(7)
	var flat := Pasture3DUtil.mountain_cone_generate_grid_gpu(GW, GH, RECT, p)
	p["dx"] = _ramp_field(0.35)
	p["dy"] = _ramp_field(-0.25)
	var gpu := Pasture3DUtil.mountain_cone_generate_grid_gpu(GW, GH, RECT, p)
	var cpu := Pasture3DUtil.mountain_cone_generate_grid(GW, GH, RECT, p)
	_check(gpu, cpu, "displacement")
	var warped := _maxdiff(flat, gpu)
	print("    control: displacement moved the GPU field by %.3f (want > 0.05)" % warped)
	if warped <= 0.05:
		_fail += 1; print("    !! displacement inputs A/B were ignored on the GPU")


# --- E. MountainInselberg: GPU == CPU ---------------------------------------------------------------
func _e_mountain_inselberg() -> void:
	print("[E] MountainInselberg: GPU == CPU")
	var p := {
		"seed": 13,
		"elevation": 25.0,
		"scale": 1.0,
		"octaves": 8,
		"rugosity": 0.0,
		"angle": 45.0,
		"gamma": 0.5,
		"bulk_amp": 0.5,
		"base_noise_amp": 0.05,
		"center": Vector2(0.5, 0.5),
	}
	var gpu := Pasture3DUtil.mountain_inselberg_generate_grid_gpu(GW, GH, RECT, p)
	var cpu := Pasture3DUtil.mountain_inselberg_generate_grid(GW, GH, RECT, p)
	_check(gpu, cpu, "inselberg")
	var span := _maxv(gpu) - _minv(gpu)
	print("    control: GPU field span = %.3f m (want > 1.0)" % span)
	if span <= 1.0:
		_fail += 1; print("    !! field is flat — nothing was measured")


# --- F. MountainRangeRadial: GPU == CPU -------------------------------------------------------------
func _f_mountain_range_radial() -> void:
	print("[F] MountainRangeRadial: GPU == CPU")
	var p := {
		"seed": 27,
		"elevation": 25.0,
		"kw_x": 4.0,
		"kw_y": 4.0,
		"half_width": 0.2,
		"angle_spread_ratio": 0.5,
		"core_size_ratio": 0.2,
		"center": Vector2(0.5, 0.5),
		"octaves": 8,
		"weight": 0.7,
		"persistence": 0.5,
		"lacunarity": 2.0,
	}
	var gpu_arr := Pasture3DUtil.mountain_range_radial_generate_grid_gpu(GW, GH, RECT, p)
	var cpu_arr := Pasture3DUtil.mountain_range_radial_generate_grid(GW, GH, RECT, p)
	if gpu_arr.size() >= 2 and cpu_arr.size() >= 2:
		_check(gpu_arr[0], cpu_arr[0], "range_radial_h")
		_check(gpu_arr[1], cpu_arr[1], "range_radial_a")
	else:
		_fail += 1; print("    !! GPU range radial return array malformed")


# --- G. MountainTibesti: GPU == CPU -----------------------------------------------------------------
func _g_mountain_tibesti() -> void:
	print("[G] MountainTibesti: GPU == CPU")
	var p := {
		"seed": 42,
		"elevation": 25.0,
		"scale": 1.0,
		"octaves": 8,
		"peak_kw": 4.0,
		"rugosity": 0.0,
		"angle": 45.0,
		"angle_spread_ratio": 0.5,
		"gamma": 0.5,
		"bulk_amp": 0.5,
		"base_noise_amp": 0.05,
		"center": Vector2(0.5, 0.5),
	}
	var gpu := Pasture3DUtil.mountain_tibesti_generate_grid_gpu(GW, GH, RECT, p)
	var cpu := Pasture3DUtil.mountain_tibesti_generate_grid(GW, GH, RECT, p)
	_check(gpu, cpu, "tibesti")
	var span := _maxv(gpu) - _minv(gpu)
	print("    control: GPU field span = %.3f m (want > 1.0)" % span)
	if span <= 1.0:
		_fail += 1; print("    !! field is flat — nothing was measured")


# --- H. MountainStump: GPU == CPU -------------------------------------------------------------------
func _h_mountain_stump() -> void:
	print("[H] MountainStump: GPU == CPU")
	var p := {
		"seed": 55,
		"elevation": 25.0,
		"scale": 1.0,
		"octaves": 8,
		"peak_kw": 4.0,
		"rugosity": 0.0,
		"angle": 45.0,
		"k_smoothing": 0.05,
		"gamma": 0.5,
		"ridge_amp": 0.4,
		"base_noise_amp": 0.05,
		"center": Vector2(0.5, 0.5),
	}
	var gpu := Pasture3DUtil.mountain_stump_generate_grid_gpu(GW, GH, RECT, p)
	var cpu := Pasture3DUtil.mountain_stump_generate_grid(GW, GH, RECT, p)
	_check(gpu, cpu, "stump")
	var span := _maxv(gpu) - _minv(gpu)
	print("    control: GPU field span = %.3f m (want > 1.0)" % span)
	if span <= 1.0:
		_fail += 1; print("    !! field is flat — nothing was measured")


# --- I. ShatteredPeak: GPU == CPU -------------------------------------------------------------------
func _i_shattered_peak() -> void:
	print("[I] ShatteredPeak: GPU == CPU")
	var p := {
		"seed": 77,
		"elevation": 25.0,
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
	var gpu := Pasture3DUtil.shattered_peak_generate_grid_gpu(GW, GH, RECT, p)
	var cpu := Pasture3DUtil.shattered_peak_generate_grid(GW, GH, RECT, p)
	_check(gpu, cpu, "shattered_peak")
	var span := _maxv(gpu) - _minv(gpu)
	print("    control: GPU field span = %.3f m (want > 1.0)" % span)
	if span <= 1.0:
		_fail += 1; print("    !! field is flat — nothing was measured")


# --- J. Caldera: GPU == CPU -------------------------------------------------------------------------
func _j_caldera() -> void:
	print("[J] Caldera: GPU == CPU")
	var p := {
		"elevation": 25.0,
		"radius": 0.2,
		"sigma_inner": 0.05,
		"sigma_outer": 0.15,
		"z_bottom": 0.2,
		"noise_r_amp": 0.02,
		"noise_z_ratio": 0.05,
		"center": Vector2(0.5, 0.5),
	}
	var gpu := Pasture3DUtil.caldera_generate_grid_gpu(GW, GH, RECT, p)
	var cpu := Pasture3DUtil.caldera_generate_grid(GW, GH, RECT, p)
	_check(gpu, cpu, "caldera")
	var span := _maxv(gpu) - _minv(gpu)
	print("    control: GPU field span = %.3f m (want > 1.0)" % span)
	if span <= 1.0:
		_fail += 1; print("    !! field is flat — nothing was measured")


# ---- helpers ----------------------------------------------------------------------------------------

func _check(p_gpu: PackedFloat32Array, p_cpu: PackedFloat32Array, p_name: String) -> void:
	var d := _maxdiff(p_gpu, p_cpu)
	print("    %-12s GPU vs CPU = %.7f (want < %.6f)" % [p_name, d, TOL])
	if d > TOL:
		_fail += 1; print("    !! GPU diverged from the CPU solver on '%s'" % p_name)


func _cone_params(p_seed: int) -> Dictionary:
	return {
		"seed": p_seed,
		"elevation": 25.0,
		"scale": 1.0,
		"octaves": 8,
		"peak_kw": 4.0,
		"angle": 45.0,
		"gamma": 0.5,
		"cone_alpha": 1.2,
		"ridge_amp": 0.4,
		"base_noise_amp": 0.05,
		"center": Vector2(0.5, 0.5),
	}


# A soft radial mask centred slightly off-centre so it clips the cone asymmetrically (1 inside -> 0 outside).
func _radial_mask() -> PackedFloat32Array:
	var m := PackedFloat32Array()
	m.resize(GW * GH)
	for iz in range(GH):
		var ny := float(iz) / float(GH - 1)
		for ix in range(GW):
			var nx := float(ix) / float(GW - 1)
			var d := sqrt(pow(nx - 0.45, 2.0) + pow(ny - 0.55, 2.0))
			m[iz * GW + ix] = clampf(1.0 - d * 2.2, 0.0, 1.0)
	return m


func _ramp_field(p_scale: float) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			s[iz * GW + ix] = p_scale * (float(ix) / GW - 0.5)
	return s


func _maxdiff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m


func _maxv(p_a: PackedFloat32Array) -> float:
	var m := -INF
	for v in p_a:
		m = maxf(m, v)
	return m


func _minv(p_a: PackedFloat32Array) -> float:
	var m := INF
	for v in p_a:
		m = minf(m, v)
	return m
