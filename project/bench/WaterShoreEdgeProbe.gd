# Pasture3D Water — shore-edge probe (prototype, water LOD work).
#
# ONE QUESTION. A large lake cannot be meshed at wave resolution -- a 1.4 km body at
# lake_calm's automatic 1.27 m spacing wants 1.2 M vertices and the build refuses. The
# fix under consideration is to stop meshing the outline at all: draw a camera-centred
# clipmap sheet, and cut it to the body with a signed distance field baked from the same
# polygon Pasture3DPool would have clipped against.
#
# Everything else about that plan is already known to work -- Pasture3DMesher is shared,
# host-agnostic and pixel-verified, and the CPU queries never touch the mesh. The one
# thing that is genuinely at risk is the RIM. Today Pasture3DPool clips boundary cells
# exactly (Geometry2D.intersect_polygons, pool.gd), so the waterline is the polygon. A
# masked sheet instead lands the waterline wherever the SDF and the alpha ramp put it,
# on a grid that has no reason to align with the shore.
#
# So this measures exactly that and nothing else: how far, in metres, each candidate's
# waterline sits from the true outline.
#
# CRITERIA
#   A. instrument floor -- the exact-clip mesh must score near zero. Validates the
#      world->pixel mapping at the same time: a flipped axis puts A off the scale.
#   B. accuracy -- every masked case within 0.25 m P99 (an eighth of the 2 m edge_offset
#      that buries the rim in the bank).
#   C. spacing independence -- the hypothesis. Mask cases at 5 m and 10 m mesh spacing
#      must stay within 1.5x of the 1.27 m case, because the feather is per-fragment and
#      should not care what the mesh is doing.
#   D. control -- a hard texel-quantised cut at the SAME spacing and SAME field must be
#      at least 4x worse. If it is not, this metric cannot see shore quality and every
#      number above it is meaningless.
#   E. anti-null -- the SDF is non-degenerate, every capture has plausible coverage, all
#      captures differ, and every PNG write is verified by reading the file back.
#
# Criteria that ran to completion are counted, so a sub-test that throws cannot read as
# a pass. Metric is geometric coverage under an unlit flat readout -- never a shaded
# diff, which on near-mirror water measures highlight placement instead of geometry.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/WaterShoreEdgeProbe.tscn
#      BENCH_OUT=<dir> to place the captures somewhere other than user://.
extends Node

const SDF := preload("res://bench/shore_sdf.gd")
const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"

## Analysis resolution. Square, so one metres-per-pixel serves both axes.
const IMG := 1024
## Metres the analysed rect is grown past the outline. Must exceed SDF_RANGE so the
## border texel of the field reads as "well outside" and a sheet running past the bake
## ends rather than smearing the last texel outward.
const PAD := 28.0
## Metres encoded at the ends of the SDF. Has to exceed the COARSEST case's vertex kill
## margin (see _kill_margin), or the clamped field can never report far enough out for a
## vertex to be killed and the geometric half of the cut goes silently inert.
const SDF_RANGE := 24.0
## Metres per SDF texel, default bake.
const SDF_TEXEL := 1.0
## Alpha ramp width in metres, centred on the outline.
const FEATHER := 0.5

## Automatic spacing for lake_calm: min wavelength 10.16 m / 8. The LOD0 case.
const SPACING_LOD0 := 1.27
## Representative of a clipmap LOD2 / LOD3 at that base spacing.
const SPACING_MID := 5.0
const SPACING_COARSE := 10.0

const ACCURACY_BUDGET_M := 0.25
const SPACING_TOLERANCE := 1.5
const CONTROL_RATIO := 4.0

var _fail := 0
var _completed := 0
const CRITERIA := 5
var _out_dir := ""

# Filled by _prepare(); read by every criterion.
var _poly := PackedVector2Array()
var _view_min := Vector2.ZERO
var _view_size := 0.0
var _mpp := 0.0
## Ground truth: 1 where the pixel centre is inside _poly. IMG x IMG.
var _truth := PackedByteArray()
var _truth_area := 0
var _native_mask := false
## name -> Dictionary of scores, so the criteria can cross-reference each other.
var _scores := {}
var _shots := {}


func _ready() -> void:
	var bail := Timer.new()
	bail.wait_time = 900.0
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
	# The waves are frozen for every capture. This probe measures a waterline, and a
	# waterline that is being displaced differently between two captures is a second
	# variable in a test that is meant to have one.
	RenderingServer.global_shader_parameter_set("water_time", 0.0)
	RenderingServer.global_shader_parameter_set("water_time_period", 120.0)

	print("=== Pasture3D — shore-edge probe ===")
	print("Godot %s | %s" % [
		Engine.get_version_info().string, RenderingServer.get_video_adapter_name()])
	print("out: %s" % ProjectSettings.globalize_path(_out_dir))
	print("")

	_prepare()
	await _run_cases()
	_criterion_a_floor()
	_criterion_b_accuracy()
	_criterion_c_spacing()
	_criterion_d_control()
	await _criterion_e_eyeball()

	print("")
	print("completed %d/%d criteria, %d failures" % [_completed, CRITERIA, _fail])
	if _completed < CRITERIA:
		print("!! a criterion did not run to completion -- treat as FAIL")
	print("VERDICT: %s" % ("PASS" if _fail == 0 and _completed == CRITERIA else "FAIL"))
	get_tree().quit(1 if (_fail > 0 or _completed < CRITERIA) else 0)


# ---- fixture -----------------------------------------------------------------

## The outline, chosen to stress a grid-aligned mask rather than to look like a lake.
##
## Four features, each a different way for a mask to be wrong:
##   - a smooth ellipse, where any quantisation shows as scalloping;
##   - a straight chord at 40 deg to the grid, the classic stair-step magnet;
##   - a 6 m inlet, NARROWER than the coarse mesh spacing -- the exact-clip mesher
##     resolves this because it clips boundary cells, and whether a masked sheet does
##     is the sharpest form of the question;
##   - a sharp headland, a convex corner an SDF rounds off if it is going to.
func _test_outline() -> PackedVector2Array:
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
		# Skipping the interior of the window leaves a straight run between its ends,
		# which is the chord -- no special-casing needed for the feature itself.
		if a > chord_a and a < chord_b:
			continue
		if not inlet_done and a >= inlet_at:
			# Mouth, apex, mouth: a narrow slot cut back toward the middle.
			pts.append(_ellipse(inlet_at - deg_to_rad(2.2)))
			pts.append(_ellipse(inlet_at - deg_to_rad(2.2)) * 0.62)
			pts.append(_ellipse(inlet_at + deg_to_rad(2.2)) * 0.62)
			pts.append(_ellipse(inlet_at + deg_to_rad(2.2)))
			inlet_done = true
			continue
		if not head_done and a >= head_at:
			pts.append(_ellipse(head_at) * 1.34)
			head_done = true
			continue
		pts.append(_ellipse(a))
	return pts


func _ellipse(p_angle: float) -> Vector2:
	return Vector2(cos(p_angle) * 52.0, sin(p_angle) * 41.0)


func _prepare() -> void:
	_poly = _test_outline()
	var mn := _poly[0]
	var mx := _poly[0]
	for v in _poly:
		mn = Vector2(minf(mn.x, v.x), minf(mn.y, v.y))
		mx = Vector2(maxf(mx.x, v.x), maxf(mx.y, v.y))
	# Square and padded: one ortho size, one metres-per-pixel, and room for the SDF's
	# border texel to sit outside everything.
	var extent: float = maxf(mx.x - mn.x, mx.y - mn.y) + PAD * 2.0
	var centre := (mn + mx) * 0.5
	_view_size = extent
	_view_min = centre - Vector2(extent, extent) * 0.5
	_mpp = _view_size / float(IMG)

	# Ground truth at pixel CENTRES, which is where the rendered coverage is sampled.
	_native_mask = ClassDB.class_exists("Pasture3DUtil") \
			and ClassDB.class_has_method("Pasture3DUtil", "build_inside_mask", true)
	_truth = SDF.inside_mask(_poly, _view_min + Vector2(0.5, 0.5) * _mpp, _mpp, IMG, IMG)
	_truth_area = 0
	for b in _truth:
		_truth_area += int(b)

	print("outline: %d points, bounds %.1f x %.1f m" % [
		_poly.size(), mx.x - mn.x, mx.y - mn.y])
	print("view:    %.1f m square, %.4f m/px at %d px  (measurement floor ~%.3f m)" % [
		_view_size, _mpp, IMG, _mpp])
	print("truth:   %d px inside (%.1f%% of frame), mask=%s" % [
		_truth_area, 100.0 * float(_truth_area) / float(IMG * IMG),
		"native" if _native_mask else "GDScript"])
	print("")


# ---- the signed distance field -----------------------------------------------

# ---- meshes ------------------------------------------------------------------

## Today's mesh: the grid clipped exactly to the outline. The reference.
func _exact_mesh(p_spacing: float) -> ArrayMesh:
	var mn := Vector2(
		floorf(_view_min.x / p_spacing) * p_spacing,
		floorf(_view_min.y / p_spacing) * p_spacing)
	var gw := int(ceil(_view_size / p_spacing)) + 2
	if ClassDB.class_exists("Pasture3DUtil") \
			and ClassDB.class_has_method("Pasture3DUtil", "build_pool_mesh", true):
		return Pasture3DUtil.build_pool_mesh(_poly, mn, p_spacing, gw, gw)
	return null


## A plain sheet over the whole view, knowing nothing about the outline. What a clipmap
## hands the shader.
func _sheet_mesh(p_spacing: float) -> ArrayMesh:
	var n := int(ceil(_view_size / p_spacing)) + 1
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for iz in n:
		for ix in n:
			var x := _view_min.x + ix * p_spacing
			var z := _view_min.y + iz * p_spacing
			verts.append(Vector3(x, 0.0, z))
			uvs.append(Vector2(x, z))
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
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Wide enough that no triangle straddling the shore is killed. Cell diagonal plus the
## half-feather that hangs outside; anything less carves a notch the fragment stage
## cannot put back.
func _kill_margin(p_spacing: float) -> float:
	return p_spacing * 1.5 + FEATHER


# ---- coverage readout --------------------------------------------------------

## Unlit flat coverage, sharing the shipped mask helpers.
##
## Deliberately NOT the lake shader: this criterion measures where the waterline is, and
## reading that off shaded water means thresholding a specular highlight. Flat white at
## the mask's own alpha over black makes the composited red channel the coverage itself.
## The mask code is the shipped code -- water_common's helpers -- so what is measured is
## what would ship; only the shading is replaced.
func _coverage_shader(p_masked: bool, p_hard: bool, p_sqrt: bool = false) -> Shader:
	var sh := Shader.new()
	sh.code = "\n".join([
		"shader_type spatial;",
		"render_mode unshaded, cull_disabled, depth_draw_never, skip_vertex_transform;",
		"#define WATER_SHORE_MASK" if p_masked else "",
		"#define WATER_SHORE_HARD" if p_hard else "",
		"#define WATER_SHORE_SQRT" if p_sqrt else "",
		'#include "%swater_common.gdshaderinc"' % WATER_DIR,
		"void vertex() {",
		"	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;",
		"	v_world_pos = wp;",
		"	VERTEX = (VIEW_MATRIX * vec4(wp, 1.0)).xyz;",
		"	NORMAL = normalize(mat3(VIEW_MATRIX) * vec3(0.0, 1.0, 0.0));",
		"#ifdef WATER_SHORE_MASK",
		"	v_shore_xz = wp.xz;",
		"	if (water_shore_distance(wp.xz) > _shore_kill_margin) {",
		"		VERTEX = vec3(0.0 / 0.0);",
		"	}",
		"#endif",
		"}",
		"void fragment() {",
		"	ALBEDO = vec3(1.0);",
		"	float a = 1.0;",
		"#ifdef WATER_SHORE_MASK",
		"	a = water_shore_alpha(v_shore_xz);",
		"#endif",
		"	ALPHA = a;",
		"}",
	])
	return sh


func _apply_shore_uniforms(p_mat: ShaderMaterial, p_sdf: Dictionary, p_spacing: float) -> void:
	p_mat.set_shader_parameter("_shore_sdf", p_sdf["texture"])
	p_mat.set_shader_parameter("_shore_rect", p_sdf["rect"])
	p_mat.set_shader_parameter("_shore_texels",
		Vector2(p_sdf["texels"], p_sdf["texels"]))
	p_mat.set_shader_parameter("_shore_range", p_sdf["range"])
	p_mat.set_shader_parameter("_shore_feather", FEATHER)
	p_mat.set_shader_parameter("_shore_offset", 0.0)
	p_mat.set_shader_parameter("_shore_kill_margin", _kill_margin(p_spacing))


# ---- the case matrix ---------------------------------------------------------

func _run_cases() -> void:
	# Float, so the reference cases carry no quantisation of their own and the format's cost
	# can be read off separately.
	var sdf_fine := SDF.bake(_poly, _view_min, _view_size, SDF_TEXEL, Image.FORMAT_RF, SDF_RANGE, false)
	var sdf_coarse := SDF.bake(_poly, _view_min, _view_size, 4.0, Image.FORMAT_RF, SDF_RANGE, false)
	# One byte per texel, linear. The cheap option, and the parity partner for the C++ R8.
	var sdf_r8 := SDF.bake(_poly, _view_min, _view_size, SDF_TEXEL, Image.FORMAT_R8, SDF_RANGE, false)
	# The C++ baker: R16F, which is the shipping format, and R8 to sit against sdf_r8.
	var sdf_rh := SDF.bake_native(_poly, _view_min, _view_size, SDF_TEXEL, SDF_RANGE, 2, true)
	var sdf_native_r8 := SDF.bake_native(_poly, _view_min, _view_size, SDF_TEXEL, SDF_RANGE, 2, false)
	# The clever encoding that did not work. Same field, same format, sqrt-mapped: a control
	# for the claim that the sampler has to be interpolating distance itself.
	var sdf_sqrt := SDF.bake_native(_poly, _view_min, _view_size, SDF_TEXEL, SDF_RANGE, 2, true, true)
	print("SDF bakes: RF %d^2 @ %.1f m (%.0f ms), RF %d^2 @ 4.0 m (%.0f ms), R8 %d^2 (%.0f ms)" % [
		sdf_fine["texels"], SDF_TEXEL, sdf_fine["ms"],
		sdf_coarse["texels"], sdf_coarse["ms"],
		sdf_r8["texels"], sdf_r8["ms"]])
	if sdf_rh.is_empty():
		_fail += 1
		print("        !! Pasture3DUtil.build_shore_sdf is missing -- the extension is stale")
	else:
		# Against the BANDED GDScript baker, which is the same algorithm. The brute-force
		# oracle above is a different algorithm and comparing against it would flatter this.
		var banded := SDF.bake(_poly, _view_min, _view_size, SDF_TEXEL, Image.FORMAT_R8,
			SDF_RANGE, true, 2)
		print("        native RH %d^2 (%.1f ms) vs GDScript banded (%.0f ms) = %.0fx" % [
			sdf_rh["texels"], sdf_rh["ms"], banded["ms"],
			banded["ms"] / maxf(sdf_rh["ms"], 0.001)])
	print("        R8 step at range %.0f m: %.3f m. R16F near the shore: under a mm." % [
		SDF_RANGE, SDF_RANGE * 2.0 / 256.0])
	print("        kill margins: %.1f m @1.27, %.1f m @5, %.1f m @10 -- the field's range" % [
		_kill_margin(SPACING_LOD0), _kill_margin(SPACING_MID),
		_kill_margin(SPACING_COARSE)])
	print("        must exceed the coarsest of these or the geometric cut goes inert.")
	print("")

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
	# Straight down. Camera +X is world +X and screen-down is world +Z, so pixel (x, y)
	# centres on _view_min + (x + 0.5, y + 0.5) * _mpp with no flip. Criterion A is what
	# proves that: get this wrong and the exact-clip case scores off the scale.
	cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	cam.position = Vector3(_view_min.x + _view_size * 0.5, 100.0,
		_view_min.y + _view_size * 0.5)
	cam.current = true
	vp.add_child(cam)

	var mi := MeshInstance3D.new()
	mi.extra_cull_margin = 64.0
	vp.add_child(mi)

	var cases := [
		{"name": "A_exact_clip", "exact": true, "spacing": SPACING_LOD0, "sdf": null,
			"hard": false},
		{"name": "B1_mask_1.27m", "exact": false, "spacing": SPACING_LOD0,
			"sdf": sdf_fine, "hard": false},
		{"name": "B2_mask_5m", "exact": false, "spacing": SPACING_MID,
			"sdf": sdf_fine, "hard": false},
		{"name": "B3_mask_10m", "exact": false, "spacing": SPACING_COARSE,
			"sdf": sdf_fine, "hard": false},
		{"name": "B4_native_rh_5m", "exact": false, "spacing": SPACING_MID,
			"sdf": sdf_rh, "hard": false},
		{"name": "B5_native_r8_5m", "exact": false, "spacing": SPACING_MID,
			"sdf": sdf_native_r8, "hard": false},
		{"name": "P_gdscript_r8_5m", "exact": false, "spacing": SPACING_MID,
			"sdf": sdf_r8, "hard": false},
		{"name": "C_hard_cut_5m", "exact": false, "spacing": SPACING_MID,
			"sdf": sdf_fine, "hard": true},
		{"name": "C_sdf_4m", "exact": false, "spacing": SPACING_MID,
			"sdf": sdf_coarse, "hard": false},
		{"name": "C_sqrt_encoding", "exact": false, "spacing": SPACING_MID,
			"sdf": sdf_sqrt, "hard": false, "sqrt": true},
	]

	print("%-20s %8s %9s %9s %9s %9s" % [
		"case", "verts", "err mean", "err p99", "err max", "area err"])
	for c in cases:
		var mesh: ArrayMesh = _exact_mesh(c["spacing"]) if c["exact"] \
			else _sheet_mesh(c["spacing"])
		if mesh == null:
			print("%-20s  -- mesh could not be built (extension missing?)" % c["name"])
			continue
		var sdf = c["sdf"]
		if not c["exact"] and (sdf == null or (sdf as Dictionary).is_empty()):
			# Skipped rather than scored. A case whose field never got baked would otherwise
			# render an unwired mask -- inert, so the whole sheet draws -- and post a number.
			_fail += 1
			print("%-20s  !! no field to test" % c["name"])
			continue
		var mat := ShaderMaterial.new()
		mat.shader = _coverage_shader(not c["exact"], c["hard"], c.get("sqrt", false))
		if sdf != null:
			_apply_shore_uniforms(mat, sdf, c["spacing"])
		mi.mesh = mesh
		mi.material_override = mat
		for i in 4:
			await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		var s := SDF.score(img, _truth, _poly, _view_min, _mpp, IMG, _truth_area)
		s["verts"] = _vertex_count(mesh)
		s["image"] = img
		_scores[c["name"]] = s
		print("%-20s %8d %8.3fm %8.3fm %8.3fm %8.3f%%" % [
			c["name"], s["verts"], s["mean"], s["p99"], s["max"], s["area_err_pct"]])

	mi.queue_free()
	vp.queue_free()
	print("")


func _vertex_count(p_mesh: ArrayMesh) -> int:
	if p_mesh == null or p_mesh.get_surface_count() == 0:
		return 0
	return (p_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()


# ---- criteria ----------------------------------------------------------------

func _need(p_name: String) -> Dictionary:
	if not _scores.has(p_name):
		_fail += 1
		print("    !! case %s produced no score" % p_name)
		return {}
	return _scores[p_name]


func _criterion_a_floor() -> void:
	print("[A] instrument floor -- the exact-clip mesh is the reference:")
	var a := _need("A_exact_clip")
	if a.is_empty():
		return
	# Two pixels of slack. The rendered edge is a rasterised triangle boundary and the
	# truth is a point-sampled mask, so they disagree along a sub-pixel band no matter
	# how exact the geometry is. Anything beyond that is a real disagreement -- and a
	# transposed or flipped axis lands tens of metres out, not tenths.
	var floor_m := _mpp * 2.0
	print("    exact clip: p99 %.3f m, max %.3f m (floor %.3f m)" % [
		a["p99"], a["max"], floor_m])
	if a["p99"] > floor_m:
		_fail += 1
		print("    !! the reference does not agree with its own polygon -- the world/pixel")
		print("       mapping or the ground-truth mask is wrong, so nothing below is valid")
	else:
		print("    -> mapping verified; the instrument resolves to ~%.3f m" % _mpp)
	_completed += 1


## The cases that are SUPPOSED to meet the budget: a well-resolved field, read with the
## feather. The rest of the matrix exists to find where that stops being true, and is
## scored by criterion D instead.
const BUDGET_CASES := ["B1_mask_1.27m", "B2_mask_5m", "B3_mask_10m", "B4_native_rh_5m",
	"B5_native_r8_5m", "P_gdscript_r8_5m"]


func _criterion_b_accuracy() -> void:
	print("[B] accuracy -- masked waterline within %.2f m (edge_offset is 2 m):" % ACCURACY_BUDGET_M)
	var any := false
	for name in BUDGET_CASES:
		var s := _need(name)
		if s.is_empty():
			continue
		any = true
		var ok: bool = s["p99"] <= ACCURACY_BUDGET_M
		# A case sitting in the last fifth of its budget has passed on paper and has no
		# margin for a shore the fixture does not have. Say so rather than printing "ok".
		var marginal: bool = ok and s["p99"] > ACCURACY_BUDGET_M * 0.8
		print("    %-20s p99 %.3f m  spill %.3f m  shortfall %.3f m  %s" % [
			name, s["p99"], s["spill"], s["shortfall"],
			("MARGINAL" if marginal else "ok") if ok else "OVER"])
		if not ok:
			_fail += 1
	if not any:
		_fail += 1
		print("    !! no masked case scored")
	_completed += 1


## The hypothesis, and the reason the whole plan might work: the feather is evaluated per
## fragment from the field, so the mesh underneath it should not enter the answer at all.
##
## Agreement is the PASS here, which makes "everything came out the same because nothing
## rendered" the failure mode to guard against -- so this also requires the meshes to have
## genuinely differed, and requires the matrix as a whole to have produced a spread. A run
## where every case returned the same number for the wrong reason fails both of those.
func _criterion_c_spacing() -> void:
	print("[C] spacing independence -- the hypothesis:")
	var base := _need("B1_mask_1.27m")
	var mid := _need("B2_mask_5m")
	var coarse := _need("B3_mask_10m")
	if base.is_empty() or mid.is_empty() or coarse.is_empty():
		return
	var floor_m := _mpp * 2.0
	var b: float = maxf(base["p99"], floor_m)
	for pair in [["5 m", mid], ["10 m", coarse]]:
		var s: Dictionary = pair[1]
		var ratio: float = s["p99"] / b
		var ok := ratio <= SPACING_TOLERANCE
		print("    %-6s / 1.27 m  =  %.2fx  (%.3f m vs %.3f m)  %s" % [
			pair[0], ratio, s["p99"], base["p99"], "ok" if ok else "DEGRADED"])
		if not ok:
			_fail += 1

	# The meshes have to have actually differed, or agreement means nothing.
	var lo: int = mini(mini(base["verts"], mid["verts"]), coarse["verts"])
	var hi: int = maxi(maxi(base["verts"], mid["verts"]), coarse["verts"])
	print("    verts: exact %d, sheet@1.27 %d, sheet@5 %d, sheet@10 %d  (%.0fx span)" % [
		_need("A_exact_clip").get("verts", 0), base["verts"], mid["verts"],
		coarse["verts"], float(hi) / float(maxi(lo, 1))])
	if hi < lo * 10:
		_fail += 1
		print("    !! the three sheets are not meaningfully different meshes, so their")
		print("       agreement says nothing about spacing")

	# And the harness has to be capable of telling cases apart at all.
	var distinct := {}
	for name in _scores.keys():
		distinct[snappedf(_scores[name]["p99"], 0.001)] = true
	print("    the matrix produced %d distinct scores across %d cases" % [
		distinct.size(), _scores.size()])
	if distinct.size() < 3:
		_fail += 1
		print("    !! fewer than three distinct outcomes -- this harness cannot")
		print("       distinguish cases, so identical results are not evidence")
	_completed += 1


## Controls, in the form the rest of this bench suite uses: things that MUST fail the
## criterion above. Both are single-variable changes away from a passing case.
##
##   C  -- same field, same mesh, feather removed. Isolates the ramp.
##   B4 -- same mesh, same feather, field coarsened 4x. Isolates the resolution.
##
## A ratio threshold was the first draft of this and was the wrong instrument: it asked
## whether the control was "worse enough" against a number picked before any data existed.
## Whether the control crosses the budget the candidates have to meet is not a number
## anyone has to choose.
func _criterion_d_control() -> void:
	print("[D] controls -- each must FAIL criterion B's %.2f m budget:" % ACCURACY_BUDGET_M)
	var soft := _need("B2_mask_5m")
	if soft.is_empty():
		return
	var controls := [
		["C_hard_cut_5m", "feather removed"],
		["C_sdf_4m", "field coarsened to 4 m texels"],
		["C_sqrt_encoding", "distance stored sqrt-mapped instead of linear"],
	]
	for c in controls:
		var s := _need(c[0])
		if s.is_empty():
			continue
		var failed_budget: bool = s["p99"] > ACCURACY_BUDGET_M
		print("    %-20s p99 %.3f m  (%.1fx the candidate)  %s -- %s" % [
			c[0], s["p99"], s["p99"] / maxf(soft["p99"], 1e-4),
			"fails as required" if failed_budget else "!! PASSED", c[1]])
		if not failed_budget:
			_fail += 1
			print("       the candidate's %.3f m therefore does not demonstrate anything:" % soft["p99"])
			print("       this metric cannot see the difference the control removed")

	# PARITY. The C++ baker and the GDScript one are handed the same outline at the same
	# resolution, so their waterlines must land in the same place. This is the check that
	# catches a port that is fast and wrong, and it is worth more than any timing here.
	var gd := _need("P_gdscript_r8_5m")
	var native := _need("B5_native_r8_5m")
	if not gd.is_empty() and not native.is_empty():
		var delta: float = absf(native["p99"] - gd["p99"])
		print("    parity: native %.3f m vs GDScript %.3f m, delta %.4f m (floor %.4f m)" % [
			native["p99"], gd["p99"], delta, _mpp])
		if delta > _mpp:
			_fail += 1
			print("    !! the C++ baker does not agree with its oracle -- do not ship it")

	# FORMAT. Both are linear and differ only in bits per texel, so this is the price of the
	# cheap option stated rather than assumed.
	var rh := _need("B4_native_rh_5m")
	if not rh.is_empty() and not native.is_empty():
		print("    format: R16F %.3f m (%d B/texel) vs R8 %.3f m (1 B/texel)" % [
			rh["p99"], 2, native["p99"]])
	_completed += 1


func _criterion_e_eyeball() -> void:
	print("[E] captures + anti-null checks:")
	# Every score must come from a frame that actually drew the body. This is the check
	# that stops a black frame -- which disagrees with the truth mask everywhere, but only
	# in places that happen to be far from the shore -- from producing a number at all.
	#
	# It does NOT check that the cases differ from each other. An earlier version did, and
	# it was wrong: the spacing sweep coming out bit-identical is the result, not a fault.
	# Criterion C carries that check in the form where it means something.
	var null_fail := false
	for name in _scores.keys():
		var s: Dictionary = _scores[name]
		var frac: float = float(s["covered"]) / float(maxi(_truth_area, 1))
		if frac < 0.5 or frac > 2.0:
			_fail += 1
			null_fail = true
			print("    !! %s covered %.2fx the true area -- it did not draw the body" % [
				name, frac])
	if not null_fail:
		print("    -> every case drew the body to within 2x of its true area")

	# The top-down readouts, for looking at rather than measuring.
	for name in _scores.keys():
		_save(_scores[name]["image"], "shore_top_%s.png" % name)
	await _perspective_captures()
	_completed += 1


## The rim at eye level, with the real lake material over a bank. The numbers above say
## where the waterline is; these say whether it looks like a shore.
func _perspective_captures() -> void:
	var sdf := SDF.bake(_poly, _view_min, _view_size, SDF_TEXEL, Image.FORMAT_RF, SDF_RANGE, false)
	var vp := SubViewport.new()
	vp.size = Vector2i(1280, 720)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
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

	# High and off to the side. The first pass put the sun near the view axis and the
	# specular sheet swallowed the waterline in every frame -- the captures were of a
	# highlight, not of a shore.
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-62.0, -75.0, 0.0)
	vp.add_child(sun)
	# The shading reads the sun from a global, not from the light node.
	RenderingServer.global_shader_parameter_set("water_sun_direction",
		-sun.global_transform.basis.z)
	RenderingServer.global_shader_parameter_set("water_sun_color", Vector3(1.0, 0.97, 0.9))

	# A bank just under the surface, so the rim has something to end against -- which is
	# the whole premise of edge_offset and the only setting in which the question makes
	# sense. A rim judged against empty space is a harder test than the real one.
	var bank := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(_view_size * 2.0, _view_size * 2.0)
	bank.mesh = plane
	var bank_mat := StandardMaterial3D.new()
	bank_mat.albedo_color = Color(0.42, 0.35, 0.26)
	bank_mat.roughness = 0.95
	bank.material_override = bank_mat
	# 2.5 m down, not 0.7. At 0.7 m the lake's absorption barely tints the bank, so the
	# water read as a faint sheen and the waterline -- the thing being judged -- had almost
	# no contrast against the dry ground beside it.
	bank.position = Vector3(0.0, -2.5, 0.0)
	vp.add_child(bank)

	var water := MeshInstance3D.new()
	water.extra_cull_margin = 64.0
	vp.add_child(water)

	var cam := Camera3D.new()
	cam.near = 0.05
	cam.far = 2000.0
	cam.current = true
	vp.add_child(cam)

	# Three poses, all from OUTSIDE the body looking in, because a waterline seen from over
	# the water is mostly hidden by the water. Oblique rather than level: the first pass
	# put the camera at 2.4 m and the shore compressed into two or three pixels of frame,
	# which is not a view anything can be judged in.
	var poses := [
		# The 6 m inlet, close. The feature no grid this coarse can represent by meshing.
		{"name": "inlet", "pos": Vector3(-78.0, 16.0, 26.0), "look": Vector3(-34.0, 0.0, 10.0)},
		# The headland, a sharp convex corner -- where an SDF rounds off if it is going to.
		{"name": "headland", "pos": Vector3(4.0, 20.0, -92.0), "look": Vector3(-14.0, 0.0, -46.0)},
		# A plain stretch of shore at a grazing angle, which is how a shore is usually seen.
		{"name": "grazing", "pos": Vector3(96.0, 3.2, 34.0), "look": Vector3(20.0, 0.0, 12.0)},
	]
	var variants := [
		{"name": "A_exact", "exact": true, "shader": WATER_DIR + "water_body.gdshader",
			"hard": false},
		{"name": "B_mask_5m", "exact": false,
			"shader": WATER_DIR + "water_lake_masked.gdshader", "hard": false},
		{"name": "C_hard_5m", "exact": false, "shader": "", "hard": true},
	]

	for v in variants:
		var mesh: ArrayMesh = _exact_mesh(SPACING_LOD0) if v["exact"] \
			else _sheet_mesh(SPACING_MID)
		if mesh == null:
			print("    !! %s: no mesh" % v["name"])
			_fail += 1
			continue
		var mat := ShaderMaterial.new()
		if v["shader"] != "":
			var sh: Shader = load(v["shader"])
			if sh == null:
				_fail += 1
				print("    !! %s: shader %s did not load" % [v["name"], v["shader"]])
				continue
			mat.shader = sh
		else:
			mat.shader = _lake_shader_with_defines(true)
		if not v["exact"]:
			_apply_shore_uniforms(mat, sdf, SPACING_MID)
		water.mesh = mesh
		water.material_override = mat
		water.set_instance_shader_parameter("_water_domain_origin", Vector3.ZERO)
		for pose in poses:
			cam.position = pose["pos"]
			cam.look_at(pose["look"], Vector3.UP)
			for i in 6:
				await RenderingServer.frame_post_draw
			_save(vp.get_texture().get_image(),
				"shore_view_%s_%s.png" % [pose["name"], v["name"]])

	vp.queue_free()


## The lake wrapper's feature set with the hard cut spliced in -- the control variant,
## which has no wrapper file of its own because it is not something anyone would ship.
func _lake_shader_with_defines(p_hard: bool) -> Shader:
	var sh := Shader.new()
	sh.code = "\n".join([
		"shader_type spatial;",
		"render_mode cull_disabled, depth_draw_never, diffuse_lambert, specular_schlick_ggx, skip_vertex_transform;",
		"#define WATER_WAVE_COUNT 4",
		"#define WATER_SHORE_MASK",
		"#define WATER_SHORE_HARD" if p_hard else "",
		"#define WATER_DETAIL",
		"#define WATER_DEPTH_FADE",
		"#define WATER_FOAM_SHORE",
		"#define WATER_SCATTER",
		'#include "%swater_common.gdshaderinc"' % WATER_DIR,
		'#include "%swater_waves.gdshaderinc"' % WATER_DIR,
		'#include "%swater_surface.gdshaderinc"' % WATER_DIR,
		'#include "%swater_shading.gdshaderinc"' % WATER_DIR,
	])
	return sh


## Write, then read the file back. A save that silently failed on a missing directory has
## produced a green run in this bench suite before; "written" is not evidence.
func _save(p_img: Image, p_name: String) -> void:
	var path := _out_dir + p_name
	var err := p_img.save_png(path)
	if err != OK:
		_fail += 1
		print("    !! save %s failed (%d)" % [path, err])
		return
	if not FileAccess.file_exists(path) or FileAccess.get_file_as_bytes(path).size() < 1024:
		_fail += 1
		print("    !! %s did not land on disk" % path)
		return
	_shots[p_name] = path
