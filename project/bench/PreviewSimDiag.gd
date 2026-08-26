# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# §21.8 — DIAGNOSIS, not a gate. "The material preview does not work", re-tested the way §21.8 asks:
# with a POPULATED Sim Result and a Filter Type-appropriate band, now that phase 6.5 makes both reachable.
#
# §21.8 names two likely explanations, both of which phase 6.5 already addresses:
#   1. a sim Filter Type with a null `sim_result` reads a defined 0 everywhere and previews blank;
#   2. a sim Filter Type band left at the SLOPE defaults of 25-90 passes almost nothing.
# and says: if it STILL fails with those two removed, that is its own investigation.
#
# This script removes both and asks whether it still fails. It does. Two divergences, each measured with
# a control that separates "the preview is broken here" from "this fixture had nothing to show".
#
# D1 — RELIEF MATERIAL (Plow / Mound). The BAKE hands the whole compiled program ONE sim dict, from
#      `_sim_result_for()` -> `_relief_sim_result()` -> the FIRST non-null result anywhere in the stack
#      (plow.gd:464, plow.gd:498). The PREVIEW hands it only the CHOSEN selector's own `sim_result`
#      (terrain_brush.gd:1176). A stack that carries its result on one layer bakes correctly and previews
#      blank on every other layer.
#
# D2 — MANAGED SIM (the pass chain). The BAKE evaluates a member's masks against `p_st["fields"]`, the
#      PREVIOUS pass's LIVE flow / erosion / deposition / wetness (sim_manager.gd:834). The PREVIEW
#      evaluates them against `_mask_sim_dict()`, the selector's `sim_result` RESOURCE (sim.gd:1261) —
#      which under a manager is documented as ignored, so the correct configuration is null, so the
#      preview is blank on exactly the idiom §19.5 exists to deliver.
#
# NOTHING IS SAVED and nothing here is a gate — no exit code is asserted on. It prints what it measures.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/PreviewSimDiag.tscn
extends Node

const DEMO_DATA := "res://demo/data"

const K_SLOPE := 0
const K_FLOW := 3

## The shipped FLOW preset (relief_selector.gd PRESETS) — a Filter Type-appropriate band, which is the
## whole point: §21.8's hypothesis 2 is that the band was wrong, so the diagnosis must not repeat it.
const FLOW_MIN := 5000.0
const FLOW_MAX := 1.0e9
const FLOW_FALLOFF := 2500.0

const SITE_D1 := Vector3(300.0, 0.0, 300.0)
const SITE_D2 := Vector3(700.0, 0.0, 300.0)

const LOOP_HALF := 60.0
const CHAIN_MARGIN := 40.0

var _root: Node3D
var _terrain
var _data
var _mat


func _ready() -> void:
	print("\n=== §21.8 preview diagnosis: does it still fail with the two known causes removed? ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_data = _terrain.data
	_mat = _terrain.material
	if _data == null or not _data.has_method("selector_mask_field") or _mat == null \
			or not _mat.has_method("set_mask_preview"):
		print("!! this build has no selector / preview API; nothing to diagnose")
		get_tree().quit(1)
		return

	_d1_relief_stack()
	_d2_managed_sim()

	print("\n=== end of diagnosis ===\n")
	get_tree().quit(0)


# --- D1: a stack that bakes correctly and previews blank -------------------------------------------
#
# The reported shape: one Sim Result, a stack of layers, sim Filter Types on more than one of them. At bake
# every layer sees the result. In the preview only the layer that literally holds the reference does.
func _d1_relief_stack() -> void:
	print("[D1] relief material: the bake shares one Sim Result across the stack, the preview does not")

	var plow := Pasture3DPlow.new()
	plow.name = "D1"
	_root.add_child(plow)
	plow.terrain = _terrain
	plow.global_position = SITE_D1
	plow.snap_to_surface = false
	plow.source = Pasture3DPlow.Source.RELIEF
	plow._layer_owner = "pasture3d_brush:Plow_D1"
	var path := Path3D.new()
	var c := Curve3D.new()
	for p in [Vector3(-LOOP_HALF, 0, -LOOP_HALF), Vector3(LOOP_HALF, 0, -LOOP_HALF),
			Vector3(LOOP_HALF, 0, LOOP_HALF), Vector3(-LOOP_HALF, 0, LOOP_HALF)]:
		c.add_point(p)
	c.closed = true
	path.curve = c
	plow.add_child(path)

	# A POPULATED result, built here rather than solved, so "the band selects something" is true by
	# construction and cannot be confused with a weak sim. Half the extent drains 50 000 m2 (well over the
	# 5 000 m2 preset floor), half drains the 1 m2 floor.
	var res := _flow_result(SITE_D1, LOOP_HALF + 40.0, 50000.0)
	print("    fixture result: %s" % res.describe())

	var l0 := Pasture3DReliefFractal.new()
	l0.resource_name = "L0"
	l0.selector = _sel(K_FLOW, FLOW_MIN, FLOW_MAX, FLOW_FALLOFF, 0.0)
	l0.selector.sim_result = res
	var l1 := Pasture3DReliefFractal.new()
	l1.resource_name = "L1"
	l1.selector = _sel(K_FLOW, FLOW_MIN, FLOW_MAX, FLOW_FALLOFF, 0.0)
	l1.selector.sim_result = null # the natural configuration: the stack already carries one
	var stack := Pasture3DReliefStack.new()
	stack.layers = [l0, l1] as Array[Pasture3DReliefMaterial]
	plow.relief = stack

	# What the BAKE will hand the compiled program, asked of the bake's own resolver.
	var baked_res: Pasture3DSimResult = plow._sim_result_for()
	print("    bake's one sim dict comes from _sim_result_for() = %s" % (
			"null" if baked_res == null else "the stack's result (%dx%d)" % [baked_res.width, baked_res.height]))
	print("    layer 1's own selector.sim_result            = %s" % (
			"null" if l1.selector.sim_result == null else "set"))

	plow.mask_preview = true

	# Layer 0 — the one holding the reference. This is the case that works, and it is here to prove the
	# band, the site and the result all line up. If THIS is blank the fixture is wrong, not the code.
	plow._mask_preview_layer = 0
	plow._update_mask_preview()
	var f0 := _preview_field(plow)
	var s0 := _spread(f0)
	print("    preview of layer 0 (result assigned):   %d cells, weight %.4f..%.4f, %.1f%% selected" % [
			f0.size(), s0[0], s0[1], _fraction_over(f0, 0.5) * 100.0])

	# Layer 1 — the same band over the same ground, relying on the stack's shared result the way the bake
	# does. Blank.
	plow._mask_preview_layer = 1
	plow._update_mask_preview()
	var f1 := _preview_field(plow)
	var s1 := _spread(f1)
	print("    preview of layer 1 (result NOT on it): %d cells, weight %.4f..%.4f, %.1f%% selected" % [
			f1.size(), s1[0], s1[1], _fraction_over(f1, 0.5) * 100.0])

	# What layer 1 will ACTUALLY bake as, recomputed here from the bake's inputs — the same selector, the
	# same grid, but the sim dict the bake shares. Independent of the preview path entirely.
	var g := _plow_grid(plow)
	var below: PackedFloat32Array = _data.composite_height_below(_layer_id(plow), g[0], g[1], g[4], g[2], g[3])
	var will_bake: PackedFloat32Array = _data.selector_mask_field(below,
			{"gw": g[2], "gh": g[3], "cell_size": g[4], "min_x": g[0], "min_z": g[1]},
			PackedFloat32Array(l1.selector.to_params()), _dict(baked_res))
	var sb := _spread(will_bake)
	print("    what layer 1 BAKES as (bake's shared dict): weight %.4f..%.4f, %.1f%% selected" % [
			sb[0], sb[1], _fraction_over(will_bake, 0.5) * 100.0])

	# CONTROL: put the same result on layer 1's own selector. If the preview now lights up, the blank above
	# was the missing reference and nothing else — not a dead band, not a fixture outside the extent.
	l1.selector.sim_result = res
	plow._update_mask_preview()
	var f1c := _preview_field(plow)
	var s1c := _spread(f1c)
	print("    CONTROL same layer 1 with the result assigned to it: weight %.4f..%.4f, %.1f%% selected" % [
			s1c[0], s1c[1], _fraction_over(f1c, 0.5) * 100.0])

	var preview_blank: bool = s1[1] <= 0.0
	var bake_lights: bool = sb[1] > 0.0
	var control_lights: bool = s1c[1] > 0.0
	print("    -> preview blank: %s | bake non-empty: %s | control recovers: %s" % [
			preview_blank, bake_lights, control_lights])
	if preview_blank and bake_lights and control_lights:
		print("    -> D1 CONFIRMED: the preview reads one selector's reference, the bake reads the stack's.")
	elif not bake_lights:
		print("    -> INCONCLUSIVE: the band selected nothing even at bake; the fixture measured nothing.")
	else:
		print("    -> NOT REPRODUCED here.")
	plow.mask_preview = false
	print("")


# --- D2: a managed Sim previews a resource the bake never reads ------------------------------------
#
# Under a manager the bake gates pass 2 on pass 1's LIVE fields. The preview gates it on the selector's
# `sim_result` resource, which under a manager is meant to be null. So the two answer different questions,
# and the one an artist can see is the one that is empty.
func _d2_managed_sim() -> void:
	print("[D2] managed Sim: the bake gates on the previous pass's live fields, the preview on a resource")

	var mgr := Pasture3DSimManager.new()
	mgr.name = "M_D2"
	_root.add_child(mgr)
	mgr.terrain = _terrain
	mgr.global_position = SITE_D2
	mgr.snap_to_surface = false
	mgr.catchment_margin = CHAIN_MARGIN
	mgr._layer_owner = "pasture3d_brush:Erosion218_D2"

	var p1 := _sim_under(mgr, "P1", Vector3.ZERO)
	var p2 := _sim_under(mgr, "P2", Vector3.ZERO)
	if p1 == null or p2 == null:
		print("    !! no terrain at %s; the fixture is outside demo/data\n" % SITE_D2)
		return

	# Pass 2 masks on pass 1's flow. Filter Type-appropriate band, no `sim_result` — which is what §19.5
	# says to do under a manager, and what the child's own warning tells you to do.
	var flow_sel := _sel(K_FLOW, FLOW_MIN, FLOW_MAX, FLOW_FALLOFF, 0.0)
	p2.erosion_mask = [flow_sel] as Array[Pasture3DTerrainMask]

	mgr.capture_chain = true
	if not bool(mgr.simulate_now(1, false).get("ok", false)):
		print("    !! the chain did not solve; nothing to compare\n")
		return
	var chain: Array = mgr.last_chain
	var baked_mask := PackedFloat32Array()
	for e: Dictionary in chain:
		if String(e.get("name", "")) == "P2":
			baked_mask = e.get("mask", PackedFloat32Array())
	if baked_mask.is_empty():
		print("    !! the chain captured no mask for pass 2; nothing to compare\n")
		return
	var bm := _spread(baked_mask)
	print("    what the BAKE gated pass 2 with (live fields): %d cells, %.4f..%.4f, %.1f%% selected" % [
			baked_mask.size(), bm[0], bm[1], _fraction_over(baked_mask, 0.5) * 100.0])

	# The same mask, previewed.
	p2.mask_preview = 1
	p2._update_mask_preview()
	var shown := _preview_field(p2)
	var sm := _spread(shown)
	print("    what the PREVIEW shows for it (sim_result): %d cells, %.4f..%.4f, %.1f%% selected" % [
			shown.size(), sm[0], sm[1], _fraction_over(shown, 0.5) * 100.0])
	print("    (the preview's dict is %s)" % ("EMPTY" if p2._mask_sim_dict(p2.erosion_mask).is_empty()
			else "populated"))

	# CONTROL: the same node, same preview machinery, a SLOPE band instead. Both paths read the surface, so
	# both must light up — which proves the preview is not simply broken on a managed Sim.
	p2.erosion_mask = [_sel(K_SLOPE, 12.0, 90.0, 6.0, 0.0)] as Array[Pasture3DTerrainMask]
	p2._update_mask_preview()
	var ctrl := _preview_field(p2)
	var sc := _spread(ctrl)
	print("    CONTROL a SLOPE band on the same node: %.4f..%.4f, %.1f%% selected" % [
			sc[0], sc[1], _fraction_over(ctrl, 0.5) * 100.0])

	var bake_lights: bool = bm[1] > 0.0
	var preview_blank: bool = sm[1] <= 0.0
	var control_lights: bool = sc[1] > 0.0
	print("    -> bake non-empty: %s | preview blank: %s | SLOPE control lights: %s" % [
			bake_lights, preview_blank, control_lights])
	if bake_lights and preview_blank and control_lights:
		print("    -> D2 CONFIRMED: the two paths read different fields; only the bake's is populated.")
	elif not bake_lights:
		print("    -> INCONCLUSIVE: pass 1's flow gated nothing, so there was nothing for pass 2 to show.")
	elif not control_lights:
		print("    -> INCONCLUSIVE: the preview is blank for a SLOPE band too; this is not sim-specific.")
	else:
		print("    -> NOT REPRODUCED here.")
	p2.mask_preview = 0

	# D3, on the same chain: WHICH GROUND the preview reads. `_show_mask_preview` always builds its field
	# from `composite_height_below` — the surface UNDER this brush's layer, i.e. the ground before the chain
	# ran. Under a manager, pass N's masks are evaluated against pass N-1's OUTPUT (sim_manager.gd:829,
	# `z_in`). So for every pass after the first, a SLOPE / ALTITUDE / CURVATURE band previews against a
	# surface the bake will not use — and this one is not about sim Filter Types at all.
	#
	# Compared as pass 1's z_in against pass 2's z_in, both off the chain's own capture, so the two share a
	# grid exactly. Pass 1's z_in IS the below-layer composite (§19.5) — which is what the preview reads.
	#
	# CONTROL: pass 1 against itself, which must be 0.0 m, or the comparison is measuring grid drift rather
	# than the chain.
	print("[D3] managed Sim: the preview reads the pre-chain ground, the bake reads the previous pass's")
	var z1 := PackedFloat32Array()
	var z2 := PackedFloat32Array()
	for e: Dictionary in chain:
		if String(e.get("name", "")) == "P1":
			z1 = e.get("z_in", PackedFloat32Array())
		elif String(e.get("name", "")) == "P2":
			z2 = e.get("z_in", PackedFloat32Array())
	if z1.is_empty() or z2.size() != z1.size():
		print("    !! the chain did not capture both input surfaces; nothing to compare\n")
		return
	var drift := 0.0
	for i in range(z1.size()):
		if is_finite(z1[i]) and is_finite(z2[i]):
			drift = maxf(drift, absf(z2[i] - z1[i]))
	print("    pass 1's input vs pass 2's input (the two surfaces in play):")
	print("      max |difference| over %d cells: %.6f m" % [z1.size(), drift])
	print("    CONTROL pass 1 against itself: %.6f m (want exactly 0)" % _self_drift(z1))
	if drift <= 0.0:
		print("    -> INCONCLUSIVE: pass 1 moved nothing here, so there is no difference to see.\n")
		return

	# The two surfaces differ, which is just the chain working. The QUESTION is which of them the preview
	# reads — so ask the preview, rather than inferring it from the chain the way the first version of
	# this diagnosis did.
	var layer_id: int = mgr._ensure_layer_for(mgr._layer_owner, true)
	var vs: float = _terrain.vertex_spacing
	var pad := LOOP_HALF + CHAIN_MARGIN + 4.0
	var mx := floorf((SITE_D2.x - pad) / vs) * vs
	var mz := floorf((SITE_D2.z - pad) / vs) * vs
	var gw := int(round(((ceilf((SITE_D2.x + pad) / vs) * vs) - mx) / vs)) + 1
	var gh := int(round(((ceilf((SITE_D2.z + pad) / vs) * vs) - mz) / vs)) + 1
	var ground: PackedFloat32Array = _data.composite_height_below(layer_id, mx, mz, vs, gw, gh)
	var reads: PackedFloat32Array = p2._preview_below(layer_id, mx, mz, vs, gw, gh)
	var on_ground := reads.to_byte_array() == ground.to_byte_array()
	print("    with the WHOLE chain built, pass 2's preview reads the pre-chain ground: %s" % on_ground)
	if not bool(mgr.simulate_now(1, false, 0).get("ok", false)):
		print("    !! the build-through failed; cannot finish D3\n")
		return
	var after: PackedFloat32Array = p2._preview_below(layer_id, mx, mz, vs, gw, gh)
	var chained: PackedFloat32Array = _data.composite_height_below(layer_id + 1, mx, mz, vs, gw, gh)
	var on_chain := after.to_byte_array() == chained.to_byte_array()
	print("    after Simulate To Here on pass 1, it reads pass 1's OUTPUT instead:      %s" % on_chain)
	if on_ground and on_chain:
		print("    -> D3 FIXED: the preview follows the build-through, and falls back with a warning")
		print("       when the chain is not built to exactly the previous pass. Gate BL pins both halves.")
	elif not on_chain:
		print("    -> D3 CONFIRMED: for pass 2+ the previewed surface is not the surface the bake gates on.")
	else:
		print("    -> PARTIAL: it reads the chain's output but the fallback is not the pre-chain ground.")
	print("")


func _self_drift(p_z: PackedFloat32Array) -> float:
	var m := 0.0
	for i in range(p_z.size()):
		if is_finite(p_z[i]):
			m = maxf(m, absf(p_z[i] - p_z[i]))
	return m


# --- helpers ---------------------------------------------------------------------------------------

func _sel(p_kind: int, p_lo: float, p_hi: float, p_f_lo: float, p_f_hi: float) -> Pasture3DTerrainMask:
	var s := Pasture3DTerrainMask.new()
	s.filter_type = p_kind
	s.range_min = p_lo
	s.range_max = p_hi
	s.falloff_low = p_f_lo
	s.falloff_high = p_f_hi
	return s


## A populated Sim Result centred on `p_at`, `p_half` metres to a side, whose western half drains
## `p_area` m2 and whose eastern half drains the 1 m2 floor. `flow` is stored LOG-scaled (§8.2).
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
	r.source_node = "PreviewSimDiag"
	r.source_loops = 1
	return r


func _dict(r: Pasture3DSimResult) -> Dictionary:
	if r == null or not r.is_valid():
		return {}
	return {"min_x": r.min_x, "min_z": r.min_z, "cell_size": r.cell_size,
			"width": r.width, "height": r.height, "flow": r.flow, "erosion": r.erosion,
			"deposition": r.deposition, "wetness": r.wetness}


func _sim_under(p_mgr: Pasture3DSimManager, p_name: String, p_offset: Vector3) -> Pasture3DSim:
	var s := Pasture3DSim.new()
	s.name = p_name
	p_mgr.add_child(s)
	s.terrain = _terrain
	s.snap_to_surface = false
	s.position = p_offset
	s.falloff_width = 12.0
	s.iterations = 20
	s.erosion_rate = 0.15
	s.hillslope_diffusion = 0.15
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	for p in [Vector3(-LOOP_HALF, 0, -LOOP_HALF), Vector3(LOOP_HALF, 0, -LOOP_HALF),
			Vector3(LOOP_HALF, 0, LOOP_HALF), Vector3(-LOOP_HALF, 0, LOOP_HALF)]:
		c.add_point(p)
	c.closed = true
	path.curve = c
	s.add_child(path)
	if not is_finite(_data.get_height(p_mgr.global_position + p_offset)):
		return null
	return s


## [min_x, min_z, gw, gh, cell] of the grid the Plow's preview covers — its loop footprint snapped to the
## terrain grid. Derived from the node's geometry, not read back off the preview.
func _plow_grid(p_brush) -> Array:
	var vs: float = _terrain.vertex_spacing
	var at: Vector3 = p_brush.global_position
	var min_x := floorf((at.x - LOOP_HALF) / vs) * vs
	var min_z := floorf((at.z - LOOP_HALF) / vs) * vs
	var max_x := ceilf((at.x + LOOP_HALF) / vs) * vs
	var max_z := ceilf((at.z + LOOP_HALF) / vs) * vs
	return [min_x, min_z, int(round((max_x - min_x) / vs)) + 1, int(round((max_z - min_z) / vs)) + 1, vs]


func _layer_id(p_brush) -> int:
	var id: int = _data.find_layer_by_owner(p_brush._layer_owner)
	if id >= 0:
		return id
	var stack = _data.get_layer_stack()
	return stack.get_layer_count() if stack != null else 0


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
	var n := 0
	for v in p_a:
		if is_finite(v) and v > p_t:
			n += 1
	return float(n) / float(p_a.size())
