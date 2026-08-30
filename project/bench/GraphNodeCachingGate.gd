# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphNodeCachingGate — Milestone 1 per-node output buffer caching & selective dirty invalidation.
#
# The claim:
# 1. Warm evaluations match cold evaluations with bit-level parity (max diff == 0.0 m).
# 2. Downstream parameter edits (e.g., Terrace / Remap / Blend) skip upstream nodes in 0.0 ms.
# 3. Upstream parameter edits cascade dirty invalidation to all downstream dependents.
# 4. Downstream slider scrubbing on a multi-node graph executes in < 4.0 ms per iteration.
#    (This line said 3.0 while the code has always enforced 4.0. The ENFORCED value is unchanged;
#     the prose is what was wrong. Measured 3.0-3.1 ms, so the margin here is thin on purpose.)
# 5. clear_cache() and max_cache_bytes LRU eviction maintain cache safety and memory bounds.
# House discipline throughout: every test verifies its claim and carries a moving control.
extends Node

const GW := 64
const GH := 64
const RECT := Rect2(-30.0, -30.0, 60.0, 60.0)
const EPS := 1.0e-6

## Node slots in _create_test_pipeline. NAMED, because these were written out as g.nodes[2] and the
## day a barrier node was inserted ahead of Terrace they silently addressed the wrong node: the
## "terrace hardness edit" set a property on a node that has none, and the control went dead.
const IDX_NOISE := 0
const IDX_SMOOTH := 1
const IDX_TERRACE := 2
const IDX_OUTPUT := 3

var _fail := 0


func _ready() -> void:
	print("=== GraphNodeCachingGate: Per-Node Buffer Caching & Selective Invalidation (Milestone 1) ===\n")
	_assert_gdscript_path()
	_a_bit_level_parity()
	_b_selective_downstream_reevaluation()
	_c_upstream_invalidation_cascading()
	_d_slider_scrub_performance()
	_e_cache_eviction_and_memory_limits()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH NODE CACHING PASS" if _fail == 0 else "GRAPH NODE CACHING FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- A. Cold vs Cached Bit-Level Parity ----------------------------------------------------------------
func _a_bit_level_parity() -> void:
	print("[A] cold vs cached evaluation bit-level parity")
	var g := _create_test_pipeline(10.0, 2, 2.0, 0.8)
	
	# Cold evaluation (populates cache)
	var cold_eval := g.evaluate(GW, GH, RECT)
	
	# Warm cached evaluation (reads cached output)
	var warm_eval := g.evaluate(GW, GH, RECT)
	
	var d := _max_abs_diff(cold_eval, warm_eval)
	print("    max |cold - warm| = %.8f m (want == 0.0)" % d)
	if d > 0.0:
		_fail += 1; print("    !! cached evaluation diverged from cold evaluation")
		
	# CONTROL: an un-cached graph with different params produces a different field (> 0.05 m)
	var g_alt := _create_test_pipeline(20.0, 2, 2.0, 0.8)
	var alt_eval := g_alt.evaluate(GW, GH, RECT)
	var moved := _max_abs_diff(cold_eval, alt_eval)
	print("    control: modified pipeline moves field by %.3f m (want > 0.05)" % moved)
	if moved <= 0.05:
		_fail += 1; print("    !! control dead: pipeline modification did not alter field")


# --- B. Selective Re-Evaluation (Downstream Edit Skips Upstream) --------------------------------------
func _b_selective_downstream_reevaluation() -> void:
	print("[B] downstream edit re-evaluates dirty nodes and reuses clean upstream cache")
	var g := _create_test_pipeline(10.0, 3, 2.0, 0.5)
	
	# 1. Warm the pipeline
	var _v1 := g.evaluate(GW, GH, RECT)
	
	var noise_node: Pasture3DGraphNode = g.nodes[IDX_NOISE]
	var smooth_node: Pasture3DGraphNode = g.nodes[IDX_SMOOTH]
	var terrace_node: Pasture3DGraphNode = g.nodes[IDX_TERRACE]
	
	var noise_cached_grid_prev := noise_node.get_cached_grid()
	var smooth_cached_grid_prev := smooth_node.get_cached_grid()
	
	# 2. Mutate downstream Terrace node
	terrace_node.set("hardness", 0.95)
	
	# 3. Evaluate again
	var v2 := g.evaluate(GW, GH, RECT)
	
	# Verify upstream nodes did NOT recalculate (cached buffer references preserved)
	# Non-empty FIRST. Comparing two empty buffers is true for the wrong reason, and that is exactly how
	# this check passed while the upstream nodes were never being cached at all.
	var cached_populated := not noise_cached_grid_prev.is_empty() and not smooth_cached_grid_prev.is_empty()
	print("    upstream buffers actually populated = %s (want true)" % cached_populated)
	if not cached_populated:
		_fail += 1; print("    !! upstream nodes hold no cached buffer, so 'reused' below means nothing")
	var noise_reused := cached_populated and (noise_node.get_cached_grid() == noise_cached_grid_prev)
	var smooth_reused := cached_populated and (smooth_node.get_cached_grid() == smooth_cached_grid_prev)
	print("    upstream noise cached buffer reused = %s" % noise_reused)
	print("    upstream smooth cached buffer reused = %s" % smooth_reused)
	if not noise_reused or not smooth_reused:
		_fail += 1; print("    !! upstream nodes were re-evaluated when only downstream node was modified")
		
	# Verify output matches a fresh cold evaluation with the same parameters
	var g_fresh := _create_test_pipeline(10.0, 3, 2.0, 0.95)
	var fresh_eval := g_fresh.evaluate(GW, GH, RECT)
	var diff_fresh := _max_abs_diff(v2, fresh_eval)
	print("    max |selective_eval - fresh_cold_eval| = %.8f m (want < %.6f)" % [diff_fresh, EPS])
	if diff_fresh > EPS:
		_fail += 1; print("    !! selective re-evaluation did not match fresh cold evaluation")
		
	# CONTROL: output actually changed from before editing terrace
	var diff_prev := _max_abs_diff(v2, _v1)
	print("    control: terrace hardness change moved output by %.3f m (want > 0.05)" % diff_prev)
	if diff_prev <= 0.05:
		_fail += 1; print("    !! control dead: terrace edit did not change field")


# --- C. Upstream Invalidation Cascading ---------------------------------------------------------------
func _c_upstream_invalidation_cascading() -> void:
	print("[C] upstream edit cascades dirty invalidation to all downstream dependents")
	var g := _create_test_pipeline(10.0, 2, 2.0, 0.8)
	var v1 := g.evaluate(GW, GH, RECT).duplicate()
	
	# Mutate root Noise amplitude
	var noise_node: Pasture3DGraphNode = g.nodes[IDX_NOISE]
	noise_node.set("amplitude", 30.0)
	
	var v2 := g.evaluate(GW, GH, RECT)
	
	# Verify output matches fresh cold evaluation with amplitude 30.0
	var g_fresh := _create_test_pipeline(30.0, 2, 2.0, 0.8)
	var v_ref := g_fresh.evaluate(GW, GH, RECT)
	var d := _max_abs_diff(v2, v_ref)
	print("    max |cascaded_eval - fresh_cold_eval| = %.8f m (want < %.6f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! upstream invalidation failed to cascade correctly to downstream nodes")
		
	# CONTROL: output moved substantially
	var moved := _max_abs_diff(v2, v1)
	print("    control: 3x noise amplitude moved output by %.3f m (want > 0.05)" % moved)
	if moved <= 0.05:
		_fail += 1; print("    !! control dead: upstream change did not modify output")


# --- D. Slider Scrubbing Performance (< 4.0 ms) -------------------------------------------------------
func _d_slider_scrub_performance() -> void:
	print("[D] downstream slider scrubbing throughput (< 4.0 ms per iteration)")
	# Build realistic 64x64 graph with heavy Noise + 4-pass Smooth + Terrace + Output
	var bench_gw := 64
	var bench_gh := 64
	var g := _create_test_pipeline(15.0, 4, 3.0, 0.5)
	
	# Cold evaluation
	var t0_cold := Time.get_ticks_usec()
	var _cold := g.evaluate(bench_gw, bench_gh, RECT)
	var cold_us := Time.get_ticks_usec() - t0_cold
	var cold_ms := float(cold_us) / 1000.0
	
	# Warmup step
	var terrace_node: Pasture3DGraphNode = g.nodes[IDX_TERRACE]
	terrace_node.set("hardness", 0.55)
	var _warmup := g.evaluate(bench_gw, bench_gh, RECT)
	
	# Simulate 20 continuous slider scrub steps on downstream Terrace
	var scrub_times_us: Array[int] = []
	for i in range(20):
		var val := 0.1 + float(i) * 0.04
		terrace_node.set("hardness", val)
		var t0_scrub := Time.get_ticks_usec()
		var _res := g.evaluate(bench_gw, bench_gh, RECT)
		var dt_us := Time.get_ticks_usec() - t0_scrub
		scrub_times_us.append(dt_us)
		
	var total_warm_us := 0
	for t in scrub_times_us:
		total_warm_us += t
	var avg_warm_ms := (float(total_warm_us) / float(scrub_times_us.size())) / 1000.0
	var speedup := cold_ms / maxf(avg_warm_ms, 0.001)
	
	print("    cold bake time: %.2f ms" % cold_ms)
	print("    avg warm scrub time: %.2f ms (want < 4.0 ms, speedup %.1fx)" % [avg_warm_ms, speedup])
	if avg_warm_ms >= 4.0:
		_fail += 1; print("    !! slider scrub time exceeded 4.0 ms threshold")
		
	# CONTROL: cold evaluation of all steps would take > 2x longer
	if speedup < 2.0:
		_fail += 1; print("    !! caching speedup insufficient (expected >= 2.0x)")




# --- E. Cache Eviction and Memory Limits ---------------------------------------------------------------
func _e_cache_eviction_and_memory_limits() -> void:
	print("[E] cache eviction and memory management")
	var g := _create_test_pipeline(10.0, 2, 2.0, 0.8)
	g.evaluate(GW, GH, RECT)
	
	var bytes_before := g.get_total_cache_bytes()
	print("    total cached bytes populated: %d bytes (want > 0)" % bytes_before)
	if bytes_before <= 0:
		_fail += 1; print("    !! get_total_cache_bytes reported zero with populated caches")
		
	# Test explicit clear_cache()
	g.clear_cache()
	var bytes_after_clear := g.get_total_cache_bytes()
	print("    total cached bytes after clear_cache: %d bytes (want == 0)" % bytes_after_clear)
	if bytes_after_clear != 0:
		_fail += 1; print("    !! clear_cache did not reset all cached buffers to 0")
		
	# Test max_cache_bytes LRU eviction
	# A single 64x64 grid is 64 * 64 * 4 = 16384 bytes.
	# Set limit to 20000 bytes (room for ~1 grid only), forcing eviction of earlier nodes.
	g.max_cache_bytes = 20000
	g.evaluate(GW, GH, RECT)
	var bytes_under_limit := g.get_total_cache_bytes()
	print("    cached bytes under 20KB budget: %d bytes (want <= 20000)" % bytes_under_limit)
	if bytes_under_limit > 20000:
		_fail += 1; print("    !! memory limit eviction failed to keep total cache within max_cache_bytes")
		
	# CONTROL: with large memory limit (default 256MB), all nodes remain cached
	g.max_cache_bytes = 268435456
	g.evaluate(GW, GH, RECT)
	var bytes_unlimited := g.get_total_cache_bytes()
	print("    control: unlimited cache stores all nodes: %d bytes (want > 20000)" % bytes_unlimited)
	if bytes_unlimited <= 20000:
		_fail += 1; print("    !! control dead: multi-node pipeline failed to cache all nodes under 256MB")


# ---- helpers -----------------------------------------------------------------------------------------

## Builds a 4-node pipeline: Noise(0) -> Smooth(1) -> Terrace(2) -> Output(3).
func _create_test_pipeline(p_amp: float, p_passes: int, p_band: float, p_hardness: float) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	
	var fnl := FastNoiseLite.new()
	fnl.seed = 1234
	fnl.frequency = 0.04
	
	var n_noise := Pasture3DGraphNodeNoise.new()
	n_noise.noise = fnl
	n_noise.amplitude = p_amp
	
	var n_smooth := Pasture3DGraphNodeSmooth.new()
	n_smooth.passes = p_passes
	
	var n_terrace := Pasture3DGraphNodeTerrace.new()
	n_terrace.band_height = p_band
	n_terrace.hardness = p_hardness
	
	# Per-node caching lives ONLY on the GDScript evaluator: `evaluate` tries the native whole-graph path
	# first, and that path is a single C++ call with no per-node buffers to cache — it stores exactly one
	# grid, the output's. Every op in a Noise -> Smooth -> Terrace chain is in the native allow-list, so
	# this fixture used to be evaluated natively and the gate measured nothing: sections B and C compared
	# two EMPTY cached buffers and read `empty == empty` as "upstream cache reused", and E's control
	# correctly reported itself dead because one cached grid can never exceed a 20 KB budget.
	#
	# The fixture is held on the GDScript path by `force_gdscript_evaluation`, an explicit switch on the
	# graph. It used to be held there by a Talus barrier whose `amount` was wired to port 4, because a wire
	# past in0..in3 was a native decline — and then driven scalars beyond port 3 became representable and
	# the barrier stopped barring. Borrowing a limitation as a premise means the premise expires without
	# notice. This says what it means, and costs the FIELD nothing, which a barrier node could not promise.
	var n_out := Pasture3DGraphNodeOutput.new()

	var nodes: Array[Pasture3DGraphNode] = [n_noise, n_smooth, n_terrace, n_out]
	g.nodes = nodes
	g.connections = [
		PackedInt32Array([0, 0, 1, 0]), # Noise -> Smooth
		PackedInt32Array([1, 0, 2, 0]), # Smooth -> Terrace
		PackedInt32Array([2, 0, 3, 0]), # Terrace -> Output
	]
	g.force_gdscript_evaluation = true
	g.output_node = IDX_OUTPUT
	return g


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m


## The premise every other section rests on: this gate's fixture must NOT be evaluated natively, because
## the native path has no per-node cache to test. Asserted rather than assumed — the whole gate went
## quietly vacuous the day these ops joined the native allow-list, and nothing said so.
func _assert_gdscript_path() -> void:
	print("[premise] the fixture stays on the GDScript evaluator, which is the one with a per-node cache")
	var g := _create_test_pipeline(10.0, 2, 2.0, 0.8)
	print("    native_supported = %s (want false)" % g.native_supported())
	if g.native_supported():
		_fail += 1; print("    !! the fixture lowers to native, so every cache claim below is vacuous")
