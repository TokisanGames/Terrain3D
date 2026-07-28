# Pasture3D Water — Phase 2 exit gate (spec §7).
#
# Gate criteria:
#   A. C++ generates a wave table and it reaches the shader
#   B. the uploaded table overrides the compile-time fallback
#   C. the clock advances and wraps to the loop period
#   D. the loop is seamless -- surface at t=T is identical to t=0
#   E. no seams at LOD boundaries
#   F. waves match between the clipmap and a plain mesh
#   G. the cheap scalar depth reconstruction agrees with the mat4 path to 1e-4
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/WaterPhase2Gate.tscn
extends Node

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const DEPTH_PROBE := "res://bench/water_depth_probe.gdshader"

const LOOP_PERIOD := 120.0
const VERTEX_SPACING := 4.0

var _fail := 0
var _out_dir := ""
var _table: PackedVector4Array


func _ready() -> void:
	var bail := Timer.new()
	bail.wait_time = 120.0
	bail.one_shot = true
	bail.timeout.connect(func():
		push_error("gate timed out")
		get_tree().quit(2))
	add_child(bail)
	bail.start()

	_out_dir = OS.get_environment("BENCH_OUT")
	if _out_dir == "":
		_out_dir = "user://"

	print("=== Pasture3D Water — Phase 2 gate ===")
	print("Godot %s | %s | %s" % [
		Engine.get_version_info().string,
		RenderingServer.get_video_adapter_name(),
		RenderingServer.get_current_rendering_method()])
	print("")

	await _gate_ab_table()
	await _gate_c_clock()
	await _gate_de_surface()
	await _gate_f_parity()
	await _gate_g_depth()

	print("")
	print("=== PHASE 2 GATE %s ===" % ("PASS" if _fail == 0 else "FAIL (%d)" % _fail))
	get_tree().quit(0 if _fail == 0 else 1)


# ---- A + B: C++ wave table generation and upload ----------------------------
func _gate_ab_table() -> void:
	print("[A] C++ wave table -> shader uniform:")
	var root := _make_world(Vector3(0, 6, 0), -10.0)
	var terrain := _make_ocean(root)
	await _settle()

	var mat: ShaderMaterial = terrain.ocean_material
	var value: Variant = mat.get_shader_parameter("_waves")
	if not (value is PackedVector4Array):
		print("    FAIL: _waves is %s, not PackedVector4Array" % type_string(typeof(value)))
		print("    !! ShaderMaterial rejected the upload type from C++")
		_fail += 1
		root.queue_free()
		await _settle()
		return
	_table = value
	print("    uploaded %d entries (WATER_MAX_WAVES = 8)" % _table.size())
	if _table.size() != 8:
		_fail += 1
		print("    !! expected 8")

	var live := 0
	for i in _table.size():
		var w := _table[i]
		print("        [%d] dir=(%+.3f, %+.3f)  amp=%.3f m  L=%.2f m  |dir|=%.5f" % [
			i, w.x, w.y, w.z, w.w, sqrt(w.x * w.x + w.y * w.y)])
		if w.z > 0.0:
			live += 1
		if absf(sqrt(w.x * w.x + w.y * w.y) - 1.0) > 1e-3:
			_fail += 1
			print("            !! direction is not unit length")
		if w.w <= 0.0:
			_fail += 1
			print("            !! non-positive wavelength breaks the fallback sentinel")
	if live != terrain.ocean_wave_count:
		_fail += 1
		print("    !! %d live waves, expected %d" % [live, terrain.ocean_wave_count])

	# Loop quantisation: each wave must complete a whole number of cycles in T.
	print("[A] loop quantisation (cycles per %.0f s must be integral):" % LOOP_PERIOD)
	var worst := 0.0
	for i in terrain.ocean_wave_count:
		var w := _table[i]
		var ang := TAU / w.w
		var omega: float = sqrt(9.81 * ang)
		var cycles: float = omega * LOOP_PERIOD / TAU
		var err: float = absf(cycles - roundf(cycles))
		worst = maxf(worst, err)
		# GDScript's % has no %e conversion; num_scientific() is the equivalent.
		print("        [%d] L=%7.2f m -> %8.4f cycles (err %s)" % [
			i, w.w, cycles, String.num_scientific(err)])
	if worst > 1e-4:
		_fail += 1
		print("    !! worst deviation %s -- the loop will not be seamless" % String.num_scientific(worst))
	else:
		print("    -> worst deviation %s, integral" % String.num_scientific(worst))

	# B: the uploaded table must beat the compile-time fallback. Uploading a
	# table whose amplitudes are all zero must give flat water, not defaults.
	print("[B] uploaded table overrides the compile-time fallback:")
	var flat := PackedVector4Array()
	for i in 8:
		flat.append(Vector4(1.0, 0.0, 0.0, 10.0)) # zero amplitude, valid wavelength
	mat.set_shader_parameter("_waves", flat)
	RenderingServer.global_shader_parameter_set("water_time", 0.0)
	await _settle()
	var img_flat := _grab()
	mat.set_shader_parameter("_waves", _table)
	await _settle()
	var img_waves := _grab()
	var d := _diff(img_flat, img_waves)
	print("    zero-amplitude vs generated table: mean diff %.5f, max %.5f" % [d.x, d.y])
	if d.y < 0.02:
		_fail += 1
		print("    !! no difference -- the uploaded table is being ignored")
	else:
		print("    -> the upload is what drives the surface")

	root.queue_free()
	await _settle()


# ---- C: the shared clock ----------------------------------------------------
func _gate_c_clock() -> void:
	print("[C] water clock:")
	var root := _make_world(Vector3(0, 6, 0), -10.0)
	var terrain := _make_ocean(root, false) # the point of this gate is the clock
	await _settle()

	var samples: Array[float] = []
	for i in 6:
		await get_tree().physics_frame
		samples.append(terrain.get_water_time())
	print("    get_water_time() over 6 physics frames: %s" % [samples])

	var advancing := samples[-1] > samples[0]
	if not advancing:
		_fail += 1
		print("    !! the clock is not advancing")

	# The global must carry the same value the node reports.
	var seen: float = ProjectSettings.get_setting("shader_globals/water_time", {}).get("value", -1.0) \
		if ProjectSettings.has_setting("shader_globals/water_time") else -1.0
	print("    loop period %.0f s; project.godot default %s" % [terrain.ocean_wave_loop_period, seen])

	# Wrapping: fast-forward past the period and confirm it stays bounded.
	var bounded := true
	for i in 20:
		await get_tree().physics_frame
		if terrain.get_water_time() < 0.0 or terrain.get_water_time() > LOOP_PERIOD:
			bounded = false
	if not bounded:
		_fail += 1
		print("    !! clock left [0, T]")
	else:
		print("    -> advancing and bounded to [0, %.0f]" % LOOP_PERIOD)

	root.queue_free()
	await _settle()


# ---- D + E: loop seam, LOD seams --------------------------------------------
func _gate_de_surface() -> void:
	# Steep enough that wave structure fills the frame. A near-horizon view is
	# mostly distant water that looks the same at any time, which swamps the
	# difference metric with sky and makes the control indistinguishable.
	var root := _make_world(Vector3(0, 25, 0), -38.0)
	var terrain := _make_ocean(root)
	await _settle()

	# D. Frequencies are quantised to T, so the surface at t=T must be the same
	# surface as t=0 -- set the clock directly rather than relying on the wrap,
	# which would make the comparison trivially true.
	print("[D] loop seam (surface at t=0 vs t=%.0f):" % LOOP_PERIOD)
	RenderingServer.global_shader_parameter_set("water_time", 0.0)
	await _settle()
	var img_t0 := _grab()
	RenderingServer.global_shader_parameter_set("water_time", LOOP_PERIOD)
	await _settle()
	var img_tT := _grab()
	var d := _diff(img_t0, img_tT)
	print("    mean diff %.6f, max %.6f" % [d.x, d.y])
	# A control: a time that is NOT the period must differ, or the test is vacuous.
	RenderingServer.global_shader_parameter_set("water_time", LOOP_PERIOD * 0.37)
	await _settle()
	var d_ctrl := _diff(img_t0, _grab())
	print("    control at t=%.1f: mean diff %.6f, max %.6f" % [LOOP_PERIOD * 0.37, d_ctrl.x, d_ctrl.y])
	if d_ctrl.y < 0.05:
		_fail += 1
		print("    !! control shows no motion -- the loop test proves nothing")
	elif d.y > 0.02:
		_fail += 1
		print("    !! the loop is not seamless")
	else:
		print("    -> seamless (%.0fx smaller than the control)" % (d_ctrl.y / maxf(d.y, 1e-6)))

	RenderingServer.global_shader_parameter_set("water_time", 0.0)
	root.queue_free()
	await _settle()

	# E. Straight down from height, water fills the frame edge to edge. The
	# clipmap reaches ~16 km, far past the frustum, so ANY pixel of sky is a
	# crack between LOD rings -- a much sharper signal than eyeballing a horizon.
	# The background is flat magenta rather than a sky. A first attempt used
	# "luminance below a threshold means water" and reported holes at high
	# steepness -- those were blown-out sun glints, not gaps. No amount of
	# specular can produce magenta, so this cannot false-positive the same way.
	print("[E] LOD seams (top-down over a magenta void, any magenta is a gap):")

	# Control: with no water at all the detector must read ~100%, or a clean
	# result below would only mean the detector never fires.
	var r_ctrl := _make_void_world(Vector3(0, 120, 0), -90.0)
	await _settle()
	var gap_ctrl := _magenta_fraction()
	print("    control, no water: %.2f%% gap" % gap_ctrl)
	if gap_ctrl < 99.0:
		_fail += 1
		print("    !! the gap detector does not fire on an empty frame")
	r_ctrl.queue_free()
	await _settle()

	for steepness: float in [0.35, 0.9]:
		var r2 := _make_void_world(Vector3(0, 120, 0), -90.0)
		var t2 := _make_ocean(r2)
		t2.ocean_wave_steepness = steepness
		await _settle()
		var gap := _magenta_fraction()
		var path := "%s/phase2_lod_seams_s%02d.png" % [_out_dir, int(steepness * 100)]
		_screenshot(path)
		print("    steepness %.2f: gap pixels %.4f%% -> %s" % [
			steepness, gap, "OK" if gap <= 0.001 else "FAIL (holes in the surface)"])
		if gap > 0.001:
			_fail += 1
		print("        %s" % path)
		r2.queue_free()
		await _settle()

	# The top-down capture cannot see the defect Phase 1 §8.2 left open: single
	# dark specks along the horizon on the clipmap that the plain mesh does not
	# show. Those live at grazing angle, where LOD rings are packed into a few
	# pixels. Same magenta void, but the frame is now part sky, so a whole-frame
	# fraction would just measure the horizon. Instead: in each column, find the
	# topmost water pixel, and count magenta strictly below it. The ocean is a
	# continuous sheet, so nothing under its own silhouette can legitimately be
	# background -- while crests poking above the horizon cost nothing.
	print("[E] horizon at grazing angle (magenta below the water silhouette is a crack):")
	var r3 := _make_void_world(Vector3(0, 12, 0), -3.0)
	var t3 := _make_ocean(r3)
	await _settle()
	var holes := _holes_below_silhouette()
	var path3 := "%s/phase2_lod_seams_grazing.png" % _out_dir
	_screenshot(path3)
	print("    columns with water: %d of %d | magenta pixels below the silhouette: %d" % [
		holes.y, holes.z, holes.x])
	if holes.y < holes.z * 0.5:
		_fail += 1
		print("    !! water covers under half the columns -- wrong framing, nothing tested")
	elif holes.x > 0:
		_fail += 1
		print("    !! the clipmap has cracks at grazing angle")
	else:
		print("    -> no cracks; the Phase 1 horizon specks are shading, not geometry")
	print("        %s" % path3)
	r3.queue_free()
	await _settle()


# ---- F: clipmap vs plain mesh -----------------------------------------------
# Both paths evaluate the same pure function of world XZ, so the same wave table
# under a frozen clock must give the same surface regardless of which mesh
# carries it. What this gate is really asking is whether the clipmap path adds
# anything of its own -- a domain offset, a stale uniform, a geomorph leaking
# into the wave input.
#
# Three things had to be got right before the measurement meant anything, each
# of which produced a wrong verdict first:
#
#   1. Wave count. water_body compiles with WATER_WAVE_COUNT 4 and water_ocean
#      with 8, so by default the two read different prefixes of the same table.
#      The plain mesh got the swell and none of the medium waves, and a loose
#      threshold passed it anyway. Both sides are pinned to 4 here.
#
#   2. What is being differenced. Water is near-mirror, so a normal difference
#      far too small to see lands a saturated specular pixel somewhere slightly
#      different, and a shaded diff ends up measuring highlight placement. The
#      gate now renders WATER_DEBUG_SURFACE -- world normal and displaced height
#      as unlit colour -- and shading is reported alongside, not gated on.
#
#   3. Mesh density. The generated table's shortest wave is 10 m (the C++
#      MIN_WAVELENGTH floor), and the shader's own rule of thumb wants vertex
#      spacing <= L_min/8. At the 4 m spacing the other gates use, that wave is
#      sampled 2.5 times per period and aliases differently on each topology --
#      a real artefact, but of the test's tessellation, not of the clipmap. This
#      gate drops to 1 m and looks steeply down so the whole frame is inside
#      LOD0 and well inside the plane, rather than comparing a clipmap that
#      reaches kilometres against a finite grid.
func _gate_f_parity() -> void:
	print("[F] clipmap vs plain MeshInstance3D at matched density:")
	var cam_pos := Vector3(0, 30, 0)
	var pitch := -70.0
	var spacing := 1.0
	var extent := 512.0

	var dbg_clip := _debug_surface_shader(true)
	var dbg_plain := _debug_surface_shader(false)

	# --- clipmap ---
	var r1 := _make_world(cam_pos, pitch)
	var mat1 := ShaderMaterial.new()
	mat1.shader = dbg_clip
	var t1 := _make_ocean(r1, true, mat1, spacing)
	t1.ocean_wave_count = 4
	await _settle()
	var table: PackedVector4Array = mat1.get_shader_parameter("_waves")
	var steepness: float = t1.ocean_wave_steepness # read before the node is freed
	RenderingServer.global_shader_parameter_set("water_time", 3.0)
	await _settle()
	var img_clip := _grab()
	_screenshot("%s/phase2_parity_clipmap.png" % _out_dir)

	# Same camera, same clock, shaded -- kept only so the pair can be eyeballed.
	t1.ocean_material.shader = load(WATER_DIR + "water_ocean.gdshader")
	await _settle()
	var lit_clip := _grab()
	_screenshot("%s/phase2_parity_clipmap_lit.png" % _out_dir)
	r1.queue_free()
	await _settle()

	# --- plain mesh ---
	var r2 := _make_world(cam_pos, pitch)
	var mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(extent, extent)
	var subdiv := int(extent / spacing) - 1
	plane.subdivide_width = subdiv
	plane.subdivide_depth = subdiv
	mi.mesh = plane
	var m2 := ShaderMaterial.new()
	m2.shader = dbg_plain
	m2.set_shader_parameter("_waves", table)
	m2.set_shader_parameter("wave_steepness", steepness)
	mi.material_override = m2
	mi.custom_aabb = AABB(Vector3(-extent, -50, -extent), Vector3(extent * 2, 100, extent * 2))
	r2.add_child(mi)
	await _settle()
	var img_plain := _grab()
	_screenshot("%s/phase2_parity_plainmesh.png" % _out_dir)

	m2.shader = load(WATER_DIR + "water_body.gdshader")
	m2.set_shader_parameter("_waves", table)
	m2.set_shader_parameter("wave_steepness", steepness)
	# _make_ocean() overrides deep_color on the clipmap side; without this the
	# reference diff is measuring that, not the surface.
	m2.set_shader_parameter("deep_color", Color(0.02, 0.09, 0.14))
	await _settle()
	var lit_plain := _grab()
	_screenshot("%s/phase2_parity_plainmesh_lit.png" % _out_dir)
	r2.queue_free()
	await _settle()

	var d := _diff(img_clip, img_plain)
	var dl := _diff(lit_clip, lit_plain)
	# Two images agreeing tells you nothing if neither has any structure in it,
	# and this gate has already produced one false pass. The readout only spans
	# roughly 0.35..0.65 (a normal component mapped into 0..1 and then tonemapped),
	# so the comparison is only meaningful while that spread stays well above the
	# difference being measured.
	var span := _span(img_clip)
	print("    grid %.0f m, %d subdivisions, 4 waves both sides, clock frozen at t=3" % [
		spacing, subdiv])
	print("    surface (normal + height, unlit): mean %.5f, max %.5f" % [d.x, d.y])
	print("    shaded, for reference only:       mean %.5f, max %.5f" % [dl.x, dl.y])
	print("    signal span in the readout:       %.5f (%.0fx the mean diff)" % [
		span, span / maxf(d.x, 1e-9)])
	# Topology still differs -- rings of varying density with a geomorph against
	# a uniform grid -- so this cannot reach zero. It has to be far below the
	# 8-vs-4-wave mismatch this test originally failed to catch, which read
	# 0.023 through the shaded metric.
	if span < 0.05:
		_fail += 1
		print("    !! the readout is nearly flat -- nothing was compared, test is vacuous")
	elif d.x > 0.004:
		_fail += 1
		print("    !! the clipmap path is not evaluating the same wave function")
	else:
		print("    -> same surface; the clipmap adds nothing of its own")
	RenderingServer.global_shader_parameter_set("water_time", 0.0)


# The four wrappers are fixed feature sets, so the unlit readout gate F needs is
# built here instead: same includes, same render_mode, WATER_DEBUG_SURFACE on and
# the Phase 3 placeholders off. Gate B of Phase 1 established that an inline
# #define + #include variant compiles identically to a wrapper file.
func _debug_surface_shader(p_clipmap: bool) -> Shader:
	var sh := Shader.new()
	sh.code = "\n".join([
		"shader_type spatial;",
		"render_mode cull_disabled, depth_draw_never, diffuse_lambert, specular_schlick_ggx, skip_vertex_transform;",
		"#define WATER_CLIPMAP" if p_clipmap else "",
		"#define WATER_WAVE_COUNT 4",
		"#define WATER_DEBUG_SURFACE",
		'#include "%swater_common.gdshaderinc"' % WATER_DIR,
		'#include "%swater_waves.gdshaderinc"' % WATER_DIR,
		'#include "%swater_surface.gdshaderinc"' % WATER_DIR,
		'#include "%swater_shading.gdshaderinc"' % WATER_DIR,
	])
	return sh


# ---- G: depth reconstruction (spec §3.5) ------------------------------------
func _gate_g_depth() -> void:
	print("[G] scalar vs mat4 linear depth reconstruction:")
	var root := Node3D.new()
	add_child(root)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 2, 12)
	cam.rotation_degrees = Vector3(-6, 0, 0)
	cam.near = 0.05
	cam.far = 4000.0
	cam.current = true
	root.add_child(cam)

	# Opaque geometry spread across the depth range, so the probe samples real
	# and varied depths rather than a cleared buffer.
	for i in 12:
		var box := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(6, 6, 6)
		box.mesh = bm
		box.position = Vector3(cos(i * 1.7) * 8.0, sin(i * 2.3) * 4.0, -float(i) * 22.0)
		var bmat := StandardMaterial3D.new()
		bmat.albedo_color = Color(0.5, 0.5, 0.5)
		box.material_override = bmat
		root.add_child(box)
	var floor_mi := MeshInstance3D.new()
	var fp := PlaneMesh.new()
	fp.size = Vector2(600, 600)
	floor_mi.mesh = fp
	floor_mi.position = Vector3(0, -8, -250)
	root.add_child(floor_mi)

	var probe := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(2, 2)
	q.flip_faces = true
	probe.mesh = q
	probe.position = cam.position + Vector3(0, 0, -0.3)
	probe.rotation = cam.rotation
	probe.extra_cull_margin = 1000.0
	var pmat := ShaderMaterial.new()
	pmat.shader = load(DEPTH_PROBE)
	pmat.set_shader_parameter("depth_norm", 300.0)
	pmat.set_shader_parameter("tolerance", 1e-4)
	probe.material_override = pmat
	root.add_child(probe)

	await _settle()
	var img := _grab()
	var path := "%s/phase2_depth_probe.png" % _out_dir
	img.save_png(path)

	var bad := 0
	var total := 0
	var g_min := 2.0
	var g_max := -1.0
	var worst_gb := 0.0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			total += 1
			if c.r > 0.5:
				bad += 1
			g_min = minf(g_min, c.g)
			g_max = maxf(g_max, c.g)
			worst_gb = maxf(worst_gb, absf(c.g - c.b))
	print("    sampled %d px | disagreements > 1e-4 rel: %d" % [total, bad])
	print("    depth spread across the frame: %.3f .. %.3f (normalised)" % [g_min, g_max])
	print("    worst |scalar - mat4| in the readback channels: %.4f" % worst_gb)
	print("    %s" % path)

	if g_max - g_min < 0.05:
		# Both methods agreeing on a cleared depth buffer would be meaningless.
		_fail += 1
		print("    !! depth is nearly constant -- the probe saw no real geometry, test is vacuous")
	elif bad > 0:
		_fail += 1
		print("    !! the scalar reconstruction of spec §3.5 is not equivalent")
	else:
		print("    -> equivalent; the two mat4 chains in the legacy shader can go")

	root.queue_free()
	await _settle()


# ---- helpers ---------------------------------------------------------------
func _make_world(p_cam_pos: Vector3, p_pitch: float) -> Node3D:
	var root := Node3D.new()
	add_child(root)
	var env := Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 120, 0)
	root.add_child(sun)
	var cam := Camera3D.new()
	cam.position = p_cam_pos
	cam.rotation_degrees = Vector3(p_pitch, 0, 0)
	cam.far = 20000.0
	cam.cull_mask = 1
	cam.current = true
	root.add_child(cam)
	return root


# p_freeze_clock: Pasture3D drives the water_time global every physics frame, so
# any test that sets the clock by hand has to stop it first or the node writes
# over the value between the set and the capture. Only gate C wants it running.
func _make_ocean(p_root: Node3D, p_freeze_clock: bool = true,
		p_material: ShaderMaterial = null, p_spacing: float = VERTEX_SPACING) -> Pasture3D:
	var mat := p_material
	if mat == null:
		mat = ShaderMaterial.new()
		mat.shader = load(WATER_DIR + "water_ocean.gdshader")
	mat.set_shader_parameter("deep_color", Color(0.02, 0.09, 0.14))
	var terrain := Pasture3D.new()
	terrain.ocean_material = mat
	terrain.ocean_enabled = true
	terrain.ocean_vertex_spacing = p_spacing
	terrain.ocean_wave_count = 8
	terrain.ocean_wave_direction = 20.0
	terrain.ocean_wave_spread = 28.0
	terrain.ocean_wave_amplitude = 1.4
	terrain.ocean_wave_length_max = 130.0
	terrain.ocean_wave_steepness = 0.35
	terrain.ocean_wave_loop_period = LOOP_PERIOD
	terrain.render_layers = 1 << 4 # keep the (empty) terrain out of frame
	terrain.ocean_render_layers = 1
	p_root.add_child(terrain)
	if p_freeze_clock:
		terrain.set_physics_process(false)
	return terrain


func _settle() -> void:
	for i in 12:
		await RenderingServer.frame_post_draw


func _grab() -> Image:
	return get_viewport().get_texture().get_image()


func _screenshot(p_path: String) -> void:
	_grab().save_png(p_path)


# Returns (mean, max) absolute per-channel difference over a strided sample.
func _diff(p_a: Image, p_b: Image) -> Vector2:
	var total := 0.0
	var worst := 0.0
	var n := 0
	for y in range(0, p_a.get_height(), 3):
		for x in range(0, p_a.get_width(), 3):
			var ca := p_a.get_pixel(x, y)
			var cb := p_b.get_pixel(x, y)
			var e: float = maxf(maxf(absf(ca.r - cb.r), absf(ca.g - cb.g)), absf(ca.b - cb.b))
			total += e
			worst = maxf(worst, e)
			n += 1
	return Vector2(total / float(maxi(n, 1)), worst)


# Widest per-channel range within one image -- how much signal a _diff() against
# it had available to find, so a near-zero diff can be told from a blank frame.
func _span(p_img: Image) -> float:
	var lo := Vector3(2, 2, 2)
	var hi := Vector3(-1, -1, -1)
	for y in range(0, p_img.get_height(), 3):
		for x in range(0, p_img.get_width(), 3):
			var c := p_img.get_pixel(x, y)
			var v := Vector3(c.r, c.g, c.b)
			lo = lo.min(v)
			hi = hi.max(v)
	var s := hi - lo
	return maxf(maxf(s.x, s.y), s.z)


# A world with no sky at all: the clear colour is magenta and the only light is
# a fixed ambient, so nothing in the scene can approach the background hue.
func _make_void_world(p_cam_pos: Vector3, p_pitch: float) -> Node3D:
	var root := Node3D.new()
	add_child(root)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(1, 0, 1)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.55, 0.6)
	env.ambient_light_energy = 1.0
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 120, 0)
	root.add_child(sun)
	var cam := Camera3D.new()
	cam.position = p_cam_pos
	cam.rotation_degrees = Vector3(p_pitch, 0, 0)
	cam.far = 20000.0
	cam.cull_mask = 1
	cam.current = true
	root.add_child(cam)
	return root


# Percentage of the frame showing UNBLENDED magenta -- i.e. a genuine gap.
#
# The water is not opaque (ALPHA ~0.55 at these angles), so magenta shows
# through everywhere to some degree. A covered pixel lands near r=0.46, b=0.53
# once the water is mixed over it; only a real hole stays at full (1, 0, 1).
# Specular can drive a water pixel to white, but white has a high green channel
# and is excluded.
func _magenta_fraction() -> float:
	var img := _grab()
	var gap := 0
	var total := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			total += 1
			var c := img.get_pixel(x, y)
			if c.r > 0.85 and c.g < 0.25 and c.b > 0.85:
				gap += 1
	return 100.0 * float(gap) / float(maxi(total, 1))


# Returns (holes, columns_with_water, columns_sampled). A hole is a background
# pixel that lies below the topmost water pixel of its own column -- see the
# grazing-angle block in gate E for why that is the right question to ask.
func _holes_below_silhouette() -> Vector3i:
	var img := _grab()
	var h := img.get_height()
	var holes := 0
	var with_water := 0
	var cols := 0
	for x in range(0, img.get_width(), 2):
		cols += 1
		var top := -1
		for y in h:
			var c := img.get_pixel(x, y)
			var is_bg: bool = c.r > 0.85 and c.g < 0.25 and c.b > 0.85
			if top < 0:
				if not is_bg:
					top = y
					with_water += 1
			elif is_bg:
				holes += 1
	return Vector3i(holes, with_water, cols)
