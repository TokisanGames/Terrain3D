# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphGpuParityGate — the GPU whole-graph evaluator vs the CPU oracle (terrain-graph RenderingDevice path).
#
# The claim: Pasture3DUtil.graph_eval_grid_gpu (C++ Pasture3DGraphGPU, a local RenderingDevice) runs the
# graph's GRID passes — Blend, Smooth, Output — over resident buffers and produces the SAME field as the CPU
# whole-graph evaluator (graph_eval_grid) within a small epsilon. The generators (Input/Noise/Const) are
# CPU-computed and uploaded on both paths, so the noise is identical; only the grid arithmetic differs
# (GPU float vs CPU float/double intermediates), which is where the epsilon comes from.
#
# RUN NON-HEADLESS: the dummy headless driver has no local RenderingDevice. When none is available (CI /
# --headless) the GPU call returns empty and this gate SKIPS with a clear message rather than failing — the
# same way the SDF GPU raster is verified in the editor, not in headless CI. House discipline otherwise:
# measure a field delta, carry a control.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project res://bench/GraphGpuParityGate.tscn   (no --headless)
extends Node

const GW := 48
const GH := 32
const RECT := Rect2(-20.0, 12.0, 90.0, 70.0)
const TOL := 1.0e-3 # GPU float vs CPU float/double intermediates

var _fail := 0


func _ready() -> void:
	print("=== GraphGpuParityGate: GPU whole-graph evaluator vs CPU oracle ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		print("!! Pasture3DUtil.graph_eval_grid_gpu is missing — the DLL is stale; rebuild the extension.")
		_finish(1); return
	# Availability probe: an empty return means no local RenderingDevice (headless / no driver).
	var probe := _gpu(_io([]), _ramp(1.0))
	if probe.is_empty():
		print("GPU unavailable (no local RenderingDevice — running --headless?). SKIPPING.")
		print("Run WITHOUT --headless on a machine with a GPU to actually verify GPU/CPU parity.")
		_finish(0); return

	_a_identity()
	_b_smooth()
	_c_add_noise()
	_d_generator_with_grid_barrier()
	_e_blend_modes()
	_finish(_fail)


func _finish(p_code: int) -> void:
	print("\n=== %s (%d failures) ===\n" % ["GRAPH GPU PARITY PASS" if _fail == 0 else "GRAPH GPU PARITY FAIL", _fail])
	get_tree().quit(0 if p_code == 0 and _fail == 0 else 1)


# --- A. Input -> Output identity ----------------------------------------------------------------------
func _a_identity() -> void:
	print("[A] Input -> Output identity: GPU == surface == CPU")
	var g := _io([])
	var surf := _ramp(3.0)
	_check(g, surf, "identity")
	var moved := _maxdiff(_gpu(g, surf), _gpu(g, _ramp(8.0)))
	print("    control: a different surface moves the GPU output by %.3f (want > 0.05)" % moved)
	if moved <= 0.05:
		_fail += 1; print("    !! control dead — the GPU is not reading the input")


# --- B. Input -> Smooth -> Output == the NaN-aware blur ------------------------------------------------
func _b_smooth() -> void:
	print("[B] Input -> Smooth -> Output: GPU == blur_nan == CPU")
	var sm := Pasture3DGraphNodeSmooth.new(); sm.passes = 3
	var g := _io([sm])
	var surf := _ramp(5.0)
	_check(g, surf, "smooth")
	var gpu := _gpu(g, surf)
	var changed := _maxdiff(gpu, surf)
	print("    control: the GPU smooth moved the surface by %.3f (want > 0.01)" % changed)
	if changed <= 0.01:
		_fail += 1; print("    !! the GPU Smooth passed the surface straight through")


# --- C. Input -> Blend(ADD) <- Noise -> Output --------------------------------------------------------
func _c_add_noise() -> void:
	print("[C] Input -> Blend(ADD) <- Noise -> Output: GPU == CPU")
	var noise := _make_noise(7, 0.05)
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), _noise(noise, 6.0),
		_blend(Pasture3DGraphNodeBlend.Mode.ADD), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [_c4(0, 0, 2, 0), _c4(1, 0, 2, 1), _c4(2, 0, 3, 0)]
	_check(g, _ramp(4.0), "add-noise")


# --- D. A generator with a grid barrier (Noise -> Smooth -> Output) ------------------------------------
func _d_generator_with_grid_barrier() -> void:
	print("[D] Noise -> Smooth -> Output (no Input): GPU == CPU")
	var g := Pasture3DTerrainGraph.new()
	var sm := Pasture3DGraphNodeSmooth.new(); sm.passes = 2
	var nodes: Array[Pasture3DGraphNode] = [_noise(_make_noise(3, 0.06), 9.0), sm, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [_c4(0, 0, 1, 0), _c4(1, 0, 2, 0)]
	_check(g, _ramp(5.0), "gen-barrier")


# --- E. Every blend mode matches on the GPU -----------------------------------------------------------
func _e_blend_modes() -> void:
	print("[E] each blend mode: GPU == CPU (diamond A op B, A=Input surface, B=Noise)")
	var modes := {
		"ADD": Pasture3DGraphNodeBlend.Mode.ADD, "SUB": Pasture3DGraphNodeBlend.Mode.SUB,
		"MUL": Pasture3DGraphNodeBlend.Mode.MUL, "MAX": Pasture3DGraphNodeBlend.Mode.MAX,
		"MIN": Pasture3DGraphNodeBlend.Mode.MIN,
	}
	var surf := _ramp(4.0)
	for name in modes:
		var g := Pasture3DTerrainGraph.new()
		var nodes: Array[Pasture3DGraphNode] = [
			Pasture3DGraphNodeInput.new(), _noise(_make_noise(9, 0.06), 5.0),
			_blend(modes[name]), Pasture3DGraphNodeOutput.new()]
		g.nodes = nodes
		g.connections = [_c4(0, 0, 2, 0), _c4(1, 0, 2, 1), _c4(2, 0, 3, 0)]
		var d := _maxdiff(_gpu(g, surf), _cpu(g, surf))
		print("    %-4s GPU vs CPU = %.7f (want < %.6f)" % [name, d, TOL])
		if d > TOL:
			_fail += 1; print("    !! GPU diverged from CPU on blend mode %s" % name)


# ---- helpers ----------------------------------------------------------------------------------------

func _check(p_g: Pasture3DTerrainGraph, p_surf: PackedFloat32Array, p_name: String) -> void:
	var gpu := _gpu(p_g, p_surf)
	var cpu := _cpu(p_g, p_surf)
	var d := _maxdiff(gpu, cpu)
	print("    %-12s GPU vs CPU = %.7f (want < %.6f)" % [p_name, d, TOL])
	if d > TOL:
		_fail += 1; print("    !! GPU diverged from the CPU oracle on '%s'" % p_name)


func _gpu(p_g: Pasture3DTerrainGraph, p_surf: PackedFloat32Array) -> PackedFloat32Array:
	return Pasture3DUtil.graph_eval_grid_gpu(p_g.compile_graph_program(), GW, GH, RECT, p_surf)


func _cpu(p_g: Pasture3DTerrainGraph, p_surf: PackedFloat32Array) -> PackedFloat32Array:
	return Pasture3DUtil.graph_eval_grid(p_g.compile_graph_program(), GW, GH, RECT, p_surf)


func _io(p_mid: Array) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new()]
	for m in p_mid:
		nodes.append(m)
	nodes.append(Pasture3DGraphNodeOutput.new())
	g.nodes = nodes
	var conns: Array = []
	for i in range(nodes.size() - 1):
		conns.append(_c4(i, 0, i + 1, 0))
	g.connections = conns
	return g


func _c4(a: int, b: int, c: int, d: int) -> PackedInt32Array:
	return PackedInt32Array([a, b, c, d])


func _noise(p_noise: FastNoiseLite, p_a: float) -> Pasture3DGraphNodeNoise:
	var n := Pasture3DGraphNodeNoise.new(); n.noise = p_noise; n.amplitude = p_a
	return n


func _blend(p_mode) -> Pasture3DGraphNodeBlend:
	var n := Pasture3DGraphNodeBlend.new(); n.mode = p_mode
	return n


func _make_noise(p_seed: int, p_freq: float) -> FastNoiseLite:
	var n := FastNoiseLite.new(); n.seed = p_seed; n.frequency = p_freq
	return n


func _ramp(p_scale: float) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			s[iz * GW + ix] = p_scale * (float(ix) / GW + float(iz) / GH)
	return s


func _maxdiff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m
