# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Phase 5.5 gates AS-AX for the mask preview (PASTURE3D_SIM_NODE_SPEC.md §18.7).
#
# WHAT THIS GATE DOES NOT TEST: the red pixels. The overlay is a `DEBUG_MASK_PREVIEW` shader insert, and
# a headless run has no viewport to photograph — so nothing here proves the terrain is tinted, that the
# tint follows the weight, or that the 0.5 band line is drawn. Those need an editor. This is the same
# accommodation gates M4 and AO make, and it is stated in the output rather than left for a reader to
# infer from four green lines.
#
# WHAT IT DOES TEST is the claim the feature actually rests on: **what you see is what will bake.** The
# texture handed to the material is the bake's own mask over the bake's own grid, its rect registers with
# the world, only one brush can own the overlay, and turning it off leaves nothing behind. Every one of
# those is answerable without a pixel.
#
# NOTHING IS SAVED. Bakes write into the terrain's in-memory layer; demo/data on disk is only touched by
# an explicit save, which nothing here calls.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/SimPhase55Gate.tscn
extends Node

const DEMO_DATA := "res://demo/data"

const K_SLOPE := 0
const K_ALTITUDE := 1

const SITE_A := Vector3(300.0, 0.0, 300.0)
const SITE_B := Vector3(700.0, 0.0, 300.0)

const LOOP_HALF := 60.0
const NODE_MARGIN := 40.0

var _fail := 0
var _root: Node3D
var _terrain
var _data
var _mat


func _ready() -> void:
	print("\n=== Pasture3DSim phase 5.5 (spec §18.7 gates AS-AX) ===\n")
	print("NOTE: the rendered overlay is UNGATED here — headless has no viewport. These criteria test")
	print("      that the previewed field IS the bake's field, not that it appears on screen.\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_data = _terrain.data
	_mat = _terrain.material
	if _data == null or not _data.has_method("selector_mask_field"):
		_fail += 1
		print("!! this build has no selector_mask_field — phase 5 is unbuilt, not failing")
		_done()
		return
	if _mat == null or not _mat.has_method("set_mask_preview"):
		_fail += 1
		print("!! this build has no mask preview material API — phase 5.5 is unbuilt, not failing")
		_done()
		return

	_gate_as_same_field()
	_gate_at_rect()
	_gate_au_one_owner()
	_gate_av_leaves_nothing()
	_gate_aw_clipped_to_brush()
	await _gate_ax_live_update()

	_done()


func _done() -> void:
	print("\n=== %s (%d failures) ===\n" % ["SIM PHASE 5.5 PASS" if _fail == 0 else "SIM PHASE 5.5 FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- AS: the preview is the bake's own mask --------------------------------------------------------
# The texture the node hands the material must be the SAME field `selector_mask_field` produces over the
# same grid, at the same resolution, off the same source surface. Recomputed here independently and
# compared cell for cell.
#
# CONTROL: the same field built at preview resolution, which must DIFFER on a slope band. §17.5 says
# slope is measured over the grid spacing, so a coarser grid gates differently — if the two agree, the
# fixture is flat and "at build resolution" is an untested claim.
func _gate_as_same_field() -> void:
	print("[AS] the previewed field is the bake's own field:")
	var sim = _make_sim("AS", SITE_A)
	if sim == null:
		return
	sim.erosion_mask = [_sel(K_SLOPE, 12.0, 90.0, 6.0, 0.0)] as Array[Pasture3DReliefSelector]
	sim.mask_preview = 1
	if not sim._owns_mask_preview():
		_fail += 1
		print("    !! the node did not claim the preview; nothing to compare")
		return

	# What the preview shows.
	var shown := _preview_field(sim)
	if shown.is_empty():
		_fail += 1
		print("    !! could not read the preview texture back")
		return

	# What a bake would APPLY, recomputed here from the same inputs: the selector field times the loop's
	# own area mask. Both halves come from the bake's functions (`selector_mask_field`, `sim_mask_deltas`),
	# assembled here rather than read back off the brush — the claim is that the preview equals what the
	# bake applies, so the gate has to build that from the bake's side.
	var g := _preview_grid(sim)
	var raw: PackedFloat32Array = _data.selector_mask_field(
			_below(sim, g), {"gw": g[2], "gh": g[3], "cell_size": g[4], "min_x": g[0], "min_z": g[1]},
			_block(sim.erosion_mask), {})
	var want := raw.duplicate()
	var area := _area_mask(sim, g)
	if area.size() == want.size():
		for i in range(want.size()):
			want[i] *= area[i]
	if want.size() != shown.size():
		_fail += 1
		print("    !! sizes differ: preview %d, bake %d" % [shown.size(), want.size()])
		return
	var spread := _spread(want)
	print("    grid %dx%d at %.2f m; the field really varies (min %.3f, max %.3f)" % [
			g[2], g[3], g[4], spread[0], spread[1]])
	if spread[1] - spread[0] < 0.5:
		_fail += 1
		print("    !! the mask is nearly constant here; AS would agree on a field of ones")
		return
	var worst := _max_abs_diff(shown, want)
	print("    max |preview - bake| over %d cells: %.9f" % [shown.size(), worst])
	# The texture round-trips through FORMAT_RF, so this is float32 exact, not merely close.
	if worst != 0.0:
		_fail += 1
		print("    !! the preview is not the field the bake will use")

	# CONTROL: a coarser grid must gate differently. Compared UNCLIPPED against UNCLIPPED — the loop mask
	# is not part of this claim, and comparing a coarse unclipped field against a fine clipped one would
	# differ for a reason that has nothing to do with resolution.
	var cw: int = maxi(int(g[2] / 4), 8)
	var ch: int = maxi(int(g[3] / 4), 8)
	var ccell: float = g[4] * float(g[2] - 1) / float(cw - 1)
	var coarse: PackedFloat32Array = _data.selector_mask_field(
			_data.resample_grid(_below(sim, g), g[2], g[3], cw, ch),
			{"gw": cw, "gh": ch, "cell_size": ccell, "min_x": g[0], "min_z": g[1]},
			_block(sim.erosion_mask), {})
	var mean_fine := _mean(raw)
	var mean_coarse := _mean(coarse)
	print("    CONTROL same band at 1/4 resolution: mean weight %.4f vs %.4f (want different)" % [
			mean_coarse, mean_fine])
	if absf(mean_coarse - mean_fine) < 0.005:
		_fail += 1
		print("    !! resolution does not change this band, so 'at build resolution' is untested here")
	sim.mask_preview = 0


# --- AT: the rect registers with the world ---------------------------------------------------------
# The rect handed to the material maps texel centres onto the grid's world samples. Checked by inverting
# the shader's own mapping at known world points and confirming it lands on the right texel.
#
# CONTROL: the rect displaced by one catchment margin, which must land different texels — the mistake an
# off-by-one grid origin makes, and one §17.8's AF already caught once in the field lookup.
func _gate_at_rect() -> void:
	print("[AT] the preview rect registers with the world:")
	var sim = _make_sim("AT", SITE_A)
	if sim == null:
		return
	sim.erosion_mask = [_sel(K_ALTITUDE, -1.0e6, 1.0e6, 0.0, 0.0)] as Array[Pasture3DReliefSelector]
	sim.mask_preview = 1
	var rect: Vector4 = sim._mask_preview_rect
	var g := _preview_grid(sim)
	if rect.z <= 0.0 or rect.w <= 0.0:
		_fail += 1
		print("    !! no rect recorded; the preview did not build")
		return

	# The shader does uv = (world - rect.xy) / rect.zw, then samples a gw x gh texture with linear filter,
	# so world sample (ix,iz) must land exactly on texel centre (ix+0.5)/gw.
	var worst := 0.0
	for probe in [[0, 0], [g[2] - 1, 0], [0, g[3] - 1], [g[2] - 1, g[3] - 1], [g[2] / 2, g[3] / 3]]:
		var wx: float = g[0] + float(probe[0]) * g[4]
		var wz: float = g[1] + float(probe[1]) * g[4]
		var u := (wx - rect.x) / rect.z
		var v := (wz - rect.y) / rect.w
		worst = maxf(worst, absf(u * float(g[2]) - (float(probe[0]) + 0.5)))
		worst = maxf(worst, absf(v * float(g[3]) - (float(probe[1]) + 0.5)))
	print("    max texel-centre error over 5 probes (corners + interior): %.6f texels" % worst)
	if worst > 0.001:
		_fail += 1
		print("    !! world-to-uv does not land on texel centres; the overlay is offset from the mask")

	# CONTROL: displace the rect origin by one margin.
	var moved := 0.0
	for probe in [[0, 0], [g[2] / 2, g[3] / 3]]:
		var wx: float = g[0] + float(probe[0]) * g[4]
		var u_ok := (wx - rect.x) / rect.z
		var u_bad := (wx - (rect.x + NODE_MARGIN)) / rect.z
		moved = maxf(moved, absf(u_ok - u_bad) * float(g[2]))
	print("    CONTROL origin displaced by %.0f m: %.1f texels of error (want many)" % [NODE_MARGIN, moved])
	if moved < 1.0:
		_fail += 1
		print("    !! displacing the origin barely moves the lookup; AT cannot see a misregistered rect")
	sim.mask_preview = 0


# --- AU: one owner ---------------------------------------------------------------------------------
# There is one set of preview uniforms on the terrain material, so enabling a preview on a second brush
# must take it from the first, and the first must be able to tell.
#
# CONTROL: a single brush left enabled, which must STAY the owner. Without it, "exclusive" is
# indistinguishable from "the preview never turns on at all".
func _gate_au_one_owner() -> void:
	print("[AU] only one brush owns the preview:")
	var a = _make_sim("AU_A", SITE_A)
	var b = _make_sim("AU_B", SITE_B)
	if a == null or b == null:
		return
	var sel: Array[Pasture3DReliefSelector] = [_sel(K_SLOPE, 8.0, 90.0, 4.0, 0.0)]
	a.erosion_mask = sel
	b.erosion_mask = sel

	a.mask_preview = 1
	var a_alone: bool = a._owns_mask_preview()
	print("    CONTROL one brush enabled: A owns it = %s (want true)" % a_alone)
	if not a_alone:
		_fail += 1
		print("    !! enabling a preview did not claim it; AU would 'pass' on a feature that never runs")
		return

	b.mask_preview = 1
	print("    after B enables: A owns = %s, B owns = %s (want false, true)" % [
			a._owns_mask_preview(), b._owns_mask_preview()])
	if a._owns_mask_preview() or not b._owns_mask_preview():
		_fail += 1
		print("    !! two brushes can hold the preview at once, or the second failed to claim it")

	# A must not be able to blank B's preview while cleaning up after itself.
	a.mask_preview = 0
	print("    after A turns itself off: B still owns = %s (want true)" % b._owns_mask_preview())
	if not b._owns_mask_preview():
		_fail += 1
		print("    !! a node clearing up took down another brush's preview")
	b.mask_preview = 0


# --- AV: it leaves nothing behind ------------------------------------------------------------------
# Disabling must drop the owner, the texture and the shader insert, and must never have touched the
# terrain data — a preview that wrote to a layer would be a bake wearing a different name.
#
# CONTROL: the same readings taken WITH the preview on, which must differ. Otherwise AV is comparing two
# identical no-ops and would pass on a feature that does nothing.
func _gate_av_leaves_nothing() -> void:
	print("[AV] disabling leaves nothing behind:")
	var sim = _make_sim("AV", SITE_A)
	if sim == null:
		return
	var probes := _probe_ring(SITE_A)
	var before := _snapshot(probes)
	sim.erosion_mask = [_sel(K_SLOPE, 8.0, 90.0, 4.0, 0.0)] as Array[Pasture3DReliefSelector]

	sim.mask_preview = 1
	var on_owner: int = int(_mat.get_mask_preview_owner())
	var on_code: String = _shader_code()
	var on_has_insert: bool = on_code.contains("_mask_preview_tex")
	print("    CONTROL with the preview ON: owner %d, shader carries the insert = %s (both want set)" % [
			on_owner, on_has_insert])
	if on_owner == 0 or not on_has_insert:
		_fail += 1
		print("    !! the preview never turned on, so 'it leaves nothing behind' proves nothing")
		return

	sim.mask_preview = 0
	var off_owner: int = int(_mat.get_mask_preview_owner())
	var off_has_insert: bool = _shader_code().contains("_mask_preview_tex")
	print("    with it OFF: owner %d, shader carries the insert = %s (both want clear)" % [
			off_owner, off_has_insert])
	if off_owner != 0:
		_fail += 1
		print("    !! the material still names an owner")
	if off_has_insert:
		_fail += 1
		print("    !! the shader still carries the preview insert; it would ship in a build")

	var moved := _max_abs_diff(before, _snapshot(probes))
	print("    terrain height touched by the whole preview cycle: %.9f m (want exactly 0)" % moved)
	if moved != 0.0:
		_fail += 1
		print("    !! the preview wrote to the terrain; it is a bake wearing another name")


# --- AW: the preview shows where the BRUSH acts, not the whole grid --------------------------------
# The selector weight is defined over the entire grid, but the brush only applies it inside its own loop.
# Showing the raw weight paints the footprint rectangle and overstates the affected area — reported from
# the editor on the first build of this feature, where a Mound's red square dwarfed the mound.
#
# Also checks the second half of "leaves nothing behind": previewing must not CREATE the brush's layer.
#
# CONTROL: the unclipped field, which must cover cells the clipped one does not. If the loop already
# filled its own bounding box there would be nothing to clip and the criterion would be empty.
func _gate_aw_clipped_to_brush() -> void:
	print("[AW] the preview is clipped to where the brush acts:")
	var sim = _make_sim("AW", SITE_B)
	if sim == null:
		return
	# A band that passes everywhere, so anything NOT red is the clip and not the selector.
	sim.erosion_mask = [_sel(K_ALTITUDE, -1.0e6, 1.0e6, 0.0, 0.0)] as Array[Pasture3DReliefSelector]

	var layers_before := _layer_count()
	sim.mask_preview = 1
	var layers_after := _layer_count()
	print("    layers in the stack: %d before the preview, %d after (want equal)" % [
			layers_before, layers_after])
	if layers_after != layers_before:
		_fail += 1
		print("    !! previewing created a layer; that is not 'leaves nothing behind'")

	var shown := _preview_field(sim)
	if shown.is_empty():
		_fail += 1
		print("    !! no preview to inspect")
		return
	var lit := 0
	for v in shown:
		if v > 0.01:
			lit += 1
	var frac := float(lit) / float(shown.size())
	# The loop is a 120 m square inside a grid grown by a 40 m margin on every side, so the loop covers
	# (120/200)^2 = 36% of it. Anything near 100% means the clip is not happening.
	print("    %d of %d cells lit (%.1f%%); the loop covers about 36%% of the grid" % [
			lit, shown.size(), 100.0 * frac])
	if frac > 0.60:
		_fail += 1
		print("    !! the preview covers far more than the loop; it is painting the bounding box")
	if frac < 0.15:
		_fail += 1
		print("    !! almost nothing is lit; the clip has eaten the mask as well as the margin")

	# CONTROL: the unclipped field must light cells the clipped one does not.
	var g := _preview_grid(sim)
	var raw: PackedFloat32Array = _data.selector_mask_field(
			_below(sim, g), {"gw": g[2], "gh": g[3], "cell_size": g[4], "min_x": g[0], "min_z": g[1]},
			_block(sim.erosion_mask), {})
	var raw_lit := 0
	for v in raw:
		if v > 0.01:
			raw_lit += 1
	print("    CONTROL unclipped: %d cells lit (want many more than %d)" % [raw_lit, lit])
	if raw_lit <= lit:
		_fail += 1
		print("    !! the unclipped field lights no extra cells, so there was nothing for the clip to do")
	sim.mask_preview = 0


# --- AX: editing a selector updates the overlay ----------------------------------------------------
# A Pasture3DReliefSelector is a Resource: the inspector mutates it in place and fires `changed`. Without
# a connection the node never hears, and the overlay only moved when the toggle was flipped — reported
# from the editor as "the preview does not update live when editing".
#
# The rebuild is deferred so a burst of edits in one frame costs one rebuild, hence the frame wait.
#
# CONTROL: the edit must be one that actually changes the field, computed independently. Nudging a band
# that gates the same cells either way would make "the texture changed" impossible to fail.
func _gate_ax_live_update() -> void:
	print("[AX] editing a selector rebuilds the overlay:")
	var sim = _make_sim("AX", SITE_B)
	if sim == null:
		return
	var sel := _sel(K_ALTITUDE, 40.0, 1.0e6, 0.0, 0.0)
	sim.erosion_mask = [sel] as Array[Pasture3DReliefSelector]
	sim.mask_preview = 1
	# Drain anything already queued before recording the baseline. `_ready` queues a rebuild of its own,
	# and the first version of this criterion was measuring THAT firing on the awaited frame rather than
	# the selector's signal — it passed with the signal connection disabled, which is what the break test
	# is for. After this await the only thing left that can rebuild the overlay is the edit below.
	await get_tree().process_frame
	var before := _preview_field(sim)
	if before.is_empty():
		_fail += 1
		print("    !! no preview to start from")
		return

	# CONTROL: what the field becomes with the new band, worked out here rather than read back.
	var g := _preview_grid(sim)
	var moved := _sel(K_ALTITUDE, 80.0, 1.0e6, 0.0, 0.0)
	var want: PackedFloat32Array = _data.selector_mask_field(
			_below(sim, g), {"gw": g[2], "gh": g[3], "cell_size": g[4], "min_x": g[0], "min_z": g[1],
			"area_mask": _area_mask(sim, g)}, _block([moved]), {})
	var delta := _max_abs_diff(before, want)
	print("    CONTROL the edit changes the field by %.4f at most (want > 0.01)" % delta)
	if delta <= 0.01:
		_fail += 1
		print("    !! this band edit gates the same cells; AX could not fail")
		return

	sel.range_min = 80.0 # mutates in place and emits `changed`, exactly as the inspector does
	var immediate := _max_abs_diff(_preview_field(sim), before)
	await get_tree().process_frame
	var after := _preview_field(sim)
	print("    same frame: overlay moved %.4f; after one frame: %.9f from the expected field" % [
			immediate, _max_abs_diff(after, want)])
	if _max_abs_diff(after, want) != 0.0:
		_fail += 1
		print("    !! editing the selector did not rebuild the overlay")
	sim.mask_preview = 0


# --- helpers --------------------------------------------------------------------------------------

func _sel(p_kind: int, p_lo: float, p_hi: float, p_f_lo: float, p_f_hi: float) -> Pasture3DReliefSelector:
	var s := Pasture3DReliefSelector.new()
	s.kind = p_kind
	s.range_min = p_lo
	s.range_max = p_hi
	s.falloff_low = p_f_lo
	s.falloff_high = p_f_hi
	return s


func _block(p_list: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for s: Pasture3DReliefSelector in p_list:
		out.append_array(PackedFloat32Array(s.to_params()))
	return out


## [min_x, min_z, gw, gh, cell] of the grid a Sim's preview covers — its loops grown by the catchment
## margin, snapped to the terrain grid. Derived here from the node's own public geometry rather than read
## back out of the brush, so AS is not asking the code under test where it decided to look.
func _preview_grid(p_sim) -> Array:
	var vs: float = _terrain.vertex_spacing
	var box := AABB()
	var have := false
	for s in p_sim.get_children():
		if not (s is Path3D) or s.curve == null:
			continue
		var pts := PackedVector3Array()
		var xf: Transform3D = s.global_transform
		for pt in s.curve.get_baked_points():
			pts.append(xf * pt)
		var mn := Vector2(pts[0].x, pts[0].z)
		var mx := mn
		for pt in pts:
			mn.x = minf(mn.x, pt.x)
			mn.y = minf(mn.y, pt.z)
			mx.x = maxf(mx.x, pt.x)
			mx.y = maxf(mx.y, pt.z)
		var pad: float = maxf(p_sim.edge_offset, 0.0) + 2.0
		var a := AABB(Vector3(mn.x - pad, -10000.0, mn.y - pad),
				Vector3(mx.x - mn.x + pad * 2.0, 20000.0, mx.y - mn.y + pad * 2.0)).grow(p_sim.catchment_margin)
		box = a if not have else box.merge(a)
		have = true
	var min_x := floorf(box.position.x / vs) * vs
	var min_z := floorf(box.position.z / vs) * vs
	var max_x := ceilf((box.position.x + box.size.x) / vs) * vs
	var max_z := ceilf((box.position.z + box.size.z) / vs) * vs
	return [min_x, min_z, int(round((max_x - min_x) / vs)) + 1, int(round((max_z - min_z) / vs)) + 1, vs]


## The surface the mask is built from. A brush with no layer yet will be appended at the TOP of the
## stack, so everything currently in it is below — stated here independently rather than read back off
## the brush, so AS is not asking the code under test which surface it chose.
func _below(p_sim, p_g: Array) -> PackedFloat32Array:
	var layer_id: int = _data.find_layer_by_owner(p_sim._layer_owner)
	if layer_id < 0:
		layer_id = _layer_count()
	return _data.composite_height_below(layer_id, p_g[0], p_g[1], p_g[4], p_g[2], p_g[3])


## The preview texture read back as a flat float array.
func _preview_field(p_sim) -> PackedFloat32Array:
	var tex: ImageTexture = p_sim._mask_preview_texture
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


## The generated shader's SOURCE, not its uniform list.
##
## RenderingServer.get_shader_parameter_list() looked like the natural way to ask "is the insert compiled
## in", and it answers the ADD direction correctly — but it caches per shader RID and never purges
## uniforms that disappear, so a debug view that has been switched OFF still lists its uniforms. Verified
## against the shipped `set_show_heightmap(false)`, which leaves `heightmap_black_height` behind exactly
## the same way. Reading the source is the only way to see a removal.
func _shader_code() -> String:
	return _mat.get_generated_shader_code()


## The loop's own area mask over the preview grid, from the BAKE's masker fed a delta of all ones —
## edge offset, falloff width and curve included. Assembled here from the Sim's public properties, not
## taken from the preview path.
func _area_mask(p_sim, p_g: Array) -> PackedFloat32Array:
	var n: int = p_g[2] * p_g[3]
	var ones := PackedFloat32Array()
	ones.resize(n)
	ones.fill(1.0)
	var out := PackedFloat32Array()
	out.resize(n)
	for s in p_sim.get_children():
		if not (s is Path3D) or s.curve == null:
			continue
		var poly := PackedVector2Array()
		var xf: Transform3D = s.global_transform
		for pt in s.curve.get_baked_points():
			poly.append(Vector2((xf * pt).x, (xf * pt).z))
		poly = _decimate(poly, maxf(_terrain.vertex_spacing, 0.25))
		if poly.size() < 3:
			continue
		var m: PackedFloat32Array = _data.sim_mask_deltas(ones, poly, {
				"sw": p_g[2], "sh": p_g[3], "gw": p_g[2], "gh": p_g[3],
				"sim_min_x": p_g[0], "sim_min_z": p_g[1], "sim_cell": p_g[4],
				"min_x": p_g[0], "min_z": p_g[1], "vs": p_g[4],
				"edge_offset": p_sim.edge_offset, "falloff_width": maxf(p_sim.falloff_width, 0.001),
			}, _ramp_lut(p_sim.falloff_curve))
		if m.size() != n:
			continue
		for i in range(n):
			if is_finite(m[i]):
				out[i] = maxf(out[i], clampf(m[i], 0.0, 1.0))
	return out


## Mirrors Pasture3DTerrainBrush._decimate — the polygon a Sim hands the masker is decimated to terrain
## resolution, so a gate that skips that step compares two different polygons.
func _decimate(p_pts: PackedVector2Array, p_step: float) -> PackedVector2Array:
	var n := p_pts.size()
	if n < 3:
		return p_pts
	var out := PackedVector2Array()
	out.append(p_pts[0])
	var acc := 0.0
	for i in range(1, n):
		acc += p_pts[i].distance_to(p_pts[i - 1])
		if acc >= p_step:
			out.append(p_pts[i])
			acc = 0.0
	return out


## Default smoothstep ramp LUT, matching Pasture3DTerrainBrush._ramp_lut with a null curve.
func _ramp_lut(p_curve: Curve) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(256)
	for i in range(256):
		var x := float(i) / 255.0
		out[i] = p_curve.sample_baked(x) if p_curve != null else smoothstep(0.0, 1.0, x)
	return out


func _layer_count() -> int:
	var stack = _data.get_layer_stack()
	return stack.get_layer_count() if stack != null else 0


func _spread(p_a: PackedFloat32Array) -> Array:
	var lo := INF
	var hi := -INF
	for v in p_a:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return [lo, hi]


func _mean(p_a: PackedFloat32Array) -> float:
	var s := 0.0
	for v in p_a:
		s += v
	return s / maxf(float(p_a.size()), 1.0)


func _max_abs_diff(p_a, p_b) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		if is_finite(p_a[i]) and is_finite(p_b[i]):
			m = maxf(m, absf(p_a[i] - p_b[i]))
	return m


func _make_sim(p_name: String, p_at: Vector3):
	if not is_finite(_height(p_at)):
		_fail += 1
		print("    !! no terrain at %s; the fixture is outside demo/data" % p_at)
		return null
	var sim := Pasture3DSim.new()
	sim.name = p_name
	_root.add_child(sim)
	sim.terrain = _terrain
	sim.global_position = p_at
	sim.catchment_margin = NODE_MARGIN
	sim.snap_to_surface = false
	sim._layer_owner = "pasture3d_brush:Erosion_%s" % p_name
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	c.add_point(Vector3(-LOOP_HALF, 0.0, -LOOP_HALF))
	c.add_point(Vector3(LOOP_HALF, 0.0, -LOOP_HALF))
	c.add_point(Vector3(LOOP_HALF, 0.0, LOOP_HALF))
	c.add_point(Vector3(-LOOP_HALF, 0.0, LOOP_HALF))
	c.closed = true
	path.curve = c
	sim.add_child(path)
	return sim


func _probe_ring(p_at: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for dz in [-30.0, 0.0, 30.0]:
		for dx in [-30.0, 0.0, 30.0]:
			out.append(p_at + Vector3(dx, 0.0, dz))
	return out


func _snapshot(p_points: Array[Vector3]) -> Array[float]:
	var out: Array[float] = []
	for p in p_points:
		out.append(_height(p))
	return out


func _height(p_at: Vector3) -> float:
	return _data.get_height(Vector3(p_at.x, 0.0, p_at.z))
