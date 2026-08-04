# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# A water body must find its Pasture3DPoolManager whatever order the two enter the tree.
#
# Registration used to happen once, in _ready and ENTER_TREE, and was never retried. Sibling
# order therefore decided it: a Pasture3DPool sitting ABOVE the manager in the scene ran its
# one attempt against an empty group, registered with nothing, and stayed invisible to
# body_at() for the life of the scene — a buoy floating on it got no body and fell through —
# while also missing every profiles_changed. Pasture3DOcean had the identical defect and
# WaterBodiesPhase2Gate never caught either, because every fixture in the suite happens to
# build its manager first.
#
# The two orders are each other's control in the ordinary sense, but the one that matters is
# criterion C: it pins the retry as the thing doing the work, so this cannot pass for the
# wrong reason if registration were ever moved back to a once-only act that merely got lucky
# with ordering.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/WaterBodyLateManagerCheck.tscn
extends Node

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const LAKE_MAT := WATER_DIR + "M_water_lake.tres"

var _fail := 0


func _ready() -> void:
	print("\n=== water body registration is order-independent ===\n")
	await _check_body_first()
	await _check_manager_first()
	await _check_retry_is_what_registers()
	await _check_ocean_body_first()

	print("")
	if _fail == 0:
		print("=== LATE MANAGER CHECK PASS ===")
	else:
		print("=== LATE MANAGER CHECK FAIL (%d) ===" % _fail)
	get_tree().quit(1 if _fail > 0 else 0)


## The bug, stated directly: the pool enters the tree BEFORE the manager exists.
func _check_body_first() -> void:
	print("[A] pool added before the manager:")
	var root := Node3D.new()
	add_child(root)
	var pool := _make_pool(root)
	# Nothing to find yet — this is the state the old code registered against and never revisited.
	var manager := _make_manager(root)
	await _run_physics(4)

	var bodies := manager.get_bodies()
	var listed := bodies.has(pool)
	print("    manager.get_bodies() holds the pool: %s" % listed)
	if not listed:
		_fail += 1
		print("    !! the pool never registered — body_at() cannot return it and buoys fall through")

	# The registry is only half of it: the signal is what carries a profile edit to the mesh.
	var connected: bool = manager.profiles_changed.is_connected(pool._on_profiles_changed)
	print("    profiles_changed connected: %s" % connected)
	if not connected:
		_fail += 1
		print("    !! the pool will not hear a profile change")

	# And the thing the registry exists for.
	var found := manager.body_at(pool.global_position + Vector3(0, -1, 0))
	print("    body_at() a point inside it: %s" % (found.name if found else "<null>"))
	if found != pool:
		_fail += 1
		print("    !! body_at() does not return the pool")
	root.queue_free()
	await _run_physics(2)


## The order that always worked. Present so a regression that broke it is not mistaken for a
## fix to the other one.
func _check_manager_first() -> void:
	print("\n[B] CONTROL, manager added before the pool (the order that always worked):")
	var root := Node3D.new()
	add_child(root)
	var manager := _make_manager(root)
	var pool := _make_pool(root)
	await _run_physics(4)

	var listed := manager.get_bodies().has(pool)
	print("    manager.get_bodies() holds the pool: %s" % listed)
	if not listed:
		_fail += 1
		print("    !! regression: the working order stopped working")
	root.queue_free()
	await _run_physics(2)


## Pins WHY [A] passes.
##
## A body added before its manager cannot be registered at _ready — there is nothing to
## register with — so it must still be unregistered before the first physics tick and
## registered after one. If both reads came back true this check would be passing on
## something other than the retry, and would keep passing if the retry were deleted.
func _check_retry_is_what_registers() -> void:
	print("\n[C] the retry is what registers it, not _ready:")
	var root := Node3D.new()
	add_child(root)
	var pool := _make_pool(root)
	var manager := _make_manager(root)
	# No physics frame has run yet: _ready has fired, the tick has not.
	var before := manager.get_bodies().has(pool)
	await _run_physics(2)
	var after := manager.get_bodies().has(pool)
	print("    registered before any physics tick: %s (must be false)" % before)
	print("    registered after:                   %s (must be true)" % after)
	if before:
		_fail += 1
		print("    !! registered at _ready — this check can no longer tell the retry is load-bearing")
	if not after:
		_fail += 1
		print("    !! never registered")
	root.queue_free()
	await _run_physics(2)


## The same defect in the C++ node, which got the same fix.
func _check_ocean_body_first() -> void:
	print("\n[D] Pasture3DOcean added before the manager:")
	var root := Node3D.new()
	add_child(root)
	var ocean := Pasture3DOcean.new()
	ocean.name = "Ocean"
	root.add_child(ocean)
	var manager := _make_manager(root)
	await _run_physics(4)

	var listed := manager.get_bodies().has(ocean)
	print("    manager.get_bodies() holds the ocean: %s" % listed)
	if not listed:
		_fail += 1
		print("    !! the ocean never registered — a buoy in open water gets no body")

	# An ocean is unbounded, so any point is a point it should answer for.
	var found := manager.body_at(Vector3(1234, -5, -678))
	print("    body_at() far out to sea: %s" % (found.name if found else "<null>"))
	if found != ocean:
		_fail += 1
		print("    !! body_at() does not fall back to the ocean")
	root.queue_free()
	await _run_physics(2)


# ---- fixtures ----------------------------------------------------------------

func _make_manager(p_root: Node3D) -> Pasture3DPoolManager:
	var m := Pasture3DPoolManager.new()
	m.name = "Pasture3DPoolManager"
	var profile := Pasture3DWaveProfile.new()
	profile.profile_name = "flat_test"
	profile.wave_count = 2
	profile.amplitude = 0.05
	profile.length_max = 60.0
	profile.steepness = 0.2
	var profiles: Array[Pasture3DWaveProfile] = [profile]
	m.profiles = profiles
	p_root.add_child(m)
	return m


func _make_pool(p_root: Node3D) -> Pasture3DPool:
	var pool := Pasture3DPool.new()
	pool.name = "Pool"
	var c := Curve3D.new()
	for p in [Vector3(-50, 0, -50), Vector3(50, 0, -50), Vector3(50, 0, 50), Vector3(-50, 0, 50)]:
		c.add_point(p)
	c.closed = true
	pool.curve = c
	pool.wave_profile = &"flat_test"
	pool.material = load(LAKE_MAT)
	pool.underwater_enabled = false
	p_root.add_child(pool)
	return pool


func _run_physics(p_ticks: int) -> void:
	for i in p_ticks:
		await get_tree().physics_frame
