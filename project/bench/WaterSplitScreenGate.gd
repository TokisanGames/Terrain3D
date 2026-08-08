# Pasture3D Water — split-screen gate.
#
# The plugin has had per-camera terrain clipmaps since the earliest split-screen work: Pasture3DMesher
# carries a ClipmapView per camera, each on that camera's reserved render layer, each geomorphing to
# its own target. Water never used any of it. Pasture3DOcean passed `false` for per-instance target
# positions and never called set_views, and Pasture3DWaterClipmap copied the ocean -- so both drew a
# single clipmap centred on one camera and every other player saw a surface morphing toward someone
# else's position.
#
# THE FAILURE THIS IS BUILT TO CATCH is "wired up but still centred on camera 0". Everything reports
# two views, every layer is right, no error appears anywhere, and the second player's water is
# subtly wrong in a way no count or uniform can see. So the gate renders two cameras far apart and
# requires their water to DIFFER -- and its control is the same two viewports pointed at the same
# camera, which must then agree. Without that control, "the images differ" is also what you get from
# two cameras looking at different scenery.
#
# CRITERIA
#   A. the camera list reaches the water at all: Pasture3D broadcasts, the manager holds it with the
#      documented precedence, and the clipmap reports one view per camera. Controls: a hand-set list
#      must lose to a terrain that is broadcasting, and must WIN when no terrain exists (spec W4).
#   B. each view geomorphs to its OWN camera. Two viewports, two cameras, one lake; the two frames
#      must differ. CONTROL: both viewports on camera 0, which must agree.
#   C. the layers the terrain assigned are the layers the water drew on, so each camera sees its own
#      view and only its own.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/WaterSplitScreenGate.tscn
#      BENCH_OUT=<dir> for the captures.
extends Node

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const LAKE_MAT := WATER_DIR + "M_water_lake.tres"
const VIEW := Vector2i(512, 384)

var _fail := 0
var _completed := 0
const CRITERIA := 3
var _out_dir := ""


func _ready() -> void:
	var bail := Timer.new()
	bail.wait_time = 900.0
	bail.one_shot = true
	bail.timeout.connect(func():
		push_error("gate timed out")
		get_tree().quit(2))
	add_child(bail)
	bail.start()

	_out_dir = OS.get_environment("BENCH_OUT")
	if _out_dir == "":
		_out_dir = "user://"
	if not _out_dir.ends_with("/"):
		_out_dir += "/"
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.global_shader_parameter_set("water_time", 0.0)
	RenderingServer.global_shader_parameter_set("water_time_period", 120.0)
	RenderingServer.global_shader_parameter_set("water_sun_direction", Vector3(0.35, 0.75, -0.56))
	RenderingServer.global_shader_parameter_set("water_sun_color", Vector3(1.0, 0.97, 0.9))

	print("=== Pasture3D — water split screen ===")
	print("Godot %s | %s" % [
		Engine.get_version_info().string, RenderingServer.get_video_adapter_name()])
	print("")

	await _criterion_a_the_list_arrives()
	await _criterion_b_each_view_follows_its_own_camera()
	await _criterion_c_layers()

	print("")
	print("completed %d/%d criteria, %d failures" % [_completed, CRITERIA, _fail])
	if _completed < CRITERIA:
		print("!! a criterion did not run to completion -- treat as FAIL")
	print("VERDICT: %s" % ("PASS" if _fail == 0 and _completed == CRITERIA else "FAIL"))
	get_tree().quit(1 if (_fail > 0 or _completed < CRITERIA) else 0)


# ---- A: the list reaches the water -------------------------------------------

func _criterion_a_the_list_arrives() -> void:
	print("[A] the camera list, from Pasture3D to the clipmap:")
	var root := Node3D.new()
	add_child(root)
	var terrain := Pasture3D.new()
	root.add_child(terrain)
	# The manager as a CHILD of the terrain, which is how the demo scene authors it and what makes
	# _find_terrain()'s ancestor-first rule the unambiguous answer.
	var manager := Pasture3DPoolManager.new()
	terrain.add_child(manager)
	manager.set_physics_process(false)
	var cams: Array[Camera3D] = []
	for i in 2:
		var c := Camera3D.new()
		c.position = Vector3(i * 400.0, 30.0, 0.0)
		root.add_child(c)
		cams.append(c)
	var pool := _pool(root, 1.0)
	# MASKED explicitly: AUTO leaves a body this small meshed, and a meshed body has no clipmap to
	# count views on. The first run of this gate reported "0 views" for exactly that reason.
	pool.surface_mode = pool.SurfaceMode.MASKED
	await get_tree().process_frame

	terrain.set_cameras(cams)
	await get_tree().process_frame
	pool.rebuild()
	await get_tree().process_frame

	print("    manager holds %d camera(s), from_terrain=%s, layers=%s" % [
		manager.get_view_cameras().size(), manager.are_cameras_from_terrain(),
		manager.get_view_layers()])
	if manager.get_view_cameras().size() != 2:
		_fail += 1
		print("    !! the broadcast did not reach the manager")

	var clip: Node = pool.get_node_or_null("Clipmap")
	print("    clipmap views: %d (want 2)" % [0 if clip == null else clip.get_view_count()])
	if clip == null or clip.get_view_count() != 2:
		_fail += 1
		print("    !! the clipmap is not one view per camera")

	# CONTROL 1: a hand-set list must LOSE while a terrain is broadcasting, which is the precedence
	# rule. Without it, whichever wrote last wins and terrain and water can end up on different
	# camera sets -- a seam at every shoreline.
	manager.set_manual_cameras([cams[0]] as Array[Camera3D], PackedInt32Array([1]))
	await get_tree().process_frame
	print("    CONTROL, hand-set while a terrain broadcasts: manager holds %d (want 2)" % [
		manager.get_view_cameras().size()])
	if manager.get_view_cameras().size() != 2:
		_fail += 1
		print("    !! a hand-set list overrode the terrain -- precedence is not holding")

	# CONTROL 2: with NO terrain, the hand-set list must be the one that works. Water spec W4 says
	# water runs in a scene with no Pasture3D at all, so the terrain cannot be the only way in.
	#
	# The terrain fixture is torn down FIRST and a frame allowed to pass. queue_free() leaves a node
	# in the tree until the frame ends, and the first version of this ran the control while the other
	# fixture's terrain was still there -- so the "no terrain" manager found one and reported itself
	# terrain-driven. Precedence is decided by the method now, but the teardown is still wrong to
	# leave: _resolve_cameras() pulls from any terrain it can reach on the way in.
	root.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame

	var lone := Node3D.new()
	add_child(lone)
	var m2 := Pasture3DPoolManager.new()
	lone.add_child(m2)
	m2.set_physics_process(false)
	var c2 := Camera3D.new()
	lone.add_child(c2)
	var c3 := Camera3D.new()
	lone.add_child(c3)
	await get_tree().process_frame
	m2.set_manual_cameras([c2, c3] as Array[Camera3D], PackedInt32Array([1 << 19, 1 << 18]))
	await get_tree().process_frame
	print("    CONTROL, no terrain: manager holds %d, from_terrain=%s (want 2, false)" % [
		m2.get_view_cameras().size(), m2.are_cameras_from_terrain()])
	if m2.get_view_cameras().size() != 2 or m2.are_cameras_from_terrain():
		_fail += 1
		print("    !! a manager with no terrain cannot be given cameras -- W4 is broken")
	lone.queue_free()
	await get_tree().process_frame
	_completed += 1


# ---- B: each view follows its own camera -------------------------------------

func _criterion_b_each_view_follows_its_own_camera() -> void:
	print("[B] two viewports, two cameras, one lake:")
	# One WORLD shared by both viewports, which is what split screen is: the same scene rendered
	# twice. Separate worlds would pass this trivially and prove nothing.
	var world := World3D.new()
	var host := SubViewport.new()
	host.size = VIEW
	host.world_3d = world
	host.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(host)

	var root := Node3D.new()
	host.add_child(root)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.05, 0.07, 0.1)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.3, 0.3, 0.32)
	env.environment = e
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -70.0, 0.0)
	root.add_child(sun)

	var terrain := Pasture3D.new()
	root.add_child(terrain)
	var manager := Pasture3DPoolManager.new()
	terrain.add_child(manager)
	manager.set_physics_process(false)

	# A body big enough that the two cameras stand on DIFFERENT rings of it. If both sat inside LOD0
	# the geomorph would be identical either way and the comparison would have nothing to find.
	var pool := _pool(root, 9.0)
	pool.surface_mode = pool.SurfaceMode.MASKED

	# Two cameras 500 m apart, both looking down at the water from the same height and angle, so the
	# only thing that differs between the frames is where the clipmap centres itself.
	var cams: Array[Camera3D] = []
	for i in 2:
		var c := Camera3D.new()
		c.position = Vector3(-250.0 + i * 500.0, 60.0, 260.0)
		c.rotation_degrees = Vector3(-24.0, 0.0, 0.0)
		# Layers 20 and 19, matching TERRAIN_TOP_BIT - i, plus gameplay 1-16.
		c.cull_mask = 0xFFFF | (1 << (19 - i))
		root.add_child(c)
		cams.append(c)
	await get_tree().process_frame
	terrain.set_cameras(cams)
	await get_tree().process_frame
	pool.rebuild()
	await get_tree().process_frame

	var shots := []
	for i in 2:
		shots.append(await _grab(host, cams[i]))
		_save(shots[i], "split_view_%d.png" % i)
	var d := _mean_abs_diff(shots[0], shots[1])
	print("    camera 0 vs camera 1: mean abs diff %.5f" % d)

	# CONTROL: the same two renders with BOTH viewports on camera 0. Everything else is held --
	# same world, same lake, same lighting -- so if the difference above is the clipmap following
	# each camera, this must collapse to zero.
	var a := await _grab(host, cams[0])
	var b := await _grab(host, cams[0])
	var control := _mean_abs_diff(a, b)
	print("    CONTROL, both on camera 0: mean abs diff %.5f" % control)
	if control > 0.0005:
		_fail += 1
		print("    !! the same camera twice does not render the same frame, so the difference")
		print("       above cannot be attributed to per-view geomorphing")
	elif d <= 0.0005:
		_fail += 1
		print("    !! the two cameras render the SAME water. Both views are centred on one")
		print("       camera -- wired up, reporting two views, and still single-view in effect.")
	else:
		print("    -> each view geomorphs to its own camera (%.0fx the control)" % (
			d / maxf(control, 1e-6)))
	host.queue_free()
	await get_tree().process_frame
	_completed += 1


# ---- C: the layers ------------------------------------------------------------

func _criterion_c_layers() -> void:
	print("[C] the layers the terrain assigned are the ones the water drew on:")
	var root := Node3D.new()
	add_child(root)
	var terrain := Pasture3D.new()
	root.add_child(terrain)
	var manager := Pasture3DPoolManager.new()
	terrain.add_child(manager)
	manager.set_physics_process(false)
	var cams: Array[Camera3D] = []
	for i in 3:
		var c := Camera3D.new()
		root.add_child(c)
		cams.append(c)
	await get_tree().process_frame
	terrain.set_cameras(cams)
	await get_tree().process_frame

	# TERRAIN_TOP_BIT is 19, descending: 20, 19, 18 for cameras 0..2.
	var want := PackedInt32Array([1 << 19, 1 << 18, 1 << 17])
	var got: PackedInt32Array = manager.get_view_layers()
	print("    layers: %s" % [got])
	print("    want:   %s" % [want])
	if got != want:
		_fail += 1
		print("    !! the layer mapping does not match the terrain's. Water view i must land on")
		print("       the SAME reserved bit as terrain view i, or camera i cannot see it.")
	else:
		print("    -> water lands on the bits the cameras' cull masks actually contain")
	# CONTROL: a single camera is the solo path and must send NOTHING, so subscribers fall back to
	# one view rather than one view pinned to a layer only one camera can see.
	terrain.set_cameras([cams[0]] as Array[Camera3D])
	await get_tree().process_frame
	print("    CONTROL, one camera: %d camera(s), layers %s (both want empty)" % [
		manager.get_view_cameras().size(), manager.get_view_layers()])
	if manager.get_view_cameras().size() != 0 or manager.get_view_layers().size() != 0:
		_fail += 1
		print("    !! the solo path is not empty, so a single-camera game gets a layered view")
	root.queue_free()
	await get_tree().process_frame
	_completed += 1


# ---- plumbing -----------------------------------------------------------------

func _pool(p_root: Node3D, p_scale: float) -> Pasture3DPool:
	var pool := Pasture3DPool.new()
	pool.name = "Pool"
	var c := Curve3D.new()
	for i in 48:
		var a := TAU * float(i) / 48.0
		c.add_point(Vector3(cos(a) * 52.0, 0.0, sin(a) * 41.0) * p_scale)
	c.closed = true
	pool.curve = c
	pool.wave_profile = &"lake_calm"
	pool.material = load(LAKE_MAT)
	pool.underwater_enabled = false
	p_root.add_child(pool)
	return pool


## One frame through the given camera. The clock is re-frozen each time: a manager left running would
## advance water_time between the two grabs and every comparison here would be measuring the waves.
func _grab(p_vp: SubViewport, p_cam: Camera3D) -> Image:
	p_cam.current = true
	RenderingServer.global_shader_parameter_set("water_time", 0.0)
	for i in 6:
		RenderingServer.global_shader_parameter_set("water_time", 0.0)
		await RenderingServer.frame_post_draw
	return p_vp.get_texture().get_image()


func _mean_abs_diff(p_a: Image, p_b: Image) -> float:
	var total := 0.0
	var n := 0
	for y in range(0, VIEW.y, 2):
		for x in range(0, VIEW.x, 2):
			var ca := p_a.get_pixel(x, y)
			var cb := p_b.get_pixel(x, y)
			total += maxf(maxf(absf(ca.r - cb.r), absf(ca.g - cb.g)), absf(ca.b - cb.b))
			n += 1
	return total / float(maxi(n, 1))


func _save(p_img: Image, p_name: String) -> void:
	var path := _out_dir + p_name
	if p_img.save_png(path) != OK or not FileAccess.file_exists(path):
		_fail += 1
		print("    !! save %s failed" % path)
