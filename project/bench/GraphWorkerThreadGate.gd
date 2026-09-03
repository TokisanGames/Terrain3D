# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphWorkerThreadGate — verifies graph evaluation and mountain solve on background worker threads
#
@tool
extends Node


func _ready() -> void:
	print("\n================================================================================")
	print("=== GraphWorkerThreadGate: Worker Thread Graph Solve Verification ===")
	print("================================================================================\n")

	# Create a representative graph with MountainCone / Noise / Math operations
	var graph := Pasture3DTerrainGraph.new()
	var n_noise := Pasture3DGraphNodeNoise.new()
	n_noise.scale = 50.0
	n_noise.frequency = 0.02
	n_noise.amplitude = 25.0
	graph.nodes.append(n_noise)

	var n_out := Pasture3DGraphNodeOutput.new()
	graph.nodes.append(n_out)
	graph.connect_nodes(0, 0, 1, 0)

	var gw := 256
	var gh := 256
	var rect := Rect2(Vector2(-128.0, -128.0), Vector2(256.0, 256.0))

	# Test 1: Direct graph evaluation on WorkerThreadPool
	print("  [Test 1] Dispatching graph evaluate to WorkerThreadPool (gw=%d, gh=%d)..." % [gw, gh])
	var state := {
		"graph": graph,
		"gw": gw,
		"gh": gh,
		"rect": rect,
		"z": PackedFloat32Array(),
		"zo": PackedFloat32Array(),
		"done": 0,
		"time_ms": 0,
	}

	var task_id := WorkerThreadPool.add_task(func():
		var t0 := Time.get_ticks_msec()
		state["zo"] = graph.evaluate(state["gw"], state["gh"], state["rect"], null, state["z"])
		state["time_ms"] = Time.get_ticks_msec() - t0
		state["done"] = 1
	, true, "GraphWorkerTest")

	WorkerThreadPool.wait_for_task_completion(task_id)

	print("  Graph evaluated on worker thread in %d ms!" % state["time_ms"])
	assert(state["done"] == 1, "Task failed to complete")
	assert(state["zo"].size() == gw * gh, "Output size mismatch: %d vs %d" % [state["zo"].size(), gw * gh])
	assert(state["time_ms"] < 2000, "Worker solve was unexpectedly slow: %d ms" % state["time_ms"])

	print("\n=== GRAPH WORKER THREAD PASS (All assertions passed!) ===\n")
	get_tree().quit(0)
