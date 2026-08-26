# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphGpuBenchGate — measure the GPU/CPU crossover for the whole-graph evaluator, to SET the live-bake
# threshold (graph_gpu_threshold / ProjectSettings pasture_3d/performance/graph_gpu_threshold).
#
# This is a PERFORMANCE bench, not a correctness gate: it times graph_eval_grid (CPU) against
# graph_eval_grid_gpu (force-GPU) across grid sizes for a few representative graph shapes, and reports the
# smallest cell count at which the GPU wins. That crossover is what graph_gpu_threshold() defaults to.
#
# RUN NON-HEADLESS: the force-GPU path needs a local RenderingDevice (the dummy headless driver has none).
# Under --headless the GPU call returns empty and this bench SKIPS. NOT registered in gates.txt — it
# measures timing, not a field delta, so it has nothing to assert in CI.
#
# Run: Godot_v4.7-stable_win64_console.exe --path <abs project> res://bench/GraphGpuBenchGate.tscn  (no --headless)
extends Node

# Side lengths to sweep; cells = side*side. Spans the trivial-brush..huge-brush range.
const SIDES := [64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048]
const RECT := Rect2(-500.0, -500.0, 1000.0, 1000.0)
const REPS := 7 # per measurement; report the MIN (least contended = truest compute cost)


func _ready() -> void:
	print("=== GraphGpuBenchGate: GPU/CPU crossover for the whole-graph evaluator ===\n")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		print("!! Pasture3DUtil.graph_eval_grid_gpu missing — the DLL is stale; rebuild the extension.")
		get_tree().quit(1); return
	# Availability + warm-up: the first GPU call compiles the shader; do it OUTSIDE any timed region.
	var warm := Pasture3DUtil.graph_eval_grid_gpu(_g_smooth(2).compile_graph_program(), 64, 64, RECT, _ramp(64, 64))
	if warm.is_empty():
		print("GPU unavailable (no local RenderingDevice — running --headless?). SKIPPING the bench.")
		get_tree().quit(0); return

	var shapes := {
		"identity  (In->Out)": _g_identity(),
		"smooth2   (In->Smooth2->Out)": _g_smooth(2),
		"smooth4   (In->Smooth4->Out)": _g_smooth(4),
		"mixed     (In+Noise->Blend->Smooth2->Out)": _g_mixed(),
	}
	var crossovers := {}
	for label in shapes:
		crossovers[label] = _sweep(label, shapes[label])

	print("\n=== crossovers (smallest cells where GPU beats CPU) ===")
	for label in crossovers:
		var c: int = crossovers[label]
		print("    %-42s %s" % [label, "never (CPU wins to 2048^2)" if c < 0 else "%d cells (~%d^2)" % [c, int(sqrt(float(c)))]])
	# The live-bake threshold gates ALL graph shapes with ONE cell count. A real filter does grid work, so
	# use the smooth2 crossover (a modest, common filter) as the recommendation; identity is sub-ms either
	# way and only runs on a FROZEN miss, so its GPU tax above threshold is negligible.
	var rec: int = crossovers["smooth2   (In->Smooth2->Out)"]
	print("\n>>> RECOMMENDED graph_gpu_threshold = %s" % ("keep GPU off (no crossover ≤ 2048^2)" if rec < 0 else "%d cells" % rec))
	print("    (set the default in graph_gpu_threshold() / ProjectSettings pasture_3d/performance/graph_gpu_threshold)\n")
	get_tree().quit(0)


# Sweep one graph across sizes; print CPU vs GPU min-of-REPS microseconds; return the first crossover cells.
func _sweep(p_label: String, p_g: Pasture3DTerrainGraph) -> int:
	print("[%s]" % p_label)
	print("    %8s %12s %12s %10s" % ["cells", "CPU us", "GPU us", "GPU/CPU"])
	var prog := p_g.compile_graph_program()
	var crossover := -1
	for side in SIDES:
		var gw: int = side
		var gh: int = side
		var cells := gw * gh
		var surf := _ramp(gw, gh)
		var cpu_us := _time_cpu(prog, gw, gh, surf)
		var gpu_us := _time_gpu(prog, gw, gh, surf)
		var ratio := float(gpu_us) / float(max(cpu_us, 1))
		var mark := ""
		if gpu_us < cpu_us and crossover < 0:
			crossover = cells
			mark = "  <-- crossover"
		print("    %8d %12d %12d %10.3f%s" % [cells, cpu_us, gpu_us, ratio, mark])
	return crossover


func _time_cpu(p_prog: Dictionary, p_gw: int, p_gh: int, p_surf: PackedFloat32Array) -> int:
	var best := 0x7FFFFFFFFFFFFFFF
	for r in range(REPS):
		var t0 := Time.get_ticks_usec()
		var _o := Pasture3DUtil.graph_eval_grid(p_prog, p_gw, p_gh, RECT, p_surf)
		best = mini(best, Time.get_ticks_usec() - t0)
	return best


func _time_gpu(p_prog: Dictionary, p_gw: int, p_gh: int, p_surf: PackedFloat32Array) -> int:
	var best := 0x7FFFFFFFFFFFFFFF
	for r in range(REPS):
		var t0 := Time.get_ticks_usec()
		var _o := Pasture3DUtil.graph_eval_grid_gpu(p_prog, p_gw, p_gh, RECT, p_surf)
		best = mini(best, Time.get_ticks_usec() - t0)
	return best


# ---- graph shapes ----------------------------------------------------------------------------------

func _g_identity() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [_c4(0, 0, 1, 0)]
	return g


func _g_smooth(p_passes: int) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var sm := Pasture3DGraphNodeSmooth.new(); sm.passes = p_passes
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), sm, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [_c4(0, 0, 1, 0), _c4(1, 0, 2, 0)]
	return g


func _g_mixed() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nz := FastNoiseLite.new(); nz.seed = 5; nz.frequency = 0.01
	var noise := Pasture3DGraphNodeNoise.new(); noise.noise = nz; noise.amplitude = 6.0
	var blend := Pasture3DGraphNodeBlend.new(); blend.mode = Pasture3DGraphNodeBlend.Mode.ADD
	var sm := Pasture3DGraphNodeSmooth.new(); sm.passes = 2
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), noise, blend, sm, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [_c4(0, 0, 2, 0), _c4(1, 0, 2, 1), _c4(2, 0, 3, 0), _c4(3, 0, 4, 0)]
	return g


func _c4(a: int, b: int, c: int, d: int) -> PackedInt32Array:
	return PackedInt32Array([a, b, c, d])


func _ramp(p_gw: int, p_gh: int) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(p_gw * p_gh)
	for iz in range(p_gh):
		for ix in range(p_gw):
			s[iz * p_gw + ix] = 4.0 * (float(ix) / p_gw + float(iz) / p_gh)
	return s
