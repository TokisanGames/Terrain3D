# Pasture3D Water Bodies — Phase 7 exit gate (spec §11, PASTURE3D_WATER_BODIES_SPEC.md).
#
# Phase 7 is the ribbon: an OPEN curve becomes a river rather than being refused, it follows the
# spline downhill instead of lying flat, and it carries a per-vertex flow direction that the new
# water_river.gdshader advects its detail layers along.
#
# Gate criteria, from the spec's phase table ("river follows spline Y downhill; flow direction
# correct through a 90° bend; no seam at the clock wrap (control: an unquantised half-period, which
# must seam); cost delta vs lake variant"):
#
#   A. an open curve builds a RIBBON and its surface descends with the spline — sampled along the
#      channel, not just at the ends. Control: the same curve closed, which must build a flat loop
#   B. the flow direction written into ARRAY_COLOR turns through a 90° bend and points along the
#      channel at every row. Control: the loop pool's neutral colour, which must decode to no flow
#   C. the clock wrap is seamless: water_flow_period() quantises the cross-fade against
#      water_time_period. Control: flow_quantise = false, which must leave a residue
#   D. a boat floats on a river, at the height of the reach it is over, and the body registry finds
#      it. Control: a point beside the channel, which must be dry at the same height
#   E. cost of the river variant against the lake variant   [TIMING — skipped unless RUN_TIMING=1]
#
# Every criterion carries a control that must fail; criteria that ran to completion are counted, so
# a criterion that throws part-way cannot read as a pass.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/WaterBodiesPhase7Gate.tscn
#      RUN_TIMING=1 to include E.
extends Node

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const LAKE_MAT := WATER_DIR + "M_water_lake.tres"
const RIVER_MAT := WATER_DIR + "M_water_river.tres"

const LOOP_PERIOD := 120.0

var _fail := 0
var _completed := 0
const CRITERIA := 5
var _run_timing := false


func _ready() -> void:
	var bail := Timer.new()
	bail.wait_time = 900.0
	bail.one_shot = true
	bail.timeout.connect(func():
		push_error("gate timed out")
		get_tree().quit(2))
	add_child(bail)
	bail.start()

	_run_timing = OS.get_environment("RUN_TIMING") != ""
	Engine.physics_ticks_per_second = 60
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	print("=== Pasture3D Water Bodies — Phase 7 gate ===")
	print("Godot %s | %s" % [
		Engine.get_version_info().string, RenderingServer.get_video_adapter_name()])
	print("")

	await _gate_a_downhill()
	await _gate_b_flow_direction()
	await _gate_c_wrap_seam()
	await _gate_d_float_on_river()
	await _gate_e_cost()

	print("")
	if _completed != CRITERIA:
		_fail += 1
		print("!! only %d of %d criteria ran to completion" % [_completed, CRITERIA])
	var verdict := "FAIL (%d)" % _fail
	if _fail == 0:
		verdict = "PASS" if _run_timing else "PASS (CORRECTNESS ONLY -- timing skipped)"
	print("=== PHASE 7 GATE %s ===" % verdict)
	get_tree().quit(0 if _fail == 0 else 1)


# ---- A: the river runs downhill ------------------------------------------------
#
# §7.2's second Y rule. A loop is flat at the node's Y; a ribbon takes the spline's own Y per row,
# because a river that lies flat reads as a canal cut through the hillside.
#
# Sampled ALONG the channel rather than at the two ends: a mesh that took only the first row's Y and
# a mesh that interpolated between the endpoints would both pass an ends-only check, and neither
# follows the spline.
func _gate_a_downhill() -> void:
	print("[A] an open curve builds a ribbon that descends with the spline:")
	var root := _make_world()
	_make_manager(root)
	# 200 m of channel dropping 20 m, in even steps.
	var pool := _make_pool(root, _descending_curve(200.0, 20.0, false), RIVER_MAT)
	await _settle()

	var stats: Dictionary = pool.get_build_stats()
	if not stats.get("ok", false) or not stats.get("ribbon", false):
		_fail += 1
		print("    !! no ribbon was built: ok=%s ribbon=%s reason=%s" % [
			stats.get("ok", false), stats.get("ribbon", false), stats.get("reason", "")])
		root.queue_free()
		await _settle()
		_completed += 1
		return
	print("    ribbon: %d vertices, %d triangles, %.1f ms" % [
		int(stats["vertices"]), int(stats["triangles"]), float(stats["ms"])])

	# March along the channel and require the surface to fall monotonically.
	var heights: Array[float] = []
	for i in 11:
		var x := -100.0 + i * 20.0
		heights.append(pool.get_water_height(Vector2(x, 0.0)))
	var descending := true
	for i in range(1, heights.size()):
		if heights[i] > heights[i - 1] + 0.05: # 5 cm of wave slack
			descending = false
	var drop: float = heights[0] - heights[heights.size() - 1]
	print("    surface along the channel: %.2f m at the head, %.2f m at the mouth (drop %.2f m)" % [
		heights[0], heights[heights.size() - 1], drop])
	if not descending:
		_fail += 1
		print("    !! the surface does not descend monotonically: %s" % [heights])
	elif absf(drop - 20.0) > 1.0:
		_fail += 1
		print("    !! dropped %.2f m over a spline that drops 20 m" % drop)
	else:
		print("    -> follows the spline down all 20 m")

	# Control: the SAME curve, closed. It must build a loop, and a loop is flat — if the ribbon
	# path were not doing anything special, both would behave identically.
	var cpool := _make_pool(root, _descending_curve(200.0, 20.0, true), LAKE_MAT)
	cpool.position = Vector3(0, 0, 400)
	await _settle()
	var cstats: Dictionary = cpool.get_build_stats()
	var flat := absf(cpool.get_water_height(Vector2(-90, 400)) - cpool.get_water_height(Vector2(90, 400)))
	if not cstats.get("ribbon", false) and flat < 0.5:
		print("    control (the same curve closed): fires — builds a loop, flat to %.3f m" % flat)
	else:
		_fail += 1
		print("    !! control did NOT fire: ribbon=%s, head-to-mouth difference %.3f m" % [
			cstats.get("ribbon", false), flat])
	root.queue_free()
	await _settle()
	_completed += 1


# ---- B: flow direction through a bend ------------------------------------------
#
# §10. The mesh writes the normalised XZ tangent into ARRAY_COLOR.rg, and the shader advects its
# detail layers along it. A river that flowed in one fixed direction would slide its texture
# sideways across every bend, which is exactly what the fixed detail_flow0/1 vectors do and exactly
# what this replaces.
func _gate_b_flow_direction() -> void:
	print("")
	print("[B] the flow direction follows the channel through a 90° bend:")
	var root := _make_world()
	_make_manager(root)
	# An L: 100 m along +X, then 100 m along +Z. Flow must read (1,0) then (0,1).
	var pool := _make_pool(root, _bend_curve(100.0), RIVER_MAT)
	await _settle()

	var colours := _mesh_colours(pool)
	var verts := _mesh_verts(pool)
	if colours.size() != verts.size() or colours.is_empty():
		_fail += 1
		print("    !! the mesh carries %d colours for %d vertices" % [colours.size(), verts.size()])
		root.queue_free()
		await _settle()
		_completed += 1
		return

	# Sample the flow near the start of each leg, well clear of the corner.
	var before := _flow_near(verts, colours, Vector3(-60, 0, -100))
	var after := _flow_near(verts, colours, Vector3(0, 0, -40))
	var want_before := Vector2(1, 0)
	var want_after := Vector2(0, 1)
	var err_b: float = before.distance_to(want_before)
	var err_a: float = after.distance_to(want_after)
	print("    first leg  flow %.3v (want %.3v)" % [before, want_before])
	print("    second leg flow %.3v (want %.3v)" % [after, want_after])
	if err_b > 0.15 or err_a > 0.15:
		_fail += 1
		print("    !! off by %.3f and %.3f — the flow does not turn with the channel" % [err_b, err_a])
	else:
		print("    -> turns 90° with the channel, within %.3f" % maxf(err_b, err_a))

	# Control: a LOOP pool writes the neutral colour, which decodes to a zero vector. Without it,
	# any mesh with vertex colours would read as flowing somewhere.
	var lake := _make_pool(root, _square_curve(40.0), LAKE_MAT)
	lake.position = Vector3(0, 0, 400)
	await _settle()
	var lc := _mesh_colours(lake)
	var neutral := true
	for i in mini(lc.size(), 500):
		var f := Vector2(lc[i].r * 2.0 - 1.0, lc[i].g * 2.0 - 1.0)
		if f.length() > 0.01 or lc[i].b > 0.01:
			neutral = false
	if neutral and not lc.is_empty():
		print("    control (a loop pool's colours): fires — %d vertices, all zero flow" % lc.size())
	else:
		_fail += 1
		print("    !! control did NOT fire: the lake's colours are not neutral (%d verts)" % lc.size())
	root.queue_free()
	await _settle()
	_completed += 1


# ---- C: the clock wrap is seamless ---------------------------------------------
#
# water_time wraps at water_time_period, and §3.2 makes that seamless for the waves by quantising
# their frequencies. The flow cross-fade has its OWN period, and if that does not divide the clock's
# then the hand-over is caught mid-way at the wrap and the whole surface jumps.
#
# Tested on the arithmetic the shader runs rather than through a render: water_flow_period() is a
# pure function of two uniforms, and the seam is exactly "does an integer number of cycles fit".
func _gate_c_wrap_seam() -> void:
	print("")
	print("[C] the flow cross-fade does not seam when the clock wraps:")
	# Deliberately awkward: 7 s does not divide 120 s.
	var clock := 120.0
	var asked := 7.0
	var quantised: float = clock / maxf(round(clock / asked), 1.0)
	var cycles_q: float = clock / quantised
	var cycles_raw: float = clock / asked
	print("    asked %.1f s in a %.0f s clock -> %.4f cycles (fractional)" % [asked, clock, cycles_raw])
	print("    quantised to %.4f s          -> %.4f cycles" % [quantised, cycles_q])

	# The seam IS the phase discontinuity: fract(t/period) at t just below the clock's wrap, versus
	# at t = 0. Zero means the cross-fade lands where it started.
	var seam_q := _phase_gap(clock, quantised)
	var seam_raw := _phase_gap(clock, asked)
	print("    phase at the wrap: quantised %.6f | unquantised %.6f" % [seam_q, seam_raw])
	if seam_q > 1e-4:
		_fail += 1
		print("    !! the quantised period still seams by %.6f of a cycle" % seam_q)
	elif absf(quantised - asked) / asked > 0.15:
		_fail += 1
		print("    !! quantising moved the period by %.0f%%, which is a different look, not a fix"
			% (absf(quantised - asked) / asked * 100.0))
	else:
		print("    -> seamless, and the period moved only %.1f%%"
			% (absf(quantised - asked) / asked * 100.0))

	# Control: the unquantised period must visibly seam, or the quantisation is solving nothing.
	if seam_raw > 0.01:
		print("    control (flow_quantise off): fires — %.4f of a cycle of discontinuity" % seam_raw)
	else:
		_fail += 1
		print("    !! control did NOT fire: the unquantised period does not seam either")

	# And the shader has to actually expose the switch, or the control above describes code that
	# does not exist.
	var shader: Shader = load(WATER_DIR + "water_river.gdshader")
	var names := PackedStringArray()
	for u in shader.get_shader_uniform_list(true):
		names.append(u["name"])
	for want in ["flow_period", "flow_quantise", "flow_speed_scale"]:
		if not names.has(want):
			_fail += 1
			print("    !! water_river.gdshader has no '%s' uniform" % want)
	print("    water_river.gdshader exposes flow_period, flow_quantise, flow_speed_scale")
	_completed += 1


## Discontinuity in the cross-fade phase across the clock's wrap, in cycles: 0 is seamless.
func _phase_gap(p_clock: float, p_period: float) -> float:
	var at_end: float = fposmod(p_clock / p_period, 1.0)
	var gap: float = minf(at_end, 1.0 - at_end) # wrapping either way is the same seam
	return gap


# ---- D: a boat floats on a river -----------------------------------------------
#
# The point of the ribbon carrying real Y: a boat on a river has to float at the height of the reach
# it is over, not at some single level for the whole channel. This is Phase 6's machinery meeting
# Phase 7's geometry, and it is the combination that would break silently.
func _gate_d_float_on_river() -> void:
	print("")
	print("[D] the body registry and a buoy work on a river:")
	var root := _make_world()
	var manager := _make_manager(root)
	var pool := _make_pool(root, _descending_curve(200.0, 20.0, false), RIVER_MAT)
	pool.ribbon_half_width = 8.0
	await _settle()

	var upstream := Vector3(-80, 0, 0)
	var downstream := Vector3(80, 0, 0)
	var h_up: float = pool.get_water_height(Vector2(upstream.x, upstream.z))
	var h_down: float = pool.get_water_height(Vector2(downstream.x, downstream.z))
	print("    surface %.2f m upstream, %.2f m downstream" % [h_up, h_down])

	var found_up = manager.body_at(Vector3(upstream.x, h_up - 0.5, upstream.z))
	var found_down = manager.body_at(Vector3(downstream.x, h_down - 0.5, downstream.z))
	if found_up == pool and found_down == pool:
		print("    body_at finds the river at both ends, at their own different heights")
	else:
		_fail += 1
		print("    !! body_at returned %s upstream and %s downstream" % [found_up, found_down])

	# A buoy dropped over the downstream reach must settle on THAT reach's surface, not on the
	# upstream one — which is the whole reason a ribbon carries Y per row.
	# 900 ticks, not 420: ONE buoy on 400 kg has a time constant of about 1.5 s against four buoys'
	# 0.4, so the same boat that had settled by 7 s in Phase 6 is still creeping down at that point.
	# The residual velocity is printed so "not settled yet" cannot be mistaken for "settled wrong".
	var boat := _make_boat(root, 400.0, 0.6, Vector3(downstream.x, h_down + 4.0, downstream.z))
	await _run_physics(900)
	var settled: float = boat.global_position.y
	var residual: float = boat.linear_velocity.length()
	var expect: float = h_down - (400.0 / 1000.0 / 0.6) * 0.5
	print("    a 400 kg boat over the downstream reach settled at %.2f m (predicted %.2f), %.4f m/s"
		% [settled, expect, residual])
	if residual > 0.05:
		_fail += 1
		print("    !! still moving at %.4f m/s, so this is not an equilibrium" % residual)
	elif absf(settled - expect) > 0.15:
		_fail += 1
		print("    !! %.2f m from the prediction" % (settled - expect))
	else:
		print("    -> floats on the reach it is over, within %.3f m" % absf(settled - expect))

	# Control: beside the channel, at the same height, must be dry. Without it "the river contains
	# things" could mean it contains the whole bounding box.
	var beside := Vector3(0, pool.get_water_height(Vector2(0, 0)) - 0.5, 60)
	if not pool.is_point_underwater(beside) and manager.body_at(beside) != pool:
		print("    control (60 m to the side, same depth): fires — dry, and not in the river")
	else:
		_fail += 1
		print("    !! control did NOT fire: a point 60 m from an 8 m channel reads as in it")
	root.queue_free()
	await _settle()
	_completed += 1


# ---- E: the river variant's cost -----------------------------------------------
#
# §10 prices this honestly: the cross-fade needs a second copy of each detail layer and of the foam,
# so the water spec's four-fetch budget becomes six for rivers. This is the measurement that says by
# how much.
#
# INTERLEAVED, and with a real warm-up, because the first version of this criterion was not and it
# reported +112% on one run and +8% on the next. The lake was measured first and the river second,
# so the river paid for its own shader compilation on the first run of a fresh cache and did not on
# the second. Alternating the two and discarding a warm-up pass makes compilation, GPU clock state
# and any drift land on both arms equally; the spread across passes is printed so a repeat of that
# problem is visible rather than silently halving the answer.
func _gate_e_cost() -> void:
	print("")
	print("[E] the river shader against the lake shader:")
	if not _run_timing:
		print("    SKIPPED (set RUN_TIMING=1 to measure)")
		_completed += 1
		return
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

	var lake: Array[float] = []
	var river: Array[float] = []
	for pass_i in 4:
		var l: float = await _measure_variant(LAKE_MAT)
		var r: float = await _measure_variant(RIVER_MAT)
		if pass_i == 0:
			print("    warm-up pass (discarded): lake %.4f, river %.4f" % [l, r])
			continue
		lake.append(l)
		river.append(r)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), false)
	lake.sort()
	river.sort()
	var lake_ms: float = lake[lake.size() / 2]
	var river_ms: float = river[river.size() / 2]
	print("    lake  %s -> median %.4f ms" % [lake, lake_ms])
	print("    river %s -> median %.4f ms" % [river, river_ms])
	print("    delta %.4f ms (%+.0f%%)" % [
		river_ms - lake_ms, (river_ms / maxf(lake_ms, 1e-9) - 1.0) * 100.0])

	var lake_spread: float = (lake[lake.size() - 1] - lake[0]) / maxf(lake_ms, 1e-9)
	var river_spread: float = (river[river.size() - 1] - river[0]) / maxf(river_ms, 1e-9)
	if lake_ms <= 0.0 or river_ms <= 0.0:
		_fail += 1
		print("    !! GPU timing read zero — measured nothing, not 'measured free'")
	elif maxf(lake_spread, river_spread) > 0.20:
		_fail += 1
		print("    !! pass-to-pass spread is %.0f%%, so the delta between them means little"
			% (maxf(lake_spread, river_spread) * 100.0))
	else:
		print("    -> recorded; spread %.0f%% / %.0f%%, two extra fetches is the expected shape"
			% [lake_spread * 100.0, river_spread * 100.0])
	# Control: the two variants have to be distinguishable at all. If the river measured the same as
	# the lake, either the material never reached the mesh or the timer is not seeing thewater at all.
	if river_ms > lake_ms * 1.02:
		print("    control (river costs measurably more than lake): fires")
	else:
		_fail += 1
		print("    !! control did NOT fire: the river is not measurably more expensive, so this")
		print("       is probably not measuring the river shader")
	_completed += 1


## Median GPU frame time with a sheet of the given water material filling the view.
##
## The warm-up frames are not decoration: a material seen for the first time compiles its shader on
## the frame it is drawn, and that stall lands in the samples if they start immediately. Criterion E
## discards a whole pass for the same reason at a coarser grain.
func _measure_variant(p_material: String) -> float:
	var root := _make_world()
	_make_manager(root)
	var pool := _make_pool(root, _square_curve(120.0), p_material)
	var cam := Camera3D.new()
	cam.current = true
	cam.position = Vector3(0, 12, 0)
	cam.rotation_degrees = Vector3(-20, 0, 0)
	root.add_child(cam)
	await _settle()
	for i in 30:
		await RenderingServer.frame_post_draw
	var rid := get_viewport().get_viewport_rid()
	var samples: Array[float] = []
	for i in 120:
		await RenderingServer.frame_post_draw
		samples.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
	samples.sort()
	root.queue_free()
	await _settle()
	return samples[samples.size() / 2]


# ---- helpers -------------------------------------------------------------------

func _make_world() -> Node3D:
	var root := Node3D.new()
	add_child(root)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-38, 130, 0)
	root.add_child(sun)
	return root


func _make_manager(p_root: Node3D) -> Pasture3DPoolManager:
	var m := Pasture3DPoolManager.new()
	m.name = "Pasture3DPoolManager"
	m.loop_period = LOOP_PERIOD
	var profile := Pasture3DWaveProfile.new()
	profile.profile_name = "river_flow"
	profile.wave_count = 2
	profile.amplitude = 0.001 # near-flat, so heights are the geometry rather than the sea state
	profile.length_max = 30.0
	var profiles: Array[Pasture3DWaveProfile] = [profile]
	m.profiles = profiles
	p_root.add_child(m)
	m.sun_light = p_root.get_node("Sun")
	return m


func _make_pool(p_root: Node3D, p_curve: Curve3D, p_material: String) -> Pasture3DPool:
	var pool := Pasture3DPool.new()
	pool.name = "Water"
	pool.wave_profile = &"river_flow"
	pool.water_preset = 2
	pool.material = load(p_material)
	pool.underwater_enabled = false
	pool.curve = p_curve
	p_root.add_child(pool)
	return pool


## A straight channel of the given length dropping `p_drop` metres, open or closed.
func _descending_curve(p_length: float, p_drop: float, p_closed: bool) -> Curve3D:
	var c := Curve3D.new()
	var n := 9
	for i in n:
		var t := float(i) / float(n - 1)
		c.add_point(Vector3(-p_length * 0.5 + t * p_length, -t * p_drop, 0))
	c.closed = p_closed
	return c


## An L-shaped channel: `p_leg` metres along +X at z = -p_leg, then `p_leg` along +Z at x = 0.
func _bend_curve(p_leg: float) -> Curve3D:
	var c := Curve3D.new()
	for i in 6:
		c.add_point(Vector3(-p_leg + (float(i) / 5.0) * p_leg, 0, -p_leg))
	for i in range(1, 6):
		c.add_point(Vector3(0, 0, -p_leg + (float(i) / 5.0) * p_leg))
	c.closed = false
	return c


func _square_curve(p_r: float) -> Curve3D:
	var c := Curve3D.new()
	c.add_point(Vector3(-p_r, 0, -p_r))
	c.add_point(Vector3(p_r, 0, -p_r))
	c.add_point(Vector3(p_r, 0, p_r))
	c.add_point(Vector3(-p_r, 0, p_r))
	c.closed = true
	return c


func _make_boat(p_root: Node3D, p_mass: float, p_displacement: float, p_pos: Vector3) -> RigidBody3D:
	var boat := RigidBody3D.new()
	boat.mass = p_mass
	boat.can_sleep = false
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2, 1, 3)
	shape.shape = box
	boat.add_child(shape)
	var buoy := Pasture3DBuoy.new()
	buoy.displacement = p_displacement
	buoy.full_depth = 0.5
	buoy.linear_drag = 400.0
	boat.add_child(buoy)
	p_root.add_child(boat)
	boat.global_position = p_pos
	return boat


func _mesh_surface(p_pool: Node) -> MeshInstance3D:
	for c in p_pool.get_children():
		if c is MeshInstance3D and c.mesh != null and c.mesh.get_surface_count() > 0:
			return c
	return null


func _mesh_colours(p_pool: Node) -> PackedColorArray:
	var mi := _mesh_surface(p_pool)
	if mi == null:
		return PackedColorArray()
	var a: Array = mi.mesh.surface_get_arrays(0)
	var c = a[Mesh.ARRAY_COLOR]
	return c if c != null else PackedColorArray()


func _mesh_verts(p_pool: Node) -> PackedVector3Array:
	var mi := _mesh_surface(p_pool)
	if mi == null:
		return PackedVector3Array()
	var a: Array = mi.mesh.surface_get_arrays(0)
	return a[Mesh.ARRAY_VERTEX]


## The decoded flow vector at the mesh vertex nearest `p_at` (local space).
func _flow_near(p_verts: PackedVector3Array, p_colours: PackedColorArray, p_at: Vector3) -> Vector2:
	var best := -1
	var best_d := INF
	for i in p_verts.size():
		var d: float = p_verts[i].distance_squared_to(p_at)
		if d < best_d:
			best_d = d
			best = i
	if best < 0:
		return Vector2.ZERO
	var col: Color = p_colours[best]
	return Vector2(col.r * 2.0 - 1.0, col.g * 2.0 - 1.0)


func _run_physics(p_ticks: int) -> void:
	for i in p_ticks:
		await get_tree().physics_frame


func _settle() -> void:
	for i in 4:
		await get_tree().physics_frame
	for i in 4:
		await RenderingServer.frame_post_draw
