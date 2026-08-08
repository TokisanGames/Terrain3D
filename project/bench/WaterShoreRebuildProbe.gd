# Pasture3D Water — shore rebuild probe (prototype, water LOD work).
#
# The shore-edge probe answered whether a masked sheet LOOKS right. This one answers
# whether it can be AUTHORED: a brush drags its spline, the outline changes, and something
# has to be rebuilt before the next frame the user sees. Today that something is the mesh.
# Under the mask plan it is the distance field, and if baking the field costs more than
# meshing did then the plan has moved the cost rather than removed it.
#
# The naive baker the edge probe used is O(texels x segments) and cannot answer this: a
# 1.4 km lake at 1.5 m texels is 870 k texels against ~800 segments. Timing the plan
# against that would be timing a strawman, so shore_sdf.gd carries a banded baker -- exact
# distance only where the feather reads it, a chamfer sweep for the rest -- and the first
# thing measured here is whether the fast one and the oracle put the waterline in the same
# place. A baker that is quick because it is wrong is the failure this is built to catch.
#
# CRITERIA
#   A. the banded baker matches the oracle AT THE WATERLINE, on the same fixture and the
#      same instrument the edge probe used. Control: a bake with the exact band removed
#      entirely -- pure chamfer off a binary mask -- which must fail.
#   B. the motivating fact still holds: today's mesher refuses a 1.4 km lake at automatic
#      spacing, and says so.
#   C. rebuild cost, mesh vs field, across three body sizes. Reported with the mesh path
#      forced to actually build (max_vertices raised) so the comparison is like for like.
#   D. memory, same three sizes.
#
# TIMINGS ARE CPU-SIDE GDSCRIPT, median of several samples, taken on a machine that may be
# running other things. They are here to separate "milliseconds" from "seconds", not to be
# quoted to three figures.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/WaterShoreRebuildProbe.tscn
extends Node

const SDF := preload("res://bench/shore_sdf.gd")
const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const LAKE_MAT := WATER_DIR + "M_water_lake.tres"

## Texels per metre for the shipping bake. The edge probe put the accuracy budget at
## texels <= ~1.5 m; this is that bound, not a comfortable margin inside it, so the cost
## reported is the cost of the field that actually meets the budget.
const SDF_TEXEL := 1.5
const SDF_RANGE := 24.0
const FEATHER := 0.5
## Samples per timing. Odd, so the median is a real sample.
const SAMPLES := 3

# Criterion A re-uses the edge probe's fixture and instrument.
const IMG := 1024
const PAD := 28.0
const SPACING_MID := 5.0

var _fail := 0
var _completed := 0
const CRITERIA := 4

var _poly := PackedVector2Array()
var _view_min := Vector2.ZERO
var _view_size := 0.0
var _mpp := 0.0
var _truth := PackedByteArray()
var _truth_area := 0


func _ready() -> void:
	var bail := Timer.new()
	bail.wait_time = 1800.0
	bail.one_shot = true
	bail.timeout.connect(func():
		push_error("probe timed out")
		get_tree().quit(2))
	add_child(bail)
	bail.start()

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.global_shader_parameter_set("water_time", 0.0)
	RenderingServer.global_shader_parameter_set("water_time_period", 120.0)

	print("=== Pasture3D — shore rebuild probe ===")
	print("Godot %s | %s" % [
		Engine.get_version_info().string, RenderingServer.get_video_adapter_name()])
	print("timings are CPU-side GDScript, median of %d" % SAMPLES)
	print("")

	await _criterion_a_banded_is_honest()
	await _criterion_b_the_motivating_refusal()
	await _criterion_c_rebuild_cost()
	_criterion_d_memory()

	print("")
	print("completed %d/%d criteria, %d failures" % [_completed, CRITERIA, _fail])
	if _completed < CRITERIA:
		print("!! a criterion did not run to completion -- treat as FAIL")
	print("VERDICT: %s" % ("PASS" if _fail == 0 and _completed == CRITERIA else "FAIL"))
	get_tree().quit(1 if (_fail > 0 or _completed < CRITERIA) else 0)


# ---- fixture (the edge probe's outline, so the two probes are comparable) ------

func _ellipse(p_angle: float, p_scale: float = 1.0) -> Vector2:
	return Vector2(cos(p_angle) * 52.0, sin(p_angle) * 41.0) * p_scale


func _test_outline(p_scale: float = 1.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
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
			pts.append(_ellipse(inlet_at - deg_to_rad(2.2), p_scale))
			pts.append(_ellipse(inlet_at - deg_to_rad(2.2), p_scale) * 0.62)
			pts.append(_ellipse(inlet_at + deg_to_rad(2.2), p_scale) * 0.62)
			pts.append(_ellipse(inlet_at + deg_to_rad(2.2), p_scale))
			inlet_done = true
			continue
		if not head_done and a >= head_at:
			pts.append(_ellipse(head_at, p_scale) * 1.34)
			head_done = true
			continue
		pts.append(_ellipse(a, p_scale))
	return pts


func _bounds_of(p_poly: PackedVector2Array) -> Array:
	var mn := p_poly[0]
	var mx := p_poly[0]
	for v in p_poly:
		mn = Vector2(minf(mn.x, v.x), minf(mn.y, v.y))
		mx = Vector2(maxf(mx.x, v.x), maxf(mx.y, v.y))
	return [mn, mx]


## The outline as a closed Curve3D, so a real Pasture3DPool can be pointed at it.
func _curve_of(p_poly: PackedVector2Array) -> Curve3D:
	var c := Curve3D.new()
	for v in p_poly:
		c.add_point(Vector3(v.x, 0.0, v.y))
	c.closed = true
	return c


func _median(p_v: Array) -> float:
	p_v.sort()
	return p_v[p_v.size() / 2]


# ---- A: is the fast baker honest? --------------------------------------------

func _criterion_a_banded_is_honest() -> void:
	print("[A] the banded baker vs the oracle, at the waterline:")
	_poly = _test_outline()
	var b := _bounds_of(_poly)
	var extent: float = maxf(b[1].x - b[0].x, b[1].y - b[0].y) + PAD * 2.0
	_view_size = extent
	_view_min = (b[0] + b[1]) * 0.5 - Vector2(extent, extent) * 0.5
	_mpp = _view_size / float(IMG)
	_truth = SDF.inside_mask(_poly, _view_min + Vector2(0.5, 0.5) * _mpp, _mpp, IMG, IMG)
	_truth_area = 0
	for byte in _truth:
		_truth_area += int(byte)

	var bakes := {
		"oracle (exact everywhere)": SDF.bake(_poly, _view_min, _view_size, 1.0,
			Image.FORMAT_RF, SDF_RANGE, false),
		"banded (exact band 2)": SDF.bake(_poly, _view_min, _view_size, 1.0,
			Image.FORMAT_RF, SDF_RANGE, true, 2),
		# The control. No exact band at all, so every texel's distance comes from the
		# chamfer over a BINARY mask, which cannot know where inside a texel the shore
		# runs. This is the same information loss the hard cut had, arriving by a
		# different route, and it must show up as a worse waterline.
		"CONTROL band 0 (chamfer only)": SDF.bake(_poly, _view_min, _view_size, 1.0,
			Image.FORMAT_RF, SDF_RANGE, true, 0),
	}

	var vp := _make_ortho_viewport()
	var mi := MeshInstance3D.new()
	mi.extra_cull_margin = 64.0
	mi.mesh = _sheet_mesh(SPACING_MID)
	vp.add_child(mi)

	var scores := {}
	for name in bakes.keys():
		var bake: Dictionary = bakes[name]
		var mat := ShaderMaterial.new()
		mat.shader = _coverage_shader()
		_apply_shore(mat, bake, SPACING_MID)
		mi.material_override = mat
		for i in 4:
			await RenderingServer.frame_post_draw
		var s := SDF.score(vp.get_texture().get_image(), _truth, _poly, _view_min,
			_mpp, IMG, _truth_area)
		scores[name] = s
		print("    %-30s p99 %.3f m  max %.3f m   bake %6.0f ms (%d exact texels)" % [
			name, s["p99"], s["max"], bake["ms"], bake["exact_texels"]])
	vp.queue_free()

	var oracle: Dictionary = scores["oracle (exact everywhere)"]
	var banded: Dictionary = scores["banded (exact band 2)"]
	var control: Dictionary = scores["CONTROL band 0 (chamfer only)"]

	# Same waterline, not merely a similar one: the band covers every texel the feather
	# can reach, so the two fields are identical everywhere the ramp reads them and the
	# rendered edge should agree to the instrument floor.
	var delta: float = absf(banded["p99"] - oracle["p99"])
	if delta > _mpp:
		_fail += 1
		print("    !! banded differs from the oracle by %.3f m -- it is fast because it" % delta)
		print("       is wrong, and criterion C is timing the wrong thing")
	else:
		print("    -> banded matches the oracle to %.4f m (floor %.4f m)" % [delta, _mpp])
	if control["p99"] <= banded["p99"] * 1.5:
		_fail += 1
		print("    !! the control did not degrade -- this comparison cannot see the")
		print("       difference the exact band makes, so the match above proves nothing")
	else:
		print("    -> control degrades to %.3f m (%.1fx), so the band is load-bearing" % [
			control["p99"], control["p99"] / maxf(banded["p99"], 1e-4)])
	_completed += 1


# ---- B: the fact that started this -------------------------------------------

func _criterion_b_the_motivating_refusal() -> void:
	print("[B] today's mesher on a 1.4 km lake at automatic spacing:")
	var root := _make_scene()
	var pool := _make_pool(root, _curve_of(_test_outline(13.5)))
	# PINNED to MESHED, because surface_mode defaults to AUTO and now rescues a body this size --
	# which is the feature working, and would turn this criterion into a green light that the
	# problem never existed. It is asserting something about the MESHED path specifically.
	pool.surface_mode = pool.SurfaceMode.MESHED
	await get_tree().process_frame
	var stats := pool.rebuild()
	print("    spacing %.2f m -> ok=%s" % [stats.get("spacing", 0.0), stats.get("ok", false)])
	print("    reason: %s" % stats.get("reason", ""))
	var refused: bool = not stats.get("ok", false) \
		and str(stats.get("reason", "")).contains("max_vertices")
	if not refused:
		_fail += 1
		print("    !! it did NOT refuse -- the premise of this whole exercise has changed")
		print("       and the plan should be re-argued before it is built")
	else:
		print("    -> refuses, as reported. This is the problem being solved.")
	root.queue_free()
	_completed += 1


# ---- C: what a spline drag costs ---------------------------------------------

func _criterion_c_rebuild_cost() -> void:
	print("[C] rebuild cost per edit, mesh vs field:")
	print("    %-10s %9s %12s %12s %12s %10s" % [
		"span", "spacing", "mesh build", "field (gd)", "field (C++)", "verts"])
	var results := {}
	for spec in [[104.0, 1.0], [500.0, 4.8], [1400.0, 13.5]]:
		var span: float = spec[0]
		var poly := _test_outline(spec[1])
		var root := _make_scene()
		var pool := _make_pool(root, _curve_of(poly))
		# MESHED and a raised ceiling: the mode so this times the mesher rather than the masked
		# sheet AUTO would pick at these sizes, and the ceiling so the mesher actually BUILDS
		# rather than refusing. Timing a refusal against a bake would report today's path as
		# instant; timing the masked path against the field would compare it with itself.
		pool.surface_mode = pool.SurfaceMode.MESHED
		pool.max_vertices = 40000000
		await get_tree().process_frame

		var mesh_ms := []
		var verts := 0
		var spacing := 0.0
		for i in SAMPLES:
			var st := pool.rebuild()
			mesh_ms.append(st.get("ms", 0.0))
			verts = st.get("vertices", 0)
			spacing = st.get("spacing", 0.0)
			await get_tree().process_frame

		var b := _bounds_of(poly)
		var extent: float = maxf(b[1].x - b[0].x, b[1].y - b[0].y) + PAD * 2.0
		var vmin: Vector2 = (b[0] + b[1]) * 0.5 - Vector2(extent, extent) * 0.5
		var bake_ms := []
		var bake := {}
		for i in SAMPLES:
			bake = SDF.bake(poly, vmin, extent, SDF_TEXEL, Image.FORMAT_R8, SDF_RANGE, true, 2)
			bake_ms.append(bake["ms"])
		# The one that would actually run on a spline drag.
		var native_ms := []
		var native := {}
		for i in SAMPLES:
			native = SDF.bake_native(poly, vmin, extent, SDF_TEXEL, SDF_RANGE)
			native_ms.append(native.get("ms", INF))

		var m := _median(mesh_ms)
		var f := _median(bake_ms)
		var nf := _median(native_ms)
		print("    %-10s %8.2fm %10.0f ms %10.0f ms %10.1f ms %10d" % [
			"%.0f m" % span, spacing, m, f, nf, verts])
		print("       %s field: %d^2 texels, %.2f MB, %d exact (mask %.0f / dist %.0f / encode %.0f ms)" % [
			" ".repeat(0), bake["texels"], float(bake["bytes"]) / 1048576.0,
			bake["exact_texels"], bake["ms_mask"], bake["ms_dist"], bake["ms_encode"]])
		results[span] = {"mesh": m, "field": f, "native": nf, "verts": verts, "bake": bake}
		root.queue_free()
		await get_tree().process_frame

	# The claim under test is that the field scales with the SHORE and the mesh with the
	# AREA, so the gap should widen with size rather than being a constant offset.
	var small: Dictionary = results[104.0]
	var big: Dictionary = results[1400.0]
	var mesh_growth: float = big["mesh"] / maxf(small["mesh"], 1e-3)
	var field_growth: float = big["field"] / maxf(small["field"], 1e-3)
	print("    13.5x span: mesh cost x%.1f, field cost x%.1f" % [mesh_growth, field_growth])
	if field_growth >= mesh_growth:
		_fail += 1
		print("    !! the field is not scaling better than the mesh, which is the only")
		print("       reason to prefer it here")
	# The number that decides whether a spline drag is interactive. The brushes debounce at
	# 0.1 s, so a rebuild inside that budget disappears into the debounce.
	var worst_native: float = big["native"]
	print("    C++ bake on the 1400 m body: %.1f ms against the brushes' %.0f ms debounce" % [
		worst_native, 100.0])
	if worst_native > 100.0:
		_fail += 1
		print("    !! a spline drag would not keep up: the bake outlasts the debounce that")
		print("       is supposed to hide it")
	_completed += 1


# ---- D: what it costs to hold ------------------------------------------------

func _criterion_d_memory() -> void:
	print("[D] resident cost:")
	print("    %-10s %12s %14s %12s" % ["span", "verts", "mesh >=24B/v", "field (R8)"])
	var ok := true
	for spec in [[104.0, 1.0], [500.0, 4.8], [1400.0, 13.5]]:
		var poly := _test_outline(spec[1])
		var b := _bounds_of(poly)
		var extent: float = maxf(b[1].x - b[0].x, b[1].y - b[0].y) + PAD * 2.0
		var n := int(ceil(extent / SDF_TEXEL))
		# Vertices the CURRENT path would produce: the bounding lattice, filtered by the
		# inside mask, which is what pool.gd actually emits. Counted rather than timed, so
		# this needs no build.
		var vmin: Vector2 = (b[0] + b[1]) * 0.5 - Vector2(extent, extent) * 0.5
		var gw := int(ceil(extent / 1.27)) + 1
		var mask := SDF.inside_mask(poly, vmin, 1.27, gw, gw)
		var inside := 0
		for byte in mask:
			inside += int(byte)
		var mesh_mb := float(inside) * 24.0 / 1048576.0
		var field_mb := float(n * n) / 1048576.0
		print("    %-10s %12d %11.1f MB %9.2f MB" % [
			"%.0f m" % spec[0], inside, mesh_mb, field_mb])
		if field_mb > mesh_mb:
			ok = false
	if not ok:
		_fail += 1
		print("    !! the field is not smaller than the mesh it replaces")
	else:
		print("    -> the field is smaller at every size measured")
	_completed += 1


# ---- plumbing ----------------------------------------------------------------

func _make_scene() -> Node3D:
	var root := Node3D.new()
	add_child(root)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	root.add_child(sun)
	var m := Pasture3DPoolManager.new()
	m.name = "Pasture3DPoolManager"
	# The shipped defaults are seeded in the constructor, so lake_calm is already here
	# with the length_max 25 m that produces the 1.27 m spacing this is all about.
	root.add_child(m)
	m.sun_light = sun
	return root


func _make_pool(p_root: Node3D, p_curve: Curve3D) -> Pasture3DPool:
	var pool := Pasture3DPool.new()
	pool.name = "Pool"
	pool.curve = p_curve
	pool.wave_profile = &"lake_calm"
	pool.material = load(LAKE_MAT)
	# Off: it raises an Area3D and a FogVolume per rebuild, which is real cost in the
	# editor but is not the meshing this criterion is comparing.
	pool.underwater_enabled = false
	p_root.add_child(pool)
	return pool


func _make_ortho_viewport() -> SubViewport:
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
	cam.size = _view_size
	cam.near = 1.0
	cam.far = 500.0
	cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	cam.position = Vector3(_view_min.x + _view_size * 0.5, 100.0,
		_view_min.y + _view_size * 0.5)
	cam.current = true
	vp.add_child(cam)
	return vp


func _sheet_mesh(p_spacing: float) -> ArrayMesh:
	var n := int(ceil(_view_size / p_spacing)) + 1
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for iz in n:
		for ix in n:
			verts.append(Vector3(_view_min.x + ix * p_spacing, 0.0,
				_view_min.y + iz * p_spacing))
	for iz in n - 1:
		for ix in n - 1:
			var a := iz * n + ix
			idx.append_array([a, a + n, a + 1, a + 1, a + n, a + n + 1])
	var normals := PackedVector3Array()
	normals.resize(verts.size())
	normals.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
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
