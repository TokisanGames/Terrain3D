# Pasture3D Water — Pasture3DPool masked-surface probe.
#
# The previous three probes measured the MECHANISM on synthetic sheets. This one measures the NODE:
# a real Pasture3DPool, with a real manager and a real preset material, switched between its two
# surface modes.
#
# Four things have to be true before the masked path is worth having, and only the first is about
# the thing the earlier probes looked at:
#
#   A. it builds the body that MESHED refuses, and its vertex count is a property of the SHEET
#      rather than of the lake. Control: the same outline in MESHED mode must still refuse, or the
#      comparison is against a problem that went away by itself.
#
#   B. the waterline the NODE produces is where the node's own polygon is. The earlier probes fed
#      the field a polygon directly; here the pool decimates the curve, offsets it by edge_offset,
#      pads its bounds and frames the bake itself, and any of those can be off by a step.
#      Control: mask_texel coarsened, which must show up.
#
#   C. THE CPU SIDE DOES NOT CHANGE. This is the load-bearing claim of the whole plan -- buoys, the
#      Area3D, is_point_underwater() and get_water_height() read the polygon and the analytic wave
#      sum, never the mesh, so switching how the water is DRAWN must not move where the water IS.
#      Control: a deliberately displaced query set, which must disagree.
#
#   D. the wave table survives the shader swap. MASKED mode copies the manager's resolved material
#      onto a different shader, and a copy that lost `_waves` is not obviously broken -- it is a
#      lake with the shader's compile-time waves, drawn out of step with what get_water_height()
#      reports. Control: compare against the resolved material's own table.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/WaterShorePoolProbe.tscn
#      BENCH_OUT=<dir> for the captures.
extends Node

const SDF := preload("res://bench/shore_sdf.gd")
const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const LAKE_MAT := WATER_DIR + "M_water_lake.tres"

const IMG := 1024
## The body criterion B measures. Small enough that the instrument resolves the rim.
const PROBE_SCALE := 1.0
## The body criterion A measures: 1.4 km, the size that started this.
const BIG_SCALE := 13.5
const ACCURACY_BUDGET_M := 0.25

var _fail := 0
var _completed := 0
const CRITERIA := 9
var _out_dir := ""


func _ready() -> void:
	var bail := Timer.new()
	bail.wait_time = 1800.0
	bail.one_shot = true
	bail.timeout.connect(func():
		push_error("probe timed out")
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

	print("=== Pasture3D — Pasture3DPool masked surface ===")
	print("Godot %s | %s" % [
		Engine.get_version_info().string, RenderingServer.get_video_adapter_name()])
	print("")

	await _criterion_a_it_builds()
	await _criterion_b_waterline()
	await _criterion_c_queries_unchanged()
	await _criterion_d_wave_table()
	await _criterion_e_clipmap_scales()
	await _criterion_f_carriers_agree()
	await _criterion_g_it_draws()
	await _criterion_h_coarse_rings()
	await _criterion_i_level_from_spline()

	print("")
	print("completed %d/%d criteria, %d failures" % [_completed, CRITERIA, _fail])
	if _completed < CRITERIA:
		print("!! a criterion did not run to completion -- treat as FAIL")
	print("VERDICT: %s" % ("PASS" if _fail == 0 and _completed == CRITERIA else "FAIL"))
	get_tree().quit(1 if (_fail > 0 or _completed < CRITERIA) else 0)


# ---- A: it builds what the mesher refuses ------------------------------------

func _criterion_a_it_builds() -> void:
	print("[A] a 1.4 km lake, both modes:")
	var root := _scene()
	var pool := _pool(root, BIG_SCALE)

	pool.surface_mode = pool.SurfaceMode.MESHED
	var meshed := await _rebuild(pool)
	print("    MESHED: ok=%s  %s" % [meshed.get("ok", false), meshed.get("reason", "")])
	# CONTROL. If the mesher no longer refuses this body, the masked path is solving a problem
	# that is not there and the numbers below say nothing about whether it was needed.
	if meshed.get("ok", false):
		_fail += 1
		print("    !! MESHED did not refuse -- the premise has changed, re-argue before building")

	pool.surface_mode = pool.SurfaceMode.MASKED
	var masked := await _rebuild(pool)
	print("    MASKED: ok=%s  verts=%d  tris=%d  sheet %.2f m  field=%d^2 (%.2f MB)  %.0f ms" % [
		masked.get("ok", false), masked.get("vertices", 0), masked.get("triangles", 0),
		masked.get("sheet_spacing", 0.0), masked.get("sdf_texels", 0),
		float(masked.get("sdf_bytes", 0)) / 1048576.0, masked.get("ms", 0.0)])
	if not masked.get("ok", false):
		_fail += 1
		print("    !! MASKED did not build: %s" % masked.get("reason", ""))
	else:
		# The point is not that the count is small, it is that it is the SHEET's. A sheet at the
		# same spacing over the same bounds has a count that does not know about the outline.
		var needed := 1103455 # what MESHED reported it wanted, give or take the fixture
		print("    -> %d vertices where the meshed path wanted ~%d (%.0fx fewer)" % [
			masked.get("vertices", 0), needed,
			float(needed) / maxf(masked.get("vertices", 1), 1.0)])
	# And it must be reachable without touching surface_mode at all, which is what AUTO is for.
	pool.surface_mode = pool.SurfaceMode.AUTO
	var auto := await _rebuild(pool)
	print("    AUTO (masks only what will not fit max_vertices=%d): masked=%s, ok=%s" % [
		pool.max_vertices, auto.get("masked", false), auto.get("ok", false)])
	if not auto.get("masked", false) or not auto.get("ok", false):
		_fail += 1
		print("    !! AUTO did not rescue a body the mesher refuses")
	# CONTROL: a body that DOES fit must be left alone by AUTO, or the default silently re-draws
	# every large lake in an existing project.
	var small := _pool(root, PROBE_SCALE)
	small.surface_mode = small.SurfaceMode.AUTO
	var small_stats := await _rebuild(small)
	print("    CONTROL, a body that fits: masked=%s, ok=%s, verts=%d" % [
		small_stats.get("masked", false), small_stats.get("ok", false),
		small_stats.get("vertices", 0)])
	if small_stats.get("masked", false) or not small_stats.get("ok", false):
		_fail += 1
		print("    !! AUTO masked a body that meshes fine -- existing scenes would change")
	root.queue_free()
	await get_tree().process_frame
	_completed += 1


# ---- B: the node's waterline -------------------------------------------------

func _criterion_b_waterline() -> void:
	print("[B] the waterline the NODE frames, against the node's own polygon:")
	var root := _scene()
	var pool := _pool(root, PROBE_SCALE)
	pool.surface_mode = pool.SurfaceMode.MASKED
	# THE STATIC SHEET, because this criterion renders the body's own Surface and a clipmapped body
	# has none -- its geometry is RenderingServer instances the clipmap owns, which cannot be
	# reparented into a measuring viewport. What is under test here is the NODE's framing of its
	# bake, and criterion F establishes that both carriers frame it identically.
	pool.mask_static_sheet = true
	await _rebuild(pool)

	var poly := pool.get_polygon()
	if poly.size() < 3:
		_fail += 1
		print("    !! the pool has no polygon to compare against")
		root.queue_free()
		_completed += 1
		return

	# The analysed square is derived from the POOL's polygon, so this is measuring the node's own
	# framing rather than re-deriving one that happens to agree with it.
	var mn := poly[0]
	var mx := poly[0]
	for v in poly:
		mn = Vector2(minf(mn.x, v.x), minf(mn.y, v.y))
		mx = Vector2(maxf(mx.x, v.x), maxf(mx.y, v.y))
	var extent: float = maxf(mx.x - mn.x, mx.y - mn.y) + 40.0
	var view_min: Vector2 = (mn + mx) * 0.5 - Vector2(extent, extent) * 0.5
	var mpp := extent / float(IMG)
	var truth := SDF.inside_mask(poly, view_min + Vector2(0.5, 0.5) * mpp, mpp, IMG, IMG)
	var truth_area := 0
	for b in truth:
		truth_area += int(b)

	var vp := _ortho(view_min, extent)
	# Re-parent the pool's own Surface into the measuring viewport. The MESH and the FIELD are the
	# node's; only the shading is swapped for the flat readout, because thresholding shaded water
	# measures a specular highlight rather than a waterline.
	var surface: MeshInstance3D = pool.get_node_or_null("Surface")
	if surface == null:
		_fail += 1
		print("    !! the pool built no Surface child")
		root.queue_free()
		vp.queue_free()
		_completed += 1
		return

	var results := {}
	for case in [["node as built", pool.mask_texel], ["CONTROL texel 8 m", 8.0]]:
		pool.mask_texel = case[1]
		await _rebuild(pool)
		var cover := ShaderMaterial.new()
		cover.shader = _coverage_shader()
		# Copied off the node's own runtime material, so what is measured is the field the pool
		# baked and framed -- not one this probe built to the same recipe.
		var rt: ShaderMaterial = pool._runtime_material
		if rt == null:
			_fail += 1
			print("    !! %s: the pool has no runtime material" % case[0])
			continue
		for nm in ["_shore_sdf", "_shore_rect", "_shore_texels", "_shore_range",
				"_shore_feather", "_shore_offset", "_shore_kill_margin"]:
			cover.set_shader_parameter(nm, rt.get_shader_parameter(nm))
		var previous := surface.material_override
		var old_parent := surface.get_parent()
		old_parent.remove_child(surface)
		vp.add_child(surface)
		# RE-ASSERTED every frame, not set once. Writing mask_texel schedules a DEBOUNCED rebuild
		# (0.1 s, as the brushes do), and if that fires while the capture is in flight it calls
		# _apply_material and puts the water material back -- which over this black, unlit viewport
		# renders as nothing and reads as an empty frame. That cost a round of debugging on its own,
		# because it looks exactly like a culled surface.
		for i in 5:
			surface.material_override = cover
			await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		vp.remove_child(surface)
		old_parent.add_child(surface)
		surface.material_override = previous
		var s := SDF.score(img, truth, poly, view_min, mpp, IMG, truth_area)
		results[case[0]] = s
		# Coverage FIRST, because it is what tells an empty frame from a full one -- and both of
		# those score around 40 m on this fixture, which is the polygon's inradius. Two rounds of
		# debugging went into a number that could not distinguish them.
		print("    %-18s p99 %.3f m  max %.3f m  coverage %.2fx truth  (texel %.2f m)" % [
			case[0], s["p99"], s["max"],
			float(s["covered"]) / float(maxi(truth_area, 1)), case[1]])
		print("       aabb %s  mesh %s" % [surface.custom_aabb, surface.mesh.get_aabb()])
		_save(img, "pool_mask_%s.png" % str(case[0]).replace(" ", "_"))

	if results.has("node as built"):
		var ok: bool = results["node as built"]["p99"] <= ACCURACY_BUDGET_M
		if not ok:
			_fail += 1
			print("    !! the node's waterline is outside the %.2f m budget" % ACCURACY_BUDGET_M)
		else:
			print("    -> the node frames its own bake correctly")
	if results.has("CONTROL texel 8 m"):
		if results["CONTROL texel 8 m"]["p99"] <= results["node as built"]["p99"] * 1.5:
			_fail += 1
			print("    !! the control did not degrade, so this is not measuring the field")
		else:
			print("    -> coarsening the field moves the rim, so the metric is live")
	vp.queue_free()
	root.queue_free()
	await get_tree().process_frame
	_completed += 1


# ---- C: the CPU side does not change ----------------------------------------

func _criterion_c_queries_unchanged() -> void:
	print("[C] containment and height, MESHED vs MASKED on the same outline:")
	var root := _scene()
	var pool := _pool(root, PROBE_SCALE)

	# A grid over the bounds plus a margin, so the sample set straddles the shore rather than
	# sitting comfortably inside it where any implementation would agree.
	var probes: Array[Vector3] = []
	for iz in 41:
		for ix in 41:
			probes.append(Vector3(
				lerpf(-75.0, 75.0, float(ix) / 40.0), -0.4,
				lerpf(-60.0, 60.0, float(iz) / 40.0)))

	pool.surface_mode = pool.SurfaceMode.MESHED
	await _rebuild(pool)
	var meshed_in: Array[bool] = []
	var meshed_h: Array[float] = []
	for p in probes:
		meshed_in.append(pool.is_point_underwater(p))
		meshed_h.append(pool.get_water_height(Vector2(p.x, p.z)))

	pool.surface_mode = pool.SurfaceMode.MASKED
	await _rebuild(pool)
	var disagree := 0
	var worst_h := 0.0
	var inside_count := 0
	for i in probes.size():
		var now: bool = pool.is_point_underwater(probes[i])
		if meshed_in[i]:
			inside_count += 1
		if now != meshed_in[i]:
			disagree += 1
		worst_h = maxf(worst_h, absf(pool.get_water_height(
			Vector2(probes[i].x, probes[i].z)) - meshed_h[i]))
	print("    %d probes, %d reported underwater by the meshed build" % [
		probes.size(), inside_count])
	print("    containment disagreements: %d    worst height delta: %.6f m" % [
		disagree, worst_h])
	# Anti-null: a sample set that never entered the water would agree trivially.
	if inside_count < 100:
		_fail += 1
		print("    !! too few probes landed in the water for agreement to mean anything")
	elif disagree > 0 or worst_h > 1e-5:
		_fail += 1
		print("    !! the queries moved. The mesh is supposed to be the only thing that changed.")
	else:
		print("    -> identical. Drawing the water differently did not move where it is.")

	# CONTROL. The same comparison against probes displaced by 3 m must disagree, or the check
	# above is insensitive to containment entirely.
	var control_disagree := 0
	for i in probes.size():
		if pool.is_point_underwater(probes[i] + Vector3(3.0, 0.0, 3.0)) != meshed_in[i]:
			control_disagree += 1
	print("    CONTROL, probes displaced 3 m: %d disagreements" % control_disagree)
	if control_disagree < 10:
		_fail += 1
		print("    !! displacing the probes changed almost nothing -- the comparison is blind")
	root.queue_free()
	await get_tree().process_frame
	_completed += 1


# ---- D: the wave table survived the shader swap -----------------------------

func _criterion_d_wave_table() -> void:
	print("[D] the wave table across the shader swap:")
	var root := _scene()
	var pool := _pool(root, PROBE_SCALE)
	pool.surface_mode = pool.SurfaceMode.MASKED
	await _rebuild(pool)

	var rt: ShaderMaterial = pool._runtime_material
	var src: ShaderMaterial = pool._runtime_source as ShaderMaterial
	if rt == null or src == null:
		_fail += 1
		print("    !! no runtime material to compare (masked build did not produce one)")
		root.queue_free()
		_completed += 1
		return

	var a = src.get_shader_parameter("_waves")
	var b = rt.get_shader_parameter("_waves")
	var amp_a := _amp_sum(a)
	var amp_b := _amp_sum(b)
	print("    resolved shader: %s" % src.shader.resource_path.get_file())
	print("    runtime shader:  %s" % rt.shader.resource_path.get_file())
	print("    _waves amplitude sum: resolved %.4f, runtime %.4f" % [amp_a, amp_b])
	if amp_a <= 0.0:
		_fail += 1
		print("    !! the RESOLVED material has no wave table, so this comparison is vacuous")
		print("       (is there a Pasture3DPoolManager in the scene, with a lake_calm profile?)")
	elif absf(amp_a - amp_b) > 1e-4:
		_fail += 1
		print("    !! the table did not survive the copy. The lake would draw the shader's")
		print("       compile-time waves, out of step with get_water_height().")
	else:
		print("    -> carried across intact")
	if rt.shader == src.shader:
		_fail += 1
		print("    !! the runtime material is on the SAME shader, so no mask was applied")
	root.queue_free()
	await get_tree().process_frame
	_completed += 1


func _amp_sum(p_waves) -> float:
	if p_waves == null:
		return 0.0
	var total := 0.0
	for v in (p_waves as Array):
		total += absf((v as Vector4).z)
	return total


# ---- E: the clipmap's count does not know how large the lake is --------------

func _criterion_e_clipmap_scales() -> void:
	print("[E] the clipmap's cost against the body's size:")
	if not ClassDB.class_exists("Pasture3DWaterClipmap"):
		_fail += 1
		print("    !! Pasture3DWaterClipmap is missing -- the extension is stale")
		_completed += 1
		return
	var counts := []
	for scale in [1.0, 4.8, 13.5]:
		var root := _scene()
		var pool := _pool(root, scale)
		pool.surface_mode = pool.SurfaceMode.MASKED
		var st := await _rebuild(pool)
		var clip: Node = pool.get_node_or_null("Clipmap")
		print("    scale %5.1f  clipmap=%s  verts=%d  lods=%d  reach=%.0f m  LOD0 %.2f m" % [
			scale, st.get("clipmap", false), st.get("vertices", 0),
			st.get("clipmap_lods", 0), st.get("clipmap_reach", 0.0),
			clip.vertex_spacing if clip else 0.0])
		if not st.get("clipmap", false) or clip == null:
			_fail += 1
			print("    !! the masked build did not put a clipmap up")
		else:
			counts.append(st.get("vertices", 0))
			# The reach has to span the body from anywhere in it, or a camera at one end is
			# handed nothing at the other.
			var need: float = (52.0 * scale) * 2.0 * 0.5
			if st.get("clipmap_reach", 0.0) < need:
				_fail += 1
				print("    !! reach %.0f m does not cover a %.0f m half-diagonal" % [
					st.get("clipmap_reach", 0.0), need])
			# And LOD0 must still be at the WAVE spacing -- the whole point is that a body too
			# large to mesh at 1.27 m is still drawn at 1.27 m where the camera is.
			if absf(clip.vertex_spacing - st.get("spacing", 0.0)) > 1e-4:
				_fail += 1
				print("    !! LOD0 is not at the wave spacing, so the detail was not bought back")
		root.queue_free()
		await get_tree().process_frame

	if counts.size() == 3:
		# 13.5x the span. The meshed path grows with the AREA -- 182x by the rebuild probe -- and
		# the sheet grows with it too. This must not.
		var growth: float = float(counts[2]) / maxf(float(counts[0]), 1.0)
		print("    13.5x span -> %.2fx the vertices (meshed grows ~180x)" % growth)
		if growth > 2.0:
			_fail += 1
			print("    !! the clipmap's count is still tracking the body's size")
		else:
			print("    -> the count is a property of the clipmap, not of the lake")
	_completed += 1


# ---- F: the two carriers put the waterline in the same place -----------------

func _criterion_f_carriers_agree() -> void:
	print("[F] clipmap vs static sheet, on one body:")
	var root := _scene()
	var pool := _pool(root, PROBE_SCALE)
	pool.surface_mode = pool.SurfaceMode.MASKED
	# OFF the origin, so the sea_level check below is not satisfied by a zero that would have been
	# there anyway. The clipmap is world-anchored and reads the level from a uniform; a body at
	# y = 0 cannot tell a written level from an unwritten one.
	pool.position = Vector3(0.0, 7.25, 0.0)
	await _rebuild(pool)
	var poly := pool.get_polygon()
	if poly.size() < 3:
		_fail += 1
		print("    !! no polygon")
		root.queue_free()
		_completed += 1
		return

	# The clipmap draws through RenderingServer instances this probe cannot reparent into a
	# measuring viewport, so the comparison is made on the FIELD and its framing -- which is the
	# only thing the two carriers could disagree about. The shore metric itself already covers the
	# static sheet's rendering (criterion B), and the edge probe covers spacing independence, so a
	# clipmap that reads the same field through the same shader lands in the same place.
	var readings := {}
	for use_sheet in [false, true]:
		pool.mask_static_sheet = use_sheet
		await _rebuild(pool)
		var rt: ShaderMaterial = pool._runtime_material
		if rt == null:
			_fail += 1
			print("    !! no runtime material for static_sheet=%s" % use_sheet)
			continue
		readings["sheet" if use_sheet else "clipmap"] = {
			"rect": rt.get_shader_parameter("_shore_rect"),
			"texels": rt.get_shader_parameter("_shore_texels"),
			"range": rt.get_shader_parameter("_shore_range"),
			"feather": rt.get_shader_parameter("_shore_feather"),
			"shader": rt.shader.resource_path.get_file(),
			"sea_level": rt.get_shader_parameter("sea_level"),
		}
	if readings.size() == 2:
		var a: Dictionary = readings["clipmap"]
		var b: Dictionary = readings["sheet"]
		print("    clipmap: %s  rect=%s" % [a["shader"], a["rect"]])
		print("    sheet:   %s  rect=%s" % [b["shader"], b["rect"]])
		var same_field: bool = a["rect"] == b["rect"] and a["texels"] == b["texels"] 			and a["range"] == b["range"] and a["feather"] == b["feather"]
		if not same_field:
			_fail += 1
			print("    !! the two carriers frame the field differently, so the A/B switch")
			print("       changes the shore as well as what draws it")
		else:
			print("    -> identical field and framing; only the carrier differs")
		# CONTROL: the shaders must NOT be the same, or nothing was switched.
		if a["shader"] == b["shader"]:
			_fail += 1
			print("    !! both used %s -- the clipmap variant was never selected" % a["shader"])
		else:
			print("    -> and the shader did change, so the switch is doing something")
		# The clipmap is world-anchored, so it needs the level as a uniform; the sheet is a child
		# and does not. Both are written, and the clipmap's has to be right or the lake sits at 0.
		print("    sea_level written: clipmap=%s sheet=%s (pool Y=%.2f)" % [
			a["sea_level"], b["sea_level"], pool.global_position.y])
		if a["sea_level"] == null or absf(float(a["sea_level"]) - pool.global_position.y) > 1e-4:
			_fail += 1
			print("    !! the clipmap's sea_level does not match the body's Y")
	root.queue_free()
	await get_tree().process_frame
	_completed += 1


# ---- G: the clipmap actually puts water on the screen ------------------------

## Everything above this measures plumbing: counts, uniforms, framing. None of it would notice a
## clipmap that produced no pixels, because its geometry is RenderingServer instances that no
## MeshInstance3D owns and no viewport re-parent can reach. So this renders the real thing, from a
## real camera, and compares its silhouette against the static sheet's on the same body.
func _criterion_g_it_draws() -> void:
	print("[G] the clipmap on screen, against the sheet it replaces:")
	var vp := SubViewport.new()
	vp.size = Vector2i(640, 480)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_DISABLED
	add_child(vp)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.environment = e
	vp.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-58.0, -72.0, 0.0)
	vp.add_child(sun)
	RenderingServer.global_shader_parameter_set("water_sun_direction",
		-sun.global_transform.basis.z)
	RenderingServer.global_shader_parameter_set("water_sun_color", Vector3(1.0, 0.97, 0.9))
	var bank := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(2000.0, 2000.0)
	bank.mesh = plane
	var bm := StandardMaterial3D.new()
	bm.albedo_color = Color(0.42, 0.35, 0.26)
	bm.roughness = 0.95
	bank.material_override = bm
	bank.position = Vector3(0.0, -2.5, 0.0)
	vp.add_child(bank)
	var cam := Camera3D.new()
	cam.near = 0.05
	cam.far = 3000.0
	cam.position = Vector3(-58.0, 19.0, 46.0)
	cam.current = true
	vp.add_child(cam)
	cam.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)

	# The body lives INSIDE the measured viewport, so the clipmap's world is this one.
	var root := _scene()
	remove_child(root)
	vp.add_child(root)
	var pool := _pool(root, PROBE_SCALE)
	pool.surface_mode = pool.SurfaceMode.MASKED

	for i in 6:
		await RenderingServer.frame_post_draw
	var dry := vp.get_texture().get_image()
	# ANTI-NULL, and it has to come first: every number below is a count of "blue-ish" pixels, and
	# a bank or a sky that reads blue-ish would make all of them meaningless.
	var dry_px := 0
	for b in _water_mask(dry, dry):
		dry_px += int(b)
	print("    the water-free frame against itself: %d px of water (must be 0)" % dry_px)
	if dry_px > 0:
		_fail += 1
		print("    !! the cue fires on bare ground -- every count below is noise")

	var shots := {}
	for case in [["sheet", true], ["clipmap", false]]:
		pool.mask_static_sheet = case[1]
		pool.rebuild()
		var clip: Node = pool.get_node_or_null("Clipmap")
		if clip != null:
			clip.set_clipmap_target(cam)
		for i in 8:
			await RenderingServer.frame_post_draw
		shots[case[0]] = vp.get_texture().get_image()
		_save(shots[case[0]], "pool_view_%s.png" % case[0])

	var masks := {}
	for name in shots.keys():
		masks[name] = _fill_columns(_water_mask(dry, shots[name]))
		var px := 0
		for b in masks[name]:
			px += int(b)
		print("    %-8s covers %d px (%.1f%% of frame)" % [
			name, px, 100.0 * float(px) / float(640 * 480)])
		if px < 640 * 480 / 25:
			_fail += 1
			print("    !! %s drew (almost) nothing" % name)

	if masks.size() == 2:
		# Where they disagree, as a picture: red = sheet only, green = clipmap only.
		var xor_img := Image.create(640, 480, false, Image.FORMAT_RGB8)
		for y in 480:
			for x in 640:
				var i := y * 640 + x
				var a: bool = masks["sheet"][i] == 1
				var b: bool = masks["clipmap"][i] == 1
				if a and b:
					xor_img.set_pixel(x, y, Color(0.2, 0.2, 0.2))
				elif a:
					xor_img.set_pixel(x, y, Color(1, 0, 0))
				elif b:
					xor_img.set_pixel(x, y, Color(0, 1, 0))
				else:
					xor_img.set_pixel(x, y, Color.BLACK)
		_save(xor_img, "pool_view_xor.png")
		var iou := _iou(masks["sheet"], masks["clipmap"])
		print("    silhouette IoU, clipmap vs sheet: %.4f" % iou)
		if iou < 0.95:
			_fail += 1
			print("    !! the two carriers do not put the water in the same place")
		else:
			print("    -> the clipmap draws the same body the sheet does")
		# CONTROL: MOVE THE BODY 40 m and the water must move with it.
		#
		# The first version poked _shore_rect on the runtime material directly and the frame came
		# back pixel-identical -- a live uniform edit does not reach geometry the mesher owns, and
		# nothing in the node depends on one, because every mask_* setter schedules a rebuild. So
		# the control now does what a user would: it drags the lake. That also makes it a test of
		# something real, and it caught the bug that the field was being framed in the body's LOCAL
		# xz while both carriers sample in WORLD xz -- invisible until a body sits off the origin,
		# which no fixture had.
		# ACROSS the view, not along it. The first attempt moved it 40 m in +X, which from this
		# camera is mostly straight away -- the lake receded instead of translating and the
		# silhouettes still overlapped at 0.91. This is 60 m along the screen-right axis.
		pool.position = Vector3(37.0, 0.0, 47.0)
		pool.rebuild()
		var clip2: Node = pool.get_node_or_null("Clipmap")
		if clip2 != null:
			clip2.set_clipmap_target(cam)
		for i in 8:
			await RenderingServer.frame_post_draw
		var moved_img := vp.get_texture().get_image()
		_save(moved_img, "pool_view_shifted.png")
		var moved := _fill_columns(_water_mask(dry, moved_img))
		var moved_iou := _iou(masks["sheet"], moved)
		print("    CONTROL, body moved 60 m across the view: IoU %.4f" % moved_iou)
		# The GAP is the evidence, not either number alone: a mask made of noise could not
		# agree at 0.95 with one frame and disagree at 0.8 with another.
		if moved_iou > 0.8:
			_fail += 1
			print("    !! moving the body barely changed the silhouette -- either the water is")
			print("       not following its outline, or this is not measuring where it is")
	vp.queue_free()
	await get_tree().process_frame
	_completed += 1


## The water's FOOTPRINT: every pixel the body changed against the same frame without it.
##
## Three attempts, and the two failures are worth keeping because they are the same mistake in
## opposite directions -- measuring shading when the question is coverage:
##
##   difference at 0.02 scored an IoU of 0.42 between two frames that are visually identical. That
##   threshold is above the pale, foam-covered shallows and below the specular sparkle, so what
##   survived was the sparkle -- which DOES differ between two tessellations of the same waves;
##
##   chroma (blue over red) counted the SKY, reporting 22891 px of water in a frame with none, and
##   with the sky excluded its boundary then ran through the MIDDLE of the lake, because the pale
##   shallows are not blue. Same failure again: a cue that tracks shading, not extent.
##
## The threshold is 0.005 because that is below the darkening the pale shallows get and still far
## above the zero that the untouched sky and dry bank produce -- which is what the dry-against-dry
## control asserts, and it comes out at exactly 0 px rather than "small".
func _water_mask(p_dry: Image, p_wet: Image) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(640 * 480)
	for y in 480:
		for x in 640:
			var a := p_dry.get_pixel(x, y)
			var b := p_wet.get_pixel(x, y)
			var moved: float = maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), absf(a.b - b.b))
			out[y * 640 + x] = 1 if moved > 0.005 else 0
	return out


## Solid footprint from a speckled mask: per screen column, everything between the topmost and
## bottommost water pixel.
##
## Needed because the raw mask disagreed on 32% of its own pixels between two frames that a picture
## of the disagreement showed to be scattered through the INTERIOR, with the outline matching all
## the way round. In the pale, foam-covered shallows the difference-from-dry sits right at the
## threshold, so a hair of shading between two tessellations flips pixels across it. That is a real
## difference and it is not the one under test: this criterion asks where the water ENDS.
##
## A column crossing the inlet twice is filled across the gap. That is a known and acceptable loss --
## it happens identically to both masks, and no other criterion depends on this one resolving a slot
## six metres wide.
func _fill_columns(p_mask: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(p_mask.size())
	for x in 640:
		var top := -1
		var bottom := -1
		for y in 480:
			if p_mask[y * 640 + x] == 1:
				if top < 0:
					top = y
				bottom = y
		if top < 0:
			continue
		for y in range(top, bottom + 1):
			out[y * 640 + x] = 1
	return out


func _iou(p_a: PackedByteArray, p_b: PackedByteArray) -> float:
	var inter := 0
	var uni := 0
	for i in p_a.size():
		var a := p_a[i] == 1
		var b := p_b[i] == 1
		if a and b:
			inter += 1
		if a or b:
			uni += 1
	return float(inter) / float(maxi(uni, 1))


# ---- H: the shore, where the rings are coarse --------------------------------

## The reported symptom: a pond expanded until masking kicked in, and its edges came out jagged.
##
## Criterion G compares the two carriers on a 104 m body, where the derived ring count is three and
## the coarsest cell is 5 m -- small enough that nothing shows. On a 1.4 km body it is six rings, the
## outer cell is 40 m, and the shore spends most of its length out there.
##
## The control is the STATIC SHEET on the SAME body, which is what the clipmap replaced: one uniform
## cell size, and a margin derived from it, so its waterline is as good as the field allows. A
## clipmap materially worse than the sheet it replaced is the bug whatever the absolute number, and
## comparing the two needs no threshold anyone has to choose.
func _criterion_h_coarse_rings() -> void:
	print("[H] the waterline on a body big enough to have coarse rings:")
	var root := _scene()
	var pool := _pool(root, BIG_SCALE)
	pool.surface_mode = pool.SurfaceMode.MASKED
	await _rebuild(pool)
	var poly := pool.get_polygon()
	if poly.size() < 3:
		_fail += 1
		print("    !! no polygon")
		root.queue_free()
		_completed += 1
		return

	var mn := poly[0]
	var mx := poly[0]
	for v in poly:
		mn = Vector2(minf(mn.x, v.x), minf(mn.y, v.y))
		mx = Vector2(maxf(mx.x, v.x), maxf(mx.y, v.y))
	var extent: float = maxf(mx.x - mn.x, mx.y - mn.y) + 120.0
	var view_min: Vector2 = (mn + mx) * 0.5 - Vector2(extent, extent) * 0.5
	var mpp := extent / float(IMG)
	var truth := SDF.inside_mask(poly, view_min + Vector2(0.5, 0.5) * mpp, mpp, IMG, IMG)
	var truth_area := 0
	for b in truth:
		truth_area += int(b)
	print("    %.0f m body at %.2f m/px -- the instrument floor here" % [extent, mpp])

	# The measuring viewport owns the world, because the clipmap draws into whatever world it is in
	# and centres on that viewport's camera -- which puts the rings' centre over the middle of the
	# lake, so the shore falls in the outer rings exactly as it does for someone standing in it.
	var vp := _ortho(view_min, extent)
	root.get_parent().remove_child(root)
	vp.add_child(root)
	await get_tree().process_frame

	var scores := {}
	for case in [["clipmap", false], ["clipmap, mesh_size 64", false],
			["CONTROL static sheet", true]]:
		pool.mask_static_sheet = case[1]
		# A wider ring reaches further, so the same body needs fewer of them and the COARSEST cell
		# is finer. If the residual below still tracks cell size, the per-ring margin has not
		# finished the job; if it does not, what is left is the instrument and the field.
		pool.mask_clipmap_mesh_size = 64 if str(case[0]).ends_with("64") else 16
		pool.rebuild()
		await get_tree().process_frame
		var rt: ShaderMaterial = pool._runtime_material
		if rt == null:
			_fail += 1
			print("    !! no runtime material for %s" % case[0])
			continue
		var cover := ShaderMaterial.new()
		cover.shader = _coverage_shader(not case[1])
		for nm in ["_shore_sdf", "_shore_rect", "_shore_texels", "_shore_range",
				"_shore_feather", "_shore_offset", "_shore_kill_margin", "sea_level"]:
			cover.set_shader_parameter(nm, rt.get_shader_parameter(nm))
		var clip: Node = pool.get_node_or_null("Clipmap")
		var surface: MeshInstance3D = pool.get_node_or_null("Surface")
		var cell := 0.0
		if not case[1]:
			if clip == null:
				_fail += 1
				print("    !! %s: expected a clipmap and found none" % case[0])
				continue
			cell = clip.vertex_spacing * pow(2.0, float(clip.mesh_lods - 1))
		# RE-ASSERTED every frame, for the reason criterion B is: writing mask_static_sheet
		# schedules a DEBOUNCED rebuild, and when it fires it calls _apply_material and _ensure_
		# clipmap, both of which put the water material back. The first version of this set the
		# readout material once and measured the WATER -- brightest pixel 0.09 against a threshold
		# of 0.5, which reads as an empty frame and, because it happened to both cases equally,
		# reads as the two carriers agreeing perfectly.
		#
		# Swapping the CLIPMAP's material is the only way to read its footprint at all: the geometry
		# is RenderingServer instances, and set_material re-initialises the mesher onto the new RID
		# and re-pushes _mesh_size / _vertex_spacing / _subdiv into it.
		for i in 8:
			if case[1]:
				surface.material_override = cover
			else:
				clip.material = cover
			await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		var sc := SDF.score(img, truth, poly, view_min, mpp, IMG, truth_area)
		scores[case[0]] = sc
		print("    %-21s p99 %6.2f m  max %6.2f m  coverage %.2fx  rings=%d coarsest cell %.1f m" % [
			case[0], sc["p99"], sc["max"],
			float(sc["covered"]) / float(maxi(truth_area, 1)),
			0 if clip == null else clip.mesh_lods, cell])
		_save(img, "pool_coarse_%s.png" % str(case[0]).replace(" ", "_"))

	if scores.has("clipmap") and scores.has("CONTROL static sheet"):
		var c: float = scores["clipmap"]["p99"]
		var sheet: float = scores["CONTROL static sheet"]["p99"]
		print("    clipmap %.2f m vs the sheet it replaced %.2f m  (%.1fx)" % [
			c, sheet, c / maxf(sheet, 1e-3)])
		# The mesh_size 64 row is a READING, not an assertion, and it is how the morph was pinned:
		# with the margin at 1.5 * cell it scored 2.97 m against 16's 1.35 m -- a FINER coarsest
		# cell scoring worse, which ruled out the cull and pointed at the geomorph, since four
		# rings put the outermost morph band at 694 m and this shore sits at ~700 m. With the
		# margin widened to cover the morph's 2 * cell displacement the two agree, and that
		# agreement is the evidence the diagnosis was right.
		if scores.has("clipmap, mesh_size 64"):
			var wide: float = scores["clipmap, mesh_size 64"]["p99"]
			print("    reading: mesh_size 64 (4 rings, 10.2 m coarsest) is %.2f m against 16's %.2f m" % [
				wide, c])
			if wide > c * 1.5:
				_fail += 1
				print("    !! the two ring layouts disagree, so something is still tracking the")
				print("       ring geometry rather than the field")
		# The bound is edge_offset, because that is the physical thing that matters: the rim is
		# meant to be buried in the bank, and a waterline inside the offset is a waterline nobody
		# can see. Not a ratio against the sheet -- the sheet is better here and saying so is
		# information, not a failure -- and not a multiple of the pixel size, which would have let
		# the 35 m version pass on a coarse instrument.
		if c > pool.edge_offset:
			_fail += 1
			print("    !! the clipmap's rim reaches past edge_offset (%.2f m), so it emerges from" % pool.edge_offset)
			print("       the bank. One kill margin for every ring removes whole coarse cells")
			print("       that straddle the shore, and the edge then steps at cell size.")
	vp.queue_free()
	_completed += 1


# ---- I: the water level, taken from the spline --------------------------------

## fill_offset used to mean something only at the instant Fit to Curve was pressed. level_from_spline
## makes it a live dial, which is what authoring a basin actually needs -- and the risk in doing that
## is a rebuild loop, because writing this node's transform is what a rebuild would then do.
##
## A loop would hang the probe rather than fail it, so the bail timer is the backstop; what is
## asserted here is that the level lands where the spline says, that changing the offset moves it,
## and that with the flag OFF nothing moves at all.
func _criterion_i_level_from_spline() -> void:
	print("[I] the water level relative to the spline:")
	var root := _scene()
	# A source_spline, not a bare curve: the level is solved in WORLD space and a bare curve travels
	# with the node, so there is nothing to solve for -- the node says so and this checks that too.
	var path := Path3D.new()
	path.curve = _curve(PROBE_SCALE)
	path.position = Vector3(0.0, 12.0, 0.0)
	root.add_child(path)
	var pool := Pasture3DPool.new()
	pool.name = "LevelPool"
	pool.source_spline = path
	pool.wave_profile = &"lake_calm"
	pool.material = load(LAKE_MAT)
	pool.underwater_enabled = false
	root.add_child(pool)
	await get_tree().process_frame

	# The spline's lowest baked point in world Y. The curve is flat at y = 0 in its own space and the
	# Path3D sits at 12, so the level should come out at 12 + fill_offset.
	pool.fill_offset = -0.5
	pool.level_from_spline = false
	await _rebuild(pool)
	var before := pool.global_position.y
	print("    flag off: pool Y = %.3f (spline lowest 12.00, offset -0.50)" % before)

	pool.level_from_spline = true
	await _rebuild(pool)
	var on := pool.global_position.y
	print("    flag on:  pool Y = %.3f  (want 11.50)" % on)
	if not is_equal_approx(on, 11.5):
		_fail += 1
		print("    !! the level did not land on the spline's lowest point + fill_offset")

	pool.fill_offset = -3.0
	await _rebuild(pool)
	var moved := pool.global_position.y
	print("    offset -3.0: pool Y = %.3f  (want 9.00)" % moved)
	if not is_equal_approx(moved, 9.0):
		_fail += 1
		print("    !! fill_offset is not live with the flag on")

	# CONTROL. With the flag off, the same edit must move nothing -- otherwise the level is being
	# taken from the spline unconditionally and every existing scene's water has just moved.
	pool.level_from_spline = false
	pool.global_position.y = 40.0
	pool.fill_offset = -7.0
	await _rebuild(pool)
	print("    CONTROL, flag off and offset -7.0: pool Y = %.3f (want 40.00)" % pool.global_position.y)
	if not is_equal_approx(pool.global_position.y, 40.0):
		_fail += 1
		print("    !! the level moved with the flag off -- existing scenes would change")

	# And the warning has to name the case it cannot serve, rather than sitting at whatever Y it
	# happened to be left at.
	var bare := Pasture3DPool.new()
	bare.curve = _curve(PROBE_SCALE)
	bare.level_from_spline = true
	bare.material = load(LAKE_MAT)
	root.add_child(bare)
	await get_tree().process_frame
	var warns := "\n".join(Array(bare._get_configuration_warnings()))
	var names_it := warns.contains("level_from_spline")
	print("    a bare curve warns about it: %s" % names_it)
	if not names_it:
		_fail += 1
		print("    !! level_from_spline on a bare curve is silently inert")
	root.queue_free()
	await get_tree().process_frame
	_completed += 1


# ---- plumbing ---------------------------------------------------------------

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
	# FROZEN. The manager writes water_time every physics tick, so criterion C's two passes were
	# sampling different wave phases and its "the queries moved" failure was this, not the node:
	# get_water_height() includes the wave displacement, and probes 0.4 m under a surface with a
	# 0.67 m amplitude sum flip as the crests go past. Setting the global once at startup is not
	# enough -- the node overwrites it.
	m.set_physics_process(false)
	RenderingServer.global_shader_parameter_set("water_time", 0.0)
	return root


func _pool(p_root: Node3D, p_scale: float) -> Pasture3DPool:
	var pool := Pasture3DPool.new()
	pool.name = "Pool"
	pool.curve = _curve(p_scale)
	pool.wave_profile = &"lake_calm"
	pool.material = load(LAKE_MAT)
	pool.underwater_enabled = false
	p_root.add_child(pool)
	return pool


## The shore probes' outline, as a closed Curve3D.
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
		var a := TAU * float(i) / float(N)
		if a > chord_a and a < chord_b:
			continue
		if not inlet_done and a >= inlet_at:
			for p in [_e(inlet_at - deg_to_rad(2.2), p_scale),
					_e(inlet_at - deg_to_rad(2.2), p_scale * 0.62),
					_e(inlet_at + deg_to_rad(2.2), p_scale * 0.62),
					_e(inlet_at + deg_to_rad(2.2), p_scale)]:
				c.add_point(p)
			inlet_done = true
			continue
		if not head_done and a >= head_at:
			c.add_point(_e(head_at, p_scale * 1.34))
			head_done = true
			continue
		c.add_point(_e(a, p_scale))
	c.closed = true
	return c


func _e(p_angle: float, p_scale: float) -> Vector3:
	return Vector3(cos(p_angle) * 52.0, 0.0, sin(p_angle) * 41.0) * p_scale


## Rebuild and let the frame settle, so a mesh assigned this frame is drawable next.
##
## Re-freezes the clock: process_frame runs a physics tick, and any manager that is not held still
## advances water_time across it.
func _rebuild(p_pool: Pasture3DPool) -> Dictionary:
	RenderingServer.global_shader_parameter_set("water_time", 0.0)
	var stats: Dictionary = p_pool.rebuild()
	await get_tree().process_frame
	return stats


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
	cam.far = 2000.0
	cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	cam.position = Vector3(p_view_min.x + p_extent * 0.5, 400.0,
		p_view_min.y + p_extent * 0.5)
	cam.current = true
	vp.add_child(cam)
	return vp


## Unlit flat coverage over the shore mask.
##
## p_clipmap includes the SHIPPED vertex stage instead of a hand-written one, because on a clipmap
## the geomorph, the sea_level lift and the vertex kill are the things under test and a substitute
## would be testing this probe. Only fragment() is ours; water_shading is left out so it can be.
func _coverage_shader(p_clipmap: bool = false) -> Shader:
	var lines := [
		"shader_type spatial;",
		"render_mode unshaded, cull_disabled, depth_draw_never, skip_vertex_transform;",
		"#define WATER_SHORE_MASK",
		"#define WATER_WAVE_COUNT 4",
	]
	if p_clipmap:
		lines.append("#define WATER_CLIPMAP")
	lines.append('#include "%swater_common.gdshaderinc"' % WATER_DIR)
	if p_clipmap:
		lines.append('#include "%swater_waves.gdshaderinc"' % WATER_DIR)
		lines.append('#include "%swater_surface.gdshaderinc"' % WATER_DIR)
	else:
		lines.append_array([
			"void vertex() {",
			"	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;",
			"	v_world_pos = wp;",
			"	v_shore_xz = wp.xz;",
			"	VERTEX = (VIEW_MATRIX * vec4(wp, 1.0)).xyz;",
			"	NORMAL = normalize(mat3(VIEW_MATRIX) * vec3(0.0, 1.0, 0.0));",
			"	if (water_shore_distance(wp.xz) > _shore_kill_margin) {",
			"		VERTEX = vec3(0.0 / 0.0);",
			"	}",
			"}",
		])
	lines.append_array([
		"void fragment() {",
		"	ALBEDO = vec3(1.0);",
		"	ALPHA = water_shore_alpha(v_shore_xz);",
		"}",
	])
	var sh := Shader.new()
	sh.code = "\n".join(lines)
	return sh


func _save(p_img: Image, p_name: String) -> void:
	var path := _out_dir + p_name
	if p_img.save_png(path) != OK or not FileAccess.file_exists(path):
		_fail += 1
		print("    !! save %s failed" % path)
