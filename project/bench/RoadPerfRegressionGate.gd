# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadPerfRegressionGate — the two regressions the dirty-rect / native-stamp optimisation series left
# behind (PASTURE3D_ROAD_PERF_REGRESSION_SPEC.md §2, gates [P] and [Q]).
#
# ---- WHY THIS IS ITS OWN GATE ----
#
# The spec put [P] in MarginSeamGate and [Q] in RoadPaintGate, and neither fits. MarginSeamGate is a
# one-row mask fixture about the margin band and knows nothing about splines or dirty rects.
# RoadPaintGate's header states outright that it does not drive a real Pasture3D terrain — true of the
# GDScript kernel it gates, but [Q] is about the NATIVE `stamp_road_surface_control`, which reads the
# terrain back and therefore needs one. Bolting either criterion onto those files would have meant
# amending a header into something it isn't. Both regressions come from one change series, so they get
# one gate.
#
# ---- WHAT EACH HALF ACTUALLY MEASURES ----
#
# [A]/[B] are the ghost cut. The bug is a BOX, not a pixel: `_spline_dirty_aabb` decides what gets
# cleared, so if the box does not cover where the brush used to be, the old cut survives no matter what
# the rasteriser does afterwards. Measuring the box is measuring the bug, and it is closed form.
# [B] is the other half and the reason [A] cannot be passed by simply widening everything: the partial
# path must stay NARROW, because that narrowness is the 93x win the series bought. A fix that unioned
# the previous box into both paths would pass [A] and hand the speedup straight back, and [B] is what
# refuses it.
#
# [C]/[D] are texture 31. `get_control` answers UINT32_MAX for a cell with no control data, which is not
# a control word — decoded it is base id 31 with both preserve bits set.
#
# Reaching it needed a state the ordinary APIs will not produce, and that is worth saying plainly rather
# than dressing up: a region always exists WITH a control map (`set_control_map(null)` sanitises a blank
# one straight back in), and where no region exists the write is dropped too, so the read and the write
# normally fail together and the bug stays invisible. What DOES survive sanitising is a correctly sized,
# correctly formatted control map holding NaN — the engine's own no-data pixel, which is what a region
# restored from a truncated or legacy `.res` carries and what `get_pixel` maps to UINT32_MAX. So the
# fixture writes that map directly. [C] therefore gates the normalisation itself rather than a scenario
# from the field, and the FIXTURE lines below assert the read really is UINT32_MAX before anything else
# is claimed, so a future sanitiser change that closes this door fails the fixture loudly instead of
# passing [C] vacuously.
@tool
extends Node

const REGION_SIZE: int = 64
const VS: float = 1.0

const BASE_SHIFT: int = 27
const ID_MASK: int = 0x1F
const PRESERVE_MASK: int = 0x6

var _fail: int = 0


func _ready() -> void:
	print("=== RoadPerfRegressionGate: the ghost cut and texture 31 (spec §2) ===\n")
	_ghost_cut()
	_texture_31()
	print("\n=== %s (%d failures) ===\n" % [
		"ROAD PERF REGRESSION PASS" if _fail == 0 else "ROAD PERF REGRESSION FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	if not p_ok:
		_fail += 1
	print("%s %s: %s" % ["    " if p_ok else "!!  ", p_name, p_detail])


func _area(p_box: AABB) -> float:
	return p_box.size.x * p_box.size.z


## True when `p_outer` covers every corner of `p_inner` in XZ. Corner-wise rather than by AABB.encloses
## because the boxes carry a nominal ±10000 Y span that is not what is being asserted.
func _covers_xz(p_outer: AABB, p_inner: AABB) -> bool:
	const EPS := 0.001
	return p_outer.position.x <= p_inner.position.x + EPS \
			and p_outer.position.z <= p_inner.position.z + EPS \
			and p_outer.position.x + p_outer.size.x >= p_inner.position.x + p_inner.size.x - EPS \
			and p_outer.position.z + p_outer.size.z >= p_inner.position.z + p_inner.size.z - EPS


# ---- [A] / [B] the ghost cut -------------------------------------------------------------------

## A brush with one straight spline under it, both in the tree so `to_global` is meaningful.
##
## The spline is LONG on purpose. `_total_padding()` is a fixed lateral reach added to every box, so on a
## short spline it swamps the measurement and even a perfectly narrow partial box comes out at 80%+ of the
## whole — a fixture that would fail [B] on correct code. A kilometres-long road is also the case the
## partial path exists for.
func _spline_fixture() -> Array:
	var brush := Pasture3DRidge.new()
	add_child(brush)
	var path := Path3D.new()
	var curve := Curve3D.new()
	for i in range(41):
		curve.add_point(Vector3(float(i) * 50.0 - 1000.0, 0.0, 0.0))
	path.curve = curve
	brush.add_child(path)
	return [brush, path]


func _ghost_cut() -> void:
	print("[A] a node move clears where the brush WAS, not only where it went")
	var fx := _spline_fixture()
	var brush: Node3D = fx[0]
	var path: Path3D = fx[1]

	# Where the brush is painted right now — the box the auto-refresh recorded last bake.
	var prev: AABB = brush._spline_dirty_aabb(path, PackedInt32Array())
	_check("prev footprint is real", _area(prev) > 0.0, "area %.1f m2" % _area(prev))

	# A NODE move: the parent transform changes and every LOCAL curve position stays identical, which is
	# exactly why `_moved_point_indices` cannot see it and `_refresh_owner_rect` forces `snap_all`.
	brush.position = Vector3(200.0, 0.0, 0.0)
	var moved := PackedInt32Array()
	var dirty: AABB = brush._spline_dirty_aabb(path, moved, prev)
	var here: AABB = brush._spline_dirty_aabb(path, moved)

	_check("dirty box covers the OLD footprint", _covers_xz(dirty, prev),
			"old x[%.1f,%.1f] inside dirty x[%.1f,%.1f]" % [
				prev.position.x, prev.position.x + prev.size.x,
				dirty.position.x, dirty.position.x + dirty.size.x])
	_check("dirty box covers the NEW footprint", _covers_xz(dirty, here),
			"new x[%.1f,%.1f]" % [here.position.x, here.position.x + here.size.x])
	# The control. `here` is what the code produced BEFORE this fix — the fallback with no previous box —
	# and it must MISS the old footprint, or the fixture never reproduced the ghost and [A] proves nothing.
	_check("CONTROL: without the previous box the old cut is missed", not _covers_xz(here, prev),
			"here x[%.1f,%.1f] vs old x[%.1f,%.1f]" % [
				here.position.x, here.position.x + here.size.x,
				prev.position.x, prev.position.x + prev.size.x])

	print("\n[B] a single dragged point stays narrow — the speedup, protected")
	var fx2 := _spline_fixture()
	var brush2: Node3D = fx2[0]
	var path2: Path3D = fx2[1]
	var whole: AABB = brush2._spline_footprint_aabb(path2)
	# Seed the cache with the pre-drag local positions, then drag ONE point 2 m across.
	brush2._update_curve_cache(path2)
	var stale: AABB = brush2._spline_dirty_aabb(path2, PackedInt32Array())
	path2.curve.set_point_position(20, Vector3(0.0, 0.0, 2.0))
	var partial: AABB = brush2._spline_dirty_aabb(path2, PackedInt32Array([20]), stale)
	var frac := _area(partial) / maxf(_area(whole), 0.001)
	_check("partial box is a small fraction of the whole spline", frac < 0.15,
			"%.1f%% of the whole footprint (%.1f / %.1f m2)" % [
				frac * 100.0, _area(partial), _area(whole)])
	# The control. Unioning the last painted box in on the PARTIAL path — the naive fix for [A] — widens
	# it back to the whole spline, which is the regression [B] exists to refuse.
	var naive := partial.merge(stale)
	var naive_frac := _area(naive) / maxf(_area(whole), 0.001)
	_check("CONTROL: unioning prev on the partial path gives the win back", naive_frac > 0.60,
			"%.1f%% of the whole footprint" % [naive_frac * 100.0])


# ---- [C] / [D] texture 31 ----------------------------------------------------------------------

## A terrain whose regions EXIST but whose control maps have never been created, plus a control overlay
## layer for the road to write into. Both halves matter: without the regions `_apply_control_block` drops
## the write and nothing is measured; without the missing control maps `get_control` answers a real word
## and the bug is not reached.
func _terrain_fixture() -> Array:
	var terrain := Pasture3D.new()
	terrain.region_size = REGION_SIZE
	terrain.vertex_spacing = VS
	add_child(terrain)
	# `data` is get-only — the terrain owns and creates it, so the fixture configures the one it made.
	var data: Pasture3DData = terrain.data
	# `set_region_locations` only records locations — `add_region_blank` is what makes the region exist,
	# and `_apply_control_block` drops the write outright without one. A blank region has a height map and
	# no control map, which is exactly the state [C] is about.
	var region: Pasture3DRegion = data.add_region_blank(Vector2i(0, 0))
	# The region must EXIST — `_apply_control_block` drops the write outright without one — and its control
	# map must read back as no-data. A NaN-filled map of the right size and format is the only such state
	# that survives `sanitize_map`; see the note at the top of this file.
	# Sized from the REGION, not from REGION_SIZE: `terrain.region_size` is a request the data may not have
	# adopted, and a mismatch is rejected by validate_map_size and silently replaced with a blank map.
	var rs: int = region.get_region_size()
	var nan_map := Image.create_empty(rs, rs, false, Image.FORMAT_RF)
	nan_map.fill(Color(NAN, 0.0, 0.0, 1.0))
	region.set_control_map(nan_map)
	data.ensure_layer_stack()
	var stack := data.get_layer_stack()
	var idx: int = stack.add_layer("road_surface")
	var layer: Pasture3DLayer = stack.get_layer(idx)
	layer.set_map_type(1) # TYPE_CONTROL
	layer.set_base(false)
	return [terrain, data, idx]


func _texture_31() -> void:
	print("\n[C] a road over a cell with no control data paints texture 0, not texture 31")
	var fx := _terrain_fixture()
	var data: Pasture3DData = fx[1]
	var layer_id: int = fx[2]

	# The fixture must actually be in the state the criterion is about. UINT32_MAX arrives in GDScript as
	# -1 (get_control's int return), and its decode is what the bug would have written.
	var raw: int = data.get_control(Vector3(8.0, 0.0, 8.0))
	var bugged_base := (raw >> BASE_SHIFT) & ID_MASK
	_check("FIXTURE: the read really is the no-control-data answer", raw == -1 or raw == 0xFFFFFFFF,
			"get_control = %d, which would decode to base %d and preserve bits %d" % [
				raw, bugged_base, raw & PRESERVE_MASK])
	_check("FIXTURE: that decode is the regression's signature", bugged_base == 31,
			"base %d (texture 31 is the last slot)" % bugged_base)

	var gw := 16
	var gh := 16
	var surface := PackedFloat32Array()
	surface.resize(gw * gh)
	surface.fill(1.0)
	var written: int = data.stamp_road_surface_control(layer_id, surface, gw, gh, 4.0, 4.0, VS, 3)
	_check("the stamp wrote cells at all", written > 0, "%d cells written" % written)

	var stack := data.get_layer_stack()
	var layer: Pasture3DLayer = stack.get_layer(layer_id)
	var bad_base := 0
	var bad_preserve := 0
	var read := 0
	for iz in range(gh):
		for ix in range(gw):
			var px := Vector2i(4 + ix, 4 + iz)
			var v: float = layer.get_value(Vector2i(0, 0), px)
			if is_nan(v):
				continue
			read += 1
			# The control word is stored as the BIT PATTERN of a float, not as a number — `int(v)` would
			# read a denormal near zero and report base 0 no matter what was written, which is the value
			# this criterion is looking for. Round-tripping through the bytes is the only honest read.
			var ctrl: int = PackedFloat32Array([v]).to_byte_array().decode_u32(0)
			if ((ctrl >> BASE_SHIFT) & ID_MASK) != 0:
				bad_base += 1
			if (ctrl & PRESERVE_MASK) != 0:
				bad_preserve += 1
	_check("cells read back", read > 0, "%d of %d cells present on the layer" % [read, gw * gh])
	_check("no cell decodes to a base texture nobody chose", bad_base == 0,
			"%d of %d cells with base != 0" % [bad_base, read])
	_check("no cell had the hole / navigation bits turned on", bad_preserve == 0,
			"%d of %d cells with preserve bits set" % [bad_preserve, read])

	print("\n[D] a texture id above the 5-bit field is refused by BOTH paths, identically")
	var refused: int = data.stamp_road_surface_control(layer_id, surface, gw, gh, 4.0, 4.0, VS, 32)
	_check("native refuses id 32", refused == 0, "%d cells written" % refused)
	var gd: Dictionary = Pasture3DRoadPaint.surface_control(surface, PackedInt32Array(),
			{"texture_id": 32})
	_check("GDScript refuses id 32", gd["cells"].size() == 0, "%d cells" % gd["cells"].size())
	# The control. Id 31 is IN the field and both must still paint it, or [D] would pass on code that
	# simply refuses everything.
	var ok_native: int = data.stamp_road_surface_control(layer_id, surface, gw, gh, 4.0, 4.0, VS, 31)
	var ok_gd: Dictionary = Pasture3DRoadPaint.surface_control(surface, PackedInt32Array(),
			{"texture_id": 31})
	_check("CONTROL: id 31 is inside the field and both still paint it",
			ok_native > 0 and ok_gd["cells"].size() > 0,
			"native %d cells, gdscript %d cells" % [ok_native, ok_gd["cells"].size()])
