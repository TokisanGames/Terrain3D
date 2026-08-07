# Pasture3D Water — overlapping bodies probe (prototype, water LOD work).
#
# The second thing the shore-edge probe did not cover. A masked sheet is camera-centred
# and effectively unbounded; the mask is what makes it a lake. Three things about that
# only show up with more than one body, or with the camera moving:
#
#   A. THE SHEET MOVES AND THE SHORE MUST NOT. A clipmap slides and snaps under the
#      camera. The mask is anchored in the world. If the waterline moves at all when the
#      sheet moves beneath it, the whole approach is dead on arrival -- the shore would
#      crawl as the player walks.
#
#   B. THE APRON. Between the shore and the vertex kill margin, geometry exists with alpha
#      ramping to zero. Two bodies near each other overlap their aprons over dry ground.
#      Nothing should be visible there; "alpha zero" and "no fragment" have to be the same
#      picture, or every lake gets a faint halo.
#
#   C. DRAW ORDER. Two transparent sheets that are both centred on the camera have nearly
#      identical sort keys, so which draws first can flip as the camera moves. Blending is
#      order-dependent, so a flip is a visible pop in the overlap. The question is not
#      whether blending depends on order -- it does, and it already does for the meshes
#      shipped today -- but whether MASKED sheets are less stable about it than the meshes
#      they would replace. So the exact-clip pair is measured alongside as the baseline.
#
# Each criterion carries a control that must fail, and criterion C's control is the one
# that matters most: the two forced draw orders have to differ from each other, or
# "matches both" is not evidence of stability, it is evidence of measuring nothing.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/WaterShoreOverlapProbe.tscn
#      BENCH_OUT=<dir> for the captures.
extends Node

const SDF := preload("res://bench/shore_sdf.gd")
const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"

const IMG := 512
const SDF_TEXEL := 1.0
const SDF_RANGE := 24.0
const FEATHER := 0.5
const SPACING := 1.27
## The camera-centred sheet's extent. Far larger than either body, which is the condition
## being tested: the mask is what makes it a lake, not the mesh's size.
const SHEET_SPAN := 420.0
## Camera positions in the draw-order sweep.
const SWEEP := 12

var _fail := 0
var _completed := 0
const CRITERIA := 3
var _out_dir := ""

var _poly_a := PackedVector2Array()
var _poly_b := PackedVector2Array()
var _sdf_a := {}
var _sdf_b := {}
## The analysed square, in world XZ. Shared by every top-down pass.
var _view_min := Vector2.ZERO
var _view_size := 0.0
var _mpp := 0.0

const Y_A := 0.0
const Y_B := 3.5
## Roughly where the two outlines share ground. Criterion C orbits this rather than the
## scene, so the region it measures stays a large part of the frame.
const OVERLAP_CENTRE := Vector3(34.0, 2.0, 12.0)


func _ready() -> void:
	var bail := Timer.new()
	bail.wait_time = 1200.0
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
	RenderingServer.global_shader_parameter_set("water_sun_direction", Vector3(0.4, 0.72, -0.57))
	RenderingServer.global_shader_parameter_set("water_sun_color", Vector3(1.0, 0.97, 0.9))

	print("=== Pasture3D — overlapping bodies probe ===")
	print("Godot %s | %s" % [
		Engine.get_version_info().string, RenderingServer.get_video_adapter_name()])
	print("")
	_prepare()

	await _criterion_a_sheet_motion()
	await _criterion_b_apron()
	await _criterion_c_draw_order()

	print("")
	print("completed %d/%d criteria, %d failures" % [_completed, CRITERIA, _fail])
	if _completed < CRITERIA:
		print("!! a criterion did not run to completion -- treat as FAIL")
	print("VERDICT: %s" % ("PASS" if _fail == 0 and _completed == CRITERIA else "FAIL"))
	get_tree().quit(1 if (_fail > 0 or _completed < CRITERIA) else 0)


func _prepare() -> void:
	# Two bodies that genuinely overlap in XZ at different levels -- a terrace pool over a
	# lake. Contrived on purpose: it is the arrangement that breaks, and a scene where the
	# bodies do not overlap cannot answer the question.
	_poly_a = _ellipse_poly(Vector2.ZERO, Vector2(52.0, 41.0))
	_poly_b = _ellipse_poly(Vector2(46.0, 12.0), Vector2(30.0, 24.0))

	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for p in [_poly_a, _poly_b]:
		for v in p:
			mn = Vector2(minf(mn.x, v.x), minf(mn.y, v.y))
			mx = Vector2(maxf(mx.x, v.x), maxf(mx.y, v.y))
	var extent: float = maxf(mx.x - mn.x, mx.y - mn.y) + 56.0
	_view_size = extent
	_view_min = (mn + mx) * 0.5 - Vector2(extent, extent) * 0.5
	_mpp = _view_size / float(IMG)

	_sdf_a = SDF.bake(_poly_a, _view_min, _view_size, SDF_TEXEL, Image.FORMAT_RF,
		SDF_RANGE, true, 2)
	_sdf_b = SDF.bake(_poly_b, _view_min, _view_size, SDF_TEXEL, Image.FORMAT_RF,
		SDF_RANGE, true, 2)

	var inside_a := SDF.inside_mask(_poly_a, _view_min + Vector2(0.5, 0.5) * _mpp,
		_mpp, IMG, IMG)
	var inside_b := SDF.inside_mask(_poly_b, _view_min + Vector2(0.5, 0.5) * _mpp,
		_mpp, IMG, IMG)
	var overlap := 0
	for i in inside_a.size():
		if inside_a[i] == 1 and inside_b[i] == 1:
			overlap += 1
	print("bodies: A at y=%.1f, B at y=%.1f; they share %d px (%.1f%% of the frame)" % [
		Y_A, Y_B, overlap, 100.0 * float(overlap) / float(IMG * IMG)])
	print("sheet:  %.0f m span, camera-centred; each body's mask is what bounds it" % SHEET_SPAN)
	print("view:   %.1f m square, %.4f m/px at %d px" % [_view_size, _mpp, IMG])
	print("")
	if overlap < 500:
		_fail += 1
		print("!! the two bodies barely overlap -- criterion C has nothing to measure")


func _ellipse_poly(p_centre: Vector2, p_radii: Vector2) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 72:
		var a := TAU * float(i) / 72.0
		pts.append(p_centre + Vector2(cos(a) * p_radii.x, sin(a) * p_radii.y))
	return pts


# ---- A: the sheet moves, the shore does not ----------------------------------

func _criterion_a_sheet_motion() -> void:
	print("[A] the sheet slides under a world-anchored mask:")
	var vp := _ortho_viewport()
	var mi := MeshInstance3D.new()
	mi.extra_cull_margin = 256.0
	mi.mesh = _sheet_mesh(SPACING, SHEET_SPAN)
	var mat := ShaderMaterial.new()
	mat.shader = _coverage_shader()
	_apply_shore(mat, _sdf_a, SPACING)
	mi.material_override = mat
	vp.add_child(mi)

	# Three sheet origins: aligned, half a cell, and an arbitrary fraction. A clipmap
	# snaps to whole cells, so the half-cell case is the one it actually produces; the
	# arbitrary one is there because "it works at the offsets we thought of" is not the
	# claim being made.
	var shots := {}
	for off in [0.0, SPACING * 0.5, SPACING * 0.37]:
		mi.position = Vector3(off, Y_A, off)
		for i in 4:
			await RenderingServer.frame_post_draw
		shots["%.3f" % off] = vp.get_texture().get_image()

	var base: Image = shots["0.000"]
	var worst := 0.0
	for key in shots.keys():
		if key == "0.000":
			continue
		var d := _mean_abs_diff(base, shots[key], PackedByteArray())
		worst = maxf(worst, d)
		print("    sheet offset %s m -> mean abs diff vs aligned: %.6f" % [key, d])
	if worst > 0.002:
		_fail += 1
		print("    !! the waterline moves with the sheet. A walking player would see the")
		print("       shore crawl, and this approach cannot be used as it stands.")
	else:
		print("    -> the shore is stationary under a moving sheet")

	# CONTROL. Move the MASK instead of the sheet, by one metre. If the instrument cannot
	# see that, it could not have seen the shore crawling either.
	mi.position = Vector3(0.0, Y_A, 0.0)
	var moved := _sdf_a["rect"] as Vector4
	mat.set_shader_parameter("_shore_rect",
		Vector4(moved.x + 1.0, moved.y, moved.z, moved.w))
	for i in 4:
		await RenderingServer.frame_post_draw
	var control := _mean_abs_diff(base, vp.get_texture().get_image(), PackedByteArray())
	print("    CONTROL, mask shifted 1 m -> mean abs diff %.6f" % control)
	if control < 0.002:
		_fail += 1
		print("    !! the control did not register, so the null result above is not evidence")
	else:
		print("    -> the instrument responds to a 1 m shift, so the null above is real")
	vp.queue_free()
	_completed += 1


# ---- B: the apron over dry ground --------------------------------------------

func _criterion_b_apron() -> void:
	print("[B] the alpha-zero apron between shore and kill margin:")
	var kill := SPACING * 1.5 + FEATHER
	# Outside both outlines by more than the feather can reach, but inside the region
	# where the sheet still has surviving geometry. This is the band that exists in the
	# masked approach and does not exist today.
	var apron := _apron_mask(1.0, kill + 4.0)
	var apron_px := 0
	for b in apron:
		apron_px += int(b)
	print("    apron region: %d px (%.1f%% of frame)" % [
		apron_px, 100.0 * float(apron_px) / float(IMG * IMG)])
	if apron_px < 2000:
		_fail += 1
		print("    !! the apron region is too small to measure")
		_completed += 1
		return

	var vp := _ortho_viewport(true)
	var bank := _bank()
	vp.add_child(bank)
	var pair := _masked_pair(SPACING)
	for mi in pair:
		vp.add_child(mi)

	for i in 6:
		await RenderingServer.frame_post_draw
	var with_water := vp.get_texture().get_image()

	for mi in pair:
		mi.visible = false
	for i in 6:
		await RenderingServer.frame_post_draw
	var dry := vp.get_texture().get_image()

	var d := _mean_abs_diff(with_water, dry, apron)
	print("    apron with water vs bare ground: mean abs diff %.6f" % d)
	if d > 0.002:
		_fail += 1
		print("    !! the apron is visible -- every body would carry a halo out to its")
		print("       kill margin, which grows with the coarsest LOD")
	else:
		print("    -> nothing is drawn there; alpha zero and no geometry are the same picture")

	# CONTROL. A feather wide enough to genuinely reach into the apron. If a 12 m ramp
	# does not register, the null result above is the instrument, not the shader.
	for mi in pair:
		mi.visible = true
		(mi.material_override as ShaderMaterial).set_shader_parameter("_shore_feather", 12.0)
	for i in 6:
		await RenderingServer.frame_post_draw
	var wide := vp.get_texture().get_image()
	var dc := _mean_abs_diff(wide, dry, apron)
	print("    CONTROL, feather 12 m -> mean abs diff %.6f" % dc)
	if dc < 0.002:
		_fail += 1
		print("    !! the control did not register, so the null result above is not evidence")
	else:
		print("    -> the instrument sees a %0.0fx wider ramp, so the null above is real" % (12.0 / FEATHER))
	_save(with_water, "overlap_apron_water.png")
	_save(wide, "overlap_apron_control.png")
	vp.queue_free()
	_completed += 1


## Pixels outside BOTH outlines by at least p_inner metres and within p_outer of one.
func _apron_mask(p_inner: float, p_outer: float) -> PackedByteArray:
	var origin := _view_min + Vector2(0.5, 0.5) * _mpp
	var out := PackedByteArray()
	out.resize(IMG * IMG)
	var inner_a := SDF.inside_mask(_grow(_poly_a, p_inner), origin, _mpp, IMG, IMG)
	var inner_b := SDF.inside_mask(_grow(_poly_b, p_inner), origin, _mpp, IMG, IMG)
	var outer_a := SDF.inside_mask(_grow(_poly_a, p_outer), origin, _mpp, IMG, IMG)
	var outer_b := SDF.inside_mask(_grow(_poly_b, p_outer), origin, _mpp, IMG, IMG)
	for i in out.size():
		var near: bool = outer_a[i] == 1 or outer_b[i] == 1
		var inside: bool = inner_a[i] == 1 or inner_b[i] == 1
		out[i] = 1 if (near and not inside) else 0
	return out


func _grow(p_poly: PackedVector2Array, p_by: float) -> PackedVector2Array:
	var rings := Geometry2D.offset_polygon(p_poly, p_by, Geometry2D.JOIN_MITER)
	var best := p_poly
	var best_area := -1.0
	for r in rings:
		var a := 0.0
		for i in r.size():
			var q := r[(i + 1) % r.size()]
			a += r[i].x * q.y - q.x * r[i].y
		if absf(a) > best_area:
			best_area = absf(a)
			best = r
	return best


# ---- C: draw order ------------------------------------------------------------

func _criterion_c_draw_order() -> void:
	print("[C] draw-order stability across a camera sweep:")
	var vp := SubViewport.new()
	vp.size = Vector2i(IMG, IMG)
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
	sun.rotation_degrees = Vector3(-55.0, -70.0, 0.0)
	vp.add_child(sun)
	vp.add_child(_bank())
	var cam := Camera3D.new()
	cam.near = 0.05
	cam.far = 3000.0
	cam.current = true
	vp.add_child(cam)

	for variant in ["exact (today)", "masked sheets"]:
		var pair: Array = _exact_pair() if variant.begins_with("exact") \
			else _masked_pair(SPACING)
		for mi in pair:
			vp.add_child(mi)
		var flips := 0
		var order_seq := ""
		var control_ok := true
		var min_separation := INF
		var min_region := 1 << 30
		var whole_frame_sep := 0.0
		for step in SWEEP:
			var t := float(step) / float(SWEEP - 1)
			var ang: float = lerpf(-0.5, 0.6, t)
			# Orbiting the OVERLAP, not the scene. The first sweep circled the whole pair
			# from 150 m and the shared area came to 454 px -- a real number over almost
			# no pixels, which is the shape of a result that means nothing.
			cam.position = OVERLAP_CENTRE + Vector3(sin(ang) * 85.0, 20.0, cos(ang) * 85.0)
			cam.look_at(OVERLAP_CENTRE, Vector3.UP)
			if not variant.begins_with("exact"):
				# What a clipmap does: both sheets snap to the camera, which is exactly
				# what makes their sort keys collide.
				for mi in pair:
					var snap := SPACING * 2.0
					mi.position = Vector3(
						roundf(cam.position.x / snap) * snap,
						Y_A if mi.get_meta("body") == "a" else Y_B,
						roundf(cam.position.z / snap) * snap)

			var shot := await _grab(vp, pair, 0, 0)
			var a_first := await _grab(vp, pair, 1, 2)
			var b_first := await _grab(vp, pair, 2, 1)
			var region := _overlap_region(cam)
			var region_px := 0
			for b in region:
				region_px += int(b)
			min_region = mini(min_region, region_px)
			# Whole-frame separation as well as region separation. If the two forced
			# orders differ nowhere AT ALL then render_priority is not reaching the sort,
			# which is a different failure from "the overlap happens to look the same".
			whole_frame_sep = maxf(whole_frame_sep,
				_mean_abs_diff(a_first, b_first, PackedByteArray()))
			var sep := _mean_abs_diff(a_first, b_first, region)
			min_separation = minf(min_separation, sep)
			var da := _mean_abs_diff(shot, a_first, region)
			var db := _mean_abs_diff(shot, b_first, region)
			order_seq += "A" if da <= db else "B"
		for mi in pair:
			(mi.material_override as Material).render_priority = 0
		for i in range(1, order_seq.length()):
			if order_seq[i] != order_seq[i - 1]:
				flips += 1
		print("    %-14s order across sweep: %s   flips: %d" % [
			variant, order_seq, flips])
		print("       overlap region: >= %d px every frame" % min_region)
		print("       CONTROL, forced orders differ by %.5f in the overlap, %.5f frame-wide" % [
			min_separation, whole_frame_sep])
		if min_region < 800:
			control_ok = false
			_fail += 1
			print("       !! the overlap barely reaches the screen, so the numbers above")
			print("          are measuring almost no pixels")
		elif min_separation < 0.002:
			control_ok = false
			_fail += 1
			print("       !! the forced orders are indistinguishable, so the sequence above")
			print("          is noise and says nothing about stability")
		if control_ok and flips > 0:
			print("       -> the draw order FLIPS mid-sweep; every flip is a visible pop")
			print("          in the overlap, because blending is order-dependent")
		elif control_ok:
			print("       -> order is stable across the sweep")
		for mi in pair:
			vp.remove_child(mi)
			mi.queue_free()
	vp.queue_free()
	_completed += 1


## Render once at the given draw priorities.
##
## render_priority is a MATERIAL property in Godot 4, not a VisualInstance one -- which is
## the right place for it here anyway, since it is the transparent sort key being forced.
func _grab(p_vp: SubViewport, p_pair: Array, p_pa: int, p_pb: int) -> Image:
	(p_pair[0].material_override as Material).render_priority = p_pa
	(p_pair[1].material_override as Material).render_priority = p_pb
	for i in 3:
		await RenderingServer.frame_post_draw
	return p_vp.get_texture().get_image()


## Screen-space pixels where both bodies have water.
##
## Projected analytically rather than sampled off a render. The first version thresholded
## the rendered colour ("water reads bluer than the bank"), which is a guess about shading
## dressed up as a measurement -- and when it found nothing, _mean_abs_diff over an empty
## mask returned a clean 0.0 that was indistinguishable from "the two orders agree".
##
## Both bodies are planar, and a perspective projection maps straight lines to straight
## lines, so projecting each outline's vertices and intersecting the two screen polygons
## is exact -- no renders, no threshold, and it cannot come back empty by accident.
func _overlap_region(p_cam: Camera3D) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(IMG * IMG)
	var screen := []
	for spec in [[_poly_a, Y_A], [_poly_b, Y_B]]:
		var proj := PackedVector2Array()
		for v in (spec[0] as PackedVector2Array):
			var world := Vector3(v.x, spec[1], v.y)
			if p_cam.is_position_behind(world):
				return out # a body straddling the near plane: no honest region this frame
			proj.append(p_cam.unproject_position(world))
		screen.append(proj)
	for piece in Geometry2D.intersect_polygons(screen[0], screen[1]):
		if piece.size() < 3:
			continue
		var mask := SDF.inside_mask(piece, Vector2(0.5, 0.5), 1.0, IMG, IMG)
		for i in out.size():
			if mask[i] == 1:
				out[i] = 1
	return out


# ---- plumbing ----------------------------------------------------------------

## Mean absolute per-channel difference. An empty mask means the whole frame.
func _mean_abs_diff(p_a: Image, p_b: Image, p_mask: PackedByteArray) -> float:
	var total := 0.0
	var n := 0
	var masked := not p_mask.is_empty()
	for y in IMG:
		for x in IMG:
			if masked and p_mask[y * IMG + x] == 0:
				continue
			var ca := p_a.get_pixel(x, y)
			var cb := p_b.get_pixel(x, y)
			total += maxf(maxf(absf(ca.r - cb.r), absf(ca.g - cb.g)), absf(ca.b - cb.b))
			n += 1
	return total / float(maxi(n, 1))


func _ortho_viewport(p_lit: bool = false) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = Vector2i(IMG, IMG)
	vp.own_world_3d = true
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_DISABLED
	add_child(vp)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	if p_lit:
		e.background_mode = Environment.BG_SKY
		var sky := Sky.new()
		sky.sky_material = ProceduralSkyMaterial.new()
		e.sky = sky
		e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		var sun := DirectionalLight3D.new()
		sun.rotation_degrees = Vector3(-55.0, -70.0, 0.0)
		vp.add_child(sun)
	else:
		e.background_mode = Environment.BG_COLOR
		e.background_color = Color.BLACK
		e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		e.ambient_light_color = Color.BLACK
		e.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.environment = e
	vp.add_child(env)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = _view_size
	cam.near = 1.0
	cam.far = 500.0
	cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	cam.position = Vector3(_view_min.x + _view_size * 0.5, 120.0,
		_view_min.y + _view_size * 0.5)
	cam.current = true
	vp.add_child(cam)
	return vp


func _bank() -> MeshInstance3D:
	var bank := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(1200.0, 1200.0)
	bank.mesh = plane
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.42, 0.35, 0.26)
	m.roughness = 0.95
	bank.material_override = m
	bank.position = Vector3(0.0, -2.5, 0.0)
	return bank


## Two masked sheets, each cut to its own body. What the plan would produce.
func _masked_pair(p_spacing: float) -> Array:
	var out := []
	for spec in [["a", _sdf_a, Y_A], ["b", _sdf_b, Y_B]]:
		var mi := MeshInstance3D.new()
		mi.extra_cull_margin = 512.0
		mi.mesh = _sheet_mesh(p_spacing, SHEET_SPAN)
		mi.position = Vector3(0.0, spec[2], 0.0)
		mi.set_meta("body", spec[0])
		var mat := ShaderMaterial.new()
		mat.shader = load(WATER_DIR + "water_lake_masked.gdshader")
		_apply_shore(mat, spec[1], p_spacing)
		mi.material_override = mat
		out.append(mi)
	return out


## Two exactly-clipped meshes. Today's behaviour, the baseline for criterion C.
func _exact_pair() -> Array:
	var out := []
	for spec in [["a", _poly_a, Y_A], ["b", _poly_b, Y_B]]:
		var mi := MeshInstance3D.new()
		mi.extra_cull_margin = 128.0
		var poly: PackedVector2Array = spec[1]
		var mn := Vector2(INF, INF)
		var mx := Vector2(-INF, -INF)
		for v in poly:
			mn = Vector2(minf(mn.x, v.x), minf(mn.y, v.y))
			mx = Vector2(maxf(mx.x, v.x), maxf(mx.y, v.y))
		mn = Vector2(floorf(mn.x / SPACING) * SPACING, floorf(mn.y / SPACING) * SPACING)
		var gw := int(ceil((mx.x - mn.x) / SPACING)) + 2
		var gh := int(ceil((mx.y - mn.y) / SPACING)) + 2
		mi.mesh = Pasture3DUtil.build_pool_mesh(poly, mn, SPACING, gw, gh)
		mi.position = Vector3(0.0, spec[2], 0.0)
		mi.set_meta("body", spec[0])
		var mat := ShaderMaterial.new()
		mat.shader = load(WATER_DIR + "water_body.gdshader")
		mi.material_override = mat
		out.append(mi)
	return out


func _sheet_mesh(p_spacing: float, p_span: float) -> ArrayMesh:
	var n := int(ceil(p_span / p_spacing)) + 1
	var half := p_span * 0.5
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for iz in n:
		for ix in n:
			verts.append(Vector3(-half + ix * p_spacing, 0.0, -half + iz * p_spacing))
	for iz in n - 1:
		for ix in n - 1:
			var a := iz * n + ix
			idx.append_array([a, a + n, a + 1, a + 1, a + n, a + n + 1])
	var normals := PackedVector3Array()
	normals.resize(verts.size())
	normals.fill(Vector3.UP)
	var colours := PackedColorArray()
	colours.resize(verts.size())
	colours.fill(Color(0.5, 0.5, 0.0, 1.0))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _coverage_shader() -> Shader:
	var sh := Shader.new()
	sh.code = "\n".join([
		"shader_type spatial;",
		"render_mode unshaded, cull_disabled, depth_draw_never, skip_vertex_transform;",
		"#define WATER_SHORE_MASK",
		'#include "%swater_common.gdshaderinc"' % WATER_DIR,
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
		"void fragment() {",
		"	ALBEDO = vec3(1.0);",
		"	ALPHA = water_shore_alpha(v_shore_xz);",
		"}",
	])
	return sh


func _apply_shore(p_mat: ShaderMaterial, p_sdf: Dictionary, p_spacing: float) -> void:
	p_mat.set_shader_parameter("_shore_sdf", p_sdf["texture"])
	p_mat.set_shader_parameter("_shore_rect", p_sdf["rect"])
	p_mat.set_shader_parameter("_shore_texels", Vector2(p_sdf["texels"], p_sdf["texels"]))
	p_mat.set_shader_parameter("_shore_range", p_sdf["range"])
	p_mat.set_shader_parameter("_shore_feather", FEATHER)
	p_mat.set_shader_parameter("_shore_offset", 0.0)
	p_mat.set_shader_parameter("_shore_kill_margin", p_spacing * 1.5 + FEATHER)


func _save(p_img: Image, p_name: String) -> void:
	var path := _out_dir + p_name
	if p_img.save_png(path) != OK or not FileAccess.file_exists(path):
		_fail += 1
		print("    !! save %s failed" % path)
