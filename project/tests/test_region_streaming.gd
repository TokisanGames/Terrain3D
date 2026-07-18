extends SceneTree
## Headless test for slot-pool region streaming:
##   godot --headless --path project --script tests/test_region_streaming.gd
## Authors a 5x5 island classically, then streams it with a small pool and
## asserts ring residency, eviction, height correctness under churn, and that
## slots never leak.
var _fail := 0
var _done := false
var _t: Terrain3D
var _dir := "user://stream_test_data"


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


func _initialize() -> void:
	var d := DirAccess.open("user://")
	if d != null and d.dir_exists("stream_test_data"):
		for f in DirAccess.get_files_at(_dir):
			d.remove("stream_test_data/" + f)
	else:
		DirAccess.make_dir_recursive_absolute(_dir)
	_t = Terrain3D.new()
	root.add_child(_t)
	_t.vertex_spacing = 1.0
	process_frame.connect(_run)


func _settle(max_frames: int) -> void:
	# Threaded loads land over several frames - wait until the loaded set has
	# been stable for 15 consecutive frames (or give up at max_frames).
	var last: int = -1
	var stable := 0
	for i in range(max_frames):
		await process_frame
		# Headless never emits frame_pre_draw, so pump the instancer queue like a
		# renderer would - a no-op when nothing is queued.
		RenderingServer.emit_signal("frame_pre_draw")
		var n: int = _t.data.get_region_count()
		if n == last:
			stable += 1
			if stable >= 15:
				return
		else:
			stable = 0
			last = n


func _run() -> void:
	if _done:
		return
	_done = true
	var rs: int = _t.region_size
	var ma := Terrain3DMeshAsset.new()
	ma.set_generated_type(Terrain3DMeshAsset.TYPE_TEXTURE_CARD)
	_t.assets.set_mesh_asset(0, ma)
	var rs0: int = _t.region_size
	for y in range(-2, 3):
		for x in range(-2, 3):
			_t.data.add_region_blank(Vector2i(x, y), false)
			var r: Terrain3DRegion = _t.data.get_region(Vector2i(x, y))
			r.get_height_map().fill(Color(float(10 + x + y * 5), 0, 0)) # per-region signature height
			# Instanced meshes so streaming coverage includes the instancer.
			var xforms: Array[Transform3D] = []
			for i in 20:
				xforms.append(Transform3D(Basis(), Vector3(x * rs0 + i * 10.0 + 5.0, 10, y * rs0 + 5.0)))
			_t.instancer.add_transforms(0, xforms)
			r.set_modified(true)
	_t.data.update_maps()
	for y in range(-2, 3):
		for x in range(-2, 3):
			_t.data.save_region(Vector2i(x, y), _dir, false)
	ok(DirAccess.get_files_at(_dir).size() >= 25, "authored 25 regions on disk")
	_t.queue_free()
	await process_frame

	# Fresh terrain, STREAMING ON, small pool.
	_t = Terrain3D.new()
	var ma2 := Terrain3DMeshAsset.new()
	ma2.set_generated_type(Terrain3DMeshAsset.TYPE_TEXTURE_CARD)
	_t.assets = Terrain3DAssets.new()
	_t.assets.set_mesh_asset(0, ma2)
	_t.streaming_enabled = true
	_t.streaming_slots = 25 # required for distance 1 (moving hysteresis ring): (2*2+1)^2
	_t.streaming_distance = 1 # 3x3 = 9 loaded
	_t.data_directory = _dir
	root.add_child(_t)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.global_position = Vector3(rs * 0.5, 50, rs * 0.5) # inside region (0,0)
	_t.set_camera(cam)
	_t.set_clipmap_target(cam)
	await process_frame
	ok(_t.data.is_streaming(), "streaming mode active")
	await _settle(400)
	ok(_t.data.get_region_count() == 9, "3x3 ring loaded (%d)" % _t.data.get_region_count())
	ok(_t.data.get_free_slot_count() == 16, "free slots = capacity - loaded (%d)" % _t.data.get_free_slot_count())
	var h0: float = _t.data.get_height(Vector3(rs * 0.5, 0, rs * 0.5))
	ok(absf(h0 - 10.0) < 0.01, "region (0,0) height streamed in (%.1f)" % h0)

	# Walk the camera two regions east: ring follows, west regions evict.
	cam.global_position = Vector3(rs * 2.5, 50, rs * 0.5)
	await _settle(400)
	ok(_t.data.get_region_count() == 9, "ring size stable after move (%d)" % _t.data.get_region_count())
	ok(_t.data.has_region(Vector2i(2, 0)), "east region loaded")
	ok(not _t.data.has_region(Vector2i(-2, 0)), "west region evicted")
	var h2: float = _t.data.get_height(Vector3(rs * 2.5, 0, rs * 0.5))
	ok(absf(h2 - 12.0) < 0.01, "east region heights correct after churn (%.1f)" % h2)
	ok(_t.instancer.get_mmi_region_count() == _t.data.get_region_count(),
			"instancer MMIs match residency after churn (%d/%d)" % [
			_t.instancer.get_mmi_region_count(), _t.data.get_region_count()])

	# Churn stress: 60 random hops; slots must never leak.
	seed(7)
	for i in range(60):
		var fx := randi_range(-2, 2)
		var fy := randi_range(-2, 2)
		cam.global_position = Vector3((fx + 0.5) * rs, 50, (fy + 0.5) * rs)
		for f in range(10):
			await process_frame
	await _settle(400)
	ok(_t.data.get_region_count() == 9, "ring settled after churn (%d)" % _t.data.get_region_count())
	ok(_t.data.get_free_slot_count() + _t.data.get_region_count() == 25, "no slot leaked (%d+%d)" % [
			_t.data.get_free_slot_count(), _t.data.get_region_count()])
	# Runtime modification survives eviction: edit a resident region, walk away so
	# it evicts (saving back to disk), walk back and expect the edit streamed in.
	cam.global_position = Vector3(rs * 0.5, 50, rs * 0.5)
	await _settle(400)
	_t.data.set_height(Vector3(10.0, 0, 10.0), 44.0)
	cam.global_position = Vector3(rs * 6.5, 50, rs * 0.5) # far east, (0,0) evicts
	await _settle(400)
	ok(not _t.data.has_region(Vector2i(0, 0)), "modified region evicted")
	cam.global_position = Vector3(rs * 0.5, 50, rs * 0.5)
	await _settle(400)
	var hm: float = _t.data.get_height(Vector3(10.0, 0, 10.0))
	ok(absf(hm - 44.0) < 0.01, "runtime edit saved on eviction and streamed back (%.1f)" % hm)

	# Circular shape: at distance 1 only the target region and its four orthogonal
	# neighbors are requested (corners are outside the circle).
	_t.streaming_shape = Terrain3DStreamer.CIRCLE
	cam.global_position = Vector3(-rs * 0.5, 50, -rs * 0.5) # inside region (-1,-1)
	await _settle(400)
	for loc in [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(-2, -1), Vector2i(-1, 0), Vector2i(-1, -2)]:
		ok(_t.data.has_region(loc), "circle: core region %s loaded" % loc)
	ok(not _t.data.has_region(Vector2i(2, 2)), "circle: far corner evicted")
	ok(_t.data.get_region_count() <= 13, "circle: residency bounded by hysteresis disc (%d)" % _t.data.get_region_count())
	# RAM mode: eviction parks bodies in the cache, revisits reinsert from RAM,
	# and a runtime edit survives the round trip without touching the disk.
	_t.streaming_shape = Terrain3DStreamer.SQUARE
	_t.streaming_mode = Terrain3DStreamer.RAM
	cam.global_position = Vector3(rs * 0.5, 50, rs * 0.5)
	await _settle(400)
	_t.data.set_height(Vector3(20.0, 0, 20.0), 55.0)
	cam.global_position = Vector3(rs * 6.5, 50, rs * 0.5)
	await _settle(400)
	ok(not _t.data.has_region(Vector2i(0, 0)), "ram: region evicted from GPU")
	ok(int(_t.get_streaming_stats().get("ram_cached", 0)) > 0, "ram: bodies cached (%d)" % int(_t.get_streaming_stats().get("ram_cached", 0)))
	cam.global_position = Vector3(rs * 0.5, 50, rs * 0.5)
	await _settle(400)
	var hr: float = _t.data.get_height(Vector3(20.0, 0, 20.0))
	ok(absf(hr - 55.0) < 0.01, "ram: edit survived cache round trip (%.1f)" % hr)
	_t.streaming_mode = Terrain3DStreamer.DISK

	# Runtime toggle: disabling live falls back to the classic full load, and
	# re-enabling streams again. Neither direction may crash or leak loads.
	_t.streaming_enabled = false
	await _settle(400)
	ok(not _t.data.is_streaming(), "toggle: classic mode after live disable")
	ok(_t.data.get_region_count() == 25, "toggle: full world loaded classically (%d)" % _t.data.get_region_count())
	_t.streaming_enabled = true
	await _settle(400)
	ok(_t.data.is_streaming(), "toggle: streaming again after live enable")
	ok(_t.data.get_region_count() < 25, "toggle: ring residency restored (%d)" % _t.data.get_region_count())

	# Every option must switch live and clean up after itself.
	# Slots: the pool is rebuilt live at the new capacity (needed below: distance 2
	# retains up to (2*3+1)^2 = 49 regions with hysteresis, which also exercises
	# the capacity guard boundary exactly).
	cam.global_position = Vector3(rs * 0.5, 50, rs * 0.5)
	await _settle(400)
	_t.streaming_slots = 49 # required for distance 2: (2*3+1)^2
	await _settle(400)
	ok(_t.data.get_slot_capacity() == 49, "live slots: pool rebuilt (%d)" % _t.data.get_slot_capacity())
	ok(_t.data.get_region_count() == 9, "live slots: ring reloaded after rebuild (%d)" % _t.data.get_region_count())

	# Distance grow then shrink: residency follows.
	_t.streaming_distance = 2
	await _settle(400)
	ok(_t.data.get_region_count() == 25, "live distance: grew to 5x5 (%d)" % _t.data.get_region_count())
	_t.streaming_distance = 1
	# Hysteresis keeps regions within distance+1 until the target moves; a
	# teleport cycle makes the shrink deterministic.
	cam.global_position = Vector3(rs * 6.5, 50, rs * 0.5)
	await _settle(400)
	cam.global_position = Vector3(rs * 0.5, 50, rs * 0.5)
	await _settle(400)
	ok(_t.data.get_region_count() == 9, "live distance: shrank to 3x3 (%d)" % _t.data.get_region_count())

	# Shape square -> circle: hysteresis retains the old corners in place, so
	# force a fresh area with a teleport; the circle then excludes corners.
	_t.streaming_shape = Terrain3DStreamer.CIRCLE
	cam.global_position = Vector3(rs * 6.5, 50, rs * 0.5)
	await _settle(400)
	cam.global_position = Vector3(rs * -0.5, 50, rs * -0.5) # region (-1,-1)
	await _settle(400)
	ok(not _t.data.has_region(Vector2i(0, 0)), "live shape: corner outside circle (count %d)" % _t.data.get_region_count())
	_t.streaming_shape = Terrain3DStreamer.SQUARE
	await _settle(400)
	ok(_t.data.has_region(Vector2i(0, 0)), "live shape: corner loaded again (square)")

	# Concurrent loads and loads_per_frame are per frame reads; smoke them live.
	_t.streaming_concurrent_loads = 1
	_t.streaming_loads_per_frame = 2
	cam.global_position = Vector3(rs * 1.5, 50, rs * 1.5)
	await _settle(400)
	for y in range(0, 3):
		for x in range(0, 3):
			ok(_t.data.has_region(Vector2i(x, y)), "live budgets: ring region (%d,%d) present" % [x, y])

	# Capacity guard, both ways. Raising distance grows the pool to fit rather than
	# starving loading (the "distance 15 loses regions" report); lowering slots
	# below what the current distance needs clamps distance back down.
	var streamer: Terrain3DStreamer = _t.get_streamer()
	ok(streamer.get_required_slots(4) == 121, "guard: square d4 needs 121 slots (%d)" % streamer.get_required_slots(4))
	# Raising distance auto-grows slots.
	_t.streaming_shape = Terrain3DStreamer.SQUARE
	_t.streaming_slots = 25
	_t.streaming_distance = 1
	_t.streaming_distance = 6
	ok(_t.streaming_distance == 6, "guard: distance 6 accepted (%d)" % _t.streaming_distance)
	ok(streamer.get_slots() == 225, "guard: slots grew to fit distance 6 (%d)" % streamer.get_slots())
	# Square beyond the 1024 ceiling caps distance at 14, not silent starvation.
	_t.streaming_distance = 15
	ok(_t.streaming_distance == 14, "guard: square distance 15 caps at 14 (%d)" % _t.streaming_distance)
	ok(streamer.get_slots() <= 1024, "guard: slots stay within ceiling (%d)" % streamer.get_slots())
	# A circle of the same distance needs fewer slots.
	_t.streaming_shape = Terrain3DStreamer.CIRCLE
	ok(streamer.get_required_slots(6) < 225, "guard: circle d6 needs fewer than square (%d)" % streamer.get_required_slots(6))
	# Explicitly lowering slots pulls distance down.
	_t.streaming_shape = Terrain3DStreamer.SQUARE
	_t.streaming_distance = 4 # slots grow to 121
	_t.streaming_slots = 49 # only holds distance 2
	ok(_t.streaming_distance == 2, "guard: lowering slots clamps distance (%d)" % _t.streaming_distance)

	# The on-disk known-set stays fresh as regions are created and deleted.
	# (7,7) is outside the authored 5x5, so the scan never seeded it.
	var kloc := Vector2i(7, 7)
	ok(not _t.has_region_on_disk(kloc), "known-set: unauthored location absent")
	_t.data.add_region_blank(kloc, false)
	_t.data.save_region(kloc, _dir, false)
	ok(_t.has_region_on_disk(kloc), "known-set: created region marked on disk")
	_t.data.remove_regionl(kloc, false)
	_t.data.save_region(kloc, _dir, false)
	ok(not _t.has_region_on_disk(kloc), "known-set: deleted region cleared from disk")

	print("SUITE ", "GREEN" if _fail == 0 else "RED (%d)" % _fail)
	quit(_fail)
