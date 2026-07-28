# Pasture3D Water — Phase 5 gate.
#
# Phase 5's exit gate as written is "G1 met on Steam Deck; A/B screenshots signed
# off". The Deck is unavailable, so what this measures is the desktop half, and
# §11 q7's fallback applies: EVERY DECK FIGURE IN THIS SPEC REMAINS EXTRAPOLATED.
# This gate does not, and cannot, claim otherwise. It is deliberately written so
# the same file runs unchanged on a Deck when one turns up.
#
# Four criteria:
#
#   A  cost: the shipped presets against the legacy material, all three pitches,
#      at the Deck's 1280x800. Geometry is decomposed out, so "the new shader is
#      cheaper" is not quietly resting on "and it also draws different geometry".
#   B  the presets that SHIP are the ones that render, including the lake and
#      pond on a bare MeshInstance3D with no Pasture3D anywhere (G6).
#   C  the Phase 5 geometry defaults are live and the sag is what q6 predicted.
#   D  A/B captures for sign-off, plus the wave-count comparison §11 q1 asks for.
#
# Run:  Godot_v4.7-stable_win64_console.exe --path project bench/WaterPhase5Gate.tscn
#       BENCH_OUT=some/dir to put the PNGs somewhere findable.
extends Node

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const LEGACY_MAT := "res://addons/pasture_3d/extras/shaders/M_ocean.tres"
const OCEAN_HIGH := WATER_DIR + "M_water_ocean.tres"
const OCEAN_LOW := WATER_DIR + "M_water_ocean_low.tres"
const LAKE := WATER_DIR + "M_water_lake.tres"
const POND := WATER_DIR + "M_water_pond.tres"

const BENCH_RES := Vector2i(1280, 800)
const PERF_WARMUP := 60
const PERF_FRAMES := 150
const PITCHES := [-4.0, -20.0, -60.0]
const LOOP_PERIOD := 120.0

# The geometry defaults §11 q6 closed on. Asserted rather than read, so this gate
# fails if someone changes them without revisiting the measurement behind them.
const WANT_SPACING := 1.0
const WANT_LODS := 9
const WANT_MESH_SIZE := 16
# Ratio the include file asks for, and the sag that buys.
const WANT_RATIO := 8.0
const WANT_SAG_M := 0.03
# What the old defaults measured, so criterion C's control has a number to hit.
const OLD_SAG_M := 0.22

var _fail := 0
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

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	DisplayServer.window_set_size(BENCH_RES)

	print("=== Pasture3D Water — Phase 5 gate ===")
	print("Godot %s | %s | %s" % [
		Engine.get_version_info().string,
		RenderingServer.get_video_adapter_name(),
		RenderingServer.get_current_rendering_method()])
	print("captures -> %s" % _out_dir)
	print("")

	_gate_e_detail_slope()
	await _gate_a_cost()
	await _gate_b_presets()
	await _gate_c_geometry()
	await _gate_d_captures()

	print("")
	print("=== PHASE 5 GATE %s ===" % ("PASS" if _fail == 0 else "FAIL (%d)" % _fail))
	print("NOTE: this is the DESKTOP half of the exit gate. The Steam Deck target")
	print("  (G1, 1.0 ms high tier / 0.6 ms low) is UNVERIFIED -- no hardware. See §11 q7.")
	get_tree().quit(0 if _fail == 0 else 1)


# ---- E: the detail layer does not tilt the surface past physical --------------
# Runs first, because it is the cheapest and it is the one that was missed.
#
# The Phase 5 A/B captures came back with rust-coloured speckle and flat grey
# slabs at the horizon, and the cause was a single wrong constant that had been
# shipping since Phase 3: detail_strength defaulted to 1.0 on the belief that 1.0
# meant "the slope as authored". It did not. tools/gen_water_textures.py computes
# a real derivative in m/m, normalises it by its own 99.5th percentile so the
# 8-bit range is spent usefully, and then discards the divisor. So 1.0 meant "the
# 99.5th percentile", the two summed layers reached an rms slope of 0.39 with
# excursions past 2.0, and normals tilted below the horizon -- reflecting the
# sky's brown ground hemisphere. The same constant feeds variance_to_roughness,
# so distant water was also getting +0.55 roughness and greying out.
#
# Nothing in Phase 3 caught it because every Phase 3 criterion measured a
# QUANTITY -- tiling delta, speckle ratio, cost in ms -- and none of them asked
# whether the composed normal was physically possible. This does, and it needs no
# rendering at all: the texture's own statistics and the shipped constant are
# enough to decide it.
func _gate_e_detail_slope() -> void:
	print("[E] the detail layer's composed slope is physical:")
	var img: Image = load(WATER_DIR + "T_water_deriv.png").get_image()
	if img.is_compressed():
		img.decompress()
	# Decode exactly as water_shading.gdshaderinc does: rg * 2 - 1.
	var sum_sq := 0.0
	var peak := 0.0
	var n := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			var dx := c.r * 2.0 - 1.0
			var dy := c.g * 2.0 - 1.0
			sum_sq += dx * dx + dy * dy
			peak = maxf(peak, maxf(absf(dx), absf(dy)))
			n += 2
	var stored_rms := sqrt(sum_sq / float(maxi(n, 1)))

	var mat: ShaderMaterial = load(OCEAN_HIGH)
	var strength: float = mat.get_shader_parameter("detail_strength")
	# Two scrolled layers of the same field add in quadrature; the tail adds
	# linearly, because both layers can peak on the same pixel.
	var layers := 2.0
	var applied_rms := stored_rms * strength * sqrt(layers)
	var applied_peak := peak * strength * layers

	print("    texture: stored rms %.3f, peak %.3f per layer" % [stored_rms, peak])
	print("    preset detail_strength %.2f -> applied rms %.3f m/m, worst case %.3f m/m" % [
		strength, applied_rms, applied_peak])

	# Wind-ruffled water below the 10 m Gerstner floor sits around 0.05-0.15 rms
	# slope. The tail bound is the one that matters for the artefact: past 1.0 the
	# detail alone can tilt the normal 45 degrees, and the reflection vector starts
	# finding the ground.
	if applied_rms < 0.02:
		_fail += 1
		print("      !! detail is effectively off; the sub-10 m scale has nothing in it")
	elif applied_rms > 0.20:
		_fail += 1
		print("      !! rms slope is past anything wind-ruffled water does")
	elif applied_peak > 1.0:
		_fail += 1
		print("      !! the tail tilts the normal past 45 deg; reflections will find the ground")
	else:
		print("      -> inside the physical band, and the tail stays under 45 deg")

	# The control: the old default. It has to fail, or this criterion is not
	# actually sensitive to the defect it was written for.
	var old_peak := peak * 1.0 * layers
	var old_rms := stored_rms * 1.0 * sqrt(layers)
	print("    CONTROL, the old default of 1.0: rms %.3f, worst case %.3f" % [old_rms, old_peak])
	if old_rms <= 0.20 and old_peak <= 1.0:
		_fail += 1
		print("      !! the old default passes this test, so the test does not catch the bug")
	else:
		print("      -> fails, as the shipped captures showed it should")


# ---- A: cost ----------------------------------------------------------------
# The comparison that matters is ship-against-ship: the legacy material on the
# geometry it shipped with, against each new preset on the geometry IT ships
# with. But that conflates two changes, so the legacy material is also measured
# on the new geometry -- the row that says how much of any win is the shader and
# how much is the two extra clipmap rings.
#
# Every reading is the better of two passes. A single pass catches the radiance
# cubemap still converging and the shader cache still warming, both of which bias
# upward and neither of which is the shader.
func _gate_a_cost() -> void:
	print("[A] G1 -- GPU ms at %dx%d, the Deck's resolution:" % [BENCH_RES.x, BENCH_RES.y])
	var root := _make_world(Vector3(0, 30, 0), -60.0)
	var terrain := _make_ocean(root)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	await _settle()

	var legacy: ShaderMaterial = load(LEGACY_MAT)
	var high: ShaderMaterial = load(OCEAN_HIGH)
	var low: ShaderMaterial = load(OCEAN_LOW)

	# name, material (null = ocean off), spacing, lods
	# Both shaders appear on both geometries, so the 2x2 separates the two changes
	# instead of leaving them summed. Without the "NEW high, old geom" row the cost
	# of the q6 density change could only be inferred from the legacy shader's
	# response to it, which is a different vertex program.
	var configs := [
		["OFF (sky floor)", null, WANT_SPACING, WANT_LODS],
		["LEGACY, old geom", legacy, 4.0, 7],
		["LEGACY, new geom", legacy, WANT_SPACING, WANT_LODS],
		["NEW high, old geom", high, 4.0, 7],
		["NEW high", high, WANT_SPACING, WANT_LODS],
		["NEW low", low, WANT_SPACING, WANT_LODS],
	]

	var results := {}
	for pitch in PITCHES:
		var cam: Camera3D = root.get_node("Camera3D")
		cam.rotation_degrees = Vector3(pitch, 0, 0)
		print("    pitch %.0f deg:" % pitch)
		for cfg in configs:
			terrain.ocean_vertex_spacing = cfg[2]
			terrain.ocean_mesh_lods = cfg[3]
			if cfg[1] == null:
				terrain.ocean_enabled = false
			else:
				terrain.ocean_material = cfg[1]
				terrain.ocean_enabled = true
			await _settle()
			var ms := await _measure_twice(cfg[0])
			results[[pitch, cfg[0]]] = ms

	# Coverage, so "cheaper" is never cheaper-because-less-water.
	terrain.ocean_material = high
	terrain.ocean_enabled = true
	var cam2: Camera3D = root.get_node("Camera3D")
	cam2.rotation_degrees = Vector3(-60.0, 0, 0)
	await _settle()
	var with_water := _grab()
	terrain.ocean_enabled = false
	await _settle()
	var without_water := _grab()
	terrain.ocean_enabled = true
	await _settle()
	var coverage := _coverage(without_water, with_water)
	print("    at -60 deg the ocean covers %.1f%% of the frame" % (coverage * 100.0))

	print("")
	print("    pitch,config,gpu_ms,own_share_ms,vs_legacy")
	var worst_high := 0.0
	var worst_low := 0.0
	for pitch in PITCHES:
		var floor_ms: float = results[[pitch, "OFF (sky floor)"]]
		var leg: float = results[[pitch, "LEGACY, old geom"]]
		for cfg in configs:
			var ms: float = results[[pitch, cfg[0]]]
			var own := ms - floor_ms
			var vs := "" if cfg[1] == null else "%.2fx" % (ms / leg)
			print("    %.0f,%s,%.4f,%.4f,%s" % [pitch, cfg[0], ms, own, vs])
		worst_high = maxf(worst_high, results[[pitch, "NEW high"]])
		worst_low = maxf(worst_low, results[[pitch, "NEW low"]])

	# Pass condition. Not an absolute millisecond target -- §8.4 retired that,
	# because 0.144 ms of the total is Godot's lit transparent floor and not this
	# shader's to spend. What must hold is that the replacement is cheaper than the
	# thing it replaces, at every pitch, on the geometry each actually ships with.
	var beaten := true
	for pitch in PITCHES:
		var leg: float = results[[pitch, "LEGACY, old geom"]]
		if results[[pitch, "NEW high"]] >= leg or results[[pitch, "NEW low"]] >= leg:
			beaten = false
	if beaten:
		print("    -> both new tiers cost less than legacy at every pitch")
	else:
		_fail += 1
		print("    !! a new tier costs more than the legacy material it replaces")

	# The control: the sky floor must be materially below every water row, or the
	# harness is not drawing water and every number above is a measurement of
	# nothing. 100% coverage at -60 says the same thing from the other side.
	var floor60: float = results[[-60.0, "OFF (sky floor)"]]
	var high60: float = results[[-60.0, "NEW high"]]
	print("    CONTROL, sky floor %.4f vs water %.4f: floor is lower: %s (must be true)" % [
		floor60, high60, str(floor60 < high60 * 0.9)])
	if floor60 >= high60 * 0.9 or coverage < 0.95:
		_fail += 1
		print("    !! the control did not separate; the cost readings are not evidence")

	print("    Deck extrapolation, NOT a measurement: G1 wants <= 1.0 ms high / 0.6 low.")
	print("      desktop high %.4f, low %.4f at the worst pitch." % [worst_high, worst_low])
	root.queue_free()
	await _settle()


# ---- B: the shipped presets render ------------------------------------------
# Phase 3 dressed every material by hand because the presets did not exist yet.
# They exist now, so this gate loads the .tres files themselves -- the thing a
# user gets. A preset that is missing its detail texture, or points at a shader
# whose uniforms it does not set, renders water that merely looks slightly wrong,
# and nothing but loading the real file would catch it.
#
# The lake and pond go on a bare MeshInstance3D with no Pasture3D in the scene at
# all. That is G6, and it is the claim most easily broken by accident, since
# everything else in this plugin arrives via the terrain node.
#
# Coverage alone is NOT enough here and the first version of this gate got it
# wrong: it reported the high and low ocean presets at an identical 86.9%, and
# the lake and pond at an identical 62.2%. That is the correct answer to the
# question coverage asks -- both draw water over the same silhouette -- but it
# means the criterion would have passed unchanged if M_water_ocean_low.tres
# silently loaded the high shader. So each pair is also differenced against the
# other, with a same-preset re-render as the control that must come out at zero.
func _gate_b_presets() -> void:
	print("")
	print("[B] the shipped presets render, and render DIFFERENTLY (G6 for lake/pond):")

	# --- the two ocean tiers, on the clipmap ---
	var root := _make_world(Vector3(0, 30, 0), -30.0)
	var terrain := _make_ocean(root)
	# Frozen, so a difference between two renders is the material and not the
	# clock having moved between them.
	terrain.set_physics_process(false)
	_freeze_clock(37.5)

	var shots := {}
	for entry in [["ocean high", OCEAN_HIGH], ["ocean low", OCEAN_LOW]]:
		terrain.ocean_material = load(entry[1])
		terrain.ocean_enabled = true
		await _settle()
		shots[entry[0]] = _grab()
		terrain.ocean_enabled = false
		await _settle()
		var cov := _coverage(_grab(), shots[entry[0]])
		print("    %-11s covers %.1f%% of the frame" % [entry[0], cov * 100.0])
		if cov < 0.5:
			_fail += 1
			print("      !! the preset drew (almost) nothing")

	# The control first: the same preset rendered twice must be identical, which is
	# what makes a non-zero high-vs-low difference mean something.
	terrain.ocean_material = load(OCEAN_HIGH)
	terrain.ocean_enabled = true
	await _settle()
	var repeat := _grab()
	var control_delta := _mean_delta(shots["ocean high"], repeat)
	var tier_delta := _mean_delta(shots["ocean high"], shots["ocean low"])
	print("    high vs low: mean pixel delta %.4f | CONTROL high vs high: %.4f" % [
		tier_delta, control_delta])
	if control_delta > 0.002:
		_fail += 1
		print("      !! the same preset does not render the same twice; the compare is noise")
	elif tier_delta < 0.01:
		_fail += 1
		print("      !! the two tiers render the same image -- low tier is not the low shader")
	else:
		print("      -> the tiers are genuinely different shaders, not one file twice")
	root.queue_free()
	await _settle()

	# --- lake and pond, on a bare mesh with no Pasture3D in the scene at all ---
	var body_shots := {}
	for entry in [["lake", LAKE], ["pond", POND]]:
		var r2 := _make_world(Vector3(0, 6, 90.0), -12.0)
		# Nothing writes a uniform here and nothing uploads a wave table; the
		# material has to stand entirely on its own. That is G6.
		var mi := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(400, 400)
		plane.subdivide_width = 199
		plane.subdivide_depth = 199
		mi.mesh = plane
		mi.material_override = load(entry[1])
		r2.add_child(mi)
		# The clock still has to tick, and normally Pasture3D does that. A body
		# material with a dead clock renders a frozen but perfectly plausible
		# surface, so this is set explicitly rather than assumed.
		_freeze_clock(31.7)
		await _settle()
		body_shots[entry[0]] = _grab()

		# The control: the SAME mesh with no material at all. If this still reads as
		# water coverage then the metric is measuring the mesh, not the shader.
		mi.material_override = null
		await _settle()
		var cov := _coverage(_grab(), body_shots[entry[0]])
		print("    %-11s on a bare MeshInstance3D covers %.1f%% of the frame" % [
			entry[0], cov * 100.0])
		if cov < 0.2:
			_fail += 1
			print("      !! the preset drew (almost) nothing on a plain mesh; G6 is broken")
		mi.material_override = load(entry[1])
		await _settle()
		_screenshot(_out_dir.path_join("phase5_%s.png" % entry[0]))
		r2.queue_free()
		await _settle()

	var body_delta := _mean_delta(body_shots["lake"], body_shots["pond"])
	print("    lake vs pond: mean pixel delta %.4f" % body_delta)
	if body_delta < 0.01:
		_fail += 1
		print("      !! lake and pond render the same image; they are not distinct presets")
	else:
		print("      -> distinct presets on distinct shaders")


# ---- C: the Phase 5 geometry defaults are live ------------------------------
# §11 q6 was closed by changing two defaults that must move together, so this
# asserts the shipped numbers rather than reading them back and reporting
# whatever it finds. The sag is recomputed from the parametric surface, which is
# the same arithmetic q6 was decided on.
func _gate_c_geometry() -> void:
	print("")
	print("[C] §11 q6 -- the geometry defaults and the sag they buy:")
	var root := _make_world(Vector3(0, 30, 0), -40.0)
	# Untouched: this reads the DEFAULTS, so _make_ocean is not used here.
	var terrain := Pasture3D.new()
	terrain.ocean_material = load(OCEAN_HIGH)
	terrain.ocean_enabled = true
	terrain.render_layers = 1 << 4
	terrain.ocean_render_layers = 1
	root.add_child(terrain)
	await _settle_physics(4)

	var spacing: float = terrain.ocean_vertex_spacing
	var lods: int = terrain.ocean_mesh_lods
	var mesh_size: int = terrain.ocean_mesh_size
	var half_extent := 2.0 * float(mesh_size) * spacing * pow(2.0, float(lods - 1))
	print("    defaults: mesh_size %d, spacing %.2f m, lods %d -> half-extent %.0f m" % [
		mesh_size, spacing, lods, half_extent])
	if not (is_equal_approx(spacing, WANT_SPACING) and lods == WANT_LODS
			and mesh_size == WANT_MESH_SIZE):
		_fail += 1
		print("      !! the shipped defaults are not the ones q6 closed on")

	var l_min := _l_min(terrain)
	var ratio := l_min / spacing
	var sag := _sag(terrain, spacing)
	print("    shortest wavelength %.2f m -> ratio %.2f (want >= %.1f)" % [
		l_min, ratio, WANT_RATIO])
	print("    worst cell-centre sag %.1f cm (want <= %.0f cm)" % [
		sag * 100.0, WANT_SAG_M * 100.0])
	if ratio < WANT_RATIO or sag > WANT_SAG_M:
		_fail += 1
		print("      !! the drawn surface is further from the analytic one than q6 allows")

	# The control: put the OLD defaults back and confirm the same assertion fails.
	# Without this, "sag is under 3 cm" could be true of a measurement that is not
	# looking at the geometry at all.
	terrain.ocean_vertex_spacing = 4.0
	terrain.ocean_mesh_lods = 7
	await _settle_physics(2)
	var old_sag := _sag(terrain, terrain.ocean_vertex_spacing)
	var old_ratio := _l_min(terrain) / terrain.ocean_vertex_spacing
	print("    CONTROL, old defaults (spacing 4, lods 7): ratio %.2f, sag %.1f cm" % [
		old_ratio, old_sag * 100.0])
	if old_sag <= WANT_SAG_M or old_ratio >= WANT_RATIO:
		_fail += 1
		print("      !! the control passed the test it is supposed to fail")
	elif absf(old_sag - OLD_SAG_M) > 0.03:
		_fail += 1
		print("      !! the control failed, but not at the %.0f cm Phase 4 measured" % (
			OLD_SAG_M * 100.0))
	else:
		print("      -> fails as it must, at the %.0f cm Phase 4 measured" % (OLD_SAG_M * 100.0))

	root.queue_free()
	await _settle()


func _l_min(p_terrain: Pasture3D) -> float:
	var table: PackedVector4Array = p_terrain.ocean_material.get_shader_parameter("_waves")
	var l := INF
	for w in table:
		if w.z > 0.0:
			l = minf(l, w.w)
	return l


func _sag(p_terrain: Pasture3D, p_spacing: float) -> float:
	var worst := 0.0
	for i in 40:
		for j in 40:
			var u := Vector2(float(i) * p_spacing * 3.0, float(j) * p_spacing * 3.0)
			var c0: Vector3 = p_terrain.get_water_surface_point(u)
			var c1: Vector3 = p_terrain.get_water_surface_point(u + Vector2(p_spacing, 0.0))
			var c2: Vector3 = p_terrain.get_water_surface_point(u + Vector2(0.0, p_spacing))
			var c3: Vector3 = p_terrain.get_water_surface_point(u + Vector2(p_spacing, p_spacing))
			var drawn: Vector3 = (c0 + c1 + c2 + c3) * 0.25
			var exact: Vector3 = p_terrain.get_water_surface_point(
					u + Vector2(p_spacing, p_spacing) * 0.5)
			worst = maxf(worst, absf(exact.y - drawn.y))
	return worst


# ---- D: A/B captures --------------------------------------------------------
# Reported, not graded. These are the images Phase 5 asks to be signed off, and a
# gate cannot sign off an aesthetic judgement -- what it can do is make the pair
# comparable, which means the same camera, the same sun, the same frozen instant
# and the same sea state, changing one thing at a time.
#
# The wave-count set is §11 q1. Cost is not the objection to any count (§4.6,
# §8.4 measured the whole wave sum at 0.008 ms), so the only question these can
# answer is whether 8 looks too regular. Note the ceiling: WATER_MAX_WAVES is 8,
# so 12 or 16 is a uniform-array and default-table change, not a knob.
func _gate_d_captures() -> void:
	print("")
	print("[D] A/B captures for sign-off (reported, not graded):")
	for pitch in PITCHES:
		var root := _make_world(Vector3(0, 30, 0), pitch)
		var terrain := _make_ocean(root)
		terrain.set_physics_process(false)
		_freeze_clock(37.5)

		terrain.ocean_material = load(LEGACY_MAT)
		terrain.ocean_vertex_spacing = 4.0
		terrain.ocean_mesh_lods = 7
		await _settle()
		_screenshot(_out_dir.path_join("phase5_ab_%d_legacy.png" % int(-pitch)))

		terrain.ocean_material = load(OCEAN_HIGH)
		terrain.ocean_vertex_spacing = WANT_SPACING
		terrain.ocean_mesh_lods = WANT_LODS
		await _settle()
		_screenshot(_out_dir.path_join("phase5_ab_%d_new_high.png" % int(-pitch)))

		terrain.ocean_material = load(OCEAN_LOW)
		await _settle()
		_screenshot(_out_dir.path_join("phase5_ab_%d_new_low.png" % int(-pitch)))

		print("    pitch %.0f: legacy / new high / new low written" % pitch)
		root.queue_free()
		await _settle()

	# §11 q1, at the pitch where wave shape is most visible.
	var root := _make_world(Vector3(0, 18, 0), -12.0)
	var terrain := _make_ocean(root)
	terrain.set_physics_process(false)
	terrain.ocean_material = load(OCEAN_HIGH)
	_freeze_clock(37.5)
	for count in [2, 4, 6, 8]:
		terrain.ocean_wave_count = count
		await _settle()
		_screenshot(_out_dir.path_join("phase5_waves_%d.png" % count))
	print("    §11 q1: wave counts 2/4/6/8 written (8 is WATER_MAX_WAVES, the ceiling)")
	root.queue_free()
	await _settle()


# ---- helpers ----------------------------------------------------------------
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


func _make_ocean(p_root: Node3D) -> Pasture3D:
	var terrain := Pasture3D.new()
	terrain.ocean_material = load(OCEAN_HIGH)
	terrain.ocean_enabled = true
	terrain.ocean_light_target = p_root.get_node("Sun")
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
	return terrain


# GPU readings are trustworthy only as the better of two passes: the first is
# still paying for cubemap convergence and shader cache warming, neither of which
# is the shader under test, and both of which only ever bias upward.
func _measure_twice(p_label: String) -> float:
	var a := await _measure_ms()
	var b := await _measure_ms()
	var best := minf(a, b)
	print("      %-18s %.4f ms  (passes %.4f / %.4f)" % [p_label, best, a, b])
	return best


func _measure_ms() -> float:
	var vp := get_viewport().get_viewport_rid()
	for i in PERF_WARMUP:
		await RenderingServer.frame_post_draw
	var samples: Array[float] = []
	for i in PERF_FRAMES:
		await RenderingServer.frame_post_draw
		var ms := RenderingServer.viewport_get_measured_render_time_gpu(vp)
		if ms > 0.0:
			samples.append(ms)
	samples.sort()
	return 0.0 if samples.is_empty() else samples[samples.size() / 2]


func _freeze_clock(p_time: float) -> void:
	RenderingServer.global_shader_parameter_set("water_time", p_time)
	RenderingServer.global_shader_parameter_set("water_time_period", LOOP_PERIOD)


func _settle() -> void:
	for i in 10:
		await RenderingServer.frame_post_draw


# Everything Pasture3D does for the water -- the clock, the AABB poll, the
# clipmap snap -- happens in physics, and with vsync off this harness draws
# hundreds of frames per tick (§8.5 finding 4).
func _settle_physics(p_n: int) -> void:
	for i in p_n:
		await get_tree().physics_frame
	await _settle()


func _grab() -> Image:
	return get_viewport().get_texture().get_image()


# Checked, because the first run of this gate printed "legacy / new high / new low
# written" for all nine A/B captures while every single save had failed on a
# missing output directory -- and still reported PASS. A gate whose sign-off
# artefacts silently do not exist is worse than no gate, since it reads as
# evidence.
func _screenshot(p_path: String) -> void:
	var err := _grab().save_png(p_path)
	if err != OK:
		_fail += 1
		push_error("could not write %s (error %d)" % [p_path, err])


# Mean absolute RGB difference over the frame. Distinguishes "two different
# shaders" from "the same shader loaded twice", which coverage cannot.
func _mean_delta(p_a: Image, p_b: Image) -> float:
	var total := 0.0
	var n := 0
	for y in range(0, p_a.get_height(), 4):
		for x in range(0, p_a.get_width(), 4):
			var ca := p_a.get_pixel(x, y)
			var cb := p_b.get_pixel(x, y)
			total += (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
			n += 1
	return total / float(maxi(n, 1))


func _coverage(p_without: Image, p_with: Image) -> float:
	var changed := 0
	var total := 0
	for y in range(0, p_with.get_height(), 4):
		for x in range(0, p_with.get_width(), 4):
			total += 1
			var a := p_without.get_pixel(x, y)
			var b := p_with.get_pixel(x, y)
			if maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), absf(a.b - b.b)) > 0.02:
				changed += 1
	return float(changed) / float(maxi(total, 1))
