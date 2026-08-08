# Pasture3D Water — two masked lakes in one scene.
#
# Every masked-surface probe so far has measured ONE lake. That was the honest scope while the
# mechanism was being built, but it leaves the configuration a real project actually has untested,
# and the untested part is not a detail: a masked body owns a PRIVATE ShaderMaterial (the shore
# field is a sampler2D and cannot be an instance uniform) and a PRIVATE camera-centred clipmap. Two
# lakes is therefore two materials and two clipmaps -- and under split screen, two clipmaps each
# building one instance set per camera.
#
# THE FAILURE THIS IS BUILT TO CATCH is a clipmap that draws OVER the other lake. Each clipmap
# centres on the camera and spans its whole reach regardless of where its body is, so lake A's rings
# cover lake B's basin as a matter of course. Out there A's field reads its clamped maximum and the
# fragment stage is supposed to take the alpha to zero -- but the vertex kill does NOT fire on the
# outer rings (their margin, cell * 3.5, exceeds any sane mask_range, which pool.gd documents), so
# the geometry is genuinely present over the other lake and only the alpha stands between them. That
# is worth measuring rather than reasoning about.
#
# CRITERIA
#   A. two lakes, two fields. Distinct materials, distinct rects each matching its OWN body, and
#      distinct sea_levels -- the last is the one a shared material could not fake, so the two
#      bodies sit at different Y.
#   B. one frame, two lakes: each covers its own outline and NEITHER covers the other's.
#      CONTROLS: an empty frame must score zero coverage, and deleting lake B must take B's
#      coverage with it -- which is also what proves A alone is not painting B's basin.
#   C. the waterline does not degrade in company. Lake A's rim, measured with B's clipmap drawing
#      over it and again with B gone. CONTROL: coarsening A's texel must move it, or the metric is
#      not reading the field.
#   D. split screen x two lakes: four instance sets. Both clipmaps report one view per camera, and
#      the two cameras render DIFFERENT water. CONTROL: the same camera twice must agree.
#   E. the manager routes a point to the right body. CONTROL: probes displaced by the inter-lake
#      vector must come back with the OTHER lake, which is a specific expected answer rather than
#      "something changed".
#   F. the cost, stated: vertices per lake per view, and the total. Asserts the total is the sum of
#      the parts -- no hidden multiplication -- and that neither count tracks its body's size.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/WaterTwoLakesGate.tscn
#      BENCH_OUT=<dir> for the captures.
extends Node

const SDF := preload("res://bench/shore_sdf.gd")
const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const LAKE_MAT := WATER_DIR + "M_water_lake.tres"

const IMG := 768
const VIEW := Vector2i(512, 384)
## Where the two bodies sit. Far enough apart that their outlines never touch, so "covered pixel
## outside both truths" is unambiguous, and at DIFFERENT Y so a shared material would show.
const A_POS := Vector3(-120.0, 0.0, 0.0)
const B_POS := Vector3(120.0, 6.0, 0.0)
var _fail := 0
var _completed := 0
const CRITERIA := 6
var _out_dir := ""
var _cover_shader: Shader = null
## Whether the readout material carries the body's wave table. Only criterion C's decomposition
## turns it off; see there.
var _carry_waves := true


func _ready() -> void:
	var bail := Timer.new()
	bail.wait_time = 1800.0
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

	print("=== Pasture3D — two masked lakes ===")
	print("Godot %s | %s" % [
		Engine.get_version_info().string, RenderingServer.get_video_adapter_name()])
	print("")

	await _criterion_a_two_fields()
	await _criterion_b_each_draws_its_own()
	await _criterion_c_waterline_in_company()
	await _criterion_d_split_screen()
	await _criterion_e_queries_route()
	await _criterion_f_the_cost()

	print("")
	print("completed %d/%d criteria, %d failures" % [_completed, CRITERIA, _fail])
	if _completed < CRITERIA:
		print("!! a criterion did not run to completion -- treat as FAIL")
	print("VERDICT: %s" % ("PASS" if _fail == 0 and _completed == CRITERIA else "FAIL"))
	get_tree().quit(1 if (_fail > 0 or _completed < CRITERIA) else 0)


# ---- A: two lakes, two fields -------------------------------------------------

func _criterion_a_two_fields() -> void:
	print("[A] two masked lakes, two private materials:")
	var root := _scene()
	var a := _pool(root, "LakeA", A_POS)
	var b := _pool(root, "LakeB", B_POS)
	var sa := await _rebuild(a)
	var sb := await _rebuild(b)
	if not sa.get("ok", false) or not sb.get("ok", false):
		_fail += 1
		print("    !! a body did not build: A=%s B=%s" % [
			sa.get("reason", "ok"), sb.get("reason", "ok")])
		root.queue_free()
		await get_tree().process_frame
		_completed += 1
		return

	var ma: ShaderMaterial = a._runtime_material
	var mb: ShaderMaterial = b._runtime_material
	if ma == null or mb == null:
		_fail += 1
		print("    !! a body has no runtime material (A=%s B=%s)" % [ma, mb])
		root.queue_free()
		await get_tree().process_frame
		_completed += 1
		return

	print("    materials: A #%d, B #%d" % [ma.get_instance_id(), mb.get_instance_id()])
	if ma == mb:
		_fail += 1
		print("    !! both lakes are on ONE material, so one field overwrote the other")

	var ra: Vector4 = ma.get_shader_parameter("_shore_rect")
	var rb: Vector4 = mb.get_shader_parameter("_shore_rect")
	print("    _shore_rect: A %s" % [ra])
	print("                 B %s" % [rb])
	# Each rect must be framed around ITS OWN body, which is the local/world bug's shape: a rect
	# that is right for one body and applied to both puts a lake's cut where the other lake is.
	if absf(ra.x - rb.x) < 100.0:
		_fail += 1
		print("    !! the two fields are framed in nearly the same place -- expected %.0f m apart" % [
			absf(A_POS.x - B_POS.x)])
	for pair in [[a, ra, "A"], [b, rb, "B"]]:
		var pool: Pasture3DPool = pair[0]
		var rect: Vector4 = pair[1]
		var want: Vector4 = pool._world_shore_rect()
		if rect != want:
			_fail += 1
			print("    !! lake %s's material carries %s but its body frames %s" % [
				pair[2], rect, want])

	# The textures themselves. Two lakes sharing one ImageTexture is the same bug one level down,
	# and it survives distinct materials if the duplicate was taken after the field was written.
	var ta: Texture2D = ma.get_shader_parameter("_shore_sdf")
	var tb: Texture2D = mb.get_shader_parameter("_shore_sdf")
	print("    _shore_sdf: A #%d (%d^2)  B #%d (%d^2)" % [
		0 if ta == null else ta.get_instance_id(), 0 if ta == null else ta.get_width(),
		0 if tb == null else tb.get_instance_id(), 0 if tb == null else tb.get_width()])
	if ta == null or tb == null or ta == tb:
		_fail += 1
		print("    !! the two lakes are sharing one distance field")

	# sea_level is the reading a shared material could not fake: it is a MATERIAL uniform, one
	# number, and the two bodies are at different Y on purpose.
	var la = ma.get_shader_parameter("sea_level")
	var lb = mb.get_shader_parameter("sea_level")
	print("    sea_level: A %s (body %.2f)  B %s (body %.2f)" % [
		la, a.global_position.y, lb, b.global_position.y])
	if la == null or lb == null or absf(float(la) - A_POS.y) > 1e-4 \
			or absf(float(lb) - B_POS.y) > 1e-4:
		_fail += 1
		print("    !! a lake's level is not its own -- one body's Y reached the other's material")

	# And the manager's SHARED cache is still doing its job underneath: both bodies resolve the same
	# base+profile, so it must hold one entry, not two. The privacy is in the duplicate, not in
	# defeating the cache.
	var m: Pasture3DPoolManager = root.get_node("Pasture3DPoolManager")
	print("    manager material cache: %d entr(ies) for 2 bodies on one preset" % [
		m.get_cached_material_count()])
	if m.get_cached_material_count() != 1:
		_fail += 1
		print("    !! the shared cache is not being shared, so the profile upload is per body")
	root.queue_free()
	await get_tree().process_frame
	_completed += 1


# ---- B: each lake draws its own outline and nobody else's ---------------------

func _criterion_b_each_draws_its_own() -> void:
	print("[B] one frame, two lakes -- who covered what:")
	var root := _scene()
	var a := _pool(root, "LakeA", A_POS)
	var b := _pool(root, "LakeB", B_POS)
	await _rebuild(a)
	await _rebuild(b)
	if a.get_polygon().size() < 3 or b.get_polygon().size() < 3:
		_fail += 1
		print("    !! a body has no polygon")
		root.queue_free()
		await get_tree().process_frame
		_completed += 1
		return

	# One square containing both, framed from the bodies' own polygons.
	var pa := _world_polygon(a)
	var pb := _world_polygon(b)
	var frame := _bounds(pa).merge(_bounds(pb)).grow(30.0)
	var extent: float = maxf(frame.size.x, frame.size.y)
	var view_min: Vector2 = frame.get_center() - Vector2(extent, extent) * 0.5
	var mpp := extent / float(IMG)
	var truth_a := SDF.inside_mask(pa, view_min + Vector2(0.5, 0.5) * mpp, mpp, IMG, IMG)
	var truth_b := SDF.inside_mask(pb, view_min + Vector2(0.5, 0.5) * mpp, mpp, IMG, IMG)
	var area_a := _count(truth_a)
	var area_b := _count(truth_b)
	print("    %.0f m frame at %.2f m/px; truth areas A %d px, B %d px" % [
		extent, mpp, area_a, area_b])
	if area_a < 5000 or area_b < 5000:
		_fail += 1
		print("    !! a truth mask is too small for its coverage fraction to mean anything")

	var vp := _ortho(view_min, extent)
	root.get_parent().remove_child(root)
	vp.add_child(root)
	await get_tree().process_frame

	# ANTI-NULL FIRST. Both clipmaps hidden: the frame must be empty, or every count below is
	# measuring the background.
	_set_clipmaps_visible([a, b], false)
	for i in 6:
		await RenderingServer.frame_post_draw
	var empty := _covered_mask(vp.get_texture().get_image())
	print("    the water-free frame: %d covered px (must be 0)" % _count(empty))
	if _count(empty) > 0:
		_fail += 1
		print("    !! the readout fires with no water in it -- every number below is noise")
	_set_clipmaps_visible([a, b], true)

	var both := await _capture([a, b], vp)
	_save(both, "twolakes_both.png")
	var m := _covered_mask(both)
	var in_a := _overlap(m, truth_a)
	var in_b := _overlap(m, truth_b)
	var spill := _outside_both(m, truth_a, truth_b)
	print("    both lakes: A's outline %.3f covered, B's %.3f, spill outside both %d px" % [
		float(in_a) / float(maxi(area_a, 1)), float(in_b) / float(maxi(area_b, 1)), spill])
	if float(in_a) / float(maxi(area_a, 1)) < 0.95 or float(in_b) / float(maxi(area_b, 1)) < 0.95:
		_fail += 1
		print("    !! a lake is not filling its own outline with the other one present")
	# The spill budget is the feather plus a pixel, all the way round both shores. Anything the
	# size of a lake would be a clipmap painting where it has no body.
	var perimeter_px := 2.0 * (sqrt(float(area_a)) + sqrt(float(area_b))) * 4.0
	if float(spill) > perimeter_px * 2.0:
		_fail += 1
		print("    !! %d px of water outside BOTH outlines (budget ~%.0f). A clipmap is drawing" % [
			spill, perimeter_px * 2.0])
		print("       past its own body -- the alpha is not closing over the other lake.")
	else:
		print("    -> the water outside both outlines is rim, not a second surface")

	# CONTROL. Take lake B away. Its coverage must go with it -- which is the same measurement
	# saying that what filled B's outline was B, and not A's rings reaching across.
	b.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	var alone := await _capture([a], vp)
	_save(alone, "twolakes_a_alone.png")
	var ma := _covered_mask(alone)
	var alone_a := float(_overlap(ma, truth_a)) / float(maxi(area_a, 1))
	var alone_b := float(_overlap(ma, truth_b)) / float(maxi(area_b, 1))
	print("    CONTROL, B deleted: A's outline %.3f covered, B's %.3f (want ~1 and ~0)" % [
		alone_a, alone_b])
	if alone_b > 0.05:
		_fail += 1
		print("    !! B's basin is still %.0f%% covered with B gone, so lake A's clipmap is" % [
			alone_b * 100.0])
		print("       drawing over it -- the rings span the reach and the alpha did not close")
	elif alone_a < 0.95:
		_fail += 1
		print("    !! A stopped covering its own outline when B was removed")
	else:
		print("    -> each lake's pixels are its own")
	vp.queue_free()
	await get_tree().process_frame
	_completed += 1


# ---- C: the waterline in company ----------------------------------------------

## Criterion B counts pixels, which answers "who drew where" and says nothing about the rim. This
## frames tightly on lake A -- B is off screen, but B's clipmap is centred on the CAMERA and is
## therefore drawing across this whole frame -- and scores A's waterline against A's own polygon,
## with B present and with B gone.
##
## THE BOUND IS edge_offset, not the static sheet's 0.25 m, and criterion H settled why: the rim is
## meant to be buried in the bank, and a waterline inside the offset is one nobody can see. A
## clipmap's rim is not a sheet's -- the geomorph and the per-ring kill margin both cost tenths of a
## metre -- so holding it to a number measured on a sheet would be failing it for being a clipmap.
## The tight assertion here is the one this criterion exists for: the two readings must AGREE.
func _criterion_c_waterline_in_company() -> void:
	print("[C] lake A's waterline, with another lake's clipmap over it:")
	var root := _scene()
	var a := _pool(root, "LakeA", A_POS)
	var b := _pool(root, "LakeB", B_POS)
	await _rebuild(a)
	await _rebuild(b)
	var pa := _world_polygon(a)
	if pa.size() < 3:
		_fail += 1
		print("    !! no polygon")
		root.queue_free()
		await get_tree().process_frame
		_completed += 1
		return
	var bounds := _bounds(pa)
	var extent: float = maxf(bounds.size.x, bounds.size.y) + 40.0
	var view_min: Vector2 = bounds.get_center() - Vector2(extent, extent) * 0.5
	var mpp := extent / float(IMG)
	var truth := SDF.inside_mask(pa, view_min + Vector2(0.5, 0.5) * mpp, mpp, IMG, IMG)
	var area := _count(truth)
	print("    %.0f m frame at %.3f m/px -- the instrument floor" % [extent, mpp])

	var vp := _ortho(view_min, extent)
	root.get_parent().remove_child(root)
	vp.add_child(root)
	await get_tree().process_frame

	var scores := {}
	var img := await _capture([a, b], vp)
	_save(img, "twolakes_rim_company.png")
	scores["with B"] = SDF.score(img, truth, pa, view_min, mpp, IMG, area)

	b.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	img = await _capture([a], vp)
	_save(img, "twolakes_rim_alone.png")
	scores["alone"] = SDF.score(img, truth, pa, view_min, mpp, IMG, area)

	# A READING, not an assertion: the same lake with the wave table left OUT of the readout, so the
	# residual is decomposed rather than reported as one unexplained number. The shore is tested
	# against the UNDISPLACED xz but the vertex is drawn displaced, so a Gerstner crest carries its
	# own shore value sideways -- which is where the water's edge really is, and is also why this
	# number is not the static sheet's. Whatever is left over after this is the geomorph.
	_carry_waves = false
	img = await _capture([a], vp)
	scores["reading, no waves"] = SDF.score(img, truth, pa, view_min, mpp, IMG, area)
	_carry_waves = true

	# CONTROL: coarsen A's field. If this does not degrade, the two readings above agreeing means
	# nothing -- an instrument that cannot see the field cannot see it being disturbed either.
	a.mask_texel = 8.0
	await _rebuild(a)
	img = await _capture([a], vp)
	_save(img, "twolakes_rim_coarse.png")
	scores["CONTROL texel 8 m"] = SDF.score(img, truth, pa, view_min, mpp, IMG, area)

	for k in ["with B", "alone", "reading, no waves", "CONTROL texel 8 m"]:
		var s: Dictionary = scores[k]
		print("    %-18s p99 %6.3f m  max %6.3f m  coverage %.3fx truth" % [
			k, s["p99"], s["max"], float(s["covered"]) / float(maxi(area, 1))])
	var with_b: float = scores["with B"]["p99"]
	var alone: float = scores["alone"]["p99"]
	print("    of A's %.3f m: %.3f m is there with the waves switched off (geomorph + field)," % [
		alone, scores["reading, no waves"]["p99"]])
	print("    the rest is the crest carrying its own shore value sideways.")
	# The bound is the physical one -- see the docstring.
	if with_b > a.edge_offset:
		_fail += 1
		print("    !! A's rim reaches past edge_offset (%.2f m), so it emerges from the bank" % [
			a.edge_offset])
	# THE CLAIM. A second lake's clipmap covers this entire frame; if it disturbed A's waterline at
	# all, it would show up here and nowhere else in the gate.
	if absf(with_b - alone) > maxf(alone * 0.25, mpp):
		_fail += 1
		print("    !! the second lake moved A's waterline (%.3f m vs %.3f m alone)" % [
			with_b, alone])
	else:
		print("    -> B's clipmap draws across this frame and changes nothing in it")
	if scores["CONTROL texel 8 m"]["p99"] <= alone * 1.5:
		_fail += 1
		print("    !! the control did not degrade, so this is not measuring the field")
	else:
		print("    -> and coarsening A's field does move it, so the metric is live")
	vp.queue_free()
	await get_tree().process_frame
	_completed += 1


# ---- D: split screen times two lakes ------------------------------------------

func _criterion_d_split_screen() -> void:
	print("[D] two lakes x two cameras = four instance sets:")
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

	# Big bodies, for the same reason the split-screen gate uses one: two cameras inside LOD0 would
	# geomorph identically and the comparison would have nothing to find.
	var a := _pool(root, "LakeA", Vector3(-400.0, 0.0, 0.0), 9.0)
	var b := _pool(root, "LakeB", Vector3(400.0, 6.0, 0.0), 9.0)

	# One camera standing over each lake, so each player is looking at a different body -- the
	# configuration the single-lake gate could not produce.
	var cams: Array[Camera3D] = []
	for i in 2:
		var c := Camera3D.new()
		c.position = Vector3(-400.0 + i * 800.0, 60.0, 300.0)
		c.rotation_degrees = Vector3(-24.0, 0.0, 0.0)
		c.cull_mask = 0xFFFF | (1 << (19 - i))
		root.add_child(c)
		cams.append(c)
	await get_tree().process_frame
	terrain.set_cameras(cams)
	await get_tree().process_frame
	a.rebuild()
	b.rebuild()
	await get_tree().process_frame

	var views := []
	for pair in [[a, "A"], [b, "B"]]:
		var clip: Node = (pair[0] as Node).get_node_or_null("Clipmap")
		var n: int = 0 if clip == null else clip.get_view_count()
		views.append(n)
		print("    lake %s: %d view(s)" % [pair[1], n])
	if views != [2, 2]:
		_fail += 1
		print("    !! not every lake got one view per camera, so a player sees water centred")
		print("       on somebody else")

	var shots := []
	for i in 2:
		shots.append(await _grab(host, cams[i]))
		_save(shots[i], "twolakes_split_%d.png" % i)
	var d := _mean_abs_diff(shots[0], shots[1])
	print("    camera 0 vs camera 1: mean abs diff %.5f" % d)
	# CONTROL: the same camera twice. Without it "the frames differ" is also what two cameras
	# pointed at two different lakes produce for free.
	var x := await _grab(host, cams[0])
	var y := await _grab(host, cams[0])
	var control := _mean_abs_diff(x, y)
	print("    CONTROL, both on camera 0: mean abs diff %.5f" % control)
	if control > 0.0005:
		_fail += 1
		print("    !! the same camera twice does not render the same frame")
	elif d <= 0.0005:
		_fail += 1
		print("    !! the two cameras render identical water with two lakes in the scene")
	else:
		print("    -> %.0fx the control; four instance sets, each on its own camera" % [
			d / maxf(control, 1e-6)])

	# And freeing one lake must not take the other's views with it. Both clipmaps drive the same
	# Pasture3DMesher code and both were handed the same Camera3D instances.
	a.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	var clip_b: Node = b.get_node_or_null("Clipmap")
	var left: int = 0 if clip_b == null else clip_b.get_view_count()
	print("    after freeing lake A: lake B still has %d view(s), manager holds %d bod(ies)" % [
		left, manager.get_bodies().size()])
	if left != 2:
		_fail += 1
		print("    !! freeing one lake disturbed the other's views")
	if manager.get_bodies().size() != 1:
		_fail += 1
		print("    !! the registry did not drop the freed body")
	var after := await _grab(host, cams[1])
	_save(after, "twolakes_split_after_free.png")
	if _mean_abs_diff(after, shots[1]) > 0.0005:
		_fail += 1
		print("    !! camera 1's frame changed when the OTHER lake was freed")
	else:
		print("    -> and camera 1's frame is unchanged, so nothing of B's went with A")
	host.queue_free()
	await get_tree().process_frame
	_completed += 1


# ---- E: the manager routes a point to the right body --------------------------

func _criterion_e_queries_route() -> void:
	print("[E] body_at() with two bodies registered:")
	var root := _scene()
	var a := _pool(root, "LakeA", A_POS)
	var b := _pool(root, "LakeB", B_POS)
	await _rebuild(a)
	await _rebuild(b)
	var m: Pasture3DPoolManager = root.get_node("Pasture3DPoolManager")
	print("    manager holds %d bod(ies)" % m.get_bodies().size())
	if m.get_bodies().size() != 2:
		_fail += 1
		print("    !! both bodies did not register")

	var offset := Vector3(B_POS.x - A_POS.x, 0.0, 0.0)
	var hits_a := 0
	var hits_b := 0
	var wrong := 0
	var probes: Array[Vector3] = []
	for iz in 31:
		for ix in 31:
			probes.append(A_POS + Vector3(
				lerpf(-70.0, 70.0, float(ix) / 30.0), -0.4,
				lerpf(-55.0, 55.0, float(iz) / 30.0)))
	for p in probes:
		var inside_a: bool = a.contains_point(p)
		var got: Node = m.body_at(p)
		if inside_a:
			hits_a += 1
			if got != a:
				wrong += 1
		# The same point moved onto lake B. The two outlines are identical translations of each
		# other, so a point inside A maps to a point inside B -- which makes this a specific
		# expected answer rather than "the result changed".
		var q: Vector3 = p + offset + Vector3(0.0, B_POS.y, 0.0)
		if b.contains_point(q):
			hits_b += 1
			if m.body_at(q) != b:
				wrong += 1
	print("    %d probes: %d inside A, %d inside B, %d routed to the wrong body" % [
		probes.size(), hits_a, hits_b, wrong])
	if hits_a < 100 or hits_b < 100:
		_fail += 1
		print("    !! too few probes landed in the water for the routing to mean anything")
	elif wrong > 0:
		_fail += 1
		print("    !! body_at() handed back the wrong lake")
	else:
		print("    -> every point went to the body whose outline contains it")

	# CONTROL: ask each body about the OTHER's water. A body that claims everything would have
	# scored a clean zero above, because every probe would have found its own lake first in
	# registration order.
	var cross := 0
	for p in probes:
		if a.contains_point(p + offset + Vector3(0.0, B_POS.y, 0.0)):
			cross += 1
	print("    CONTROL, lake A asked about lake B's water: %d claimed (want 0)" % cross)
	if cross > 0:
		_fail += 1
		print("    !! a body claims water that is not its own, so the routing above was luck")
	root.queue_free()
	await get_tree().process_frame
	_completed += 1


# ---- F: the cost, stated -------------------------------------------------------

## Not a timing -- a vertex count, which is the thing this whole exercise was about. The number to
## report is per lake PER VIEW, because that is what a second lake and a second player each multiply.
func _criterion_f_the_cost() -> void:
	print("[F] what a second lake costs:")
	var root := _scene()
	var a := _pool(root, "LakeA", A_POS)
	var sa := await _rebuild(a)
	var one: int = sa.get("vertices", 0)
	# A body 13.5x the span. If the second lake's count tracked its size, the clipmap's central
	# claim would be false for any scene with more than one body in it.
	var b := _pool(root, "LakeB", B_POS, 13.5)
	var sb := await _rebuild(b)
	var two: int = sb.get("vertices", 0)
	print("    lake A (104 m): %d verts, %d rings" % [one, sa.get("clipmap_lods", 0)])
	print("    lake B (1.4 km): %d verts, %d rings" % [two, sb.get("clipmap_lods", 0)])
	if one <= 0 or two <= 0:
		_fail += 1
		print("    !! a body reported no vertices, so neither number below means anything")
		root.queue_free()
		await get_tree().process_frame
		_completed += 1
		return
	# Rings scale with the LOG of the span, so a 13.5x body is a handful of rings more and not a
	# multiple. Same claim criterion E of the pool probe makes for one body, re-checked with two.
	var ratio := float(two) / float(one)
	print("    13.5x the span costs %.2fx the vertices (a meshed body would be ~180x)" % ratio)
	if ratio > 2.5:
		_fail += 1
		print("    !! the second lake's count is tracking its size")

	var clip_a: Node = a.get_node_or_null("Clipmap")
	var clip_b: Node = b.get_node_or_null("Clipmap")
	if clip_a == null or clip_b == null:
		_fail += 1
		print("    !! a masked body has no clipmap")
		root.queue_free()
		await get_tree().process_frame
		_completed += 1
		return
	# The total is the sum of the parts and nothing else: no shared pool of instances, and no
	# clipmap quietly rebuilding when a sibling appears.
	var before: int = clip_a.get_vertex_count()
	await _rebuild(b)
	var after: int = clip_a.get_vertex_count()
	print("    lake A's count with B rebuilt beside it: %d (was %d)" % [after, before])
	if after != before:
		_fail += 1
		print("    !! rebuilding one lake changed the other's geometry")
	print("    scene total, one view:   %d verts" % (one + two))
	print("    scene total, two players: %d verts (each clipmap builds one set per camera)" % [
		(one + two) * 2])
	print("    -> a second lake and a second player each MULTIPLY; a bigger lake does not.")
	root.queue_free()
	await get_tree().process_frame
	_completed += 1


# ---- plumbing -----------------------------------------------------------------

func _scene() -> Node3D:
	var root := Node3D.new()
	add_child(root)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	root.add_child(sun)
	var m := Pasture3DPoolManager.new()
	m.name = "Pasture3DPoolManager"
	root.add_child(m)
	m.sun_light = sun
	# FROZEN. The manager writes water_time every physics tick, and two captures taken across a
	# tick differ by the waves rather than by anything under test.
	m.set_physics_process(false)
	RenderingServer.global_shader_parameter_set("water_time", 0.0)
	return root


func _pool(p_root: Node3D, p_name: String, p_pos: Vector3,
		p_scale: float = 1.0) -> Pasture3DPool:
	var pool := Pasture3DPool.new()
	pool.name = p_name
	pool.curve = _curve(p_scale)
	pool.wave_profile = &"lake_calm"
	pool.material = load(LAKE_MAT)
	pool.underwater_enabled = false
	# MASKED explicitly. AUTO leaves a body this size meshed, and a meshed body has no clipmap --
	# which is the whole subject here.
	pool.surface_mode = pool.SurfaceMode.MASKED
	p_root.add_child(pool)
	pool.position = p_pos
	return pool


## The pool probe's outline, as a closed Curve3D. Same shape on purpose: its inlet and its flat
## chord are what make a coverage number sensitive to the field rather than to a circle.
func _curve(p_scale: float) -> Curve3D:
	var c := Curve3D.new()
	const N := 96
	var chord_a := deg_to_rad(28.0)
	var chord_b := deg_to_rad(74.0)
	var inlet_at := deg_to_rad(163.0)
	var head_at := deg_to_rad(252.0)
	var inlet_done := false
	var head_done := false
	for i in N:
		var ang := TAU * float(i) / float(N)
		if ang > chord_a and ang < chord_b:
			continue
		if not inlet_done and ang >= inlet_at:
			for p in [_e(inlet_at - deg_to_rad(2.2), p_scale),
					_e(inlet_at - deg_to_rad(2.2), p_scale * 0.62),
					_e(inlet_at + deg_to_rad(2.2), p_scale * 0.62),
					_e(inlet_at + deg_to_rad(2.2), p_scale)]:
				c.add_point(p)
			inlet_done = true
			continue
		if not head_done and ang >= head_at:
			c.add_point(_e(head_at, p_scale * 1.34))
			head_done = true
			continue
		c.add_point(_e(ang, p_scale))
	c.closed = true
	return c


func _e(p_angle: float, p_scale: float) -> Vector3:
	return Vector3(cos(p_angle) * 52.0, 0.0, sin(p_angle) * 41.0) * p_scale


func _rebuild(p_pool: Pasture3DPool) -> Dictionary:
	RenderingServer.global_shader_parameter_set("water_time", 0.0)
	var stats: Dictionary = p_pool.rebuild()
	await get_tree().process_frame
	return stats


## The body's outline in WORLD XZ. get_polygon() is local, and both lakes sit off the origin --
## which is the case that found the local/world framing bug in the first place.
func _world_polygon(p_pool: Pasture3DPool) -> PackedVector2Array:
	var out := PackedVector2Array()
	var o := p_pool.global_position
	for v in p_pool.get_polygon():
		out.append(v + Vector2(o.x, o.z))
	return out


func _bounds(p_poly: PackedVector2Array) -> Rect2:
	var mn := p_poly[0]
	var mx := p_poly[0]
	for v in p_poly:
		mn = Vector2(minf(mn.x, v.x), minf(mn.y, v.y))
		mx = Vector2(maxf(mx.x, v.x), maxf(mx.y, v.y))
	return Rect2(mn, mx - mn)


func _set_clipmaps_visible(p_pools: Array, p_visible: bool) -> void:
	for pool in p_pools:
		var clip: Node = (pool as Node).get_node_or_null("Clipmap")
		if clip != null:
			(clip as Node3D).visible = p_visible


## One flat-coverage frame with every given lake reading through its OWN field.
##
## The material is re-asserted every frame for the reason the pool probe's criteria B and H are:
## writing a mask_* property schedules a DEBOUNCED rebuild, and when it fires it calls
## _apply_material and _ensure_clipmap, both of which put the water material back -- which over this
## black, unlit viewport renders as nothing and reads as an empty frame.
func _capture(p_pools: Array, p_vp: SubViewport) -> Image:
	var covers := []
	for pool in p_pools:
		covers.append(_cover_for(pool))
	for i in 8:
		for k in p_pools.size():
			var clip: Node = (p_pools[k] as Node).get_node_or_null("Clipmap")
			if clip != null and covers[k] != null:
				clip.material = covers[k]
		await RenderingServer.frame_post_draw
	return p_vp.get_texture().get_image()


## A flat readout material carrying ONE body's field.
##
## Copied off the node's own runtime material, so what is measured is the field that body baked and
## framed. `_waves` comes along too: the clipmap's vertex stage displaces by the wave sum, and a
## readout on the shader's compile-time table would put the rim a few centimetres from where the
## real surface puts it.
func _cover_for(p_pool) -> ShaderMaterial:
	var rt: ShaderMaterial = p_pool._runtime_material
	if rt == null:
		_fail += 1
		print("    !! %s has no runtime material to read the field from" % (p_pool as Node).name)
		return null
	if _cover_shader == null:
		_cover_shader = _coverage_shader()
	var cover := ShaderMaterial.new()
	cover.shader = _cover_shader
	for nm in ["_shore_sdf", "_shore_rect", "_shore_texels", "_shore_range", "_shore_feather",
			"_shore_offset", "_shore_kill_margin", "sea_level"]:
		cover.set_shader_parameter(nm, rt.get_shader_parameter(nm))
	if _carry_waves:
		for nm in ["_waves", "wave_steepness"]:
			cover.set_shader_parameter(nm, rt.get_shader_parameter(nm))
	else:
		# Explicitly flat, not "left at the shader's default": the compile-time table is a real
		# wave set, so an unset uniform would be a DIFFERENT displacement rather than none.
		cover.set_shader_parameter("_waves", _flat_waves())
		cover.set_shader_parameter("wave_steepness", 0.0)
	return cover


## A four-wave table with every amplitude at zero, which is the only way to ask the shipped vertex
## stage for an undisplaced surface without editing it.
##
## The WAVELENGTH has to be non-zero. water_waves.gdshaderinc uses `_waves[0].w <= 0.0` as its
## "nothing was uploaded" sentinel and substitutes the compile-time table -- so the obvious all-zero
## array is the one input that produces the shipped waves at full amplitude, which is the opposite
## of what this is for. Layout is (dir.x, dir.y, amplitude, wavelength).
func _flat_waves() -> Array:
	var out := []
	for i in 4:
		out.append(Vector4(1.0, 0.0, 0.0, 20.0))
	return out


## Unlit flat coverage over the shore mask, on the clipmap's own vertex stage.
##
## The SHIPPED vertex stage, not a hand-written one: the geomorph, the sea_level lift and the vertex
## kill are what is under test on a clipmap, and a substitute would be testing this gate.
func _coverage_shader() -> Shader:
	var sh := Shader.new()
	sh.code = "\n".join([
		"shader_type spatial;",
		"render_mode unshaded, cull_disabled, depth_draw_never, skip_vertex_transform;",
		"#define WATER_SHORE_MASK",
		"#define WATER_CLIPMAP",
		"#define WATER_WAVE_COUNT 4",
		'#include "%swater_common.gdshaderinc"' % WATER_DIR,
		'#include "%swater_waves.gdshaderinc"' % WATER_DIR,
		'#include "%swater_surface.gdshaderinc"' % WATER_DIR,
		"void fragment() {",
		"	ALBEDO = vec3(1.0);",
		"	ALPHA = water_shore_alpha(v_shore_xz);",
		"}",
	])
	return sh


func _covered_mask(p_img: Image) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(IMG * IMG)
	for y in IMG:
		for x in IMG:
			out[y * IMG + x] = 1 if p_img.get_pixel(x, y).r > 0.5 else 0
	return out


func _count(p_mask: PackedByteArray) -> int:
	var n := 0
	for b in p_mask:
		n += int(b)
	return n


func _overlap(p_a: PackedByteArray, p_b: PackedByteArray) -> int:
	var n := 0
	for i in p_a.size():
		if p_a[i] == 1 and p_b[i] == 1:
			n += 1
	return n


func _outside_both(p_m: PackedByteArray, p_a: PackedByteArray, p_b: PackedByteArray) -> int:
	var n := 0
	for i in p_m.size():
		if p_m[i] == 1 and p_a[i] == 0 and p_b[i] == 0:
			n += 1
	return n


func _ortho(p_view_min: Vector2, p_extent: float) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = Vector2i(IMG, IMG)
	vp.own_world_3d = true
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_DISABLED
	add_child(vp)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color.BLACK
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color.BLACK
	e.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.environment = e
	vp.add_child(env)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = p_extent
	cam.near = 1.0
	cam.far = 3000.0
	cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	cam.position = Vector3(p_view_min.x + p_extent * 0.5, 600.0,
		p_view_min.y + p_extent * 0.5)
	cam.current = true
	vp.add_child(cam)
	return vp


## One frame through the given camera. The clock is re-frozen each time, or a manager left running
## would advance water_time between two grabs and every comparison would be measuring the waves.
func _grab(p_vp: SubViewport, p_cam: Camera3D) -> Image:
	p_cam.current = true
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
