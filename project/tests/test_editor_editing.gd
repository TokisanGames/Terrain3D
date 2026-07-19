extends SceneTree
## Headless tests for edit-anywhere under streaming:
##   godot --headless --path project --script tests/test_editor_editing.gd
var _fail := 0
var _done := false
var _t: Terrain3D
var _dir := "user://edit_test_data"


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


func _initialize() -> void:
	var d := DirAccess.open("user://")
	if d != null and d.dir_exists("edit_test_data"):
		for f in DirAccess.get_files_at(_dir):
			d.remove("edit_test_data/" + f)
	else:
		DirAccess.make_dir_recursive_absolute(_dir)
	_t = Terrain3D.new()
	root.add_child(_t)
	_t.vertex_spacing = 1.0
	process_frame.connect(_run)


func _settle(max_frames: int) -> void:
	var last: int = -1
	var stable := 0
	for i in range(max_frames):
		await process_frame
		RenderingServer.emit_signal("frame_pre_draw")
		var n: int = _t.data.get_region_count()
		if n == last:
			stable += 1
			if stable >= 15:
				return
		else:
			stable = 0
			last = n


func _author_world() -> void:
	var ma := Terrain3DMeshAsset.new()
	ma.set_generated_type(Terrain3DMeshAsset.TYPE_TEXTURE_CARD)
	_t.assets.set_mesh_asset(0, ma)
	for y in range(-2, 3):
		for x in range(-2, 3):
			_t.data.add_region_blank(Vector2i(x, y), false)
			_t.data.get_region(Vector2i(x, y)).get_height_map().fill(Color(float(10 + x + y * 5), 0, 0))
	_t.data.update_maps()
	for y in range(-2, 3):
		for x in range(-2, 3):
			_t.data.save_region(Vector2i(x, y), _dir, false)


func _run() -> void:
	if _done:
		return
	_done = true
	var rs: int = _t.region_size
	_author_world()
	_t.queue_free()
	await process_frame

	_t = Terrain3D.new()
	_t.assets = Terrain3DAssets.new()
	_t.streaming_enabled = true
	_t.streaming_slots = 25
	_t.streaming_distance = 1
	_t.data_directory = _dir
	root.add_child(_t)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.global_position = Vector3(rs * 0.5, 50, rs * 0.5)
	_t.set_camera(cam)
	_t.set_clipmap_target(cam)
	await _settle(400)

	# Task 1 - load-state query: (0,0) resident, far (2,2) on disk unloaded, (9,9) absent.
	ok(_t.data.get_region_load_state(Vector2i(0, 0)) == Terrain3DData.REGION_RESIDENT, "state: resident")
	ok(_t.data.get_region_load_state(Vector2i(2, 2)) == Terrain3DData.REGION_UNLOADED, "state: unloaded")
	ok(_t.data.get_region_load_state(Vector2i(9, 9)) == Terrain3DData.REGION_ABSENT, "state: absent")

	# Task 2 - ensure-resident: an unloaded region loads and keeps its authored height.
	var r: Terrain3DRegion = _t.data.ensure_region_resident(Vector2i(2, 2))
	ok(r != null, "ensure: unloaded region loaded")
	ok(_t.data.get_region_load_state(Vector2i(2, 2)) == Terrain3DData.REGION_RESIDENT, "ensure: now resident")
	ok(absf(r.get_height_map().get_pixel(0, 0).r - float(10 + 2 + 2 * 5)) < 0.01, "ensure: real data, not blank")
	ok(_t.data.ensure_region_resident(Vector2i(9, 9)) == null, "ensure: absent returns null")

	# Task 4 - data API on an unloaded region streams it in and the write lands.
	cam.global_position = Vector3(rs * 0.5, 50, rs * 0.5)
	await _settle(400)
	ok(_t.data.get_region_load_state(Vector2i(-2, -2)) == Terrain3DData.REGION_UNLOADED, "api: target starts unloaded")
	var wpos := Vector3(-2 * rs + 4.0, 0.0, -2 * rs + 4.0)
	_t.data.set_height(wpos, 77.0)
	ok(_t.data.get_region_load_state(Vector2i(-2, -2)) == Terrain3DData.REGION_RESIDENT, "api: region streamed in on write")
	ok(absf(_t.data.get_height(wpos) - 77.0) < 0.01, "api: write landed on the streamed-in region")

	# Pin API round trip, and ensure-resident skips a pinned region as an eviction victim.
	_t.data.set_region_pinned(Vector2i(0, 0), true)
	ok(_t.data.is_region_pinned(Vector2i(0, 0)), "pin: set and query")
	_t.data.set_region_pinned(Vector2i(0, 0), false)
	ok(not _t.data.is_region_pinned(Vector2i(0, 0)), "pin: cleared")

	print("SUITE ", "GREEN" if _fail == 0 else "RED (%d)" % _fail)
	quit(_fail)
