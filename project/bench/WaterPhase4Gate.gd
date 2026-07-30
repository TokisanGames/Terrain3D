# Pasture3D Water — Phase 4 exit gate (spec §7).
#
# Spec's stated exit gate is "G4 met; unit test green". The unit test is the C++
# suite (PASTURE3D_UNIT_TESTS=water via bench/UnitTestRunner.tscn) and covers the
# CPU evaluator against itself. It cannot reach the GPU, which is the half of G4
# that matters: "get_water_height(xz) agrees with the GPU surface to within 1 cm
# at any world position, at any time". That is criterion B here.
#
# Gate criteria:
#   A. the CPU clock and the shader's clock are the same number
#   B. G4 -- the GPU surface and the CPU query agree to within 1 cm
#   C. how far the drawn mesh sits from the analytic surface (reported, not graded)
#   D. §4.4 -- the ocean's shadow setting is the ocean's, not the terrain's
#   E. §4.5 -- the cull volume follows sea level
#
# Every criterion carries a control that must fail; see the header on each.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/WaterPhase4Gate.tscn
extends Node

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const PROBE_SHADER := "res://bench/water_parity_probe.gdshader"

const LOOP_PERIOD := 120.0
# Must match PROBE_MAX in water_parity_probe.gdshader.
const PROBES := 64
const CELL_PX := 8

# G4's budget, and the threshold the probe shader's red channel encodes.
const G4_METRES := 0.01

var _fail := 0
var _out_dir := ""
var _probe_vp: SubViewport
var _probe_mat: ShaderMaterial
var _last_clock_cell := Color.BLACK
# Mirrors Pasture3D.ocean_domain_origin for the probe, which cannot read it off the
# material any more. See _run_probe.
var _domain_origin := Vector3.ZERO


func _ready() -> void:
	var bail := Timer.new()
	bail.wait_time = 600.0
	bail.one_shot = true
	bail.timeout.connect(func():
		push_error("gate timed out")
		get_tree().quit(2))
	add_child(bail)
	bail.start()

	_out_dir = OS.get_environment("BENCH_OUT")
	if _out_dir == "":
		_out_dir = "user://"

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	DisplayServer.window_set_size(Vector2i(1280, 800))

	print("=== Pasture3D Water — Phase 4 gate ===")
	print("Godot %s | %s | %s" % [
		Engine.get_version_info().string,
		RenderingServer.get_video_adapter_name(),
		RenderingServer.get_current_rendering_method()])
	print("")

	_make_probe_viewport()

	await _gate_a_clock()
	await _gate_b_parity()
	_gate_c_tessellation()
	await _gate_d_shadows()
	await _gate_e_cull()

	print("")
	print("=== PHASE 4 GATE %s ===" % ("PASS" if _fail == 0 else "FAIL (%d)" % _fail))
	get_tree().quit(0 if _fail == 0 else 1)


# ---- A: one clock ------------------------------------------------------------
# get_water_height() reads _water_time; the shader reads the water_time global;
# C++ writes the second from the first once per physics frame. If they ever drift
# apart, B fails everywhere for a reason that has nothing to do with the wave
# arithmetic, so it is worth separating.
#
# Asked of the SHADER, in the shader, because there is no runtime read of a global
# shader parameter -- global_shader_parameter_get() is editor-only. That is the
# better question in any case: what the global table holds is not evidence about
# what reached the draw.
#
# Two controls. The clock must be nonzero, or every parity check below is two
# evaluations of t = 0 and proves nothing. And the same comparison is run again
# against a deliberately wrong CPU time, which must light red -- otherwise a dark
# cell is indistinguishable from a probe that never ran.
func _gate_a_clock() -> void:
	print("[A] the CPU clock and the shader clock are the same number:")
	var root := _make_world(Vector3(0, 30, 0), -40.0)
	var terrain := _make_ocean(root)
	await _settle_physics(4)

	# Let the clock run, then stop it, so the comparison is against a value that
	# actually advanced rather than against two zeroes.
	await _settle_physics(20)
	terrain.set_physics_process(false)
	await _settle()

	var t_cpu: float = terrain.get_water_time()
	var mat: ShaderMaterial = terrain.ocean_material
	var cell := await _probe_clock(mat, t_cpu)
	print("    CPU get_water_time() %.9f" % t_cpu)
	print("    shader water_time differs by more than 1e-5 s: %s | 1e-7 s: %s | is zero: %s" % [
		str(cell.r > 0.5), str(cell.g > 0.5), str(cell.b > 0.5)])

	if t_cpu <= 0.0 or cell.b > 0.5:
		_fail += 1
		print("    !! the clock never advanced, so A and B are both vacuous")
	elif cell.r > 0.5:
		_fail += 1
		print("    !! the shader is a millisecond or more away from the CPU query; the")
		print("       two evaluators are not being asked about the same instant")
	else:
		print("    -> inside 1e-5 s, against 1.7e-2 s for one 60 Hz frame of desync")

	# The control: the same cell, told a time one physics frame away. It has to
	# light, or the reading above is a probe that is not looking at anything.
	var control := await _probe_clock(mat, t_cpu + 1.0 / 60.0)
	print("    CONTROL, CPU time offset by one 60 Hz frame: red %s (must be true)" % str(
		control.r > 0.5))
	if control.r <= 0.5:
		_fail += 1
		print("    !! the clock cell does not react to a frame of drift; A is vacuous")

	# The clock must also STOP when physics does, or nothing below can be captured
	# at a known instant.
	await _settle_physics(10)
	if absf(terrain.get_water_time() - t_cpu) > 0.0:
		_fail += 1
		print("    !! the clock advances with physics disabled; nothing here can be")
		print("       captured at a known instant")

	root.queue_free()
	await _settle()


# The clock cell alone, with no surface probes.
func _probe_clock(p_ocean: ShaderMaterial, p_cpu_time: float) -> Color:
	await _run_probe(p_ocean, PackedVector2Array(), PackedVector4Array(), 0.0, p_cpu_time)
	return _last_clock_cell


# ---- B: G4 --------------------------------------------------------------------
# The chain G4 actually claims has two links, and both are checked here:
#
#   1. get_water_height(world_xz) -> the height of the surface point that LANDS on
#      world_xz. That is the Gerstner inverse, and it is checked as a round trip:
#      take a domain parameter u, ask the CPU where it goes, then ask
#      get_water_height() about the XZ it went to and require the same height back.
#      Numeric and CPU-only, so it prints real metres.
#
#   2. that surface point is the one the GPU draws. Checked by evaluating the real
#      water_eval_waves() -- same include, same wave count, same uploaded table --
#      and thresholding the difference on the GPU, where it is still float. See
#      the header of water_parity_probe.gdshader for why the readback is binary.
#
# Both links are run at several frozen instants, and again with a domain origin
# 12 km out and a sea level of 300 m, because those are the two things §3.1 and
# §4.1 add on top of the wave sum and either could be added on one side only.
#
# The control is a CPU array offset by 5 cm: the probe must light red for every
# probe. Without it "all black" is indistinguishable from a probe shader that
# never ran, and black is what a pass looks like.
func _gate_b_parity() -> void:
	print("[B] G4 -- the CPU query and the GPU surface are the same surface:")
	var root := _make_world(Vector3(0, 30, 0), -40.0)
	var terrain := _make_ocean(root)
	var mat: ShaderMaterial = terrain.ocean_material
	await _settle_physics(4)

	var cases := [
		["origin 0, sea level 0", Vector3.ZERO, 0.0],
		["origin 12 km, sea level 300", Vector3(12000.0, 0.0, -8000.0), 300.0],
	]
	var worst_roundtrip := 0.0
	var probed := 0

	for case in cases:
		# The domain origin lives on the NODE since Phase 1 of the water-bodies work
		# (WATER_BODIES_SPEC §5.4): _water_domain_origin became an `instance uniform`
		# so one shared material can serve bodies in different places, and
		# material.set_shader_parameter() no longer reaches it. Setting it the old way
		# here would leave the CPU query on origin 0 while the probe was told 12 km,
		# and this gate would fail for a reason that is not about parity at all.
		terrain.ocean_domain_origin = case[1]
		_domain_origin = case[1]
		mat.set_shader_parameter("sea_level", case[2])
		# Physics frames, so C++ re-reads the uniforms it polls.
		await _settle_physics(4)

		for instant in 3:
			await _settle_physics(11)
			terrain.set_physics_process(false)
			await _settle()

			var domains := _probe_domains(instant)
			var cpu := PackedVector4Array()
			for d in domains:
				var p: Vector3 = terrain.get_water_surface_point(d)
				cpu.append(Vector4(p.x, p.y, p.z, 0.0))
				# Link 1, numeric: the inverse solve has to undo the displacement.
				var h: float = terrain.get_water_height(Vector2(p.x, p.z))
				worst_roundtrip = maxf(worst_roundtrip, absf(h - p.y))

			var lit := await _run_probe(mat, domains, cpu, case[2],
					terrain.get_water_time())
			probed += domains.size()
			print("    %-28s t=%7.3f  R(1cm) %d  G(1mm) %d  B(xz 1cm) %d  of %d" % [
				case[0], terrain.get_water_time(), lit.x, lit.y, lit.z, domains.size()])
			if lit.x > 0:
				_fail += 1
				print("      !! %d probes miss G4 by more than 1 cm of height" % lit.x)
			if lit.z > 0:
				_fail += 1
				print("      !! %d probes land more than 1 cm away horizontally; the CPU" % lit.z)
				print("         is describing a different surface, not just a different height")

			terrain.set_physics_process(true)

	print("    inverse-solve round trip, worst over %d probes: %.6f m" % [
		probed, worst_roundtrip])
	if worst_roundtrip > G4_METRES:
		_fail += 1
		print("    !! get_water_height() does not return the height of the point it")
		print("       was asked about; link 1 of G4 is broken on the CPU alone")

	# The control. Same probes, same everything, CPU heights moved 5 cm.
	terrain.set_physics_process(false)
	await _settle()
	var domains := _probe_domains(0)
	var bad := PackedVector4Array()
	for d in domains:
		var p: Vector3 = terrain.get_water_surface_point(d)
		bad.append(Vector4(p.x, p.y + 0.05, p.z, 0.0))
	var control := await _run_probe(mat, domains, bad,
			mat.get_shader_parameter("sea_level"), terrain.get_water_time())
	print("    CONTROL, CPU heights offset by 5 cm: R %d of %d (must be all)" % [
		control.x, domains.size()])
	if control.x != domains.size():
		_fail += 1
		print("    !! the probe does not detect a 5 cm error, so a black readback")
		print("       above proves nothing -- B is vacuous")
	else:
		print("    -> the probe is live, and the surfaces agree inside 1 cm")

	root.queue_free()
	await _settle()


# 64 domain-space XZ points, deliberately unaligned with anything: not on the
# vertex grid, not on a wave crest, and spread over three decades of distance so
# the float precision story from §3.1 is exercised and not just the near field.
func _probe_domains(p_seed: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260728 + p_seed
	for i in PROBES:
		# Log-spaced radius from 1 m to 20 km, arbitrary bearing.
		var r: float = pow(10.0, rng.randf_range(0.0, 4.3))
		var a: float = rng.randf_range(0.0, TAU)
		out.append(Vector2(cos(a) * r, sin(a) * r))
	return out


# Renders one probe pass and returns the count of lit pixels per channel. The
# clock cell, which is one cell past the last probe, lands in _last_clock_cell.
func _run_probe(p_ocean: ShaderMaterial, p_domains: PackedVector2Array,
		p_cpu: PackedVector4Array, p_base_y: float, p_cpu_time: float) -> Vector3i:
	var packed := PackedVector4Array()
	for d in p_domains:
		packed.append(Vector4(d.x, d.y, 0.0, 0.0))

	# Read the wave state off the OCEAN material rather than rebuilding it, so the
	# probe cannot pass by being configured differently from the water on screen.
	_probe_mat.set_shader_parameter("_waves", p_ocean.get_shader_parameter("_waves"))
	_probe_mat.set_shader_parameter("wave_steepness",
			p_ocean.get_shader_parameter("wave_steepness"))
	# The probe declares this as a plain uniform (WATER_PLAIN_DOMAIN_ORIGIN -- a
	# canvas_item shader cannot have instance uniforms), so it is handed the value
	# the node holds rather than read back off the material, which no longer carries
	# one.
	_probe_mat.set_shader_parameter("_water_domain_origin", _domain_origin)
	_probe_mat.set_shader_parameter("probe_in", packed)
	_probe_mat.set_shader_parameter("probe_cpu", p_cpu)
	_probe_mat.set_shader_parameter("probe_count", p_domains.size())
	_probe_mat.set_shader_parameter("cell_px", float(CELL_PX))
	_probe_mat.set_shader_parameter("base_y", p_base_y)
	_probe_mat.set_shader_parameter("cpu_time", p_cpu_time)

	await _settle_frames(4)
	var img := _probe_vp.get_texture().get_image()
	var lit := Vector3i.ZERO
	var y := img.get_height() / 2
	_last_clock_cell = img.get_pixel(
			p_domains.size() * CELL_PX + CELL_PX / 2, y)
	for i in p_domains.size():
		var c := img.get_pixel(i * CELL_PX + CELL_PX / 2, y)
		if c.r > 0.5:
			lit.x += 1
		if c.g > 0.5:
			lit.y += 1
		if c.b > 0.5:
			lit.z += 1
	return lit


func _make_probe_viewport() -> void:
	_probe_mat = ShaderMaterial.new()
	_probe_mat.shader = load(PROBE_SHADER)
	_probe_vp = SubViewport.new()
	# One cell wider than PROBES: the last one is the clock cell.
	_probe_vp.size = Vector2i((PROBES + 1) * CELL_PX, 16)
	_probe_vp.disable_3d = true
	_probe_vp.transparent_bg = false
	_probe_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var rect := ColorRect.new()
	rect.size = _probe_vp.size
	rect.material = _probe_mat
	_probe_vp.add_child(rect)
	add_child(_probe_vp)


# ---- C: how far the drawn mesh is from the analytic surface -------------------
# Reported, not graded. Waves are a vertex effect, so what gets drawn is the
# straight line between displaced vertices and the analytic surface bulges above
# it at every crest. G4 is a statement about the ANALYTIC surface and criterion B
# checks exactly that, evaluated per fragment; this is the separate question of
# how much of a gap the tessellation leaves, which is a geometry-defaults decision
# (§4.6) and not a parity bug.
#
# water_waves.gdshaderinc states the rule of thumb as vertex spacing <= L_min / 8.
# The shipped ocean defaults do not meet it, and this prints by how much rather
# than asserting a number nobody has yet chosen.
func _gate_c_tessellation() -> void:
	print("[C] mesh vs analytic surface at the ocean defaults (reported, not graded):")
	var root := _make_world(Vector3(0, 30, 0), -40.0)
	var terrain := _make_ocean(root)
	var spacing: float = terrain.ocean_vertex_spacing

	# The shortest wavelength in the table, which is what the mesh has to resolve.
	var table: PackedVector4Array = terrain.ocean_material.get_shader_parameter("_waves")
	var l_min := INF
	for w in table:
		if w.z > 0.0:
			l_min = minf(l_min, w.w)

	# Sag at a cell centre: the drawn surface there is the mean of the four
	# displaced corners, and the analytic one is the displaced centre. Both are
	# parametric, so this is exact -- no camera, no rasteriser, no shading.
	var worst_sag := 0.0
	var worst_total := 0.0
	for i in 40:
		for j in 40:
			var u := Vector2(float(i) * spacing * 3.0, float(j) * spacing * 3.0)
			var c0: Vector3 = terrain.get_water_surface_point(u)
			var c1: Vector3 = terrain.get_water_surface_point(u + Vector2(spacing, 0.0))
			var c2: Vector3 = terrain.get_water_surface_point(u + Vector2(0.0, spacing))
			var c3: Vector3 = terrain.get_water_surface_point(u + Vector2(spacing, spacing))
			var drawn: Vector3 = (c0 + c1 + c2 + c3) * 0.25
			var exact: Vector3 = terrain.get_water_surface_point(
					u + Vector2(spacing, spacing) * 0.5)
			worst_sag = maxf(worst_sag, absf(exact.y - drawn.y))
			worst_total = maxf(worst_total, (exact - drawn).length())

	print("    LOD0 vertex spacing %.2f m | shortest wavelength %.2f m | ratio %.2f" % [
		spacing, l_min, l_min / spacing])
	print("    rule of thumb in water_waves.gdshaderinc is a ratio of 8 or more")
	print("    worst cell-centre sag: %.3f m vertical, %.3f m total" % [
		worst_sag, worst_total])
	if l_min / spacing < 8.0:
		print("    NOTE: the shipped defaults are %.1fx short of the rule. The drawn" % (
			8.0 / (l_min / spacing)))
		print("      surface therefore sits up to %.0f cm below the analytic one at" % (
			worst_sag * 100.0))
		print("      LOD0, and further at every coarser LOD. G4 is unaffected -- it is")
		print("      about the analytic surface -- but a buoyancy query will float")
		print("      objects that much above what the player sees. §4.6 / §11.")

	root.queue_free()


# ---- D: §4.4, the ocean's shadow setting is its own --------------------------
# The bug was that Pasture3DMesher::update() read the TERRAIN's cast_shadows and
# gi_mode for the ocean's instances, so the ocean silently inherited settings
# meant for the ground.
#
# The two halves are each other's control, and they are set up to fail if the old
# behaviour is still there: the terrain is always given the OPPOSITE setting to
# the ocean, so an ocean that follows the terrain gets exactly the wrong answer
# both times. A third capture with no caster at all fixes the scale, so "dark"
# cannot be some unrelated ambient.
#
# The ocean is given a plain opaque material for this. Its own material is
# alpha-blended and Godot does not put blended surfaces in the shadow map at all,
# which would make every reading here "no shadow" regardless of the flag -- a
# perfect way to pass a test that is examining nothing. What is under test is the
# instance flag, and that is material-independent.
func _gate_d_shadows() -> void:
	print("[D] §4.4 -- ocean_cast_shadows is the ocean's, not the terrain's:")
	# Camera below the sheet looking down at a receiver, so the caster itself is
	# behind the camera and only its shadow is in frame.
	var root := _make_world(Vector3(0, -10, 0), -55.0)
	var sun: DirectionalLight3D = root.get_node("Sun")
	sun.rotation_degrees = Vector3(-90, 0, 0)
	sun.shadow_enabled = true
	# Deliberately NOT bright. The first version used energy 2.0 and both the lit
	# readings clipped at 1.0000, which makes "not casting matches no ocean at all"
	# true by saturation rather than by measurement.
	sun.light_energy = 0.7

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(600, 600)
	ground.mesh = plane
	ground.position = Vector3(0, -40, 0)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.8, 0.8, 0.8)
	gm.roughness = 1.0
	ground.material_override = gm
	root.add_child(ground)

	var opaque := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = "shader_type spatial;\nrender_mode cull_disabled;\nvoid fragment() { ALBEDO = vec3(0.3); }\n"
	opaque.shader = sh

	var terrain := _make_ocean(root)
	terrain.ocean_material = opaque
	await _settle_physics(6)

	# Ocean casts, terrain explicitly does not.
	terrain.cast_shadows = 0
	terrain.ocean_cast_shadows = 1
	await _settle_physics(6)
	var casting := _mean_luma(_grab())
	_screenshot("%s/phase4_shadow_on.png" % _out_dir)

	# Ocean does not cast, terrain explicitly does.
	terrain.cast_shadows = 1
	terrain.ocean_cast_shadows = 0
	await _settle_physics(6)
	var not_casting := _mean_luma(_grab())
	_screenshot("%s/phase4_shadow_off.png" % _out_dir)

	# Scale: the same frame with the caster removed outright.
	terrain.ocean_enabled = false
	await _settle_physics(6)
	var no_ocean := _mean_luma(_grab())
	terrain.ocean_enabled = true

	print("    receiver luminance: ocean casting %.4f | not casting %.4f | no ocean %.4f" % [
		casting, not_casting, no_ocean])
	if absf(not_casting - no_ocean) > 0.02:
		_fail += 1
		print("    !! 'not casting' does not match 'no ocean at all', so the ocean is")
		print("       still shadowing while its own setting says off")
	elif not_casting - casting < 0.05:
		_fail += 1
		print("    !! turning ocean_cast_shadows on does not darken the receiver;")
		print("       either the flag is ignored or nothing is casting")
	else:
		print("    -> the ocean casts on its own setting and ignores the terrain's")

	print("    ocean_gi_mode is not measured here: it needs a baked GI volume, and it")
	print("      is set on the same mesher field, in the same update(), from the same")
	print("      §4.4 change as cast_shadows. Round-trip only:")
	terrain.ocean_gi_mode = 2
	var gi_ok: bool = terrain.ocean_gi_mode == 2 and terrain.gi_mode != 2
	print("      ocean_gi_mode=%d, terrain gi_mode=%d -> independent: %s" % [
		terrain.ocean_gi_mode, terrain.gi_mode, str(gi_ok)])
	if not gi_ok:
		_fail += 1
		print("      !! the two share storage")

	root.queue_free()
	await _settle()


# ---- E: §4.5, the cull volume follows sea level ------------------------------
# The clipmap sheet is built at y = 0 and the shader lifts it to sea_level, so the
# AABB the culler uses knows nothing about where the water actually is unless C++
# tells it. It did not: _update_ocean_aabbs() was never called.
#
# Measured as a difference rather than an absolute, which removes the framing
# entirely: raise the sea and raise the camera by the same amount and the picture
# must not change. The control is the bug reintroduced -- physics frozen so the
# AABB poll cannot run, then sea_level moved behind its back. That must break it,
# and releasing physics must fix it again, which is what pins the collapse on the
# AABB and not on anything else about being 600 m up.
#
# The camera sits BELOW the water looking up, and that is not an aesthetic choice.
# Looking down, a stale AABB is still somewhere under the camera and a downward
# frustum contains almost everything under the camera, so a 300 m error changed
# the coverage by nothing measurable -- the first version of this gate reported a
# control that failed to fail. Looking up, an AABB left behind at the old sea
# level is below the camera and therefore outside the frustum entirely, which is
# what culling looks like when it happens. The ocean shader is cull_disabled, so
# the underside draws.
func _gate_e_cull() -> void:
	print("[E] §4.5 -- the ocean's cull volume follows sea level:")
	var root := _make_world(Vector3(0, -25, 0), 40.0)
	var cam: Camera3D = root.get_node("Camera3D")
	var terrain := _make_ocean(root, false)
	var mat: ShaderMaterial = terrain.ocean_material
	await _settle_physics(6)

	# The sky reference, taken once. It depends only on the camera's orientation,
	# which never changes here, so one capture serves every height -- and taking it
	# up front means the control below never has to touch ocean_enabled, which
	# would re-run initialize() and repair the very AABB it is trying to leave
	# stale.
	terrain.ocean_enabled = false
	await _settle_physics(6)
	var sky := _grab()
	terrain.ocean_enabled = true
	await _settle_physics(10)

	var at_zero := await _water_coverage(terrain, cam, mat, sky, 0.0, -25.0)
	var at_300 := await _water_coverage(terrain, cam, mat, sky, 300.0, 275.0)
	print("    water coverage: sea level 0 -> %.1f%% | sea level 300 -> %.1f%%" % [
		at_zero * 100.0, at_300 * 100.0])
	_screenshot("%s/phase4_sea_level_300.png" % _out_dir)

	# The control: same move, but with the AABB poll frozen out.
	terrain.set_physics_process(false)
	await _settle()
	mat.set_shader_parameter("sea_level", 600.0)
	cam.position = Vector3(0, 575, 0)
	await _settle_frames(20)
	var stale := _coverage(sky, _grab())
	_screenshot("%s/phase4_stale_aabb.png" % _out_dir)

	# And the recovery, which is what makes the collapse attributable.
	terrain.set_physics_process(true)
	await _settle_physics(10)
	var recovered := _coverage(sky, _grab())
	_screenshot("%s/phase4_stale_aabb_recovered.png" % _out_dir)

	print("    CONTROL, sea level moved with the AABB poll frozen: %.1f%%" % (stale * 100.0))
	print("    same frame after the poll is allowed to run again:   %.1f%%" % (
		recovered * 100.0))

	if at_zero < 0.5:
		_fail += 1
		print("    !! there is no water on screen at sea level 0; nothing below means anything")
	elif absf(at_300 - at_zero) > 0.05:
		_fail += 1
		print("    !! raising the sea by 300 m changes what is drawn; the cull volume")
		print("       is not following it")
	elif recovered - stale < 0.2:
		_fail += 1
		print("    !! a deliberately stale AABB does not cull anything, so this gate")
		print("       is not measuring culling and E proves nothing")
	else:
		print("    -> sea level moves the cull volume with it (%.0f%% of the frame" % (
			(recovered - stale) * 100.0))
		print("       is culled when it does not)")

	root.queue_free()
	await _settle()


# Fraction of the frame the ocean covers, at a given sea level and camera height,
# against a sky reference the caller captured once.
func _water_coverage(p_terrain: Pasture3D, p_cam: Camera3D, p_mat: ShaderMaterial,
		p_sky: Image, p_sea_level: float, p_cam_y: float) -> float:
	p_mat.set_shader_parameter("sea_level", p_sea_level)
	p_cam.position = Vector3(0, p_cam_y, 0)
	# Physics frames, not just draw frames: the AABB poll lives in physics.
	await _settle_physics(10)
	return _coverage(p_sky, _grab())


# ---- scene helpers ----------------------------------------------------------
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
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-38, 130, 0)
	sun.shadow_enabled = false
	root.add_child(sun)
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.position = p_cam_pos
	cam.rotation_degrees = Vector3(p_pitch, 0, 0)
	cam.far = 20000.0
	cam.cull_mask = 1
	cam.current = true
	root.add_child(cam)
	return root


func _make_ocean(p_root: Node3D, p_freeze_clock: bool = false) -> Pasture3D:
	var mat := ShaderMaterial.new()
	mat.shader = load(WATER_DIR + "water_ocean.gdshader")
	mat.set_shader_parameter("deep_color", Color(0.02, 0.09, 0.14))
	mat.set_shader_parameter("absorption", Vector3(0.35, 0.08, 0.05))
	var terrain := Pasture3D.new()
	terrain.ocean_material = mat
	terrain.ocean_enabled = true
	terrain.ocean_wave_count = 8
	terrain.ocean_wave_direction = 20.0
	terrain.ocean_wave_spread = 28.0
	terrain.ocean_wave_amplitude = 1.6
	terrain.ocean_wave_length_max = 137.0
	terrain.ocean_wave_steepness = 0.35
	terrain.ocean_wave_loop_period = LOOP_PERIOD
	terrain.render_layers = 1 << 4
	terrain.ocean_render_layers = 1
	p_root.add_child(terrain)
	if p_freeze_clock:
		terrain.set_physics_process(false)
	return terrain


# ---- image helpers ----------------------------------------------------------
func _settle() -> void:
	await _settle_frames(10)


func _settle_frames(p_n: int) -> void:
	for i in p_n:
		await RenderingServer.frame_post_draw


# Draw frames are NOT physics frames here, and the difference is not academic:
# vsync is off and max_fps is 0, so this harness renders hundreds of frames per
# 60 Hz physics tick. Everything Pasture3D does for the water -- advancing the
# clock, polling the cull AABB, snapping the clipmap -- happens in physics. The
# first version of this gate settled on draw frames and measured a clipmap that
# had barely started: 0% water coverage where there should have been 100%, and a
# "frozen" clock that was simply never ticked.
func _settle_physics(p_n: int) -> void:
	for i in p_n:
		await get_tree().physics_frame
	await _settle_frames(3)


func _grab() -> Image:
	return get_viewport().get_texture().get_image()


func _screenshot(p_path: String) -> void:
	_grab().save_png(p_path)


func _chan_delta(p_a: Color, p_b: Color) -> float:
	return maxf(maxf(absf(p_a.r - p_b.r), absf(p_a.g - p_b.g)), absf(p_a.b - p_b.b))


func _coverage(p_without: Image, p_with: Image) -> float:
	var changed := 0
	var n := 0
	for y in range(0, p_with.get_height(), 3):
		for x in range(0, p_with.get_width(), 3):
			if _chan_delta(p_without.get_pixel(x, y), p_with.get_pixel(x, y)) > 0.01:
				changed += 1
			n += 1
	return float(changed) / float(maxi(n, 1))


func _mean_luma(p_img: Image) -> float:
	var total := 0.0
	var n := 0
	for y in range(0, p_img.get_height(), 4):
		for x in range(0, p_img.get_width(), 4):
			var c := p_img.get_pixel(x, y)
			total += c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
			n += 1
	return total / float(maxi(n, 1))
