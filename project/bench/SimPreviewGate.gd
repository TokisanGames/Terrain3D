# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gates BJ-BL — the mask preview shows the field the bake will use. See PASTURE3D_SIM_NODE_SPEC.md §21.8.
#
# §21.8 diagnosed three ways the previewed field and the baked field disagreed, and warned that "a gate
# which only checked the preview was non-blank would pass on all three". So none of these check for
# non-blank. Each one compares the preview against a SECOND, independently reached answer, and each one
# carries a control that must fail — because two blank fields agree, and so do two wrong ones.
#
# The three claims, in the order §21.8 raised them:
#   BJ (D1) — a relief stack's layers all read the SAME Sim Result in the preview, the one the bake
#             resolves for the whole compiled program, not each selector's own reference.
#   BK (D2) — a managed Sim's sim Filter Types preview against the PREVIOUS PASS's fields, which is what
#             §19.5 gates them on at bake time.
#   BL (D3) — a managed Sim previews against the SURFACE the previous pass produced, once the chain has
#             been built that far — and says so plainly when it has not.
#
# NOTHING IS SAVED. Bakes write into the terrain's in-memory layer; demo/data on disk is only touched by
# an explicit save, which nothing here calls.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/SimPreviewGate.tscn
extends Node

const DEMO_DATA := "res://demo/data"

const K_SLOPE := 0
const K_FLOW := 3

## The shipped FLOW preset (§21.5), so these bands are the ones an artist would actually get.
const FLOW_MIN := 5000.0
const FLOW_MAX := 1.0e9
const FLOW_FALLOFF := 2500.0

const SITE_BJ := Vector3(300.0, 0.0, 300.0)
const SITE_BK := Vector3(700.0, 0.0, 300.0)
const SITE_BL := Vector3(500.0, 0.0, 700.0)

const LOOP_HALF := 60.0
const MARGIN := 40.0

var _fail := 0
var _root: Node3D
var _terrain
var _data
var _mat


func _ready() -> void:
	print("\n=== Pasture3DSim mask preview (spec §21.8, gates BJ-BL) ===\n")
	print("NOTE: the rendered overlay is UNGATED here — headless has no viewport, the same accommodation")
	print("      gates AS-AY make. These test WHICH FIELD is handed to the material, not that it is red.\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_data = _terrain.data
	_mat = _terrain.material
	if _data == null or not _data.has_method("selector_mask_field") or _mat == null \
			or not _mat.has_method("set_mask_preview"):
		_fail += 1
		print("!! this build has no selector / preview API")
		_done()
		return

	_gate_bj()
	_gate_bk()
	_gate_bl()
	_done()


func _done() -> void:
	print("\n=== %s (%d failures) ===\n" % ["SIM PREVIEW PASS" if _fail == 0 else "SIM PREVIEW FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- BJ: every layer of a stack previews against the stack's one Sim Result ------------------------
#
# The bake hands the whole compiled program ONE sim dict, from the first non-null result anywhere in the
# stack. So two layers carrying the SAME BAND over the SAME ground must preview the SAME FIELD, whichever
# of them happens to hold the reference. Compared layer-against-layer rather than against a rebuilt
# reference, so the area mask, the grid and the clipping are identical on both sides by construction and
# the only thing left that can differ is the result each one resolved.
func _gate_bj() -> void:
	print("[BJ] a stack's layers all preview against the result the BAKE resolves:")
	var plow := _make_plow("BJ", SITE_BJ)
	var res := _flow_result(SITE_BJ, LOOP_HALF + 40.0, 50000.0)

	var l0 := Pasture3DReliefFractal.new()
	l0.selector = _sel(K_FLOW, FLOW_MIN, FLOW_MAX, FLOW_FALLOFF)
	l0.selector.sim_result = res
	var l1 := Pasture3DReliefFractal.new()
	l1.selector = _sel(K_FLOW, FLOW_MIN, FLOW_MAX, FLOW_FALLOFF)
	l1.selector.sim_result = null # the natural configuration: the stack already carries one
	var stack := Pasture3DReliefStack.new()
	stack.layers = [l0, l1] as Array[Pasture3DReliefMaterial]
	plow.relief = stack
	plow.mask_preview = true

	var f0 := _preview_layer(plow, 0)
	var f1 := _preview_layer(plow, 1)
	# PRECONDITION: a field that is constant would match anything. Reported, not assumed.
	var spread := _spread(f0)
	print("    layer 0 (holds the result): %d cells, %.4f..%.4f, %.1f%% selected" % [
			f0.size(), spread[0], spread[1], _fraction_over(f0, 0.5) * 100.0])
	if f0.is_empty() or spread[1] - spread[0] < 0.5:
		_fail += 1
		print("    !! layer 0's field is empty or nearly constant; BJ would pass on two blank fields")
		return
	var diff := _max_abs_diff(f0, f1)
	print("    layer 1 (no result of its own): max |layer1 - layer0| = %.9f (want 0)" % diff)
	if diff != 0.0:
		_fail += 1
		print("    !! the two layers preview different fields, so the preview is still resolving per-selector")

	# CONTROL 1. Give layer 1 a DIFFERENT result. The bake ignores it — the stack's first wins for every
	# selector — so the preview must ignore it too. If the field moves, the preview is still reading the
	# chosen selector's own reference and BJ above passed only because both happened to agree.
	var other := _flow_result(SITE_BJ + Vector3(1000.0, 0.0, 0.0), LOOP_HALF + 40.0, 50000.0)
	l1.selector.sim_result = other
	var f1b := _preview_layer(plow, 1)
	var moved := _max_abs_diff(f1, f1b)
	print("    CONTROL a DIFFERENT result on layer 1's own selector moves it by %.9f (want 0 — the bake ignores it)" % moved)
	if moved != 0.0:
		_fail += 1
		print("    !! the preview obeyed a reference the bake would ignore")

	# CONTROL 2. The comparison must be able to SEE a difference at all. Same layer, a band that passes
	# nothing, must differ from f0 — otherwise every "0.000000" above is a comparison of two blank fields.
	l1.selector.sim_result = null
	l1.selector.range_min = 1.0e12
	l1.selector.range_max = 1.0e13
	var f1c := _preview_layer(plow, 1)
	var vis := _max_abs_diff(f0, f1c)
	print("    CONTROL a band that passes nothing differs by %.4f (want > 0)" % vis)
	if vis <= 0.0:
		_fail += 1
		print("    !! the comparison cannot see a field change; BJ is vacuous")
	plow.mask_preview = false
	print("")


# --- BK: a managed Sim previews against the PREVIOUS pass's fields ---------------------------------
#
# §19.5 gates a member on the previous pass's live flow / erosion / deposition / wetness. Since §21.3
# those are stored on the pass that made them, so the preview can show the same field — and the way to
# prove it is the same field is to build a SECOND preview that is pointed at that result explicitly.
#
# A standalone Sim with the identical loop and margin, carrying the identical band with pass 1's result
# assigned, must preview identically. A FLOW band reads only the sim fields, never the ground, so the two
# nodes reading different SURFACES cannot contaminate the comparison — which is what makes this fair
# rather than convenient.
func _gate_bk() -> void:
	print("[BK] a managed Sim previews the PREVIOUS pass's fields:")
	var mgr := _make_manager("BK", SITE_BK)
	var p1 := _add_pass(mgr, "P1")
	var p2 := _add_pass(mgr, "P2")
	if p1 == null or p2 == null:
		_fail += 1
		print("    !! no terrain at %s\n" % SITE_BK)
		return
	p2.erosion_mask = [_sel(K_FLOW, FLOW_MIN, FLOW_MAX, FLOW_FALLOFF)] as Array[Pasture3DReliefSelector]
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		_fail += 1
		print("    !! the chain did not solve\n")
		return
	var r1: Pasture3DSimResult = mgr.pass_result(0)
	if r1 == null or not r1.is_valid():
		_fail += 1
		print("    !! pass 1 stored no masks, so there is nothing for pass 2 to read\n")
		return
	print("    pass 1's stored masks: %s" % r1.describe())

	p2.mask_preview = 1
	p2._update_mask_preview()
	var shown := _preview_field(p2)
	var spread := _spread(shown)
	print("    pass 2's preview: %d cells, %.4f..%.4f, %d cell(s) over 0.5" % [
			shown.size(), spread[0], spread[1], _count_over(shown, 0.5)])
	if shown.is_empty() or spread[1] <= 0.0:
		_fail += 1
		print("    !! pass 2 previews blank, which is the defect §21.8 D2 reported")
		p2.mask_preview = 0
		return

	# The independent second answer: a standalone Sim, same geometry, same band, pointed at pass 1's
	# result by hand. Nothing about it goes through the manager.
	var ref := _standalone_like(p2, "BK_ref", SITE_BK, r1)
	ref.mask_preview = 1
	ref._update_mask_preview()
	var want := _preview_field(ref)
	var diff := _max_abs_diff(shown, want)
	print("    against a standalone Sim pointed at pass 1's result by hand: max |diff| = %.9f (want 0)" % diff)
	if diff != 0.0:
		_fail += 1
		print("    !! the managed preview is not showing pass 1's fields")

	# CONTROL 1. Point the reference at pass 2's OWN masks instead. It must differ — otherwise "the
	# PREVIOUS pass's" is untested and any result at all would have satisfied the comparison.
	var r2: Pasture3DSimResult = mgr.pass_result(1)
	if r2 != null and r2.is_valid():
		ref.erosion_mask[0].sim_result = r2
		ref._update_mask_preview()
		var wrong := _max_abs_diff(shown, _preview_field(ref))
		print("    CONTROL the same reference pointed at pass 2's masks: %.6f (want > 0)" % wrong)
		if wrong <= 0.0:
			_fail += 1
			print("    !! pass 1's and pass 2's masks gate identically here; BK cannot tell them apart")
	else:
		_fail += 1
		print("    !! pass 2 stored no masks, so the control cannot run")

	# CONTROL 2. Pass 1 has no predecessor, so §19.5 says its sim Filter Types read a defined 0 — the
	# preview must agree with the bake about that too, rather than inventing a field for it.
	p1.erosion_mask = [_sel(K_FLOW, FLOW_MIN, FLOW_MAX, FLOW_FALLOFF)] as Array[Pasture3DReliefSelector]
	p1.mask_preview = 1
	p1._update_mask_preview()
	var first := _preview_field(p1)
	print("    CONTROL pass 1 (no predecessor) previews %.4f..%.4f (want flat 0)" % _spread(first))
	if _spread(first)[1] > 0.0:
		_fail += 1
		print("    !! pass 1 previewed a field it will not be gated on")
	p1.mask_preview = 0
	p2.mask_preview = 0
	ref.mask_preview = 0
	print("")


# --- BL: a managed Sim previews against the surface the previous pass produced ---------------------
#
# The one §21.8 called the most consequential, because it is not about sim Filter Types at all: a Slope,
# Altitude or Curvature band on pass 2 was previewed against the ground BEFORE the chain ran.
#
# Tested on the SURFACE itself rather than on a finished band, because the surface is the thing that was
# wrong and a band only shows it indirectly.
func _gate_bl() -> void:
	print("[BL] a managed Sim previews against the previous pass's OUTPUT surface:")
	var mgr := _make_manager("BL", SITE_BL)
	var p1 := _add_pass(mgr, "P1")
	var p2 := _add_pass(mgr, "P2")
	if p1 == null or p2 == null:
		_fail += 1
		print("    !! no terrain at %s\n" % SITE_BL)
		return
	p2.erosion_mask = [_sel(K_SLOPE, 12.0, 90.0, 6.0)] as Array[Pasture3DReliefSelector]
	var layer_id: int = mgr._ensure_layer_for(mgr._layer_owner, true)
	var g := _grid(SITE_BL)

	# BEFORE any build: nothing is committed, so the honest surface is the pre-chain ground and the node
	# must say so rather than draw against it silently.
	p2.mask_preview = 1
	p2._update_mask_preview()
	var pre: PackedFloat32Array = p2._preview_below(layer_id, g[0], g[1], g[4], g[2], g[3])
	var ground: PackedFloat32Array = _data.composite_height_below(layer_id, g[0], g[1], g[4], g[2], g[3])
	print("    with nothing built: preview surface == the pre-chain ground: %s" % _same(pre, ground))
	if not _same(pre, ground):
		_fail += 1
		print("    !! the fallback is not the below-layer read; BL cannot say what it fell back to")
	var warned_before := _warns_about_surface(p2)
	print("    and it warns that the preview is against the pre-chain ground: %s (want true)" % warned_before)
	if not warned_before:
		_fail += 1
		print("    !! drawing against the wrong surface in silence is the defect, not the fallback")

	# Build through pass 1 only — §21.4's Simulate To Here, which is what makes the right surface exist.
	if not bool(mgr.simulate_now(1, false, 0).get("ok", false)):
		_fail += 1
		print("    !! the build-through failed\n")
		return
	p2._update_mask_preview()
	var post: PackedFloat32Array = p2._preview_below(layer_id, g[0], g[1], g[4], g[2], g[3])
	var chained: PackedFloat32Array = _data.composite_height_below(layer_id + 1, g[0], g[1], g[4], g[2], g[3])

	# PRECONDITION: pass 1 has to have MOVED the ground, or the two surfaces are the same and BL passes
	# on a chain that did nothing.
	var moved := _max_abs_diff(ground, chained)
	print("    pass 1 moved the ground by %.3f m over %d cells" % [moved, chained.size()])
	if moved <= 0.0:
		_fail += 1
		print("    !! pass 1 changed nothing, so there is no second surface to prefer")
		return
	print("    after Simulate To Here on pass 1: preview surface == the chain's output: %s" % _same(post, chained))
	if not _same(post, chained):
		_fail += 1
		print("    !! the preview is still reading the pre-chain ground")
	var warned_after := _warns_about_surface(p2)
	print("    and the warning is gone: %s (want true)" % (not warned_after))
	if warned_after:
		_fail += 1
		print("    !! it still warns after the build-through, so the warning is not about the surface")

	# CONTROL. Pass 1 has no predecessor: its input IS the pre-chain ground, so its preview surface must
	# stay the below-layer read even now that the layer holds pass 1's own delta. If it moved too, the
	# override is reading "the layer" rather than "the previous pass".
	var p1_surface: PackedFloat32Array = p1._preview_below(layer_id, g[0], g[1], g[4], g[2], g[3])
	print("    CONTROL pass 1's own preview surface is still the pre-chain ground: %s" % _same(p1_surface, ground))
	if not _same(p1_surface, ground):
		_fail += 1
		print("    !! pass 1 previews against its own output — that is the §13 drift class, not a fix")
	p2.mask_preview = 0
	print("")


# --- fixtures --------------------------------------------------------------------------------------

func _sel(p_kind: int, p_lo: float, p_hi: float, p_f_lo: float) -> Pasture3DReliefSelector:
	var s := Pasture3DReliefSelector.new()
	s.filter_type = p_kind
	s.range_min = p_lo
	s.range_max = p_hi
	s.falloff_low = p_f_lo
	s.falloff_high = 0.0
	return s


## A populated result whose western half drains `p_area` m², so the shipped FLOW preset selects roughly
## half of it by construction rather than by luck.
func _flow_result(p_at: Vector3, p_half: float, p_area: float) -> Pasture3DSimResult:
	var r := Pasture3DSimResult.new()
	r.cell_size = 4.0
	r.width = int(p_half * 2.0 / r.cell_size) + 1
	r.height = r.width
	r.min_x = p_at.x - p_half
	r.min_z = p_at.z - p_half
	var n := r.width * r.height
	var f := PackedFloat32Array()
	f.resize(n)
	var zero := PackedFloat32Array()
	zero.resize(n)
	for iz in range(r.height):
		for ix in range(r.width):
			f[iz * r.width + ix] = log(p_area) if ix < r.width / 2 else 0.0
	r.flow = f
	r.erosion = zero
	r.deposition = zero.duplicate()
	r.wetness = zero.duplicate()
	r.source_node = "SimPreviewGate"
	r.source_loops = 1
	return r


func _make_plow(p_name: String, p_at: Vector3) -> Pasture3DPlow:
	var plow := Pasture3DPlow.new()
	plow.name = p_name
	_root.add_child(plow)
	plow.terrain = _terrain
	plow.global_position = p_at
	plow.snap_to_surface = false
	plow.source = Pasture3DPlow.Source.RELIEF
	plow._layer_owner = "pasture3d_brush:Preview_%s" % p_name
	_add_square(plow, LOOP_HALF)
	return plow


func _make_manager(p_name: String, p_at: Vector3) -> Pasture3DSimManager:
	var m := Pasture3DSimManager.new()
	m.name = "M_%s" % p_name
	_root.add_child(m)
	m.terrain = _terrain
	m.global_position = p_at
	m.snap_to_surface = false
	m.catchment_margin = MARGIN
	m._layer_owner = "pasture3d_brush:Preview_%s" % p_name
	return m


func _add_pass(p_mgr: Pasture3DSimManager, p_name: String) -> Pasture3DSim:
	var s := Pasture3DSim.new()
	s.name = p_name
	p_mgr.add_child(s)
	s.terrain = _terrain
	s.snap_to_surface = false
	s.catchment_margin = MARGIN
	s.falloff_width = 12.0
	s.iterations = 20
	s.erosion_rate = 0.15
	s.hillslope_diffusion = 0.15
	_add_square(s, LOOP_HALF)
	if not is_finite(_data.get_height(p_mgr.global_position)):
		return null
	return s


## A standalone Sim built to match a managed one exactly — same loop, same margin, same feathering — so
## the only thing that can differ between their previews is where each got its fields.
func _standalone_like(p_src: Pasture3DSim, p_name: String, p_at: Vector3,
		p_result: Pasture3DSimResult) -> Pasture3DSim:
	var s := Pasture3DSim.new()
	s.name = p_name
	_root.add_child(s)
	s.terrain = _terrain
	s.global_position = p_at
	s.snap_to_surface = false
	s.catchment_margin = p_src.catchment_margin
	s.falloff_width = p_src.falloff_width
	s.edge_offset = p_src.edge_offset
	s._layer_owner = p_src._layer_owner # the same below-layer read, so the grids line up
	_add_square(s, LOOP_HALF)
	var sel := _sel(K_FLOW, FLOW_MIN, FLOW_MAX, FLOW_FALLOFF)
	sel.sim_result = p_result
	s.erosion_mask = [sel] as Array[Pasture3DReliefSelector]
	return s


func _add_square(p_node: Node3D, p_half: float) -> void:
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	for p in [Vector3(-p_half, 0, -p_half), Vector3(p_half, 0, -p_half),
			Vector3(p_half, 0, p_half), Vector3(-p_half, 0, p_half)]:
		c.add_point(p)
	c.closed = true
	path.curve = c
	p_node.add_child(path)


# --- helpers ---------------------------------------------------------------------------------------

## [min_x, min_z, gw, gh, cell] of a grid covering the loop plus its margin, snapped to the terrain grid.
## Stated here from the fixture's own geometry rather than read off the node under test.
func _grid(p_at: Vector3) -> Array:
	var vs: float = _terrain.vertex_spacing
	var pad := LOOP_HALF + MARGIN + 4.0
	var min_x := floorf((p_at.x - pad) / vs) * vs
	var min_z := floorf((p_at.z - pad) / vs) * vs
	var max_x := ceilf((p_at.x + pad) / vs) * vs
	var max_z := ceilf((p_at.z + pad) / vs) * vs
	return [min_x, min_z, int(round((max_x - min_x) / vs)) + 1, int(round((max_z - min_z) / vs)) + 1, vs]


func _preview_layer(p_plow: Pasture3DPlow, p_layer: int) -> PackedFloat32Array:
	p_plow._mask_preview_layer = p_layer
	p_plow._update_mask_preview()
	return _preview_field(p_plow)


func _preview_field(p_brush) -> PackedFloat32Array:
	var tex: ImageTexture = p_brush._mask_preview_texture
	if tex == null:
		return PackedFloat32Array()
	var img: Image = tex.get_image()
	if img == null:
		return PackedFloat32Array()
	var out := PackedFloat32Array()
	out.resize(img.get_width() * img.get_height())
	for iz in range(img.get_height()):
		for ix in range(img.get_width()):
			out[iz * img.get_width() + ix] = img.get_pixel(ix, iz).r
	return out


func _warns_about_surface(p_sim: Pasture3DSim) -> bool:
	for w in p_sim._get_configuration_warnings():
		if String(w).contains("BEFORE the chain ran"):
			return true
	return false


## Bitwise, as raw bytes: a NaN equals a NaN, which matters because the below-layer read is NaN wherever
## no lower layer covers and an approximate compare would quietly skip exactly those cells.
func _same(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> bool:
	return p_a.size() == p_b.size() and p_a.to_byte_array() == p_b.to_byte_array()


func _spread(p_a: PackedFloat32Array) -> Array:
	var lo := INF
	var hi := -INF
	for v in p_a:
		if is_finite(v):
			lo = minf(lo, v)
			hi = maxf(hi, v)
	return [0.0, 0.0] if not is_finite(lo) else [lo, hi]


func _fraction_over(p_a: PackedFloat32Array, p_t: float) -> float:
	if p_a.is_empty():
		return 0.0
	return float(_count_over(p_a, p_t)) / float(p_a.size())


func _count_over(p_a: PackedFloat32Array, p_t: float) -> int:
	var n := 0
	for v in p_a:
		if is_finite(v) and v > p_t:
			n += 1
	return n


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		if is_finite(p_a[i]) and is_finite(p_b[i]):
			m = maxf(m, absf(p_a[i] - p_b[i]))
	return m
